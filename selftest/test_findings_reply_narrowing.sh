#!/usr/bin/env bash
# Behavioral test for the human-reply narrowing in the unaddressed-findings
# detector (wxa_vpn#1392's false-positive half, measured on wxa_vpn#1523).
#
# THE DEFECT. The detector's inline signal was "any inline comment newer than
# the newest commit". A threaded REPLY that RESOLVES a finding ("Fixed in
# <sha>") necessarily post-dates the commit it cites — the author pushes, then
# replies citing the push — so every resolution round tripped the signal, and
# the report re-flagged resolved threads forever.
#
# MEASURED, wxa_vpn#1523 (2026-08-14). The report's top three hits were the
# PR's own "Fixed in 38774043" replies, posted 7-12s after the fix commit.
# Across the PR: 5/5 false positives carried in_reply_to_id; 0/14 genuine bot
# findings did. A sweeper that cries wolf gets ignored — the detector's own
# header argues twice over that this costs more than the miss it trades
# against, and this gate's output is quoted verbatim into automerge-withheld
# comments, so a false flag there declines arms on clean PRs.
#
# THE NARROWING. Drop inline comments that are BOTH a reply (in_reply_to_id
# set) AND human. Everything else is untouched:
#   * human TOP-LEVEL inline comments still count (author-agnostic — a
#     human's own comment on the diff is a deliberate finding);
#   * BOT replies still count (a reviewer bot answering a thread with "still
#     broken after the fix" is a live finding).
# Accepted residual: a human typing a NEW finding into an existing thread is
# skipped — the operator wrote it, so the operator already knows it.
#
# Cases (all through the vendored twin's own --fixture seam):
#   S1. structural: the narrowing keys on in_reply_to_id == null OR bot login
#   R1. THE #1523 SHAPE: human reply "Fixed in <sha>" after the last commit
#       ⇒ rc=0, no unaddressed findings
#   R2. over-correction guard: a BOT reply after the last commit ⇒ rc=1
#   R3. over-correction guard: a human TOP-LEVEL inline comment ⇒ rc=1
#       (the narrowing must not eat author-agnosticism at top level)
#   R4. mixed thread: human resolution replies + one genuine late bot
#       finding ⇒ rc=1, report names the bot line and NOT the replies
#   R5. legacy fixture shape (no in_reply_to_id field at all) ⇒ still
#       flagged — absent and null must read the same, so old fixtures and
#       REST payloads that omit the field keep today's behavior
#
# Run from the repo root:
#   bash selftest/test_findings_reply_narrowing.sh
set -euo pipefail

CHECKER=.github/scripts/unaddressed-findings.sh
failed=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# S1. Structural pin: the exclusion must be the null-or-bot shape. A rewrite
# to `has("in_reply_to_id") | not` would split absent from null (R5 pins the
# behavior, this names the intended spelling), and dropping the bot escape
# would eat R2 silently on fixtures that never exercise bot replies.
if grep -q 'in_reply_to_id == null' "$CHECKER" \
   && grep -A1 'in_reply_to_id == null' "$CHECKER" | grep -q 'endswith("\[bot\]")'; then
  echo "✓ S1 narrowing is 'not a reply OR a bot' (null-check + bot escape present)"
else
  echo "✗ S1 narrowing shape missing or rewritten — expected in_reply_to_id == null with a [bot] escape"
  failed=1
fi

FX="$T/fixture"
mkdir -p "$FX"
LAST='2026-01-01T00:00:00Z'
AFTER='2026-01-01T01:00:00Z'
printf '{"merged_at": null, "last_commit": "%s"}' "$LAST" > "$FX/meta.json"
echo '[]' > "$FX/issue.json"

run_case() {  # $1 expected-rc, $2 name, $3 inline-json
  printf '%s' "$3" > "$FX/inline.json"
  set +e
  OUT=$(bash "$CHECKER" --fixture "$FX" o/r 1 2>&1); RC=$?
  set -e
  if [ "$RC" -eq "$1" ]; then
    echo "✓ $2"
  else
    echo "✗ $2 — rc=$RC, expected $1"
    printf '%s\n' "$OUT" | head -4 | sed 's/^/    /'
    failed=1
  fi
}

# R1. THE #1523 SHAPE.
run_case 0 "R1 human 'Fixed in <sha>' reply is not a finding (rc=0)" '[
  {"created_at":"'"$AFTER"'","user":{"login":"topcoder1"},"path":"infra/x.yml",
   "in_reply_to_id":3787072809,
   "body":"Fixed in 38774043 — the docstring now records the inversion."}]'

# R2. Bot reply still counts.
run_case 1 "R2 a BOT reply in a thread still counts (rc=1)" '[
  {"created_at":"'"$AFTER"'","user":{"login":"claude[bot]"},"path":"infra/x.yml",
   "in_reply_to_id":3787072809,
   "body":"Still broken after the fix: the tuple is empty on 3.12."}]'

# R3. Human top-level inline still counts.
run_case 1 "R3 a human TOP-LEVEL inline comment still counts (rc=1)" '[
  {"created_at":"'"$AFTER"'","user":{"login":"topcoder1"},"path":"deploy.yml",
   "body":"This breaks rollback — the old image tag is gone by then."}]'

# R4. Mixed: replies must not mask (or appear beside) the real finding.
printf '%s' '[
  {"created_at":"'"$AFTER"'","user":{"login":"topcoder1"},"path":"infra/x.yml",
   "in_reply_to_id":9,"body":"Fixed in 38774043."},
  {"created_at":"'"$AFTER"'","user":{"login":"claude[bot]"},"path":"docker-compose.yml",
   "body":"The compose rationale is now inverted by the trust change."}]' > "$FX/inline.json"
set +e
OUT=$(bash "$CHECKER" --fixture "$FX" o/r 1 2>&1); RC=$?
set -e
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q "compose rationale" \
   && ! printf '%s' "$OUT" | grep -q "Fixed in 38774043"; then
  echo "✓ R4 mixed thread: bot finding reported, human replies absent from the report"
else
  echo "✗ R4 mixed thread — rc=$RC; report must name the bot line and omit the replies:"
  printf '%s\n' "$OUT" | head -6 | sed 's/^/    /'
  failed=1
fi

# R5. Legacy shape: no in_reply_to_id field anywhere (old fixtures, and REST
# payloads omit the field on top-level comments rather than null-ing it).
run_case 1 "R5 field-absent inline comment keeps today's behavior (rc=1)" '[
  {"created_at":"'"$AFTER"'","user":{"login":"topcoder1"},"path":"deploy.yml",
   "body":"Real bug here."}]'

echo
if [ "$failed" -eq 0 ]; then
  echo "PASS — findings reply narrowing"
else
  echo "FAIL — findings reply narrowing"
fi
exit "$failed"
