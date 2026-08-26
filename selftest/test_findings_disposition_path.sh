#!/usr/bin/env bash
# Behavioral test for THE ACKNOWLEDGMENT PATH in the unaddressed-findings
# detector (ci-workflows#163 / #175, Codex pre-review P2: "No test exercises
# the new acknowledgment path or asserts the mutated `cutoff` and resulting
# report/verdict for merged versus open PRs, human versus bot comments, or
# findings posted after the disposition").
#
# TRIGGER. wxa_vpn#1587 (2026-08-24..26): a merged PR can never receive this
# detector's one clear-signal (an authored commit newer than the finding),
# so every post-merge finding re-flagged on every sweep for two days after
# it was already fixed or adjudicated elsewhere. The sweep's own report text
# has always asked the operator to "record why the finding does not apply";
# #175 gives that record a spelling the detector reads: a MERGED PR's
# top-level comment by a KNOWN HUMAN with a line opening (column 0) with
# `findings-disposition: <content>` acts like a commit boundary — findings
# OLDER than the newest valid marker are answered, a finding posted AFTER it
# re-flags and needs a new decision.
#
# Every leg fails CLOSED, by design, and each is pinned below through the
# vendored twin's --fixture seam (meta.json's .merged_at + issue.json
# comments), never a mirrored copy:
#
#   AK1  a finding posted AFTER a valid disposition still re-flags (rc=1) —
#        the disposition only answers findings OLDER than itself.
#   AK2  a finding posted BEFORE a later, valid disposition is suppressed
#        (rc=0), and the clean report NAMES who dispositioned it.
#   AK3  NEGATIVE CONTROL: a bot-authored "disposition" comment is not a
#        disposition at all (bots cannot disposition their own findings) —
#        the finding stays flagged (rc=1) and no "dispositioned by" appears.
#   AK4  NEGATIVE CONTROL: on an OPEN PR the marker is ignored even when
#        well-formed and human-authored — pre-merge, the answer to a
#        finding is still a commit (rc=1, same as if no marker existed).
#   AK5  NEGATIVE CONTROL: a marker that does not open its own line (mid-
#        sentence: "Note: findings-disposition: ...") dispositions nothing
#        (rc=1) — the column-0 requirement is literal, not semantic.
#   AK6  NEGATIVE CONTROL: a bare `findings-disposition:` with no content
#        after the colon dispositions nothing (rc=1).
#   AK7  two valid dispositions bracketing a finding: the NEWEST one
#        decides (sort_by(created_at) | last), and it covers a finding
#        older than it even though an earlier, now-superseded disposition
#        also exists (rc=0).
#
# Run from the repo root:
#   bash selftest/test_findings_disposition_path.sh
set -euo pipefail

CHECKER=.github/scripts/unaddressed-findings.sh
failed=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

FX="$T/fixture"
mkdir -p "$FX"

LAST='2026-01-01T00:00:00Z'
T1='2026-01-01T01:00:00Z'
T2='2026-01-01T02:00:00Z'
T3='2026-01-01T03:00:00Z'
T4='2026-01-01T04:00:00Z'
MERGED_AT='2026-01-01T05:00:00Z'

FINDING_BODY='P1 unscoped token reaches the delete endpoint — no test covers it.'
DEFAULT_DISPOSITION_BODY='findings-disposition: fixed in the parallel dotclaude PR; behavior confirmed byte-identical.'

finding_at() {
  jq -nc --arg at "$1" --arg body "$FINDING_BODY" '{created_at:$at, user:{login:"codex[bot]"}, body:$body}'
}
disposition_at() {  # disposition_at <ts> [login] [body]
  local ts="$1" who="${2:-alice}" body="${3:-$DEFAULT_DISPOSITION_BODY}"
  jq -nc --arg at "$ts" --arg who "$who" --arg body "$body" '{created_at:$at, user:{login:$who}, body:$body}'
}

