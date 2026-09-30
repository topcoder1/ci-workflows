"""A standing auto-merge arm must not survive a push that adds a gated path.

safe-paths-automerge.yml arms a PR while its diff is docs/tests-only, and
GitHub keeps that arm across later pushes by users with write access. A later
push that added a path the caller's .github/risk-paths.yml gates (or a tier-2
risk-regex path) together with any non-docs/tests file sent the classify step
down its defer branch: no reason, tiers 2 and 3 never ran, the revoke step
never fired, and the earlier arm merged the gated change once checks went
green. Found 2026-09-29 gating whois-api-llc/wxa_webcat's docs/website/
(wxa_webcat#1716). claude-author-automerge does not cover a human-authored
PR: its revoke needs claude_authored == '1'.

Every case runs the job as Actions does: the SHIPPED steps in order, each
step's SHIPPED `if:` and `env:` expressions evaluated against the outputs of
the steps before it, and each run block executed against a gh stub that holds
one PR's state (files, labels, auto-merge arm) and answers every call with the
step's own --jq filter. Nothing here mirrors the workflow's wiring, so a
condition or an env mapping that drifts changes the verdict.

1. An armed docs-only human PR whose next push adds a caller-sensitive path
   and a src file loses its arm, as does one whose push adds a tier-2 path or
   a caller-blocked path with a src file.
2. A Dependabot workflow bump armed by dependabot-auto-merge keeps its arm,
   and the mixed branch neither reads the arm nor runs the classifier for it.
   Control: the same bump from a human loses its arm.
3. The all-safe path is unchanged: the shipped enable step arms a docs-only
   PR, a docs-only re-push keeps its arm, and the would-arm branch's tier-2
   and tier-3 holds still revoke.
4. No fight with a sibling's legitimate arm: a standard-class mixed diff keeps
   its arm, the bypass label releases the tier-2 verdict (claude-author's
   Option A) but not the caller's policy, an unarmed PR costs one read and no
   classifier run, and an event that brings no new content never revokes.
5. Fail closed, as tier 3 does: an unreadable arm state counts as armed, and an
   unreadable risk-paths.yml, a classifier error or a failed Setup Node on this
   route all revoke.
6. A crafted file name on the new branch cannot add an output key or inject a
   workflow command.
"""

import json
import os
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "safe-paths-automerge.yml"
CLASSIFY_MJS = ROOT / ".github" / "scripts" / "classify.mjs"
CLASSIFIER_DEPS = ROOT / ".github" / "scripts" / "classifier-deps.mjs"

DOC = yaml.safe_load(WORKFLOW.read_text())
# PyYAML reads the bare `on:` key as the boolean True (YAML 1.1).
TRIGGER = DOC.get("on", DOC.get(True))
INPUT_DEFAULTS = {
    name: spec.get("default", "")
    for name, spec in TRIGGER["workflow_call"]["inputs"].items()
}
STEPS = DOC["jobs"]["safe_paths_automerge"]["steps"]

REPO = "acme/fixture"
PR_NUMBER = 7

# The wxa_webcat#1716 shape: docs/website/** is the caller's own `sensitive:`
# entry, which neither fleet-wide tier knows about.
POLICY = """\
blocked:
  - 'ops/**'
  - '.github/workflows/**'
sensitive:
  - 'docs/website/**'
safe_test:
  - 'tests/**'
trivial:
  - 'docs/**'
"""

# ---------------------------------------------------------------------------
# GitHub expressions, for the subset this workflow uses. Anything outside it
# (`!`, a function call, indexing) raises, so a new construct in the workflow
# fails this test loudly instead of evaluating wrong.
# ---------------------------------------------------------------------------
_TOKEN = re.compile(
    r"\s*(?:"
    r"(?P<str>'(?:[^']|'')*')"
    r"|(?P<op>&&|\|\||==|!=|\(|\))"
    r"|(?P<func>always|success|failure|cancelled)\(\)"
    r"|(?P<name>[A-Za-z_][\w-]*(?:\.[\w-]+)*)"
    r")"
)
_STATUS = re.compile(r"\b(?:always|success|failure|cancelled)\(\)")
_WHOLE = re.compile(r"\A\$\{\{(.*)\}\}\Z", re.S)


