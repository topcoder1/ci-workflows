"""Guard: codex-review.yml must prove the Codex CLI runs before it reviews.

2026-09-23, attaxion_dev#374 (run 35811980905, attempt 1): the install step
ran `npm install -g @openai/codex@latest` 257 s after 0.156.1's linux-x64
binary was published. The native binary is a per-platform OPTIONAL
dependency (`@openai/codex-linux-x64` = `npm:@openai/codex@0.156.1-linux-x64`)
and the packument npm read did not list it yet; the registry serves
packuments with `cache-control: public, max-age=300`. npm skips an optional
dependency it cannot resolve without a word, so the step printed "added 1
package" and passed, the next step died on "Missing optional dependency
@openai/codex-linux-x64", and the review was lost.

The step's SHIPPED bash is extracted and executed against stubbed `npm`,
`codex` and `sleep` (the test_codex_model_pin.py pattern). The npm stub
models what the runner's npm 10.9.8 did against a local registry serving a
stale packument: the binary installs only once the registry lists it, and a
packument npm already cached is re-read only under `--prefer-online` - a
plain retry printed "changed 1 package" and codex still could not start.

Hardcoded contract: `codex --version`, not npm's exit code, decides success;
up to 3 retries after 60, 120 and 240 s (420 s outlasts the 300 s max-age
plus the 88 s the 0.156.1 binary trailed its wrapper); then the step fails
closed with an ::error::. Negative controls run the same checks against the
pre-fix one-liner and single-point mutations of the shipped step.
"""

import os
import pathlib
import subprocess
import tempfile

import pytest
import yaml

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "codex-review.yml"
_STEP_NAME = "Install Codex CLI"

ATTEMPTS = 4  # the first install plus 3 retries
DELAYS = ["60", "120", "240"]  # seconds before retries 1, 2 and 3
VERIFY = "codex --version"
# The step as it shipped before this guard, byte for byte.
PRE_FIX_STEP = "npm install -g @openai/codex@latest"

_NPM_STUB = r"""#!/bin/sh
# The registry lists the platform binary from npm call $STUB_LISTED_FROM on
# (0 = never). npm caches the packument on its first fetch (max-age=300
# outlives the whole step) and re-reads it only under --prefer-online. A
# network error (a call number in $STUB_NPM_FAIL_ON) fetches nothing.
n=$(( $(cat "$STUB_STATE/npm.count" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$STUB_STATE/npm.count"
echo "npm $*" >> "$STUB_STATE/calls.log"
case " $STUB_NPM_FAIL_ON " in
  *" $n "*) echo "npm error code ECONNRESET" >&2; exit 1 ;;
esac
listed=no
if [ "$STUB_LISTED_FROM" -ne 0 ] && [ "$n" -ge "$STUB_LISTED_FROM" ]; then
  listed=yes
fi
case " $* " in
  *" --prefer-online "*) echo "$listed" > "$STUB_STATE/packument" ;;
  *) [ -e "$STUB_STATE/packument" ] || echo "$listed" > "$STUB_STATE/packument" ;;
esac
if [ "$(cat "$STUB_STATE/packument")" = yes ]; then : > "$STUB_STATE/binary"; fi
echo "added 1 package in 2s"
"""

_CODEX_STUB = r"""#!/bin/sh
echo "codex $*" >> "$STUB_STATE/calls.log"
if [ -e "$STUB_STATE/binary" ]; then echo "codex-cli 0.0.0-fixture"; exit 0; fi
echo "Error: Missing optional dependency @openai/codex-linux-x64. Reinstall Codex: npm install -g @openai/codex@latest" >&2
exit 1
"""

_SLEEP_STUB = r"""#!/bin/sh
echo "sleep $*" >> "$STUB_STATE/calls.log"
"""


def _shipped_step() -> str:
    wf = yaml.safe_load(WORKFLOW.read_text())
    steps = wf["jobs"]["codex-review"]["steps"]
    runs = [s["run"] for s in steps if s.get("name") == _STEP_NAME]
    assert len(runs) == 1, (
        f"expected exactly one {_STEP_NAME!r} step, found {len(runs)}"
    )
    return runs[0]


