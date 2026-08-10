#!/usr/bin/env bash
# Behavioral test for safe-paths-automerge.yml's TIER 2 risk-tier hold —
# the gate that stops a 100%-docs/tests diff from auto-merging when it
# touches a risk-tier path.
#
# Incident (topcoder1/inbox_superpilot#215, 2026-08-10): a tests-only PR
# touching web/tests/e2e/auth/signup.spec.ts drew "Auto-merge blocked —
# risk-tier paths touched. Manual click-merge required" from
# claude-author-automerge.yml, and then merged HERE 12 minutes later. The
# two workflows never disagreed in any resolvable sense: claude-author-
# automerge cannot block a merge, only decline to ARM one, and this
# workflow is the only one that arms a docs/tests diff. The decline was an
# abstention, not a veto — so the permissive gate won silently and the
# merged PR kept an audit trail claiming a human had approved it.
#
# Pins:
#   1. The incident shape holds (all_safe=0, reason=risk-tier-hold).
#   2. The bypass label RELEASES the hold — claude-author-automerge's
#      blocked-PR comment advertises that exact one-click path, so a hold
#      that ignored it would kill the advertised escape hatch.
#   3. docs/legal/** (tier 1) is NOT releasable by the label.
#   4. The hold fires ONLY in the would-arm branch. A diff carrying a
#      non-safe file must keep reason empty — emitting a revoke-triggering
#      reason there would make the revoke step disarm a SIBLING workflow's
#      legitimate arm (a dependabot bump of .github/workflows/** matches
#      the risk patterns and is armed by dependabot-auto-merge.yml).
#   5. Ordinary docs/tests still auto-merge — the carve-out this workflow
#      exists to provide must not regress.
#   6. The tier-2 pattern list has not drifted from claude-author-
#      automerge.yml's `patterns=` block.
#
# The classify block is EXTRACTED from the workflow YAML and executed, so
# this exercises the shipped bash rather than a mirrored copy that can drift.
#
# Run from the repo root:
#   bash selftest/test_safe_paths_risk_tier_hold.sh
set -euo pipefail

failed=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

WF=.github/workflows/safe-paths-automerge.yml
SIB=.github/workflows/claude-author-automerge.yml

awk '
  /^[[:space:]]*id: classify[[:space:]]*$/ { in_step = 1 }
  in_step && /^[[:space:]]*run: \|[[:space:]]*$/ { grab = 1; next }
  grab && /^      - name:/ { exit }
  grab { print }
' "$WF" | sed -e 's/^          //' > "$T/classify.sh"

if ! grep -q 'risk_tier_overrides=' "$T/classify.sh"; then
  echo "FAIL: could not extract the classify block from $WF (no risk_tier_overrides found)"
  exit 1
fi

# Stub `gh`: the shipped block makes THREE distinct calls — the changed-file
# listing (.filename), the rename sources (.previous_filename), and the live
# label read (.labels[].name). Discriminate on the --jq expression so each
# returns its own fixture; a stub returning one list for all three would make
# the bypass-label and rename cases pass vacuously.
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    *previous_filename*) cat "$FAKE_RENAMES"; exit 0 ;;
    *labels*)            cat "$FAKE_LABELS";  exit 0 ;;
  esac
done
cat "$FAKE_FILES"
STUB
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"

export GH_TOKEN=stub REPO=owner/repo PR=1 EXTRA_GLOBS="" BYPASS_LABEL="auto-merge-approved"

# Reset after every run_case so they never leak between cases.
RENAMED_FROM=""
LABELS=""

# run_case <name> <expected all_safe> <expected reason|-> <file>...
run_case() {
  local name="$1" want_safe="$2" want_reason="$3"
  shift 3
  printf '%s\n' "$@" > "$T/files.txt"
  export FAKE_FILES="$T/files.txt"
  printf '%s' "$RENAMED_FROM" > "$T/renames.txt"
  export FAKE_RENAMES="$T/renames.txt"
  printf '%s' "$LABELS" > "$T/labels.txt"
  export FAKE_LABELS="$T/labels.txt"
  RENAMED_FROM=""
  LABELS=""
  : > "$T/gh_output"
  export GITHUB_OUTPUT="$T/gh_output"

  if ! bash "$T/classify.sh" > "$T/log" 2>&1; then
    echo "FAIL[$name]: classify block exited non-zero"
    sed 's/^/    /' "$T/log"
    failed=1
    return
  fi

  local got_safe got_reason
  got_safe=$(grep -E '^all_safe=' "$T/gh_output" | tail -1 | cut -d= -f2)
  got_reason=$(grep -E '^reason=' "$T/gh_output" | tail -1 | cut -d= -f2- || true)
  [ -n "$got_reason" ] || got_reason="-"

  if [ "$got_safe" != "$want_safe" ] || \
     { [ "$want_reason" != "-" ] && [ "$got_reason" != "$want_reason" ]; }; then
    echo "FAIL[$name]: all_safe=$got_safe reason=$got_reason, want $want_safe/$want_reason (files: $*)"
    failed=1
    return
  fi
  echo "ok[$name] all_safe=$got_safe reason=$got_reason"
}

