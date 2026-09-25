"""The high-risk verifier must see both paths of a renamed file.

verifier-on-high-risk.yml's "Compute PR diff" step (id: diff) writes
changed-paths.txt, the list scripts/verifier-classify-diff.sh matches against
the high-risk globs; a list that matches none posts the check as skipped.
Porcelain `git diff` detects renames by default (diff.renames, true since git
2.9), and with rename detection `--name-only` prints a renamed file under its
new path only. `--no-renames` lists the old path too, as a deletion: the
coverage the automerge lanes get from the files API's previous_filename.

1. The shipped step, run in a fixture PR checkout where the PR moves a file
   out of a high-risk directory and edits it, lists the old and the new path,
   and the classifier, fed the central high-risk list by the shipped
   extract-high-risk-globs action, matches the old one.
2. Negative control: the same step without --no-renames (the pre-fix command)
   lists only the new path and the classifier matches nothing, so the fixture
   really exercises rename detection.
3. The verifier prompt, rendered by its shipped step: its per-file diff of the
   matched old path shows only a deletion, so the prompt must also give the
   model commands that list the PR's renames and show both paths together.
   Those commands, run in the fixture, must show the rename and the edit.
"""

import os
import re
import subprocess
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "verifier-on-high-risk.yml"
GLOBS_ACTION = ROOT / ".github" / "actions" / "extract-high-risk-globs"
CLASSIFIER = ROOT / "scripts" / "verifier-classify-diff.sh"

OLD = "src/auth/session.py"  # matches the central high-risk list
NEW = "src/misc/helpers.py"  # matches none of it
SOURCE = "".join(
    f"def check_{n}(token):\n    return token == {n}\n\n" for n in range(5)
)

# A ${{ }} expression.
EXPRESSION = re.compile(r"\$\{\{\s*(.*?)\s*\}\}")


def git_environment():
    environment = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    # No global or system config: diff.renames is git's own default, as on the
    # runner, which sets none.
    environment.update(
        GIT_CONFIG_GLOBAL=os.devnull,
        GIT_CONFIG_NOSYSTEM="1",
        GIT_AUTHOR_NAME="Fixture",
        GIT_AUTHOR_EMAIL="fixture@example.test",
        GIT_COMMITTER_NAME="Fixture",
        GIT_COMMITTER_EMAIL="fixture@example.test",
    )
    return environment


