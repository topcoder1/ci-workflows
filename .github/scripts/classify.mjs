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
// Optional `exclude:` map, keyed by class — paths that match a class pattern
// but must NOT be classified into it, falling through to the remaining classes
// instead. The motivating case: a repo gating its deployed service entrypoint
// with 'cmd/<svc>/**' under sensitive: has no way to let a tests-only diff in
// that package auto-merge, because classify() returns the first matching class
// and sensitive is checked before safe_test. Enumerating the production files
// positively "works" but fails OPEN — a NEW file added to that package matches
// nothing and lands on the `standard` fallback, i.e. auto-merge eligible with
// no Codex review, on the deployed entrypoint. An exclusion keeps the broad
// glob (so new files stay gated) and subtracts only the paths named.
//
// Exclusions are matched CASE-SENSITIVELY, always — including against the
// nocase gating classes. The invariant documented on classify() is that
// folding case may only ever ADD gating, never remove it; an exclusion REMOVES
// gating, so folding one would let 'CMD/SVC/FOO_TEST.GO' escape a gate its
// lowercase twin still hits. Case-sensitive exclusions can only ever subtract
// fewer paths, which is the safe direction.
const EXCLUDE_KEY = 'exclude';

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
// A scalar where a list belongs is a fail-OPEN, and a silent one. JS iterates
// a string per-character, so `sensitive: 'cmd/**'` becomes the patterns
// 'c','m','d','/','*','*' — none of which trips the bracket or negation guards
// below, and none of which matches a real path. The class simply stops gating.
// This is the gating-class twin of the exclude.<cls> guard further down; that
// one was caught in review on ci-workflows#145, which is what surfaced this.
//
// Fleet-audited before adding, because this guard hard-fails any repo it
// catches: all 140 repos across topcoder1 + whois-api-llc carry a
// risk-paths.yml and every class value is a real list. Eight repos
// (whois-api-qa, app-factory, wxa-graph, usdev, netsniper, domains_collector,
// dnssniper, ProfessionalServices) have an EMPTY `sensitive:` key — null, not
// a scalar — which stays legal here exactly as `rules[cls] || []` already
// treated it. So this breaks no consumer today.
for (const cls of [...PATTERN_CLASSES, 'always_review']) {
	const v = rules[cls];
	if (v !== null && v !== undefined && !Array.isArray(v)) {
		fail(
			`${RULES_PATH}: '${cls}:' must be a LIST of patterns, got a ${typeof v}. ` +
				`A bare string is iterated per-character, so every character becomes its own ` +
				`pattern and '${cls}' silently stops matching anything — an UN-gating fail-open, ` +
				`not a syntax error. Write each pattern on its own "- '…'" line.`
		);
	}
}

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
// the invariant classify() documents. Zero repos use negation in a gating
// class: true of the 45 audited 2026-07-14, and re-established 2026-08-08
// across the current fleet of 140 (see the FLEET SIZE note below — every one
// of the 140 exits 0 through this script, and negation hard-fails, so a clean
// run proves absence). As with the bracket guard above, strictness costs
// nothing today and
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

