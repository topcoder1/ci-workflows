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
#   V3. vendored detector: backticked, line-less `regression:` path ⇒ rc=1
#       (wxa-jake-ai#1054 — this gate armed over it)
#   V4. vendored detector: "regression:" in prose ⇒ rc=0 (over-correction guard)
#   V5. vendored detector: root-level extensionless `Dockerfile:12` ⇒ rc=1
#       (the shape the OLD marker caught — the fix must not trade one for the
#       other)
#   V6. vendored detector: every markdown prefix in label position ⇒ rc=1
#       (bullet, `1.`, `1)`, `###`, `>`, nested and combined; the four the
#       V3-V5 anchor dropped)
#   V7. vendored detector: negated prose and empty buckets ⇒ rc=0, bare and
#       behind those same prefixes (the anchor's whole job)
#   V8. the prefix loop does not backtrack catastrophically — a long run of
#       `>` or `#` must not abort the regex engine
#   V9. vendored detector: a LATER PR cross-referencing this one prints the
#       follow-up hint — and rc STAYS 1 (advisory, never clears the gate)
#  V10. vendored detector: a fixture with no timeline.json still reports the
#       finding (the timeline read is a hint, never a dependency)
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

# ---------------------------------------------------------------------------
# V3-V4. `regression:` findings whose path carries no `:LINE`, or is backticked.
#
# wxa-jake-ai#1054: claude[bot] posted, 3m41s after the last commit,
#   regression: `tests/ci/prod-model-health-author-scope.test.ts` — no test pins
#   the cron schedule value ...
# and the detector reported "no unaddressed findings". FINDING_RE's marker was
# `regression: \S+:[0-9]+`, which demands a line number the finding did not have
# and cannot skip the backtick the path is wrapped in. Nothing matched, so the
# comment was never examined — and this gate armed auto-merge on a PR carrying a
# live finding. A second instance (#1067) merged the same way a week later.
#
# V4 is the over-correction guard, and it matters more than V3: this marker is
# the gate's sole admission test, so one that accepted any prose after
# `regression:` would decline every arm and get the whole gate switched off.
# Its NEGATED case ("No regression: package.json is unchanged") and its `n/a`
# case are both ones codex raised against the widening itself. CLEAN_RE knows
# only the plural "No regressions found", and the marker also sits in
# SEVERITY_RE, so each would have declined the arm on a clean review: the first
# without the label-position anchor, the second because `n/a` carries a slash
# that satisfies the path-shape test.
# ---------------------------------------------------------------------------
printf '%s' '[{"created_at":"2026-01-01T01:00:00Z","user":{"login":"claude[bot]"},"body":"regression: `tests/ci/prod-model-health-author-scope.test.ts` — no test pins the cron schedule value `7,22,37,52 * * * *`."}]' > "$FX/issue.json"
set +e
bash "$CHECKER" --fixture "$FX" o/r 1 >/dev/null 2>&1; v3=$?
printf '%s' '[{"created_at":"2026-01-01T01:00:00Z","user":{"login":"github-actions[bot]"},"body":"### Codex review\n\nregression: none\n\nregression: n/a\n\nNo regression: package.json is unchanged.\n\nThis introduced no regression: everything is covered."}]' > "$FX/issue.json"
bash "$CHECKER" --fixture "$FX" o/r 1 >/dev/null 2>&1; v4=$?
printf '%s' '[{"created_at":"2026-01-01T01:00:00Z","user":{"login":"github-actions[bot]"},"body":"### Codex review\n\nregression: Dockerfile:12 - the base image is stale"}]' > "$FX/issue.json"
bash "$CHECKER" --fixture "$FX" o/r 1 >/dev/null 2>&1; v5=$?
set -e
if [ "$v3" -eq 1 ]; then
  echo "✓ V3 vendored detector flags a backticked, line-less regression: path (rc=1)"
else
  echo "✗ V3 vendored detector rc=$v3 on the wxa-jake-ai#1054 body — expected 1; the gate would arm over a live finding"
  failed=1
fi
if [ "$v4" -eq 0 ]; then
  echo "✓ V4 vendored detector ignores 'regression:' in prose (rc=0)"
