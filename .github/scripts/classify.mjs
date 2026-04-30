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
