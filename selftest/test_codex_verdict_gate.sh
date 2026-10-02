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

# ===========================================================================
# STRICT_FINDINGS mode — used ONLY by codex-review.yml's comment step when a
# findings-DELIVERY comment could not be posted. The default classifier's
# residual misses are acceptable because "the review comment still puts it in
# front of a human"; in the lost-comment branch there is no comment and no
# human, and claude-author-automerge's findings gate (unaddressed-findings.sh,
# fetched at decision time) admits a WIDER finding alphabet than the default
# signals. Strict mode over-approximates that alphabet, so a verdict the gate
# would have held cannot be degraded to "provenance only" and slip to green.
# Over-matching is the safe direction: it merely restores the pre-#169 red.
# ===========================================================================

run_strict() {
  local enforce="$1" verdict="$2" rc state out
  printf '%s' "$verdict" > "$tmp/verdict"
  : > "$tmp/ghout"
  set +e
  out=$(VERDICT_FILE="$tmp/verdict" FAIL_ON_REGRESSION="$enforce" STRICT_FINDINGS=true \
    GITHUB_OUTPUT="$tmp/ghout" node "$script" 2>&1)
  rc=$?
  set -e
  state=$(sed -n 's/^verdict_state=//p' "$tmp/ghout" | head -1)
  printf '%s %s' "$rc" "${state:-<none>}"
  printf '%s\n' "$out" > "$tmp/last_out"
}

# The lost-comment incident shape: an off-format [P2] finding plus a CLEAN
# trailer. Default mode is clean BY DESIGN (the human reads the comment);
# strict mode must refuse to call it findings-free.
p2_verdict='Coverage and state-mutation axes look fine.

- [P2] no test exercises the new error path — src/api/handler.ts:41

No regressions found on the contract-drift axis.
VERDICT: CLEAN'
check "off-format P2 verdict stays clean by default (human reads the comment)" \
  "0 clean" "$(run true "$p2_verdict")"
check "off-format P2 verdict is findings under STRICT_FINDINGS" \
  "1 regression" "$(run_strict true "$p2_verdict")"
check "STRICT_FINDINGS stays report-only without FAIL_ON_REGRESSION" \
  "0 regression" "$(run_strict false "$p2_verdict")"

# Mid-text VERDICT: REGRESSION with a CLEAN final line: default mode reads
# only the final line (deliberately); the gate's SEVERITY_RE matches the
# string anywhere and would hold the PR, so strict must too.
check "mid-text VERDICT: REGRESSION is findings under strict" "1 regression" \
  "$(run_strict true 'VERDICT: REGRESSION on the coverage axis.
VERDICT: CLEAN')"

# Regression marker whose path starts with a NON_FINDING prefix word: the
# default scan drops `regression: na/...` (its none/na filter fires on the
# word boundary at the slash) but the gate's raw marker counts it.
check "'regression: na/...' path is findings under strict" "1 regression" \
  "$(run_strict true 'regression: na/foo.py:3 - counter increment never asserted
VERDICT: CLEAN')"
# ...and the gate ALSO admits that marker behind prefixes its raw form
# cannot consume — canon strips checkboxes, quotes and numbered lists
# before the marker test — so strict must be prefix-agnostic (Codex
# pre-review round 4 found the checkbox form slipping through).
check "checkbox-prefixed 'regression: na/...' is findings under strict" "1 regression" \
  "$(run_strict true '- [ ] regression: na/foo.py:3 - counter increment never asserted')"
# Decoration glued to the word defeats a \b anchor (underscore is a word
# character), while canon strips it and admits — Codex pre-review round 6.
check "underscore-wrapped marker is findings under strict" "1 regression" \
  "$(run_strict true '__regression__: no_helpers/util.py:7 - fallback path untested')"
# The rescue must not swallow the legitimate clean shape: bare "regression:
# none" has no path-shaped target and stays clean even under strict.
check "strict: 'regression: none' still clean" "0 clean" \
  "$(run_strict true 'regression: none
VERDICT: CLEAN')"

