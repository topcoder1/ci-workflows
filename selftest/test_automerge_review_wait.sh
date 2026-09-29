#!/usr/bin/env bash
# Behavioral test for the REVIEW-COMPLETION wait in claude-author-automerge.yml's
# quiet-period gate (WS2 step 1 of the wxa_vpn maintenance program, 2026-09-29).
#
# WHY. The quiet gate arms only after findings_quiet_minutes of silence since
# the newest authored commit, inline comment, top-level bot comment,
# ready/reopen event and the PR's creation. Today a review lane's CLEAN comment
# is what stretches that window while a slower lane is still working: Claude
# Review lands at minute 7, the window moves to minute 27, and a Codex finding
# at minute 16 is read by the detector before the arm. WS2 steps 2-5 stop the
# clean comments. Without this wait the window would then be anchored on the
# push alone, and a review that finishes after minute 20 (a slow model, a
# queued runner) would post its finding after the arm: the wxa_vpn#1392 hole.
# So the gate now also requires every review check run on the head commit to
# have COMPLETED before it consults the detector.
#
# Cases:
#   R1  THE HOLE (AC2.3): the window has passed but a review is still running
#       and posts a finding when it completes. The gate waits for completion
#       and the detector declines. Before the change the gate consulted
#       before the finding existed and armed.
#   R2  a late clean review: wait for completion, then arm.
#   R3  over-correction guard: a review that already completed adds no wait.
#   R4a over-correction guard: only REVIEW checks hold the gate. A running
#       pytest, lint job or look-alike name does not.
#   R4b a caller-prefixed review lane (`review_standard / Codex Review`) holds it.
#   R5  the newest attempt of a check decides (a re-run supersedes).
#   R6  a token without `checks: read` falls back to the pre-change behavior,
#       loudly: one ::warning:: per run, never silently.
#   R7  any other read failure fails CLOSED, including a 403 that is a rate
#       limit rather than a missing permission.
#   R8  a review still running at the cap declines (quiet-cap) and names it.
#   R9  an empty review_check_names input is the pre-change behavior: no read.
#   R10 pagination: a running review on page 2 still holds the gate.
#   S1  structural: the read paginates and asks for every attempt (filter=all).
#   S2  structural: HEAD_SHA and REVIEW_CHECK_NAMES are bound in THIS step's env.
#
# Run from the repo root:
#   bash selftest/test_automerge_review_wait.sh
set -euo pipefail

WF=.github/workflows/claude-author-automerge.yml
failed=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# ---------------------------------------------------------------------------
# Extract the gate's run block and env block: the shipped bash, not a copy.
# ---------------------------------------------------------------------------
awk '
  /^      - name: Quiet period \+ unaddressed findings$/ { in_step=1 }
  in_step && /^        run: \|/ { in_run=1; next }
  in_run {
    if ($0 ~ /^          / || $0 == "") { sub(/^          /, ""); print }
    else { exit }
  }
' "$WF" > "$T/qf.sh"
awk '
  /^      - name: Quiet period \+ unaddressed findings$/ { in_step=1 }
  in_step && /^        run: \|/ { exit }
  in_step { print }
' "$WF" > "$T/qf_env.yml"

if ! grep -q 'read_anchor' "$T/qf.sh"; then
  echo "✗ could not extract the quiet/findings run block from $WF"
  exit 1
fi
echo "✓ extracted quiet/findings step ($(wc -l < "$T/qf.sh" | tr -d ' ') lines)"

# S1. One page of check runs holds at most 100; a PR with many checks pushes a
# review lane onto page 2 (R10 exercises the aggregation). filter=all returns
# every attempt so the newest one can decide (R5), whatever GitHub's default
# `latest` filter treats as latest.
# shellcheck disable=SC2016  # ${HEAD_SHA} is the literal text searched for.
if grep -F 'commits/${HEAD_SHA}/check-runs?filter=all&per_page=100' "$T/qf.sh" | grep -q -- '--paginate'; then
  echo "✓ S1 the check-runs read paginates and asks for every attempt"
else
  echo "✗ S1 the check-runs read must use filter=all&per_page=100 with --paginate"
  failed=1
fi

# S2. The run block is ${{ }}-free, so the two values live in the step's env.
# A missing binding leaves REVIEW_CHECK_NAMES empty, which is R9: the wait
# silently switched off with nothing red.
# shellcheck disable=SC2016  # the ${{ }} is the literal workflow text searched for.
if grep -q 'HEAD_SHA: ${{ github.event.pull_request.head.sha }}' "$T/qf_env.yml" &&
   grep -q 'REVIEW_CHECK_NAMES: ${{ inputs.review_check_names }}' "$T/qf_env.yml"; then
  echo "✓ S2 HEAD_SHA and REVIEW_CHECK_NAMES are bound in the step env"
