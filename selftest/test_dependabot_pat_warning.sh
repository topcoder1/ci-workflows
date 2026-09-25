#!/usr/bin/env bash
# Behavioral test for the attribution WARNING in dependabot-auto-merge.yml's
# arm step ("Auto-merge patch (and optionally minor) bumps").
#
# Incident (2026-09-25): whois-api-llc/wxa_vpn's deploy.yml skipped all 42
# Dependabot bumps merged 2026-07-23..09-25 (wxa_vpn#2031). Its caller passed
# `secrets: inherit`, which delivers nothing to this reusable across
# accounts, and a run Dependabot triggers reads ONLY the repo's Dependabot
# secret store, so no PAT could have arrived either way. The arm ran on
# GITHUB_TOKEN, GitHub attributed the merge to github-actions[bot], and ran
# no push workflow for it. Nothing said so: automerge_pat is optional and the
# fallback was silent. A 2026-09-25 sweep found AUTOMERGE_PAT in the
# Dependabot store of 2 of the 46 caller repos.
#
# Unlike claude-author/safe-paths (ci-workflows#217), this step still ARMS
# without a user PAT: Dependabot deletes its own branch, so #217's
# stranded-branch hazard does not apply, and refusing would stop auto-merge
# in every caller not yet provisioned. It warns instead, so the fallback is
# never silent.
#
# The arm step is EXTRACTED from the workflow YAML (the shipped bash) and run
# against a stubbed `gh` whose `api user` answer is computed by running the
# SHIPPED --jq filter over gh-shaped JSON:
#   1. no PAT ⇒ ::warning:: naming the Dependabot-store fix, NO /user probe,
#      still arms exactly once, head-bound, exit 0.
#   2. PAT that is a user ⇒ arms, no warning.
#   3. PAT whose /user read fails 3× (an App installation token's 403) ⇒
#      warning after exactly 3 attempts, still arms.
#   4. PAT whose /user answer is not a User ⇒ warning after 1 attempt, arms.
#   5. /user fails twice, then answers ⇒ no warning (the retry recovers).
#   6. the arm itself fails ⇒ the step fails; a warning never masks it.
#   negative control: the step with its warn calls neutralized ⇒ case 1 sees
#   no warning, so the harness can fail.
# Structural pins (hardcoded, not derived from the file under test):
#   * the run block is `${{ }}`-free — Actions evaluates expressions in a run
#     block before bash starts, so even a message quoting
#     `${{ secrets.AUTOMERGE_PAT }}` would inject the secret into the script;
#   * exactly ONE non-comment `gh pr merge --auto` in the workflow, still
#     bound with --match-head-commit;
#   * USING_PAT derives from secrets.automerge_pat, and GH_TOKEN keeps its
#     GITHUB_TOKEN fallback (the no-PAT arm runs on it);
#   * automerge_pat stays `required: false` — a required secret would fail
#     every unprovisioned caller at startup, revoke-stale-arm included.
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
  pass "exactly one arm command in $WF, bound with --match-head-commit"
else
  fail "$WF has $n arm command(s), or the arm lost --match-head-commit"
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

