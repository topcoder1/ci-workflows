# ci-workflows

Reusable GitHub Actions workflows for solo-dev fleet management.

## Workflows

### `claude-review.yml`

Runs Anthropic's [`claude-code-action@v1`](https://github.com/anthropics/claude-code-action) on PRs to post inline review comments. Caller passes `ANTHROPIC_API_KEY` as a secret.

**Inputs:**

- `review_focus` (string, optional) — appended to the base review prompt for project-specific guidance
- `checkout_depth` (number, default `0`) — git fetch-depth (0 = full history)

**Required secret:** `ANTHROPIC_API_KEY`

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

- `contracts_read_token` (optional) — PAT for private contracts repos in a different org; built-in `GITHUB_TOKEN` suffices for same-org private repos

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

## Caveats

- **Target repo workflow permissions:** must be "Read and write" (Settings → Actions → General). `install-pr-review.sh` auto-flips this; if you wire callers manually, flip it yourself.
- **`gh pr merge --auto` only waits if there are required status checks.** Without a ruleset, it merges immediately. `install-pr-review.sh` creates a ruleset by default (`--no-ruleset` to skip).
- **Install PR's `Claude Review` check may fail** with an OIDC "workflow validation" error on PRs that modify the workflow file itself. In practice it often passes; if it fails, merge with admin bypass. Subsequent PRs work normally.
- **This repo is public** — required for cross-account reusable-workflow calls (e.g. `topcoder1/ci-workflows` → `whois-api-llc/*`). The workflows contain no secrets.
