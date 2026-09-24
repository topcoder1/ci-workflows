"""Guard: the pinned-gate-tests composite action isolates a repo's merge-gate
pytest files from everything in the checkout that could switch them off.

The action (`.github/actions/pinned-gate-tests/action.yml`) is extracted from
topcoder1/webcrawl#585's inline `ci.yml` step. This selftest builds a throwaway
repo with two self-contained gate files plus an in-directory helper the gates
import by bare name, then runs the action's SHIPPED `run:` block against it the
way GitHub runs a composite `shell: bash` step (`bash --noprofile --norc -eo
pipefail`), in a scrubbed env with `python` shimmed and pip pointed at an
offline wheelhouse.

Scope. This selftest pins the properties the action must hold with a clean tree
and the ways it must FAIL: the four count cases (a parametrize row removed, a
module-level skip, the files emptied, a gate file deleted), input validation,
and the pre-check fired by HARMLESS placeholder files (an empty `__init__.py`,
a package directory or a zero-byte extension module named like a gate or helper
module, an empty module or a symlink to one filling an optional import, an
empty directory named like a dotted import's package) plus a helper left out of
`imports`. It deliberately does NOT carry executable bypass payloads — the full
route-by-route replay (a conftest that deselects, a root `pytest.py`/`venv.py`,
a package that re-runs the scanner, a `tests/__init__.py` that rewrites a test's
`__code__`) lives with webcrawl#585's own corpus and is run against the repo it
guards. Two flags whose defense only shows against such a payload — `--noconftest`
and `--confcutdir` stopping a code-bearing `tests/__init__.py` — are held here
structurally, by the flag-vacuum guard, and behaviorally over there.

Expectations are hardcoded, never derived from the action under test.
"""

import os
import pathlib
import re
import subprocess
import sys
import tempfile

import pytest
import yaml

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
ACTION = REPO_ROOT / ".github" / "actions" / "pinned-gate-tests" / "action.yml"

# --- The throwaway fixture repo -------------------------------------------
# Two self-contained gate files: a pin (which files may recursively delete,
# each human-gated in risk-paths.yml) and a scanner (every recursive delete
# under src/ sits in a pinned file). A shared helper `_gate_glob` is imported
# by bare name. A bystander test and an empty tests/__init__.py are present the
# way a real repo has them.
GATE_DIR = "tests/regression"
GATE_FILES = f"{GATE_DIR}/test_delete_sites_gated.py\n{GATE_DIR}/test_delete_pins.py"
GATE_IMPORTS = "_gate_glob"
EXPECTED = "8"  # 5 in the pin (2 sites + 3 gate files), 3 in the scanner (1 + 2)

_HELPER = '''\
"""Glob matching for risk-paths.yml patterns, shared by the gate tests."""

import os.path
import re

try:  # optional accelerator, absent in this repo: an import that resolves nowhere
    import _gate_glob_accel
except ImportError:
    _gate_glob_accel = None


def matches(glob, path):
    regex, i = "", 0
    while i < len(glob):
        if glob.startswith("**/", i):
            regex, i = regex + "(?:.*/)?", i + 3
        elif glob.startswith("**", i):
            regex, i = regex + ".*", i + 2
        elif glob[i] == "*":
            regex, i = regex + "[^/]*", i + 1
        else:
            regex, i = regex + re.escape(glob[i]), i + 1
    return re.fullmatch(regex, path) is not None
'''

_PINS = '''\
"""Pin: the files allowed to recursively delete, each human-gated."""

from pathlib import Path

import pytest
import yaml
from _gate_glob import matches

ROOT = Path(__file__).resolve().parents[2]
PINNED_DELETE_SITES = ["src/proj/cleanup.py", "src/proj/rotate.py"]
GATE_FILES = [
    "tests/regression/test_delete_pins.py",
    "tests/regression/test_delete_sites_gated.py",
    "tests/regression/_gate_glob.py",
]


def _gated_globs():
    risk = yaml.safe_load((ROOT / ".github" / "risk-paths.yml").read_text())
    return [*risk.get("blocked", []), *risk.get("sensitive", [])]


@pytest.mark.parametrize("site", PINNED_DELETE_SITES)
def test_delete_site_is_human_gated(site):
    assert any(matches(g, site) for g in _gated_globs()), site


@pytest.mark.parametrize("gate", GATE_FILES)
def test_gate_file_is_human_gated(gate):
    assert any(matches(g, gate) for g in _gated_globs()), gate
'''

