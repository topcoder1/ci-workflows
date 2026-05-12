"""Tests for scripts/verifier-redact-secrets.py.

Run from repo root: python3 -m pytest scripts/tests/test_verifier_redact_secrets.py -v
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent.parent
SCRIPT = REPO / "scripts" / "verifier-redact-secrets.py"


def _run(args, cwd=None):
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args],
        cwd=cwd, capture_output=True, text=True,
    )


PROBES = [
    ("AKIA1234567890ABCDEF", "AWS access key"),
    ("AIzaSyA0123456789abcdefghijklmnopqrstuvwxyz", "GCP API key"),
    ("Bearer abcdefghijklmnopqrstuvwxyz1234567890", "raw bearer"),
    ("api_key=verysecret_pleasedonotleak0xDEADBEEF", "key=val"),
]


@pytest.mark.parametrize("probe,label", PROBES)
def test_redacts_in_place(tmp_path, probe, label):
    f = tmp_path / "evidence.txt"
    f.write_text(f"prefix\n{probe}\nsuffix\n")
    rc = _run([str(f)])
    assert rc.returncode == 0, rc.stderr
    out = f.read_text()
    assert probe not in out, f"{label} not redacted: {out!r}"
    assert "REDACTED" in out


def test_preserves_full_git_sha(tmp_path):
    sha = "0123456789abcdef0123456789abcdef01234567"
    f = tmp_path / "evidence.txt"
    f.write_text(f"resolved to {sha}\n")
    rc = _run([str(f)])
    assert rc.returncode == 0
    assert sha in f.read_text(), "full git SHA was wrongly redacted"


def test_no_args_exits_nonzero():
    rc = _run([])
    assert rc.returncode != 0
