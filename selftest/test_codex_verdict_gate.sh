#!/usr/bin/env bash
# Guards codex-verdict.mjs — the gate that decides whether a Codex review
# verdict fails the job or merely gets commented.
#
# Background: codex-review.yml posted Codex's verdict as a PR comment and
# exited 0 no matter what it said. On topcoder1/domain-rank#74 and #79 (both
# 2026-07-27) Codex reported a missing-test regression on each PR; the check
# went green, nobody re-read the comment, and both merged with the finding
# unaddressed. The verdicts those two PRs actually produced are replayed
# verbatim below, so this test pins the real-world case and not just a
# synthetic one.
#
# Two properties matter and both are asserted:
#   1. Enforcement is OPT-IN. Without FAIL_ON_REGRESSION=true the script
#      must always exit 0 — 26 other repos consume this reusable and a
#      default-on gate would start blocking their merges.
#   2. Under enforcement it fails CLOSED: an unparseable or missing verdict
#      is a failure, because "no verdict" is exactly the state the gate
#      cannot vouch for.
#
# Run from the repo root:
#   bash selftest/test_codex_verdict_gate.sh
set -euo pipefail

script="$PWD/.github/scripts/codex-verdict.mjs"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

failed=0

# Run the gate over a verdict. Usage: run <enforce> <verdict-text>
# Echoes "<rc> <state>". Captures rc without tripping `set -e`.
run() {
  local enforce="$1" verdict="$2" rc state out
  printf '%s' "$verdict" > "$tmp/verdict"
  : > "$tmp/ghout"
  set +e
  out=$(VERDICT_FILE="$tmp/verdict" FAIL_ON_REGRESSION="$enforce" \
    GITHUB_OUTPUT="$tmp/ghout" node "$script" 2>&1)
  rc=$?
  set -e
  state=$(sed -n 's/^verdict_state=//p' "$tmp/ghout" | head -1)
  printf '%s %s' "$rc" "${state:-<none>}"
  # Surface the script's own output when a case fails.
  printf '%s' "$out" > "$tmp/last_out"
}

check() {
  local label="$1" want="$2" got="$3"
  if [ "$got" = "$want" ]; then
    echo "✓ $label"
  else
    echo "✗ $label — expected '$want', got '$got'"
    sed 's/^/    /' "$tmp/last_out" 2>/dev/null || true
    failed=1
  fi
}

# --- The two verdicts that motivated this gate ------------------------------
# Replayed verbatim (including the duplicated line the extractor produces).
# shellcheck disable=SC2016  # the backticks are literal verdict text, not substitutions
d74='regression: deploy/redeploy-code.sh:303 - No test forces either fallback `mv` failure and asserts that the new `failed=1` mutation produces an incomplete-restore status.
regression: deploy/redeploy-code.sh:303 - No test forces either fallback `mv` failure and asserts that the new `failed=1` mutation produces an incomplete-restore status.'
check "domain-rank#74 verdict fails under enforcement" "1 regression" "$(run true "$d74")"
check "domain-rank#74 verdict is report-only by default" "0 regression" "$(run false "$d74")"

d79='regression: deploy/redeploy-code.sh:171 - no test exercises the new failure path when the resolved compose config cannot be read from the box'
check "domain-rank#79 verdict fails under enforcement" "1 regression" "$(run true "$d79")"

# --- Clean verdicts must never fail ----------------------------------------
# A false positive here blocks a good PR, so cover the spelling variants
# Codex actually emits rather than only the canonical string.
check "canonical clean verdict passes" "0 clean" "$(run true 'no regressions found')"
check "clean verdict with capitals and period passes" "0 clean" "$(run true 'No regressions found.')"
check "singular clean verdict passes" "0 clean" "$(run true 'no regression found')"
check "clean verdict with 'were' passes" "0 clean" "$(run true 'No regressions were found')"
check "bolded clean verdict passes" "0 clean" "$(run true '**no regressions found**')"
# Codex paraphrases far more often than it emits the canonical string. This
# is the verbatim verdict from the pre-review OF THIS CHANGE — an exact-match
# gate called it unparseable and would have failed a clean PR.
check "paraphrased clean verdict passes" "0 clean" \
  "$(run true 'The opt-in verdict gate is correctly wired, fails closed under enforcement, and preserves advisory behavior by default. No actionable regressions were identified.')"
