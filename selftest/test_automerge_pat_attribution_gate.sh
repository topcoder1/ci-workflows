#!/usr/bin/env bash
# Behavioral test for the attribution gate in both auto-merge ARMING
# reusables: claude-author-automerge.yml (the `id: arm` step) and
# safe-paths-automerge.yml ("Enable auto-merge").
#
# Incident context (whois-api-llc/wxa-graph#553, 2026-09-16): the PR was
# auto-merged at 2:54 PM PT; a review report pushed to its head branch at
# 3:06 PM PT was accepted by git and never reached main, and an accepted
# ADR cited the missing evidence for two days (recovered in #597). (Its
# twin, wxa_vpn#1736, is NOT this bug: that user-merged branch WAS deleted
# at merge and the later push re-created it.) The branch was still there
# to push to because GitHub runs the repo's "Automatically delete head
# branches" only for a USER-attributed merge. wxa-graph's callers used
# `secrets: inherit` across accounts, which delivers nothing, so the arm
# ran on the GITHUB_TOKEN fallback (the run log shows `USING_PAT: 0`) and
# GitHub performed the merge as github-actions[bot].
#
# Measured 2026-09-18 over the 44 caller repos, merges since 2026-05-03
# (when delete_branch_on_merge was on fleet-wide): 0 of 97 bot-attributed
# merges had their head branch auto-deleted; 1746 of 1746 user-attributed
# merges did. A controlled repeat in a scratch repo with one required check
# matched: GITHUB_TOKEN armed or merged 4 of 4 survived, a user token or
# the fleet PAT 5 of 5 were deleted within 2 s. So the gate: neither
# workflow arms unless the caller's PAT arrived AND is a user credential
# (GET /user returns type=User; App installation tokens get a 403).
# Dependabot's own PRs are excepted — their runs never get Actions
# secrets, and Dependabot deletes its own branch (0 of 281 survived).
#
# The arm steps are EXTRACTED from the workflow YAML (the shipped bash,
# not a mirrored copy) and run against a stubbed `gh`:
#
#   claude-author-automerge.yml
#    1.  no PAT, non-Dependabot author ⇒ exit 0, NO arm, NO disarm, no
#        /user probe, stood_down=no-pat, an ::error:: naming the fix.
#    1b. same, but a USER already armed the PR ⇒ that arm is never
#        disarmed; the reconciler decides the label from the live arm
#        state at publish time (Codex rounds 2, 3, 5).
#    1c. same, but a BOT armed it ⇒ the bot's arm is removed (it would
#        merge as the bot; re-arming keeps the enabler), then the refusal.
#    1d. the arm state is unreadable ⇒ nothing disarmed, stood_down=no-pat.
#    1e. a bot's arm that will not come off ⇒ exit 1 (fail closed).
#    2.  PAT that is a user ⇒ arms (head-bound), armed=1, no stood_down.
#    2b. PAT whose /user read fails 3× (an App installation token's 403)
#        ⇒ refused after exactly 3 attempts, no arm, stood_down=no-pat.
#    2c. PAT whose /user answer is not a User ⇒ refused, 1 attempt.
#    2d. /user fails twice, then answers ⇒ arms (the retry recovers).
#    2e. the /user probe precedes the base/body revalidation reads, so its
#        retries never widen the revalidate-to-arm window (Codex round 3).
#    2f. user PAT + a BOT's arm ⇒ the bot's arm is removed before the
#        live-state reads, then the PR is armed as the user (Codex round 5).
#    2g. the first arm read fails and a bot's arm stays ⇒ the read-back
#        after the arm catches it, removes it, exit 1 (review pass 2).
#    3.  no PAT, author dependabot[bot] ⇒ arms, no /user probe (exception).
#    4.  near-miss authors (dependabot, Dependabot[bot], dependabot[bot]x)
#        ⇒ refused — the exception is an exact login match.
#    5.  no PAT AND the base moved ⇒ the base revalidation still runs first:
#        disarm + stood_down=base, not no-pat.
#   safe-paths-automerge.yml
#    6.  no PAT, non-Dependabot author ⇒ exit 0, NO arm, ::error:: + summary.
#    7.  PAT that is a user ⇒ arms, bound with --match-head-commit.
#    7a. the /user probe precedes the head read (Codex round 3).
#    7b. PAT whose /user read fails 3× ⇒ refused, no arm.
#    7c. the head moves before the bound arm ⇒ rejected, exit 0 + notice.
#    7d. the arm fails on an unchanged head ⇒ exit 1.
#    8.  no PAT, author dependabot[bot] ⇒ arms (wxa-mcp-server's
#        docs/package.json bumps take this path).
#    6b. no PAT + a BOT's arm ⇒ the bot's arm is removed, then the refusal.
#    8b. user PAT + a BOT's arm ⇒ removed before the head read, then the
#        bound arm as the user.
#    8c. a bot's arm that will not come off ⇒ 3 disable attempts, exit 1.
#    8d. the first arm read fails and a bot's arm stays ⇒ the read-back
#        after the arm catches it, removes it, exit 1 (review pass 2).
#   negative controls (each proves a case above can fail)
#    9.  claude-author with both refusal calls neutralized ⇒ arms under no
#        PAT (case 1).
#    9b. claude-author with only the /user refusal neutralized ⇒ arms with
#        an App-token-shaped credential (case 2b).
#    9c. claude-author with only the bot-arm removal neutralized ⇒ a
#        bot-armed PR is re-armed over with no disarm first (case 2f).
#    10. safe-paths with both refusal calls neutralized ⇒ arms (case 6).
#    9d/10b. the arm-owner jq path misspelled (`.enabled_by.is_bot`) in
#        each step ⇒ a bot's arm slips through; the stub runs the shipped
#        filters, so the harness sees it (review pass 2).
#
# Structural pins (hardcoded, not derived from the files under test):
#   * exactly ONE non-comment `gh pr merge --auto` per workflow, and both
#     the refusal and the /user probe precede it in the same step — a
#     second arm path would bypass the gate;
#   * PR_AUTHOR comes from github.event.pull_request.user.login (the one
#     field PR contents cannot set) and USING_PAT from
#     secrets.automerge_pat, in both arm steps;
#   * GH_TOKEN keeps its `|| github.token` fallback: the Dependabot path
#     and the pre-arm revalidation reads/disarms run without a PAT;
#   * automerge_pat stays `required: false` in both: a required secret
#     fails a misconfigured caller at STARTUP, which would also stop the
#     hold-label and error revokes that protect already-armed PRs;
#   * the refusal helper never calls --disable-auto (any arm already
#     present is user-attributed);
#   * both run blocks are `${{ }}`-free — Actions evaluates expressions in
#     a run block before bash starts, so even an error message quoting
#     `${{ secrets.AUTOMERGE_PAT }}` would inject the secret into the script;
#   * the decision label: stood_down=no-pat ⇒ automerge:refused-no-pat,
#     with a description within GitHub's 100-character label limit;
#   * the docstrings ask for a user PAT, not an App token.
#
# Run from the repo root:
#   bash selftest/test_automerge_pat_attribution_gate.sh
set -euo pipefail

