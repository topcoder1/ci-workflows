"""lint.yml's draft-gate job keeps its checker out of the caller's workspace.

The job fetches selftest/check_draft_gate_triggers.py from ci-workflows into a
fresh directory under RUNNER_TEMP and runs it against the caller's
.github/workflows; only ci-workflows' own self-test uses the checker in its
checkout. The checker fails closed when that directory is missing, a symlink
or not a directory.

Layers:
1. The job, run step by step: a `run:` step executes its shipped bash with a
   stub `gh` that serves the checker file; an `actions/checkout` step with a
   `path:` is replayed the way actions/checkout treats an existing directory
   without a .git (it empties the directory, following a symlink, then clones
   into it). A normal caller gets the checker's usual verdicts, with nothing
   left in the workspace. A workspace entry at any path the checker might be
   written to changes nothing. An empty fetch fails the job. The self-test
   branch runs the checkout's own checker and fetches nothing.
2. The checker: a missing workflows directory, a symlink to one, and a file in
   its place each exit 1.
"""

import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest
import yaml

from selftest.check_draft_gate_triggers import main as checker_main

ROOT = Path(__file__).resolve().parents[1]
LINT = ROOT / ".github" / "workflows" / "lint.yml"
CHECKER = ROOT / "selftest" / "check_draft_gate_triggers.py"
JOB = "draft-gate-triggers"
EXPRESSION = re.compile(r"\$\{\{\s*(.*?)\s*\}\}")

CLEAN = """\
on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]
jobs:
  review:
    uses: topcoder1/ci-workflows/.github/workflows/claude-review.yml@main
"""
# Gated through the claude-review reusable, without ready_for_review.
VIOLATING = """\
on:
  pull_request:
    types: [opened, synchronize, reopened]
jobs:
  review:
    uses: topcoder1/ci-workflows/.github/workflows/claude-review.yml@main
"""
OK_LINE = "OK: every draft-gated workflow listens for `ready_for_review`\n"
VIOLATION_LINE = "::error file=.github/workflows/pr-review.yml::pr-review.yml: "


def evaluate(expression, context):
    """The expressions this job uses, and nothing else."""
    match = re.fullmatch(r"github\.repository\s*(==|!=)\s*'([^']*)'", expression)
    if match:
        equal = context["github.repository"] == match.group(2)
        return str(equal if match.group(1) == "==" else not equal).lower()
    if expression == "github.token":
        return "fixture-token"
    raise AssertionError(f"the harness cannot evaluate ${{{{ {expression} }}}}")


def substitute(text, context):
    return EXPRESSION.sub(lambda m: evaluate(m.group(1), context), str(text))


def replay_checkout(workspace, step):
    """What actions/checkout does to a `path:` that exists without a .git: it
    empties the directory (after following a symlink) and clones into it."""
    target = workspace / step["with"]["path"]
    if target.exists() and not (target / ".git").exists():
        for entry in target.iterdir():
            if entry.is_dir() and not entry.is_symlink():
                shutil.rmtree(entry)
            else:
                entry.unlink()
    target.mkdir(parents=True, exist_ok=True)
    (target / ".git").mkdir(exist_ok=True)
    (target / "selftest").mkdir(exist_ok=True)
    shutil.copy(CHECKER, target / "selftest" / CHECKER.name)


