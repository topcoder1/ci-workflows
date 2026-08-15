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
#   V8. neither the normalizer nor the marker backtracks catastrophically —
#       400-char runs of `>` `#` `*` `-` `|` `_` `` ` `` `1.` must not abort
#       the regex engine (an abort reads as CLEAN and ARMS auto-merge)
#   V9. SUPERSET INVARIANT, differential: every shape the ORIGINAL marker
#       matched must still match, over the cross product of block prefix ×
#       marker spelling × path wrapping × with/without `:LINE` (2688 shapes).
#       V9b: negations and empty buckets still rejected across the same matrix
#  V10. the P-label clause and the marker share ONE definition of "label
#       prefix" — a `[P2]` under a heading / in a list / quote / checkbox /
#       table row overrides a CLEAN phrase, disclaimers still do not
#  V11. the wrappers and prefixes round 3 lost outright, end-to-end: bold,
#       backtick-in-bold, markdown link, quoted, parenthesized paths; checkbox
#       and table-row items; colon-outside-bold and code-span marker spellings
#  V14. follow-up hint: a LATER PR cross-referencing this one is printed, and
#       rc STAYS 1 (advisory, never clears the gate)
#  V15. follow-up hint: a fixture with no timeline.json still reports the
#       finding (the timeline read is a hint, never a dependency)
#  V16. vendored detector: a cross-repo cross-reference is printed OWNER/REPO#N,
#       never as a bare #N that points at an unrelated local PR
#  V17. vendored detector: a same-repo cross-reference stays terse #N even when
#       the event carries repository.full_name (over-correction guard)
#  V18. vendored detector: a cross-repo xref whose event omits the repository
#       object recovers the slug from html_url
#  V19. vendored detector: slug comparison is case-insensitive, so `Owner/Repo`
#       against owner/repo stays terse (second over-correction guard)
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

