#!/usr/bin/env bash
# Guards codex-gate.mjs's decision PRIORITY: an always_review match must RUN
# Codex even when the diff is under SIZE_THRESHOLD, and even when every changed
# file is docs/tests.
#
# always_review exists to override the gate's two cost escapes. It lists the
# files whose small edits still need a second reader, and it does that only
# while its rule is checked FIRST. Reorder the rules (hoist the small-diff skip
# above it, say) and every caller's always_review silently stops forcing a read:
# the gate prints a plausible "small diff" reason, the job goes green, and
# nothing turns red. classify.mjs validates the always_review LIST (shape,
# brackets, negation), but before this test nothing executed codex-gate.mjs at
# all, so nothing pinned the ORDER. Raised by the independent review on
# whois-api-llc/wxa_webcat#1612 (2026-09-23).
#
# Every RUN case has a control that differs from it only in the always_review
# match and must SKIP. A gate that ran Codex unconditionally, or a harness that
# could not read the gate's verdict, fails here instead of passing.
#
# The threshold, the file names and every expected verdict are HARDCODED, never
# read back from codex-gate.mjs: a test that derives its expectations from the
# artifact under test cannot catch that artifact changing.
#
# Run from the repo root:
#   bash selftest/test_codex_gate_priority.sh
set -euo pipefail

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# codex-review.yml fetches codex-gate.mjs and the vendored deps bundle it
# imports into the caller checkout's .github/scripts/, then runs the gate from
# the checkout root, where it reads .github/risk-paths.yml. Mirror that layout.
mkdir -p "$tmp/repo/.github/scripts"
cp .github/scripts/codex-gate.mjs .github/scripts/classifier-deps.mjs "$tmp/repo/.github/scripts/"

failed=0

# expect_gate <want> <description> <diff lines> <file...> — <want> is the
# should_run value the gate writes to GITHUB_OUTPUT, which is what
# codex-review.yml's `steps.gate.outputs.should_run` consumes. SIZE_THRESHOLD
# is passed exactly as that workflow passes it. GITHUB_STEP_SUMMARY is
# redirected too: under Actions the pytest step's own summary file is
# inherited, and every case would append a fake "Codex cost gate" block to it.
expect_gate() {
  local want="$1" desc="$2" lines="$3" rc got
  shift 3
  : > "$tmp/ghout"
  set +e
  (cd "$tmp/repo" && CHANGED_FILES="$(printf '%s\n' "$@")" DIFF_LINES="$lines" \
    SIZE_THRESHOLD=30 GITHUB_OUTPUT="$tmp/ghout" GITHUB_STEP_SUMMARY="$tmp/summary" \
    node .github/scripts/codex-gate.mjs) > "$tmp/out" 2>&1 < /dev/null
  rc=$?
  set -e
  got=$(sed -n 's/^should_run=//p' "$tmp/ghout")
  if [ "$rc" -eq 0 ] && [ "$got" = "$want" ]; then
    echo "✓ $desc"
  else
    echo "✗ $desc — expected exit 0 + should_run=$want; got rc=$rc, should_run='$got':"
    sed 's/^/    /' "$tmp/out"
    failed=1
  fi
}

cat > "$tmp/repo/.github/risk-paths.yml" <<'YAML'
blocked: []
always_review:
  - 'internal/store/migrations.go'
  - 'docs/runbooks/**'
  - 'tests/e2e/test_payments.py'
YAML

# 1. always_review beats the SMALL-DIFF skip: 5 lines is under the threshold.
expect_gate true "always_review match in a 5-line diff runs Codex" 5 internal/store/migrations.go
expect_gate false "control: a 5-line diff with no always_review match skips" 5 internal/store/schema.go

# 2. always_review beats the DOCS/TESTS-ONLY skip. 400 lines clears the size
#    threshold, so only the docs/tests rule could skip these.
expect_gate true "always_review match in a docs-only diff runs Codex" 400 docs/runbooks/rotate-keys.md
expect_gate false "control: a docs-only diff with no always_review match skips" 400 docs/guide/intro.md
expect_gate true "always_review match in a tests-only diff runs Codex" 400 tests/e2e/test_payments.py
expect_gate false "control: a tests-only diff with no always_review match skips" 400 tests/e2e/test_search.py

# 3. ...and both escapes at once: a small, docs-only diff.
expect_gate true "always_review match in a small docs-only diff runs Codex" 5 docs/runbooks/rotate-keys.md
expect_gate false "control: a small docs-only diff with no always_review match skips" 5 docs/guide/intro.md

# 4. One matching file anywhere in the diff forces the run for the whole diff.
expect_gate true "one always_review file among others in a small diff runs Codex" 5 \
  README.md docs/guide/intro.md internal/store/migrations.go
expect_gate false "control: the same small diff without that file skips" 5 \
  README.md docs/guide/intro.md internal/store/schema.go

# 5. CONTROL for the default arm: a large, mixed diff with no always_review
#    match runs, so the SKIP verdicts above come from the escapes and not from
#    a gate that has stopped running Codex at all.
expect_gate true "control: a 400-line mixed diff with no always_review match runs" 400 \
  internal/store/schema.go docs/guide/intro.md

exit "$failed"
