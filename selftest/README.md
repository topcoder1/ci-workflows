# selftest/

Self-test fixtures for the reusable workflows in this repo.

These are **not** production tests — they verify that the reusables in
`.github/workflows/` boot, accept their declared inputs, and produce
expected outputs. The fixtures here are deliberately minimal.

## Why `selftest/` not `tests/`

Keep this directory scoped to "verify reusables on this repo." A `tests/`
directory would imply a general test suite for a library — which this repo
isn't. Future contributors should resist expanding `selftest/` to cover
arbitrary helper scripts; that's a different kind of repo.

## What lives here

- `test_smoke.py` — trivial passing test invoked by `tests-runner.yml`'s
  self-test path. Verifies pytest discovery, pyproject.toml plumbing, and
  the `uv run pytest` invocation end-to-end.
- `test_automerge_risk_patterns.sh` / `test_bb_automerge_risk_patterns.sh`
  — risk-tier regex behavior, driven by the shared corpus in
  `risk_patterns_corpus.txt`.
- `test_automerge_body_gate.sh` — the PR-body closing-keyword gate in
  `claude-author-automerge.yml`. `closes #N <qualifier>` closes N in FULL on
  merge (GitHub reads the keyword and the number, nothing after them);
  topcoder1/webcrawl#509 was closed that way on 2026-09-04 by "closes #509
  follow-up (b)". The gate abstains (declines to arm, revokes a stale arm,
  leaves a sticky comment, publishes `automerge:refused-body`) when a
  closing reference is followed by a qualifier; bare references and lists
  ("closes #1 and #2", "fixes #1, #2, #3.") clear. Runs the extracted step
  against 14 bodies and pins the wiring into the arm, quiet-period and
  error-revoke conditions.