else
  echo "✗ V4 vendored detector rc=$v4 on prose containing 'regression:' — expected 0; a marker that matches everything gates nothing"
  failed=1
fi
if [ "$v5" -eq 1 ]; then
  echo "✓ V5 vendored detector still flags a root-level extensionless file:line (rc=1)"
else
  echo "✗ V5 vendored detector rc=$v5 on 'regression: Dockerfile:12' — expected 1; the widening traded one blind spot for another"
  failed=1
fi

# ---------------------------------------------------------------------------
# V6-V8. Markdown list, heading and blockquote prefixes in LABEL POSITION.
#
# The V3-V5 fix widened the path shape and, to reject negated prose, anchored
# the marker to the start of its line. That anchor allowed only a `-`/`*`/`+`
# bullet and `**` bold — and silently dropped four prefixes the ORIGINAL
# unanchored marker matched, all of which real bot findings use: `1.` and `1)`
# numbered lists, `###` headings, and `>` blockquotes. A narrower version of the
# same blind spot, in the gate's sole admission test.
#
# V6 pins the shapes that must be admitted, V7 the prose that must not — the
# anchor's whole job, re-checked with the wider prefix alphabet, including the
# negations wearing those same prefixes ("> No regression:", "1. No
# regression:"). The mechanism is that block markers are not WORDS: every
# negation phrasing puts a word between line start and marker.
#
# V8 pins the loop SHAPE. `([[:space:]]*(>+|#{1,6}|...))*` — a repeated group
# whose body also repeats — is the classic `(a+)+`: a run of N markers has
# 2^(N-1) partitions and Oniguruma walks them all. With `>+`/`#{1,6}` in place,
# 20 `>` then `regression: none` aborts jq with "Regex failure:
# retry-limit-in-match over". The detector sends jq's stderr to /dev/null, so
# that abort empties the finding list and the gate reads CLEAN — it would arm
# auto-merge on hostile input. jq is driven directly here because at detector
# level the abort and a genuine pass are the same rc and the same output.
# ---------------------------------------------------------------------------
mk_issue() {  # $1 = body, $2 = login (default claude[bot])
  jq -n --arg b "$1" --arg u "${2:-claude[bot]}" \
    '[{created_at:"2026-01-01T01:00:00Z",user:{login:$u},body:$b}]' > "$FX/issue.json"
}
expect_rc() {  # $1 = expected rc, $2 = case name, $3 = body, $4 = login
  mk_issue "$3" "${4:-claude[bot]}"
  set +e
  bash "$CHECKER" --fixture "$FX" o/r 1 >/dev/null 2>&1; local got=$?
  set -e
  if [ "$got" -eq "$1" ]; then
    echo "✓ $2"
  else
    echo "✗ $2 — rc=$got, expected $1"
    failed=1
  fi
}

# V6. MUST ACCEPT: every markdown prefix a bot may put in front of the marker.
expect_rc 1 "V6a  bare                     regression: src/foo.ts:12"        'regression: src/foo.ts:12'
expect_rc 1 "V6b  dash bullet              - regression: ..."               '- regression: src/foo.ts:12'
expect_rc 1 "V6c  star bullet + bold       * **regression:** ..."           '* **regression:** src/foo.ts:12'
expect_rc 1 "V6d  numbered list            1. regression: ..."              '1. regression: src/foo.ts:12'
expect_rc 1 "V6e  paren-numbered list      1) regression: ..."              '1) regression: src/foo.ts:12'
expect_rc 1 "V6f  heading                  ### regression: ..."             '### regression: src/foo.ts:12'
expect_rc 1 "V6g  blockquote               > regression: ..."               '> regression: src/foo.ts:12'
expect_rc 1 "V6h  nested blockquote        >> regression: ..."              '>> regression: src/foo.ts:12'
expect_rc 1 "V6i  spaced nested quote      > > regression: ..."             '> > regression: src/foo.ts:12'
expect_rc 1 "V6j  quote+number+bold        > 1. **regression:** ..."        '> 1. **regression:** src/foo.ts:12'
expect_rc 1 "V6k  indented bullet          '  - regression: ...'"           '  - regression: src/foo.ts:12'
expect_rc 1 "V6l  h1                       # regression: ..."               '# regression: src/foo.ts:12'
expect_rc 1 "V6m  h6                       ###### regression: ..."          '###### regression: src/foo.ts:12'
expect_rc 1 "V6n  prefix mid-body          header\n\n### regression: ..."   '**Second pass**

