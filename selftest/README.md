# selftest/

Self-test fixtures for the reusable workflows in this repo.

These are **not** production tests — they verify that the reusables in
`.github/workflows/` boot, accept their declared inputs, and produce
expected outputs. The fixtures here are deliberately minimal.

## Why `selftest/` not `tests/`

Keep this directory scoped to "verify reusables on this repo." A `tests/`
directory would imply a general test suite for a library — which this repo
isn't. Future contributors should resist expanding `selftest/` to cover
arbitrary helper scripts; that's a different kind of repo.

## What lives here

- `test_smoke.py` — trivial passing test invoked by `tests-runner.yml`'s
  self-test path. Verifies pytest discovery, pyproject.toml plumbing, and
  the `uv run pytest` invocation end-to-end.
- `test_automerge_risk_patterns.sh` / `test_bb_automerge_risk_patterns.sh`
  — risk-tier regex behavior, driven by the shared corpus in
  `risk_patterns_corpus.txt`.
- `test_pr_files_listing.sh` — no reusable may fetch changed files via
  `gh pr diff` (HTTP 406 past 20k diff lines); pins the paginated
  files-API idiom instead.
- `test_prettier_symlink_filter.sh` — extracts the symlink filter from
  `lint.yml` / `prettier-autofix.yml`, runs it against a fixture tree,
  and asserts the two copies haven't drifted.
- `test_workflow_guards.py` — pytest wrapper that runs the `.sh`
  selftests above, so `tests-runner.yml`'s self-test path enforces them
  in CI.
- Future: one self-test fixture per reusable (`.coverage-floor` JSON for
  `coverage-floor.yml`, lessons-section markdown for
  `regression-convention.yml`, pty fixture for `tty-tests.yml`).