# KNOWN OVER-MATCH, pinned as a decision: a P-token DISCLAIMER reads as a
# finding under strict. Tightening it means porting the gate's CLEAN_RE
# suppressor into strict mode, and an over-wide suppressor there is the
# #165 fail-open; the cost as-is is a pre-#169-style red on a lost comment,
# in a vocabulary ("[P1]/[P2] issues") codex-review's own prompt never
# elicits. Codex pre-review round 3 raised this; declined with rationale.
check "strict: P-token disclaimer over-matches (deliberate)" "1 regression" \
  "$(run_strict true 'No [P1] or [P2] issues found. VERDICT: CLEAN')"

# Strict must NOT red plain clean prose — the degrade path exists so a lost
# CLEAN verdict stays green, and these are the real clean shapes.
check "strict: domain-rank#82 clean prose stays clean" "0 clean" \
  "$(run_strict true 'No regressions found in the requested coverage, state-mutation, or contract-drift axes.')"
check "strict: clean trailer verdict stays clean" "0 clean" \
  "$(run_strict true 'Reviewed the diff.
VERDICT: CLEAN')"
check "strict: no-verdict sentinel still classifies no_verdict" "1 no_verdict" \
  "$(run_strict true '(Codex produced no parseable verdict — see workflow logs)')"

# ===========================================================================
# PARITY SWEEP: strict mode must over-approximate the automerge findings
# gate. The gate's predicate is evaluated HERE with the same regex variables
# unaddressed-findings.sh ships and the same jq application it runs at
# decision time (its late_issue select) — so if either file drifts, this
# breaks in this repo's own CI, not on a merged PR. One-directional by
# design: strict may fail bodies the gate would pass (that only restores the
# pre-#169 red on a lost comment), never the reverse.
# ===========================================================================
if command -v jq >/dev/null 2>&1; then
  eval "$(grep -E '^(_NOT_EMPTY|_BLOCK_PREFIX|_MARKER_CANON|_REGRESSION_MARKER|_REGRESSION_MARKER_RAW|FINDING_RE|CLEAN_RE|SEVERITY_RE)=' .github/scripts/unaddressed-findings.sh)"
  # _REGRESSION_MARKER is checked too: FINDING_RE interpolates it, so a
  # rename upstream would otherwise eval FINDING_RE with an empty trailing
  # alternative that matches every body.
  for v in _NOT_EMPTY _BLOCK_PREFIX _MARKER_CANON _REGRESSION_MARKER _REGRESSION_MARKER_RAW FINDING_RE CLEAN_RE SEVERITY_RE; do
    if [ -z "$(eval "printf '%s' \"\$$v\"")" ]; then
      echo "✗ parity: could not extract $v from unaddressed-findings.sh — variable renamed?"
      failed=1
    fi
  done

  gate_counts() {
    jq -n --arg body "$1" \
      --arg find "$FINDING_RE" --arg clean "$CLEAN_RE" \
      --arg sev "$SEVERITY_RE" --arg rmark "$_REGRESSION_MARKER_RAW" \
      --arg blk "$_BLOCK_PREFIX" --arg mark "$_MARKER_CANON" '
      def canon: split("\n") | map(sub($blk; "") | sub($mark; "regression: "; "i")) | join("\n");
      (($body | canon) | test($find; "i"))
        and ((($body | test($clean; "i")) | not)
             or ($body | test($sev; "i"))
             or ($body | test($rmark; "i")))'
  }

  # Bodies spanning every admission clause the gate has, plus clean controls.
  # Delimited with an unlikely separator so multi-line bodies survive.
  parity_corpus() {
    cat <<'CORPUS'
Coverage looks fine.

- [P2] no test exercises the new error path — src/api/handler.ts:41

VERDICT: CLEAN
===CASE===
P2: `handler` accepts unvalidated ids — src/api/handler.ts:41
VERDICT: CLEAN
===CASE===
**P1** Authentication bypass in the token refresh path.
No regressions found elsewhere.
===CASE===
No issues found on coverage, but P1 unscoped token reaches push.
===CASE===
Flagged 3 issues inline.
===CASE===
No regressions found. Flagged 3 confirmed issues inline.
===CASE===
VERDICT: REGRESSION on the coverage axis.
VERDICT: CLEAN
===CASE===
regression: na/foo.py:3 - counter increment never asserted
VERDICT: CLEAN
===CASE===
- [ ] regression: na/foo.py:3 - counter increment never asserted
===CASE===
> regression: no_helpers/util.py:7 - fallback path untested
===CASE===
__regression__: no_helpers/util.py:7 - fallback path untested
===CASE===
**regression**: na/foo.py:3 - counter increment never asserted
===CASE===
`regression`: no_cache/store.py:12 - eviction path untested
===CASE===
(regression: na/foo.py:3 - counter increment never asserted)
===CASE===
[regression: no_helpers/util.py:7 - fallback path untested]
===CASE===
<regression: na/foo.py:3 - counter increment never asserted
===CASE===
- regression: `src/x.py:9` - unasserted state mutation
===CASE===
No regressions found in the requested coverage, state-mutation, or contract-drift axes.
===CASE===
Looks good to me.
===CASE===
No [P1] or [P2] issues found. VERDICT: CLEAN
CORPUS
  }

  case_n=0
  body=''
  flush_parity_case() {
    [ -n "$body" ] || return 0
    case_n=$((case_n + 1))
    local gate strict_state
    gate=$(gate_counts "$body")
    strict_state=$(run_strict false "$body")
    strict_state="${strict_state#* }"
    if [ "$gate" = "true" ] && [ "$strict_state" = "clean" ]; then
      echo "✗ parity case $case_n: the automerge gate would hold this body but STRICT_FINDINGS calls it clean (fail-open on a lost comment)"
      printf '%s\n' "$body" | sed 's/^/    | /'
      failed=1
    else
      echo "✓ parity case $case_n: gate=$gate strict=$strict_state (strict ⊇ gate holds)"
    fi
    body=''
  }
  while IFS= read -r line; do
    if [ "$line" = "===CASE===" ]; then
      flush_parity_case
    else
      body="${body:+$body
}$line"
    fi
  done < <(parity_corpus)
  flush_parity_case
