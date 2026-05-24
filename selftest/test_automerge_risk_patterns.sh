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

# Cases the regex MUST flag as risky (manual click-merge).
RISKY=(
  "src/auth/login.py"
  "internal/auth/security.go"            # auth segment, Go layout
  "internal/oauth2/server.go"            # oauth2 alternation — wxa-mcp-server#193/#197 gap (2026-05-24)
  "internal/oauth2/handler.go"
  "pkg/oauth2/token.go"
  "main.go"                              # Go entrypoint at root — wxa-mcp-server#193 gap
  "cmd/server/main.go"                   # Go entrypoint under cmd/
  "cmd/wxa-mcp-server/main.go"
  # Auth-adjacent variants (sibling-gap audit, 2026-05-24).
  # NOTE: Pattern is path-segment-anchored, not filename-prefix. So
  # `internal/signin/handler.go` matches (signin is a segment) but
  # `controllers/sessions_controller.rb` does NOT (sessions is a
  # filename prefix, not a segment). Per-repo Rails/Django/Express
  # conventions belong in caller's risk-paths.yml.
  "internal/signin/handler.go"
  "internal/signup/form.go"
  "src/logout/handler.go"
  "internal/sessions/store.go"           # sessions (plural) — Go convention
  "internal/jwt/sign.go"
  "services/mfa/verify.py"
  "app/totp/generate.go"
  "lib/webauthn/register.go"
  "internal/passkey/store.go"
  # Billing-adjacent variants
  "internal/subscription/manager.go"
  "app/subscriptions/cancel.rb"
  "api/checkout/session.go"
  "services/refund/issuer.py"
  "api/refunds/handler.go"
  # Secret (singular) variants
  "internal/secret/manager.go"
  "config/secret/keystore.go"
  "secrets/api-keys.json"
  ".env.production"
  "src/keychain_helpers.py"
  "credentials.py"
  "migrations/031_cdn_operator.sql"
  "src/db/schema.sql"
  "billing/invoices.py"
  "Dockerfile"
  "docker-compose.yml"
  ".github/workflows/deploy.yml"
  ".github/risk-paths.yml"
  ".github/CODEOWNERS"
  "infra/iam/scanner-role.json"          # IAM policy
  "infra/iam/wxa-vpn-api-policy.json"
  "infra/terraform/main.tf"              # IaC under infra/
  "infra/digitalocean/systemd/wxa.service"
  "infra/scanner-id/identity.json"
  "infra/nginx/honeypot.conf"
  "infra/nginx-checkip-vhost.conf"       # top-level nginx config
  "infra/wxa-vpn-api.service"            # systemd unit
  "infra/wxa-workload.slice"
  "infra/wxa-gt-builder.timer"
  "infra/some.tf"
  "infra/deploy-netflow-cron.sh"         # shell script
  "infra/setup-actions-runner.sh"
  "infra/deploy-systemd.sh"
  "terraform/main.tf"
  "pulumi/index.ts"
  "k8s/deployment.yaml"
  "fly.toml"
  "deploy/prod.sh"
  "deploy.sh"
  "deploy-staging.yml"
)

# Cases the regex MUST allow through to auto-merge (the historical false positives).
SAFE=(
  "src/wxa_vpn/api/routes.py"
  "tests/test_anything.py"
  "docs/data-dictionary.md"
  "main_test.go"                         # adjacent to main.go but a test file
  "internal/foo/main_test.go"
  "internal/oauth2.md"                   # doc file mentioning oauth2 — pattern needs trailing / or end
  "cmd/server/mainview.go"               # starts with "main" but not the literal main.go
  "src/oauth2helper.go"                  # oauth2 substring but not a path segment
  # Substrings that look auth/billing-ish but aren't path segments — must NOT over-block
  "internal/sessionsutil.go"             # "sessionsutil" segment, not "sessions"
  "pkg/jwtutil.go"                       # "jwtutil" not "jwt"
  "lib/passkeystore.go"                  # "passkeystore" not "passkey"
  "internal/totps.go"                    # "totps" — neither "totp/" nor "totp$"
  "docs/checkout-flow.md"                # "checkout-flow.md" not literal "checkout"
  "lib/subscriber.go"                    # "subscriber" not "subscription"
  "internal/secretly.go"                 # "secretly" not "secret"
  "tests/test_authorization_logic.py"    # "test_authorization_logic.py" — not literal "auth"
  "docs/signin-flow.md"                  # doc with "signin-flow" substring
  "scripts/run_analysis.py"
  "infra/crontabs/wxa-scanner.crontab"   # cron schedule — wxa_vpn#439 case
  "infra/crontabs/wxa-scanner-active.crontab"
  "infra/crontabs/README.md"
  "infra/crontabs/wxa-scanner-slow.crontab"
  "infra/aws-scanner-setup.md"           # runbook docs
  "infra/crontab.example"                # example config
  "infra/README.md"
)

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

echo ""
if [ "$failed" -gt 0 ]; then
  echo "FAIL: $failed case(s) regressed."
  exit 1
fi
echo "OK: all risk-pattern cases pass."