_SCANNER = '''\
"""Scanner: every recursive delete under src/ sits in a pinned file."""

import ast
from pathlib import Path

import pytest
from test_delete_pins import PINNED_DELETE_SITES

ROOT = Path(__file__).resolve().parents[2]


def _delete_sites():
    sites = set()
    for path in sorted((ROOT / "src").rglob("*.py")):
        for node in ast.walk(ast.parse(path.read_text(), filename=str(path))):
            if not isinstance(node, ast.Call):
                continue
            f = node.func
            if (
                isinstance(f, ast.Attribute)
                and isinstance(f.value, ast.Name)
                and (f.value.id, f.attr) == ("shutil", "rmtree")
            ):
                sites.add(path.relative_to(ROOT).as_posix())
    return sites


def test_every_delete_site_is_pinned():
    unpinned = sorted(_delete_sites() - set(PINNED_DELETE_SITES))
    assert not unpinned, f"recursive delete outside the pinned files: {unpinned}"


@pytest.mark.parametrize("site", PINNED_DELETE_SITES)
def test_pinned_site_still_deletes(site):
    assert site in _delete_sites(), f"{site} is pinned but no longer deletes"
'''

_RISK_PATHS = """\
blocked:
  - ".github/workflows/**"
sensitive:
  - "src/proj/cleanup.py"
  - "src/proj/rotate.py"
  - "tests/regression/test_delete_*.py"
  - "tests/regression/_gate_glob.py"
"""

FIXTURE = {
    "src/proj/__init__.py": "",
    "src/proj/cleanup.py": "import shutil\n\n\ndef wipe_cache(path):\n    shutil.rmtree(path)\n",
    "src/proj/rotate.py": "import shutil\n\n\ndef drop_old(path):\n    shutil.rmtree(path, ignore_errors=True)\n",
    ".github/risk-paths.yml": _RISK_PATHS,
    "tests/__init__.py": "",
    "tests/regression/_gate_glob.py": _HELPER,
    "tests/regression/test_delete_pins.py": _PINS,
    "tests/regression/test_delete_sites_gated.py": _SCANNER,
    "tests/regression/test_unrelated.py": "def test_unrelated():\n    assert True\n",
    "pyproject.toml": '[project]\nname = "proj"\nversion = "0.0.0"\n\n[tool.pytest.ini_options]\ntestpaths = ["tests"]\n',
}


def _shipped_step():
    action = yaml.safe_load(ACTION.read_text())
    assert action["runs"]["using"] == "composite", "must be a composite action"
    steps = action["runs"]["steps"]
    assert len(steps) == 1, f"expected one composite step, found {len(steps)}"
    step = steps[0]
    assert step["shell"] == "bash", step.get("shell")
    return step


