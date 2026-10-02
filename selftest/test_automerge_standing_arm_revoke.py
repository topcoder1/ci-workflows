"""A risk-tier verdict must revoke a standing auto-merge arm.

GitHub keeps an auto-merge arm across later pushes by users with write
access. When a Claude-authored PR's diff touches a risk-tier path
(src/auth/login.py, a migration, a workflow) and neither bypass releases it,
claude-author-automerge.yml's "Comment + skip when risky" posts "Auto-merge
blocked — risk-tier paths touched" and the decision label reads
automerge:blocked-risk-tier. Nothing disarmed, though: the quiet gate and the
arm step are skipped on that verdict, and the error revoke fires only on a
failed step. So a PR armed on an earlier, clean revision kept the arm when a
later push added the risk-tier path, and merged it unreviewed once checks went
green. The classifier verdict has always had "Revoke auto-merge if classifier
blocked"; the regex verdict now has "Revoke auto-merge if risk-tier blocked".

Every case runs the job the way Actions does: the SHIPPED steps in order, each
step's SHIPPED `if:`, `env:` and `run:` expressions evaluated against the event
and the outputs of the steps before it, and each run block executed under
`bash -e` against a gh stub that holds one pull request's state (files,
labels, comments, timeline, the auto-merge arm) across the runs of a case.
Nothing here mirrors the workflow's wiring, so a condition, an env mapping or
a token that drifts changes the verdict. The quiet gate is switched off
(`findings_quiet_minutes: 0`): it never runs on a risky, unbypassed verdict,
and on the bypass paths it only delays the arm.

1. The gap: a Claude PR armed by the shipped enable step on a clean revision
   loses that arm when its next push adds src/auth/login.py. The new step
   disarms it once, as github-actions[bot], and the sticky comment and
   automerge:blocked-risk-tier follow. An unarmed risky PR passes the same
   idempotent revoke with a green run.
2. Only this workflow's own bypasses keep the arm, with no disarm attempted:
   the bypass label (Option A), a SUCCESS from the configured Codex check
   (Option B), and `risk_main_go: false` for a main.go change. Controls: a
   failed or absent Codex check, and the default risk_main_go, revoke. A
   re-run of an event from before the bypass label landed replays that
   event's label snapshot; the live label still keeps the arm (and the
   comment is not refreshed over it), a near-match label releases nothing,
   a bypass label input with a stray newline releases nothing, and an
   unreadable live label set still revokes.
3. The hold step: the disarm is recorded as github-actions[bot], which the
   manual-hold Signal 2 ignores, so when a human then applies the bypass label
   the PR re-arms instead of sitting on a phantom human hold. A hold label
   still revokes through the hold step alone, and that run clears the
   decision labels. The arm step's own disarms are recorded the same way: a
   pre-arm stand-down (a retargeted base, or one it cannot read) and the
   removal of a bot's arm each leave the PR's newest auto-merge event, and a
   later clean push still re-arms. They try github-actions[bot] three times,
   so a transient failure does not reach the PAT, which is the fallback
   only, for a bot that cannot disarm.
4. Fail closed: only OFF counts. An arm still ON after the disarm, or an arm
   state that cannot be read, fails the step, the always() error revoke
   retries the disarm, and the decision label is not published, so the
   announcement never outruns the enforcement. A failed Option B probe (an
   HTML 5xx body jq cannot parse) skips the step under implicit success(),
   and the error revoke disarms instead: an unreadable check released
   nothing.
5. Ownership: a real SHA that differs from the event's head leaves the verdict
   to the newer head's run (no disarm, no label, no comment), including a
   push that lands while the live labels are read: the head check sits
   immediately before the disarm. An HTTP error body from the head read,
   which gh api prints to stdout, is not a moved head: it skips neither the
   revoke nor the error revoke's retry.
6. Negative controls: each property above fails on a workflow mutated to break
   it: the step removed (the workflow before this fix), the Codex clause
   dropped, the PAT disarming, either guard trusting any answer, a
   verification that only rejects ON, the live bypass-label check disabled,
   failing open, or matching by substring or by `grep -xF`, the head check
   placed before the label read, the comment posting without a verified
   revoke, the error revoke ignoring a failed Option B probe, and the arm
   step disarming under GH_TOKEN (the PAT), with a single bot attempt, or
   with no PAT fallback.
7. The arm binds to the head the risk-tier step LISTED: a head that went
   A → B before that listing and back to A before the arm (where
   --match-head-commit sees the event's head A again) is not armed on a
   verdict about B's files.
"""

import copy
import json
import math
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "claude-author-automerge.yml"

DOC = yaml.safe_load(WORKFLOW.read_text())
# PyYAML reads the bare `on:` key as the boolean True (YAML 1.1).
TRIGGER = DOC.get("on", DOC.get(True))
INPUT_DEFAULTS = {
    name: spec.get("default", "")
    for name, spec in TRIGGER["workflow_call"]["inputs"].items()
}
JOB = DOC["jobs"]["automerge"]
STEPS = JOB["steps"]

REPO = "acme/fixture"
PR_NUMBER = 7
PR_URL = f"https://github.com/{REPO}/pull/{PR_NUMBER}"
GITHUB_TOKEN = "ghs_stub"  # github.token: acts as github-actions[bot]
PAT = "pat_stub"  # secrets.automerge_pat: acts as its user, pat-user
NEW_HEAD = "b" * 40  # a head pushed while a run is still deciding
BYPASS_LABEL = INPUT_DEFAULTS["risk_bypass_label"]
HOLD_LABEL = INPUT_DEFAULTS["hold_label"]
CODEX_CHECK = "review / Codex Review"
RISK_LABEL = "automerge:blocked-risk-tier"
RISK_MARKER = "<!-- claude-author-automerge:risk-tier -->"

REVOKE = "risk_revoke"
ARM = "arm"
RISK_COMMENT = "Comment + skip when risky"
HOLD_REVOKE = "Revoke auto-merge on hold label"
ERROR_REVOKE = "Revoke auto-merge if gates errored"

# ---------------------------------------------------------------------------
# GitHub expressions, for the subset this workflow uses: literals, context
# paths, ! == != && || and parentheses, the status functions, toJson and
# startsWith. Anything else raises, so a new construct in the workflow fails
# this test loudly instead of evaluating wrong.
# ---------------------------------------------------------------------------
_LEX = re.compile(
    r"\s*(?:(?P<str>'(?:[^']|'')*')"
    r"|(?P<num>\d+(?:\.\d+)?)"
    r"|(?P<op>&&|\|\||==|!=|!|\(|\)|,)"
    r"|(?P<name>[A-Za-z_][\w-]*(?:\.[A-Za-z_][\w-]*)*))"
)
_STATUS = re.compile(r"\b(?:always|success|failure|cancelled)\s*\(")
_EXPR = re.compile(r"\$\{\{(.*?)\}\}", re.S)


def _truthy(value):
    if isinstance(value, float) and math.isnan(value):
        return False
    return value not in (None, False, 0, "")


def _number(value):
    if value is None:
        return 0
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, (int, float)):
        return value
    if isinstance(value, str):
        try:
            return float(value) if value.strip() else 0
        except ValueError:
            return math.nan
    return math.nan


def _equal(a, b):
    """GitHub's loose equality: strings compare case-insensitively, and
    operands of different types compare as numbers."""
    if isinstance(a, str) and isinstance(b, str):
        return a.lower() == b.lower()
    if type(a) is type(b):
        return a == b
    return _number(a) == _number(b)


def _render(value):
    if value is None:
        return ""
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, float) and value.is_integer():
        return str(int(value))
    if isinstance(value, (int, float, str)):
        return str(value)
    raise ValueError(f"cannot render a {type(value).__name__} into a string")