def _translate(expr):
    expr = expr.strip()
    out, pos = [], 0
    while pos < len(expr):
        m = _TOKEN.match(expr, pos)
        if not m or m.end() == pos:
            raise ValueError(f"unsupported expression syntax at {expr[pos:]!r}")
        pos = m.end()
        if m["str"] is not None:
            out.append(repr(m["str"][1:-1].replace("''", "'")))
        elif m["op"]:
            out.append({"&&": " and ", "||": " or "}.get(m["op"], f" {m['op']} "))
        elif m["func"]:
            out.append(f"_{m['func']}()")
        elif m["name"] in ("true", "false", "null"):
            out.append({"true": "True", "false": "False", "null": "None"}[m["name"]])
        else:
            out.append(f"_get({m['name']!r})")
    return "".join(out)


def _evaluate(expr, ctx, prior_failed):
    def get(path):
        node = ctx
        for part in path.split("."):
            if not isinstance(node, dict) or part not in node:
                return ""
            node = node[part]
        return node

    scope = {
        "__builtins__": {},
        "_get": get,
        "_always": lambda: True,
        "_success": lambda: not prior_failed,
        "_failure": lambda: prior_failed,
        "_cancelled": lambda: False,
    }
    return eval(_translate(expr), scope)


def step_runs(step, ctx, prior_failed):
    """An `if:` without a status function carries an implicit success()."""
    cond = step.get("if")
    if cond is None:
        return not prior_failed
    value = bool(_evaluate(str(cond), ctx, prior_failed))
    return value if _STATUS.search(str(cond)) else value and not prior_failed


def step_env(step, ctx):
    env = {}
    for name, raw in (step.get("env") or {}).items():
        raw = str(raw)
        m = _WHOLE.match(raw.strip())
        if m:
            value = _evaluate(m[1], ctx, False)
        elif "${{" in raw:
            raise ValueError(f"{name}: an expression inside a string is not supported")
        else:
            value = raw
        if isinstance(value, bool):
            value = "true" if value else "false"
        env[name] = "" if value is None else str(value)
    return env


def parse_outputs(text):
    outputs, lines, i = {}, text.split("\n"), 0
    while i < len(lines):
        line = lines[i]
        eq, heredoc = line.find("="), line.find("<<")
        if heredoc > 0 and (eq < 0 or heredoc < eq):
            name, delim = line[:heredoc], line[heredoc + 2 :]
            body, i = [], i + 1
            while i < len(lines) and lines[i] != delim:
                body.append(lines[i])
                i += 1
            outputs[name] = "\n".join(body)
        elif eq > 0:
            outputs[line[:eq]] = line[eq + 1 :]
        i += 1
    return outputs