else
  echo "✗ parity sweep skipped: jq not installed (required — the automerge gate runs on jq)"
  failed=1
fi


# ===========================================================================
# QUIET — may codex-review.yml leave this verdict off the PR? (WS2 step 3)
#
# Every new PR comment notifies the PR's watchers. codex-review.yml stops
# posting a verdict only on POSITIVE evidence that it is an all-clear: state
# clean with the strict signals applied, no P0-P3 token (a P3 is a finding
# the gate lets through, not an all-clear), an all-clear phrase, and no
# caveat word. Anything else posts exactly as before. Measured on 220 real
# verdicts (90 PRs in five repos, 09-15..10-02): 85 quiet, and all 50
# distinct texts among them were all-clears. The fixtures below keep the
# real corpus's SHAPES; the wording is neutral because the PRs they came
# from live in private repositories.
# ===========================================================================

# Usage: run_quiet <strict:true|false> <verdict-text>. Echoes "<rc> <quiet>".
run_quiet() {
  local strict="$1" verdict="$2" rc quiet out
  printf '%s' "$verdict" > "$tmp/verdict"
  : > "$tmp/ghout"
  set +e
  out=$(VERDICT_FILE="$tmp/verdict" FAIL_ON_REGRESSION=false STRICT_FINDINGS="$strict" \
    GITHUB_OUTPUT="$tmp/ghout" node "$script" 2>&1)
  rc=$?
  set -e
  quiet=$(sed -n 's/^quiet=//p' "$tmp/ghout" | head -1)
  printf '%s %s' "$rc" "${quiet:-<none>}"
  printf '%s\n' "$out" > "$tmp/last_out"
}

# The common all-clear, duplicated as the extractor produces it.
q_axes='No regressions found on the requested coverage, state-mutation, or contract-drift axes.
No regressions found on the requested coverage, state-mutation, or contract-drift axes.'
check "quiet: the common duplicated all-clear" "0 true" "$(run_quiet true "$q_axes")"
check "quiet: a bare VERDICT: CLEAN trailer" "0 true" "$(run_quiet true 'VERDICT: CLEAN')"
q_singular='No regression found. The changed outputs are specifically tested; no new runtime state mutation or contract drift was introduced.
VERDICT: CLEAN'
check "quiet: singular all-clear with a description of what is covered" "0 true" "$(run_quiet true "$q_singular")"

# A P3 is a finding: clean under every state rule (strict counts only
# P0-P2), and it must still reach a human.
q_p3='The new counter mutation lacks a post-state assertion.

Review comment:

