"""Every Claude review lane runs a pinned Claude Code CLI.

claude-code-action runs the Claude Code CLI bundled with its release unless it
is handed another executable, so without a pin every action bump would also
move each lane's CLI. claude-review.yml pins its CLI; the adversarial and
verifier lanes do the same: CLAUDE_CODE_VERSION at the job level, the step
"Pre-install Claude Code binary" (id claude_install) installing exactly that
version and failing closed on any other, and the action step running its
verified executable through path_to_claude_code_executable.

Every anthropics/claude-code-action step in .github/workflows is checked, and
each lane's pin is written out here, not read from the workflows, so a bump is
a reviewed change to this file too and a new lane without a pin fails. The
lanes' install steps run one script, so a fix to it reaches every lane.
"""

import re
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
EXPECTED_PINS = {
    "claude-review.yml": "2.1.233",
    "claude-adversarial-review.yml": "2.1.276",
    "verifier-on-high-risk.yml": "2.1.276",
}
INSTALL_ID = "claude_install"
EXECUTABLE = "${{ steps.claude_install.outputs.executable }}"


def shipped_texts():
    return {path.name: path.read_text() for path in sorted(WORKFLOWS.glob("*.y*ml"))}


def action_lanes(texts):
    """(file name, job, index of its claude-code-action step) for every one."""
    found = []
    for name, text in sorted(texts.items()):
        document = yaml.safe_load(text) or {}
        for job in (document.get("jobs") or {}).values():
            for index, step in enumerate(job.get("steps") or []):
                if str(step.get("uses", "")).startswith(
                    "anthropics/claude-code-action@"
                ):
                    found.append((name, job, index))
    return found


def lane_problems(name, job, index):
    steps = job["steps"]
    action = steps[index]
    problems = []
    pin = (job.get("env") or {}).get("CLAUDE_CODE_VERSION")
    if name not in EXPECTED_PINS:
        problems.append(
            f"{name}: CLAUDE_CODE_VERSION is not expected for this lane; "
            "pin its CLI and add the lane to EXPECTED_PINS"
        )
    elif pin != EXPECTED_PINS[name]:
        problems.append(
            f"{name}: CLAUDE_CODE_VERSION is {pin!r}, not {EXPECTED_PINS.get(name)!r}"
        )
    installs = [i for i, step in enumerate(steps) if step.get("id") == INSTALL_ID]
    if len(installs) != 1:
        problems.append(f"{name}: {len(installs)} steps with id {INSTALL_ID}, not 1")
    else:
        install = steps[installs[0]]
        if installs[0] > index:
            problems.append(f"{name}: the install step runs after the action")
        if install.get("if") != action.get("if"):
            problems.append(
                f"{name}: the install step runs on {install.get('if')!r}, "
                f"the action on {action.get('if')!r}"
            )
    if (action.get("with") or {}).get("path_to_claude_code_executable") != EXECUTABLE:
        problems.append(f"{name}: the action does not run the installed executable")
    return problems


# The lanes whose install step this repo added bound it themselves; in the
# verifier the job's time must still cover the model step and the steps that
# report a failure after an install stall.
INSTALL_TIMEOUT_LANES = {"claude-adversarial-review.yml", "verifier-on-high-risk.yml"}
MAX_INSTALL_MINUTES = 5
# What the verifier's job keeps beyond the model and install timeouts: the
# rest of the setup (checkouts, classification, the prompt) and the steps that
# report a failure afterwards, the 5 + 3 minutes that
# selftest/test_verifier_failure_result.py reserves.
VERIFIER_RESERVE_MINUTES = 8


def install_timeout_problems(name, job, index):
    steps = job["steps"]
    installs = [step for step in steps if step.get("id") == INSTALL_ID]
    if name not in INSTALL_TIMEOUT_LANES or len(installs) != 1:
        return []
    minutes = installs[0].get("timeout-minutes")
    if not isinstance(minutes, int) or not 1 <= minutes <= MAX_INSTALL_MINUTES:
        return [f"{name}: the install step's timeout-minutes is {minutes!r}"]
    job_minutes = job.get("timeout-minutes")
    model_minutes = steps[index].get("timeout-minutes")
    if isinstance(job_minutes, int) and isinstance(model_minutes, int):
        if job_minutes - model_minutes - minutes < VERIFIER_RESERVE_MINUTES:
            return [f"{name}: install and model timeouts leave the job too little time"]
    return []


