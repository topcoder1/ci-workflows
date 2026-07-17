#!/usr/bin/env bash
# Behavioral test for the manual-hold gate in claude-author-automerge.yml —
# the step that keeps a HUMAN's explicit "do not auto-merge this" decision
# in force across workflow re-runs.
#
# Incident context (whois-api-llc/techrecon#405, 2026-07-02): a human ran
# `gh pr merge --disable-auto` and an in-flight run re-armed auto-merge 11
# seconds later; the PR merged with no human click. The hold step (label +
# timeline signals) exists to prevent exactly that. But both of its reads
# were fail-open: `... 2>/dev/null || echo ""` degraded ANY read failure to
# "no hold", so an API blip could defeat the human's explicit one-click
# hold under precisely the conditions (API misbehavior) where the defense
# matters. The sibling classifier-verdict step already fails closed on an
# unreadable label set after 3 retries (codex round-3 P1 on the
# base-riskpaths-gate PR); this test pins the same contract onto both hold
# signals.
#
# Two additional silent-defeat defects found while hardening, both pinned
# here:
#
#   * The label read was UNPAGINATED (default 30 labels/page) — a hold
#     label past position 30 read as absent. The classifier-verdict read
#     already paginates; the hold read now matches it.
#   * The timeline read piped `gh api --paginate` into an AGGREGATING jq
#     (max of created_at). `--paginate` emits each page as its own
#     top-level JSON array (see `gh api --help`), and jq runs the filter
#     once PER INPUT — so any timeline crossing one page produced one
#     verdict line per page, multi-line output the `= "yes"` string
#     comparison can never match. Reproduced 2026-07-16: newest event a
#     human auto_merge_disabled on page 2 ⇒ "no\nyes" ⇒ hold MISSED.
#     Timelines cross a page at >100 events (30 pre-fix); busy PRs — the
#     ones humans hold — get there routinely.
#
# This test EXTRACTS the step's bash from the workflow YAML (the shipped
# script, not a mirrored copy) and executes it against a stubbed `gh`:
#
#   1.  hold label present (among others) ⇒ hold=1, reason=label:<name>;
#       the timeline is NOT queried (label short-circuits).
#   2.  near-miss label names (prefix / suffix / case variants) do NOT
#       hold — grep -qxF exact-match semantics.
#   3.  newest timeline event a HUMAN auto_merge_disabled ⇒ hold=1.
#   4.  newest event a github-actions[bot] disable (our own classifier /
#       hold revoke) ⇒ no hold — a bot revoke must not strand a PR.
#   5.  human disable then LATER re-enable ⇒ no hold (re-enable lifts).
#   6.  same-second enable + human disable tie ⇒ hold=1 (fail-safe: GitHub
#       timeline timestamps are whole-second, collisions are real).
#   7.  MULTI-PAGE: human disable newest, on page 2 of a concatenated
#       two-array payload ⇒ hold=1 (the per-page-max defect above).
#   8.  MULTI-PAGE inverse: disable on page 1, newer enable on page 2 ⇒
#       no hold (cross-page max, not any-page-yes).
#   9.  label read fails twice then succeeds ⇒ retry recovers, the
#       post-retry value is USED (hold=1), exactly 3 attempts made.
#  10.  FAIL CLOSED: label read fails 3× ⇒ nonzero exit, never "no hold".
#  11.  timeline read fails twice then succeeds ⇒ retry recovers (hold=1).
#  12.  FAIL CLOSED: timeline read fails 3× ⇒ nonzero exit.
#  13.  FAIL CLOSED: timeline responds 200-with-garbage (non-JSON) ⇒
#       nonzero exit — a mangled body must not read as "no hold".
#  14.  hold_label input empty ⇒ label signal skipped (no labels call),
#       timeline still consulted.
#  15.  empty timeline ⇒ no hold (the $t == null branch).
#
# Structural pins: the extracted run block contains no `${{ }}`
# interpolation (extraction-safe AND injection-safe); both reads paginate;
# the always() error-revoke step counts steps.hold.outcome == 'failure' as
# a gate error (a failed hold read must also DISARM a stale arm from an
# earlier run — "refusing to arm" alone is not fail-closed for a PR that
# is already armed); and the step's header comment no longer promises the
# graceful degradation ("can never crash the run") that made the hold
# defeatable.
#
# Run from the repo root:
#   bash selftest/test_automerge_hold_gate.sh
set -euo pipefail

