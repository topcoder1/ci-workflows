"""Exercise the workflow's actual local-context step with committed Git fixtures."""

import os
from pathlib import Path
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

    def run_step(self, base=None, head=None):
        environment = dict(
            os.environ,
            BASE_SHA=base or self.base,
            HEAD_SHA=head or self.head,
            GITHUB_WORKSPACE=str(self.repo),
            GITHUB_OUTPUT=str(self.output),
        )
        return subprocess.run(
            ["bash", "-c", self.step["run"]],
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
