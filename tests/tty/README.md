# tests/tty/

Pexpect-based behavioral tests. Exercised by `tty-tests.yml`.

These are **self-tests** of the `tty-tests.yml` reusable — verifying that
pexpect actually works on a GitHub-hosted ubuntu-latest runner with
`TERM=xterm-256color`. Real callers (downstream repos) will add their own
TTY tests here for their CLIs and agent behavioral contracts.

## Convention

- Filename: `test_<scenario>.py` (pytest discovery).
- Use `pexpect.spawn()` with an explicit `timeout=N` (default 30s is too long
  on flake — use 5–10s and let CI re-run if genuinely slow).
- Assert on output via `child.expect()` rather than `child.read()` so
  diagnostics show which expected pattern didn't match.
- One scenario per file. Don't bundle.

## Why a separate directory from `selftest/`

`selftest/` holds the Python package (`selftest/sample.py`) that
`tests-runner.yml` and `coverage-floor.yml` exercise. `tests/tty/` holds
behavioral fixtures that don't fit the "production code + unit tests"
model. Different concerns, different directories.
