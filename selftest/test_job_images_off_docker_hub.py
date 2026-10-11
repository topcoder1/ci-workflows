"""Guard: no job in this repo's workflows sends a default or bare image name to
Docker Hub.

2026-10-09: dotclaude#479 (run 37991904725) and #485 failed "coverage-floor /
Measure coverage and enforce floor" before the job's first step. `docker pull
postgres:16` got `toomanyrequests: You have reached your unauthenticated pull
rate limit` on every try, then `Docker pull failed with exit code 1`. Docker
Hub rate-limits anonymous pulls per IP and GitHub-hosted runners share egress
IPs, so a bare Docker Hub name can fail any run, and coverage-floor.yml starts
its postgres and redis services on every run of every caller (that run had
services_postgres: false).

coverage-floor.yml now pulls a bare name, its own default or one a caller
passes, from Google's Docker Hub mirror (mirror.gcr.io/library/...), which
needs no credential. A reference with a `/` (a registry, or a Docker Hub
namespace such as pgvector/pgvector) is pulled exactly as given: GitHub's
expression language cannot split a string to tell the two apart.

Each service also starts only when its services_* input is true: switched off,
its image is '' and nothing is pulled at all (test_coverage_floor_services.py
pins that). So the guard and REQUIRED switch a service on before asking where
its image comes from.

Two layers:

1. The guard (`docker_hub_pulls`) resolves every image a job pulls (each
   service's image, the job container, each `docker://` step) by evaluating
   its expression with an empty `inputs` (this repo's own pull_request and
   push runs), with the declared defaults, and with caller-passed bare names.
   It fails on any result Docker would fetch from Docker Hub. Literals alone
   are not enough: `inputs.postgres_image || 'mirror.gcr.io/library/postgres:16'`
   holds only mirrored literals and still sends a caller's `postgres:16` to
   Docker Hub.
2. REQUIRED hardcodes the coverage-floor services and what each resolves to,
   so a guard that finds nothing, or a mirror typo the generic rule cannot
   see, fails too. Mutations of the shipped workflow and synthetic fixtures
   are the negative controls.
"""

import pathlib
import re

import pytest
import yaml

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
WORKFLOWS_DIR = REPO_ROOT / ".github" / "workflows"
COVERAGE_FLOOR = WORKFLOWS_DIR / "coverage-floor.yml"

MIRROR = "mirror.gcr.io/library/"

# Hosts Docker resolves to Docker Hub when a reference names one explicitly.
_DOCKER_HUB_HOSTS = {
    "docker.io",
    "index.docker.io",
    "registry-1.docker.io",
    "registry.hub.docker.com",
}


def is_docker_hub(ref: str) -> bool:
    """True when `docker pull <ref>` fetches from Docker Hub.

    Docker's rule (distribution/reference): the first path component names a
    registry only when it contains '.' or ':', is 'localhost', or has an
    uppercase letter. Otherwise the whole reference lives on Docker Hub, under
    library/ when it has no '/' at all.
    """
    if not ref:
        return False  # an empty image starts no container
    host, slash, _ = ref.partition("/")
    if slash and (
        "." in host or ":" in host or host == "localhost" or host != host.lower()
    ):
        return host.lower() in _DOCKER_HUB_HOSTS
    return True


# --- the subset of GitHub's expression language image fields use -----------

_TOKEN = re.compile(r"\s*('(?:[^']|'')*'|\|\||&&|\}\}|[!(),.]|[A-Za-z_][\w-]*)")


def _to_str(value) -> str:
    if value is None:
        return ""
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, str):
        return value
    raise ValueError(f"no string form modeled for {value!r}")


def _format(fmt, *args) -> str:
    def sub(m):
        if m.group(1) is None:
            return m.group(0)[0]  # '{{' -> '{', '}}' -> '}'
        return _to_str(args[int(m.group(1))])

    return re.sub(r"\{\{|\}\}|\{(\d+)\}", sub, _to_str(fmt))


