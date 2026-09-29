"""The verifier's required check is posted as a failure when its job cannot
finish, not left waiting.

verifier-on-high-risk.yml posts the check-run `verifier / evidence-bound`, which
callers make a required check, from two steps that run on GitHub's implicit
success(): "Post check-run — skipped" and "Post check-run — verifier result".
A step that fails before them (the SHA check, checkout, the submodule step,
evidence materialization, the transcript check, redaction, upload), or a post
that itself fails, creates no check-run. Branch protection then sits at
"Expected — Waiting for status to be reported" instead of showing a failure.
The job's last step, "Post check-run — verifier did not finish", posts the
check as a failure in those runs.

1. Structure: the step exists once, is the last step of the job and runs on
   exactly `failure()`. Not `always()` or `cancelled()`: a run that a newer run
   of the same PR cancels must not post a failure that lands after the newer
   run's result on the same head SHA. Every step that posts a check-run posts
   the name hardcoded here (not read from the workflow) and takes its token,
   head SHA and repository from the same expressions. The step's script says
   `conclusion=failure` and never `success`, and nothing a PR controls reaches
   it: no `${{ }}` in the script, and in its env only values GitHub sets.
2. Behavior: the shipped script, run under bash with a stub `gh` that records
   each argument on its own line and with only the step's own env (the failure
   can come from the job's first step, before any step has set state), makes
   one POST to repos/<repo>/check-runs for the PR head SHA, completed and
   failed.
3. Negative controls: each mutant of a copy of the workflow text (the condition
   `always()`, `cancelled()` or absent; the conclusion `success`; the step not
   last or twice; the check name, head SHA or token changed; a PR-controlled
   value reaching the step; a script that posts twice or needs the scratch
   directory) is rejected by the check for what it broke.
"""

import os
import re
import subprocess
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "verifier-on-high-risk.yml"
SHIPPED = WORKFLOW.read_text()
JOB = "verify"

# Hardcoded, not read from the workflow: renaming the check in every step at
# once would leave a required check that no post satisfies.
CHECK_NAME = "verifier / evidence-bound"
STEP = "Post check-run — verifier did not finish"
POST_STEPS = ("Post check-run — skipped", "Post check-run — verifier result", STEP)
# What each post step takes from the event, verbatim.
POST_ENV = {
    "GH_TOKEN": "${{ github.token }}",
    "HEAD_SHA": "${{ github.event.pull_request.head.sha }}",
    "REPO": "${{ github.repository }}",
}
# The only ${{ }} expressions the step may hold: none is text a PR chooses.
ALLOWED_EXPRESSIONS = {
    "github.token",
    "github.event.pull_request.head.sha",
    "github.repository",
    "github.server_url",
    "github.run_id",
}
EXPRESSION = re.compile(r"\$\{\{\s*(.*?)\s*\}\}")

HEAD = "1" * 40  # the PR's head commit
MERGE = "2" * 40  # github.sha in a pull_request run: the merge commit
FIXTURE = {
    "github.token": "token-fixture",
    "github.event.pull_request.head.sha": HEAD,
    "github.sha": MERGE,
    "github.repository": "owner/repo",
    "github.server_url": "https://github.example",
    "github.run_id": "4242",
}
RUN_URL = "https://github.example/owner/repo/actions/runs/4242"
ENDPOINT = "repos/owner/repo/check-runs"

# Stands in for gh: each call's arguments, one per line, in a file of its own.
STUB = r"""#!/bin/sh
call=$(mktemp "$STUB_CALLS/call.XXXXXX") || exit 1
printf '%s\n' "$@" > "$call"
"""


def steps_of(text):
    return yaml.safe_load(text)["jobs"][JOB]["steps"]


def named(steps, name):
    return [step for step in steps if step.get("name") == name]


def single_step(text):
    found = named(steps_of(text), STEP)
    assert len(found) == 1, f"expected one step named {STEP!r}, found {len(found)}"
    return found[0]


def posted_names(script):
    """The check names a script hands `gh api` as `-f name=...`."""
    pattern = r"""-f\s+name=(?:"([^"]*)"|'([^']*)'|(\S+))"""
    return [
        next(group for group in match.groups() if group is not None)
        for match in re.finditer(pattern, script)
    ]