WF=.github/workflows/claude-author-automerge.yml
failed=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# ---------------------------------------------------------------------------
# 0a. Structural pins.
# ---------------------------------------------------------------------------
if grep -q "steps.hold.outcome == 'failure'" "$WF"; then
  echo "✓ error-revoke step counts a failed hold read as a gate error (stale arm disarmed)"
else
  echo "✗ error-revoke step does not include steps.hold.outcome == 'failure' — a failed hold read leaves a stale arm alive"
  failed=1
fi
if grep -q 'degrade gracefully' "$WF"; then
  echo "✗ hold-step header still promises graceful degradation ('degrade gracefully' / 'can never crash the run') — stale after fail-closed hardening"
  failed=1
else
  echo "✓ hold-step header no longer promises fail-open graceful degradation"
fi

# ---------------------------------------------------------------------------
# 0b. Extract the manual-hold step's run block — the shipped bash, not a
#     mirrored copy.
# ---------------------------------------------------------------------------
awk '
  /^      - name: Check manual hold$/ { in_step=1 }
  in_step && /^        run: \|/ { in_run=1; next }
  in_run {
    if ($0 ~ /^          / || $0 == "") { sub(/^          /, ""); print }
    else { exit }
  }
' "$WF" > "$T/hold.sh"

if ! grep -q 'HOLD_LABEL' "$T/hold.sh" || ! grep -q 'GITHUB_OUTPUT' "$T/hold.sh"; then
  echo "✗ could not extract the manual-hold run block from $WF"
  exit 1
fi
echo "✓ extracted manual-hold step ($(wc -l < "$T/hold.sh" | tr -d ' ') lines)"

if grep -q '${{' "$T/hold.sh"; then
  echo "✗ manual-hold run block contains \${{ }} interpolation — untestable standalone and an injection-risk pattern; use env vars (\$GITHUB_REPOSITORY)"
  failed=1
else
  echo "✓ manual-hold run block is interpolation-free (env vars only)"
fi

if grep -q 'labels?per_page=100' "$T/hold.sh" && grep -A1 'labels?per_page=100' "$T/hold.sh" | grep -q -- '--paginate'; then
  echo "✓ label read paginates (a hold label past the 30-label default page cannot read as absent)"
else
  echo "✗ label read does not paginate — a hold label past the 30-label default page reads as absent"
  failed=1
fi

if grep -q 'timeline?per_page=100' "$T/hold.sh" && grep -A1 'timeline?per_page=100' "$T/hold.sh" | grep -q -- '--paginate'; then
  echo "✓ timeline read paginates"
else
  echo "✗ timeline read does not paginate with an explicit page size"
  failed=1
fi

# ---------------------------------------------------------------------------
# 0c. Stubs. `gh` dispatches on the requested URL and logs every call;
#     `sleep` no-ops the retry backoffs. Knobs (env):
#       STUB_LABELS              — newline-separated label names ('' = none)
#       STUB_LABELS_FAIL_TIMES   — first N labels calls fail (HTTP-500 shape)
#       STUB_TIMELINE_FILE       — raw bytes served for the timeline call
#                                  (may be MULTIPLE concatenated JSON arrays,
#                                  exactly like `gh api --paginate` output,
#                                  or garbage)
#       STUB_TIMELINE_FAIL_TIMES — first N timeline calls fail
# ---------------------------------------------------------------------------
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
args="$*"
echo "$args" >> "$CALLS_LOG"
bump() { local f="$1" n; n=$(cat "$f" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$f"; echo "$n"; }
case "$args" in
  *issues/*/labels*)
    n=$(bump "$STUB_DIR/labels-attempts")
    if [ "$n" -le "${STUB_LABELS_FAIL_TIMES:-0}" ]; then
      echo "gh: Internal Server Error (HTTP 500)" >&2
      exit 1
    fi
    printf '%s\n' "${STUB_LABELS:-}"
    ;;
  *issues/*/timeline*)
    n=$(bump "$STUB_DIR/timeline-attempts")
    if [ "$n" -le "${STUB_TIMELINE_FAIL_TIMES:-0}" ]; then
      echo "gh: Internal Server Error (HTTP 500)" >&2
      exit 1
    fi
    cat "$STUB_TIMELINE_FILE"
    ;;
  *)
    echo "gh-stub: unexpected call: $args" >&2
    exit 64
    ;;
