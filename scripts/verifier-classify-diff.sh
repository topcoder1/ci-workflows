#!/usr/bin/env bash
# verifier-classify-diff.sh — emit paths matching any pattern in the
# patterns-file. Exit 0 if any matches found, 1 if none.
#
# Used by verifier-on-high-risk.yml: if there are matches, the verifier
# dispatches; if not, the workflow exits silently (skip).
#
# Usage:
#   verifier-classify-diff.sh --patterns FILE --paths FILE
#     FILE format: one regex / one path per line.

set -euo pipefail

PATTERNS=""
PATHS=""

usage() { echo "Usage: $0 --patterns FILE --paths FILE" >&2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --patterns) PATTERNS="$2"; shift 2 ;;
    --paths) PATHS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

[[ -z "$PATTERNS" || -z "$PATHS" ]] && { usage; exit 2; }
[[ ! -f "$PATTERNS" ]] && { echo "patterns file not found: $PATTERNS" >&2; exit 2; }
[[ ! -f "$PATHS" ]] && { echo "paths file not found: $PATHS" >&2; exit 2; }

matched=0
while IFS= read -r path; do
  [[ -z "$path" ]] && continue
  while IFS= read -r pat; do
    [[ -z "$pat" ]] && continue
    if echo "$path" | grep -Eq "$pat"; then
      printf '%s\t(matched: %s)\n' "$path" "$pat"
      matched=1
      break  # one match per path is enough
    fi
  done < "$PATTERNS"
done < "$PATHS"

[[ "$matched" -eq 1 ]] && exit 0 || exit 1
