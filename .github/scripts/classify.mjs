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

// `yaml` and `minimatch` come from classifier-deps.mjs — a committed, version-
// pinned esbuild bundle that the workflows fetch into the same directory as this
// script (see scripts/build-classifier-deps.sh). This replaced an
// `npm install --no-save yaml@2 minimatch@10` that ran inside the CALLER's
// checkout, where a root package.json dragged that repo's entire dependency tree
// into every classify run: ~1000 packages instead of 4 in wxa-jake-ai, whose
// tail latency (32s / 7m03s / 5m20s across three consecutive runs) blew the
// auto-merge gate's poll budget and wedged PRs. The classifier is a fail-closed
// gate in 45 repos, so npm in its critical path was a fleet-wide wedge vector;
// it now depends only on the GitHub API, which it already required and already
// retries.
//
// The node_modules fallback is a rollout shim, and stays as insurance for any
// caller that pins the reusable to a sha. Callers reference these workflows
// @main, so the workflow YAML and this script normally update together — but a
// run that started before the change landed and reaches this step after it
// would otherwise hard-fail on a file its older YAML never fetched. Anything
// other than a missing file (a corrupt or truncated bundle) is re-thrown rather
// than papered over: this gate fails closed.
let parseDocument, isAlias, isMap, isScalar, isSeq, minimatch;
try {
	({ parseDocument, isAlias, isMap, isScalar, isSeq, minimatch } = await import('./classifier-deps.mjs'));
} catch (e) {
	if (e?.code !== 'ERR_MODULE_NOT_FOUND') throw e;
	process.stderr.write(
		'classify.mjs: classifier-deps.mjs not found beside this script — falling back to ' +
			'node_modules. Verdicts are unaffected, but the workflow running this is out of ' +
			'date: it should fetch classifier-deps.mjs alongside classify.mjs.\n'
	);
	({ parseDocument, isAlias, isMap, isScalar, isSeq } = await import('yaml'));
	({ minimatch } = await import('minimatch'));
}

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

// The source text and the parsed document stay in reach after parsing: the
// wrapped-pattern guard below reads each entry's SOURCE, which the value alone
// cannot show.
let rules, yamlWarnings, source, doc;
try {
	source = readFileSync(RULES_PATH, 'utf8');
	doc = parseDocument(source);
	// parse() threw the first error; this keeps that path, and its message,
	// exactly as it was. What parseDocument() adds is the warnings, which
	// parse() only printed — see the guard below.
	if (doc.errors.length > 0) throw doc.errors[0];
	yamlWarnings = [...doc.warnings];
	// One warning never reaches doc.warnings: yaml raises it while converting
	// the document, when a mapping key is itself a collection ('[blocked]: …')
	// and gets stringified — to '[ blocked ]', silently dropping the class it
	// named. yaml reports it only through process.emitWarning — the channel its
	// logger (log.ts) uses, which yaml's own tests exercise — so collect what it
	// emits during the (synchronous) conversion and fail on that too. (Codex
	// review round 2 of this guard.)
	const emitWarning = process.emitWarning;
	process.emitWarning = (w) =>
		yamlWarnings.push(typeof w === 'string' ? { message: w, code: 'while converting' } : w);
	try {
		rules = doc.toJS();
	} finally {
		process.emitWarning = emitWarning;
	}
} catch (e) {
	fail(`failed to read ${RULES_PATH}: ${e.message}`);
}

