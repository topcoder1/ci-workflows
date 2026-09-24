#!/usr/bin/env bash
# Tests for the risk-tier path regex in claude-author-automerge.yml.
#
# The regex list was over-classifying cron-only changes (lesson 2026-05-04
# after wxa_vpn#250; concrete case: wxa_vpn#439 + #441 in 2026-05-20). This
# script bakes the expected matching behavior into version control so future
# narrowings or expansions to the regex list cannot silently regress.
#
# Run from the repo root:
#   bash selftest/test_automerge_risk_patterns.sh
set -euo pipefail

# Mirror the patterns block from .github/workflows/claude-author-automerge.yml.
# Keep these in lock-step — if you edit one, edit the other. The mirror drift
# guard at the bottom of this file fails when they differ.
patterns='^(.*/)?(auth|login|signin|signup|logout|session[s]?|oauth|oauth2|sso|jwt|mfa|totp|webauthn|passkey)(/|\.(py|go|ts|tsx|js|jsx)$|$)
^(.*/)?secret[s]?(/|\.(py|go|ts|tsx|js|jsx)$|$)
^(.*/)?\.env($|\..*)
^(.*/)?keychain.*
^(.*/)?credentials.*
(^|/)\.gitleaks(\.(json|toml|yaml|yml|properties|props|prop|hcl|tfvars|dotenv|env|ini))?(/|$)
(^|/)gitleaks\.toml$
(^|/)\.gitleaksignore$
^(.*/)?migrations(/|$)
.*\.sql$
^(.*/)?(billing|payment[s]?|pricing|invoice[s]?|subscription[s]?|checkout|refund[s]?)(/|\.(py|go|ts|tsx|js|jsx)$|$)
^docs/legal/.*
^docs/decisions/.*
^docs/(marketing|pricing|product-page)([/.-]|$)
(^|/)naf(/|\.(py|go|ts|js)$)
(^|/)main\.go$
(^|/)Dockerfile(\..*)?$
^docker-compose.*\.ya?ml$
(^|/)docker/docker-compose.*\.ya?ml$
^\.github/workflows/.*
^templates/ci-workflows/.*
^\.github/actions?/.*
^\.github/scripts/.*
(^|/)action\.ya?ml$
^\.github/dependabot\.ya?ml$
^\.github/risk-paths\.yml$
^\.github/CODEOWNERS$
^infra/iam/.*
^infra/(deploy|terraform|pulumi|k8s|cloudformation|ansible|digitalocean|scanner-id)/.*
^infra/nginx.*
^infra/.*\.(service|slice|timer|tf|hcl|sh)$
^terraform/.*
^pulumi/.*
^k8s/.*
^fly\.toml$
^deploy/.*
(^|/)deploy.*\.(sh|ya?ml)$
(^|/)ml/predictor\.(py|go|ts|js)$
(^|/)ml/retrain\.(py|go|ts|js)$'

matches() {
  local f=$1
  local pat
  while IFS= read -r pat; do
    pat="${pat#"${pat%%[![:space:]]*}"}"
    [ -z "$pat" ] && continue
    # Mirror of the runtime .audit evidence-SQL skip (wxa_webcat#978):
    # root .audit/ paths are exempt from the SQL pattern ONLY.
    if [ "$pat" = '.*\.sql$' ] && echo "$f" | grep -Eq '^\.audit/'; then
      continue
    fi
    if echo "$f" | grep -Eq "$pat"; then
      return 0
    fi
  done <<< "$patterns"
  return 1
}

# Test cases sourced from shared corpus at selftest/risk_patterns_corpus.txt.
# The corpus is single source of truth for BOTH the GH selftest (this file)
# AND the BB selftest (test_bb_automerge_risk_patterns.sh), so drift between
# claude-author-automerge.yml's regex and bb-automerge.py's HIGH_RISK_PATTERNS
# is caught here.
CORPUS="$(dirname "$0")/risk_patterns_corpus.txt"
[ ! -f "$CORPUS" ] && { echo "FAIL: corpus not found at $CORPUS"; exit 2; }
RISKY=()
SAFE=()
while IFS= read -r line; do
  case "$line" in
    RISKY_BB:*) ;;  # BB-only entries skipped by GH selftest
    RISKY:*) RISKY+=("${line#RISKY: }") ;;
    SAFE:*)  SAFE+=("${line#SAFE: }") ;;
    "#"*|"") ;;
  esac
done < "$CORPUS"

failed=0

echo "Risky paths (must match):"
for p in "${RISKY[@]}"; do
  if matches "$p"; then
    echo "  ✓ $p"
  else
    echo "  ✗ $p (FAILED — should have matched)"
    failed=$((failed + 1))
  fi
done

echo ""
echo "Safe paths (must NOT match):"
for p in "${SAFE[@]}"; do
  if matches "$p"; then
    echo "  ✗ $p (FAILED — should NOT have matched)"
    failed=$((failed + 1))
  else
    echo "  ✓ $p"
  fi
done

# --- main.go opt-out (risk_main_go=false) ---
# Mirrors the runtime filter in claude-author-automerge.yml: when a Go-monorepo
# caller sets risk_main_go=false, the main.go pattern is dropped so dev-tool
# entrypoints (cmd/<tool>/main.go) auto-merge, while every OTHER risk-tier
# pattern still fires. The caller gates its real deployed service entrypoint via
# .github/risk-paths.yml instead.
patterns_no_maingo="$(printf '%s\n' "$patterns" | grep -vF 'main\.go')"