# ---------------------------------------------------------------------------
# The gh stub: one pull request whose state lives in files under $STUB_DIR.
# Every read runs the caller's own --jq filter over API-shaped JSON; the arm is
# one piece of state seen through both the REST (`auto_merge`) and the GraphQL
# (`autoMergeRequest`) shapes, and only `gh pr merge` changes it.
# ---------------------------------------------------------------------------
GH_STUB = r"""#!/usr/bin/env bash
set -uo pipefail
d="$STUB_DIR"
printf '%s\n' "$*" >> "$d/calls.log"
filter=""
prev=""
for a in "$@"; do
  [ "$prev" = "--jq" ] && filter="$a"
  prev="$a"
done
out() { if [ -n "$filter" ]; then jq -r "$filter"; else cat; fi; }
arm=$(cat "$d/arm")
case "${1:-} ${2:-}" in
  "pr view")
    jq -n --arg arm "$arm" '{autoMergeRequest: (if $arm == "ON" then {enabledBy: {login: "pat-user", is_bot: false}} else null end)}' | out
    exit ;;
  "pr merge")
    case " $* " in
      *" --disable-auto "*)
        echo disable >> "$d/disable.log"; echo OFF > "$d/arm"; exit 0 ;;
      *" --auto "*)
        want=""; prev=""
        for a in "$@"; do [ "$prev" = "--match-head-commit" ] && want="$a"; prev="$a"; done
        [ "$want" = "$(cat "$d/head_sha")" ] || { echo "gh: head moved" >&2; exit 1; }
        echo arm >> "$d/arm.log"; echo ON > "$d/arm"; exit 0 ;;
    esac ;;
  "api user")
    echo '{"login": "pat-user", "type": "User"}' | out
    exit ;;
esac
url=""
for a in "$@"; do case "$a" in repos/*) url="$a"; break ;; esac; done
case "$url" in
  "repos/__REPO__/pulls/__PR__/files"*)
    out < "$d/files.json"; exit ;;
  "repos/__REPO__/pulls/__PR__")
    case "$filter" in
      *auto_merge*) [ -e "$d/arm_read_fails" ] && { echo "gh: Bad Gateway (HTTP 502)" >&2; exit 1; } ;;
    esac
    jq -n --arg sha "$(cat "$d/head_sha")" --arg arm "$arm" --slurpfile labels "$d/labels.json" \
      '{head: {sha: $sha}, labels: $labels[0], auto_merge: (if $arm == "ON" then {enabled_by: {login: "pat-user", type: "User"}, merge_method: "squash"} else null end)}' | out
    exit ;;
  "repos/__REPO__/contents/.github/risk-paths.yml")
    [ -e "$d/risk_500" ] && { echo "gh: Internal Server Error (HTTP 500)" >&2; exit 1; }
    [ -e "$d/risk.yml" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    base64 < "$d/risk.yml" | tr -d '\n'; echo; exit ;;
  "repos/topcoder1/ci-workflows/contents/.github/scripts/classify.mjs")
    base64 < "$d/classify.mjs" | tr -d '\n'; echo; exit ;;
  "repos/topcoder1/ci-workflows/contents/.github/scripts/classifier-deps.mjs")
    base64 < "__DEPS__" | tr -d '\n'; echo; exit ;;
esac
echo "gh-stub: unexpected call: $*" >&2
exit 64
"""


@dataclass
class PR:
    """One revision of the PR, as the event that runs the job sees it."""

    files: list
    head_sha: str = "a" * 40
    author: str = "octo-human"
    branch: str = "feature/docs"
    action: str = "synchronize"
    labels: tuple = ()
    armed: object = None  # True/False sets the arm; None keeps the stub's state
    policy: object = None  # risk-paths.yml text; None is a 404
    risk_500: bool = False
    arm_read_fails: bool = False
    setup_node_fails: bool = False
    classify_mjs: object = None  # replacement classifier source


class Stub:
    def __init__(self, tmp):
        self.tmp = tmp
        self.dir = tmp / "stub"
        self.bin = tmp / "bin"
        self.dir.mkdir()
        self.bin.mkdir()
        gh = self.bin / "gh"
        gh.write_text(
            GH_STUB.replace("__REPO__", REPO)
            .replace("__PR__", str(PR_NUMBER))
            .replace("__DEPS__", str(CLASSIFIER_DEPS))
        )
        gh.chmod(0o755)
        # The steps back off with sleep between retries; the stub never
        # recovers, so waiting only slows the test.
        sleep = self.bin / "sleep"
        sleep.write_text("#!/usr/bin/env bash\nexit 0\n")
        sleep.chmod(0o755)
        (self.dir / "arm").write_text("OFF\n")
        self.runs = 0

    def stage(self, pr):
        d = self.dir
        rows = []
        for entry in pr.files:
            if "=>" in entry:
                old, new = entry.split("=>", 1)
                rows.append(
                    {"filename": new, "previous_filename": old, "status": "renamed"}
                )
            else:
                rows.append({"filename": entry, "status": "modified"})
        (d / "files.json").write_text(json.dumps(rows))
        (d / "labels.json").write_text(json.dumps([{"name": n} for n in pr.labels]))
        (d / "head_sha").write_text(pr.head_sha + "\n")
        if pr.armed is not None:
            (d / "arm").write_text("ON\n" if pr.armed else "OFF\n")
        for name in (
            "risk.yml",
            "risk_500",
            "arm_read_fails",
            "calls.log",
            "disable.log",
            "arm.log",
        ):
            (d / name).unlink(missing_ok=True)
        if pr.policy is not None:
            (d / "risk.yml").write_text(pr.policy)
        if pr.risk_500:
            (d / "risk_500").touch()
        if pr.arm_read_fails:
            (d / "arm_read_fails").touch()
        (d / "classify.mjs").write_text(
            pr.classify_mjs if pr.classify_mjs is not None else CLASSIFY_MJS.read_text()
        )

    def arm(self):
        return (self.dir / "arm").read_text().strip()

    def lines(self, name):
        path = self.dir / name
        return path.read_text().splitlines() if path.exists() else []


