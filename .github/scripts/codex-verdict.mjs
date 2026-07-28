// Codex verdict gate. Classifies the verdict text produced by
// codex-review.yml and, when the caller opts in, FAILS the job on a
// regression instead of merely commenting it.
//
// Why this exists: codex-review.yml has always posted Codex's verdict as a
// PR comment and exited 0 regardless of what the verdict said (its only
// `exit 1` is the 3000-file cost gate). A green check plus a comment nobody
// re-reads is not a gate. On topcoder1/domain-rank#74 and #79 — both on
// 2026-07-27 — Codex reported a missing-test regression on each PR and both
// merged with the finding unaddressed.
//
// Opt-in by design: callers pass `fail_on_regression: true`. The default is
// false, so the reusable's existing consumers keep today's advisory
// behavior. Many Codex findings are advisories that get correctly declined,
// so blocking-by-default would be wrong.
//
// Secondary effect worth knowing when you opt in: claude-author-automerge.yml
// treats a SUCCESS conclusion on the configured `codex_check_name` as a
// bypass of the risk-tier manual-merge gate (Option B). It requires an
// explicit success, so a job that fails here also withdraws that bypass —
// a regression can no longer read as "second-model reviewed".
//
// Inputs (from env):
//   VERDICT_FILE        path to the extracted verdict (default /tmp/codex.verdict)
//   FAIL_ON_REGRESSION  "true" to enforce; anything else reports only
//   GITHUB_OUTPUT       (optional) — verdict_state=clean|regression|unparseable
//   GITHUB_STEP_SUMMARY (optional) — append markdown summary
//
// Exit code: 1 only when FAIL_ON_REGRESSION=true AND the verdict is not
// clean. Report-only mode always exits 0.

import { readFileSync, existsSync, appendFileSync } from 'node:fs';

const verdictFile = process.env.VERDICT_FILE || '/tmp/codex.verdict';
const enforce = (process.env.FAIL_ON_REGRESSION || '').trim().toLowerCase() === 'true';

// A missing file means the review step did not produce a verdict. Treat it
// like an unparseable one (fail closed under enforcement) rather than
// silently passing — "no verdict" is exactly the state we cannot vouch for.
const raw = existsSync(verdictFile) ? readFileSync(verdictFile, 'utf8') : '';

// Normalize for matching only; `raw` is still what gets reported. Markdown
// emphasis is stripped because Codex sometimes bolds its verdict line, which
// would otherwise break the `regression:` anchor.
const text = raw
  .replace(/[`*_]/g, ' ')
  .replace(/\s+/g, ' ')
  .trim()
  .toLowerCase();

// Codex is instructed to answer in one of three shapes:
//   no regressions found
//   regression: <file:line> - <one sentence>
//   regression: <file:line> - <one>; regression: <file:line> - <two>
// Multi-finding verdicts are semicolon-separated, so split findings on `;`.
const NON_FINDING = /^(none|nothing|n\/a|na|no)\b/;
const findings = [...text.matchAll(/\bregression\s*:\s*([^;]*)/g)]
  .map((m) => m[1].trim())
  .filter(Boolean)
  // "regression: none" is Codex answering in the finding shape but reporting
  // nothing. Counting it would block a clean PR.
  .filter((d) => !NON_FINDING.test(d));

// Codex frequently paraphrases the clean verdict rather than emitting the
// canonical string — the pre-review of this very change answered "No
// actionable regressions were identified", which an exact-match on
// "no regressions found" would have failed under enforcement. Match the
// negative-finding family instead: "no <adj>* <noun> <adv>* <verb>".
// Widening this is safe in the direction that matters, because a verdict
// using the `regression:` form is already decided above.
const CLEAN =
  /\bno\s+(?:\w+\s+){0,3}(?:regressions?|issues?|problems?|concerns?|findings?)\s+(?:\w+\s+){0,2}(?:found|identified|detected|observed|spotted|noted)\b/;

// A hedge AFTER the clean phrase means Codex cleared the diff and then
// qualified it ("no regressions found, but the new branch is untested").
// That is not a clean verdict this gate can vouch for, and because the
// qualifier skips the `regression:` form it would otherwise pass. Scoped to
// the text following the clean phrase so an incidental "but" earlier in the
// reasoning does not demote an otherwise clean answer.
const HEDGE = /\b(?:but|however|although|though|except|caveat)\b/;

// Order matters: a verdict that lists findings is a regression even if the
// surrounding prose also contains a clean phrase somewhere.
let state;
const cleanMatch = text.match(CLEAN);
if (findings.length > 0) {
  state = 'regression';
} else if (cleanMatch && !HEDGE.test(text.slice(cleanMatch.index + cleanMatch[0].length))) {
  state = 'clean';
} else {
  state = 'unparseable';
}

const summary = {
  clean: 'Codex reported no regressions.',
  regression: `Codex reported ${findings.length} regression(s).`,
  unparseable:
    'Codex produced no verdict this gate could classify — treated as unresolved.'
}[state];

if (process.env.GITHUB_OUTPUT) {
  appendFileSync(process.env.GITHUB_OUTPUT, `verdict_state=${state}\n`);
}
if (process.env.GITHUB_STEP_SUMMARY) {
  appendFileSync(
    process.env.GITHUB_STEP_SUMMARY,
    `### Codex verdict gate\n\n- State: \`${state}\`\n- Enforcing: \`${enforce}\`\n- ${summary}\n`
  );
}

console.log(`Verdict: state=${state}; enforcing=${enforce}; ${summary}`);
for (const f of findings) console.log(`  - regression: ${f}`);

if (enforce && state !== 'clean') {
  const hint =
    state === 'regression'
      ? 'Address the finding, or reply on the PR explaining why it is declined and re-run this check.'
      : 'Re-run the Codex review; if it keeps producing no parseable verdict, check the workflow logs.';
  console.log(`::error::Codex review did not come back clean (${state}). ${hint}`);
  process.exit(1);
}
