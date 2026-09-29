"""The Codex review runs with the base branch's Codex project config.

codex-review.yml runs Codex in the PR checkout, and Codex takes project-level
config and instructions from the directory it runs in. The step "Review with
the base branch's Codex project config" makes the working tree's copies of
the paths Codex reads the base commit's, and removes any the base does not
have, before Codex is installed, logged in or run.

PROJECT_PATHS is what codex-cli 0.158.0 read at startup when traced running
`review` in a checkout: AGENTS.md and AGENTS.override.md at the root, .codex/,
.agents/, and the plugin manifests under .codex-plugin/, .claude-plugin/ and
.cursor-plugin/. It is hardcoded here, not read from the workflow.

Layers:
1. Placement: the step runs whenever the review does, before Codex is
   installed, logged in or run, and covers exactly PROJECT_PATHS.
2. Behavior: in a fixture PR checkout (a detached merge commit with remote
   refs, as actions/checkout leaves refs/pull/N/merge) whose PR changes, adds
   and deletes files under those paths, the working tree ends with the base's
   versions and none of the PR's additions, while the index, the commits and
   the rest of the tree keep the PR's. A PR that swaps AGENTS.md for a symlink
   gets the base's regular file back.
3. Unaffected PRs: when the PR leaves those paths as the base has them, or
   the repo has none of them, the step changes nothing in the checkout.
4. Fail closed: a base commit missing from the checkout exits 1 with the
   working tree untouched.
5. End to end: the step, then the shipped review step with a stub codex that
   prints the project files Codex would load; it sees the base's. Without the
   step it sees the checkout's own files (negative control), and mutated
   steps (the index restored instead of the working tree, a path left off
   the list) fail.
6. CODEX_HOME: the login step makes it a directory under RUNNER_TEMP and hands
   it to later steps through GITHUB_ENV before logging in.
"""

import os
import re
import subprocess
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "codex-review.yml"
JOB = "codex-review"
STEP = "Review with the base branch's Codex project config"
INSTALL = "Install Codex CLI"
LOGIN = "Authenticate Codex with API key"
REVIEW = "Run Codex adversarial review"

PROJECT_PATHS = [
    "AGENTS.md",
    "AGENTS.override.md",
    ".codex",
    ".agents",
    ".codex-plugin",
    ".claude-plugin",
    ".cursor-plugin",
]

BASE_FILES = {
    "AGENTS.md": "base instructions\n",
    ".codex/config.toml": "# base config\n",
    ".codex/skills/base-skill/SKILL.md": "base skill\n",
    ".codex/rules/base.rules": "# base rules\n",
    "app.py": "x = 1\n",
}
# The PR changes, adds and deletes files under every project path, and
# changes files outside them.
PR_FILES = {
    "AGENTS.md": "PR-head instructions\n",
    ".codex/config.toml": "# PR-head config\n",
    ".codex/skills/base-skill/SKILL.md": None,
    ".codex/skills/pr-skill/SKILL.md": "PR-head skill\n",
    ".codex/hooks.json": "{}\n",
    ".codex/agents/pr.toml": "# PR-head agent\n",
    "AGENTS.override.md": "PR-head override\n",
    ".agents/skills/pr/SKILL.md": "PR-head skill\n",
    ".codex-plugin/plugin.json": "{}\n",
    ".claude-plugin/plugin.json": "{}\n",
    ".cursor-plugin/plugin.json": "{}\n",
    "app.py": "x = 2\n",
    "docs/guide.md": "PR-head docs\n",
}
# Every file in the working tree after the step.
AFTER_THE_STEP = {
    "AGENTS.md": "base instructions\n",
    ".codex/config.toml": "# base config\n",
    ".codex/skills/base-skill/SKILL.md": "base skill\n",
    ".codex/rules/base.rules": "# base rules\n",
    "app.py": "x = 2\n",
    "docs/guide.md": "PR-head docs\n",
}
BASE_MARKERS = ["base instructions", "# base config", "base skill"]
PR_MARKERS = [
    "PR-head instructions",
    "PR-head config",
    "PR-head override",
    "PR-head skill",
    "PR-head agent",
]

# A ${{ }} expression.
EXPRESSION = re.compile(r"\$\{\{\s*(.*?)\s*\}\}")


