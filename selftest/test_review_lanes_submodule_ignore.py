"""Review lanes whose model runs git must see a submodule's pointer change.

git leaves a submodule's pointer change out of `git diff`, `git log -p`,
`git show` and `git diff-tree` when the .gitmodules it reads sets
`submodule.<name>.ignore` (`all` hides it), and that file comes from the PR.
#250 passes `--ignore-submodules=none` wherever a workflow writes the git
command. In the adversarial and Codex lanes the model runs git itself, so each
lane has a step, before its model step, that writes
`submodule.<name>.ignore=none` into the checkout's .git/config for every name
with an `ignore` key in the base's, the PR head's or the merge commit's
.gitmodules. A per-name setting in any config scope overrides .gitmodules;
`diff.ignoreSubmodules` does not. .git/config is not PR-controlled, and git
reads it whatever environment the model's shell is given.

Layers:
1. Discovery: the lanes with the step, plus the exempt verifier, are exactly
   the model-git LANES that test_review_lanes_base_attributes.py discovers,
   and both copies of the step are one script that runs whenever the model
   step does.
2. Behavior: the shipped step runs in a fixture PR checkout (a detached merge
   commit with remote refs only, as actions/checkout leaves refs/pull/N/merge),
   then `git diff`, `git log -p` and `git show`, under the model step's
   environment, must print the pointer change. Shapes: a bumped pointer; a
   submodule only the PR adds, in the working tree claude-code-action's
   restoreConfigFromBase leaves (the base has no .gitmodules, so git reads
   the PR's from the index); a name only the base's .gitmodules has; an
   ignore key only the merge commit puts under its name; and the PR head
   checked out.
3. Fail closed: a name outside ^[A-Za-z0-9._/-]{1,255}$ (with `=`, `$(...)`,
   a backtick, a quote, a space or 256 characters, and, through a git shim
   because git's config grammar cannot produce one, a newline), a .gitmodules
   git cannot parse, a base commit missing from the checkout, or more than 256
   names: exit 1, with .git/config untouched.
4. Unaffected repos: with no .gitmodules, or one that sets no ignore key, the
   step leaves .git/config byte-identical and writes no GITHUB_ENV or
   GITHUB_OUTPUT.
5. Negative controls: each fixture hides the change from plain git, and the
   step fails layer 2 when it writes `all`, or leaves the base, the head or
   the merge commit unread.
6. The Codex review step end to end after the new step, with a stub codex
   that diffs as its prompt asks under an environment cut down to PATH and
   HOME: the change still shows.
"""

import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest
import yaml

from selftest.test_review_lanes_base_attributes import LANES

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"

STEP = "Keep submodule changes visible to the model's git"
ADVERSARIAL = (
    "claude-adversarial-review.yml",
    "adversarial-review",
    "Adversarial pass",
)
CODEX = ("codex-review.yml", "codex-review", "Run Codex adversarial review")
# (workflow, job id, model step) of each lane that runs the step.
SUBMODULE_LANES = {ADVERSARIAL, CODEX}
# The verifier's prompt hands its model git commands that carry
# --ignore-submodules=none (#250); test_verifier_changed_paths_renames.py pins
# them.
EXEMPT = {("verifier-on-high-risk.yml", "verify", "Run verifier (claude-code-action)")}

LINK = "vendor/lib"  # the submodule's path
# Submodule commits. The superproject records them without holding them.
BEFORE = "1" * 40
AFTER = "2" * 40
POINTER = f"+Subproject commit {AFTER}"

# What a model runs to read the PR in the merge checkout: HEAD is the merge
# commit and HEAD^2 the PR's head.
MERGE_COMMANDS = {
    "diff": ["--no-pager", "diff", "origin/main...HEAD"],
    "log": ["--no-pager", "log", "-p", "origin/main..HEAD"],
    "show": ["--no-pager", "show", "HEAD^2"],
}
# The same, with the PR's head checked out instead.
HEAD_COMMANDS = {
    "diff": ["--no-pager", "diff", "origin/main...HEAD"],
    "log": ["--no-pager", "log", "-p", "origin/main..HEAD"],
    "show": ["--no-pager", "show", "HEAD"],
}

# A ${{ }} expression.
EXPRESSION = re.compile(r"\$\{\{\s*(.*?)\s*\}\}")