### regression: src/foo.ts:12'
expect_rc 1 "V6o  #1054 backticked pathless" 'regression: `tests/ci/prod-model-health-author-scope.test.ts` — no test pins the cron value'
expect_rc 1 "V6p  root extensionless       regression: Dockerfile:12"       'regression: Dockerfile:12 - the base image is stale'
expect_rc 1 "V6q  root extensionless       regression: Makefile:8"          'regression: Makefile:8 - the target is no longer built'

# V7. MUST REJECT: negated prose and empty buckets, bare and behind the new
# prefixes. Bot login, since these ride the issue-comment path.
expect_rc 0 "V7a  negation                 No regression: package.json ..."  'No regression: package.json is unchanged' 'github-actions[bot]'
expect_rc 0 "V7b  negation                 Not a regression: main.go:267 ..." 'Not a regression: main.go:267 is covered' 'github-actions[bot]'
expect_rc 0 "V7c  mid-sentence negation    ...shows no regression: main.go:267" 'the diff shows no regression: main.go:267 is covered' 'github-actions[bot]'
expect_rc 0 "V7d  quoted negation          > No regression: ..."            '> No regression: package.json is unchanged' 'github-actions[bot]'
expect_rc 0 "V7e  numbered negation        1. No regression: ..."           '1. No regression: package.json is unchanged' 'github-actions[bot]'
expect_rc 0 "V7f  heading negation         ### Not a regression: ..."       '### Not a regression: main.go:267 is covered' 'github-actions[bot]'
expect_rc 0 "V7g  empty bucket             regression: none"                'regression: none' 'github-actions[bot]'
expect_rc 0 "V7h  empty bucket             regression: n/a"                 'regression: n/a' 'github-actions[bot]'
expect_rc 0 "V7i  empty bucket             regression: nothing to report"   'regression: nothing to report' 'github-actions[bot]'
expect_rc 0 "V7j  not a path               regression: 3.2 seconds slower"  'regression: 3.2 seconds slower' 'github-actions[bot]'
expect_rc 0 "V7k  time of day              regression: 12:30 elapsed"       'regression: 12:30 elapsed' 'github-actions[bot]'
expect_rc 0 "V7l  quoted empty bucket      > regression: none"              '> regression: none' 'github-actions[bot]'
expect_rc 0 "V7m  heading empty bucket     ### regression: n/a"             '### regression: n/a' 'github-actions[bot]'

# V8. The prefix loop must not backtrack catastrophically. Read the shipped
# marker out of the detector rather than restating it — a copy here would pass
# forever while the real one rotted.
marker=$(sed -n "s/^_REGRESSION_MARKER='\(.*\)'\$/\1/p" "$CHECKER")
if [ -z "$marker" ]; then
  echo "✗ V8 could not extract _REGRESSION_MARKER from $CHECKER"
  failed=1