matches_no_maingo() {
  local f=$1 pat
  while IFS= read -r pat; do
    pat="${pat#"${pat%%[![:space:]]*}"}"
    [ -z "$pat" ] && continue
    # Same .audit evidence-SQL skip as matches() — the exemption is
    # independent of the main.go opt-out filter.
    if [ "$pat" = '.*\.sql$' ] && echo "$f" | grep -Eq '^\.audit/'; then
      continue
    fi
    echo "$f" | grep -Eq "$pat" && return 0
  done <<< "$patterns_no_maingo"
  return 1
}

# Sanity: the filter actually removed exactly the main.go line and nothing else.
if [ "$(printf '%s\n' "$patterns" | grep -cF 'main\.go')" != "1" ] || \
   [ -n "$(printf '%s\n' "$patterns_no_maingo" | grep -F 'main\.go' || true)" ]; then
  echo "  ✗ filter did not remove exactly the main.go pattern (FAILED)"
  failed=$((failed + 1))
fi

echo ""
echo "main.go opt-out (risk_main_go=false) — these main.go paths must NOT match:"
for p in "main.go" "cmd/techrecon-regress/main.go" "cmd/wxa-mcp-server/main.go" "internal/foo/main.go"; do
  if matches_no_maingo "$p"; then
    echo "  ✗ $p (FAILED — should NOT match when risk_main_go=false)"
    failed=$((failed + 1))
  else
    echo "  ✓ $p"
  fi
done

echo ""
echo "main.go opt-out — other risk-tier paths must STILL match (filter is main.go-only):"
for p in "internal/auth/security.go" "Dockerfile" "db/migrations/001.sql" "internal/oauth2/server.go"; do
  if matches_no_maingo "$p"; then
    echo "  ✓ $p"
  else
    echo "  ✗ $p (FAILED — should STILL match when only main.go is opted out)"
    failed=$((failed + 1))
  fi
done

# --- gitleaks config: typo negative control (2026-09-24) ---
# The corpus proves the list above gates gitleaks' config and ignore files.
# This proves those verdicts come from the three gitleaks lines and can FAIL:
# misspell `gitleaks` in a copy of the list, and every path below must then
# stop matching. If one still matches, a different pattern is carrying it, and
# the corpus entry proves nothing about the gitleaks lines. The probe paths are
# HARDCODED on purpose — a probe read back out of the list under test agrees
# with that list no matter what it says (see test_classify_env_globs.sh case 3).
gitleaks_paths=(.gitleaks.toml sub/.gitleaks.toml .gitleaks.json services/api/.gitleaks.json
  .gitleaks.toml/.keep .gitleaks.yaml .gitleaks .gitleaks/config.toml
  gitleaks.toml .github/gitleaks.toml .gitleaksignore services/api/.gitleaksignore)
patterns_typo="$(printf '%s\n' "$patterns" | sed 's/gitleaks/gitlaeks/g')"

matches_typo() {
  local f=$1 pat
  while IFS= read -r pat; do
    pat="${pat#"${pat%%[![:space:]]*}"}"
    [ -z "$pat" ] && continue
    echo "$f" | grep -Eq "$pat" && return 0
  done <<< "$patterns_typo"
  return 1
}

echo ""
echo "gitleaks typo negative control — must match the list, and NOT a copy with 'gitleaks' misspelled:"
# Sanity: the mutation rewrote exactly the three gitleaks lines. Rewriting
# none would let every check below pass vacuously.
if [ "$(printf '%s\n' "$patterns" | grep -c 'gitleaks')" != "3" ] || \
   [ -n "$(printf '%s\n' "$patterns_typo" | grep -F 'gitleaks' || true)" ]; then
  echo "  ✗ the typo did not rewrite exactly the three gitleaks patterns (FAILED)"
  failed=$((failed + 1))
fi
for p in "${gitleaks_paths[@]}"; do
  if matches "$p" && ! matches_typo "$p"; then
    echo "  ✓ $p"
  else
    echo "  ✗ $p (FAILED — must match the list and NOT the typo'd copy)"
    failed=$((failed + 1))
  fi
done

# --- Mirror drift guard ---
# Every case above runs against the hardcoded COPY at the top of this file,
# never against the workflow. test_safe_paths_risk_tier_hold.sh pins
# safe-paths' tier-2 copy to claude-author-automerge.yml, but nothing pinned
# this one. So a pattern narrowed in both workflow copies, or one added here
# and never shipped, passed every corpus case while the shipped gate stayed
# open. Compare this list line for line with the shipped patterns= block.
echo ""
echo "Mirror drift guard — this list must equal claude-author-automerge.yml's patterns= block:"
if ! MIRROR="$patterns" python3 - "$(dirname "$0")/../.github/workflows/claude-author-automerge.yml" <<'PY'
import os, re, sys
text = open(sys.argv[1]).read()
m = re.search(r"^ +patterns='(.*?)'\n", text, re.S | re.M)
if not m:
    sys.exit("  could not locate the patterns=' block in claude-author-automerge.yml")
shipped = [l.strip() for l in m.group(1).splitlines() if l.strip()]
mirror = [l.strip() for l in os.environ["MIRROR"].splitlines() if l.strip()]
if shipped != mirror:
    for p in mirror:
        if p not in shipped:
            print("  only in this selftest:              %s" % p)
    for p in shipped:
        if p not in mirror:
            print("  only in claude-author-automerge.yml: %s" % p)
    if sorted(shipped) == sorted(mirror):
        print("  same patterns in a different order (the first match names the pattern in the blocked-PR comment)")
    sys.exit(1)
print("  ✓ %d patterns identical" % len(shipped))
PY
then
  echo "  ✗ this list has drifted from claude-author-automerge.yml (FAILED)"
  failed=$((failed + 1))
fi

echo ""
if [ "$failed" -gt 0 ]; then
  echo "FAIL: $failed case(s) regressed."
  exit 1
fi
echo "OK: all risk-pattern cases pass."