class Symlink(str):
    """A symbolic link to the given target."""


def git_environment():
    environment = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
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
    return result.stdout


def stage(repo, files):
    """Stage `files`, each path mapped to its text, a Symlink, or None to
    delete it."""
    for path, content in files.items():
        target = repo / path
        if content is None:
            git(repo, "rm", "-q", path)
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.is_symlink() or target.exists():
            target.unlink()
        if isinstance(content, Symlink):
            target.symlink_to(content)
        else:
            target.write_text(content)
        git(repo, "add", path)


class Checkout:
    """A PR checkout as actions/checkout leaves it for a pull_request run: a
    detached merge commit and remote refs. The PR branches from a commit
    holding `base_files` and changes them as `pr_files` says."""

    def __init__(self, root, base_files, pr_files):
        self.repo = root / "checkout"
        self.repo.mkdir()
        git(self.repo, "init", "-q", "-b", "main")
        stage(self.repo, base_files)
        git(self.repo, "commit", "-qm", "base")
        self.base = git(self.repo, "rev-parse", "HEAD").strip()
        git(self.repo, "switch", "-qc", "pr")
        stage(self.repo, pr_files)
        git(self.repo, "commit", "-qm", "pr")
        self.head = git(self.repo, "rev-parse", "HEAD").strip()
        origin = root / "origin.git"
        git(self.repo, "init", "-q", "--bare", str(origin))
        git(self.repo, "push", "-q", str(origin), f"{self.base}:refs/heads/main")
        git(self.repo, "remote", "add", "origin", origin.as_uri())
        git(self.repo, "fetch", "-q", "origin")
        git(self.repo, "switch", "-q", "--detach", self.base)
        git(self.repo, "merge", "-q", "--no-ff", "-m", "Merge pr into main", self.head)
        git(self.repo, "branch", "-q", "-D", "main", "pr")
        self.merge = git(self.repo, "rev-parse", "HEAD").strip()
        self.event = {
            "github.event.pull_request.base.sha": self.base,
            "github.event.pull_request.base.ref": "main",
            "github.event.pull_request.title": "Fixture PR",
        }

    def tree(self):
        """Every file and link in the working tree, outside .git."""
        entries = {}
        for path in sorted(self.repo.rglob("*")):
            relative = path.relative_to(self.repo).as_posix()
            if relative == ".git" or relative.startswith(".git/"):
                continue
            if path.is_symlink():
                entries[relative] = Symlink(os.readlink(path))
            elif path.is_file():
                entries[relative] = path.read_text()
        return entries

    def state(self):
        """What must not change: the index, HEAD, .git/config and status."""
        return (
            git(self.repo, "ls-files", "-s"),
            git(self.repo, "rev-parse", "HEAD"),
            (self.repo / ".git" / "config").read_bytes(),
            git(self.repo, "status", "--porcelain", "--ignored"),
        )


def load(text=None):
    return yaml.safe_load(text if text is not None else WORKFLOW.read_text())


def find_step(document, name):
    steps = [s for s in document["jobs"][JOB]["steps"] if s.get("name") == name]
    assert len(steps) == 1, f"expected one step named {name!r}"
    return steps[0]


def step_environment(document, step, event):
    """What the runner puts in the step's environment: workflow, then job,
    then step env, each ${{ }} expression looked up in the fixture event."""
    merged = {
        **(document.get("env") or {}),
        **(document["jobs"][JOB].get("env") or {}),
        **(step.get("env") or {}),
    }

    def evaluate(match):
        assert match.group(1) in event, f"no fixture value for {match.group(0)}"
        return event[match.group(1)]

    return {k: EXPRESSION.sub(evaluate, str(v)) for k, v in merged.items()}


def shipped_run(step):
    run = step["run"]
    assert "${{" not in run, "the runner would substitute into this script"
    return run


def run_step(checkout, script=None, event=None):
    document = load()
    step = find_step(document, STEP)
    return subprocess.run(
        [
            "bash",
            "--noprofile",
            "--norc",
            "-eo",
            "pipefail",
            "-c",
            shipped_run(step) if script is None else script,
        ],
        cwd=checkout.repo,
        env={
            **git_environment(),
            **step_environment(document, step, event or checkout.event),
        },
        capture_output=True,
        text=True,
    )


