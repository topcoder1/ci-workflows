#!/usr/bin/env python3
"""Enforce: a workflow gated on `draft == false` MUST listen for `ready_for_review`.

WHY THIS EXISTS
---------------
A workflow whose job gates on `if: github.event.pull_request.draft == false`, but whose
`on.pull_request.types` omits `ready_for_review`, FAILS OPEN:

    1. PR opened as a draft  -> `opened` fires          -> job skips on the gate (correct)
    2. `gh pr ready`         -> `ready_for_review` fires -> caller is not listening
    3. nothing runs; the check stays `skipped`

GitHub counts a **skipped REQUIRED context as SATISFIED**, so the PR merges green and
UNREVIEWED. Fleet policy makes DRAFT the standard auto-merge opt-out, so every
manual-merge PR is draft->ready -- the recommended workflow was the one guaranteed to skip
the review. (It can also fail CLOSED, leaving a PR stuck on "Expected -- Waiting for status
to be reported", when no draft-phase run fired at all: domain-rank#33.)

WHY A CHECK AND NOT A COMMENT
-----------------------------
This exact mistake has been made twice fleet-wide: `reopened` was dropped first, then
`ready_for_review` was dropped *directly below the comment warning about `reopened`*. A
comment did not prevent the recurrence. And fixing it centrally does not fix consumers:
ci-workflows#115 and dotclaude#156 both landed 2026-07-15, yet a sweep on 2026-07-16 still
found 21 installed repos vulnerable, because neither central fix is retroactive. This check
runs inside the `lint.yml` reusable, against the CALLER's workflows, so installed-repo drift
is caught on every PR rather than by a periodic manual audit.

WHY IT PARSES INSTEAD OF GREPPING
---------------------------------
The transitive case is the one that bites: a caller like `pr-review.yml` contains NO `draft`
expression anywhere -- the gate lives in the reusable it calls. Grepping the caller cannot
see it. An explicit `types:` list is a DENYLIST BY OMISSION, and GitHub's default types
(opened/synchronize/reopened) exclude `ready_for_review`, so an ABSENT list is unsafe too.

Usage:
    check_draft_gate_triggers.py <workflows-dir> [--extra-reusable name.yml ...]

Exits 0 when clean, 1 when any violation is found (annotated for GitHub Actions).
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import yaml

# GitHub's default `pull_request` activity types. `ready_for_review` is NOT among them --
# which is why an absent `types:` list is not a safe default for a draft-gated workflow.
GITHUB_DEFAULT_PR_TYPES: tuple[str, ...] = ("opened", "synchronize", "reopened")

# Reusables in topcoder1/ci-workflows whose jobs gate on `draft == false`. A caller inherits
# that gate transitively. Kept in sync with the repo by test_registry_matches_repo in
# selftest/test_check_draft_gate_triggers.py, which fails if a new draft-gating reusable is
# added here without being registered -- so the registry cannot silently rot.
DRAFT_GATED_REUSABLES: frozenset[str] = frozenset(
    {
        "claude-review.yml",
        "claude-author-automerge.yml",
        "safe-paths-automerge.yml",
        "codex-review.yml",
        "claude-adversarial-review.yml",
    }
)

DRAFT_GATE_EXPR = "draft == false"


def load_workflow(path: Path) -> dict | None:
    try:
        doc = yaml.safe_load(path.read_text())
    except yaml.YAMLError:
        return None  # actionlint owns YAML validity; don't double-report
    return doc if isinstance(doc, dict) else None


def triggers(workflow: dict) -> dict:
    """Return the `on:` block.

    PyYAML resolves the bare key `on:` to the boolean True (YAML 1.1 truthiness), so
    `workflow["on"]` is a KeyError on every real GitHub workflow. Accept every spelling
    rather than silently reading nothing and passing vacuously.
    """
    for key in (True, "on", "On", "ON"):
        if key in workflow:
            raw = workflow[key]
            break
    else:
        return {}
    if isinstance(raw, str):
        return {raw: {}}
    if isinstance(raw, list):
        return {str(k): {} for k in raw}
    return raw if isinstance(raw, dict) else {}


def pr_types(workflow: dict) -> tuple[str, ...]:
    pull_request = triggers(workflow).get("pull_request")
    if not isinstance(pull_request, dict):
        return GITHUB_DEFAULT_PR_TYPES
    types = pull_request.get("types")
    if isinstance(types, list) and types:
        return tuple(str(t) for t in types)
    return GITHUB_DEFAULT_PR_TYPES


def draft_gate_reason(workflow: dict, reusables: frozenset[str]) -> str | None:
    """Why this workflow is draft-gated, or None. Checks own jobs AND called reusables."""
    jobs = workflow.get("jobs")
    if not isinstance(jobs, dict):
        return None
    for job_id, job in jobs.items():
        if not isinstance(job, dict):
            continue
        if DRAFT_GATE_EXPR in str(job.get("if", "")):
            return f"job `{job_id}` gates on `{DRAFT_GATE_EXPR}`"
        uses = job.get("uses")
        if isinstance(uses, str):
            base = uses.split("@")[0].rsplit("/", 1)[-1]
            if base in reusables:
                return f"job `{job_id}` calls `{base}`, which gates on `{DRAFT_GATE_EXPR}`"
    return None


def check_dir(workflows_dir: Path, reusables: frozenset[str]) -> list[str]:
    violations: list[str] = []
    files = sorted(workflows_dir.glob("*.yml")) + sorted(workflows_dir.glob("*.yaml"))
    for path in files:
        workflow = load_workflow(path)
        if workflow is None:
            continue
        if "pull_request" not in triggers(workflow):
            continue
        reason = draft_gate_reason(workflow, reusables)
        if reason is None:
            continue
        types = pr_types(workflow)
        if "ready_for_review" in types:
            continue
        pull_request = triggers(workflow).get("pull_request")
        has_explicit_types = (
            isinstance(pull_request, dict)
            and isinstance(pull_request.get("types"), list)
            and bool(pull_request["types"])
        )
        listed = (
            f"types: {list(types)}"
            if has_explicit_types
            else f"no explicit `types:` list, so GitHub's defaults apply: {list(types)}"
        )
        violations.append(
            f"{path.name}: {reason}, but does not listen for `ready_for_review` "
            f"({listed}). A draft PR skips that job at `opened`, and `gh pr ready` would "
            f"fire nothing this workflow hears -- so its check reports `skipped`, which "
            f"GitHub counts as a SATISFIED required context, and the PR merges green and "
            f"unreviewed. Fix: add `ready_for_review` to the types list. "
            f"See ci-workflows#115, domain-rank#35."
        )
    return violations


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("workflows_dir", type=Path)
    parser.add_argument(
        "--extra-reusable",
        action="append",
        default=[],
        help="Additional draft-gating reusable filename to treat as transitive.",
    )
    args = parser.parse_args(argv)

    if not args.workflows_dir.is_dir():
        # Not an error: plenty of repos have no workflows dir.
        print(f"no workflows directory at {args.workflows_dir}; nothing to check")
        return 0

    reusables = DRAFT_GATED_REUSABLES | set(args.extra_reusable)
    violations = check_dir(args.workflows_dir, reusables)

    for v in violations:
        print(f"::error file=.github/workflows/{v.split(':')[0]}::{v}")
    if violations:
        print(
            f"\n{len(violations)} workflow(s) gate on `{DRAFT_GATE_EXPR}` without listening "
            f"for `ready_for_review`. This FAILS OPEN: the required check reports `skipped`, "
            f"which GitHub counts as satisfied, so the PR merges unreviewed."
        )
        return 1

    print("OK: every draft-gated workflow listens for `ready_for_review`")
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