# run_case <expected-rc> <name> <merged-at-or-null> <issue-json-array> -> sets RC, OUT
run_case() {
  local want_rc="$1" name="$2" merged="$3" issue_json="$4"
  if [ "$merged" = "null" ]; then
    printf '{"merged_at": null, "last_commit": "%s"}' "$LAST" > "$FX/meta.json"
  else
    printf '{"merged_at": "%s", "last_commit": "%s"}' "$merged" "$LAST" > "$FX/meta.json"
  fi
  printf '%s' "$issue_json" > "$FX/issue.json"
  echo '[]' > "$FX/inline.json"
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

# AK1: disposition BEFORE the finding -> finding post-dates it, still flagged.
D=$(disposition_at "$T1")
F=$(finding_at "$T2")
ARR=$(jq -sc '.' <(echo "$D") <(echo "$F"))
run_case 1 "AK1 a finding posted AFTER the disposition still re-flags" "$MERGED_AT" "$ARR"
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -qF 'dispositioned by alice' \
   && printf '%s' "$OUT" | grep -qF 'POST-DATE it and need a new decision'; then
  echo "✓ AK1b report shows the disposition AND that this finding post-dates it"
else
  echo "✗ AK1b report missing the disposition/post-date framing:"
  printf '%s\n' "$OUT" | sed 's/^/    /'
  failed=1
fi

# AK2: finding BEFORE a later, valid disposition -> suppressed, and named.
F=$(finding_at "$T1")
D=$(disposition_at "$T2")
ARR=$(jq -sc '.' <(echo "$F") <(echo "$D"))
run_case 0 "AK2 a finding posted BEFORE the disposition is suppressed" "$MERGED_AT" "$ARR"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qF 'dispositioned by alice'; then
  echo "✓ AK2b the clean report names who dispositioned it — suppression is never silent"
else
  echo "✗ AK2b clean report does not name the disposition:"
  printf '%s\n' "$OUT" | sed 's/^/    /'
  failed=1
fi

# AK3: NEGATIVE CONTROL — a bot cannot disposition its own (or any) finding.
F=$(finding_at "$T1")
D=$(disposition_at "$T2" "codex[bot]")
ARR=$(jq -sc '.' <(echo "$F") <(echo "$D"))
run_case 1 "AK3 [negative control] a bot-authored disposition is not a disposition" "$MERGED_AT" "$ARR"
if [ "$RC" -eq 1 ] && ! printf '%s' "$OUT" | grep -qF 'dispositioned by'; then
  echo "✓ AK3b report carries no 'dispositioned by' — the bot marker was never applied"
else
  echo "✗ AK3b report should not credit a bot disposition:"
  printf '%s\n' "$OUT" | sed 's/^/    /'
  failed=1
fi

# AK4: NEGATIVE CONTROL — open PRs ignore the marker entirely, even human + well-formed.
F=$(finding_at "$T1")
D=$(disposition_at "$T2")
ARR=$(jq -sc '.' <(echo "$F") <(echo "$D"))
run_case 1 "AK4 [negative control] an OPEN PR ignores an otherwise-valid marker" "null" "$ARR"

# AK5: NEGATIVE CONTROL — the marker must OPEN its own line (column 0).
F=$(finding_at "$T1")
D=$(disposition_at "$T2" "alice" "Note: findings-disposition: fixed elsewhere, see the parallel PR.")
ARR=$(jq -sc '.' <(echo "$F") <(echo "$D"))
run_case 1 "AK5 [negative control] a mid-sentence marker dispositions nothing" "$MERGED_AT" "$ARR"

# AK6: NEGATIVE CONTROL — content is required after the colon.
F=$(finding_at "$T1")
D=$(disposition_at "$T2" "alice" "findings-disposition:")
ARR=$(jq -sc '.' <(echo "$F") <(echo "$D"))
run_case 1 "AK6 [negative control] an empty-content marker dispositions nothing" "$MERGED_AT" "$ARR"

# AK7: two valid dispositions bracketing a finding -> the NEWEST one decides.
D1=$(disposition_at "$T2" "alice" "findings-disposition: n/a — reviewed and declined, see thread.")
F=$(finding_at "$T3")
D2=$(disposition_at "$T4" "bob" "findings-disposition: confirmed fixed by the follow-up commit on main.")
ARR=$(jq -sc '.' <(echo "$D1") <(echo "$F") <(echo "$D2"))
run_case 0 "AK7 the newest of two dispositions decides (sort_by(created_at) | last)" "$MERGED_AT" "$ARR"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qF 'dispositioned by bob' \
   && ! printf '%s' "$OUT" | grep -qF 'dispositioned by alice'; then
  echo "✓ AK7b report credits bob (the newer disposition), not alice's superseded one"
else
  echo "✗ AK7b report should credit the newest disposition only:"
  printf '%s\n' "$OUT" | sed 's/^/    /'
  failed=1
fi

echo
if [ "$failed" -ne 0 ]; then
  echo "FAILED"
  exit 1
fi
echo "PASSED"
