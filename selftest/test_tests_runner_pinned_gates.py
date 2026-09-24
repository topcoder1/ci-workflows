"""Guard: tests-runner.yml's opt-in pinned-gate step stays opt-in, pinned, and first.

Repos whose tests run through this reusable have no job of their own to host
the pinned-gate-tests action (.github/actions/pinned-gate-tests), so the
reusable offers it: set `pinned_gate_files` / `pinned_gate_expected` (and
`pinned_gate_imports` for bare-name helpers) and the Tests (Python) job runs
the caller's merge gates a second time, isolated from its pytest config,
conftests and look-alike modules, before anything else in the job.

What makes that safe is all wiring, so this module pins the wiring:

- the step is skipped unless `pinned_gate_files` is set, so the ~45 callers
  that never set it are untouched;
- it uses the action at a full commit SHA, never a branch or tag;
- its inputs map one-for-one onto the action's;
- it sits after setup-python (the action builds its venv from `python`) and
  before `Install uv`, the git-deps credential and `uv sync` — the first point
  where PR code runs or a credential exists. Moved later, the gates would run
  after PR code had a chance to tamper with the job.

The checks run as one function over a parsed workflow so the negative controls
below can feed it mutants: each shape here is one an edit could plausibly
produce, and the checker must reject every one. Expectations are hardcoded,
never read back from the workflow under test.
"""

import copy
import os
import pathlib
import re
import subprocess
import tempfile

import pytest
import yaml

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "tests-runner.yml"

GATE_STEP_NAME = "Merge gates, isolated from pytest config"
ACTION_REF = re.compile(
    r"^topcoder1/ci-workflows/\.github/actions/pinned-gate-tests@[0-9a-f]{40}$"
)
OPT_IN_IF = "${{ format('{0}', inputs.pinned_gate_files) != '' }}"
EXPECTED_WITH = {
    "files": "${{ inputs.pinned_gate_files }}",
    "expected": "${{ inputs.pinned_gate_expected }}",
    "imports": "${{ inputs.pinned_gate_imports }}",
    "extra-packages": "${{ inputs.pinned_gate_extra_packages }}",
}
EXPECTED_INPUT_DEFAULTS = {
    "pinned_gate_files": "",
    "pinned_gate_expected": "",
    "pinned_gate_imports": "",
    "pinned_gate_extra_packages": "pyyaml==6.0.3",
}
# run-python must run whenever pinned gates are configured, even if `detect`
# failed: a skipped required check passes (Codex P1 on this change).
RUN_PYTHON_IF = (
    "${{ !cancelled() && (needs.detect.outputs.language == 'python' "
    "|| format('{0}', inputs.pinned_gate_files) != '') }}"
)
# Steps the gate must precede: the first place PR code runs or a credential
# is written.
MUST_PRECEDE = (
    "Install uv",
    "Configure scoped git credential for cross-org clones",
    "Install deps and run tests",
)


def _load():
    return yaml.safe_load(WORKFLOW.read_text())


def _workflow_call_inputs(wf):
    # PyYAML reads the bare `on:` key as the boolean True.
    on = wf.get("on", wf.get(True))
    return on["workflow_call"]["inputs"]


def _step_index(steps, pred):
    hits = [i for i, s in enumerate(steps) if pred(s)]
    return hits[0] if len(hits) == 1 else None


