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
patterns='^(.*/)?(auth|login|signin|signup|logout|session[s]?|oauth|oauth2|sso|jwt|mfa|totp|webauthn|passkey)(/|\.(py|go|ts|tsx|js|jsx)$|$)
^(.*/)?secret[s]?(/|\.(py|go|ts|tsx|js|jsx)$|$)
^(.*/)?\.env($|\..*)
^(.*/)?keychain.*
^(.*/)?credentials.*
^(.*/)?migrations(/|$)
.*\.sql$
^(.*/)?(billing|payment[s]?|pricing|invoice[s]?|subscription[s]?|checkout|refund[s]?)(/|\.(py|go|ts|tsx|js|jsx)$|$)
^docs/legal/.*
^docs/decisions/.*
^docs/(marketing|pricing|product-page)([/.-]|$)
(^|/)naf(/|\.(py|go|ts|js)$)
(^|/)main\.go$
(^|/)Dockerfile(\..*)?$
(^|/)[^/]*\.Dockerfile$
^docker-compose.*\.ya?ml$
(^|/)docker/docker-compose.*\.ya?ml$
(^|/)docker-compose[^/]*\.ya?ml$
(^|/)compose(\.[^/]*)?\.ya?ml$
^\.github/workflows/.*
^templates/ci-workflows/.*
^\.github/actions?/.*
^\.github/scripts/.*
(^|/)action\.ya?ml$
^\.github/dependabot\.ya?ml$
^\.github/risk-paths\.yml$
^(docs/)?CODEOWNERS$
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

# --- Name-gated files: typo negative controls (2026-09-25) ---
# The corpus proves this file's copy of the list gates compose files,
# suffix-style Dockerfiles and CODEOWNERS. These controls run against the
# SHIPPED patterns= block instead, read from claude-author-automerge.yml, so
# narrowing those lines in both workflows (with this copy untouched) fails
# here too. Each verdict must come from a line naming the file, and can FAIL:
# misspell the name in a copy of the list, and every probe must then stop
# matching. If one still matches, another pattern (^deploy/.*, say) is
# carrying it. The probes are HARDCODED on purpose: a probe read back out of
# the list under test agrees with that list no matter what it says.
shipped=$(python3 - "$(dirname "$0")/../.github/workflows/claude-author-automerge.yml" <<'PY'
import re, sys
m = re.search(r"^ +patterns='(.*?)'\n", open(sys.argv[1]).read(), re.S | re.M)
if not m:
    sys.exit("could not locate the patterns= block in claude-author-automerge.yml")
print("\n".join(l.lstrip() for l in m.group(1).splitlines() if l.strip()))
PY
) || shipped=""
if [ -z "$shipped" ]; then
  echo "  ✗ could not read the shipped patterns= block (FAILED)"
  failed=$((failed + 1))
fi

matches_in() {
  local list=$1 f=$2 pat
  while IFS= read -r pat; do
    pat="${pat#"${pat%%[![:space:]]*}"}"
    [ -z "$pat" ] && continue
    echo "$f" | grep -Eq "$pat" && return 0
  done <<< "$list"
  return 1
}

# typo_control <name> <misspelling> <lines naming it> <probe>...
typo_control() {
  local name=$1 typo=$2 lines=$3 copy p
  shift 3
  copy="$(printf '%s\n' "$shipped" | sed "s/$name/$typo/g")"
  # Sanity: the typo rewrote exactly the lines naming the file. Rewriting
  # none would let every check below pass vacuously.
  if [ "$(printf '%s\n' "$shipped" | grep -c "$name")" != "$lines" ] || \
     [ -n "$(printf '%s\n' "$copy" | grep -F "$name" || true)" ]; then
    echo "  ✗ the typo did not rewrite exactly the $lines '$name' patterns (FAILED)"
    failed=$((failed + 1))
  fi
  for p in "$@"; do
    if matches_in "$shipped" "$p" && ! matches_in "$copy" "$p"; then
      echo "  ✓ $p"
    else
      echo "  ✗ $p (FAILED — must match the shipped list and NOT the copy with '$name' misspelled)"
      failed=$((failed + 1))
    fi
  done
}

echo ""
echo "Name-gated files — must match the SHIPPED list, and NOT a copy with the name misspelled:"
# One probe per corpus case these lines exist for, so narrowing a shipped line
# to drop any of them (a .yml, a dotless suffix, an empty stem) fails here.
typo_control compose cmopose 4 compose.yaml compose.yml compose.override.yaml \
  compose.prod.yml services/api/compose.yaml services/api/docker-compose.yml \
  services/api/docker-compose.yaml services/api/docker-compose-dev.yml \
  monitoring/docker-compose.monitoring.yml tests/integration/docker-compose.yml
typo_control Dockerfile Dcokerfile 2 api.Dockerfile docker/proxy.Dockerfile \
  tests/.Dockerfile tests/images/api-prod.Dockerfile
typo_control CODEOWNERS CDOEOWNERS 2 CODEOWNERS docs/CODEOWNERS

# The shipped list must still leave each near-miss alone, so WIDENING a
# shipped line (a `.*` that crosses `/`, a dropped anchor) fails here too,
# with this file's copy untouched. Hardcoded, like the probes above.
echo ""
echo "Name-gated near-misses — the SHIPPED list must NOT match these:"
for p in docs/docker-compose-guide.md docs/compose.md composer.yaml recompose.yml \
  services/docker-compose/x.yml docs/compose.examples/example.yml \
  tests/fixtures/invalid-docker-compose.yml \
  docs/api.Dockerfile.md tests/regression/test_dockerfile_model_deps_pinned.py \
  src/CODEOWNERS docs/team/CODEOWNERS docs/CODEOWNERS.md; do
  if matches_in "$shipped" "$p"; then
    echo "  ✗ $p (FAILED — the shipped list must NOT match this near-miss)"
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

echo ""
if [ "$failed" -gt 0 ]; then
  echo "FAIL: $failed case(s) regressed."
  exit 1
fi
echo "OK: all risk-pattern cases pass."
