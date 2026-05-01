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
