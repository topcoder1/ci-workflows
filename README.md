# ci-workflows

Reusable GitHub Actions workflows for solo-dev fleet management.

## Workflows

### `claude-review.yml`

Runs Anthropic's [`claude-code-action@v1`](https://github.com/anthropics/claude-code-action) on PRs to post inline review comments. Caller passes `ANTHROPIC_API_KEY` as a secret.

**Inputs:**

- `review_focus` (string, optional) — appended to the base review prompt for project-specific guidance
- `checkout_depth` (number, default `0`) — git fetch-depth (0 = full history)
- `max_turns` (number, default `25`) — cap on agentic turns; raise per-repo when large diffs exhaust it
- `max_budget_usd` (number, default `3`) — hard per-run spend ceiling (`--max-budget-usd`, counts subagent spend). Fleet baseline per review: median $0.61 / p90 $1.06 / max $2.68. A budget stop **fails** the check with a message naming this input; raise it per-repo only for legitimately huge diffs.

**Required secret:** `ANTHROPIC_API_KEY`

**Spend guardrails (added after the 2026-08-14..16 incident, when a Claude Code CLI behavior change reached this REQUIRED lane through an unpinned install and ran $3–7 per review for two days, pushing the org over its monthly cap and pausing the API for CI _and_ production):**

| Guardrail                                                                                      | Where                                                                                                                    | What it bounds                                                                                                                                                                         |
| ---------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Claude Code CLI **pinned** (`CLAUDE_CODE_VERSION`, exact semver ≥ 2.1.217)                     | `jobs.review.env` in `claude-review.yml`; the pre-install step targets it and **refuses** to review on any other version | The channel all three August incidents came through (default-model flip Aug 4, `/code-review` subagent fan-out Aug 14, tool-output offload Aug 16). The pin is the **rollback lever**. |
| `--max-budget-usd ${{ inputs.max_budget_usd }}`                                                | `claude_args`                                                                                                            | Per-run dollars, subagent spend included; name-independent, unlike `--disallowedTools`                                                                                                 |
| `--max-turns ${{ inputs.max_turns }}` + `--disallowedTools "Task,Agent,Skill,Workflow"`        | `claude_args`                                                                                                            | Parent turns; the fan-out tools by name                                                                                                                                                |
| review step `timeout-minutes: 30`, job `timeout-minutes: 35`                                   | `claude-review.yml`                                                                                                      | Wall clock (step-level so a timed-out review still reaches the lost-findings guard)                                                                                                    |
| Guard step: fails on `subtype: error_max_budget_usd`; `::warning::` when `total_cost_usd` > $2 | `Lost-findings guard` step                                                                                               | Detection in-band, per run, minutes after the fact — no cron, PAT, or Admin API key                                                                                                    |
| `anthropics/claude-code-action` in its **own** dependabot group                                | `.github/dependabot.yml`                                                                                                 | A behavior-changing action bump can no longer ride the routine minor/patch batch                                                                                                       |

**Bumping the CLI pin (or merging a `claude-code-action` bump):** change `CLAUDE_CODE_VERSION` (one line) → merge (manual, as always in this repo) → watch the next 5 `review / Claude Review` runs across the fleet: `total_cost_usd` in the run log should stay ≤ ~$1.50 and duration ≤ ~10 min; the guard warns on any run over the soft threshold. Anything else → revert the pin. Note that `gh run rerun` replays the reusable at the SHA the original run resolved, so a fix merged to `main` reaches existing PRs only through a **fresh event** (push / close-reopen), never a re-run.

Selftests: `selftest/test_claude_review_cost_guardrails.sh` (static contract), `selftest/test_claude_review_lost_findings_guard.sh` S19–S21 (guard verdicts), `selftest/test_claude_review_max_turns_type.sh`.

### `prettier-autofix.yml`

Runs `prettier --write` on PR-changed markdown and pushes the fix back to the branch as a single commit. Pairs with `lint.yml`'s `prettier --check`: when a markdown PR lands with formatting drift, autofix lands a `style: prettier auto-fix` commit so the lint check goes green on the next CI run instead of blocking the PR.

**Inputs:**