# --- 1. Structure --------------------------------------------------------------
# Each check returns what is wrong, one line per problem; empty when it is right.


def placement_problems(text):
    steps = steps_of(text)
    found = named(steps, STEP)
    if len(found) != 1:
        return [f"found {len(found)} steps named {STEP!r}, not one"]
    problems = []
    if steps[-1] is not found[0]:
        problems.append(f"{STEP!r} is not the last step of job {JOB!r}")
    if found[0].get("if") != "failure()":
        problems.append(f"its condition is {found[0].get('if')!r}, not 'failure()'")
    return problems


def post_step_problems(text):
    posting = [
        step for step in steps_of(text) if "/check-runs" in (step.get("run") or "")
    ]
    problems = []
    absent = set(POST_STEPS) - {step.get("name") for step in posting}
    if absent:
        problems.append(f"no step named {sorted(absent)} posts to /check-runs")
    for step in posting:
        posted = posted_names(step["run"])
        if posted != [CHECK_NAME]:
            problems.append(
                f"{step.get('name')!r} posts check name {posted}, not {CHECK_NAME!r}"
            )
        env = step.get("env") or {}
        for key, expected in POST_ENV.items():
            if env.get(key) != expected:
                problems.append(
                    f"{step.get('name')!r} sets {key} to {env.get(key)!r}, "
                    f"not {expected!r}"
                )
    return problems


def conclusion_problems(text):
    script = single_step(text)["run"]
    problems = []
    if "conclusion=failure" not in script:
        problems.append("its script does not post conclusion=failure")
    if "success" in script.lower():
        problems.append("its script mentions success")
    return problems


def input_problems(text):
    step = single_step(text)
    problems = []
    if "${{" in step["run"]:
        problems.append("its script holds a ${{ }} expression; env carries values")
    used = {
        match.group(1)
        for value in (step.get("env") or {}).values()
        for match in EXPRESSION.finditer(str(value))
    }
    if used - ALLOWED_EXPRESSIONS:
        problems.append(
            f"its env uses {sorted(used - ALLOWED_EXPRESSIONS)}; only "
            f"{sorted(ALLOWED_EXPRESSIONS)} may reach it"
        )
    return problems


def test_the_step_is_the_jobs_last_and_runs_on_exactly_failure():
    assert placement_problems(SHIPPED) == []


def test_every_post_step_posts_the_same_check_on_the_same_head_sha():
    assert post_step_problems(SHIPPED) == []


def test_the_step_can_only_post_a_failure():
    assert conclusion_problems(SHIPPED) == []


def test_nothing_a_pr_controls_reaches_the_step():
    assert input_problems(SHIPPED) == []


# --- 2. Behavior ---------------------------------------------------------------


def substitute(value):
    """`value` with each ${{ }} expression replaced by its fixture value."""

    def lookup(match):
        assert match.group(1) in FIXTURE, f"no fixture value for {match.group(0)}"
        return FIXTURE[match.group(1)]

    return EXPRESSION.sub(lookup, str(value))


