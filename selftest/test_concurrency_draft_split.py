"""Guard: a draft-gated workflow's concurrency group must split by draft flag.

A job gated on `github.event.pull_request.draft == false` makes every
draft-payload run a no-op, but in a group it shares with live runs of the same
PR that no-op run can still cancel the live run, or replace it while it waits,
and then skip. The callers split their groups by the payload's draft flag
after that race hit attaxion_dev#303 (ci-workflows#110 and #116 did the same
for the review lanes). safe-paths-automerge.yml then declared its own unsplit
group, which put both runs back into one queue one level down. On 2026-10-16
a push to a draft PR and `gh pr ready` about a second later delivered the
draft-payload `synchronize` AFTER `ready_for_review`: the ready run was
cancelled ("higher priority waiting request for safe-paths-automerge-<N>"),
the synchronize run skipped, and neither run armed auto-merge
(whois-api-llc/wxa_vpn#2258).

Three layers:

1. Pins. Each reusable in EXPECTED_GROUPS declares exactly its hardcoded
   group, with cancel-in-progress on: live runs must still supersede each
   other, so a newer push cancels a stale live run before it can arm from
   pre-push state. Hardcoded on purpose: read from the workflow, the
   expectation would follow the workflow when it regresses.
2. What the pinned strings mean, by rendering them for draft and live
   payloads and comparing the names case-insensitively, as GitHub does: a
   draft and a live run of one PR land in different groups, two PRs never
   share one, and the reusable never lands in a group its caller runs hold
   (CALLER_GROUPS).
3. A sweep over every workflow the fleet's draft-gate lint counts as gated
   (check_draft_gate_triggers.draft_gate_reason: a job `if:` containing
   `draft == false`, or a job calling a reusable that has one). Each group it
   declares, workflow- or job-level, must render split and stay out of its
   callers' groups, and a gated reusable's group must be pinned in layer 1.
   verifier-on-high-risk.yml keeps an unsplit per-PR group because no job
   there gates on draft; a control adds a `draft == false` gate and must be
   caught. Other spellings of a draft gate (`!...draft`, a step's `if:`) go
   undetected here, as they do in the lint.

Negative controls run each layer against a mutated copy and must fail.
"""

import pathlib
import re

import pytest
import yaml

from selftest.check_draft_gate_triggers import (
    DRAFT_GATED_REUSABLES,
    draft_gate_reason,
    load_workflow,
    triggers,
)

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
WORKFLOWS_DIR = REPO_ROOT / ".github" / "workflows"

# Change by decision only, in the same PR as the workflow.
EXPECTED_GROUPS = {
    "safe-paths-automerge.yml": (
        "safe-paths-automerge-reusable-${{ github.event.pull_request.number }}"
        "-${{ github.event.pull_request.draft && 'draft' || 'live' }}"
    ),
}

# The group the callers of each pinned reusable declare for themselves. For
# safe-paths, every fleet caller (41 of 41, read 2026-10-16) declares this one,
# from dotclaude's templates/ci-workflows/callers/safe-paths-automerge.yml.
# Concurrency groups are repo-scoped and their names case-insensitive, so a
# reusable group that renders the same, ignoring case, would make the run
# contend for the group its own caller run holds.
CALLER_GROUPS = {
    "safe-paths-automerge.yml": (
        "safe-paths-automerge-${{ github.event.pull_request.number }}"
        "-${{ github.event.pull_request.draft && 'draft' || 'live' }}"
    ),
}

# The pre-fix group: what a revert would restore.
UNSPLIT = "safe-paths-automerge-${{ github.event.pull_request.number }}"

# The only expressions a rendered group may use. Anything else fails closed: a
# group keyed on github.run_id or the head SHA would stop live runs from
# superseding each other, and an expression this table cannot read must not
# pass unread.
_MODELED = {
    "github.event.pull_request.number": lambda pr, draft: str(pr),
    "github.event.pull_request.draft && 'draft' || 'live'": (
        lambda pr, draft: "draft" if draft else "live"
    ),
}


