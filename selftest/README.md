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
- `test_classify_nocase.sh` — `classify.mjs` case-folds pattern matching for
  `blocked`/`sensitive` **only**. minimatch defaults to case-sensitive, so a
  lowercase `**/secrets*` missed `docs/SECRETS.md` and a production secrets
  rotation runbook classified `risk:trivial` (wxa-jake-ai#875 / #877). Pins
  the fix _and_ the asymmetry that makes it safe — folding may only ever add
  gating, never remove it — so folding the safe/trivial classes is rejected:
  it would demote an unmatched path from the strict `standard` fallback into
  an auto-merge-eligible class (a PR adding `Tests/release.py` under
  `safe_test: ['tests/**']`).
- `test_codex_verdict_gate.sh` — `codex-verdict.mjs` classification and its
  opt-in enforcement. Codex's verdict used to be a comment only: the job
  exited 0 whatever it said, so domain-rank#74 and #79 (both 2026-07-27) each
  merged with a reported missing-test regression unaddressed. Replays both
  verdicts verbatim. Pins the two properties that keep the gate safe for the
  other 26 consumers — enforcement happens only on the literal
  `FAIL_ON_REGRESSION=true`, and under enforcement it fails on evidence of a
  finding (a `regression:` line or a `VERDICT: REGRESSION` trailer) plus on no
  output at all. Requiring the trailer was tried and failed the first real PR
  it ran on (domain-rank#82): the model ignores the instruction and a clean
  review went red. Requiring a recognizable CLEAN phrase failed the same way.
  The accepted cost — asserted explicitly — is that a finding phrased outside
  both forms is missed.
- `test_automerge_base_gate.sh` — auto-merge may only target the ref a
  branch ruleset actually protects. Rulesets are conventionally scoped to
  the default branch (`ref_name: ~DEFAULT_BRANCH`), so a feature-branch base
  has no required checks and `--auto` merges on the spot; every other
  protection in that lane is latency-shaped and assumes a wait to lose.
  wxa-jake-ai#1027 merged into another open PR's head 68s after opening and
  grew that PR's reviewed diff from 6 files to 8. Pins: default base is free
  (no API calls), another open PR's head refuses unconditionally, other
  non-default bases need the opt-in label, and every unreadable input
  refuses.
- `test_pr_files_listing.sh` — no reusable may fetch changed files via
  `gh pr diff` (HTTP 406 past 20k diff lines); pins the paginated
  files-API idiom instead.
- `test_prettier_symlink_filter.sh` — extracts the symlink filter from
  `lint.yml` / `prettier-autofix.yml`, runs it against a fixture tree,
  and asserts the two copies haven't drifted.
- `test_prettier_scope_failsafe.sh` — a failed changed-file listing must
  SKIP the prettier run (mode=none), never fall open to the full-tree
  glob; and prettier-autofix must revert writes under
  `.github/workflows/` before committing (automerge_pat has no workflow
  scope, so such pushes are always rejected — wxa-secrets#27). Extracts
  and executes the shipped bash; drift-checks the listing block between
  the two workflows.
- `test_workflow_guards.py` — pytest wrapper that runs the `.sh`
  selftests above, so `tests-runner.yml`'s self-test path enforces them
  in CI.
- Future: one self-test fixture per reusable (`.coverage-floor` JSON for
  `coverage-floor.yml`, lessons-section markdown for
  `regression-convention.yml`, pty fixture for `tty-tests.yml`).
