#!/usr/bin/env bash
# Behavioral test for the REVIEW-TRIGGER anchor in claude-author-automerge.yml's
# quiet-period gate (wxa_vpn#1392, incident PR wxa_vpn#1512).
#
# THE DEFECT. The quiet gate holds the arm until the review conversation has
# been silent for findings_quiet_minutes, then runs the unaddressed-findings
# detector. Its three original anchors — newest authored commit, newest inline
# comment, newest non-self [bot] comment — all measure silence that has ALREADY
# ELAPSED. That is the right question only when the event that woke the workflow
# did not itself start a review.
#
# `ready_for_review` does exactly that. pr-review.yml, pr-codex-review.yml and
# claude-author-automerge.yml share the same `types:` list, so readying a draft
# fires the review lanes and arms the gate in the same instant — while every
# anchor the gate can read still dates from before the PR was drafted. The
# longer a PR sits in draft, the more thoroughly the gate is satisfied that
# nobody is talking, at the exact moment three review lanes start talking.
#
# MEASURED, wxa_vpn#1512 (2026-08-14). The PR was drafted at 03:21 and readied
# at 05:38:04Z — 2h09m later. The step logged:
#
#   Quiet: newest commit/review activity is 7757s old (>= 1200s).
#   whois-api-llc/wxa_vpn#1512 — no unaddressed findings (last commit 03:20:37Z)
#   Enabling auto-merge (squash)                                  [05:38:26Z]
#
# It never slept. The detector's "clean" was accurate and useless: it read a
# conversation the reviews had not joined yet. Codex posted VERDICT: REGRESSION
# at 05:39:01Z — 35 seconds after the arm — and the PR merged at 05:42:51Z
# carrying it. The regression shipped and needed follow-up PR #1518 to fix.
# #1518 then cleared the same way at 3074s; its review came back clean, so that
# one was a near miss rather than a hit.
#
# WHY A LONGER WINDOW IS NOT THE FIX: no window helps when the clock starts
# pre-expired. 7757s already exceeded a 20-minute window by 6.5x, and would
# exceed any window an operator would accept. The anchor has to include the
# moment the current round of review was TRIGGERED.
#
# WHY THIS IS NOT NEW POLICY: the push path already waits. wxa_vpn#1513, the
# same day, slept 1162s then 441s and merged clean. This only stops the ready
# path from skipping a wait the push path has always taken — which is why A2
# and A4 below matter as much as A1: over-gating is how these controls get
# switched off, and a gate that could be held shut by its own re-runs would be.
#
# Cases:
#   S1. structural: the timeline anchor read paginates
#   S2. structural: the anchor filters to ready_for_review/reopened by EVENT,
#       not by a substring of the whole timeline
#   A1. THE INCIDENT: old commit + old comments + RECENT ready_for_review ⇒
#       the gate SLEEPS the remainder instead of clearing instantly
#   A2. over-correction guard: an OLD ready_for_review does not hold the gate
#       shut — it ages out like every other anchor (a point-in-time event, not
#       "now"), so a later `labeled` re-run still arms without sleeping
#   A3. `reopened` anchors too (draft→ready is not the only review trigger)
#   A4. over-correction guard: unrelated timeline events (labeled, commented,
#       assigned, merged) anchor NOTHING — pr-classify labels every PR seconds
#       after it opens, and anchoring on that would hold every arm for a full
#       window on every run
#   A5. an unreadable timeline fails CLOSED (an unreadable anchor is not an
#       absent one — same posture as the three sibling reads)
#   A6. a PR with no ready/reopen event and an aged-out creation behaves
#       exactly as before the fix (empty c4 must not poison the anchor set)
#   A7. THE `opened` DOOR (review round 2): a recently-CREATED PR with old
#       commits and no ready event sleeps the remainder — `opened` is in
#       the same review-lane `types:` list, so a branch whose commits idled
#       before the PR was opened non-draft is #1512 through a different
#       door; c5 (creation time, from the event payload) anchors it
#   A8. over-correction guard for c5: an aged-out creation time does not
#       hold the gate shut (same point-in-time rule as A2)
#   S3. structural: PR_CREATED_AT is bound from the event payload in the
#       step's env block — c5 reads an env var, and an unbound var is an
#       empty c5 forever, silently reverting A7 to the pre-fix behavior
#
# Run from the repo root:
#   bash selftest/test_automerge_quiet_anchor.sh
set -euo pipefail