- [P3] Assert the counter outcome — src/jobs/counter.py:57-60
  The new path increments the counter, but no test asserts the value.'
check "quiet: a P3 review comment posts (state reads clean)" "0 false" "$(run_quiet true "$q_p3")"
q_p3_after_all_clear='No functional regression or comment-contract drift was found; only a missing assertion remains.
VERDICT: CLEAN

Review comment:

- [P3] Assert the staged-file post-state — tests/test_stage.py:88'
check "quiet: an all-clear followed by a P3 posts" "0 false" "$(run_quiet true "$q_p3_after_all_clear")"
check "quiet: clean prose with no all-clear phrase posts" "0 false" "$(run_quiet true 'Coverage and state-mutation axes look fine.')"
check "quiet: an all-clear with a caveat posts" "0 false" "$(run_quiet true 'No regressions found. Missing coverage: no test pins the new cron entry.')"
check "quiet: a regression finding posts" "0 false" "$(run_quiet true "$d79")"
check "quiet: the no-verdict sentinel posts" "0 false" "$(run_quiet true '(Codex produced no parseable verdict — see workflow logs)')"
check "quiet: an empty verdict posts" "0 false" "$(run_quiet true '')"
check "quiet: a REGRESSION trailer outranks the all-clear phrase" "0 false" "$(run_quiet true 'No regressions found on the requested axes.
VERDICT: REGRESSION')"
# The strict signals decide quiet whatever STRICT_FINDINGS says: the
# default classifier calls this clean, but a P2 is a finding.
q_p2='No regressions found.

- [P2] no test exercises the new error path — src/api/handler.ts:41'
check "quiet: a P2 posts even without STRICT_FINDINGS" "0 false" "$(run_quiet false "$q_p2")"
check "quiet: the line is written on a regression run too" "0 false" "$(run_quiet false "$d74")"
# A review that says it fell short is not an all-clear, whatever it
# concludes (Codex pre-review round 2): Codex has reported "no regressions
# found" over a review that never read the diff.
check "quiet: an all-clear over a review that could not inspect the diff posts" "0 false" "$(run_quiet true 'No issues found; I was unable to inspect the diff.
VERDICT: CLEAN')"
check "quiet: an all-clear after a sandboxed git failure posts" "0 false" "$(run_quiet true 'No regressions found. git commands failed in the sandbox, so the diff was read from the PR title only.
VERDICT: CLEAN')"
check "quiet: an all-clear on a partial review posts" "0 false" "$(run_quiet true 'No regressions found in the files reviewed; the review was partial.')"
# Contractions and typographic apostrophes (Codex pre-review round 3).
check "quiet: \"didn't inspect\" posts" "0 false" "$(run_quiet true "No issues found. I didn't inspect the diff due to permissions.
VERDICT: CLEAN")"
check "quiet: \"wasn’t able\" (typographic apostrophe) posts" "0 false" "$(run_quiet true 'No regressions found; I wasn’t able to read the test files.')"
check "quiet: \"haven't reviewed\" posts" "0 false" "$(run_quiet true "No regressions found. Git was not available, so I haven't reviewed the changes.")"
# The all-clear must complete as one (Codex pre-review round 4): a bare
# "no regression" opens the missing-test finding the prompt asks for.
check "quiet: \"No regression test covers …\" is a finding and posts" "0 false" "$(run_quiet true 'No regression test covers the new retry branch.')"
check "quiet: \"no regression is evident\" is an all-clear" "0 true" "$(run_quiet true 'Only dependency metadata changed, and no regression is evident.')"
check "quiet: \"wasn't available\" posts" "0 false" "$(run_quiet true "No regressions found. The repository wasn't available; the assessment used only the PR title.")"
# Codex pre-review round 5: the gate's flagged-count form allows words
# between the count and "issue", and the perfect tense hides "able".
check "quiet: \"Flagged 3 confirmed issues\" is a finding and posts" "0 false" "$(run_quiet true 'No regressions found. Flagged 3 confirmed issues inline.')"
check "quiet: \"haven't been able\" posts" "0 false" "$(run_quiet true "No regressions found. I haven't been able to inspect the diff.
VERDICT: CLEAN")"
check "quiet: \"had not been able\" posts" "0 false" "$(run_quiet true 'No regressions found. I had not been able to read the changed files.')"

exit "$failed"
