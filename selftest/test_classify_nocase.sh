#!/usr/bin/env bash
# Guards classify.mjs's case-insensitive path matching.
#
# minimatch defaults to case-SENSITIVE, so a lowercase-authored pattern
# silently misses real-world case variants. '**/secrets*' in wxa-jake-ai's
# `blocked:` matched 'docs/secrets.md' but NOT 'docs/SECRETS.md' — so the
# production secrets ROTATION RUNBOOK, whose shell snippets are pasted
# against prod hosts, fell through to 'docs/**' and classified risk:trivial
# ("zero runtime impact"), auto-merge-eligible. wxa-jake-ai#875 had to be
# opened as a draft to dodge it; the repo-side exact-case gate is
# wxa-jake-ai#877. classify.mjs now matches with {nocase:true}; this test
# bakes that into version control.
#
# Fleet evidence gathered before shipping (2026-07-14): every blob in all 45
# repos carrying a risk-paths.yml (18,604 files) was classified twice, nocase
# off vs on. ZERO downgrades fleet-wide; exactly 2 upgrades, both real secrets
# docs (wxa-jake-ai 'docs/SECRETS.md', inbox_superpilot
# 'docs/SECRETS_ROTATION.md').
#
# Run from the repo root:
#   bash selftest/test_classify_nocase.sh
set -euo pipefail

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# classify.mjs resolves its deps from its own location, so install them next
# to a copy in the temp dir — same versions pr-classify.yml pins.
cp .github/scripts/classify.mjs "$tmp/classify.mjs"
(cd "$tmp" && npm install --no-save --silent yaml@2 minimatch@10 >/dev/null 2>&1)

mkdir -p "$tmp/repo/.github"
failed=0

# Assert `expected` is the class for `file` under the rules already written
# to $tmp/repo/.github/risk-paths.yml.
expect() {
  local file="$1" expected="$2" desc="$3" got
  got=$(cd "$tmp/repo" && echo "$file" | node "$tmp/classify.mjs")
  if [ "$got" = "$expected" ]; then
    echo "✓ $desc"
  else
    echo "✗ $desc — expected '$expected' for '$file', got '$got'"
    failed=1
  fi
}

# The real wxa-jake-ai shape that produced the bug: a lowercase 'secrets' glob
# in blocked:, and a docs/** + **/*.md catch-all in trivial:. Before nocase,
# 'docs/SECRETS.md' skipped blocked and landed in trivial.
cat > "$tmp/repo/.github/risk-paths.yml" <<'YAML'
blocked:
  - '**/secrets*'
  - 'Dockerfile'
  - '**/.env'
sensitive:
  - 'src/lib/server/auth.ts'
trivial:
  - '**/*.md'
  - 'docs/**'
YAML

# 1. THE BUG. This is the whole point of the file.
expect "docs/SECRETS.md" blocked "uppercase SECRETS.md is blocked by a lowercase 'secrets' glob"

# 2. The pre-existing lowercase behavior must not regress.
expect "docs/secrets.md" blocked "lowercase secrets.md still blocked"

# 3. PRECEDENCE — the property that makes nocase fail-SAFE rather than just
#    fail-safe-in-practice. 'docs/SECRETS.md' matches BOTH the blocked glob
#    (only under case-folding) and the trivial 'docs/**' glob. PATTERN_CLASSES
#    is ordered most-gated-first, so blocked must win. If someone ever
#    reorders that list, case-folding starts handing files to trivial and this
#    test fires.
expect "docs/SECRETS.md" blocked "blocked wins over a same-file trivial match (ordering intact)"

# 4. Mixed case, not just upper — real repos have 'Secrets.yaml'.
expect "config/Secrets.yaml" blocked "mixed-case Secrets.yaml is blocked"

# 5. Dockerfile case variants — latent in 44/45 fleet repos (no live hit yet).
expect "DOCKERFILE" blocked "DOCKERFILE is blocked by the 'Dockerfile' pattern"

# 6. nocase must not swallow genuinely unrelated paths into blocked.
expect "docs/PLAN.md" trivial "an ordinary doc is still trivial"
expect "src/lib/server/auth.ts" sensitive "a sensitive path is unaffected"
expect "src/lib/server/thing.ts" standard "an unmatched path still falls back to standard"

