"""Every Claude review lane runs the CLI in permission mode `default`.

claude-code-action builds the CLI's arguments through the Agent SDK it bundles.
Up to SDK 0.3.276 (action v1.0.229) the SDK passed `--permission-mode default`
whenever the caller set no mode; from 0.3.286 (first in action v1.0.238;
v1.0.250 bundles 0.3.300) it passes nothing, and the CLI takes its mode from the settings it loads. The action
loads the user, project and local sources, and the project's
.claude/settings.json is the caller's, restored from the PR's base branch,
which is not always the default branch. A `permissions.defaultMode` there
(`bypassPermissions`, `acceptEdits`, `auto`, ...) would then pick the
reviewer's mode, and `bypassPermissions`, `acceptEdits` and `auto` each let
some tool outside the lane's --allowedTools run (`plan` and `dontAsk` are
stricter, but the lanes are written for `default`). So each lane passes `--permission-mode default` in
claude_args, the argument the SDK used to send. `auto` is no substitute: it
runs the tools its classifier approves, allowlisted or not.

The lanes and the flag are written out here, not read from the workflows, so
dropping or changing the flag fails, and so does a new lane that lacks it.
claude_args is read the way the action reads it: lines starting with `#` are
dropped, the rest is split into shell words.
"""

import shlex
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
GITHUB = ROOT / ".github"
# Every anthropics/claude-code-action step there is, per file.
EXPECTED_STEPS = {
    "workflows/claude-review.yml": 1,
    "workflows/claude-adversarial-review.yml": 1,
    "workflows/verifier-on-high-risk.yml": 1,
}
FLAG = "--permission-mode"
MODE = "default"
# Either one replaces the mode with bypassPermissions or offers it.
BYPASS_FLAGS = (
    "--dangerously-skip-permissions",
    "--allow-dangerously-skip-permissions",
)
LINE = "            --permission-mode default\n"


def shipped_texts():
    paths = sorted(GITHUB.glob("workflows/*.y*ml")) + sorted(
        GITHUB.glob("actions/*/action.y*ml")
    )
    return {str(path.relative_to(GITHUB)): path.read_text() for path in paths}


def action_steps(document):
    """Every step of a workflow's jobs, or of a composite action."""
    steps = []
    for job in (document.get("jobs") or {}).values():
        steps += job.get("steps") or []
    steps += (document.get("runs") or {}).get("steps") or []
    return [
        step
        for step in steps
        if str(step.get("uses", "")).startswith("anthropics/claude-code-action@")
    ]


def claude_words(claude_args):
    lines = [
        line for line in claude_args.splitlines() if not line.strip().startswith("#")
    ]
    return shlex.split("\n".join(lines))


def step_problems(name, step):
    claude_args = (step.get("with") or {}).get("claude_args")
    if not isinstance(claude_args, str):
        return [f"{name}: the claude-code-action step has no claude_args"]
    words = claude_words(claude_args)
    problems = []
    modes = [i for i, word in enumerate(words) if word.startswith(FLAG)]
    if len(modes) != 1:
        problems.append(
            f"{name}: claude_args carries {FLAG} {len(modes)} times, not once"
        )
    for i in modes:
        if words[i] != FLAG:
            problems.append(
                f"{name}: claude_args writes {words[i]!r}, not '{FLAG} {MODE}'"
            )
        elif i + 1 >= len(words) or words[i + 1] != MODE:
            value = words[i + 1] if i + 1 < len(words) else None
            problems.append(f"{name}: {FLAG} is {value!r}, not {MODE!r}")
    for word in words:
        if word in BYPASS_FLAGS:
            problems.append(f"{name}: claude_args carries {word}")
    return problems


def all_problems(texts):
    problems = []
    for name, text in sorted(texts.items()):
        steps = action_steps(yaml.safe_load(text) or {})
        if name not in EXPECTED_STEPS:
            if steps:
                problems.append(
                    f"{name}: not an expected lane; pass {FLAG} {MODE} in its "
                    "claude_args and add it to EXPECTED_STEPS"
                )
        elif len(steps) != EXPECTED_STEPS[name]:
            problems.append(
                f"{name}: {len(steps)} claude-code-action steps, not {EXPECTED_STEPS[name]}"
            )
        for step in steps:
            problems += step_problems(name, step)
    missing = sorted(set(EXPECTED_STEPS) - set(texts))
    if missing:
        problems.append(f"lanes not found: {missing}")
    return problems


