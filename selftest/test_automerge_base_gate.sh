#!/usr/bin/env bash
# Behavioral test for the base-branch gate in claude-author-automerge.yml —
# the step that keeps auto-merge pointed at the one ref a branch ruleset
# actually protects.
#
# Incident context (whois-api-llc/wxa-jake-ai#1027, 2026-07-28): a PR opened
# against ANOTHER OPEN PR's head branch was squash-merged 68 seconds after
# creation. It grew that PR's diff from 6 files to 8 AFTER its 4-round codex
# review had completed, so the human being asked to click merge on the parent
# would approve two files nobody reviewed.
#
# The mechanism is what makes this a gate and not a preference. Branch
# rulesets are conventionally scoped to the default branch (`ref_name:
# ~DEFAULT_BRANCH`), so a feature-branch base has NO required status checks:
# `gh pr merge --auto` merges on the spot instead of waiting. Every other
# protection in this lane is latency-shaped — the caller-side classification
# gate, this workflow's own hold read — and silently assumes there is a wait
# to lose. In #1027 the disarm that would have caught it started 7 seconds
# AFTER the merge landed. Remove the wait and the unguarded arm always wins,
# which is why "the hold label protects main-targeted PRs" was true only by
# accident of timing.
#
# Policy pinned here:
#
#   * base == default branch          → no refusal, and NO API calls (the
#                                       overwhelmingly common path stays free)
#   * base is another open PR's head  → refuse, NOT liftable by the opt-in
#                                       label (the review-scope-expansion
#                                       vector above)
#   * base != default branch          → refuse unless the opt-in label is
#                                       present
#   * unreadable anything             → refuse (fail closed)
#
# This test EXTRACTS the step's bash from the workflow YAML (the shipped
# script, not a mirrored copy) and executes it against a stubbed `gh`:
#
#   1.  base == default branch ⇒ no refusal…
#   2.  …and not one API call is made.
#   3.  #1027 replay: base is another open PR's head ⇒ refuse.
#   4.  the opt-in label does NOT lift that refusal.
#   5.  non-default base, not another PR's head, no opt-in ⇒ refuse.
#   6.  non-default base + opt-in label ⇒ allowed.
#   7.  near-miss opt-in label names do not opt in (grep -qxF exact match).
#   8.  a base that is a SUBSTRING of an open head does not refuse.
#   9.  MULTI-PAGE: the matching head arrives on a later page ⇒ refuse.
#  10.  opt-in input empty ⇒ every non-default base refuses; labels unread.
#  11.  FAIL CLOSED: open-PR listing fails 3× ⇒ nonzero exit.
#  12.  FAIL CLOSED: label read fails 3× ⇒ nonzero exit.
#  13.  FAIL CLOSED: empty base ref ⇒ nonzero exit.
#  14.  FAIL CLOSED: empty default branch ⇒ nonzero exit.
#  15.  open-PR listing fails twice then succeeds ⇒ retry recovers.
#
# Structural pins: the extracted run block contains no `${{ }}` interpolation
# (extraction-safe AND injection-safe); the open-PR listing paginates with a
# NON-aggregating jq (an aggregating filter prints one verdict per page — the
# defect pinned in test_automerge_hold_gate.sh case 7); that listing is
# filtered to same-repo heads (a fork PR's `.head.ref` is only a branch name
# in the fork, so an unrelated fork branch of the same name would read as the
# parent PR's head and refuse an opted-in merge); the enable step
# consults the gate; a refusal revokes an existing arm; and the always()
# error-revoke counts a failed gate read as a gate error, so a fail-closed
# read also disarms a PR armed by an earlier run.
#
# Run from the repo root:
#   bash selftest/test_automerge_base_gate.sh
set -euo pipefail

WF=.github/workflows/claude-author-automerge.yml
failed=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# ---------------------------------------------------------------------------
# 0a. Structural pins — wiring this test cannot see from the extracted bash.
# ---------------------------------------------------------------------------
if grep -q "steps.base_gate.outputs.refuse != '1'" "$WF"; then
  echo "✓ enable step consults the base gate"
