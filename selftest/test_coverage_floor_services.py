"""Guard: coverage-floor.yml starts a service container only when asked.

2026-10-09: both service images were unconditional, so every caller pulled
postgres:16 and redis:7 from Docker Hub on every run, although
services_postgres / services_redis gated only what the tests saw (the
DATABASE_URL / REDIS_URL exports). Docker Hub's unauthenticated pull limit
then failed the job before it measured anything (dotclaude#485, twice), and
coverage-floor is a required check in nine repos. One caller of seventeen
(inbox_superpilot) opts in; the other sixteen pulled two images they never
used.

GitHub skips a service whose image is an empty string, so each image is gated
on its input. The image expressions are rendered here the way Actions renders
them (the evaluator in test_automerge_standing_arm_revoke.py), with the inputs
a caller gets: the workflow's declared defaults, the caller's values on top.
The expected images are hardcoded.
"""

import pathlib

import pytest
import yaml

from selftest.test_automerge_standing_arm_revoke import substitute

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "coverage-floor.yml"


def _images(caller):
    """Each service's image, as Actions renders it for a caller passing `caller`."""
    workflow = yaml.safe_load(WORKFLOW.read_text())
    declared = workflow.get("on", workflow.get(True))["workflow_call"]["inputs"]
    inputs = {name: spec.get("default") for name, spec in declared.items()}
    inputs.update(caller)
    services = workflow["jobs"]["measure"]["services"]
    return {
        name: substitute(service["image"], {"inputs": inputs})
        for name, service in services.items()
    }


@pytest.mark.parametrize(
    "caller, expected",
    [
        # Sixteen of the seventeen callers set neither input: nothing is pulled.
        ({}, {"postgres": "", "redis": ""}),
        # An image alone does not start its service.
        (
            {"postgres_image": "pgvector/pgvector:pg16", "redis_image": "redis:7"},
            {"postgres": "", "redis": ""},
        ),
        ({"services_postgres": True}, {"postgres": "postgres:16", "redis": ""}),
        ({"services_redis": True}, {"postgres": "", "redis": "redis:7"}),
        # inbox_superpilot's caller.
        (
            {
                "services_postgres": True,
                "services_redis": True,
                "postgres_image": "pgvector/pgvector:pg16",
            },
            {"postgres": "pgvector/pgvector:pg16", "redis": "redis:7"},
        ),
        # An empty image input still falls back to the default image.
        (
            {
                "services_postgres": True,
                "postgres_image": "",
                "services_redis": True,
                "redis_image": "",
            },
            {"postgres": "postgres:16", "redis": "redis:7"},
        ),
    ],
)
def test_a_service_starts_only_when_its_input_asks(caller, expected):
    assert _images(caller) == expected