class _Parser:
    """Recursive descent in GitHub's precedence: || < && < == != < ! < primary.
    `a || b` and `a && b` yield an operand, not a boolean, as in Actions."""

    def __init__(self, text, ctx, prior_failed):
        self.ctx, self.prior_failed, self.i = ctx, prior_failed, 0
        self.toks, pos, text = [], 0, text.strip()
        while pos < len(text):
            m = _LEX.match(text, pos)
            if not m or m.end() == pos:
                raise ValueError(f"unsupported expression syntax at {text[pos:]!r}")
            pos = m.end()
            self.toks.append((m.lastgroup, m[m.lastgroup]))

    def value(self):
        v = self._or()
        if self.i != len(self.toks):
            raise ValueError(f"unexpected {self.toks[self.i]!r}")
        return v

    def _peek(self):
        return self.toks[self.i] if self.i < len(self.toks) else (None, None)

    def _take(self, op=None):
        tok = self._peek()
        if tok == (None, None) or (op is not None and tok != ("op", op)):
            raise ValueError(f"expected {op or 'a token'}, got {tok!r}")
        self.i += 1
        return tok

    def _or(self):
        v = self._and()
        while self._peek() == ("op", "||"):
            self._take()
            right = self._and()
            v = v if _truthy(v) else right
        return v

    def _and(self):
        v = self._eq()
        while self._peek() == ("op", "&&"):
            self._take()
            right = self._eq()
            v = right if _truthy(v) else v
        return v

    def _eq(self):
        v = self._not()
        while self._peek() in (("op", "=="), ("op", "!=")):
            op = self._take()[1]
            same = _equal(v, self._not())
            v = same if op == "==" else not same
        return v

    def _not(self):
        if self._peek() == ("op", "!"):
            self._take()
            return not _truthy(self._not())
        return self._primary()

    def _primary(self):
        kind, text = self._take()
        if (kind, text) == ("op", "("):
            v = self._or()
            self._take(")")
            return v
        if kind == "str":
            return text[1:-1].replace("''", "'")
        if kind == "num":
            return float(text) if "." in text else int(text)
        if kind != "name":
            raise ValueError(f"unexpected {text!r}")
        if self._peek() == ("op", "("):
            self._take()
            args = []
            if self._peek() != ("op", ")"):
                args.append(self._or())
                while self._peek() == ("op", ","):
                    self._take()
                    args.append(self._or())
            self._take(")")
            return self._call(text, args)
        if text in ("true", "false", "null"):
            return {"true": True, "false": False, "null": None}[text]
        node = self.ctx
        for part in text.split("."):
            if not isinstance(node, dict) or part not in node:
                return None
            node = node[part]
        return node

    def _call(self, name, args):
        if name in ("always", "success", "failure", "cancelled") and not args:
            return {
                "always": True,
                "success": not self.prior_failed,
                "failure": self.prior_failed,
                "cancelled": False,
            }[name]
        if name == "toJson" and len(args) == 1:
            return json.dumps(args[0], indent=2)
        if name == "startsWith" and len(args) == 2:
            return _render(args[0]).lower().startswith(_render(args[1]).lower())
        raise ValueError(f"unsupported function {name}() with {len(args)} arguments")


def evaluate(text, ctx, prior_failed=False):
    return _Parser(text, ctx, prior_failed).value()


def substitute(text, ctx):
    """Every ${{ }} in a string, replaced as Actions does before a shell runs."""
    return _EXPR.sub(lambda m: _render(evaluate(m[1], ctx)), str(text))


def step_runs(step, ctx, prior_failed):
    """An `if:` without a status function carries an implicit success()."""
    cond = step.get("if")
    if cond is None:
        return not prior_failed
    cond = str(cond).strip()
    whole = re.fullmatch(r"\$\{\{(.*)\}\}", cond, re.S)
    if whole and "${{" not in whole[1]:
        cond = whole[1]
    value = _truthy(evaluate(cond, ctx, prior_failed))
    return value if _STATUS.search(cond) else value and not prior_failed


def parse_outputs(text):
    outputs, lines, i = {}, text.split("\n"), 0
    while i < len(lines):
        line = lines[i]
        eq, heredoc = line.find("="), line.find("<<")
        if heredoc > 0 and (eq < 0 or heredoc < eq):
            name, delim = line[:heredoc], line[heredoc + 2 :]
            body, i = [], i + 1
            while i < len(lines) and lines[i] != delim:
                body.append(lines[i])
                i += 1
            outputs[name] = "\n".join(body)
        elif eq > 0:
            outputs[line[:eq]] = line[eq + 1 :]
        i += 1
    return outputs


