#!/usr/bin/env bash
# Pins the vendored-dependency contract for the classifier scripts.
#
# WHY THIS EXISTS
#
# pr-classify.yml and codex-review.yml used to run
# `npm install --no-save yaml@2 minimatch@10` inside the CALLER's checkout.
# When the caller has a root package.json — any JS repo — npm installs that
# repo's ENTIRE dependency tree, not just the two named packages. In
# whois-api-llc/wxa-jake-ai (24 deps + 39 devDeps) that turned a 4-package
# install into ~1000 packages, and the tail latency scaled with it: three
# consecutive runs on 2026-09-03 measured 32s, 7m03s and 5m20s in the SAME
# repo. The 7m03s run blew claude-author-automerge.yml's
# wait-for-classification budget and wedged the PR
# (whois-api-llc/wxa-jake-ai#1107).
#
# The deps are now a committed, version-pinned esbuild bundle
# (.github/scripts/classifier-deps.mjs) fetched alongside the scripts, so the
# classifier needs no npm at run time.
#
# Case 2 is the point of the file. Vendoring yaml is NOT a trivial repackaging:
# yaml's package.json exports map has no 'import' condition, so under
# --platform=node esbuild bundles its CommonJS build, whose composer.js opens
# with a top-level require('process'). ESM output cannot synchronously require a
# builtin, so esbuild emits a shim that THROWS on first use. The first bundle
# built here did exactly that — it imported fine and blew up inside parse(),
# which would have hard-failed the classifier in all 45 caller repos. A
# load-only smoke test does not catch it; the deps must actually be CALLED.
#
# Run from the repo root:
#   bash selftest/test_classifier_deps_vendored.sh
set -euo pipefail

DEPS=.github/scripts/classifier-deps.mjs
CLASSIFY=.github/scripts/classify.mjs

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failed=0

ok()   { printf '  ok   — %s\n' "$1"; }
bad()  { printf '  FAIL — %s\n' "$1"; failed=1; }

# Strip comment lines before grepping for wiring. Both checks below look for
# script names and npm invocations, and this repo's workflows discuss both at
# length in prose — including the comments added by the change under test, which
# quote the very `npm install yaml@2 minimatch@10` line being removed. Grepping
# raw text reported three failures on a correctly-wired tree. A leading '#' is a
# comment in the YAML and inside `run: |` shell bodies alike, so one filter
# serves both.
#
# Returns the stripped body for herestring matching rather than exposing a pipe.
# `code_only "$f" | grep -q PAT` is a trap under `set -o pipefail`: grep -q exits
# at the first match, SIGPIPEs the upstream grep, and the pipeline reports 141 —
# so a MATCH reads as a failure. It only fires when the upstream still has output
# buffered when -q quits, which made it size-dependent: the two small workflows
# passed and the 110KB claude-author-automerge.yml failed.
code_only() { grep -vE '^[[:space:]]*#' "$1" || true; }

echo "1. the committed bundle exists and is current"

if [ ! -f "$DEPS" ]; then
	bad "$DEPS is missing — run scripts/build-classifier-deps.sh"
else
	ok "$DEPS is present"
fi

# Rebuild from the pinned versions and byte-compare. Catches a hand-edited
# bundle, and a version bump in the build script that was never regenerated.
# Needs npm; skip rather than fail when offline so the rest of the file still
# runs, but say so loudly — this is the only check that proves provenance.
if command -v npm >/dev/null 2>&1 && npm ping >/dev/null 2>&1; then
	if scripts/build-classifier-deps.sh --check >/dev/null 2>&1; then
		ok "bundle matches a fresh build from the pinned versions"
	else
		bad "bundle is STALE — run scripts/build-classifier-deps.sh and commit the result"
	fi
else
	printf '  SKIP — npm registry unreachable; cannot verify bundle provenance\n'
fi

echo
echo "2. the vendored deps actually RUN (not just import)"

