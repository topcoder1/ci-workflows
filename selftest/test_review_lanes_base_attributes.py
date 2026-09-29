"""Review lanes whose model runs git must read attributes from the base commit.

The verifier, adversarial and Codex lanes hand their model a PR checkout and
let it run git: `git diff`, `git log -p`, `git show`. git takes .gitattributes
from that checkout, so a path the PR itself marks `binary` or `-diff` (that
.gitattributes included) prints as "Binary files ... differ" and the model
never sees the change. Each lane now gives its model step
GIT_ATTR_SOURCE=<base sha>: the fix #244 makes in claude-review.yml's context
step with `git --attr-source`, carried to git commands the model itself runs.

GitHub's own diff (`gh pr diff`, the pulls/<n>/files API) ignores
.gitattributes altogether, so a lane that reads only that diff needs nothing.
That half was measured against github.com and cannot run here.

Layers:
1. Discovery: each claude-code-action step whose --allowedTools has a Bash
   rule for git or a shell (or that has no allowlist), and each step running
   `codex review` or `codex exec`, must be one of the hardcoded LANES, so a new
   lane or a widened allowlist of those shapes cannot slip past this file.
2. Behavior: `git diff`, `git log -p` and `git show` run in a fixture PR
   checkout (a detached merge commit with remote refs only, as actions/checkout
   leaves refs/pull/N/merge) under the environment the workflow gives each
   lane's model step. The files the PR marks must print in full, and the
   base's own `-diff` must still summarize its lockfile. Negative controls:
   GIT_ATTR_SOURCE dropped, misspelled, or set to the head sha or the base
   branch name.
3. Shipped bash: the verifier's rendered prompt command, and the Codex review
   step run end to end with a stub `codex` that diffs as its prompt asks.
4. The verifier's classifier input (`git diff --name-only`) lists every path
   whatever its attributes, so that step needs no attribute source.
"""

import os
import re
import subprocess
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"

# (workflow, job id, step name) of every step that lets a model run git.
LANES = {
    ("verifier-on-high-risk.yml", "verify", "Run verifier (claude-code-action)"),
    ("claude-adversarial-review.yml", "adversarial-review", "Adversarial pass"),
    ("codex-review.yml", "codex-review", "Run Codex adversarial review"),
}

# The git subcommands that print patches, as a model would run them against
# the base: HEAD is the merge commit and HEAD^2 the PR's head.
PATCH_COMMANDS = {
    "diff": ["git", "--no-pager", "diff", "origin/main...HEAD"],
    "log": ["git", "--no-pager", "log", "-p", "origin/main..HEAD"],
    "show": ["git", "--no-pager", "show", "HEAD^2"],
}

BASE_FILES = {
    ".gitattributes": "*.lock -diff\n",
    "deps.lock": "lock_marker = 1\n",
    "notes.txt": "notes\n",
    "conf/app.cfg": "app\n",
    "plain.txt": "plain\n",
}
PR_FILES = {
    ".gitattributes": "*.lock -diff\nnotes.txt -diff\n.gitattributes -diff\n",
    "conf/.gitattributes": "* binary\n",
    "notes.txt": "notes\nnotes_marker = 1\n",
    "conf/app.cfg": "app\napp_marker = 2\n",
    "deps.lock": "lock_marker = 2\n",
    "plain.txt": "plain\nplain_marker = 3\n",
}
# Added lines the PR's own attributes hide from plain git, per path.
HIDDEN_BY_THE_PR = {
    "notes.txt": "+notes_marker = 1",
    "conf/app.cfg": "+app_marker = 2",
    ".gitattributes": "+notes.txt -diff",
    "conf/.gitattributes": "+* binary",
}
# The base declares lockfiles -diff; that must keep working.
BASE_SUMMARY = "Binary files a/deps.lock and b/deps.lock differ"
PR_SUMMARY = "Binary files a/notes.txt and b/notes.txt differ"

