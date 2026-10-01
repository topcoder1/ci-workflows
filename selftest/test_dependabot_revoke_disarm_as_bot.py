"""dependabot-auto-merge's revoke must not read as a human's durable hold.

revoke-stale-arm withdraws the arm dependabot-auto-merge.yml granted once a
Dependabot PR carries a commit Dependabot did not make. It disarmed with the
caller's automerge_pat, so GitHub recorded the `auto_merge_disabled` under the
PAT's user. claude-author-automerge.yml's manual-hold step (its Signal 2) reads
the newest auto-merge event as a HUMAN's durable hold whenever it is a disable
by anyone but github-actions[bot], and its enable step then never arms the PR
again. That workflow does judge this PR: the commit that made it non-bot is a
Claude session's fix pushed onto the Dependabot branch, and its
`Co-Authored-By: Claude` trailer marks the PR Claude-authored (the override
label does too), while its enable step exempts Dependabot PRs from the PAT
requirement. So once the revoke ran, every later claude-author run reported
`timeline:human-disable-newest` and never armed the PR, with no error
anywhere, though no human had disabled anything. A caller without the PAT
never had the hold: its revoke already ran as github-actions[bot].

The revoke now disarms the way claude-author's and safe-paths' revokes do: as
github-actions[bot] (GITHUB_TOKEN can disable an arm the PAT user placed,
whois-api-llc/wxa_webcat#1715), three verified attempts, and only then as the
PAT user, so it stays fail-closed.

Each case runs the SHIPPED jobs for one event the way Actions does:
authorship's step, then the `auto-merge` and `revoke-stale-arm` jobs' `if:`
evaluated on its output, then the revoke step with its SHIPPED `env:`, against
a gh stub that holds one PR (commits, auto-merge arm, timeline) and records
each auto-merge event under the actor its token stands for.
claude-author-automerge's SHIPPED detection and manual-hold steps then read
the same PR, the detection step in a real checkout of its history.

1. A push from a Claude session onto an armed Dependabot PR: the revoke
   disarms once, as github-actions[bot]; claude-author calls the PR
   Claude-authored, and its hold step reports no hold. Control: a human's
   disable still holds.
2. Fallback: a bot that cannot disarm is tried three times, then the PAT,
   verified; with no PAT wired, the step fails after the bot's attempts.
3. Fail closed: an arm still ON, or unreadable, after every attempt fails the
   step and posts no explanation.
4. Ownership: a head pushed (and armed by its own run) while the revoke
   retries ends the revoke; the PAT never disarms it.
5. Negative control: the same revoke with BOT_TOKEN wired to the PAT is read
   as a human's hold, so case 1 can fail.
"""

import copy
import json
import os
import subprocess
from dataclasses import dataclass
from pathlib import Path

import pytest
import yaml

# The GitHub-expression subset evaluator: one implementation, so a construct
# it cannot read fails loudly in both harnesses instead of evaluating wrong.
from selftest.test_safe_paths_standing_arm_revoke import (
    parse_outputs,
    step_env,
    step_runs,
)

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
DB = yaml.safe_load((WORKFLOWS / "dependabot-auto-merge.yml").read_text())
DB_JOBS = DB["jobs"]
# PyYAML reads the bare `on:` key as the boolean True (YAML 1.1).
DB_INPUTS = {
    name: spec.get("default", "")
    for name, spec in DB.get("on", DB.get(True))["workflow_call"]["inputs"].items()
}
REVOKE = next(
    s
    for s in DB_JOBS["revoke-stale-arm"]["steps"]
    if s["name"] == "Revoke the arm if a non-bot commit is present"
)

CA = yaml.safe_load((WORKFLOWS / "claude-author-automerge.yml").read_text())
CA_INPUTS = {
    name: spec.get("default", "")
    for name, spec in CA.get("on", CA.get(True))["workflow_call"]["inputs"].items()
}
CA_STEPS = {s["id"]: s for s in CA["jobs"]["automerge"]["steps"] if "id" in s}

REPO = "acme/fixture"
PR_NUMBER = 7
BRANCH = "dependabot/npm_and_yarn/lodash-4.17.21"
GITHUB_TOKEN = "ghs_stub"  # secrets.GITHUB_TOKEN: acts as github-actions[bot]
PAT = "pat_stub"  # secrets.automerge_pat: acts as its user, pat-user
PUSHER = "octo-human"  # pushes a Claude session's fix onto the Dependabot branch
NEW_HEAD = "b" * 40  # a head pushed while the revoke is still retrying

