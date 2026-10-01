#!/usr/bin/env bash
# Behavioral test for the ownership guards in front of the auto-merge
# revokes: a guard's read counts only when it is well formed, so an API
# error can never pass for a moved head (or base) and skip the revoke.
#
# Every revoke first re-reads the PR and stands down when the head (for the
# base-gate revoke, the base) has moved since its event: a newer run owns
# that decision, and a stale disarm could land after that run validly armed.
# The rule written beside each guard: stand down only on a POSITIVE read; if
# the read itself fails, revoke anyway.
#
# The guards read
#     now=$(gh api "repos/…/pulls/${PR}" --jq .head.sha 2>/dev/null || echo "")
# and stood down on any non-empty `now` that differed. But `gh api` prints an
# HTTP error's JSON body to STDOUT even with --jq, and exits 1. Measured
# 2026-09-30 on gh 2.89.0: a 404 printed
#     {"message":"Not Found","documentation_url":"…","status":"404"}
# on stdout and `gh: Not Found (HTTP 404)` on stderr (gh's processResponse
# skips the --jq filter once it has parsed a server error and copies the body
# to stdout). `|| echo ""` kept that body, the guard took it for a moved
# head, and the revoke was skipped: the arm it exists to remove stayed
# standing, on exactly the failure the rule was written for. `gh pr view` is
# not affected; its GraphQL errors go to stderr only (measured the same day).
#
# The shipped run blocks are extracted by step name and executed against a
# stateful `gh` stub that answers every read by running the step's own --jq
# filter over API-shaped JSON, and serves the scripted answer for a guard
# read:
#
#   claude-author-automerge.yml
#     base   "Revoke auto-merge on base-gate refusal"   (guards on the base)
#     body   "Revoke auto-merge on body-gate refusal"   (guards on the head)
#     error  "Revoke auto-merge if gates errored"       (guards on the head)
#     arm    "Enable auto-merge", its arm-failure branch: a moved head stands
#            down (exit 0); anything else fails the step, and a failed arm
#            step is what fires the error revoke
#   dependabot-auto-merge.yml
#     dependabot  "Revoke the arm if a non-bot commit is present" (guards on
#            the head, and re-reads it right before the disarm)
#
# Cases, for each revoke:
#   1. the read answers an HTTP error's JSON body on stdout with rc=1 (a 404,
#      a 403 rate limit, a 502) ⇒ disarms, and claims no move;
#   2. the read fails with nothing on stdout, rc=1 ⇒ disarms (the shape the
#      old guard already handled; a control);
#   3. the read answers the event's own head or base ⇒ disarms, and the call
#      right before the disarm is that read;
#   4. the read answers a different, well-formed head or base ⇒ keeps the arm
#      with a notice (the guard still stands down on a real move).
# The arm-failure branch:
#   5. an error body ⇒ exit 1 and no "head moved" notice; the error revoke
#      that the failure fires then removes the arm an earlier run placed,
#      with the API still failing;
#   6. the event's own head ⇒ exit 1;
#   7. a different head ⇒ exit 0 with the notice, no ::error::.
# The dependabot revoke:
#   8. the head moves between the guard and the disarm ⇒ keeps the arm (a
#      sibling run may already have armed the new head).
# Negative control:
#   9. the body revoke with the old read planted back ⇒ case 1 keeps the
#      arm: the harness catches exactly this regression.
#
# Run from the repo root:
#   bash selftest/test_automerge_revoke_guard.sh
set -euo pipefail

CA=.github/workflows/claude-author-automerge.yml
DB=.github/workflows/dependabot-auto-merge.yml
failed=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

pass() { echo "✓ $1"; }
fail() {
  echo "✗ $1"
  failed=1
}

extract_run() { # workflow, step name → that step's run block
  awk -v name="      - name: $2" '
    $0 == name { in_step = 1; next }
    in_step && /^      - name: / { exit }
    in_step && /^        run: \|/ { in_run = 1; next }
    in_run {
      if ($0 ~ /^          / || $0 == "") { sub(/^          /, ""); print }
      else { exit }
    }
  ' "$1"
}
step_header() { # workflow, step name → the step's lines from its name to `run: |`
  awk -v name="      - name: $2" '$0 == name { f = 1 } f && /^        run: \|/ { exit } f' "$1"
}

# ---------------------------------------------------------------------------
# 0. Extraction, and the wiring case 5 relies on.
# ---------------------------------------------------------------------------
extract_run "$CA" "Revoke auto-merge on base-gate refusal" > "$T/base.sh"
extract_run "$CA" "Revoke auto-merge on body-gate refusal" > "$T/body.sh"
extract_run "$CA" "Revoke auto-merge if gates errored" > "$T/error.sh"
extract_run "$CA" "Enable auto-merge" > "$T/arm.sh"
extract_run "$DB" "Revoke the arm if a non-bot commit is present" > "$T/dependabot.sh"
for block in base body error dependabot; do
  if ! grep -q -- '--disable-auto' "$T/$block.sh"; then
    echo "✗ could not extract the $block revoke (no --disable-auto in the extracted block)"
    exit 1
  fi
