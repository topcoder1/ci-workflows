"""The Claude review lanes allow only read-only commands by prefix.

A `Bash(<command>:*)` allow rule lets the model run <command> with any
arguments. For rg, sed and awk that reaches past reading: each can run another
program or write files (verifier-on-high-risk.yml's allowlist comment gives
the reasons), so no lane allows them. Nor may a lane allow Bash broadly
(`Bash`, `Bash(*)`, a rule whose command is a wildcard), which would allow
them too. The commands are written out here, not read from the workflows, so
a lane that gains one of them fails.

Every `anthropics/claude-code-action` step in .github/workflows is checked,
not just the lanes known today, and its allowlist is read the way the action
reads it: `--allowedTools` / `--allowed-tools` in `claude_args` (shell-split,
`--flag value` or `--flag=value`, comma-separated), plus the `allowed_tools`
input.
"""

import re
import shlex
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
KNOWN_LANES = {
    "claude-adversarial-review.yml",
    "claude-review.yml",
    "verifier-on-high-risk.yml",
}
EXCLUDED_COMMANDS = {"rg", "sed", "awk"}
ALLOW_FLAGS = ("--allowedTools", "--allowed-tools")
COMMAND = re.compile(r"[A-Za-z0-9_.+-]+")


def allowed_tools(step):
    """Every allow rule a claude-code-action step passes."""
    with_ = step.get("with") or {}
    values = []
    tokens = shlex.split(str(with_.get("claude_args") or ""))
    for index, token in enumerate(tokens):
        for flag in ALLOW_FLAGS:
            if token == flag and index + 1 < len(tokens):
                values.append(tokens[index + 1])
            elif token.startswith(flag + "="):
                values.append(token[len(flag) + 1 :])
    if with_.get("allowed_tools"):
        values.append(str(with_["allowed_tools"]))
    return [
        rule.strip() for value in values for rule in value.split(",") if rule.strip()
    ]


def rejected_rules(rules):
    """Bash rules that allow an excluded command, or Bash broadly."""
    rejected = []
    for rule in rules:
        if rule == "Bash":
            rejected.append(rule)
            continue
        match = re.fullmatch(r"Bash\((.*)\)", rule, re.DOTALL)
        if not match:
            continue
        command = re.split(r"[:\s]", match.group(1).strip(), maxsplit=1)[0]
        if not COMMAND.fullmatch(command) or command in EXCLUDED_COMMANDS:
            rejected.append(rule)
    return rejected


def action_steps():
    """(workflow file name, step) for every claude-code-action step."""
    found = []
    for path in sorted(WORKFLOWS.glob("*.y*ml")):
        document = yaml.safe_load(path.read_text()) or {}
        for job in (document.get("jobs") or {}).values():
            for step in job.get("steps") or []:
                if str(step.get("uses", "")).startswith(
                    "anthropics/claude-code-action@"
                ):
                    found.append((path.name, step))
    return found


def test_every_known_lane_is_discovered_with_an_allowlist():
    steps = action_steps()
    assert KNOWN_LANES <= {name for name, _ in steps}
    for name, step in steps:
        if name in KNOWN_LANES:
            assert allowed_tools(step), f"{name}: no allow rules found"


@pytest.mark.parametrize(
    "name, step",
    action_steps(),
    ids=lambda value: value if isinstance(value, str) else "",
)
def test_no_lane_allows_a_command_that_reaches_past_reading(name, step):
    assert rejected_rules(allowed_tools(step)) == []


def test_the_adversarial_lane_keeps_its_search_and_history():
    (step,) = [
        step for name, step in action_steps() if name == "claude-adversarial-review.yml"
    ]
    rules = allowed_tools(step)
    assert "Bash(grep:*)" in rules
    assert "Bash(git log:*)" in rules


@pytest.mark.parametrize(
    "rule",
    [
        "Bash(rg:*)",
        "Bash(rg)",
        "Bash(rg -n:*)",
        "Bash(rg *)",
        "Bash(sed:*)",
        "Bash(awk:*)",
        "Bash",
        "Bash(*)",
        "Bash(:*)",
        "Bash(* rg:*)",
        "Bash(r?:*)",
    ],
)
def test_the_check_rejects_excluded_and_broad_rules(rule):
    assert rejected_rules(["Bash(grep:*)", rule, "Read"]) == [rule]


def test_the_check_leaves_other_rules_alone():
    rules = [
        "Bash(grep:*)",
        "Bash(rgx:*)",
        "Bash(sedate:*)",
        "Bash(git log:*)",
        "Read",
        "mcp__github_inline_comment__create_inline_comment",
    ]
    assert rejected_rules(rules) == []


@pytest.mark.parametrize(
    "claude_args",
    [
        '--allowedTools "Bash(grep:*),Bash(rg:*)"',
        "--allowedTools 'Bash(grep:*),Bash(rg:*)'",
        "--allowed-tools Bash(rg:*)",
        '--allowedTools="Bash(rg:*)"',
        '--model x\n--allowedTools "Read"\n--allowedTools "Bash(rg:*)"',
    ],
)
def test_the_allowlist_is_read_however_it_is_written(claude_args):
    step = {"with": {"claude_args": claude_args}}
    assert rejected_rules(allowed_tools(step)) == ["Bash(rg:*)"]


def test_the_allowed_tools_input_is_read_too():
    step = {
        "with": {"claude_args": '--allowedTools "Read"', "allowed_tools": "Bash(rg:*)"}
    }
    assert rejected_rules(allowed_tools(step)) == ["Bash(rg:*)"]
