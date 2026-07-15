#!/usr/bin/env node
// Risk classifier for PR auto-merge gating.
//
// Reads .github/risk-paths.yml from cwd (the caller repo's checkout), reads
// the list of changed files from stdin (one path per line), and prints the
// highest-priority risk class to stdout.
//
// Priority (high → low): blocked > sensitive > standard > safe_test > safe_deps > safe_config > trivial
// `standard` is the implicit fallback for any file that doesn't match a
// known class — this is intentional: unknown paths default to the most
// strict non-blocking class so the auto-merge gate stays safe.
//
// CLI:
//   echo "<file paths, one per line>" | node classify.mjs
//
// Exit codes:
//   0 — printed a class name on stdout
//   1 — fatal error (missing rules file, parse error, etc.)
//
// Used by topcoder1/ci-workflows/.github/workflows/pr-classify.yml.

import { readFileSync } from 'node:fs';
import { parse } from 'yaml';
import { minimatch } from 'minimatch';

const RULES_PATH = '.github/risk-paths.yml';
const PRIORITY = [
	'blocked',
	'sensitive',
	'standard',
	'safe_test',
	'safe_deps',
	'safe_config',
	'trivial'
];
// Classes we test patterns against. `standard` is not in this list — it's
// the fallback for any file that matches NO pattern in any class.
const PATTERN_CLASSES = ['blocked', 'sensitive', 'safe_test', 'safe_deps', 'safe_config', 'trivial'];
// Classes matched case-insensitively. See the invariant on classify() below:
// folding case may only ever ADD gating, never remove it — which is exactly
// why the safe/trivial classes are absent here.
const NOCASE_CLASSES = new Set(['blocked', 'sensitive']);

function fail(msg) {
	process.stderr.write(`classify.mjs: ${msg}\n`);
	process.exit(1);
}

let rules;
try {
	rules = parse(readFileSync(RULES_PATH, 'utf8'));
} catch (e) {
	fail(`failed to read ${RULES_PATH}: ${e.message}`);
}

// A '[' in a pattern is a minimatch character class, never a literal
// bracket — a SvelteKit-style 'src/routes/[id]/+page.ts' entry silently
// matches nothing, and GitHub CODEOWNERS drops bracket lines entirely, so
// the gate the author thinks exists doesn't. That exact failure shipped
// once: wxa-jake-ai's stream gate was a no-op for six weeks
// (wxa-jake-ai#783). ALL brackets are banned, including intentional
// character classes like '*.[jt]s': '[id]' is syntactically a valid char
// class too, so no check can tell intent apart, and a heuristic that
// guesses wrong recreates the silent dead gate. Enumerate instead
// ('*.js' + '*.ts') — the 2026-07-04 fleet audit found zero real
// char-class uses, so strictness costs nothing. Fail closed.
//
// 'always_review' is validated here too even though this script never
// matches against it: codex-gate.mjs consumes it with the same minimatch
// semantics but is deliberately permissive on config errors, so this
// fail-closed pass is the only place a dead always_review entry gets
// caught before it silently skips a required Codex review.
for (const cls of [...PATTERN_CLASSES, 'always_review']) {
	for (const p of rules[cls] || []) {
		if (typeof p === 'string' && (p.includes('[') || p.includes(']'))) {
			fail(
				`${RULES_PATH}: pattern '${p}' (under '${cls}:') contains a bracket — ` +
					`minimatch reads '[...]' as a character class, so a literal path like a SvelteKit ` +
					`'[id]' segment can never match. Replace the bracket segment with '*' ` +
					`(e.g. 'src/routes/api/chat/*/stream/+server.ts') or use a parent '**' glob, ` +
					`and mirror the same fix in .github/CODEOWNERS (GitHub ignores bracket lines there). ` +
					`If you meant a real character class like '*.[jt]s', enumerate it instead ` +
					`('*.js' + '*.ts') — brackets are banned outright because intent is ambiguous. ` +
					`Context: wxa-jake-ai#783.`
			);
		}
	}
}