# 7. NO FAIL-OPEN: case-folding must never move a file OUT of blocked or
#    sensitive. Construct the adversarial case directly — a path whose ONLY
#    exact-case match is blocked, plus a trivial glob that would swallow it if
#    class ordering or matching ever inverted.
cat > "$tmp/repo/.github/risk-paths.yml" <<'YAML'
blocked:
  - 'infra/PROD_KEYS.md'
trivial:
  - '**/*.md'
YAML
expect "infra/PROD_KEYS.md" blocked "an exact-case blocked entry is not downgraded by a trivial glob"
expect "infra/prod_keys.md" blocked "...and its lowercase variant is caught too, not left standard/trivial"

# 8. The '.env' family keeps working (enumerated, not globbed, in most repos).
cat > "$tmp/repo/.github/risk-paths.yml" <<'YAML'
blocked:
  - '**/.env'
trivial:
  - '**/*.md'
YAML
expect ".env" blocked ".env still blocked"
expect "app/.ENV" blocked "uppercase .ENV is blocked too"

# 9. THE ASYMMETRY — case-folding is applied to blocked/sensitive ONLY, and
#    that is deliberate. Folding the safe/trivial classes is a fail-OPEN: a
#    path matching nothing gets the strict 'standard' fallback, and folding
#    would hand it to an auto-merge-eligible class instead. On GitHub's
#    case-sensitive filesystem 'Tests/release.py' is a DISTINCT path from
#    'tests/release.py', so a lowercase 'tests/**' must not claim it.
#
#    Class precedence does NOT protect against this — it only breaks ties when
#    a blocked/sensitive pattern also matches, and here none does. These cases
#    are about files a PR ADDS, which no audit of existing files can catch.
#    (Raised as P1 by codex pre-review on the change that introduced folding.)
cat > "$tmp/repo/.github/risk-paths.yml" <<'YAML'
blocked:
  - '**/secrets*'
safe_test:
  - 'tests/**'
safe_config:
  - '.vscode/**'
trivial:
  - 'docs/**'
YAML
expect "tests/release.py" safe_test "exact-case safe_test path still matches"
expect "Tests/release.py" standard "case-variant of a safe_test glob stays standard, NOT safe_test"
expect "docs/notes.md" trivial "exact-case trivial path still matches"
expect "DOCS/deploy-prod.sh" standard "case-variant of a trivial glob stays standard, NOT trivial"
expect ".VSCode/tasks.json" standard "case-variant of a safe_config glob stays standard"
# ...while the gating classes DO still fold, in the same rules file.
expect "docs/SECRETS.md" blocked "blocked still folds case even as safe classes do not"

# 10. NEGATION FAILS CLOSED in a folded class. '!' inverts the match, so
#     case-folding would REMOVE gating rather than add it — the one thing the
#     fold must never do. Verified directly: minimatch('FOO','!foo') is true,
#     but false under {nocase:true}. Same shape for segment extglobs.
#     Mirrors the bracket guard's fail-closed stance: no repo in the fleet
#     uses negation in a gating class, so strictness costs nothing.
#     (Codex round-2 P2.)
expect_fail_closed() {
  local desc="$1" needle="$2" out rc
  set +e
  out=$(cd "$tmp/repo" && echo "README.md" | node "$tmp/classify.mjs" 2>&1)
  rc=$?
  set -e
  if [ "$rc" -ne 0 ] && echo "$out" | grep -q "$needle"; then
    echo "✓ $desc"
  else
    echo "✗ $desc — expected nonzero exit + '$needle'; got rc=$rc:"
    echo "$out" | sed 's/^/    /'
    failed=1
  fi
}

cat > "$tmp/repo/.github/risk-paths.yml" <<'YAML'
blocked:
  - '!foo'
YAML
expect_fail_closed "leading-'!' negation under blocked: fails closed" "negation"

cat > "$tmp/repo/.github/risk-paths.yml" <<'YAML'
blocked: []
sensitive:
  - 'src/!(*.md)'
YAML
expect_fail_closed "segment extglob negation under sensitive: fails closed" "negation"

# ...but negation in a NON-folded class is not this guard's business: those
# classes are still matched case-sensitively, so the invariant can't break
# there. Guarding them too would be scope creep beyond the fold.
cat > "$tmp/repo/.github/risk-paths.yml" <<'YAML'
blocked: []
trivial:
  - '!src/**'
YAML
expect "docs/x.md" trivial "negation in a non-folded class is left alone"

exit "$failed"