@pytest.fixture
def checkout(tmp_path):
    return Checkout(tmp_path, BASE_FILES, PR_FILES)


# --- 1. Placement ------------------------------------------------------------


def test_the_step_runs_before_codex_is_installed_logged_in_or_run():
    steps = load()["jobs"][JOB]["steps"]
    names = [step.get("name") for step in steps]
    assert names.count(STEP) == 1
    assert names.index(STEP) < names.index(INSTALL) < names.index(LOGIN)
    assert names.index(LOGIN) < names.index(REVIEW)
    step, review = steps[names.index(STEP)], steps[names.index(REVIEW)]
    assert (
        step.get("if") == review.get("if") == "steps.gate.outputs.should_run == 'true'"
    )
    assert step["env"] == {"BASE_SHA": "${{ github.event.pull_request.base.sha }}"}


def test_the_step_covers_the_paths_codex_reads():
    script = shipped_run(find_step(load(), STEP))
    listed = re.findall(r"^\s*paths=\((.*)\)\s*$", script, re.M)
    assert len(listed) == 1, "expected one paths=(...) list"
    assert listed[0].split() == PROJECT_PATHS


# --- 2. Behavior ----------------------------------------------------------------


def test_the_working_tree_gets_the_base_project_config(checkout):
    before = checkout.state()[:3]
    result = run_step(checkout)
    assert result.returncode == 0, result.stdout + result.stderr
    assert checkout.tree() == AFTER_THE_STEP
    # The index, HEAD and .git/config are the PR checkout's as before, and the
    # PR's versions stay readable through git.
    assert checkout.state()[:3] == before
    assert git(checkout.repo, "show", "HEAD:AGENTS.md") == PR_FILES["AGENTS.md"]
    assert result.stdout.endswith(
        "11 path(s) in the working tree put back as the base has them.\n"
    )


def test_a_symlink_the_pr_puts_in_place_of_agents_md_is_undone(tmp_path):
    checkout = Checkout(
        tmp_path,
        {"AGENTS.md": "base instructions\n"},
        {
            "AGENTS.md": Symlink("docs/notes.md"),
            "docs/notes.md": "PR-head instructions\n",
        },
    )
    result = run_step(checkout)
    assert result.returncode == 0, result.stdout + result.stderr
    assert checkout.tree() == {
        "AGENTS.md": "base instructions\n",
        "docs/notes.md": "PR-head instructions\n",
    }


# --- 3. Unaffected PRs -------------------------------------------------------------


UNAFFECTED = {
    "project config untouched": (BASE_FILES, {"app.py": "x = 2\n"}),
    "no project config": ({"app.py": "x = 1\n"}, {"app.py": "x = 2\n"}),
}


@pytest.mark.parametrize("repo", sorted(UNAFFECTED))
def test_a_pr_that_leaves_the_project_config_alone_changes_nothing(repo, tmp_path):
    checkout = Checkout(tmp_path, *UNAFFECTED[repo])
    tree, state = checkout.tree(), checkout.state()
    result = run_step(checkout)
    assert result.returncode == 0, result.stdout + result.stderr
    assert result.stdout == "The PR leaves Codex's project config as the base has it.\n"
    assert checkout.tree() == tree
    assert checkout.state() == state


# --- 4. Fail closed -----------------------------------------------------------------


def test_a_base_commit_missing_from_the_checkout_fails_closed(checkout):
    tree, state = checkout.tree(), checkout.state()
    event = {**checkout.event, "github.event.pull_request.base.sha": "3" * 40}
    result = run_step(checkout, event=event)
    assert result.returncode == 1, result.stdout + result.stderr
    assert "base commit is not in this checkout" in result.stdout
    assert checkout.tree() == tree
    assert checkout.state() == state


# --- 5. End to end --------------------------------------------------------------------