// Glob negation is incompatible with the case-fold applied to the gating
// classes, and breaks its one invariant. '!' inverts the match, so folding
// case REMOVES gating rather than adding it: minimatch('FOO', '!foo') is true
// (gated) but false under {nocase:true} (ungated) — a downgrade. Segment
// extglobs have the same shape: 'src/!(*.md)' matches 'src/A.MD' today and
// stops matching once case is folded. Fail closed rather than quietly violate
// the invariant classify() documents. Zero of the 45 repos carrying a
// risk-paths.yml use negation in a gating class (fleet audit 2026-07-14), so
// — as with the bracket guard above — strictness costs nothing today and
// stops the footgun from ever being introduced. (Codex round-2 P2 on the
// change that introduced the fold.)
for (const cls of NOCASE_CLASSES) {
	for (const p of rules[cls] || []) {
		if (typeof p === 'string' && (p.trimStart().startsWith('!') || p.includes('!('))) {
			fail(
				`${RULES_PATH}: pattern '${p}' (under '${cls}:') uses glob negation — ` +
					`'${cls}' is matched case-insensitively so that a lowercase pattern still ` +
					`catches real-world case variants, and negation inverts that: folding case ` +
					`REMOVES gating instead of adding it (minimatch('FOO','!foo') is true, but ` +
					`false with nocase). Express the rule positively — list the paths you want ` +
					`gated rather than the ones you don't. Context: wxa-jake-ai#877.`
			);
		}
	}
}

const changedFiles = readFileSync(0, 'utf8')
	.split('\n')
	.map((s) => s.trim())
	.filter(Boolean);

if (changedFiles.length === 0) {
	// No changed files = nothing to classify. Default to standard so the
	// caller doesn't choke on an empty PR (shouldn't happen on real PRs).
	process.stdout.write('standard\n');
	process.exit(0);
}

// Case-folding is applied to the GATING classes only. The invariant:
//
//     folding case may only ever ADD gating, never remove it.
//
// Why fold at all: minimatch defaults to case-SENSITIVE, so a lowercase
// pattern silently misses real-world case variants. '**/secrets*' matched
// 'docs/secrets.md' but NOT 'docs/SECRETS.md', so wxa-jake-ai's production
// secrets ROTATION RUNBOOK fell through to 'docs/**' and classified
// risk:trivial — auto-merge-eligible (wxa-jake-ai#875 had to be held as a
// draft to dodge it; fixed repo-side in wxa-jake-ai#877). The same latent gap
// exists for 'Dockerfile' (a committed 'dockerfile'/'DOCKERFILE') and the
// '.env' family, in every repo in the fleet.
//
// Why NOT fold the safe/trivial classes: doing so is a fail-OPEN. A path that
// matches nothing today gets the deliberately-strict 'standard' fallback;
// folding case can hand it to an auto-merge-eligible class instead. With
// `safe_test: ['tests/**']`, a PR adding 'Tests/release.py' would classify
// safe_test rather than standard — and on GitHub's case-sensitive filesystem
// that is a genuinely DISTINCT path, not the same file recased, so a
// lowercase pattern has no business claiming it. Class precedence cannot
// prevent this: it only breaks ties when a blocked/sensitive pattern also
// matches, and here none does. Folding the safe classes has no upside either
// — its only effect is to make them more lenient, which is precisely the
// direction we don't want. (Caught by codex pre-review on this change; the
// fleet audit below could not have found it, since it scanned files that
// already exist and this vector is about files a future PR introduces.)
//
// So the asymmetry is the point, not an oversight: blocked/sensitive can only
// grow, safe/trivial can only shrink-or-stay. selftest/test_classify_nocase.sh
// pins both halves.
//
// Fleet audit before shipping, 2026-07-14 — every blob in all 45 repos
// carrying a risk-paths.yml (18,604 files) classified twice, fold off vs on:
// ZERO downgrades, exactly 2 upgrades, both real secrets docs (wxa-jake-ai
// 'docs/SECRETS.md', inbox_superpilot 'docs/SECRETS_ROTATION.md'). Both are
// blocked:-class hits, so both still land under this narrower fold.
//
// NOTE: this does NOT fix .github/CODEOWNERS, which GitHub matches itself and
// also case-sensitively ("CODEOWNERS paths are case sensitive, because GitHub
// uses a case sensitive file system"). A repo relying on a lowercase glob to
// own an uppercase path still needs an exact-case CODEOWNERS line.
function classify(file) {
	for (const cls of PATTERN_CLASSES) {
		const patterns = rules[cls] || [];
		for (const p of patterns) {
			const opts = { dot: true, matchBase: false, nocase: NOCASE_CLASSES.has(cls) };
			if (minimatch(file, p, opts)) return cls;
		}
	}
	return 'standard';
}

const classes = new Set(changedFiles.map(classify));
const winner = PRIORITY.find((c) => classes.has(c)) || 'standard';
process.stdout.write(winner + '\n');