_FUNCTIONS = {
    # String comparisons in GitHub expressions ignore case.
    "contains": lambda s, v: _to_str(v).lower() in _to_str(s).lower(),
    "startswith": lambda s, v: _to_str(s).lower().startswith(_to_str(v).lower()),
    "endswith": lambda s, v: _to_str(s).lower().endswith(_to_str(v).lower()),
    "format": _format,
}


class _Expr:
    """Evaluates one `${{ ... }}` body. Syntax outside the subset raises, so an
    image expression this guard cannot read fails the test instead of passing
    unread."""

    def __init__(self, text: str, pos: int, inputs: dict):
        self.text, self.pos, self.inputs = text, pos, inputs
        self._advance()

    def _advance(self):
        m = _TOKEN.match(self.text, self.pos)
        if not m:
            raise ValueError(
                f"unsupported expression syntax: {self.text[self.pos :]!r}"
            )
        self.tok, self.pos = m.group(1), m.end()

    def _expect(self, tok):
        if self.tok != tok:
            raise ValueError(f"expected {tok!r}, got {self.tok!r} in {self.text!r}")
        self._advance()

    def parse(self):
        value = self._or()
        if self.tok != "}}":
            raise ValueError(f"expected '}}}}', got {self.tok!r} in {self.text!r}")
        return value, self.pos

    # `||` and `&&` return an operand, not a bool, as in GitHub.
    def _or(self):
        value = self._and()
        while self.tok == "||":
            self._advance()
            rhs = self._and()
            value = value if value else rhs
        return value

    def _and(self):
        value = self._not()
        while self.tok == "&&":
            self._advance()
            rhs = self._not()
            value = rhs if value else value
        return value

    def _not(self):
        if self.tok == "!":
            self._advance()
            return not self._not()
        return self._primary()

    def _primary(self):
        tok = self.tok
        self._advance()
        if tok == "(":
            value = self._or()
            self._expect(")")
            return value
        if tok.startswith("'"):
            return tok[1:-1].replace("''", "'")
        if not re.fullmatch(r"[A-Za-z_][\w-]*", tok):
            raise ValueError(f"unexpected {tok!r} in {self.text!r}")
        name = tok.lower()
        if name in ("true", "false", "null"):
            return {"true": True, "false": False, "null": None}[name]
        if self.tok == "(":
            if name not in _FUNCTIONS:
                raise ValueError(f"function {tok}() is not modeled")
            self._advance()
            args = [] if self.tok == ")" else [self._or()]
            while self.tok == ",":
                self._advance()
                args.append(self._or())
            self._expect(")")
            return _FUNCTIONS[name](*args)
        if name != "inputs":
            raise ValueError(f"context {tok!r} is not modeled; only inputs.* is")
        self._expect(".")
        prop = self.tok
        self._advance()
        return self.inputs.get(prop.lower())


def resolve(template: str, inputs: dict) -> str:
    """The string GitHub hands to `docker pull` for this field."""
    # GitHub looks up context properties case-insensitively.
    inputs = {name.lower(): value for name, value in inputs.items()}
    out, i = [], 0
    while (start := template.find("${{", i)) != -1:
        out.append(template[i:start])
        value, i = _Expr(template, start + 3, inputs).parse()
        out.append(_to_str(value))
    out.append(template[i:])
    return "".join(out)


# --- the guard ---------------------------------------------------------------

# Names a caller might pass for a service image. Each must resolve off Docker Hub.
BARE_SAMPLES = (
    "postgres:16",
    "redis:7",
    "postgres:16-alpine",
    "postgres",
    "mysql:8.4",
    "postgres@sha256:" + "0" * 64,
)


def image_slots(workflow: dict):
    """(job, slot, template) for every image a job pulls."""
    for job_id, job in (workflow.get("jobs") or {}).items():
        for service_id, service in (job.get("services") or {}).items():
            if isinstance(service, dict):
                service = service.get("image", "")
            yield job_id, f"services.{service_id}", str(service)
        container = job.get("container")
        if isinstance(container, dict):
            container = container.get("image", "")
        if container is not None:
            yield job_id, "container", str(container)
        for i, step in enumerate(job.get("steps") or []):
            uses = str(step.get("uses", ""))
            if uses.startswith("docker://"):
                yield job_id, f"steps[{i}]", uses[len("docker://") :]


