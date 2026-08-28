#!/usr/bin/env bash
# Behavioral test for the arbiter decision-label step in
# claude-author-automerge.yml — the step that makes a deliberate
# non-arm legible at the surface operators actually probe.
#
# Incident context (whois-api-llc/wxa-graph#476 + #478, 2026-08-28):
# two Claude-authored PRs ended CLEAN, all checks green,
# autoMergeRequest=null. #476 was withheld by the unaddressed-findings
# gate (a Codex finding postdated the last commit); #478 was blocked by
# the risk-tier regex ((^|/)main\.go$) with the Codex bypass
# deliberately unreachable (review_standard boundary). Both decisions
# were correct — but both runs were GREEN and the reasons lived only in
# sticky comments and log ::notices, so the operator diagnosed the
# known cancel-in-progress wedge, burned a label-refire on the PR where
# it could not help (#476), and never tried it on the PR where it would
# have (#478). The decision-label step publishes exactly one
# `automerge:*` label naming the standing decision, so
# "autoMergeRequest=null + automerge:* label" reads as a deliberate
# abstention and "…with NO automerge:* label" keeps meaning wedge.
#
# This test EXTRACTS the step's bash from the workflow YAML (the
# shipped script, not a mirrored copy) and executes it against a
# stubbed `gh`:
#
#   1.  findings decision ⇒ stale `automerge:blocked-risk-tier` DELETEd
#       (URL-encoded), `automerge:withheld-findings` created + POSTed;
#       foreign labels (risk:standard, auto-merge-approved) untouched.
#   2.  armed ⇒ every `automerge:*` label removed, nothing added; the
#       colon-less near-misses `automerge` and `auto-merge` survive
#       (prefix is EXACTLY `automerge:` — the arbiter must never eat
#       the fleet's bypass/override labels).
#   3.  no terminal state this run owns (all inputs empty — arm stood
#       down on a moved head, or a gate errored) ⇒ ZERO gh calls: a
#       stale run must not clear a newer run's valid label.
#   4.  idempotent: decision label already present ⇒ read only, zero
#       mutating calls (no delete/create/POST churn on every event).
#   5.  risky with no bypass ⇒ `automerge:blocked-risk-tier`.
#   6.  risky but Codex-bypassed, quiet gate unset ⇒ no publish (the
#       arm path owns the outcome; its absence means the run died
#       mid-flight — not this step's story to tell).
#   7.  label read fails ⇒ exit 0 with ::warning, no mutations
#       (advisory surface — a label blip must not redden a correct
#       gate decision).
#   8.  POST fails ⇒ exit 0 with ::warning (non-fatal, single attempt —
#       no gh-retry double-fire).
#   9.  hold=1 ⇒ arbiter labels cleared (the hold label is the signal).
#  10.  quiet-cap ⇒ `automerge:withheld-quiet-cap` (previously the
#       least visible state: log-only, no comment).
#  11.  base refusal outranks a simultaneous risky match ⇒
#       `automerge:refused-base` (mirrors the arm gate's precedence).
#  12.  classifier-blocked ⇒ `automerge:blocked-classifier` published
#       and stale arbiter labels swapped out — NOT a clear: the verdict
#       can come from the direct risk-paths.yml read with no risk:*
#       label on the PR (pr-classify absent/lagging/failed), and the
#       "no automerge:* label = wedge" contract only holds if every
#       abstention labels (codex round-3 P2).
#  13.  DELETE of a stale label fails ⇒ exit 0 (non-fatal).
#  14.  ownership probe: live head ≠ this run's head ⇒ zero label
#       mutations (a superseded run's stale decision must not repaint
#       labels the newer head's run owns — codex round-1 P2).
#  15.  ownership probe: live head unreadable ⇒ ::warning + exit 0,
#       zero mutations (fails toward silence, never a stale repaint).
#  16.  arm stood down on pre-arm base revalidation (stood_down=base)
#       ⇒ `automerge:refused-base` — the disarm-then-green path was the
#       one remaining unlabeled wedge signature (codex round-1 P2).
#       NOTE the accepted snapshot semantics (codex round-2): a base
#       retarget AFTER a run ends emits only `edited` (unsubscribed),
#       so the label goes stale until the next event's run reconciles
#       it — unfixable at publish time, and its remedy line stays the
#       correct operator move; the label wording points at the remedy,
#       not a live fact.
#  17.  `gh label create` conflict (already exists) is tolerated: the
#       add still lands, exit 0 — real failures report at the POST
#       (codex round-1 P3, pinned as designed).
#  18.  the create conflict falls through to `gh label edit`, so a
#       repo that minted the label under older wording gets its
#       description refreshed (codex round-3 P3).
#
# Structural pins:
#   * the arm step carries `id: arm` and publishes `armed=1` AFTER the
#     `gh pr merge --auto` call (the reconciler keys "clear labels" off
#     it; the head-moved stand-down must exit before it).
#   * bypass_codex publishes `state=` for the risk-tier comment.
#   * the risk-tier comment no longer promises the dead-end "workflow
#     auto-bypasses … on its next run" recovery: a completing check
#     fires no run, bot label writes fire nothing, and repos routing
#     standard-tier PRs to `review_standard / Codex Review` exclude the
#     bypass BY DESIGN (wxa-graph pr-codex-review.yml's documented
#     security boundary). The comment must say what actually re-fires
#     the workflow.
#   * the decision-label run block is `${{ }}`-free (extraction-safe
#     and injection-safe), its label read paginates, and the step sits
#     BEFORE the always() error-revoke step (which must stay last).
#
# Run from the repo root:
#   bash selftest/test_automerge_decision_label.sh
set -euo pipefail