else
  echo "✗ S2 the quiet step's env must bind HEAD_SHA and REVIEW_CHECK_NAMES"
  failed=1
fi

# ---------------------------------------------------------------------------
# Stubs. Fake clock: NOW lives in $T_NOW; `date -u +%s` reads it and `sleep N`
# advances it by N. Anchor timestamps:
#   OLD    2026-01-01T00:00:00Z -> 1000000   (age 7000s at NOW0: window passed)
#   YOUNG  2026-01-01T02:00:00Z -> 1006800   (age  200s at NOW0: 1000s left)
# A check run is fixture {id, name, done_at}; the gh stub reports it completed
# once NOW >= done_at, so a review "finishes" while the gate sleeps.
# ---------------------------------------------------------------------------
NOW0=1007000
DONE=$((NOW0 + 360))
PAST=$((NOW0 - 100))
NEVER=$((NOW0 + 999999))
mkdir -p "$T/bin"

cat > "$T/bin/date" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "-u" ] && [ "$2" = "+%s" ]; then cat "$T_NOW"; exit 0; fi
if [ "$1" = "-u" ] && [ "$2" = "-d" ]; then
  case "$3" in
    2026-01-01T00:00:00Z) echo 1000000 ;;
    2026-01-01T02:00:00Z) echo 1006800 ;;
    *) echo "date-stub: unmapped timestamp '$3'" >&2; exit 1 ;;
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

cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$T_DIR/gh.log"
case "$*" in
  *commits/*/check-runs*)
    if [ -f "$T_DIR/checkruns_error" ]; then cat "$T_DIR/checkruns_error" >&2; exit 1; fi
    now=$(cat "$T_NOW")
    for page in "$T_DIR"/checkruns_page*.json; do
      jq -c --argjson now "$now" '{total_count: length, check_runs: map({id, name,
        status: (if $now >= .done_at then "completed" else "in_progress" end)})}' "$page"
    done
    exit 0 ;;
  *pulls/*/commits*)
    cat "$T_DIR/commits.json"; exit 0 ;;
  *pulls/*/comments*)
    echo '[]'; exit 0 ;;
  *issues/*/timeline*)
    echo '[]'; exit 0 ;;
  *contents/.github/scripts/unaddressed-findings.sh*)
    base64 < "$T_DIR/checker_stub.sh"; exit 0 ;;
  *issues/*/comments*--jq*)
    exit 0 ;;
  *issues/*/comments*)
    echo '[]'; exit 0 ;;
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

DEFAULT_NAMES=$'Claude Review\nCodex Review\nClaude Adversarial Review\nverifier-evidence-bound-runner\n'

new_case() {
  CASE=$(mktemp -d "$T/case.XXXXXX")
  # The detector reports a finding only once the late review has posted it.
  cat > "$CASE/checker_stub.sh" <<'EOF'
#!/usr/bin/env bash
now=$(cat "$T_NOW")
if [ -f "$T_DIR/finding_at" ] && [ "$now" -ge "$(cat "$T_DIR/finding_at")" ]; then
  echo "stub: a finding the late review posted"; exit 1
fi
echo "stub: no unaddressed findings"; exit 0
EOF
  echo "$NOW0" > "$CASE/now"
  : > "$CASE/gh.log"; : > "$CASE/sleep.log"; : > "$CASE/calls.log"; : > "$CASE/output"
  echo '[{"parents":[{"sha":"x"}],"commit":{"committer":{"date":"2026-01-01T00:00:00Z"}}}]' > "$CASE/commits.json"
  echo '[]' > "$CASE/checkruns_page1.json"
}
runs() {  # $1 = page number, then "id|name|done_at" per check run
  local page=$1; shift
  printf '%s\n' "$@" | jq -R -s 'split("\n") | map(select(length > 0) | split("|")
    | {id: (.[0] | tonumber), name: .[1], done_at: (.[2] | tonumber)})' > "$CASE/checkruns_page$page.json"
}
exec_gate() {  # $1 = REVIEW_CHECK_NAMES
  set +e
  PATH="$T/bin:$PATH" T_DIR="$CASE" T_NOW="$CASE/now" \
    GITHUB_OUTPUT="$CASE/output" GITHUB_REPOSITORY="o/r" \
    PR=1 PR_URL="https://example.invalid/pr/1" QUIET_MINUTES=20 \
    PR_CREATED_AT="" HEAD_SHA="abc123" REVIEW_CHECK_NAMES="$1" \
    bash "$T/qf.sh" > "$CASE/stdout" 2>&1
  RC=$?
  set -e
}
polls() { grep -c '^60$' "$CASE/sleep.log" || true; }
report() {  # $1 = case id, $2 = description; uses RC and the case files
  echo "     rc=$RC output=[$(tr '\n' ' ' < "$CASE/output")] sleeps=[$(tr '\n' ' ' < "$CASE/sleep.log")]"
  echo "     stdout tail: $(tail -3 "$CASE/stdout" | tr '\n' ' ')"
}

