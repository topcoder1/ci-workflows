#!/usr/bin/env bash
# Guards the input TYPE of claude-review.yml's `max_turns`.
#
# `${{ inputs.max_turns }}` is interpolated verbatim into `claude_args`, which
# the action parses as CLI arguments. Declared as `string`, any calling repo can
# smuggle extra flags through it:
#
#   max_turns: "25 --allowedTools 'Bash(*),mcp__github__*'"
#
# That widens the tool allowlist of a workflow the entire fleet runs, from a
# per-repo caller file that no central review sees. `type: number` closes it at
# GitHub's input validation, before interpolation ever happens — a non-numeric
# value is rejected and the run never starts.
#
# Caught in review on ci-workflows#152, which originally shipped `type: string`
# with `default: "25"`.
#
# The default must also stay a BARE integer: GitHub rejects a quoted string
# literal as the default of a `number` input, and that failure mode is a
# startup_failure, which emits no check-run at all — so a required
# `review / Claude Review` context would simply never report and every PR in
# every calling repo would wedge on a check that cannot arrive.
#
# Run from the repo root:
#   bash selftest/test_claude_review_max_turns_type.sh
set -euo pipefail

WF=".github/workflows/claude-review.yml"
failed=0

fail() { echo "  FAIL: $*"; failed=1; }
pass() { echo "  ok: $*"; }

echo "== claude-review.yml max_turns input type =="

python3 - "$WF" <<'PY' || failed=1
import sys, yaml

path = sys.argv[1]
with open(path) as fh:
    doc = yaml.safe_load(fh)

# PyYAML parses the bare `on:` key as the boolean True.
trigger = doc.get("on", doc.get(True))
inputs = trigger["workflow_call"]["inputs"]

problems = []

if "max_turns" not in inputs:
    problems.append("max_turns input is missing entirely")
else:
    mt = inputs["max_turns"]

    if mt.get("type") != "number":
        problems.append(
            f"max_turns type is {mt.get('type')!r}, must be 'number' — "
            "'string' lets a caller inject extra CLI flags into claude_args"
        )

    default = mt.get("default")
    if not isinstance(default, int) or isinstance(default, bool):
        problems.append(
            f"max_turns default is {default!r} ({type(default).__name__}); a "
            "number input needs a bare integer, and a quoted default is a "
            "startup_failure that emits no check-run"
        )

# The interpolation this all protects must still be the thing being fed.
with open(path) as fh:
    body = fh.read()
if "--max-turns ${{ inputs.max_turns }}" not in body:
    problems.append(
        "claude_args no longer interpolates inputs.max_turns; if the flag moved, "
        "move this guard with it"
    )

for p in problems:
    print(f"  FAIL: {p}")
sys.exit(1 if problems else 0)
PY

if [ "$failed" -eq 0 ]; then
  pass "max_turns is type: number with a bare-integer default, interpolated into claude_args"
fi

echo
if [ "$failed" -ne 0 ]; then
  echo "FAILED"
  exit 1
fi
echo "PASSED"
