"""claude-review.yml skips the review only while the PR is still a draft.

THE GAP. GitHub judges a required check by the newest-created run of the
calling workflow on the head commit, whatever order the runs finish in, and a
`skipped` check satisfies the requirement, even over an older run's failure
(measured 2026-10-16 in a private scratch repo). The review job used to gate
on the event payload's draft flag alone. A push to a draft PR followed seconds
later by `gh pr ready` can leave a draft-payload `synchronize` run as the
head's newest run: created AFTER the `ready_for_review` run, or the ONLY run on
the head when the ready event carried the previous head (both seen in that
lab). That run published `review / Claude Review` = skipped, over a review
still running or failed, or with no review of the head at all.

THE FIX. A run whose payload says draft runs the `live_draft` job, which reads
the PR's draft flag at run time, and reads a `true` again 15 s later. The
review is skipped only when both reads say draft. Three layers pin it:

1. Wiring, EVALUATED: both jobs' `if:` conditions run through a small
   evaluator for the GitHub expression subset they use (&& and || return an
   operand, == and != compare strings case-insensitively and coerce
   mismatched types to numbers, an `if:` without a status function carries an
   implicit success(), which a skipped `needs` fails). They are checked
   against a HARDCODED truth table over payload, gate outcome and
   cancellation, never compared as text, and the shipped review `if:` must
   skip nothing the old gate reviewed over a wider grid of gate endings. The
   gate job's permissions must fit inside the fleet caller's grant: a reusable
   job that asks for more fails every run at startup, which publishes no check
   at all.
2. The shipped bash: the read step is extracted from the workflow and run
   under /bin/bash with the runner's flags (-eo pipefail) against a stubbed
   `gh` and `sleep`. Only an exit-0 reply that is exactly `true` or `false`
   counts. Anything else (an error body on stdout, which gh prints with exit
   1, null, a quoted or capitalized literal, two lines) is retried, then
   written as `unknown`, which reviews. A `true` is confirmed by a second
   read 15 s later, and the second read decides.
3. Negative controls: mutants of the workflow text and of the extracted
   script, each a plausible regression, must each fail layer 1 or 2. The
   evaluator and the stub have their own controls.
"""

import json
import math
import os
import pathlib
import re
import subprocess
import sys
from typing import NamedTuple

import pytest
import yaml

from selftest.check_draft_gate_triggers import DRAFT_GATE_EXPR

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "claude-review.yml"
CALLER = REPO_ROOT / ".github" / "workflows" / "pr-review.yml"

# What every fleet caller of claude-review.yml grants at workflow level: this
# repo's own pr-review.yml, and the installer template it is copied from.
# A reusable's job cannot hold more than this.
CALLER_GRANT = {"contents": "read", "pull-requests": "write", "id-token": "write"}
LEVEL = {"none": 0, "read": 1, "write": 2}

GATE_JOB = "live_draft"
GATE_NAME = "Live draft state"
REVIEW_JOB = "review"
REVIEW_NAME = "Claude Review"  # `review / Claude Review`, the required context
GATE_PERMISSIONS = {"pull-requests": "read"}
GATE_OUTPUTS = {"draft": "${{ steps.live.outputs.draft }}"}
GATE_ENV = {
    "GH_TOKEN": "${{ github.token }}",
    "REPO": "${{ github.repository }}",
    "PR": "${{ github.event.pull_request.number }}",
}
GH_READ = ["api", "repos/o/r/pulls/7", "--jq", ".draft"]


# ---------------------------------------------------------------------------
# A GitHub expression evaluator for the subset these `if:` conditions use:
# '...' literals, true/false/null, dotted context paths (unset = null),
# status functions, !, ==, !=, && and || and parentheses.
# ---------------------------------------------------------------------------
TOKEN = re.compile(
    r"\s*('(?:[^']|'')*'|==|!=|&&|\|\||!|\(|\)|[A-Za-z_][\w-]*(?:\.[\w-]+)*(?:\(\))?)"
)
STATUS_CALL = re.compile(r"\b(success|failure|cancelled|always)\(\)")


