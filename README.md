# ci-workflows

Reusable GitHub Actions workflows for solo-dev fleet management.

## Workflows

### `claude-review.yml`

Runs Anthropic's [`claude-code-action@v1`](https://github.com/anthropics/claude-code-action) on PRs to post inline review comments. Caller passes `ANTHROPIC_API_KEY` as a secret.

**Inputs:**
- `review_focus` (string, optional) — appended to the base review prompt for project-specific guidance
- `checkout_depth` (number, default `0`) — git fetch-depth (0 = full history)

**Required secret:** `ANTHROPIC_API_KEY`

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

## Rotate the API key fleet-wide

```bash
~/.claude/templates/ci-workflows/scripts/rotate-anthropic-key.sh --apply
```

## Caveats

- **Target repo must allow workflow writes:** Settings → Actions → General → Workflow permissions → "Read and write permissions"
- **`gh pr merge --auto` only waits if there are required status checks.** Without a ruleset, it merges immediately. Add a ruleset on each target repo before relying on auto-merge.
- **This repo is public** — required for cross-account reusable-workflow calls (e.g. `topcoder1/ci-workflows` → `whois-api-llc/*`). The workflows contain no secrets.
