#!/usr/bin/env bash
# Behavioral test: codex-gate.mjs must judge each changed path EXACTLY as
# named, and FAIL CLOSED on a path that starts or ends with whitespace, instead
# of trimming it into a different path.
#
# Why. The gate trimmed every changed path before matching it, so a real file
# name with leading or trailing whitespace was judged as another path, and the
# cost gate could skip a Codex review the caller requires. With
# `always_review: ['docs/customer/*']`, on a 100-line diff:
#   - a file named ` ` in docs/customer/ is `docs/customer/ `, which matches
#     `docs/customer/*`; trimmed to `docs/customer/`, it did not, and the gate
#     skipped Codex as docs-only;
#   - `notes.md ` (a trailing space) is not markdown, but trimmed it read as
#     `notes.md`, and the diff skipped as docs-only;
#   - a whitespace-only name at the root was trimmed away, leaving only docs.
# A skipped review still concludes the job `success`. JavaScript's trim() also
# strips a no-break space, U+2028, U+3000 and the BOM, and a tab or carriage
# return. Found by the Codex pre-review of topcoder1/ci-workflows#312.
#
# codex-gate.mjs now keeps each path as given, drops only EMPTY lines, and
# stops (an ::error:: naming the path, exit 1, no should_run output) on any path
# trim() would change, so codex-review.yml's "Codex cost gate" step goes red, as
# its 3000-file cap does. Pins:
#   1. It stops on each padded shape, before any rule: a whitespace-only name in
#      an always_review directory, on a 100-line diff and on a 5-line one; a
#      trailing space; a whitespace-only name at the root; a trailing CR; a
#      trailing no-break space, shown escaped. From the path-list file
#      (CHANGED_FILES_FILE) and from the legacy CHANGED_FILES variable.
#   2. Controls: an always_review path still runs Codex; names with interior
#      spaces, accents and an emoji still skip as docs-only; blank lines are
#      still dropped.
#   3. Mutation controls: with the stop's test replaced by `false`, the padded
#      names are judged by their REAL names (should_run=true), so nothing else
#      trims them; and each one's trimmed reading skips Codex
#      (should_run=false), so the fixtures reproduce the escape a trim made.
#
# Every fixture and expected verdict is HARDCODED, never read back from
# codex-gate.mjs.
#
# Run from the repo root:
#   bash selftest/test_codex_gate_padded_paths.sh
set -euo pipefail

NEEDLE='starts or ends with whitespace'
failed=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# Built from bytes: bash 3.2 has no \u escapes.
CR=$(printf '\r')
NBSP=$(printf '\302\240') # U+00A0 NO-BREAK SPACE

# codex-review.yml fetches the gate and the vendored deps it imports into one
# directory, and runs the gate from the caller's checkout, where
# .github/risk-paths.yml sits.
mkdir -p "$T/repo/.github" "$T/scripts"
cp .github/scripts/codex-gate.mjs .github/scripts/classifier-deps.mjs "$T/scripts/"
printf '%s\n' 'always_review:' "  - 'docs/customer/*'" > "$T/repo/.github/risk-paths.yml"

# Mutant: the stop's test replaced by `false`. It must differ from the shipped
# script, or the mutation controls below would prove nothing.
sed 's/if (f !== f\.trim())/if (false)/' .github/scripts/codex-gate.mjs > "$T/scripts/codex-gate-unstopped.mjs"
if cmp -s .github/scripts/codex-gate.mjs "$T/scripts/codex-gate-unstopped.mjs"; then
  echo "✗ no stop to cut out of codex-gate.mjs — it does not test each changed path with 'f !== f.trim()'"
  failed=1
  mutant_ok=0
else
  mutant_ok=1
fi

FROM='file'
# run_gate <script> <diff lines> <path...> — sets RC, LOG and SR (should_run).
# The paths go one per line in a file named by CHANGED_FILES_FILE, as
# codex-review.yml hands them over, or in CHANGED_FILES after FROM=env (then
# reset). SIZE_THRESHOLD is what the workflow passes. GITHUB_STEP_SUMMARY is
# redirected so a run under Actions does not append to the real summary.
run_gate() {
  local script=$1 lines=$2
  shift 2
  printf '%s\n' "$@" > "$T/paths.txt"
  : > "$T/gateout"
  set +e
  if [ "$FROM" = env ]; then
    LOG=$(cd "$T/repo" && CHANGED_FILES_FILE='' CHANGED_FILES="$(cat "$T/paths.txt")" DIFF_LINES="$lines" \
      SIZE_THRESHOLD=30 GITHUB_OUTPUT="$T/gateout" GITHUB_STEP_SUMMARY="$T/summary" \
      node "$T/scripts/$script" 2>&1 < /dev/null)
  else
    LOG=$(cd "$T/repo" && CHANGED_FILES_FILE="$T/paths.txt" DIFF_LINES="$lines" \
      SIZE_THRESHOLD=30 GITHUB_OUTPUT="$T/gateout" GITHUB_STEP_SUMMARY="$T/summary" \
      node "$T/scripts/$script" 2>&1 < /dev/null)
  fi
  RC=$?
  set -e
  FROM='file'
  SR=$(sed -n 's/^should_run=//p' "$T/gateout")
}

