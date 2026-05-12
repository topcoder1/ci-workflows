#!/usr/bin/env bash
# audit-required-checks-fleet.sh — fleet-fanout wrapper around
# validate-required-checks.sh.
#
# Loops over the supplied repo list (default: hardcoded 14-repo GH fleet),
# calls validate-required-checks.sh on each, and emits a digest body. Used
# by the weekly audit-required-checks.yml cron GHA to decide whether to
# open / update a digest issue.
#
# Exits 0 if all repos cleanly validated (whether or not warnings were
# emitted); exits non-zero if any per-repo invocation FAILED (script error,
# not policy warning). Cleanly distinguishing these two means the cron job
# can detect "the audit itself broke" separately from "the audit found
# something."
#
# Usage:
#   audit-required-checks-fleet.sh --repos "owner/repo1 owner/repo2 ..."
#                                  [--out FILE]   # default stdout
#
# Stdout / --out content (digest body):
#   - One block per repo with non-empty output from validate-required-checks.sh
#   - "All N repos clean. Last run: <ISO date>" if zero blocks
#
# Designed to be safely runnable from a GHA scheduled job AND from a
# local shell (the validate-required-checks.sh stub-substitution in
# tests works because we look up the script via $PATH, not a fixed path).

set -euo pipefail

REPOS=""
OUT="/dev/stdout"

usage() {
  cat <<EOF
Usage: $0 --repos "owner/repo1 owner/repo2 ..." [--out FILE]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repos) REPOS="$2"; shift 2 ;;
    --out)   OUT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$REPOS" ]]; then
  usage >&2
  exit 2
fi

# Locate validate-required-checks.sh — try $PATH first (so tests can stub
# it), then fall back to ../scripts/ relative to this file (so the GHA
# checkout works).
VALIDATOR="$(command -v validate-required-checks.sh || true)"
if [[ -z "$VALIDATOR" ]]; then
  SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
  if [[ -x "$SELF_DIR/validate-required-checks.sh" ]]; then
    VALIDATOR="$SELF_DIR/validate-required-checks.sh"
  fi
fi
if [[ -z "$VALIDATOR" || ! -x "$VALIDATOR" ]]; then
  echo "audit-required-checks-fleet: validate-required-checks.sh not found on PATH or in $SELF_DIR" >&2
  exit 2
fi

DIGEST=""
TOTAL=0
CLEAN=0
ERRORS=()

for repo in $REPOS; do
  TOTAL=$((TOTAL + 1))
  out=""
  err_rc=0
  # Capture both stdout + stderr; let the script's exit code distinguish
  # validator-error vs policy-warning. Tee into a string for the digest.
  if out=$("$VALIDATOR" "$repo" 2>&1); then
    if [[ -z "$out" ]]; then
      CLEAN=$((CLEAN + 1))
    else
      DIGEST="$DIGEST"$'\n'"### $repo"$'\n\n```'$'\n'"$out"$'\n''```'$'\n'
    fi
  else
    err_rc=$?
    ERRORS+=("$repo (exit $err_rc)")
    DIGEST="$DIGEST"$'\n'"### $repo (script error, exit $err_rc)"$'\n\n```'$'\n'"$out"$'\n''```'$'\n'
  fi
done

ISO_DATE="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
if [[ -z "$DIGEST" ]]; then
  echo "All $TOTAL repos clean. Last run: $ISO_DATE" > "$OUT"
else
  {
    echo "# Required-checks audit digest"
    echo
    echo "Run: $ISO_DATE"
    echo "Fleet: $TOTAL repos ($CLEAN clean, $((TOTAL - CLEAN)) with output)"
    echo
    echo "$DIGEST"
  } > "$OUT"
fi

if [[ ${#ERRORS[@]} -gt 0 ]]; then
  echo "audit-required-checks-fleet: ${#ERRORS[@]} repo(s) errored: ${ERRORS[*]}" >&2
  exit 1
fi
exit 0
