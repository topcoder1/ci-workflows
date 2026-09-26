"""The cross-org git credential must never be AUTOMERGE_PAT on a Dependabot-triggered run.

2026-09-25 (independent review of topcoder1/dotclaude#411): a run Dependabot
triggers reads ONLY the repo's Dependabot secret store. Once AUTOMERGE_PAT is
provisioned there, so dependabot-auto-merge.yml can arm as a user and the merge
fires push workflows (whois-api-llc/wxa_vpn#2031), every Dependabot-triggered
workflow that maps the secret receives it. tests-runner.yml and
coverage-floor.yml then wrote it into the insteadOf config that `uv sync` uses
when a caller sets use_pat_for_git_deps: true. The fleet-wide write PAT would be
readable by the install-time code of the very package versions the PR bumped
(whois-api-llc/wxa_sanctions opts in on both). A read-only GIT_DEPS_PAT is still
used there; only the AUTOMERGE_PAT fallback is withheld.

The CROSS_ORG_PAT expression is evaluated here, not string-matched: a small
evaluator for the GitHub Actions expression subset the line uses runs it over
hand-derived contexts, so a precedence slip or a result that is the boolean
`false` fails. `false` in `env` renders as the string "false", which the step
would write into git config as a token. The step's run block is also executed
for the Dependabot notice branch.
"""

import re
import subprocess
from pathlib import Path

import pytest
import yaml

WORKFLOWS = Path(__file__).resolve().parents[1] / ".github" / "workflows"
REUSABLES = ["tests-runner.yml", "coverage-floor.yml"]

# The expression both reusables shipped before this change, kept verbatim as the
# negative control: it hands AUTOMERGE_PAT to a Dependabot-triggered PR run.
PRE_FIX = (
    "((github.event_name == 'push' && github.ref == format('refs/heads/{0}', "
    "github.event.repository.default_branch)) || inputs.use_pat_for_git_deps) "
    "&& (secrets.GIT_DEPS_PAT || secrets.AUTOMERGE_PAT) || ''"
)

# --- evaluator for the GitHub Actions expression subset -------------------------

_TOKEN = re.compile(
    r"\s*(?:(?P<op>\|\||&&|==|!=|!|\(|\)|,)"
    r"|(?P<str>'(?:[^']|'')*')"
    r"|(?P<name>[A-Za-z_][A-Za-z0-9_\-]*(?:\.[A-Za-z_][A-Za-z0-9_\-]*)*))"
)


def _tokens(src):
    pos, out = 0, []
    src = src.strip()
    while pos < len(src):
        m = _TOKEN.match(src, pos)
        if not m or m.end() == pos:
            raise ValueError(f"unsupported expression syntax at {src[pos:]!r}")
        out.append(m)
        pos = m.end()
    return out


def _truthy(v):
    return v not in (False, None, "", 0)


def _eq(a, b):
    if isinstance(a, str) and isinstance(b, str):
        return (
            a.casefold() == b.casefold()
        )  # GitHub compares strings case-insensitively
    if type(a) is type(b):
        return a == b
    raise ValueError(f"cross-type comparison not modelled: {a!r} vs {b!r}")


def evaluate(expr, ctx):
    toks, i = _tokens(expr), 0

    def peek():
        return toks[i] if i < len(toks) else None

    def take(op=None):
        nonlocal i
        t = peek()
        if t is None or (op is not None and t.group("op") != op):
            raise ValueError(f"expected {op!r} in {expr!r}")
        i += 1
        return t

    def lookup(path):
        if path in ("true", "false", "null"):
            return {"true": True, "false": False, "null": None}[path]
        node = ctx
        for part in path.split("."):
            if not isinstance(node, dict):
                return None
            node = next((v for k, v in node.items() if k.lower() == part.lower()), None)
        return node

    def primary():
        t = take()
        if t.group("op") == "(":
            v = or_()
            take(")")
            return v
        if t.group("op") == "!":
            return not _truthy(primary())
        if t.group("str") is not None:
            return t.group("str")[1:-1].replace("''", "'")
        name = t.group("name")
        if name is None:
            raise ValueError(f"unexpected token {t.group(0)!r}")
        if peek() is not None and peek().group("op") == "(":
            if name != "format":
                raise ValueError(f"function {name} not modelled")
            take("(")
            args = [or_()]
            while peek() is not None and peek().group("op") == ",":
                take(",")
                args.append(or_())
            take(")")
            return re.sub(
                r"\{(\d+)\}", lambda m: str(args[1 + int(m.group(1))]), args[0]
            )
        return lookup(name)

    def cmp():
        v = primary()
        while peek() is not None and peek().group("op") in ("==", "!="):
            op = take().group("op")
            r = primary()
            v = _eq(v, r) if op == "==" else not _eq(v, r)
        return v

    def and_():
        v = cmp()
        while peek() is not None and peek().group("op") == "&&":
            take()
            r = cmp()
            v = r if _truthy(v) else v
        return v

    def or_():
        v = and_()
        while peek() is not None and peek().group("op") == "||":
            take()
            r = and_()
            v = v if _truthy(v) else r
        return v

    result = or_()
    if i != len(toks):
        raise ValueError(f"trailing tokens in {expr!r}")
    return result


