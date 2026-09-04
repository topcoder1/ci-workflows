#!/usr/bin/env bash
# Regenerates .github/scripts/classifier-deps.mjs — the vendored ESM bundle of
# the only two third-party packages the classifier scripts need (`yaml` for
# risk-paths.yml, `minimatch` for glob matching).
#
# WHY VENDOR AT ALL
#
# pr-classify.yml used to run `npm install --no-save yaml@2 minimatch@10` inside
# the CALLER's checkout. When the caller has a root package.json — any JS repo —
# npm installs that repo's ENTIRE dependency tree, not just the two named
# packages. Measured 2026-09-03: 37 packages/5.0s with a 3-dep package.json
# present vs 4 packages/0.13s without. In whois-api-llc/wxa-jake-ai (24 deps +
# 39 devDeps) that turned a 4-package install into ~1000 packages of registry
# round-trips, and multiplied exposure to per-request tail latency by the same
# factor: three consecutive runs took 32s, 7m03s and 5m20s in the SAME repo.
# The 7m03s run blew through claude-author-automerge.yml's 5-minute
# wait-for-classification budget and wedged the PR (whois-api-llc/wxa-jake-ai#1107).
#
# Isolating the install directory alone would fix the latency (a cold, isolated,
# empty-cache install of just these two packages measures 0.76-0.93s). Vendoring
# goes further and removes npm from the runtime path entirely, which is what
# actually matters here: the classifier is a FAIL-CLOSED gate in 45 repos, so
# every external service in its critical path is a fleet-wide wedge vector.
# After this change the classifier depends on ONE external service (the GitHub
# API) instead of two — and that one is already required to fetch the scripts
# and is already wrapped in `retry`, so vendoring adds no new failure domain.
#
# It also pins the supply chain. `yaml@2`/`minimatch@10` were floating majors:
# every classifier run in every caller repo executed whatever those resolved to
# at that moment, freshly downloaded, in a job holding a GITHUB_TOKEN. And
# because pr-classify.yml and claude-author-automerge.yml resolved them
# independently, two runs minutes apart could match with different minimatch
# patch versions — the exact matcher-drift class that
# claude-author-automerge.yml's own comments call out as the bug the gate
# exists to prevent. One committed bundle makes both byte-identical.
#
# WHY DEPS-ONLY (and not a bundle of classify.mjs itself)
#
# So the generated artifact is decoupled from the scripts. classify.mjs changes
# often (risk-pattern work); yaml/minimatch have never been bumped in this
# repo's history. Vendoring only the deps means the committed bundle does not
# need regenerating when the classifier logic changes — only on a deliberate
# dependency bump. The scripts stay readable source that reviewers actually read.
#
# USAGE
#
#   scripts/build-classifier-deps.sh           # regenerate the bundle in place
#   scripts/build-classifier-deps.sh --check   # verify the committed bundle is
#                                              # current; non-zero if stale
#
# To change a version, edit scripts/classifier-deps/package.json, run
#   (cd scripts/classifier-deps && npm install --package-lock-only)
# to refresh the lockfile, then run this script and commit both.
# selftest/test_classifier_deps_vendored.sh runs --check in CI.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$repo_root/.github/scripts/classifier-deps.mjs"
manifest_dir="$repo_root/scripts/classifier-deps"

check_mode=0
if [ "${1:-}" = "--check" ]; then
	check_mode=1
elif [ -n "${1:-}" ]; then
	echo "usage: $(basename "$0") [--check]" >&2
	exit 2
fi

command -v npm >/dev/null 2>&1 || { echo "build-classifier-deps: npm not found on PATH" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "build-classifier-deps: node not found on PATH" >&2; exit 1; }
for f in package.json package-lock.json; do
	[ -f "$manifest_dir/$f" ] || { echo "build-classifier-deps: missing $manifest_dir/$f" >&2; exit 1; }
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Install from the COMMITTED LOCKFILE, into an isolated directory.
#
# `npm ci` rather than `npm install`, and a lockfile rather than bare version
# arguments, because pinning only the direct dependencies is not enough to make
# this bundle reproducible: minimatch depends on brace-expansion@^5.0.8, which
# depends on balanced-match@^4.0.2, and BOTH are bundled into the output. With
# those ranges floating, a new compatible transitive release would make --check
# report the committed bundle stale with no pin change of ours, and a
# regeneration would silently vendor different code while the direct-version
# assertions below still passed. (Codex pre-review, round 1.)
#
# The isolated directory matters for the same reason it does in the workflows:
# this script must never install inside the repo, or a package.json at the
# install cwd drags in the surrounding tree — the very bug being fixed.
#
# --ignore-scripts blocks package install hooks, the primary npm
# code-execution vector. esbuild resolves its platform binary through
# optionalDependencies rather than a postinstall, so it works without them.
cp "$manifest_dir/package.json" "$manifest_dir/package-lock.json" "$work/"
(
	cd "$work"
	npm ci --silent --no-audit --no-fund --ignore-scripts >/dev/null
)