# ---------------------------------------------------------------------------
# R1. THE HOLE. Every anchor is 7000s old, so the 1200s window has passed.
# Codex is still running and posts a finding when it completes 360s from now.
# The gate must poll until the review completes, then let the detector see
# the finding and decline.
# ---------------------------------------------------------------------------
new_case
runs 1 "10|review / Claude Review|$PAST" "11|review / Codex Review|$DONE"
echo "$DONE" > "$CASE/finding_at"
exec_gate "$DEFAULT_NAMES"
if [ "$RC" -eq 0 ] && grep -q '^clear=0$' "$CASE/output" && grep -q '^reason=findings$' "$CASE/output" \
   && [ "$(polls)" -eq 6 ] && grep -q 'disable-auto' "$CASE/calls.log"; then
  echo "✓ R1 a review still running past the window is waited for; its finding declines the arm"
else
  echo "✗ R1 the gate did not wait for the running review (the #1392 hole WS2 steps 2-5 would reopen)"
  report
  failed=1
fi

# R2. The same late review comes back clean: wait for it, then arm.
new_case
runs 1 "10|review / Claude Review|$PAST" "11|review / Codex Review|$DONE"
exec_gate "$DEFAULT_NAMES"
if [ "$RC" -eq 0 ] && grep -q '^clear=1$' "$CASE/output" && grep -q '^reason=quiet+clean$' "$CASE/output" \
   && [ "$(polls)" -eq 6 ]; then
  echo "✓ R2 a late clean review is waited for, then the gate clears"
else
  echo "✗ R2 a late clean review did not produce wait-then-clear"
  report
  failed=1
fi

# R3. Over-correction guard: reviews that already completed add no wait.
new_case
runs 1 "10|review / Claude Review|$PAST" "11|review / Codex Review|$PAST"
exec_gate "$DEFAULT_NAMES"
if [ "$RC" -eq 0 ] && grep -q '^clear=1$' "$CASE/output" && [ ! -s "$CASE/sleep.log" ]; then
  echo "✓ R3 completed reviews add no wait"
else
  echo "✗ R3 completed reviews still held the gate"
  report
  failed=1
fi

# R4a. Over-correction guard: only review lanes hold the gate. The rest of CI
# (pytest, lint) and names that merely resemble a lane never do; the required
# checks already gate the merge itself.
new_case
runs 1 "20|pytest|$NEVER" "21|lint / actionlint|$NEVER" "22|Codex Review Summary|$NEVER" \
  "23|review / Codex Reviewer|$NEVER" "24|review / Claude Review|$PAST"
exec_gate "$DEFAULT_NAMES"
if [ "$RC" -eq 0 ] && grep -q '^clear=1$' "$CASE/output" && [ ! -s "$CASE/sleep.log" ]; then
  echo "✓ R4a running non-review checks and look-alike names do not hold the gate"
else
  echo "✗ R4a a non-review check held the gate"
  report
  failed=1
fi

# R4b. A caller job id prefixes the reusable job name: `review_standard / Codex Review`.
new_case
runs 1 "30|review_standard / Codex Review|$DONE"
exec_gate "$DEFAULT_NAMES"
if [ "$RC" -eq 0 ] && grep -q '^clear=1$' "$CASE/output" && [ "$(polls)" -eq 6 ]; then
  echo "✓ R4b a caller-prefixed review lane holds the gate until it completes"
else
  echo "✗ R4b the gate did not match '<caller job> / Codex Review'"
  report
  failed=1
fi

# R5. The newest attempt decides. A re-run (higher id) still running holds the
# gate even though an earlier attempt completed, and an earlier attempt still
# listed as running does not hold it once a newer attempt completed.
new_case
runs 1 "40|review / Claude Review|$PAST" "41|review / Claude Review|$DONE"
exec_gate "$DEFAULT_NAMES"
r5a_ok=0
if [ "$RC" -eq 0 ] && grep -q '^clear=1$' "$CASE/output" && [ "$(polls)" -eq 6 ]; then r5a_ok=1; fi
new_case
runs 1 "40|review / Claude Review|$NEVER" "41|review / Claude Review|$PAST"
exec_gate "$DEFAULT_NAMES"
if [ "$r5a_ok" -eq 1 ] && [ "$RC" -eq 0 ] && grep -q '^clear=1$' "$CASE/output" && [ ! -s "$CASE/sleep.log" ]; then
  echo "✓ R5 the newest attempt of each review check decides"
