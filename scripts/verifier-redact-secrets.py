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
    # AWS access key ID
    re.compile(r"AKIA[0-9A-Z]{16}"),
    # GCP API key
    re.compile(r"AIza[0-9A-Za-z_\-]{35}"),
    # GitHub personal access tokens (classic + fine-grained) + OAuth tokens
    re.compile(r"\bghp_[A-Za-z0-9]{36,}"),
    re.compile(r"\bgho_[A-Za-z0-9]{36,}"),
    re.compile(r"\bghu_[A-Za-z0-9]{36,}"),
    re.compile(r"\bghs_[A-Za-z0-9]{36,}"),
    re.compile(r"\bghr_[A-Za-z0-9]{36,}"),
    re.compile(r"\bgithub_pat_[A-Za-z0-9_]{60,}"),
    # OpenAI / Anthropic API keys
    re.compile(r"\bsk-ant-[A-Za-z0-9_\-]{32,}"),
    re.compile(r"\bsk-proj-[A-Za-z0-9_\-]{32,}"),
    re.compile(r"\bsk-[A-Za-z0-9_\-]{32,}"),
    # Slack / Discord / Stripe
    re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{10,}"),
    re.compile(r"\b(rk|sk|pk)_(live|test)_[A-Za-z0-9]{20,}"),
    # Bearer tokens
    re.compile(r"Bearer\s+[A-Za-z0-9._\-]{20,}", re.IGNORECASE),
    # key=value / key:value form (catches arbitrary providers when labeled)
    re.compile(r"(?i)(api[_-]?key|secret|token|credential|password|passwd)\s*[:=]\s*\S{8,}"),
    # High-entropy base64-like chunks >= 40 chars (raised from 32 per codex
    # round 3 — 32-char hex collides with UUIDs-without-hyphens, 32-char
    # alnum collides with cache/build IDs). The allowlist below covers
    # common-shape legitimate evidence values (git SHAs, sha256 digests,
    # UUIDs). Catch-all kept for genuinely high-entropy unknown blobs.
    re.compile(r"\b[A-Za-z0-9+/=_\-]{40,}\b"),
]
# Known-safe tokens that look high-entropy but are legitimate evidence.
# Ordered most-specific-first; checked before any redaction.
KNOWN_SAFE_PATTERNS = [
    re.compile(r"^[0-9a-f]{40}$"),                                # full git SHA
    re.compile(r"^[0-9a-f]{64}$"),                                # sha256 hex
    re.compile(r"^[0-9a-f]{56}$"),                                # sha224 hex
    re.compile(r"^[0-9a-f]{96}$"),                                # sha384 hex
    re.compile(r"^[0-9a-f]{128}$"),                               # sha512 hex
    re.compile(r"^[0-9a-fA-F]{32}$"),                             # md5 hex / UUID-no-hyphens
    re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"),  # UUID
]


def _is_known_safe(snippet: str) -> bool:
    return any(p.match(snippet) for p in KNOWN_SAFE_PATTERNS)


def redact(text: str) -> str:
    def _sub(m: re.Match) -> str:
        snippet = m.group(0)
        if _is_known_safe(snippet):
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
