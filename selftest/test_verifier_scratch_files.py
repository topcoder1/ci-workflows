"""The high-risk verifier keeps its own files out of the PR checkout, and only
the classifier's clean "no match" lets it skip.

verifier-on-high-risk.yml's diff and classify steps write the changed-path
list the classifier reads and the matches it writes. The PR decides what is
on disk in its own checkout, so the job keeps these files in a directory it
makes under RUNNER_TEMP. The classify step reads the classifier's exit 1 as
"no high-risk path matched" and skips the verifier; any other failure,
including an output the step cannot write, must fail the job instead.

1. A PR that changes a high-risk path and also commits entries at those
   files' names in the checkout: the shipped steps still match the path.
2. Controls: without those entries the path matches, and a PR changing no
   high-risk path is still a clean no-match, with the steps' outputs as they
   were.
3. An output the classify step cannot write fails the step.
4. The classifier exits 2, never 1, when it cannot write a match, when a
   pattern is not a valid regex, and when the patterns file holds none.
"""

import os
import shutil
import subprocess
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "verifier-on-high-risk.yml"
GLOBS_ACTION = ROOT / ".github" / "actions" / "extract-high-risk-globs"
CLASSIFIER = ROOT / "scripts" / "verifier-classify-diff.sh"

HIGH_RISK = "src/auth/session.py"  # matches the central high-risk list
LOW_RISK = "docs/notes.md"  # matches none of it
PATTERNS = "${{ steps.globs.outputs.patterns_file }}"


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
    return result.stdout.strip()


def link(target):
    """An entry that `plant` makes a symlink to `target`."""
    return ("link", target)


DIRECTORY = ("directory", None)


def plant(repo, entries):
    for name, (kind, target) in entries.items():
        if kind == "link":
            (repo / name).symlink_to(target)
        else:
            (repo / name).mkdir()
            (repo / name / "entry").write_text("entry\n")


def pr_checkout(root, changed, entries=None):
    """A PR checkout as actions/checkout leaves it for a pull_request run: a
    detached merge commit, remote refs only. The PR edits `changed` and
    commits `entries` at the repository root."""
    repo = root / "checkout"
    repo.mkdir(parents=True)
    git(repo, "init", "-q", "-b", "main")
    for path in (HIGH_RISK, LOW_RISK):
        (repo / path).parent.mkdir(parents=True, exist_ok=True)
        (repo / path).write_text("base\n")
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", "base")
    base = git(repo, "rev-parse", "HEAD")
    git(repo, "switch", "-qc", "pr")
    (repo / changed).write_text("base\nedited\n")
    plant(repo, entries or {})
    git(repo, "add", "-A")
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
    return repo, {
        "github.event.pull_request.base.sha": base,
        "github.event.pull_request.head.sha": head,
        "github.event.pull_request.base.ref": "main",
    }


@pytest.fixture
def patterns(tmp_path):
    """The central high-risk regexes, from the shipped extract action."""
    action = yaml.safe_load((GLOBS_ACTION / "action.yml").read_text())
    (step,) = action["runs"]["steps"]
    script = step["run"].replace("${{ github.action_path }}", str(GLOBS_ACTION))
    workdir = tmp_path / "globs"
    workdir.mkdir()
    output = workdir / "github-output"
    subprocess.run(
        ["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", script],
        cwd=workdir,
        env={**os.environ, "TMPDIR": str(workdir), "GITHUB_OUTPUT": str(output)},
        check=True,
        capture_output=True,
    )
    fields = dict(line.split("=", 1) for line in output.read_text().splitlines())
    return fields["patterns_file"]


class Job:
    """The verify job's steps up to the classifier, run as the runner would:
    in the PR checkout, each with its own $GITHUB_OUTPUT, and with what
    earlier steps wrote to $GITHUB_ENV."""

    def __init__(self, tmp_path, checkout, patterns):
        self.repo, self.event = checkout
        self.tmp = tmp_path
        self.patterns = patterns
        self.document = yaml.safe_load(WORKFLOW.read_text())
        self.steps = {
            step.get("id"): step for step in self.document["jobs"]["verify"]["steps"]
        }
        # The job's second checkout: this repository at the pinned SHA.
        (self.repo / "ci-workflows" / "scripts").mkdir(parents=True)
        shutil.copy(CLASSIFIER, self.repo / "ci-workflows" / "scripts")
        self.runner_temp = tmp_path / "runner-temp"
        self.runner_temp.mkdir()
        self.github_env = tmp_path / "github-env"
        self.github_env.write_text("")

    def exported(self):
        return dict(
            line.split("=", 1) for line in self.github_env.read_text().splitlines()
        )

    def run(self, step_id):
        """Run a step; return its exit status and what it wrote to
        $GITHUB_OUTPUT."""
        step = self.steps[step_id]
        script = step["run"].replace(PATTERNS, self.patterns)
        assert "${{" not in script, "an expression the fixture does not substitute"
        variables = {
            **(self.document["jobs"]["verify"].get("env") or {}),
            **(step.get("env") or {}),
        }
        for name, value in variables.items():
            for expression, fixture in self.event.items():
                value = str(value).replace("${{ " + expression + " }}", fixture)
            assert "${{" not in value, f"no fixture value for {name}"
            variables[name] = value
        output = self.tmp / f"{step_id}-github-output"
        result = subprocess.run(
            ["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", script],
            cwd=self.repo,
            env={
                **git_environment(),
                **self.exported(),
                **variables,
                "RUNNER_TEMP": str(self.runner_temp),
                "GITHUB_ENV": str(self.github_env),
                "GITHUB_OUTPUT": str(output),
            },
            capture_output=True,
            text=True,
        )
        return result.returncode, output.read_text() if output.exists() else ""

    def classify(self):
        """Run the steps through the classifier; return each one's result."""
        results = {}
        # The step that makes the scratch directory, where the job has one.
        for step_id in [i for i in ("scratch",) if i in self.steps] + [
            "diff",
            "classify",
        ]:
            results[step_id] = self.run(step_id)
            if results[step_id][0] != 0:
                break
        return results


