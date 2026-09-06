"""Guard: codex-review.yml must pin AND enforce the Codex model.

2026-09-04: `npm install -g @openai/codex@latest` floated the CLI to 0.153.4,
whose bundled default flipped from gpt-5.6-sol to gpt-6-astra. Nobody chose
it. Across the next 88 fleet reviews Astra at reasoning=low reported zero
regressions against a 16% baseline on Sol (750 reviews), at 2.5x the token
price. claude-review.yml learned the same lesson in August (its CLI pin is
"the rollback lever"); this is the Codex lane's equivalent.

Two layers:

1. Text guards (`_check`): one pinned id at the job level (CODEX_MODEL) equal
   to the hardcoded PINNED_MODEL; the invocation passes
   `-c model="$CODEX_MODEL"`; the banner grep stays line-anchored; the run
   step refuses (exit 1) a DIFFERENT reported model. Four negative controls
   prove the guard fails when the artifact narrows.
2. Behavioral fixtures: the step's SHIPPED provenance+refusal bash is
   extracted from the workflow and executed against synthetic codex.out
   files, following test_comment_nonfatal_reporting.sh sec. 4b. This is what
   pins the fail-safe asymmetry: a wrong model reds the run, but a missing,
   re-cased, CRLF, or out-of-region banner must never red the 27 consumers.
"""

import os
import pathlib
import re
import subprocess
import tempfile

import pytest
import yaml

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "codex-review.yml"

# Change by decision only: cite the measured hit rate in the PR that bumps it.
PINNED_MODEL = "gpt-5.6-sol"

_ANCHORED_GREP = "grep -ioE '^model:[[:space:]]*"
_REFUSAL = re.compile(
    r'elif \[ "\$model_raw" != "\$pin" \]; then\n(?P<body>(?:.*\n)*?)\s+fi\n'
)
_PROVENANCE_MARKER = "codex_version=$(codex --version"
_STEP_NAME = "Run Codex adversarial review"
UNREPORTED = "(unreported — see logs)"


def _check(text: str) -> None:
    env = re.search(r"^\s{6}CODEX_MODEL:\s*(\S+)\s*$", text, flags=re.M)
    assert env, "codex-review.yml must declare CODEX_MODEL under jobs.codex-review.env"
    assert env.group(1) == PINNED_MODEL, (
        f"CODEX_MODEL is {env.group(1)!r}; expected {PINNED_MODEL!r}. Changing "
        "the review model is a decision: bump PINNED_MODEL here in the same PR "
        "and cite the measured hit rate."
    )

    inv = re.search(
        r"^\s+codex \\\n(?P<flags>(?:\s+-[^\n]*\\\n)+)\s+review \"\$PROMPT\"",
        text,
        flags=re.M,
    )
    assert inv, 'could not find the `codex ... review "$PROMPT"` invocation'
    assert '-c model="$CODEX_MODEL" \\' in inv.group("flags"), (
        'the codex invocation must pass -c model="$CODEX_MODEL"; without it the '
        "pin is documentation and @openai/codex@latest's bundled default runs"
    )

    assert _ANCHORED_GREP in text, (
        "the banner grep must stay anchored to line start (^model:); unanchored, "
        "a `model:` fragment in the review text becomes the reported model and "
        "the refusal below fires on it"
    )
    assert 'if [ -z "$model_raw" ]; then' in text, (
        "the fail-safe branch must test emptiness, not the display sentinel"
    )
    refusal = _REFUSAL.search(text)
    assert refusal, "the review step must compare the reported model to the pin"
    assert re.search(r"^\s+exit 1\s*$", refusal.group("body"), flags=re.M), (
        "a different reported model must fail the run (exit 1), not just warn"
    )


def test_codex_review_pins_and_enforces_the_model():
    _check(WORKFLOW.read_text())


def _typo_pin(t: str) -> str:
    return t.replace(
        f"CODEX_MODEL: {PINNED_MODEL}\n", f"CODEX_MODEL: {PINNED_MODEL}x\n"
    )


def _drop_flag(t: str) -> str:
    return t.replace('            -c model="$CODEX_MODEL" \\\n', "")


def _drop_anchor(t: str) -> str:
    return t.replace(_ANCHORED_GREP, "grep -ioE 'model:[[:space:]]*")


def _defang_refusal(t: str) -> str:
    return _REFUSAL.sub(lambda m: m.group(0).replace("exit 1", "true", 1), t, count=1)


@pytest.mark.parametrize(
    "mutate",
    [_typo_pin, _drop_flag, _drop_anchor, _defang_refusal],
    ids=["typo-in-pinned-id", "flag-dropped", "anchor-dropped", "refusal-defanged"],
)
def test_guard_catches_each_regression(mutate):
    """Negative controls: a guard that reads the artifact it checks must be
    shown to fail when that artifact narrows."""
    text = WORKFLOW.read_text()
    mutated = mutate(text)
    assert mutated != text, "mutation did not apply; the anchor drifted"
    with pytest.raises(AssertionError):
        _check(mutated)