def behavior_problems(text, tmp_path):
    """Run the step's script as the runner would, under a stub `gh` and with
    only the step's own env, and report what its call got wrong."""
    step = single_step(text)
    stub_dir, calls = tmp_path / "bin", tmp_path / "calls"
    stub_dir.mkdir()
    calls.mkdir()
    stub = stub_dir / "gh"
    stub.write_text(STUB)
    stub.chmod(0o755)
    environment = {k: substitute(v) for k, v in (step.get("env") or {}).items()}
    result = subprocess.run(
        ["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", step["run"]],
        cwd=tmp_path,
        env={
            **environment,
            "PATH": f"{stub_dir}{os.pathsep}{os.environ['PATH']}",
            "STUB_CALLS": str(calls),
        },
        capture_output=True,
        text=True,
    )
    problems = []
    if result.returncode != 0:
        problems.append(f"it exited {result.returncode}: {result.stderr.strip()}")
    recorded = [call.read_text().splitlines() for call in sorted(calls.iterdir())]
    if len(recorded) != 1:
        return problems + [f"expected one gh call, saw {len(recorded)}"]
    (arguments,) = recorded
    called = [*arguments[:3], "".join(arguments[3:4]).lstrip("/")]
    if called != ["api", "-X", "POST", ENDPOINT]:
        problems.append(f"it calls gh {called}, not a POST to {ENDPOINT}")
    if arguments[4::2] != ["-f"] * len(arguments[5::2]):
        problems.append(f"it passes fields other than as -f pairs: {arguments[4:]}")
    fields = {}
    for pair in arguments[5::2]:
        key, _, value = pair.partition("=")
        fields[key] = value
    expected = {
        "name": CHECK_NAME,
        "head_sha": HEAD,
        "status": "completed",
        "conclusion": "failure",
    }
    for key, value in expected.items():
        if fields.get(key) != value:
            problems.append(f"it posts {key}={fields.get(key)!r}, not {value!r}")
    if not fields.get("output[title]"):
        problems.append("it posts no output[title]")
    if RUN_URL not in fields.get("output[summary]", ""):
        problems.append(f"its output[summary] does not point at {RUN_URL}")
    return problems


def test_the_step_posts_the_failed_check_using_only_its_own_env(tmp_path):
    assert behavior_problems(SHIPPED, tmp_path) == []


# --- 3. Negative controls ------------------------------------------------------


def swap(old, new):
    """An edit that replaces `old` with `new`, and fails if `old` is not there."""

    def edit(text):
        assert old in text, f"mutation anchor {old!r} drifted"
        return text.replace(old, new)

    return edit


def in_step(edit):
    """`edit`, applied to the text of the failure-result step, the file's last."""

    def mutate(text):
        start = text.index(f"      - name: {STEP}\n")
        return text[:start] + edit(text[start:])

    return mutate


def add_a_step_after_it(text):
    return text + "\n      - name: A later step\n        run: echo later\n"


def move_before_the_result_step(text):
    cut = text.index(f"      - name: {STEP}\n")
    before, step = text[:cut], text[cut:]
    at = before.index("      - name: Post check-run — verifier result\n")
    return before[:at] + step + "\n" + before[at:]


def twice(text):
    return text + "\n" + text[text.index(f"      - name: {STEP}\n") :]


# Edits that both tables below use.
conclusion_success = in_step(swap("conclusion=failure", "conclusion=success"))
check_renamed_in_every_step = swap(CHECK_NAME, "verifier / evidence")
head_from_github_sha = in_step(swap("github.event.pull_request.head.sha", "github.sha"))

# id: (edit of the workflow text, the check that must reject it, and a part of
# the problem that check must report)
MUTANTS = {
    "condition always()": (
        in_step(swap("if: failure()", "if: always()")),
        placement_problems,
        "'always()'",
    ),
    "condition cancelled()": (
        in_step(swap("if: failure()", "if: cancelled()")),
        placement_problems,
        "'cancelled()'",
    ),
    "no condition": (
        in_step(swap("        if: failure()\n", "")),
        placement_problems,
        "None",
    ),
    "a step after it": (add_a_step_after_it, placement_problems, "not the last step"),
    "moved before the result step": (
        move_before_the_result_step,
        placement_problems,
        "not the last step",
    ),
    "the step twice": (twice, placement_problems, "found 2 steps"),
    "a post step renamed": (
        swap("- name: Post check-run — skipped", "- name: Post check-run — skipped 2"),
        post_step_problems,
        "no step named",
    ),
    "check name misspelled in the step": (
        in_step(swap(CHECK_NAME, "verifier / evidence-boundd")),
        post_step_problems,
        "posts check name",
    ),
    "check name changed in every post step": (
        check_renamed_in_every_step,
        post_step_problems,
        "posts check name",
    ),
    "head sha from github.sha": (
        head_from_github_sha,
        post_step_problems,
        "sets HEAD_SHA",
    ),
    "token from a secret": (
        in_step(swap("${{ github.token }}", "${{ secrets.ANTHROPIC_API_KEY }}")),
        post_step_problems,
        "sets GH_TOKEN",
    ),
    "conclusion success": (
        conclusion_success,
        conclusion_problems,
        "does not post conclusion=failure",
    ),
    "success in the title": (
        in_step(swap("Verifier did not finish", "Verifier success")),
        conclusion_problems,
        "mentions success",
    ),
    "PR title in the script": (
        in_step(swap("${RUN_URL}", "${{ github.event.pull_request.title }}")),
        input_problems,
        "script holds a ${{ }} expression",
    ),
    "PR title in the run URL": (
        in_step(swap("github.run_id", "github.event.pull_request.title")),
        input_problems,
        "['github.event.pull_request.title']",
    ),
}