def _run(script: str, listed_from: int, npm_fail_on: str = ""):
    """Run `script` as GitHub runs a `run:` block without `shell:` (bash -e).

    Returns (rc, output, calls) where calls lists every stub invocation."""
    with tempfile.TemporaryDirectory() as tmp:
        d = pathlib.Path(tmp)
        bindir = d / "bin"
        bindir.mkdir()
        for name, body in (
            ("npm", _NPM_STUB),
            ("codex", _CODEX_STUB),
            ("sleep", _SLEEP_STUB),
        ):
            stub = bindir / name
            stub.write_text(body)
            stub.chmod(0o755)
        step = d / "step.sh"
        step.write_text(script)
        env = {
            **os.environ,
            "PATH": f"{bindir}:{os.environ['PATH']}",
            "STUB_STATE": str(d),
            "STUB_LISTED_FROM": str(listed_from),
            "STUB_NPM_FAIL_ON": npm_fail_on,
        }
        proc = subprocess.run(
            ["bash", "-e", str(step)],
            env=env,
            capture_output=True,
            text=True,
            stdin=subprocess.DEVNULL,
            timeout=60,
        )
        log = d / "calls.log"
        calls = log.read_text().splitlines() if log.exists() else []
        return proc.returncode, proc.stdout + proc.stderr, calls


def _kinds(calls):
    """Collapse each call to what the contract cares about."""
    kinds = []
    for call in calls:
        if call.startswith("npm "):
            args = call.split()[1:]
            assert (
                "install" in args
                and "-g" in args
                and any(a.startswith("@openai/codex@") for a in args)
            ), f"not a global install of @openai/codex: {call!r}"
            kinds.append("install")
        elif call == VERIFY:
            kinds.append("verify")
        else:
            kinds.append(call)
    return kinds


def _expected(attempts: int):
    seq = []
    for i in range(1, attempts + 1):
        seq += ["install", "verify"]
        if i < attempts:
            seq.append(f"sleep {DELAYS[i - 1]}")
    return seq


def _check(script: str) -> None:
    # The binary never lands: every attempt is verified, the retries follow
    # the pinned cadence, and the step then fails closed.
    rc, out, calls = _run(script, listed_from=0)
    assert _kinds(calls) == _expected(ATTEMPTS), (
        f"a binary that never lands must get {ATTEMPTS} verified attempts "
        f"with {DELAYS} s between them; got {calls}"
    )
    assert rc != 0 and "::error::" in out, (
        f"the step must fail closed with an ::error:: (rc={rc}):\n{out}"
    )

    # The registry catches up after 0..3 retries: the step recovers and
    # stops at the first attempt whose binary runs. From attempt 2 on this
    # needs the retry to bypass npm's cached packument.
    for lands in range(1, ATTEMPTS + 1):
        rc, out, calls = _run(script, listed_from=lands)
        assert rc == 0, (
            f"binary listed from attempt {lands}: the step must recover "
            f"(rc={rc}):\n{out}"
        )
        assert _kinds(calls) == _expected(lands), (
            f"binary listed from attempt {lands}: expected "
            f"{_expected(lands)}, got {calls}"
        )
        assert "::error::" not in out, out
        if lands == 1:
            assert "::warning::" not in out, f"a healthy install must not warn:\n{out}"

    # npm itself fails once (a network blip): that is retried too.
    rc, out, calls = _run(script, listed_from=1, npm_fail_on="1")
    kinds = _kinds(calls)
    assert rc == 0 and kinds[-1] == "verify", (
        f"an npm error must be retried until codex runs (rc={rc}): {calls}\n{out}"
    )
    assert [k for k in kinds if k != "verify"] == [
        "install",
        f"sleep {DELAYS[0]}",
        "install",
    ], calls


def test_install_step_verifies_the_binary_and_retries():
    _check(_shipped_step())


def _pre_fix(_: str) -> str:
    return PRE_FIX_STEP


def _drop_verify(t: str) -> str:
    return t.replace(f" && {VERIFY}", "")


def _drop_retry(t: str) -> str:
    return t.replace("for attempt in 1 2 3 4; do", "for attempt in 1; do")


def _drop_cache_bypass(t: str) -> str:
    return t.replace(" --prefer-online", "")


def _shorten_backoff(t: str) -> str:
    return t.replace("delay=60\n", "delay=30\n")


def _fail_open(t: str) -> str:
    head, sep, tail = t.rpartition("exit 1")
    return head + "exit 0" + tail if sep else t


@pytest.mark.parametrize(
    "mutate",
    [
        _pre_fix,
        _drop_verify,
        _drop_retry,
        _drop_cache_bypass,
        _shorten_backoff,
        _fail_open,
    ],
    ids=[
        "pre-fix-one-liner",
        "verify-dropped",
        "retry-dropped",
        "cache-bypass-dropped",
        "backoff-shortened",
        "fails-open",
    ],
)
def test_guard_catches_each_regression(mutate):
    """Negative controls: a guard that reads the artifact it checks must be
    shown to fail when that artifact narrows."""
    script = _shipped_step()
    mutated = mutate(script)
    assert mutated != script, "mutation did not apply; the anchor drifted"
    with pytest.raises(AssertionError):
        _check(mutated)
