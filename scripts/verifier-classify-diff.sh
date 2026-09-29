#!/usr/bin/env bash
# verifier-classify-diff.sh — emit paths matching any pattern in the
# patterns-file. Exit 0 if any matches found, 1 if none, 2 on any error:
# 1 must mean only "every path checked, nothing matched", because the caller
# skips the verifier on it.
#
# Used by verifier-on-high-risk.yml: if there are matches, the verifier
# dispatches; if not, the workflow exits silently (skip).
#
# Usage:
#   verifier-classify-diff.sh --patterns FILE --paths FILE
#     FILE format: one regex / one path per line.

set -euo pipefail
# set -e alone exits with the failing command's status, often 1: a match it
# could not write would read as "no match".
trap 'exit 2' ERR

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
# No pattern at all matches nothing: an error, not a verdict.
grep -q . "$PATTERNS" || { echo "no patterns in $PATTERNS" >&2; exit 2; }

# Nothing below may fail in a way that reads as "no match". Both files are
# opened with exec, whose failure trips the ERR trap; a redirection on a loop
# can fail without it. Each grep reads the whole paths file, with no
# redirection of its own, and prints its exit status inside its command
# substitution: a substitution that cannot run returns no status, not 1.
NL=$'\n'
first=()  # first[n]: the first pattern, in file order, matching line n of PATHS
exec 3< "$PATTERNS"
while IFS= read -r -u 3 pat; do
  [[ -z "$pat" ]] && continue
  out="$(grep -anE -e "$pat" -- "$PATHS"; echo "status=$?")"
  status="${out##*status=}"
  [[ "$status" == 1 ]] && continue
  if [[ "$status" != 0 ]]; then
    echo "pattern failed (grep status ${status:-missing}): $pat" >&2
    exit 2
  fi
  hits="${out%status=*}"
  [[ "$hits" == *"$NL" ]] || { echo "unexpected grep output for: $pat" >&2; exit 2; }
  while [[ -n "$hits" ]]; do
    n="${hits%%:*}"
    hits="${hits#*"$NL"}"
    [[ "$n" =~ ^[1-9][0-9]*$ ]] || { echo "unexpected grep output for: $pat" >&2; exit 2; }
    [[ -n "${first[n]:-}" ]] || first[n]="$pat"
  done
done
exec 3<&-

matched=0
n=0
exec 4< "$PATHS"
while IFS= read -r -u 4 path; do
  n=$((n + 1))
  [[ -z "$path" || -z "${first[n]:-}" ]] && continue
  printf '%s\t(matched: %s)\n' "$path" "${first[n]}"
  matched=1
done
exec 4<&-

[[ "$matched" -eq 1 ]] && exit 0 || exit 1
