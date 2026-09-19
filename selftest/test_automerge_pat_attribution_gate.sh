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
# to push to because
# GitHub runs the repo's "Automatically delete head branches" only for a
# USER-attributed merge. wxa-graph's callers used `secrets: inherit`
# across accounts, which delivers nothing, so the arm ran on the
# GITHUB_TOKEN fallback (the run log shows `USING_PAT: 0`) and GitHub
# performed the merge as github-actions[bot].
#
# Measured 2026-09-18 over the 44 caller repos, merges since 2026-05-03
# (when delete_branch_on_merge was on fleet-wide): 0 of 97 bot-attributed
# merges had their head branch auto-deleted; 1746 of 1746 user-attributed
# merges did. A controlled repeat in a scratch repo with one required check
# matched: GITHUB_TOKEN armed or merged 4 of 4 survived, a user token or
# the fleet PAT 5 of 5 were deleted within 2 s. So the gate: without the
# caller's PAT, neither workflow arms (Dependabot's own PRs excepted —
# their runs never get Actions secrets, and Dependabot deletes its own
# branch: 0 of 281 survived).
#
# The arm steps are EXTRACTED from the workflow YAML (the shipped bash,
# not a mirrored copy) and run against a stubbed `gh`:
#
#   claude-author-automerge.yml
#    1. no PAT, non-Dependabot author ⇒ exit 0, NO arm, NO disarm,
#       stood_down=no-pat, an ::error:: naming the caller fix.
#    2. PAT present ⇒ arms (head-bound), armed=1, no stood_down.
#    3. no PAT, author dependabot[bot] ⇒ arms (exception kept).
#    4. near-miss authors (dependabot, Dependabot[bot], dependabot[bot]x)
#       ⇒ refused — the exception is an exact login match.
#    5. no PAT AND the base moved ⇒ the base revalidation still runs first:
#       disarm + stood_down=base, not no-pat. The gate sits after the
#       revalidations so their safety disarms keep working.
#   safe-paths-automerge.yml
#    6. no PAT, non-Dependabot author ⇒ exit 0, NO arm, ::error::, and the
#       step summary carries the reason.
#    7. PAT present ⇒ arms.
#    8. no PAT, author dependabot[bot] ⇒ arms (wxa-mcp-server's
#       docs/package.json bumps take this path).
#   negative controls (the cases above can fail)
#    9. claude-author step with the gate call neutralized ⇒ the harness
#       sees an arm under no PAT.
#   10. safe-paths step with the gate condition neutralized ⇒ same.
#
# Structural pins (hardcoded, not derived from the files under test):
#   * exactly ONE non-comment `gh pr merge --auto` per workflow, and the
#     gate precedes it in the same step — a second arm path would bypass
#     the gate;
#   * PR_AUTHOR comes from github.event.pull_request.user.login (the one
#     field PR contents cannot set) and USING_PAT from
#     secrets.automerge_pat, in both arm steps;
#   * GH_TOKEN keeps its `|| github.token` fallback: the Dependabot path
#     and the pre-arm revalidation reads/disarms run without a PAT;
#   * automerge_pat stays `required: false` in both: a required secret
#     fails a misconfigured caller at STARTUP, which would also stop the
#     hold-label and error revokes that protect already-armed PRs;
#   * the refusal helper never calls --disable-auto (see the workflow
#     comment: any arm already present is user-attributed);
#   * both run blocks are `${{ }}`-free — Actions evaluates expressions in
#     a run block before bash starts, so even an error message quoting
#     `${{ secrets.AUTOMERGE_PAT }}` would inject the secret into the script;
#   * the decision label: stood_down=no-pat ⇒ automerge:refused-no-pat,
#     with a description within GitHub's 100-character label limit;
#   * the docstrings no longer offer a GitHub App token as an alternative
#     (GITHUB_TOKEN is one; the merge would still be bot-attributed).
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