@pytest.fixture(scope="session")
def wheelhouse(tmp_path_factory):
    """Download pytest + pyyaml (and deps) once, for the SAME interpreter the
    action's venv will use, so every case installs offline and deterministically.
    """
    packages = ["pytest==9.1.1", "pyyaml==6.0.3"]
    wh = tmp_path_factory.mktemp("wheelhouse")
    builder = tmp_path_factory.mktemp("wheelbuilder") / "venv"
    subprocess.run(
        [sys.executable, "-m", "venv", str(builder)], check=True, capture_output=True
    )
    pip = builder / ("Scripts" if os.name == "nt" else "bin") / "pip"
    proc = subprocess.run(
        [str(pip), "download", "--only-binary=:all:", "-d", str(wh), *packages],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        pytest.skip(
            "could not build the offline wheelhouse (no network for "
            f"pytest/pyyaml wheels):\n{proc.stdout}\n{proc.stderr}"
        )
    return wh


def _write_fixture(root: pathlib.Path):
    for rel, content in FIXTURE.items():
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(content)


def _run_action(
    wheelhouse,
    *,
    files=GATE_FILES,
    expected=EXPECTED,
    imports=GATE_IMPORTS,
    pytest_version="9.1.1",
    extra_packages="pyyaml==6.0.3",
    mutate=None,
):
    """Run the action's shipped run: block against a fresh copy of the fixture.

    Returns (returncode, combined_output)."""
    run = _shipped_step()["run"]
    with tempfile.TemporaryDirectory() as tmp:
        d = pathlib.Path(tmp)
        repo = d / "repo"
        repo.mkdir()
        _write_fixture(repo)
        if mutate is not None:
            mutate(repo)

        shim = d / "shim"
        shim.mkdir()
        (shim / "python").symlink_to(sys.executable)
        runner_temp = d / "runner_temp"
        runner_temp.mkdir()
        step = d / "step.sh"
        step.write_text(run)

        env = {
            **os.environ,
            "PATH": f"{shim}{os.pathsep}{os.environ.get('PATH', '')}",
            "RUNNER_TEMP": str(runner_temp),
            "PIP_FIND_LINKS": str(wheelhouse),
            "PIP_NO_INDEX": "1",
            "PIP_DISABLE_PIP_VERSION_CHECK": "1",
            "GATE_FILES": files,
            "GATE_IMPORTS": imports,
            "EXPECTED": expected,
            "PYTEST_VERSION": pytest_version,
            "EXTRA_PACKAGES": extra_packages,
        }
        proc = subprocess.run(
            ["bash", "--noprofile", "--norc", "-eo", "pipefail", str(step)],
            cwd=repo,
            env=env,
            capture_output=True,
            text=True,
            stdin=subprocess.DEVNULL,
            timeout=300,
        )
        return proc.returncode, proc.stdout + proc.stderr


# --- Behavioral: the clean tree passes ------------------------------------
def test_clean_tree_passes(wheelhouse):
    rc, out = _run_action(wheelhouse)
    assert rc == 0, f"clean tree must pass:\n{out}"
    assert f"{EXPECTED} passed" in out, out


# --- Behavioral: an actual gate violation fails ---------------------------
def test_ungated_recursive_delete_fails(wheelhouse):
    """A new ungated shutil.rmtree in src/ is what the scanner exists to catch."""

    def mutate(repo):
        (repo / "src/proj/tidy.py").write_text(
            "import shutil\n\n\ndef tidy(p):\n    shutil.rmtree(p)\n"
        )

    rc, out = _run_action(wheelhouse, mutate=mutate)
    assert rc != 0, f"an ungated recursive delete must fail the gate:\n{out}"


# --- Behavioral: a passing count that masks a disabled test still fails ----
def test_added_then_skipped_test_still_fails(wheelhouse):
    """`8 passed, 1 skipped` must fail even though `8 passed` matches EXPECTED.

    An added-then-skipped test keeps the passed count at EXPECTED while a test
    does not run; the summary carries a `skipped` outcome, which the action
    rejects. (Adding a test to a gate file is itself a human-gated edit, so
    this needs the file touched — but the reject makes "exactly N passed"
    literal regardless.)
    """

    def mutate(repo):
        p = repo / "tests/regression/test_delete_pins.py"
        p.write_text(
            p.read_text()
            + '\n\n@pytest.mark.skip(reason="demo")\ndef test_added_but_skipped():\n    assert True\n'
        )

    rc, out = _run_action(wheelhouse, mutate=mutate)
    assert f"{EXPECTED} passed" in out and "skipped" in out, out  # the masking shape
    assert rc != 0, f"a summary with a skipped outcome must fail:\n{out}"


# --- Behavioral: the four count cases -------------------------------------
def _drop_gate_list_row(repo):
    p = repo / "tests/regression/test_delete_pins.py"
    p.write_text(
        p.read_text().replace('    "tests/regression/_gate_glob.py",\n', "", 1)
    )


def _module_level_skip(repo):
    p = repo / "tests/regression/test_delete_sites_gated.py"
    p.write_text(
        p.read_text().replace(
            "import ast\n",
            'import ast\n\nimport pytest as _pt\npytestmark = _pt.mark.skip(reason="x")\n',
            1,
        )
    )


def _empty_both_gate_files(repo):
    (repo / "tests/regression/test_delete_pins.py").write_text("")
    (repo / "tests/regression/test_delete_sites_gated.py").write_text("")


def _delete_a_gate_file(repo):
    (repo / "tests/regression/test_delete_pins.py").unlink()


@pytest.mark.parametrize(
    "mutate,why",
    [
        (_drop_gate_list_row, "a parametrize row removed (fewer than expected pass)"),
        (_module_level_skip, "a module-level skip (tests skip, not pass)"),
        (_empty_both_gate_files, "both gate files emptied (no tests ran, exit 5)"),
        (_delete_a_gate_file, "a gate file deleted"),
    ],
)
def test_count_cases_fail(wheelhouse, mutate, why):
    rc, out = _run_action(wheelhouse, mutate=mutate)
    assert rc != 0, f"must fail: {why}\n{out}"


# --- Behavioral: the pre-check, fired by harmless placeholders ------------
def _init_py_in_gate_dir(repo):
    (repo / "tests/regression/__init__.py").write_text("")


def _package_shadow_of_a_gate(repo):
    d = repo / "tests/regression/test_delete_pins"
    d.mkdir()
    (d / "__init__.py").write_text("")


def _extension_shadow_of_a_gate(repo):
    (repo / "tests/regression/test_delete_pins.abi3.so").write_bytes(b"")


def _package_shadow_of_a_helper(repo):
    d = repo / "tests/regression/_gate_glob"
    d.mkdir()
    (d / "__init__.py").write_text("")


@pytest.mark.parametrize(
    "mutate,why",
    [
        (_init_py_in_gate_dir, "an __init__.py in the gate directory"),
        (_package_shadow_of_a_gate, "a package dir named like a gate module"),
        (_extension_shadow_of_a_gate, "an extension module named like a gate module"),
        (
            _package_shadow_of_a_helper,
            "a package dir named like a declared helper import",
        ),
    ],
)
def test_precheck_placeholder_cases_fail(wheelhouse, mutate, why):
    rc, out = _run_action(wheelhouse, mutate=mutate)
    assert rc != 0, f"pre-check must fail: {why}\n{out}"
    assert "::error::" in out, out


# --- Behavioral: every bare-name import that lands in the gate dir is pinned --
# A helper the caller forgot to list in `imports` resolves from the gate
# directory but is not pinned, so a package or extension module of the same
# name could shadow it. The pre-check reads the pinned files' imports and fails
# on any that would load from the gate directory without being declared.
def test_undeclared_helper_import_fails(wheelhouse):
    """The clean tree, with `_gate_glob` left out of `imports`. The pin reaches
    the helper only through `from _gate_glob import matches`, so this is the
    `from X import Y` path of the scan; the scanner file, scanned first, has
    no gate-directory import to trip on."""
    rc, out = _run_action(wheelhouse, imports="")
    assert rc != 0, f"an undeclared in-directory helper must fail:\n{out}"
    assert "test_delete_pins.py imports _gate_glob" in out, out
    assert "not pinned" in out, out


def test_optional_import_filled_from_gate_dir_fails(wheelhouse):
    """The helper's optional `_gate_glob_accel` import resolves nowhere in the
    clean tree (which passes). An empty placeholder named like it, dropped in the
    gate directory, would now be imported by the gates: the pre-check must fail
    on it before pytest starts."""

    def mutate(repo):
        (repo / "tests/regression/_gate_glob_accel.py").write_text("")

    rc, out = _run_action(wheelhouse, mutate=mutate)
    assert rc != 0, f"an undeclared module filling an optional import must fail:\n{out}"
    assert "_gate_glob_accel" in out and "not pinned" in out, out


def test_extension_module_filling_an_optional_import_fails(wheelhouse):
    """The same optional import, filled by a zero-byte EXTENSION module
    (`.abi3.so`, an import suffix on Linux and macOS alike) rather than a
    `.py`: every import suffix counts, not only source files."""

    def mutate(repo):
        (repo / "tests/regression/_gate_glob_accel.abi3.so").write_bytes(b"")

    rc, out = _run_action(wheelhouse, mutate=mutate)
    assert rc != 0, f"an extension module filling an optional import must fail:\n{out}"
    assert "_gate_glob_accel.abi3.so" in out and "not pinned" in out, out


def test_symlink_filling_an_optional_import_fails(wheelhouse):
    """The same optional import, filled by a SYMLINK in the gate directory that
    points outside it (at an empty file). Python imports it through the link's
    own path, which is in the gate directory, so it must count as a gate-
    directory module wherever it points (Codex P1: a resolve()-then-contain
    check followed the link out and passed it)."""

    def mutate(repo):
        (repo / "elsewhere").mkdir()
        (repo / "elsewhere/empty.py").write_text("")
        (repo / "tests/regression/_gate_glob_accel.py").symlink_to(
            "../../elsewhere/empty.py"
        )

    rc, out = _run_action(wheelhouse, mutate=mutate)
    assert rc != 0, f"a symlinked module filling an optional import must fail:\n{out}"
    assert "_gate_glob_accel" in out and "not pinned" in out, out


def test_directory_named_like_a_dotted_import_fails(wheelhouse):
    """The helper does `import os.path`. A directory in the gate directory named
    like the top-level package of a dotted import is the shape a namespace
    package, or one that extends its __path__, would merge submodules from
    (Codex P2: the scan resolved only the top-level name, found it elsewhere,
    and passed). An empty directory with an empty module is enough to fail."""

    def mutate(repo):
        (repo / "tests/regression/os").mkdir()
        (repo / "tests/regression/os/path.py").write_text("")

    rc, out = _run_action(wheelhouse, mutate=mutate)
    assert rc != 0, (
        f"a directory named like a dotted import's package must fail:\n{out}"
    )
    assert "os" in out and "not pinned" in out, out


# --- Behavioral: input validation, before any venv is built ---------------
def test_files_in_two_directories_fail(wheelhouse):
    rc, out = _run_action(
        wheelhouse,
        files="tests/regression/test_delete_pins.py\nsrc/proj/cleanup.py",
    )
    assert rc != 0 and "one directory" in out, out


def test_non_integer_expected_fails(wheelhouse):
    rc, out = _run_action(wheelhouse, expected="eight")
    assert rc != 0 and "integer" in out, out


def test_empty_files_fails(wheelhouse):
    rc, out = _run_action(wheelhouse, files="")
    assert rc != 0 and "files input is empty" in out, out


def test_zero_expected_fails(wheelhouse):
    rc, out = _run_action(wheelhouse, expected="0")
    assert rc != 0, out


def test_absolute_gate_path_fails(wheelhouse):
    """Repo-root-relative only: an absolute path could run a file outside the
    checkout that the PR never touched (Codex P2)."""
    rc, out = _run_action(
        wheelhouse,
        files=f"/tmp/{GATE_DIR}/test_delete_pins.py\n{GATE_DIR}/test_delete_sites_gated.py",
    )
    assert rc != 0 and "absolute" in out, out


def test_dotdot_gate_path_fails(wheelhouse):
    """A `..` segment could escape the checkout, same as an absolute path."""
    rc, out = _run_action(
        wheelhouse,
        files=f"{GATE_DIR}/../regression/test_delete_pins.py\n{GATE_DIR}/test_delete_sites_gated.py",
    )
    assert rc != 0 and "'..'" in out, out


def _executable_lines(run: str) -> str:
    """The run: block with shell comments removed, so a load-bearing flag left
    in a comment after being dropped from the command does not satisfy the
    guard below (Codex P2 on this PR). Drop full-comment lines, then strip
    inline ` # ...` comments (shell requires whitespace before `#`); no code
    line here carries an in-string `#`.
    """
    kept = []
    for line in run.splitlines():
        if line.lstrip().startswith("#"):
            continue
        kept.append(re.sub(r"(?<=\s)#.*$", "", line))
    return "\n".join(kept)


# --- Structural: the EXECUTABLE command still carries every load-bearing flag
# If a refactor drops one of these from the command, a bypass route reopens
# while the behavioral cases above (which use harmless placeholders) could still
# pass. This is the vacuum guard for the two flags whose defense only shows
# against an executable payload (--noconftest, --confcutdir) and the rest
# besides. Checked against the comment-stripped script so a flag surviving only
# in a comment does not count.
def test_run_block_pins_every_flag():
    code = _executable_lines(_shipped_step()["run"])
    required = [
        "python -I -m venv",  # -I on the bootstrap; isolated venv
        "--no-cache-dir",  # past a poisoned pip cache
        "pytest==$PYTEST_VERSION",  # pinned pytest
        '"$venv/bin/python" -I -m pytest',  # -I on pytest
        "-c /dev/null",  # no pyproject/pytest.ini/tox/setup.cfg
        "--rootdir .",
        "--noconftest",  # no conftest at any level
        "no:cacheprovider",
        '--confcutdir "$gate_dir"',  # stop the package walk before tests/
        "--import-mode=append",  # gate dir last on sys.path
        "PathFinder.find_spec",  # module-origin pre-check
        "ast.walk(ast.parse(",  # the pinned files' imports are scanned
        "all_suffixes()",  # any importable file in the gate dir counts
        "base.is_symlink() or base.is_dir()",  # symlinks/dirs, never resolved
        "not pinned: add it to the imports input",
        '"__init__.py"',  # gate-dir package pre-check (the code literal)
    ]
    missing = [flag for flag in required if flag not in code]
    assert not missing, (
        f"the action dropped load-bearing flag(s) from the command: {missing}"
    )
    # The -I pre-check reads gate dir + module names from the environment, so a
    # gate name can never be interpolated into the script.
    assert 'GATE_DIR="$gate_dir" GATE_MODULES="$modules"' in code
    # The count check compares against the caller's EXPECTED literal, exactly.
    assert '"$EXPECTED passed"' in code
    # ...and rejects any non-passing outcome, so an added-then-disabled test
    # cannot hold `passed` at EXPECTED (Codex P1).
    assert "skipped|deselected|xfailed|xpassed" in code
    # A unique venv dir per invocation, so two calls in one job never share
    # packages (Codex P2).
    assert 'mktemp -d "$RUNNER_TEMP/pinned-gate-tests.XXXXXX"' in code
    assert '"$RUNNER_TEMP/gates/bin' not in code, (
        "fixed venv path reused across invocations"
    )


def test_env_maps_every_input():
    env = _shipped_step()["env"]
    assert env == {
        "GATE_FILES": "${{ inputs.files }}",
        "GATE_IMPORTS": "${{ inputs.imports }}",
        "EXPECTED": "${{ inputs.expected }}",
        "PYTEST_VERSION": "${{ inputs.pytest-version }}",
        "EXTRA_PACKAGES": "${{ inputs.extra-packages }}",
    }, env


def test_inputs_declared_with_expected_contract():
    action = yaml.safe_load(ACTION.read_text())
    inputs = action["inputs"]
    assert inputs["files"]["required"] is True
    assert inputs["expected"]["required"] is True
    assert inputs["imports"].get("required") is False
    assert inputs["imports"].get("default") == ""
    assert inputs["pytest-version"].get("default") == "9.1.1"
    assert inputs["extra-packages"].get("default") == "pyyaml==6.0.3"
