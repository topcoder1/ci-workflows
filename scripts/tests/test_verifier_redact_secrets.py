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
    ("ghp_1234567890abcdefghijklmnopqrstuvwxyzABCD", "GitHub PAT classic"),
    ("github_pat_11ABC1234567890abcdefghij_abcdefghijklmnopqrstuvwxyz1234567890ABCDEFGHabcdef", "GitHub fine-grained PAT"),
    ("sk-ant-api03-abcdefghij1234567890abcdefghij1234567890ABCDEFGH", "Anthropic API key"),
    ("sk-proj-abcdefghij1234567890abcdefghij1234567890ABCDEFGH", "OpenAI project key"),
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


SAFE_EVIDENCE_VALUES = [
    ("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "sha256 hex"),
    ("aabbccddeeff00112233445566778899", "md5 hex / UUID-no-hyphens"),
    ("550e8400-e29b-41d4-a716-446655440000", "UUID with hyphens"),
]


@pytest.mark.parametrize("value,label", SAFE_EVIDENCE_VALUES)
def test_preserves_legitimate_evidence_values(tmp_path, value, label):
    f = tmp_path / "evidence.txt"
    f.write_text(f"computed digest: {value}\n")
    rc = _run([str(f)])
    assert rc.returncode == 0
    assert value in f.read_text(), f"{label} ({value}) was wrongly redacted"


def test_no_args_exits_nonzero():
    rc = _run([])
    assert rc.returncode != 0