done
if ! grep -q 'gh pr merge --auto' "$T/arm.sh"; then
  echo "✗ could not extract the arm step (no arm command in the extracted block)"
  exit 1
fi
pass "extracted the four revokes and the arm step"

error_header=$(step_header "$CA" "Revoke auto-merge if gates errored")
if grep -qF "steps.arm.outcome == 'failure'" <<< "$error_header"; then
  pass "a failed arm step fires the error revoke (case 5 relies on it)"
else
  fail "the error revoke no longer fires on a failed arm step: an arm failure would leave any standing arm in place"
fi

# ---------------------------------------------------------------------------
# The stub. One PR's state lives in $STUB_DIR: `arm` (ON|OFF), and, for the
# guard reads, `head_reads` / `base_reads`: one scripted answer per line,
# popped per read (the last line repeats):
#   ok:<value>      the read succeeds and the head (or base) is <value>
#   errbody:<code>  gh's HTTP-error shape: the JSON body on STDOUT, rc=1
#   stderr          a failure with nothing on stdout, rc=1 (no response)
# A read is a head read when its --jq filter names the head, a base read
# when it names the base. Every served answer is logged, so a case can prove
# its failure reached the guard. `gh pr merge --auto` fails while `arm_fails`
# exists (GitHub's expected-head rejection).
# ---------------------------------------------------------------------------
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
d="$STUB_DIR"
printf 'gh %s\n' "$*" >> "$d/gh.log"
filter=""
prev=""
for a in "$@"; do
  [ "$prev" = "--jq" ] && filter="$a"
  prev="$a"
done
arm_json() {
  if [ "$(cat "$d/arm")" = "ON" ]; then
    echo '{"autoMergeRequest":{"enabledBy":{"login":"pat-user","is_bot":false}}}'
  else
    echo '{"autoMergeRequest":null}'
  fi
}
pop() { # queue file → its first line; the last line stays
  local first
  first=$(head -n 1 "$1")
  if [ "$(wc -l < "$1")" -gt 1 ]; then
    tail -n +2 "$1" > "$1.next" && mv "$1.next" "$1"
  fi
  printf '%s' "$first"
}
error_body() { # status → gh's stdout and stderr for that HTTP error, rc=1
  case "$1" in
    404)
      echo '{"message":"Not Found","documentation_url":"https://docs.github.com/rest/pulls/pulls#get-a-pull-request","status":"404"}'
      echo "gh: Not Found (HTTP 404)" >&2 ;;
    403)
      echo '{"message":"API rate limit exceeded for installation ID 12345678.","documentation_url":"https://docs.github.com/rest/overview/resources-in-the-rest-api#rate-limiting","status":"403"}'
      echo "gh: API rate limit exceeded for installation ID 12345678. (HTTP 403)" >&2 ;;
    502)
      echo '{"message":"Server Error","status":"502"}'
      echo "gh: Server Error (HTTP 502)" >&2 ;;
    *) echo "STUB: no error body for status $1" >&2; exit 99 ;;
  esac
  exit 1
}
case "${1:-} ${2:-}" in
  "pr view")
    arm_json | jq -r "$filter"
    exit ;;
  "pr merge")
    case " $* " in
      *" --disable-auto "*)
        echo OFF > "$d/arm"
        exit 0 ;;
      *" --auto "*)
        if [ -e "$d/arm_fails" ]; then
          echo "GraphQL: Head sha didn't match expected head sha (enablePullRequestAutoMerge)" >&2
          exit 1
        fi
        echo ON > "$d/arm"
        exit 0 ;;
    esac ;;
  "pr comment")
    exit 0 ;;
  "api user")
    echo '{"login":"pat-user","type":"User"}' | jq -r "$filter"
    exit ;;
esac
if [ "${1:-}" = "api" ]; then
  case "$filter" in
    *head*) kind=head ;;
    *base*) kind=base ;;
    *) kind=other ;;
  esac
  head="$EVENT_HEAD"
  base="$EVENT_BASE"
  if [ -s "$d/${kind}_reads" ]; then
    answer=$(pop "$d/${kind}_reads")
    echo "served $kind $answer" >> "$d/served.log"
    case "$answer" in
      ok:*)
        if [ "$kind" = head ]; then head="${answer#ok:}"; else base="${answer#ok:}"; fi ;;
      errbody:*) error_body "${answer#errbody:}" ;;
      stderr)
        echo "error connecting to api.github.com" >&2
        exit 1 ;;
      *) echo "STUB: unknown scripted answer '$answer'" >&2; exit 99 ;;
    esac
  fi
  jq -n --arg h "$head" --arg b "$base" '{head: {sha: $h}, base: {ref: $b}, body: ""}' | jq -r "$filter"
  exit
