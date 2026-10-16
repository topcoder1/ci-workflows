#!/usr/bin/env bash
# audit-required-checks-fleet.sh — fleet-fanout wrapper around
# validate-required-checks.sh.
#
# Loops over the supplied repo list (default: hardcoded 14-repo GH fleet),
# calls validate-required-checks.sh on each, and emits a digest body. Used
# by the weekly audit-required-checks.yml cron GHA to decide whether to
# open / update a digest issue.
#
# Each repo is filed by the validator's exit code (see its header):
#   0      clean: no digest block, counted in the "clean" total
#   1      FINDING: a required check will never report on PRs, but only with
#          the validator's `==> FAIL` verdict line. Without it, exit 1 is an
#          ERROR: bash exits 1 on an unbound variable under set -u, and Python
#          on a SyntaxError, before any verdict exists.
#   other  ERROR: the audit could not check the repo (3 = GitHub API error,
#          4 = validator crashed, 2 = usage / missing tool, anything else =
#          unexpected exit code)
# Findings and errors get differently worded digest headings and stderr
# lines, so "the audit found something" never reads like "the audit broke".
#
# Attaxion repos are skipped by name, the same rule as the fleet red-workflow
# digest (topcoder1/dotclaude templates/ci-workflows/scripts/
# fleet-red-workflow-sweep.sh): the ERE '^(asm-|attaxion)' against the
# lowercased repo name, owner excluded. Skipped names go to stderr and the
# digest.
#
# Exit codes (audit-required-checks.yml fails the org's job on any non-zero):
#   0  every audited repo clean
#   1  at least one finding, and every repo was audited
#   2  usage error, validator not found, or no repo left after the skip
#   3  at least one repo could not be audited (findings may exist as well)
#
# Usage:
#   audit-required-checks-fleet.sh --repos "owner/repo1 owner/repo2 ..."
#                                  [--out FILE]   # default stdout
#
# Stdout / --out content (digest body):
#   - One block per repo with a finding or an error, holding the validator's
#     output
#   - "All N repos clean. Last run: <ISO date>" if zero blocks (the workflow's
#     digest job opens no issue when every org's first line reads so)
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

# Attaxion repos are out of scope for this fleet tooling (see the header).
EXCLUDE='^(asm-|attaxion)'

DIGEST=""
TOTAL=0
CLEAN=0
FINDINGS=0
ERRORS=0
FINDING_REPOS=""
ERROR_REPOS=""
SKIPPED=""

for repo in $REPOS; do
  lname=$(printf '%s' "${repo#*/}" | tr '[:upper:]' '[:lower:]')
  if [[ "$lname" =~ $EXCLUDE ]]; then
    SKIPPED="${SKIPPED:+$SKIPPED, }$repo"
    continue
  fi
  TOTAL=$((TOTAL + 1))
  # Capture stdout + stderr for the digest. The validator always prints a
  # header, so only its exit code says how the repo is filed.
  rc=0
  out=$("$VALIDATOR" "$repo" 2>&1) || rc=$?
  # ERROR unless proven otherwise: a code with no arm below stays an error,
  # and exit 1 is a finding only beside the validator's own FAIL verdict.
  kind=error
  why="unexpected exit code"
  case "$rc" in
    0) kind=clean ;;
    1)
      if grep -q '^==> FAIL' <<< "$out"; then
        kind=finding
      else
        why="no FAIL verdict in the output"
      fi
      ;;
    2) why="usage error or missing tool" ;;
    3) why="GitHub API error" ;;
    4) why="validator crashed" ;;
  esac
  case "$kind" in
    clean)
      CLEAN=$((CLEAN + 1))
      ;;
    finding)
      FINDINGS=$((FINDINGS + 1))
      FINDING_REPOS="${FINDING_REPOS:+$FINDING_REPOS, }$repo"
      DIGEST="$DIGEST"$'\n'"### $repo — FINDING: a required check will never report on PRs"$'\n\n```'$'\n'"$out"$'\n''```'$'\n'
      ;;
    *)
      ERRORS=$((ERRORS + 1))
      ERROR_REPOS="${ERROR_REPOS:+$ERROR_REPOS, }$repo (exit $rc: $why)"
      DIGEST="$DIGEST"$'\n'"### $repo — ERROR: not audited (exit $rc: $why)"$'\n\n```'$'\n'"$out"$'\n''```'$'\n'
      ;;
  esac
done

SKIP_NOTE=""
if [[ -n "$SKIPPED" ]]; then
  SKIP_NOTE="Skipped by name ($EXCLUDE): $SKIPPED."
  echo "audit-required-checks-fleet: $SKIP_NOTE" >&2
fi
if [[ $TOTAL -eq 0 ]]; then
  echo "audit-required-checks-fleet: no repo left to audit" >&2
  exit 2
fi

ISO_DATE="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
if [[ -z "$DIGEST" ]]; then
  {
    echo "All $TOTAL repos clean. Last run: $ISO_DATE"
    if [[ -n "$SKIP_NOTE" ]]; then echo "$SKIP_NOTE"; fi
  } > "$OUT"
else
  {
    echo "# Required-checks audit digest"
    echo
    echo "Run: $ISO_DATE"
    echo "Fleet: $TOTAL repos audited ($CLEAN clean, $FINDINGS with findings, $ERRORS could not be audited)"
    if [[ -n "$SKIP_NOTE" ]]; then echo "$SKIP_NOTE"; fi
    echo
    echo "$DIGEST"
  } > "$OUT"
fi

if [[ $FINDINGS -gt 0 ]]; then
  echo "audit-required-checks-fleet: FINDINGS in $FINDINGS repo(s), a required check that will never report on PRs: $FINDING_REPOS" >&2
fi
if [[ $ERRORS -gt 0 ]]; then
  echo "audit-required-checks-fleet: ERRORS: $ERRORS repo(s) could not be audited: $ERROR_REPOS" >&2
  exit 3
fi
if [[ $FINDINGS -gt 0 ]]; then
  exit 1
fi
exit 0
