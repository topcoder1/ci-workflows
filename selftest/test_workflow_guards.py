"""Run the shell selftests under pytest.

tests-runner.yml's self-test path executes `uv run pytest -q` on this
repo's own PRs, so wrapping the .sh selftests here is what makes them
CI-enforced rather than run-manually-only documentation.
"""

import pathlib
import subprocess

import pytest

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent


# test_bb_automerge_risk_patterns.sh is deliberately absent: it resolves
# bb-automerge.py from the local ~/.claude/templates checkout and imports
# `requests`, neither of which exists on this repo's CI runner. Run it
# manually on a workstation.
@pytest.mark.parametrize(
    "script",
    [
        "selftest/test_automerge_risk_patterns.sh",
        "selftest/test_automerge_riskfile_gate.sh",
        "selftest/test_classify_bracket_guard.sh",
        "selftest/test_classify_nocase.sh",
        "selftest/test_pr_files_listing.sh",
        "selftest/test_prettier_symlink_filter.sh",
    ],
)
def test_shell_selftest(script):
    proc = subprocess.run(
        ["bash", script], cwd=REPO_ROOT, capture_output=True, text=True
    )
    assert proc.returncode == 0, f"{script} failed:\n{proc.stdout}\n{proc.stderr}"