esac
STUB
chmod +x "$T/bin/gh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/sleep"
chmod +x "$T/bin/sleep"

# ---------------------------------------------------------------------------
# Runner + assertions.
# ---------------------------------------------------------------------------
STUB_LABELS=""; STUB_LABELS_FAIL_TIMES=0; STUB_TIMELINE_FAIL_TIMES=0
STUB_TIMELINE_FILE="$T/timeline.json"; CASE_HOLD_LABEL="manual-merge"

reset_case() {
  STUB_LABELS=""; STUB_LABELS_FAIL_TIMES=0; STUB_TIMELINE_FAIL_TIMES=0
  STUB_TIMELINE_FILE="$T/timeline.json"; CASE_HOLD_LABEL="manual-merge"
  echo '[]' > "$T/timeline.json"
}

run_hold() {
  OUT_FILE="$T/gh-output.txt"
  CALLS_LOG="$T/calls.log"
  : > "$OUT_FILE"
  : > "$CALLS_LOG"
  rm -f "$T/labels-attempts" "$T/timeline-attempts"
  set +e
  HOLD_LOG=$(cd "$T" && \
    PATH="$T/bin:$PATH" \
    GITHUB_REPOSITORY="acme/fixture" PR=123 HOLD_LABEL="$CASE_HOLD_LABEL" \
    GITHUB_OUTPUT="$OUT_FILE" GH_TOKEN=stub \
    STUB_DIR="$T" CALLS_LOG="$CALLS_LOG" \
    STUB_LABELS="$STUB_LABELS" STUB_LABELS_FAIL_TIMES="$STUB_LABELS_FAIL_TIMES" \
    STUB_TIMELINE_FILE="$STUB_TIMELINE_FILE" \
    STUB_TIMELINE_FAIL_TIMES="$STUB_TIMELINE_FAIL_TIMES" \
    bash hold.sh 2>&1)
  HOLD_RC=$?
  set -e
}

out_get() { grep "^$1=" "$OUT_FILE" | tail -1 | cut -d= -f2- || true; }

# expect_hold <desc> <hold> <reason>
expect_hold() {
  local desc="$1" want_hold="$2" want_reason="$3"
  if [ "$HOLD_RC" != "0" ]; then
    echo "✗ $desc — step exited rc=$HOLD_RC (want 0). Output:"
    echo "$HOLD_LOG" | sed 's/^/    /'
    failed=1
    return
  fi
  local got_hold got_reason
  got_hold=$(out_get hold); got_reason=$(out_get reason)
  if [ "$got_hold" = "$want_hold" ] && [ "$got_reason" = "$want_reason" ]; then
    echo "✓ $desc"
  else
    echo "✗ $desc — got hold='$got_hold' reason='$got_reason' (want '$want_hold'/'$want_reason'). Output:"
    echo "$HOLD_LOG" | sed 's/^/    /'
    failed=1
  fi
}

# expect_fail_closed <desc> <needle>
expect_fail_closed() {
  local desc="$1" needle="$2"
  if [ "$HOLD_RC" -ne 0 ] && echo "$HOLD_LOG" | grep -q "$needle"; then
    echo "✓ $desc"
  else
    echo "✗ $desc — want nonzero rc + '$needle'; got rc=$HOLD_RC. Output:"
    echo "$HOLD_LOG" | sed 's/^/    /'
    failed=1
  fi
}