else
  echo "✗ enable step does not consult steps.base_gate.outputs.refuse — the gate computes a verdict nothing reads"
  failed=1
fi
if grep -q "steps.base_gate.outcome == 'failure'" "$WF"; then
  echo "✓ error-revoke counts a failed base-gate read as a gate error (stale arm disarmed)"
else
  echo "✗ error-revoke omits steps.base_gate.outcome == 'failure' — a fail-closed read leaves a stale arm alive"
  failed=1
fi
if grep -q 'name: Revoke auto-merge on base-gate refusal' "$WF"; then
  echo "✓ a base-gate refusal revokes an already-armed auto-merge"
else
  echo "✗ no revoke step for a base-gate refusal — refusing to arm is not fail-closed for an already-armed PR"
  failed=1
fi
# The base and the opt-in label mutate WITHOUT moving the head SHA, so
# --match-head-commit alone does not bind this verdict. A stale run that
# cleared the gate before a retarget would otherwise arm against an
# unprotected base and — having no required checks there — merge instantly.
enable_block=$(awk '/name: Enable auto-merge/{f=1} f' "$WF")
if echo "$enable_block" | grep -q 'could not re-read the base ref before arming'; then
  echo "✓ the arm re-binds to the base this run's gate validated"
else
  echo "✗ the arm does not revalidate the base — a retarget between the gate read and the arm merges under unvalidated routing"
  failed=1
fi
if echo "$enable_block" | grep -q 'is no longer present and the base is not the default branch'; then
  echo "✓ the arm re-checks the opt-in label on a non-default base"
else
  echo "✗ the arm does not re-check the opt-in label — removing it before the arm still merges on a non-default base"
  failed=1
fi
if echo "$enable_block" | grep -q 'became the head branch of an open PR since'; then
  echo "✓ the arm re-lists open heads (a parent PR opened after the gate fires no event for this child)"
else
  echo "✗ the arm does not re-list open heads — a parent PR opened between gate and arm still merges the child into it"
  failed=1
fi
# Every PRE-ARM rejection must DISARM, not merely decline to re-arm: the PR
# may already be armed by an earlier run, whose own gate legitimately passed.
# Scoped to the revalidation region (everything before the arm itself) — the
# head-moved branch AFTER the arm deliberately does NOT revoke, because that
# run's knowledge is stale and its revoke could land after the newer head's
# run validly armed. See that branch's own comment.
# The helper's own body legitimately contains `exit 1` (the "still ON after
# --disable-auto" escalation), so strip the function before scanning for
# bare exits in the rejection paths.
prearm=$(echo "$enable_block" \
  | awk '/gh pr merge --auto/{exit} {print}' \
  | awk '/disarm_then_exit\(\) \{/{inf=1} inf && /^ *\}$/{inf=0; next} !inf')
if echo "$enable_block" | grep -q 'disarm_then_exit()' \
  && ! echo "$prearm" | grep -qE '^ *exit [01]$'; then
  echo "✓ every pre-arm rejection disarms an existing arm (no bare exit-without-disarm)"
else
  echo "✗ a pre-arm rejection exits without disarming — an arm placed by an earlier run survives the rejection"
  failed=1
fi

# ---------------------------------------------------------------------------
# 0b. Extract the base-gate step's run block — the shipped bash.
# ---------------------------------------------------------------------------
awk '
  /^      - name: Check base branch$/ { in_step=1 }
  in_step && /^        run: \|/ { in_run=1; next }
  in_run {
    if ($0 ~ /^          / || $0 == "") { sub(/^          /, ""); print }
    else { exit }
  }
' "$WF" > "$T/base.sh"

if ! grep -q 'BASE_REF' "$T/base.sh" || ! grep -q 'GITHUB_OUTPUT' "$T/base.sh"; then
  echo "✗ could not extract the base-gate run block from $WF"
  exit 1
fi
echo "✓ extracted base-gate step ($(wc -l < "$T/base.sh" | tr -d ' ') lines)"