def render(group: str, pr: int, draft: bool) -> str:
    """The group a run for PR `pr` with this payload draft flag would join.

    Lower-cased: GitHub compares group names case-insensitively, so two names
    that differ only in case are one group.
    """

    def expand(match: re.Match) -> str:
        expr = " ".join(match.group(1).split())
        if expr not in _MODELED:
            raise ValueError(f"expression {expr!r} in {group!r} is not modeled")
        return _MODELED[expr](pr, draft)

    rendered = re.sub(r"\$\{\{(.*?)\}\}", expand, group)
    if "${{" in rendered:
        raise ValueError(f"unterminated expression in {group!r}")
    return rendered.lower()


def split_problems(group: str) -> list[str]:
    problems = []
    if render(group, 1, True) == render(group, 1, False):
        problems.append(
            "a draft-payload run and a live run of one PR share this group, so "
            "the draft-payload run, a no-op behind the draft gate, can cancel or "
            "replace the live run"
        )
    if render(group, 1, False) == render(group, 2, False):
        problems.append("two PRs share this group, so one PR's run cancels another's")
    return problems


def caller_collisions(group: str, caller_group: str) -> list[str]:
    """Rendered groups this group shares with its callers' groups."""
    mine = {render(group, 1, draft) for draft in (True, False)}
    theirs = {render(caller_group, 1, draft) for draft in (True, False)}
    return sorted(mine & theirs)


def concurrency_blocks(workflow: dict) -> list[tuple[str, str, object]]:
    """(where, group, cancel-in-progress) for the workflow and for each job."""
    found = [("workflow", workflow.get("concurrency"))]
    jobs = workflow.get("jobs")
    if isinstance(jobs, dict):
        found += [
            (f"job `{job_id}`", job.get("concurrency"))
            for job_id, job in jobs.items()
            if isinstance(job, dict)
        ]
    blocks = []
    for where, conc in found:
        if isinstance(conc, dict):
            blocks.append(
                (where, str(conc.get("group")), conc.get("cancel-in-progress"))
            )
        elif conc is not None:
            blocks.append((where, str(conc), None))
    return blocks


def check_pinned(name: str, text: str) -> None:
    workflow = yaml.safe_load(text)
    assert isinstance(workflow, dict), f"{name} does not parse to a mapping"
    blocks = {
        where: (group, cancel) for where, group, cancel in concurrency_blocks(workflow)
    }
    assert "workflow" in blocks, (
        f"{name} must declare a workflow-level concurrency group"
    )
    group, cancel = blocks["workflow"]
    assert group == EXPECTED_GROUPS[name], (
        f"{name}'s concurrency group is {group!r}; expected {EXPECTED_GROUPS[name]!r}. "
        "It must split by the payload's draft flag, or a stale draft-payload run "
        "cancels the ready run and skips, and it must not render the same as its "
        "callers' own group."
    )
    assert cancel is True, (
        f"{name} must keep cancel-in-progress: true, got {cancel!r}: a newer push "
        "has to cancel a stale live run before it can act on pre-push state"
    )


def gated_groups(workflows_dir: pathlib.Path) -> dict[str, list[tuple[str, str]]]:
    """Each draft-gated workflow's (where, group) pairs, gated workflows only."""
    found = {}
    for path in sorted(workflows_dir.glob("*.yml")) + sorted(
        workflows_dir.glob("*.yaml")
    ):
        workflow = load_workflow(path)
        if (
            workflow is None
            or draft_gate_reason(workflow, DRAFT_GATED_REUSABLES) is None
        ):
            continue
        blocks = [(where, group) for where, group, _ in concurrency_blocks(workflow)]
        if blocks:
            found[path.name] = blocks
    return found