WF=.github/workflows/claude-author-automerge.yml
failed=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# ---------------------------------------------------------------------------
# 0a. Structural pins.
# ---------------------------------------------------------------------------
if awk '/^      - name: Enable auto-merge$/{f=1} f && /^        id: arm$/{found=1} f && /^      - name:/ && !/Enable auto-merge/{f=0} END{exit !found}' "$WF"; then
  echo "✓ arm step carries id: arm"
else
  echo "✗ arm step has no id: arm — the decision-label reconciler cannot see steps.arm.outputs.armed"
  failed=1
fi

if grep -q 'echo "armed=1" >> "\$GITHUB_OUTPUT"' "$WF"; then
  echo "✓ arm step publishes armed=1"
else
  echo "✗ arm step does not publish armed=1 — armed PRs would keep stale abstention labels"
  failed=1
fi

if grep -q 'state=\${codex_state:-absent}' "$WF"; then
  echo "✓ bypass_codex publishes its observed state"
else
  echo "✗ bypass_codex does not publish state= — the risk-tier comment cannot show what the gate observed"
  failed=1
fi

if grep -q 'auto-bypasses' "$WF"; then
  echo "✗ risk-tier comment still promises the workflow 'auto-bypasses … on its next run' — there is no next run: checks completing fire no pull_request event and bot label writes fire nothing (wxa-graph#478)"
  failed=1
else
  echo "✓ dead-end 'auto-bypasses on its next run' promise is gone"
fi

if grep -q 'a check completing fires' "$WF" && grep -q 'review_standard / Codex Review' "$WF"; then
  echo "✓ risk-tier comment states the real re-fire semantics and the review_standard boundary"
else
  echo "✗ risk-tier comment does not explain what actually re-fires the workflow / the review_standard exclusion"
  failed=1
fi

# Step order: decision label BEFORE the error-revoke step (whose contract
# is to run last).
order=$(awk '/^      - name: Publish arbiter decision label$/{print "decision"} /^      - name: Revoke auto-merge if gates errored$/{print "revoke"}' "$WF" | paste -sd, -)
if [ "$order" = "decision,revoke" ]; then
  echo "✓ decision-label step precedes the always() error-revoke step"
else
  echo "✗ step order is '$order' — expected the decision-label step before the error-revoke step (which must stay last)"
  failed=1
fi

if grep -q 'DECISION LABELS' "$WF"; then
  echo "✓ workflow header documents the decision-label contract"
else
  echo "✗ workflow header does not document the decision-label contract"
  failed=1
fi

if awk '/^      - name: Publish arbiter decision label$/{f=1} f && /!cancelled\(\)/{found=1} f && /^        run: \|/{f=0} END{exit !found}' "$WF"; then
  echo "✓ decision step gates on !cancelled() — a cancelled superseded run cannot repaint labels"