CA=.github/workflows/claude-author-automerge.yml
SP=.github/workflows/safe-paths-automerge.yml
failed=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

pass() { echo "✓ $1"; }
fail() { echo "✗ $1"; failed=1; }

# ---------------------------------------------------------------------------
# 0a. Extraction — the shipped run blocks.
# ---------------------------------------------------------------------------
extract_run() { # workflow → the "Enable auto-merge" step's run block
  awk '
    /^      - name: Enable auto-merge$/ { in_step=1; next }
    in_step && /^        run: \|/ { in_run=1; next }
    in_run {
      if ($0 ~ /^          / || $0 == "") { sub(/^          /, ""); print }
      else { exit }
    }
  ' "$1"
}
step_header() { # workflow → the step's lines from its name to `run: |`
  awk '/^      - name: Enable auto-merge$/{f=1} f && /^        run: \|/{exit} f' "$1"
}

extract_run "$CA" > "$T/ca.sh"
extract_run "$SP" > "$T/sp.sh"
for f in ca sp; do
  if ! grep -q 'gh pr merge --auto' "$T/$f.sh" || ! grep -q 'USING_PAT' "$T/$f.sh"; then
    echo "✗ could not extract the arm step ($f) — no arm command or USING_PAT in the extracted block"
    exit 1
  fi
done
pass "extracted both arm steps (claude-author $(wc -l < "$T/ca.sh" | tr -d ' ') lines, safe-paths $(wc -l < "$T/sp.sh" | tr -d ' ') lines)"

# ---------------------------------------------------------------------------
# 0b. Structural pins.
# ---------------------------------------------------------------------------
for wf in "$CA" "$SP"; do
  n=$(awk '!/^[[:space:]]*#/ && /gh pr merge --auto/' "$wf" | wc -l | tr -d ' ')
  if [ "$n" = "1" ]; then
    pass "$wf has exactly one arm call site"
  else
    fail "$wf has $n non-comment 'gh pr merge --auto' lines, expected 1 — a second arm path bypasses the attribution gate"
  fi
done

precedes_arm() { # extracted block, fixed string → 0 when that string's first line precedes the arm line
  awk -v s="$2" '
    index($0, s) && !mark { mark=NR }
    !/^[[:space:]]*#/ && /gh pr merge --auto/ && !arm { arm=NR }
    END { exit !(mark && arm && mark < arm) }
  ' "$1"
}
for f in ca sp; do
  if precedes_arm "$T/$f.sh" 'refuse_unattributed_arm "No automerge_pat reached this workflow."' \
    && precedes_arm "$T/$f.sh" "gh api user --jq 'select(.type == \"User\") | .login'"; then
    pass "$f: the no-PAT refusal and the /user probe both precede the arm"
  else
    fail "$f: the attribution gate (refusal + /user probe) does not precede the arm command"
  fi