def problems(wf) -> list:
    out = []
    inputs = _workflow_call_inputs(wf)
    for name, default in EXPECTED_INPUT_DEFAULTS.items():
        spec = inputs.get(name)
        if spec is None:
            out.append(f"workflow_call input `{name}` is missing")
            continue
        if spec.get("required") is not False or spec.get("type") != "string":
            out.append(f"input `{name}` must be an optional string")
        if spec.get("default") != default:
            out.append(
                f"input `{name}` default is {spec.get('default')!r}, not {default!r}"
            )

    run_python_if = wf["jobs"]["run-python"].get("if")
    if run_python_if != RUN_PYTHON_IF:
        out.append(
            "run-python must run whenever pinned gates are configured, even if "
            f"detect failed: if={run_python_if!r}"
        )
    detect_env = wf["jobs"]["detect"]["steps"][-1].get("env", {})
    if (
        detect_env.get("INPUT_PINNED_GATE_FILES")
        != "${{ inputs.pinned_gate_files || '' }}"
    ):
        out.append("detect must receive pinned_gate_files to force the Python job")

    steps = wf["jobs"]["run-python"]["steps"]
    gates = [
        i for i, s in enumerate(steps) if "pinned-gate-tests" in str(s.get("uses", ""))
    ]
    if len(gates) != 1:
        return out + [
            f"expected one pinned-gate-tests step in run-python, found {len(gates)}"
        ]
    gi = gates[0]
    gate = steps[gi]
    if gate.get("name") != GATE_STEP_NAME:
        out.append(f"gate step is named {gate.get('name')!r}, not {GATE_STEP_NAME!r}")
    if not ACTION_REF.match(str(gate.get("uses", ""))):
        out.append(f"gate step is not pinned to a commit SHA: {gate.get('uses')!r}")
    if gate.get("if") != OPT_IN_IF:
        out.append(
            f"gate step is not opt-in on pinned_gate_files: if={gate.get('if')!r}"
        )
    if gate.get("with") != EXPECTED_WITH:
        out.append(f"gate step inputs are miswired: {gate.get('with')!r}")

    setup = _step_index(
        steps, lambda s: str(s.get("uses", "")).startswith("actions/setup-python@")
    )
    if setup is None or not setup < gi:
        out.append("gate step must come after the one actions/setup-python step")
    for name in MUST_PRECEDE:
        idx = _step_index(steps, lambda s, n=name: s.get("name") == n)
        if idx is None:
            out.append(f"expected exactly one run-python step named {name!r}")
        elif not gi < idx:
            out.append(f"gate step must run before {name!r}")
    return out


def test_shipped_workflow_wires_the_gate_step_opt_in_pinned_and_first():
    assert problems(_load()) == []


def _moved_after_tests(wf):
    steps = wf["jobs"]["run-python"]["steps"]
    gate = next(s for s in steps if "pinned-gate-tests" in str(s.get("uses", "")))
    steps.remove(gate)
    steps.insert(
        next(
            i
            for i, s in enumerate(steps)
            if s.get("name") == "Install deps and run tests"
        )
        + 1,
        gate,
    )


def _credential_before_gate(wf):
    steps = wf["jobs"]["run-python"]["steps"]
    cred = next(
        s
        for s in steps
        if s.get("name") == "Configure scoped git credential for cross-org clones"
    )
    steps.remove(cred)
    steps.insert(
        next(
            i
            for i, s in enumerate(steps)
            if "pinned-gate-tests" in str(s.get("uses", ""))
        ),
        cred,
    )


def _gate(wf):
    return next(
        s
        for s in wf["jobs"]["run-python"]["steps"]
        if "pinned-gate-tests" in str(s.get("uses", ""))
    )


MUTANTS = {
    "gate step moved after the test run": _moved_after_tests,
    "credential written before the gate step": _credential_before_gate,
    "opt-in `if` dropped (runs for every caller)": lambda wf: _gate(wf).pop("if"),
    "action taken from @main": lambda wf: _gate(wf).__setitem__(
        "uses", "topcoder1/ci-workflows/.github/actions/pinned-gate-tests@main"
    ),
    "expected wired to the files input": lambda wf: _gate(wf)["with"].__setitem__(
        "expected", "${{ inputs.pinned_gate_files }}"
    ),
    "imports input dropped": lambda wf: _gate(wf)["with"].pop("imports"),
    "run-python skippable when detect fails": lambda wf: wf["jobs"][
        "run-python"
    ].__setitem__("if", "needs.detect.outputs.language == 'python'"),
    "detect not told about pinned gates": lambda wf: wf["jobs"]["detect"]["steps"][-1][
        "env"
    ].pop("INPUT_PINNED_GATE_FILES"),
    "files input given a non-empty default (runs for every caller)": lambda wf: (
        _workflow_call_inputs(wf)["pinned_gate_files"].__setitem__(
            "default", "tests/regression/test_x.py"
        )
    ),
}


@pytest.mark.parametrize("mutate", MUTANTS.values(), ids=MUTANTS.keys())
def test_checker_rejects_every_known_bad_shape(mutate):
    """The checker must not go vacuous: each mutant here must be caught."""
    wf = copy.deepcopy(_load())
    mutate(wf)
    assert problems(wf), "the checker accepted a mutant it must reject"


# --- Behavioral: the shipped detect script, against PR-controlled manifests ---
GATES = "tests/regression/test_example_gate.py"


def _detect_step(wf):
    return next(s for s in wf["jobs"]["detect"]["steps"] if s.get("id") == "d")