def _number(v):
    if v is None:
        return 0.0
    if isinstance(v, bool):
        return 1.0 if v else 0.0
    if isinstance(v, (int, float)):
        return float(v)
    s = v.strip()
    if not s:
        return 0.0
    try:
        return float(s)
    except ValueError:
        return math.nan


def truthy(v):
    if isinstance(v, bool):
        return v
    if v is None:
        return False
    if isinstance(v, (int, float)):
        return v != 0 and not math.isnan(v)
    return v != ""


def _equal(a, b):
    if isinstance(a, str) and isinstance(b, str):
        return a.lower() == b.lower()
    return _number(a) == _number(b)  # NaN equals nothing


class Expr:
    def __init__(self, text, ctx, status):
        text = text.strip()
        self.tokens, pos = [], 0
        while pos < len(text):
            m = TOKEN.match(text, pos)
            if not m:
                raise ValueError(f"cannot tokenize {text[pos:]!r}")
            self.tokens.append(m.group(1))
            pos = m.end()
        self.i, self.ctx, self.status = 0, ctx, status

    def _peek(self):
        return self.tokens[self.i] if self.i < len(self.tokens) else None

    def _take(self):
        token = self._peek()
        self.i += 1
        return token

    def value(self):
        v = self._or()
        if self._peek() is not None:
            raise ValueError(f"trailing tokens {self.tokens[self.i :]}")
        return v

    def _or(self):
        v = self._and()
        while self._peek() == "||":
            self._take()
            right = self._and()
            v = v if truthy(v) else right
        return v

    def _and(self):
        v = self._cmp()
        while self._peek() == "&&":
            self._take()
            right = self._cmp()
            v = right if truthy(v) else v
        return v

    def _cmp(self):
        v = self._unary()
        while self._peek() in ("==", "!="):
            op = self._take()
            right = self._unary()
            v = _equal(v, right) if op == "==" else not _equal(v, right)
        return v

    def _unary(self):
        if self._peek() == "!":
            self._take()
            return not truthy(self._unary())
        return self._primary()

    def _primary(self):
        token = self._take()
        if token is None:
            raise ValueError("unexpected end of expression")
        if token == "(":
            v = self._or()
            if self._take() != ")":
                raise ValueError("unbalanced parentheses")
            return v
        if token.startswith("'"):
            return token[1:-1].replace("''", "'")
        if token in ("true", "false"):
            return token == "true"
        if token == "null":
            return None
        if token.endswith("()"):
            return self.status[token[:-2]]
        return self.ctx.get(token)


def job_runs(job, ctx, needs_results, cancelled):
    """Whether a job starts, given its needs' results and the run's state.

    Job-level status functions: success() is true when no needed job ended in
    anything but success (a SKIPPED need fails it, which is why GitHub skips a
    job whose need was skipped unless its `if:` calls a status function),
    failure() when one failed, cancelled() when the run was cancelled. An
    `if:` that calls none of them is evaluated as `success() && (<if>)`.
    """
    status = {
        "success": not cancelled and all(r == "success" for r in needs_results),
        "failure": not cancelled and any(r == "failure" for r in needs_results),
        "cancelled": cancelled,
        "always": True,
    }
    cond = str(job.get("if", "")).strip()
    whole = re.fullmatch(r"\$\{\{(.*)\}\}", cond, re.S)
    if whole:
        cond = whole.group(1).strip()
    if not cond:
        cond = "success()"
    elif not STATUS_CALL.search(cond):
        cond = f"success() && ({cond})"
    return truthy(Expr(cond, ctx, status).value())


# Payload draft flags: a draft event, a ready event, and no pull_request
# payload at all (null), which reviews, as it always has.
PAYLOADS = (True, False, None)
# What the gate job can leave behind when it runs: (result, its `draft`
# output). It writes true/false/unknown and exits 0. A job that dies (failure)
# or times out (cancelled, measured) keeps whatever it wrote: nothing, or a
# `true` written just before it died.
GATE_ENDINGS = (
    ("success", "true"),
    ("success", "false"),
    ("success", "unknown"),
    ("failure", None),
    ("failure", ""),
    ("failure", "true"),
    ("cancelled", None),
    ("cancelled", ""),
    ("cancelled", "true"),
)