done

for wf in "$CA" "$SP"; do
  hdr=$(step_header "$wf")
  if grep -qF 'PR_AUTHOR: ${{ github.event.pull_request.user.login }}' <<< "$hdr"; then
    pass "$wf: PR_AUTHOR is the PR author's login"
  else
    fail "$wf: PR_AUTHOR is not github.event.pull_request.user.login — the Dependabot exception must key on a field PR contents cannot set"
  fi
  if grep -qF "USING_PAT: \${{ secrets.automerge_pat != '' && '1' || '0' }}" <<< "$hdr"; then
    pass "$wf: USING_PAT reflects whether the PAT arrived"
  else
    fail "$wf: USING_PAT is not computed from secrets.automerge_pat"
  fi
  if grep -qF 'GH_TOKEN: ${{ secrets.automerge_pat || github.token }}' <<< "$hdr"; then
    pass "$wf: GH_TOKEN keeps the github.token fallback (Dependabot path, revalidation reads)"
  else
    fail "$wf: GH_TOKEN lost its github.token fallback — the Dependabot path and the no-PAT revalidation disarms would run with no token"
  fi
  req=$(awk '/^      automerge_pat:$/{f=1} f && /^        required:/{print $2; exit}' "$wf")
  if [ "$req" = "false" ]; then
    pass "$wf: automerge_pat stays required: false"
  else
    fail "$wf: automerge_pat is 'required: ${req:-<missing>}' — a required secret fails misconfigured callers at startup, killing their hold/error revokes"
  fi
  if grep -q 'Optional fine-grained PAT (or GitHub App token)' "$wf" || ! grep -q 'Use a USER PAT, not an App token' "$wf"; then
    fail "$wf: the automerge_pat docstring still offers a GitHub App token — GITHUB_TOKEN is one, and its merges keep the branch"
  else
    pass "$wf: docstring asks for a user PAT, not an App token"
  fi
done

for f in ca sp; do
  if grep -q '\${{' "$T/$f.sh"; then
    fail "$f arm run block contains \${{ }} — Actions would evaluate it before bash runs (a quoted secret expression is an injection)"
  else
    pass "$f arm run block is \${{ }}-free"
  fi
done

refuse_body=$(awk '/refuse_unattributed_arm\(\) \{/{f=1} f{print} f && /^ *\}$/{exit}' "$T/ca.sh")
if [ -n "$refuse_body" ] && ! grep -q 'disable-auto' <<< "$refuse_body" && grep -q 'stood_down=no-pat' <<< "$refuse_body"; then
  pass "refuse_unattributed_arm publishes stood_down=no-pat and never disarms"
else
  fail "refuse_unattributed_arm is missing, disarms, or does not publish stood_down=no-pat"
fi

if grep -qF '"${ARM_STOOD_DOWN:-}" = "no-pat"' "$CA" && grep -qF 'decision="automerge:refused-no-pat"' "$CA"; then
  pass "reconciler maps stood_down=no-pat to automerge:refused-no-pat"
else
  fail "reconciler does not map stood_down=no-pat to automerge:refused-no-pat — the refusal would read as the unlabeled wedge"
fi
if grep -qF 'if [ "$decision" = "automerge:refused-no-pat" ]; then' "$CA" \
   && grep -qF '.auto_merge.enabled_by.type == "Bot"' "$CA"; then
  pass "reconciler re-reads the live arm state before publishing refused-no-pat"
else
  fail "reconciler publishes refused-no-pat without re-reading the arm state — a user-armed PR could carry a refusal label"
fi
desc=$(awk -F'desc="' '/automerge:refused-no-pat\)[[:space:]]+color=/{split($2, a, "\""); print a[1]}' "$CA")
dlen=$(printf '%s' "$desc" | python3 -c 'import sys; print(len(sys.stdin.read()))')
if [ -n "$desc" ] && [ "$dlen" -le 100 ]; then
  pass "automerge:refused-no-pat has a description within GitHub's 100-char limit ($dlen)"
else
  fail "automerge:refused-no-pat description missing or over 100 chars (${dlen:-0}) — gh label create would reject it"
fi