def _declared_inputs(workflow: dict) -> dict:
    on = workflow.get("on", workflow.get(True))
    call = on.get("workflow_call") if isinstance(on, dict) else None
    return (call or {}).get("inputs") or {}


def _scenarios(template: str, declared: dict):
    defaults = {name: spec.get("default") for name, spec in declared.items()}
    names = sorted(set(re.findall(r"inputs\.([A-Za-z_][\w-]*)", template, re.I)))
    # A boolean input an image reads switches its service on or off. A caller
    # that passes an image uses that service, so those scenarios switch it on;
    # left off, the image is '' and nothing is pulled.
    on = {
        name: True
        for name in names
        if (declared.get(name) or {}).get("type") == "boolean"
    }
    yield "inputs empty (this repo's own runs)", {}
    yield "caller passes nothing (declared defaults)", defaults
    if on:
        yield f"caller switches on {', '.join(on)}", {**defaults, **on}
    for name in names:
        if (declared.get(name) or {}).get("type", "string") != "string":
            continue
        for sample in BARE_SAMPLES:
            yield f"caller passes {name}: {sample}", {**defaults, **on, name: sample}


def docker_hub_pulls(text: str) -> list:
    """Every (slot, scenario) that resolves to a Docker Hub image."""
    workflow = yaml.safe_load(text)
    declared = _declared_inputs(workflow)
    found = []
    for job_id, slot, template in image_slots(workflow):
        for label, inputs in _scenarios(template, declared):
            ref = resolve(template, inputs)
            if is_docker_hub(ref):
                found.append(f"jobs.{job_id}.{slot}: {label} -> {ref}")
    return found


# The image slots known to exist, the input that switches each service on, the
# input that feeds its image, and what a caller value resolves to once the
# service is on (None = no image input). Hardcoded, never read from the
# workflow: derived expectations cannot fail when the workflow narrows.
REQUIRED = {
    ("coverage-floor.yml", "measure", "services.postgres"): (
        "services_postgres",
        "postgres_image",
        {
            None: MIRROR + "postgres:16",
            "": MIRROR + "postgres:16",
            "postgres:16": MIRROR + "postgres:16",
            "postgres:15-alpine": MIRROR + "postgres:15-alpine",
            # Pulled as given; a caller needing pgvector passes the mirror form.
            "pgvector/pgvector:pg16": "pgvector/pgvector:pg16",
            "mirror.gcr.io/pgvector/pgvector:pg16": "mirror.gcr.io/pgvector/pgvector:pg16",
            "ghcr.io/acme/postgres:16": "ghcr.io/acme/postgres:16",
        },
    ),
    ("coverage-floor.yml", "measure", "services.redis"): (
        "services_redis",
        "redis_image",
        {
            None: MIRROR + "redis:7",
            "": MIRROR + "redis:7",
            "redis:7": MIRROR + "redis:7",
            "redis:7-alpine": MIRROR + "redis:7-alpine",
            "ghcr.io/acme/redis:7": "ghcr.io/acme/redis:7",
        },
    ),
}


def _check_required(workflow_name: str, text: str) -> None:
    slots = {
        (job_id, slot): template
        for job_id, slot, template in image_slots(yaml.safe_load(text))
    }
    for (name, job_id, slot), (switch, input_name, cases) in REQUIRED.items():
        if name != workflow_name:
            continue
        assert (job_id, slot) in slots, (
            f"{name}: jobs.{job_id}.{slot} not found; the guard must find the "
            "images it is known to check"
        )
        for value, want in cases.items():
            inputs = (
                {switch: True} if value is None else {switch: True, input_name: value}
            )
            got = resolve(slots[(job_id, slot)], inputs)
            assert got == want, (
                f"{name} jobs.{job_id}.{slot}: {input_name}={value!r} -> {got!r}, want {want!r}"
            )


