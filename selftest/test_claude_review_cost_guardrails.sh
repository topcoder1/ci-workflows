#!/usr/bin/env bash
# Guards the SPEND CEILINGS of claude-review.yml — the controls added after
# the 2026-08-14..16 incident, in which the `review / Claude Review` lane (a
# REQUIRED check on ~49 repos) went from $0.65-1.14 to $3.26-6.89 per review
# for two days and pushed the org over its monthly cap, pausing the API for
# CI and production alike. Root cause: a Claude Code CLI behavior change
# (bundled multi-agent /code-review fan-out) reached the fleet through an
# UNPINNED CLI install; --max-turns saw none of the subagent spend.
#
# Four properties, all static (the behavioral half — the guard step's
# budget-stop verdict and soft warning — lives in
# test_claude_review_lost_findings_guard.sh S19-S21):
#
#   1. `max_budget_usd` is a `number` input with a bare numeric default and is
#      interpolated as `--max-budget-usd ${{ inputs.max_budget_usd }}` — the
#      same injection guard as max_turns (see test_claude_review_max_turns_type.sh):
#      `string` would let a caller smuggle flags into claude_args, and a quoted
#      default is a startup_failure that emits no check-run at all.
#   2. The review step has a step-level `timeout-minutes` (<= 30) and the job
#      a larger job-level one — step-level so a timed-out review still reaches
#      the lost-findings guard.
#   3. The Claude Code CLI is PINNED (`CLAUDE_CODE_VERSION`, semver, >= 2.1.217
#      = the floor for --max-budget-usd counting subagent spend), the install
#      step targets it AND refuses to review on any other version.
#   4. The guard step receives the cap (`MAX_BUDGET_USD`) and names the
#      budget-stop subtype `error_max_budget_usd`.
#
# Run from the repo root:
#   bash selftest/test_claude_review_cost_guardrails.sh
set -euo pipefail

WF=".github/workflows/claude-review.yml"
failed=0

pass() { echo "  ok: $*"; }

echo "== claude-review.yml spend ceilings: budget input, timeouts, CLI pin, guard wiring =="

python3 - "$WF" <<'PY' || failed=1
import re, sys, yaml

path = sys.argv[1]
with open(path) as fh:
    doc = yaml.safe_load(fh)
with open(path) as fh:
    body = fh.read()

problems = []

# ---- 1. max_budget_usd input ------------------------------------------------
trigger = doc.get("on", doc.get(True))  # PyYAML parses bare `on:` as True
inputs = trigger["workflow_call"]["inputs"]
mb = inputs.get("max_budget_usd")
if mb is None:
    problems.append("max_budget_usd input is missing entirely")
else:
    if mb.get("type") != "number":
        problems.append(
            f"max_budget_usd type is {mb.get('type')!r}, must be 'number' — "
            "'string' lets a caller inject extra CLI flags into claude_args"
        )
    default = mb.get("default")
    if isinstance(default, bool) or not isinstance(default, (int, float)):
        problems.append(
            f"max_budget_usd default is {default!r} ({type(default).__name__}); a "
            "number input needs a bare numeric default — a quoted default is a "
            "startup_failure that emits no check-run"
        )
    elif not (0 < default <= 10):
        problems.append(
            f"max_budget_usd default {default!r} is outside (0, 10]: the fleet "
            "baseline is median $0.61 / p90 $1.06 / max $2.68 per review; a "
            "default this far off is either a typo or a silent policy change"
        )
if "--max-budget-usd ${{ inputs.max_budget_usd }}" not in body:
    problems.append(
        "claude_args no longer interpolates inputs.max_budget_usd as "
        "`--max-budget-usd ${{ inputs.max_budget_usd }}`; if the flag moved, move this guard with it"
    )
if "--max-turns ${{ inputs.max_turns }}" not in body:
    problems.append("claude_args lost `--max-turns ${{ inputs.max_turns }}` — the turn cap is the second bound")

# ---- 2. timeouts -----------------------------------------------------------------
job = doc["jobs"]["review"]
steps = job["steps"]
by_id = {s.get("id"): s for s in steps if s.get("id")}
review = by_id.get("claude")
if review is None:
    problems.append("no step with `id: claude` (the claude-code-action step)")