# ---------------------------------------------------------------------------
# The gh stub: one pull request whose state lives in $STUB_STATE. Every read
# runs the caller's own --jq filter over API-shaped JSON through jq. The arm
# is one piece of state seen through both the GraphQL (`autoMergeRequest`,
# gh pr view) and REST (`auto_merge`) shapes, and only `gh pr merge` changes
# it. Each change lands on the PR timeline under the actor its token stands
# for, and each call is logged with the step that made it: the identity a
# disarm is recorded under decides whether the manual-hold step later reads
# it as a human's hold.
# ---------------------------------------------------------------------------
GH_STUB = r"""#!__PYTHON__ -S
import json
import os
import subprocess
import sys
import urllib.parse

BASE = "repos/__REPO__"
PULL = BASE + "/pulls/__PR__"
ISSUE = BASE + "/issues/__PR__"
BOT, PAT = "__BOT__", "__PAT__"
ACTORS = {BOT: ("github-actions[bot]", True), PAT: ("pat-user", False)}

path = os.environ["STUB_STATE"]
with open(path) as f:
    state = json.load(f)
argv = sys.argv[1:]
token = os.environ.get("GH_TOKEN", "")
step = os.environ.get("STUB_STEP", "")
state["calls"].append({"step": step, "token": token, "argv": argv})


def fail(message, code=1):
    sys.stderr.write(message + "\n")
    sys.exit(code)


def unexpected():
    fail("gh-stub: unexpected call: " + " ".join(argv), 64)


def actor():
    if token not in ACTORS:
        fail("gh-stub: GH_TOKEN is neither github.token nor the PAT: %r" % token, 4)
    return ACTORS[token]


def emit(value, jq):
    text = json.dumps(value)
    if jq is None:
        print(text)
        sys.exit(0)
    proc = subprocess.run(["jq", "-r", jq], input=text, capture_output=True, text=True)
    sys.stdout.write(proc.stdout)
    sys.stderr.write(proc.stderr)
    sys.exit(proc.returncode)


def http_error(status, message):
    # Real gh prints an HTTP error's JSON body to STDOUT, --jq or not, and
    # exits 1 (gh 2.89, measured 2026-09-30).
    print(json.dumps({"message": message, "status": str(status)}))
    fail("gh: %s (HTTP %d)" % (message, status))


def html_error(status):
    # A non-JSON error body, such as the HTML page GitHub's edge serves on
    # some 5xx: gh 2.89's processResponse copies it to stdout as-is, then
    # reports the status and exits 1.
    print("<!DOCTYPE html><html><body>Unicorn! (%d)</body></html>" % status)
    fail("gh: HTTP %d" % status)


def record(event):
    state["clock"] += 1
    n = state["clock"]
    state["timeline"].append({
        "event": event,
        "created_at": "2026-09-30T10:%02d:%02dZ" % (n // 60, n % 60),
        "actor": {"login": actor()[0]},
    })


def option(args, name):
    return args[args.index(name) + 1] if name in args else None


def labels():
    return [{"name": n} for n in state["labels"]]


def pr(args):
    if args[:1] == ["view"]:
        if option(args, "--json") != "autoMergeRequest":
            unexpected()
        if state["knobs"].get("pr_view_fails"):
            # gh pr view leaves stdout empty on an error (measured).
            fail("GraphQL: Something went wrong while executing your query (HTTP 502)")
        arm = state["arm"]
        emit({"autoMergeRequest": None if arm is None else
              {"enabledBy": {"login": arm["login"], "is_bot": arm["is_bot"]}}},
             option(args, "--jq"))
    if args[:1] == ["merge"] and "--disable-auto" in args:
        actor()
        call = {"step": step, "token": token, "effective": False}
        state["disables"].append(call)
        if token == BOT and state["knobs"].get("bot_cannot_disarm"):
            fail("GraphQL: Resource not accessible by integration (disablePullRequestAutoMerge)")
        if state["disarm_failures_left"] > 0:
            state["disarm_failures_left"] -= 1
            fail("GraphQL: Something went wrong while executing your query. (disablePullRequestAutoMerge)")
        if state["arm"] is None:
            fail("GraphQL: auto-merge is not enabled for this pull request (disablePullRequestAutoMerge)")
        state["arm"] = None
        call["effective"] = True
        record("auto_merge_disabled")
        sys.exit(0)
    if args[:1] == ["merge"] and "--auto" in args:
        login, is_bot = actor()
        state["arm_calls"] += 1
        if option(args, "--match-head-commit") != state["head_sha"]:
            fail("GraphQL: Head branch was modified. Review and try the merge again. (enablePullRequestAutoMerge)")
        # Enabling on an armed PR keeps the original enabler (measured).
        if state["arm"] is None:
            method = next(m for m in ("squash", "merge", "rebase") if "--" + m in args)
            state["arm"] = {"login": login, "is_bot": is_bot}
            record({"squash": "auto_squash_enabled", "merge": "auto_merge_enabled",
                    "rebase": "auto_rebase_enabled"}[method])
        sys.exit(0)
    if args[:1] == ["comment"]:
        with open(option(args, "--body-file")) as f:
            body = f.read()
        state["comments"].append({"id": 900 + len(state["comments"]), "body": body,
                                  "user": {"login": actor()[0]}})
        sys.exit(0)


def api(args):
    method, jq, fields, endpoint = "GET", None, [], None
    it = iter(args)
    for a in it:
        if a in ("-X", "--method"):
            method = next(it)
        elif a == "--jq":
            jq = next(it)
        elif a in ("-f", "-F"):
            fields.append(next(it))
        elif a == "--paginate":
            pass
        elif a.startswith("-") or endpoint is not None:
            unexpected()
        else:
            endpoint = a
    if endpoint is None:
        unexpected()
    route = urllib.parse.urlsplit(endpoint.lstrip("/")).path
    if (method, route) == ("GET", "user"):
        if state["knobs"].get("head_on_arm"):
            # The arm step's first call: a push puts the event's head back.
            state["head_sha"] = state["knobs"]["head_on_arm"]
            state["knobs"]["head_on_arm"] = ""
        if token != PAT:
            http_error(403, "Resource not accessible by integration")
        emit({"login": "pat-user", "type": "User"}, jq)
    if (method, route) == ("GET", PULL):
        if state["knobs"].get("pr_read_fails") or (
            step and step == state["knobs"].get("pr_read_fails_for")
        ):
            http_error(502, "Server Error")
        arm = state["arm"]
        emit({
            "number": int("__PR__"),
            "head": {"sha": state["head_sha"]},
            "base": {"ref": state["base_ref"]},
            "body": state["body"],
            "labels": labels(),
            "auto_merge": None if arm is None else {
                "enabled_by": {"login": arm["login"], "type": "Bot" if arm["is_bot"] else "User"},
                "merge_method": "squash",
            },
        }, jq)
    if (method, route) == ("GET", PULL + "/files"):
        emit(state["files"], jq)
    if (method, route) == ("GET", ISSUE + "/labels"):
        if step and step == state["knobs"].get("labels_fail_for"):
            http_error(502, "Server Error")
        if step and step == state["knobs"].get("head_moves_on_labels_read"):
            # A push lands while this read is served, and the newer head's
            # run arms it (through the PAT) before this run resumes.
            state["knobs"]["head_moves_on_labels_read"] = ""
            state["head_sha"] = "__NEW_HEAD__"
            state["arm"] = {"login": "pat-user", "is_bot": False}
        emit(labels(), jq)
    if (method, route) == ("POST", ISSUE + "/labels"):
        for item in fields:
            key, _, name = item.partition("=")
            if key != "labels[]":
                unexpected()
            if name not in state["labels"]:
                state["labels"].append(name)
        emit(labels(), jq)
    if method == "DELETE" and route.startswith(ISSUE + "/labels/"):
        name = urllib.parse.unquote(route[len(ISSUE + "/labels/"):])
        if name not in state["labels"]:
            http_error(404, "Label does not exist")
        state["labels"].remove(name)
        emit(labels(), jq)
    if (method, route) == ("GET", ISSUE + "/timeline"):
        emit(state["timeline"], jq)
    if (method, route) == ("GET", ISSUE + "/comments"):
        emit(state["comments"], jq)
    if method == "PATCH" and route.startswith(BASE + "/issues/comments/"):
        cid = int(route.rsplit("/", 1)[1])
        body = dict(item.partition("=")[::2] for item in fields)["body"]
        for comment in state["comments"]:
            if comment["id"] == cid:
                comment["body"] = body
        emit({"id": cid}, jq)
    if (method, route) == ("GET", BASE + "/contents/.github/risk-paths.yml"):
        # No repo policy: the global risk-tier regex decides.
        http_error(404, "Not Found")
    parts = route.split("/")
    if method == "GET" and route.startswith(BASE + "/commits/") and len(parts) == 6:
        if state["knobs"].get("checks_read_fails"):
            html_error(502)
        runs = state["check_runs"] if parts[4] == state["head_sha"] else []
        if parts[5] == "check-runs":
            emit({"total_count": len(runs), "check_runs": runs}, jq)
        if parts[5] == "status":
            emit({"state": "pending", "statuses": []}, jq)


def label(args):
    if len(args) < 2 or args[0] not in ("create", "edit"):
        unexpected()
    actor()
    if args[0] == "create":
        if args[1] in state["repo_labels"]:
            fail('label with name "%s" already exists; use `--force` to update its color and description' % args[1])
        state["repo_labels"].append(args[1])
    sys.exit(0)


try:
    commands = {"api": api, "pr": pr, "label": label}
    if argv[:1] and argv[0] in commands:
        commands[argv[0]](argv[1:])
    unexpected()
finally:
    with open(path, "w") as f:
        json.dump(state, f)
"""


def _stamp(n):
    return f"2026-09-30T10:{n // 60:02d}:{n % 60:02d}Z"


@dataclass
class Revision:
    """One event on the PR: the head it carries and the state around it."""

    files: list
    head_sha: str = "a" * 40
    branch: str = "claude/rotate-keys"
    action: str = "synchronize"
    labels: tuple = ()  # applied by a human before this event
    # True: armed through the PAT earlier; "bot": armed by github-actions[bot]
    # earlier (a GITHUB_TOKEN arm from before the attribution gate); False:
    # unarmed; None: as left.
    armed: object = None
    # The base GET pulls/7 answers now; the event's payload keeps "main", so
    # anything else is a retarget after the event fired.
    live_base: str = "main"
    inputs: dict = field(default_factory=dict)  # the caller's input overrides
    check_runs: tuple = ()  # (name, conclusion) on the head commit
    event_head_sha: object = None  # the payload's head, when a newer push has landed
    # The payload's labels when they differ from the PR's live ones: a re-run
    # replays its original event, label snapshot included. None: the live set.
    event_labels: object = None
    body: str = "Rotates the signing keys."
    bot_cannot_disarm: bool = False  # GitHub refuses github.token's --disable-auto
    disarm_fails_once: bool = False  # the first --disable-auto fails transiently
    pr_read_fails: bool = False  # GET pulls/7 answers HTTP 502, its body on stdout
    pr_read_fails_for: str = ""  # the one step whose GET pulls/7 reads answer HTTP 502
    pr_view_fails: bool = False  # gh pr view exits 1 with an empty stdout
    checks_read_fails: bool = False  # the check-runs read answers an HTML 502
    labels_fail_for: str = ""  # the step whose live-label reads answer HTTP 502
    head_moves_on_labels_read: str = ""  # the step whose label read sees a push land
    head_returns_on_arm: bool = False  # the event's head is back as the arm step starts