def context(pr, steps):
    return {
        "github": {
            "token": "ghs_stub",
            "repository": REPO,
            "event": {
                "action": pr.action,
                "repository": {"default_branch": "main"},
                "pull_request": {
                    "number": PR_NUMBER,
                    "draft": False,
                    "html_url": f"https://github.com/{REPO}/pull/{PR_NUMBER}",
                    "user": {"login": pr.author},
                    "head": {"sha": pr.head_sha, "ref": pr.branch},
                    "base": {"ref": "main"},
                },
            },
        },
        "inputs": dict(INPUT_DEFAULTS),
        "secrets": {"automerge_pat": "pat_stub"},
        "steps": steps,
    }


@dataclass
class Job:
    steps: dict
    logs: dict
    arm: str
    disables: int
    arms: int
    calls: list

    def out(self, step_id):
        return self.steps.get(step_id, {}).get("outputs", {})

    def outcome(self, step_id):
        return self.steps.get(step_id, {}).get("outcome")

    def reads(self, needle):
        return sum(needle in call for call in self.calls)

    def __str__(self):
        parts = [f"arm={self.arm} disables={self.disables} arms={self.arms}"]
        for key, state in self.steps.items():
            parts.append(f"  {key}: {state['outcome']} {state['outputs']}")
        parts.append("  gh calls:")
        parts.extend(f"    {c}" for c in self.calls)
        for key, log in self.logs.items():
            parts.append(f"  --- {key} log ---")
            parts.extend(f"    {line}" for line in log.splitlines())
        return "\n".join(parts)


def run_job(stub, pr):
    stub.runs += 1
    work = stub.tmp / f"run{stub.runs}"
    work.mkdir()
    stub.stage(pr)
    steps, logs, prior_failed = {}, {}, False
    for index, step in enumerate(STEPS):
        key = step.get("id") or step["name"]
        ctx = context(pr, steps)
        if not step_runs(step, ctx, prior_failed):
            steps[key] = {"outcome": "skipped", "outputs": {}}
            continue
        if "uses" in step:
            failed = pr.setup_node_fails and step.get("id") == "setup_node"
            steps[key] = {"outcome": "failure" if failed else "success", "outputs": {}}
        else:
            step_dir = work / f"step{index}"
            step_dir.mkdir()
            script = step_dir / "run.sh"
            script.write_text(step["run"])
            output = step_dir / "github_output"
            output.write_text("")
            env = {
                "PATH": f"{stub.bin}{os.pathsep}{os.environ['PATH']}",
                "HOME": os.environ.get("HOME", str(step_dir)),
                "TMPDIR": str(step_dir),
                "GITHUB_OUTPUT": str(output),
                "GITHUB_STEP_SUMMARY": str(step_dir / "summary.md"),
                "GITHUB_REPOSITORY": REPO,
                "STUB_DIR": str(stub.dir),
            }
            env.update(step_env(step, ctx))
            proc = subprocess.run(
                ["bash", "-e", str(script)],
                env=env,
                cwd=step_dir,
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                timeout=120,
            )
            logs[key] = proc.stdout + proc.stderr
            steps[key] = {
                "outcome": "success" if proc.returncode == 0 else "failure",
                "outputs": parse_outputs(output.read_text()),
            }
        prior_failed = prior_failed or steps[key]["outcome"] == "failure"
    return Job(
        steps=steps,
        logs=logs,
        arm=stub.arm(),
        disables=len(stub.lines("disable.log")),
        arms=len(stub.lines("arm.log")),
        calls=stub.lines("calls.log"),
    )