def expected_review(payload, gate_output, cancelled):
    """THE TRUTH TABLE, hardcoded. The review is skipped only on a draft
    payload whose gate wrote `true`, whatever became of the gate after it
    wrote, or on a cancelled run (a newer run superseded it and carries the
    verdict)."""
    if cancelled:
        return False
    return not (payload is True and gate_output == "true")


def scenarios():
    """Every (payload, gate result, gate output, cancelled) combination."""
    for cancelled in (False, True):
        for payload in PAYLOADS:
            yield payload, "skipped", None, cancelled
            yield payload, "skipped", "", cancelled
            for result, output in GATE_ENDINGS:
                yield payload, result, output, cancelled


def wiring_problems(doc):
    """Layer 1 against a parsed workflow; [] when every property holds."""
    problems = []
    jobs = doc.get("jobs") or {}
    gate, review = jobs.get(GATE_JOB), jobs.get(REVIEW_JOB)
    if not isinstance(gate, dict) or not isinstance(review, dict):
        return [
            f"claude-review.yml needs jobs {GATE_JOB!r} and {REVIEW_JOB!r}; has {sorted(jobs)}"
        ]

    # The required context and the gate's own check name.
    if review.get("name") != REVIEW_NAME:
        problems.append(
            f"the review job's name is {review.get('name')!r}: `review / {REVIEW_NAME}` is the "
            "context fleet rulesets require"
        )
    if gate.get("name") != GATE_NAME:
        problems.append(
            f"the gate job's name is {gate.get('name')!r}, want {GATE_NAME!r}"
        )
    names = [j.get("name") for j in jobs.values() if isinstance(j, dict)]
    if names.count(REVIEW_NAME) != 1:
        problems.append(
            f"exactly one job may publish `{REVIEW_NAME}`; names are {names}"
        )

    # Permissions: inside the caller's grant, and the gate holds read only.
    for job_id, job in jobs.items():
        for scope, level in (job.get("permissions") or {}).items():
            granted = CALLER_GRANT.get(scope, "none")
            if LEVEL.get(level, 99) > LEVEL[granted]:
                problems.append(
                    f"job {job_id!r} asks for `{scope}: {level}`, beyond the callers' "
                    f"`{scope}: {granted}`: every run would fail at startup and publish no check"
                )
    if gate.get("permissions") != GATE_PERMISSIONS:
        problems.append(
            f"the gate job's permissions are {gate.get('permissions')!r}, want {GATE_PERMISSIONS!r}"
        )
    if gate.get("outputs") != GATE_OUTPUTS:
        problems.append(
            f"the gate job's outputs are {gate.get('outputs')!r}, want {GATE_OUTPUTS!r}"
        )
    minutes = gate.get("timeout-minutes")
    if not isinstance(minutes, int) or not 0 < minutes <= 10:
        problems.append(
            f"the gate job's timeout-minutes is {minutes!r}; it must stay a short bound"
        )
    steps = gate.get("steps") or []
    if [s.get("id") for s in steps] != ["live"]:
        problems.append(
            f"the gate job must run exactly one step, id `live`; has {[s.get('id') for s in steps]}"
        )
    elif steps[0].get("env") != GATE_ENV:
        problems.append(
            f"the read step's env is {steps[0].get('env')!r}, want {GATE_ENV!r}"
        )
    elif "${{" in str(steps[0].get("run", "")):
        problems.append(
            "the read step's script holds an expression the runner would substitute into it"
        )
    if review.get("needs") not in (GATE_JOB, [GATE_JOB]):
        problems.append(
            f"the review job must need {GATE_JOB!r}; needs {review.get('needs')!r}"
        )
    # lint.yml's draft-gate check keys on this literal: its registry test
    # counts a reusable as draft-gated only if a job `if:` holds it. Lose it
    # and that test reports claude-review.yml as no longer gated; drop it
    # from the registry to make the test pass, and callers that do not
    # listen for ready_for_review stop being flagged. A PR opened as a draft
    # then never gets a review.
    if DRAFT_GATE_EXPR not in str(review.get("if", "")):
        problems.append(
            f"the review job's `if:` no longer contains `{DRAFT_GATE_EXPR}`, which lint.yml's "
            "draft-gate registry keys on (see selftest/check_draft_gate_triggers.py)"
        )

    # The truth table, evaluated.
    try:
        for payload in PAYLOADS:
            for cancelled in (False, True):
                ctx = {"github.event.pull_request.draft": payload}
                got = job_runs(gate, ctx, [], cancelled)
                want = payload is True and not cancelled
                if got != want:
                    problems.append(
                        f"gate job runs={got} for payload draft={payload!r} cancelled={cancelled}, want {want}"
                    )
        for payload, result, output, cancelled in scenarios():
            ctx = {
                "github.event.pull_request.draft": payload,
                f"needs.{GATE_JOB}.outputs.draft": output,
            }
            got = job_runs(review, ctx, [result], cancelled)
            want = expected_review(payload, output, cancelled)
            if got != want:
                problems.append(
                    f"review runs={got} for payload draft={payload!r}, gate {result} "
                    f"output={output!r}, cancelled={cancelled}; want {want}"
                )
        problems += subset_problems(review)
    except (ValueError, KeyError) as exc:
        problems.append(f"an `if:` the evaluator cannot read: {exc}")
    return problems