class Gitlink(str):
    """A submodule commit recorded at a path (a mode 160000 entry)."""


def gitmodules(*sections):
    """A .gitmodules; each section is (name, path, *settings)."""
    return "".join(
        f'[submodule "{name}"]\n'
        f"\tpath = {path}\n"
        f"\turl = https://example.test/{path}.git\n"
        + "".join(f"\t{setting}\n" for setting in settings)
        for name, path, *settings in sections
    )


def git_environment():
    environment = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    # No global or system config: only the fixture's own settings.
    environment.update(
        GIT_CONFIG_GLOBAL=os.devnull,
        GIT_CONFIG_NOSYSTEM="1",
        GIT_AUTHOR_NAME="Fixture",
        GIT_AUTHOR_EMAIL="fixture@example.test",
        GIT_COMMITTER_NAME="Fixture",
        GIT_COMMITTER_EMAIL="fixture@example.test",
    )
    return environment


def git(repo, *arguments, environment=None):
    result = subprocess.run(
        ["git", *arguments],
        cwd=repo,
        env={**git_environment(), **(environment or {})},
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr
    return result.stdout


def stage(repo, files):
    """Stage `files`, each path mapped to its text, a Gitlink, or None to
    delete it. Only these paths: a submodule has no work tree here."""
    for path, content in files.items():
        if content is None:
            git(repo, "rm", "-q", "--cached", path)
            if (repo / path).is_file():
                (repo / path).unlink()
        elif isinstance(content, Gitlink):
            git(
                repo, "update-index", "--add", "--cacheinfo", f"160000,{content},{path}"
            )
        else:
            (repo / path).parent.mkdir(parents=True, exist_ok=True)
            (repo / path).write_text(content)
            git(repo, "add", path)


class Checkout:
    """A PR checkout as actions/checkout leaves it for a pull_request run: a
    detached merge commit and remote refs only. The PR branches from a commit
    holding `base_files` and changes them as `pr_files` says; `target_files`,
    when given, change the target branch after the PR branched."""

    def __init__(self, root, base_files, pr_files, target_files=None):
        self.repo = root / "checkout"
        self.repo.mkdir()
        git(self.repo, "init", "-q", "-b", "main")
        stage(self.repo, base_files)
        git(self.repo, "commit", "-qm", "merge base")
        git(self.repo, "switch", "-qc", "pr")
        stage(self.repo, pr_files)
        git(self.repo, "commit", "-qm", "pr")
        self.head = git(self.repo, "rev-parse", "HEAD").strip()
        git(self.repo, "switch", "-q", "main")
        if target_files:
            stage(self.repo, target_files)
            git(self.repo, "commit", "-qm", "the target branch moves on")
        self.base = git(self.repo, "rev-parse", "HEAD").strip()
        origin = root / "origin.git"
        git(self.repo, "init", "-q", "--bare", str(origin))
        git(self.repo, "push", "-q", str(origin), f"{self.base}:refs/heads/main")
        git(self.repo, "remote", "add", "origin", origin.as_uri())
        git(self.repo, "fetch", "-q", "--no-recurse-submodules", "origin")
        git(self.repo, "switch", "-q", "--detach", self.base)
        git(self.repo, "merge", "-q", "--no-ff", "-m", "Merge pr into main", self.head)
        git(self.repo, "branch", "-q", "-D", "main", "pr")
        self.event = {
            "github.event.pull_request.base.sha": self.base,
            "github.event.pull_request.head.sha": self.head,
            "github.event.pull_request.base.ref": "main",
            "github.event.pull_request.title": "Fixture PR",
        }

    def config_bytes(self):
        return (self.repo / ".git" / "config").read_bytes()

    def restore_config_from_base(self):
        """What claude-code-action's restoreConfigFromBase does to .gitmodules
        before its model starts: delete it, check out the base branch's copy
        when there is one, and unstage, so the index keeps the PR's copy."""
        (self.repo / ".gitmodules").unlink(missing_ok=True)
        environment = git_environment()
        for argv in (
            ["git", "checkout", "origin/main", "--", ".gitmodules"],
            ["git", "reset", "-q", "--", ".gitmodules"],
        ):
            subprocess.run(argv, cwd=self.repo, env=environment, capture_output=True)

    def check_out_head(self):
        """What a model with a free shell (Codex) could do before diffing."""
        git(self.repo, "checkout", "-q", "--detach", self.head)


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


def run_step(checkout, lane, tmp_path, script=None, event=None, path=None):
    """Run the lane's copy of the step (or `script` in its place) in the
    checkout, as the runner would."""
    workflow, job, _ = lane
    document = load(workflow)
    step = find_step(document, job, STEP)
    runner_temp = tmp_path / "runner-temp"
    runner_temp.mkdir(exist_ok=True)
    environment = {
        **git_environment(),
        **step_environment(document, job, step, event or checkout.event),
        "RUNNER_TEMP": str(runner_temp),
        "GITHUB_ENV": str(tmp_path / "github-env"),
        "GITHUB_OUTPUT": str(tmp_path / "github-output"),
    }
    if path is not None:
        environment["PATH"] = f"{path}{os.pathsep}{environment['PATH']}"
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
        env=environment,
        capture_output=True,
        text=True,
    )