# ---------------------------------------------------------------------------
# 0c. Stubs: `gh` logs every call and models the PR's auto-merge state; its
#     `pr view` and `api user` answers are computed by running the SHIPPED
#     --jq filter over gh-shaped JSON, so a wrong field path in a workflow
#     filter (e.g. `.enabled_by.is_bot`) gives a wrong answer here exactly
#     as it would in production (independent review, second pass).
#     `sleep` no-ops the retry backoffs. Knobs (env):
#       STUB_ARMED_BY              — the arm at the start: none|bot|user
#       STUB_ARMED_BY_FAIL_TIMES   — first N `pr view` reads exit 1
#       STUB_DISARM_STUCK          — 1 ⇒ --disable-auto leaves the arm on
#       STUB_ARM_FAIL              — 1 ⇒ `gh pr merge --auto` exits 1
#       STUB_BASE / STUB_HEAD / STUB_HEAD_LATER — the live-state reads
#       STUB_USER_TYPE             — GET /user's `type` (default User)
#       STUB_USER_FAIL_TIMES       — first N /user reads exit 1 (a 403)
#     `gh pr merge --auto` models GitHub: it sets the enabler only when the
#     PR is not armed (USING_PAT=1 ⇒ the user, else the Actions bot) and
#     KEEPS an existing enabler — measured 2026-09-18.
# ---------------------------------------------------------------------------
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_LOG"
arm_state() { cat "$ARM_STATE" 2>/dev/null || echo none; }
jq_filter() { while [ $# -gt 0 ]; do [ "$1" = "--jq" ] && { printf '%s' "$2"; return; }; shift; done; }
case "$1 $2" in
  "pr merge")
    case " $* " in
      *" --disable-auto "*) [ "${STUB_DISARM_STUCK:-0}" = "1" ] || echo none > "$ARM_STATE" ;;
      *" --auto "*)
        [ "${STUB_ARM_FAIL:-0}" = "1" ] && exit 1
        if [ "$(arm_state)" = "none" ]; then
          if [ "${USING_PAT:-0}" = "1" ]; then echo user > "$ARM_STATE"; else echo bot > "$ARM_STATE"; fi
        fi ;;
    esac
    exit 0 ;;
  "pr view")
    n=$(cat "$VIEW_READS" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$VIEW_READS"
    [ "$n" -le "${STUB_ARMED_BY_FAIL_TIMES:-0}" ] && exit 1
    case "$(arm_state)" in
      none) json='{"autoMergeRequest":null}' ;;
      bot)  json='{"autoMergeRequest":{"enabledBy":{"login":"app/github-actions","is_bot":true}}}' ;;
      user) json='{"autoMergeRequest":{"enabledBy":{"login":"topcoder1","is_bot":false}}}' ;;
    esac
    printf '%s\n' "$json" | jq -r "$(jq_filter "$@")"
    exit $? ;;
esac
if [ "$1" = "api" ] && [ "$2" = "user" ]; then
  n=$(cat "$USER_CALLS" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$USER_CALLS"
  [ "$n" -le "${STUB_USER_FAIL_TIMES:-0}" ] && exit 1
  printf '{"login":"topcoder1","type":"%s"}\n' "${STUB_USER_TYPE:-User}" | jq -r "$(jq_filter "$@")"
  exit $?
fi
if [ "$1" = "api" ]; then
  case "$*" in
    *"--jq .base.ref"*) printf '%s\n' "${STUB_BASE:-main}" ;;
    *"--jq .head.sha"*)
      # The first head read answers STUB_HEAD (default: the event's head);
      # later reads answer STUB_HEAD_LATER when set (a push mid-run).
      h=$(cat "$HEAD_READS" 2>/dev/null || echo 0); h=$((h + 1)); echo "$h" > "$HEAD_READS"
      if [ "$h" -gt 1 ] && [ -n "${STUB_HEAD_LATER:-}" ]; then printf '%s\n' "$STUB_HEAD_LATER"
      else printf '%s\n' "${STUB_HEAD:-$HEAD_SHA}"; fi ;;
    *"--jq .body"*) printf '%s\n' "" ;;
  esac
  exit 0
fi
exit 0
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/sleep"
chmod +x "$T/bin/gh" "$T/bin/sleep"

HEAD="c0ffee0000000000000000000000000000000001"

run_step() { # script, using_pat, author → $T/out.log, $T/gh.log, $T/ghout, $T/summary
  : > "$T/gh.log"; : > "$T/ghout"; : > "$T/summary"; rm -f "$T/user_calls" "$T/head_reads" "$T/view_reads"
  echo "${STUB_ARMED_BY:-none}" > "$T/arm_state"
  local rc=0
  ( export PATH="$T/bin:$PATH" GH_LOG="$T/gh.log" USER_CALLS="$T/user_calls" HEAD_READS="$T/head_reads" \
      ARM_STATE="$T/arm_state" VIEW_READS="$T/view_reads" \
      GITHUB_OUTPUT="$T/ghout" GITHUB_STEP_SUMMARY="$T/summary" GITHUB_REPOSITORY="stub/repo" \
      GH_TOKEN=stub PR=42 PR_URL="https://github.com/stub/repo/pull/42" \
      HEAD_SHA="$HEAD" METHOD=squash REASON="branch=claude/x" RISKY=0 \
      BYPASS_LABEL=0 BYPASS_CODEX=0 GATE_BASE_REF=main GATE_BODY_SHA="" \
      DEFAULT_BRANCH=main OPTIN_LABEL=auto-merge-nonmain \
      USING_PAT="$2" PR_AUTHOR="$3"
    bash "$1" ) > "$T/out.log" 2>&1 || rc=$?
  echo "rc=$rc" >> "$T/out.log"
}
has() { grep -qF -- "$2" "$1"; }
armed() { grep -q 'gh pr merge --auto' "$T/gh.log"; }
disarmed() { grep -q 'gh pr merge --disable-auto' "$T/gh.log"; }
user_calls() { grep -c '^gh api user' "$T/gh.log" || true; }
# Codex round 3: the /user probe's retries must never sit between a
# live-state read and the arm, so its first call must PRECEDE the step's
# first live-state read in the call log.
probe_before() { # fixed string of the first live-state read
  local p r
  p=$(grep -n -m1 -F -- "gh api user" "$T/gh.log" | cut -d: -f1)
  r=$(grep -n -m1 -F -- "$1" "$T/gh.log" | cut -d: -f1)
  [ -n "$p" ] && [ -n "$r" ] && [ "$p" -lt "$r" ]
}
dump() { sed 's/^/    /' "$T/out.log" "$T/gh.log" "$T/ghout"; }