def sweep(workflows_dir: pathlib.Path) -> list[str]:
    problems = []
    for name, blocks in gated_groups(workflows_dir).items():
        reusable = "workflow_call" in triggers(load_workflow(workflows_dir / name))
        for where, group in blocks:
            problems += [f"{name} ({where}): {p}" for p in split_problems(group)]
            if name in CALLER_GROUPS:
                hits = caller_collisions(group, CALLER_GROUPS[name])
                if hits:
                    problems.append(
                        f"{name} ({where}): renders as {', '.join(hits)}, a "
                        "group its callers hold"
                    )
            if reusable and name not in EXPECTED_GROUPS:
                problems.append(
                    f"{name} ({where}): a draft-gated reusable's group must be "
                    "pinned in EXPECTED_GROUPS, with its callers' group in "
                    "CALLER_GROUPS"
                )
    return problems


# --- layer 1: the pins ---------------------------------------------------------


@pytest.mark.parametrize("name", sorted(EXPECTED_GROUPS))
def test_reusable_group_is_pinned(name):
    check_pinned(name, (WORKFLOWS_DIR / name).read_text())


def _set_group(text: str, group: str) -> str:
    old = f"  group: {EXPECTED_GROUPS['safe-paths-automerge.yml']}\n"
    return text.replace(old, f"  group: {group}\n", 1)


def _unsplit(text: str) -> str:
    return _set_group(text, UNSPLIT)


def _callers_own_group(text: str) -> str:
    return _set_group(text, CALLER_GROUPS["safe-paths-automerge.yml"])


def _cancel_off(text: str) -> str:
    block = f"  group: {EXPECTED_GROUPS['safe-paths-automerge.yml']}\n  cancel-in-progress: "
    return text.replace(block + "true\n", block + "false\n", 1)


@pytest.mark.parametrize(
    "mutate",
    [_unsplit, _callers_own_group, _cancel_off],
    ids=["unsplit", "callers-own-group", "cancel-in-progress-off"],
)
def test_pin_catches_each_regression(mutate):
    """Negative controls: a guard that reads the artifact it checks must be
    shown to fail when that artifact regresses."""
    text = (WORKFLOWS_DIR / "safe-paths-automerge.yml").read_text()
    mutated = mutate(text)
    assert mutated != text, "mutation did not apply; the anchor drifted"
    with pytest.raises(AssertionError):
        check_pinned("safe-paths-automerge.yml", mutated)


# --- layer 2: what the pinned strings mean ---------------------------------------


@pytest.mark.parametrize("name", sorted(EXPECTED_GROUPS))
def test_pinned_group_splits_by_draft_flag(name):
    assert split_problems(EXPECTED_GROUPS[name]) == []
    assert render(EXPECTED_GROUPS[name], 7, True) != render(
        EXPECTED_GROUPS[name], 7, False
    )


@pytest.mark.parametrize("name", sorted(EXPECTED_GROUPS))
def test_pinned_group_never_joins_a_callers_group(name):
    assert name in CALLER_GROUPS, f"{name}: record its callers' group in CALLER_GROUPS"
    assert caller_collisions(EXPECTED_GROUPS[name], CALLER_GROUPS[name]) == []


def test_split_check_catches_the_pre_fix_group():
    problems = split_problems(UNSPLIT)
    assert len(problems) == 1 and "draft-payload run and a live run" in problems[0]


def test_split_check_catches_a_group_shared_across_prs():
    problems = split_problems(
        "safe-paths-automerge-reusable-${{ github.event.pull_request.draft && 'draft' || 'live' }}"
    )
    assert len(problems) == 1 and "two PRs" in problems[0]


@pytest.mark.parametrize(
    "variant",
    [
        lambda group: group.replace("${{ ", "${{").replace(" }}", "}}"),
        lambda group: group.replace("safe-paths-automerge-", "Safe-Paths-Automerge-"),
    ],
    ids=["respaced", "recased"],
)
def test_collision_check_reads_the_rendered_group_not_the_text(variant):
    """Different text, same group: GitHub ignores the spacing inside an
    expression, and compares group names case-insensitively."""
    caller = CALLER_GROUPS["safe-paths-automerge.yml"]
    other = variant(caller)
    assert other != caller
    assert caller_collisions(other, caller) == [
        "safe-paths-automerge-1-draft",
        "safe-paths-automerge-1-live",
    ]


