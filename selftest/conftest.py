"""Make `check_draft_gate_triggers` importable when pytest is invoked from the repo root.

selftest.yml runs `pytest selftest` from the repo root, so the checker's directory is not
on sys.path by default and the import fails at COLLECTION time — which reads as a broken
selftest rather than a failing rule. Keep this file even if it looks redundant: without it
`pytest selftest` from the root dies with ModuleNotFoundError.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
