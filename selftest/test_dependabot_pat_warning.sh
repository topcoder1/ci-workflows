#!/usr/bin/env bash
# Behavioral test for the attribution handling in dependabot-auto-merge.yml's
# arm step ("Auto-merge patch (and optionally minor) bumps").
#
# Incident (2026-09-25): whois-api-llc/wxa_vpn's deploy.yml skipped all 42
# Dependabot bumps merged 2026-07-23..09-25 (wxa_vpn#2031). Its caller passed
# `secrets: inherit`, which delivers nothing to this reusable across
# accounts. It also triggered on `pull_request`, and a run Dependabot
# triggers there reads ONLY the repo's Dependabot secret store, so no PAT
# could have arrived either way. The arm ran on GITHUB_TOKEN, GitHub
# attributed the merge to github-actions[bot], and ran no push workflow for
# it. Nothing said so: automerge_pat is optional and the fallback was silent.
#
# The fix the warning names is the caller's (topcoder1/dotclaude#411):
# trigger on pull_request_target, so the run reads the Actions store, and
# map automerge_pat explicitly. It must NEVER suggest the Dependabot store.
# Every Dependabot-triggered job that references a copy there holds it in
# runner memory while running the bumped dependency code (16 repos'
# coverage-floor callers, 2026-09-26).
#
# Unlike claude-author/safe-paths (ci-workflows#217), this step still ARMS
# without a user PAT: Dependabot deletes its own branch, so #217's
# stranded-branch hazard does not apply, and refusing would stop auto-merge
# in every caller not yet moved to pull_request_target. It warns instead, so
# the fallback is never silent. There is no GET /user probe (Codex round 2):
# only a GITHUB_TOKEN-attributed merge is denied push workflows.
#
# A PAT arm counts only if it is the FIRST one: re-arming keeps the original
# enabler (measured, #217). safe-paths-automerge runs on `pull_request`,
# reads the empty Dependabot store, and arms docs/tests-only Dependabot PRs
# with GITHUB_TOKEN 2-44 s before this job (wxa-mcp-server#436 and 6 more,
# found by the independent review of dotclaude#411). So with a PAT, the step
# reads the enabler back and replaces a bot's arm with the PAT user's.
#
# The arm step is EXTRACTED from the workflow YAML (the shipped bash) and run
# against a stubbed `gh` that models the PR's arm state (none/bot/user;
# re-arming keeps the original enabler) and answers `pr view` by running the
# SHIPPED --jq filter over gh-shaped JSON:
#   1. no PAT ⇒ ::warning:: (plus a step-summary line) naming the
#      pull_request_target fix and never the Dependabot store; still arms
#      exactly once, head-bound, exit 0.
#   2. a PAT, nothing armed before ⇒ one arm, as the user, no disarm, no
#      warning, no `gh api user` call.
#   3. the arm itself fails ⇒ the step fails; a warning never masks it.
#   4. a PAT, a BOT armed first ⇒ the bot's arm is removed and the PR re-armed
#      as the user (head-bound), no warning.
#   5. a PAT, a bot's arm that will not come off ⇒ 3 disarm attempts, no
#      re-arm, a warning that the merge stays bot-attributed, exit 0.
#   6. a PAT, a USER armed first ⇒ never disarmed, no warning.
#   negative controls, each proving a case above can fail:
#     the ::warning:: echoes neutralized ⇒ case 1 sees no warning;
#     the bot-arm replacement neutralized ⇒ case 4 ends bot-armed;
#     the enabler jq path misspelled (`.enabled_by.is_bot`) ⇒ case 4 ends
#     bot-armed (the stub runs the shipped filter, so a typo is caught).
# Structural pins (hardcoded, not derived from the file under test):
#   * the run block is `${{ }}`-free — Actions evaluates expressions in a run
#     block before bash starts, so even a message quoting
#     `${{ secrets.AUTOMERGE_PAT }}` would inject the secret into the script;
#   * exactly ONE non-comment `gh pr merge --auto` in the workflow, still
#     bound with --match-head-commit (both arms go through it);
#   * USING_PAT derives from secrets.automerge_pat, and GH_TOKEN keeps its
#     GITHUB_TOKEN fallback (the no-PAT arm runs on it);
#   * automerge_pat stays `required: false` — a required secret would fail
#     every unprovisioned caller at startup, revoke-stale-arm included;
#   * the only action the reusable uses is dependabot/fetch-metadata, pinned
#     by commit SHA, and nothing checks out the PR. Callers run this on
#     pull_request_target with the Actions secrets, which is safe only while
#     no PR code runs; a moved tag is how tj-actions/changed-files harvested
#     secrets from runner memory (CVE-2025-30066).
#
# Run from the repo root:
#   bash selftest/test_dependabot_pat_warning.sh
set -euo pipefail