# ---------------------------------------------------------------------------
# claude-author-automerge.yml
# ---------------------------------------------------------------------------
run_step "$T/ca.sh" 0 "topcoder1"
if ! armed && ! disarmed && [ "$(user_calls)" = "0" ] && has "$T/out.log" "rc=0" \
   && has "$T/ghout" "stood_down=no-pat" && ! has "$T/ghout" "armed=1" \
   && has "$T/out.log" "::error::No automerge_pat reached this workflow."; then
  pass "1: claude-author, no PAT ⇒ no arm, no disarm, no probe, stood_down=no-pat, exit 0"
else
  fail "1: claude-author, no PAT should refuse cleanly"; dump
fi

export STUB_ARMED_BY="user"
run_step "$T/ca.sh" 0 "topcoder1"
unset STUB_ARMED_BY
if ! armed && ! disarmed && has "$T/ghout" "stood_down=no-pat" && has "$T/out.log" "rc=0"; then
  pass "1b: no PAT, a USER already armed the PR ⇒ that arm is kept (no disarm); the reconciler decides the label"
else
  fail "1b: a user's existing arm must never be disarmed by the attribution gate"; dump
fi

export STUB_ARMED_BY="bot"
run_step "$T/ca.sh" 0 "topcoder1"
unset STUB_ARMED_BY
if ! armed && disarmed && has "$T/ghout" "stood_down=no-pat" && has "$T/out.log" "rc=0"; then
  pass "1c: no PAT, a BOT armed the PR ⇒ the bot's arm is removed, then the refusal (stood_down=no-pat)"
else
  fail "1c: a bot's arm on a non-Dependabot PR must be removed — it would merge as the bot (Codex round 5)"; dump
fi

export STUB_ARMED_BY_FAIL_TIMES=1
run_step "$T/ca.sh" 0 "topcoder1"
unset STUB_ARMED_BY_FAIL_TIMES
if ! armed && ! disarmed && has "$T/ghout" "stood_down=no-pat" && has "$T/out.log" "rc=0"; then
  pass "1d: no PAT, arm state unreadable ⇒ nothing disarmed, stood_down=no-pat, exit 0"
else
  fail "1d: an unreadable arm state must leave arms alone and still refuse"; dump
fi

export STUB_ARMED_BY="bot" STUB_DISARM_STUCK=1
run_step "$T/ca.sh" 1 "topcoder1"
unset STUB_ARMED_BY STUB_DISARM_STUCK
if ! armed && has "$T/out.log" "rc=1" && has "$T/out.log" "::error::could not verify the bot's arm is off"; then
  pass "1e: a bot's arm that will not come off ⇒ exit 1 (fail closed), no arm"
else
  fail "1e: an unverifiable bot-arm removal must fail the step"; dump
fi

run_step "$T/ca.sh" 1 "topcoder1"
if has "$T/gh.log" "gh pr merge --auto --squash --match-head-commit $HEAD https://github.com/stub/repo/pull/42" \
   && has "$T/ghout" "armed=1" && ! has "$T/ghout" "stood_down=" && has "$T/out.log" "Arming as topcoder1" \
   && has "$T/out.log" "rc=0"; then
  pass "2: claude-author, user PAT ⇒ head-bound arm, armed=1"
else
  fail "2: claude-author with a user PAT should arm"; dump
fi
if probe_before "--jq .base.ref"; then
  pass "2e: claude-author probes /user BEFORE the base/body revalidation reads (no retry gap before the arm)"
else
  fail "2e: the /user probe runs after the live-state revalidation — its retries widen the revalidate-to-arm window (Codex round 3)"; dump
fi