# --- behavioral: execute the shipped provenance + refusal bash ---------------


def _shipped_provenance_block() -> str:
    wf = yaml.safe_load(WORKFLOW.read_text())
    steps = wf["jobs"]["codex-review"]["steps"]
    run = next(s["run"] for s in steps if s.get("name") == _STEP_NAME)
    assert run.startswith("set -euo pipefail"), "the review step runs under strict mode"
    assert _PROVENANCE_MARKER in run, "provenance block moved; update the marker"
    # From the provenance capture to the end of the step: the refusal is the
    # last thing the step does, so nothing after it is lost.
    return "set -euo pipefail\n" + run[run.index(_PROVENANCE_MARKER) :]


def _run_shipped(codex_out: str, codex_model: str = PINNED_MODEL):
    """Run the shipped block against a synthetic /tmp/codex.out.

    Returns (rc, log, reported_model, step_summary)."""
    with tempfile.TemporaryDirectory() as tmp:
        d = pathlib.Path(tmp)
        (d / "codex.out").write_text(codex_out)
        summary = d / "summary.md"
        summary.write_text("")
        bindir = d / "bin"
        bindir.mkdir()
        stub = bindir / "codex"
        stub.write_text("#!/bin/sh\necho 'codex-cli 0.0.0-fixture'\n")
        stub.chmod(0o755)
        # Same rewrite test_comment_nonfatal_reporting.sh applies: the shipped
        # step hardcodes /tmp/..., private on an ephemeral runner.
        script = _shipped_provenance_block().replace("/tmp/", f"{d}/")
        env = {
            **os.environ,
            "PATH": f"{bindir}:{os.environ['PATH']}",
            "CODEX_MODEL": codex_model,
            "GITHUB_STEP_SUMMARY": str(summary),
        }
        proc = subprocess.run(
            ["bash", "-c", script], env=env, capture_output=True, text=True
        )
        reported = (
            (d / "codex.model").read_text() if (d / "codex.model").exists() else None
        )
        return proc.returncode, proc.stdout + proc.stderr, reported, summary.read_text()


_BANNER_TAIL = "provider: openai\nreasoning effort: low\n\ncodex\nVERDICT: CLEAN\n"


def test_pinned_banner_passes_cleanly():
    rc, log, reported, _ = _run_shipped(f"model: {PINNED_MODEL}\n{_BANNER_TAIL}")
    assert rc == 0, log
    assert reported == PINNED_MODEL
    assert "::error::" not in log and "::warning::" not in log, log


def test_different_model_is_refused_after_provenance_is_recorded():
    rc, log, reported, summary = _run_shipped(f"model: gpt-6-astra\n{_BANNER_TAIL}")
    assert rc == 1, log
    assert "::error::" in log and "gpt-6-astra" in log and PINNED_MODEL in log, log
    # Provenance lands before the refusal so the run is diagnosable.
    assert reported == "gpt-6-astra"
    assert "gpt-6-astra" in summary


@pytest.mark.parametrize(
    "codex_out",
    [
        pytest.param(
            f"Model: {PINNED_MODEL.upper()}\n{_BANNER_TAIL}", id="recased-banner"
        ),
        pytest.param(f"model: {PINNED_MODEL}\r\n{_BANNER_TAIL}", id="crlf-banner"),
    ],
)
def test_banner_variants_still_match_the_pin(codex_out):
    rc, log, reported, _ = _run_shipped(codex_out)
    assert rc == 0, log
    assert reported == PINNED_MODEL
    assert "::warning::" not in log, log


def test_pin_itself_is_case_folded():
    rc, log, _, _ = _run_shipped(
        f"model: {PINNED_MODEL}\n{_BANNER_TAIL}", codex_model=PINNED_MODEL.upper()
    )
    assert rc == 0, log
    assert "::error::" not in log, log


@pytest.mark.parametrize(
    "codex_out",
    [
        pytest.param(
            "  pricing_model: str = 'legacy'\n" + _BANNER_TAIL,
            id="indented-fragment-only",
        ),
        pytest.param(
            "\n" * 34 + "model: gpt-4o-mini\n" + _BANNER_TAIL,
            id="column0-decoy-past-banner-region",
        ),
        pytest.param(_BANNER_TAIL, id="no-banner-at-all"),
    ],
)
def test_unmatched_banner_warns_but_never_refuses(codex_out):
    """The fail-safe direction: a format change or review-text fragment must
    not red the 27 consuming repos; it is a warning and a sentinel."""
    rc, log, reported, _ = _run_shipped(codex_out)
    assert rc == 0, log
    assert "::warning::" in log and "::error::" not in log, log
    assert reported == UNREPORTED