REVOKE = next(s["name"] for s in STEPS if s["name"].startswith("Revoke auto-merge"))


def armed_by_a_docs_only_revision(tmp_path):
    """Revision 1 — docs-only, armed by the SHIPPED enable step."""
    stub = Stub(tmp_path)
    first = run_job(
        stub, PR(["docs/runbooks/restore.md"], head_sha="1" * 40, policy=POLICY)
    )
    assert first.arms == 1 and first.arm == "ON" and first.disables == 0, (
        f"the docs-only revision must be armed here:\n{first}"
    )
    return stub


# ---------------------------------------------------------------------------
# 1. The gap: a push that adds a gated path AND a src file revokes the arm.
# ---------------------------------------------------------------------------
@pytest.mark.parametrize(
    "push, policy, step_id, verdict",
    [
        pytest.param(
            ["docs/runbooks/restore.md", "docs/website/pricing.md", "src/x.py"],
            POLICY,
            "classifier_hold",
            {"hold": "1", "reason": "classifier-hold"},
            id="caller-sensitive",
        ),
        pytest.param(
            ["src/auth/login.py", "src/x.py"],
            None,
            "classify",
            {"all_safe": "0", "reason": "standing-arm-risk-tier"},
            id="tier-2-regex",
        ),
        pytest.param(
            ["ops/rotate.sh", "src/x.py"],
            POLICY,
            "classifier_hold",
            {"hold": "1", "reason": "classifier-hold"},
            id="caller-blocked",
        ),
    ],
)
def test_a_push_adding_a_gated_path_and_src_revokes_the_docs_only_arm(
    tmp_path, push, policy, step_id, verdict
):
    stub = armed_by_a_docs_only_revision(tmp_path)
    job = run_job(stub, PR(push, head_sha="2" * 40, policy=policy))
    assert job.arm == "OFF" and job.disables >= 1, (
        f"the arm from the docs-only revision survived a push adding a gated path:\n{job}"
    )
    assert job.outcome(REVOKE) == "success", (
        f"the revoke step did not finish clean:\n{job}"
    )
    assert job.out(step_id) == verdict, f"unexpected {step_id} outputs:\n{job}"


# ---------------------------------------------------------------------------
# 2. Dependabot: its arm belongs to dependabot-auto-merge.
# ---------------------------------------------------------------------------
@pytest.mark.parametrize(
    "files, policy",
    [
        pytest.param([".github/workflows/ci.yml"], POLICY, id="workflow-bump"),
        pytest.param(["Dockerfile"], None, id="docker-bump"),
    ],
)
def test_a_dependabot_bump_keeps_dependabot_auto_merges_arm(tmp_path, files, policy):
    stub = Stub(tmp_path)
    job = run_job(
        stub,
        PR(
            files,
            author="dependabot[bot]",
            branch="dependabot/github_actions/actions/checkout-7",
            armed=True,
            policy=policy,
        ),
    )
    assert job.arm == "ON" and job.disables == 0, (
        f"dependabot-auto-merge's arm was revoked:\n{job}"
    )
    assert job.out("classify") == {"all_safe": "0"}, (
        f"unexpected classify outputs:\n{job}"
    )
    assert job.reads("auto_merge") == 0 and job.reads("/contents/") == 0, (
        f"the mixed branch read the arm or ran the classifier on a Dependabot PR:\n{job}"
    )