if grep -q '${{' "$T/base.sh"; then
  echo "✗ base-gate run block contains \${{ }} interpolation — untestable standalone and an injection-risk pattern; use env vars"
  failed=1
else
  echo "✓ base-gate run block is interpolation-free (env vars only)"
fi

if grep -q 'pulls?state=open&per_page=100' "$T/base.sh" \
  && grep -A1 'pulls?state=open&per_page=100' "$T/base.sh" | grep -q -- '--paginate'; then
  echo "✓ open-PR listing paginates (a base branch past page 1 cannot read as unlisted)"
else
  echo "✗ open-PR listing does not paginate with an explicit page size"
  failed=1
fi
# The filter streams `.head.ref` per page; an aggregating filter
# (map/add/any/reduce) would emit one answer PER PAGE — the multi-page defect
# from the hold gate.
if grep -q -- '\.head\.ref' "$T/base.sh" \
  && ! grep -Eq -- "--jq '[^']*(map\(|add|reduce |any\()" "$T/base.sh"; then
  echo "✓ open-PR listing uses a non-aggregating jq (safe under --paginate)"
else
  echo "✗ open-PR listing must stream .head.ref — an aggregating filter yields one answer per page under --paginate"
  failed=1
fi
# Fork PRs share the head-ref namespace: a fork branch named like this repo's
# base would read as "the parent PR's head" and refuse a legitimately
# opted-in merge. Compare full_name, not just the ref. (Codex round 1, P2.)
if grep -q 'head.repo.full_name == env.GITHUB_REPOSITORY' "$T/base.sh"; then
  echo "✓ open-PR listing is filtered to same-repo heads (fork refs cannot collide)"
else
  echo "✗ open-PR listing does not filter on .head.repo.full_name — an unrelated fork branch of the same name reads as the parent PR's head"
  failed=1
fi