# before_in_log A B: the first log line containing A precedes the first containing B.
before_in_log() {
  local a b
  a=$(grep -n -m1 -F -- "$1" "$T/gh.log" | cut -d: -f1)
  b=$(grep -n -m1 -F -- "$2" "$T/gh.log" | cut -d: -f1)
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
}
export STUB_ARMED_BY="bot"
run_step "$T/ca.sh" 1 "topcoder1"
unset STUB_ARMED_BY
if has "$T/ghout" "armed=1" && before_in_log "gh pr merge --disable-auto" "--jq .base.ref" \
   && before_in_log "gh pr merge --disable-auto" "gh pr merge --auto"; then
  pass "2f: user PAT + a BOT's arm ⇒ the bot's arm is removed before the live-state reads, then the PR is armed as the user"
else
  fail "2f: a bot's arm must be replaced, not re-armed over — GitHub keeps the original enabler (Codex round 5)"; dump
fi

export STUB_ARMED_BY="bot" STUB_ARMED_BY_FAIL_TIMES=1
run_step "$T/ca.sh" 1 "topcoder1"
unset STUB_ARMED_BY STUB_ARMED_BY_FAIL_TIMES
if has "$T/out.log" "rc=1" && ! has "$T/ghout" "armed=1" \
   && has "$T/out.log" "::error::after arming, auto-merge is enabled by 'bot'" && disarmed; then
  pass "2g: the first arm read fails and a BOT's arm stays ⇒ the read-back after the arm catches it, removes it, exit 1"
else
  fail "2g: an arm left with a bot as enabler must not be reported as armed (review pass 2, #1)"; dump
fi

export STUB_USER_FAIL_TIMES=3
run_step "$T/ca.sh" 1 "topcoder1"
unset STUB_USER_FAIL_TIMES
if ! armed && ! disarmed && [ "$(user_calls)" = "3" ] && has "$T/ghout" "stood_down=no-pat" \
   && has "$T/out.log" "::error::automerge_pat is not a user credential" && has "$T/out.log" "rc=0"; then
  pass "2b: claude-author, App-token-shaped PAT (/user 403 ×3) ⇒ refused after 3 attempts"
else
  fail "2b: a credential GET /user refuses must not arm"; dump
fi

export STUB_USER_TYPE="Bot"
run_step "$T/ca.sh" 1 "topcoder1"
unset STUB_USER_TYPE
if ! armed && [ "$(user_calls)" = "1" ] && has "$T/ghout" "stood_down=no-pat"; then
  pass "2c: claude-author, /user answers but not as a User ⇒ refused, no retry"
else
  fail "2c: a non-User /user answer must refuse"; dump
fi

export STUB_USER_FAIL_TIMES=2
run_step "$T/ca.sh" 1 "topcoder1"
unset STUB_USER_FAIL_TIMES
if armed && [ "$(user_calls)" = "3" ] && has "$T/ghout" "armed=1"; then
  pass "2d: claude-author, /user fails twice then answers ⇒ arms (retry recovers)"
else
  fail "2d: a transient /user failure should be retried"; dump
fi

run_step "$T/ca.sh" 0 "dependabot[bot]"
if armed && has "$T/ghout" "armed=1" && ! has "$T/ghout" "stood_down=no-pat" && [ "$(user_calls)" = "0" ]; then
  pass "3: claude-author, no PAT, dependabot[bot] ⇒ arms, no probe (exception kept)"
else
  fail "3: claude-author must keep arming Dependabot's own PRs without a PAT"; dump
fi

for author in "dependabot" "Dependabot[bot]" "dependabot[bot]x"; do
  run_step "$T/ca.sh" 0 "$author"
  if ! armed && has "$T/ghout" "stood_down=no-pat"; then
    pass "4: near-miss author '$author' ⇒ refused (exact-match exception)"
  else
    fail "4: near-miss author '$author' took the Dependabot exception"; dump
  fi
done

export STUB_BASE="feature/other"
run_step "$T/ca.sh" 0 "topcoder1"
unset STUB_BASE
if disarmed && has "$T/ghout" "stood_down=base" && ! has "$T/ghout" "stood_down=no-pat" && ! armed; then
  pass "5: no PAT + moved base ⇒ the base revalidation still disarms first (stood_down=base)"
else
  fail "5: the attribution gate pre-empted the base revalidation's disarm"; dump
fi

# ---------------------------------------------------------------------------
# safe-paths-automerge.yml
# ---------------------------------------------------------------------------
run_step "$T/sp.sh" 0 "wxacoeur"
if ! armed && ! disarmed && has "$T/out.log" "rc=0" \
   && has "$T/out.log" "::error::No automerge_pat reached this workflow." \
   && has "$T/summary" "No automerge_pat reached this workflow."; then
  pass "6: safe-paths, no PAT ⇒ no arm, no disarm, ::error:: + step summary, exit 0"
else
  fail "6: safe-paths, no PAT should refuse cleanly"; dump; sed 's/^/    /' "$T/summary"
fi