def test_the_same_workflow_bump_from_a_human_loses_its_arm(tmp_path):
    """Control for the Dependabot case: the author, not the path, spares it."""
    stub = Stub(tmp_path)
    job = run_job(stub, PR([".github/workflows/ci.yml"], armed=True, policy=POLICY))
    assert job.arm == "OFF" and job.disables >= 1, (
        f"a human's workflow edit kept its arm:\n{job}"
    )


# ---------------------------------------------------------------------------
# 3. The all-safe path is unchanged.
# ---------------------------------------------------------------------------
def test_the_all_safe_path_still_arms_and_keeps_its_arm(tmp_path):
    stub = Stub(tmp_path)
    fresh = run_job(stub, PR(["docs/guide.md", "tests/test_guide.py"], policy=POLICY))
    assert fresh.arms == 1 and fresh.arm == "ON" and fresh.disables == 0, (
        f"a docs/tests-only PR was not armed:\n{fresh}"
    )
    assert fresh.out("classify") == {"all_safe": "1", "renames_safe": "1"}, str(fresh)
    assert fresh.out("classifier_hold") == {"hold": "0"}, str(fresh)
    assert fresh.reads("auto_merge") == 0, (
        f"the would-arm branch read the arm state:\n{fresh}"
    )

    repush = run_job(
        stub, PR(["docs/guide.md", "docs/faq.md"], head_sha="3" * 40, policy=POLICY)
    )
    assert repush.arm == "ON" and repush.disables == 0, (
        f"a docs-only re-push lost its arm:\n{repush}"
    )


@pytest.mark.parametrize(
    "files, policy, step_id, verdict",
    [
        pytest.param(
            ["docs/website/pricing.md"],
            POLICY,
            "classifier_hold",
            {"hold": "1", "reason": "classifier-hold"},
            id="tier-3",
        ),
        pytest.param(
            ["docs/decisions/0007-cache.md"],
            None,
            "classify",
            {"all_safe": "0", "reason": "risk-tier-hold"},
            id="tier-2",
        ),
    ],
)
def test_the_would_arm_branch_still_revokes_its_holds(
    tmp_path, files, policy, step_id, verdict
):
    stub = Stub(tmp_path)
    job = run_job(stub, PR(files, armed=True, policy=policy))
    assert job.arm == "OFF" and job.disables >= 1, (
        f"a docs-only hold kept a standing arm:\n{job}"
    )
    assert job.out(step_id) == verdict, f"unexpected {step_id} outputs:\n{job}"


# ---------------------------------------------------------------------------
# 4. No fight with a sibling's legitimate arm.
# ---------------------------------------------------------------------------
def test_a_standard_mixed_diff_keeps_a_siblings_arm(tmp_path):
    """claude-author-automerge arms standard-class diffs; this must not undo that."""
    stub = Stub(tmp_path)
    job = run_job(
        stub,
        PR(
            ["src/x.py", "docs/notes.md"],
            branch="claude/refactor",
            armed=True,
            policy=POLICY,
        ),
    )
    assert job.arm == "ON" and job.disables == 0, (
        f"a sibling's standard-class arm was revoked:\n{job}"
    )
    assert job.out("classify") == {"all_safe": "0", "standing_arm_check": "1"}, str(job)
    assert job.out("classifier_hold") == {"hold": "0"}, str(job)


def test_the_bypass_label_releases_the_tier_2_verdict_only(tmp_path):
    label = INPUT_DEFAULTS["risk_bypass_label"]
    stub = Stub(tmp_path)
    released = run_job(
        stub, PR(["src/auth/login.py", "src/x.py"], labels=(label,), armed=True)
    )
    assert released.arm == "ON" and released.disables == 0, (
        f"the bypass label did not release the tier-2 verdict (claude-author's Option A):\n{released}"
    )
    assert released.out("classify") == {"all_safe": "0", "standing_arm_check": "1"}, (
        str(released)
    )

    held = run_job(
        stub,
        PR(
            ["docs/website/pricing.md", "src/x.py"],
            labels=(label,),
            armed=True,
            policy=POLICY,
        ),
    )
    assert held.arm == "OFF" and held.disables >= 1, (
        f"the bypass label released the caller's own risk-paths.yml verdict:\n{held}"
    )


