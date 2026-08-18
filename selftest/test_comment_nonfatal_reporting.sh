#!/usr/bin/env bash
# A gate's REPORTING must not be able to fail the gate.
#
# INCIDENT (whois-api-llc/wxa-graph #422-#426, 2026-08-17 18:29-18:36Z).
# GitHub's comments API served `HTTP 503: No server is currently available
# to service your request` for about two minutes. Two reusable lanes had
# already DECIDED — claude-review's bot-skip had computed `total=1
# non-bot=0`, coverage-floor had measured 83.0% against a floor of 80.2% —
# and then failed a REQUIRED check on the post-decision comment call
# (runs 32055207194 and 32055207104). All five open dependabot PRs sat
# blocked on gates that had passed. Worse than the red: in the bot-skip
# step the failed `gh pr comment` also aborted the step BEFORE
# `skipped=true` reached GITHUB_OUTPUT, so downstream steps saw no decision
# at all.
#
# THE INVARIANT: once the decision is made, posting about it is reporting.
# A reporting failure degrades to a ::warning:: and the decision stands —
# it must never red the check (mask a pass), and it must never make the
# decision output unreachable.
#
# THE COUNTER-INVARIANT, pinned just as hard: calls that ARE the
# enforcement stay fatal. `gh pr merge --disable-auto` failing must still
# fail the revoke step — a swallowed revoke failure leaves a stale arm
# live, which is fail-open. Deliberately NOT covered here for the same
# reason: the lost-findings fallback comment in claude-review.yml (its
# failure is load-bearing — a green check over unpostable findings is the
# #165 bug) and the Codex verdict comment in codex-review.yml (it delivers
# findings that the automerge findings gate reads; see
# test_codex_verdict_gate_is_wired_and_opt_in in test_workflow_guards.py).
# coverage-floor's sticky comment is an action step, not bash — its
# continue-on-error pin lives in test_workflow_guards.py
# (test_sticky_comment_action_steps_are_nonfatal).
#
# This extracts each workflow's SHIPPED bash — not a mirrored copy — and
# executes it against a `gh` stub whose comment/list/delete/merge calls can
# be told to fail the way 2026-08-17 did.
#
# Run from the repo root:
#   bash selftest/test_comment_nonfatal_reporting.sh
set -euo pipefail

REVIEW_WF=.github/workflows/claude-review.yml
MERGE_WF=.github/workflows/dependabot-auto-merge.yml
DRIFT_WF=.github/workflows/openapi-types-drift.yml

failed=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

pass() { echo "✓ $1"; }
fail() {
  echo "✗ $1"
  failed=1
}

extract_run() {
  local wf="$1" step_name="$2" out="$3"
  awk -v name="      - name: $step_name" '
    $0 == name { in_step = 1; next }
    in_step && /^        run: \|/ { in_run = 1; next }
    in_run {
      if ($0 ~ /^          / || $0 == "") { sub(/^          /, ""); print }
      else { exit }
    }
  ' "$wf" > "$out"
  if [ ! -s "$out" ]; then
    fail "could not extract '$step_name' from $wf — step renamed or reindented?"
    return 1
  fi
}