// Every WARNING yaml reports fails closed, not only errors — the ones it
// collects in doc.warnings while parsing and the one it emits while converting
// (above). A warning is yaml carrying on with its best guess, and a guess in a
// rules file can be a rule that silently does nothing. The motivating case:
// an UNQUOTED entry that starts with '!' is a YAML tag, not text.
// '- !scripts/la1_deploy_ssh_setup.sh' and '- !secrets/**' name tags the
// parser cannot resolve, so it warns (TAG_RESOLVE_FAILED), drops the tag and
// keeps an EMPTY string — and the negation pass below looks for a '!' that is
// no longer there. Under blocked:/sensitive: that gate disappears; under
// always_review: codex-gate.mjs stops forcing a review of the path, so a
// 5-line diff to it skips Codex; and this script exits 0 throughout, the
// warning lost in the job log. Quoting fixes it, and a quoted '!x' is glob
// negation, which that pass rejects with its own reason. Tag spellings that
// resolve to '' WITHOUT a warning ('- !', '- !!str') are caught by the entry
// pass further down.
//
// ci-workflows#227 named this out of scope ("Rejecting empty patterns or YAML
// warnings would be a separate hardening"); the independent review of
// ci-workflows#228 raised it again. selftest/test_classify_dead_entry_guard.sh
// pins it, and the entry pass below, in every location.
//
// Fleet audit before adding both, 2026-09-23, exit-code-gated over all 148
// repos the token can see, and re-run on the final guard. Controls:
// whois-api-llc/whoisxmlapi-samples a 404 "Not Found" non-carrier; a bogus ref
// a "No commit found" bad ref, which is never read as an absence;
// topcoder1/ci-workflows a carrier. There are 46 carriers (45 live, 1
// archived), and 266 rules files — every default branch plus the head,
// test-merge and non-default base of all 187 open PRs. They hold 13,901
// entries with no warning (while parsing or converting), no empty, padded,
// multi-line, '#'-leading or non-string entry, and no '!' outside a comment.
// All 266 exit 0 with both guards, and every verdict is unchanged. In the same
// pass, synthetic tag, empty, non-string, collection-key and multi-line files
// flipped from 0 to 1, and a clean one stayed at 0.
if (yamlWarnings.length > 0) {
	fail(
		`${RULES_PATH}: the YAML parser warned — ` +
			yamlWarnings.map((w) => `${w.message.split('\n')[0].replace(/:$/, '')} (${w.code})`).join('; ') +
			`. A warning is not an error to the parser, which carries on with its best guess, so it ` +
			`fails closed here. The usual cause is an unquoted entry that starts with '!' ` +
			`('- !scripts/deploy.sh', '- !secrets/**'): YAML reads it as a TAG, not text, drops the ` +
			`tag it cannot resolve and keeps an EMPTY pattern, so the gate, exclusion or forced Codex ` +
			`review that line names silently disappears while this script exits 0. Quote every ` +
			`pattern ("- '…'"); a quoted leading '!' is glob negation, which is rejected on its own. ` +
			`A key written as a list or mapping ('[blocked]:') is turned into a string ('[ blocked ]') ` +
			`the same silent way, dropping the class it named: write the plain key ('blocked:').`
	);
}

// The top level must be a PLAIN mapping, or every gate disappears at once and
// this script still exits 0: each class is read as rules[cls], which is
// undefined on a list, on a scalar, and on the JS Set and Map that yaml builds —
// without a warning — for a top-level '!!set' or '!!omap'. The realistic shape
// is a file whose keys were all written as list items,
//
//     - blocked:
//         - '**/.env*'
//
// which YAML reads as ONE list of one-key mappings, so every PR classifies
// 'standard'. An empty or comment-only file (null) crashed on rules[cls] with a
// TypeError instead: closed, but naming nothing.
//
// Fleet audit before adding this guard and the three after it (the key
// allowlist, the wrapped-pattern guard, and the '/' and './' checks in the
// entry pass), 2026-09-23, exit-code-gated over all 148 repos the token can
// see, with the controls named on the warning guard above (plus
// whois-api-llc/dnssniper-prod-, recorded as an empty repository, not a
// non-carrier). 46 carriers (45 live, 1 archived) and 269 rules files — every
// default branch plus the head, test-merge and non-default base of all 187
// open PRs. Each is a plain mapping using only the nine allowed keys; their
// 14,217 entries hold no whitespace at all, so nothing is wrapped, and none
// ends with '/' or starts with '/' or './'. All 269 exit 0 before and after,
// and a per-path spot check of every distinct file changed no verdict. In the
// same pass a synthetic file of each shape flipped from 0 to 1, and a clean
// one holding all nine keys stayed at 0. The three always_review users
// (topcoder1/ipgeo_core, whois-api-llc/techrecon, whois-api-llc/wxa_webcat)
// all run pr-classify.yml, so these guards reach them: codex-gate.mjs still
// tolerates every one of these shapes on its own.
if (rules === null || rules === undefined) {
	fail(
		`${RULES_PATH}: holds no rules — it is empty, holds only comments, or is null — so no class ` +
			`would gate anything. Write the class lists at the top level ("blocked:\\n  - '…'").`
	);
}
if (typeof rules !== 'object' || Object.getPrototypeOf(rules) !== Object.prototype) {
	const kind = Array.isArray(rules)
		? 'a list'
		: typeof rules === 'object'
			? `a ${rules.constructor?.name ?? 'non-plain object'}`
			: `a ${typeof rules}`;
	fail(
		`${RULES_PATH}: the top level must be a mapping of class name → pattern list ` +
			`("blocked:\\n  - '…'"), got ${kind}. Every class is read from that mapping, so any other ` +
			`shape silently drops every gate while this script exits 0. A key written as a list item ` +
			`('- blocked:') makes the whole file one list: start each key at the beginning of its line.`
	);
}

