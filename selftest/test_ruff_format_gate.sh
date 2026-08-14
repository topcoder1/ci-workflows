#!/usr/bin/env bash
# Behavioral test for the `ruff format --check` gate in lint.yml.
#
# Why the gate exists: `ruff check` and `ruff format --check` catch DISJOINT
# problems, and until now this workflow could only do the former. webcrawl#429
# found 10 of 12 files under scripts/ format-dirty while raising ZERO lint
# errors — `ruff check` called that tree clean right up until formatting was
# gated. A fleet audit on 2026-08-14 found the same shape in 4 of the 7 repos
# that lint Python here (328 dirty files total), because no consumer had any
# way to check formatting.
#
# Pins:
#   1. run_ruff_format defaults to FALSE. Enabling by default would redden
#      every consumer carrying pre-existing drift on the day it merged — the
#      exact fleet breakage this file's "drop in without breaking it" default
#      exists to prevent.
#   2. The job runs when EITHER gate is requested, so run_ruff_format alone is
#      not a silent no-op.
#   3. BOTH gates run in a single pass. Short-circuiting on the first failure
#      would hide the formatter's findings behind a lint failure, turning one
#      red gate into two fix cycles.
#   4. A failure in EITHER gate fails the step.
#   5. Both invocations receive the SAME paths and the SAME pinned version, so
#      the two gates can never disagree about scope or rule set.
#
# The run block is EXTRACTED from the workflow YAML and executed against a
# stubbed `pipx`, so this exercises the shipped bash rather than a mirror.
#
# Run from the repo root:
#   bash selftest/test_ruff_format_gate.sh
set -euo pipefail

WF=.github/workflows/lint.yml
failed=0

pass() { echo "✓ $1"; }
fail() {
  echo "✗ $1"
  [ -n "${2:-}" ] && echo "    $2"
  failed=1
}

# --- static: the input contract -------------------------------------------
default=$(python3 -c "
import yaml
d = yaml.safe_load(open('$WF'))
print(d[True]['workflow_call']['inputs']['run_ruff_format']['default'])
")
[ "$default" = "False" ] &&
  pass "run_ruff_format defaults to false (opt-in)" ||
  fail "run_ruff_format default is '$default', expected False" \
    "Defaulting ON reddens every consumer with pre-existing drift."

cond=$(python3 -c "
import yaml
print(yaml.safe_load(open('$WF'))['jobs']['ruff']['if'])
")
case "$cond" in
  *run_ruff_format*) pass "job condition honours run_ruff_format" ;;
  *) fail "job condition ignores run_ruff_format" \
      "run_ruff_format: true would be a silent no-op: $cond" ;;
esac

# --- behavioral: extract the run block and execute it ----------------------
work=$(mktemp -d)
trap 'rm -rf "$work"; return 0 2>/dev/null || true' EXIT

python3 -c "
import yaml
steps = yaml.safe_load(open('$WF'))['jobs']['ruff']['steps']
run = [s for s in steps if s.get('name') == 'Run ruff'][0]['run']
open('$work/run.sh', 'w').write(run)
"

mkdir -p "$work/bin" "$work/repo/src" "$work/repo/tests"
# Stub pipx: log the ruff subcommand + its paths, and fail `check` so the
# no-short-circuit property is observable.
cat > "$work/bin/pipx" <<'STUB'
#!/usr/bin/env bash
args=("$@")
out=""
seen_ruff=0
for a in "${args[@]}"; do
  if [ "$seen_ruff" = "1" ]; then out="$out $a"; fi
  if [ "$a" = "ruff" ]; then seen_ruff=1; fi
done
echo "INVOKED:${out}" >> "$PIPX_LOG"
case "$out" in
  *" check "*) exit 1 ;;   # lint fails
  *) exit 0 ;;             # formatter passes
esac
STUB
chmod +x "$work/bin/pipx"

export PIPX_LOG="$work/invocations.log"
: > "$PIPX_LOG"

set +e
(
  cd "$work/repo"
  PATH="$work/bin:$PATH" \
  RUFF_PATHS="" RUFF_VERSION="0.15.10" RUN_CHECK="true" RUN_FORMAT="true" \
    bash "$work/run.sh"
) > "$work/stdout.log" 2>&1
rc=$?
set -e

log=$(cat "$PIPX_LOG")

grep -q 'INVOKED:.* check ' <<< "$log" &&
  pass "ruff check ran" ||
  fail "ruff check did not run" "$log"

grep -q 'INVOKED:.* format --check ' <<< "$log" &&
  pass "ruff format --check ran even though check FAILED (no short-circuit)" ||
  fail "formatter was skipped after a lint failure" \
    "One red gate would then take two fix cycles. log: $log"

[ "$rc" -ne 0 ] &&
  pass "step fails when a gate fails (rc=$rc)" ||
  fail "step exited 0 despite a failing gate" "$(cat "$work/stdout.log")"

# Same scope and same pin for both — otherwise the gates can disagree.
check_paths=$(grep 'INVOKED:.* check ' <<< "$log" | sed 's/.* check //')
fmt_paths=$(grep 'INVOKED:.* format --check ' <<< "$log" | sed 's/.* format --check //')
[ -n "$check_paths" ] && [ "$check_paths" = "$fmt_paths" ] &&
  pass "both gates got identical paths ($check_paths)" ||
  fail "scope differs between gates" "check='$check_paths' format='$fmt_paths'"

grep -q 'ruff==0.15.10' <<< "$(cat "$PIPX_LOG")" 2>/dev/null || true
vers=$(grep -c 'INVOKED:' <<< "$log")
[ "$vers" -eq 2 ] &&
  pass "exactly two invocations (one per gate)" ||
  fail "expected 2 invocations, saw $vers" "$log"

# --- format-only must not require run_ruff --------------------------------
: > "$PIPX_LOG"
set +e
(
  cd "$work/repo"
  PATH="$work/bin:$PATH" \
  RUFF_PATHS="" RUFF_VERSION="0.15.10" RUN_CHECK="false" RUN_FORMAT="true" \
    bash "$work/run.sh"
) > "$work/stdout2.log" 2>&1
rc2=$?
set -e
log2=$(cat "$PIPX_LOG")

! grep -q 'INVOKED:.* check ' <<< "$log2" &&
  pass "run_ruff=false suppresses ruff check" ||
  fail "ruff check ran with RUN_CHECK=false" "$log2"

grep -q 'INVOKED:.* format --check ' <<< "$log2" && [ "$rc2" -eq 0 ] &&
  pass "format-only run works standalone and passes" ||
  fail "format-only run misbehaved (rc=$rc2)" "$log2"

echo
[ "$failed" -eq 0 ] && echo "all ruff-format-gate checks passed" || echo "FAILURES above"
exit "$failed"