def subset_problems(review):
    """The fix may only ADD reviews. The old gate skipped every draft payload
    and nothing else, so on the shipped review `if:`, a run that was not
    cancelled may skip only on a draft payload. Checked over a grid wider than
    the table: every gate result, and outputs the gate never writes."""
    problems = []
    for payload in PAYLOADS:
        for result in ("success", "failure", "cancelled", "skipped"):
            for output in (None, "", "true", "TRUE", "false", "unknown", "draft"):
                ctx = {
                    "github.event.pull_request.draft": payload,
                    f"needs.{GATE_JOB}.outputs.draft": output,
                }
                if payload is not True and not job_runs(review, ctx, [result], False):
                    problems.append(
                        f"review skipped on payload draft={payload!r}, gate {result} "
                        f"output={output!r}: the old gate reviewed that run"
                    )
    return problems


def load(text=None):
    return yaml.safe_load(text if text is not None else WORKFLOW.read_text())


# --- layer 1 ---------------------------------------------------------------


def test_evaluator_controls():
    """The semantics the truth table leans on, checked on the evaluator."""
    ok = {"success": True, "failure": False, "cancelled": False, "always": True}
    for text, want in (
        ("'a' && '' || 'c'", "c"),  # a falsy middle falls through to the ||
        ("'' != 'true'", True),
        ("null != 'true'", True),  # null vs a string: 0 vs NaN, never equal
        ("'TRUE' != 'true'", False),  # strings compare case-insensitively
        ("null == false", True),  # both coerce to 0
        ("true == false", False),
        ("!cancelled() && ('x' == 'x')", True),
    ):
        assert Expr(text, {}, ok).value() == want, text
    # A skipped need fails the implicit success(); a status call lifts it.
    assert job_runs({"if": "true"}, {}, ["skipped"], False) is False
    assert job_runs({"if": "${{ !cancelled() }}"}, {}, ["skipped"], False) is True
    assert job_runs({"if": "${{ !cancelled() }}"}, {}, ["success"], True) is False


def test_caller_grant_matches_this_repos_caller():
    """CALLER_GRANT is hardcoded; the canonical caller must still grant it."""
    caller = yaml.safe_load(CALLER.read_text())
    assert caller.get("permissions") == CALLER_GRANT


def test_wiring_and_truth_table():
    problems = wiring_problems(load())
    assert problems == [], "\n".join(problems)


