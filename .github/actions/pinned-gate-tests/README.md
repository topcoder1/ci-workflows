# pinned-gate-tests (composite action)

Runs a repo's **merge-gate pytest files** a second time, isolated from
everything in the checkout that could switch them off. Extracted from
[topcoder1/webcrawl#585](https://github.com/topcoder1/webcrawl/pull/585)'s
inline `ci.yml` step so every fleet repo whose merge gates are written as
pytest tests can reuse it.

## The problem

A repo can encode a merge rule as a pytest test — "every recursive delete sits
in a human-gated file", "every risk path is owned in CODEOWNERS", and so on. In
a normal `pytest tests/ ...` run, a PR can turn such a test **off without
touching it**, and the diff that does so needs no human click, so it
auto-merges with the gate silently disabled. The routes (each reproduced in the
webcrawl PR body):

- a `conftest.py` that adds a mark the run deselects;
- a `--deselect` / `addopts` entry in `pyproject.toml`;
- a new `pytest.ini` / `tox.ini` / `setup.cfg` that ignores the files;
- a root-level `pytest.py` or `venv.py` that `python -m` runs instead of the
  real module;
- a package directory or extension module named like a gate test (it can set
  `__file__` to pass pytest's import-mismatch check);
- a code-bearing `tests/__init__.py` (pytest runs the `__init__.py` of every
  package from `confcutdir` down at setup, and under `-c /dev/null` confcutdir
  defaults to `/dev`);
- an `__init__.py` in the gate directory itself.

## What this action does

It runs the gate files **first in the job, before the project is installed**,
in a fresh venv holding only pytest and the packages the gates import, and
**fails unless exactly `expected` tests pass**. Every flag is load-bearing —
see the comments in [`action.yml`](action.yml) and the route table in the
webcrawl PR:

| Flag                                                                   | Route it closes                                                                                                                                                                                                    |
| ---------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `-I` on venv bootstrap, pre-check and pytest                           | root-level `pytest.py` / `venv.py` on `sys.path` under `python -m`                                                                                                                                                 |
| `-c /dev/null --rootdir .`                                             | `pyproject.toml` / `pytest.ini` / `tox.ini` / `setup.cfg`                                                                                                                                                          |
| `--noconftest`                                                         | `conftest.py` at any level                                                                                                                                                                                         |
| `--confcutdir <gate dir>`                                              | a code-bearing `tests/__init__.py` run during pytest's package walk                                                                                                                                                |
| `--import-mode=append`                                                 | a module dropped in the gate dir shadowing one the gates import                                                                                                                                                    |
| pre-check (no `__init__.py`; `PathFinder.find_spec` origin per module) | a package dir / extension module named like a gate or helper; a deleted gate file                                                                                                                                  |
| pre-check import scan (pinned files' `import`s, parsed not run)        | a helper left out of `imports`; a module, symlink or directory dropped in the gate dir under the name of something the gates import (filling an optional import, or a namespace/`extend_path` package's submodule) |
| exact `expected` count                                                 | a deselected, skipped or uncollected test                                                                                                                                                                          |
| `--no-cache-dir`, pinned `pytest==`                                    | a poisoned pip cache from an earlier run of the same PR; a pytest that changes collection rules                                                                                                                    |

## Usage

Add it as a **step** inside a job that **already feeds a required status
check**, before you install the project:

```yaml
jobs:
  test: # a job whose success a required check depends on
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: actions/setup-python@v7
        with:
          python-version: "3.12"

      # FIRST, before any `pip install -e .` / `uv sync` / test run.
      - name: Merge gates, isolated from pytest config
        uses: topcoder1/ci-workflows/.github/actions/pinned-gate-tests@<SHA>
        with:
          files: |
            tests/regression/test_recursive_delete_sites_are_gated.py
            tests/regression/test_risk_paths_cover_recursive_deletes.py
          expected: "109"
          # These two gates import only each other (already pinned by `files`),
          # so no `imports`. A gate that imports a helper from the gate dir by
          # bare name must list it, e.g.:
          # imports: |
          #   _risk_paths_glob
          # Optional — these are the defaults:
          # pytest-version: "9.1.1"
          # extra-packages: "pyyaml==6.0.3"

      - run: pip install -e .
      - run: pytest tests/ ...
```

### Do NOT make it its own job

A new job means a new required status context, which sits at
`Expected — Waiting for status to be reported` on every open PR until the
ruleset is updated, and reports nothing on a docs-only skip. Put the step
inside an **existing** job that a required check already gates (webcrawl uses
`test`, whose failure fails the required `coverage-floor-gate`). Then no ruleset
change is needed.

## Inputs

| Input            | Required | Default         | Notes                                                                                                                                                                                                                                                                                                  |
| ---------------- | -------- | --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `files`          | yes      | —               | Newline-separated gate test files, repo-root-relative, **all in one directory**.                                                                                                                                                                                                                       |
| `expected`       | yes      | —               | Exact number of tests that must pass. A hardcoded literal.                                                                                                                                                                                                                                             |
| `imports`        | no       | `""`            | Newline-separated bare-name helper modules the gates import from the gate directory. Pinned by the pre-check, and **required** for every such import: the step fails on one left undeclared. Gate files importing each other need no entry. Do **not** list installed packages or the project package. |
| `pytest-version` | no       | `9.1.1`         | Pinned; the isolation was verified against 9.1.1's collection rules.                                                                                                                                                                                                                                   |
| `extra-packages` | no       | `pyyaml==6.0.3` | Space-separated, version-pinned packages the gate files import at collection time.                                                                                                                                                                                                                     |

## Keep `expected` and `files` in the caller workflow

They belong in the **caller's `.github/workflows/*.yml`** (a `blocked` risk
tier — a human click to change), never in a repo file the gate tests read.
Bumping `expected` after adding a gate test is therefore a deliberate,
human-gated edit in the same PR that adds the test.

Every listed test must **pass unconditionally**: the step accepts exactly
`expected` passed and nothing else, so a `skipped` / `deselected` / `xfailed` /
`xpassed` outcome fails it. Don't route gate files that skip conditionally
through this action.

## Limitation: gates that import the project package

Gate tests that import the project package itself (`import my_project`) cannot
be isolated this way — installing the project runs PR code, which is the exact
thing this action avoids. Route only self-contained gate files (they read files
off disk and import in-directory helpers) through this action. If a listed gate
file imports an uninstalled, undeclared module, collection fails and the step
**fails closed** — safe, but not what you want as a steady state.

## Pinning convention

Pin to a specific **SHA**, never `@main`. This action decides whether a
security-relevant gate ran; a malicious commit to `main` could weaken it.
Bumping the pin is a deliberate PR.

## Fail-closed contract

Every failure path exits non-zero: empty/invalid inputs, a non-`.py` path, an
absolute path or one with a `..` segment (repo-root-relative only), files
spanning two directories, a missing or deleted gate file, a gate-directory
package, a name-shadow of a gate or helper module, anything in the gate
directory — a module file, a directory or a symlink, wherever it points — named
like the top-level package of an import the pinned files make without being
declared in `imports`, a pytest exit of 1/2/4/5, and any count other than
`expected`. Callers must
treat a failure as a hard block — that is the whole point.

The import scan reads the static `import` / `from … import` statements of the
pinned files (gates and declared helpers). It does not see dynamic imports
(`importlib.import_module("…")`) or imports made lazily inside the standard
library or installed packages; keep gate files to plain static imports.