WF=.github/workflows/dependabot-auto-merge.yml
STEP='Auto-merge patch (and optionally minor) bumps'
failed=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

pass() { echo "✓ $1"; }
fail() { echo "✗ $1"; failed=1; }

extract_run() { # workflow → the arm step's `run: |` block
  awk -v step="      - name: $STEP" '
    $0 == step { in_step=1; next }
    in_step && /^      - name: / { exit }
    in_step && /^        run: \|/ { in_run=1; next }
    in_run {
      if ($0 ~ /^          / || $0 == "") { sub(/^          /, ""); print }
      else { exit }
    }
  ' "$1"
}
step_block() { # workflow → the arm step, from its name to the next step or job
  awk -v step="      - name: $STEP" '
    $0 == step { f=1; print; next }
    f && (/^      - name: / || /^  [a-z]/) { exit }
    f
  ' "$1"
}

extract_run "$WF" > "$T/arm.sh"
if ! grep -q 'gh pr merge --auto' "$T/arm.sh" || ! grep -q 'USING_PAT' "$T/arm.sh"; then
  echo "✗ could not extract the arm step — no multi-line run block with the arm command and USING_PAT"
  exit 1
fi
pass "extracted the arm step ($(wc -l < "$T/arm.sh" | tr -d ' ') lines)"

# ---------------------------------------------------------------------------
# Structural pins.
# ---------------------------------------------------------------------------
if grep -qF '${{' "$T/arm.sh"; then
  fail "the arm step's run block contains \${{ — Actions would interpolate it before bash runs"
else
  pass "the arm step's run block is \${{ }}-free"
fi

n=$(awk '!/^[[:space:]]*#/ && /gh pr merge --auto/' "$WF" | wc -l | tr -d ' ')
if [ "$n" = "1" ] && grep -qF -- '--match-head-commit "$HEAD_SHA"' "$T/arm.sh"; then
  pass "exactly one arm call site in $WF, bound with --match-head-commit"
else
  fail "$WF has $n arm call site(s), or the arm lost --match-head-commit"
fi

block=$(step_block "$WF")
if grep -qF "USING_PAT: \${{ secrets.automerge_pat != '' && '1' || '0' }}" <<<"$block" \
  && grep -qF 'GH_TOKEN: ${{ secrets.automerge_pat || secrets.GITHUB_TOKEN }}' <<<"$block"; then
  pass "USING_PAT derives from secrets.automerge_pat; GH_TOKEN keeps its GITHUB_TOKEN fallback"
else
  fail "the arm step's USING_PAT / GH_TOKEN wiring changed"
fi

if awk '/^    secrets:/{s=1} s && /^      automerge_pat:/{a=1} a && /^        required:/{found=($2 == "false"); exit} END{exit !found}' "$WF"; then
  pass "automerge_pat stays required: false"
else
  fail "automerge_pat is no longer required: false — unprovisioned callers would fail at startup"
fi