fi
echo "STUB: unexpected 'gh $*'" >&2
exit 99
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/sleep"
chmod +x "$T/bin/gh" "$T/bin/sleep"

EVENT_HEAD=$(printf 'c0ffee%034d' 1)
NEW_HEAD=$(printf 'c0ffee%034d' 2)
S="$T/state"

# run_block <script> <head reads> [<base reads>] → $T/out ending in rc=<n>.
# Reads are space-separated queue entries. The PR starts armed by an earlier
# run unless KEEP_STATE=1 carries the previous block's state over (the error
# revoke running after a failed arm step, on the same PR).
run_block() {
  if [ "${KEEP_STATE:-0}" != "1" ]; then
    rm -rf "$S"
    mkdir -p "$S"
    echo ON > "$S/arm"
    : > "$S/gh.log"
    : > "$S/ghout"
  fi
  : > "$S/served.log"
  rm -f "$S/head_reads" "$S/base_reads" "$S/arm_fails"
  if [ -n "$2" ]; then printf '%s\n' "$2" | tr ' ' '\n' > "$S/head_reads"; fi
  if [ -n "${3:-}" ]; then printf '%s\n' "$3" | tr ' ' '\n' > "$S/base_reads"; fi
  if [ "${ARM_FAILS:-0}" = "1" ]; then : > "$S/arm_fails"; fi
  local rc=0
  (
    export PATH="$T/bin:$PATH" STUB_DIR="$S" EVENT_HEAD EVENT_BASE=main \
      GITHUB_OUTPUT="$S/ghout" GITHUB_REPOSITORY="stub/repo" REPO="stub/repo" \
      GH_TOKEN=stub BOT_TOKEN=stub PR=42 PR_URL="https://github.com/stub/repo/pull/42" \
      HEAD_SHA="$EVENT_HEAD" GATE_BASE_REF=main GATE_BODY_SHA="" \
      ACTOR='dependabot[bot]' NON_BOT=1 METHOD=squash REASON="branch=claude/x" \
      RISKY=0 BYPASS_LABEL=0 BYPASS_CODEX=0 USING_PAT=1 PR_AUTHOR=topcoder1 \
      DEFAULT_BRANCH=main OPTIN_LABEL=auto-merge-nonmain \
      CLASSIFIER_HEAD="$EVENT_HEAD" RISK_HEAD="$EVENT_HEAD"
    bash "$1"
  ) > "$T/out" 2>&1 < /dev/null || rc=$?
  echo "rc=$rc" >> "$T/out"
}
has() { grep -qF -- "$1" "$T/out"; }
disarmed() { grep -q '^gh pr merge --disable-auto' "$S/gh.log"; }
arm_is() { [ "$(cat "$S/arm")" = "$1" ]; }
served() { grep -qxF "served $1" "$S/served.log"; }
before_disarm() { # the gh call right before the first disarm
  awk '/^gh pr merge --disable-auto/ { print prev; exit } { prev = $0 }' "$S/gh.log"
}
dump() {
  sed 's/^/    out: /' "$T/out"
  sed 's/^/    gh:  /' "$S/gh.log"
}

# ---------------------------------------------------------------------------
# 1–4. Each revoke, against each shape of guard read.
# ---------------------------------------------------------------------------
revoke_cases() { # block, read kind (head|base), the notice a real move prints
  local block="$1" kind="$2" moved_notice="$3" event moved code
  if [ "$kind" = head ]; then event="$EVENT_HEAD" moved="$NEW_HEAD"; else event=main moved=release; fi
  reads() { if [ "$kind" = head ]; then run_block "$T/$block.sh" "$1"; else run_block "$T/$block.sh" "" "$1"; fi; }

  for code in 404 403 502; do
    reads "errbody:$code"
    if disarmed && arm_is OFF && has "rc=0" && ! has "$moved_notice" && served "$kind errbody:$code"; then
      pass "1: $block: the $kind read answers an HTTP $code error body on stdout ⇒ disarms"
    else
      fail "1: $block: an HTTP $code error body was taken for a moved $kind; the revoke was skipped and the arm stands"
      dump
    fi
  done

  reads "stderr"
  if disarmed && arm_is OFF && has "rc=0" && served "$kind stderr"; then
    pass "2: $block: the $kind read fails with nothing on stdout ⇒ disarms"
  else
    fail "2: $block: a failed $kind read must still disarm"
    dump
  fi

  reads "ok:$event"
  if disarmed && arm_is OFF && has "rc=0" && [[ "$(before_disarm)" == "gh api "*"--jq .$kind."* ]]; then
    pass "3: $block: the event's own $kind ⇒ disarms, and the $kind is read right before the disarm"
  else
    fail "3: $block: an unchanged $kind must disarm, with the $kind read immediately before (got: '$(before_disarm)')"
    dump
  fi

  reads "ok:$moved"
  if ! disarmed && arm_is ON && has "rc=0" && has "$moved_notice"; then
    pass "4: $block: a different $kind ⇒ keeps the arm with a notice (a real move still stands down)"
  else
    fail "4: $block: a positively read move must stand down and leave the newer run's arm alone"
    dump
  fi
}
revoke_cases base base "base changed"
revoke_cases body head "head moved"
revoke_cases error head "head moved"
revoke_cases dependabot head "head moved"

