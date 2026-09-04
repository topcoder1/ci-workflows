#!/usr/bin/env bash
# Guards classify.mjs's list-shape validation on the CLASS lists.
#
# A scalar where a list belongs is a fail-OPEN, and a silent one: JS iterates a
# string per-character, so `sensitive: 'cmd/**'` becomes the patterns
# 'c','m','d','/','*','*'. None trips the bracket or negation guards, and none
# matches a real path — the class just stops gating, with no error anywhere.
#
# This is the gating-class twin of the exclude.<cls> guard covered by
# test_classify_exclude.sh (case 13). That one was caught in review on
# ci-workflows#145, which is what surfaced this pre-existing one.
#
# The guard hard-fails any repo it catches, so it was fleet-audited first: all
# 140 repos across topcoder1 + whois-api-llc carry a risk-paths.yml and every
# class value is a real list. Eight have an EMPTY `sensitive:` key (null, not a
# scalar) — case 3 pins that those stay legal.
#
# Run from the repo root:
#   bash selftest/test_classify_list_shape.sh
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

expect_fail() { # expect_fail <yaml> <needle> <description>
  printf '%s' "$1" > "$tmp/repo/.github/risk-paths.yml"
  set +e
  out=$(cd "$tmp/repo" && echo "README.md" | node "$tmp/classify.mjs" 2>&1)
  rc=$?
  set -e
  if [ "$rc" -ne 0 ] && echo "$out" | grep -q "$2"; then
    echo "✓ $3"
  else
    echo "✗ $3: expected nonzero exit + '$2', got rc=$rc:"
    echo "$out" | sed 's/^/    /'
    failed=1
  fi
}

expect() { # expect <want> <got> <description>
  if [ "$2" = "$1" ]; then
    echo "✓ $3"
  else
    echo "✗ $3: want '$1', got '$2'"
    failed=1
  fi
}

classify() { printf '%s\n' "$@" | (cd "$tmp/repo" && node "$tmp/classify.mjs"); }

# 1. A scalar gating class fails closed rather than silently un-gating.
expect_fail "blocked: []
sensitive: 'cmd/svc/**'
" "must be a LIST" "scalar sensitive: fails closed"

# 2. always_review is validated too — classify.mjs never matches against it,
#    but codex-gate.mjs consumes it with the same per-character hazard.
expect_fail "blocked: []
always_review: 'internal/store/migrations.go'
" "must be a LIST" "scalar always_review: fails closed"

# 3. An EMPTY class key stays legal. Eight real repos ship one today
#    (whois-api-qa, app-factory, wxa-graph, usdev, netsniper,
#    domains_collector, dnssniper, ProfessionalServices) — hard-failing those
#    would take out their whole classify step for no safety gain.
cat > "$tmp/repo/.github/risk-paths.yml" <<'YAML'
blocked: []
sensitive:
safe_test:
  - '**/*_test.go'
YAML
expect safe_test "$(classify foo_test.go)" "empty sensitive: key stays legal (8 real repos rely on it)"
expect standard "$(classify foo.go)" "empty sensitive: key gates nothing, as before"

# 4. THE FAIL-OPEN THIS PREVENTS: with the scalar accepted, 'cmd/svc/main.go'
#    would classify `standard` instead of `sensitive` — auto-merge eligible.
#    Written as a proper list, it gates correctly.
cat > "$tmp/repo/.github/risk-paths.yml" <<'YAML'
blocked: []
sensitive:
  - 'cmd/svc/**'
YAML
expect sensitive "$(classify cmd/svc/main.go)" "a real list gates correctly (the behavior the scalar silently lost)"

# 5. A clean rules file is unaffected.
expect standard "$(classify README.md)" "unmatched path still falls back to standard"

exit "$failed"
