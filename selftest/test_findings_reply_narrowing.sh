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
#   S1. structural: the narrowing keys on in_reply_to_id == null OR (one
#       login pipeline: null OR bot) — the connector is `or`, and the null
#       test guards `endswith` structurally, not by arm order
#   R1. THE #1523 SHAPE: human reply "Fixed in <sha>" after the last commit
#       ⇒ rc=0, no unaddressed findings
#   R2. over-correction guard: a BOT reply after the last commit ⇒ rc=1
#   R2b. a reply whose author is UNKNOWN (.user null — deleted/suspended
#       account) ⇒ rc=1. Reading an absent login as "not a bot" would
#       silently convert an unknown author into a false negative; the
#       exclusion drops KNOWN-human replies only.
#   R3. over-correction guard: a human TOP-LEVEL inline comment ⇒ rc=1
#       (the narrowing must not eat author-agnosticism at top level)
#   R4. mixed thread: human resolution replies + one genuine late bot
#       finding ⇒ rc=1, report names the bot line and NOT the replies
#   R5. legacy fixture shape (no in_reply_to_id field at all) ⇒ still
#       flagged — absent and null must read the same, so old fixtures and
#       REST payloads that omit the field keep today's behavior
#   R6. explicit `"in_reply_to_id": null` (the OTHER spelling of "not a
#       reply" — REST omits the field, but a cached/proxied payload may
#       null it) ⇒ still flagged; pins that a `has()` rewrite cannot split
#       the two spellings
#   R7. TOP-LEVEL crash guard: one null-user issue comment must not abort
#       the jq program and silence every other top-level finding (with
#       stderr discarded, that abort read as "no findings" — exit 0)
#   R8. direction pin: a null-user TOP-LEVEL comment falls to that path's
#       default (only KNOWN bots count), the mirror of R2b on the inline
#       path (default is to count, so unknown authors do)
#
# Run from the repo root:
#   bash selftest/test_findings_reply_narrowing.sh
set -euo pipefail

CHECKER=.github/scripts/unaddressed-findings.sh
failed=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# S1. Structural pin: the exclusion must be the null-or-(unknown-or-bot) shape.
# A rewrite to `has("in_reply_to_id") | not` would split absent from null (R5
# and R6 pin the behavior, this names the intended spelling); dropping the bot
# escape would eat R2 silently on fixtures that never exercise bot replies;
# dropping the unknown-author test would eat R2b the same way. Two more things
# it pins, both review catches: the null test and the bot test must be ONE
# pipeline on the login (`. == null or endswith`) so null-safety is structural
# rather than dependent on which sibling arm is evaluated first; and the
# connector between the reply test and the login pipeline must be `or` — with
# `and`, no comment can satisfy both (a reply is not a non-reply), late_inline
# is always empty, and the sweep passes every PR. R3/R5 catch that at runtime;
# S1 is the structural claim, so it must not certify a shape it did not check.
# LAYOUT-INDEPENDENT on purpose: the select is read with newlines folded to
# spaces (`tr`), so the connector test sees the whole expression regardless of
# whether a maintainer keeps it on two lines or one — a -A line window here
# would false-fail on a correct one-line consolidation, and this comment used
# to promise no such window while the line below it had one.
# `|| true`: under `set -o pipefail` a no-match grep exits 1, which would ABORT
# the suite here instead of letting S1 report ✗ — an empty S1_SELECT is a
# finding for S1 to print, not a reason to stop testing.
S1_SELECT=$(tr '\n' ' ' < "$CHECKER" | grep -oE 'select\(\.in_reply_to_id == null[^]]*\]' | head -1 || true)
if grep -q 'in_reply_to_id == null' "$CHECKER" \
   && grep -qF '(.user.login | . == null or endswith("[bot]"))' "$CHECKER" \
   && printf '%s' "$S1_SELECT" | grep -qE 'in_reply_to_id == null[[:space:]]+or[[:space:]]+\(\.user\.login \|' \
   && ! printf '%s' "$S1_SELECT" | grep -qE 'in_reply_to_id == null[[:space:]]+and\b'; then
  echo "✓ S1 narrowing is 'not a reply OR (unknown author OR bot)' — one login pipeline, joined by or"
else
  echo "✗ S1 narrowing shape missing or rewritten — expected 'in_reply_to_id == null' joined by 'or' to ONE login pipeline '(.user.login | . == null or endswith(\"[bot]\"))'"
  failed=1
fi

FX="$T/fixture"
mkdir -p "$FX"
LAST='2026-01-01T00:00:00Z'
AFTER='2026-01-01T01:00:00Z'
printf '{"merged_at": null, "last_commit": "%s"}' "$LAST" > "$FX/meta.json"
echo '[]' > "$FX/issue.json"

