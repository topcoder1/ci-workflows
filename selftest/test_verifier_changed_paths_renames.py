"""The high-risk verifier must see every path a PR changes, and follow a file
that moves.

verifier-on-high-risk.yml's "Compute PR diff" step (id: diff) writes
changed-paths.txt, the list scripts/verifier-classify-diff.sh matches against
the high-risk globs; a list that matches none posts the check as skipped.
Porcelain `git diff` detects renames by default (diff.renames, true since git
2.9), and with rename detection `--name-only` prints a renamed file under its
new path only. `--no-renames` lists the old path too, as a deletion: the
coverage the automerge lanes get from the files API's previous_filename.
git also applies a submodule's `ignore` setting from the checkout's
.gitmodules, the PR's own copy, to a diff between two commits: `ignore = all`
leaves the submodule's change out, --name-only included, unless the command
passes --ignore-submodules=none.

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
4. A PR that moves a submodule in a high-risk directory to another commit and
   sets `ignore = all` for it: the step lists the submodule and the classifier
   matches it, and .gitmodules, which the central list also gates. Negative
   control: without --ignore-submodules=none only .gitmodules is listed.
5. The prompt's commands show that change, and follow a submodule the PR
   moves out of the directory. Negative controls: each command without the
   flag.
6. A move that rewrites most of the file, which git's default 50% similarity
   does not pair: the prompt's rename listing, at 10%, pairs a move that kept
   two of ten functions (negative control: the listing at the default).
7. For a matched file the PR removes, the prompt's changed-paths listing names
   where its code went when no other command in the prompt does: a new file
   after a move that kept nothing, or a file that already existed, which git
   never pairs as a rename destination (negative control: the listing limited
   to added files).
8. Code can also leave a matched file the PR keeps: here most of it moves into
   a file that already exists. The prompt step names each matched file the PR
   keeps but deletes lines from (its numstat, under the base's attributes) and
   sends the model to the changed-paths listing for it, which names where the
   code went. A kept file the PR only adds to, even one its own .gitattributes
   marks binary, a binary file the PR adds, whose numstat reads "-" as a kept
   binary file's does, and a matched file the PR removes, which the listing
   already covers, leave the prompt as it was. Negative control: that numstat
   without --ignore-submodules=none misses a kept submodule the PR's
   .gitmodules ignores, whose old commit line the PR's bump deletes. The note
   names every such file, in the classifier's order, a file that becomes a
   symlink included; and the step fails, writing no prompt, when the base ref
   does not resolve or a matched path is outside the diff step's alphabet.
"""

import os
import re
import shutil
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
EXISTING = "src/misc/utils.py"  # in the base already; matches none of it
EXISTING_SOURCE = "def existing():\n    return None\n\n"
# Ten functions of one length, and ten rewritten ones of the same length that
# share no line with them.
FUNCTIONS = [f"def check_{n}(token):\n    return token == {n}\n\n" for n in range(10)]
REWRITTEN = [f"def allow_{n}(claim):\n    return claim != {n}\n\n" for n in range(10)]
SOURCE = "".join(FUNCTIONS[:5])

LINK = "src/auth/vendor-lib"  # a submodule; matches the central high-risk list
MOVED_LINK = "src/misc/vendor-lib"  # matches none of it
# Submodule commits. The superproject records them without holding them.
BEFORE = "1" * 40
AFTER = "2" * 40

# A ${{ }} expression.
EXPRESSION = re.compile(r"\$\{\{\s*(.*?)\s*\}\}")


def gitmodules(path, *settings):
    return (
        '[submodule "vendor-lib"]\n'
        f"\tpath = {path}\n"
        "\turl = https://example.test/vendor-lib.git\n"
    ) + "".join(f"\t{setting}\n" for setting in settings)


class Gitlink(str):
    """A submodule commit recorded at a path (a mode 160000 entry)."""


