#!/usr/bin/env bash
# Behavioral test for the quiet-period + unaddressed-findings gate in
# claude-author-automerge.yml (wxa_vpn#1392).
#
# Incident context: review bots post findings continuously and nothing holds
# the door between the last review and the merge — four PRs merged 3m18s to
# 16m17s after a finding posted, with no commit in response (wxa_vpn#1385,
# #1376, #1378, #1345; the last two carried P1s). The gate holds the ARM (not
# the merge) until the conversation has been quiet for findings_quiet_minutes,
# then runs the unaddressed-findings detector; findings decline the arm and
# disarm any stale arm, never touching the manual merge button.
#
# Cases:
#   S1. structural: error-revoke counts steps.quiet_findings.outcome == 'failure'
#   S2. structural: Enable auto-merge requires quiet_findings.outputs.clear == '1'
#   S3. structural: extracted run block is ${{ }}-interpolation-free
#   S4. structural: all three anchor reads paginate
#   B1. findings_quiet_minutes=0 ⇒ clear=1 reason=disabled, ZERO gh calls
#   B2. quiet satisfied + detector clean ⇒ clear=1 reason=quiet+clean
#   B3. quiet satisfied + detector findings ⇒ clear=0 reason=findings,
#       --disable-auto called, sticky comment posted
#   B4. detector invocation error (rc=2) ⇒ nonzero exit (fail closed)
#   B5. young activity ⇒ sleeps the remaining window, then proceeds
#   B6. no anchor resolvable (empty commits+comments) ⇒ nonzero exit
#   B7. our own marker comment does NOT reset the clock (no sleep)
#   B8. chronic chatter ⇒ quiet-cap: clear=0 reason=quiet-cap + disarm
#   B9. anchor read fails 3x ⇒ nonzero exit (fail closed)
#   V1. vendored detector, --fixture: late bot P1 comment ⇒ rc=1
#   V2. vendored detector, --fixture: clean PR ⇒ rc=0
#
# Run from the repo root:
#   bash selftest/test_automerge_findings_gate.sh
set -euo pipefail

WF=.github/workflows/claude-author-automerge.yml
CHECKER=.github/scripts/unaddressed-findings.sh
failed=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# ---------------------------------------------------------------------------
# S1-S2. Structural pins.
# ---------------------------------------------------------------------------
if grep -q "steps.quiet_findings.outcome == 'failure'" "$WF"; then
  echo "✓ S1 error-revoke counts a failed quiet/findings read as a gate error"
else
  echo "✗ S1 error-revoke does not include steps.quiet_findings.outcome == 'failure' — a crashed gate leaves a stale arm alive"
  failed=1
fi
if awk '/^      - name: Enable auto-merge$/,/^        env:/' "$WF" \
    | grep -q "steps.quiet_findings.outputs.clear == '1'"; then
  echo "✓ S2 Enable auto-merge requires quiet_findings clear=1"
else
  echo "✗ S2 Enable auto-merge does not require steps.quiet_findings.outputs.clear == '1' — the gate is decorative"
  failed=1
fi

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

if ! grep -q 'QUIET_MINUTES' "$T/qf.sh" || ! grep -q 'GITHUB_OUTPUT' "$T/qf.sh"; then
  echo "✗ could not extract the quiet/findings run block from $WF"
  exit 1
fi
echo "✓ extracted quiet/findings step ($(wc -l < "$T/qf.sh" | tr -d ' ') lines)"

# S3. Interpolation-free (extraction-safe AND injection-safe).
if grep -q '${{' "$T/qf.sh"; then
  echo "✗ S3 run block contains \${{ }} interpolation — untestable standalone and an injection risk; use env vars"
  failed=1
else
  echo "✓ S3 run block is interpolation-free (env vars only)"
fi

# S4. All three anchor reads paginate.
for ep in 'pulls/${PR}/commits?per_page=100' 'pulls/${PR}/comments?per_page=100' 'issues/${PR}/comments?per_page=100'; do
  if grep -F "$ep" "$T/qf.sh" | grep -q -- '--paginate'; then
    echo "✓ S4 anchor read paginates: $ep"
  else
    echo "✗ S4 anchor read does not paginate: $ep — activity past page 1 resets no clock"
    failed=1
  fi
done

# ---------------------------------------------------------------------------
# Stub environment. Fake gh / date / sleep on PATH; per-case fixtures.
#
# Fake clock: NOW lives in $T_NOW; `date -u +%s` reads it, `sleep N`
# advances it by N (and logs the call). `date -u -d <ts> +%s` maps the
# fixture timestamps:
#   OLD    2026-01-01T00:00:00Z -> 1000000   (age >= quiet at start)
#   YOUNG  2026-01-01T02:00:00Z -> 1006800   (age 200s at start NOW=1007000)
#   CHATTY 2026-01-01T09:09:09Z -> NOW-100   (always 100s ago: livelock)
# ---------------------------------------------------------------------------
mkdir -p "$T/bin"