def run_job(workspace, tmp_path, repository="acme/app", served=None, text=None):
    """Run the job's steps in order in `workspace`; return the last run step's
    result and the argument lists the stub gh was called with."""
    document = yaml.safe_load(text if text is not None else LINT.read_text())
    context = {"github.repository": repository}
    stub = tmp_path / "bin" / "gh"
    stub.parent.mkdir(exist_ok=True)
    calls = tmp_path / "gh-calls"
    body = tmp_path / "gh-body"
    body.write_bytes(served if served is not None else CHECKER.read_bytes())
    # One argument per line, then an end marker, so each call's argv is exact.
    stub.write_text(
        "#!/bin/sh\n"
        f'for argument; do printf \'%s\\n\' "$argument"; done >> "{calls}"\n'
        f"echo '--end-of-call--' >> \"{calls}\"\n"
        f'base64 < "{body}"\n'
    )
    stub.chmod(0o755)
    runner_temp = tmp_path / "runner-temp"
    runner_temp.mkdir(exist_ok=True)
    result = None
    for step in document["jobs"][JOB]["steps"]:
        condition = step.get("if")
        if condition is not None and substitute(condition, context) != "true":
            continue
        uses = step.get("uses", "")
        if uses.startswith("actions/checkout@"):
            if (step.get("with") or {}).get("path"):
                replay_checkout(workspace, step)
            continue  # the workspace is the caller's checkout
        if step.get("name") == "Install PyYAML":
            continue  # pyyaml is already importable here
        environment = {
            **os.environ,
            **{k: substitute(v, context) for k, v in (step.get("env") or {}).items()},
            "PATH": f"{stub.parent}{os.pathsep}{os.environ['PATH']}",
            "RUNNER_TEMP": str(runner_temp),
        }
        result = subprocess.run(
            ["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", step["run"]],
            cwd=workspace,
            env=environment,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            break
    assert result is not None, "no run step executed"
    recorded = calls.read_text().split("--end-of-call--\n") if calls.exists() else []
    return result, [call.splitlines() for call in recorded if call]


def workspace_with(tmp_path, workflows):
    workspace = tmp_path / "workspace"
    (workspace / ".github" / "workflows").mkdir(parents=True)
    for name, text in workflows.items():
        (workspace / ".github" / "workflows" / name).write_text(text)
    return workspace


def listing(workspace):
    return sorted(
        (str(p.relative_to(workspace)), p.is_symlink()) for p in workspace.rglob("*")
    )


# --- 1. The job -------------------------------------------------------------


def test_a_clean_caller_passes_and_the_workspace_is_left_alone(tmp_path):
    workspace = workspace_with(tmp_path, {"pr-review.yml": CLEAN})
    before = listing(workspace)
    result, calls = run_job(workspace, tmp_path)
    assert result.returncode == 0, result.stdout + result.stderr
    assert result.stdout == OK_LINE
    assert listing(workspace) == before
    # One fetch: a GET pinned to main, the source the reusable documents.
    assert calls == [
        [
            "api",
            "repos/topcoder1/ci-workflows/contents/selftest/"
            "check_draft_gate_triggers.py?ref=main",
            "--jq",
            ".content",
        ]
    ]
    (call,) = calls
    assert call[1].endswith("?ref=main")
    # gh api sends a POST once any field or input is given, or if told to.
    post_flags = {"-f", "-F", "--field", "--raw-field", "--input", "-X", "--method"}
    assert not post_flags & set(call)


def test_a_violating_caller_fails(tmp_path):
    workspace = workspace_with(tmp_path, {"pr-review.yml": VIOLATING})
    result, _ = run_job(workspace, tmp_path)
    assert result.returncode == 1, result.stdout + result.stderr
    assert result.stdout.startswith(VIOLATION_LINE)


@pytest.mark.parametrize("entry", [".ci-workflows-checker", "draft-gate"])
def test_a_workspace_entry_where_a_checker_could_land_changes_nothing(entry, tmp_path):
    workspace = workspace_with(tmp_path, {"pr-review.yml": VIOLATING})
    (workspace / entry).symlink_to(".github")
    result, _ = run_job(workspace, tmp_path)
    assert result.returncode == 1, result.stdout + result.stderr
    assert result.stdout.startswith(VIOLATION_LINE)
    assert (workspace / ".github" / "workflows" / "pr-review.yml").read_text() == (
        VIOLATING
    )


def test_a_checkout_into_the_workspace_would_empty_the_workflows(tmp_path):
    # Negative control for the replay above: the job as it was, with the
    # checker checked out into the workspace. The replay empties .github
    # through the symlink, and the checker then fails closed rather than
    # reporting nothing to check.
    text = LINT.read_text()
    old_step = (
        "      - name: Check out the checker\n"
        "        if: ${{ github.repository != 'topcoder1/ci-workflows' }}\n"
        "        uses: actions/checkout@v7\n"
        "        with:\n"
        "          repository: topcoder1/ci-workflows\n"
        "          ref: main\n"
        "          path: .ci-workflows-checker\n"
        "          persist-credentials: false\n\n"
    )
    anchor = "      - name: Install PyYAML\n"
    assert text.count(anchor) == 1
    old = text.replace(anchor, old_step + anchor)
    old = old.replace(
        'checker="$dir/check_draft_gate_triggers.py"',
        'checker=".ci-workflows-checker/selftest/check_draft_gate_triggers.py"',
    )
    workspace = workspace_with(tmp_path, {"pr-review.yml": VIOLATING})
    (workspace / ".ci-workflows-checker").symlink_to(".github")
    result, _ = run_job(workspace, tmp_path, text=old)
    assert not (workspace / ".github" / "workflows").exists()
    assert result.returncode == 1, result.stdout + result.stderr
    assert "is missing" in result.stdout


def test_an_empty_fetch_fails_the_job(tmp_path):
    workspace = workspace_with(tmp_path, {"pr-review.yml": CLEAN})
    result, _ = run_job(workspace, tmp_path, served=b"")
    assert result.returncode == 1
    assert "fetched an empty draft-gate checker" in result.stdout


def test_the_self_test_runs_the_checkouts_own_checker(tmp_path):
    workspace = workspace_with(tmp_path, {"pr-review.yml": VIOLATING})
    (workspace / "selftest").mkdir()
    shutil.copy(CHECKER, workspace / "selftest" / CHECKER.name)
    result, calls = run_job(workspace, tmp_path, repository="topcoder1/ci-workflows")
    assert result.returncode == 1, result.stdout + result.stderr
    assert result.stdout.startswith(VIOLATION_LINE)
    assert calls == []


# --- 2. The checker ---------------------------------------------------------


def test_a_real_workflows_directory_is_checked(tmp_path, capsys):
    workflows = tmp_path / "workflows"
    workflows.mkdir()
    (workflows / "pr-review.yml").write_text(CLEAN)
    assert checker_main([str(workflows)]) == 0
    assert capsys.readouterr().out == OK_LINE


BROKEN = {
    "missing": lambda path: None,
    "a symlink": lambda path: path.symlink_to(path.parent / "elsewhere"),
    "not a directory": lambda path: path.write_text("not a directory\n"),
}


@pytest.mark.parametrize("kind", sorted(BROKEN))
def test_a_workflows_path_that_is_not_a_real_directory_fails(kind, tmp_path, capsys):
    (tmp_path / "elsewhere").mkdir()
    (tmp_path / "elsewhere" / "pr-review.yml").write_text(CLEAN)
    workflows = tmp_path / "workflows"
    BROKEN[kind](workflows)
    assert checker_main([str(workflows)]) == 1
    assert f"is {kind}, so the draft-gate check" in capsys.readouterr().out