def _check(workflow_name: str, text: str) -> None:
    found = docker_hub_pulls(text)
    assert not found, f"{workflow_name} pulls from Docker Hub:\n" + "\n".join(found)
    _check_required(workflow_name, text)


_WORKFLOWS = sorted([*WORKFLOWS_DIR.glob("*.yml"), *WORKFLOWS_DIR.glob("*.yaml")])


def test_the_scan_covers_the_workflows_it_must():
    names = {p.name for p in _WORKFLOWS}
    assert {name for name, _, _ in REQUIRED} <= names


@pytest.mark.parametrize("path", _WORKFLOWS, ids=lambda p: p.name)
def test_no_job_pulls_from_docker_hub(path):
    _check(path.name, path.read_text())


# --- negative controls: the guard fails when the shipped workflow regresses --

_POSTGRES_IMAGE = re.compile(r"^(?P<indent>[ \t]+)image: .*postgres_image.*$", re.M)


def _set_postgres_image(text: str, expr: str) -> str:
    return _POSTGRES_IMAGE.sub(
        lambda m: f"{m.group('indent')}image: {expr}", text, count=1
    )


def _back_to_docker_hub(t):
    return _set_postgres_image(t, "${{ inputs.postgres_image || 'postgres:16' }}")


def _mirror_only_the_default(t):
    # The declared default is mirrored too, so only a name a caller passes
    # still reaches Docker Hub.
    t = t.replace(
        'default: "postgres:16"', 'default: "mirror.gcr.io/library/postgres:16"'
    )
    return _set_postgres_image(
        t, "${{ inputs.postgres_image || 'mirror.gcr.io/library/postgres:16' }}"
    )


def _prefix_every_reference(t):
    return _set_postgres_image(
        t,
        "${{ format('mirror.gcr.io/library/{0}', inputs.postgres_image || 'postgres:16') }}",
    )


def _typo_in_mirror(t):
    return t.replace("mirror.gcr.io/library/", "mirror.gcr.io/libary/")


def _service_renamed_out_of_view(t):
    return re.sub(
        r"^([ \t]+)postgres:\n([ \t]+image:)", r"\1pg:\n\2", t, count=1, flags=re.M
    )


@pytest.mark.parametrize(
    "mutate, why",
    [
        (_back_to_docker_hub, r"inputs empty \(this repo's own runs\) -> postgres:16"),
        (
            _mirror_only_the_default,
            r"caller passes postgres_image: postgres:16 -> postgres:16",
        ),
        (_prefix_every_reference, r"-> 'mirror\.gcr\.io/library/pgvector/pgvector"),
        (_typo_in_mirror, r"-> 'mirror\.gcr\.io/libary/postgres:16'"),
        (_service_renamed_out_of_view, r"services\.postgres not found"),
    ],
    ids=[
        "bare-default-again",
        "caller-name-passes-through",
        "registry-refs-prefixed-too",
        "typo-in-mirror-path",
        "required-slot-missing",
    ],
)
def test_guard_catches_each_regression(mutate, why):
    """A guard that reads the artifact it checks must be shown to fail when
    that artifact narrows, and for the reason the mutation names."""
    text = COVERAGE_FLOOR.read_text()
    mutated = mutate(text)
    assert mutated != text, "mutation did not apply; the anchor drifted"
    with pytest.raises(AssertionError, match=why):
        _check(COVERAGE_FLOOR.name, mutated)


# --- every slot kind, on fixtures the real workflows do not contain ----------

_FIXTURE = """
on:
  workflow_call:
    inputs:
      db_image:
        type: string
        default: postgres:16
jobs:
  literal:
    runs-on: ubuntu-latest
    services:
      db: {image: postgres:16}
      cache: {image: bitnami/redis:7}
      hub: {image: docker.io/library/redis:7}
      short: "postgres:16"
  passthrough:
    runs-on: ubuntu-latest
    services:
      db: {image: "${{ inputs.db_image }}"}
  container-string:
    runs-on: ubuntu-latest
    container: node:20
  container-mapping:
    runs-on: ubuntu-latest
    container: {image: "python:3.13"}
  docker-step:
    runs-on: ubuntu-latest
    steps:
      - uses: docker://alpine:3.20
"""