def all_problems(texts):
    lanes = action_lanes(texts)
    problems = []
    names = {name for name, _, _ in lanes}
    if not set(EXPECTED_PINS) <= names:
        problems.append(f"lanes not found: {sorted(set(EXPECTED_PINS) - names)}")
    for name, job, index in lanes:
        problems += lane_problems(name, job, index)
        problems += install_timeout_problems(name, job, index)
    scripts = {
        step["run"]
        for _, job, _ in lanes
        for step in job["steps"]
        if step.get("id") == INSTALL_ID and "run" in step
    }
    if len(scripts) > 1:
        problems.append(f"the lanes' install steps run {len(scripts)} scripts, not 1")
    return problems


def test_every_pin_is_an_exact_version():
    for pin in EXPECTED_PINS.values():
        assert re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", pin), pin


def test_every_lane_runs_its_pinned_cli():
    assert all_problems(shipped_texts()) == []


def swap(name, old, new):
    def edit(texts):
        assert texts[name].count(old) == 1, (name, old)
        return {**texts, name: texts[name].replace(old, new)}

    return edit


def add_workflow(texts):
    lane = """name: New lane
on: pull_request
jobs:
  look:
    runs-on: ubuntu-latest
    steps:
      - uses: anthropics/claude-code-action@a4f54ef2c58884867281bd8e2f8d63352ad019a9
        with:
          prompt: hi
"""
    return {**texts, "new-lane.yml": lane}


ADVERSARIAL = "claude-adversarial-review.yml"
VERIFIER = "verifier-on-high-risk.yml"
HANDOFF = (
    "          path_to_claude_code_executable: "
    "${{ steps.claude_install.outputs.executable }}\n"
)
MUTANTS = {
    "adversarial action runs its bundled CLI": (
        swap(ADVERSARIAL, HANDOFF, ""),
        "does not run the installed executable",
    ),
    "verifier pin moved": (
        swap(
            VERIFIER, 'CLAUDE_CODE_VERSION: "2.1.276"', 'CLAUDE_CODE_VERSION: "2.1.277"'
        ),
        "CLAUDE_CODE_VERSION is '2.1.277'",
    ),
    "verifier install step gone": (
        swap(
            VERIFIER, "        id: claude_install\n", "        id: claude_install_x\n"
        ),
        "0 steps with id claude_install",
    ),
    "adversarial install step on another condition": (
        swap(
            ADVERSARIAL,
            "        id: claude_install\n",
            "        id: claude_install\n        if: false\n",
        ),
        "the install step runs on False",
    ),
    "verifier refusal dropped": (
        swap(VERIFIER, "refusing to review on an unpinned binary", "installed anyway"),
        "run 2 scripts, not 1",
    ),
    "a new lane without a pin": (add_workflow, "new-lane.yml: CLAUDE_CODE_VERSION"),
    "verifier install unbounded": (
        swap(
            VERIFIER,
            "        timeout-minutes: 4\n        run: |\n",
            "        run: |\n",
        ),
        "the install step's timeout-minutes is None",
    ),
    "verifier job without the install's time": (
        swap(VERIFIER, "    timeout-minutes: 25\n", "    timeout-minutes: 20\n"),
        "leave the job too little time",
    ),
    "adversarial install bound too long": (
        swap(
            ADVERSARIAL,
            "        timeout-minutes: 4\n        run: |\n",
            "        timeout-minutes: 30\n        run: |\n",
        ),
        "the install step's timeout-minutes is 30",
    ),
}


@pytest.mark.parametrize("mutant", sorted(MUTANTS))
def test_a_mutated_lane_fails_the_check_for_what_it_broke(mutant):
    edit, expected = MUTANTS[mutant]
    problems = all_problems(edit(shipped_texts()))
    assert any(expected in problem for problem in problems), problems