// Every top-level key must be one a tool reads. A key nothing reads is
// ignored, so a misspelt class ('sensitve:', 'SENSITIVE:', 'blocked_paths:') is
// a gate that does not exist while this script exits 0. The allowlist is
// STRICT by choice (2026-09-23). The alternative, rejecting only keys within
// two edits of a known one, lets 'SENSITIVE:' (nine edits away) and
// 'blocked_paths:' (six) through. It holds the eight keys this script reads
// plus sensitive_deploy_gated, a mapping that dotclaude's /babysit-prs tooling
// reads (bb-pr-deploy-gated-derive.mjs) and this script ignores. The cost is
// coupling, taken on purpose: a tool that starts reading a NEW key from this
// file must add it here first. Until it does, the PR that adds the key to a
// repo fails its own classify check (pr-classify.yml reads the PR's
// test-merge), and once merged, both auto-merge lanes stop arming in that repo
// (they read the base branch's rules). exclude: already refuses a class name it
// does not know, for the same reason.
const KNOWN_KEYS = [...PATTERN_CLASSES, 'always_review', EXCLUDE_KEY, 'sensitive_deploy_gated'];
const unknownKeys = Object.keys(rules).filter((k) => !KNOWN_KEYS.includes(k));
if (unknownKeys.length > 0) {
	fail(
		`${RULES_PATH}: unknown top-level key${unknownKeys.length > 1 ? 's' : ''} ` +
			`${unknownKeys.map((k) => JSON.stringify(k)).join(', ')} — no tool reads a key it does not ` +
			`know, so a misspelt class is a gate that does not exist while this script exits 0. Keys ` +
			`are case-sensitive; valid keys are ${KNOWN_KEYS.join(', ')}.` +
			(unknownKeys.includes('standard')
				? ` 'standard' is not a key: it is the fallback for any path no class matches, and takes no list.`
				: '') +
			` A tool that reads a new key must add it to classify.mjs first.`
	);
}

// A scalar where a list belongs is a fail-OPEN, and a silent one. JS iterates
// a string per-character, so `sensitive: 'cmd/**'` becomes the patterns
// 'c','m','d','/','*','*' — none of which trips the bracket or negation guards
// below, and none of which matches a real path. The class simply stops gating.
// This is the gating-class twin of the exclude.<cls> guard further down; that
// one was caught in review on ci-workflows#145, which is what surfaced this.
//
// Fleet-audited before adding, because this guard hard-fails any repo it
// catches. Re-audited 2026-08-08 after the first pass was found faulty (see
// below): of 140 repos across topcoder1 + whois-api-llc, 45 carry a
// risk-paths.yml — matching the count cited in the negation guard below — and
// 95 carry none at all. Every class value in all 45 is a real list; zero
// scalars. Eight (whois-api-qa, app-factory, wxa-graph, usdev, netsniper,
// domains_collector, dnssniper, ProfessionalServices) have an EMPTY
// `sensitive:` key — null, not a scalar — which stays legal here exactly as
// `rules[cls] || []` already treated it. All 45 run through this script and
// exit 0, so the guard breaks no consumer.
//
// CORRECTION: ci-workflows#146 shipped this comment claiming "all 140 repos
// carry a risk-paths.yml". That was an artifact of the audit script, not a
// measurement. `gh api .../contents/<path>` prints a ~127-byte JSON error to
// STDOUT and exits 1 when the file is missing; the script tested only for an
// empty body, so all 140 counted as carriers, and the YAML analyzer parsed
// {"message":"Not Found"} as an object with no class keys and reported it
// clean. If you re-run a sweep like this, gate on the EXIT CODE and keep a
// known-missing repo as a negative control — "140 of 140" was the tell.
//
// Pick that control by RE-MEASURING it, never by trusting a name written
// here: a control is only a control while it stays a non-carrier, and this
// comment first named topcoder1/dotclaude — an active fleet repo, which is
// exactly the kind that acquires a rules file, and did (dotclaude#336,
// 2026-09-17). Prefer a repo outside the automerge fleet entirely;
// whois-api-llc/whoisxmlapi-samples is the current pick, a published samples
// repo with no .github/workflows at all, so no installer can give it one.
// Verify before relying on it — 404 + exit 1 is the non-carrier signal,
// and note that the error body lands on STDOUT, which is what made the
// original sweep miscount:
//
//   gh api repos/whois-api-llc/whoisxmlapi-samples/contents/.github/risk-paths.yml \
//     >/dev/null 2>&1; echo "rc=$?"    # rc=1 ⇒ genuine non-carrier
//
// Sweep of 2026-09-17, exit-code-gated over both orgs: 141 non-archived
// repos, 44 carriers, 97 non-carriers, 0 ambiguous reads.
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