@pytest.mark.parametrize(
    "group",
    [
        "x-${{ github.run_id }}",
        "x-${{ github.event.pull_request.head.sha }}",
        "x-${{ github.event.pull_request.number",
    ],
    ids=["run-id", "head-sha", "unterminated"],
)
def test_unmodeled_expressions_fail_closed(group):
    with pytest.raises(ValueError):
        render(group, 1, True)


# --- layer 3: the sweep ----------------------------------------------------------


def test_sweep_sees_the_gated_groups():
    # Guards the sweep below: if it stopped seeing these, it would pass vacuously.
    assert {"safe-paths-automerge.yml", "pr-review.yml", "pr-codex-review.yml"} <= set(
        gated_groups(WORKFLOWS_DIR)
    )


def test_every_draft_gated_workflow_splits_its_group():
    assert sweep(WORKFLOWS_DIR) == []


def _copy(tmp_path: pathlib.Path, name: str, text: str) -> pathlib.Path:
    workflows = tmp_path / "workflows"
    workflows.mkdir(exist_ok=True)
    (workflows / name).write_text(text)
    return workflows


def test_sweep_catches_a_draft_gate_added_to_the_verifier(tmp_path):
    """verifier-on-high-risk.yml's unsplit per-PR group is safe only because no
    job there gates on draft: a draft-payload run classifies and posts the same
    check on the same head SHA as a live run would. Gate it with
    `draft == false` and the sweep must object."""
    shipped = (WORKFLOWS_DIR / "verifier-on-high-risk.yml").read_text()
    assert sweep(_copy(tmp_path, "verifier-on-high-risk.yml", shipped)) == []
    anchor = "  verify:\n    name: verifier-evidence-bound-runner\n"
    gated = shipped.replace(
        anchor, anchor + "    if: github.event.pull_request.draft == false\n", 1
    )
    assert gated != shipped, "mutation did not apply; the anchor drifted"
    problems = sweep(_copy(tmp_path, "verifier-on-high-risk.yml", gated))
    assert any("draft-payload run and a live run" in p for p in problems), problems
    assert any("EXPECTED_GROUPS" in p for p in problems), problems


def test_sweep_catches_a_caller_reverted_to_one_group(tmp_path):
    """A caller is gated through the reusable it calls (#116's pr-review.yml)."""
    shipped = (WORKFLOWS_DIR / "pr-review.yml").read_text()
    split = (
        "claude-review-${{ github.event.pull_request.number }}"
        "-${{ github.event.pull_request.draft && 'draft' || 'live' }}"
    )
    reverted = shipped.replace(
        split, "claude-review-${{ github.event.pull_request.number }}", 1
    )
    assert reverted != shipped, "mutation did not apply; the anchor drifted"
    problems = sweep(_copy(tmp_path, "pr-review.yml", reverted))
    assert len(problems) == 1 and "draft-payload run and a live run" in problems[0], (
        problems
    )


@pytest.mark.parametrize(
    "group, problem",
    [
        (CALLER_GROUPS["safe-paths-automerge.yml"], "a group its callers hold"),
        (
            "safe-paths-automerge-job-${{ github.event.pull_request.number }}",
            "draft-payload run and a live run",
        ),
    ],
    ids=["callers-own-group", "unsplit"],
)
def test_sweep_checks_job_level_groups_too(tmp_path, group, problem):
    """The pin reads only the workflow-level group; a job can declare its own."""
    shipped = (WORKFLOWS_DIR / "safe-paths-automerge.yml").read_text()
    assert sweep(_copy(tmp_path, "safe-paths-automerge.yml", shipped)) == []
    anchor = "  safe_paths_automerge:\n    runs-on: ubuntu-latest\n"
    job_group = (
        f"    concurrency:\n      group: {group}\n      cancel-in-progress: true\n"
    )
    mutated = shipped.replace(anchor, anchor + job_group, 1)
    assert mutated != shipped, "mutation did not apply; the anchor drifted"
    problems = sweep(_copy(tmp_path, "safe-paths-automerge.yml", mutated))
    assert len(problems) == 1, problems
    assert "job `safe_paths_automerge`" in problems[0] and problem in problems[0], (
        problems
    )
