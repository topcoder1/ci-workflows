#!/usr/bin/env python3
"""verifier-redact-secrets — in-place secret-scrub on evidence files.

Scans each input file against the broadened secret-pattern list (mirrored
from the B2 verifier in attaxion_dev/tools/regenerate-plan-proofs.py).
Replaces each match with `[REDACTED:{N}ch]` in place.

Used by verifier-on-high-risk.yml AFTER the verifier agent emits its
evidence bundle and BEFORE actions/upload-artifact runs. This is the
spec section B1 "pre-publish redaction" step — without it, evidence captured
by the verifier could leak secrets to the artifact (which inherits repo
ACL but is still a publication).

Usage:
    verifier-redact-secrets.py FILE [FILE ...]
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

SECRET_PATTERNS = [
    re.compile(r"AKIA[0-9A-Z]{16}"),
    re.compile(r"AIza[0-9A-Za-z_\-]{35}"),
    re.compile(r"Bearer\s+[A-Za-z0-9._\-]{20,}", re.IGNORECASE),
    re.compile(r"(?i)(api[_-]?key|secret|token|credential|password|passwd)\s*[:=]\s*\S{8,}"),
    # High-entropy base64-like chunks >= 32 chars; allowlist full git SHAs.
    re.compile(r"\b[A-Za-z0-9+/=]{32,}\b"),
]
KNOWN_SAFE_RE = re.compile(r"^[0-9a-f]{40}$")  # full git SHAs


def redact(text: str) -> str:
    def _sub(m: re.Match) -> str:
        snippet = m.group(0)
        if KNOWN_SAFE_RE.match(snippet):
            return snippet
        return f"[REDACTED:{len(snippet)}ch]"
    out = text
    for pat in SECRET_PATTERNS:
        out = pat.sub(_sub, out)
    return out


def main(argv: list[str] | None = None) -> int:
    args = argv if argv is not None else sys.argv[1:]
    if not args:
        print("usage: verifier-redact-secrets.py FILE [FILE ...]", file=sys.stderr)
        return 2
    for raw in args:
        p = Path(raw)
        if not p.is_file():
            print(f"verifier-redact-secrets: not a file: {raw}", file=sys.stderr)
            return 2
        try:
            content = p.read_text()
        except UnicodeDecodeError:
            # Binary file — skip (evidence bundle may include tar/gz).
            continue
        scrubbed = redact(content)
        if scrubbed != content:
            p.write_text(scrubbed)
            print(f"verifier-redact-secrets: redacted {raw}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