# The same, for what only running the script shows.
BEHAVIOR_MUTANTS = {
    "conclusion success": (conclusion_success, "conclusion='success'"),
    "check name changed in every post step": (
        check_renamed_in_every_step,
        "name='verifier / evidence'",
    ),
    "head sha from github.sha": (head_from_github_sha, f"head_sha={MERGE!r}"),
    "needs the scratch directory": (
        in_step(
            swap(
                "set -euo pipefail\n",
                'set -euo pipefail\n          : "${VERIFIER_SCRATCH:?}"\n',
            )
        ),
        "VERIFIER_SCRATCH",
    ),
    "a second gh call": (
        in_step(
            swap(
                "gh api -X POST", "gh api -X GET /rate_limit\n          gh api -X POST"
            )
        ),
        "expected one gh call, saw 2",
    ),
}


@pytest.mark.parametrize("mutant", sorted(MUTANTS))
def test_a_mutated_workflow_fails_the_check_for_what_it_broke(mutant):
    edit, check, expected = MUTANTS[mutant]
    mutated = edit(SHIPPED)
    assert mutated != SHIPPED
    problems = check(mutated)
    assert any(expected in problem for problem in problems), problems


@pytest.mark.parametrize("mutant", sorted(BEHAVIOR_MUTANTS))
def test_a_mutated_script_fails_the_behavior_check(mutant, tmp_path):
    edit, expected = BEHAVIOR_MUTANTS[mutant]
    mutated = edit(SHIPPED)
    assert mutated != SHIPPED
    problems = behavior_problems(mutated, tmp_path)
    assert any(expected in problem for problem in problems), problems


# --- The model step times out before the job does ---------------------------

MODEL_STEP = "Run verifier (claude-code-action)"
# Minutes the job keeps after the model step's timeout for the steps that
# report its failure (evidence, redaction, upload, the result post).
REPORTING_HEADROOM = 3


def model_timeout_problems(text):
    document = yaml.safe_load(text)
    job = document["jobs"]["verify"]
    (model,) = named(job["steps"], MODEL_STEP)
    problems = []
    if model.get("continue-on-error") is not True:
        problems.append("the model step does not continue on error")
    step_minutes, job_minutes = model.get("timeout-minutes"), job.get("timeout-minutes")
    if not isinstance(step_minutes, int) or not isinstance(job_minutes, int):
        problems.append("the model step or the job has no timeout-minutes")
    elif job_minutes - step_minutes < REPORTING_HEADROOM:
        problems.append("the model step's timeout leaves the job too little time")
    return problems


def test_a_hung_model_fails_its_step_before_the_job_times_out():
    assert model_timeout_problems(WORKFLOW.read_text()) == []


@pytest.mark.parametrize(
    "edit",
    [
        lambda text: text.replace("        timeout-minutes: 10\n", "", 1),
        lambda text: text.replace(
            "        timeout-minutes: 10\n", "        timeout-minutes: 15\n", 1
        ),
        lambda text: text.replace(
            "    timeout-minutes: 15\n", "    timeout-minutes: 12\n", 1
        ),
        lambda text: text.replace(
            "        continue-on-error: true # keep the workflow running",
            "        continue-on-error: false # keep the workflow running",
            1,
        ),
    ],
    ids=[
        "no-step-timeout",
        "step-timeout-equals-job",
        "job-timeout-too-close",
        "no-continue-on-error",
    ],
)
def test_a_mutated_timeout_fails_the_check(edit):
    text = WORKFLOW.read_text()
    mutated = edit(text)
    assert mutated != text
    assert model_timeout_problems(mutated) != []