else
  echo "✗ R5 the gate did not judge each review by its newest attempt (r5a_ok=$r5a_ok)"
  report
  failed=1
fi

# R6. A token without `checks: read` (28 of 42 callers on 2026-09-29) falls
# back to the pre-change behavior and says so once per run. A YOUNG commit
# makes the loop run twice, so "once" is tested, not assumed.
new_case
echo '[{"parents":[{"sha":"x"}],"commit":{"committer":{"date":"2026-01-01T02:00:00Z"}}}]' > "$CASE/commits.json"
echo 'gh: Resource not accessible by integration (HTTP 403)' > "$CASE/checkruns_error"
exec_gate "$DEFAULT_NAMES"
warnings=$(grep -c '::warning::' "$CASE/stdout" || true)
if [ "$RC" -eq 0 ] && grep -q '^clear=1$' "$CASE/output" && [ "$warnings" -eq 1 ] \
   && [ "$(tr '\n' ' ' < "$CASE/sleep.log")" = "1000 " ]; then
  echo "✓ R6 a token without checks: read falls back to the comment window with one warning"
else
  echo "✗ R6 the missing-permission fallback misbehaved (warnings=$warnings)"
  report
  failed=1
fi

# R7. Every other failure fails closed: a server error, and a 403 that is a
# secondary rate limit, not a missing permission. Three attempts, then exit 1.
r7_ok=1
for err in 'gh: Server Error (HTTP 502)' 'gh: You have exceeded a secondary rate limit (HTTP 403)'; do
  new_case
  echo "$err" > "$CASE/checkruns_error"
  exec_gate "$DEFAULT_NAMES"
  attempts=$(grep -c 'check-runs' "$CASE/gh.log" || true)
  if [ "$RC" -ne 1 ] || grep -q '^clear=' "$CASE/output" || [ "$attempts" -ne 3 ] \
     || ! grep -q 'check runs' "$CASE/stdout"; then
    echo "✗ R7 '$err' did not fail closed after 3 attempts (attempts=$attempts)"
    report
    r7_ok=0
  fi
done
if [ "$r7_ok" -eq 1 ]; then
  echo "✓ R7 other check-runs read failures fail closed after 3 attempts"
else
  failed=1
fi

# R8. A review that never finishes: poll to the cap (3 x 1200s), then decline
# via quiet-cap, disarm, and name the lane that was still running.
new_case
runs 1 "50|review / Codex Review|$NEVER"
exec_gate "$DEFAULT_NAMES"
if [ "$RC" -eq 0 ] && grep -q '^clear=0$' "$CASE/output" && grep -q '^reason=quiet-cap$' "$CASE/output" \
   && grep -q 'disable-auto' "$CASE/calls.log" && grep -q 'review / Codex Review' "$CASE/stdout"; then
  echo "✓ R8 a review still running at the cap declines via quiet-cap and is named"
else
  echo "✗ R8 the cap path did not decline and name the running review"
  report
  failed=1
fi

# R9. An empty input is the pre-change behavior: no check-runs read at all.
new_case
runs 1 "60|review / Codex Review|$NEVER"
exec_gate ""
if [ "$RC" -eq 0 ] && grep -q '^clear=1$' "$CASE/output" && ! grep -q 'check-runs' "$CASE/gh.log" \
   && [ ! -s "$CASE/sleep.log" ]; then
  echo "✓ R9 an empty review_check_names reads no check runs and waits for none"
else
  echo "✗ R9 an empty review_check_names still read or waited on check runs"
  report
  failed=1
fi

# R10. Pagination: page 1 is complete, page 2 has the running review.
new_case
runs 1 "70|review / Claude Review|$PAST"
runs 2 "71|review / Codex Review|$DONE"
exec_gate "$DEFAULT_NAMES"
if [ "$RC" -eq 0 ] && grep -q '^clear=1$' "$CASE/output" && [ "$(polls)" -eq 6 ]; then
  echo "✓ R10 a running review on page 2 still holds the gate"
else
  echo "✗ R10 the gate read only page 1 of the check runs"
  report
  failed=1
fi

if [ "$failed" -ne 0 ]; then
  echo "FAILED"
  exit 1
fi
echo "PASSED"