class Stub:
    def __init__(self, tmp):
        self.tmp = tmp
        self.bin = tmp / "bin"
        self.bin.mkdir()
        self.state_path = tmp / "state.json"
        gh = self.bin / "gh"
        gh.write_text(
            GH_STUB.replace("__PYTHON__", sys.executable)
            .replace("__REPO__", REPO)
            .replace("__PR__", str(PR_NUMBER))
            .replace("__BOT__", GITHUB_TOKEN)
            .replace("__PAT__", PAT)
            .replace("__NEW_HEAD__", NEW_HEAD)
        )
        gh.chmod(0o755)
        # The steps back off with sleep between retries; the stub never
        # recovers, so waiting only slows the test.
        sleep = self.bin / "sleep"
        sleep.write_text("#!/usr/bin/env bash\nexit 0\n")
        sleep.chmod(0o755)
        self.write(
            {
                "head_sha": "",
                "base_ref": "main",
                "body": "",
                "files": [],
                "labels": [],
                "repo_labels": [],
                "arm": None,
                "timeline": [],
                "comments": [],
                "check_runs": [],
                "clock": 0,
                "knobs": {},
                "calls": [],
                "disables": [],
                "disarm_failures_left": 0,
                "arm_calls": 0,
            }
        )
        self.runs = 0

    def read(self):
        return json.loads(self.state_path.read_text())

    def write(self, state):
        self.state_path.write_text(json.dumps(state))

    def stage(self, rev):
        """Apply one revision; returns the labels its event payload carries."""
        s = self.read()
        s["head_sha"] = rev.head_sha
        s["base_ref"] = rev.live_base
        s["body"] = rev.body
        s["files"] = [{"filename": f, "status": "modified"} for f in rev.files]
        for name in rev.labels:
            if name not in s["labels"]:
                s["labels"].append(name)
        if rev.armed and s["arm"] is None:
            # Armed on an earlier revision, through the caller's PAT, or by
            # github-actions[bot].
            login = "github-actions[bot]" if rev.armed == "bot" else "pat-user"
            s["arm"] = {"login": login, "is_bot": rev.armed == "bot"}
            s["clock"] += 1
            s["timeline"].append(
                {
                    "event": "auto_squash_enabled",
                    "created_at": _stamp(s["clock"]),
                    "actor": {"login": login},
                }
            )
        elif rev.armed is False:
            s["arm"] = None
        s["check_runs"] = [
            {
                "id": i + 1,
                "name": name,
                "status": "completed",
                "conclusion": conclusion,
                "app": {"id": 1},
            }
            for i, (name, conclusion) in enumerate(rev.check_runs)
        ]
        s["knobs"] = {
            "bot_cannot_disarm": rev.bot_cannot_disarm,
            "pr_read_fails": rev.pr_read_fails,
            "pr_read_fails_for": rev.pr_read_fails_for,
            "pr_view_fails": rev.pr_view_fails,
            "checks_read_fails": rev.checks_read_fails,
            "labels_fail_for": rev.labels_fail_for,
            "head_moves_on_labels_read": rev.head_moves_on_labels_read,
            "head_on_arm": (rev.event_head_sha or rev.head_sha)
            if rev.head_returns_on_arm
            else "",
        }
        s["disarm_failures_left"] = 1 if rev.disarm_fails_once else 0
        s["calls"], s["disables"], s["arm_calls"] = [], [], 0
        self.write(s)
        if rev.event_labels is not None:
            return list(rev.event_labels)
        return list(s["labels"])


def context(rev, labels, inputs, results):
    return {
        "github": {
            "token": GITHUB_TOKEN,
            "repository": REPO,
            "event": {
                "action": rev.action,
                "repository": {"default_branch": "main"},
                "pull_request": {
                    "number": PR_NUMBER,
                    "draft": False,
                    "html_url": PR_URL,
                    "user": {"login": "octo-dev"},
                    "created_at": "2026-09-30T09:00:00Z",
                    "body": rev.body,
                    "labels": [{"name": n} for n in labels],
                    "head": {
                        "sha": rev.event_head_sha or rev.head_sha,
                        "ref": rev.branch,
                    },
                    "base": {"ref": "main", "sha": "0" * 40},
                },
            },
        },
        "inputs": inputs,
        "secrets": {"automerge_pat": PAT},
        "steps": {
            key: {
                "outputs": r["outputs"],
                "outcome": r["outcome"],
                "conclusion": r["outcome"],
            }
            for key, r in results.items()
        },
    }


@dataclass
class Job:
    steps: dict
    logs: dict
    state: dict

    @property
    def arm(self):
        return "OFF" if self.state["arm"] is None else "ON"

    @property
    def disarmed_by(self):
        """(step, token) of each --disable-auto that turned an arm off."""
        return [
            (c["step"], c["token"]) for c in self.state["disables"] if c["effective"]
        ]

    @property
    def disarm_attempts(self):
        """(step, token) of every --disable-auto, whether or not it took."""
        return [(c["step"], c["token"]) for c in self.state["disables"]]

    @property
    def disables(self):
        """Every --disable-auto attempt, whether or not an arm stood."""
        return len(self.state["disables"])

    @property
    def disable_steps(self):
        return [c["step"] for c in self.state["disables"]]

    @property
    def arms(self):
        return self.state["arm_calls"]

    @property
    def labels(self):
        return self.state["labels"]

    @property
    def comments(self):
        return [c["body"] for c in self.state["comments"]]

    @property
    def failed(self):
        return [k for k, r in self.steps.items() if r["outcome"] == "failure"]

    def out(self, key):
        return self.steps.get(key, {}).get("outputs", {})

    def outcome(self, key):
        return self.steps.get(key, {}).get("outcome")

    def __str__(self):
        parts = [
            f"arm={self.arm} disables={self.state['disables']} "
            f"arm_calls={self.arms} labels={self.labels}"
        ]
        for key, r in self.steps.items():
            parts.append(f"  {key}: {r['outcome']} {r['outputs']}")
        parts.append("  gh calls:")
        parts.extend(
            f"    [{c['step']} | {c['token']}] {' '.join(c['argv'])}"
            for c in self.state["calls"]
        )
        for key, log in self.logs.items():
            parts.append(f"  --- {key} ---")
            parts.extend(f"    {line}" for line in log.splitlines())
        return "\n".join(parts)


def run_job(stub, rev, steps=STEPS):
    stub.runs += 1
    work = stub.tmp / f"run{stub.runs}"
    work.mkdir()
    labels = stub.stage(rev)
    inputs = {**INPUT_DEFAULTS, "findings_quiet_minutes": 0, **rev.inputs}
    results, logs, prior_failed = {}, {}, False
    assert _truthy(evaluate(str(JOB["if"]), context(rev, labels, inputs, results))), (
        "the job's own `if:` skips this event"
    )
    for index, step in enumerate(steps):
        key = step.get("id") or step["name"]
        ctx = context(rev, labels, inputs, results)
        if not step_runs(step, ctx, prior_failed):
            results[key] = {"outcome": "skipped", "outputs": {}}
            continue
        if "uses" in step:
            results[key] = {"outcome": "success", "outputs": {}}
            continue
        assert "shell" not in step, f"{key}: a non-default shell is not modeled"
        step_dir = work / f"step{index:02d}"
        step_dir.mkdir()
        script = step_dir / "run.sh"
        script.write_text(substitute(step["run"], ctx))
        output = step_dir / "github_output"
        output.write_text("")
        env = {
            "PATH": f"{stub.bin}{os.pathsep}{os.environ['PATH']}",
            "HOME": str(step_dir),
            "TMPDIR": str(step_dir),
            "GITHUB_OUTPUT": str(output),
            "GITHUB_REPOSITORY": REPO,
            "STUB_STATE": str(stub.state_path),
            "STUB_STEP": key,
        }
        env.update(
            {
                name: substitute(value, ctx)
                for name, value in (step.get("env") or {}).items()
            }
        )
        proc = subprocess.run(
            ["bash", "-e", str(script)],
            env=env,
            cwd=step_dir,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=120,
        )
        logs[key] = proc.stdout + proc.stderr
        results[key] = {
            "outcome": "success" if proc.returncode == 0 else "failure",
            "outputs": parse_outputs(output.read_text()),
        }
        prior_failed = prior_failed or results[key]["outcome"] == "failure"
    return Job(steps=results, logs=logs, state=stub.read())


CLEAN = ["src/keys/rotate.py"]
RISKY = ["src/keys/rotate.py", "src/auth/login.py"]


