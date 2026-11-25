#!/usr/bin/env bash
# Behavioral test for the retry in claude-author-automerge.yml's last step,
# "Revoke auto-merge if gates errored": the always() revoke that every gate
# failure in that workflow relies on to remove an arm an earlier run placed
# (the 3000-file cap, unreadable rules, classifier errors, the
# control-character names of topcoder1/ci-workflows#312, a failed disarm in
# another revoke).
#
# The step ran `gh pr merge --disable-auto` ONCE, `|| true`, then verified.
# One transient API error therefore left the arm standing: the job ended red,
# GitHub kept the auto-merge request, and the PR merged once its required
# checks passed, a revision no gate had cleared. An unreadable verification
# read aborted the step under `set -e` with no retry either. Found by Codex
# pre-review round 3 of #312.
#
# The step now disarms in safe-paths-automerge.yml's revoke shape: up to three
# attempts as github-actions[bot], each after a head-moved check and each
# verified, where only a read of OFF counts (UNKNOWN is not OFF); then the
# same as the automerge_pat user; else it fails with an ::error::. The bot
# goes first because this workflow's manual-hold step (Signal 2) ignores only
# github-actions[bot] disables: a disarm recorded as the PAT user reads as a
# HUMAN's durable hold, and the PR never re-arms on its own.
#
# The shipped run block is extracted by step name and executed against a
# stateful `gh` stub that holds one PR's state: the arm, the live head, and
# the timeline, where each disarm lands under the actor of the token that ran
# it. After a revoke, the SHIPPED "Check manual hold" step runs against the
# same PR, the way this workflow's next run reads it.
#
# Cases:
#   0. wiring: the revoke runs under github.token, with the caller's
#      automerge_pat as its fallback token;
#   1. the first disarm fails transiently (a 502), the second takes ⇒ OFF,
#      both attempts as the bot, and the next run reads no hold;
#   2. GitHub refuses the bot's disarm every time ⇒ three bot attempts, then
#      the PAT ⇒ OFF, with a ::warning:: naming the cost: the next run reads
#      the PAT's disarm as a human's hold (the decision this pins: a stranded
#      PR costs a click, a surviving arm merges an unchecked revision);
#   3. every disarm is refused ⇒ three attempts each, exit 1 with ::error::;
#   4. no automerge_pat reached the workflow ⇒ exit 1 after the bot's three;
#   5. the verification read fails once ⇒ UNKNOWN is retried, not taken for
#      OFF; failing every time ⇒ exit 1, though the first disarm took;
#   6. the head moved before the step ⇒ stands down with no disarm;
#   7. the head moves during the retries ⇒ the check before the next attempt
#      stands down, before a bot retry and before the PAT's first attempt;
#   8. controls: an armed PR whose first disarm works ⇒ one attempt, no hold;
#      an unarmed PR ⇒ green, nothing disarmed, no hold;
#   9. negative controls: the block before this fix keeps the arm on case 1,
#      and mutants without the bot's retries, without the fallback, reading
#      UNKNOWN as OFF or checking the head only once each break their case.
#
# Run from the repo root:
#   bash selftest/test_automerge_error_revoke_retry.sh
set -euo pipefail

CA=.github/workflows/claude-author-automerge.yml
STEP="Revoke auto-merge if gates errored"
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
# 0. Extraction and wiring.
# ---------------------------------------------------------------------------
extract_run "$CA" "$STEP" > "$T/revoke.sh"
extract_run "$CA" "Check manual hold" > "$T/hold.sh"
if ! grep -q -- '--disable-auto' "$T/revoke.sh"; then
  echo "✗ could not extract '$STEP' (no --disable-auto in the extracted block)"
  exit 1
fi
if ! grep -q 'auto_merge_disabled' "$T/hold.sh"; then
  echo "✗ could not extract 'Check manual hold' (no auto_merge_disabled in the extracted block)"
  exit 1
fi
pass "extracted the error revoke and the manual-hold step"

