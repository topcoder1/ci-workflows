# Selftest for check_draft_gate_triggers.py -- the fleet's enforcement of:
#
#   a workflow gated on `draft == false` MUST listen for `ready_for_review`.
#
# Lesson 2026-07-15/2026-07-16: this omission has now been made TWICE fleet-wide
# (`reopened` dropped first, then `ready_for_review` dropped directly below the comment
# warning about `reopened`), and both central fixes (ci-workflows#115, dotclaude#156) were
# non-retroactive -- a sweep the next day still found 21 installed repos vulnerable. The
# rule is pinned to the runtime here so the next omission is caught centrally.
#
# These tests protect the CHECKER. The checker's own failure mode is passing vacuously:
# if it stops seeing the transitive gate, or stops reading `on:`, every violation sails
# through and the check becomes decoration that reports green forever. Each test below
# targets one such vacuum.

from pathlib import Path

import pytest
import yaml

from selftest.check_draft_gate_triggers import (
    DRAFT_GATE_EXPR,
    DRAFT_GATED_REUSABLES,
    GITHUB_DEFAULT_PR_TYPES,
    check_dir,
    draft_gate_reason,
    main,
    pr_types,
    triggers,
)

REPO_ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS_DIR = REPO_ROOT / ".github" / "workflows"

TRANSITIVE_CALLER = """\
name: PR Review
on:
  pull_request:
    types: [opened, synchronize, reopened]
jobs:
  review:
    uses: topcoder1/ci-workflows/.github/workflows/claude-review.yml@main
"""

FIXED_CALLER = """\
name: PR Review
on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]
jobs:
  review:
    uses: topcoder1/ci-workflows/.github/workflows/claude-review.yml@main
"""

DIRECT_GATE = """\
name: Direct
on:
  pull_request:
    types: [opened]
jobs:
  build:
    if: github.event.pull_request.draft == false
    runs-on: ubuntu-latest
    steps: [{run: 'true'}]
"""

NO_TYPES_AT_ALL = """\
name: Defaults
on:
  pull_request:
jobs:
  review:
    uses: topcoder1/ci-workflows/.github/workflows/claude-review.yml@main
"""

NO_DRAFT_GATE = """\
name: Plain
on:
  pull_request:
    types: [opened]
jobs:
  build:
    runs-on: ubuntu-latest
    steps: [{run: 'true'}]
"""

NOT_PULL_REQUEST = """\
name: Nightly
on:
  schedule: [{cron: '0 0 * * *'}]
jobs:
  build:
    if: github.event.pull_request.draft == false
    runs-on: ubuntu-latest
    steps: [{run: 'true'}]
"""


def write(tmp_path: Path, name: str, body: str) -> Path:
    d = tmp_path / "workflows"
    d.mkdir(exist_ok=True)
    (d / name).write_text(body)
    return d


# --- the load-bearing property: the transitive gate is visible at all ---------------


def test_detects_gate_inherited_from_called_reusable():
    """The caller has NO `draft` text of its own -- grep cannot see this; parsing must.

    This is the whole reason the checker exists. If it ever regresses to a text search
    over the caller, every transitive violation passes vacuously -- which is exactly the
    shape that left 21 repos merging unreviewed PRs.
    """
    caller = yaml.safe_load(TRANSITIVE_CALLER)
    assert "draft" not in TRANSITIVE_CALLER, "fixture must contain no draft expression"
    reason = draft_gate_reason(caller, DRAFT_GATED_REUSABLES)
    assert reason is not None and "claude-review.yml" in reason


def test_detects_direct_gate():
    workflow = yaml.safe_load(DIRECT_GATE)
    reason = draft_gate_reason(workflow, DRAFT_GATED_REUSABLES)
    assert reason is not None and DRAFT_GATE_EXPR in reason


def test_on_key_is_read_despite_yaml_boolean_truthiness():
    """PyYAML resolves the bare key `on:` to boolean True (YAML 1.1).

    A checker that does `workflow["on"]` reads nothing on every real workflow and reports
    green forever. Pin the behavior rather than trusting the idiom.
    """
    workflow = yaml.safe_load(TRANSITIVE_CALLER)
    assert True in workflow, "precondition: PyYAML really does key this as boolean True"
    assert "pull_request" in triggers(workflow)


# --- the rule ----------------------------------------------------------------------


def test_flags_transitive_caller_missing_ready_for_review(tmp_path):
    d = write(tmp_path, "pr-review.yml", TRANSITIVE_CALLER)
    violations = check_dir(d, DRAFT_GATED_REUSABLES)
    assert len(violations) == 1
    assert "pr-review.yml" in violations[0]
    assert "ready_for_review" in violations[0]


def test_accepts_caller_that_lists_ready_for_review(tmp_path):
    d = write(tmp_path, "pr-review.yml", FIXED_CALLER)
    assert check_dir(d, DRAFT_GATED_REUSABLES) == []


def test_absent_types_list_is_a_violation(tmp_path):
    """An ABSENT `types:` is not a safe default: GitHub's defaults exclude ready_for_review."""
    assert "ready_for_review" not in GITHUB_DEFAULT_PR_TYPES
    d = write(tmp_path, "defaults.yml", NO_TYPES_AT_ALL)
    violations = check_dir(d, DRAFT_GATED_REUSABLES)
    assert len(violations) == 1
    assert "no explicit `types:` list" in violations[0]


def test_direct_gate_missing_trigger_is_flagged(tmp_path):
    d = write(tmp_path, "direct.yml", DIRECT_GATE)
    assert len(check_dir(d, DRAFT_GATED_REUSABLES)) == 1


# --- must NOT over-flag: a noisy check gets disabled, which is its own failure ------