def armed_by_a_clean_revision(tmp_path, steps=STEPS, **inputs):
    """Revision 1 — no risk-tier path; the SHIPPED enable step arms it."""
    stub = Stub(tmp_path)
    first = run_job(stub, Revision(CLEAN, head_sha="1" * 40, inputs=inputs), steps)
    assert first.arms == 1 and first.arm == "ON" and first.disables == 0, (
        f"the clean revision must be armed here:\n{first}"
    )
    return stub


def risky_push(**kw):
    """Revision 2 — the next push adds src/auth/login.py."""
    return Revision(RISKY, head_sha="2" * 40, **kw)


# ---------------------------------------------------------------------------
# 1. The gap.
# ---------------------------------------------------------------------------
def test_a_push_adding_a_risk_tier_path_revokes_the_standing_arm(tmp_path):
    stub = armed_by_a_clean_revision(tmp_path)
    job = run_job(stub, risky_push())
    assert job.out("risk").get("risky") == "1", (
        f"the risk step did not flag src/auth:\n{job}"
    )
    assert job.arm == "OFF" and job.disarmed_by == [(REVOKE, GITHUB_TOKEN)], (
        f"the arm from the clean revision survived a push adding src/auth/login.py:\n{job}"
    )
    assert job.out(REVOKE) == {"arm_off": "1"}, str(job)
    assert job.outcome("arm") == "skipped", str(job)
    assert job.outcome(ERROR_REVOKE) == "skipped", str(job)
    assert RISK_LABEL in job.labels, f"the decision label is missing:\n{job}"
    comment = next((b for b in job.comments if RISK_MARKER in b), "")
    assert "Auto-merge stays off while this block stands" in comment, (
        f"the risk-tier comment is missing, or does not say the block is enforced:\n{job}"
    )


def test_an_unarmed_risky_pr_passes_the_idempotent_revoke(tmp_path):
    """Most risky PRs were never armed: the disarm finds nothing and gh exits
    nonzero, and the verified OFF must still leave a green run."""
    stub = Stub(tmp_path)
    job = run_job(stub, Revision(RISKY, armed=False))
    assert job.out(REVOKE) == {"arm_off": "1"}, str(job)
    assert job.disable_steps == [REVOKE] and job.disarmed_by == [], str(job)
    assert not job.failed, f"a step failed on an unarmed risky PR:\n{job}"
    assert RISK_LABEL in job.labels, str(job)


# ---------------------------------------------------------------------------
# 2. Only this workflow's own bypasses keep the arm.
# ---------------------------------------------------------------------------
def test_the_bypass_label_keeps_the_arm(tmp_path):
    stub = armed_by_a_clean_revision(tmp_path)
    job = run_job(stub, risky_push(labels=(BYPASS_LABEL,)))
    assert job.arm == "ON" and job.disables == 0, (
        f"the bypass label (Option A) did not keep the arm:\n{job}"
    )
    assert job.outcome("risk") == "skipped", str(job)
    assert job.outcome(REVOKE) == "skipped", str(job)
    assert job.out("arm").get("armed") == "1", str(job)


def test_a_re_run_of_an_older_event_keeps_the_bypass_labels_arm(tmp_path):
    """A re-run replays its original event, label snapshot included, so a
    re-run of the push from before a human applied the bypass label reads no
    bypass. The label is on the PR now and its own run armed it: the revoke
    leaves that arm alone and the run publishes no risk-tier label."""
    stub = armed_by_a_clean_revision(tmp_path)
    run_job(stub, risky_push())
    approved = run_job(stub, risky_push(action="labeled", labels=(BYPASS_LABEL,)))
    assert approved.arm == "ON", str(approved)
    rerun = run_job(stub, risky_push(event_labels=()))
    assert rerun.out("bypass_label") == {"bypass": "0"}, str(rerun)
    assert rerun.arm == "ON" and rerun.disables == 0, (
        f"a re-run of an older event revoked the bypass label's arm:\n{rerun}"
    )
    assert rerun.outcome(REVOKE) == "success" and rerun.out(REVOKE) == {}, str(rerun)
    assert RISK_LABEL not in rerun.labels, str(rerun)
    assert rerun.outcome(RISK_COMMENT) == "skipped", (
        f"the risk-tier comment was refreshed over an arm the revoke kept:\n{rerun}"
    )


def test_a_near_match_label_is_not_the_bypass_label(tmp_path):
    """The live re-check matches the whole label name: a label that merely
    contains the bypass label's name releases nothing."""
    near = f"not-{BYPASS_LABEL}"
    stub = armed_by_a_clean_revision(tmp_path)
    job = run_job(stub, risky_push(labels=(near,)))
    assert job.arm == "OFF" and job.disarmed_by == [(REVOKE, GITHUB_TOKEN)], (
        f"the label {near!r} released the risk-tier verdict:\n{job}"
    )
    assert RISK_LABEL in job.labels, str(job)


def test_an_unreadable_live_label_set_still_revokes(tmp_path):
    """The live bypass-label read skips the revoke only on a positive answer:
    an HTTP error (its JSON body on stdout) is not the label."""
    stub = armed_by_a_clean_revision(tmp_path)
    job = run_job(stub, risky_push(labels_fail_for=REVOKE))
    assert job.arm == "OFF" and job.disarmed_by == [(REVOKE, GITHUB_TOKEN)], (
        f"an unreadable live label set skipped the revoke:\n{job}"
    )


def test_a_bypass_label_input_with_a_stray_newline_still_revokes(tmp_path):
    """A YAML block scalar (`risk_bypass_label: |`) keeps a trailing newline.
    That name matches no label, so nothing may release the verdict; `grep -F`
    would split it into two patterns, and the empty one matches the empty
    read of an unlabeled PR."""
    inputs = {"risk_bypass_label": BYPASS_LABEL + "\n"}
    stub = armed_by_a_clean_revision(tmp_path, **inputs)
    job = run_job(stub, risky_push(inputs=inputs))
    assert job.arm == "OFF" and job.disarmed_by == [(REVOKE, GITHUB_TOKEN)], (
        f"a bypass label input with a trailing newline skipped the revoke:\n{job}"
    )


@pytest.mark.parametrize(
    "conclusion, kept",
    [
        pytest.param("success", True, id="codex-success"),
        pytest.param("failure", False, id="codex-failure"),
        pytest.param(None, False, id="codex-absent"),
    ],
)
def test_a_codex_success_keeps_the_arm(tmp_path, conclusion, kept):
    inputs = {"codex_check_name": CODEX_CHECK}
    stub = armed_by_a_clean_revision(tmp_path, **inputs)
    runs = ((CODEX_CHECK, conclusion),) if conclusion else ()
    job = run_job(stub, risky_push(inputs=inputs, check_runs=runs))
    assert job.out("bypass_codex").get("bypass") == ("1" if kept else "0"), str(job)
    if kept:
        assert job.arm == "ON" and job.disables == 0, (
            f"a Codex SUCCESS (Option B) did not keep the arm:\n{job}"
        )
        assert job.outcome(REVOKE) == "skipped", str(job)
    else:
        assert job.arm == "OFF" and job.disarmed_by == [(REVOKE, GITHUB_TOKEN)], (
            f"a Codex check that did not succeed kept the arm:\n{job}"
        )


@pytest.mark.parametrize(
    "risk_main_go, kept",
    [
        pytest.param(False, True, id="risk_main_go-false"),
        pytest.param(True, False, id="risk_main_go-default"),
    ],
)
def test_risk_main_go_false_keeps_a_main_go_arm(tmp_path, risk_main_go, kept):
    inputs = {"risk_main_go": risk_main_go}
    stub = armed_by_a_clean_revision(tmp_path, **inputs)
    main_go = Revision(["cmd/tool/main.go"], head_sha="2" * 40, inputs=inputs)
    job = run_job(stub, main_go)
    if kept:
        assert job.arm == "ON" and job.disables == 0, (
            f"risk_main_go: false did not keep a main.go change's arm:\n{job}"
        )
    else:
        assert job.arm == "OFF", str(job)
        assert job.disarmed_by == [(REVOKE, GITHUB_TOKEN)], str(job)