# The regression this file exists for. Call both exports for real: a bundle
# whose require shim throws imports cleanly and only fails on use.
cat > "$tmp/exercise.mjs" <<'EOF'
import { parse, minimatch } from './classifier-deps.mjs';
const rules = parse("blocked:\n  - '**/.env*'\n  - '**/secrets*'\nsafe_test:\n  - 'tests/**'\n");
if (!Array.isArray(rules.blocked) || rules.blocked.length !== 2) {
  console.error('parse() returned unexpected shape: ' + JSON.stringify(rules));
  process.exit(1);
}
// Exercise the option sets classify.mjs actually uses, including nocase.
const checks = [
  ['.env.prod', '**/.env*', { dot: true, matchBase: false, nocase: false }, true],
  ['docs/SECRETS.md', '**/secrets*', { dot: true, matchBase: false, nocase: true }, true],
  ['docs/SECRETS.md', '**/secrets*', { dot: true, matchBase: false, nocase: false }, false],
  ['tests/a/b.py', 'tests/**', { dot: true, matchBase: false, nocase: false }, true],
  ['src/main.go', 'tests/**', { dot: true, matchBase: false, nocase: false }, false]
];
for (const [file, pat, opts, want] of checks) {
  const got = minimatch(file, pat, opts);
  if (got !== want) {
    console.error(`minimatch(${file}, ${pat}, nocase=${opts.nocase}) = ${got}, want ${want}`);
    process.exit(1);
  }
}
console.log('OK');
EOF
cp "$DEPS" "$tmp/classifier-deps.mjs"
if out=$(cd "$tmp" && node exercise.mjs 2>&1) && [ "$out" = "OK" ]; then
	ok "parse() and minimatch() both execute and return correct results"
else
	bad "vendored deps failed when CALLED: $(printf '%s' "$out" | tr '\n' '|')"
fi

echo
echo "3. classify.mjs resolves deps with NO node_modules anywhere"

# Proves the vendored path is genuinely load-bearing rather than silently
# falling back to an ambient install. Runs under $tmp, which has no
# node_modules on its resolution path.
mkdir -p "$tmp/novm/repo/.github"
cp "$CLASSIFY" "$DEPS" "$tmp/novm/"
cat > "$tmp/novm/repo/.github/risk-paths.yml" <<'YAML'
blocked:
  - '**/.env*'
sensitive: []
safe_test:
  - 'tests/**'
YAML
got=$(printf '%s\n' .env.prod | (cd "$tmp/novm/repo" && node ../classify.mjs) 2>"$tmp/novm.err" || true)
if [ "$got" = "blocked" ]; then
	ok "classify.mjs classified .env.prod as blocked with no node_modules present"
else
	bad "classify.mjs without node_modules printed '$got' (want 'blocked'); stderr: $(tr '\n' '|' < "$tmp/novm.err")"
fi
# And it must NOT have warned about falling back — the vendored file was there.
if grep -q 'falling back to node_modules' "$tmp/novm.err" 2>/dev/null; then
	bad "classify.mjs took the node_modules fallback even though $DEPS was present"
else
	ok "no spurious fallback warning when the bundle is present"
fi

echo
echo "4. the node_modules fallback still works when the bundle is absent"

# Rollout shim: a run that started before this change landed executes older
# workflow YAML that never fetches classifier-deps.mjs. That must degrade to
# node_modules with a warning, not hard-fail. Needs npm; skip when offline.
mkdir -p "$tmp/fb/repo/.github"
cp "$CLASSIFY" "$tmp/fb/"
cp "$tmp/novm/repo/.github/risk-paths.yml" "$tmp/fb/repo/.github/risk-paths.yml"
if command -v npm >/dev/null 2>&1 &&
	(cd "$tmp/fb" && npm install --no-save --silent --no-audit --no-fund yaml@2 minimatch@10 >/dev/null 2>&1); then
	got=$(printf '%s\n' .env.prod | (cd "$tmp/fb/repo" && node ../classify.mjs) 2>"$tmp/fb.err" || true)
	if [ "$got" = "blocked" ]; then
		ok "fallback path classified .env.prod as blocked"
	else
		bad "fallback path printed '$got' (want 'blocked'); stderr: $(tr '\n' '|' < "$tmp/fb.err")"
	fi
	if grep -q 'falling back to node_modules' "$tmp/fb.err"; then
		ok "fallback is announced on stderr (silent degradation would hide a stale caller)"
	else
		bad "fallback happened without the stderr warning"
	fi