else
  bt_failed=0
  for spec in "60:>" "60:#" "40:*" "200:>"; do
    n=${spec%%:*}; ch=${spec#*:}
    run=$(awk -v n="$n" -v c="$ch" 'BEGIN{s="";for(i=0;i<n;i++)s=s c;print s}')
    set +e
    err=$(jq -rn --arg re "$marker" --arg b "${run}regression: none" \
            '($b|test($re;"i"))' 2>&1 >/dev/null); rc=$?
    set -e
    if [ "$rc" -ne 0 ] || [ -n "$err" ]; then
      echo "✗ V8 regex failed on ${n}x'${ch}' prefix run: ${err:-rc=$rc}"
      bt_failed=1
    fi
  done
  if [ "$bt_failed" -eq 0 ]; then
    echo "✓ V8 prefix loop survives long marker runs (no retry-limit abort)"
  else
    echo "  ↳ the loop backtracks: repeat SINGLE characters (>, #), not runs (>+, #{1,6})"
    failed=1
  fi
fi

# ---------------------------------------------------------------------------
# V9-V10. Follow-up cross-reference hint (dotclaude#216, ported here so the
# twins stay byte-identical below the vendored header).
#
# The detector's whole signal is "no commit on THIS PR answered the finding",
# and that stays true forever once the fix lands in a LATER PR — so the report
# never expires and every sweep re-dispatches finished work. inbox_superpilot
# #211 cost three sessions that way. The hint reads the timeline for PRs that
# cross-reference this one and prints them.
#
# What these two cases pin is the SAFETY shape of that hint, because it now
# runs inside the arming path:
#
#    V9 — rc STAYS 1 while the hint prints. A cross-reference proves a later PR
#         mentioned this one, NOT that the finding was fixed; if it cleared the
#         report, the gate would arm on the exact class it exists to catch, and
#         this file's whole B3 path would go quiet. The fixture also carries an
#         xref that PREDATES the finding — the `since` guard must suppress it,
#         or every long-lived PR grows a permanent false hint.
#   V10 — the timeline read is NON-FATAL. It is the one fetch in the script
#         guarded by `|| echo '[]'` rather than a fail-closed `exit 2`, because
#         it decorates a report that already stands on its own. A fixture with
#         no timeline.json (every V1-V8 fixture above) must still report the
#         finding. Inside the gate the same property means a timeline 403 or
#         outage degrades to "no hint", never to a detector error — which the
#         gate treats as rc!=1 and fails closed on.
#
# Cost note: the clean path returns BEFORE this block, so a PR with no findings
# makes zero timeline calls — the read is on the decline path only.
# ---------------------------------------------------------------------------
printf '%s' '[{"created_at":"2026-01-01T01:00:00Z","user":{"login":"github-actions[bot]"},"body":"- [P1] token validation bypassed — auth.py:41"}]' > "$FX/issue.json"
printf '%s' '[
  {"event":"cross-referenced","created_at":"2025-12-01T00:00:00Z",
   "source":{"issue":{"number":99,"state":"open","title":"predates the finding",
             "pull_request":{"merged_at":null}}}},
  {"event":"cross-referenced","created_at":"2026-01-02T00:00:00Z",
   "source":{"issue":{"number":213,"state":"closed","title":"test: pin the auth check",
             "pull_request":{"merged_at":"2026-01-02T01:00:00Z"}}}}
]' > "$FX/timeline.json"
set +e
out9=$(bash "$CHECKER" --fixture "$FX" o/r 1 2>&1); v9=$?
rm -f "$FX/timeline.json"
out10=$(bash "$CHECKER" --fixture "$FX" o/r 1 2>&1); v10=$?
set -e
if [ "$v9" -eq 1 ] && grep -q 'possible follow-up' <<<"$out9" \
   && grep -q '#213' <<<"$out9" && grep -q 'MERGED' <<<"$out9" \
   && ! grep -q '#99' <<<"$out9"; then
  echo "✓ V9 follow-up hint names the later PR, suppresses the earlier xref, and rc stays 1"
else
  echo "✗ V9 rc=$v9 — expected rc=1 with a '#213 MERGED' hint and no '#99'; got: $(tr '\n' ' ' <<<"$out9" | head -c 200)"
  failed=1
fi
if [ "$v10" -eq 1 ] && grep -q 'UNADDRESSED FINDINGS' <<<"$out10" \
   && ! grep -q 'possible follow-up' <<<"$out10"; then
  echo "✓ V10 a fixture with no timeline.json still reports the finding (hint is non-fatal)"
else
  echo "✗ V10 rc=$v10 — a missing timeline must degrade to 'no hint', not change the verdict; got: $(tr '\n' ' ' <<<"$out10" | head -c 200)"
  failed=1
fi

echo
if [ "$failed" -ne 0 ]; then
  echo "FAILED — see ✗ lines above"
  exit 1
fi
echo "all findings-gate cases passed"