# A `gh` stub. Reads always work; the write surfaces (pr comment, comment
# list, comment delete, pr merge) fail on request — each with the literal
# 503 the outage served.
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
echo "gh $*" >> "$GH_LOG"
fail_503() {
  echo "HTTP 503: No server is currently available to service your request (https://api.github.com/graphql)" >&2
  exit 1
}
case "${1:-}" in
  api)
    if [ "${2:-}" = "-X" ]; then
      case "${3:-}" in
        DELETE)
          [ "${GH_DELETE_FAIL:-0}" = "1" ] && fail_503
          exit 0
          ;;
        *) echo "STUB: unexpected 'gh api -X ${3:-}'" >&2; exit 99 ;;
      esac
    fi
    case "${2:-}" in
      */commits)
        cat "$GH_ROWS_FILE"
        ;;
      */issues/*/comments)
        [ "${GH_LIST_FAIL:-0}" = "1" ] && fail_503
        printf '%s' "${GH_LIST_IDS:-}"
        ;;
      *)
        # PR head read, used by the revoke step's ownership guard.
        echo "${GH_HEAD:-EVENTSHA}"
        ;;
    esac
    ;;
  pr)
    case "${2:-}" in
      comment)
        [ "${GH_COMMENT_FAIL:-0}" = "1" ] && fail_503
        exit 0
        ;;
      merge)
        [ "${GH_MERGE_FAIL:-0}" = "1" ] && fail_503
        exit 0
        ;;
      view) echo "${GH_ARMED:-true}" ;;
      *) echo "STUB: unexpected 'gh pr ${2:-}'" >&2; exit 99 ;;
    esac
    ;;
  *) echo "STUB: unexpected 'gh ${1:-}'" >&2; exit 99 ;;
esac
STUB
chmod +x "$T/bin/gh"

# Rows are `author|committer|verified` — same fixtures as
# test_bot_skip_commit_authorship.sh.
rows_genuine=$'dependabot[bot]|web-flow|true'
rows_human=$'topcoder1|topcoder1|false'

# ===========================================================================
# 1. claude-review.yml — the required review's bot-skip step.
#    The decision output is `skipped=true`; the comment is the announcement.
# ===========================================================================
extract_run "$REVIEW_WF" "Skip review for bot-authored PRs (dependabot/renovate)" "$T/review.sh" || true

if [ -s "$T/review.sh" ]; then
  review_case() {
    local label="$1" rows="$2" comment_fail="$3"
    echo "· scenario review/$label"
    printf '%s\n' "$rows" > "$T/rows"
    : > "$T/out"
    : > "$T/ghlog"
    rc=0
    (
      PATH="$T/bin:$PATH" \
      GH_ROWS_FILE="$T/rows" GH_LOG="$T/ghlog" GH_COMMENT_FAIL="$comment_fail" \
      GITHUB_OUTPUT="$T/out" GH_TOKEN=stub PR=422 ACTOR='dependabot[bot]' \
      REPO='whois-api-llc/wxa-graph' \
      bash "$T/review.sh"
    ) > "$T/stdout" 2>&1 || rc=$?
  }

  # THE INCIDENT: all-bot PR, decision made, comments API down.
  review_case "incident" "$rows_genuine" 1
  if [ "$rc" -eq 0 ]; then
    pass "review/comment API down: step still exits 0 (required check stays green)"
  else
    fail "review/comment API down: step exited $rc — a comments-API 503 redded the required check (the 2026-08-17 defect)"
    sed 's/^/    /' "$T/stdout"
  fi
  if grep -q '^skipped=true$' "$T/out"; then
    pass "review/comment API down: skipped=true still reaches GITHUB_OUTPUT"
  else
    fail "review/comment API down: skipped=true never written — downstream steps see no decision at all"
  fi
  if grep -q '::warning::' "$T/stdout"; then
    pass "review/comment API down: degraded to a ::warning::"
  else
    fail "review/comment API down: no ::warning:: emitted — the lost comment is invisible in the log"
  fi

  # Control: comments API healthy — decision identical, announcement posted.
  review_case "healthy" "$rows_genuine" 0
  if [ "$rc" -eq 0 ] && grep -q '^skipped=true$' "$T/out" && grep -q '^gh pr comment' "$T/ghlog"; then
    pass "review/comment API healthy: skip decided and announced (control)"
  else
    fail "review/comment API healthy: expected exit 0 + skipped=true + a posted comment (control broke)"
    sed 's/^/    /' "$T/stdout"
  fi

  # Harness validity: a human commit must still send the PR to a full
  # review, with no comment attempted — proves the extracted script's
  # decision logic actually ran rather than short-circuiting.
  review_case "human" "$rows_human" 1
  if [ "$rc" -eq 0 ] && ! grep -q '^skipped=true$' "$T/out" && ! grep -q '^gh pr comment' "$T/ghlog"; then
    pass "review/non-bot commit: full review, no skip, no comment attempted (decision logic intact)"
  else
    fail "review/non-bot commit: expected exit 0, no skip, no comment (rc=$rc)"
    sed 's/^/    /' "$T/stdout"
  fi
fi

# ===========================================================================
# 2. dependabot-auto-merge.yml — the revoke step. The revoke is enforcement;
#    the explanation comment afterwards is reporting.
# ===========================================================================
extract_run "$MERGE_WF" "Revoke the arm if a non-bot commit is present" "$T/revoke.sh" || true

if [ -s "$T/revoke.sh" ]; then
  revoke_case() {
    local label="$1" comment_fail="$2" merge_fail="$3"
    echo "· scenario revoke/$label"
    : > "$T/ghlog"
    rc=0
    (
      PATH="$T/bin:$PATH" \
      GH_LOG="$T/ghlog" GH_ARMED=true GH_HEAD=EVENTSHA HEAD_SHA=EVENTSHA \
      GH_COMMENT_FAIL="$comment_fail" GH_MERGE_FAIL="$merge_fail" \
      GH_TOKEN=stub PR=422 ACTOR='dependabot[bot]' NON_BOT=1 \
      REPO='whois-api-llc/wxa-graph' \
      bash "$T/revoke.sh"
    ) > "$T/stdout" 2>&1 || rc=$?
  }

  # THE PATTERN: revoke executed, then the comments API eats the explanation.
  revoke_case "comment down" 1 0
  if [ "$rc" -eq 0 ] && grep -q '^gh pr merge --disable-auto' "$T/ghlog"; then
    pass "revoke/comment API down: revoke executed and step exits 0 — a SUCCEEDED revoke no longer reads as failed"
  else
    fail "revoke/comment API down: rc=$rc — the explanation comment failure masks a revoke that already succeeded"
    sed 's/^/    /' "$T/stdout"
  fi
  if grep -q 'Revoked auto-merge' "$T/stdout" && grep -q '::warning::' "$T/stdout"; then
    pass "revoke/comment API down: outcome logged, comment loss degraded to a ::warning::"
  else
    fail "revoke/comment API down: expected the 'Revoked auto-merge' log line plus a ::warning::"
    sed 's/^/    /' "$T/stdout"
  fi

  # COUNTER-INVARIANT: the revoke itself failing must stay fatal. Swallowing
  # it would leave a stale arm live on a PR carrying non-bot commits.
  revoke_case "merge down" 0 1
  if [ "$rc" -ne 0 ]; then
    pass "revoke/--disable-auto fails: step stays fatal (enforcement is not reporting)"
  else
    fail "revoke/--disable-auto fails: step exited 0 — a failed revoke was swallowed, stale arm stays live (fail-open)"
    sed 's/^/    /' "$T/stdout"
  fi
fi

# ===========================================================================
# 3. openapi-types-drift.yml — stale-comment cleanup on the PASSING path.
#    drift=0 is the gate saying "clean"; everything in this step is hygiene.
# ===========================================================================
extract_run "$DRIFT_WF" "Remove stale drift comment when clean" "$T/drift_clean.sh" || true

if [ -s "$T/drift_clean.sh" ]; then
  drift_case() {
    local label="$1" list_fail="$2" ids="$3" delete_fail="$4"
    echo "· scenario drift-clean/$label"
    : > "$T/ghlog"
    rc=0
    (
      PATH="$T/bin:$PATH" \
      GH_LOG="$T/ghlog" GH_LIST_FAIL="$list_fail" GH_LIST_IDS="$ids" \
      GH_DELETE_FAIL="$delete_fail" \
      GH_TOKEN=stub PR=422 REPO='whois-api-llc/wxa-graph' \
      bash "$T/drift_clean.sh"
    ) > "$T/stdout" 2>&1 || rc=$?
  }

  drift_case "list down" 1 '' 0
  if [ "$rc" -eq 0 ] && grep -q '::warning::' "$T/stdout"; then
    pass "drift-clean/comment listing down: passing gate stays green, loss is a ::warning::"
  else
    fail "drift-clean/comment listing down: rc=$rc — a comments-API 503 redded the PASSING path"
    sed 's/^/    /' "$T/stdout"
  fi

  drift_case "delete down" 0 $'9001\n' 1
  if [ "$rc" -eq 0 ] && grep -q '::warning::' "$T/stdout"; then
    pass "drift-clean/comment DELETE down: passing gate stays green, loss is a ::warning::"
  else
    fail "drift-clean/comment DELETE down: rc=$rc — a comments-API 503 redded the PASSING path"
    sed 's/^/    /' "$T/stdout"
  fi

  # Controls: with a healthy API the cleanup still actually cleans up…
  drift_case "delete works" 0 $'9001\n' 0
  if [ "$rc" -eq 0 ] && grep -q '^gh api -X DELETE' "$T/ghlog" && grep -q 'Removed stale drift comment' "$T/stdout"; then
    pass "drift-clean/stale comment present: deleted (control)"
  else
    fail "drift-clean/stale comment present: expected exit 0 + a DELETE + the removal log line (rc=$rc)"
    sed 's/^/    /' "$T/stdout"
  fi

  # …and with nothing stale it touches nothing.
  drift_case "nothing stale" 0 '' 0
  if [ "$rc" -eq 0 ] && ! grep -q 'DELETE' "$T/ghlog"; then
    pass "drift-clean/no stale comment: no-op (control)"
  else
    fail "drift-clean/no stale comment: expected exit 0 and no DELETE (rc=$rc)"
    sed 's/^/    /' "$T/stdout"
  fi
fi

# ---------------------------------------------------------------------------
if [ "$failed" -eq 0 ]; then
  echo
  echo "ALL PASS: reporting failures degrade to warnings; decisions and enforcement stand."
else
  echo
  echo "FAILURES above."
fi
exit "$failed"