def test_no_skip_outside_the_old_skip_set():
    """subset_problems on the SHIPPED review `if:`, plus a control: an `if:`
    that skips a ready payload must be caught, or the check is vacuous."""
    review = load()["jobs"][REVIEW_JOB]
    assert subset_problems(review) == []
    mutant = {
        **review,
        "if": "${{ !cancelled() && needs.live_draft.outputs.draft == 'false' }}",
    }
    assert subset_problems(mutant)


# --- layer 2: the shipped bash ---------------------------------------------


def read_script(doc=None):
    steps = (doc or load())["jobs"][GATE_JOB]["steps"]
    return next(s for s in steps if s.get("id") == "live")["run"]


GH_STUB = r"""#!__PYTHON__ -S
import json, os, sys
log = os.environ["STUB_LOG"]
with open(log, "a") as fh:
    fh.write(json.dumps(sys.argv[1:]) + "\n")
argv = sys.argv[1:]
if len(argv) != 4 or argv[0] != "api" or argv[2:] != ["--jq", ".draft"]:
    sys.stderr.write("STUB: unexpected gh call %r\n" % (argv,))
    sys.exit(99)
with open(os.environ["STUB_ANSWERS"]) as fh:
    answers = json.load(fh)
with open(log) as fh:
    n = sum(1 for _ in fh)
answer = answers[min(n, len(answers)) - 1]
sys.stdout.write(answer["out"])
sys.stderr.write(answer.get("err", ""))
sys.exit(answer["rc"])
"""

SLEEP_STUB = """#!/bin/sh
echo "$*" >> "$STUB_LOG.sleep"
"""


def reply(out, rc=0):
    """One gh answer: its stdout (a newline appended unless empty) and exit."""
    return {"rc": rc, "out": out + "\n" if out else ""}


OK_TRUE, OK_FALSE = reply("true"), reply("false")
# How gh reports an HTTP error under --jq: the JSON body on STDOUT, exit 1.
ERROR = {
    "rc": 1,
    "out": '{"message":"Server Error","status":"502"}\n',
    "err": "gh: Server Error (HTTP 502)\n",
}


def run_read(tmp_path, answers, pr="7", script=None):
    """Run the read step; return (rc, outputs dict, gh argv list, sleeps, stdout)."""
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir(exist_ok=True)
    gh = bin_dir / "gh"
    gh.write_text(GH_STUB.replace("__PYTHON__", sys.executable))
    gh.chmod(0o755)
    sleep = bin_dir / "sleep"
    sleep.write_text(SLEEP_STUB)
    sleep.chmod(0o755)
    log = tmp_path / "gh.log"
    for path in (log, tmp_path / "gh.log.sleep"):
        path.write_text("")
    answers_file = tmp_path / "answers.json"
    answers_file.write_text(json.dumps(answers))
    out = tmp_path / "github_output"
    out.write_text("")
    script_file = tmp_path / "read.sh"
    script_file.write_text(script if script is not None else read_script())
    env = {
        "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
        "HOME": str(tmp_path),
        "GH_TOKEN": "stub",
        "REPO": "o/r",
        "PR": pr,
        "GITHUB_OUTPUT": str(out),
        "STUB_LOG": str(log),
        "STUB_ANSWERS": str(answers_file),
    }
    # The runner's default shell: bash --noprofile --norc -eo pipefail {0}.
    proc = subprocess.run(
        ["/bin/bash", "--noprofile", "--norc", "-eo", "pipefail", str(script_file)],
        env=env,
        capture_output=True,
        text=True,
        timeout=60,
    )
    lines = [line for line in out.read_text().splitlines() if line]
    outputs = {}
    for line in lines:
        key, _, value = line.partition("=")
        outputs.setdefault(key, []).append(value)
    calls = [json.loads(line) for line in log.read_text().splitlines() if line]
    sleeps = (tmp_path / "gh.log.sleep").read_text().split()
    return proc.returncode, outputs, calls, sleeps, proc.stdout + proc.stderr


