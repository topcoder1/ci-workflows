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
#   2. Under enforcement the `VERDICT:` trailer decides, and a response
#      answering neither the trailer nor the `regression:` form fails
#      CLOSED. Both prose-reading rules were tried first and both failed:
#      requiring a recognizable clean phrase false-failed a live clean
#      review, and treating any prose without `regression:` as clean let an
#      off-format finding through. One required output line replaces a
#      judgement call about English.
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
  # Surface the script's own output when a case fails. The trailing newline
  # matters: without it the next result line is glued onto the end of this
  # diagnostic, which both mangles the output and hides every failure after
  # the first from a line-anchored `grep '^✗'`.
  printf '%s\n' "$out" > "$tmp/last_out"
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

# --- The trailer decides ----------------------------------------------------
# The prompt requires the response to END with `VERDICT: CLEAN` or
# `VERDICT: REGRESSION`. Prose above it is for humans.
check "CLEAN trailer passes" "0 clean" \
  "$(run true 'Reviewed the diff.
VERDICT: CLEAN')"
check "REGRESSION trailer fails" "1 regression" \
  "$(run true 'regression: a.py:1 - no test covers the new branch
VERDICT: REGRESSION')"
check "lowercase trailer passes" "0 clean" "$(run true 'ok
verdict: clean')"
check "bolded trailer passes" "0 clean" "$(run true 'ok
**VERDICT: CLEAN**')"
check "trailing whitespace on the trailer is tolerated" "0 clean" \
  "$(run true 'ok
VERDICT:   CLEAN   ')"

# Prose Codex actually emits, all genuinely clean, each carrying the trailer.
# The middle one has no negative-finding phrase at all — an earlier revision
# that required a recognizable clean phrase failed its PR.
check "paraphrased clean verdict passes" "0 clean" \
  "$(run true 'The opt-in verdict gate is correctly wired. No actionable regressions were identified.
VERDICT: CLEAN')"
check "purely descriptive clean verdict passes" "0 clean" \
  "$(run true 'The workflow consistently routes and validates Codex review outcomes, while the regression tests cover the relevant success, failure, skipped, cancelled, draft, and unknown-class cases.
VERDICT: CLEAN')"

# The trailer may not RETRACT findings. A response that lists regressions and
# then claims CLEAN is a regression — the findings are the evidence.
check "findings outrank a CLEAN trailer" "1 regression" \
  "$(run true 'regression: a.py:1 - unasserted state mutation
VERDICT: CLEAN')"
# Only the FINAL non-empty line counts, so a quoted example earlier in the
# prose cannot decide the verdict.
check "only the final line decides" "1 regression" \
  "$(run true 'The format asks me to answer VERDICT: CLEAN when nothing is wrong.
VERDICT: REGRESSION')"
# ...and prose AFTER the trailer means the contract was not followed. Reading
# the earlier marker would be the off-format-finding hole in a new costume.
check "prose after a CLEAN trailer fails closed" "1 no_verdict" \
  "$(run true 'VERDICT: CLEAN
Also, the new fallback branch has no test.')"
check "trailer with a trailing period passes" "0 clean" "$(run true 'ok
VERDICT: CLEAN.')"

# NOTHING below the trailer is forgiven, and that is the decision, not an
# oversight. Three attempts to whitelist trailing CLI telemetry were each
# shown to swallow a real finding written in the same shape, so the gate now
# trusts only the last line. codex-cli 0.145.0 prints nothing after the
# response (verified against real output), and if a future CLI adds a footer
# these cases go no_verdict — RED and diagnosable — rather than silently
# promoting an earlier CLEAN marker.
check "a footer below the trailer fails closed, not open" "1 no_verdict" \
  "$(run true 'Reviewed.
VERDICT: CLEAN
tokens used: 12345')"
# The three real findings that killed each successive filter. All must fail.
check "prose below the trailer fails closed" "1 no_verdict" \
  "$(run true 'VERDICT: CLEAN
The token refresh path has no test.')"
check "a finding opening with 'Usage:' fails closed" "1 no_verdict" \
  "$(run true 'VERDICT: CLEAN
Usage: the token refresh path has no test.')"
check "a finding shaped like a token count fails closed" "1 no_verdict" \
  "$(run true 'VERDICT: CLEAN
Tokens used: 1 token can authorize every tenant.')"
# Codex answering in the finding shape but reporting nothing must not block.
check "'regression: none' is clean, not a finding" "0 clean" \
  "$(run true 'regression: none
VERDICT: CLEAN')"

# --- Multi-finding format ---------------------------------------------------
check "semicolon-separated findings fail" "1 regression" \
  "$(run true 'regression: a.py:1 - one; regression: b.py:2 - two
VERDICT: REGRESSION')"

# --- Fail closed when the contract is not answered --------------------------
# Both live findings predate the trailer and carry none, so they also pin the
# fallback: a `regression:` line is believed even without a trailer.
check "findings without a trailer still fail" "1 regression" "$(run true "$d79")"

# An off-format FINDING — no trailer, no `regression:` token. Reading this as
# clean is the hole Codex round 1 caught in the previous revision: it would
# have passed AND restored the auto-merge bypass.
check "off-format finding fails closed" "1 no_verdict" \
  "$(run true 'The new fallback branch has no test.')"
check "terse approval without a trailer fails closed" "1 no_verdict" \
  "$(run true 'Looks good to me.')"
check "clean phrasing without a trailer fails closed" "1 no_verdict" \
  "$(run true 'no regressions found')"

# The workflow writes this literal sentinel when awk extracts nothing.
check "workflow's no-verdict sentinel fails closed" "1 no_verdict" \
  "$(run true '(Codex produced no parseable verdict — see workflow logs)')"
check "empty verdict fails closed" "1 no_verdict" "$(run true '')"
check "whitespace-only verdict fails closed" "1 no_verdict" "$(run true '
  ')"
# ...but never in report-only mode.
check "no_verdict is report-only by default" "0 no_verdict" \
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
