"""Exercise the workflow's actual local-context step with committed Git fixtures."""

import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/claude-review.yml"


class ReviewContextTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.repo = self.directory / "repository"
        self.repo.mkdir()
        self.output = self.directory / "github-output"
        self.document = yaml.safe_load(WORKFLOW.read_text())
        self.step = next(
            s
            for s in self.document["jobs"]["review"]["steps"]
            if s.get("id") == "review_context"
        )
        self.git("init", "-q")
        (self.repo / "source.txt").write_text("before\n")
        self.git("add", ".")
        self.git("commit", "-qm", "base")
        self.base = self.git("rev-parse", "HEAD").strip()
        (self.repo / "source.txt").write_text("committed after\n")
        self.git("add", ".")
        self.git("commit", "-qm", "head")
        self.head = self.git("rev-parse", "HEAD").strip()

    def git(self, *arguments):
        return subprocess.check_output(
            [
                "git",
                "-c",
                "core.hooksPath=/dev/null",
                "-c",
                "commit.gpgsign=false",
                "-c",
                "user.name=Fixture",
                "-c",
                "user.email=fixture@example.test",
                *arguments,
            ],
            cwd=self.repo,
            text=True,
        )

    def run_step(self, base=None, head=None, script=None):
        environment = dict(
            os.environ,
            BASE_SHA=base or self.base,
            HEAD_SHA=head or self.head,
            GITHUB_WORKSPACE=str(self.repo),
            GITHUB_OUTPUT=str(self.output),
        )
        return subprocess.run(
            ["bash", "-c", script or self.step["run"]],
            cwd=self.repo,
            env=environment,
            capture_output=True,
            text=True,
        )

    def context(self):
        field, value = self.output.read_text().strip().split("=", 1)
        self.assertEqual(field, "directory")
        result = Path(value)
        self.assertEqual(result.parent, self.repo)
        self.assertFalse(result.is_symlink())
        return result

    def test_context_is_required_before_the_review_and_used_by_its_prompt(self):
        steps = self.document["jobs"]["review"]["steps"]
        review = next(
            s
            for s in steps
            if s.get("uses", "").startswith("anthropics/claude-code-action@")
        )
        self.assertLess(steps.index(self.step), steps.index(review))
        self.assertNotIn("continue-on-error", self.step)
        self.assertEqual(
            self.step["if"],
            "${{ steps.bot_check.outputs.skipped != 'true' && github.event.pull_request.number }}",
        )
        self.assertEqual(
            self.step["env"],
            {
                "BASE_SHA": "${{ github.event.pull_request.base.sha }}",
                "HEAD_SHA": "${{ github.event.pull_request.head.sha }}",
            },
        )
        prompt = review["with"]["prompt"]
        self.assertIn("${{ steps.review_context.outputs.directory }}", prompt)
        for artifact in ("source.txt", "files.tsv", "index.tsv", "diff.patch"):
            self.assertIn(artifact, prompt)

    def test_large_diff_and_more_than_100_files_are_complete(self):
        for number in range(101):
            (self.repo / f"file-{number}.txt").write_text(f"{number}\n")
        (self.repo / "large.txt").write_text("line\n" * 22000)
        self.git("add", ".")
        self.git("commit", "-qm", "large change")
        self.head = self.git("rev-parse", "HEAD").strip()
        (self.repo / "source.txt").write_text("uncommitted content must not leak\n")
        (self.repo / "untracked.txt").write_text("not PR content\n")
        result = self.run_step()
        self.assertEqual(result.returncode, 0, result.stderr)
        context = self.context()
        expected = self.git(
            f"--attr-source={self.base}",
            "--no-pager",
            "diff",
            "--no-ext-diff",
            "--no-textconv",
            "--no-renames",
            "--full-index",
            f"{self.base}...{self.head}",
            "--",
        )
        patch = (context / "diff.patch").read_text()
        self.assertEqual(patch, expected)
        self.assertGreater(len(patch.splitlines()), 20000)
        self.assertEqual(len((context / "files.tsv").read_text().splitlines()), 103)
        self.assertEqual(len((context / "index.tsv").read_text().splitlines()), 103)
        self.assertNotIn("uncommitted content must not leak", patch)
        self.assertNotIn("not PR content", patch)
        self.assertIn(self.base, (context / "source.txt").read_text())
        self.assertIn(self.head, (context / "source.txt").read_text())

    def test_invalid_identity_fails_before_publishing_context(self):
        result = self.run_step(base="main; echo invalid")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.output.exists())

    def test_unavailable_commit_fails_without_publishing_context(self):
        result = self.run_step(head="1" * 40)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.output.exists())

    def test_files_the_prs_attributes_mark_binary_reach_the_review(self):
        # The PR's own .gitattributes decides what plain `git diff` prints:
        # `-diff` on a path (here also on the .gitattributes itself) and
        # `binary` in a subdirectory's file each reduce the content to
        # "Binary files ... differ".
        (self.repo / ".gitattributes").write_text(".gitattributes -diff\n*.cfg -diff\n")
        (self.repo / "settings.cfg").write_text("setting_marker = 1\n")
        (self.repo / "conf").mkdir()
        (self.repo / "conf" / ".gitattributes").write_text("* binary\n")
        (self.repo / "conf" / "app.txt").write_text("nested_marker = 2\n")
        self.git("add", ".")
        self.git("commit", "-qm", "attributes that hide files")
        self.head = self.git("rev-parse", "HEAD").strip()
        # Control: git honouring the PR's attributes keeps these paths out.
        plain = self.git(
            "--no-pager",
            "diff",
            "--no-ext-diff",
            "--no-textconv",
            f"{self.base}...{self.head}",
            "--",
        )
        self.assertIn("Binary files", plain)
        self.assertNotIn("setting_marker", plain)
        result = self.run_step()
        self.assertEqual(result.returncode, 0, result.stderr)
        context = self.context()
        patch = (context / "diff.patch").read_text()
        self.assertNotIn("Binary files", patch)
        for line in (
            "setting_marker = 1",
            "nested_marker = 2",
            "*.cfg -diff",
            "* binary",
        ):
            self.assertIn(line, patch)
        for row in (context / "files.tsv").read_text().splitlines():
            added, deleted, _path = row.split("\t", 2)
            self.assertTrue(added.isdigit() and deleted.isdigit(), row)

    def test_the_bases_own_attributes_still_apply(self):
        # What the base already declares keeps working: its `-diff` on
        # lockfiles still keeps their churn out of the review, while a
        # `-diff` the PR adds for its own file does nothing.
        (self.repo / ".gitattributes").write_text("*.lock -diff\n")
        (self.repo / "deps.lock").write_text("lock_marker = 1\n")
        self.git("add", ".")
        self.git("commit", "-qm", "base declares lockfiles -diff")
        self.base = self.git("rev-parse", "HEAD").strip()
        (self.repo / "deps.lock").write_text("lock_marker = 2\n")
        with (self.repo / ".gitattributes").open("a") as attributes:
            attributes.write("*.cfg -diff\n")
        (self.repo / "settings.cfg").write_text("setting_marker = 1\n")
        self.git("add", ".")
        self.git("commit", "-qm", "PR edits a lockfile and hides its own file")
        self.head = self.git("rev-parse", "HEAD").strip()
        result = self.run_step()
        self.assertEqual(result.returncode, 0, result.stderr)
        context = self.context()
        patch = (context / "diff.patch").read_text()
        self.assertIn("Binary files a/deps.lock and b/deps.lock differ", patch)
        self.assertNotIn("lock_marker", patch)
        self.assertIn("setting_marker = 1", patch)
        self.assertIn("+*.cfg -diff", patch)
        rows = {
            row.split("\t", 2)[2]: row.split("\t", 2)[:2]
            for row in (context / "files.tsv").read_text().splitlines()
        }
        self.assertEqual(rows["deps.lock"], ["-", "-"])
        self.assertEqual(rows["settings.cfg"], ["1", "0"])

    def commit_submodule_bump(self):
        # git applies a submodule's `ignore` setting from the checkout's
        # .gitmodules, the PR's own copy, to a diff between two commits too.
        # Here the PR moves a submodule to another commit and sets
        # `ignore = all` for it.
        section = (
            '[submodule "lib"]\n'
            "\tpath = vendor/lib\n"
            "\turl = https://example.test/lib.git\n"
        )
        (self.repo / ".gitmodules").write_text(section)
        self.git("add", ".gitmodules")
        self.git(
            "update-index", "--add", "--cacheinfo", f"160000,{'1' * 40},vendor/lib"
        )
        self.git("commit", "-qm", "base has a submodule")
        self.base = self.git("rev-parse", "HEAD").strip()
        (self.repo / ".gitmodules").write_text(section + "\tignore = all\n")
        self.git("add", ".gitmodules")
        self.git("update-index", "--cacheinfo", f"160000,{'2' * 40},vendor/lib")
        self.git("commit", "-qm", "PR moves it and sets ignore = all")
        self.head = self.git("rev-parse", "HEAD").strip()

    def test_a_submodule_the_prs_gitmodules_ignores_reaches_the_review(self):
        self.commit_submodule_bump()
        result = self.run_step()
        self.assertEqual(result.returncode, 0, result.stderr)
        context = self.context()
        self.assertIn(
            f"-Subproject commit {'1' * 40}\n+Subproject commit {'2' * 40}\n",
            (context / "diff.patch").read_text(),
        )
        self.assertEqual(
            (context / "files.tsv").read_text(),
            "1\t0\t.gitmodules\n1\t1\tvendor/lib\n",
        )
        self.assertIn(
            "\tdiff --git a/vendor/lib b/vendor/lib\n",
            (context / "index.tsv").read_text(),
        )

    def test_without_the_flag_the_prs_gitmodules_hides_the_submodule(self):
        # Negative control: both diff commands without --ignore-submodules=none.
        self.commit_submodule_bump()
        script, count = re.subn(
            r"(?m)^(\s*git\b[^\n]*?) --ignore-submodules=none\b",
            r"\1",
            self.step["run"],
        )
        self.assertEqual(count, 2)
        result = self.run_step(script=script)
        self.assertEqual(result.returncode, 0, result.stderr)
        context = self.context()
        patch = (context / "diff.patch").read_text()
        self.assertNotIn("diff --git a/vendor/lib", patch)
        self.assertNotIn("Subproject commit", patch)
        self.assertEqual((context / "files.tsv").read_text(), "1\t0\t.gitmodules\n")

    def test_both_diff_commands_read_attributes_from_the_base(self):
        # Joined continuation lines: one entry per shell command.
        commands = self.step["run"].replace("\\\n", " ").splitlines()
        patch = [c for c in commands if 'diff.patch"' in c and " diff " in c]
        numstat = [c for c in commands if "files.tsv" in c and " diff " in c]
        self.assertEqual(len(patch), 1)
        self.assertEqual(len(numstat), 1)
        for command in patch + numstat:
            self.assertIn('git --attr-source="$BASE_SHA" --no-pager diff', command)
        # No --text: real binaries keep their one-line summary, so the patch
        # stays bounded by the PR's text however large its binaries are.
        self.assertNotIn("--text", patch[0])

    def test_repository_diff_programs_are_not_executed(self):
        marker = self.directory / "unexpected-execution"
        program = self.directory / "diff-program.sh"
        program.write_text(f'#!/bin/sh\ntouch "{marker}"\n')
        program.chmod(0o755)
        self.git("config", "diff.external", str(program))
        self.git("config", "diff.custom.textconv", str(program))
        (self.repo / ".gitattributes").write_text("*.txt diff=custom\n")
        self.git("add", ".")
        self.git("commit", "-qm", "attributes")
        self.head = self.git("rev-parse", "HEAD").strip()
        result = self.run_step()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(marker.exists())
        self.assertIn("committed after", (self.context() / "diff.patch").read_text())


if __name__ == "__main__":
    unittest.main()