def assert_model_sees_the_pointer(checkout, lane, commands):
    """Every patch-printing git command, under the lane's model-step
    environment, prints the submodule's new commit."""
    workflow, job, name = lane
    document = load(workflow)
    environment = step_environment(
        document, job, find_step(document, job, name), checkout.event
    )
    for command, arguments in commands.items():
        shown = git(checkout.repo, *arguments, environment=environment)
        assert POINTER in shown, (
            f"{workflow}: `git {command}` under {name!r}'s environment hides "
            f"the submodule change at {LINK}:\n{shown}"
        )


def assert_plain_git_hides_the_pointer(checkout, commands):
    for arguments in commands.values():
        assert POINTER not in git(checkout.repo, *arguments)


# --- PR shapes ---------------------------------------------------------------


def bumped_pointer(root):
    """The PR sets `ignore = all` and moves the submodule."""
    return Checkout(
        root,
        {".gitmodules": gitmodules(("vendor/lib", LINK)), LINK: Gitlink(BEFORE)},
        {
            ".gitmodules": gitmodules(("vendor/lib", LINK, "ignore = all")),
            LINK: Gitlink(AFTER),
        },
    )


def added_by_the_pr(root):
    """The base has no .gitmodules; the PR adds a submodule, ignored."""
    return Checkout(
        root,
        {"app.py": "x = 1\n"},
        {
            ".gitmodules": gitmodules(("vendor/lib", LINK, "ignore = all")),
            LINK: Gitlink(AFTER),
        },
    )


def name_only_the_base_has(root):
    """The base ignores the submodule under one name; the PR renames it,
    drops the setting and moves the submodule. The restored .gitmodules is
    the base's, so the base's name decides."""
    return Checkout(
        root,
        {
            ".gitmodules": gitmodules(("vendored", LINK, "ignore = all")),
            LINK: Gitlink(BEFORE),
        },
        {".gitmodules": gitmodules(("vendor/lib", LINK)), LINK: Gitlink(AFTER)},
    )


def ignore_only_the_merge_sets(root):
    """The PR adds `ignore = all` under the submodule's old name while the
    target branch renames it: the clean merge puts the setting under the NEW
    name, which neither side ignores. The PR's head keeps the old name."""
    return Checkout(
        root,
        {".gitmodules": gitmodules(("A", LINK)), LINK: Gitlink(BEFORE)},
        {".gitmodules": gitmodules(("A", LINK, "ignore = all")), LINK: Gitlink(AFTER)},
        target_files={".gitmodules": gitmodules(("Z", LINK))},
    )


# name: (fixture, how the model's checkout is shaped, lanes, commands)
SHAPES = {
    "bumped pointer": (bumped_pointer, None, SUBMODULE_LANES, MERGE_COMMANDS),
    "added by the PR, read from the index": (
        added_by_the_pr,
        Checkout.restore_config_from_base,
        {ADVERSARIAL},
        MERGE_COMMANDS,
    ),
    "name only the base has": (
        name_only_the_base_has,
        Checkout.restore_config_from_base,
        {ADVERSARIAL},
        MERGE_COMMANDS,
    ),
    "ignore only the merge commit sets": (
        ignore_only_the_merge_sets,
        None,
        SUBMODULE_LANES,
        MERGE_COMMANDS,
    ),
    "PR head checked out": (
        ignore_only_the_merge_sets,
        Checkout.check_out_head,
        {CODEX},
        HEAD_COMMANDS,
    ),
}
CASES = [
    pytest.param(shape, lane, id=f"{shape}-{lane[0]}")
    for shape, (_, _, lanes, _) in SHAPES.items()
    for lane in sorted(lanes)
]


