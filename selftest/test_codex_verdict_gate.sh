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
#   2. Under enforcement it fails on evidence of a FINDING — a `regression:`
#      line or a `VERDICT: REGRESSION` trailer — plus on no output at all.
#      Requiring the trailer was tried and failed the first real PR it ran
#      on (domain-rank#82, below): the model ignores the instruction, and a
#      clean review went red. Requiring a recognizable CLEAN phrase failed
#      the same way. The accepted cost is that a finding phrased outside
#      both forms is missed; the review comment still reaches a human.
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

# --- The trailer, when the model bothers to emit it --------------------------
# The prompt asks the response to END with `VERDICT: CLEAN` or
# `VERDICT: REGRESSION`, and it is read from the final non-empty line. It is
# used when present and simply absent when not (see domain-rank#82 below);
# only `VERDICT: REGRESSION` can fail a PR on its own.
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
# KNOWN MISS, accepted deliberately. Prose after a CLEAN trailer is not read,
# so a concern written there is not caught. Catching it means requiring the
# trailer to be last, which requires the trailer — and domain-rank#82 below
# shows that reddens clean PRs. The review comment still shows this to a human.
check "prose after a CLEAN trailer is accepted (known miss)" "0 clean" \
  "$(run true 'VERDICT: CLEAN
Also, the new fallback branch has no test.')"
check "trailer with a trailing period passes" "0 clean" "$(run true 'ok
VERDICT: CLEAN.')"

# THE CASE THAT DECIDED THE DESIGN. Verbatim from topcoder1/domain-rank#82,
# 2026-07-28T04:57Z, the first real PR the gate ran on. The prompt asking for
# the trailer was in that run's log; gpt-5.6-sol answered without it, the gate
# scored no_verdict, and a clean PR went red. Requiring the trailer is
# therefore not viable — this must pass.
check "clean prose without the trailer passes (domain-rank#82)" "0 clean" \
  "$(run true 'No regressions found in the requested coverage, state-mutation, or contract-drift axes.
No regressions found in the requested coverage, state-mutation, or contract-drift axes.')"
# Trailing CLI noise is harmless now that the trailer is not required to be
# last. codex-cli 0.145.0 emits none (verified against real output).
check "a footer below the trailer is harmless" "0 clean" \
  "$(run true 'Reviewed.
VERDICT: CLEAN
tokens used: 12345')"
# Codex answering in the finding shape but reporting nothing must not block.
check "'regression: none' is clean, not a finding" "0 clean" \
  "$(run true 'regression: none
VERDICT: CLEAN')"

# --- Multi-finding format ---------------------------------------------------
check "semicolon-separated findings fail" "1 regression" \
  "$(run true 'regression: a.py:1 - one; regression: b.py:2 - two
VERDICT: REGRESSION')"

# --- What still fails, and what is knowingly let through ---------------------
# Both live findings predate the trailer and carry none, so they also pin the
# primary signal: a `regression:` line is believed with or without a trailer.
check "findings without a trailer still fail" "1 regression" "$(run true "$d79")"

# THE ACCEPTED RESIDUAL RISK, stated out loud: a finding phrased in neither
# the `regression:` form nor a REGRESSION trailer is missed. Every rule that
# caught it also failed clean PRs, because the two are indistinguishable
# without reading English — "The new fallback branch has no test." and "Looks
# good to me." are both trailer-less prose. This gate optimizes for not
# blocking correct work, and leaves the miss to the human reading the comment.
check "off-format finding is missed (accepted risk)" "0 clean" \
  "$(run true 'The new fallback branch has no test.')"
check "terse approval without a trailer passes" "0 clean" \
  "$(run true 'Looks good to me.')"
check "clean phrasing without a trailer passes" "0 clean" \
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