# ---------------------------------------------------------------------------
# The gh stub: one pull request whose state lives in files under $STUB_DIR.
# Every read runs the caller's own --jq filter over API-shaped JSON. Each
# disarm is logged with the token that ran it, and each change of the arm
# lands on the PR's timeline under the actor that token stands for, which is
# what claude-author-automerge's hold step reads.
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
case "${GH_TOKEN:-}" in
  "__BOT_TOKEN__") actor="github-actions[bot]" ;;
  "__PAT__") actor="pat-user" ;;
  *) actor="" ;;
esac
record() { # an auto-merge event on the PR's timeline, as this token's actor
  local n
  n=$(( $(cat "$d/clock") + 1 ))
  echo "$n" > "$d/clock"
  jq --arg event "$1" --arg login "$actor" \
    --arg at "$(printf '2026-10-01T10:%02d:%02dZ' $((n / 60)) $((n % 60)))" \
    '. + [{event: $event, created_at: $at, actor: {login: $login}}]' \
    "$d/timeline.json" > "$d/timeline.next" && mv "$d/timeline.next" "$d/timeline.json"
}
case "${1:-} ${2:-}" in
  "pr view")
    n=$(( $(cat "$d/view_reads" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$d/view_reads"
    if [ "$n" -gt 1 ] && [ -e "$d/later_view_reads_fail" ]; then
      # gh pr view's GraphQL errors go to stderr only (measured, gh 2.89).
      echo "GraphQL: Something went wrong while executing your query." >&2; exit 1
    fi
    jq -n --arg arm "$(cat "$d/arm")" \
      '{autoMergeRequest: (if $arm == "ON" then {enabledBy: {login: "pat-user"}} else null end)}' | out
    exit ;;
  "pr merge")
    [ -n "$actor" ] || { echo "gh-stub: GH_TOKEN is neither github.token nor the PAT: '${GH_TOKEN:-}'" >&2; exit 4; }
    case " $* " in
      *" --disable-auto "*)
        echo "${GH_TOKEN:-}" >> "$d/disable.log"
        if [ -e "$d/move_head_on_disarm" ]; then
          # A push lands mid-revoke, and that head's own run arms it.
          rm -f "$d/move_head_on_disarm"
          echo "__NEW_HEAD__" > "$d/head_sha"; echo ON > "$d/arm"
        fi
        if [ -e "$d/bot_cannot_disarm" ] && [ "${GH_TOKEN:-}" = "__BOT_TOKEN__" ]; then
          echo "gh: Resource not accessible by integration (HTTP 403)" >&2; exit 1
        fi
        # The disable is accepted, yet the arm reads ON again (re-armed under it).
        [ -e "$d/disarm_does_not_stick" ] && exit 0
        [ "$(cat "$d/arm")" = ON ] && record auto_merge_disabled
        echo OFF > "$d/arm"; exit 0 ;;
    esac ;;
  "pr comment")
    echo comment >> "$d/comment.log"; exit 0 ;;