# Read the versions actually installed and cross-check them against the
# manifest. `npm ci` already fails when package.json and the lockfile disagree;
# this catches the rarer case of an install that silently produced something
# else, and supplies the numbers for the provenance banner below.
version_of() { node -p "require('$work/node_modules/$1/package.json').version"; }
for pkg in yaml minimatch esbuild; do
	want=$(node -p "
		const m = require('$work/package.json');
		m.dependencies?.['$pkg'] ?? m.devDependencies?.['$pkg'] ?? '';
	")
	got=$(version_of "$pkg")
	if [ "$got" != "$want" ]; then
		echo "build-classifier-deps: $pkg resolved to $got, manifest pins $want" >&2
		exit 1
	fi
done

# The entry point re-exports exactly the two symbols the classifier scripts use.
# Keep this surface minimal: every added export widens the bundle and the audit.
cat > "$work/entry.mjs" <<'ENTRY'
export { parse } from 'yaml';
export { minimatch } from 'minimatch';
ENTRY

# Provenance banner, so the committed artifact says what produced it without
# anyone having to find this script first. The contents list is generated from
# the lockfile rather than hardcoded, so a transitive bump shows up in the
# artifact's diff instead of silently changing 300KB of unreviewable code.
# Platform-specific @esbuild/* packages are excluded — esbuild is the bundler
# and contributes no code to the output.
contents=$(node -p "
	const lock = require('$work/package-lock.json');
	Object.entries(lock.packages)
		.filter(([k]) => k.startsWith('node_modules/') && !k.startsWith('node_modules/@esbuild/'))
		.map(([k, v]) => k.replace('node_modules/', '') + '@' + v.version)
		.sort()
		.map((s) => '// ' + s)
		.join('\n');
")

# Built with printf, not a heredoc: a heredoc inside \$( ) has its body scanned
# for quotes by the command-substitution parser, so a lone apostrophe in the
# prose is read as an unterminated string and the whole file fails to parse.
# printf '%s\n' with one double-quoted argument per line is the idiom the
# workflows here already use for multi-line bodies.
banner=$(printf '%s\n' \
	"// @generated by scripts/build-classifier-deps.sh — DO NOT EDIT BY HAND." \
	"//" \
	"// Vendored dependency bundle for .github/scripts/classify.mjs and" \
	"// .github/scripts/codex-gate.mjs. Committed so the classifier needs no" \
	"// 'npm install' at run time: it is a fail-closed gate in every caller repo," \
	"// and npm in that path is a fleet-wide wedge vector (see the build script" \
	"// header for the incident that motivated this)." \
	"//" \
	"// Exact tree vendored here (from scripts/classifier-deps/package-lock.json):" \
	"$contents" \
	"//" \
	"// To change a version: edit scripts/classifier-deps/package.json, refresh" \
	"// the lockfile, re-run scripts/build-classifier-deps.sh, and commit all" \
	"// three. Verify with:" \
	"//     scripts/build-classifier-deps.sh --check" \
	"" \
	"// yaml's package.json exports map has no 'import' condition — only" \
	"// 'node' (CommonJS) and a browser 'default'. Under --platform=node esbuild" \
	"// therefore bundles the CommonJS build, whose composer.js opens with a" \
	"// top-level require('process'); ESM output cannot synchronously require a" \
	"// builtin, so esbuild emits a shim that THROWS ('Dynamic require of" \
	"// \"process\" is not supported') the first time parse() runs. That shim" \
	"// delegates to a real require when one is in scope, so supplying one here" \
	"// fixes it — and keeps yaml's NODE build, i.e. byte-for-byte the code path" \
	"// npm install resolves. Resolving to the browser ESM build instead would" \
	"// dodge the require but silently swap in a different implementation." \
	"import { createRequire as __classifierCreateRequire } from 'node:module';" \
	"const require = __classifierCreateRequire(import.meta.url);")

# ALWAYS build inside the work dir, then copy out (or diff against) the result.
# Never point --outfile straight at the repo, and always run esbuild with its cwd
# set to $work.
#
# esbuild annotates each bundled chunk with its source path rendered relative to
# the process CWD. Run from the repo root, every one of those 152 comments became
# an absolute walk out of the repo and into the random mktemp directory — so the
# artifact embedded the build machine's filesystem layout and no two builds could
# ever be byte-identical (--check reported STALE on a file it had just written).
# Running from $work with relative arguments makes them stable
# 'node_modules/yaml/dist/...' paths, identical on every machine.
built="$work/out/classifier-deps.mjs"
mkdir -p "$work/out"

(
	cd "$work"
	./node_modules/.bin/esbuild entry.mjs \
		--bundle \
		--format=esm \
		--platform=node \
		--target=node22 \
		--legal-comments=inline \
		--banner:js="$banner" \
		--outfile=out/classifier-deps.mjs \
		--log-level=warning
)

# Fail closed if a build-machine path leaked into the artifact — the bug the
# fixed outfile location above exists to prevent. Anchored on the work dir and
# on absolute-looking source annotations so a future flag change cannot quietly
# reintroduce a non-reproducible bundle.
#
# Captured to a variable rather than piping grep into head: under `set -o
# pipefail`, head closing the pipe early SIGPIPEs grep and the pipeline returns
# 141, which `set -e` turns into an exit 141 before the intended `exit 1` runs.
leaks=$(grep -n -e "$work" -e '^// /' -e '^// \.\./' "$built" || true)
if [ -n "$leaks" ]; then
	echo "build-classifier-deps: build-machine paths leaked into the bundle — not reproducible." >&2
	printf '%s\n' "$leaks" | sed -n '1,3p' >&2
	exit 1
fi

summary=$(printf '%s' "$contents" | sed 's|^// ||' | tr '\n' ' ')

if [ "$check_mode" -eq 1 ]; then
	if [ ! -f "$out" ]; then
		echo "build-classifier-deps: $out is missing — run scripts/build-classifier-deps.sh" >&2
		exit 1
	fi
	if ! diff -q "$out" "$built" >/dev/null 2>&1; then
		echo "build-classifier-deps: $out is STALE (differs from a fresh build)." >&2
		echo "  Regenerate and commit it:  scripts/build-classifier-deps.sh" >&2
		exit 1
	fi
	echo "build-classifier-deps: $(basename "$out") is current — $summary"
	exit 0
fi

cp "$built" "$out"
echo "build-classifier-deps: wrote $out ($(wc -c < "$out" | tr -d ' ') bytes)"
echo "  $summary"