def git(repo, *arguments):
    result = subprocess.run(
        ["git", *arguments],
        cwd=repo,
        env=git_environment(),
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr
    return result.stdout.strip()


def bash(script, cwd, environment):
    """Run `script` as a workflow step; return what it wrote to $GITHUB_OUTPUT."""
    output = cwd.parent / f"{cwd.name}-github-output"
    result = subprocess.run(
        ["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", script],
        cwd=cwd,
        env={**environment, "GITHUB_OUTPUT": str(output)},
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr
    return output.read_text()


@pytest.fixture
def checkout(tmp_path):
    """A PR checkout as actions/checkout leaves it for a pull_request run (a
    detached merge commit, remote refs only), where the PR moves OLD to NEW
    and edits it."""
    repo = tmp_path / "checkout"
    (repo / OLD).parent.mkdir(parents=True)
    git(repo, "init", "-q", "-b", "main")
    (repo / OLD).write_text(SOURCE)
    git(repo, "add", ".")
    git(repo, "commit", "-qm", "base")
    base = git(repo, "rev-parse", "HEAD")
    git(repo, "switch", "-qc", "pr")
    (repo / NEW).parent.mkdir(parents=True)
    git(repo, "mv", OLD, NEW)
    (repo / NEW).write_text(SOURCE + "# moved\n")
    git(repo, "commit", "-qam", "move and edit")
    head = git(repo, "rev-parse", "HEAD")
    origin = tmp_path / "origin.git"
    git(repo, "init", "-q", "--bare", str(origin))
    git(repo, "push", "-q", str(origin), f"{base}:refs/heads/main")
    git(repo, "remote", "add", "origin", origin.as_uri())
    git(repo, "fetch", "-q", "origin")
    git(repo, "switch", "-q", "--detach", base)
    git(repo, "merge", "-q", "--no-ff", "-m", "Merge pr into main", head)
    git(repo, "branch", "-q", "-D", "main", "pr")
    event = {
        "github.event.pull_request.base.sha": base,
        "github.event.pull_request.head.sha": head,
        "github.event.pull_request.base.ref": "main",
    }
    return repo, event


@pytest.fixture
def patterns(tmp_path):
    """The high-risk regexes, extracted from the central list by the shipped
    extract-high-risk-globs action, as the job does before it classifies."""
    action = yaml.safe_load((GLOBS_ACTION / "action.yml").read_text())
    (step,) = action["runs"]["steps"]
    script = step["run"].replace("${{ github.action_path }}", str(GLOBS_ACTION))
    assert "${{" not in script, "an expression the fixture does not substitute"
    workdir = tmp_path / "globs"
    workdir.mkdir()
    output = bash(script, workdir, {**os.environ, "TMPDIR": str(workdir)})
    return dict(line.split("=", 1) for line in output.splitlines())["patterns_file"]


def find_step(step_id):
    document = yaml.safe_load(WORKFLOW.read_text())
    steps = [s for s in document["jobs"]["verify"]["steps"] if s.get("id") == step_id]
    assert len(steps) == 1, f"expected one step with id {step_id!r} in job 'verify'"
    return document, steps[0]


def diff_step():
    return find_step("diff")


def step_environment(document, step, event):
    """What the runner puts in the step's environment: workflow, then job,
    then step env, each ${{ }} expression looked up in the fixture event."""
    merged = {
        **(document.get("env") or {}),
        **(document["jobs"]["verify"].get("env") or {}),
        **(step.get("env") or {}),
    }

    def evaluate(match):
        assert match.group(1) in event, f"no fixture value for {match.group(0)}"
        return event[match.group(1)]

    return {k: EXPRESSION.sub(evaluate, str(v)) for k, v in merged.items()}


def run_step(checkout, script):
    """Run `script` as the diff step; return changed-paths.txt's lines and
    what the step wrote to $GITHUB_OUTPUT."""
    repo, event = checkout
    document, step = diff_step()
    assert "${{" not in script, "the runner would substitute into this script"
    environment = {**git_environment(), **step_environment(document, step, event)}
    output = bash(script, repo, environment)
    return (repo / "changed-paths.txt").read_text().splitlines(), output


def classify(repo, patterns):
    """The classifier's verdict on changed-paths.txt: exit 0 and the matched
    lines, or exit 1 when nothing matches and the job posts "Skipped"."""
    result = subprocess.run(
        [
            "bash",
            str(CLASSIFIER),
            "--patterns",
            patterns,
            "--paths",
            "changed-paths.txt",
        ],
        cwd=repo,
        capture_output=True,
        text=True,
    )
    assert result.returncode in (0, 1), result.stderr
    return result.returncode, result.stdout


def test_diff_step_lists_a_renamed_files_old_path(checkout, patterns):
    _, step = diff_step()
    listed, output = run_step(checkout, step["run"])
    assert sorted(listed) == [OLD, NEW], (
        f"the classifier would never see {OLD}: {listed}"
    )
    assert output == "changed_count=2\n"
    rc, matches = classify(checkout[0], patterns)
    matched = [line.split("\t")[0] for line in matches.splitlines()]
    assert rc == 0 and matched == [OLD], matches


def test_pre_fix_command_lists_only_the_new_path(checkout, patterns):
    # Negative control: the step without --no-renames, as it shipped before.
    # It misses the old path and nothing matches, so the fixture exercises
    # rename detection and the test above can fail.
    _, step = diff_step()
    pre_fix, count = re.subn(
        r"(?m)^(\s*git\b[^\n]*?) --no-renames\b", r"\1", step["run"]
    )
    assert count == 1, "expected one `git ... --no-renames` line in the step"
    listed, output = run_step(checkout, pre_fix)
    assert listed == [NEW]
    assert output == "changed_count=1\n"
    assert classify(checkout[0], patterns) == (1, "")


def model_git(repo, command):
    """Run a git command the verifier prompt hands the model, in the checkout."""
    result = subprocess.run(
        ["bash", "-c", command],
        cwd=repo,
        env=git_environment(),
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr
    return result.stdout


def test_verifier_prompt_leads_the_model_to_both_paths_of_a_rename(checkout, tmp_path):
    # The classifier matches only OLD, and the prompt's per-file diff of OLD
    # shows a deletion: the edited file at NEW never appears in it. The prompt
    # must hand the model commands that find the rename and show both paths.
    repo, event = checkout
    document, step = find_step("prompt")
    workdir = tmp_path / "prompt"
    workdir.mkdir()
    (workdir / "matches.txt").write_text(f"{OLD}\t(matched: fixture)\n")
    environment = {**os.environ, **step_environment(document, step, event)}
    prompt = bash(step["run"], workdir, environment)

    per_file = re.search(r"Read the diff for that file via Bash: `([^`]+)`", prompt)
    assert per_file, "no per-file diff command in the prompt"
    alone = model_git(repo, per_file.group(1).replace("<file>", OLD))
    assert "deleted file mode" in alone and "+# moved" not in alone, alone

    commands = re.findall(r"`(git diff --find-renames [^`]*)`", prompt)
    listing = [c for c in commands if "--name-status" in c]
    paired = [c for c in commands if "<old> <new>" in c]
    assert len(listing) == 1 and len(paired) == 1, commands
    pair = rf"^R\d+\t{re.escape(OLD)}\t{re.escape(NEW)}$"
    assert re.search(pair, model_git(repo, listing[0]), re.M), listing[0]
    shown = model_git(repo, paired[0].replace("<old>", OLD).replace("<new>", NEW))
    assert f"rename from {OLD}" in shown and f"rename to {NEW}" in shown, shown
    assert "+# moved" in shown, shown