else:
    st = review.get("timeout-minutes")
    if not isinstance(st, int) or isinstance(st, bool) or not (0 < st <= 30):
        problems.append(
            f"the review step's timeout-minutes is {st!r}; must be an int in (0, 30] "
            "(fleet baseline p90 ~7 min, longest legit run on record 18 min; the "
            "Aug-14 fan-out ran 25-134 min, one run 629 min)"
        )
    jt = job.get("timeout-minutes")
    if not isinstance(jt, int) or isinstance(jt, bool):
        problems.append(f"job-level timeout-minutes is {jt!r}; must be an int (GitHub's default is 6h)")
    elif isinstance(st, int) and not isinstance(st, bool) and jt <= st:
        problems.append(
            f"job timeout-minutes ({jt}) must exceed the review step's ({st}) so a "
            "timed-out review still reaches the lost-findings guard"
        )

# ---- 3. CLI pin -----------------------------------------------------------------
pin = (job.get("env") or {}).get("CLAUDE_CODE_VERSION")
m = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", str(pin or ""))
if not m:
    problems.append(
        f"jobs.review.env.CLAUDE_CODE_VERSION is {pin!r}; must be an exact semver "
        "(no `latest`/`stable`) — the pin is the fleet's rollback lever"
    )
elif tuple(int(x) for x in m.groups()) < (2, 1, 217):
    problems.append(
        f"CLAUDE_CODE_VERSION {pin} is below 2.1.217, the floor at which "
        "--max-budget-usd counts subagent spend and stops running subagents"
    )
install = next((s for s in steps if str(s.get("name", "")).startswith("Pre-install Claude Code binary")), None)
if install is None:
    problems.append("no `Pre-install Claude Code binary ...` step")
else:
    run = install.get("run", "")
    if 'bash -s -- "$CLAUDE_CODE_VERSION"' not in run:
        problems.append("the install step no longer passes $CLAUDE_CODE_VERSION to install.sh (`bash -s -- \"$CLAUDE_CODE_VERSION\"`)")
    if "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" not in run:
        problems.append("the npm fallback no longer pins @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}")
    if "refusing to review on an unpinned binary" not in run:
        problems.append("the install step no longer refuses to review on a version other than the pin")
    # The refusal must be a hard exit, not a warning: find the line after the
    # refusal message and require `exit 1` before the next non-comment line.
    lines = run.splitlines()
    idx = next((i for i, l in enumerate(lines) if "refusing to review on an unpinned binary" in l), None)
    if idx is not None:
        following = [l.strip() for l in lines[idx + 1: idx + 3] if l.strip() and not l.strip().startswith("#")]
        if not following or following[0] != "exit 1":
            problems.append("the unpinned-binary refusal is not followed by `exit 1` — it must fail closed")

# ---- 4. guard wiring ---------------------------------------------------------------
guard = by_id.get("guard")
if guard is None:
    problems.append("no `id: guard` step")
else:
    if (guard.get("env") or {}).get("MAX_BUDGET_USD") != "${{ inputs.max_budget_usd }}":
        problems.append("guard env MAX_BUDGET_USD is not wired to ${{ inputs.max_budget_usd }} — the budget-stop message names the wrong cap")
    grun = guard.get("run", "")
    if "error_max_budget_usd" not in grun:
        problems.append("the guard no longer names the budget-stop subtype `error_max_budget_usd`")
    if not re.search(r"^\s*SOFT_COST_USD=\d+(\.\d+)?\s*$", grun, re.M):
        problems.append("the guard has no numeric SOFT_COST_USD soft threshold")

for p in problems:
    print(f"  FAIL: {p}")
sys.exit(1 if problems else 0)
PY

if [ "$failed" -eq 0 ]; then
  pass "max_budget_usd is type: number with a bare numeric default and interpolated into claude_args"
  pass "review step timeout-minutes <= 30, job timeout-minutes larger"
  pass "Claude Code CLI pinned to an exact version >= 2.1.217; install targets it and refuses anything else"
  pass "guard receives MAX_BUDGET_USD and names error_max_budget_usd"
fi

echo
if [ "$failed" -ne 0 ]; then
  echo "FAILED"
  exit 1
fi
echo "PASSED"
