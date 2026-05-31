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
# Keep these in lock-step — if you edit one, edit the other.
patterns='^(.*/)?(auth|login|signin|signup|logout|session[s]?|oauth|oauth2|sso|jwt|mfa|totp|webauthn|passkey)(/|$)
^(.*/)?secret[s]?(/|$)
^(.*/)?\.env($|\..*)
^(.*/)?keychain.*
^(.*/)?credentials.*
^(.*/)?migrations(/|$)
.*\.sql$
^(.*/)?(billing|payment[s]?|pricing|invoice[s]?|subscription[s]?|checkout|refund[s]?)(/|$)
(^|/)naf(/|\.(py|go|ts|js)$)
(^|/)main\.go$
(^|/)Dockerfile(\..*)?$
^docker-compose.*\.ya?ml$
^\.github/workflows/.*
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
(^|/)deploy.*\.(sh|ya?ml)$'

matches() {
  local f=$1
  local pat
  while IFS= read -r pat; do
    pat="${pat#"${pat%%[![:space:]]*}"}"
    [ -z "$pat" ] && continue
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

echo ""
if [ "$failed" -gt 0 ]; then
  echo "FAIL: $failed case(s) regressed."
  exit 1
fi
echo "OK: all risk-pattern cases pass."