check "'no issues detected' passes" "0 clean" "$(run true 'No issues detected.')"
check "'no problems were observed' passes" "0 clean" "$(run true 'no problems were observed')"

# A hedge after the clean phrase is not clean: Codex cleared the diff and
# then qualified it, and the qualifier never uses the `regression:` form, so
# nothing else would catch it.
check "hedged clean verdict fails closed" "1 unparseable" \
  "$(run true 'No regressions found, but the new fallback branch has no test.')"
check "'however' hedge fails closed" "1 unparseable" \
  "$(run true 'No issues found. However, the state mutation on line 40 is unasserted.')"
# ...while a hedge BEFORE the clean phrase is just reasoning prose.
check "hedge before the clean phrase stays clean" "0 clean" \
  "$(run true 'I considered the error path, but it is covered. No regressions found.')"
# Codex answering in the finding shape but reporting nothing must not block.
check "'regression: none' is clean, not a finding" "0 clean" \
  "$(run true 'no regressions found
regression: none')"

# --- Multi-finding format ---------------------------------------------------
check "semicolon-separated findings fail" "1 regression" \
  "$(run true 'regression: a.py:1 - one; regression: b.py:2 - two')"

# --- Fail closed ------------------------------------------------------------
# The workflow writes this literal sentinel when awk extracts nothing.
check "workflow's no-verdict sentinel fails closed" "1 unparseable" \
  "$(run true '(Codex produced no parseable verdict — see workflow logs)')"
check "empty verdict fails closed" "1 unparseable" "$(run true '')"
check "chatty off-format verdict fails closed" "1 unparseable" \
  "$(run true 'I reviewed the diff and it looks fine to me overall.')"
# ...but never in report-only mode.
check "unparseable verdict is report-only by default" "0 unparseable" \
  "$(run false '(Codex produced no parseable verdict — see workflow logs)')"

# A missing verdict file is not the same as an empty one — it means the
# review step never wrote one. Same fail-closed treatment.
set +e
VERDICT_FILE="$tmp/does-not-exist" FAIL_ON_REGRESSION=true node "$script" >/dev/null 2>&1
rc=$?
set -e
check "missing verdict file fails closed" "1" "$rc"

# --- Mixed verdict: findings win -------------------------------------------
# If Codex hedges with both phrasings, the finding must decide. Otherwise a
# stray "no regressions found" in the reasoning tail would clear a real one.
check "clean phrase alongside a finding still fails" "1 regression" \
  "$(run true 'no regressions found in the tests, but regression: src/x.py:9 - state mutation unasserted')"

# --- Enforcement is strictly opt-in ----------------------------------------
# Anything other than the exact string "true" must leave the gate advisory;
# a caller that never sets the input gets an empty env var.
for val in "" "false" "FALSE" "0" "yes" "1"; do
  got="$(run "$val" "$d79")"
  if [ "${got%% *}" = "0" ]; then
    echo "✓ FAIL_ON_REGRESSION='$val' does not enforce"
  else
    echo "✗ FAIL_ON_REGRESSION='$val' enforced — only the literal 'true' may"
    failed=1
  fi
done
# ...and the boolean GitHub renders for `fail_on_regression: true` does.
check "FAIL_ON_REGRESSION='true' enforces" "1 regression" "$(run "true" "$d79")"
check "FAIL_ON_REGRESSION=' TRUE ' enforces" "1 regression" "$(run " TRUE " "$d79")"

exit "$failed"
