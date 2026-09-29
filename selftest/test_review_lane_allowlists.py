"""The Claude review lanes allow only read-only commands by prefix.

A `Bash(<command>:*)` allow rule lets the model run <command> with any
arguments. For rg, sed and awk that reaches past reading: each can run another
program or write files (verifier-on-high-risk.yml's allowlist comment gives
the reasons), so no lane allows them. The commands are written out here, not
read from the workflows, so a lane that gains one of them fails.
"""

import re
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
LANE_FILES = (
    "claude-adversarial-review.yml",
    "claude-review.yml",
    "verifier-on-high-risk.yml",
)
EXCLUDED_COMMANDS = ("rg", "sed", "awk")
EXCLUDED_RULE = re.compile(
    r"Bash\((?:%s)(?:[: ].*)?\)" % "|".join(map(re.escape, EXCLUDED_COMMANDS))
)


def allowed_tools(claude_args):
    found = re.findall(r'--allowedTools\s+"([^"]*)"', claude_args)
    assert len(found) == 1, claude_args
    return [tool.strip() for tool in found[0].split(",") if tool.strip()]


def excluded_rules(tools):
    return [tool for tool in tools if EXCLUDED_RULE.fullmatch(tool)]


def lane_allowlist(name):
    document = yaml.safe_load((WORKFLOWS / name).read_text())
    steps = [
        step
        for job in document["jobs"].values()
        for step in job.get("steps", [])
        if str(step.get("uses", "")).startswith("anthropics/claude-code-action@")
    ]
    assert len(steps) == 1, name
    return allowed_tools(steps[0]["with"]["claude_args"])


@pytest.mark.parametrize("name", LANE_FILES)
def test_no_lane_allows_a_command_that_reaches_past_reading(name):
    tools = lane_allowlist(name)
    assert tools, f"{name}: no --allowedTools list found"
    assert excluded_rules(tools) == []


def test_the_adversarial_lane_keeps_its_search_and_history():
    tools = lane_allowlist("claude-adversarial-review.yml")
    assert "Bash(grep:*)" in tools
    assert "Bash(git log:*)" in tools


@pytest.mark.parametrize(
    "rule", ["Bash(rg:*)", "Bash(rg)", "Bash(rg -n:*)", "Bash(sed:*)", "Bash(awk:*)"]
)
def test_the_check_rejects_each_excluded_command(rule):
    assert excluded_rules(["Bash(grep:*)", rule, "Read"]) == [rule]


def test_the_check_leaves_other_commands_alone():
    tools = ["Bash(grep:*)", "Bash(rgx:*)", "Bash(sedate:*)", "Bash(git log:*)", "Read"]
    assert excluded_rules(tools) == []