def prepare(shape, tmp_path, lane, script=None):
    """Build the shape's checkout, run the step, then shape the checkout as
    the model will see it."""
    build, reshape, _, commands = SHAPES[shape]
    checkout = build(tmp_path)
    result = run_step(checkout, lane, tmp_path, script=script)
    assert result.returncode == 0, result.stdout + result.stderr
    if reshape is not None:
        reshape(checkout)
    return checkout, commands


# --- 1. Discovery --------------------------------------------------------------


def test_every_model_git_lane_runs_the_step_or_is_exempt():
    assert SUBMODULE_LANES | EXEMPT == LANES
    assert not SUBMODULE_LANES & EXEMPT


@pytest.mark.parametrize("lane", sorted(SUBMODULE_LANES), ids=lambda lane: lane[0])
def test_the_step_runs_before_the_model_step_whenever_it_runs(lane):
    workflow, job, name = lane
    steps = load(workflow)["jobs"][job]["steps"]
    names = [step.get("name") for step in steps]
    assert names.count(STEP) == 1
    step, model = steps[names.index(STEP)], steps[names.index(name)]
    assert names.index(STEP) < names.index(name)
    assert step.get("if") == model.get("if")


def test_both_lanes_run_one_script():
    steps = [
        find_step(load(workflow), job, STEP)
        for workflow, job, _ in sorted(SUBMODULE_LANES)
    ]
    assert steps[0]["run"] == steps[1]["run"]
    environment = {
        "BASE_SHA": "${{ github.event.pull_request.base.sha }}",
        "HEAD_SHA": "${{ github.event.pull_request.head.sha }}",
    }
    assert [step["env"] for step in steps] == [environment, environment]


# --- 2 and 5. Behavior and negative controls -----------------------------------


@pytest.mark.parametrize("shape", sorted(SHAPES))
def test_the_fixture_hides_the_pointer_from_plain_git(shape, tmp_path):
    build, reshape, _, commands = SHAPES[shape]
    checkout = build(tmp_path)
    if reshape is not None:
        reshape(checkout)
    assert_plain_git_hides_the_pointer(checkout, commands)


@pytest.mark.parametrize(("shape", "lane"), CASES)
def test_the_models_git_shows_the_pointer_change(shape, lane, tmp_path):
    checkout, commands = prepare(shape, tmp_path, lane)
    assert_model_sees_the_pointer(checkout, lane, commands)


def test_the_step_names_what_it_sets(tmp_path):
    checkout = bumped_pointer(tmp_path)
    result = run_step(checkout, CODEX, tmp_path)
    assert result.returncode == 0, result.stderr
    assert result.stdout == "submodule.vendor/lib.ignore=none\n"
    assert git(checkout.repo, "config", "--local", "--get-regexp", "^submodule\\.") == (
        "submodule.vendor/lib.ignore none\n"
    )


LOOP = 'for rev in "$BASE_SHA" "$HEAD_SHA" HEAD; do'
# mutation: (edit, the shape it must break)
MUTATIONS = {
    "value all": (
        lambda text: text.replace('.ignore" none', '.ignore" all'),
        "bumped pointer",
    ),
    "base unread": (
        lambda text: text.replace(LOOP, 'for rev in "$HEAD_SHA" HEAD; do'),
        "name only the base has",
    ),
    "head unread": (
        lambda text: text.replace(LOOP, 'for rev in "$BASE_SHA" HEAD; do'),
        "PR head checked out",
    ),
    "merge unread": (
        lambda text: text.replace(LOOP, 'for rev in "$BASE_SHA" "$HEAD_SHA"; do'),
        "ignore only the merge commit sets",
    ),
}


@pytest.mark.parametrize("mutation", sorted(MUTATIONS))
def test_a_step_that_misses_a_source_fails(mutation, tmp_path):
    edit, shape = MUTATIONS[mutation]
    lane = sorted(SHAPES[shape][2])[0]
    workflow, job, _ = lane
    script = shipped_run(find_step(load(workflow), job, STEP))
    mutated = edit(script)
    assert mutated != script, "mutation did not apply; the anchor drifted"
    checkout, commands = prepare(shape, tmp_path, lane, script=mutated)
    with pytest.raises(AssertionError, match="hides the submodule change"):
        assert_model_sees_the_pointer(checkout, lane, commands)