ENTRIES = {
    "list-links-to-matches": {"changed-paths.txt": link("matches.txt")},
    "matches-links-to-list": {"matches.txt": link("changed-paths.txt")},
    "matches-is-a-directory": {"matches.txt": DIRECTORY},
}


@pytest.mark.parametrize("shape", sorted(ENTRIES))
def test_what_the_pr_commits_in_its_checkout_cannot_unmatch_a_high_risk_path(
    tmp_path, patterns, shape
):
    checkout = pr_checkout(tmp_path, HIGH_RISK, ENTRIES[shape])
    results = Job(tmp_path, checkout, patterns).classify()
    assert results["diff"] == (0, "changed_count=2\n"), results
    assert results["classify"] == (0, "matched=yes\n"), results


@pytest.mark.parametrize(
    ("changed", "verdict"),
    [(HIGH_RISK, "matched=yes\n"), (LOW_RISK, "matched=no\n")],
    ids=["high-risk", "low-risk"],
)
def test_without_those_entries_the_verdicts_are_unchanged(
    tmp_path, patterns, changed, verdict
):
    # Controls: a high-risk change matches and a low-risk one is still a
    # clean no-match, with the outputs the steps always wrote.
    results = Job(tmp_path, pr_checkout(tmp_path, changed), patterns).classify()
    assert results["diff"] == (0, "changed_count=1\n"), results
    assert results["classify"] == (0, verdict), results


def test_an_output_the_classify_step_cannot_write_fails_the_step(tmp_path, patterns):
    job = Job(tmp_path, pr_checkout(tmp_path, HIGH_RISK), patterns)
    assert job.run("scratch")[0] == 0
    assert job.run("diff")[0] == 0
    (Path(job.exported()["VERIFIER_SCRATCH"]) / "matches.txt").mkdir()
    status, output = job.run("classify")
    assert status != 0 and "matched=" not in output, (status, output)


def classifier(tmp_path, patterns, paths, stdout=None):
    (tmp_path / "patterns.txt").write_text(patterns)
    (tmp_path / "paths.txt").write_text(paths)
    return subprocess.run(
        ["bash", str(CLASSIFIER), "--patterns", "patterns.txt", "--paths", "paths.txt"],
        cwd=tmp_path,
        stdout=stdout if stdout is not None else subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


def test_the_classifier_exits_1_only_for_a_clean_no_match(tmp_path):
    # Controls: a match, and a clean no-match.
    matched = classifier(tmp_path, "^src/auth/\n", f"{LOW_RISK}\n{HIGH_RISK}\n")
    assert (matched.returncode, matched.stdout) == (
        0,
        f"{HIGH_RISK}\t(matched: ^src/auth/)\n",
    )
    assert classifier(tmp_path, "^src/auth/\n", f"{LOW_RISK}\n").returncode == 1


@pytest.mark.parametrize(
    ("patterns", "paths", "stdout"),
    [
        ("^src/auth/\n", f"{HIGH_RISK}\n", subprocess.DEVNULL),
        ("^src/(auth\n", f"{HIGH_RISK}\n", None),
        ("\n\n", f"{HIGH_RISK}\n", None),
    ],
    ids=["match-not-written", "invalid-pattern", "no-patterns"],
)
def test_the_classifier_exits_2_when_it_fails(tmp_path, patterns, paths, stdout):
    if stdout is subprocess.DEVNULL:
        # A match it cannot write: its standard output is closed.
        (tmp_path / "patterns.txt").write_text(patterns)
        (tmp_path / "paths.txt").write_text(paths)
        result = subprocess.run(
            [
                "bash",
                "-c",
                f'exec >&-; exec bash "{CLASSIFIER}" --patterns patterns.txt'
                " --paths paths.txt",
            ],
            cwd=tmp_path,
            capture_output=False,
            stderr=subprocess.PIPE,
            text=True,
        )
    else:
        result = classifier(tmp_path, patterns, paths)
    assert result.returncode == 2, result.stderr


def test_the_classifier_never_reads_a_failure_to_run_as_no_match(tmp_path):
    # With few file descriptors left, what the classifier needs before grep
    # can answer (a redirection, a pipe, a command substitution) fails. For a
    # path that matches, every run must report the match (exit 0) or fail
    # (exit 2, or bash's own abort): never exit 1, which skips the verifier.
    (tmp_path / "patterns.txt").write_text("^src/auth/\n")
    (tmp_path / "paths.txt").write_text(f"{LOW_RISK}\n{HIGH_RISK}\n")
    command = f'exec bash "{CLASSIFIER}" --patterns patterns.txt --paths paths.txt'
    seen = {}
    for limit in range(3, 25):
        result = subprocess.run(
            ["bash", "-c", f"ulimit -n {limit} && {command}"],
            cwd=tmp_path,
            capture_output=True,
            text=True,
        )
        seen[limit] = result.returncode
        if result.returncode == 0:
            assert result.stdout == f"{HIGH_RISK}\t(matched: ^src/auth/)\n", limit
        assert result.returncode != 1, (limit, result.stderr)
    # Control: the limits reach both a clean run and one that cannot finish.
    codes = set(seen.values())
    assert 0 in codes and codes - {0}, seen