# ---------------------------------------------------------------------------
# Behavior.
# ---------------------------------------------------------------------------
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_LOG"
jq_filter() { while [ $# -gt 0 ]; do [ "$1" = "--jq" ] && { printf '%s' "$2"; return; }; shift; done; }
if [ "$1" = "api" ] && [ "$2" = "user" ]; then
  n=$(cat "$USER_CALLS" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$USER_CALLS"
  [ "$n" -le "${STUB_USER_FAIL_TIMES:-0}" ] && { echo "gh: Resource not accessible by integration (HTTP 403)" >&2; exit 1; }
  printf '{"login":"topcoder1","type":"%s"}\n' "${STUB_USER_TYPE:-User}" | jq -r "$(jq_filter "$@")"
  exit $?
fi
if [ "$1 $2" = "pr merge" ]; then
  [ "${STUB_ARM_FAIL:-0}" = "1" ] && { echo "arm failed" >&2; exit 1; }
  exit 0
fi
exit 1
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/sleep"
chmod +x "$T/bin/gh" "$T/bin/sleep"

run_case() { # script, then env assignments
  local script="$1"; shift
  : > "$T/gh.log"; rm -f "$T/user_calls"; : > "$T/summary"
  rc=0
  env "$@" PATH="$T/bin:$PATH" GH_LOG="$T/gh.log" USER_CALLS="$T/user_calls" \
    GITHUB_STEP_SUMMARY="$T/summary" GITHUB_REPOSITORY=whois-api-llc/wxa_vpn \
    PR_URL=https://github.com/whois-api-llc/wxa_vpn/pull/9 HEAD_SHA=abc123 METHOD=squash \
    bash "$script" > "$T/out" 2>&1 || rc=$?
}
arms() { grep -c '^gh pr merge --auto --squash --match-head-commit abc123 https://github.com/whois-api-llc/wxa_vpn/pull/9$' "$T/gh.log" || true; }
user_calls() { grep -c '^gh api user' "$T/gh.log" || true; }
warned() { grep -q '^::warning' "$T/out"; }

# 1. no PAT
run_case "$T/arm.sh" USING_PAT=0
if [ "$rc" = 0 ] && [ "$(arms)" = 1 ] && [ "$(user_calls)" = 0 ] && warned \
  && grep -q 'gh secret set AUTOMERGE_PAT --app dependabot --repo whois-api-llc/wxa_vpn' "$T/out" \
  && grep -q 'push workflows' "$T/summary"; then
  pass "1. no PAT: warns with the Dependabot-store fix (annotation + summary), no /user probe, arms once"
else
  fail "1. no PAT: rc=$rc arms=$(arms) user_calls=$(user_calls)"; sed 's/^/    /' "$T/out"
fi

# 2. a user PAT
run_case "$T/arm.sh" USING_PAT=1 STUB_USER_TYPE=User
if [ "$rc" = 0 ] && [ "$(arms)" = 1 ] && [ "$(user_calls)" = 1 ] && ! warned; then
  pass "2. user PAT: arms, no warning"
else
  fail "2. user PAT: rc=$rc arms=$(arms) user_calls=$(user_calls)"; sed 's/^/    /' "$T/out"
fi

# 3. /user fails every time (an App installation token's 403)
run_case "$T/arm.sh" USING_PAT=1 STUB_USER_FAIL_TIMES=9
if [ "$rc" = 0 ] && [ "$(arms)" = 1 ] && [ "$(user_calls)" = 3 ] && warned; then
  pass "3. /user fails 3×: warns after exactly 3 attempts, still arms"
else
  fail "3. /user fails: rc=$rc arms=$(arms) user_calls=$(user_calls)"; sed 's/^/    /' "$T/out"
fi

# 4. /user answers, but not a User
run_case "$T/arm.sh" USING_PAT=1 STUB_USER_TYPE=Bot
if [ "$rc" = 0 ] && [ "$(arms)" = 1 ] && [ "$(user_calls)" = 1 ] && warned; then
  pass "4. non-User credential: warns after 1 attempt, still arms"
else
  fail "4. non-User credential: rc=$rc arms=$(arms) user_calls=$(user_calls)"; sed 's/^/    /' "$T/out"
fi

# 5. the retry recovers
run_case "$T/arm.sh" USING_PAT=1 STUB_USER_FAIL_TIMES=2
if [ "$rc" = 0 ] && [ "$(arms)" = 1 ] && [ "$(user_calls)" = 3 ] && ! warned; then
  pass "5. /user fails twice then answers: no warning"
else
  fail "5. retry: rc=$rc arms=$(arms) user_calls=$(user_calls)"; sed 's/^/    /' "$T/out"
fi

# 6. the arm fails
run_case "$T/arm.sh" USING_PAT=0 STUB_ARM_FAIL=1
if [ "$rc" != 0 ]; then
  pass "6. a failed arm fails the step (the warning does not mask it)"
else
  fail "6. the arm failed but the step exited 0"; sed 's/^/    /' "$T/out"
fi

# Negative control: neutralize every warn call — case 1 must now see none.
sed -E 's/^([[:space:]]*)warn /\1: warn /' "$T/arm.sh" > "$T/arm_nowarn.sh"
if cmp -s "$T/arm.sh" "$T/arm_nowarn.sh"; then
  fail "control: found no warn call to neutralize"
else
  run_case "$T/arm_nowarn.sh" USING_PAT=0
  if ! warned; then
    pass "control: with the warn calls neutralized, case 1 sees no warning (the harness can fail)"
  else
    fail "control: a warning appeared with every warn call neutralized"
  fi
fi

exit "$failed"