# ---------------------------------------------------------------------------
# 3. The hold step.
# ---------------------------------------------------------------------------
def test_the_revoke_does_not_read_as_a_human_hold(tmp_path):
    stub = armed_by_a_clean_revision(tmp_path)
    revoked = run_job(stub, risky_push())
    assert revoked.arm == "OFF", str(revoked)
    relabeled = run_job(stub, risky_push(action="labeled", labels=(BYPASS_LABEL,)))
    assert relabeled.out("hold") == {"hold": "0", "reason": ""}, (
        f"the risk-tier revoke read as a human's hold:\n{relabeled}"
    )
    assert relabeled.arm == "ON" and relabeled.arms == 1, (
        f"the bypass label did not re-arm after the revoke:\n{relabeled}"
    )
    assert RISK_LABEL not in relabeled.labels, str(relabeled)


def test_a_hold_label_revokes_through_the_hold_step_alone(tmp_path):
    stub = armed_by_a_clean_revision(tmp_path)
    job = run_job(stub, risky_push(labels=(HOLD_LABEL,)))
    assert job.arm == "OFF", str(job)
    assert job.disarmed_by == [(HOLD_REVOKE, GITHUB_TOKEN)], str(job)
    assert job.outcome(REVOKE) == "skipped", str(job)
    assert not [n for n in job.labels if n.startswith("automerge:")], (
        f"a hold run left a decision label:\n{job}"
    )


def retargeted_push(**kw):
    """Revision 2 — clean, but the PR was retargeted after its event fired: the
    arm step's live re-read sees `release`, not the `main` its gate read."""
    return Revision(CLEAN, head_sha="2" * 40, live_base="release", **kw)


def clean_push():
    """Revision 3 — a later push, still clean, on the default branch."""
    return Revision(CLEAN, head_sha="3" * 40)


@pytest.mark.parametrize(
    "fault, outcome, outputs",
    [
        pytest.param(
            {"live_base": "release"},
            "success",
            {"stood_down": "base"},
            id="base-changed",
        ),
        pytest.param({"pr_read_fails_for": ARM}, "failure", {}, id="base-unreadable"),
    ],
)
def test_a_pre_arm_stand_down_does_not_read_as_a_human_hold(
    tmp_path, fault, outcome, outputs
):
    """The arm step re-reads the base right before it arms. A retarget since
    the gate read, or a base it cannot read, makes it disarm the arm an
    earlier run placed and stand down. Nothing after that disarm records an
    auto-merge event, so the next run's hold step reads it, and that step
    takes a disable by anyone but github-actions[bot] for a human's durable
    hold: a disarm under the PAT stranded a clean PR no human ever disabled."""
    stub = armed_by_a_clean_revision(tmp_path)
    stood = run_job(stub, Revision(CLEAN, head_sha="2" * 40, **fault))
    later = run_job(stub, clean_push())
    assert later.out("hold") == {"hold": "0", "reason": ""} and later.arm == "ON", (
        f"the arm step's disarm {stood.disarmed_by} read as a human's hold, and "
        f"the clean PR was never re-armed:\n{later}"
    )
    assert later.arms == 1, str(later)
    assert stood.disarmed_by == [(ARM, GITHUB_TOKEN)], str(stood)
    assert stood.outcome(ARM) == outcome and stood.out(ARM) == outputs, str(stood)


def test_removing_a_bots_arm_before_a_stand_down_does_not_read_as_a_human_hold(
    tmp_path,
):
    """A bot's arm merges as the bot, so the arm step removes it before its
    revalidation reads. When the step then stands down instead of arming as
    the PAT user, that removal is the PR's newest auto-merge event."""
    stub = Stub(tmp_path)
    stood = run_job(stub, retargeted_push(armed="bot"))
    later = run_job(stub, clean_push())
    assert later.out("hold") == {"hold": "0", "reason": ""} and later.arm == "ON", (
        f"the removal of the bot's arm {stood.disarmed_by} read as a human's "
        f"hold, and the clean PR was never re-armed:\n{later}"
    )
    assert stood.disarmed_by == [(ARM, GITHUB_TOKEN)], str(stood)
    assert stood.out(ARM) == {"stood_down": "base"}, str(stood)


def test_the_arm_steps_disarm_falls_back_to_the_pat_when_the_bot_cannot(tmp_path):
    """GITHUB_TOKEN can disable an arm the PAT user placed
    (whois-api-llc/wxa_webcat#1715), so the PAT is the fallback only: tried
    after the bot's attempts, and verified like them, so the disarm stays
    fail-closed."""
    stub = armed_by_a_clean_revision(tmp_path)
    stood = run_job(stub, retargeted_push(bot_cannot_disarm=True))
    assert stood.arm == "OFF" and stood.out(ARM) == {"stood_down": "base"}, (
        f"the arm survived a refused bot disarm:\n{stood}"
    )
    assert stood.disarm_attempts == [(ARM, GITHUB_TOKEN)] * 3 + [(ARM, PAT)], (
        f"expected three attempts as github-actions[bot], then the PAT:\n{stood}"
    )


def test_a_transient_disarm_failure_retries_as_the_bot(tmp_path):
    """One failed attempt is not a refusal: the bot retries before the PAT may
    step in, so a 502 does not cost the PR a phantom human hold."""
    stub = armed_by_a_clean_revision(tmp_path)
    stood = run_job(stub, retargeted_push(disarm_fails_once=True))
    assert stood.disarm_attempts == [(ARM, GITHUB_TOKEN)] * 2, str(stood)
    assert stood.disarmed_by == [(ARM, GITHUB_TOKEN)], str(stood)


# ---------------------------------------------------------------------------
# 4. Fail closed: only OFF counts.
# ---------------------------------------------------------------------------
@pytest.mark.parametrize(
    "fault, state, arm",
    [
        pytest.param({"bot_cannot_disarm": True}, "ON", "ON", id="still-on"),
        pytest.param({"pr_view_fails": True}, "UNKNOWN", "OFF", id="unreadable"),
    ],
)
def test_an_unverified_disarm_fails_closed(tmp_path, fault, state, arm):
    stub = Stub(tmp_path)
    job = run_job(stub, Revision(RISKY, armed=True, **fault))
    assert job.outcome(REVOKE) == "failure", (
        f"an arm state of {state} passed as revoked:\n{job}"
    )
    assert f"after risk-tier revoke: {state}" in job.logs[REVOKE], str(job)
    assert job.arm == arm, str(job)
    assert job.disable_steps == [REVOKE, ERROR_REVOKE], (
        f"the error revoke did not retry the disarm:\n{job}"
    )
    assert RISK_LABEL not in job.labels, (
        f"the decision label announced a block the revoke could not verify:\n{job}"
    )
    assert not job.comments, str(job)


def test_a_failed_codex_probe_still_revokes(tmp_path):
    """Option B's check-runs read can fail: gh copies a non-JSON 5xx body to
    stdout, jq cannot parse it, and the step fails. Implicit success() then
    skips the revoke, but a check that could not be read released nothing,
    so the always() error revoke must disarm."""
    inputs = {"codex_check_name": CODEX_CHECK}
    stub = armed_by_a_clean_revision(tmp_path, **inputs)
    job = run_job(stub, risky_push(inputs=inputs, checks_read_fails=True))
    assert job.outcome("bypass_codex") == "failure", str(job)
    assert job.outcome(REVOKE) == "skipped", str(job)
    assert job.arm == "OFF", f"a failed Option B probe left the standing arm:\n{job}"
    assert job.disarmed_by == [(ERROR_REVOKE, GITHUB_TOKEN)], str(job)
    assert RISK_LABEL not in job.labels, str(job)


# ---------------------------------------------------------------------------
# 5. Ownership.
# ---------------------------------------------------------------------------
def test_a_moved_head_leaves_the_revoke_to_the_newer_heads_run(tmp_path):
    stub = Stub(tmp_path)
    job = run_job(
        stub, Revision(RISKY, head_sha="2" * 40, event_head_sha="1" * 40, armed=True)
    )
    assert job.out("risk").get("risky") == "1", str(job)
    assert job.arm == "ON" and job.disables == 0, (
        f"a run for an older head revoked what the newer head's run owns:\n{job}"
    )
    assert job.outcome(REVOKE) == "success" and job.out(REVOKE) == {}, str(job)
    assert RISK_LABEL not in job.labels, str(job)
    assert job.outcome(RISK_COMMENT) == "skipped", str(job)


