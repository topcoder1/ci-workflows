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

function classify(file) {
	for (const cls of PATTERN_CLASSES) {
		const patterns = rules[cls] || [];
		for (const p of patterns) {
			if (minimatch(file, p, { dot: true, matchBase: false })) return cls;
		}
	}
	return 'standard';
}

const classes = new Set(changedFiles.map(classify));
const winner = PRIORITY.find((c) => classes.has(c)) || 'standard';
process.stdout.write(winner + '\n');