// A pattern wrapped over lines is ONE pattern, not a list. YAML folds a line
// break inside a plain or quoted scalar, and between the lines of a '>' block,
// into a space, so
//
//     sensitive:
//       - cmd/**
//         internal/**
//
// is the single pattern 'cmd/** internal/**', which matches neither path, and
// this script exits 0. A flow list missing a comma ('[go.sum' then
// 'package-lock.json]' on the next line) folds the same way. The value cannot
// be told apart from a real interior space ('docs/My Notes/**'), which is why
// the entry pass below cannot catch it: this guard reads the SOURCE of every
// entry in the locations that pass covers — every class, always_review and
// every exclude: list, through aliases — and rejects a plain or single-quoted
// entry whose text spans lines, a double-quoted one written over lines whose
// value holds any whitespace, and a '>' block of more than one content line.
// Two spellings fold nothing and stay legal: a double-quoted line ending in an
// escaped '\' right after its last character, which joins the lines with
// nothing between them, and a one-line '>-' or '|-' block. (A one-line '>' or
// '|' block keeps a trailing newline, and a '|' block of several lines keeps
// its line breaks; the entry pass rejects both.)
const deref = (n) => (isAlias(n) ? n.resolve(doc) : n);
function isWrapped(n) {
	const text = source.slice(n.range[0], n.range[1]);
	if (n.type === 'PLAIN' || n.type === 'QUOTE_SINGLE') return /[\r\n]/.test(text);
	if (n.type === 'QUOTE_DOUBLE') {
		// An escaped line break ('\' ending the line) joins the lines with
		// nothing between them; any other line break folds into whitespace. The
		// VALUE tells the two apart however that whitespace was spelled — typed
		// before the '\', or an escape such as '\t', '\x20', '\_' or '\N' (U+0085,
		// which \s omits) on either side of it — so a double-quoted entry written
		// over lines is rejected when its value holds any. A real interior space
		// written over lines is refused with it; the fleet has none, and such a
		// pattern fits on one line. This replaced a scan of the source for the
		// characters before each '\' that the independent review and Codex round
		// 5 each showed an escape could slip past.
		return /[\r\n]/.test(text) && /[\s\u0085]/.test(n.value);
	}
	if (n.type === 'BLOCK_FOLDED') {
		// The first line is the '>' header; the rest is the content.
		return text.split(/\r\n|\r|\n/).slice(1).filter((l) => l.trim() !== '').length > 1;
	}
	return false;
}
// The pairs of a mapping node, keyed the way toJS() keys them: an alias key
// ('? *cls') is the key it names, so looking a class up by name would miss the
// list under it. (Codex review round 1 of this guard.) A '<<' merge key — an
// explicit '!!merge <<', or any '<<' under '%YAML 1.1' — copies another
// mapping's pairs in, so a class list could come from anywhere in the file; no
// rules file needs one, and it is refused rather than traced.
//
// A key repeated in a way yaml does not report is refused too. yaml errors on
// a repeated key only when both are the same scalar, so '*k :' repeating
// 'sensitive:' (or 1 beside "1") parses cleanly, and toJS() keeps the LAST
// list — the gate under the first silently disappears. (Independent review of
// this guard; main has the same hole.)
function pairsOf(map, where) {
	const seen = new Set();
	return map.items.map(({ key, value }) => {
		const k = deref(key);
		if (isScalar(k) && typeof k.value === 'symbol') {
			fail(
				`${RULES_PATH}: ${where} uses a '<<' merge key — it copies another mapping's keys into this ` +
					`one, so a class list would be assembled from elsewhere in the file, out of reach of ` +
					`the checks that read each entry's source. Write the keys out in full.`
			);
		}
		const name = isScalar(k) ? k.value : k;
		if (seen.has(String(name))) {
			fail(
				`${RULES_PATH}: ${where} repeats the key ${JSON.stringify(String(name))} — yaml reports a ` +
					`repeated key only when both are the same scalar, not an alias key ('*k :') or a ` +
					`number beside a string (1 and "1"), and the later list silently replaces the earlier ` +
					`one, so every pattern under the first is dropped. Merge them under one key.`
			);
		}
		seen.add(String(name));
		return [name, value];
	});
}
const entryLists = [];
for (const [key, value] of pairsOf(doc.contents, 'the top level')) {
	if ([...PATTERN_CLASSES, 'always_review'].includes(key)) entryLists.push([key, value]);
	const excludeNode = key === EXCLUDE_KEY ? deref(value) : null;
	if (isMap(excludeNode)) {
		for (const [cls, list] of pairsOf(excludeNode, `'${EXCLUDE_KEY}:'`)) {
			entryLists.push([`${EXCLUDE_KEY}.${cls}`, list]);
		}
	}
}
for (const [where, list] of entryLists) {
	const seq = deref(list);
	if (!isSeq(seq)) continue; // absent, empty, or a shape the list guards name
	for (const item of seq.items) {
		const n = deref(item);
		if (isScalar(n) && isWrapped(n)) {
			fail(
				`${RULES_PATH}: entry ${JSON.stringify(n.value)} (under '${where}:') is wrapped over ` +
					`several lines — YAML joins the lines of a plain or quoted scalar, or of a '>' block, ` +
					`into ONE pattern (a single line break becomes a space), not the list it looks like, ` +
					`so it matches none of the paths its lines name. Give each pattern its own "- '…'" ` +
					`line; in a '[…]' flow list, separate the entries with commas. To break one long ` +
					`pattern, end the line inside double quotes with '\\' right after its last ` +
					`character, which joins the lines with nothing between them; a double-quoted entry ` +
					`written over several lines must hold no whitespace at all, so a pattern with a ` +
					`real space in it goes on one line.`
			);
		}
	}
}