def test_a_push_during_the_label_read_keeps_the_newer_heads_arm(tmp_path):
    """The ownership check sits immediately before the disarm: a push that
    lands (and is armed by its own run) while the live labels are read makes
    the head a newer one, and this run must not disarm it."""
    stub = armed_by_a_clean_revision(tmp_path)
    job = run_job(stub, risky_push(head_moves_on_labels_read=REVOKE))
    assert job.arm == "ON" and job.disables == 0, (
        f"a run for the older head disarmed the newer head's arm:\n{job}"
    )
    assert job.out(REVOKE) == {}, str(job)


def test_an_error_body_from_the_head_read_does_not_skip_the_revoke(tmp_path):
    stub = Stub(tmp_path)
    job = run_job(stub, Revision(RISKY, armed=True, pr_read_fails=True))
    assert job.arm == "OFF" and job.disarmed_by == [(REVOKE, GITHUB_TOKEN)], (
        f"an HTTP error body from the head read skipped the revoke:\n{job}"
    )
    assert job.outcome(REVOKE) == "success", str(job)


def test_the_error_revoke_retries_through_an_unreadable_head(tmp_path):
    """The first disarm fails transiently, so the revoke fails and the error
    revoke retries. Its head read hits an HTTP error whose JSON body gh prints
    to stdout: that is not a moved head, and the retry must disarm."""
    stub = Stub(tmp_path)
    rev = Revision(RISKY, armed=True, pr_read_fails=True, disarm_fails_once=True)
    job = run_job(stub, rev)
    assert job.outcome(REVOKE) == "failure", str(job)
    assert job.arm == "OFF", (
        f"the error revoke read an API error as a moved head and kept the arm:\n{job}"
    )
    assert job.disarmed_by == [(ERROR_REVOKE, GITHUB_TOKEN)], str(job)
    assert job.outcome(ERROR_REVOKE) == "success", str(job)


# ---------------------------------------------------------------------------
# 6. Negative controls: each mutant breaks the property its case pins, and
#    the case's own observation sees it.
# ---------------------------------------------------------------------------
def _edit(step_key, field_name, old, new):
    """A mutant replacing text in one step's `if`, `run` or env GH_TOKEN."""

    def mutate(steps):
        step = next(s for s in steps if step_key in (s.get("id"), s.get("name")))
        container = step["env"] if field_name == "env" else step
        key = "GH_TOKEN" if field_name == "env" else field_name
        assert old in container[key], f"mutant anchor {old!r} is not in {step_key}"
        container[key] = container[key].replace(old, new)
        return steps

    return mutate


def _trusting_guard(step_key):
    """The head guard both revokes had before: `|| echo ""` keeps an HTTP
    error body, and any non-empty answer reads as a moved head."""

    def mutate(steps):
        steps = _edit(
            step_key,
            "run",
            '--jq .head.sha 2>/dev/null) || now=""',
            '--jq .head.sha 2>/dev/null || echo "")',
        )(steps)
        return _edit(
            step_key,
            "run",
            '[[ "$now" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]]',
            '[ -n "$now" ]',
        )(steps)

    return mutate


def _scenario_risky_push(tmp_path, steps):
    return run_job(armed_by_a_clean_revision(tmp_path, steps), risky_push(), steps)


def _scenario_codex(tmp_path, steps, **fault):
    inputs = {"codex_check_name": CODEX_CHECK}
    stub = armed_by_a_clean_revision(tmp_path, steps, **inputs)
    return run_job(stub, risky_push(inputs=inputs, **fault), steps)


def _scenario_codex_success(tmp_path, steps):
    return _scenario_codex(tmp_path, steps, check_runs=((CODEX_CHECK, "success"),))


def _scenario_failed_codex_probe(tmp_path, steps):
    return _scenario_codex(tmp_path, steps, checks_read_fails=True)


def _scenario_relabel_after_revoke(tmp_path, steps):
    stub = armed_by_a_clean_revision(tmp_path, steps)
    run_job(stub, risky_push(), steps)
    return run_job(stub, risky_push(action="labeled", labels=(BYPASS_LABEL,)), steps)


def _scenario_stale_rerun_after_approval(tmp_path, steps):
    stub = armed_by_a_clean_revision(tmp_path, steps)
    run_job(stub, risky_push(), steps)
    run_job(stub, risky_push(action="labeled", labels=(BYPASS_LABEL,)), steps)
    return run_job(stub, risky_push(event_labels=()), steps)


def _scenario_unreadable_live_labels(tmp_path, steps):
    stub = armed_by_a_clean_revision(tmp_path, steps)
    return run_job(stub, risky_push(labels_fail_for=REVOKE), steps)


def _scenario_near_match_label(tmp_path, steps):
    stub = armed_by_a_clean_revision(tmp_path, steps)
    return run_job(stub, risky_push(labels=(f"not-{BYPASS_LABEL}",)), steps)


def _scenario_push_during_label_read(tmp_path, steps):
    stub = armed_by_a_clean_revision(tmp_path, steps)
    return run_job(stub, risky_push(head_moves_on_labels_read=REVOKE), steps)


def _scenario_bypass_input_with_a_newline(tmp_path, steps):
    inputs = {"risk_bypass_label": BYPASS_LABEL + "\n"}
    stub = armed_by_a_clean_revision(tmp_path, steps, **inputs)
    return run_job(stub, risky_push(inputs=inputs), steps)


def _label_match_by_grep(steps):
    """The `grep -qxF` match this replaced, which splits its pattern on
    newlines."""
    steps = _edit(
        REVOKE,
        "run",
        "while IFS= read -r live; do",
        'if grep -qxF -- "$BYPASS_LABEL" <<<"$live_labels"; then',
    )(steps)
    steps = _edit(
        REVOKE, "run", 'if [ "$live" = "$BYPASS_LABEL" ]; then', "if true; then"
    )(steps)
    return _edit(REVOKE, "run", 'done <<<"$live_labels"', "fi")(steps)


def _guard_before_the_label_read(steps):
    """The order before Codex round 6: the head guard, then the label read."""
    step = next(s for s in steps if s.get("id") == REVOKE)
    run = step["run"]
    label = run.index("# Exact string equality")
    guard = run.index("# The ownership check comes last")
    disarm = run.index("gh pr merge --disable-auto")
    assert label < guard < disarm, "mutant anchors out of order"
    step["run"] = run[:label] + run[guard:disarm] + run[label:guard] + run[disarm:]
    return steps


def _scenario_armed_risky(tmp_path, steps, **fault):
    return run_job(Stub(tmp_path), Revision(RISKY, armed=True, **fault), steps)


def _scenario_head_read_error(tmp_path, steps):
    return _scenario_armed_risky(tmp_path, steps, pr_read_fails=True)


def _scenario_unreadable_arm_state(tmp_path, steps):
    return _scenario_armed_risky(tmp_path, steps, pr_view_fails=True)


def _scenario_retry_through_unreadable_head(tmp_path, steps):
    return _scenario_armed_risky(
        tmp_path, steps, pr_read_fails=True, disarm_fails_once=True
    )


def _arm_disarms_under_gh_token(steps):
    """The arm step before the bot-first disarm: every disarm ran under
    GH_TOKEN, which is the PAT whenever the caller passes one."""
    step = next(s for s in steps if s.get("id") == ARM)
    assert step["env"]["BOT_TOKEN"] == "${{ github.token }}", "mutant anchor moved"
    step["env"]["BOT_TOKEN"] = step["env"]["GH_TOKEN"]
    return steps


def _scenario_clean_push_after_a_stand_down(tmp_path, steps):
    stub = armed_by_a_clean_revision(tmp_path, steps)
    run_job(stub, retargeted_push(), steps)
    return run_job(stub, clean_push(), steps)


def _scenario_stand_down(tmp_path, steps, **fault):
    stub = armed_by_a_clean_revision(tmp_path, steps)
    return run_job(stub, retargeted_push(**fault), steps)


def _scenario_stand_down_through_a_transient_failure(tmp_path, steps):
    return _scenario_stand_down(tmp_path, steps, disarm_fails_once=True)