# Runs the checker on inline.json (+ optional issue.json) fixtures and asserts
# the exit code. ALWAYS returns 0: this file runs under `set -e`, so a nonzero
# return from a bare `run_case` call would abort the suite at the first
# failing case and silently skip every later one — the per-case verdict lives
# in `failed` (the suite's exit), and the report stays in $OUT so callers can
# additionally assert on its CONTENT (R4b does) without hand-rolling a second
# harness.
run_case() {  # $1 expected-rc, $2 name, $3 inline-json, $4 issue-json (optional)
  printf '%s' "$3" > "$FX/inline.json"
  printf '%s' "${4:-[]}" > "$FX/issue.json"
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
  return 0
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

# R2b. Unknown-author reply counts (deleted/suspended account -> .user null).
run_case 1 "R2b a reply with a null .user still counts (rc=1)" '[
  {"created_at":"'"$AFTER"'","user":null,"path":"infra/x.yml",
   "in_reply_to_id":3787072809,
   "body":"The retry loop still deadlocks when the queue is empty."}]'

# R3. Human top-level inline still counts.
run_case 1 "R3 a human TOP-LEVEL inline comment still counts (rc=1)" '[
  {"created_at":"'"$AFTER"'","user":{"login":"topcoder1"},"path":"deploy.yml",
   "body":"This breaks rollback — the old image tag is gone by then."}]'

# R4. Mixed: replies must not mask (or appear beside) the real finding.
# Exit code through the shared harness; the report-content assertions read
# the $OUT it leaves behind and run UNCONDITIONALLY — gating them on R4's
# verdict would silently skip the only content check exactly when the
# checker misbehaves, which is when its report matters most. $OUT is bound
# to R4_OUT immediately, so a case inserted between R4 and R4b later cannot
# silently redirect the content assertions at someone else's report.
run_case 1 "R4 mixed thread flags (rc=1)" '[
  {"created_at":"'"$AFTER"'","user":{"login":"topcoder1"},"path":"infra/x.yml",
   "in_reply_to_id":9,"body":"Fixed in 38774043."},
  {"created_at":"'"$AFTER"'","user":{"login":"claude[bot]"},"path":"docker-compose.yml",
   "body":"The compose rationale is now inverted by the trust change."}]'
R4_OUT=$OUT
if printf '%s' "$R4_OUT" | grep -q "compose rationale" \
   && ! printf '%s' "$R4_OUT" | grep -q "Fixed in 38774043"; then
  echo "✓ R4b report names the bot finding and omits the human replies"
else
  echo "✗ R4b report must name the bot line and omit the replies:"
  printf '%s\n' "$R4_OUT" | head -6 | sed 's/^/    /'
  failed=1
fi

# R5. Legacy shape: no in_reply_to_id field anywhere (old fixtures, and REST
# payloads omit the field on top-level comments rather than null-ing it).
run_case 1 "R5 field-absent inline comment keeps today's behavior (rc=1)" '[
  {"created_at":"'"$AFTER"'","user":{"login":"topcoder1"},"path":"deploy.yml",
   "body":"Real bug here."}]'

# R6. The OTHER spelling of "not a reply": the field present and explicitly
# null. jq reads absent and null identically through `.in_reply_to_id`, and
# this pins that a future `has("in_reply_to_id")` rewrite cannot split them.
run_case 1 "R6 explicit in_reply_to_id:null keeps today's behavior (rc=1)" '[
  {"created_at":"'"$AFTER"'","user":{"login":"topcoder1"},"path":"deploy.yml",
   "in_reply_to_id":null,
   "body":"Real bug here."}]'

# R7. THE CRASH CASE, on the TOP-LEVEL path: one null-user comment anywhere
# in the issue-comment list must not silence the OTHER findings. Pre-guard,
# `null | endswith` was a jq type error, stderr was discarded, late_issue
# came back empty and a genuine bot P1 in the same list vanished — exit 0.
run_case 1 "R7 a null-user issue comment does not silence a bot finding (rc=1)" '[]' '[
  {"created_at":"'"$AFTER"'","user":null,
   "body":"thanks, closing the loop"},
  {"created_at":"'"$AFTER"'","user":{"login":"github-actions[bot]"},
   "body":"- [P1] Token check is skippable — auth.py:31"}]'

# R8. Direction pin for the same guard: a null-user TOP-LEVEL comment falls
# to this path's default — top-level counts only KNOWN bots, so an unknown
# author does not count (the mirror of R2b, where inline's default is to
# count and unknown authors therefore do).
run_case 0 "R8 a null-user issue comment alone is not a finding (rc=0)" '[]' '[
  {"created_at":"'"$AFTER"'","user":null,
   "body":"- [P1] Token check is skippable — auth.py:31"}]'

echo
if [ "$failed" -eq 0 ]; then
  echo "PASS — findings reply narrowing"
else
  echo "FAIL — findings reply narrowing"
fi
exit "$failed"
