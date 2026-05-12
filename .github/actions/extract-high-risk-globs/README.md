# extract-high-risk-globs (composite action)

Parses the high-risk path glob list out of `.github/workflows/claude-author-automerge.yml` and emits it as a file path.

## Why a composite action

The glob list is the single source of truth for which paths trigger the verifier-on-high-risk gate (Plan 5b) AND which paths cause `claude-author-automerge.yml` to decline auto-merge. To prevent drift, both consumers import from this composite action.

## Usage

```yaml
- name: Extract high-risk path globs
  id: globs
  uses: topcoder1/ci-workflows/.github/actions/extract-high-risk-globs@<SHA>

- name: Read patterns
  run: |
    echo "Got ${{ steps.globs.outputs.count }} patterns:"
    cat "${{ steps.globs.outputs.patterns_file }}"
```

## Pinning convention

Always pin to a specific SHA, never to `@main`. The glob list is security-adjacent (controls which PRs go through high-risk verification); a malicious commit to `main` could weaken it. Bumping the pin is a deliberate PR.

## Fail-closed contract

If the parser produces zero patterns (file moved, heredoc renamed, etc.), the action exits 1. Callers MUST treat this as a hard failure — never proceed with an empty pattern list.