run_step "$T/sp.sh" 1 "wxacoeur"
if has "$T/gh.log" "gh pr merge --auto --squash --match-head-commit $HEAD https://github.com/stub/repo/pull/42" \
   && has "$T/out.log" "rc=0"; then
  pass "7: safe-paths, user PAT ⇒ arms, bound to the classified head"
else
  fail "7: safe-paths with a user PAT should arm with --match-head-commit"; dump
fi
if probe_before "--jq .head.sha"; then
  pass "7a: safe-paths probes /user BEFORE the head read (no retry gap before the arm)"
else
  fail "7a: the /user probe runs after the head read — its retries widen the read-to-arm window (Codex round 3)"; dump
fi

export STUB_ARM_FAIL=1 STUB_HEAD_LATER="0000000000000000000000000000000000000bad"
run_step "$T/sp.sh" 1 "wxacoeur"
unset STUB_ARM_FAIL STUB_HEAD_LATER
if has "$T/out.log" "rc=0" && has "$T/out.log" "head moved ($HEAD → 0000000000000000000000000000000000000bad)" \
   && ! has "$T/out.log" "::error::"; then
  pass "7c: safe-paths, the head moves before the bound arm ⇒ the arm is rejected, exit 0 with a notice"
else
  fail "7c: a head-moved arm rejection must stand down cleanly"; dump
fi

export STUB_ARM_FAIL=1
run_step "$T/sp.sh" 1 "wxacoeur"
unset STUB_ARM_FAIL
if has "$T/out.log" "rc=1" && has "$T/out.log" "::error::enable auto-merge failed and the head still matches $HEAD"; then
  pass "7d: safe-paths, the arm fails with the head unchanged ⇒ exit 1 (investigate)"
else
  fail "7d: an arm failure on an unchanged head must fail the step"; dump
fi

export STUB_USER_FAIL_TIMES=3
run_step "$T/sp.sh" 1 "wxacoeur"
unset STUB_USER_FAIL_TIMES
if ! armed && [ "$(user_calls)" = "3" ] && has "$T/out.log" "::error::automerge_pat is not a user credential"; then
  pass "7b: safe-paths, App-token-shaped PAT ⇒ refused after 3 attempts"
else
  fail "7b: safe-paths must not arm with a non-user credential"; dump
fi

run_step "$T/sp.sh" 0 "dependabot[bot]"
if armed && has "$T/out.log" "rc=0" && [ "$(user_calls)" = "0" ] && ! disarmed; then
  pass "8: safe-paths, no PAT, dependabot[bot] ⇒ arms (exception kept, no bot-arm check)"
else
  fail "8: safe-paths must keep arming Dependabot's own safe-paths PRs"; dump
fi

export STUB_ARMED_BY="bot"
run_step "$T/sp.sh" 0 "wxacoeur"
unset STUB_ARMED_BY
if ! armed && disarmed && has "$T/out.log" "::error::No automerge_pat reached this workflow." && has "$T/out.log" "rc=0"; then
  pass "6b: safe-paths, no PAT + a BOT's arm ⇒ the bot's arm is removed, then the refusal"
else
  fail "6b: safe-paths must remove a bot's arm on a non-Dependabot PR"; dump
fi

export STUB_ARMED_BY="bot"
run_step "$T/sp.sh" 1 "wxacoeur"
unset STUB_ARMED_BY
if armed && before_in_log "gh pr merge --disable-auto" "--jq .head.sha" \
   && before_in_log "gh pr merge --disable-auto" "gh pr merge --auto" && has "$T/out.log" "rc=0"; then
  pass "8b: safe-paths, user PAT + a BOT's arm ⇒ removed before the head read, then the bound arm as the user"
else
  fail "8b: safe-paths must replace a bot's arm before arming as the user"; dump
fi

export STUB_ARMED_BY="bot" STUB_DISARM_STUCK=1
run_step "$T/sp.sh" 1 "wxacoeur"
unset STUB_ARMED_BY STUB_DISARM_STUCK
if ! armed && has "$T/out.log" "rc=1" && has "$T/out.log" "::error::could not verify the bot's arm is off" \
   && [ "$(grep -c 'gh pr merge --disable-auto' "$T/gh.log")" = "3" ]; then
  pass "8c: safe-paths, a bot's arm that will not come off ⇒ 3 disable attempts, then exit 1 (fail closed), no arm"
else
  fail "8c: an unverifiable bot-arm removal must fail the safe-paths step"; dump
fi

export STUB_ARMED_BY="bot" STUB_ARMED_BY_FAIL_TIMES=1
run_step "$T/sp.sh" 1 "wxacoeur"
unset STUB_ARMED_BY STUB_ARMED_BY_FAIL_TIMES
if has "$T/out.log" "rc=1" && has "$T/out.log" "::error::after arming, auto-merge is enabled by 'bot'" && disarmed; then
  pass "8d: safe-paths, the first arm read fails and a BOT's arm stays ⇒ caught after the arm, removed, exit 1"
