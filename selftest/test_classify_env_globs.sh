#!/usr/bin/env bash
# Pins the caller-side `blocked: ['**/.env*']` contract through classify.mjs.
#
# WHY THIS EXISTS
#
# On 2026-05-24 (#74) the `blocked:` .env glob was replaced fleet-wide with ten
# exact names — .env, .env.local, .env.{development,production,staging,test}
# and their .local twins. That enumeration missed .env.prod, .env.dev, .env.ci,
# .env.qa, .env.uat, .env.sandbox, .env.aws and .env.secret, which silently
# fell through to `standard` in 30 repos for eleven weeks.
#
# It was inert for auto-merge — the central risk-tier regex in
# claude-author-automerge.yml is ANDed with this verdict and stayed broad
# (pinned by risk_patterns_corpus.txt). But in repos whose .github/CODEOWNERS
# mirrors blocked:, the same names went unowned. whois-api-llc/wxa-secrets is
# the credentials store and gates on a REQUIRED codeowner-gate; ten names were
# unowned there, so a PR adding .env.prod cleared it with no code-owner
# approval.
#
# The repo-local mirror test could not catch it: it derived its probe paths
# FROM risk-paths.yml, so the contract narrowed along with the list and the
# suite stayed green throughout. That is the failure mode this file guards —
# a test whose expectations come from the artifact under test proves nothing.
# The expected classes below are HARDCODED and must stay that way.
#
# Case 3 is the point of the file: a typo'd glob still parses, still classifies
# every path, and still passes any test that reads the glob back out of the
# same file. Only a hardcoded expectation catches it.
#
# Run from the repo root:
#   bash selftest/test_classify_env_globs.sh
set -euo pipefail

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# classify.mjs imports its deps from classifier-deps.mjs sitting beside it —
# the same committed, version-pinned bundle pr-classify.yml fetches into
# .github/scripts/. Copying both mirrors the workflow's on-disk layout exactly,
# and replaces an `npm install yaml@2 minimatch@10` that made this test both
# slower and dependent on whatever those majors resolved to that day.
cp .github/scripts/classify.mjs .github/scripts/classifier-deps.mjs "$tmp/"

mkdir -p "$tmp/repo/.github"
failed=0

write_rules() { # write_rules <env-glob>
  cat > "$tmp/repo/.github/risk-paths.yml" <<YAML
blocked:
  - '$1'
  - '**/secrets*'
sensitive: []
safe_test:
  - '**/*_test.go'
YAML
}

# classify <file> — echoes the computed class.
classify() { printf '%s\n' "$1" | (cd "$tmp/repo" && node "$tmp/classify.mjs"); }

expect() { # expect <want> <got> <description>
  if [ "$2" = "$1" ]; then
    echo "✓ $3"
  else
    echo "✗ $3: want '$1', got '$2'"
    failed=1
  fi
}

# ── Case 1: the shipped glob blocks every .env variant ─────────────────────
# Hardcoded on purpose — see header. Each name below is one the 2026-05-24
# enumeration missed, plus the two it did cover (as controls) and a nested
# path (the '**/' prefix must match at depth AND at the root).
write_rules '**/.env*'
for f in \
  .env \
  .env.local \
  .env.production \
  .env.prod \
  .env.dev \
  .env.ci \
  .env.qa \
  .env.uat \
  .env.sandbox \
  .env.aws \
  .env.secret \
  .env.example \
  .env.template \
  backend/.env \
  backend/.env.secret \
  services/api/config/.env.prod
do
  expect blocked "$(classify "$f")" "blocked: $f"
done

# ── Case 2: non-.env paths are unaffected ──────────────────────────────────
# Guards the opposite error — a glob so broad it swallows ordinary files.
# 'environment.ts' and 'src/env/config.go' are the near-misses that a
# careless '**/*env*' would wrongly gate.
for f in \
  README.md \
  src/app.py \
  environment.ts \
  src/env/config.go \
  docs/env-vars.md
do
  expect standard "$(classify "$f")" "standard: $f"
done

# ── Case 3: NEGATIVE CONTROL — a typo'd glob must NOT classify as blocked ──
# This is the case the repo-local mirror tests could not express. A test that
# reads the glob out of risk-paths.yml and probes with it agrees with itself
# no matter what the glob says; '.evn' would sail through. The expectation
# here is hardcoded, so the typo surfaces as a failure.
#
# If this case ever passes as 'blocked', the test has stopped discriminating
# and every assertion above it is worthless.
write_rules '**/.evn*'
expect standard "$(classify .env.prod)" "typo'd glob '**/.evn*' does NOT gate .env.prod"
expect standard "$(classify .env)" "typo'd glob '**/.evn*' does NOT gate .env"

# ── Case 4: exclude: may not subtract from blocked ─────────────────────────
# The template carve-out attempted in #74 is unexpressible caller-side:
# classify.mjs fails CLOSED on `exclude.blocked` rather than honouring it.
# Pinned here so the .env carve-out cannot be reintroduced by that route.
cat > "$tmp/repo/.github/risk-paths.yml" <<'YAML'
blocked:
  - '**/.env*'
exclude:
  blocked:
    - '**/.env.example'
YAML
if printf '%s\n' .env.example | (cd "$tmp/repo" && node "$tmp/classify.mjs") >/dev/null 2>&1; then
  echo "✗ exclude.blocked was accepted — the blocked tier must refuse subtraction"
  failed=1
else
  echo "✓ exclude.blocked is refused (fails closed)"
fi

if [ "$failed" -ne 0 ]; then
  echo "FAIL: classify .env glob contract regressed"
  exit 1
fi
echo "All classify .env-glob cases passed."
