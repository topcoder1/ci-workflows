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
//   GITHUB_OUTPUT       (optional) — verdict_state=clean|regression|no_verdict
//   GITHUB_STEP_SUMMARY (optional) — append markdown summary
//
// Exit code: 1 only when FAIL_ON_REGRESSION=true AND the verdict is not
// clean. Report-only mode always exits 0.

import { readFileSync, existsSync, appendFileSync } from 'node:fs';

const verdictFile = process.env.VERDICT_FILE || '/tmp/codex.verdict';
const enforce = (process.env.FAIL_ON_REGRESSION || '').trim().toLowerCase() === 'true';

// A missing file means the review step never wrote a verdict. It reads as
// the empty string, which lands in `no_verdict` below — fail closed under
// enforcement rather than silently passing a review that did not happen.
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

// THE TRAILER IS THE VERDICT. codex-review.yml's prompt requires the response
// to end with exactly `VERDICT: CLEAN` or `VERDICT: REGRESSION`, and that line
// is what decides here. Everything else in the response is prose for a human.
//
// This exists because BOTH prose-reading rules fail, and each was tried:
//
//   - Requiring a recognizable clean phrase false-fails clean reviews. Codex
//     phrases "nothing found" freely: "no regressions found", "No actionable
//     regressions were identified", and one live verdict that just described
//     the diff approvingly with no negative-finding phrase at all. A gate
//     that reddens clean PRs gets switched off.
//   - Treating any prose without a `regression:` token as clean lets an
//     off-format finding through — "The new fallback branch has no test."
//     reads clean and, worse, restores the auto-merge bypass. (Codex review
//     round 1 caught exactly this on the previous revision.)
//
// One required output line is far more reliable to produce than a three-shape
// contract, and non-compliance is now a single crisp signal instead of a
// judgement call about English.
// It must be the FINAL non-empty line, because that is what the prompt asks
// for. Accepting the marker anywhere would let trailing prose slip past it:
// "VERDICT: CLEAN" followed by "Also, the new branch has no test." would read
// clean, which is the same off-format-finding hole in a new costume. A marker
// that is not last means the response did not follow the contract, so it
// falls through to no_verdict below and fails closed. (Codex review round 2.)
//
// Scanned against markdown-stripped text that still has its line structure —
// `text` above collapsed newlines for the finding scan, which would defeat a
// line anchor.
// DELIBERATELY NOT trimming trailing CLI telemetry here. codex-review.yml's
// awk extraction keeps everything after the last `codex` marker, so anything
// the CLI printed below the model's answer would become the final line, and
// three successive attempts to filter that out were each shown to swallow a
// real finding instead — "Usage: the token refresh path has no test.",
// "Tokens used: 1 token can authorize every tenant". Every such filter is a
// hole in the strict final-line rule, which is the actual security property.
//
// It was defending a footer that does not exist: codex-cli 0.145.0 prints
// nothing after the response (verified against real output 2026-07-27).
//
// If a future CLI does add one, the trailer stops being last, the gate reports
// no_verdict, and enforcing repos go RED. That is loud, immediately
// diagnosable, and fixed by one narrow filter written against the actual
// footer format. The alternative — a speculative filter that silently eats a
// finding — fails in the direction this gate exists to prevent. Do not re-add
// one without a real footer sample to match against.
const contentLines = raw
  .replace(/[`*_]/g, ' ')
  .split('\n')
  .map((l) => l.trim())
  .filter((l) => l !== '');
const lastLine = contentLines.length ? contentLines[contentLines.length - 1] : '';
const trailerMatch = lastLine.match(/^verdict:\s*(clean|regression)\s*\.?$/i);
const trailer = trailerMatch ? trailerMatch[1].toLowerCase() : null;

// codex-review.yml writes this exact sentinel when its awk extraction comes
// up empty.
const NO_VERDICT_SENTINEL = /codex produced no parseable verdict/;

let state;
if (trailer) {
  // Authoritative. A response that lists findings and then claims CLEAN is
  // still a regression — the findings are the evidence, the trailer is not
  // allowed to retract them.
  state = trailer === 'regression' || findings.length > 0 ? 'regression' : 'clean';
} else if (findings.length > 0) {
  // No trailer, but it reported in the finding form. Believe the findings.
  state = 'regression';
} else {
  // No trailer and no findings: the response did not answer the contract, so
  // there is nothing to vouch for. Fail closed. This also covers an empty or
  // missing verdict file and the workflow's own no-parseable-verdict
  // sentinel — a review that did not happen must never read as "clean".
  state = 'no_verdict';
  if (text !== '' && !NO_VERDICT_SENTINEL.test(text)) {
    console.log(
      '::warning::Codex answered without the required `VERDICT:` trailer. ' +
        'Treating as no verdict.'
    );
  }
}

const summary = {
  clean: 'Codex reported no regressions.',
  regression: `Codex reported ${findings.length} regression(s).`,
  no_verdict:
    'Codex produced no verdict at all — the review did not happen, so nothing is vouched for.'
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
      : 'The review produced no verdict at all — re-run it, and check the workflow logs if it keeps coming back empty.';
  console.log(`::error::Codex review did not come back clean (${state}). ${hint}`);
  process.exit(1);
}