else
	printf '  SKIP — npm unavailable; cannot exercise the node_modules fallback\n'
fi

echo
echo "5. the bundle stays fetchable through the GitHub contents API"

# Every consumer pulls this file with `gh api .../contents/...`, which only
# returns inline content for blobs under 1 MiB. A future dependency bump that
# crossed that line would break classification in every caller repo at once,
# with a failure mode ("empty content") that looks nothing like its cause.
# Hardcoded limit, deliberately: deriving it from the file under test would
# make this check vacuous.
size=$(wc -c < "$DEPS" | tr -d ' ')
limit=1048576
if [ "$size" -lt "$limit" ]; then
	ok "bundle is ${size} bytes, under the ${limit}-byte contents API inline cap"
else
	bad "bundle is ${size} bytes — at/over the ${limit}-byte cap; the API will stop returning it inline"
fi

echo
echo "6. every workflow that fetches a dep-using script also fetches the bundle"

# Forward coverage: derived from the workflows, so a NEW consumer added later is
# checked automatically. Case 7 below hardcodes the three known consumers so
# that this set narrowing to zero cannot pass silently.
for wf in .github/workflows/*.yml; do
	body=$(code_only "$wf")
	grep -qE 'classify\.mjs|codex-gate\.mjs' <<<"$body" || continue
	if grep -q 'classifier-deps\.mjs' <<<"$body"; then
		ok "$(basename "$wf") fetches classifier-deps.mjs"
	else
		bad "$(basename "$wf") fetches a dep-using script but NOT classifier-deps.mjs — it will hit the node_modules fallback, or fail"
	fi
done

echo
echo "7. the run-time npm install is gone from the classifier path"

for wf in .github/workflows/pr-classify.yml \
	.github/workflows/codex-review.yml \
	.github/workflows/claude-author-automerge.yml; do
	if [ ! -f "$wf" ]; then
		bad "$wf is missing — this test's anchors are stale"
		continue
	fi
	body=$(code_only "$wf")
	if grep -q 'classifier-deps\.mjs' <<<"$body"; then
		ok "$(basename "$wf") is wired to the vendored bundle"
	else
		bad "$(basename "$wf") no longer references classifier-deps.mjs"
	fi
	# The specific install that caused the incident. Anchored on the package
	# names so an equivalent line in different flag order is still caught.
	hit=$(grep -E 'npm (install|i|ci).*(yaml@|minimatch@)' <<<"$body" | sed -n '1p' || true)
	if [ -n "$hit" ]; then
		bad "$(basename "$wf") still npm-installs yaml/minimatch at run time: $hit"
	else
		ok "$(basename "$wf") has no run-time yaml/minimatch install"
	fi
done

echo
echo "8. the other classify selftests exercise the vendored path, not the fallback"

# A selftest that npm-installs into its temp dir still PASSES — classify.mjs
# falls back to node_modules and classifies identically — so it goes on
# reporting green while silently testing the degraded path instead of the one
# that ships. Two of the five did exactly that after the first pass of this
# change; nothing failed, and only a stray "falling back to node_modules" on
# stderr gave it away.
for t in selftest/test_classify_*.sh; do
	[ -f "$t" ] || continue
	hit=$(grep -E 'npm (install|i|ci).*(yaml@|minimatch@)' <<<"$(code_only "$t")" | sed -n '1p' || true)
	if [ -n "$hit" ]; then
		bad "$(basename "$t") still npm-installs its deps — it exercises the fallback, not the vendored bundle: $hit"
	else
		ok "$(basename "$t") uses the vendored bundle"
	fi
done

echo
if [ "$failed" -ne 0 ]; then
	echo "FAILED"
	exit 1
fi
echo "All classifier vendored-dependency checks passed."
