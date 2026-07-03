#!/usr/bin/env bash
# Guards against reintroducing `gh pr diff` as the changed-file source in
# the reusable workflows.
#
# `gh pr diff` HTTP-406s once a PR's diff exceeds 20k lines ("Sorry, the
# diff exceeded the maximum number of lines"), which killed the automerge
# risk scan, safe-paths classify, pr-classify, and the codex cost gate on
# large PRs (topcoder1/dotclaude#121, 23k insertions / 161 files; earlier
# topcoder1/attaxion_dev#71, 261k lines). The paginated files API
# (`gh api repos/{o}/{r}/pulls/{n}/files --paginate`) lists names at any
# diff size; past its 3000-file listing cap the gating workflows fail
# closed instead of silently under-classifying.
#
# Run from the repo root:
#   bash selftest/test_pr_files_listing.sh
set -euo pipefail

failed=0

# 1. No reusable may EXECUTE `gh pr diff`. Mentions in comments and in
#    --allowedTools strings handed to review agents are fine.
viol=$(grep -rn 'gh pr diff' .github/workflows/*.yml \
  | grep -v 'allowedTools' \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)
if [ -n "$viol" ]; then
  echo "✗ executable 'gh pr diff' found in reusables (use the paginated files API):"
  echo "$viol" | sed 's/^/    /'
  failed=1
else
  echo "✓ no executable 'gh pr diff' in .github/workflows/"
fi

# 2. Every changed-file consumer pins the paginated files API idiom.
for wf in claude-author-automerge safe-paths-automerge pr-classify codex-review lint prettier-autofix; do
  f=".github/workflows/${wf}.yml"
  if grep -q -- '--paginate' "$f" && grep -q 'pulls/' "$f" && grep -q '/files' "$f"; then
    echo "✓ ${wf}.yml lists changed files via the paginated files API"
  else
    echo "✗ ${wf}.yml is missing the paginated files API changed-file listing"
    failed=1
  fi
done

exit "$failed"