class Read(NamedTuple):
    """One read case. The stub serves `answers` in order, then repeats the
    last one. The rest is what the step must end with: its output, how many
    gh calls, the backoff sleeps, and a line its log must carry."""

    answers: list
    draft: str
    calls: int
    sleeps: list
    marker: str
    pr: str = "7"


def gave_up(answers, pr="7"):
    """A read that never got a usable reply: three calls, then `unknown`."""
    return Read(answers, "unknown", 3, ["5", "10"], "::warning::", pr)


# Hardcoded: the expectations are the contract.
READS = {
    # A `true` is read again 15 s later; the stub repeats its last answer.
    "draft": Read([OK_TRUE], "true", 2, ["15"], "is still a draft"),
    "ready": Read([OK_FALSE], "false", 1, [], "::notice::"),
    # Readied between the two reads, or the second read failed: it decides.
    "draft-then-ready": Read([OK_TRUE, OK_FALSE], "false", 2, ["15"], "::notice::"),
    "draft-then-error": Read(
        [OK_TRUE, ERROR], "unknown", 4, ["15", "5", "10"], "::warning::"
    ),
    "error-thrice": gave_up([ERROR]),
    "error-then-draft": Read(
        [ERROR, OK_TRUE], "true", 3, ["5", "15"], "is still a draft"
    ),
    "errors-then-ready": Read(
        [ERROR, ERROR, OK_FALSE], "false", 3, ["5", "10"], "::notice::"
    ),
    "null": gave_up([reply("null")]),
    "empty": gave_up([reply("")]),
    # GitHub compares strings case-insensitively: written through, `True`
    # would read as 'true' in the review's `if:` and skip it.
    "capitalized": gave_up([reply("True")]),
    "quoted": gave_up([reply('"true"')]),
    "two-lines": gave_up([reply("true\nfalse")]),
    # A failed call's stdout is never the flag, whatever it says.
    "true-on-failure": gave_up([reply("true", rc=1)]),
    "no-pr": Read([OK_TRUE], "unknown", 0, [], "::warning::", pr=""),
    "pr-not-a-number": Read([OK_TRUE], "unknown", 0, [], "::warning::", pr="7abc"),
}


def read_problems(tmp_path, script=None):
    """Layer 2 over every READS case; [] when every expectation holds."""
    problems = []
    for case, (answers, draft, n_calls, sleeps, marker, pr) in READS.items():
        workdir = tmp_path / case
        workdir.mkdir()
        rc, outputs, calls, slept, log = run_read(
            workdir, answers, pr=pr, script=script
        )
        if rc != 0:
            problems.append(
                f"{case}: exit {rc}; the decision is the output, the step never fails:\n{log}"
            )
        if outputs != {"draft": [draft]}:
            problems.append(
                f"{case}: GITHUB_OUTPUT holds {outputs!r}, want exactly draft={draft}"
            )
        if len(calls) != n_calls or any(c != GH_READ for c in calls):
            problems.append(f"{case}: gh calls {calls!r}, want {n_calls} x {GH_READ!r}")
        if slept != sleeps:
            problems.append(f"{case}: sleeps {slept!r}, want {sleeps!r}")
        if marker not in log:
            problems.append(f"{case}: the log lacks {marker!r}:\n{log}")
    return problems


def test_read_step_shipped_bash(tmp_path):
    problems = read_problems(tmp_path)
    assert problems == [], "\n".join(problems)


def test_read_step_parses_under_bin_bash():
    proc = subprocess.run(
        ["/bin/bash", "-n"], input=read_script(), capture_output=True, text=True
    )
    assert proc.returncode == 0, proc.stderr


def test_stub_control(tmp_path):
    """Positive control: the harness sees what the stub serves. A stub that
    answered nothing would make every case read `unknown` vacuously."""
    rc, outputs, calls, _, _ = run_read(tmp_path, [OK_FALSE])
    assert (rc, outputs, calls) == (0, {"draft": ["false"]}, [GH_READ])


# --- layer 3: negative controls --------------------------------------------

