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


# Codex round 4: KNOWN_SAFE allowlist for hex HMAC / UUID shapes was a
# redaction bypass (real secrets often take those shapes). The allowlist
# is now restricted to ONLY full git-SHAs. The values below SHOULD be
# redacted by the catch-all >= 40-char regex — we accept the false-
# positive on legitimate sha256 digests as the cost of fail-safe.
HEX_LIKE_SECRET_SHAPES = [
    ("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "sha256-shaped (could be HMAC)"),
    ("550e8400e29b41d4a716446655440000abcdef0123456789abcdef0123456789", "high-entropy 64ch hex"),
]


@pytest.mark.parametrize("value,label", HEX_LIKE_SECRET_SHAPES)
def test_redacts_hex_like_high_entropy_strings(tmp_path, value, label):
    """Hex tokens >= 40 chars are redacted UNLESS they match the
    git-SHA allowlist (40 lowercase hex). 64-char shapes do not match."""
    f = tmp_path / "evidence.txt"
    f.write_text(f"value: {value}\n")
    rc = _run([str(f)])
    assert rc.returncode == 0
    assert value not in f.read_text(), f"{label} should have been redacted"


def test_no_args_exits_nonzero():
    rc = _run([])
    assert rc.returncode != 0