# --- 3. Fail closed --------------------------------------------------------------


def with_pr_gitmodules(root, text):
    """The PR adds `text` as its .gitmodules, with the submodule it names."""
    return Checkout(
        root,
        {"app.py": "x = 1\n"},
        {".gitmodules": text, LINK: Gitlink(AFTER)},
    )


def assert_failed_closed(result, checkout, before, message):
    assert result.returncode == 1, result.stdout + result.stderr
    assert message in result.stdout
    assert checkout.config_bytes() == before, ".git/config was written"


# Each is written into .gitmodules with `"` and `\` escaped.
MALICIOUS_NAMES = {
    "equals sign": "vendor=lib",
    "command substitution": "$(touch pwned)",
    "backtick": "`touch pwned`",
    "double quote": 'vendor"lib',
    "space": "vendor lib",
    "semicolon": "vendor;lib",
    "256 characters": "n" * 256,
}


@pytest.mark.parametrize("name", sorted(MALICIOUS_NAMES))
@pytest.mark.parametrize("lane", sorted(SUBMODULE_LANES), ids=lambda lane: lane[0])
def test_a_name_outside_the_pattern_fails_closed(name, lane, tmp_path):
    raw = MALICIOUS_NAMES[name]
    quoted = raw.replace("\\", "\\\\").replace('"', '\\"')
    checkout = with_pr_gitmodules(
        tmp_path, f'[submodule "{quoted}"]\n\tpath = {LINK}\n\tignore = all\n'
    )
    before = checkout.config_bytes()
    result = run_step(checkout, lane, tmp_path)
    assert_failed_closed(
        result, checkout, before, "sets ignore for a submodule whose name"
    )
    # The name is never echoed, and nothing in it ran.
    assert raw not in result.stdout + result.stderr
    assert not (checkout.repo / "pwned").exists()


def test_a_name_of_255_characters_passes(tmp_path):
    name = "n" * 255
    checkout = with_pr_gitmodules(
        tmp_path, f'[submodule "{name}"]\n\tpath = {LINK}\n\tignore = all\n'
    )
    result = run_step(checkout, CODEX, tmp_path)
    assert result.returncode == 0, result.stderr
    assert (
        git(checkout.repo, "config", "--local", f"submodule.{name}.ignore") == "none\n"
    )


def test_a_name_with_a_newline_fails_closed(tmp_path):
    # git's config grammar ends a section header at a newline, so no
    # .gitmodules yields such a name; a shim makes `git config --list` return
    # one, as a parser change could.
    checkout = bumped_pointer(tmp_path)
    before = checkout.config_bytes()
    shim = tmp_path / "shim" / "git"
    shim.parent.mkdir()
    shim.write_text(
        f"#!{shutil.which('python3')}\n"
        "import os, sys\n"
        "if '--list' in sys.argv[1:]:\n"
        "    record = b'submodule.a' + bytes([10]) + b'b.ignore' + bytes([0])\n"
        "    sys.stdout.buffer.write(record)\n"
        "    sys.exit(0)\n"
        f"os.execv({shutil.which('git')!r}, ['git', *sys.argv[1:]])\n"
    )
    shim.chmod(0o755)
    result = run_step(checkout, ADVERSARIAL, tmp_path, path=shim.parent)
    assert_failed_closed(
        result, checkout, before, "sets ignore for a submodule whose name"
    )


def test_a_gitmodules_git_cannot_parse_fails_closed(tmp_path):
    checkout = Checkout(
        tmp_path,
        {"app.py": "x = 1\n"},
        {".gitmodules": '[submodule "vendor/lib"\n\tignore = all\n'},
    )
    before = checkout.config_bytes()
    result = run_step(checkout, CODEX, tmp_path)
    assert_failed_closed(result, checkout, before, "git cannot parse the .gitmodules")


