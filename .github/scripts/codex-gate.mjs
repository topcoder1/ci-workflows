// Codex cost gate. Decides whether the reusable codex-review.yml workflow
// should actually invoke `codex review`, or skip to save API spend.
//
// Inputs (from env):
//   CHANGED_FILES      newline-separated list of files in the PR diff
//   DIFF_LINES         total +/- lines in the PR diff
//   SIZE_THRESHOLD     skip if lines < threshold (default 30)
//   GITHUB_OUTPUT      (optional) — write KEY=VALUE here for downstream steps
//   GITHUB_STEP_SUMMARY (optional) — append markdown summary
//
// Reads: .github/risk-paths.yml (caller's checkout) for `always_review:`
//
// Decision priority (highest wins):
//   1. ANY changed file matches always_review → RUN (bypass all escapes)
//   2. lines < SIZE_THRESHOLD                 → SKIP "small diff"
//   3. ALL changed files are docs/tests       → SKIP "docs/tests only"
//   4. otherwise                              → RUN

import { readFileSync, existsSync, appendFileSync } from 'node:fs';
import { parse } from 'yaml';
import { minimatch } from 'minimatch';

const files = (process.env.CHANGED_FILES || '')
  .split('\n')
  .map((s) => s.trim())
  .filter(Boolean);
const lines = parseInt(process.env.DIFF_LINES || '0', 10);
const threshold = parseInt(process.env.SIZE_THRESHOLD || '30', 10);

let alwaysReview = [];
if (existsSync('.github/risk-paths.yml')) {
  try {
    const rules = parse(readFileSync('.github/risk-paths.yml', 'utf8')) || {};
    if (Array.isArray(rules.always_review)) alwaysReview = rules.always_review;
  } catch {
    // Tolerate parse errors — gate stays permissive (no always_review match).
  }
}

const matchOpts = { dot: true };
const matched = (globs) => (f) => globs.some((p) => minimatch(f, p, matchOpts));
const alwaysHits = files.filter(matched(alwaysReview));

// Docs/tests heuristic — files where Codex's three-axis prompt rarely earns
// its cost. Conservative: only patterns that almost never carry runtime risk.
const docTestGlobs = [
  '**/*.md',
  '**/*.mdx',
  'docs/**',
  '**/docs/**',
  'tests/**',
  '**/tests/**',
  '**/__tests__/**',
  '**/*.test.*',
  '**/*.spec.*',
  '**/*_test.go',
  '**/test_*.py',
  '**/*_test.py',
  'LICENSE',
  '**/LICENSE',
  'CHANGELOG*',
  '**/CHANGELOG*',
  '.github/ISSUE_TEMPLATE/**',
  '.github/PULL_REQUEST_TEMPLATE*'
];
const allDocsOrTests = files.length > 0 && files.every(matched(docTestGlobs));

let shouldRun = true;
let reason;
if (alwaysHits.length > 0) {
  reason = `always_review match (${alwaysHits.slice(0, 3).join(', ')}${alwaysHits.length > 3 ? ', …' : ''}) — running Codex`;
} else if (lines < threshold) {
  shouldRun = false;
  reason = `small diff (${lines} lines < ${threshold}) — skipping Codex`;
} else if (allDocsOrTests) {
  shouldRun = false;
  reason = `all ${files.length} changed file(s) are docs/tests — skipping Codex`;
} else {
  reason = `${lines} lines across ${files.length} file(s), mixed content — running Codex`;
}

const out = `should_run=${shouldRun}\nskip_reason=${reason}\n`;
if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, out);
if (process.env.GITHUB_STEP_SUMMARY) {
  appendFileSync(
    process.env.GITHUB_STEP_SUMMARY,
    `### Codex cost gate\n\n- Decision: \`${shouldRun ? 'RUN' : 'SKIP'}\`\n- Reason: ${reason}\n- Files: ${files.length}\n- Lines changed: ${lines}\n`
  );
}
console.log(`Gate: should_run=${shouldRun}; ${reason}`);