else
  echo "✗ decision step does not gate on !cancelled() — a cancelled run's always() pass could publish stale state"
  failed=1
fi

if grep -q 'stood_down=base' "$WF"; then
  echo "✓ pre-arm base-revalidation stand-downs publish stood_down=base (no unlabeled disarm-then-green)"
else
  echo "✗ disarm_then_exit does not publish stood_down=base — base-revalidation stand-downs stay unlabeled wedge signatures"
  failed=1
fi

# ---------------------------------------------------------------------------
# 0b. Extract the decision-label step's run block — the shipped bash, not a
#     mirrored copy.
# ---------------------------------------------------------------------------
awk '
  /^      - name: Publish arbiter decision label$/ { in_step=1 }
  in_step && /^        run: \|/ { in_run=1; next }
  in_run {
    if ($0 ~ /^          / || $0 == "") { sub(/^          /, ""); print }
    else { exit }
  }
' "$WF" > "$T/decision.sh"

if ! grep -q 'automerge:blocked-risk-tier' "$T/decision.sh" || ! grep -q 'publish=0' "$T/decision.sh"; then
  echo "✗ could not extract the decision-label run block from $WF"
  exit 1
fi
echo "✓ extracted decision-label step ($(wc -l < "$T/decision.sh" | tr -d ' ') lines)"

if grep -q '${{' "$T/decision.sh"; then
  echo "✗ decision-label run block contains \${{ }} interpolation — untestable standalone and an injection-risk pattern; use env vars (\$GITHUB_REPOSITORY)"
  failed=1
else
  echo "✓ decision-label run block is interpolation-free (env vars only)"
fi

if grep -q 'labels?per_page=100' "$T/decision.sh" && grep -A1 'labels?per_page=100' "$T/decision.sh" | grep -q -- '--paginate'; then
  echo "✓ label read paginates (an arbiter label past the 30-label default page cannot read as absent)"
else
  echo "✗ label read does not paginate"
  failed=1
fi

# ---------------------------------------------------------------------------
# 0c. Stubs. `gh` dispatches on argv and logs every call. Knobs (env):
#       STUB_LABELS            — newline-separated current label names
#       STUB_LABELS_FAIL       — 1 ⇒ the labels read exits 1
#       STUB_DELETE_FAIL       — 1 ⇒ every DELETE exits 1
#       STUB_POST_FAIL         — 1 ⇒ every POST exits 1
#       STUB_LIVE_HEAD         — sha the pulls read returns (ownership probe)
#       STUB_HEAD_FAIL         — 1 ⇒ the pulls read exits 1
#       STUB_CREATE_FAIL       — 1 ⇒ `gh label create` exits 1 (conflict)
# ---------------------------------------------------------------------------
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_LOG"
case "$1" in
  api)
    shift
    method="GET"
    if [ "$1" = "-X" ]; then method="$2"; shift 2; fi
    path="$1"
    case "$method $path" in
      "GET "*"/pulls/"*)
        if [ "${STUB_HEAD_FAIL:-0}" = "1" ]; then exit 1; fi
        # The step pipes through --jq .head.sha; emit the sha directly.
        printf '%s\n' "${STUB_LIVE_HEAD:-}"
        exit 0 ;;
      "GET "*"/labels?per_page=100")
        if [ "${STUB_LABELS_FAIL:-0}" = "1" ]; then exit 1; fi
        # The step pipes through --jq '.[].name'; emit names directly.
        printf '%s\n' "${STUB_LABELS:-}"
        exit 0 ;;
      "DELETE "*)
        [ "${STUB_DELETE_FAIL:-0}" = "1" ] && exit 1
        exit 0 ;;
      "POST "*)
        [ "${STUB_POST_FAIL:-0}" = "1" ] && exit 1
        exit 0 ;;
    esac
    exit 0 ;;
  label)
    # gh label create|edit <name> --color … --description …
    if [ "$2" = "create" ] && [ "${STUB_CREATE_FAIL:-0}" = "1" ]; then exit 1; fi
    exit 0 ;;
esac
exit 0
STUB
chmod +x "$T/bin/gh"

HEAD="feedc0dedeadbeef"