uses=$(awk '!/^[[:space:]]*#/ && /^[[:space:]]+(- )?uses:/ { sub(/^[[:space:]]+(- )?uses:[[:space:]]*/, ""); sub(/[[:space:]]+#.*/, ""); print }' "$WF")
if grep -Eqx 'dependabot/fetch-metadata@[0-9a-f]{40}' <<<"$uses"; then
  pass "the only action is dependabot/fetch-metadata, pinned by commit SHA (nothing checks out PR code)"
else
  fail "the reusable uses an action other than a SHA-pinned fetch-metadata: $(printf '%s' "$uses" | tr '\n' ' ')"
fi

# ---------------------------------------------------------------------------
# Behavior.
# ---------------------------------------------------------------------------
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_LOG"
arm_state() { cat "$ARM_STATE" 2>/dev/null || echo none; }
jq_filter() { while [ $# -gt 0 ]; do [ "$1" = "--jq" ] && { printf '%s' "$2"; return; }; shift; done; }
if [ "$1" = "api" ] && [ "$2" = "user" ]; then
  echo "gh: Resource not accessible by integration (HTTP 403)" >&2; exit 1
fi
case "$1 $2" in
  "pr merge")
    case " $* " in
      *" --disable-auto "*) [ "${STUB_DISARM_STUCK:-0}" = "1" ] || echo none > "$ARM_STATE" ;;
      *" --auto "*)
        [ "${STUB_ARM_FAIL:-0}" = "1" ] && { echo "arm failed" >&2; exit 1; }
        # Re-arming keeps the ORIGINAL enabler (measured, ci-workflows#217).
        if [ "$(arm_state)" = "none" ]; then
          if [ "${USING_PAT:-0}" = "1" ]; then echo user > "$ARM_STATE"; else echo bot > "$ARM_STATE"; fi
        fi ;;
    esac
    exit 0 ;;
  "pr view")
    case "$(arm_state)" in
      none) json='{"autoMergeRequest":null}' ;;
      bot)  json='{"autoMergeRequest":{"enabledBy":{"login":"app/github-actions","is_bot":true}}}' ;;
      user) json='{"autoMergeRequest":{"enabledBy":{"login":"topcoder1","is_bot":false}}}' ;;
    esac
    printf '%s\n' "$json" | jq -r "$(jq_filter "$@")"
    exit $? ;;
esac
exit 1
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/sleep"
chmod +x "$T/bin/gh" "$T/bin/sleep"

run_case() { # script, initial arm state, then env assignments
  local script="$1" initial="$2"; shift 2
  : > "$T/gh.log"; : > "$T/summary"; printf '%s\n' "$initial" > "$T/arm_state"
  rc=0
  env "$@" PATH="$T/bin:$PATH" GH_LOG="$T/gh.log" ARM_STATE="$T/arm_state" \
    GITHUB_STEP_SUMMARY="$T/summary" GITHUB_REPOSITORY=whois-api-llc/wxa_vpn \
    PR_URL=https://github.com/whois-api-llc/wxa_vpn/pull/9 HEAD_SHA=abc123 METHOD=squash \
    bash "$script" > "$T/out" 2>&1 || rc=$?
}
arms() { grep -c '^gh pr merge --auto --squash --match-head-commit abc123 https://github.com/whois-api-llc/wxa_vpn/pull/9$' "$T/gh.log" || true; }
disarms() { grep -c '^gh pr merge --disable-auto' "$T/gh.log" || true; }
user_calls() { grep -c '^gh api user' "$T/gh.log" || true; }
state() { cat "$T/arm_state"; }
warned() { grep -q '^::warning' "$T/out"; }
report() { fail "$1: rc=$rc arms=$(arms) disarms=$(disarms) user_calls=$(user_calls) state=$(state)"; sed 's/^/    /' "$T/out"; }

# 1. no PAT
run_case "$T/arm.sh" none USING_PAT=0
if [ "$rc" = 0 ] && [ "$(arms)" = 1 ] && [ "$(disarms)" = 0 ] && [ "$(user_calls)" = 0 ] && warned \
  && grep -q 'pull_request_target' "$T/out" && ! grep -q -- '--app dependabot' "$T/out" \
  && grep -q 'push workflows' "$T/summary"; then
  pass "1. no PAT: warns with the pull_request_target fix, never the Dependabot store (annotation + summary), arms once"