bad() {
  echo "✗ $1 — $2. Output:"
  printf '%s\n' "$LOG" | sed 's/^/    /'
  failed=1
}

# expect_stop <desc> <shown> <diff lines> <path...> — exit 1, no outputs, and an
# ::error:: naming the padded path as <shown>. Matched with `case`, so no pipe
# can race it.
expect_stop() {
  local desc=$1 shown=$2 lines=$3 named=0
  shift 3
  run_gate codex-gate.mjs "$lines" "$@"
  case "$LOG" in
    *"::error::codex-gate.mjs: changed path $shown $NEEDLE"*) named=1 ;;
  esac
  if [ "$RC" -ne 0 ] && [ ! -s "$T/gateout" ] && [ "$named" = 1 ]; then
    echo "✓ $desc"
  else
    bad "$desc" "want a nonzero exit, no outputs, and '::error::codex-gate.mjs: changed path $shown $NEEDLE'; got rc=$RC, should_run='$SR'"
  fi
}

# expect_gate <script> <want> <desc> <diff lines> <path...> — exit 0 and
# should_run=<want>.
expect_gate() {
  local script=$1 want=$2 desc=$3 lines=$4
  shift 4
  run_gate "$script" "$lines" "$@"
  if [ "$RC" -eq 0 ] && [ "$SR" = "$want" ]; then
    echo "✓ $desc"
  else
    bad "$desc" "want exit 0 and should_run=$want; got rc=$RC, should_run='$SR'"
  fi
}

# 1. Each padded shape stops, before any rule.
expect_stop "a whitespace-only name in an always_review directory stops" '"docs/customer/ "' 100 'docs/customer/ '
expect_stop "the same name stops on a 5-line diff, before the small-diff rule" '"docs/customer/ "' 5 'docs/customer/ '
expect_stop "a trailing space stops" '"notes.md "' 100 'notes.md '
expect_stop "a whitespace-only name at the root stops instead of being dropped" '" "' 100 'docs/guide.md' ' '
expect_stop "a trailing carriage return stops" '"notes.md\r"' 100 "notes.md$CR"
expect_stop "a trailing no-break space stops, shown escaped" '"notes.md\u00a0"' 100 "notes.md$NBSP"
FROM='env'
expect_stop "a padded name in the legacy CHANGED_FILES variable stops too" '"docs/customer/ "' 100 'docs/customer/ '

# 2. Controls.
expect_gate codex-gate.mjs true "control: an always_review path still runs Codex" 100 'docs/customer/terms.md'
expect_gate codex-gate.mjs false "control: names with interior spaces, accents and an emoji still skip as docs-only" \
  100 'docs/My Notes/résumé 🚀.md' 'docs/guide.md'
expect_gate codex-gate.mjs false "control: blank lines are still dropped (kept, one would read as a non-docs path and run Codex)" \
  100 '' 'docs/guide.md' '' ''

# 3. Mutation controls: the real names run Codex, and their trimmed readings
#    skip it.
if [ "$mutant_ok" = 1 ]; then
  expect_gate codex-gate-unstopped.mjs true "control: unstopped, 'docs/customer/ ' is judged by its real name (always_review)" \
    100 'docs/customer/ '
  expect_gate codex-gate-unstopped.mjs true "control: unstopped, 'notes.md ' is judged by its real name (not docs)" \
    100 'notes.md '
  expect_gate codex-gate-unstopped.mjs true "control: unstopped, a root ' ' is judged by its real name, not dropped" \
    100 'docs/guide.md' ' '
fi
expect_gate codex-gate.mjs false "escape: trimmed, 'docs/customer/ ' misses docs/customer/* and skips as docs-only" \
  100 'docs/customer/'
expect_gate codex-gate.mjs false "escape: trimmed, 'notes.md ' reads as markdown and skips as docs-only" 100 'notes.md'
expect_gate codex-gate.mjs false "escape: trimmed away, a root ' ' leaves docs only" 100 'docs/guide.md'

echo ""
if [ "$failed" -ne 0 ]; then
  echo "FAIL: codex-gate.mjs does not judge padded paths as named."
  exit 1
fi
echo "OK: codex-gate.mjs stops on padded paths."
