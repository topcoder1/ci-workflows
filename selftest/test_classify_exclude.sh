#!/usr/bin/env bash
# Guards classify.mjs's `exclude:` support.
#
# Why the feature exists: a repo gating its deployed service entrypoint with
# 'cmd/<svc>/**' under sensitive: cannot let a tests-only diff in that package
# auto-merge, because classify() returns the FIRST matching class and sensitive
# is checked before safe_test. Observed on whois-api-llc/techrecon#847 — a
# two-file, tests-only flake fix classified risk:sensitive and needed a manual
# click.
#
# Why not just enumerate the production files positively under sensitive:
# (which is what the negation guard's error message steers authors toward):
# that fails OPEN. A NEW file added to the package matches nothing and lands on
# the `standard` fallback — auto-merge eligible, no Codex review, on the
# deployed entrypoint. Case 2 below is that exact scenario and is the reason
# this feature exists rather than the enumeration.
#
# Run from the repo root:
#   bash selftest/test_classify_exclude.sh
set -euo pipefail

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# classify.mjs resolves its deps from its own location, so install them next
# to a copy in the temp dir — same versions pr-classify.yml pins.
cp .github/scripts/classify.mjs "$tmp/classify.mjs"
(cd "$tmp" && npm install --no-save --silent yaml@2 minimatch@10 >/dev/null 2>&1)

mkdir -p "$tmp/repo/.github"
failed=0

# The techrecon shape: a broad sensitive glob over the deployed entrypoint,
# the fleet-standard safe_test glob, and an exclusion carving tests back out.
write_rules() {
  cat > "$tmp/repo/.github/risk-paths.yml" <<'YAML'
blocked: []
sensitive:
  - 'cmd/svc/**'
safe_test:
  - '**/*_test.go'
exclude:
  sensitive:
    - 'cmd/svc/**/*_test.go'
YAML
}

# classify <file...> — echoes the computed class.
classify() { printf '%s\n' "$@" | (cd "$tmp/repo" && node "$tmp/classify.mjs"); }

expect() { # expect <want> <got> <description>
  if [ "$2" = "$1" ]; then
    echo "✓ $3"
  else
    echo "✗ $3: want '$1', got '$2'"
    failed=1
  fi
}

write_rules

# 1. The motivating case: a tests-only diff in the gated package is exempted
#    and falls through to safe_test.
expect safe_test "$(classify cmd/svc/characterization_boot_test.go)" \
  "tests in the gated package fall through to safe_test"

# 2. THE POINT OF THE FEATURE: a NEW production file in the same package is
#    still gated. Positive enumeration of the production files would classify
#    this 'standard' — auto-merge eligible on the deployed entrypoint.
expect sensitive "$(classify cmd/svc/handlers.go)" \
  "a NEW production file in the gated package stays sensitive (no fail-open)"

# 3. Existing production files are unaffected.
expect sensitive "$(classify cmd/svc/main.go)" "existing production file stays sensitive"

# 4. A mixed test+production PR still gates on the production file.
expect sensitive "$(classify cmd/svc/foo_test.go cmd/svc/main.go)" \
  "mixed test+production PR still classifies sensitive"

# 5. THE INVARIANT: exclusions are case-SENSITIVE even though sensitive: is
#    matched nocase. Folding the exclusion would let a case variant escape a
#    gate its lowercase twin still hits — i.e. folding would REMOVE gating,
#    which classify()'s documented invariant forbids.
expect sensitive "$(classify cmd/svc/FOO_TEST.GO)" \
  "case variant is NOT excluded (folding may only add gating, never remove it)"

# 6. Paths outside the gated package are untouched by the exclusion.
expect safe_test "$(classify internal/detect/foo_test.go)" "unrelated test file still safe_test"
expect standard "$(classify internal/detect/foo.go)" "unrelated source file still standard"

# 7. An exclusion skips the WHOLE class, so a second sensitive pattern cannot
#    silently re-gate an exempted path.
cat > "$tmp/repo/.github/risk-paths.yml" <<'YAML'
blocked: []
sensitive:
  - 'cmd/svc/**'
  - '**/*.go'
safe_test:
  - '**/*_test.go'
exclude:
  sensitive:
    - 'cmd/svc/**/*_test.go'
YAML
expect safe_test "$(classify cmd/svc/foo_test.go)" \
  "exclusion skips the whole class (a second sensitive pattern cannot re-gate)"

# 8. Absent `exclude:` — behavior is exactly as before the feature.
cat > "$tmp/repo/.github/risk-paths.yml" <<'YAML'
blocked: []
sensitive:
  - 'cmd/svc/**'
safe_test:
  - '**/*_test.go'
YAML
expect sensitive "$(classify cmd/svc/foo_test.go)" \
  "without exclude:, a gated-package test file classifies sensitive (unchanged)"

# --- fail-closed guards on the exclusion lists themselves -------------------

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

# 9. Negation inside an exclusion inverts it into "exclude everything EXCEPT
#    this", silently un-gating the class. Banned, like in the gating classes.
expect_fail "blocked: []
exclude:
  sensitive:
    - '!cmd/svc/**/*_test.go'
" "negation" "negation in an exclusion fails closed"

# 10. Brackets are the silent-dead-gate footgun here too — a dead exclusion
#     leaves paths gated, but the author believes otherwise.
expect_fail "blocked: []
exclude:
  sensitive:
    - 'cmd/svc/[id]/foo.go'
" "bracket" "bracket in an exclusion fails closed"

# 11. A typo'd class key would exclude nothing while reading as if it worked.
expect_fail "blocked: []
exclude:
  sensitve:
    - 'cmd/svc/**/*_test.go'
" "unknown class" "unknown class key under exclude: fails closed"

# 12. Subtracting from `blocked` is refused outright. It is the hardest tier
#     and carries the secrets/Dockerfile/deploy families; a stray '**' in an
#     exclusion there would silently un-gate all of them.
expect_fail "blocked:
  - '**/.env'
exclude:
  blocked:
    - '**/.env.example'
" "may not subtract from 'blocked'" "exclude: under blocked: fails closed"

# 13. A scalar where a list belongs is a fail-OPEN, not a syntax error: JS
#     iterates a string per-character, so every character becomes a pattern
#     and '*' among them matches any root-level path. Caught in review on the
#     PR that introduced exclude: (ci-workflows#145).
expect_fail "blocked: []
sensitive:
  - 'cmd/svc/**'
exclude:
  sensitive: 'cmd/svc/**/*_test.go'
" "must be a LIST" "scalar exclude.<cls>: value fails closed"

# 14. An empty exclusion list is legitimate (no exclusions) and must not fail.
cat > "$tmp/repo/.github/risk-paths.yml" <<'YAML'
blocked: []
sensitive:
  - 'cmd/svc/**'
exclude:
  sensitive:
YAML
expect sensitive "$(classify cmd/svc/main.go)" "empty exclusion list is a no-op, not an error"

# 15. Wrong shape (a list instead of a class→patterns mapping).
expect_fail "blocked: []
exclude:
  - 'cmd/svc/**/*_test.go'
" "must be a mapping" "exclude: as a list fails closed"

exit "$failed"