def _run_detect(manifests, *, pinned="", language="auto", wf=None):
    """Run the shipped `detect` script as GitHub runs a bare `run:` step, in a
    workdir holding `manifests`. Returns (returncode, language-or-None, output).
    `wf` swaps in a mutated workflow for a negative control.
    """
    step = _detect_step(wf or _load())
    with tempfile.TemporaryDirectory() as tmp:
        work = pathlib.Path(tmp) / "work"
        work.mkdir()
        for name in manifests:
            (work / name).write_text("{}\n" if name == "package.json" else "")
        out_file = pathlib.Path(tmp) / "github_output"
        out_file.write_text("")
        script = pathlib.Path(tmp) / "detect.sh"
        script.write_text(step["run"])
        env = {
            **os.environ,
            "GITHUB_OUTPUT": str(out_file),
            "INPUT_LANGUAGE": language,
            "INPUT_WORKDIR": ".",
            "INPUT_GO_VERSION": "",
            "INPUT_PINNED_GATE_FILES": pinned,
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
        lang = next(
            (
                line.split("=", 1)[1]
                for line in out_file.read_text().splitlines()
                if line.startswith("language=")
            ),
            None,
        )
        return proc.returncode, lang, proc.stdout + proc.stderr


@pytest.mark.parametrize(
    "manifests,language",
    [
        (["package.json"], "auto"),  # a PR swapped pyproject.toml for package.json
        (["pyproject.toml", "package.json"], "auto"),  # a PR made detection ambiguous
        ([], "auto"),  # a PR removed every manifest
        (["pyproject.toml"], "auto"),
        (["package.json"], "python"),
    ],
)
def test_pinned_gates_force_the_python_job_whatever_the_manifests(manifests, language):
    """With pinned gates set, the checkout cannot steer the run away from the
    Python job and its gate step (Codex P1 on this change)."""
    rc, lang, out = _run_detect(manifests, pinned=GATES, language=language)
    assert rc == 0 and lang == "python", f"rc={rc} language={lang}\n{out}"


def test_pinned_gates_with_an_explicit_non_python_language_fail_closed():
    rc, lang, out = _run_detect(["package.json"], pinned=GATES, language="js")
    assert rc != 0 and "::error::" in out, f"rc={rc} language={lang}\n{out}"


@pytest.mark.parametrize(
    "manifests,expected",
    [
        (["package.json"], "js"),
        (["pyproject.toml"], "python"),
        (["go.mod"], "go"),
    ],
)
def test_without_pinned_gates_detection_is_unchanged(manifests, expected):
    """The positive control: callers that never set pinned_gate_files keep
    manifest-based detection exactly as before."""
    rc, lang, out = _run_detect(manifests)
    assert rc == 0 and lang == expected, f"rc={rc} language={lang}\n{out}"


def test_without_pinned_gates_ambiguity_still_fails():
    rc, _, out = _run_detect(["pyproject.toml", "package.json"])
    assert rc != 0 and "ambiguous" in out, out


# Both auto-detect failures name the inputs that fix them, Markdown-quoted.
# Inside the step's double quotes an unescaped backtick pair is a command
# substitution: bash runs `language:` as a command, fails, and splices in
# nothing, so the annotation read "Pass  explicitly, or set  to the correct
# subdir." The step still failed closed; only the hint was lost.
INPUT_HINTS = ("`language:`", "`working_directory:`")
AUTO_DETECT_FAILURES = {
    "no manifest": [],
    "ambiguous": ["pyproject.toml", "package.json"],
}


def _auto_detect_error(manifests, wf=None):
    """The one `::error::` annotation a failed auto-detection prints."""
    rc, _, out = _run_detect(manifests, wf=wf)
    errors = [line for line in out.splitlines() if line.startswith("::error::")]
    assert rc != 0 and len(errors) == 1, f"rc={rc}\n{out}"
    return errors[0]


def _names_the_inputs(error):
    return all(hint in error for hint in INPUT_HINTS)


@pytest.mark.parametrize(
    "manifests", AUTO_DETECT_FAILURES.values(), ids=AUTO_DETECT_FAILURES.keys()
)
def test_auto_detect_failures_name_the_inputs_that_fix_them(manifests):
    error = _auto_detect_error(manifests)
    assert _names_the_inputs(error), error


@pytest.mark.parametrize(
    "manifests", AUTO_DETECT_FAILURES.values(), ids=AUTO_DETECT_FAILURES.keys()
)
def test_hint_check_rejects_unescaped_backticks(manifests):
    """Negative control: with the backticks unescaped (the pre-fix form), the
    same check must fail, or it would also pass on a blanked hint."""
    wf = copy.deepcopy(_load())
    step = _detect_step(wf)
    step["run"] = step["run"].replace("\\`", "`")
    error = _auto_detect_error(manifests, wf=wf)
    assert not _names_the_inputs(error), error