gate_before_arm() { # extracted block → 0 when the gate line precedes the arm line
  awk '
    /if \[ "\$USING_PAT" != "1" \] && \[ "\$PR_AUTHOR" != "dependabot\[bot\]" \]; then/ && !gate { gate=NR }
    !/^[[:space:]]*#/ && /gh pr merge --auto/ && !arm { arm=NR }
    END { exit !(gate && arm && gate < arm) }
  ' "$1"
}
for f in ca sp; do
  if gate_before_arm "$T/$f.sh"; then
    pass "$f: the attribution gate precedes the arm"
  else
    fail "$f: no attribution gate before the arm command"
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
desc=$(awk -F'desc="' '/automerge:refused-no-pat\)[[:space:]]+color=/{split($2, a, "\""); print a[1]}' "$CA")
dlen=$(printf '%s' "$desc" | python3 -c 'import sys; print(len(sys.stdin.read()))')
if [ -n "$desc" ] && [ "$dlen" -le 100 ]; then
  pass "automerge:refused-no-pat has a description within GitHub's 100-char limit ($dlen)"
else
  fail "automerge:refused-no-pat description missing or over 100 chars (${dlen:-0}) — gh label create would reject it"
fi

# ---------------------------------------------------------------------------
# 0c. Stub `gh`: logs every call; answers the reads both steps make.
#       STUB_BASE   — what the claude-author base re-read returns (main)
#       STUB_HEAD   — what the head-sha read returns (the event's head)
# ---------------------------------------------------------------------------
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_LOG"
case "$1 $2" in
  "pr merge") exit 0 ;;
  "pr view") echo "OFF"; exit 0 ;;
esac
if [ "$1" = "api" ]; then
  case "$*" in
    *"--jq .base.ref"*) printf '%s\n' "${STUB_BASE:-main}" ;;
    *"--jq .head.sha"*) printf '%s\n' "${STUB_HEAD:-$HEAD_SHA}" ;;
    *"--jq .body"*) printf '%s\n' "" ;;
  esac
  exit 0
fi
exit 0
STUB
chmod +x "$T/bin/gh"

HEAD="c0ffee0000000000000000000000000000000001"