# expect_calls <desc> <endpoint-substr> <want-count>
expect_calls() {
  local desc="$1" needle="$2" want="$3" got
  got=$(grep -c "$needle" "$CALLS_LOG" || true)
  if [ "$got" = "$want" ]; then
    echo "✓ $desc"
  else
    echo "✗ $desc — $needle called $got time(s), want $want. Calls:"
    sed 's/^/    /' "$CALLS_LOG"
    failed=1
  fi
}

echo ""
echo "— behavioral cases —"

# 1. hold label present among others ⇒ hold, label short-circuits timeline.
reset_case
STUB_LABELS=$(printf '%s\n' 'risk:standard' 'manual-merge' 'auto-merge')
run_hold
expect_hold "hold label present (among others) ⇒ hold via label" 1 "label:manual-merge"
expect_calls "  … and the timeline is not queried (label short-circuits)" "/timeline" 0

# 2. near-miss label names must NOT hold (exact-match semantics).
reset_case
STUB_LABELS=$(printf '%s\n' 'manual-merge-now' 'not-manual-merge' 'Manual-Merge')
run_hold
expect_hold "near-miss label names (prefix/suffix/case) do not hold" 0 ""

# 3. newest timeline event a HUMAN disable ⇒ hold.
reset_case
cat > "$T/timeline.json" <<'JSON'
[{"event":"labeled","created_at":"2026-07-10T09:00:00Z","actor":{"login":"github-actions[bot]"}},
 {"event":"auto_merge_enabled","created_at":"2026-07-10T10:00:00Z","actor":{"login":"topcoder1"}},
 {"event":"auto_merge_disabled","created_at":"2026-07-10T12:00:00Z","actor":{"login":"topcoder1"}}]
JSON
run_hold
expect_hold "newest event = human --disable-auto ⇒ hold via timeline" 1 "timeline:human-disable-newest"

# 4. newest event a bot disable (our own revoke) ⇒ no hold.
reset_case
cat > "$T/timeline.json" <<'JSON'
[{"event":"auto_merge_enabled","created_at":"2026-07-10T10:00:00Z","actor":{"login":"topcoder1"}},
 {"event":"auto_merge_disabled","created_at":"2026-07-10T12:00:00Z","actor":{"login":"github-actions[bot]"}}]
JSON
run_hold
expect_hold "newest event = github-actions[bot] disable (self-revoke) ⇒ no hold" 0 ""

# 5. human disable then LATER re-enable ⇒ no hold.
reset_case
cat > "$T/timeline.json" <<'JSON'
[{"event":"auto_merge_disabled","created_at":"2026-07-10T10:00:00Z","actor":{"login":"topcoder1"}},
 {"event":"auto_merge_enabled","created_at":"2026-07-10T12:00:00Z","actor":{"login":"topcoder1"}}]
JSON
run_hold
expect_hold "human disable then later re-enable ⇒ no hold (re-enable lifts)" 0 ""

# 6. same-second tie between enable and human disable ⇒ hold (fail-safe).
reset_case
cat > "$T/timeline.json" <<'JSON'
[{"event":"auto_merge_enabled","created_at":"2026-07-10T12:00:00Z","actor":{"login":"topcoder1"}},
 {"event":"auto_merge_disabled","created_at":"2026-07-10T12:00:00Z","actor":{"login":"topcoder1"}}]
JSON
run_hold
expect_hold "same-second enable/disable tie resolves toward the human disable" 1 "timeline:human-disable-newest"

# 7. MULTI-PAGE: `gh api --paginate` emits one JSON array PER PAGE. The
#    newest event (human disable) sits on page 2. The old per-page jq
#    computed a per-page max and printed one verdict line per page —
#    reproduced output "no\nyes", which the = "yes" comparison missed.
reset_case
cat > "$T/timeline.json" <<'JSON'
[{"event":"auto_merge_enabled","created_at":"2026-07-10T10:00:00Z","actor":{"login":"topcoder1"}}]
[{"event":"labeled","created_at":"2026-07-10T11:00:00Z","actor":{"login":"github-actions[bot]"}},
 {"event":"auto_merge_disabled","created_at":"2026-07-10T12:00:00Z","actor":{"login":"topcoder1"}}]
