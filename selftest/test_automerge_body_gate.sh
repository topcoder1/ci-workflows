#!/usr/bin/env bash
# Behavioral test for the PR-body closing-keyword gate in
# claude-author-automerge.yml — the step that ABSTAINS from arming when a
# body says "closes #N <qualifier>".
#
# Incident (topcoder1/webcrawl#509, 2026-09-04): a PR body read "closes #509
# follow-up (b)". GitHub's closing-keyword parser reads the keyword and the
# number and ignores everything after them, so the squash-merge closed #509
# in full; the lane posted deploy records and a refresh ask to a closed issue
# for a day before noticing. The gate declines to arm (never vetoes) so the
# author rewrites the body ("part of #N") or a human clicks knowing what
# closes.
#
# This test EXTRACTS the step's bash from the workflow YAML (the shipped
# script, not a mirrored copy) and executes it with PR_BODY set:
#
#   1.  "closes #509 follow-up (b)"            ⇒ refuse=1 (the incident)
#   2.  "Closes #12."                          ⇒ clear (bare reference, period)
#   3.  "Closes #12" at end of line            ⇒ clear
#   4.  "closes #1 and #2"                     ⇒ clear (a list of references)
#   5.  "Fixes #1, #2, #3."                    ⇒ clear
#   6.  "Fixes #7 (partial)"                   ⇒ refuse=1
#   7.  "Part of #509 (candidate follow-up f)" ⇒ clear (no closing keyword)
#   8.  "fixes for #12 are in"                 ⇒ clear (keyword not directly
#                                                 followed by the reference)
#   9.  multi-line: a clean line then a qualified one ⇒ refuse=1, and the
#       reason names the qualified line, not the clean one
#  10.  "closes #509's saga"                   ⇒ refuse=1
#  11.  "RESOLVES #3 — see notes"              ⇒ refuse=1 (case-insensitive)
#  12.  empty body                             ⇒ clear
#  13.  "Fixes #12: the parser"                ⇒ refuse=1 (colon then prose)
#  14.  "closed #4 & #5"                       ⇒ clear ("&" joins references)
#
# Structural pins: the extracted run block contains no `${{ }}` (extraction-
# and injection-safe); the arm step and the quiet-period step both require
# steps.body_gate.outputs.refuse != '1'; the always() error-revoke counts
# steps.body_gate.outcome == 'failure'; the decision-label publisher knows
# automerge:refused-body.
#
# Run from the repo root:
#   bash selftest/test_automerge_body_gate.sh
set -euo pipefail

WF=.github/workflows/claude-author-automerge.yml
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
failed=0

# ---------------------------------------------------------------------------
# Extract the step's run block (the lines under `run: |`, de-indented).
# ---------------------------------------------------------------------------
awk '
  /^      - name: Check PR body closing keywords$/ { in_step=1; next }
  in_step && /^      - name: / { exit }
  in_step && /^        run: \|$/ { in_run=1; next }
  in_run && /^          / { sub(/^          /, ""); print; next }
  in_run && /^[[:space:]]*$/ { print ""; next }
  in_run { exit }
' "$WF" > "$T/gate.sh"
if ! grep -q 'refuse=' "$T/gate.sh"; then
  echo "✗ could not extract the body-gate run block from $WF"
  exit 1
fi
echo "✓ extracted body-gate step ($(wc -l < "$T/gate.sh" | tr -d ' ') lines)"

if grep -q '\${{' "$T/gate.sh"; then
  echo "✗ the body-gate run block contains \${{ }} interpolation (must read the body from env only)"
  failed=1
else
  echo "✓ no \${{ }} interpolation inside the run block"
fi

run_gate() {
  OUT_FILE="$T/gh-output.txt"
  : > "$OUT_FILE"
  set +e
  GATE_LOG=$(cd "$T" && PR_BODY="$1" GITHUB_OUTPUT="$OUT_FILE" bash gate.sh 2>&1)
  GATE_RC=$?
  set -e
}