class Symlink(str):
    """A symbolic link to the path it holds (a mode 120000 entry)."""


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
    """Run `script` as a workflow step; return what it wrote to $GITHUB_OUTPUT,
    a file of its own as on the runner."""
    output = cwd.parent / f"{cwd.name}-github-output"
    output.unlink(missing_ok=True)
    result = subprocess.run(
        ["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", script],
        cwd=cwd,
        env={**environment, "GITHUB_OUTPUT": str(output)},
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr
    return output.read_text()


def stage(repo, files):
    """Stage `files`, each path mapped to its text, a Gitlink, a Symlink, or
    None to delete it. Only these paths: a submodule has no work tree here, and
    `git add -A` would stage it as deleted."""
    for path, content in files.items():
        if content is None:
            git(repo, "rm", "-q", "--cached", path)
            if (repo / path).is_file():
                (repo / path).unlink()
        elif isinstance(content, Symlink):
            (repo / path).unlink(missing_ok=True)
            (repo / path).symlink_to(content)
            git(repo, "add", path)
        elif isinstance(content, Gitlink):
            git(
                repo, "update-index", "--add", "--cacheinfo", f"160000,{content},{path}"
            )
        else:
            (repo / path).parent.mkdir(parents=True, exist_ok=True)
            (repo / path).write_text(content)
            git(repo, "add", path)


def pr_checkout(root, base_files, pr_files):
    """A PR checkout as actions/checkout leaves it for a pull_request run (a
    detached merge commit, remote refs only). The base commit holds
    `base_files`; the PR's commit changes them as `pr_files` says."""
    repo = root / "checkout"
    repo.mkdir(parents=True)
    git(repo, "init", "-q", "-b", "main")
    stage(repo, base_files)
    git(repo, "commit", "-qm", "base")
    base = git(repo, "rev-parse", "HEAD")
    git(repo, "switch", "-qc", "pr")
    stage(repo, pr_files)
    git(repo, "commit", "-qm", "pr")
    head = git(repo, "rev-parse", "HEAD")
    origin = root / "origin.git"
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
def checkout(tmp_path):
    """The PR moves OLD to NEW and edits it."""
    return pr_checkout(tmp_path, {OLD: SOURCE}, {OLD: None, NEW: SOURCE + "# moved\n"})


@pytest.fixture
def submodule_bump(tmp_path):
    """The PR moves the submodule at LINK to another commit and sets
    `ignore = all` for it."""
    return pr_checkout(
        tmp_path,
        {".gitmodules": gitmodules(LINK), LINK: Gitlink(BEFORE)},
        {".gitmodules": gitmodules(LINK, "ignore = all"), LINK: Gitlink(AFTER)},
    )


@pytest.fixture
def submodule_move(tmp_path):
    """The PR moves the submodule from LINK to MOVED_LINK and sets
    `ignore = all` for it there."""
    return pr_checkout(
        tmp_path,
        {".gitmodules": gitmodules(LINK), LINK: Gitlink(BEFORE)},
        {
            ".gitmodules": gitmodules(MOVED_LINK, "ignore = all"),
            LINK: None,
            MOVED_LINK: Gitlink(BEFORE),
        },
    )


@pytest.fixture
def move_into_existing(tmp_path):
    """The PR deletes OLD and moves its functions, unchanged, into EXISTING."""
    return pr_checkout(
        tmp_path,
        {OLD: "".join(FUNCTIONS), EXISTING: EXISTING_SOURCE},
        {OLD: None, EXISTING: EXISTING_SOURCE + "".join(FUNCTIONS)},
    )


@pytest.fixture
def rewrite_move(tmp_path):
    """The PR moves OLD to NEW and rewrites eight of its ten functions."""
    return pr_checkout(
        tmp_path,
        {OLD: "".join(FUNCTIONS)},
        {OLD: None, NEW: "".join(FUNCTIONS[:2] + REWRITTEN[2:])},
    )


@pytest.fixture
def full_rewrite(tmp_path):
    """The PR deletes OLD and adds NEW, which keeps none of its lines."""
    return pr_checkout(
        tmp_path, {OLD: "".join(FUNCTIONS)}, {OLD: None, NEW: "".join(REWRITTEN)}
    )


@pytest.fixture
def kept_extraction(tmp_path):
    """The PR moves eight of OLD's ten functions, unchanged, into EXISTING and
    keeps OLD with the other two. Its own directory, so a test can use it
    beside another checkout."""
    return pr_checkout(
        tmp_path / "kept-extraction",
        {OLD: "".join(FUNCTIONS), EXISTING: EXISTING_SOURCE},
        {
            OLD: "".join(FUNCTIONS[:2]),
            EXISTING: EXISTING_SOURCE + "".join(FUNCTIONS[2:]),
        },
    )


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


def scratch(repo):
    """The job's scratch directory (VERIFIER_SCRATCH), outside the checkout."""
    directory = repo.parent / "scratch"
    directory.mkdir(exist_ok=True)
    return directory


def run_step(checkout, script):
    """Run `script` as the diff step; return changed-paths.txt's lines and
    what the step wrote to $GITHUB_OUTPUT."""
    repo, event = checkout
    document, step = diff_step()
    assert "${{" not in script, "the runner would substitute into this script"
    environment = {
        **git_environment(),
        **step_environment(document, step, event),
        "VERIFIER_SCRATCH": str(scratch(repo)),
    }
    output = bash(script, repo, environment)
    return (scratch(repo) / "changed-paths.txt").read_text().splitlines(), output


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
            str(scratch(repo) / "changed-paths.txt"),
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


def test_diff_step_lists_a_submodule_its_gitmodules_ignores(submodule_bump, patterns):
    _, step = diff_step()
    listed, output = run_step(submodule_bump, step["run"])
    assert sorted(listed) == [".gitmodules", LINK], (
        f"the classifier would never see {LINK}: {listed}"
    )
    assert output == "changed_count=2\n"
    rc, matches = classify(submodule_bump[0], patterns)
    matched = [line.split("\t")[0] for line in matches.splitlines()]
    # .gitmodules matches too: the central list gates it (2026-09-28).
    assert rc == 0 and sorted(matched) == [".gitmodules", LINK], matches


def test_without_the_flag_the_prs_gitmodules_hides_the_submodule(
    submodule_bump, patterns
):
    # Negative control: the step without --ignore-submodules=none, as it
    # shipped before. The PR's `ignore = all` leaves the submodule out, so the
    # classifier never sees it.
    _, step = diff_step()
    pre_fix, count = re.subn(
        r"(?m)^(\s*git\b[^\n]*?) --ignore-submodules=none\b", r"\1", step["run"]
    )
    assert count == 1, "expected one `git ... --ignore-submodules=none` line"
    listed, output = run_step(submodule_bump, pre_fix)
    assert listed == [".gitmodules"]
    assert output == "changed_count=1\n"
    _, matches = classify(submodule_bump[0], patterns)
    assert LINK not in matches


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


def render_prompt(checkout, *matched, script=None):
    """The verifier prompt as its shipped step, or `script`, renders it when
    the classifier matched `matched`, in that order: in the PR checkout, as on
    the runner, since the step runs git there, with the matches in the job's
    scratch directory."""
    repo, event = checkout
    document, step = find_step("prompt")
    (scratch(repo) / "matches.txt").write_text(
        "".join(f"{path}\t(matched: fixture)\n" for path in matched)
    )
    environment = {
        **git_environment(),
        **step_environment(document, step, event),
        "VERIFIER_SCRATCH": str(scratch(repo)),
    }
    return bash(script or step["run"], repo, environment)


# What tells apart the other commands the prompt hands the model.
COMMAND_MARKERS = {
    "renames": lambda command: "--diff-filter=R" in command,
    "pair": lambda command: "<old> <new>" in command,
    "changed": lambda command: (
        "--name-status" in command and "--diff-filter" not in command
    ),
}


def prompt_command(prompt, kind):
    """The prompt's one command of `kind`: the per-file diff, the rename
    listing, the paired diff, or the changed-paths listing."""
    if kind == "per_file":
        found = re.findall(r"Read the diff for that file via Bash: `([^`]+)`", prompt)
    else:
        found = [
            command
            for command in re.findall(r"`(git diff [^`]*)`", prompt)
            if COMMAND_MARKERS[kind](command)
        ]
    assert len(found) == 1, f"expected one {kind} command in the prompt: {found}"
    return found[0]


def without_flag(command):
    """`command` without --ignore-submodules=none."""
    stripped, count = re.subn(r" --ignore-submodules=none\b", "", command)
    assert count == 1, command
    return stripped


def test_verifier_prompt_leads_the_model_to_both_paths_of_a_rename(checkout):
    # The classifier matches only OLD, and the prompt's per-file diff of OLD
    # shows a deletion: the edited file at NEW never appears in it. The prompt
    # must hand the model commands that find the rename and show both paths.
    repo, _ = checkout
    prompt = render_prompt(checkout, OLD)
    per_file = prompt_command(prompt, "per_file")
    alone = model_git(repo, per_file.replace("<file>", OLD))
    assert "deleted file mode" in alone and "+# moved" not in alone, alone

    listing = prompt_command(prompt, "renames")
    pair = rf"^R\d+\t{re.escape(OLD)}\t{re.escape(NEW)}$"
    assert re.search(pair, model_git(repo, listing), re.M), listing
    paired = prompt_command(prompt, "pair")
    shown = model_git(repo, paired.replace("<old>", OLD).replace("<new>", NEW))
    assert f"rename from {OLD}" in shown and f"rename to {NEW}" in shown, shown
    assert "+# moved" in shown, shown


def test_verifier_prompt_shows_a_submodule_its_gitmodules_ignores(submodule_bump):
    repo, _ = submodule_bump
    per_file = prompt_command(render_prompt(submodule_bump, LINK), "per_file")
    shown = model_git(repo, per_file.replace("<file>", LINK))
    assert f"-Subproject commit {BEFORE}\n+Subproject commit {AFTER}\n" in shown, shown
    # Negative control: without the flag the model reads an empty diff.
    assert model_git(repo, without_flag(per_file).replace("<file>", LINK)) == ""


def test_verifier_prompt_follows_a_submodule_the_pr_moves(submodule_move):
    # The classifier matches LINK, which the PR deletes: its .gitmodules maps
    # only MOVED_LINK, so nothing hides that half. The commands that find
    # where the submodule went must not hide the other half.
    repo, _ = submodule_move
    prompt = render_prompt(submodule_move, LINK)
    renames = prompt_command(prompt, "renames")
    pair = prompt_command(prompt, "pair")
    pair = pair.replace("<old>", LINK).replace("<new>", MOVED_LINK)
    changed = prompt_command(prompt, "changed")
    assert model_git(repo, renames) == f"R100\t{LINK}\t{MOVED_LINK}\n"
    shown = model_git(repo, pair)
    assert f"rename from {LINK}\nrename to {MOVED_LINK}\n" in shown, shown
    assert model_git(repo, changed) == f"M\t.gitmodules\nD\t{LINK}\nA\t{MOVED_LINK}\n"
    # Negative controls: without the flag, none of them names MOVED_LINK.
    for command in (renames, pair, changed):
        assert MOVED_LINK not in model_git(repo, without_flag(command)), command


def test_verifier_prompt_pairs_a_move_that_rewrites_most_of_the_file(rewrite_move):
    # Two of ten functions kept: git scores the pair 21% similar.
    repo, _ = rewrite_move
    prompt = render_prompt(rewrite_move, OLD)
    renames = prompt_command(prompt, "renames")
    assert model_git(repo, renames) == f"R021\t{OLD}\t{NEW}\n"
    paired = prompt_command(prompt, "pair")
    shown = model_git(repo, paired.replace("<old>", OLD).replace("<new>", NEW))
    assert f"rename from {OLD}\nrename to {NEW}\n" in shown, shown
    assert "+def allow_9(claim):\n" in shown, shown
    # Negative control: the listing at git's default 50%, as it shipped
    # before, does not list the move.
    default, count = re.subn(r"--find-renames=\S+", "--find-renames", renames)
    assert count == 1, renames
    assert model_git(repo, default) == ""


def test_verifier_prompt_lists_what_the_pr_changes_for_a_matched_file_it_removes(
    full_rewrite,
):
    # A move that kept none of the file pairs at no threshold the listing
    # uses: the per-file diff shows a deletion and the rename listing is
    # empty, so neither names NEW. The changed-paths listing does.
    repo, _ = full_rewrite
    prompt = render_prompt(full_rewrite, OLD)
    alone = model_git(repo, prompt_command(prompt, "per_file").replace("<file>", OLD))
    assert "deleted file mode" in alone and NEW not in alone, alone
    assert model_git(repo, prompt_command(prompt, "renames")) == ""
    assert model_git(repo, prompt_command(prompt, "changed")) == f"D\t{OLD}\nA\t{NEW}\n"


def test_verifier_prompt_finds_code_moved_into_a_file_that_already_existed(
    move_into_existing,
):
    # git pairs a removed file only with an added one, so code moved into a
    # file the base already has is no rename, however much of it matches.
    repo, _ = move_into_existing
    prompt = render_prompt(move_into_existing, OLD)
    alone = model_git(repo, prompt_command(prompt, "per_file").replace("<file>", OLD))
    assert "deleted file mode" in alone and EXISTING not in alone, alone
    assert model_git(repo, prompt_command(prompt, "renames")) == ""
    changed = prompt_command(prompt, "changed")
    assert model_git(repo, changed) == f"D\t{OLD}\nM\t{EXISTING}\n"
    # Negative control: the listing limited to added files names nothing.
    added_only, count = re.subn(
        r"--name-status\b", "--name-status --diff-filter=A", changed
    )
    assert count == 1, changed
    assert model_git(repo, added_only) == ""


def kept_note(prompt):
    """What the prompt says between step 1's changed-paths instruction and step
    2: the note on matched files the PR keeps but deletes lines from, or
    nothing, as before the note existed."""
    found = re.search(
        r"and verify any that its code moved to\.\n(.*?)^  2\. Identify",
        prompt,
        re.S | re.M,
    )
    assert found, "step 1 no longer ends where this test looks for the note"
    return found.group(1)


def note_naming(*paths):
    """The note, as the prompt must word it, naming `paths`."""
    return (
        "     The PR also deletes lines from these matched files, which it\n"
        "     keeps. Code can move out of a file that stays, so for them as\n"
        "     well, list every path the PR changes with that command and\n"
        "     verify any that their deleted lines moved to:\n"
    ) + "".join(f"       {path}\n" for path in paths)


def test_verifier_prompt_follows_code_moved_out_of_a_matched_file_it_keeps(
    kept_extraction,
):
    # OLD stays, so its per-file diff shows only deletions and no rename
    # pairs it; step 1 sends the model to the changed-paths listing only for a
    # matched file the PR removes. The note must name OLD and point at that
    # listing, which names EXISTING.
    repo, _ = kept_extraction
    prompt = render_prompt(kept_extraction, OLD)
    assert kept_note(prompt) == note_naming(OLD), prompt
    changed = prompt_command(prompt, "changed")
    # "that command": the note follows the changed-paths listing directly.
    assert (
        f"`{changed}`\n     and verify any that its code moved to.\n     The PR"
        in prompt
    )
    alone = model_git(repo, prompt_command(prompt, "per_file").replace("<file>", OLD))
    assert "deleted file mode" not in alone and "-def check_9(token):\n" in alone, alone
    assert EXISTING not in alone, alone
    assert model_git(repo, prompt_command(prompt, "renames")) == ""
    assert model_git(repo, changed) == f"M\t{OLD}\nM\t{EXISTING}\n"


@pytest.mark.parametrize(
    ("attributes", "plain_numstat"),
    [({}, f"3\t0\t{OLD}\n"), ({".gitattributes": f"{OLD} binary\n"}, f"-\t-\t{OLD}\n")],
    ids=["plain", "marked-binary-by-the-pr"],
)
def test_verifier_prompt_is_unchanged_for_a_kept_matched_file_that_only_gains_lines(
    tmp_path, kept_extraction, attributes, plain_numstat
):
    # OLD gains a function and loses nothing, so step 1 runs straight into
    # step 2. In the second shape the PR's own .gitattributes marks OLD
    # binary: plain git honours it (control), numstat reads "-", and only the
    # base's attributes keep that from counting as deleted lines.
    checkout = pr_checkout(
        tmp_path, {OLD: SOURCE}, {OLD: SOURCE + FUNCTIONS[5], **attributes}
    )
    numstat = f"git diff --numstat origin/main...HEAD -- {OLD}"
    assert model_git(checkout[0], numstat) == plain_numstat
    assert kept_note(render_prompt(checkout, OLD)) == ""
    # Positive control: the same probe finds the note for a file losing lines.
    assert kept_note(render_prompt(kept_extraction, OLD)) == note_naming(OLD)


def test_verifier_prompt_leaves_a_matched_file_the_pr_removes_as_it_was(
    move_into_existing, kept_extraction
):
    # OLD loses every line (control), but the PR removes it: step 1 already
    # sends the model to the changed-paths listing for it, so no note.
    repo, _ = move_into_existing
    numstat = f"git diff --no-renames --numstat origin/main...HEAD -- {OLD}"
    assert model_git(repo, numstat) == f"0\t30\t{OLD}\n"
    prompt = render_prompt(move_into_existing, OLD)
    assert kept_note(prompt) == ""
    changed = prompt_command(prompt, "changed")
    assert model_git(repo, changed) == f"D\t{OLD}\nM\t{EXISTING}\n"
    # Positive control: the same probe finds the note for a file the PR keeps.
    assert kept_note(render_prompt(kept_extraction, OLD)) == note_naming(OLD)


def test_without_the_flag_the_prs_gitmodules_hides_a_kept_submodules_deleted_line(
    submodule_bump,
):
    # The PR keeps LINK and moves it to another commit, deleting the old
    # commit line, so the note names LINK.
    assert kept_note(render_prompt(submodule_bump, LINK)) == note_naming(LINK)
    # Negative control: the step without --ignore-submodules=none on the
    # numstat that picks the files. The PR's `ignore = all` hides the change.
    _, step = find_step("prompt")
    (numstat,) = [line for line in step["run"].splitlines() if "--numstat" in line]
    unflagged = step["run"].replace(numstat, without_flag(numstat))
    assert kept_note(render_prompt(submodule_bump, LINK, script=unflagged)) == ""


def test_verifier_prompt_leaves_out_a_binary_file_the_pr_adds(tmp_path):
    # git cannot count a binary file's lines: numstat prints "-", which counts
    # as deleted lines for a file the PR keeps. A file the PR adds lost
    # nothing, so it gets no note.
    key = "src/auth/signing.key"
    added = pr_checkout(tmp_path / "added", {OLD: SOURCE}, {key: "\x00key-1\n"})
    numstat = f"git diff --numstat origin/main...HEAD -- {key}"
    assert model_git(added[0], numstat) == f"-\t-\t{key}\n"
    assert kept_note(render_prompt(added, key)) == ""
    # Positive control: the same file, kept and changed, gets the note.
    kept = pr_checkout(tmp_path / "kept", {key: "\x00key-1\n"}, {key: "\x00key-2\n"})
    assert model_git(kept[0], numstat) == f"-\t-\t{key}\n"
    assert kept_note(render_prompt(kept, key)) == note_naming(key)


def test_verifier_prompt_names_every_kept_file_losing_lines_in_matched_order(
    tmp_path,
):
    # Four matched files, in the classifier's order: two the PR keeps but
    # deletes lines from, one it only adds to, one it removes.
    login, policy, tokens = (
        "src/auth/login.py",
        "src/auth/policy.py",
        "src/auth/tokens.py",
    )
    checkout = pr_checkout(
        tmp_path,
        {login: SOURCE, policy: SOURCE, OLD: "".join(FUNCTIONS), tokens: SOURCE},
        {
            login: "".join(FUNCTIONS[:4]),
            policy: SOURCE + FUNCTIONS[5],
            OLD: "".join(FUNCTIONS[:2]),
            tokens: None,
            EXISTING: "".join(FUNCTIONS[2:]),
        },
    )
    prompt = render_prompt(checkout, login, policy, OLD, tokens)
    assert kept_note(prompt) == note_naming(login, OLD)


def test_verifier_prompt_names_a_matched_file_that_becomes_a_symlink(tmp_path):
    # A type change (status T) keeps the path but not the file's lines.
    checkout = pr_checkout(
        tmp_path,
        {OLD: "".join(FUNCTIONS), EXISTING: EXISTING_SOURCE},
        {OLD: Symlink("../misc/utils.py")},
    )
    changed = f"git diff --no-renames --name-status origin/main...HEAD -- {OLD}"
    assert model_git(checkout[0], changed) == f"T\t{OLD}\n"
    assert kept_note(render_prompt(checkout, OLD)) == note_naming(OLD)


@pytest.mark.parametrize(
    ("base_ref", "matched"),
    [("gone", OLD), ("main", "src/auth/*.py")],
    ids=["base-ref-missing", "matched-path-outside-the-alphabet"],
)
def test_verifier_prompt_step_fails_before_writing_a_prompt(
    kept_extraction, base_ref, matched
):
    # Never a prompt without the note it needs: a numstat that cannot run, or
    # a matched path git would read as a pattern, fails the step first.
    repo, event = kept_extraction
    document, step = find_step("prompt")
    (scratch(repo) / "matches.txt").write_text(f"{matched}\t(matched: fixture)\n")
    event = {**event, "github.event.pull_request.base.ref": base_ref}
    output = repo.parent / "github-output"
    result = subprocess.run(
        ["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", step["run"]],
        cwd=repo,
        env={
            **git_environment(),
            **step_environment(document, step, event),
            "VERIFIER_SCRATCH": str(scratch(repo)),
            "GITHUB_OUTPUT": str(output),
        },
        capture_output=True,
        text=True,
    )
    assert result.returncode != 0, result.stdout
    assert not output.exists()


def test_verifier_prompt_step_fails_when_it_cannot_reread_the_matches(
    kept_extraction, tmp_path
):
    # The step reads the matches whole for the prompt, then record by record
    # for the note. A `cat` that removes the file after printing it leaves the
    # second read nothing to open: the step must fail, not drop the note.
    repo, event = kept_extraction
    document, step = find_step("prompt")
    (scratch(repo) / "matches.txt").write_text(f"{OLD}\t(matched: fixture)\n")
    shim = tmp_path / "shim" / "cat"
    shim.parent.mkdir()
    shim.write_text(
        "#!/bin/sh\n"
        f'{shutil.which("cat")} "$@" || exit\n'
        'for f; do case $f in */matches.txt) rm -f "$f" ;; esac; done\n'
    )
    shim.chmod(0o755)
    output = repo.parent / "github-output"
    environment = {
        **git_environment(),
        **step_environment(document, step, event),
        "VERIFIER_SCRATCH": str(scratch(repo)),
        "GITHUB_OUTPUT": str(output),
    }
    environment["PATH"] = f"{shim.parent}{os.pathsep}{environment['PATH']}"
    result = subprocess.run(
        ["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", step["run"]],
        cwd=repo,
        env=environment,
        capture_output=True,
        text=True,
    )
    assert result.returncode != 0, result.stdout
    assert "matches.txt" in result.stderr, result.stderr
    assert not output.exists()