esac
url=""
for a in "$@"; do case "$a" in repos/* | /repos/*) url="${a#/}"; break ;; esac; done
case "$url" in
  "repos/__REPO__/pulls/__PR__/commits")
    out < "$d/commits.json"; exit ;;
  "repos/__REPO__/pulls/__PR__")
    jq -n --arg sha "$(cat "$d/head_sha")" '{head: {sha: $sha}}' | out; exit ;;
  "repos/__REPO__/issues/__PR__/labels"*)
    echo '[]' | out; exit ;;
  "repos/__REPO__/issues/__PR__/timeline"*)
    out < "$d/timeline.json"; exit ;;
esac
echo "gh-stub: unexpected call: $*" >&2
exit 64
"""

FAULTS = (
    "bot_cannot_disarm",  # GITHUB_TOKEN's --disable-auto is refused
    "disarm_does_not_stick",  # every --disable-auto exits 0, the arm stays ON
    "later_view_reads_fail",  # every arm-state read after the first fails
    "move_head_on_disarm",  # NEW_HEAD lands, armed, during the first disarm
)


@dataclass
class PR:
    """The event that runs the jobs: a push onto a Dependabot PR."""

    base_sha: str
    head_sha: str
    pat_wired: bool = True  # the caller passes automerge_pat


@dataclass
class Step:
    rc: int
    outputs: dict
    log: str


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
            .replace("__BOT_TOKEN__", GITHUB_TOKEN)
            .replace("__PAT__", PAT)
            .replace("__NEW_HEAD__", NEW_HEAD)
        )
        gh.chmod(0o755)
        # The revoke backs off with sleep between attempts; waiting only
        # slows the test.
        sleep = self.bin / "sleep"
        sleep.write_text("#!/usr/bin/env bash\nexit 0\n")
        sleep.chmod(0o755)
        (self.dir / "arm").write_text("OFF\n")
        (self.dir / "timeline.json").write_text("[]")
        (self.dir / "clock").write_text("0\n")
        self.runs = 0

    def record(self, event, login):
        """An auto-merge event on the PR's timeline, the way the stub adds one."""
        n = int((self.dir / "clock").read_text()) + 1
        (self.dir / "clock").write_text(f"{n}\n")
        timeline = json.loads((self.dir / "timeline.json").read_text())
        timeline.append(
            {
                "event": event,
                "created_at": f"2026-10-01T10:{n // 60:02d}:{n % 60:02d}Z",
                "actor": {"login": login},
            }
        )
        (self.dir / "timeline.json").write_text(json.dumps(timeline))

    def arm(self):
        return (self.dir / "arm").read_text().strip()

    def lines(self, name):
        path = self.dir / name
        return path.read_text().splitlines() if path.exists() else []

    def disarmed_by(self):
        """The token each --disable-auto ran with, in order."""
        return self.lines("disable.log")

    def comments(self):
        return len(self.lines("comment.log"))


def dependabot_history(tmp):
    """The PR's history in a real checkout: Dependabot's bump, then a fix a
    Claude session pushed onto the same branch, carrying its trailer."""
    repo = tmp / "checkout"
    repo.mkdir()
    env = {**os.environ, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"}

    def git(*args):
        return subprocess.run(
            ["git", *args], cwd=repo, env=env, check=True, capture_output=True, text=True
        ).stdout.strip()

    def commit(message, name, email):
        identity = ["-c", f"user.name={name}", "-c", f"user.email={email}"]
        git(*identity, "commit", "-q", "--allow-empty", "-m", message)
        return git("rev-parse", "HEAD")

    git("init", "-q")
    base = commit("Initial commit", PUSHER, "octo@example.com")
    commit(
        "Bump lodash from 4.17.20 to 4.17.21",
        "dependabot[bot]",
        "49699333+dependabot[bot]@users.noreply.github.com",
    )
    head = commit(
        "fix: adapt to lodash 4.17.21\n\n"
        "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>",
        PUSHER,
        "octo@example.com",
    )
    return repo, base, head


def armed_dependabot_pr(tmp, pat_wired=True, **faults):
    """A Dependabot PR that dependabot-auto-merge armed while it was bot-only
    (with the PAT when the caller wires one), the moment a Claude session's
    fix lands on it."""
    stub = Stub(tmp)
    stub.checkout, base, head = dependabot_history(tmp)
    commits = [
        {
            "author": {"login": "dependabot[bot]"},
            "committer": {"login": "web-flow"},
            "commit": {"verification": {"verified": True}},
        },
        {
            "author": {"login": PUSHER},
            "committer": {"login": PUSHER},
            "commit": {"verification": {"verified": False}},
        },
    ]
    (stub.dir / "commits.json").write_text(json.dumps(commits))
    (stub.dir / "head_sha").write_text(head + "\n")
    (stub.dir / "arm").write_text("ON\n")
    stub.record("auto_squash_enabled", "pat-user" if pat_wired else "github-actions[bot]")
    for name, on in faults.items():
        assert name in FAULTS, name
        if on:
            (stub.dir / name).touch()
    return stub, PR(base_sha=base, head_sha=head, pat_wired=pat_wired)


def context(pr):
    secrets = {"GITHUB_TOKEN": GITHUB_TOKEN}
    if pr.pat_wired:
        secrets["automerge_pat"] = PAT
    return {
        "github": {
            "actor": PUSHER,
            "token": GITHUB_TOKEN,
            "repository": REPO,
            "event": {
                "pull_request": {
                    "number": PR_NUMBER,
                    "html_url": f"https://github.com/{REPO}/pull/{PR_NUMBER}",
                    "user": {"login": "dependabot[bot]"},
                    "head": {"sha": pr.head_sha, "ref": BRANCH},
                    "base": {"sha": pr.base_sha, "ref": "main"},
                },
            },
        },
        "inputs": dict(DB_INPUTS),
        "secrets": secrets,
        "needs": {},
        "steps": {},
    }


def run_step(stub, step, ctx, cwd=None, env=None):
    """One step's SHIPPED run block under `bash -e`, with its SHIPPED env."""
    stub.runs += 1
    step_dir = stub.tmp / f"step{stub.runs}"
    step_dir.mkdir()
    script = step_dir / "run.sh"
    script.write_text(step["run"])
    output = step_dir / "github_output"
    output.write_text("")
    proc = subprocess.run(
        ["bash", "-e", str(script)],
        env={
            "PATH": f"{stub.bin}{os.pathsep}{os.environ['PATH']}",
            "HOME": os.environ.get("HOME", str(step_dir)),
            "TMPDIR": str(step_dir),
            "GITHUB_OUTPUT": str(output),
            "GITHUB_STEP_SUMMARY": str(step_dir / "summary.md"),
            "GITHUB_REPOSITORY": REPO,
            "STUB_DIR": str(stub.dir),
            **step_env(step, ctx),
            **(env or {}),
        },
        cwd=cwd or step_dir,
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        timeout=120,
    )
    return Step(proc.returncode, parse_outputs(output.read_text()), proc.stdout + proc.stderr)


@dataclass
class Run:
    non_bot: str
    arm_job_runs: bool
    revoke: object  # the revoke step's Step, or None when its job was skipped

    def __str__(self):
        log = self.revoke.log if self.revoke else "(revoke job skipped)"
        return f"non_bot={self.non_bot} arm_job_runs={self.arm_job_runs}\n{log}"


def run_dependabot_auto_merge(stub, pr, revoke=REVOKE):
    """dependabot-auto-merge.yml's jobs for one event, in their `needs` order."""
    ctx = context(pr)
    assert step_runs(DB_JOBS["authorship"], ctx, False)
    [scan_step] = DB_JOBS["authorship"]["steps"]
    scan = run_step(stub, scan_step, ctx)
    assert scan.rc == 0, scan.log
    outputs = step_env(
        {"env": DB_JOBS["authorship"]["outputs"]},
        {"steps": {scan_step["id"]: {"outputs": scan.outputs}}},
    )
    ctx["needs"] = {"authorship": {"result": "success", "outputs": outputs}}
    arm_job_runs = step_runs(DB_JOBS["auto-merge"], ctx, False)
    result = None
    if step_runs(DB_JOBS["revoke-stale-arm"], ctx, False):
        result = run_step(stub, revoke, ctx)
    return Run(outputs["non_bot"], arm_job_runs, result)


def claude_author_detect(stub, pr):
    """claude-author-automerge's SHIPPED detection step, in the PR's checkout."""
    ctx = {**context(pr), "inputs": CA_INPUTS}
    detect = CA_STEPS["detect"]
    # toJson() is outside the evaluator; Actions renders the PR's empty
    # label list as "[]".
    step = {**detect, "env": {k: v for k, v in detect["env"].items() if k != "LABELS_JSON"}}
    result = run_step(stub, step, ctx, cwd=stub.checkout, env={"LABELS_JSON": "[]"})
    assert result.rc == 0, result.log
    return result.outputs


def claude_author_hold(stub):
    """claude-author-automerge's SHIPPED "Check manual hold" step, run against
    this PR the way that workflow's next run would. Its enable step needs
    hold != '1', and a disable by anyone but github-actions[bot] as the newest
    auto-merge event reads as a human's durable hold."""
    ctx = {
        "github": {
            "token": GITHUB_TOKEN,
            "repository": REPO,
            "event": {"pull_request": {"number": PR_NUMBER}},
        },
        "inputs": CA_INPUTS,
    }
    result = run_step(stub, CA_STEPS["hold"], ctx)
    assert result.rc == 0, f"claude-author's hold step failed:\n{result.log}"
    return result.outputs


# ---------------------------------------------------------------------------
# 1. The revoke is recorded as github-actions[bot], so it is not a hold.
# ---------------------------------------------------------------------------
def test_the_revoke_is_not_read_as_a_human_hold(tmp_path):
    stub, pr = armed_dependabot_pr(tmp_path)
    run = run_dependabot_auto_merge(stub, pr)
    assert run.non_bot == "1" and not run.arm_job_runs and run.revoke, str(run)
    assert run.revoke.rc == 0 and stub.arm() == "OFF" and stub.comments() == 1, str(run)
    # The premise: claude-author-automerge judges this Dependabot PR.
    assert claude_author_detect(stub, pr) == {"claude_authored": "1", "reason": "trailer"}

    hold = claude_author_hold(stub)
    assert hold == {"hold": "0", "reason": ""}, (
        f"revoke-stale-arm's disarm, run as {stub.disarmed_by()}, read as a "
        f"human's hold ({hold}): claude-author-automerge never arms the PR "
        f"again:\n{run}"
    )
    assert stub.disarmed_by() == [GITHUB_TOKEN], str(run)

    # Control: the same hold step does hold on a human's disable.
    stub.record("auto_squash_enabled", "pat-user")
    stub.record("auto_merge_disabled", PUSHER)
    assert claude_author_hold(stub) == {
        "hold": "1",
        "reason": "timeline:human-disable-newest",
    }


# ---------------------------------------------------------------------------
# 2. The PAT is the fallback only, after three attempts as the bot.
# ---------------------------------------------------------------------------
def test_the_revoke_falls_back_to_the_pat_when_the_bot_cannot_disarm(tmp_path):
    stub, pr = armed_dependabot_pr(tmp_path, bot_cannot_disarm=True)
    run = run_dependabot_auto_merge(stub, pr)
    assert run.revoke.rc == 0 and stub.arm() == "OFF" and stub.comments() == 1, str(run)
    assert stub.disarmed_by() == [GITHUB_TOKEN] * 3 + [PAT], (
        f"expected three attempts as github-actions[bot], then the PAT:\n{run}"
    )


def test_without_a_pat_a_bot_that_cannot_disarm_fails_the_step(tmp_path):
    stub, pr = armed_dependabot_pr(tmp_path, pat_wired=False, bot_cannot_disarm=True)
    run = run_dependabot_auto_merge(stub, pr)
    assert run.revoke.rc != 0 and stub.arm() == "ON" and stub.comments() == 0, str(run)
    assert stub.disarmed_by() == [GITHUB_TOKEN] * 3, str(run)


# ---------------------------------------------------------------------------
# 3. Only a verified OFF counts.
# ---------------------------------------------------------------------------
@pytest.mark.parametrize("fault", ["disarm_does_not_stick", "later_view_reads_fail"])
def test_an_unverified_disarm_fails_the_step(tmp_path, fault):
    stub, pr = armed_dependabot_pr(tmp_path, **{fault: True})
    run = run_dependabot_auto_merge(stub, pr)
    assert run.revoke.rc != 0 and "::error::" in run.revoke.log, (
        f"a disarm that could not be verified passed as a revoke:\n{run}"
    )
    assert stub.comments() == 0, f"the explanation claimed an unverified revoke:\n{run}"
    assert stub.disarmed_by() == [GITHUB_TOKEN] * 3 + [PAT] * 3, str(run)


# ---------------------------------------------------------------------------
# 4. The ownership guard runs before every attempt, the PAT's included.
# ---------------------------------------------------------------------------
def test_a_head_pushed_mid_revoke_keeps_its_own_arm(tmp_path):
    stub, pr = armed_dependabot_pr(tmp_path, bot_cannot_disarm=True, move_head_on_disarm=True)
    run = run_dependabot_auto_merge(stub, pr)
    assert stub.arm() == "ON" and PAT not in stub.disarmed_by(), (
        f"the revoke disarmed the arm the newer head's own run placed:\n{run}"
    )
    assert run.revoke.rc == 0 and "head moved" in run.revoke.log, str(run)


# ---------------------------------------------------------------------------
# 5. Negative control: a revoke recorded as the PAT user does hold the PR.
# ---------------------------------------------------------------------------
def test_negative_control_a_bot_token_wired_to_the_pat_holds_the_pr(tmp_path):
    stub, pr = armed_dependabot_pr(tmp_path)
    revoke = copy.deepcopy(REVOKE)
    revoke["env"]["BOT_TOKEN"] = "${{ secrets.automerge_pat }}"
    run = run_dependabot_auto_merge(stub, pr, revoke)
    assert stub.arm() == "OFF" and set(stub.disarmed_by()) == {PAT}, str(run)
    assert claude_author_hold(stub) == {
        "hold": "1",
        "reason": "timeline:human-disable-newest",
    }
