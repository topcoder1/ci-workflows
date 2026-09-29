"""Gate scripts fetched at run time live outside the caller's checkout.

pr-classify.yml and codex-review.yml fetch their scripts from this repository
and run them with node: classify.mjs and codex-gate.mjs, each importing
classifier-deps.mjs from beside itself. The caller's checkout is the PR's
tree, where the PR decides what every path holds, so the scripts go to a
directory each job makes for itself under RUNNER_TEMP.

For each workflow, the shipped fetch step and the step that runs the script,
in a fixture checkout with a stub `gh` that serves this repository's scripts:
1. A PR that commits entries at the scripts' own paths: only this
   repository's scripts run, and the verdict is theirs.
2. Control: without those entries, the same verdict.
"""

import os
import subprocess
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
SCRIPTS = ROOT / ".github" / "scripts"

STUB_GH = """#!/usr/bin/env bash
# Serves this repository's scripts for the contents API and a fixed file list
# for the pulls API; anything else is a call the test does not model.
args="$*"
case "$args" in
  *"/contents/.github/scripts/"*)
    name="${args##*/contents/.github/scripts/}"
    base64 < "$SCRIPTS_SOURCE/${name%% *}" | tr -d '\\n' ;;
  *previous_filename*) ;;
  *"/pulls/"*"/files"*) printf '%s\\n' "$STUB_CHANGED" ;;
  *) echo "gh stub: unexpected call: $*" >&2; exit 64 ;;
esac
"""

# Runs, when imported, only if node loads it instead of this repository's
# classifier-deps.mjs.
OTHER_MODULE = """import { writeFileSync } from "node:fs";
writeFileSync(process.env.OTHER_MODULE_RAN, "ran\\n");
"""

LANES = {
    "pr-classify": {
        "workflow": "pr-classify.yml",
        "fetch": "Fetch classifier script and vendored deps from this reusable's repo",
        "run": "Compute highest-priority class",
        "script": "classify.mjs",
        "risk_paths": "blocked:\n  - 'src/auth/**'\n",
        "verdict": "class=blocked",
    },
    "codex-review": {
        "workflow": "codex-review.yml",
        "fetch": "Fetch gate scripts",
        "run": "Codex cost gate",
        "script": "codex-gate.mjs",
        "risk_paths": "always_review:\n  - 'src/auth/**'\n",
        "verdict": "should_run=true",
    },
}


def find_step(document, name):
    steps = [
        step
        for job in document["jobs"].values()
        for step in job.get("steps") or []
        if step.get("name") == name
    ]
    assert len(steps) == 1, f"expected one step named {name!r}"
    return steps[0]


def run_lane(tmp_path, lane, entries):
    """Run the lane's fetch step, then the step that runs its script, in a
    fixture checkout holding `entries`; return what the second step wrote to
    $GITHUB_OUTPUT and whether a module other than the fetched one ran."""
    spec = LANES[lane]
    document = yaml.safe_load((WORKFLOWS / spec["workflow"]).read_text())
    repo = tmp_path / "checkout"
    (repo / ".github").mkdir(parents=True)
    (repo / ".github" / "risk-paths.yml").write_text(spec["risk_paths"])
    for path, make in entries.items():
        (repo / path).parent.mkdir(parents=True, exist_ok=True)
        make(repo / path)
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    (bin_dir / "gh").write_text(STUB_GH)
    (bin_dir / "gh").chmod(0o755)
    runner_temp = tmp_path / "runner-temp"
    runner_temp.mkdir()
    (runner_temp / "codex-gate-paths.txt").write_text("src/auth/session.py\n")
    github_env = tmp_path / "github-env"
    github_env.write_text("")
    marker = tmp_path / "other-module-ran"
    environment = {
        **{k: v for k, v in os.environ.items() if not k.startswith("GIT_")},
        "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
        "SCRIPTS_SOURCE": str(SCRIPTS),
        "STUB_CHANGED": "src/auth/session.py",
        "OTHER_MODULE_RAN": str(marker),
        "RUNNER_TEMP": str(runner_temp),
        "GITHUB_ENV": str(github_env),
        "GITHUB_REPOSITORY": "acme/fixture",
        "GITHUB_STEP_SUMMARY": str(tmp_path / "summary"),
        "GH_TOKEN": "stub",
        "PR": "7",
        "CHANGED_FILES_FILE": str(runner_temp / "codex-gate-paths.txt"),
        "DIFF_LINES": "100",
        "SIZE_THRESHOLD": "30",
    }
    output = tmp_path / "github-output"
    for name in (spec["fetch"], spec["run"]):
        script = find_step(document, name)["run"]
        assert "${{" not in script, "an expression the fixture does not substitute"
        exported = dict(
            line.split("=", 1) for line in github_env.read_text().splitlines()
        )
        output.unlink(missing_ok=True)
        result = subprocess.run(
            ["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", script],
            cwd=repo,
            env={**environment, **exported, "GITHUB_OUTPUT": str(output)},
            capture_output=True,
            text=True,
            stdin=subprocess.DEVNULL,
        )
        if result.returncode != 0:
            return None, marker.exists(), result.stdout + result.stderr
    return output.read_text(), marker.exists(), ""


def entries_at_the_script_paths(lane):
    """The PR commits the script's own path as a link into a directory of its
    own, which also holds a classifier-deps.mjs."""
    script = LANES[lane]["script"]
    return {
        f".github/scripts/{script}": lambda path: path.symlink_to(
            f"../../elsewhere/{script}"
        ),
        "elsewhere/classifier-deps.mjs": lambda path: path.write_text(OTHER_MODULE),
    }


@pytest.mark.parametrize("lane", sorted(LANES))
def test_only_the_fetched_scripts_run(tmp_path, lane):
    output, other_ran, log = run_lane(tmp_path, lane, entries_at_the_script_paths(lane))
    assert not other_ran, "a module from the PR's tree ran"
    assert output is not None, log
    assert LANES[lane]["verdict"] in output.splitlines(), output


@pytest.mark.parametrize("lane", sorted(LANES))
def test_without_those_entries_the_verdict_is_the_same(tmp_path, lane):
    # Control: the fixture's change reaches the verdict the test expects.
    output, other_ran, log = run_lane(tmp_path, lane, {})
    assert not other_ran
    assert output is not None, log
    assert LANES[lane]["verdict"] in output.splitlines(), output