else
  fail "8d: safe-paths must not leave a bot's arm behind when the first read failed (review pass 2, #1)"; dump
fi

# ---------------------------------------------------------------------------
# Negative controls: neutralize a refusal; the harness must then see the
# bot arm it exists to prevent. Each mutation is verified to have applied
# the expected number of times, so no control can pass vacuously.
# ---------------------------------------------------------------------------
neutralize() { # script, which-regex, expected-count, out
  sed "s/^\( *\)refuse_unattributed_arm \"$2.*\"$/\1: neutralized/" "$1" > "$4"
  [ "$(grep -c ': neutralized' "$4")" = "$3" ]
}

if neutralize "$T/ca.sh" "" 2 "$T/ca_mut.sh"; then
  run_step "$T/ca_mut.sh" 0 "topcoder1"
  if armed; then
    pass "9: negative control — claude-author without its refusals arms under no PAT (case 1 can fail)"
  else
    fail "9: negative control — the neutralized claude-author step did not arm; case 1 proves nothing"
  fi
else
  fail "9: negative control mutation did not neutralize exactly two refusal calls"
fi

if neutralize "$T/ca.sh" "automerge_pat is not a user credential" 1 "$T/ca_mut2.sh"; then
  export STUB_USER_FAIL_TIMES=3
  run_step "$T/ca_mut2.sh" 1 "topcoder1"
  unset STUB_USER_FAIL_TIMES
  if armed; then
    pass "9b: negative control — without the /user refusal an App-token-shaped PAT arms (case 2b can fail)"
  else
    fail "9b: negative control — the neutralized /user refusal did not arm; case 2b proves nothing"
  fi
else
  fail "9b: negative control mutation did not neutralize exactly the /user refusal"
fi

# 9c: neutralize only the bot-arm REMOVAL (the first --disable-auto after the
# "a bot armed this PR" notice); case 2f must then see no disarm before the arm.
awk '/a bot armed this PR/{seen=1} seen && !done && /gh pr merge --disable-auto/{sub(/gh pr merge --disable-auto "\$PR_URL" 2>&1 \|\| true/, ": removal-neutralized"); done=1} {print}' \
  "$T/ca.sh" > "$T/ca_mut3.sh"
if [ "$(grep -c 'removal-neutralized' "$T/ca_mut3.sh")" = "1" ]; then
  export STUB_ARMED_BY="bot"
  run_step "$T/ca_mut3.sh" 1 "topcoder1"
  unset STUB_ARMED_BY
  if ! before_in_log "gh pr merge --disable-auto" "gh pr merge --auto"; then
    pass "9c: negative control — without the bot-arm removal, a bot-armed PR is re-armed over (case 2f can fail)"
  else
    fail "9c: negative control — a disarm still preceded the arm with the removal neutralized; case 2f proves nothing"
  fi
else
  fail "9c: negative control mutation did not neutralize exactly the bot-arm removal"
fi

if neutralize "$T/sp.sh" "" 2 "$T/sp_mut.sh"; then
  run_step "$T/sp_mut.sh" 0 "wxacoeur"
  if armed; then
    pass "10: negative control — safe-paths without its refusals arms under no PAT (case 6 can fail)"
  else
    fail "10: negative control — the neutralized safe-paths step did not arm; case 6 proves nothing"
  fi
else
  fail "10: negative control mutation did not neutralize exactly two refusal calls"
fi

# 9d / 10b: the TYPO controls for the arm-owner jq (independent review, pass
# 2). With the enabler path misspelled, a bot's arm reads as a user's; the
# stub runs the SHIPPED filter, so the bot-armed cases must then fail —
# proving the harness can see a filter typo that would be silent in prod.
typo_control() { # label, script, author
  sed 's/\.autoMergeRequest\.enabledBy\.is_bot/.autoMergeRequest.enabled_by.is_bot/g' "$2" > "$2.typo"
  if [ "$(grep -c 'enabled_by.is_bot' "$2.typo")" -ge 2 ]; then
    export STUB_ARMED_BY="bot"
    run_step "$2.typo" 1 "$3"
    unset STUB_ARMED_BY
    if disarmed; then
      fail "$1: negative control — a misspelled enabler path still removed the bot's arm; the stub is not running the shipped filter"
    else
      pass "$1: negative control — a misspelled enabler path lets a bot's arm through unseen by the step, and the harness catches it"
    fi
  else
    fail "$1: typo mutation did not reach both enabler reads (top-of-step and read-back)"
  fi
}
typo_control "9d" "$T/ca.sh" "topcoder1"
typo_control "10b" "$T/sp.sh" "wxacoeur"

# ---------------------------------------------------------------------------
if [ "$failed" -ne 0 ]; then
  echo ""
  echo "FAILED — see ✗ lines above."
  exit 1
fi
echo ""
echo "All attribution-gate selftests passed."
