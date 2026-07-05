#!/usr/bin/env bash
# Guards classify.mjs's bracket-pattern validation.
#
# minimatch treats '[...]' as a character class, so a literal SvelteKit-style
# entry like 'src/routes/api/chat/[id]/stream/+server.ts' in risk-paths.yml
# can never match its own file — the gate is a silent no-op. GitHub
# CODEOWNERS additionally ignores any line containing brackets, so the
# lockstep CODEOWNERS mirror dies the same way. This exact failure shipped
# in wxa-jake-ai (stream gate dead 2026-05-24 → 2026-07-04, fixed in
# wxa-jake-ai#783; fleet audited same day — no other repo affected).
# classify.mjs now fails closed on bracket patterns; this test bakes that
# behavior AND the recommended '*' rewrite into version control.
#
# Run from the repo root:
#   bash selftest/test_classify_bracket_guard.sh
set -euo pipefail

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# classify.mjs resolves its deps from its own location, so install them next
# to a copy in the temp dir — same versions pr-classify.yml pins.
cp .github/scripts/classify.mjs "$tmp/classify.mjs"
(cd "$tmp" && npm install --no-save --silent yaml@2 minimatch@10 >/dev/null 2>&1)

mkdir -p "$tmp/repo/.github"
failed=0

# 1. A bracket pattern must fail closed with an actionable message.
cat > "$tmp/repo/.github/risk-paths.yml" <<'YAML'
blocked: []
sensitive:
  - 'src/routes/api/chat/[id]/stream/+server.ts'
YAML
set +e
out=$(cd "$tmp/repo" && echo "README.md" | node "$tmp/classify.mjs" 2>&1)
rc=$?
set -e
if [ "$rc" -ne 0 ] && echo "$out" | grep -q "character class"; then
  echo "✓ bracket pattern fails closed with an actionable message"
else
  echo "✗ expected nonzero exit + 'character class' in message; got rc=$rc:"
  echo "$out" | sed 's/^/    /'
  failed=1
fi

# 2. The recommended '*' rewrite actually matches the real bracketed path
#    (this is the wxa-jake-ai#783 fix, verified against the classifier's own
#    minimatch options).
cat > "$tmp/repo/.github/risk-paths.yml" <<'YAML'
blocked: []
sensitive:
  - 'src/routes/api/chat/*/stream/+server.ts'
YAML
cls=$(cd "$tmp/repo" && echo "src/routes/api/chat/[id]/stream/+server.ts" | node "$tmp/classify.mjs")
if [ "$cls" = "sensitive" ]; then
  echo "✓ '*' rewrite classifies the literal [id] path as sensitive"
else
  echo "✗ expected 'sensitive' for the [id] path under the '*' rewrite, got '$cls'"
  failed=1
fi

# 3. A clean rules file still classifies normally (no false positive).
cls=$(cd "$tmp/repo" && echo "README.md" | node "$tmp/classify.mjs")
if [ "$cls" = "standard" ]; then
  echo "✓ clean rules file classifies normally"
else
  echo "✗ expected 'standard' for README.md, got '$cls'"
  failed=1
fi

# 4. Intentional character classes are ALSO rejected — this is a decision,
#    not an oversight. '[id]' is syntactically a valid char class, so intent
#    can't be told apart; authors must enumerate ('*.js' + '*.ts'). The
#    message must say so.
cat > "$tmp/repo/.github/risk-paths.yml" <<'YAML'
blocked: []
safe_test:
  - 'tests/**/*.[jt]s'
YAML
set +e
out=$(cd "$tmp/repo" && echo "README.md" | node "$tmp/classify.mjs" 2>&1)
rc=$?
set -e
if [ "$rc" -ne 0 ] && echo "$out" | grep -q "enumerate"; then
  echo "✓ intentional char class rejected with the enumeration hint"
else
  echo "✗ expected nonzero exit + 'enumerate' in message for char-class pattern; got rc=$rc:"
  echo "$out" | sed 's/^/    /'
  failed=1
fi

# 5. 'always_review' is validated too: classify.mjs never matches against it,
#    but codex-gate.mjs consumes it with the same minimatch semantics and is
#    permissive on config errors — this guard is the only fail-closed pass
#    over that list.
cat > "$tmp/repo/.github/risk-paths.yml" <<'YAML'
blocked: []
always_review:
  - 'src/routes/[id]/+page.ts'
YAML
set +e
out=$(cd "$tmp/repo" && echo "README.md" | node "$tmp/classify.mjs" 2>&1)
rc=$?
set -e
if [ "$rc" -ne 0 ] && echo "$out" | grep -q "always_review"; then
  echo "✓ bracket pattern under always_review fails closed"
else
  echo "✗ expected nonzero exit + 'always_review' in message; got rc=$rc:"
  echo "$out" | sed 's/^/    /'
  failed=1
fi

exit "$failed"