header=$(step_header "$CA" "$STEP")
if grep -qxF '          GH_TOKEN: ${{ github.token }}' <<< "$header" \
  && grep -qxF '          FALLBACK_TOKEN: ${{ secrets.automerge_pat }}' <<< "$header"; then
  pass "0: the revoke runs as github-actions[bot] (github.token), with automerge_pat as its fallback"
else
  fail "0: the revoke must run under github.token, with FALLBACK_TOKEN mapped to secrets.automerge_pat"
fi

# ---------------------------------------------------------------------------
# The stub. One PR's state lives in $STUB_DIR: `arm` (ON|OFF), `head`, and
# `timeline.json`, where each change of the arm lands under the actor of the
# token that made it: ghs_stub is github.token (github-actions[bot]),
# pat_stub the caller's automerge_pat (pat-user). Faults, as files:
#   disable_fails      a count: the next N --disable-auto calls fail (a 502)
#   refuse_bot / refuse_pat  GitHub refuses that token's --disable-auto
#   view_fails         a count: the next N `gh pr view` calls fail, with
#                      nothing on stdout (gh pr view's error shape, measured)
#   move_head_on_disable  a count: the Nth --disable-auto fails as a push
#                      lands, and that push's own run arms the new head
# Every --disable-auto is logged with its actor in disables.log, and every
# one that turned an arm off in disarmed_by.log.
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
out() { if [ -n "$filter" ]; then jq -r "$filter"; else cat; fi; }
case "${GH_TOKEN:-}" in
  ghs_stub) actor="github-actions[bot]" kind=bot ;;
  pat_stub) actor="pat-user" kind=pat ;;
  *) echo "gh-stub: GH_TOKEN is neither github.token nor the PAT: '${GH_TOKEN:-}'" >&2; exit 4 ;;
esac
take() { # a fault count → 0 (one fewer left) while any are left, else 1
  local n
  n=$(cat "$d/$1" 2>/dev/null || echo 0)
  [ "$n" -gt 0 ] || return 1
  echo $((n - 1)) > "$d/$1"
}
record() { # an auto-merge event on the PR's timeline, as this token's actor
  local n
  n=$(( $(cat "$d/clock") + 1 ))
  echo "$n" > "$d/clock"
  jq --arg event "$1" --arg login "$actor" \
    --arg at "$(printf '2026-11-25T10:%02d:%02dZ' $((n / 60)) $((n % 60)))" \
    '. + [{event: $event, created_at: $at, actor: {login: $login}}]' \
    "$d/timeline.json" > "$d/timeline.next" && mv "$d/timeline.next" "$d/timeline.json"
}
case "${1:-} ${2:-}" in
  "pr view")
    if take view_fails; then
      echo "GraphQL: Something went wrong while executing your query (HTTP 502)" >&2
      exit 1
    fi
    if [ "$(cat "$d/arm")" = ON ]; then
      echo '{"autoMergeRequest":{"enabledBy":{"login":"pat-user","is_bot":false}}}'
    else
      echo '{"autoMergeRequest":null}'
    fi | out
    exit ;;
  "pr merge")
    case " $* " in
      *" --disable-auto "*)
        echo "$actor" >> "$d/disables.log"
        n=$(wc -l < "$d/disables.log" | tr -d ' ')
        if [ "$n" = "$(cat "$d/move_head_on_disable" 2>/dev/null)" ]; then
          echo "$STUB_NEW_HEAD" > "$d/head"
          echo ON > "$d/arm"
          echo "GraphQL: Something went wrong while executing your query. (disablePullRequestAutoMerge)" >&2
          exit 1
        fi
        if take disable_fails; then
          echo "GraphQL: Something went wrong while executing your query. (disablePullRequestAutoMerge)" >&2
          exit 1
        fi
        if [ -e "$d/refuse_$kind" ]; then
          echo "GraphQL: Resource not accessible by integration (disablePullRequestAutoMerge)" >&2
          exit 1
        fi
        if [ "$(cat "$d/arm")" != ON ]; then
          # Nothing armed: gh prints nothing and GitHub records no event.
          # Measured 2026-11-25 on whois-api-llc/wxa-graph#845: its
          # classifier revoke ran --disable-auto twice on the never-armed PR
          # (runs 44286865985, 44287859932; no output in either log) and its
          # timeline holds no auto-merge event, while the same timeline
          # query lists them on PRs that were armed (#870, #878).
          exit 0
        fi
        echo OFF > "$d/arm"
        record auto_merge_disabled
        echo "$actor" >> "$d/disarmed_by.log"
        exit 0 ;;
    esac ;;
