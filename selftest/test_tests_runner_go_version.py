"""Guard: tests-runner.yml's Go job installs the Go release go.mod pins.

go.mod carries two versions. The `go` directive is the oldest Go the module
accepts; a `toolchain` directive names the release it builds with
(https://go.dev/ref/mod#go-mod-file-toolchain). The `detect` job read only the
`go` line and handed it to actions/setup-go as an exact version, and setup-go
then exports GOTOOLCHAIN=local, which makes `go` use what was installed and
skip the toolchain line. A repo that pinned a patched toolchain would have run
its tests on the unpatched floor, green and with no warning. coverage-floor.yml
had the same code and did exactly that to whois-api-llc/techrecon (go 1.26.1 /
toolchain go1.26.10, the pin for GO-2026-6809) on 2026-10-23. No repo called
this reusable with Go then, so here nothing had gone wrong yet.

The release is now resolved in the Go job itself, by a step just before
setup-go. In `detect`, a failure would skip run-go, and a skipped required
check passes. The rules: install the newer of the toolchain pin and the `go`
line, compared in Go's order (1.27rc2 < 1.27.0); read both without a `//`
comment or a CR; hand a release candidate to setup-go as SemVer's 1.27.0-rc.2,
the only spelling it matches; fail on a toolchain line naming no Go release
instead of testing on the floor again. A caller's `go_version` input wins.

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
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "tests-runner.yml"

MODULE = "module example.com/m\n\n"


def _go_steps():
    return yaml.safe_load(WORKFLOW.read_text())["jobs"]["run-go"]["steps"]


def _resolve_index(steps):
    hits = [i for i, s in enumerate(steps) if s.get("id") == "go"]
    assert len(hits) == 1, "run-go needs exactly one step with id `go`"
    return hits[0]


def _resolve(gomod, *, go_version=""):
    """Run the shipped resolver step as GitHub runs a bare `run:` step, in its
    working directory, with go.mod holding `gomod` (None: no go.mod at all).

    Returns (returncode, the go_version output or None, the step's log).
    """
    steps = _go_steps()
    step = steps[_resolve_index(steps)]
    with tempfile.TemporaryDirectory() as tmp:
        work = pathlib.Path(tmp) / "work"
        work.mkdir()
        if gomod is not None:
            # Bytes, so a CRLF fixture reaches the step as CRLF.
            (work / "go.mod").write_bytes(gomod.encode())
        out_file = pathlib.Path(tmp) / "github_output"
        out_file.write_text("")
        script = pathlib.Path(tmp) / "resolve.sh"
        script.write_text(step["run"])
        env = {
            **os.environ,
            "GITHUB_OUTPUT": str(out_file),
            "INPUT_GO_VERSION": go_version,
        }
        proc = subprocess.run(
            ["bash", "--noprofile", "--norc", "-eo", "pipefail", str(script)],
            cwd=work,
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
        # techrecon's go.mod at #1213.
        pytest.param(
            MODULE + "go 1.26.1\n\ntoolchain go1.26.10\n",
            "",
            "1.26.10",
            id="toolchain-pin",
        ),
        # Versions compare as numbers: a text sort puts 1.26.10 below 1.26.9.
        pytest.param(
            MODULE + "go 1.26.9\n\ntoolchain go1.26.10\n",
            "",
            "1.26.10",
            id="pin-patch-crosses-a-digit",
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
        # Go ends the token at `//` without a space before it.
        pytest.param(
            MODULE + "go 1.26.1\n\ntoolchain go1.26.10//GO-2026-6809\n",
            "",
            "1.26.10",
            id="toolchain-with-unspaced-comment",
        ),
        # A pin below the go line is stale: go1.26.0 could not build a
        # `go 1.26.1` module under GOTOOLCHAIN=local.
        pytest.param(
            MODULE + "go 1.26.1\n\ntoolchain go1.26.0\n",
            "",
            "1.26.1",
            id="stale-pin-below-go-line",
        ),
        pytest.param(
            MODULE + "go 1.26.1\n\ntoolchain go1.25.5\n",
            "",
            "1.26.1",
            id="stale-pin-older-minor",
        ),
        # setup-go matches 1.27.0-rc.2, never Go's 1.27rc2.
        pytest.param(
            MODULE + "go 1.26.1\n\ntoolchain go1.27rc2\n",
            "",
            "1.27.0-rc.2",
            id="release-candidate-pin",
        ),
        # Compared in Go's order, an rc sits below its release.
        pytest.param(
            MODULE + "go 1.27.0\n\ntoolchain go1.27rc2\n",
            "",
            "1.27.0",
            id="stale-rc-pin-below-release",
        ),
        pytest.param(
            MODULE + "go 1.27rc1\n",
            "",
            "1.27.0-rc.1",
            id="release-candidate-go-line",
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
def test_the_go_job_resolves_the_release_to_install(gomod, go_version, expected):
    rc, resolved, log = _resolve(gomod, go_version=go_version)
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
def test_an_unreadable_toolchain_line_fails_the_go_job(toolchain):
    """Testing on the floor again would repeat the silent failure, so the job
    stops and names the line instead."""
    rc, resolved, log = _resolve(MODULE + f"go 1.26.1\n\ntoolchain {toolchain}\n")
    assert rc != 0, log
    assert resolved is None, log
    # Quoted, because the message's own example (go1.N.P) could change.
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
    rc, resolved, log = _resolve(lookalikes)
    assert (rc, resolved) == (0, "1.26.1"), log
    # Positive control through the same harness: the real directive is read.
    rc, resolved, log = _resolve(lookalikes + "toolchain go1.26.10\n")
    assert (rc, resolved) == (0, "1.26.10"), log


def test_the_go_job_installs_what_it_resolved():
    """Resolved after checkout and before setup-go, inside run-go: a failure
    in `detect` would skip this job, and a skipped required check passes. The
    step sees the caller's inputs the harness above feeds it."""
    steps = _go_steps()
    uses = [str(s.get("uses", "")) for s in steps]
    checkout = [i for i, u in enumerate(uses) if u.startswith("actions/checkout@")]
    setup_go = [i for i, u in enumerate(uses) if u.startswith("actions/setup-go@")]
    assert len(checkout) == 1 and len(setup_go) == 1
    resolve = _resolve_index(steps)
    assert checkout[0] < resolve < setup_go[0]
    assert steps[setup_go[0]].get("with") == {
        "go-version": "${{ steps.go.outputs.go_version }}"
    }
    step = steps[resolve]
    assert step.get("working-directory") == "${{ inputs.working_directory || '.' }}"
    assert (
        step.get("env", {}).get("INPUT_GO_VERSION") == "${{ inputs.go_version || '' }}"
    )
