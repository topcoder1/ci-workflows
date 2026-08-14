#!/usr/bin/env bash
# Behavioral test for the ruff rule-set warning in lint.yml.
#
# #139 pinned ruff's version, which stops a new ruff release from reddening
# the fleet on release day. It does not make any repo's rule set EXPLICIT:
# a repo with no `select` still inherits ruff's built-in defaults, so the
# deliberate pin bump re-scopes what that repo enforces, and the new findings
# land on whoever opens the next unrelated PR there. dotclaude#186 is the
# shape of that — an unchanged tests/ tree went from clean to 25 errors
# (ISC004 x12, PLW1510 x8, FURB167 x3, RUF059, PIE810) purely because 0.16
# widened the defaults. The pin defers that hazard to bump time; this warning
# is what makes it visible before then.
#
# Pins:
#   1. The warning fires when no rule selection is declared anywhere.
#   2. It does NOT fire for pyproject `[tool.ruff.lint]`/`[tool.ruff]` select,
#      `extend-select`, or a `ruff.toml`/`.ruff.toml` selection.
#   3. It reads ONLY `[tool.ruff*]` tables. A `select =` under some other
#      tool must not suppress it — a repo told it declared a rule set it did
#      not is worse off than one that was never told anything.
#   4. It WARNS rather than fails. A hard failure would redden every
#      currently-green consumer the moment it merges.
#
# The detection block is EXTRACTED from the workflow YAML and executed, so
# this exercises the shipped bash rather than a mirrored copy.
#
# The version pin itself is covered by test_lint_ruff_version_is_pinned in
# selftest/test_workflow_guards.py — not duplicated here.
#
# Run from the repo root:
#   bash selftest/test_ruff_ruleset_warning.sh
set -euo pipefail

WF=.github/workflows/lint.yml
failed=0

pass() { echo "✓ $1"; }
fail() {
  echo "✗ $1"
  failed=1
}

# Extraction starts at the helper's definition, NOT at RULESET_DECLARED=0 —
# the caller alone would eval to an undefined function, and every case would
# then "warn" for the wrong reason while looking like a real detector bug.
# Terminator moved from `echo "ruff check (v` to `RC=0` when the format gate
# landed. That echo is now nested inside `if [ "$RUN_CHECK" = "true" ]`, so
# stopping at it would capture the opening `if` without its `fi` — the block
# would fail to parse and every case below would report for the wrong reason.
# `RC=0` is the first line after the advisory and sits at the same top level
# the echo used to, so the extracted region stays exactly the rule-set logic.
block=$(awk '
  /^[[:space:]]*ruff_select_declared\(\) \{/ { grab = 1 }
  grab && /^[[:space:]]*RC=0[[:space:]]*$/ { exit }
  grab { print }
' "$WF" | sed 's/^[[:space:]]*//')

if [ -z "$block" ]; then
  echo "✗ could not extract the rule-set detection block from $WF"
  exit 1
fi
# Guard the extraction itself: both the helper and its caller must be present.
for required in 'ruff_select_declared()' 'RULESET_DECLARED=0' '::warning::'; do
  case "$block" in
    *"$required"*) ;;
    *)
      echo "✗ extracted block is missing '$required' — the anchors have drifted"
      exit 1
      ;;
  esac
done

# The warning must never be able to fail the job.
if printf '%s' "$block" | grep -q '::error::'; then
  fail "the rule-set check emits ::error:: — it must only ever ::warning::"
else
  pass "rule-set check is advisory (no ::error::)"
fi
if printf '%s' "$block" | grep -Eq '^[[:space:]]*exit [1-9]'; then
  fail "the rule-set check exits non-zero — it must not fail the job"
else
  pass "rule-set check cannot fail the job"
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# check_case <name> <yes|no> [filename contents]...
check_case() {
  name=$1
  expect=$2
  shift 2
  case_dir="$tmp/case"
  rm -rf "$case_dir"
  mkdir -p "$case_dir"
  while [ "$#" -ge 2 ]; do
    printf '%s\n' "$2" >"$case_dir/$1"
    shift 2
  done
  got=$(
    cd "$case_dir"
    RUFF_VERSION=0.15.10
    eval "$block" 2>&1 || true
  )
  case "$got" in
    *"::warning::No explicit ruff rule selection"*) actual=yes ;;
    *) actual=no ;;
  esac
  if [ "$actual" = "$expect" ]; then
    pass "$name (warning=$actual)"
  else
    fail "$name: expected warning=$expect, got warning=$actual"
  fi
}

check_case "pyproject [tool.ruff.lint] select -> silent" no \
  pyproject.toml '[tool.ruff.lint]
select = ["E4", "E7", "E9", "F"]'

check_case "pyproject legacy [tool.ruff] select -> silent" no \
  pyproject.toml '[tool.ruff]
select = ["E", "F"]'

check_case "pyproject extend-select -> silent" no \
  pyproject.toml '[tool.ruff.lint]
extend-select = ["I"]'

# TOML dotted keys spell the same setting several ways. Matching a bare
# `select` inside a ruff table sees only the first form and tells a repo that
# DID declare a rule set that it did not — the harmful direction, since it
# sends someone to add config they already have. (Claude review round 1.)
check_case "pyproject [tool.ruff] + dotted lint.select -> silent" no \
  pyproject.toml '[tool.ruff]
lint.select = ["E4", "E7", "E9", "F"]'

check_case "pyproject [tool.ruff] + dotted lint.extend-select -> silent" no \
  pyproject.toml '[tool.ruff]
lint.extend-select = ["B"]'

check_case "pyproject [tool] + fully dotted ruff.lint.select -> silent" no \
  pyproject.toml '[tool]
ruff.lint.select = ["F"]'

# A dotted key under [tool.ruff] that is NOT the rule set must still warn.
check_case "pyproject [tool.ruff] + dotted lint.line-length -> warns" yes \
  pyproject.toml '[tool.ruff]
lint.line-length = 100'

# And a dotted `select` owned by another tool must not match either.
check_case "pyproject [tool] + other-tool dotted select -> warns" yes \
  pyproject.toml '[tool]
someotherlinter.select = ["ALL"]'

check_case "pyproject with no ruff config -> warns" yes \
  pyproject.toml '[project]
name = "x"'

# The false negative that would actually matter.
check_case "select under a NON-ruff table -> still warns" yes \
  pyproject.toml '[project]
name = "x"

[tool.someotherlinter]
select = ["ALL"]'

check_case "[tool.ruff] configuring something else -> warns" yes \
  pyproject.toml '[tool.ruff]
line-length = 100'

check_case "ruff.toml with select -> silent" no \
  ruff.toml 'select = ["E4", "F"]'

check_case "ruff.toml without select -> warns" yes \
  ruff.toml 'line-length = 100'

check_case ".ruff.toml [lint] extend-select -> silent" no \
  .ruff.toml '[lint]
extend-select = ["B"]'

check_case "no config files at all -> warns" yes

exit "$failed"