esac
if [ "${1:-}" = "api" ]; then
  url=""
  for a in "$@"; do
    case "$a" in repos/* | /repos/*) url="${a#/}"; break ;; esac
  done
  case "${url%%\?*}" in
    repos/stub/repo/pulls/42)
      jq -n --arg h "$(cat "$d/head")" '{head: {sha: $h}}' | out
      exit ;;
    repos/stub/repo/issues/42/labels)
      echo '[]' | out
      exit ;;
    repos/stub/repo/issues/42/timeline)
      out < "$d/timeline.json"
      exit ;;
  esac
fi
echo "gh-stub: unexpected call: gh $*" >&2
exit 64
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/sleep"
chmod +x "$T/bin/gh" "$T/bin/sleep"

BOT=ghs_stub
PAT=pat_stub
B="github-actions[bot]"
P="pat-user"
EVENT_HEAD=$(printf 'c0ffee%034d' 1)
NEW_HEAD=$(printf 'c0ffee%034d' 2)
S="$T/state"

# run_revoke <script> [fault ...] → $T/out, ending in rc=<n>. The PR starts
# armed through the PAT by an earlier run, on the event's head. Faults:
#   disable_fails=<n> view_fails=<n> move_head_on_disable=<n>  (see the stub)
#   refuse=bot|pat|all   GitHub refuses that token's disarm, every time
#   head=<sha>           the live head, when a push landed before the step
#   no_pat               no automerge_pat reached the workflow
#   unarmed              nothing armed the PR
run_revoke() {
  local script="$1" fallback="$PAT" f rc=0
  shift
  rm -rf "$S"
  mkdir -p "$S"
  echo ON > "$S/arm"
  echo "$EVENT_HEAD" > "$S/head"
  echo 1 > "$S/clock"
  echo '[{"event":"auto_squash_enabled","created_at":"2026-11-25T10:00:01Z","actor":{"login":"pat-user"}}]' > "$S/timeline.json"
  : > "$S/gh.log"
  : > "$S/disables.log"
  : > "$S/disarmed_by.log"
  for f in "$@"; do
    case "$f" in
      disable_fails=* | view_fails=* | move_head_on_disable=*) echo "${f#*=}" > "$S/${f%%=*}" ;;
      refuse=bot) : > "$S/refuse_bot" ;;
      refuse=all) : > "$S/refuse_bot" && : > "$S/refuse_pat" ;;
      head=*) echo "${f#*=}" > "$S/head" ;;
      no_pat) fallback="" ;;
      unarmed) echo OFF > "$S/arm" && echo '[]' > "$S/timeline.json" ;;
      *) echo "run_revoke: unknown fault '$f'" >&2 && exit 2 ;;
    esac
  done
  (
    export PATH="$T/bin:$PATH" STUB_DIR="$S" STUB_NEW_HEAD="$NEW_HEAD" \
      GITHUB_REPOSITORY="stub/repo" GH_TOKEN="$BOT" FALLBACK_TOKEN="$fallback" \
      PR=42 PR_URL="https://github.com/stub/repo/pull/42" HEAD_SHA="$EVENT_HEAD"
    bash "$script"
  ) > "$T/out" 2>&1 < /dev/null || rc=$?
  echo "rc=$rc" >> "$T/out"
}

# The SHIPPED manual-hold step on the same PR, as the next run reads it
# → "hold=<0|1> reason=<reason>".
hold_after() {
  : > "$S/hold_output"
  if ! (
    export PATH="$T/bin:$PATH" STUB_DIR="$S" GITHUB_REPOSITORY="stub/repo" \
      GH_TOKEN="$BOT" PR=42 HOLD_LABEL=manual-merge GITHUB_OUTPUT="$S/hold_output"
    bash "$T/hold.sh"
  ) > "$T/hold_log" 2>&1 < /dev/null; then
    echo "hold step failed: $(tr '\n' ' ' < "$T/hold_log")"
    return 0
  fi
  paste -sd ' ' "$S/hold_output"
}

has() { grep -qF -- "$1" "$T/out"; }
arm_is() { [ "$(cat "$S/arm")" = "$1" ]; }
attempts() { paste -sd , "$S/disables.log"; }
disarmed_by() { paste -sd , "$S/disarmed_by.log"; }
dump() {
  echo "    attempts: [$(attempts)] disarmed by: [$(disarmed_by)] arm: $(cat "$S/arm")"
  sed 's/^/    out: /' "$T/out"
  sed 's/^/    gh:  /' "$S/gh.log"
}
NO_HOLD="hold=0 reason="
HUMAN_HOLD="hold=1 reason=timeline:human-disable-newest"

# ---------------------------------------------------------------------------
# 1. A transient failure is retried as the bot.
# ---------------------------------------------------------------------------
run_revoke "$T/revoke.sh" disable_fails=1
if arm_is OFF && has "rc=0" && [ "$(attempts)" = "$B,$B" ] && [ "$(disarmed_by)" = "$B" ]; then
  pass "1: the first disarm fails (a 502) ⇒ the bot's second attempt takes it, no PAT"
else
  fail "1: one transient failure must be retried as the bot, not leave the arm or reach the PAT"
  dump
fi
hold=$(hold_after)
if [ "$hold" = "$NO_HOLD" ]; then
  pass "1: the next run reads no hold, so the PR re-arms once its gates pass"
else
  fail "1: a retried disarm left a hold ($hold): the PR would never re-arm on its own"
fi

# ---------------------------------------------------------------------------
# 2. A bot that cannot disarm falls back to the PAT, at the cost of a hold.
# ---------------------------------------------------------------------------
run_revoke "$T/revoke.sh" refuse=bot
if arm_is OFF && has "rc=0" && [ "$(attempts)" = "$B,$B,$B,$P" ] && [ "$(disarmed_by)" = "$P" ] \
  && has "::warning::" && has "human's hold"; then
  pass "2: the bot is refused three times ⇒ the PAT disarms, with a warning naming the hold it leaves"
else
  fail "2: after three refused bot attempts the PAT must disarm, and the warning must say what that costs"
  dump
fi
hold=$(hold_after)
if [ "$hold" = "$HUMAN_HOLD" ]; then
  pass "2: the next run reads the PAT's disarm as a human's hold (the accepted cost: a human re-arms)"
else
  fail "2: expected the PAT's disarm to read as a human's hold, got: $hold"
fi

# ---------------------------------------------------------------------------
# 3–4. Nothing can disarm: fail loudly.
# ---------------------------------------------------------------------------
run_revoke "$T/revoke.sh" refuse=all
if arm_is ON && has "rc=1" && has "::error::" && [ "$(attempts)" = "$B,$B,$B,$P,$P,$P" ]; then
  pass "3: every disarm is refused ⇒ three attempts per token, then exit 1 with an ::error::"
else
  fail "3: a revoke that cannot verify OFF must fail the step after every attempt"
  dump
fi

run_revoke "$T/revoke.sh" refuse=bot no_pat
if arm_is ON && has "rc=1" && has "::error::" && [ "$(attempts)" = "$B,$B,$B" ]; then
  pass "4: no automerge_pat reached the workflow ⇒ exit 1 after the bot's three attempts"
else
  fail "4: without a fallback token the step must fail after the bot's attempts"
  dump
fi

# ---------------------------------------------------------------------------
# 5. UNKNOWN is not OFF.
# ---------------------------------------------------------------------------
run_revoke "$T/revoke.sh" view_fails=1
if arm_is OFF && has "rc=0" && [ "$(attempts)" = "$B,$B" ] && [ "$(disarmed_by)" = "$B" ]; then
  pass "5: the verification read fails once ⇒ retried and verified, not taken for OFF"
else
  fail "5: an unreadable arm state must be retried (UNKNOWN is not OFF), not abort the step"
  dump
fi

run_revoke "$T/revoke.sh" view_fails=99
if has "rc=1" && has "::error::" && [ "$(attempts)" = "$B,$B,$B,$P,$P,$P" ]; then
  pass "5: the arm state is never readable ⇒ exit 1, though the first disarm took (only a read of OFF counts)"
else
  fail "5: a revoke that never reads OFF must fail the step"
  dump
fi
hold=$(hold_after)
if [ "$hold" = "$NO_HOLD" ]; then
  pass "5: the PAT's attempts on an arm already gone record nothing, so no hold"
else
  fail "5: the PAT's attempts on a disarmed PR left a hold ($hold)"
fi

# ---------------------------------------------------------------------------
# 6–7. Ownership: a newer head's run owns the arm.
# ---------------------------------------------------------------------------
run_revoke "$T/revoke.sh" head="$NEW_HEAD"
if arm_is ON && has "rc=0" && has "head moved" && [ "$(attempts)" = "" ]; then
  pass "6: the head moved before the step ⇒ stands down with no disarm"
else
  fail "6: a moved head must leave the arm to the newer head's run"
  dump
fi

run_revoke "$T/revoke.sh" move_head_on_disable=1
if arm_is ON && has "rc=0" && has "head moved" && [ "$(attempts)" = "$B" ]; then
  pass "7: the head moves during the first attempt ⇒ the bot's retry stands down"
else
  fail "7: a head pushed (and armed) mid-revoke was disarmed by a retry"
  dump
fi

run_revoke "$T/revoke.sh" refuse=bot move_head_on_disable=3
if arm_is ON && has "rc=0" && has "head moved" && [ "$(attempts)" = "$B,$B,$B" ]; then
  pass "7: the head moves during the bot's last attempt ⇒ the PAT never runs"
else
  fail "7: the PAT fallback disarmed a head pushed (and armed) mid-revoke"
  dump
fi

# ---------------------------------------------------------------------------
# 8. Controls.
# ---------------------------------------------------------------------------
run_revoke "$T/revoke.sh"
if arm_is OFF && has "rc=0" && [ "$(attempts)" = "$B" ] && [ "$(disarmed_by)" = "$B" ]; then
  pass "8: control: the first disarm works ⇒ one attempt, as the bot"
else
  fail "8: control: a working disarm must take one attempt"
  dump
fi
hold=$(hold_after)
if [ "$hold" = "$NO_HOLD" ]; then
  pass "8: control: no hold after the bot's disarm"
else
  fail "8: control: the bot's disarm read as a hold ($hold)"
fi

run_revoke "$T/revoke.sh" unarmed
if arm_is OFF && has "rc=0" && [ "$(attempts)" = "$B" ] && [ "$(disarmed_by)" = "" ]; then
  pass "8: control: an unarmed PR ⇒ green, nothing disarmed"
else
  fail "8: control: an unarmed PR must pass the idempotent revoke"
  dump
fi

# ---------------------------------------------------------------------------
# 9. Negative controls. First the block as it was before this fix.
# ---------------------------------------------------------------------------
cat > "$T/before.sh" <<'BEFORE'
set -euo pipefail
now=$(gh api "repos/${GITHUB_REPOSITORY}/pulls/${PR}" --jq .head.sha 2>/dev/null) || now=""
if [[ "$now" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] && [ "$now" != "$HEAD_SHA" ]; then
  echo "::notice::head moved (${HEAD_SHA} → ${now}) since this event — the newer head's run owns gating; skipping stale revoke."
  exit 0
fi
echo "A gating step errored — revoking any existing auto-merge arm (fail closed for already-armed PRs)."
gh pr merge --disable-auto "$PR_URL" 2>&1 || true
state=$(gh pr view "$PR_URL" --json autoMergeRequest \
  --jq 'if .autoMergeRequest == null then "OFF" else "ON" end')
echo "Auto-merge state after error revoke: $state"
if [ "$state" = "ON" ]; then
  echo "::error::auto-merge still ON after --disable-auto — investigate"
  exit 1
fi
BEFORE
run_revoke "$T/before.sh" disable_fails=1
if arm_is ON && [ "$(attempts)" = "$B" ]; then
  pass "9: negative control: the block before this fix keeps the arm on case 1 (the harness sees the bug)"
else
  fail "9: negative control: the old single attempt disarmed; case 1 no longer tests anything"
  dump
fi

# mutant <name> <old> <new> [<old> <new> ...] → $T/<name>.sh: the shipped
# block with each <old> (which must appear exactly once) replaced by <new>.
mutant() {
  python3 - "$T/revoke.sh" "$T/$1.sh" "${@:2}" <<'PY'
import sys
src, dst, pairs = sys.argv[1], sys.argv[2], sys.argv[3:]
text = open(src).read()
for old, new in zip(pairs[::2], pairs[1::2]):
    if text.count(old) != 1:
        sys.exit(f"cannot plant the mutant: {old!r} appears {text.count(old)} times")
    text = text.replace(old, new)
open(dst, "w").write(text)
PY
}

if mutant one_bot_attempt 'for attempt in 1 2 3; do' 'for attempt in 1; do'; then
  run_revoke "$T/one_bot_attempt.sh" disable_fails=1
  if [ "$(disarmed_by)" = "$P" ] && [ "$(hold_after)" = "$HUMAN_HOLD" ]; then
    pass "9: negative control: one attempt per token sends case 1's 502 to the PAT, and a hold (case 1 sees it)"
  else
    fail "9: negative control: the one-attempt mutant went unnoticed by case 1"
    dump
  fi
else
  fail "9: negative control: the revoke no longer carries the bot's three attempts to plant over"
fi

if mutant no_fallback 'disarm "github-actions[bot]" && [ -n "${FALLBACK_TOKEN:-}" ]' 'disarm "github-actions[bot]" && false'; then
  run_revoke "$T/no_fallback.sh" refuse=bot
  if arm_is ON && has "rc=1"; then
    pass "9: negative control: without the fallback, case 2's arm survives (case 2 sees it)"
  else
    fail "9: negative control: the no-fallback mutant went unnoticed by case 2"
    dump
  fi
else
  fail "9: negative control: the revoke no longer carries the PAT fallback to plant over"
fi

if mutant on_only \
  '[ "$state" = "OFF" ] && return 0' '[ "$state" != "ON" ] && return 0' \
  'if [ "$state" != "OFF" ]; then' 'if [ "$state" = "ON" ]; then'; then
  run_revoke "$T/on_only.sh" view_fails=99
  if has "rc=0"; then
    pass "9: negative control: rejecting only ON passes a never-verified revoke (case 5 sees it)"
  else
    fail "9: negative control: the ON-only mutant went unnoticed by case 5"
    dump
  fi
else
  fail "9: negative control: the revoke no longer carries the OFF-only checks to plant over"
fi

check_in_loop=$'    if head_moved; then\n      exit 0\n    fi\n'
if mutant head_checked_once \
  $'for attempt in 1 2 3; do\n'"$check_in_loop" $'for attempt in 1 2 3; do\n' \
  $'disarm() {\n' $'disarm() {\n'"$check_in_loop"; then
  run_revoke "$T/head_checked_once.sh" move_head_on_disable=1
  if arm_is OFF; then
    pass "9: negative control: a head checked only before the first attempt lets a retry disarm the newer head (case 7 sees it)"
  else
    fail "9: negative control: the check-once mutant went unnoticed by case 7"
    dump
  fi
else
  fail "9: negative control: the revoke no longer checks the head inside its attempt loop"
fi

echo ""
if [ "$failed" -ne 0 ]; then
  echo "FAIL: the error revoke can leave a standing arm, or disarm as the wrong identity."
  exit 1
fi
echo "PASS: the error revoke retries as the bot, falls back to the PAT, and stands down on a moved head."