def test_ignores_workflow_without_draft_gate(tmp_path):
    d = write(tmp_path, "plain.yml", NO_DRAFT_GATE)
    assert check_dir(d, DRAFT_GATED_REUSABLES) == []


def test_ignores_non_pull_request_workflow(tmp_path):
    d = write(tmp_path, "nightly.yml", NOT_PULL_REQUEST)
    assert check_dir(d, DRAFT_GATED_REUSABLES) == []


def test_unparseable_yaml_is_left_to_actionlint(tmp_path):
    d = write(tmp_path, "broken.yml", "{{ not yaml at all")
    assert check_dir(d, DRAFT_GATED_REUSABLES) == []


def test_pr_types_defaults_when_types_absent():
    assert pr_types(yaml.safe_load(NO_TYPES_AT_ALL)) == GITHUB_DEFAULT_PR_TYPES


# --- every `on:` shape must be readable, or the checker silently stops checking -----


def test_triggers_handles_string_form():
    """`on: pull_request` is valid and used in the wild."""
    assert "pull_request" in triggers(yaml.safe_load("on: pull_request\njobs: {}\n"))


def test_triggers_handles_list_form():
    """`on: [pull_request, push]` is valid and used in the wild."""
    assert "pull_request" in triggers(yaml.safe_load("on: [pull_request, push]\njobs: {}\n"))


def test_triggers_returns_empty_when_no_on_key():
    assert triggers({"jobs": {}}) == {}


def test_string_form_caller_is_still_checked(tmp_path):
    """A draft-gated caller using the string form must not slip through unchecked."""
    body = (
        "on: pull_request\n"
        "jobs:\n"
        "  review:\n"
        "    uses: topcoder1/ci-workflows/.github/workflows/claude-review.yml@main\n"
    )
    d = write(tmp_path, "stringform.yml", body)
    assert len(check_dir(d, DRAFT_GATED_REUSABLES)) == 1


def test_pr_types_defaults_when_types_is_empty_list():
    wf = yaml.safe_load("on:\n  pull_request:\n    types: []\njobs: {}\n")
    assert pr_types(wf) == GITHUB_DEFAULT_PR_TYPES


def test_pr_types_defaults_when_pull_request_is_not_a_mapping():
    assert pr_types(yaml.safe_load("on: pull_request\njobs: {}\n")) == GITHUB_DEFAULT_PR_TYPES


def test_draft_gate_reason_tolerates_malformed_jobs():
    # A workflow mid-edit (or a template with a null job) must not crash the whole check.
    assert draft_gate_reason({"jobs": None}, DRAFT_GATED_REUSABLES) is None
    assert draft_gate_reason({"jobs": {"a": None}}, DRAFT_GATED_REUSABLES) is None


# --- exit codes: the check must actually fail the job ------------------------------


def test_main_exits_1_on_violation(tmp_path, capsys):
    d = write(tmp_path, "pr-review.yml", TRANSITIVE_CALLER)
    assert main([str(d)]) == 1
    assert "::error" in capsys.readouterr().out


def test_main_exits_0_when_clean(tmp_path):
    d = write(tmp_path, "pr-review.yml", FIXED_CALLER)
    assert main([str(d)]) == 0


def test_main_exits_0_when_no_workflows_dir(tmp_path):
    assert main([str(tmp_path / "nope")]) == 0


def test_extra_reusable_flag_extends_the_registry(tmp_path):
    body = TRANSITIVE_CALLER.replace("claude-review.yml", "some-other-gated.yml")
    d = write(tmp_path, "custom.yml", body)
    assert check_dir(d, DRAFT_GATED_REUSABLES) == []  # unknown reusable -> not flagged
    assert main([str(d), "--extra-reusable", "some-other-gated.yml"]) == 1


# --- the registry must not rot -----------------------------------------------------


def test_registry_matches_repo():
    """Every draft-gating `workflow_call` reusable in this repo must be registered.

    Without this, adding a new draft-gating reusable silently creates a new class of
    transitive violation the checker cannot see -- the registry would rot and the check
    would pass vacuously on exactly the callers it exists to protect.
    """
    actual = set()
    for path in sorted(WORKFLOWS_DIR.glob("*.yml")):
        doc = yaml.safe_load(path.read_text())
        if not isinstance(doc, dict):
            continue
        on = triggers(doc)
        if "workflow_call" not in on:
            continue
        jobs = doc.get("jobs") or {}
        for job in jobs.values():
            if isinstance(job, dict) and DRAFT_GATE_EXPR in str(job.get("if", "")):
                actual.add(path.name)
                break

    assert actual == set(DRAFT_GATED_REUSABLES), (
        f"DRAFT_GATED_REUSABLES is out of sync with this repo.\n"
        f"  registered but not draft-gated reusables: {set(DRAFT_GATED_REUSABLES) - actual}\n"
        f"  draft-gated reusables not registered:     {actual - set(DRAFT_GATED_REUSABLES)}\n"
        f"A reusable missing from the registry is invisible to the transitive check, so "
        f"callers of it would merge unreviewed. Add it to DRAFT_GATED_REUSABLES."
    )


# --- this repo's own callers obey the rule (the selftest half) ---------------------


def test_workflows_dir_is_discoverable():
    # Guards the two tests below: a wrong path would make them vacuously pass and
    # silently retire the selftest.
    assert sorted(WORKFLOWS_DIR.glob("*.yml")), f"no workflows found under {WORKFLOWS_DIR}"


def test_this_repos_own_workflows_obey_the_rule():
    """ci-workflows' own callers are where this rule was broken twice. Lock them.

    `pr-review.yml` here is the canonical caller the fleet is installed from, so a
    regression in it propagates to every new install.
    """
    violations = check_dir(WORKFLOWS_DIR, DRAFT_GATED_REUSABLES)
    assert violations == [], "\n".join(violations)