def test_evaluator_matches_github_semantics():
    ctx = {"a": "x", "e": "", "n": None}
    assert evaluate("'' || 'x'", ctx) == "x"
    assert evaluate("false && 'x'", ctx) is False
    assert evaluate("false || ''", ctx) == ""
    assert evaluate("a && e || 'd'", ctx) == "d"  # && binds tighter than ||
    assert evaluate("'Dependabot[bot]' != 'dependabot[bot]'", ctx) is False
    assert evaluate("format('refs/heads/{0}', a)", ctx) == "refs/heads/x"


# --- the shipped expression --------------------------------------------------------


def _step(workflow):
    doc = yaml.safe_load((WORKFLOWS / workflow).read_text())
    steps = [
        s
        for job in doc["jobs"].values()
        for s in job.get("steps", [])
        if "CROSS_ORG_PAT" in (s.get("env") or {})
    ]
    assert len(steps) == 1, (
        f"{workflow}: expected one step setting CROSS_ORG_PAT, found {len(steps)}"
    )
    return steps[0]


def _expr(workflow):
    raw = _step(workflow)["env"]["CROSS_ORG_PAT"]
    m = re.fullmatch(r"\$\{\{(.*)\}\}", raw.strip(), re.S)
    assert m, f"{workflow}: CROSS_ORG_PAT is not a single expression: {raw!r}"
    return m.group(1)


def _ctx(event, actor, opt_in, git_deps="", automerge="amp", ref=None):
    return {
        "github": {
            "event_name": event,
            "ref": ref
            or ("refs/heads/main" if event == "push" else "refs/pull/9/merge"),
            "actor": actor,
            "event": {"repository": {"default_branch": "main"}},
        },
        "inputs": {"use_pat_for_git_deps": opt_in},
        "secrets": {"GIT_DEPS_PAT": git_deps, "AUTOMERGE_PAT": automerge},
    }


# (event, actor, use_pat_for_git_deps, GIT_DEPS_PAT, AUTOMERGE_PAT, ref) -> expected env value
CASES = [
    (
        "dependabot run, opted in, only AUTOMERGE_PAT",
        ("pull_request", "dependabot[bot]", True, "", "amp", None),
        "",
    ),
    (
        "dependabot run, opted in, GIT_DEPS_PAT wins",
        ("pull_request", "dependabot[bot]", True, "gdp", "amp", None),
        "gdp",
    ),
    (
        "dependabot run, not opted in",
        ("pull_request", "dependabot[bot]", False, "", "amp", None),
        "",
    ),
    ("human PR, opted in", ("pull_request", "alice", True, "", "amp", None), "amp"),
    ("human PR, not opted in", ("pull_request", "alice", False, "", "amp", None), ""),
    (
        "push to the default branch",
        ("push", "topcoder1", False, "", "amp", None),
        "amp",
    ),
    (
        "push to a feature branch",
        ("push", "alice", False, "", "amp", "refs/heads/feature"),
        "",
    ),
    ("nothing forwarded", ("pull_request", "alice", True, "", "", None), ""),
]


@pytest.mark.parametrize("workflow", REUSABLES)
@pytest.mark.parametrize("case", CASES, ids=[c[0] for c in CASES])
def test_cross_org_pat_value(workflow, case):
    _, (event, actor, opt_in, gdp, amp, ref), expected = case
    got = evaluate(_expr(workflow), _ctx(event, actor, opt_in, gdp, amp, ref))
    assert got == expected and isinstance(got, str), (
        f"{workflow}: CROSS_ORG_PAT evaluated to {got!r}, expected {expected!r}"
    )


def test_negative_control_pre_fix_expression_leaks_to_dependabot():
    assert evaluate(PRE_FIX, _ctx("pull_request", "dependabot[bot]", True)) == "amp"


@pytest.mark.parametrize("workflow", REUSABLES)
def test_dependabot_run_explains_the_withheld_fallback(workflow, tmp_path):
    step = _step(workflow)
    base = {
        "PATH": "/usr/bin:/bin",
        "RUNNER_TEMP": str(tmp_path),
        "CROSS_ORG_PAT": "",
        "PAT_FORWARDED": "true",
    }
    out = {}
    for flag in ("true", "false"):
        proc = subprocess.run(
            ["bash", "-c", step["run"]],
            env={**base, "DEPENDABOT_RUN": flag},
            capture_output=True,
            text=True,
            stdin=subprocess.DEVNULL,
        )
        assert proc.returncode == 0, proc.stderr
        out[flag] = proc.stdout
    assert not (tmp_path / "cross-org-gitconfig").exists(), (
        "wrote a credential config with no credential"
    )
    assert (
        "Dependabot-triggered run" in out["true"] and "--app dependabot" in out["true"]
    ), out["true"]
    assert "Dependabot-triggered run" not in out["false"], out["false"]
