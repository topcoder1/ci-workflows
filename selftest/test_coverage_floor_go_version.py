"""Guard: coverage-floor.yml installs the Go release go.mod pins, not its floor.

go.mod carries two versions. The `go` directive is the oldest Go the module
accepts; a `toolchain` directive names the release it builds with
(https://go.dev/ref/mod#go-mod-file-toolchain). The detect step read only the
`go` line and handed it to actions/setup-go as an exact version, and setup-go
then exports GOTOOLCHAIN=local, which makes `go` use what was installed and
skip the toolchain line. So a repo that pinned a patched toolchain had its
coverage measured on the unpatched floor, green and with no warning:
whois-api-llc/techrecon#1213's required coverage-floor job (120625436528,
2026-10-23) logged `Setup go version spec 1.26.1` and `go version go1.26.1`
while its go.mod said `go 1.26.1` / `toolchain go1.26.10`, the pin taken for
the crypto/x509 advisory GO-2026-6809.

The detect step now prefers a `toolchain goV` line, falls back to the `go`
line, and fails on a toolchain line it cannot read instead of measuring the
floor again. A caller's `go_version` input still wins over both.

The shipped step runs here against hand-written go.mod files. Every expected
version is a literal, never read back from the workflow under test.
"""

import os
import pathlib
import subprocess
import tempfile

import pytest
import yaml

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "coverage-floor.yml"

MODULE = "module example.com/m\n\n"


def _steps():
    return yaml.safe_load(WORKFLOW.read_text())["jobs"]["measure"]["steps"]


def _detect(gomod, *, go_version=""):
    """Run the shipped `detect` step as GitHub runs a bare `run:` step, for a
    caller passing `language: go` and `working_directory: work`, with
    work/go.mod holding `gomod` (None: no go.mod at all).

    Returns (returncode, the go_version output or None, the step's log).
    """
    step = next(s for s in _steps() if s.get("id") == "detect")
    with tempfile.TemporaryDirectory() as tmp:
        work = pathlib.Path(tmp) / "work"
        work.mkdir()
        if gomod is not None:
            # Bytes, so a CRLF fixture reaches the step as CRLF.
            (work / "go.mod").write_bytes(gomod.encode())
        out_file = pathlib.Path(tmp) / "github_output"
        out_file.write_text("")
        script = pathlib.Path(tmp) / "detect.sh"
        script.write_text(step["run"])
        env = {
            **os.environ,
            "GITHUB_OUTPUT": str(out_file),
            "INPUT_LANGUAGE": "go",
            "INPUT_WORKDIR": "work",
            "INPUT_GO_VERSION": go_version,
        }
        proc = subprocess.run(
            ["bash", "--noprofile", "--norc", "-eo", "pipefail", str(script)],
            cwd=tmp,
            env=env,
            capture_output=True,
            text=True,
            stdin=subprocess.DEVNULL,
            timeout=30,
        )
        resolved = next(
            (
                line.split("=", 1)[1]
                for line in out_file.read_text().splitlines()
                if line.startswith("go_version=")
            ),
            None,
        )
        return proc.returncode, resolved, proc.stdout + proc.stderr


@pytest.mark.parametrize(
    "gomod, go_version, expected",
    [
        pytest.param(MODULE + "go 1.26.1\n", "", "1.26.1", id="go-line-only"),
        # techrecon's go.mod at #1213, the shape that ran on go1.26.1.
        pytest.param(
            MODULE + "go 1.26.1\n\ntoolchain go1.26.10\n",
            "",
            "1.26.10",
            id="toolchain-pin",
        ),
        pytest.param(
            MODULE + "toolchain go1.26.10\n\ngo 1.26.1\n",
            "",
            "1.26.10",
            id="toolchain-above-go-line",
        ),
        pytest.param(
            MODULE + "go 1.26.1\n\ntoolchain go1.26.10 // GO-2026-6809\n",
            "",
            "1.26.10",
            id="toolchain-with-comment",
        ),
        pytest.param(
            "module example.com/m\r\n\r\ngo 1.26.1\r\n\r\ntoolchain go1.26.10\r\n",
            "",
            "1.26.10",
            id="crlf-line-endings",
        ),
        # `default` asks for no particular toolchain: the go line decides.
        pytest.param(
            MODULE + "go 1.26.1\n\ntoolchain default\n",
            "",
            "1.26.1",
            id="toolchain-default",
        ),
        pytest.param(
            MODULE + "go 1.26.1\n\ntoolchain go1.27rc2\n",
            "",
            "1.27rc2",
            id="release-candidate",
        ),
        # A custom build's `-suffix` names the release it was built from.
        pytest.param(
            MODULE + "go 1.26.1\n\ntoolchain go1.26.10-bigcorp\n",
            "",
            "1.26.10",
            id="custom-toolchain-suffix",
        ),
        pytest.param(
            MODULE + "go 1.26.1\n\ntoolchain go1.26.10\n",
            "1.25.3",
            "1.25.3",
            id="caller-go-version-wins",
        ),
        # The caller's input is used as given, so go.mod is never read.
        pytest.param(
            MODULE + "go 1.26.1\n\ntoolchain banana\n",
            "1.26.10",
            "1.26.10",
            id="caller-go-version-skips-go-mod",
        ),
        pytest.param(None, "", "1.23", id="no-go-mod"),
    ],
)
def test_detect_resolves_the_go_release_to_install(gomod, go_version, expected):
    rc, resolved, log = _detect(gomod, go_version=go_version)
    assert rc == 0, log
    assert resolved == expected, log


@pytest.mark.parametrize(
    "toolchain",
    [
        "1.26.10",  # no `go` prefix
        "go1.26.10x",  # `go` accepts this spelling and, under GOTOOLCHAIN=local, ignores it
        "banana",
    ],
)
def test_an_unreadable_toolchain_line_fails_the_job(toolchain):
    """Measuring the floor again would repeat the silent failure, so the job
    stops and names the line instead."""
    rc, resolved, log = _detect(MODULE + f"go 1.26.1\n\ntoolchain {toolchain}\n")
    assert rc != 0, log
    assert resolved is None, log
    # Quoted, because the message's own example (go1.26.10) contains 1.26.10.
    assert "::error::" in log and f"'{toolchain}'" in log, log


def test_only_a_toolchain_directive_moves_the_version():
    """Negative control: lines that only look like a pin are not one."""
    lookalikes = (
        MODULE
        + "go 1.26.1\n\n"
        + "// toolchain go1.99.0\n"
        + "toolchian go1.99.0\n"
        + "require example.com/toolchain v1.99.0\n"
    )
    rc, resolved, log = _detect(lookalikes)
    assert (rc, resolved) == (0, "1.26.1"), log
    # Positive control through the same harness: the real directive is read.
    rc, resolved, log = _detect(lookalikes + "toolchain go1.26.10\n")
    assert (rc, resolved) == (0, "1.26.10"), log


def test_setup_go_installs_what_detect_resolved():
    """The resolver is half the fix: setup-go has to install its output."""
    setup_go = [
        s for s in _steps() if str(s.get("uses", "")).startswith("actions/setup-go@")
    ]
    assert len(setup_go) == 1
    assert setup_go[0].get("with") == {
        "go-version": "${{ steps.detect.outputs.go_version }}"
    }