def test_a_base_commit_missing_from_the_checkout_fails_closed(tmp_path):
    checkout = bumped_pointer(tmp_path)
    before = checkout.config_bytes()
    event = {**checkout.event, "github.event.pull_request.base.sha": "3" * 40}
    result = run_step(checkout, ADVERSARIAL, tmp_path, event=event)
    assert_failed_closed(result, checkout, before, "is not in this checkout")


def test_more_than_256_names_fails_closed(tmp_path):
    text = "".join(
        f'[submodule "s{n:03}"]\n\tpath = s{n:03}\n\tignore = all\n' for n in range(257)
    )
    checkout = with_pr_gitmodules(tmp_path, text)
    before = checkout.config_bytes()
    result = run_step(checkout, CODEX, tmp_path)
    assert_failed_closed(result, checkout, before, "more than this step's cap of 256")


# --- 4. Unaffected repos --------------------------------------------------------


UNAFFECTED = {
    "no .gitmodules": ({"app.py": "x = 1\n"}, {"app.py": "x = 2\n"}),
    "no ignore key": (
        {".gitmodules": gitmodules(("vendor/lib", LINK)), LINK: Gitlink(BEFORE)},
        {LINK: Gitlink(AFTER)},
    ),
}


@pytest.mark.parametrize("repo", sorted(UNAFFECTED))
@pytest.mark.parametrize("lane", sorted(SUBMODULE_LANES), ids=lambda lane: lane[0])
def test_a_repo_that_ignores_no_submodule_is_left_as_it_is(repo, lane, tmp_path):
    checkout = Checkout(tmp_path, *UNAFFECTED[repo])
    before = checkout.config_bytes()
    status = git(checkout.repo, "status", "--porcelain", "--ignored")
    result = run_step(checkout, lane, tmp_path)
    assert result.returncode == 0, result.stderr
    assert result.stdout == (
        "No .gitmodules sets ignore for a submodule; .git/config is left as it is.\n"
    )
    assert checkout.config_bytes() == before
    assert git(checkout.repo, "status", "--porcelain", "--ignored") == status
    assert not (tmp_path / "github-env").exists()
    assert not (tmp_path / "github-output").exists()


# --- 6. The Codex review step end to end ----------------------------------------


def test_codex_sees_the_pointer_under_a_stripped_environment(tmp_path):
    checkout = bumped_pointer(tmp_path)
    result = run_step(checkout, CODEX, tmp_path)
    assert result.returncode == 0, result.stderr
    document = load("codex-review.yml")
    step = find_step(document, "codex-review", "Run Codex adversarial review")
    stub = tmp_path / "bin" / "codex"
    stub.parent.mkdir()
    # Stands in for the Codex CLI: it diffs the way the review prompt asks,
    # in a shell that inherits nothing but PATH and HOME.
    stub.write_text(
        "#!/bin/sh\n"
        'if [ "$1" = "--version" ]; then echo "codex-cli 0.0.0-fixture"; exit 0; fi\n'
        "for prompt; do :; done\n"
        "base=$(printf '%s\\n' \"$prompt\" | grep -oE 'origin/[A-Za-z0-9._/-]+' | head -n 1)\n"
        '[ -n "$base" ] || { echo "stub: the prompt names no origin/<base>" >&2; exit 1; }\n'
        'echo "model: $CODEX_MODEL"\n'
        'env -i PATH="$PATH" HOME="$STUB_HOME" git --no-pager diff "$base...HEAD"\n'
        "printf 'codex\\nVERDICT: CLEAN\\n'\n"
    )
    stub.chmod(0o755)
    home = tmp_path / "home"
    home.mkdir()
    out = tmp_path / "out"
    out.mkdir()
    summary = tmp_path / "summary.md"
    summary.write_text("")
    script = shipped_run(step).replace("/tmp/", f"{out}/")
    review = subprocess.run(
        ["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", script],
        cwd=checkout.repo,
        env={
            **git_environment(),
            **step_environment(document, "codex-review", step, checkout.event),
            "PATH": f"{stub.parent}{os.pathsep}{os.environ['PATH']}",
            "STUB_HOME": str(home),
            "GITHUB_STEP_SUMMARY": str(summary),
        },
        capture_output=True,
        text=True,
    )
    assert review.returncode == 0, review.stdout + review.stderr
    seen = (out / "codex.out").read_text()
    assert POINTER in seen, f"Codex's git hid the submodule change:\n{seen}"
    assert f"-Subproject commit {BEFORE}" in seen
