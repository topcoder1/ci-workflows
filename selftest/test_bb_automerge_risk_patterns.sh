#!/usr/bin/env bash
# Selftest for bb-automerge.py — exercises HIGH_RISK_PATTERNS against the
# shared corpus at selftest/risk_patterns_corpus.txt. ANY drift between
# bb-automerge.py and claude-author-automerge.yml is caught here OR by the
# parallel test_automerge_risk_patterns.sh; matching corpora means matching
# coverage.
#
# Run from the repo root:
#   bash selftest/test_bb_automerge_risk_patterns.sh
#
# Resolution of bb-automerge.py:
#   - Prefer $BB_AUTOMERGE_PY if set
#   - Else $HOME/.claude/templates/ci-workflows/scripts/bb-automerge.py
#   - Else fail
set -euo pipefail

SCRIPT="${BB_AUTOMERGE_PY:-$HOME/.claude/templates/ci-workflows/scripts/bb-automerge.py}"
if [ ! -f "$SCRIPT" ]; then
  echo "FAIL: bb-automerge.py not found at $SCRIPT"
  echo "Hint: set BB_AUTOMERGE_PY env var to its location"
  exit 2
fi

CORPUS="$(dirname "$0")/risk_patterns_corpus.txt"
[ ! -f "$CORPUS" ] && { echo "FAIL: corpus not found at $CORPUS"; exit 2; }

# One-shot Python harness — load the script via importlib, exercise find_high_risk
HARNESS=$(cat <<'PYEOF'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location('bba', os.environ['SCRIPT'])
mod = importlib.util.module_from_spec(spec)
# Register in sys.modules BEFORE exec_module so @dataclass can resolve cls.__module__
# (Python 3.14 stricter behavior — see CPython dataclasses.py line 814).
sys.modules['bba'] = mod
spec.loader.exec_module(mod)
fail = 0
for line in open(os.environ['CORPUS']):
    line = line.strip()
    if not line or line.startswith('#'):
        continue
    if line.startswith('RISKY_BB:'):
        path = line[len('RISKY_BB: '):]
        hits = mod.find_high_risk([path])
        if not hits:
            print(f"FAIL [risky_bb->safe]: '{path}' not classified as high-risk by BB patterns")
            fail = 1
    elif line.startswith('RISKY:'):
        path = line[len('RISKY: '):]
        hits = mod.find_high_risk([path])
        if not hits:
            print(f"FAIL [risky->safe]: '{path}' not classified as high-risk")
            fail = 1
    elif line.startswith('SAFE:'):
        path = line[len('SAFE: '):]
        hits = mod.find_high_risk([path])
        if hits:
            print(f"FAIL [safe->risky]: '{path}' incorrectly classified as high-risk")
            fail = 1
sys.exit(fail)
PYEOF
)
SCRIPT="$SCRIPT" CORPUS="$CORPUS" python3 -c "$HARNESS"
EXIT=$?
if [ $EXIT -eq 0 ]; then
  COUNT=$(grep -cE '^(RISKY(_BB)?|SAFE):' "$CORPUS")
  echo "PASS — all $COUNT cases"
fi
exit $EXIT