_CLEAN_FIXTURE = """
on: [pull_request]
jobs:
  clean:
    runs-on: ubuntu-latest
    services:
      db: {image: mirror.gcr.io/library/postgres:16}
      cache: {image: "ghcr.io/acme/redis:7"}
      off: {image: ""}
    container: {image: public.ecr.aws/docker/library/node:20}
    steps:
      - uses: docker://localhost:5000/tool:1
      - uses: actions/checkout@v7
"""


def test_every_slot_kind_is_flagged():
    found = docker_hub_pulls(_FIXTURE)
    flagged = {line.split(":")[0] for line in found}
    assert flagged == {
        "jobs.literal.services.db",
        "jobs.literal.services.cache",
        "jobs.literal.services.hub",
        "jobs.literal.services.short",
        "jobs.passthrough.services.db",
        "jobs.container-string.container",
        "jobs.container-mapping.container",
        "jobs.docker-step.steps[0]",
    }, found
    # The pass-through is caught for the declared default and for each bare
    # name a caller might pass, not only once.
    assert sum(line.startswith("jobs.passthrough.") for line in found) == 1 + len(
        BARE_SAMPLES
    ), found
    # Input names match case-insensitively, as in GitHub.
    recased = _FIXTURE.replace("inputs.db_image", "inputs.DB_Image")
    assert sum(
        line.startswith("jobs.passthrough.") for line in docker_hub_pulls(recased)
    ) == 1 + len(BARE_SAMPLES)


def test_clean_fixture_passes():
    assert docker_hub_pulls(_CLEAN_FIXTURE) == []


@pytest.mark.parametrize(
    "ref, on_hub",
    [
        ("postgres:16", True),
        ("postgres", True),
        ("library/postgres:16", True),
        ("pgvector/pgvector:pg16", True),
        ("docker.io/library/postgres:16", True),
        ("index.docker.io/library/redis:7", True),
        ("registry-1.docker.io/library/redis", True),
        ("postgres@sha256:" + "0" * 64, True),
        (MIRROR + "postgres:16", False),
        ("mirror.gcr.io/pgvector/pgvector:pg16", False),
        ("public.ecr.aws/docker/library/postgres:16", False),
        ("ghcr.io/acme/postgres:16", False),
        ("localhost/tool:1", False),
        ("localhost:5000/tool:1", False),
        ("", False),
    ],
)
def test_is_docker_hub(ref, on_hub):
    assert is_docker_hub(ref) is on_hub


@pytest.mark.parametrize(
    "template, inputs, want",
    [
        ("${{ inputs.x || 'd' }}", {}, "d"),
        ("${{ inputs.x || 'd' }}", {"x": ""}, "d"),
        ("${{ inputs.x && 'yes' || 'no' }}", {"x": "v"}, "yes"),
        ("${{ !contains(inputs.x, '/') }}", {"x": "a/b"}, "false"),
        ("${{ contains('ABC', 'b') }}", {}, "true"),
        ("${{ startsWith('Mirror.gcr.io/x', 'mirror.') }}", {}, "true"),
        ("${{ format('p/{0}-{{1}}', 'x') }}", {}, "p/x-{1}"),
        ("a-${{ inputs.x }}-b", {"x": "v"}, "a-v-b"),
        ("${{ 'it''s' }}", {}, "it's"),
    ],
)
def test_expression_subset_matches_github_semantics(template, inputs, want):
    assert resolve(template, inputs) == want


@pytest.mark.parametrize(
    "template",
    [
        "${{ inputs.x == 'postgres' }}",
        "${{ matrix.image }}",
        "${{ toJSON(inputs) }}",
        "${{ inputs.x",
    ],
)
def test_unmodeled_syntax_fails_closed(template):
    with pytest.raises(ValueError):
        resolve(template, {"x": "postgres"})