def test_every_lane_runs_in_permission_mode_default():
    assert all_problems(shipped_texts()) == []


def swap(name, old, new):
    def edit(texts):
        assert texts[name].count(old) == 1, (name, old)
        return {**texts, name: texts[name].replace(old, new)}

    return edit


def add_lane(texts):
    lane = """name: New lane
on: pull_request
jobs:
  look:
    runs-on: ubuntu-latest
    steps:
      - uses: anthropics/claude-code-action@a26b07d8c778b0c43f64618e5fd29fd0f8af72e8
        with:
          prompt: hi
          claude_args: |
            --max-turns 5
"""
    return {**texts, "workflows/new-lane.yml": lane}


def add_composite(texts):
    action = """name: Wrapped review
runs:
  using: composite
  steps:
    - uses: anthropics/claude-code-action@a26b07d8c778b0c43f64618e5fd29fd0f8af72e8
      with:
        prompt: hi
        claude_args: |
          --permission-mode default
"""
    return {**texts, "actions/wrapped-review/action.yml": action}


def drop_lane(name):
    def edit(texts):
        return {key: value for key, value in texts.items() if key != name}

    return edit


REVIEW = "workflows/claude-review.yml"
ADVERSARIAL = "workflows/claude-adversarial-review.yml"
VERIFIER = "workflows/verifier-on-high-risk.yml"
MUTANTS = {
    "review lane without the flag": (
        swap(REVIEW, LINE, ""),
        f"{REVIEW}: claude_args carries --permission-mode 0 times",
    ),
    "adversarial lane in auto": (
        swap(ADVERSARIAL, LINE, LINE.replace(MODE, "auto")),
        f"{ADVERSARIAL}: --permission-mode is 'auto', not 'default'",
    ),
    "verifier lane in bypassPermissions": (
        swap(VERIFIER, LINE, LINE.replace(MODE, "bypassPermissions")),
        f"{VERIFIER}: --permission-mode is 'bypassPermissions'",
    ),
    "flag with no value": (
        swap(REVIEW, LINE, "            --permission-mode\n"),
        f"{REVIEW}: --permission-mode is",
    ),
    "flag in --flag=value form": (
        swap(VERIFIER, LINE, "            --permission-mode=default\n"),
        f"{VERIFIER}: claude_args writes '--permission-mode=default'",
    ),
    "flag misspelled": (
        swap(ADVERSARIAL, LINE, "            --permision-mode default\n"),
        f"{ADVERSARIAL}: claude_args carries --permission-mode 0 times",
    ),
    "flag commented out": (
        swap(REVIEW, LINE, "            # --permission-mode default\n"),
        f"{REVIEW}: claude_args carries --permission-mode 0 times",
    ),
    "flag given twice": (
        swap(VERIFIER, LINE, LINE + "            --permission-mode acceptEdits\n"),
        f"{VERIFIER}: claude_args carries --permission-mode 2 times",
    ),
    "bypass flag added": (
        swap(ADVERSARIAL, LINE, LINE + "            --dangerously-skip-permissions\n"),
        f"{ADVERSARIAL}: claude_args carries --dangerously-skip-permissions",
    ),
    "a new lane without the flag": (
        add_lane,
        "workflows/new-lane.yml: not an expected lane",
    ),
    "a composite action wrapping the action": (
        add_composite,
        "actions/wrapped-review/action.yml: not an expected lane",
    ),
    "an expected lane gone": (
        drop_lane(VERIFIER),
        f"lanes not found: ['{VERIFIER}']",
    ),
    "an expected lane's action step renamed away": (
        swap(
            REVIEW,
            "uses: anthropics/claude-code-action@",
            "uses: anthropics/claude-code-action-fork@",
        ),
        f"{REVIEW}: 0 claude-code-action steps, not 1",
    ),
}


@pytest.mark.parametrize("mutant", sorted(MUTANTS))
def test_a_mutated_lane_fails_the_check_for_what_it_broke(mutant):
    edit, expected = MUTANTS[mutant]
    problems = all_problems(edit(shipped_texts()))
    assert any(expected in problem for problem in problems), problems