run_step() { # script, using_pat, author → $T/out.log, $T/gh.log, $T/ghout, $T/summary
  : > "$T/gh.log"; : > "$T/ghout"; : > "$T/summary"
  local rc=0
  ( export PATH="$T/bin:$PATH" GH_LOG="$T/gh.log" GITHUB_OUTPUT="$T/ghout" \
      GITHUB_STEP_SUMMARY="$T/summary" GITHUB_REPOSITORY="stub/repo" \
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

# ---------------------------------------------------------------------------
# claude-author-automerge.yml
# ---------------------------------------------------------------------------
run_step "$T/ca.sh" 0 "topcoder1"
if ! armed && ! disarmed && has "$T/out.log" "rc=0" && has "$T/ghout" "stood_down=no-pat" \
   && has "$T/out.log" "::error::No automerge_pat reached this workflow" && ! has "$T/ghout" "armed=1"; then
  pass "1: claude-author, no PAT ⇒ no arm, no disarm, stood_down=no-pat, exit 0"
else
  fail "1: claude-author, no PAT should refuse cleanly"; sed 's/^/    /' "$T/out.log" "$T/gh.log" "$T/ghout"
fi

run_step "$T/ca.sh" 1 "topcoder1"
if has "$T/gh.log" "gh pr merge --auto --squash --match-head-commit $HEAD https://github.com/stub/repo/pull/42" \
   && has "$T/ghout" "armed=1" && ! has "$T/ghout" "stood_down=" && has "$T/out.log" "rc=0"; then
  pass "2: claude-author, PAT present ⇒ head-bound arm, armed=1"
else
  fail "2: claude-author with the PAT should arm"; sed 's/^/    /' "$T/out.log" "$T/gh.log" "$T/ghout"
fi

run_step "$T/ca.sh" 0 "dependabot[bot]"
if armed && has "$T/ghout" "armed=1" && ! has "$T/ghout" "stood_down=no-pat"; then
  pass "3: claude-author, no PAT, dependabot[bot] ⇒ arms (exception kept)"
else
  fail "3: claude-author must keep arming Dependabot's own PRs without a PAT"; sed 's/^/    /' "$T/out.log" "$T/gh.log"
fi

for author in "dependabot" "Dependabot[bot]" "dependabot[bot]x"; do
  run_step "$T/ca.sh" 0 "$author"
  if ! armed && has "$T/ghout" "stood_down=no-pat"; then
    pass "4: near-miss author '$author' ⇒ refused (exact-match exception)"
  else
    fail "4: near-miss author '$author' took the Dependabot exception"; sed 's/^/    /' "$T/gh.log"
  fi
done

export STUB_BASE="feature/other"
run_step "$T/ca.sh" 0 "topcoder1"
unset STUB_BASE
if disarmed && has "$T/ghout" "stood_down=base" && ! has "$T/ghout" "stood_down=no-pat" && ! armed; then
  pass "5: no PAT + moved base ⇒ the base revalidation still disarms first (stood_down=base)"
else
  fail "5: the attribution gate pre-empted the base revalidation's disarm"; sed 's/^/    /' "$T/out.log" "$T/gh.log" "$T/ghout"
fi

# ---------------------------------------------------------------------------
# safe-paths-automerge.yml
# ---------------------------------------------------------------------------
run_step "$T/sp.sh" 0 "wxacoeur"
if ! armed && ! disarmed && has "$T/out.log" "rc=0" && has "$T/out.log" "::error::No automerge_pat reached this workflow" \
   && has "$T/summary" "No automerge_pat reached this workflow"; then
  pass "6: safe-paths, no PAT ⇒ no arm, no disarm, ::error:: + step summary, exit 0"
else
  fail "6: safe-paths, no PAT should refuse cleanly"; sed 's/^/    /' "$T/out.log" "$T/gh.log" "$T/summary"
fi

run_step "$T/sp.sh" 1 "wxacoeur"
if has "$T/gh.log" "gh pr merge --auto --squash https://github.com/stub/repo/pull/42" && has "$T/out.log" "rc=0"; then
  pass "7: safe-paths, PAT present ⇒ arms"
else
  fail "7: safe-paths with the PAT should arm"; sed 's/^/    /' "$T/out.log" "$T/gh.log"
fi

run_step "$T/sp.sh" 0 "dependabot[bot]"
if armed && has "$T/out.log" "rc=0"; then
  pass "8: safe-paths, no PAT, dependabot[bot] ⇒ arms (exception kept)"
else
  fail "8: safe-paths must keep arming Dependabot's own safe-paths PRs"; sed 's/^/    /' "$T/out.log" "$T/gh.log"
fi

# ---------------------------------------------------------------------------
# Negative controls: neutralize each gate; the harness must then see the
# bot arm the gate exists to prevent. Each mutation is verified to have
# applied, so a control can never pass vacuously.
# ---------------------------------------------------------------------------
sed 's/^\( *\)refuse_unattributed_arm$/\1: gate-neutralized/' "$T/ca.sh" > "$T/ca_mut.sh"
if [ "$(grep -c 'gate-neutralized' "$T/ca_mut.sh")" = "1" ]; then
  run_step "$T/ca_mut.sh" 0 "topcoder1"
  if armed; then
    pass "9: negative control — claude-author without the gate arms under no PAT (case 1 can fail)"
  else
    fail "9: negative control — the neutralized claude-author step did not arm; case 1 proves nothing"
  fi
else
  fail "9: negative control mutation did not apply to exactly one gate call"
fi

sed 's/if \[ "\$USING_PAT" != "1" \] && \[ "\$PR_AUTHOR" != "dependabot\[bot\]" \]; then/if false; then/' "$T/sp.sh" > "$T/sp_mut.sh"
if ! cmp -s "$T/sp.sh" "$T/sp_mut.sh"; then
  run_step "$T/sp_mut.sh" 0 "wxacoeur"
  if armed; then
    pass "10: negative control — safe-paths without the gate arms under no PAT (case 6 can fail)"
  else
    fail "10: negative control — the neutralized safe-paths step did not arm; case 6 proves nothing"
  fi
else
  fail "10: negative control mutation did not apply"
fi

# ---------------------------------------------------------------------------
if [ "$failed" -ne 0 ]; then
  echo ""
  echo "FAILED — see ✗ lines above."
  exit 1
fi
echo ""
echo "All attribution-gate selftests passed."