# S4. All FOUR anchor reads paginate. The timeline read is the review-trigger
# anchor (wxa_vpn#1512); its behaviour is pinned in test_automerge_quiet_anchor.sh,
# but it belongs in this loop because the loop's claim is "every anchor read
# paginates" — a list that enumerates three of four silently stops being that.
for ep in 'pulls/${PR}/commits?per_page=100' 'pulls/${PR}/comments?per_page=100' \
          'issues/${PR}/comments?per_page=100' 'issues/${PR}/timeline?per_page=100'; do
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
  *issues/*/timeline*)
    # The review-trigger anchor (wxa_vpn#1512). Empty here on purpose: the
    # cases in THIS file are about the quiet/findings decision, and an empty
    # timeline is the pre-fix anchor set exactly. Its own behaviour — a recent
    # ready_for_review must anchor, an old one must not, unrelated events must
    # not, an unreadable read must fail closed — is pinned in
    # selftest/test_automerge_quiet_anchor.sh.
    echo '[]'; exit 0 ;;
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
  # PR_CREATED_AT pinned empty: the c5 anchor belongs to
  # test_automerge_quiet_anchor.sh; an ambient value exported in a
  # developer's shell would otherwise activate it here and fail the
  # zero-sleep cases nondeterministically.
  PATH="$T/bin:$PATH" T_DIR="$CASE" T_NOW="$CASE/now" \
    GITHUB_OUTPUT="$CASE/output" GITHUB_REPOSITORY="o/r" \
    PR=1 PR_URL="https://example.invalid/pr/1" QUIET_MINUTES="$1" \
    PR_CREATED_AT="" \
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

# ---------------------------------------------------------------------------
# V8-V10 (round 4). The detector now NORMALIZES the body and then applies a
# simple marker to the residue, instead of enumerating markdown's formatting
# space inside one expression. Read all three pieces out of the detector rather
# than restating them — a copy here would pass forever while the real one rots.
# ---------------------------------------------------------------------------
blk=$(sed -n "s/^_BLOCK_PREFIX='\(.*\)'\$/\1/p" "$CHECKER")
mark=$(sed -n "s/^_MARKER_CANON='\(.*\)'\$/\1/p" "$CHECKER")
marker=$(sed -n "s/^_REGRESSION_MARKER='\(.*\)'\$/\1/p" "$CHECKER")
canon=$(sed -n 's/^ *\(def canon:.*\)$/\1/p' "$CHECKER")
if [ -z "$blk" ] || [ -z "$mark" ] || [ -z "$marker" ] || [ -z "$canon" ]; then
  echo "✗ V8-V10 could not extract the normalizer + marker from $CHECKER"
  failed=1
else

# V8. Nothing in the pipeline may backtrack catastrophically. An Oniguruma
# retry-limit abort exits jq non-zero with an empty result, and the detector
# sends jq's stderr to /dev/null — so the finding list comes back empty, the
# gate reads CLEAN and ARMS AUTO-MERGE on hostile input. jq is driven directly
# here because at detector level the abort and a genuine pass are the same rc
# and the same output. Runs like these are ordinary in bot comments: quoted
# replies nest, and a pasted conflict marker is seven `>`.
#
# The property being pinned is that every repetition consumes a FIXED number of
# characters per iteration. _BLOCK_PREFIX is stronger still — `^`-anchored with
# nothing after it, so it always succeeds and can never be made to retry.
bt_failed=0
# shellcheck disable=SC1111  # the “ is a hostile INPUT character, not a
# shell quote: models autocorrect quotes and the normalizer must survive
# a 400-long run of them without a retry-limit abort.
for spec in "400:>" "400:#" "400:*" "400:-" "400:|" "400:_" "400:\`" "400:1." \
            "400:•" "400:–" "400:—" "400:\"" "400:'" "400:(" "400:[" "400:<" "400:“"; do
  n=${spec%%:*}; ch=${spec#*:}
  run=$(awk -v n="$n" -v c="$ch" 'BEGIN{s="";for(i=0;i<n;i++)s=s c;print s}')
  for tail in "" "regression: none" "regression: src/foo.ts:12"; do
    set +e
    err=$(jq -rn --arg blk "$blk" --arg mark "$mark" --arg re "$marker" \
            --arg b "${run}${tail}" "$canon"' ($b|canon|test($re;"i"))' 2>&1 >/dev/null); rc=$?
    set -e
    if [ "$rc" -ne 0 ] || [ -n "$err" ]; then
      echo "✗ V8 regex failed on ${n}x'${ch}' + '${tail}': ${err:-rc=$rc}"
      bt_failed=1
    fi
  done
done
if [ "$bt_failed" -eq 0 ]; then
  echo "✓ V8 normalizer + marker survive 400-char hostile runs (no retry-limit abort)"
else
  echo "  ↳ something backtracks: every repetition must consume a FIXED count"
  failed=1
fi

# V9. THE SUPERSET INVARIANT, differentially, over a cross product.
#
# Rounds 2, 3 and 4 each fixed the shape they were looking at and silently
# stopped matching shapes the ORIGINAL marker (`regression: \S+:[0-9]+`, still
# on origin/main) did match. None was caught by a test, because each round
# tested only what it had just fixed, and — the deeper failure — each round's
# corpus could only express the shapes its own composition allowed.
#
# ROUND 5 WIDENED THE AXES for exactly that reason. Round 4 composed bodies as
# `prefix + spelling + " " + wrap(path) + tail`, and EVERY prefix in the axis
# ENDED WITH A SPACE, so two whole families were unreachable by construction no
# matter how many entries the axes grew:
#
#   * a TIGHT bullet — `-regression: src/foo.ts:12` — which round 4 stopped
#     matching and rounds 1 AND 3 both matched (~99 shapes, a two-way loss);
#   * punctuation wrapping the WHOLE marker — `"regression: main.go:267"`,
#     `(regression: main.go)`, `[regression: main.go]` — which round 1 matched
#     (its `\S+` never looked left) and rounds 2, 3 and 4 all dropped.
#
# So the space between prefix and marker is an AXIS now, and so is the wrapping
# around the marker as a whole, and the unicode bullets and dashes models
# actually paste are in the prefix alphabet. Measured over these widened axes:
# round 3 loses 3686 shapes vs the original (2686 undeclared), round 4 loses
# 3430 (2430 undeclared), round 5 loses 1000 which — OVER THIS ALPHABET — are
# all negations, the single narrowing the label-position anchor exists to make.
#
# ROUND 6 SCOPES THAT CLAIM, because it was read as a universal one and is not.
# The invariant holds over the ENUMERATED corpus below, not over markdown:
# independent corpora put the out-of-alphabet residual at roughly 10,200 bodies
# the original matched and the shipped marker misses, none of them negations —
# unicode leads beyond the three listed, paren-wrapped ordered items, HTML tags,
# strikethrough, leading colon/caret/tilde, zero-width space, BOM. That residual
# is ACCEPTED: none is attested in real bot traffic, and each addition widens
# FINDING_RE, which is the sole admission gate. See the detector's own
# SUPERSET INVARIANT note for the full argument.
#
# `lost` = matched by the original, not by the shipped marker — a regression.
# `missed` = not matched at all, which also covers the shapes the original was
# itself blind to (a pathless `main.go`, `**regression:**` with no space after
# the colon), so a pure superset check could not have caught them.
ORIGINAL='regression: \S+:[0-9]+'
v9=$(jq -n --arg blk "$blk" --arg mark "$mark" --arg new "$marker" --arg orig "$ORIGINAL" "$canon"'
  ["", "  ", "-", "*", "+", "- [ ]", "- [x]", "- [X]", "1.", "1)", "10.",
   "#", "###", "######", ">", ">>", "> >", "> -", "|", "| -", "  > 1.",
   "> - [ ]", "\u2022", "\u2013", "\u2014"] as $pfx
  | ["", " "] as $sp
  | ["regression:", "**regression:**", "**regression**:", "*regression:*",
     "*regression*:", "__regression:__", "__regression__:", "`regression:`"] as $spl
  | ["WHOLE", "\"WHOLE\"", "\u0027WHOLE\u0027", "(WHOLE)", "[WHOLE]"] as $whl
  | ["PATH", "`PATH`", "**PATH**", "**`PATH`**", "[PATH](https://example.com/x)",
     "\"PATH\"", "\u0027PATH\u0027", "(PATH)",
     "\u201cPATH\u201d", "\u2018PATH\u2019", "<PATH>"] as $wrp
  | ["src/lib/main.go", "src/lib/main.go:267"] as $pth
  | [ $pfx[] as $p | $sp[] as $x | $spl[] as $s | $whl[] as $h | $wrp[] as $w | $pth[] as $t
      | $p + $x + ($h | sub("WHOLE"; $s + " " + ($w | sub("PATH"; $t))))
        + " — no test covers the new branch" ]
  | (length - (unique | length)) as $dupes
  | map({b: ., orig: test($orig; "i"), new: (canon | test($new; "i"))})
  | {total: length, dupes: $dupes,
     lost:   [.[] | select(.orig and (.new | not)) | .b],
     missed: [.[] | select(.new | not) | .b]}')
v9_total=$(printf '%s' "$v9" | jq -r '.total')
v9_lost=$(printf '%s' "$v9" | jq -r '.lost | length')
v9_missed=$(printf '%s' "$v9" | jq -r '.missed | length')
# The corpus must hold DISTINCT BODIES. Round 4 checked distinct AXIS ENTRIES,
# which is strictly weaker — two different axis values can still compose into
# the same body. This is not pedantry either way. The single-quoted path wrapper
# was first written with literal apostrophes inside this single-quoted jq
# program, where the shell ate them and collapsed that entry into a duplicate of
# the bare wrapper — so the single-quoted shape went untested while `total`
# stayed at its expected value and every case still passed. A linter caught it
# (SC2026); a stable case count never would. Every quote and unicode character
# is spelled \uXXXX for that reason, and this guard is the backstop: a corpus
# that cannot detect its own collapse proves nothing.
v9_dupes=$(printf '%s' "$v9" | jq -r '.dupes')
if [ "$v9_dupes" -ne 0 ]; then
  echo "✗ V9 corpus has $v9_dupes duplicate BODIES — those shapes are silently untested"
  failed=1
elif [ "$v9_lost" -eq 0 ] && [ "$v9_missed" -eq 0 ]; then
  echo "✓ V9 superset invariant holds over $v9_total cross-product shapes (0 lost, 0 missed)"
else
  echo "✗ V9 superset invariant BROKEN: $v9_lost lost vs the original, $v9_missed unmatched of $v9_total"
  printf '%s' "$v9" | jq -r '(.lost + .missed) | unique | .[0:8][] | "    " + .'
  failed=1
fi

# V9b. The reject side, over the SAME widened axes — spacing, whole-marker
# wrapping and the unicode prefixes included. The path-SHAPE test is the sole
# admission gate: a marker that accepts prose flags every comment containing the
# word, and a sweeper that cries wolf gets ignored. Running the reject corpus
# over every axis the accept corpus gained is what keeps a widening honest.
v9b=$(jq -n --arg blk "$blk" --arg mark "$mark" --arg new "$marker" "$canon"'
  ["", "  ", "-", "- [ ]", "1.", "###", ">", ">>", "|", "> - [ ]",
   "\u2022", "\u2014"] as $pfx
  | ["", " "] as $sp
  | ["regression:", "**regression:**", "**regression**:", "`regression:`"] as $spl
  | ["WHOLE", "\"WHOLE\"", "\u0027WHOLE\u0027", "(WHOLE)", "[WHOLE]"] as $whl
  | ["none", "nothing to report", "n/a", "N/A", "not applicable",
     "3.2 seconds slower", "12:30 elapsed"] as $empty
  | ["No regression: package.json is unchanged",
     "Not a regression: main.go:267 is covered",
     "the diff shows no regression: main.go:267 is covered",
     "See regression: main.go:267 for the earlier discussion"] as $neg
  | [ $pfx[] as $p | $sp[] as $x | $whl[] as $h
      | ( ($spl[] as $s | $empty[] as $e
           | $p + $x + ($h | sub("WHOLE"; $s + " " + $e))),
          ($neg[] as $n | $p + $x + ($h | sub("WHOLE"; $n))) ) ]
  | {total: length, fired: [.[] | select(canon | test($new; "i"))]}')
v9b_total=$(printf '%s' "$v9b" | jq -r '.total')
v9b_fired=$(printf '%s' "$v9b" | jq -r '.fired | length')
if [ "$v9b_fired" -eq 0 ]; then
  echo "✓ V9b negations and empty buckets still rejected across $v9b_total shapes"
else
  echo "✗ V9b the widened marker fired on $v9b_fired of $v9b_total prose shapes"
  printf '%s' "$v9b" | jq -r '.fired[0:8][] | "    " + .'
  failed=1
fi

fi  # normalizer extraction guard

# V10. TWO definitions of "label prefix", and that is the DESIGN — not the drift
# round 4 read it as.
#
# Round 4 deleted SEVERITY_RE's own bullet prefix and routed the P-label clause
# through the normalizer, reasoning that widening an ASSERTION test can only
# ever flag more. That reasoning holds for FINDING_RE, which decides whether a
# comment is examined at all. It is exactly backwards for SEVERITY_RE, which
# admits nothing: it CANCELS CLEAN_RE. Widening a suppressor loses findings;
# widening the thing that overrides a suppressor MANUFACTURES FALSE POSITIVES.
#
# Measured, 8 shapes out of 8 (V10f-V10m): a re-review that quotes, tabulates or
# checks off the previous round's finding and then passes returned rc=0 under
# round 3 and rc=1 under round 4. For the automerge gate that is worse than for
# the operator sweep — a false finding DECLINES THE ARM on a clean PR, and a
# gate that blocks passing PRs gets switched off, at which point it protects
# nothing at all.
#
# So SEVERITY_RE reads the RAW body and allows a bullet and nothing else, while
# the regression marker reads the NORMALIZED body and allows the full block
# alphabet. They are allowed to disagree because they are not the same kind of
# test: the marker carries its own admission gate — a path-shaped token — so it
# cannot fire on quoted prose, and a bare `[P1]` is quoted constantly.
V10_CLEAN='### Codex review

No regressions found on the coverage axis.

'
# MUST override: the bullet position codex actually emits, tight and spaced.
expect_rc 1 "V10a bare P-label overrides CLEAN"      "${V10_CLEAN}[P1] Token check is skippable — auth.py:31" 'github-actions[bot]'
expect_rc 1 "V10b bullet P-label overrides CLEAN"    "${V10_CLEAN}- [P2] Contract drift — send_request.go:462" 'github-actions[bot]'
expect_rc 1 "V10c bullet bold P overrides CLEAN"     "${V10_CLEAN}- **P2** Contract drift — send_request.go:462" 'github-actions[bot]'
expect_rc 1 "V10d bare bold P overrides CLEAN"       "${V10_CLEAN}**P1** unscoped token reaches push — auth.py:31" 'github-actions[bot]'
expect_rc 1 "V10e bare P0-dash overrides CLEAN"      "${V10_CLEAN}P0 — credentials are logged in plaintext" 'github-actions[bot]'

# MUST NOT override: the eight shapes round 4 flipped. Each body is a PASS that
# recites an earlier finding and stamps a clean verdict.
V10_QUOTED='### Codex review

Re-reviewed after the fix. The previous round said:

'
V10_TAIL='

All of that is now addressed. No issues found. VERDICT: CLEAN'
expect_rc 0 "V10f quoted [P1] stays CLEAN"           "${V10_QUOTED}> [P1] Token check is skippable — auth.py:31${V10_TAIL}" 'github-actions[bot]'
expect_rc 0 "V10g quoted **P1** stays CLEAN"         "${V10_QUOTED}> **P1** Token check is skippable — auth.py:31${V10_TAIL}" 'github-actions[bot]'
expect_rc 0 "V10h quoted P1-dash stays CLEAN"        "${V10_QUOTED}> P1 — credentials are logged in plaintext${V10_TAIL}" 'github-actions[bot]'
expect_rc 0 "V10i numbered [P2] stays CLEAN"         "${V10_QUOTED}1. [P2] Contract drift — send_request.go:462${V10_TAIL}" 'github-actions[bot]'
expect_rc 0 "V10j heading bold P1 stays CLEAN"       "${V10_QUOTED}### **P1** Token check is skippable — auth.py:31${V10_TAIL}" 'github-actions[bot]'
expect_rc 0 "V10k table-row [P1] stays CLEAN"        "${V10_QUOTED}| [P1] Token check is skippable — auth.py:31 |${V10_TAIL}" 'github-actions[bot]'
expect_rc 0 "V10l checked-checkbox [P1] stays CLEAN" "${V10_QUOTED}- [x] [P1] Token check is skippable — auth.py:31${V10_TAIL}" 'github-actions[bot]'
expect_rc 0 "V10m nested-quote [P0] stays CLEAN"     "${V10_QUOTED}>> [P0] Credentials logged in plaintext — auth.py:88${V10_TAIL}" 'github-actions[bot]'

# The disclaimer and empty-bucket cases, unchanged: a word before the label and
# a bucket with nothing in it are rejected regardless of which body is read.
expect_rc 0 "V10n quoted disclaimer stays CLEAN"     '### Codex review

> No [P1] or [P2] issues found. VERDICT: CLEAN' 'github-actions[bot]'
expect_rc 0 "V10o checkbox empty bucket stays CLEAN" '### Codex review

- [ ] P1: none
- [x] P2: none

VERDICT: CLEAN' 'github-actions[bot]'

# ROUND 6: the regression marker overrides CLEAN with ROUND 3'S prefix alphabet
# and no more, applied to the RAW body like every other severity signal.
#
# Round 5 left this one term reading canon's output, to keep round 3's
# `- regression: ...` override alive. It kept that and bought the whole block
# alphabet with it — 76 of 484 measured suppressor-side shapes flipped to a
# false decline, 66 of them on one 9-prefix × 8-wrapping grid. The term now uses
# `_REGRESSION_MARKER_RAW`, which is round 3's marker verbatim, so the override
# set is round 3's exactly: V13 below measures both directions and requires
# zero. V10p is the shape round 5 was protecting and it still passes.
expect_rc 1 "V10p bullet regression overrides CLEAN" "${V10_CLEAN}- regression: src/foo.ts:12 — no test covers X" 'github-actions[bot]'
expect_rc 1 "V10q star bullet regression overrides CLEAN" "${V10_CLEAN}* regression: src/foo.ts:12 — no test covers X" 'github-actions[bot]'
expect_rc 1 "V10r quote regression overrides CLEAN" "${V10_CLEAN}> regression: src/foo.ts:12 — no test covers X" 'github-actions[bot]'
expect_rc 1 "V10s numbered regression overrides CLEAN" "${V10_CLEAN}1. regression: src/foo.ts:12 — no test covers X" 'github-actions[bot]'
expect_rc 1 "V10t backticked path overrides CLEAN" "${V10_CLEAN}regression: \`src/foo.ts\` — no test covers X" 'github-actions[bot]'

# THE ROUND-5 FALSE POSITIVE, pinned so it cannot come back. Every one of these
# is a PASS: a re-review that recites the previous round's regression line and
# stamps a clean verdict. Each returned rc=0 under round 3, rc=1 under round 5.
#
# V10u is the sharpest of them and the reason this round exists. A CHECKED
# checkbox is the universal notation for an ADDRESSED finding, so round 5
# declined the merge precisely when the evidence said the finding was resolved.
# For the automerge gate that is worse than for the operator sweep: a false
# finding declines the arm on a clean PR, and a gate that blocks passing PRs
# gets switched off, at which point it protects nothing at all.
V10_QUOTED_REG='### Codex review

Re-reviewed after the fix. The previous round said:

'
expect_rc 0 "V10u checked checkbox regression stays CLEAN" '- [x] regression: src/foo.ts:12 - fixed in 2a5937e
No issues found. VERDICT: CLEAN' 'github-actions[bot]'
expect_rc 0 "V10v open checkbox regression stays CLEAN"  "${V10_QUOTED_REG}- [ ] regression: src/foo.ts:12 — no test covers X${V10_TAIL}" 'github-actions[bot]'
expect_rc 0 "V10w table-row regression stays CLEAN"      "${V10_QUOTED_REG}| regression: src/foo.ts:12 — no test covers X |${V10_TAIL}" 'github-actions[bot]'
expect_rc 0 "V10x quoted-whole regression stays CLEAN"   "${V10_QUOTED_REG}\"regression: src/foo.ts:12 — no test covers X\"${V10_TAIL}" 'github-actions[bot]'
expect_rc 0 "V10y paren-whole regression stays CLEAN"    "${V10_QUOTED_REG}(regression: src/foo.ts:12 — no test covers X)${V10_TAIL}" 'github-actions[bot]'
expect_rc 0 "V10z unicode-bullet regression stays CLEAN" "${V10_QUOTED_REG}• regression: src/foo.ts:12 — no test covers X${V10_TAIL}" 'github-actions[bot]'
expect_rc 0 "V10aa bold path regression stays CLEAN"     "${V10_QUOTED_REG}regression: **src/foo.ts:12** — no test covers X${V10_TAIL}" 'github-actions[bot]'

# V11. The path WRAPPERS and the two block prefixes round 3 lost outright,
# driven end-to-end through the detector rather than through jq.
expect_rc 1 "V11a bold path                  regression: **src/foo.ts**"       'regression: **src/foo.ts:12** — no test'
expect_rc 1 'V11b backtick-in-bold path      regression: **`src/foo.ts`**'     'regression: **`src/foo.ts`** — no test'
expect_rc 1 "V11c markdown-link path         regression: [src/foo.ts:12](...)" 'regression: [src/foo.ts:12](https://example.com/x) — no test'
expect_rc 1 "V11d double-quoted path         regression: \"src/foo.ts\""       'regression: "src/foo.ts" — no test'
expect_rc 1 "V11e single-quoted path         regression: (single-quoted)"      "regression: 'src/foo.ts' — no test"
expect_rc 1 "V11f parenthesized path         regression: (src/foo.ts:12)"      'regression: (src/foo.ts:12) — no test'
expect_rc 1 "V11g checkbox item              - [ ] regression: ..."            '- [ ] regression: src/foo.ts:12 — no test'
expect_rc 1 "V11h checked checkbox item      - [x] regression: ..."            '- [x] regression: src/foo.ts:12 — no test'
expect_rc 1 "V11i table row                  | regression: ... |"              '| regression: src/foo.ts:12 — no test |'
expect_rc 1 "V11j colon outside the bold     **regression**: src/foo.ts"       '**regression**: src/foo.ts — no test'
expect_rc 1 "V11k single-asterisk emphasis   *regression:* src/foo.ts"         '*regression:* src/foo.ts — no test'
expect_rc 1 "V11l double-underscore          __regression__: src/foo.ts"       '__regression__: src/foo.ts — no test'
expect_rc 1 "V11m marker in a code span      \`regression:\` src/foo.ts"       '`regression:` src/foo.ts — no test'
expect_rc 0 "V11n checkbox negation          - [ ] No regression: main.go:267" '- [ ] No regression: main.go:267 is covered' 'github-actions[bot]'
expect_rc 0 "V11o table-row empty bucket     | regression: n/a |"              '| regression: n/a |' 'github-actions[bot]'

# V12 (round 5). The two shape families round 4's corpus could not express,
# driven end-to-end through the detector. Tight bullets were matched by BOTH
# round 1 and round 3 and lost in round 4; whole-marker wrapping was matched by
# round 1 and lost in rounds 2, 3 and 4. The unicode prefixes were matched by
# nobody until now.
expect_rc 1 "V12a tight dash bullet         -regression: ..."          '-regression: src/foo.ts:12 — no test'
expect_rc 1 "V12b tight plus bullet         +regression: ..."          '+regression: src/foo.ts:12 — no test'
expect_rc 1 "V12c tight star bullet         *regression: ..."          '*regression: src/foo.ts:12 — no test'
expect_rc 1 "V12d tight blockquote          >regression: ..."          '>regression: src/foo.ts:12 — no test'
expect_rc 1 "V12e unicode bullet            • regression: ..."         '• regression: src/foo.ts:12 — no test'
expect_rc 1 "V12f unicode bullet tight      •regression: ..."          '•regression: src/foo.ts:12 — no test'
expect_rc 1 "V12g en dash prefix            – regression: ..."         '– regression: src/foo.ts:12 — no test'
expect_rc 1 "V12h em dash prefix            — regression: ..."         '— regression: src/foo.ts:12 — no test'
expect_rc 1 "V12i whole marker double-quoted" '"regression: src/foo.ts:12" — no test'
expect_rc 1 "V12j whole marker single-quoted" "'regression: src/foo.ts:12' — no test"
expect_rc 1 "V12k whole marker parenthesized" '(regression: src/foo.ts:12) — no test'
expect_rc 1 "V12l whole marker bracketed"      '[regression: src/foo.ts:12] — no test'
expect_rc 1 "V12m whole marker smart-quoted"   '“regression: src/foo.ts:12” — no test'
expect_rc 1 "V12n angle-bracketed path"        'regression: <src/foo.ts:12> — no test'
expect_rc 1 "V12o smart-quoted path"           'regression: “src/foo.ts:12” — no test'

# ...and the same widening against the reject side. Every axis added in round 5
# is exercised on prose and empty buckets too.
expect_rc 0 "V12p tight dash negation        -No regression: ..."      '-No regression: main.go:267 is covered' 'github-actions[bot]'
expect_rc 0 "V12q unicode bullet negation    •No regression: ..."      '•No regression: main.go:267 is covered' 'github-actions[bot]'
expect_rc 0 "V12r quoted whole negation"     '"No regression: main.go:267 is covered"' 'github-actions[bot]'
expect_rc 0 "V12s paren whole negation"      '(the diff shows no regression: main.go:267)' 'github-actions[bot]'
expect_rc 0 "V12t tight dash empty bucket    -regression: none"        '-regression: none' 'github-actions[bot]'
expect_rc 0 "V12u quoted whole n/a"          '"regression: n/a"' 'github-actions[bot]'
expect_rc 0 "V12v paren whole empty bucket"  '(regression: nothing to report)' 'github-actions[bot]'
expect_rc 0 "V12w bracket whole time-of-day" '[regression: 12:30 elapsed]' 'github-actions[bot]'
expect_rc 0 "V12x em dash seconds"           '— regression: 3.2 seconds slower' 'github-actions[bot]'

# ---------------------------------------------------------------------------
# V13 (round 6). THE SUPPRESSOR-SIDE DIFFERENTIAL, measured rather than argued.
#
# The V10 cases above pin named shapes. This pins the PROPERTY: on the
# suppressor side — "does a finding marker override a clean verdict" — the
# shipped override must behave exactly as round 3 did, in BOTH directions.
#
#   new flags       shapes round 6 declines that round 3 armed  → false positives
#   lost overrides  shapes round 3 declined that round 6 arms   → lost coverage
#
# Over the exact 20,240-shape grid below, round 5 — canon plus its normalized
# marker, which is how it actually ran — scores 14,624 new flags and 0 lost. The
# requirement here is ZERO on both counts. Round 3's marker is read out of the
# detector's own `_REGRESSION_MARKER_RAW`, so this measures the shipped
# expression rather than a copy that would rot.
#
# (An earlier draft of this comment said 27,968, a figure carried over from a
# larger grid than the one below — larger than this grid's total, in fact. Round
# 6 is the round about not shipping unmeasured claims, so it was re-measured.)
#
# Every body carries a clean verdict, which is what makes it a SUPPRESSOR-side
# measurement: CLEAN_RE always fires, so the only question left is whether the
# override cancels it.
raw_marker=$(sed -n "s/^_REGRESSION_MARKER_RAW='\(.*\)'\$/\1/p" "$CHECKER")
if [ -z "$raw_marker" ]; then
  echo "✗ V13 could not extract _REGRESSION_MARKER_RAW from $CHECKER"
  failed=1
else
# ROUND 3's marker, verbatim from commit 5bcc1ca — the historical baseline this
# round is pinned against. It is restated here ON PURPOSE, unlike every other
# expression in this file: a baseline read out of the shipped file would move
# whenever the shipped file moves, and then it would measure nothing at all.
R3_MARKER='(^|\n)([[:space:]]*(>|[-*+]|[0-9]+[.)]|#))*[[:space:]]*\**regression:\**[[:space:]]*`?(?!n/a\b)(?=[^[:space:]`]*(/|\.[A-Za-z])|[A-Za-z_][A-Za-z0-9_.@+-]*:[0-9])[A-Za-z0-9_./@+-]+(:[0-9]+)?'
if [ "$raw_marker" != "$R3_MARKER" ]; then
  echo "✗ V13 _REGRESSION_MARKER_RAW is no longer round 3's marker verbatim —"
  echo "  the parity this round ships is by REUSE, not by rederivation"
  failed=1
fi
# Every quote and unicode character below is spelled \uXXXX, for the reason V9
# records: written literally, the apostrophes get eaten by THIS single-quoted
# shell string, the single-quoted entries collapse into duplicates of the bare
# ones, and the corpus silently shrinks while its count stays put. Writing this
# block the wrong way once, in this round, is how that note earned its keep.
v13=$(jq -n --arg m6 "$raw_marker" --arg m3 "$R3_MARKER" '
  ["", "-", "* ", "+ ", "- [ ] ", "- [x] ", "- [X] ", "1. ", "1) ", "  ",
   "# ", "### ", "> ", ">> ", "> - ", "| ", "| - ", "> - [ ] ", "> - [x] ",
   "\u2022 ", "\u2022", "\u2013 ", "\u2014 "] as $pfx
  | ["regression:", "**regression:**", "**regression**:", "`regression:`",
     "~~regression:~~"] as $spl
  | ["WHOLE", "\"WHOLE\"", "\u0027WHOLE\u0027", "(WHOLE)", "[WHOLE]",
     "\u201cWHOLE\u201d", "\u2018WHOLE\u2019", "<WHOLE>"] as $whl
  | ["PATH", "`PATH`", "**PATH**", "**`PATH`**", "[PATH](https://example.com/x)",
     "\"PATH\"", "\u0027PATH\u0027", "(PATH)", "\u201cPATH\u201d", "<PATH>",
     "~~PATH~~"] as $wrp
  | ["src/foo.ts", "src/foo.ts:12"] as $pth
  | "### Codex review\n\nPrevious round:\n\n" as $head
  | "\n\nAll of that is now addressed. No issues found. VERDICT: CLEAN" as $tail
  | [ $pfx[] as $p | $spl[] as $s | $whl[] as $h | $wrp[] as $w | $pth[] as $t
      | $head + $p
        + ($h | sub("WHOLE"; $s + " " + ($w | sub("PATH"; $t)))) + $tail ]
  | map({r3: test($m3; "i"), r6: test($m6; "i")})
  | {total: length,
     new:  [.[] | select(.r6 and (.r3 | not))] | length,
     lost: [.[] | select(.r3 and (.r6 | not))] | length}')
v13_total=$(printf '%s' "$v13" | jq -r '.total')
v13_new=$(printf '%s' "$v13" | jq -r '.new')
v13_lost=$(printf '%s' "$v13" | jq -r '.lost')
if [ "$v13_new" -eq 0 ] && [ "$v13_lost" -eq 0 ]; then
  echo "✓ V13 suppressor-side parity with round 3 over $v13_total shapes (0 new, 0 lost)"
else
  echo "✗ V13 suppressor-side parity BROKEN: $v13_new new false positives, $v13_lost lost overrides, of $v13_total"
  failed=1
fi

# V13b. The override marker carries its own prefix loop now, so it needs its own
# backtracking guard — the V8 loop above drives the NORMALIZED pipeline and
# would not see this expression at all. Same stakes: a retry-limit abort exits
# jq non-zero with an empty result, stderr goes to /dev/null, and the gate reads
# CLEAN and ARMS on hostile input.
#
# The property: each alternative in `([[:space:]]*(>|[-*+]|[0-9]+[.)]|#))*`
# either consumes exactly one character or is a digit run TERMINATED by `[.)]`,
# which a digit cannot be — so no iteration has a choice to make. The loop round
# 3 was measured dying on was the earlier `(>+|#{1,6}|...)` shape, not this one.
bt6_failed=0
# shellcheck disable=SC1111  # hostile INPUT characters, not shell quotes.
for spec in "400:>" "400:#" "400:*" "400:-" "400:+" "400:|" "400:1." "400: " \
            "400:\`" "400:_" "400:•" "400:—" "400:\"" "400:(" "400:[" "400:“" \
            "133: > 1." "200:> " "200: 1"; do
  n=${spec%%:*}; ch=${spec#*:}
  run=$(awk -v n="$n" -v c="$ch" 'BEGIN{s="";for(i=0;i<n;i++)s=s c;print s}')
  for tail in "" "regression: none" "regression: src/foo.ts:12"; do
    set +e
    err=$(jq -rn --arg re "$raw_marker" --arg b "${run}${tail}" \
            '($b|test($re;"i"))' 2>&1 >/dev/null); rc=$?
    set -e
    if [ "$rc" -ne 0 ] || [ -n "$err" ]; then
      echo "✗ V13b raw override marker failed on ${n}x'${ch}' + '${tail}': ${err:-rc=$rc}"
      bt6_failed=1
    fi
  done
done
if [ "$bt6_failed" -eq 0 ]; then
  echo "✓ V13b raw override marker survives 400-char hostile runs (no retry-limit abort)"
else
  failed=1
fi

# V13c. The ROUTING, asserted structurally. The behavioural cases above would
# also pass if someone re-normalized this term and then re-narrowed it some
# other way; this pins which body each test actually reads.
if grep -q '($raw | test($rmark; "i"))' "$CHECKER" \
   && grep -q '($body | test($find; "i"))' "$CHECKER" \
   && grep -q '($raw | test($sev; "i"))' "$CHECKER" \
   && grep -q '($raw | test($clean; "i"))' "$CHECKER"; then
  echo "✓ V13c routing: marker+severity+clean read RAW, FINDING_RE reads the normalized body"
else
  echo "✗ V13c routing changed — the override term or the admission gate moved bodies"
  failed=1
fi

fi  # raw-marker extraction guard

# ---------------------------------------------------------------------------
# V14-V15. Follow-up cross-reference hint (dotclaude#216, ported here so the
# twins stay byte-identical below the vendored header).
#
# The detector's whole signal is "no commit on THIS PR answered the finding",
# and that stays true forever once the fix lands in a LATER PR — so the report
# never expires and every sweep re-dispatches finished work. inbox_superpilot
# #211 cost three sessions that way. The hint reads the timeline for PRs that
# cross-reference this one and prints them.
#
# What these two cases pin is the SAFETY shape of that hint, because it runs
# inside the auto-merge arming path:
#
#   V14 — rc STAYS 1 while the hint prints. A cross-reference proves a later PR
#         mentioned this one, NOT that the finding was fixed; if it cleared the
#         report, the gate would arm on the exact class it exists to catch, and
#         this file's whole B3 path would go quiet. The fixture also carries an
#         xref that PREDATES the finding — the `since` guard must suppress it,
#         or every long-lived PR grows a permanent false hint.
#   V15 — the timeline read is NON-FATAL. It is the one fetch in the script
#         guarded by `|| echo '[]'` rather than a fail-closed `exit 2`, because
#         it decorates a report that already stands on its own. A fixture with
#         no timeline.json (every fixture above) must still report the finding.
#         Inside the gate the same property means a timeline 403 or outage
#         degrades to "no hint", never to a detector error — which the gate
#         treats as rc!=1 and fails closed on.
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
out14=$(bash "$CHECKER" --fixture "$FX" o/r 1 2>&1); v14=$?
rm -f "$FX/timeline.json"
out15=$(bash "$CHECKER" --fixture "$FX" o/r 1 2>&1); v15=$?
set -e
if [ "$v14" -eq 1 ] && grep -q 'possible follow-up' <<<"$out14" \
   && grep -q '#213' <<<"$out14" && grep -q 'MERGED' <<<"$out14" \
   && ! grep -q '#99' <<<"$out14"; then
  echo "✓ V14 follow-up hint names the later PR, suppresses the earlier xref, and rc stays 1"
else
  echo "✗ V14 rc=$v14 — expected rc=1 with a '#213 MERGED' hint and no '#99'; got: $(tr '\n' ' ' <<<"$out14" | head -c 200)"
  failed=1
fi
if [ "$v15" -eq 1 ] && grep -q 'UNADDRESSED FINDINGS' <<<"$out15" \
   && ! grep -q 'possible follow-up' <<<"$out15"; then
  echo "✓ V15 a fixture with no timeline.json still reports the finding (hint is non-fatal)"
else
  echo "✗ V15 rc=$v15 — a missing timeline must degrade to 'no hint', not change the verdict; got: $(tr '\n' ' ' <<<"$out15" | head -c 200)"
  failed=1
fi

# ---------------------------------------------------------------------------
# V16-V19. The follow-up hint must say WHICH REPO the follow-up lives in.
#
# A `cross-referenced` timeline event can originate in ANOTHER repository, and
# .source.issue.number is local to THAT repo. Printing a bare "#213" therefore
# reads as a PR in the repo being scanned — so an operator chasing the hint
# lands on an unrelated local #213, which is worse than no hint at all: this
# block exists to STOP redundant dispatch, and a wrong pointer causes it.
#
# The slug is resolved repository.full_name -> html_url -> scanned repo, and
# each of those three branches gets a case; the two that must stay TERSE are
# guards, and they matter more than the two that qualify.
#
#  V16 — the disambiguation itself. Note the negative assertion is anchored to
#        the printed line shape, not to the substring "#213": "other/x#213"
#        contains "#213", so a plain `! grep '#213'` would pass even against
#        the unfixed script and pin nothing.
#  V17 — the over-correction guard, and as with V4 it matters more than the
#        case it guards. Nearly every real follow-up is same-repo; qualifying
#        those too would push a slug onto every line of an already-dense hint.
#        The fixture carries repository.full_name EQUAL to the scanned repo,
#        which is the shape a real same-repo event has — a fix that qualifies
#        whenever the field is merely present, rather than when it differs,
#        passes V16 and fails here.
#  V18 — the html_url fallback. repository is the documented field but not a
#        guaranteed one, and an event that omits it is exactly where a bare
#        number misleads most, so the slug is recovered from the URL before
#        giving up and assuming same-repo.
#  V19 — the second over-correction guard. GitHub slugs are case-insensitive,
#        so an operator who types `Owner/Repo` must not get every local
#        follow-up needlessly qualified.
#
# V18/V19 close a Codex P2 on the first cut of this change: V16/V17 alone
# exercised only full_name at exact casing, leaving both other branches of the
# resolution chain documented but unpinned.
# ---------------------------------------------------------------------------
printf '%s' '[
  {"event":"cross-referenced","created_at":"2026-01-02T00:00:00Z",
   "source":{"issue":{"number":213,"state":"closed","title":"fix landed in a sibling repo",
             "repository":{"full_name":"other/elsewhere"},
             "pull_request":{"merged_at":"2026-01-02T01:00:00Z"}}}},
  {"event":"cross-referenced","created_at":"2026-01-02T00:00:00Z",
   "source":{"issue":{"number":7,"state":"open","title":"local follow-up",
             "repository":{"full_name":"o/r"},
             "pull_request":{"merged_at":null}}}}
]' > "$FX/timeline.json"
set +e
out16=$(bash "$CHECKER" --fixture "$FX" o/r 1 2>&1); v16=$?
set -e
if [ "$v16" -eq 1 ] && grep -q 'other/elsewhere#213' <<<"$out16" \
   && ! grep -qE '^[[:space:]]+#213[[:space:]]' <<<"$out16"; then
  echo "✓ V16 a cross-repo follow-up prints owner/repo#213, not a bare #213"
else
  echo "✗ V16 rc=$v16 — a cross-repo xref must be qualified; got: $(tr '\n' ' ' <<<"$out16" | head -c 200)"
  failed=1
fi
if [ "$v16" -eq 1 ] && grep -qE '^[[:space:]]+#7[[:space:]]' <<<"$out16" \
   && ! grep -q 'o/r#7' <<<"$out16"; then
  echo "✓ V17 a same-repo follow-up stays terse #7 even with repository.full_name set"
else
  echo "✗ V17 rc=$v16 — same-repo xrefs must not be qualified; got: $(tr '\n' ' ' <<<"$out16" | head -c 200)"
  failed=1
fi

# V18-V19. The other two branches of the slug-resolution chain: html_url when
# the repository object is absent, and a case-differing same-repo slug.
printf '%s' '[
  {"event":"cross-referenced","created_at":"2026-01-02T00:00:00Z",
   "source":{"issue":{"number":41,"state":"open","title":"fix in a third repo",
             "html_url":"https://github.com/third/party/pull/41",
             "pull_request":{"merged_at":null}}}},
  {"event":"cross-referenced","created_at":"2026-01-02T00:00:00Z",
   "source":{"issue":{"number":9,"state":"open","title":"local, slug typed differently",
             "repository":{"full_name":"O/R"},
             "pull_request":{"merged_at":null}}}}
]' > "$FX/timeline.json"
set +e
out18=$(bash "$CHECKER" --fixture "$FX" o/r 1 2>&1); v18=$?
set -e
if [ "$v18" -eq 1 ] && grep -q 'third/party#41' <<<"$out18" \
   && ! grep -qE '^[[:space:]]+#41[[:space:]]' <<<"$out18"; then
  echo "✓ V18 a cross-repo xref with no repository object recovers its slug from html_url"
else
  echo "✗ V18 rc=$v18 — html_url must back-stop a missing repository object; got: $(tr '\n' ' ' <<<"$out18" | head -c 200)"
  failed=1
fi
if [ "$v18" -eq 1 ] && grep -qE '^[[:space:]]+#9[[:space:]]' <<<"$out18" \
   && ! grep -q 'O/R#9' <<<"$out18"; then
  echo "✓ V19 a case-differing same-repo slug stays terse (comparison is case-insensitive)"
else
  echo "✗ V19 rc=$v18 — GitHub slugs are case-insensitive; \`Owner/Repo\` must not qualify; got: $(tr '\n' ' ' <<<"$out18" | head -c 200)"
  failed=1
fi

echo
if [ "$failed" -ne 0 ]; then
  echo "FAILED — see ✗ lines above"
  exit 1
fi
echo "all findings-gate cases passed"