# 1. The incident case, exactly as it merged.
run_case "incident-auth-spec" 0 risk-tier-hold "web/tests/e2e/auth/signup.spec.ts"
run_case "incident-pr215-full" 0 risk-tier-hold \
  "web/tests/e2e/auth/signup.spec.ts" \
  "web/tests/e2e/kb/knowledge-base.spec.ts" \
  "web/tests/e2e/marketing/landing.spec.ts" \
  "web/tests/e2e/stripe/stripe-integration.spec.ts"

# Other risk directories under a test root hold the same way.
run_case "risk-session-dir" 0 risk-tier-hold "web/tests/e2e/session/expiry.spec.ts"
run_case "risk-billing-dir" 0 risk-tier-hold "web/tests/e2e/checkout/pay.spec.ts"
# A .sql fixture under tests/ is safe-by-glob but risk-tier by content.
run_case "risk-sql-fixture" 0 risk-tier-hold "tests/fixtures/seed.sql"

# 2. The bypass label releases the hold.
LABELS="auto-merge-approved"
run_case "bypass-releases-hold" 1 - "web/tests/e2e/auth/signup.spec.ts"
# An unrelated label must NOT release it.
LABELS="dependencies"
run_case "unrelated-label-holds" 0 risk-tier-hold "web/tests/e2e/auth/signup.spec.ts"

# 3. Tier 1 is absolute — the label does not release customer-facing legal
#    wording. A label click is not evidence anyone read the clause.
LABELS="auto-merge-approved"
run_case "legal-not-bypassable" 0 unsafe-override "docs/legal/acceptable-use-policy.md"

# 4. The hold is scoped to the would-arm branch. These carry a non-safe file,
#    so this workflow no-ops — reason MUST stay empty or the revoke step
#    would disarm whatever sibling legitimately armed the PR.
run_case "workflow-bump-no-reason" 0 - ".github/workflows/ci.yml"
run_case "workflow-bump-mixed-no-reason" 0 - ".github/workflows/ci.yml" "docs/changelog.md"
run_case "auth-source-no-reason" 0 - "src/auth/login.ts"

# 5. Regression guard: the carve-out still works.
run_case "plain-docs" 1 - "docs/architecture.md"
run_case "plain-tests" 1 - "tests/test_a.py" "tests/test_b.py"
run_case "specs-no-risk-dir" 1 - \
  "web/tests/e2e/kb/knowledge-base.spec.ts" \
  "web/tests/e2e/marketing/landing.spec.ts" \
  "web/tests/e2e/stripe/stripe-integration.spec.ts"

# 6. Rename bypass: relocating an auth spec OUT of auth/ reports only the
#    destination in .filename. The destination is safe-by-glob, so without
#    scanning previous_filename the move would auto-merge.
RENAMED_FROM="web/tests/e2e/auth/signup.spec.ts"
run_case "rename-auth-out" 0 risk-tier-hold "web/tests/e2e/misc/signup2.spec.ts"
# A rename with no risk path on either end stays safe.
RENAMED_FROM="web/tests/e2e/kb/old.spec.ts"
run_case "rename-benign" 1 - "web/tests/e2e/kb/new.spec.ts"

# 7. DRIFT GUARD. The tier-2 list is a verbatim copy of the sibling gate's
#    `patterns=` block. If they diverge, the two gates disagree about what
#    is risky and this whole fix silently develops holes.
python3 - "$WF" "$SIB" <<'PY' || failed=1
import re, sys
wf, sib = (open(p).read() for p in sys.argv[1:3])
def block(text, name):
    m = re.search(r"^ +%s='(.*?)'\n" % name, text, re.S | re.M)
    if not m:
        sys.exit("FAIL[drift-guard]: could not locate %s=' block" % name)
    return [l.strip() for l in m.group(1).splitlines() if l.strip()]
a, b = block(wf, "risk_tier_overrides"), block(sib, "patterns")
if a != b:
    only_wf = [p for p in a if p not in b]
    only_sib = [p for p in b if p not in a]
    print("FAIL[drift-guard]: tier-2 list has drifted from claude-author-automerge.yml")
    for p in only_wf:
        print("    only in safe-paths-automerge.yml:      %s" % p)
    for p in only_sib:
        print("    only in claude-author-automerge.yml:   %s" % p)
    sys.exit(1)
print("ok[drift-guard] %d patterns identical in both gates" % len(a))
PY

if [ "$failed" -ne 0 ]; then
  echo "FAILED"
  exit 1
fi
echo "All safe-paths risk-tier-hold cases passed."