// Every entry must be a string that some changed path could match: in every
// class, in always_review, and — through the same checkEntry() — in every
// exclude: list below. The passes after this one test strings only and skip
// anything else, so before this pass these entries went unchecked:
//
// An empty or whitespace-only string matches no changed path. It reads like a
// rule and does nothing. YAML makes one without a warning from a bare '- !'
// (its non-specific tag) or '- !!str', so the warning guard above cannot see
// these.
//
// A non-string entry — '- 42', 'true', 'null', '~', a bare '-', 'key: value',
// '[…]' — is skipped outright by the passes below and by isExcluded(), so in
// exclude: it silently exempts nothing. In a class list or always_review it
// makes minimatch throw ('invalid pattern'), but only for a changed file that
// reaches it: classify() and codex-gate.mjs both stop at a file's first match.
// So the same line crashes one PR's classification and is silently skipped on
// the next, and in always_review it fails the Codex job instead of naming
// itself. Rejecting it here, on every PR, makes it loud in the right place.
//
// Three kinds of string can never match either (found by the independent
// review and Codex round 5 of this guard). Changed paths are read one per line
// and trimmed before matching (see changedFiles below and codex-gate.mjs), so a
// pattern with leading or trailing whitespace matches nothing — a '|' or '>'
// block scalar keeps a trailing newline — and neither does one with a line
// break inside, which is what a '|' block of several lines or a "\n" escape
// becomes: ONE pattern, not a list. (A '>' block, or a plain or quoted scalar
// wrapped over lines, folds its lines into spaces instead, and no value check
// can tell that space from a real one like 'docs/My Notes/**': the
// wrapped-pattern guard above reads the source, and names every one of them
// before this pass runs — including a '>' or '>+' block, which keeps a
// trailing newline. That order matters: this pass's advice for a padded entry,
// one quoted line, would turn a wrapped pair into a single dead pattern.)
// And minimatch reads a pattern that starts with '#' as a comment, which
// matches nothing: a quoted '#…' is exactly what an author gets by quoting a
// '- #scripts/x.sh' line as written, which YAML read as a comment (null).
//
// Fail closed on all of them, in the style of the other passes: a rules entry
// nobody can match is a gate that is not there. The fleet audit is recorded
// on the warning guard above; no caller carries any of these shapes.
function checkEntry(p, where) {
	if (typeof p !== 'string') {
		const kind =
			p === null ? 'null' : Array.isArray(p) ? 'a list' : typeof p === 'object' ? 'a mapping' : `a ${typeof p}`;
		// Show the value, to help find the line. A YAML alias to its own anchor
		// ('- &x [*x]') is a legal cycle that JSON.stringify throws on, and the
		// message must still come from fail(). (Codex review round 3.)
		let shown;
		try {
			shown = p !== null && typeof p === 'object' ? JSON.stringify(p) : String(p);
		} catch {
			shown = '(recursive)';
		}
		fail(
			`${RULES_PATH}: entry ${shown} (under '${where}:') is ${kind}, not a string — ` +
				`YAML reads an unquoted number or true/false as that type, a bare '-', 'null', '~' or a ` +
				`'- #…' comment as null, and 'key: value' or '[…]' as a collection. ` +
				(where.startsWith(`${EXCLUDE_KEY}.`)
					? `An exclusion that is not a string is skipped, so it silently exempts nothing. `
					: `minimatch throws on anything but a string, so on a PR with a changed file that ` +
						`reaches the entry ` +
						(where === 'always_review' ? 'codex-gate.mjs fails the Codex job' : 'this script crashes') +
						`, and on every other PR the line silently matches nothing. `) +
				`Quote the path you meant ("- '…'") or delete the line.`
		);
	}
	// The four string checks below say "matches no changed path", not "gates
	// nothing": in exclude: a dead entry exempts nothing, which leaves its paths
	// gated, and in a safe class its paths fall through to the next class that
	// matches them, or to 'standard' when none does.
	if (p.trim() === '') {
		fail(
			`${RULES_PATH}: entry ${JSON.stringify(p)} (under '${where}:') is empty or whitespace-only — ` +
				`changed paths are trimmed before they are matched and empty ones dropped, so it ` +
				`matches no changed path while reading like a rule. A bare '- !' or '- !!str' parses ` +
				`this way too: YAML reads the '!' as a tag, not text. Write the path you meant, quoted ` +
				`("- '…'"), or delete the line.`
		);
	}
	if (p !== p.trim()) {
		fail(
			`${RULES_PATH}: entry ${JSON.stringify(p)} (under '${where}:') has leading or trailing whitespace — ` +
				`changed paths are trimmed before they are matched, so none starts or ends with ` +
				`whitespace and the entry matches no changed path. A '|' or '>' block scalar keeps a ` +
				`trailing newline this way. Write the pattern on one quoted line with nothing around ` +
				`it ("- '…'").`
		);
	}
	if (/[\r\n]/.test(p)) {
		fail(
			`${RULES_PATH}: entry ${JSON.stringify(p)} (under '${where}:') contains a line break — ` +
				`changed paths arrive one per line, so none contains one and the entry matches no ` +
				`changed path. A '|' block scalar of several lines is ONE pattern, not a ` +
				`list: give each pattern its own "- '…'" line.`
		);
	}
	if (p.startsWith('#')) {
		fail(
			`${RULES_PATH}: entry ${JSON.stringify(p)} (under '${where}:') starts with '#' — minimatch ` +
				`reads a pattern that starts with '#' as a comment, so it matches no changed path. ` +
				`If the path was commented out, delete the line; to match a path that really starts ` +
				`with '#', escape it ('\\#…').`
		);
	}
	// Changed paths are the repo-relative paths of FILES, so none ends with '/'
	// or starts with '/' or './' — and minimatch keeps a leading '.' segment,
	// so './infra/**' is no alias of 'infra/**'. Each shape is a habit carried
	// in from CODEOWNERS or .gitignore, where 'infra/' means everything under
	// infra/ and a leading '/' anchors a pattern to the repo root; here every
	// pattern is already anchored there. Brace alternatives are checked too,
	// since '{infra/,terraform/}' spells the same dead entry twice. A NEGATED
	// entry is left to the negation pass below, which rejects it in every
	// location: '!tests/' matches nearly every path, not none, and that pass
	// says why. (Codex review round 3 of this guard.)
	if (usesNegation(p)) return;
	for (const alt of [p, ...minimatch.braceExpand(p)]) {
		// Judged as minimatch reads it: '\.' is a literal '.', so '\./infra/**'
		// is the dead './infra/**' to it. (Codex review round 6 of this guard.)
		const s = minimatch.unescape(alt);
		const shape = s.endsWith('/')
			? "ends with '/'"
			: s.startsWith('./')
				? "starts with './'"
				: s.startsWith('/')
					? "starts with '/'"
					: '';
		if (shape) {
			fail(
				`${RULES_PATH}: entry ${JSON.stringify(p)} (under '${where}:') ${shape}` +
					(alt !== p
						? ` (brace alternative ${JSON.stringify(s)})`
						: s !== p
							? ` (minimatch reads it as ${JSON.stringify(s)})`
							: '') +
					` — changed paths are the repo-relative paths of files, so none ends with '/' or ` +
					`starts with '/' or './', and ${alt === p ? 'the entry' : 'that alternative'} matches no ` +
					`changed path. ` +
					(s.endsWith('/')
						? `In CODEOWNERS and .gitignore 'infra/' means everything under infra/; here that is 'infra/**'.`
						: s.startsWith('./')
							? `Drop the './': every pattern here is already relative to the repo root.`
							: `Drop the leading '/': in CODEOWNERS and .gitignore it anchors a pattern to the ` +
								`repo root, and every pattern here is already anchored there.`)
			);
		}
	}
}
for (const cls of [...PATTERN_CLASSES, 'always_review']) {
	for (const p of rules[cls] || []) checkEntry(p, cls);
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
// semantics. That gate tolerates an unparseable file or a non-list value
// (either reads as no always_review at all) and applies any string it is
// given without a word, so this script's fail-closed passes are the only
// place a dead always_review entry gets caught before it silently skips a
// required Codex review. The gate throws on a non-string entry, which fails
// the Codex job rather than naming the line; the entry pass above names it
// here.
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

// Glob negation fails closed in EVERY pattern class, for a different reason in
// each half of PATTERN_CLASSES, and in always_review for a third.
//
// In the gating classes it is incompatible with the case-fold, and breaks its
// one invariant. '!' inverts the match, so folding case REMOVES gating rather
// than adding it: minimatch('FOO', '!foo') is true (gated) but false under
// {nocase:true} (ungated) — a downgrade. Segment extglobs have the same shape:
// 'src/!(*.md)' matches 'src/A.MD' today and stops matching once case is
// folded. Fail closed rather than quietly violate the invariant classify()
// documents. Zero of the 45 repos carrying a risk-paths.yml used negation in a
// gating class (fleet audit 2026-07-14). (Codex round-2 P2 on the change that
// introduced the fold.)
//
// In the safe classes it is a fail-OPEN on its own, fold or no fold. A negated
// entry matches every path EXCEPT the one it names, and classify() returns the
// first class with a match — so one gitignore-style line,
//
//     safe_test: ['tests/**', '!tests/fixtures/**']
//
// classifies every file that is not blocked or sensitive as safe_test: all of
// the repo's `standard` code becomes auto-merge eligible, and so does every
// file a future PR adds. A '!(…)' extglob is the same complement scoped to one
// segment ('**/!(*.md)' is every non-markdown file in the repo). Paths come back
// OUT of a class through exclude:, which subtracts only what it names. Found by
// an independent code review during topcoder1/webcrawl#579 (2026-09-22), and
// verified against the vendored bundle: minimatch(
// 'src/webcrawl/aws_pipeline/crawl_lock.py', '!no_such_file', {dot: true,
// matchBase: false}) is true. Fleet audit before extending the ban, same day,
// exit-code-gated over all 148 repos the token can see (controls:
// whois-api-llc/whoisxmlapi-samples a 404 non-carrier, topcoder1/ci-workflows a
// carrier): 45 carriers, and 267 rules files — every default branch plus the
// merge ref, head and non-default base of all 188 open PRs — hold 13,940
// patterns and not one '!' outside a comment, so nothing is negated in any
// class by any spelling. All 267 still exit 0 with this guard.
//
// In always_review it inverts the list's one job. This script never matches
// always_review, but codex-gate.mjs forces a Codex review whenever ANY changed
// file matches ANY entry, and to minimatch a negated entry is a valid glob, so
// the gate applies it without a word: it is caught here or nowhere. It forces
// review on every path EXCEPT the one it names: small and docs/tests-only diffs
// to that path alone skip Codex, while every other diff is pushed into review.
// always_review has no exclude:, so there is no subtraction to rewrite it into.
// ci-workflows#227 left this list out on purpose: a match only ever ADDS a
// Codex run, so negation can widen review but never narrow it. True against a
// file without the entry, not against the entry the author wrote: the list
// exists to force review of the paths it names, and negation exempts exactly
// the named one, the same intent argument the bracket pass above makes for a
// dead entry. A deliberate segment extglob ('src/!(generated)/**') is where
// #227 is right: it forces exactly what it means and cannot fail open. It is
// rejected anyway, as the bracket pass rejects an intentional '*.[jt]s': no
// check can tell it from an accident, and the fleet uses none. Its rewrite is
// 'src/**', which over-forces in the safe direction, not a list of
// subdirectories, which leaves each new one to the cost gate. An independent
// review on whois-api-llc/wxa_webcat#1612 (2026-09-23) measured
// '!scripts/la1_deploy_ssh_setup.sh' passing this script with exit 0 and that
// path's small diffs skipping Codex. Fleet audit before extending the ban,
// same day, exit-code-gated with the same controls:
// 142 non-archived repos, 45 carriers, and 247 rules files (every default
// branch plus the head, test-merge and non-default base of all 176 open PRs).
// Three carry always_review (topcoder1/ipgeo_core, whois-api-llc/techrecon,
// whois-api-llc/wxa_webcat), none negates an entry, and all 247 exit 0 with
// this guard.
//
// Every guard site — all three here and the exclude: guard below — tests a
// pattern with usesNegation(), which reads minimatch's own brace expansion as
// well as the raw string, because braces can assemble an extglob negation the
// raw pattern never spells: '{!,@}(tests)/**' has neither a leading '!' nor
// '!(', yet minimatch expands it to '!(tests)/**' + '@(tests)/**', which
// together match every path below the root (Codex round 1 on the change that
// extended this guard). Expansion can move a '!' or '(' but never mint one: a
// range takes only letter or number endpoints and none yields either character,
// so a pattern with no '!' cannot build a negation. A '!' that expansion moves
// to the front never negates the whole pattern — minimatch settles that before
// it expands braces — so flagging it when no '(' follows is merely strict.
//
// So — as with the bracket guard above — strictness costs nothing today and
// stops the footgun from ever being introduced. selftest/test_classify_nocase.sh
// (case 10) pins the gating half; selftest/test_classify_negation_guard.sh pins
// the safe half, always_review (case 9) and the brace-built spellings at every
// guard site.
function usesNegation(p) {
	return [p, ...minimatch.braceExpand(p)].some((s) => s.trimStart().startsWith('!') || s.includes('!('));
}
for (const cls of [...PATTERN_CLASSES, 'always_review']) {
	for (const p of rules[cls] || []) {
		if (typeof p === 'string' && usesNegation(p)) {
			fail(
				NOCASE_CLASSES.has(cls)
					? `${RULES_PATH}: pattern '${p}' (under '${cls}:') uses glob negation — ` +
							`'${cls}' is matched case-insensitively so that a lowercase pattern still ` +
							`catches real-world case variants, and negation inverts that: folding case ` +
							`REMOVES gating instead of adding it (minimatch('FOO','!foo') is true, but ` +
							`false with nocase). Express the rule positively — list the paths you want ` +
							`gated rather than the ones you don't. Context: wxa-jake-ai#877.`
					: cls === 'always_review'
						? `${RULES_PATH}: pattern '${p}' (under '${cls}:') uses glob negation — ` +
								`codex-gate.mjs forces a Codex review whenever ANY changed file matches ANY ` +
								`'${cls}' entry, and a leading '!' matches every path EXCEPT the one it names. ` +
								`The named path is the one path the entry does not force: small and ` +
								`docs/tests-only diffs to it alone skip Codex, while a diff to any other path ` +
								`is forced into review; a '!(…)' extglob does the same within its segment. ` +
								`List the paths that must always be reviewed positively ('${cls}' has no ` +
								`'${EXCLUDE_KEY}:'): prefer a broader glob such as 'src/**', which over-forces ` +
								`in the safe direction, to a list of subdirectories, which leaves each new ` +
								`one to the size and docs/tests skips.`
						: `${RULES_PATH}: pattern '${p}' (under '${cls}:') uses glob negation — ` +
								`negation inverts the match. A leading '!' matches every path EXCEPT the one ` +
								`it names, and classify() takes the first class that matches, so one such ` +
								`entry reclassifies every other ungated file (anything blocked: and sensitive: don't ` +
								`catch) into an auto-merge-eligible tier instead of the strict 'standard' ` +
								`fallback — including every file a future PR adds; a '!(…)' extglob does the ` +
								`same within its segment. List the paths you want in '${cls}' positively; to ` +
								`carve some back out, use "${EXCLUDE_KEY}:\\n  ${cls}:\\n    - '…'", which ` +
								`subtracts only what it names.`
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
	// Subtracting from `blocked` is refused outright. blocked is the top class
	// (it outranks sensitive when a PR matches both) and the hardest human
	// gate among the lanes that read this verdict: claude-author-automerge.yml
	// and safe-paths-automerge.yml refuse to arm it, and no bypass label or
	// Codex-success bypass releases it. Both lanes refuse sensitive the same
	// way, but sensitive has one sanctioned exception — a repo's declared
	// sensitive_deploy_gated subset, which dotclaude's /babysit-prs loop may
	// merge while the deploy hold is on (commands/babysit-prs.md,
	// operator-authorised 2026-09-10; ci-workflows#191 proposes the same for
	// claude-author-automerge.yml); blocked has none. dependabot-auto-merge.yml
	// does not read this verdict at all: it arms Dependabot patch and minor
	// bumps outside the github_actions ecosystem (minor unless the caller sets
	// allow_minor: false), so a Dependabot Dockerfile bump can merge with no
	// human (whois-api-llc/techrecon#952, a minor golang bump, risk:blocked,
	// 2026-08-28).
	//
	// A typical blocked: list carries the secrets family ('**/.env*',
	// '**/secrets*'), Dockerfiles and docker-compose, CI workflows, the
	// classifier config itself and infra/, terraform/, k8s/ — the set
	// pr-classify.yml's sticky comment names. A stray '**' in an exclusion
	// there silently un-gates all of it, and an exclusion is exactly the kind
	// of subtraction that is easy to get subtly wrong, where deleting a
	// blocked: entry outright is at least visible in review. No concrete need
	// for this has appeared; per the same reasoning as the bracket and
	// negation bans above, strictness costs nothing today. Lift this if a real
	// case turns up.
	//
	// CORRECTION: from ci-workflows#145 (2026-08-07) until this rewrite, this
	// comment and the message below said blocked "hard-fails the classify
	// check and never bypasses". The first half was already false when
	// written: pr-classify.yml stopped exiting non-zero on blocked in
	// ci-workflows#21 (2026-05-02); it labels risk:blocked and posts a sticky
	// manual-merge comment, and the check stays green. The second half holds
	// only for the lanes that read this verdict (see dependabot above). The
	// claim surfaced while choosing a tier in wxa_webcat#1607, whose final
	// reasoning rests on precedent and Codex routing instead.
	//
	// Choosing between blocked and sensitive for a path? Beyond the above, the
	// difference is set by each caller — above all its pr-codex-review.yml,
	// which decides whether a blocked PR gets a Codex review at all and is not
	// uniform: a 2026-09-22 sweep of both orgs found 42 of 44 callers whose
	// review job admits blocked, while this repo's own caller and wxa_webcat's
	// admit only sensitive and standard. Read the caller's job `if:` and its
	// `paths-ignore` (which can skip workflow and Dockerfile PRs entirely)
	// before choosing a tier for its review coverage.
	if (cls === 'blocked') {
		fail(
			`${RULES_PATH}: '${EXCLUDE_KEY}:' may not subtract from 'blocked' — it is the top class and ` +
				`typically covers the secrets, Dockerfile, workflow and infra paths, which an over-broad ` +
				`exclusion would silently un-gate. Narrow the 'blocked:' patterns themselves if something ` +
				`is over-matched, so the change is visible rather than subtracted.`
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
		checkEntry(p, `${EXCLUDE_KEY}.${cls}`);
		if (p.includes('[') || p.includes(']')) {
			fail(
				`${RULES_PATH}: pattern '${p}' (under '${EXCLUDE_KEY}.${cls}:') contains a bracket — ` +
					`minimatch reads '[...]' as a character class, so the exclusion matches nothing and ` +
					`the paths you meant to exempt stay gated. Replace the bracket segment with '*', or ` +
					`enumerate. Same rule as the gating classes.`
			);
		}
		if (usesNegation(p)) {
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