# A ${{ }} expression; a model's --allowedTools list; a Codex model run on an
# uncommented line; programs that, allowed as a Bash rule, let a model run git.
EXPRESSION = re.compile(r"\$\{\{\s*(.*?)\s*\}\}")
ALLOWED_TOOLS = re.compile(r'(?<![\w-])--allowedTools\s+"([^"]*)"')
CODEX_MODEL_RUN = re.compile(
    r"^(?:[^#\n]*[\s;|&(/])?codex\s[^\n]*\b(?:review|exec)\b", re.M
)
GIT_RUNNERS = {"git", "bash", "sh", "zsh", "env", "xargs"}


def git_environment():
    environment = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    # No global or system config or attributes: only the fixture's count.
    environment.update(
        GIT_CONFIG_GLOBAL=os.devnull,
        GIT_CONFIG_NOSYSTEM="1",
        GIT_ATTR_NOSYSTEM="1",
        XDG_CONFIG_HOME=os.devnull,
        GIT_AUTHOR_NAME="Fixture",
        GIT_AUTHOR_EMAIL="fixture@example.test",
        GIT_COMMITTER_NAME="Fixture",
        GIT_COMMITTER_EMAIL="fixture@example.test",
    )
    return environment


class Checkout:
    """A PR checkout as actions/checkout leaves it for a pull_request run."""

    def __init__(self, root):
        self.repo = root / "checkout"
        self.repo.mkdir()
        self.git("init", "-q", "-b", "main")
        self.write(BASE_FILES)
        self.git("add", ".")
        self.git("commit", "-qm", "base")
        self.base = self.git("rev-parse", "HEAD").strip()
        self.git("switch", "-qc", "pr")
        self.write(PR_FILES)
        self.git("add", ".")
        self.git("commit", "-qm", "PR marks its own files binary")
        self.head = self.git("rev-parse", "HEAD").strip()
        # origin serves main at the base; HEAD is the merge commit.
        origin = root / "origin.git"
        self.git("init", "-q", "--bare", str(origin))
        self.git("push", "-q", str(origin), f"{self.base}:refs/heads/main")
        self.git("remote", "add", "origin", origin.as_uri())
        self.git("fetch", "-q", "origin")
        self.git("switch", "-q", "--detach", self.base)
        self.git("merge", "-q", "--no-ff", "-m", "Merge pr into main", self.head)
        # Like actions/checkout: a detached HEAD and remote refs only, so a
        # branch name that resolves here would not on the runner.
        self.git("branch", "-q", "-D", "main", "pr")
        self.event = {
            "github.event.pull_request.base.sha": self.base,
            "github.event.pull_request.head.sha": self.head,
            "github.event.pull_request.base.ref": "main",
            "github.event.pull_request.title": "Fixture PR",
        }

    def write(self, files):
        for name, content in files.items():
            path = self.repo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)

    def git(self, *arguments):
        return self.run(["git", *arguments])

    def run(self, argv, environment=None):
        result = subprocess.run(
            argv,
            cwd=self.repo,
            env={**git_environment(), **(environment or {})},
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0, result.stderr
        return result.stdout


@pytest.fixture
def checkout(tmp_path):
    return Checkout(tmp_path)


def load(workflow, text=None):
    return yaml.safe_load(
        text if text is not None else (WORKFLOWS / workflow).read_text()
    )


def find_step(document, job, name):
    steps = [s for s in document["jobs"][job]["steps"] if s.get("name") == name]
    assert len(steps) == 1, f"expected one step named {name!r} in job {job!r}"
    return steps[0]


def step_environment(document, job, step, event):
    """What the runner puts in the step's environment: workflow, then job,
    then step env, each ${{ }} expression looked up in the fixture event."""
    merged = {
        **(document.get("env") or {}),
        **(document["jobs"][job].get("env") or {}),
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


def runs_git(step):
    """Whether a step lets its model run git: a claude-code-action step whose
    allowlist has a Bash rule for git or a shell, or no allowlist at all; or a
    step that runs `codex review` or `codex exec`."""
    if step.get("uses", "").startswith("anthropics/claude-code-action@"):
        tools = ALLOWED_TOOLS.search((step.get("with") or {}).get("claude_args", ""))
        if tools is None:  # no allowlist: assume the worst
            return True
        for tool in (t.strip() for t in tools.group(1).split(",")):
            rule = re.fullmatch(r"Bash(?:\((.*)\))?", tool)
            if rule:
                program = re.split(r"[\s:]+", (rule.group(1) or "*").strip())[0]
                if program == "*" or program.rsplit("/", 1)[-1] in GIT_RUNNERS:
                    return True
        return False
    return bool(CODEX_MODEL_RUN.search(step.get("run", "").replace("\\\n", " ")))


def assert_model_sees_the_change(workflow, text, checkout):
    """Under the model step's environment, every patch-printing git command
    shows what the PR marks binary and still summarizes what the base marks
    -diff."""
    _, job, name = next(lane for lane in LANES if lane[0] == workflow)
    document = load(workflow, text)
    step = find_step(document, job, name)
    environment = step_environment(document, job, step, checkout.event)
    for command, argv in PATCH_COMMANDS.items():
        shown = checkout.run(argv, environment)
        for path, line in HIDDEN_BY_THE_PR.items():
            assert line in shown, (
                f"{workflow}: `git {command}` under {name!r}'s environment hides "
                f"{path} (the PR's own .gitattributes decided what git prints)"
            )
        assert BASE_SUMMARY in shown, (
            f"{workflow}: `git {command}` lost the base's own `*.lock -diff`"
        )


def test_every_model_step_that_runs_git_is_a_known_lane():
    found = set()
    for path in sorted(WORKFLOWS.glob("*.yml")):
        document = load(path.name)
        for job_id, job in (document.get("jobs") or {}).items():
            for step in job.get("steps") or []:
                if runs_git(step):
                    found.add((path.name, job_id, step.get("name")))
    # claude-review.yml's model runs no git: its diff comes from the context
    # step, whose `git --attr-source` selftest/test_claude_review_context.py
    # pins.
    assert found == LANES


def test_the_fixture_hides_the_marked_files_from_plain_git(checkout):
    # Control: without an attribute source, git honours the PR's attributes.
    for argv in PATCH_COMMANDS.values():
        shown = checkout.run(argv)
        assert PR_SUMMARY in shown
        assert "Binary files a/conf/app.cfg and b/conf/app.cfg differ" in shown
        for line in HIDDEN_BY_THE_PR.values():
            assert line not in shown
        assert "+plain_marker = 3" in shown


@pytest.mark.parametrize("workflow", sorted(lane[0] for lane in LANES))
def test_each_lanes_model_git_reads_attributes_from_the_base(checkout, workflow):
    assert_model_sees_the_change(workflow, None, checkout)


LINE = "GIT_ATTR_SOURCE: ${{ github.event.pull_request.base.sha }}\n"
MUTATIONS = {
    "dropped": lambda text: re.sub(r"(?m)^ *" + re.escape(LINE), "", text),
    "misspelled": lambda text: text.replace(
        LINE, "GIT_ATTRS_" + LINE[len("GIT_ATTR_") :]
    ),
    "head-sha": lambda text: text.replace(LINE, LINE.replace(".base.sha", ".head.sha")),
    "base-ref": lambda text: text.replace(LINE, LINE.replace(".base.sha", ".base.ref")),
}


@pytest.mark.parametrize("mutation", sorted(MUTATIONS))
@pytest.mark.parametrize("workflow", sorted(lane[0] for lane in LANES))
def test_a_lane_that_reads_the_prs_attributes_fails(checkout, workflow, mutation):
    text = (WORKFLOWS / workflow).read_text()
    mutated = MUTATIONS[mutation](text)
    assert mutated != text, "mutation did not apply; the anchor drifted"
    # Either git reads the PR's attributes, or it refuses the attribute source.
    with pytest.raises(AssertionError, match="hides|bad --attr-source"):
        assert_model_sees_the_change(workflow, mutated, checkout)


def test_verifier_prompt_command_shows_what_the_pr_marks_binary(checkout, tmp_path):
    document = load("verifier-on-high-risk.yml")
    build = next(
        s for s in document["jobs"]["verify"]["steps"] if s.get("id") == "prompt"
    )
    workdir = tmp_path / "prompt"
    workdir.mkdir()
    (workdir / "matches.txt").write_text("notes.txt\t(matched: fixture)\n")
    output = workdir / "github-output"
    result = subprocess.run(
        ["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", shipped_run(build)],
        cwd=workdir,
        env={
            **os.environ,
            **step_environment(document, "verify", build, checkout.event),
            "GITHUB_OUTPUT": str(output),
        },
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr
    prompt = output.read_text()
    command = re.search(r"Read the diff for that file via Bash: `([^`]+)`", prompt)
    assert command and "<file>" in command.group(1), "no per-file diff command"
    model = find_step(document, "verify", "Run verifier (claude-code-action)")
    environment = step_environment(document, "verify", model, checkout.event)
    for path, line in HIDDEN_BY_THE_PR.items():
        argv = ["bash", "-c", command.group(1).replace("<file>", path)]
        shown = checkout.run(argv, environment)
        assert line in shown and "Binary files" not in shown, (path, shown)
        # Control: the same command reads the PR's attributes without it.
        assert "Binary files" in checkout.run(argv)
    argv = ["bash", "-c", command.group(1).replace("<file>", "deps.lock")]
    assert BASE_SUMMARY in checkout.run(argv, environment)


def test_codex_step_hands_codex_the_base_attributes(checkout, tmp_path):
    document = load("codex-review.yml")
    step = find_step(document, "codex-review", "Run Codex adversarial review")
    stub = tmp_path / "bin" / "codex"
    stub.parent.mkdir()
    # Stands in for the Codex CLI: it diffs the way the review prompt asks.
    stub.write_text(
        "#!/bin/sh\n"
        'if [ "$1" = "--version" ]; then echo "codex-cli 0.0.0-fixture"; exit 0; fi\n'
        "for prompt; do :; done\n"
        "base=$(printf '%s\\n' \"$prompt\" | grep -oE 'origin/[A-Za-z0-9._/-]+' | head -n 1)\n"
        '[ -n "$base" ] || { echo "stub: the prompt names no origin/<base>" >&2; exit 1; }\n'
        'echo "model: $CODEX_MODEL"\n'
        'git --no-pager diff "$base...HEAD"\n'
        "printf 'codex\\nVERDICT: CLEAN\\n'\n"
    )
    stub.chmod(0o755)
    out = tmp_path / "out"
    out.mkdir()
    summary = tmp_path / "summary.md"
    summary.write_text("")
    script = shipped_run(step).replace("/tmp/", f"{out}/")
    result = subprocess.run(
        ["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", script],
        cwd=checkout.repo,
        env={
            **git_environment(),
            **step_environment(document, "codex-review", step, checkout.event),
            "PATH": f"{stub.parent}{os.pathsep}{os.environ['PATH']}",
            "GITHUB_STEP_SUMMARY": str(summary),
        },
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    seen = (out / "codex.out").read_text()
    for path, line in HIDDEN_BY_THE_PR.items():
        assert line in seen, f"Codex saw {path} only as binary:\n{seen}"
    assert BASE_SUMMARY in seen
    assert "+plain_marker = 3" in seen


def test_verifier_classifier_lists_paths_whatever_their_attributes(checkout, tmp_path):
    document = load("verifier-on-high-risk.yml")
    step = next(s for s in document["jobs"]["verify"]["steps"] if s.get("id") == "diff")
    output = tmp_path / "github-output"
    result = subprocess.run(
        ["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", shipped_run(step)],
        cwd=checkout.repo,
        env={
            **git_environment(),
            **step_environment(document, "verify", step, checkout.event),
            "GITHUB_OUTPUT": str(output),
        },
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr
    listed = (checkout.repo / "changed-paths.txt").read_text().splitlines()
    assert sorted(listed) == [
        ".gitattributes",
        "conf/.gitattributes",
        "conf/app.cfg",
        "deps.lock",
        "notes.txt",
        "plain.txt",
    ]
    assert output.read_text() == "changed_count=6\n"