def _scenario_stand_down_the_bot_cannot_disarm(tmp_path, steps):
    return _scenario_stand_down(tmp_path, steps, bot_cannot_disarm=True)


@pytest.mark.parametrize(
    "mutate, scenario, broken",
    [
        pytest.param(
            lambda steps: [s for s in steps if s.get("id") != REVOKE],
            _scenario_risky_push,
            lambda job: job.arm == "ON" and job.disables == 0,
            id="no-revoke-step",
        ),
        pytest.param(
            _edit(REVOKE, "if", "&& steps.bypass_codex.outputs.bypass != '1'", ""),
            _scenario_codex_success,
            lambda job: job.disarmed_by == [(REVOKE, GITHUB_TOKEN)],
            id="revoke-ignores-codex",
        ),
        pytest.param(
            _edit(REVOKE, "env", "github.token", "secrets.automerge_pat"),
            _scenario_relabel_after_revoke,
            lambda job: job.out("hold").get("hold") == "1" and job.arm == "OFF",
            id="revoke-as-the-pat",
        ),
        pytest.param(
            _trusting_guard(REVOKE),
            _scenario_head_read_error,
            lambda job: job.arm == "ON" and job.disables == 0,
            id="guard-trusts-any-answer",
        ),
        pytest.param(
            _edit(REVOKE, "run", '[ "$state" != "OFF" ]', '[ "$state" = "ON" ]'),
            _scenario_unreadable_arm_state,
            lambda job: job.outcome(REVOKE) == "success" and RISK_LABEL in job.labels,
            id="on-only-verification",
        ),
        pytest.param(
            _edit(REVOKE, "run", 'if [ -n "$BYPASS_LABEL" ]; then', "if false; then"),
            _scenario_stale_rerun_after_approval,
            lambda job: job.disarmed_by == [(REVOKE, GITHUB_TOKEN)],
            id="revoke-ignores-a-live-bypass-label",
        ),
        pytest.param(
            _edit(
                REVOKE,
                "run",
                '2>/dev/null) || live_labels=""',
                "2>/dev/null) || exit 0",
            ),
            _scenario_unreadable_live_labels,
            lambda job: job.arm == "ON" and job.disables == 0,
            id="live-label-check-fails-open",
        ),
        pytest.param(
            _edit(
                REVOKE,
                "run",
                'if [ "$live" = "$BYPASS_LABEL" ]; then',
                'if [[ "$live" == *"$BYPASS_LABEL"* ]]; then',
            ),
            _scenario_near_match_label,
            lambda job: job.arm == "ON" and job.disables == 0,
            id="label-match-by-substring",
        ),
        pytest.param(
            _label_match_by_grep,
            _scenario_bypass_input_with_a_newline,
            lambda job: job.arm == "ON" and job.disables == 0,
            id="label-match-by-grep-xF",
        ),
        pytest.param(
            _guard_before_the_label_read,
            _scenario_push_during_label_read,
            lambda job: job.disarmed_by == [(REVOKE, GITHUB_TOKEN)],
            id="head-guard-before-the-label-read",
        ),
        pytest.param(
            _edit(
                RISK_COMMENT, "if", " &&\nsteps.risk_revoke.outputs.arm_off == '1'", ""
            ),
            _scenario_stale_rerun_after_approval,
            lambda job: job.outcome(RISK_COMMENT) == "success",
            id="comment-without-a-verified-revoke",
        ),
        pytest.param(
            _edit(ERROR_REVOKE, "if", "steps.bypass_codex.outcome == 'failure' ||", ""),
            _scenario_failed_codex_probe,
            lambda job: job.arm == "ON" and job.disables == 0,
            id="error-revoke-ignores-a-failed-codex-probe",
        ),
        pytest.param(
            _trusting_guard(ERROR_REVOKE),
            _scenario_retry_through_unreadable_head,
            lambda job: job.arm == "ON" and job.disarmed_by == [],
            id="error-revoke-guard-trusts-any-answer",
        ),
        pytest.param(
            _arm_disarms_under_gh_token,
            _scenario_clean_push_after_a_stand_down,
            lambda job: job.out("hold").get("reason") == "timeline:human-disable-newest"
            and job.arms == 0,
            id="arm-disarms-as-the-pat",
        ),
        pytest.param(
            _edit(
                ARM,
                "run",
                'for _ in 1 2 3; do\n    GH_TOKEN="$1"',
                'for _ in 1; do\n    GH_TOKEN="$1"',
            ),
            _scenario_stand_down_through_a_transient_failure,
            lambda job: job.disarmed_by == [(ARM, PAT)],
            id="arm-disarm-without-bot-retries",
        ),
        pytest.param(
            _edit(ARM, "run", 'disarm_as "$GH_TOKEN"', "return 1"),
            _scenario_stand_down_the_bot_cannot_disarm,
            lambda job: job.arm == "ON",
            id="arm-disarm-without-the-pat-fallback",
        ),
    ],
)
def test_a_mutated_workflow_breaks_what_its_case_pins(
    tmp_path, mutate, scenario, broken
):
    job = scenario(tmp_path, mutate(copy.deepcopy(STEPS)))
    assert broken(job), f"the mutant went unnoticed by the case that pins it:\n{job}"


# ---------------------------------------------------------------------------
# 7. The arm binds to the head the risk-tier step listed.
# ---------------------------------------------------------------------------
def test_a_head_that_came_back_is_not_armed_on_the_risk_tier_verdict(tmp_path):
    """A → B → A. The event's head A adds src/auth/login.py; B, a [skip ci]
    revert of it that starts no run to cancel this one, is the head while
    the risk-tier step lists, so that verdict is clean; A is pushed back
    before the arm step. --match-head-commit then matches A, the event's
    head, so binding only to that armed A on a verdict about B's files."""
    stub = Stub(tmp_path)
    job = run_job(
        stub,
        Revision(
            CLEAN,  # B's diff, which is what the risk-tier step lists
            head_sha="2" * 40,  # B, the live head while the gates list
            event_head_sha="1" * 40,  # A, the event's head
            head_returns_on_arm=True,  # A is back as the arm step starts
        ),
    )
    assert job.arms == 0 and job.arm == "OFF", (
        f"the run armed its event's head on a verdict about another head's files:\n{job}"
    )
    assert job.out("risk").get("risky") == "0", str(job)
    assert job.out("risk").get("classified_head") == "2" * 40, str(job)
    assert job.outcome("arm") == "success" and "armed" not in job.out("arm"), str(job)


def test_the_risk_tier_step_reads_its_head_before_it_lists(tmp_path):
    """The recorded head binds the listing only if it is read first: read
    after the listing, a head that moved during it would pass for the head
    the listing saw."""
    job = run_job(Stub(tmp_path), Revision(CLEAN))
    calls = [" ".join(c["argv"]) for c in job.state["calls"] if c["step"] == "risk"]
    head = next((i for i, c in enumerate(calls) if "--jq .head.sha" in c), None)
    listing = next((i for i, c in enumerate(calls) if "/files" in c), None)
    assert head is not None and listing is not None and head < listing, (
        f"the risk-tier step did not read its head before listing:\n{job}"
    )
    assert job.out("risk").get("classified_head") == "a" * 40, str(job)


def test_a_risk_tier_verdict_with_no_head_is_disarmed_as_github_actions(tmp_path):
    """The risk-tier step keeps its verdict when it cannot read the head, and
    the arm step then refuses to arm on it. The disarm must be the error
    revoke's: github-actions[bot] behind its head guard. A disarm in the arm
    step runs with the caller's PAT, which the hold step reads as a human's
    durable hold, so one API blip would leave the PR unarmed for good."""
    stub = armed_by_a_clean_revision(tmp_path)
    job = run_job(stub, Revision(CLEAN, head_sha="2" * 40, pr_read_fails_for="risk"))
    assert job.out("risk").get("risky") == "0", str(job)
    assert "classified_head" not in job.out("risk"), str(job)
    assert job.outcome("arm") == "failure" and job.arms == 0, str(job)
    assert job.arm == "OFF" and job.disarmed_by == [(ERROR_REVOKE, GITHUB_TOKEN)], (
        f"the unbound verdict was not disarmed by the error revoke as github-actions[bot]:\n{job}"
    )