- `test_classify_nocase.sh` — `classify.mjs` case-folds pattern matching for
  `blocked`/`sensitive` **only**. minimatch defaults to case-sensitive, so a
  lowercase `**/secrets*` missed `docs/SECRETS.md` and a production secrets
  rotation runbook classified `risk:trivial` (wxa-jake-ai#875 / #877). Pins
  the fix _and_ the asymmetry that makes it safe — folding may only ever add
  gating, never remove it — so folding the safe/trivial classes is rejected:
  it would demote an unmatched path from the strict `standard` fallback into
  an auto-merge-eligible class (a PR adding `Tests/release.py` under
  `safe_test: ['tests/**']`).
- `test_classify_dead_entry_guard.sh` — `classify.mjs` fails closed on the
  `risk-paths.yml` entries known to leave a pattern no changed path can match.
  An unquoted `- !scripts/deploy.sh` is a YAML tag, not text: the parser only
  warns and keeps an empty string, which the negation guard never sees, so the
  gate (or, under `always_review`, the forced Codex review) silently
  disappears and the classifier still exits 0. Every warning yaml reports,
  while parsing or converting, now fails closed, and so does an entry that is
  empty, whitespace-only, padded (a `|` block scalar keeps a trailing
  newline), holding a line break (a `|` block of several lines), `#`-leading
  (a minimatch comment) or not a string, in every class, `exclude:` list and
  `always_review`. Positive controls: a quoted `'!x'` still gets the negation
  guard's own message, and ordinary entries still load.
- `test_classify_rules_shape_guard.sh` — `classify.mjs` fails closed on the
  `risk-paths.yml` shapes that silently drop a gate while it exits 0. A top
  level that is not a plain mapping (`- blocked: […]` makes the whole file one
  list; a `!!set` or `!!omap` becomes a JS Set or Map) drops every gate at
  once, and an empty or comment-only file crashed with a TypeError instead of
  a message. An unknown top-level key (`sensitve:`, `SENSITIVE:`,
  `blocked_paths:`) is a gate that does not exist: keys are held to a strict
  allowlist of the nine the fleet uses (the eight `classify.mjs` reads, plus
  `sensitive_deploy_gated`, which dotclaude's `/babysit-prs` tooling reads). An
  entry that ends with `/` (`infra/`, a CODEOWNERS habit) or starts with `./`
  or `/` matches no changed path, in any brace alternative too. A pattern
  wrapped over lines (`- cmd/**` with `internal/**` indented on the next line,
  a two-line `>-` block, a flow list missing a comma) is ONE pattern with a
  space in it; since the value cannot be told from a real interior space, the
  guard reads each entry's source through yaml's node predicates, which the
  vendored bundle now exports. It follows alias keys (`? *cls`) as `toJS()`
  does, and refuses a `<<` merge key, which would copy a class list in from
  elsewhere in the file. A carriage return outside a CRLF line ending fails
  closed too: YAML 1.2 and most parsers read a lone CR as a line break, and
  classify's parser reads it as text. Positive controls: all nine keys together, and
  every spelling that folds nothing (an escaped `\` line join, a one-line `>-`
  block, a flow list across lines with its comma), in LF and CRLF files.
- `test_classifier_deps_vendored.sh` — the classifier's deps are a committed,
  version-pinned esbuild bundle (`.github/scripts/classifier-deps.mjs`) instead
  of a run-time `npm install`. The install used to run inside the caller's
  checkout, where a root `package.json` pulled that repo's whole dependency tree
  into every classify run (~1000 packages instead of 4 in wxa-jake-ai; 32s /
  7m03s / 5m20s across three consecutive runs, the slowest of which wedged a PR
  by blowing the auto-merge gate's poll budget). Pins that the bundle is not
  stale, that every consumer workflow fetches it, and that no run-time
  yaml/minimatch install has crept back. Its central case CALLS every export
  rather than merely importing them: yaml's exports map has no `import`
  condition, so esbuild bundles its CommonJS build, whose `require('process')`
  becomes a shim that throws — the first bundle built here imported cleanly and
  died inside `parse()`, which would have hard-failed the classifier in all 45
  caller repos.
- `test_codex_verdict_gate.sh` — `codex-verdict.mjs` classification and its
  opt-in enforcement. Codex's verdict used to be a comment only: the job
  exited 0 whatever it said, so domain-rank#74 and #79 (both 2026-07-27) each
  merged with a reported missing-test regression unaddressed. Replays both
  verdicts verbatim. Pins the two properties that keep the gate safe for the
  other 26 consumers — enforcement happens only on the literal
  `FAIL_ON_REGRESSION=true`, and under enforcement it fails on evidence of a
  finding (a `regression:` line or a `VERDICT: REGRESSION` trailer) plus on no
  output at all. Requiring the trailer was tried and failed the first real PR
  it ran on (domain-rank#82): the model ignores the instruction and a clean
  review went red. Requiring a recognizable CLEAN phrase failed the same way.
  The accepted cost — asserted explicitly — is that a finding phrased outside
  both forms is missed.
- `test_codex_gate_priority.sh` — `codex-gate.mjs`'s rule order. An
  `always_review` match must run Codex even on a diff under `SIZE_THRESHOLD`
  and even when every changed file is docs/tests; hoisting either skip above
  it would silently stop every caller's `always_review` from forcing a read.
  Each run case has a control that differs only in the match and must skip.
  The first selftest to execute `codex-gate.mjs` at all (gap raised on
  whois-api-llc/wxa_webcat#1612).
- `test_automerge_base_gate.sh` — auto-merge may only target the ref a
  branch ruleset actually protects. Rulesets are conventionally scoped to
  the default branch (`ref_name: ~DEFAULT_BRANCH`), so a feature-branch base
  has no required checks and `--auto` merges on the spot; every other
  protection in that lane is latency-shaped and assumes a wait to lose.
  wxa-jake-ai#1027 merged into another open PR's head 68s after opening and
  grew that PR's reviewed diff from 6 files to 8. Pins: default base is free
  (no API calls), another open PR's head refuses unconditionally, other
  non-default bases need the opt-in label, and every unreadable input
  refuses. Its "every pre-arm rejection disarms" scan now ends at the arm
  command rather than at a comment quoting it — the old anchor read 47 lines
  of comments and no rejection path — with a line-count floor and planted
  bare-exit negative controls on both sides of the attribution-gate helper.
- `test_automerge_pat_attribution_gate.sh` — neither arming reusable may
  arm unless the caller's `automerge_pat` arrived AND is a user credential
  (`GET /user` answers `type: User`). GitHub deletes a merged head branch
  (`delete_branch_on_merge`) only for a USER-attributed merge; after a
  GITHUB_TOKEN arm the merge is github-actions[bot]'s, the branch survives,
  and a later push to it never reaches main (wxa-graph#553). Measured
  2026-09-18: 0/97 bot-attributed fleet merges auto-deleted vs 1746/1746
  user-attributed; a scratch-repo repeat matched (4/4 vs 5/5). Runs both
  extracted arm steps against a stub that models the PR's arm state
  (re-arming keeps the ORIGINAL enabler, as measured) and answers `pr view`
  / `api user` by running the SHIPPED `--jq` filters over gh-shaped JSON.
  Pins: no PAT or a non-user credential refuses (claude-author publishes
  `automerge:refused-no-pat`); a bot's existing arm is replaced and a user's
  is never touched; the enabler is read back after the arm; the slow probe
  precedes every live-state read; the safe-paths arm is head-bound;
  Dependabot's own PRs keep the old path by exact login match. Negative
  controls neutralize each refusal and the bot-arm removal, and misspell the
  enabler path (a typo that would be silent in production); structural pins
  hold one arm call site per workflow and keep `automerge_pat`
  `required: false`.
- `test_pr_files_listing.sh` — no reusable may fetch changed files via
  `gh pr diff` (HTTP 406 past 20k diff lines); pins the paginated
  files-API idiom instead.
- `test_verifier_changed_paths_renames.py` — runs
  `verifier-on-high-risk.yml`'s shipped "Compute PR diff" step in a fixture
  PR checkout where the PR renames a file: the path list the high-risk
  classifier reads must name the old path as well as the new one. `git diff`
  detects renames by default, and `--name-only` then prints only the new
  path, so the step passes `--no-renames`. The classifier, fed the central
  high-risk list by the shipped `extract-high-risk-globs` action, must then
  match the old path. Negative control: the step without the flag lists only
  the new path, and nothing matches. The verifier's per-file diff of that old
  path shows only a deletion, so the test also renders the shipped prompt and
  runs the commands it gives the model to list the PR's renames and read both
  paths together; they must show the rename and the edit. git also applies a
  submodule's `ignore` setting from the checkout's `.gitmodules` (the PR's
  own copy) to diffs between commits, so the step and every prompt command
  pass `--ignore-submodules=none`: a submodule change the PR's `.gitmodules`
  ignores must be listed, matched and shown to the model, and a submodule
  the PR moves must be followed to its new path (negative controls: each
  command without the flag). A move that rewrites most of a file falls under
  git's default 50% similarity: the prompt's rename listing, at 10%, must
  pair a move that kept two of ten functions (negative control: the default
  threshold), and its added-files listing must name the new path of a move
  that kept nothing.
- `test_prettier_symlink_filter.sh` — extracts the symlink filter from
  `lint.yml` / `prettier-autofix.yml`, runs it against a fixture tree,
  and asserts the two copies haven't drifted.
- `test_regression_convention_bullet_cap.sh` — once a `## Lessons` bullet
  cites a paired regression test, that test is the control and the prose is a
  second copy, so `regression-convention.yml` caps the bullet and pushes the
  narrative to the archive. Pins the ways the gate could wrongly fail a PR:
  bullets the PR did not touch, and bullets with no test citation, must both
  pass — adopting the cap must not tax a repo's existing backlog. Also pins
  that it stays opt-in (`default: 0`), since a default-on cap would fail PRs
  fleet-wide the day it lands.
- `test_prettier_scope_failsafe.sh` — a failed changed-file listing must
  SKIP the prettier run (mode=none), never fall open to the full-tree
  glob; and prettier-autofix must revert writes under
  `.github/workflows/` before committing (automerge_pat has no workflow
  scope, so such pushes are always rejected — wxa-secrets#27). Extracts
  and executes the shipped bash; drift-checks the listing block between
  the two workflows.
- `test_prettier_untrusted_head_config.sh` — prettier-autofix.yml checks out
  the attacker-/model-writable PR head with the push PAT in reach, and
  prettier's default search LOADS config and plugins as code
  (`prettier.config.js`, `.prettierrc.cjs`, a `package.json` `"prettier"` ref).
  Pins that the hardened workflow never executes head-reachable code: the write
  step is extracted and run against a canary `prettier.config.cjs` (its marker
  must stay absent) under an empty `--config` and under a base `--config`, plus
  an editorconfig-parity case (the empty-`{}` default must still honor
  `.editorconfig`, unlike `--no-config`); the base-config resolver is run in
  fixture repos and must materialize the BASE bytes (and degrade JS / plugin /
  `package.json`-string configs to the empty `{}` with a warning); and
  structurally the checkout is `persist-credentials: false` **and passes no
  `token:`** (the guard reads the comment-stripped checkout step, so a flip to
  `true` or a revert to the old `token:` form both fail — not the raw-file grep
  that the repo's own lesson warns against), the prettier CLI installs
  off-checkout with a pinned registry + `--ignore-scripts` + neutralized npm
  user-config, the push auth rides an inline `http.extraheader`, and the target
  list follows `--`. The canary and the credential/editorconfig guards are all
  mutation-proven. Its sibling `test_lint_prettier_check_untrusted_head.sh`
  carries the same hardening for `lint.yml`'s read-only `prettier --check`.
- `test_lint_prettier_check_untrusted_head.sh` — `lint.yml`'s `prettier
--check` has the same head-config-execution vector as the autofix write lane
  (the pull_request merge ref carries head content), minus the push PAT. Pins
  that the check never executes a head `prettier.config.cjs` (extracts and runs
  the check step against a canary; asserts the marker stays absent, that a base
  `--config` actually applies via a `--check` exit-code differential, and that
  the empty-`{}` default still honors `.editorconfig`), and structurally that
  the prettier job's checkout is `persist-credentials: false` with no `token:`,
  the prettier CLI installs off-checkout, and the target list follows `--`. Its
  load-bearing check is a **drift guard**: the "Resolve base prettier config"
  and "Install prettier" step bodies must be BYTE-IDENTICAL to
  `prettier-autofix.yml`'s, so the check lane and the write lane resolve config
  the same way (else autofix fixes a file the check rejects). All guards are
  mutation-proven.
- `test_ruff_ruleset_warning.sh` — #139 pinned ruff's version, which stops a
  release from reddening the fleet on release day; it does not make any
  repo's rule set explicit. A repo with no `select` still inherits ruff's
  built-in defaults, so the deliberate pin bump re-scopes what it enforces
  and the new findings land on whoever opens the next unrelated PR there
  (dotclaude#186 is that shape: unchanged tree, clean → 25 errors, purely
  because 0.16 widened the defaults). Extracts and executes the shipped
  detection bash. Pins that the warning fires only when nothing is declared,
  that it reads **only** `[tool.ruff*]` tables — a `select` under another
  tool must not suppress it — and that it can never fail the job, since a
  hard failure would redden every currently-green consumer on merge. The
  version pin itself is covered by `test_lint_ruff_version_is_pinned`.
- `test_claude_review_lost_findings_guard.sh` — `claude-review.yml` must
  keep the reviewer single-pass and must not let findings vanish. On
  wxa-graph#403 (run 31925279662, 2026-08-16) the lane ran 52 min, posted
  "Flagged 6 issues inline", created zero inline comments and concluded
  SUCCESS; the log named no denied tool and four findings were lost. Cause:
  since the action's 1.0.190 bump (Claude Code 2.1.227) the reviewer's first
  call is the CLI's bundled `Skill(code-review)`, a background subagent with
  its own finder/verifier fan-out that `--max-turns` never sees — the whole
  fleet went from 1-8 min to 20-134 min per review at the bump. Pins (1)
  `--disallowedTools Task,Agent,Skill,Workflow` in `claude_args`, and (2)
  the guard: extracts the shipped bash and runs it against a stubbed `gh` —
  the summary's "Flagged N issues inline" claim vs the inline comments the
  bot actually created since the job's anchor; denials printed with tool
  names; denied/errored inline bodies and subagent reports recovered into
  one fallback comment phrased for bb-unaddressed-findings; job fails only
  when nothing was recoverable or the fallback could not be posted; every
  guard-side read error (API failure, missing/malformed transcript,
  unrecognized phrasing) is a warning and exit 0.
- `test_codex_model_pin.py` — pins `codex-review.yml`'s Codex model
  (`CODEX_MODEL`: hardcoded expectation plus typo/drop-flag/drop-anchor/
  defang negative controls), and executes the step's shipped provenance +
  refusal bash against synthetic `codex.out` fixtures: a different model
  reds the run; a re-cased or CRLF banner still matches the pin; a missing
  or out-of-region banner only warns.
  Background: the 2026-09-04 `@openai/codex@latest` bump silently flipped
  the bundled default to gpt-6-astra, which then reported zero regressions
  in 88 fleet reviews against a 16% baseline on gpt-5.6-sol.
- `test_codex_cli_install.py` — executes `codex-review.yml`'s shipped
  "Install Codex CLI" bash against stubbed `npm`/`codex`/`sleep`:
  `codex --version`, never npm's exit code, decides success; a platform
  binary the registry lists late is retried up to 4 times, waiting
  60/120/240/300 s (doubling, capped at the 300 s packument max-age), with
  `--prefer-online` (within max-age the npm stub replays its cached
  packument without it, as npm 10.9.8 measurably does); a binary that never
  lands fails the step closed with an `::error::`. Negative controls: the
  pre-fix one-liner plus verify/retry/cache-bypass/backoff/cap/fail-closed
  mutations.
  Background: on 2026-09-22 (PT) attaxion_dev#374's Codex job installed
  0.156.1 257 s after its linux-x64 binary was published, from a packument
  that did not list it yet; npm skipped the optional dependency silently
  ("added 1 package") and the next step died on
  `Missing optional dependency @openai/codex-linux-x64`.
- `test_review_lanes_base_attributes.py` — every review lane whose model
  runs git in the PR checkout (the verifier, the adversarial pass, Codex)
  must give that model `GIT_ATTR_SOURCE=<base sha>`, so `.gitattributes`
  comes from the base: a path the PR itself marks `binary` or `-diff` still
  reaches the model in full, and the base's own `-diff` keeps working.
  Matches the claude-code-action steps whose allowlist grants git or a shell
  (or that have none) and the steps running `codex review`/`exec` against a
  hardcoded lane list; runs `git diff`, `git log -p` and `git show` in a
  fixture merge checkout under each lane's model-step environment (negative
  controls: the variable dropped, misspelled, or set to the head sha or the
  base branch name); renders the verifier prompt and runs its diff command;
  runs the Codex review step against a stub `codex`. Background: #244 closes the same gap in
  `claude-review.yml`'s context step. GitHub's own diff (`gh pr diff`, the
  files API) ignores `.gitattributes`, so a lane reading only that diff
  needs nothing.
- `test_workflow_guards.py` — pytest wrapper that runs the `.sh`
  selftests above, so `tests-runner.yml`'s self-test path enforces them
  in CI.
- Future: one self-test fixture per reusable (`.coverage-floor` JSON for
  `coverage-floor.yml`, lessons-section markdown for
  `regression-convention.yml`, pty fixture for `tty-tests.yml`).
