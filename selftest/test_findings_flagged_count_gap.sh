#!/usr/bin/env bash
# Behavioral test for the sentence-bounded "flagged N ... issue" clause in
# the unaddressed-findings detector (ci-workflows#175, Codex pre-review P2:
# "No test exercises the new sentence-bounded adjective gap").
#
# THE BURN. whois-api-llc/wxa_webcat#927, 2026-08-16: claude[bot]'s inline
# posting failed wholesale — all four of its inline comments predate the
# last commit — so the round's findings existed ONLY in a top-level summary
# posted 26 minutes after it: "Flagged 4 confirmed issues inline: (1) ...".
# The clause at the time read `[Ff]lagged [0-9]+ issue`, demanding "issue"
# IMMEDIATELY after the count; the adjective "confirmed" broke adjacency, no
# other alternative matched (no P-token, no VERDICT trailer, no
# "regression:" line), and the sweeper printed "no unaddressed findings" on
# a PR that actually had four.
#
# THE FIX (#175): both FINDING_RE (the admission gate, count `[0-9]+`) and
# SEVERITY_RE (the clean-suppressor override, count `[1-9][0-9]*`) gained a
# SENTENCE-BOUNDED gap between the count and "issue" — `[^.!?\n]{0,60}?` —
# tolerating the words a model puts in between while refusing to cross a
# sentence boundary. The bound matters most on the SEVERITY_RE side: an
# unbounded `.*` gap there would let a stray "flagged N ... issue" phrase in
# one sentence resurrect a CLEAN verdict from a totally unrelated later
# sentence — the false "do not merge yet" the file's own comments warn
# against twice over. The count asymmetry ([0-9]+ vs [1-9][0-9]*) is
# deliberate too: a ZERO count is still a FINDING_RE candidate (so CLEAN_RE
# gets to weigh the clean phrase beside it) but must never OVERRIDE a clean
# verdict via SEVERITY_RE — "No issues found. Flagged 0 confirmed issues
# inline." must stay clean.
#
# Five cases, each driven through the vendored twin's own --fixture seam
# (never a mirrored regex copy) with a bot top-level issue comment posted
# after the last commit:
#
#   FC1         the #927 shape itself: an adjective between the count and
#               "issue" is still admitted as a finding (rc=1), and the body
#               reaches the report.
#   FC-OVERRIDE the same adjective gap also lets a real nonzero count
#               override an unrelated CLEAN_RE phrase earlier in the body
#               (rc=1) — the widening applies on the override side too.
#   FC-ZERO     NEGATIVE CONTROL: a zero count is examined but must never
#               override a clean verdict (rc=0) — pins the [0-9]+ vs
#               [1-9][0-9]* count asymmetry. Widening SEVERITY_RE's count to
#               [0-9]+ flips this case to rc=1.
#   FC3         NEGATIVE CONTROL: "flagged 2 findings, all addressed. No
#               issues found." must stay clean (rc=0) — the gap cannot cross
#               the period to manufacture a false override. A gap widened to
#               `.*` (unbounded) would flip this case to rc=1.
#   FC-BASELINE sanity: an unrelated clean comment with no "flagged" mention
#               at all stays clean (rc=0) — proves the harness isn't
#               tautologically flagging everything.
#
# Run from the repo root:
#   bash selftest/test_findings_flagged_count_gap.sh
set -euo pipefail

CHECKER=.github/scripts/unaddressed-findings.sh
failed=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

FX="$T/fixture"
mkdir -p "$FX"
LAST='2026-01-01T00:00:00Z'
AFTER='2026-01-01T01:00:00Z'
printf '{"merged_at": null, "last_commit": "%s"}' "$LAST" > "$FX/meta.json"
echo '[]' > "$FX/inline.json"

# run_case <expected-rc> <name> <bot-issue-comment-body> -> sets RC, OUT
run_case() {
  local want_rc="$1" name="$2" body="$3"
  jq -nc --arg at "$AFTER" --arg body "$body" \
    '[{"created_at":$at,"user":{"login":"codex[bot]"},"body":$body}]' > "$FX/issue.json"
  set +e
  OUT=$(bash "$CHECKER" --fixture "$FX" o/r 1 2>&1); RC=$?
  set -e
  if [ "$RC" -eq "$want_rc" ]; then
    echo "✓ $name"
  else
    echo "✗ $name — rc=$RC, expected $want_rc"
    printf '%s\n' "$OUT" | sed 's/^/    /'
    failed=1
  fi
}

run_case 1 "FC1 the #927 shape: an adjective between count and 'issue' is still admitted (rc=1)" \
  'Flagged 4 confirmed issues inline: (1) auth bypass in the token refresh path (2) unscoped id reaches the delete endpoint.'
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -qF 'Flagged 4 confirmed issues inline'; then
  echo "✓ FC1b the admitted body reaches the report verbatim"
else
  echo "✗ FC1b the report does not name the admitted #927-shaped finding:"
  printf '%s\n' "$OUT" | sed 's/^/    /'
  failed=1
fi

run_case 1 "FC-OVERRIDE an adjective-gapped nonzero count overrides an unrelated clean phrase (rc=1)" \
  'No issues found on the auth axis. Flagged 3 confirmed issues inline on the coverage axis.'
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -qF 'Flagged 3 confirmed issues inline'; then
  echo "✓ FC-OVERRIDEb the overriding body reaches the report verbatim"
else
  echo "✗ FC-OVERRIDEb the report does not name the overriding finding:"
  printf '%s\n' "$OUT" | sed 's/^/    /'
  failed=1
fi

run_case 0 "FC-ZERO a zero count never overrides a clean verdict (rc=0) [negative control]" \
  'No issues found. Flagged 0 confirmed issues inline.'

run_case 0 "FC3 the gap cannot cross a sentence boundary to fabricate an override (rc=0) [negative control]" \
  'Flagged 2 findings, all addressed. No issues found.'

run_case 0 "FC-BASELINE an unrelated clean comment stays clean (rc=0) [negative control]" \
  'No issues found. Nothing else to report.'

echo
if [ "$failed" -ne 0 ]; then
  echo "FAILED"
  exit 1
fi
echo "PASSED"