# ---------------------------------------------------------------------------
# 5–7. The arm step's failure branch.
# ---------------------------------------------------------------------------
ARM_FAILS=1 run_block "$T/arm.sh" "errbody:404"
if has "rc=1" && has "::error::enable auto-merge failed" && ! has "head moved" && served "head errbody:404" && arm_is ON; then
  pass "5: arm: the arm fails and the head read answers an error body ⇒ exit 1 and no 'head moved' claim"
else
  fail "5: arm: an error body was taken for a moved head; the failed arm exits green and the error revoke never fires"
  dump
fi
# The failure above fires the error revoke on the same PR (pinned in 0.),
# with the API still failing; the arm an earlier run placed must come off.
KEEP_STATE=1 run_block "$T/error.sh" "errbody:404"
if disarmed && arm_is OFF && has "rc=0" && served "head errbody:404"; then
  pass "5: the error revoke that failure fires removes the standing arm"
else
  fail "5: after a failed arm with an unreadable head, the standing arm survived"
  dump
fi

ARM_FAILS=1 run_block "$T/arm.sh" "ok:$EVENT_HEAD"
if has "rc=1" && has "::error::enable auto-merge failed and the head still matches $EVENT_HEAD"; then
  pass "6: arm: the arm fails on the event's own head ⇒ exit 1"
else
  fail "6: arm: a failed arm on an unchanged head must fail the step"
  dump
fi

ARM_FAILS=1 run_block "$T/arm.sh" "ok:$NEW_HEAD"
if has "rc=0" && has "head moved ($EVENT_HEAD → $NEW_HEAD)" && ! has "::error::"; then
  pass "7: arm: the arm fails because the head moved ⇒ exit 0 with the notice"
else
  fail "7: arm: a positively read move must stand down cleanly"
  dump
fi

# ---------------------------------------------------------------------------
# 8. The dependabot revoke re-reads the head right before its disarm.
# ---------------------------------------------------------------------------
run_block "$T/dependabot.sh" "ok:$EVENT_HEAD ok:$NEW_HEAD"
if ! disarmed && arm_is ON && has "rc=0" && has "head moved" \
  && [ "$(grep -c '^served head ' "$S/served.log")" = "2" ]; then
  pass "8: dependabot: the head moves after the guard, before the disarm ⇒ keeps the arm"
else
  fail "8: dependabot: a head that moved after the guard read was disarmed anyway"
  dump
fi

# ---------------------------------------------------------------------------
# 9. Negative control: the old read, planted back into the body revoke.
# ---------------------------------------------------------------------------
if python3 - "$T/body.sh" "$T/body_old.sh" <<'PY'; then
import sys
src = open(sys.argv[1]).read()
for new, old in [
    ('2>/dev/null) || now=""', '2>/dev/null || echo "")'),
    ('[[ "$now" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]]', '[ -n "$now" ]'),
]:
    if src.count(new) != 1:
        sys.exit(f"cannot plant the old read: {new!r} appears {src.count(new)} times")
    src = src.replace(new, old)
open(sys.argv[2], "w").write(src)
PY
  run_block "$T/body_old.sh" "errbody:404"
  if ! disarmed && arm_is ON && has "head moved"; then
    pass "9: negative control: the old read keeps the arm on an error body (the harness sees the regression)"
  else
    fail "9: negative control: the planted old read disarmed; the error-body case no longer tests anything"
    dump
  fi
else
  fail "9: negative control: the body revoke no longer carries the SHA-checked read to plant the old one over"
fi

echo ""
if [ "$failed" -ne 0 ]; then
  echo "FAIL: a revoke ownership guard can be skipped by an API error."
  exit 1
fi
echo "PASS: every revoke guard disarms unless it positively reads a move."