WF=.github/workflows/claude-author-automerge.yml
failed=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# ---------------------------------------------------------------------------
# Extract the gate's run block — the shipped bash, not a mirrored copy.
# ---------------------------------------------------------------------------
awk '
  /^      - name: Quiet period \+ unaddressed findings$/ { in_step=1 }
  in_step && /^        run: \|/ { in_run=1; next }
  in_run {
    if ($0 ~ /^          / || $0 == "") { sub(/^          /, ""); print }
    else { exit }
  }
' "$WF" > "$T/qf.sh"

if ! grep -q 'QUIET_MINUTES' "$T/qf.sh" || ! grep -q 'read_anchor' "$T/qf.sh"; then
  echo "✗ could not extract the quiet/findings run block from $WF"
  exit 1
fi
echo "✓ extracted quiet/findings step ($(wc -l < "$T/qf.sh" | tr -d ' ') lines)"

# ---------------------------------------------------------------------------
# S1. The timeline read paginates.
#
# A PR that has been readied, converted back to draft and readied again — or
# simply one with a long timeline — pushes the ready event past page 1. An
# unpaginated read would silently restore the exact defect this file exists to
# pin, and would do it only on the busiest PRs.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016  # `${PR}` is the literal text being searched for in
# the EXTRACTED workflow shell, not an expansion this test wants performed.
if grep -F 'issues/${PR}/timeline?per_page=100' "$T/qf.sh" | grep -q -- '--paginate'; then
  echo "✓ S1 timeline anchor read paginates"
else
  echo "✗ S1 timeline anchor read does not paginate — a ready event past page 1 anchors nothing"
  failed=1
fi

# S2. Filtered by EVENT equality, not by a substring of the payload. A
# `test("ready_for_review")` over the whole timeline would match any comment
# quoting the phrase, and the anchor would then be steered by prose.
if grep -q '\.event == "ready_for_review"' "$T/qf.sh" && grep -q '\.event == "reopened"' "$T/qf.sh"; then
  echo "✓ S2 anchor selects on .event equality for both review triggers"
else
  echo "✗ S2 anchor does not select .event == ready_for_review / reopened"
  failed=1
fi

# S3. The c5 anchor reads $PR_CREATED_AT, and the run block is deliberately
# ${{ }}-free — so the binding lives in the step's env block, and dropping
# it there leaves c5 empty on every run: A7 silently reverts to pre-fix
# behavior with nothing red. Pin the binding in the WORKFLOW, not the
# extracted shell.
# shellcheck disable=SC2016  # the ${{ }} is the literal workflow-expression
# text being searched for, not a shell expansion this test wants performed.
if grep -q 'PR_CREATED_AT: ${{ github.event.pull_request.created_at }}' "$WF"; then
  echo "✓ S3 PR_CREATED_AT is bound from the event payload in the step env"
else
  echo "✗ S3 PR_CREATED_AT env binding missing — c5 is empty forever and the opened trigger is unanchored"
  failed=1
fi

# ---------------------------------------------------------------------------
# Stub environment — same shape as test_automerge_findings_gate.sh.
#
# Fake clock: NOW lives in $T_NOW; `date -u +%s` reads it, `sleep N` advances it
# by N and logs the call. Fixture timestamps:
#   OLD    2026-01-01T00:00:00Z -> 1000000   (age 7000s at NOW=1007000: quiet)
#   YOUNG  2026-01-01T02:00:00Z -> 1006800   (age  200s at NOW=1007000: not)
# ---------------------------------------------------------------------------
mkdir -p "$T/bin"