- `markdown_glob` (string, default `**/*.md`) — keep in sync with `lint.yml`'s same input
- `install_node_deps` (bool, default `true`) — run `npm ci` first so prettier plugins (e.g. `prettier-plugin-svelte`) resolve
- `changed_only` (bool, default `true`) — write only PR-touched files; mirrors `lint.yml`'s `prettier_changed_only`
- `commit_message` (string, default `style: prettier auto-fix`)

**Required secret:** `automerge_pat` — fine-grained PAT (or classic with `repo` scope). Same secret name and required scopes as `claude-author-automerge.yml`, so a repo that already has auto-merge wired needs no extra provisioning. Why a PAT: pushes by the default `GITHUB_TOKEN` do not retrigger downstream `pull_request` workflows, so the lint check would stay red against the previous SHA. A PAT push triggers `lint.yml` on the new commit and the check turns green.

**Skipped automatically on:** fork PRs (cross-repo push impossible), closed PRs, PRs touching zero markdown.

### `openapi-types-drift.yml`

Detects drift between a committed generated-types file (e.g. `src/api/types.gen.ts`) and what `openapi-typescript` would produce from the contracts spec today. Prevents the "types.gen.ts hand-edit drift" class of bug where contract changes in one repo never propagate to the consumer repo's generated file.

**Topology:** designed for a dual-repo layout where a "contracts" repo owns the OpenAPI spec + codegen script and a separate "consumer" repo commits the generated file. The consumer repo installs this caller.

**Inputs:**

- `contracts_repo` (string, required) — GitHub slug of the contracts repo (`owner/repo`)
- `contracts_rev_source` (string, default `head`) — how to pin the contracts revision: `head` (no pin), `contracts-rev` (`.contracts-rev` file), `go-mod`, or `package-json`
- `contracts_rev_file` (string, default `.contracts-rev`) — pin file path when `contracts_rev_source=contracts-rev`
- `contracts_gen_cmd` (string, default `npm run gen-ts --`) — command run inside contracts repo; must accept a positional output-file argument
- `contracts_spec_path` (string, default `openapi/v2.yaml`) — spec path for display in error messages
- `generated_types_path` (string, default `src/api/types.gen.ts`) — repo-root-relative path to the committed generated file in the caller
- `node_version` (string, default `20`) — Node.js version for codegen

**Secrets:**

- `contracts_read_token` — PAT required for ANY private contracts repo (the built-in `GITHUB_TOKEN` is scoped to the caller repo only; it cannot read other private repos, even in the same org). Not needed for public contracts repos.

**On drift:** fails the check and posts a sticky PR comment with the first 50 lines of the diff and regen instructions. Removes the comment automatically when the PR is updated and drift is gone.

**Advisory soak:** install with `contracts_rev_source: head` first. Do NOT add to required-status-checks until after ~1 week of advisory runs. See the caller PR body for the gating plan.

**Known limitation:** without a `.contracts-rev` pin file, the gate evaluates drift against contracts HEAD at CI time. If contracts HEAD advances between CI runs, the gate may report different results for the same PR. The permanent fix is Path C: add `.contracts-rev` and switch to `contracts_rev_source: contracts-rev`.

**Caller template:** `~/.claude/templates/ci-workflows/callers/openapi-types-drift.yml`

### `dependabot-auto-merge.yml`

Auto-merges Dependabot PRs for patch (and optionally minor) version bumps once required checks pass.

**Inputs:**

- `merge_method` (string, default `squash`) — `merge` | `squash` | `rebase`
- `allow_minor` (bool, default `true`) — also merge minor bumps

**Required secret:** none (uses auto-injected `GITHUB_TOKEN`)

## Per-project caller stubs