run_case() { # name; env knobs via caller exports
  : > "$T/gh.log"
  local rc=0
  ( export PATH="$T/bin:$PATH" GH_LOG="$T/gh.log" \
      GITHUB_REPOSITORY="stub/repo" PR="42" GH_TOKEN=x GH_REPO="stub/repo" \
      HEAD_SHA="$HEAD" STUB_LIVE_HEAD="${STUB_LIVE_HEAD:-$HEAD}"
    bash "$T/decision.sh" ) > "$T/out.log" 2>&1 || rc=$?
  echo "rc=$rc" >> "$T/out.log"
}

expect() { # description, grep-pattern, file
  if grep -qF -- "$2" "$3"; then
    echo "✓ $1"
  else
    echo "✗ $1 — pattern '$2' absent from $3:"
    sed 's/^/    /' "$3"
    failed=1
  fi
}
expect_absent() {
  if grep -qF -- "$2" "$3"; then
    echo "✗ $1 — pattern '$2' unexpectedly present in $3:"
    sed 's/^/    /' "$3"
    failed=1
  else
    echo "✓ $1"
  fi
}

# ---------------------------------------------------------------------------
# 1. findings decision reconciles: stale risk-tier label out (URL-encoded),
#    withheld-findings in, foreign labels untouched.
# ---------------------------------------------------------------------------
export ARMED="" ARM_STOOD_DOWN="" BLOCKED="" HOLD="" BASE_REFUSE="" RISKY="" BYPASS_LBL="" BYPASS_CDX="" QF_REASON="findings"
export STUB_LABELS=$'risk:standard\nautomerge:blocked-risk-tier\nauto-merge-approved'
export STUB_LABELS_FAIL=0 STUB_DELETE_FAIL=0 STUB_POST_FAIL=0 STUB_HEAD_FAIL=0 STUB_CREATE_FAIL=0
run_case findings
expect "1a: stale automerge:blocked-risk-tier deleted, colon URL-encoded" \
  "api -X DELETE /repos/stub/repo/issues/42/labels/automerge%3Ablocked-risk-tier" "$T/gh.log"
expect "1b: automerge:withheld-findings ensured (gh label create)" \
  "label create automerge:withheld-findings" "$T/gh.log"
expect "1c: automerge:withheld-findings added to the PR" \
  "api -X POST /repos/stub/repo/issues/42/labels -f labels[]=automerge:withheld-findings" "$T/gh.log"
expect_absent "1d: risk:standard untouched" "labels/risk" "$T/gh.log"
expect_absent "1e: auto-merge-approved untouched" "auto-merge-approved" "$T/gh.log"
expect "1f: step exits 0" "rc=0" "$T/out.log"

# ---------------------------------------------------------------------------
# 2. armed clears arbiter labels; colon-less near-misses survive.
# ---------------------------------------------------------------------------
export ARMED="1" QF_REASON=""
export STUB_LABELS=$'automerge:withheld-findings\nautomerge\nauto-merge'
run_case armed
expect "2a: armed run deletes the stale arbiter label" \
  "api -X DELETE /repos/stub/repo/issues/42/labels/automerge%3Awithheld-findings" "$T/gh.log"
if grep -qE 'labels/automerge$|labels/auto-merge$' "$T/gh.log"; then
  echo "✗ 2b: a colon-less near-miss label was deleted — prefix must be exactly 'automerge:'"
  sed 's/^/    /' "$T/gh.log"
  failed=1
else
  echo "✓ 2b: colon-less near-misses ('automerge', 'auto-merge') survive"
fi
if [ "$(grep -c 'DELETE' "$T/gh.log")" = "1" ]; then
  echo "✓ 2c: exactly one DELETE (near-misses 'automerge'/'auto-merge' untouched)"
else
  echo "✗ 2c: expected exactly one DELETE, log:"; sed 's/^/    /' "$T/gh.log"; failed=1
fi
expect_absent "2d: nothing added on an armed run" "POST" "$T/gh.log"

# ---------------------------------------------------------------------------
# 3. no terminal state ⇒ zero gh calls.
# ---------------------------------------------------------------------------
export ARMED="" BLOCKED="" HOLD="" BASE_REFUSE="" RISKY="" QF_REASON=""
export STUB_LABELS=""
run_case noop
if [ ! -s "$T/gh.log" ]; then
  echo "✓ 3: run with no owned terminal state makes zero gh calls (no clobbering a newer run's label)"