# ---------------------------------------------------------------------------
# 0c. Stubs. `gh` dispatches on the requested URL and logs every call;
#     `sleep` no-ops the retry backoffs. Output is post-`--jq` shaped, as the
#     real `gh api --jq` would emit. Knobs (env):
#       STUB_OPEN_HEADS          — newline-separated open-PR head refs
#       STUB_OPENPR_FAIL_TIMES   — first N open-PR listings fail
#       STUB_LABELS              — newline-separated label names
#       STUB_LABELS_FAIL_TIMES   — first N label reads fail
# ---------------------------------------------------------------------------
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
args="$*"
echo "$args" >> "$CALLS_LOG"
bump() { local f="$1" n; n=$(cat "$f" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$f"; echo "$n"; }
case "$args" in
  *"pulls?state=open"*)
    n=$(bump "$STUB_DIR/openpr-attempts")
    if [ "$n" -le "${STUB_OPENPR_FAIL_TIMES:-0}" ]; then
      echo "gh: Internal Server Error (HTTP 500)" >&2
      exit 1
    fi
    printf '%s\n' "${STUB_OPEN_HEADS:-}"
    ;;
  *issues/*/labels*)
    n=$(bump "$STUB_DIR/labels-attempts")
    if [ "$n" -le "${STUB_LABELS_FAIL_TIMES:-0}" ]; then
      echo "gh: Internal Server Error (HTTP 500)" >&2
      exit 1
    fi
    printf '%s\n' "${STUB_LABELS:-}"
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
reset_case() {
  STUB_OPEN_HEADS=""; STUB_OPENPR_FAIL_TIMES=0
  STUB_LABELS=""; STUB_LABELS_FAIL_TIMES=0
  CASE_BASE_REF="main"; CASE_DEFAULT_BRANCH="main"
  CASE_OPTIN_LABEL="auto-merge-nonmain"
}

run_gate() {
  OUT_FILE="$T/gh-output.txt"
  CALLS_LOG="$T/calls.log"
  : > "$OUT_FILE"
  : > "$CALLS_LOG"
  rm -f "$T/openpr-attempts" "$T/labels-attempts"
  set +e
  GATE_LOG=$(cd "$T" && \
    PATH="$T/bin:$PATH" \
    GITHUB_REPOSITORY="acme/fixture" PR=1027 \
    BASE_REF="$CASE_BASE_REF" DEFAULT_BRANCH="$CASE_DEFAULT_BRANCH" \
    OPTIN_LABEL="$CASE_OPTIN_LABEL" \
    GITHUB_OUTPUT="$OUT_FILE" GH_TOKEN=stub \
    STUB_DIR="$T" CALLS_LOG="$CALLS_LOG" \
    STUB_OPEN_HEADS="$STUB_OPEN_HEADS" \
    STUB_OPENPR_FAIL_TIMES="$STUB_OPENPR_FAIL_TIMES" \
    STUB_LABELS="$STUB_LABELS" STUB_LABELS_FAIL_TIMES="$STUB_LABELS_FAIL_TIMES" \
    bash base.sh 2>&1)
  GATE_RC=$?
  set -e
}

out_get() { grep "^$1=" "$OUT_FILE" | tail -1 | cut -d= -f2- || true; }

# expect_gate <desc> <refuse> [reason-substring]
expect_gate() {
  local desc="$1" want="$2" needle="${3:-}" got
  if [ "$GATE_RC" != "0" ]; then
    echo "✗ $desc — step exited rc=$GATE_RC (want 0). Output:"
    echo "$GATE_LOG" | sed 's/^/    /'
    failed=1
    return
  fi
  got=$(out_get refuse)
  if [ "$got" != "$want" ]; then
    echo "✗ $desc — got refuse='$got' (want '$want'). Output:"
    echo "$GATE_LOG" | sed 's/^/    /'
    failed=1
    return
  fi
  if [ -n "$needle" ] && ! out_get reason | grep -q "$needle"; then
    echo "✗ $desc — reason '$(out_get reason)' does not mention '$needle'"
    failed=1
    return
  fi
  echo "✓ $desc"
}

# expect_fail_closed <desc> <needle>
expect_fail_closed() {
  local desc="$1" needle="$2"
  if [ "$GATE_RC" -ne 0 ] && echo "$GATE_LOG" | grep -q "$needle"; then
    echo "✓ $desc"
  else
    echo "✗ $desc — want nonzero rc + '$needle'; got rc=$GATE_RC. Output:"
    echo "$GATE_LOG" | sed 's/^/    /'
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

# 1/2. The default branch is the protected ref: no refusal, and the common
#      path must not spend API calls to learn that.
reset_case
run_gate
expect_gate "base == default branch ⇒ no refusal" 0
expect_calls "  … and no API call is made on the default-branch path" "" 0

# 3. THE #1027 REPLAY.
reset_case
CASE_BASE_REF="fix/qa1104-credit-guard-residuals"
STUB_OPEN_HEADS=$(printf '%s\n' 'fix/qa1104-estimate-shape-filter' 'fix/qa1104-credit-guard-residuals')
run_gate
expect_gate "#1027 replay: base is another open PR's head ⇒ refuse" 1 "head branch of another open PR"
expect_calls "  … and the label read is skipped (that refusal is unconditional)" "/labels" 0

# 4. The opt-in label must NOT lift the open-PR-head refusal — opting into a
#    plain integration branch is a routing choice; opting into rewriting an
#    under-review PR's diff is not one a label should be able to make.
reset_case
CASE_BASE_REF="fix/parent"
STUB_OPEN_HEADS="fix/parent"
STUB_LABELS=$(printf '%s\n' 'risk:standard' 'auto-merge-nonmain')
run_gate
expect_gate "opt-in label does NOT lift the open-PR-head refusal" 1 "head branch of another open PR"

# 5. Plain non-default base, no opt-in.
reset_case
CASE_BASE_REF="integration/v2"
STUB_OPEN_HEADS="something/else"
run_gate
expect_gate "non-default base without the opt-in label ⇒ refuse" 1 "not the default branch"

# 6. Plain non-default base WITH opt-in.
reset_case
CASE_BASE_REF="integration/v2"
STUB_OPEN_HEADS="something/else"
STUB_LABELS=$(printf '%s\n' 'risk:standard' 'auto-merge-nonmain')
run_gate
expect_gate "non-default base WITH the opt-in label ⇒ allowed" 0

# 7. Near-miss opt-in label names must not opt in.
reset_case
CASE_BASE_REF="integration/v2"
STUB_OPEN_HEADS="something/else"
STUB_LABELS=$(printf '%s\n' 'auto-merge-nonmain-please' 'not-auto-merge-nonmain' 'Auto-Merge-Nonmain')
run_gate
expect_gate "near-miss opt-in label names (prefix/suffix/case) do not opt in" 1 "not the default branch"

# 8. Substring must not count as a match — grep -qxF is whole-line.
reset_case
CASE_BASE_REF="fix/parent"
STUB_OPEN_HEADS=$(printf '%s\n' 'fix/parent-2' 'prefix/fix/parent')
run_gate
expect_gate "a base that is only a SUBSTRING of an open head does not refuse as one" 1 "not the default branch"

# 9. MULTI-PAGE: `gh api --paginate` concatenates pages; the matching head
#    arrives after the first page's worth of refs.
reset_case
CASE_BASE_REF="fix/parent"
STUB_OPEN_HEADS=$(printf '%s\n' 'a/1' 'b/2' 'c/3' 'fix/parent')
run_gate
expect_gate "matching head later in a paginated listing ⇒ refuse" 1 "head branch of another open PR"

# 10. Opt-in disabled by the caller ⇒ no escape hatch at all, labels unread.
reset_case
CASE_BASE_REF="integration/v2"
CASE_OPTIN_LABEL=""
STUB_OPEN_HEADS="something/else"
STUB_LABELS="auto-merge-nonmain"
run_gate
expect_gate "opt-in input empty ⇒ every non-default base refuses" 1 "opt-in is disabled"
expect_calls "  … and the labels endpoint is never called" "/labels" 0

# 11. FAIL CLOSED: cannot rule out that the base is another PR's head.
reset_case
CASE_BASE_REF="integration/v2"
STUB_OPENPR_FAIL_TIMES=3
run_gate
expect_fail_closed "unreadable open-PR listing (HTTP 500 ×3) fails closed" "could not list open PRs"

# 12. FAIL CLOSED: cannot confirm the opt-in.
reset_case
CASE_BASE_REF="integration/v2"
STUB_OPEN_HEADS="something/else"
STUB_LABELS_FAIL_TIMES=3
run_gate
expect_fail_closed "unreadable label set (HTTP 500 ×3) fails closed" "could not read PR labels"

# 13/14. FAIL CLOSED on a missing base or default branch. An absent
#        `github.event.repository.default_branch` would otherwise compare
#        unequal to every base and silently refuse-or-allow on noise.
reset_case
CASE_BASE_REF=""
run_gate
expect_fail_closed "empty base ref fails closed" "empty base ref"
reset_case
CASE_DEFAULT_BRANCH=""
run_gate
expect_fail_closed "empty default branch fails closed" "empty base ref"

# 15. Retry recovers.
reset_case
CASE_BASE_REF="fix/parent"
STUB_OPEN_HEADS="fix/parent"
STUB_OPENPR_FAIL_TIMES=2
run_gate
expect_gate "open-PR listing fails ×2 then succeeds ⇒ retry recovers, refusal honored" 1 "head branch of another open PR"
if [ "$(cat "$T/openpr-attempts" 2>/dev/null)" = "3" ]; then
  echo "✓   … exactly 3 open-PR listing attempts made"
else
  echo "✗   … expected 3 open-PR listing attempts, got '$(cat "$T/openpr-attempts" 2>/dev/null)'"
  failed=1
fi

echo ""
if [ "$failed" -gt 0 ]; then
  echo "FAIL: base-branch gate case(s) regressed."
  exit 1
fi
echo "OK: all base-branch gate cases pass."