def test_an_unarmed_mixed_diff_costs_one_read_and_no_classifier_run(tmp_path):
    stub = Stub(tmp_path)
    job = run_job(
        stub, PR(["docs/website/pricing.md", "src/x.py"], armed=False, policy=POLICY)
    )
    assert job.disables == 0 and job.arm == "OFF", str(job)
    assert job.out("classify") == {"all_safe": "0"}, str(job)
    assert job.reads("auto_merge") == 1, f"expected exactly one arm-state read:\n{job}"
    assert job.reads("/contents/") == 0, (
        f"the classifier ran with nothing to revoke:\n{job}"
    )
    assert job.outcome("classifier_hold") == "skipped", str(job)


def test_an_event_that_brings_no_new_content_never_revokes(tmp_path):
    """A labeled run sees an arm placed after the last push, with that content in view."""
    stub = Stub(tmp_path)
    job = run_job(
        stub, PR(["src/auth/login.py", "src/x.py"], action="labeled", armed=True)
    )
    assert job.arm == "ON" and job.disables == 0, (
        f"a labeled event revoked an arm:\n{job}"
    )
    assert job.reads("auto_merge") == 0, str(job)


# ---------------------------------------------------------------------------
# 5. Fail closed, the way tier 3 does.
# ---------------------------------------------------------------------------
def test_an_unreadable_arm_state_counts_as_armed(tmp_path):
    stub = Stub(tmp_path)
    job = run_job(
        stub,
        PR(
            ["docs/website/pricing.md", "src/x.py"],
            armed=True,
            arm_read_fails=True,
            policy=POLICY,
        ),
    )
    assert job.arm == "OFF" and job.disables >= 1, (
        f"an unreadable arm state skipped the check:\n{job}"
    )
    assert job.out("classify").get("standing_arm_check") == "1", str(job)


@pytest.mark.parametrize(
    "fault, reason",
    [
        pytest.param({"risk_500": True}, "rules-unreadable", id="rules-unreadable"),
        pytest.param(
            {"classify_mjs": "process.stdout.write('bogus\\n');\n"},
            "classifier-enum",
            id="classifier-enum",
        ),
    ],
)
def test_a_tier_3_error_on_this_route_revokes(tmp_path, fault, reason):
    stub = Stub(tmp_path)
    job = run_job(
        stub, PR(["src/x.py", "docs/notes.md"], armed=True, policy=POLICY, **fault)
    )
    assert job.out("classifier_hold") == {"hold": "1", "reason": reason}, str(job)
    assert job.arm == "OFF" and job.disables >= 1, (
        f"a tier-3 error left the arm standing:\n{job}"
    )


def test_a_failed_setup_node_on_this_route_revokes(tmp_path):
    stub = Stub(tmp_path)
    job = run_job(
        stub,
        PR(
            ["src/x.py", "docs/notes.md"],
            armed=True,
            policy=POLICY,
            setup_node_fails=True,
        ),
    )
    assert job.outcome("classifier_hold") == "skipped", str(job)
    assert job.arm == "OFF" and job.disables >= 1, (
        f"a failed Setup Node left the arm standing:\n{job}"
    )


# ---------------------------------------------------------------------------
# 6. PR-controlled file names on the new branch.
# ---------------------------------------------------------------------------
def test_a_crafted_file_name_cannot_steer_the_new_branch(tmp_path):
    bs = "\\"
    crafted = f"src/auth/x{bs}n::notice::injected{bs}nall_safe=1{bs}nEOF.py"
    stub = Stub(tmp_path)
    job = run_job(stub, PR([crafted, "src/x.py"], armed=True))
    assert job.out("classify") == {
        "all_safe": "0",
        "reason": "standing-arm-risk-tier",
    }, str(job)
    log = job.logs["classify"].splitlines()
    assert not any(line.startswith("::notice::injected") for line in log), str(job)
    assert "all_safe=1" not in log, str(job)
    assert job.arm == "OFF", str(job)