else
  echo "✗ 3: expected zero gh calls, log:"; sed 's/^/    /' "$T/gh.log"; failed=1
fi
expect "3b: says so" "No arbiter decision to publish" "$T/out.log"

# ---------------------------------------------------------------------------
# 4. idempotent: decision label already present ⇒ read-only.
# ---------------------------------------------------------------------------
export QF_REASON="findings"
export STUB_LABELS="automerge:withheld-findings"
run_case idempotent
if ! grep -qE 'DELETE|POST|label create' "$T/gh.log"; then
  echo "✓ 4: already-correct label ⇒ zero mutating calls"
else
  echo "✗ 4: expected read-only, log:"; sed 's/^/    /' "$T/gh.log"; failed=1
fi

# ---------------------------------------------------------------------------
# 5. risky with no bypass ⇒ blocked-risk-tier.
# ---------------------------------------------------------------------------
export QF_REASON="" RISKY="1" BYPASS_LBL="0" BYPASS_CDX="0"
export STUB_LABELS=""
run_case risky
expect "5: risky-no-bypass publishes automerge:blocked-risk-tier" \
  "labels[]=automerge:blocked-risk-tier" "$T/gh.log"

# ---------------------------------------------------------------------------
# 6. risky but Codex-bypassed, quiet outputs empty ⇒ no publish.
# ---------------------------------------------------------------------------
export BYPASS_CDX="1"
run_case risky_bypassed
if [ ! -s "$T/gh.log" ]; then
  echo "✓ 6: risky-but-bypassed with no quiet verdict publishes nothing"
else
  echo "✗ 6: expected zero gh calls, log:"; sed 's/^/    /' "$T/gh.log"; failed=1
fi

# ---------------------------------------------------------------------------
# 7. label read fails ⇒ exit 0, warning, no mutations.
# ---------------------------------------------------------------------------
export BYPASS_CDX="0" QF_REASON="" RISKY="1"
export STUB_LABELS_FAIL=1
run_case read_fail
expect "7a: degraded to a warning" "::warning::could not read PR labels" "$T/out.log"
expect_absent "7b: no mutations after a failed read" "DELETE" "$T/gh.log"
expect_absent "7c: no adds after a failed read" "POST" "$T/gh.log"
expect "7d: step exits 0 (advisory surface)" "rc=0" "$T/out.log"
export STUB_LABELS_FAIL=0

# ---------------------------------------------------------------------------
# 8. POST fails ⇒ exit 0 with warning (single attempt, non-fatal).
# ---------------------------------------------------------------------------
export STUB_POST_FAIL=1 STUB_LABELS=""
run_case post_fail
expect "8a: add failure degrades to a warning" "::warning::could not add arbiter decision label" "$T/out.log"
expect "8c: step exits 0 (non-fatal)" "rc=0" "$T/out.log"
expect_absent "8d: no false 'Published' success line when the POST failed" "Published arbiter decision label" "$T/out.log"
if [ "$(grep -c 'POST' "$T/gh.log")" = "1" ]; then
  echo "✓ 8b: exactly one POST attempt (no gh-retry double-fire)"
else
  echo "✗ 8b: expected exactly one POST, log:"; sed 's/^/    /' "$T/gh.log"; failed=1
fi
export STUB_POST_FAIL=0

# ---------------------------------------------------------------------------
# 9. hold ⇒ arbiter labels cleared.
# ---------------------------------------------------------------------------
export RISKY="" HOLD="1"
export STUB_LABELS="automerge:blocked-risk-tier"
run_case hold
expect "9a: hold clears the stale arbiter label" "DELETE" "$T/gh.log"
expect_absent "9b: hold adds nothing" "POST" "$T/gh.log"
export HOLD=""

# ---------------------------------------------------------------------------
# 10. quiet-cap ⇒ withheld-quiet-cap.
# ---------------------------------------------------------------------------
export QF_REASON="quiet-cap" STUB_LABELS=""
run_case quiet_cap
expect "10: quiet-cap publishes automerge:withheld-quiet-cap" \
  "labels[]=automerge:withheld-quiet-cap" "$T/gh.log"

