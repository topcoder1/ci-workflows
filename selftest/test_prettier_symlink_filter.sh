#!/usr/bin/env bash
# Behavioral test for the prettier symlink filter in lint.yml and
# prettier-autofix.yml.
#
# Prettier hard-errors on explicitly specified symlinks ("Explicitly
# specified pattern '<path>' is a symbolic link.") — repos like
# topcoder1/dotclaude track symlinked SKILL.md files by convention, which
# turned every autofix/lint run red on PRs touching them (dotclaude#121).
# Both workflows drop symlinks from the explicit target list before
# invoking prettier.
#
# The filter block is EXTRACTED from the workflow YAML and executed, so
# this exercises the shipped bash, not a mirrored copy. A drift check
# asserts lint.yml and prettier-autofix.yml carry an identical filter.
#
# Run from the repo root:
#   bash selftest/test_prettier_symlink_filter.sh
set -euo pipefail

extract_filter() {
  awk '/^[[:space:]]*SYMLINKS=\(\)/{grab=1} grab{print} grab && /TARGETS=\("\$[{]KEPT\[@\][}]"\)/{exit}' "$1"
}

failed=0

# 1. Drift check: the filter block must be identical in both workflows.
a=$(extract_filter .github/workflows/lint.yml)
b=$(extract_filter .github/workflows/prettier-autofix.yml)
if [ -z "$a" ] || [ -z "$b" ]; then
  echo "✗ could not extract the symlink filter block from one of the workflows"
  exit 1
fi
if [ "$a" = "$b" ]; then
  echo "✓ lint.yml and prettier-autofix.yml symlink filters are identical"
else
  echo "✗ symlink filter drifted between lint.yml and prettier-autofix.yml:"
  diff <(echo "$a") <(echo "$b") | sed 's/^/    /' || true
  failed=1
fi

# 2. Behavioral: run the extracted block against a fixture tree.
snippet=$(echo "$a" | sed 's/^[[:space:]]*//')
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
(
  cd "$tmp"
  echo '# real' > real.md
  ln -s real.md link.md
  ln -s missing.md dangling.md

  TARGETS=(real.md link.md dangling.md)
  eval "$snippet" > /dev/null
  if [ "${#TARGETS[@]}" -eq 1 ] && [ "${TARGETS[0]}" = "real.md" ]; then
    echo "✓ filter keeps regular files, drops symlinks (incl. dangling)"
  else
    echo "✗ expected TARGETS=(real.md), got: ${TARGETS[*]:-<empty>}"
    exit 1
  fi

  TARGETS=(link.md dangling.md)
  eval "$snippet" > /dev/null
  if [ "${#TARGETS[@]}" -eq 0 ]; then
    echo "✓ all-symlink input empties the target list"
  else
    echo "✗ expected empty TARGETS, got: ${TARGETS[*]}"
    exit 1
  fi
) || failed=1

exit "$failed"