See [`callers/pr-review.yml`](https://github.com/topcoder1/ci-workflows/blob/main/callers/pr-review.yml) and [`callers/dependabot-auto-merge.yml`](https://github.com/topcoder1/ci-workflows/blob/main/callers/dependabot-auto-merge.yml) in the templates dir at `~/.claude/templates/ci-workflows/`.

## Bootstrap a target repo

```bash
~/.claude/templates/ci-workflows/scripts/install-pr-review.sh whois-api-llc/wxa-jake-ai
```

The script reads `ANTHROPIC_API_KEY` from env, falling back to 1Password (`op://Private/ANTHROPIC_PR_REVIEW_KEY/credential`).

It installs both `pr-review.yml` and `dependabot-auto-merge.yml` callers, sets workflow perms to write, enables auto-merge on the repo, and creates a branch ruleset.

## Bootstrap a `dependabot.yml` across the fleet

The auto-merge workflow only fires on Dependabot PRs — and Dependabot only opens PRs when a `.github/dependabot.yml` exists in the target repo. Use this script to add a baseline config (ecosystems auto-detected) to repos that don't have one yet:

```bash
# Dry-run (default): print what would be added per repo
~/.claude/templates/ci-workflows/scripts/bootstrap-dependabot-config.sh \
  topcoder1/foo whois-api-llc/bar

# Apply: open a PR per repo with auto-merge armed
~/.claude/templates/ci-workflows/scripts/bootstrap-dependabot-config.sh --apply \
  --from-list repos.txt
```

Detection (any matching marker file → ecosystem enabled): `package.json` → npm; `pyproject.toml` / `requirements*.txt` / `setup.py` / `Pipfile` → pip; `go.mod` → gomod; `Cargo.toml` → cargo; `Gemfile` → bundler; `composer.json` → composer; `Dockerfile*` → docker; any `.github/workflows/*.yml` → github-actions. Cadence is weekly; minor + patch updates are grouped per ecosystem; PR cap is 5 per ecosystem.

## Rotate the API key fleet-wide

```bash
~/.claude/templates/ci-workflows/scripts/rotate-anthropic-key.sh --apply
```

## Classifier dependencies are vendored

`.github/scripts/classify.mjs` and `codex-gate.mjs` need `yaml` and `minimatch`.
Rather than installing them at run time, both import
`.github/scripts/classifier-deps.mjs` — a committed, version-pinned esbuild
bundle that every consumer fetches alongside the script itself.

The pins live in `scripts/classifier-deps/package.json`, with
`package-lock.json` beside it pinning the transitives too — `minimatch` pulls in
`brace-expansion` and `balanced-match`, and both end up in the bundle, so
without a lockfile a compatible transitive release would make `--check` report
a stale bundle with no pin change of ours. To change a version:

```bash
$EDITOR scripts/classifier-deps/package.json
(cd scripts/classifier-deps && npm install --package-lock-only)
scripts/build-classifier-deps.sh          # regenerate
scripts/build-classifier-deps.sh --check  # verify the committed copy is current
```

Commit the manifest, the lockfile and the regenerated bundle together.

`selftest/test_classifier_deps_vendored.sh` runs `--check` in CI, so a bumped pin
with a stale bundle fails there. Nothing else needs regenerating — editing
`classify.mjs` does **not** require rebuilding the bundle.

Why it is vendored rather than installed: the classifier used to run
`npm install --no-save yaml@2 minimatch@10` inside the **caller's** checkout,
where a root `package.json` made npm install that repo's entire dependency tree
on every PR — ~1000 packages instead of 4 in `wxa-jake-ai`, with a measured 7m03s
worst case that blew the auto-merge gate's poll budget and wedged the PR. The
classifier is a fail-closed gate in every caller repo, so npm in its critical
path was a fleet-wide wedge vector; it now depends only on the GitHub API, which
it already required. The pins are exact, so `pr-classify.yml` and
`claude-author-automerge.yml` match with identical bytes instead of independently
resolved floating majors.

## Caveats

- **Target repo workflow permissions:** must be "Read and write" (Settings → Actions → General). `install-pr-review.sh` auto-flips this; if you wire callers manually, flip it yourself.
- **`gh pr merge --auto` only waits if there are required status checks.** Without a ruleset, it merges immediately. `install-pr-review.sh` creates a ruleset by default (`--no-ruleset` to skip).
- **Install PR's `Claude Review` check may fail** with an OIDC "workflow validation" error on PRs that modify the workflow file itself. In practice it often passes; if it fails, merge with admin bypass. Subsequent PRs work normally.
- **This repo is public** — required for cross-account reusable-workflow calls (e.g. `topcoder1/ci-workflows` → `whois-api-llc/*`). The workflows contain no secrets.
