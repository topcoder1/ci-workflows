"""The Claude review lanes allow only reviewed read-only commands.

A `Bash(<command>:*)` allow rule lets the model run <command> with any
arguments. Some commands reach past reading: rg, sed and awk can run another
program or write files (verifier-on-high-risk.yml's allowlist comment gives
the reasons), as can shells, interpreters and wrappers such as `env`. So every
Bash rule a lane allows must be one of the read-only command prefixes written
out in SAFE_BASH_COMMANDS below, not read from the workflows. A lane that
gains any other Bash rule, `Bash` or `Bash(*)` included, fails, and widening
the list is a reviewed change to this file.

Every `anthropics/claude-code-action` step in .github/workflows is checked,
not just the lanes known today. Its rules are read the way the CLI takes them:
`--allowedTools` / `--allowed-tools` in `claude_args`, as `--flag value ...`
(every value up to the next option) or `--flag=value`, each value split on
commas and spaces outside parentheses, plus the `allowed_tools` input.
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
# The read-only command prefixes the lanes may allow, and nothing else.
SAFE_BASH_COMMANDS = {
    "gh pr comment",
    "gh pr diff",
    "gh pr view",
    "git diff",
    "git log",
    "git ls-files",
    "git show",
    "grep",
    "cat",
    "head",
    "tail",
    "wc",
    "ls",
    "find",
    "file",
}
ALLOW_FLAGS = ("--allowedTools", "--allowed-tools")


def split_rules(value):
    """Split on commas and whitespace outside parentheses."""
    rules, current, depth = [], "", 0
    for char in value:
        if char == "(":
            depth += 1
        elif char == ")":
            depth = max(depth - 1, 0)
        if depth == 0 and (char == "," or char.isspace()):
            if current.strip():
                rules.append(current.strip())
            current = ""
        else:
            current += char
    if current.strip():
        rules.append(current.strip())
    return rules


def allowed_tools(step):
    """Every allow rule a claude-code-action step passes."""
    with_ = step.get("with") or {}
    values = []
    tokens = shlex.split(str(with_.get("claude_args") or ""))
    index = 0
    while index < len(tokens):
        token = tokens[index]
        index += 1
        if token in ALLOW_FLAGS:
            while index < len(tokens) and not tokens[index].startswith("-"):
                values.append(tokens[index])
                index += 1
        elif any(token.startswith(flag + "=") for flag in ALLOW_FLAGS):
            values.append(token.split("=", 1)[1])
    if with_.get("allowed_tools"):
        values.append(str(with_["allowed_tools"]))
    return [rule for value in values for rule in split_rules(value)]


def rejected_rules(rules):
    """Bash rules outside SAFE_BASH_COMMANDS, `Bash` itself included."""
    rejected = []
    for rule in rules:
        if rule == "Bash":
            rejected.append(rule)
            continue
        match = re.fullmatch(r"Bash\((.*)\)", rule, re.DOTALL)
        if not match:
            continue
        command = re.sub(r"(?::\*| \*)$", "", match.group(1).strip()).strip()
        if command not in SAFE_BASH_COMMANDS:
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
def test_every_lane_allows_only_reviewed_read_only_commands(name, step):
    assert rejected_rules(allowed_tools(step)) == []


def test_the_adversarial_lane_keeps_its_search_and_history():
    (step,) = [
        step for name, step in action_steps() if name == "claude-adversarial-review.yml"
    ]
    rules = allowed_tools(step)
    assert "Bash(grep:*)" in rules
    assert "Bash(git log:*)" in rules
    assert "Bash(rg:*)" not in rules


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
        "Bash(* grep:*)",
        "Bash(env grep:*)",
        "Bash(command grep:*)",
        "Bash(sh:*)",
        "Bash(bash:*)",
        "Bash(xargs:*)",
        "Bash(python3:*)",
        "Bash(git:*)",
        "Bash(gh:*)",
        "Bash(grep; ls:*)",
    ],
)
def test_the_check_rejects_rules_outside_the_reviewed_list(rule):
    assert rejected_rules(["Bash(grep:*)", rule, "Read"]) == [rule]


def test_the_check_accepts_the_reviewed_list_in_either_wildcard_form():
    rules = [f"Bash({command}:*)" for command in sorted(SAFE_BASH_COMMANDS)]
    rules += ["Bash(grep *)", "Bash(git log)", "Read", "mcp__github__x"]
    assert rejected_rules(rules) == []


@pytest.mark.parametrize(
    "claude_args",
    [
        '--allowedTools "Bash(grep:*),Bash(rg:*)"',
        "--allowedTools 'Bash(grep:*),Bash(rg:*)'",
        "--allowed-tools Bash(rg:*)",
        '--allowedTools="Bash(rg:*)"',
        '--model x\n--allowedTools "Read"\n--allowedTools "Bash(rg:*)"',
        "--allowedTools Bash(grep:*) Bash(rg:*)",
        '--allowedTools "Bash(grep:*) Bash(rg:*)"',
        '--allowedTools "Bash(git log:*)" "Bash(rg:*)" --max-turns 3',
    ],
)
def test_the_allowlist_is_read_however_it_is_written(claude_args):
    step = {"with": {"claude_args": claude_args}}
    assert rejected_rules(allowed_tools(step)) == ["Bash(rg:*)"]


def test_rules_with_spaces_inside_parentheses_stay_whole():
    step = {
        "with": {
            "claude_args": '--allowedTools "Bash(git log:*) Read,Bash(gh pr view:*)"'
        }
    }
    assert allowed_tools(step) == ["Bash(git log:*)", "Read", "Bash(gh pr view:*)"]


def test_the_allowed_tools_input_is_read_too():
    step = {
        "with": {"claude_args": '--allowedTools "Read"', "allowed_tools": "Bash(rg:*)"}
    }
    assert rejected_rules(allowed_tools(step)) == ["Bash(rg:*)"]