def review_sees(checkout, tmp_path):
    """Run the shipped review step with a stub codex that prints the project
    files Codex would load; return what it printed."""
    document = load()
    step = find_step(document, REVIEW)
    stub = tmp_path / "bin" / "codex"
    stub.parent.mkdir()
    stub.write_text(
        "#!/bin/sh\n"
        'if [ "$1" = "--version" ]; then echo "codex-cli 0.0.0-fixture"; exit 0; fi\n'
        'echo "model: $CODEX_MODEL"\n'
        "for f in AGENTS.override.md AGENTS.md .codex/config.toml; do\n"
        '  [ -f "$f" ] && cat "$f"\n'
        "done\n"
        "find .codex .agents .codex-plugin .claude-plugin .cursor-plugin "
        "-type f -exec cat {} + 2>/dev/null\n"
        "printf 'codex\\nVERDICT: CLEAN\\n'\n"
    )
    stub.chmod(0o755)
    out = tmp_path / "out"
    out.mkdir()
    summary = tmp_path / "summary.md"
    summary.write_text("")
    result = subprocess.run(
        [
            "bash",
            "--noprofile",
            "--norc",
            "-eo",
            "pipefail",
            "-c",
            shipped_run(step).replace("/tmp/", f"{out}/"),
        ],
        cwd=checkout.repo,
        env={
            **git_environment(),
            **step_environment(document, step, checkout.event),
            "PATH": f"{stub.parent}{os.pathsep}{os.environ['PATH']}",
            "GITHUB_STEP_SUMMARY": str(summary),
        },
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    return (out / "codex.out").read_text()


def assert_sees_the_base_config(seen):
    for marker in BASE_MARKERS:
        assert marker in seen, f"Codex did not load the base's {marker!r}:\n{seen}"
    for marker in PR_MARKERS:
        assert marker not in seen, f"Codex loaded the PR's {marker!r}:\n{seen}"


def test_codex_loads_the_base_project_config(checkout, tmp_path):
    result = run_step(checkout)
    assert result.returncode == 0, result.stdout + result.stderr
    assert_sees_the_base_config(review_sees(checkout, tmp_path))


def test_without_the_step_the_review_reads_the_checkouts_files(checkout, tmp_path):
    seen = review_sees(checkout, tmp_path)
    for marker in PR_MARKERS:
        assert marker in seen


MUTATIONS = {
    "the index restored instead of the working tree": lambda text: text.replace(
        "--worktree", "--staged"
    ),
    "AGENTS.md off the list": lambda text: text.replace("paths=(AGENTS.md ", "paths=("),
}


@pytest.mark.parametrize("mutation", sorted(MUTATIONS))
def test_a_step_that_keeps_the_prs_project_config_fails(mutation, checkout, tmp_path):
    script = shipped_run(find_step(load(), STEP))
    mutated = MUTATIONS[mutation](script)
    assert mutated != script, "mutation did not apply; the anchor drifted"
    result = run_step(checkout, script=mutated)
    assert result.returncode == 0, result.stdout + result.stderr
    with pytest.raises(AssertionError, match="loaded the PR's|did not load the base's"):
        assert_sees_the_base_config(review_sees(checkout, tmp_path))


# --- 6. CODEX_HOME --------------------------------------------------------------------


def test_the_login_step_uses_a_codex_home_in_runner_temp(tmp_path):
    step = find_step(load(), LOGIN)
    stub = tmp_path / "bin" / "codex"
    stub.parent.mkdir()
    seen = tmp_path / "seen"
    stub.write_text(
        "#!/bin/sh\n"
        "cat > /dev/null\n"
        f'printf \'%s %s\\n\' "$CODEX_HOME" "$*" >> "{seen}"\n'
    )
    stub.chmod(0o755)
    runner_temp = tmp_path / "runner-temp"
    runner_temp.mkdir()
    github_env = tmp_path / "github-env"
    result = subprocess.run(
        ["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", shipped_run(step)],
        cwd=tmp_path,
        env={
            **os.environ,
            "PATH": f"{stub.parent}{os.pathsep}{os.environ['PATH']}",
            "RUNNER_TEMP": str(runner_temp),
            "GITHUB_ENV": str(github_env),
            "OPENAI_API_KEY": "fixture-key",
        },
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    home = runner_temp / "codex-home"
    assert home.is_dir()
    assert github_env.read_text() == f"CODEX_HOME={home}\n"
    assert seen.read_text() == (f"{home} login --with-api-key\n{home} login status\n")