// Exclusion lists get the SAME fail-closed guards as the gating classes, and
// two of their own. A bracket is the silent-dead-gate footgun in either
// direction. Negation inside an exclusion is worse than in a gating class: an
// exclusion is already a subtraction, so negating it flips the rule into
// "exclude everything EXCEPT this" and silently un-gates the whole class. An
// unknown class key ('sensitve:') would exclude nothing while leaving the
// author convinced they had exempted paths they had not — so it is rejected
// rather than ignored, even though its effect is the safe direction.
const rawExclude = rules[EXCLUDE_KEY];
let excludeRules = {};
if (rawExclude !== undefined && rawExclude !== null) {
	if (typeof rawExclude !== 'object' || Array.isArray(rawExclude)) {
		fail(
			`${RULES_PATH}: '${EXCLUDE_KEY}:' must be a mapping of class name → pattern list ` +
				`(e.g. "${EXCLUDE_KEY}:\\n  sensitive:\\n    - 'cmd/svc/**/*_test.go'"), got ` +
				`${Array.isArray(rawExclude) ? 'a list' : typeof rawExclude}.`
		);
	}
	excludeRules = rawExclude;
}
for (const cls of Object.keys(excludeRules)) {
	if (!PATTERN_CLASSES.includes(cls)) {
		fail(
			`${RULES_PATH}: '${EXCLUDE_KEY}:' names unknown class '${cls}' — valid classes are ` +
				`${PATTERN_CLASSES.join(', ')}. A typo here would silently exclude nothing, so it fails closed.`
		);
	}
	// Subtracting from `blocked` is refused outright. blocked is the hardest
	// tier — it hard-fails the classify check and never bypasses — and it
	// carries the secrets family ('**/.env', '**/secrets*'), Dockerfiles and
	// deploy/. A stray '**' in an exclusion there silently un-gates all of it,
	// and an exclusion is exactly the kind of subtraction that is easy to get
	// subtly wrong, where deleting a blocked: entry outright is at least
	// visible in review. No concrete need for this has appeared; per the same
	// reasoning as the bracket and negation bans above, strictness costs
	// nothing today. Lift this if a real case turns up.
	if (cls === 'blocked') {
		fail(
			`${RULES_PATH}: '${EXCLUDE_KEY}:' may not subtract from 'blocked' — it is the hardest ` +
				`tier (hard-fails classify, never bypasses) and covers the secrets, Dockerfile and ` +
				`deploy paths. Narrow the 'blocked:' patterns themselves if something is over-matched, ` +
				`so the change is visible rather than subtracted.`
		);
	}
	// A scalar where a list belongs is a fail-OPEN, not a syntax error: JS
	// iterates a string per-character, so `sensitive: 'cmd/svc/**'` becomes the
	// patterns 'c','m','d','/','s',… ,'*'. None trips the bracket or negation
	// guards, and minimatch(file, '*') matches any root-level path — silently
	// exempting files from the class. Require a real list.
	const patterns = excludeRules[cls];
	if (patterns !== null && patterns !== undefined && !Array.isArray(patterns)) {
		fail(
			`${RULES_PATH}: '${EXCLUDE_KEY}.${cls}:' must be a LIST of patterns, got a ${typeof patterns}. ` +
				`A bare string is iterated per-character here, so every character becomes a pattern — ` +
				`'*' among them silently exempts root-level paths from '${cls}'. Write each pattern on ` +
				`its own "- '…'" line.`
		);
	}
	for (const p of patterns || []) {
		if (typeof p !== 'string') continue;
		if (p.includes('[') || p.includes(']')) {
			fail(
				`${RULES_PATH}: pattern '${p}' (under '${EXCLUDE_KEY}.${cls}:') contains a bracket — ` +
					`minimatch reads '[...]' as a character class, so the exclusion matches nothing and ` +
					`the paths you meant to exempt stay gated. Replace the bracket segment with '*', or ` +
					`enumerate. Same rule as the gating classes.`
			);
		}
		if (p.trimStart().startsWith('!') || p.includes('!(')) {
			fail(
				`${RULES_PATH}: pattern '${p}' (under '${EXCLUDE_KEY}.${cls}:') uses glob negation — ` +
					`an exclusion is already a subtraction, so negating it inverts the rule into ` +
					`"exclude everything EXCEPT this" and silently un-gates the whole '${cls}' class. ` +
					`Express the exclusion positively: list the paths to exempt.`
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
// Fleet audit before shipping, 2026-07-14 — every blob in all 45 repos then
// carrying a risk-paths.yml (18,604 files) classified twice, fold off vs on:
// ZERO downgrades, exactly 2 upgrades, both real secrets docs (wxa-jake-ai
// 'docs/SECRETS.md', inbox_superpilot 'docs/SECRETS_ROTATION.md'). Both are
// blocked:-class hits, so both still land under this narrower fold.
//
// FLEET SIZE, corrected 2026-08-08: the fleet is no longer 45. Enumerating
// topcoder1 + whois-api-llc found 140 repos, and ALL 140 carry a
// risk-paths.yml. The blob-level fold comparison above was never redone at
// that size, so treat its numbers as covering the 45 that existed then — the
// conclusion still holds structurally (folding can only ADD gating, by
// construction), but the empirical backing is the smaller set.
//
// What WAS established across all 140 (2026-08-08): every one of their
// risk-paths.yml files runs through this script and exits 0. Since this script
// hard-fails on brackets, on negation in a gating class, and on a scalar where
// a list belongs, a clean run over the fleet proves none of the 140 uses any
// of them. Cite this rather than the stale 45 when sizing a guard's blast
// radius — the earlier figure understated it by ~3x.
//
// NOTE: this does NOT fix .github/CODEOWNERS, which GitHub matches itself and
// also case-sensitively ("CODEOWNERS paths are case sensitive, because GitHub
// uses a case sensitive file system"). A repo relying on a lowercase glob to
// own an uppercase path still needs an exact-case CODEOWNERS line.
// isExcluded reports whether `file` is exempted from `cls` by an `exclude:`
// entry. Always case-sensitive — see EXCLUDE_KEY above for why folding here
// would break classify()'s invariant.
function isExcluded(file, cls) {
	for (const p of excludeRules[cls] || []) {
		if (typeof p === 'string' && minimatch(file, p, { dot: true, matchBase: false, nocase: false })) {
			return true;
		}
	}
	return false;
}

function classify(file) {
	for (const cls of PATTERN_CLASSES) {
		// Skip the whole class, not just the matching pattern: a file exempted
		// from `sensitive` must not be re-gated by a second sensitive pattern.
		if (isExcluded(file, cls)) continue;
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