JSON
run_hold
expect_hold "multi-page timeline: human disable newest on page 2 ⇒ hold" 1 "timeline:human-disable-newest"

# 8. MULTI-PAGE inverse: the disable is older than a page-2 enable — the
#    aggregation must be a cross-page max, not any-page-yes.
reset_case
cat > "$T/timeline.json" <<'JSON'
[{"event":"auto_merge_disabled","created_at":"2026-07-10T10:00:00Z","actor":{"login":"topcoder1"}}]
[{"event":"auto_merge_enabled","created_at":"2026-07-10T12:00:00Z","actor":{"login":"topcoder1"}}]
JSON
run_hold
expect_hold "multi-page timeline: newer enable on page 2 outranks page-1 disable ⇒ no hold" 0 ""

# 9. label read fails twice then succeeds ⇒ retry recovers and the fetched
#    value is used.
reset_case
STUB_LABELS="manual-merge"
STUB_LABELS_FAIL_TIMES=2
run_hold
expect_hold "label read fails ×2 then succeeds ⇒ retry recovers, hold honored" 1 "label:manual-merge"
if [ "$(cat "$T/labels-attempts" 2>/dev/null)" = "3" ]; then
  echo "✓   … exactly 3 label-read attempts made"
else
  echo "✗   … expected 3 label-read attempts, got '$(cat "$T/labels-attempts" 2>/dev/null)'"
  failed=1
fi

# 10. FAIL CLOSED: label read fails 3× ⇒ nonzero, never silent "no hold".
reset_case
STUB_LABELS="manual-merge"
STUB_LABELS_FAIL_TIMES=3
run_hold
expect_fail_closed "unreadable label set (HTTP 500 ×3) fails closed" "could not read PR labels"

# 11. timeline read fails twice then succeeds ⇒ retry recovers.
reset_case
cat > "$T/timeline.json" <<'JSON'
[{"event":"auto_merge_disabled","created_at":"2026-07-10T12:00:00Z","actor":{"login":"topcoder1"}}]
JSON
STUB_TIMELINE_FAIL_TIMES=2
run_hold
expect_hold "timeline read fails ×2 then succeeds ⇒ retry recovers, hold honored" 1 "timeline:human-disable-newest"

# 12. FAIL CLOSED: timeline read fails 3× ⇒ nonzero.
reset_case
STUB_TIMELINE_FAIL_TIMES=3
run_hold
expect_fail_closed "unreadable timeline (HTTP 500 ×3) fails closed" "could not read the PR timeline"

# 13. FAIL CLOSED: timeline responds 200-with-garbage — a mangled body must
#     not be read as "no hold".
reset_case
printf 'upstream gateway error (text/html)\n' > "$T/timeline.json"
run_hold
expect_fail_closed "garbled (non-JSON) timeline body fails closed" "did not parse"

# 14. hold_label input empty ⇒ label signal disabled; timeline still gates.
reset_case
CASE_HOLD_LABEL=""
cat > "$T/timeline.json" <<'JSON'
[{"event":"auto_merge_disabled","created_at":"2026-07-10T12:00:00Z","actor":{"login":"topcoder1"}}]
JSON
run_hold
expect_hold "hold_label input empty ⇒ label signal off, timeline still holds" 1 "timeline:human-disable-newest"
expect_calls "  … and the labels endpoint is never called" "/labels" 0

# 15. empty timeline ⇒ no hold.
reset_case
run_hold
expect_hold "no labels + empty timeline ⇒ no hold" 0 ""

echo ""
if [ "$failed" -gt 0 ]; then
  echo "FAIL: manual-hold gate case(s) regressed."
  exit 1
fi
echo "OK: all manual-hold gate cases pass."