cat > "$T/bin/date" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "-u" ] && [ "$2" = "+%s" ]; then cat "$T_NOW"; exit 0; fi
if [ "$1" = "-u" ] && [ "$2" = "-d" ]; then
  case "$3" in
    2026-01-01T00:00:00Z) echo 1000000 ;;
    2026-01-01T02:00:00Z) echo 1006800 ;;
    *) echo "date-stub: unmapped timestamp '$3' — new fixture timestamps must be added to the case map in this stub (see the fake-clock note above the stub in this file)" >&2; exit 1 ;;
  esac
  exit 0
fi
echo "date-stub: unexpected args: $*" >&2; exit 1
EOF

cat > "$T/bin/sleep" <<'EOF'
#!/usr/bin/env bash
echo "$1" >> "$T_DIR/sleep.log"
n=$(cat "$T_NOW"); echo $(( n + ${1%.*} )) > "$T_NOW"
exit 0
EOF

# gh stub: dispatches on call shape, logs every call. `timeline` is matched
# BEFORE the generic issues-comments arm; neither string contains the other, so
# the order is belt-and-braces rather than load-bearing.
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$T_DIR/gh.log"
case "$*" in
  *pulls/*/commits*)
    cat "$T_DIR/commits.json"; exit 0 ;;
  *pulls/*/comments*)
    cat "$T_DIR/inline.json"; exit 0 ;;
  *issues/*/timeline*)
    [ -f "$T_DIR/fail_timeline" ] && exit 1
    cat "$T_DIR/timeline.json"; exit 0 ;;
  *contents/.github/scripts/unaddressed-findings.sh*)
    base64 < "$T_DIR/checker_stub.sh"; exit 0 ;;
  *issues/*/comments*--jq*)
    exit 0 ;;
  *issues/*/comments*)
    cat "$T_DIR/issue.json"; exit 0 ;;
  "pr merge --disable-auto"*)
    echo "disable-auto" >> "$T_DIR/calls.log"; exit 0 ;;
  "pr view"*)
    echo "OFF"; exit 0 ;;
  "pr comment"*)
    echo "comment-posted" >> "$T_DIR/calls.log"; exit 0 ;;
  "api -X PATCH"*)
    echo "comment-patched" >> "$T_DIR/calls.log"; exit 0 ;;
  *)
    echo "gh-stub: unmatched: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$T/bin/date" "$T/bin/sleep" "$T/bin/gh"

OLD_COMMITS='[{"parents":[{"sha":"x"}],"commit":{"committer":{"date":"2026-01-01T00:00:00Z"}}}]'

new_case() {
  CASE=$(mktemp -d "$T/case.XXXXXX")
  cat > "$CASE/checker_stub.sh" <<'EOF'
#!/usr/bin/env bash
echo "stub findings report line"
exit "$(cat "$T_DIR/checker_rc")"
EOF
  echo 1007000 > "$CASE/now"
  : > "$CASE/gh.log"; : > "$CASE/sleep.log"; : > "$CASE/calls.log"; : > "$CASE/output"
  printf '%s' "$OLD_COMMITS" > "$CASE/commits.json"
  echo '[]' > "$CASE/inline.json"
  echo '[]' > "$CASE/issue.json"
  echo '[]' > "$CASE/timeline.json"
  echo 0 > "$CASE/checker_rc"
}
exec_gate() {  # $1 = quiet minutes, $2 = PR_CREATED_AT (optional; empty = unset-like)
  set +e
  PATH="$T/bin:$PATH" T_DIR="$CASE" T_NOW="$CASE/now" \
    GITHUB_OUTPUT="$CASE/output" GITHUB_REPOSITORY="o/r" \
    PR=1 PR_URL="https://example.invalid/pr/1" QUIET_MINUTES="$1" \
    PR_CREATED_AT="${2:-}" \
    bash "$T/qf.sh" > "$CASE/stdout" 2>&1
  RC=$?
  set -e
}
timeline_with() {  # $1 = event name, $2 = created_at
  jq -n --arg e "$1" --arg t "$2" '[{event:$e, created_at:$t}]' > "$CASE/timeline.json"
}

# ---------------------------------------------------------------------------
# A1. THE INCIDENT. Everything the old anchor set could see is 7000s old; the
# PR was readied 200s ago. Pre-fix this cleared the 1200s window without a
# single sleep and armed over a review that had not started. Post-fix the ready
# event IS the anchor, so the gate sleeps the 1000s remainder — which is what
# gives the review lanes room to post before the detector reads the thread.
# ---------------------------------------------------------------------------
new_case
timeline_with ready_for_review 2026-01-01T02:00:00Z
exec_gate 20
if [ "$RC" -eq 0 ] && grep -q '^clear=1$' "$CASE/output" && grep -q '^1000$' "$CASE/sleep.log"; then
  echo "✓ A1 a recent ready_for_review anchors the clock: slept the 1000s remainder before consulting the detector"
else
  echo "✗ A1 ready_for_review did not anchor the quiet clock — rc=$RC sleeps=[$(tr '\n' ' ' < "$CASE/sleep.log")] output=[$(tr '\n' ' ' < "$CASE/output")]"
  echo "     this is wxa_vpn#1512: the gate arms in the same instant the review lanes are triggered"
  failed=1
fi

# ---------------------------------------------------------------------------
# A2. OVER-CORRECTION GUARD, and the one that keeps this fix shippable. The
# anchor is a point-in-time event timestamp, not "now". A `labeled` re-run an
# hour after the ready must therefore see it age out like any other anchor and
# arm without sleeping. Anchoring on "this PR was ever readied" instead would
# hold every subsequent run for a full window, and a gate that never opens gets
# set to findings_quiet_minutes=0 — at which point it protects nothing.
# ---------------------------------------------------------------------------
new_case
timeline_with ready_for_review 2026-01-01T00:00:00Z
exec_gate 20
if [ "$RC" -eq 0 ] && grep -q '^clear=1$' "$CASE/output" && [ ! -s "$CASE/sleep.log" ]; then
  echo "✓ A2 an aged-out ready_for_review does not hold the gate shut (armed without sleeping)"
else
  echo "✗ A2 an OLD ready_for_review still delayed the arm — rc=$RC sleeps=[$(tr '\n' ' ' < "$CASE/sleep.log")] output=[$(tr '\n' ' ' < "$CASE/output")]"
  echo "     the anchor must be the event's timestamp, never a boolean 'was readied'"
  failed=1
fi

# A3. `reopened` re-fires the review lanes on the same `types:` list, so it is a
# review trigger too and must anchor identically — including the arm at the
# end: asserting only the sleep would pass a gate that waited correctly and
# then failed to write clear=1 (review round 2's catch on this very case).
new_case
timeline_with reopened 2026-01-01T02:00:00Z
exec_gate 20
if [ "$RC" -eq 0 ] && grep -q '^clear=1$' "$CASE/output" && grep -q '^1000$' "$CASE/sleep.log"; then
  echo "✓ A3 a recent reopened anchors the clock the same way (and still arms)"
else
  echo "✗ A3 reopened did not anchor+arm — rc=$RC sleeps=[$(tr '\n' ' ' < "$CASE/sleep.log")] output=[$(tr '\n' ' ' < "$CASE/output")]"
  failed=1
fi

# ---------------------------------------------------------------------------
# A4. OVER-CORRECTION GUARD. Only the two review triggers anchor. `labeled` is
# the sharpest of these: pr-classify labels every PR within seconds of opening
# and this workflow re-runs on `labeled`, so anchoring on it would make every
# arm wait a full window behind a label the gate itself provoked. The others are
# ordinary timeline noise that must stay invisible to the clock.
# ---------------------------------------------------------------------------
for ev in labeled commented assigned merged review_requested head_ref_force_pushed; do
  new_case
  timeline_with "$ev" 2026-01-01T02:00:00Z
  exec_gate 20
  if [ "$RC" -eq 0 ] && grep -q '^clear=1$' "$CASE/output" && [ ! -s "$CASE/sleep.log" ]; then
    echo "✓ A4 '$ev' does not anchor the quiet clock"
  else
    echo "✗ A4 '$ev' anchored the quiet clock — rc=$RC sleeps=[$(tr '\n' ' ' < "$CASE/sleep.log")]"
    echo "     only ready_for_review/reopened trigger a review round; anything else stalls every arm"
    failed=1
  fi
done

# ---------------------------------------------------------------------------
# A5. Fail CLOSED. "Could not read the timeline" and "the PR was never readied"
# are the same empty value to every caller downstream, and only the second
# justifies arming. The three sibling anchor reads already return 1 on failure;
# this one must too, or the fix quietly reverts to the pre-fix anchor set on any
# API blip — the failure mode being least visible exactly when the API is worst.
# ---------------------------------------------------------------------------
new_case
touch "$CASE/fail_timeline"
exec_gate 20
if [ "$RC" -ne 0 ]; then
  echo "✓ A5 an unreadable timeline fails closed (no anchor, no arm)"
else
  echo "✗ A5 timeline read failing 3x produced rc=0 — an unreadable anchor read as an absent one"
  failed=1
fi

# ---------------------------------------------------------------------------
# A6. A PR with no ready/reopen event and an AGED-OUT creation time. `max //
# empty` yields no c4, c5 has aged out, the empty line is stripped, and the
# anchor set decides exactly as before the fix. Pins that the added reads
# cannot poison the common case (a mature PR's labeled/synchronize re-runs).
# ---------------------------------------------------------------------------
new_case
echo '[]' > "$CASE/timeline.json"
exec_gate 20 2026-01-01T00:00:00Z
if [ "$RC" -eq 0 ] && grep -q '^clear=1$' "$CASE/output" && grep -q '^reason=quiet+clean$' "$CASE/output" \
   && [ ! -s "$CASE/sleep.log" ]; then
  echo "✓ A6 no ready/reopen event + aged-out creation leaves the pre-fix decision intact"
else
  echo "✗ A6 the added anchors changed the outcome — rc=$RC output=[$(tr '\n' ' ' < "$CASE/output")] sleeps=[$(tr '\n' ' ' < "$CASE/sleep.log")]"
  failed=1
fi

# ---------------------------------------------------------------------------
# A7. THE `opened` DOOR (review round 2, the incomplete-fix finding). Commits
# idle since T0; the PR is CREATED non-draft at T1 = now-200s; no ready or
# reopen event exists because the PR was never a draft. `opened` fires the
# review lanes and this gate in the same instant — without c5 the gate reads
# only pre-aged anchors and arms immediately, #1512 through a different door.
# With c5 the creation time IS the anchor: sleep the 1000s remainder.
# ---------------------------------------------------------------------------
new_case
echo '[]' > "$CASE/timeline.json"
exec_gate 20 2026-01-01T02:00:00Z
if [ "$RC" -eq 0 ] && grep -q '^clear=1$' "$CASE/output" && grep -q '^1000$' "$CASE/sleep.log"; then
  echo "✓ A7 a recently-created PR (opened trigger) anchors on creation: slept the 1000s remainder"
else
  echo "✗ A7 the opened door is unanchored — rc=$RC sleeps=[$(tr '\n' ' ' < "$CASE/sleep.log")] output=[$(tr '\n' ' ' < "$CASE/output")]"
  echo "     commits idled before a non-draft open ⇒ the gate arms as the review lanes start"
  failed=1
fi

# ---------------------------------------------------------------------------
# A8. Over-correction guard for c5, same rule as A2: creation time is a
# point-in-time value, so once it ages out it must not delay any later run.
# (A6 already covers this composed with an empty timeline; this pins it with
# a ready event present, so the two immutable anchors age out independently.)
# ---------------------------------------------------------------------------
new_case
timeline_with ready_for_review 2026-01-01T00:00:00Z
exec_gate 20 2026-01-01T00:00:00Z
if [ "$RC" -eq 0 ] && grep -q '^clear=1$' "$CASE/output" && [ ! -s "$CASE/sleep.log" ]; then
  echo "✓ A8 aged-out creation + aged-out ready event do not hold the gate shut"
else
  echo "✗ A8 an old creation time still delayed the arm — rc=$RC sleeps=[$(tr '\n' ' ' < "$CASE/sleep.log")]"
  failed=1
fi

echo
if [ "$failed" -eq 0 ]; then
  echo "PASS — quiet-period review-trigger anchor"
else
  echo "FAIL — quiet-period review-trigger anchor"
fi
exit "$failed"