else
  report "1. no PAT"
fi

# 2. a PAT, nothing armed before
run_case "$T/arm.sh" none USING_PAT=1
if [ "$rc" = 0 ] && [ "$(arms)" = 1 ] && [ "$(disarms)" = 0 ] && [ "$(user_calls)" = 0 ] \
  && [ "$(state)" = user ] && ! warned; then
  pass "2. PAT, nothing armed before: one arm, as the user, no warning, no /user probe"
else
  report "2. PAT, nothing armed before"
fi

# 3. the arm fails
run_case "$T/arm.sh" none USING_PAT=0 STUB_ARM_FAIL=1
if [ "$rc" != 0 ]; then
  pass "3. a failed arm fails the step (the warning does not mask it)"
else
  report "3. the arm failed but the step exited 0"
fi

# 4. a PAT, a bot armed first (safe-paths-automerge's GITHUB_TOKEN arm)
run_case "$T/arm.sh" bot USING_PAT=1
if [ "$rc" = 0 ] && [ "$(disarms)" = 1 ] && [ "$(arms)" = 2 ] && [ "$(state)" = user ] && ! warned; then
  pass "4. PAT, a bot armed first: its arm is removed and the PR re-armed as the user"
else
  report "4. PAT, a bot armed first"
fi

# 5. a PAT, a bot's arm that will not come off
run_case "$T/arm.sh" bot USING_PAT=1 STUB_DISARM_STUCK=1
if [ "$rc" = 0 ] && [ "$(disarms)" = 3 ] && [ "$(arms)" = 1 ] && [ "$(state)" = bot ] && warned \
  && grep -q 'push workflows' "$T/summary"; then
  pass "5. PAT, a stuck bot arm: 3 disarm attempts, no blind re-arm, a warning, exit 0"
else
  report "5. PAT, a stuck bot arm"
fi

# 6. a PAT, a user armed first
run_case "$T/arm.sh" user USING_PAT=1
if [ "$rc" = 0 ] && [ "$(disarms)" = 0 ] && [ "$(state)" = user ] && ! warned; then
  pass "6. PAT, a user armed first: never disarmed, no warning"
else
  report "6. PAT, a user armed first"
fi

# Negative controls: each neutralizes one mechanism and reruns the case it
# protects, which must then fail.
neutralize() { # label, sed expression → $T/arm_ctl.sh
  sed -E "$2" "$T/arm.sh" > "$T/arm_ctl.sh"
  if cmp -s "$T/arm.sh" "$T/arm_ctl.sh"; then
    fail "control ($1): the sed matched nothing to neutralize"
    return 1
  fi
}
if neutralize "warning" 's/^([[:space:]]*)echo "::warning::/\1: echo "::warning::/'; then
  run_case "$T/arm_ctl.sh" none USING_PAT=0
  if ! warned; then pass "control: with the ::warning:: echoes neutralized, case 1 sees no warning"
  else fail "control: a warning appeared with every ::warning:: echo neutralized"; fi
fi
if neutralize "replacement" 's/= "bot" \]; then/= "never" ]; then/'; then
  run_case "$T/arm_ctl.sh" bot USING_PAT=1
  if [ "$(state)" = bot ]; then pass "control: with the bot-arm replacement neutralized, case 4 ends bot-armed"
  else fail "control: case 4 ended '$(state)' with the replacement neutralized"; fi
fi
if neutralize "jq path" 's/\.enabledBy\.is_bot/.enabled_by.is_bot/g'; then
  run_case "$T/arm_ctl.sh" bot USING_PAT=1
  if [ "$(state)" = bot ]; then pass "control: with the enabler jq path misspelled, case 4 ends bot-armed (the stub runs the shipped filter)"
  else fail "control: case 4 ended '$(state)' with the enabler jq path misspelled"; fi
fi

exit "$failed"