cat > "$T/bin/date" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "-u" ] && [ "$2" = "+%s" ]; then cat "$T_NOW"; exit 0; fi
if [ "$1" = "-u" ] && [ "$2" = "-d" ]; then
  case "$3" in
    2026-01-01T00:00:00Z) echo 1000000 ;;
    2026-01-01T02:00:00Z) echo 1006800 ;;
    2026-01-01T09:09:09Z) echo $(( $(cat "$T_NOW") - 100 )) ;;
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

# gh stub: dispatches on the call shape; logs every call. Steered by files
# in $T_DIR: commits.json / inline.json / issue.json fixtures, checker_rc
# (detector exit code), fail_commits (make the commits read fail).
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$T_DIR/gh.log"
case "$*" in
  *pulls/*/commits*)
    [ -f "$T_DIR/fail_commits" ] && exit 1
    cat "$T_DIR/commits.json"; exit 0 ;;
  *pulls/*/comments*)
    cat "$T_DIR/inline.json"; exit 0 ;;
  *contents/.github/scripts/unaddressed-findings.sh*)
    base64 < "$T_DIR/checker_stub.sh"; exit 0 ;;
  *issues/*/comments*--jq*)
    # sticky-comment lookup: report no existing comment
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
YOUNG_INLINE='[{"created_at":"2026-01-01T02:00:00Z","user":{"login":"github-actions[bot]"},"body":"[P2] something"}]'

# new_case — fresh fixture dir with empty defaults; cases overwrite fixtures
# BEFORE exec_gate. exec_gate <minutes> — run the extracted block once.
new_case() {
  CASE=$(mktemp -d "$T/case.XXXXXX")
  cat > "$CASE/checker_stub.sh" <<'EOF'
#!/usr/bin/env bash
echo "stub findings report line"
exit "$(cat "$T_DIR/checker_rc")"
EOF
  echo 1007000 > "$CASE/now"
  : > "$CASE/gh.log"; : > "$CASE/sleep.log"; : > "$CASE/calls.log"; : > "$CASE/output"
  echo '[]' > "$CASE/commits.json"
  echo '[]' > "$CASE/inline.json"
  echo '[]' > "$CASE/issue.json"
  echo 0 > "$CASE/checker_rc"
}
exec_gate() {
  set +e
  PATH="$T/bin:$PATH" T_DIR="$CASE" T_NOW="$CASE/now" \
    GITHUB_OUTPUT="$CASE/output" GITHUB_REPOSITORY="o/r" \
    PR=1 PR_URL="https://example.invalid/pr/1" QUIET_MINUTES="$1" \
    bash "$T/qf.sh" > "$CASE/stdout" 2>&1
  RC=$?
  set -e
}

# B1. Gate disabled: minutes=0 ⇒ clear=1 reason=disabled, ZERO gh calls.
new_case
exec_gate 0
if [ "$RC" -eq 0 ] && grep -q '^clear=1$' "$CASE/output" && grep -q '^reason=disabled$' "$CASE/output" \
   && [ ! -s "$CASE/gh.log" ]; then
  echo "✓ B1 minutes=0 disables the gate without touching the API"
else
  echo "✗ B1 minutes=0: rc=$RC output=[$(tr '\n' ' ' < "$CASE/output")] gh-calls=$(wc -l < "$CASE/gh.log" | tr -d ' ')"
  failed=1
fi

# B2. Quiet + clean ⇒ clear=1.
new_case
printf '%s' "$OLD_COMMITS" > "$CASE/commits.json"
exec_gate 20
if [ "$RC" -eq 0 ] && grep -q '^clear=1$' "$CASE/output" && grep -q '^reason=quiet+clean$' "$CASE/output"; then
  echo "✓ B2 quiet + clean detector arms (clear=1)"
else
  echo "✗ B2: rc=$RC output=[$(tr '\n' ' ' < "$CASE/output")] stdout: $(tail -3 "$CASE/stdout" | tr '\n' ' ')"
  failed=1
fi

# B3. Quiet + findings ⇒ clear=0, disarm, sticky comment.
new_case
printf '%s' "$OLD_COMMITS" > "$CASE/commits.json"
echo 1 > "$CASE/checker_rc"
exec_gate 20
if [ "$RC" -eq 0 ] && grep -q '^clear=0$' "$CASE/output" && grep -q '^reason=findings$' "$CASE/output" \
   && grep -q 'disable-auto' "$CASE/calls.log" && grep -q 'comment-posted' "$CASE/calls.log"; then
  echo "✓ B3 findings decline the arm, disarm stale arms, and post the sticky comment"
else
  echo "✗ B3: rc=$RC output=[$(tr '\n' ' ' < "$CASE/output")] calls=[$(tr '\n' ' ' < "$CASE/calls.log")] stdout: $(tail -3 "$CASE/stdout" | tr '\n' ' ')"
  failed=1
fi

# B4. Detector invocation error (rc=2) ⇒ nonzero exit (fail closed).
new_case
printf '%s' "$OLD_COMMITS" > "$CASE/commits.json"
echo 2 > "$CASE/checker_rc"
exec_gate 20
if [ "$RC" -ne 0 ]; then
  echo "✓ B4 detector error fails the step (fail closed; error-revoke disarms)"
else
  echo "✗ B4 detector rc=2 produced step rc=0 — an unreadable detector must never arm"
  failed=1
fi

# B5. Young activity ⇒ sleeps the remaining window, then proceeds.
new_case
printf '%s' "$OLD_COMMITS" > "$CASE/commits.json"
printf '%s' "$YOUNG_INLINE" > "$CASE/inline.json"
exec_gate 20
if [ "$RC" -eq 0 ] && grep -q '^clear=1$' "$CASE/output" && grep -q '^1000$' "$CASE/sleep.log"; then
  echo "✓ B5 young inline comment: slept the 1000s remainder, then armed"
else
  echo "✗ B5: rc=$RC sleeps=[$(tr '\n' ' ' < "$CASE/sleep.log")] output=[$(tr '\n' ' ' < "$CASE/output")]"
  failed=1
fi

# B6. No anchor resolvable ⇒ nonzero exit (an absence is not a timestamp).
new_case
exec_gate 20
if [ "$RC" -ne 0 ]; then
  echo "✓ B6 empty commits+comments fail closed (no anchor, no arm)"
else
  echo "✗ B6 empty fixtures produced rc=0 — a PR with no readable activity must not arm"
  failed=1
fi

# B7. Our own marker comment does NOT reset the clock.
new_case
printf '%s' "$OLD_COMMITS" > "$CASE/commits.json"
printf '%s' '[{"created_at":"2026-01-01T02:00:00Z","user":{"login":"github-actions[bot]"},"body":"<!-- claude-author-automerge:findings-gate -->\nAuto-merge withheld"}]' > "$CASE/issue.json"
exec_gate 20
if [ "$RC" -eq 0 ] && grep -q '^clear=1$' "$CASE/output" && [ ! -s "$CASE/sleep.log" ]; then
  echo "✓ B7 the gate's own sticky comment does not reset its clock"
else
  echo "✗ B7: rc=$RC sleeps=[$(tr '\n' ' ' < "$CASE/sleep.log")] output=[$(tr '\n' ' ' < "$CASE/output")] — the gate holds itself shut"
  failed=1
fi

# B8. Chronic chatter ⇒ quiet-cap: clear=0 reason=quiet-cap + disarm.
new_case
printf '%s' "$OLD_COMMITS" > "$CASE/commits.json"
printf '%s' '[{"created_at":"2026-01-01T09:09:09Z","user":{"login":"somebot[bot]"},"body":"chatter"}]' > "$CASE/issue.json"
exec_gate 20
if [ "$RC" -eq 0 ] && grep -q '^clear=0$' "$CASE/output" && grep -q '^reason=quiet-cap$' "$CASE/output" \
   && grep -q 'disable-auto' "$CASE/calls.log"; then
  echo "✓ B8 chronic chatter hits the cap: declined + disarmed, not livelocked"
else
  echo "✗ B8: rc=$RC output=[$(tr '\n' ' ' < "$CASE/output")] calls=[$(tr '\n' ' ' < "$CASE/calls.log")]"
  failed=1
fi

# B9. Anchor read fails 3x ⇒ nonzero exit (fail closed).
new_case
touch "$CASE/fail_commits"
exec_gate 20
if [ "$RC" -ne 0 ]; then
  echo "✓ B9 unreadable commits fail closed after retries"
else
  echo "✗ B9 commits read failing 3x produced rc=0 — blind arming"
  failed=1
fi

# ---------------------------------------------------------------------------
# V1-V2. Vendored detector twin, via its own --fixture seam.
# ---------------------------------------------------------------------------
FX="$T/fixture"
mkdir -p "$FX"
printf '%s' '{"merged_at": null, "last_commit": "2026-01-01T00:00:00Z"}' > "$FX/meta.json"
echo '[]' > "$FX/inline.json"
printf '%s' '[{"created_at":"2026-01-01T01:00:00Z","user":{"login":"github-actions[bot]"},"body":"- [P1] token validation bypassed — auth.py:41"}]' > "$FX/issue.json"
set +e
bash "$CHECKER" --fixture "$FX" o/r 1 >/dev/null 2>&1; v1=$?
echo '[]' > "$FX/issue.json"
bash "$CHECKER" --fixture "$FX" o/r 1 >/dev/null 2>&1; v2=$?
set -e
if [ "$v1" -eq 1 ]; then
  echo "✓ V1 vendored detector flags a late bot P1 (rc=1)"
else
  echo "✗ V1 vendored detector rc=$v1 on a late P1 — expected 1"
  failed=1
fi
if [ "$v2" -eq 0 ]; then
  echo "✓ V2 vendored detector passes a clean PR (rc=0)"
else
  echo "✗ V2 vendored detector rc=$v2 on a clean PR — expected 0"
  failed=1
fi

echo
if [ "$failed" -ne 0 ]; then
  echo "FAILED — see ✗ lines above"
  exit 1
fi
echo "all findings-gate cases passed"