# ---------------------------------------------------------------------------
# 11. base refusal outranks a simultaneous risky match.
# ---------------------------------------------------------------------------
export QF_REASON="" BASE_REFUSE="1" RISKY="1"
run_case base_refuse
expect "11: refused-base wins precedence over blocked-risk-tier" \
  "labels[]=automerge:refused-base" "$T/gh.log"
export BASE_REFUSE="" RISKY=""

# ---------------------------------------------------------------------------
# 12. classifier-blocked ⇒ publishes automerge:blocked-classifier.
# ---------------------------------------------------------------------------
export BLOCKED="1"
export STUB_LABELS="automerge:withheld-findings"
run_case blocked
expect "12a: classifier-blocked swaps out the stale arbiter label" \
  "api -X DELETE /repos/stub/repo/issues/42/labels/automerge%3Awithheld-findings" "$T/gh.log"
expect "12b: classifier-blocked publishes its own decision label (label can exist with NO risk:* label on the PR)" \
  "labels[]=automerge:blocked-classifier" "$T/gh.log"
export BLOCKED=""

# ---------------------------------------------------------------------------
# 13. DELETE failure is non-fatal.
# ---------------------------------------------------------------------------
export ARMED="1" STUB_DELETE_FAIL=1
export STUB_LABELS="automerge:withheld-findings"
run_case delete_fail
expect "13a: delete failure degrades to a warning" "::warning::could not remove stale arbiter label" "$T/out.log"
expect "13b: step exits 0 (non-fatal)" "rc=0" "$T/out.log"
export ARMED="" STUB_DELETE_FAIL=0

# ---------------------------------------------------------------------------
# 14. ownership probe: live head moved ⇒ zero mutations.
# ---------------------------------------------------------------------------
export QF_REASON="findings" STUB_LABELS="automerge:blocked-risk-tier"
export STUB_LIVE_HEAD="0000000000000000"
run_case head_moved
expect "14a: stands down on a moved head" "the newer head's run owns the labels" "$T/out.log"
expect_absent "14b: no deletes from a superseded run" "DELETE" "$T/gh.log"
expect_absent "14c: no adds from a superseded run" "POST" "$T/gh.log"
expect "14d: step exits 0" "rc=0" "$T/out.log"
unset STUB_LIVE_HEAD

# ---------------------------------------------------------------------------
# 15. ownership probe: live head unreadable ⇒ warning, zero mutations.
# ---------------------------------------------------------------------------
export STUB_HEAD_FAIL=1
run_case head_fail
expect "15a: degraded to a warning" "::warning::could not read the live head" "$T/out.log"
expect_absent "15b: no mutations on an unreadable head" "DELETE" "$T/gh.log"
expect_absent "15c: no adds on an unreadable head" "POST" "$T/gh.log"
expect "15d: step exits 0" "rc=0" "$T/out.log"
export STUB_HEAD_FAIL=0

# ---------------------------------------------------------------------------
# 16. arm stood down on pre-arm base revalidation ⇒ refused-base.
# ---------------------------------------------------------------------------
export QF_REASON="" ARM_STOOD_DOWN="base" STUB_LABELS=""
run_case stood_down
expect "16: base-revalidation stand-down publishes automerge:refused-base" \
  "labels[]=automerge:refused-base" "$T/gh.log"
export ARM_STOOD_DOWN=""

# ---------------------------------------------------------------------------
# 17+18. `gh label create` conflict tolerated; falls through to edit
#        (description refresh); the add still lands.
# ---------------------------------------------------------------------------
export QF_REASON="findings" STUB_CREATE_FAIL=1 STUB_LABELS=""
run_case create_conflict
expect "17a: add lands despite a create conflict" \
  "labels[]=automerge:withheld-findings" "$T/gh.log"
expect "17b: step exits 0" "rc=0" "$T/out.log"
expect "18: create conflict falls through to gh label edit (stale description refresh)" \
  "label edit automerge:withheld-findings" "$T/gh.log"
export STUB_CREATE_FAIL=0

# ---------------------------------------------------------------------------
if [ "$failed" -ne 0 ]; then
  echo ""
  echo "FAILED — see ✗ lines above."
  exit 1
fi
echo ""
echo "All decision-label selftests passed."
