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
# Repository-qualified and URL references close too (codex round 1, P2).
expect_gate "15. 'Fixes owner/repo#123 partial' refuses" "Fixes owner/repo#123 partial" 1 "owner/repo#123 partial"
expect_gate "16. 'Fixes owner/repo#123' clears" "Fixes owner/repo#123" 0
expect_gate "17. 'Resolves https://github.com/o/r/issues/12 (partly)' refuses" \
  "Resolves https://github.com/o/r/issues/12 (partly)" 1
expect_gate "18. 'closes https://github.com/o/r/issues/12' clears" "closes https://github.com/o/r/issues/12" 0
expect_gate "19. 'closes #1, owner/repo#2 and https://github.com/o/r/pull/3.' clears" \
  "closes #1, owner/repo#2 and https://github.com/o/r/pull/3." 0
# codex round 2: a TAB before the qualifier used to end the match at the
# reference ([^[:cntrl:]] excludes tab), clearing the exact hazard.
expect_gate "22. a TAB before the qualifier still refuses" "$(printf 'Fixes #12\t(partial)')" 1
# codex round 2: the Oxford pair ", and" is a separator, not a qualifier.
expect_gate "23. 'Fixes #1, #2, and #3.' clears" "Fixes #1, #2, and #3." 0
expect_gate "24. 'Closes #1; #2 and #3' clears" "Closes #1; #2 and #3" 0
# codex round 2: the finder is case-insensitive, so the stripper must fold too.
expect_gate "25. bare mixed-case URL clears" "Closes https://GitHub.com/o/r/issues/12" 0
expect_gate "26. mixed-case URL with a qualifier refuses" \
  "Closes https://GitHub.com/o/r/issues/12 partially" 1
# codex round 3: GitHub's documented multi-issue form repeats the keyword —
# only "Fixes #1, fixes #2" closes both, and it is not a qualifier.
expect_gate "27. 'Fixes #1, fixes #2' clears" "Fixes #1, fixes #2" 0
expect_gate "28. 'Closes #1 and closes owner/repo#2.' clears" "Closes #1 and closes owner/repo#2." 0
expect_gate "29. 'Fixes #1, fixes #2 (partial)' still refuses" "Fixes #1, fixes #2 (partial)" 1

# The gate publishes a hash of the body it judged, so the arm step can
# re-bind to it (a body edit fires no caller event).
run_gate "Closes #12."
if [ -n "$(out_get body_sha)" ] && [ "$(printf '%s' "$(out_get body_sha)" | wc -c | tr -d ' ')" = "16" ]; then
  echo "✓ 20. body_sha output published (16 hex chars)"
else
  echo "✗ 20. body_sha output missing or malformed: '$(out_get body_sha)'"
  failed=1
fi
sha_a=$(out_get body_sha); run_gate "Closes #12. (edited)"; sha_b=$(out_get body_sha)
if [ "$sha_a" != "$sha_b" ]; then
  echo "✓ 21. body_sha changes when the body changes"
else
  echo "✗ 21. body_sha identical for different bodies"
  failed=1
fi

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
pin "the sticky-comment lookup paginates" "issues/\$PR/comments?per_page=100\" --paginate" 1
# codex round 2: `gh --paginate | head -1` takes SIGPIPE on duplicate markers,
# and with no `|| true` on the pipeline pipefail aborts the step before the
# sticky comment is updated. This lookup takes the first id by parameter
# expansion instead. (The risk-tier comment step at ~line 1562 still uses the
# piped shape; it carries `|| true`, so it degrades to an empty result and a
# duplicate comment rather than aborting — reported on the PR, not fixed here.)
pin "the body-gate sticky lookup avoids the SIGPIPE-prone head -1" 'existing=${existing_all%%' 1
# codex round 3: the advisory comment must not redden a completed refusal.
pin "both comment writes degrade to a warning" "could not update the body-gate comment" 1
pin "the comment post degrades to a warning too" "could not post the body-gate comment" 1
pin "the arm step re-binds to the body the gate judged" "GATE_BODY_SHA: \${{ steps.body_gate.outputs.body_sha }}" 1
pin "a body change at arm time stands down as 'body'" "stood_down=body" 1
pin "exactly one stand-down reason is published" "STOOD_DOWN_PUBLISHED" 2
pin "the decision label reads the body stand-down" "\"\${ARM_STOOD_DOWN:-}\" = \"body\"" 1

echo ""
if [ "$failed" -gt 0 ]; then
  echo "FAIL: body-gate case(s) regressed."
  exit 1
fi
echo "OK: all body-gate cases pass."