REVIEW_IF = (
    "if: ${{ !cancelled() && (github.event.pull_request.draft == false"
    " || needs.live_draft.outputs.draft != 'true') }}"
)
WORKFLOW_MUTANTS = {
    # The pre-fix gate: payload only, the bug this file exists for.
    "payload-only gate": (REVIEW_IF, "if: github.event.pull_request.draft == false"),
    # Implicit success(): a ready payload skips the gate, and the review
    # with it, on every ready PR.
    "no status function": (
        REVIEW_IF,
        "if: ${{ github.event.pull_request.draft == false"
        " || needs.live_draft.outputs.draft != 'true' }}",
    ),
    # A gate that died writes nothing; `== 'false'` would skip the review.
    "fail-open on a dead gate": (
        "needs.live_draft.outputs.draft != 'true'",
        "needs.live_draft.outputs.draft == 'false'",
    ),
    # always() reviews on cancelled runs: superseded runs would all review.
    "always()": ("${{ !cancelled() && (", "${{ always() && ("),
    # An inverted gate: drafts read nothing and every draft push reviews.
    "inverted gate": (
        "    if: github.event.pull_request.draft == true\n",
        "    if: github.event.pull_request.draft == false\n",
    ),
    # Beyond the caller's grant: startup failure, no check at all.
    "gate asks for actions": (
        "    permissions:\n      pull-requests: read\n",
        "    permissions:\n      pull-requests: read\n      actions: read\n",
    ),
    "gate output unwired": (
        "draft: ${{ steps.live.outputs.draft }}",
        "draft: ${{ steps.live.outputs.decision }}",
    ),
    "review job renamed": ("    name: Claude Review\n", "    name: Claude review\n"),
    "gate named like the review": (
        "    name: Live draft state\n",
        "    name: Claude Review\n",
    ),
    "review needs nothing": ("    needs: live_draft\n", ""),
}


@pytest.mark.parametrize("mutant", sorted(WORKFLOW_MUTANTS))
def test_workflow_mutant_is_caught(mutant):
    old, new = WORKFLOW_MUTANTS[mutant]
    text = WORKFLOW.read_text()
    assert text.count(old) == 1, (
        f"anchor for {mutant!r} not found exactly once: {old!r}"
    )
    problems = wiring_problems(load(text.replace(old, new, 1)))
    assert problems, f"mutant {mutant!r} passed the wiring checks"


SCRIPT_MUTANTS = {
    # A read that never got a usable reply reads as draft: every failed
    # read skips the review.
    "failed read is draft": ("  echo unknown\n", "  echo true\n"),
    # Without a PR number the step reads nothing; that reads as draft.
    "no pr is draft": ("draft=unknown\n", "draft=true\n"),
    # One `true` decides: a stale first read skips the review.
    "no confirmation read": ("    sleep 15\n    draft=$(read_draft)\n", "    :\n"),
    # The exit status ignored: a failed call's stdout taken as the flag.
    "exit status ignored": (
        "if reply=$(gh api \"repos/${REPO}/pulls/${PR}\" --jq '.draft'); then",
        "reply=$(gh api \"repos/${REPO}/pulls/${PR}\" --jq '.draft') || true\n              if true; then",
    ),
    # Any reply written through.
    "shape check gone": ("true|false)\n", "*)\n"),
    "no retry": ("for attempt in 1 2 3; do", "for attempt in 1; do"),
    "pr not validated": ("if [[ ${PR:-} =~ ^[0-9]+$ ]]; then", "if true; then"),
}


@pytest.mark.parametrize("mutant", sorted(SCRIPT_MUTANTS))
def test_script_mutant_is_caught(mutant, tmp_path):
    old, new = SCRIPT_MUTANTS[mutant]
    script = read_script()
    assert script.count(old) == 1, (
        f"anchor for {mutant!r} not found exactly once: {old!r}"
    )
    problems = read_problems(tmp_path, script=script.replace(old, new, 1))
    assert problems, f"mutant {mutant!r} passed every read case"
