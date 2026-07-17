"""Run the shell selftests under pytest.

tests-runner.yml's self-test path executes `uv run pytest -q` on this
repo's own PRs, so wrapping the .sh selftests here is what makes them
CI-enforced rather than run-manually-only documentation.
"""

import pathlib
import re
import subprocess

import pytest

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
WORKFLOWS_DIR = REPO_ROOT / ".github" / "workflows"


# test_bb_automerge_risk_patterns.sh is deliberately absent: it resolves
# bb-automerge.py from the local ~/.claude/templates checkout and imports
# `requests`, neither of which exists on this repo's CI runner. Run it
# manually on a workstation.
@pytest.mark.parametrize(
    "script",
    [
        "selftest/test_automerge_risk_patterns.sh",
        "selftest/test_classify_bracket_guard.sh",
        "selftest/test_classify_nocase.sh",
        "selftest/test_pr_files_listing.sh",
        "selftest/test_prettier_scope_failsafe.sh",
        "selftest/test_prettier_symlink_filter.sh",
    ],
)
def test_shell_selftest(script):
    proc = subprocess.run(
        ["bash", script], cwd=REPO_ROOT, capture_output=True, text=True
    )
    assert proc.returncode == 0, f"{script} failed:\n{proc.stdout}\n{proc.stderr}"


def test_no_global_git_config_writes_in_workflows():
    """No reusable may write to global git config.

    2026-07-16 (wxa-secrets#28 codex review): tests-runner.yml and
    coverage-floor.yml wrote AUTOMERGE_PAT into a global insteadOf rewrite
    before running PR-controlled code (uv sync build hooks, pytest) on
    pull_request events — any same-repo PR could read the cross-org PAT
    via `git config --global --get-regexp url` and exfiltrate it.
    Credentials must go into a scoped throwaway file (GIT_CONFIG_GLOBAL
    pointed at $RUNNER_TEMP) that is deleted before the default test
    invocation (the test_command override path scrubs afterward and accepts
    the wider window).
    """
    offenders = [
        wf.name
        for wf in sorted(WORKFLOWS_DIR.glob("*.yml"))
        if "git config --global" in wf.read_text()
    ]
    assert not offenders, (
        f"global git config writes in {offenders} — use a scoped "
        "GIT_CONFIG_GLOBAL temp file scrubbed before the default test run"
    )


@pytest.mark.parametrize("workflow", ["tests-runner.yml", "coverage-floor.yml"])
def test_scoped_git_credential_gated_and_scrubbed(workflow):
    """The cross-org git credential must be (a) opt-in on pull_request
    events, (b) written to a scoped file, and (c) deleted before the DEFAULT
    test invocation, which executes PR-controlled code and must not be able
    to re-resolve dependencies. (A caller `test_command` runs install+tests
    as one command and is scrubbed only afterward — the wider window is
    accepted for that path, so this guard only checks the default
    invocations.)"""
    text = (WORKFLOWS_DIR / workflow).read_text()

    # (a) The credential is ALLOWLIST-gated: auto-materialized only on a
    # push to the default branch (post-review code); every other event —
    # PRs, branch pushes, schedule, workflow_dispatch — needs the explicit
    # caller opt-in input. Denylist forms ("not a PR") regressed this once
    # (codex round-2 P1).
    assert "inputs.use_pat_for_git_deps" in text, workflow
    allowlist = (
        "github.event_name == 'push' && github.ref == "
        "format('refs/heads/{0}', github.event.repository.default_branch)"
    )
    assert allowlist in text, workflow

    # (b) The credential lives in a scoped throwaway file, not ~/.gitconfig,
    # and a least-privilege GIT_DEPS_PAT (fine-grained read-only) wins over
    # the fleet-wide AUTOMERGE_PAT when forwarded.
    assert 'CROSS_ORG_GITCONFIG="$RUNNER_TEMP/cross-org-gitconfig"' in text, workflow
    assert "secrets.GIT_DEPS_PAT || secrets.AUTOMERGE_PAT" in text, workflow

    # (c) Every install branch (test_command / uv / pip fallback) scrubs the
    # credential, and each test invocation is LOCALLY preceded by a scrub
    # with no install command in between. A global first-scrub-vs-last-
    # invocation comparison would still pass if one branch's scrub moved
    # below its own pytest (codex round-4 P2), so check per invocation.
    scrub = 'rm -f "$CROSS_ORG_GITCONFIG"; unset GIT_CONFIG_GLOBAL'
    assert text.count(scrub) >= 3, (
        f"{workflow}: every install branch must scrub the scoped credential "
        "(before the default test invocation; test_command scrubs afterward)"
    )
    invocations = {
        "tests-runner.yml": ["uv run --no-sync pytest -q", ".venv/bin/pytest -q"],
        "coverage-floor.yml": [
            "uv run --no-sync pytest --cov",
            ".venv/bin/pytest --cov",
        ],
    }[workflow]
    install_markers = ("uv sync", "pip install", 'eval "$INPUT_TEST_COMMAND"')
    for marker in invocations:
        # Line-anchored so header/comment mentions of the command don't
        # count as invocations.
        sites = [
            m.start()
            for m in re.finditer(rf"^\s*{re.escape(marker)}", text, flags=re.M)
        ]
        assert sites, f"{workflow}: expected test invocation {marker!r} not found"
        for pos in sites:
            last_scrub = text.rfind(scrub, 0, pos)
            assert last_scrub != -1, (
                f"{workflow}: no credential scrub precedes {marker!r}"
            )
            last_install = max(text.rfind(i, 0, pos) for i in install_markers)
            assert last_scrub > last_install, (
                f"{workflow}: an install command sits between the scrub and "
                f"{marker!r} — credential would be reachable by PR-controlled "
                "test code"
            )

    # Regression trip-wire: a plain `uv run pytest` implicitly re-syncs the
    # environment, which would re-fetch git deps mid-test-invocation.
    assert "uv run pytest" not in text, (
        f"{workflow}: test invocation must be `uv run --no-sync pytest` so "
        "tests can never trigger a credential-needing re-resolve"
    )