out_get() { grep "^$1=" "$OUT_FILE" | tail -1 | cut -d= -f2- || true; }

# expect_gate <desc> <body> <want-refuse> [reason-needle]
expect_gate() {
  local desc="$1" body="$2" want="$3" needle="${4:-}" got
  run_gate "$body"
  if [ "$GATE_RC" != "0" ]; then
    echo "✗ $desc — step exited rc=$GATE_RC (want 0). Output:"
    echo "$GATE_LOG" | sed 's/^/    /'
    failed=1
    return
  fi
  got=$(out_get refuse)
  if [ "$got" != "$want" ]; then
    echo "✗ $desc — got refuse='$got' (want '$want'). Output:"
    echo "$GATE_LOG" | sed 's/^/    /'
    failed=1
    return
  fi
  if [ -n "$needle" ] && ! out_get reason | grep -qF -- "$needle"; then
    echo "✗ $desc — reason '$(out_get reason)' lacks '$needle'"
    failed=1
    return
  fi
  echo "✓ $desc"
}

echo ""
expect_gate "1. the incident: 'closes #509 follow-up (b)' refuses" \
  "Fixes four defects. This closes #509 follow-up (b); it also carries (c)." 1 "closes #509 follow-up (b)"
expect_gate "2. 'Closes #12.' clears" "Closes #12." 0
expect_gate "3. 'Closes #12' at end of line clears" "Small fix.

Closes #12" 0
expect_gate "4. 'closes #1 and #2' clears" "closes #1 and #2" 0
expect_gate "5. 'Fixes #1, #2, #3.' clears" "Fixes #1, #2, #3." 0
expect_gate "6. 'Fixes #7 (partial)' refuses" "Fixes #7 (partial)" 1 "Fixes #7 (partial)"
expect_gate "7. 'Part of #509 (candidate follow-up f)' clears" "Part of #509 (candidate follow-up f), reference first." 0
expect_gate "8. 'fixes for #12 are in' clears (keyword not followed by the reference)" "The fixes for #12 are in this PR." 0
expect_gate "9. multi-line: the qualified line refuses and is the one named" "Closes #12.

Also closes #509 follow-up (b) as recorded." 1 "closes #509 follow-up (b) as recorded"
expect_gate "10. \"closes #509's saga\" refuses" "closes #509's saga" 1
expect_gate "11. 'RESOLVES #3 — see notes' refuses (case-insensitive)" "RESOLVES #3 — see notes" 1
expect_gate "12. empty body clears" "" 0
expect_gate "13. 'Fixes #12: the parser' refuses" "Fixes #12: the parser now rejects it" 1
expect_gate "14. 'closed #4 & #5' clears" "closed #4 & #5" 0

# ---------------------------------------------------------------------------
# Wiring pins.
# ---------------------------------------------------------------------------
pin() {
  local desc="$1" needle="$2" want="$3" got
  got=$(grep -cF -- "$needle" "$WF" || true)
  if [ "$got" -ge "$want" ]; then
    echo "✓ $desc"
  else
    echo "✗ $desc — '$needle' found $got time(s), want ≥ $want"
    failed=1
  fi
}
pin "arm + quiet-period steps require the body gate to clear" "steps.body_gate.outputs.refuse != '1'" 2
pin "error-revoke counts a failed body gate" "steps.body_gate.outcome == 'failure'" 1
pin "a body refusal revokes an existing arm" "- name: Revoke auto-merge on body-gate refusal" 1
pin "decision-label publisher knows the verdict" "automerge:refused-body" 2
pin "a refusal leaves a sticky comment" "claude-author-automerge:body-gate" 1

echo ""
if [ "$failed" -gt 0 ]; then
  echo "FAIL: body-gate case(s) regressed."
  exit 1
fi
echo "OK: all body-gate cases pass."
