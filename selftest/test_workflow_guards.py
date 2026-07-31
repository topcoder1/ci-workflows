"""Run the shell selftests under pytest.

tests-runner.yml's self-test path executes `uv run pytest -q` on this
repo's own PRs, so wrapping the .sh selftests here is what makes them
CI-enforced rather than run-manually-only documentation.
"""

import pathlib
import re
import subprocess

import pytest

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
WORKFLOWS_DIR = REPO_ROOT / ".github" / "workflows"


# test_bb_automerge_risk_patterns.sh is deliberately absent: it resolves
# bb-automerge.py from the local ~/.claude/templates checkout and imports
# `requests`, neither of which exists on this repo's CI runner. Run it
# manually on a workstation.
@pytest.mark.parametrize(
    "script",
    [
        "selftest/test_automerge_base_gate.sh",
        "selftest/test_automerge_hold_gate.sh",
        "selftest/test_automerge_risk_patterns.sh",
        "selftest/test_automerge_riskfile_gate.sh",
        "selftest/test_classify_bracket_guard.sh",
        "selftest/test_classify_nocase.sh",
        "selftest/test_codex_verdict_gate.sh",
        "selftest/test_pr_files_listing.sh",
        "selftest/test_prettier_scope_failsafe.sh",
        "selftest/test_prettier_symlink_filter.sh",
        "selftest/test_safe_paths_unsafe_overrides.sh",
    ],
)
def test_shell_selftest(script):
    proc = subprocess.run(
        ["bash", script], cwd=REPO_ROOT, capture_output=True, text=True
    )
    assert proc.returncode == 0, f"{script} failed:\n{proc.stdout}\n{proc.stderr}"


def test_codex_verdict_gate_is_wired_and_opt_in():
    """codex-review.yml must enforce Codex's verdict only when asked to.

    The gate's logic is executed by selftest/test_codex_verdict_gate.sh;
    this pins the workflow wiring around it, which that test cannot see.

    Three properties, each with a real failure mode:

    1. `default: false`. This reusable has 27 consumers on `@main`. A
       default-on gate would start failing their PRs on Codex advisories
       the moment this merges.
    2. The input actually reaches the script. If the env binding is dropped
       the script silently runs report-only forever — the opted-in repo
       believes it is gated and is not. That is worse than no gate.
    3. The evaluation runs AFTER the comment is posted. Failing first would
       leave the PR with a red X and no visible explanation of what Codex
       found.
    """
    text = (WORKFLOWS_DIR / "codex-review.yml").read_text()

    assert "fail_on_regression:" in text, (
        "codex-review.yml must declare the fail_on_regression input"
    )
    # The default lives in the input block; check it is the false literal and
    # not merely mentioned in the description prose.
    m = re.search(
        r"fail_on_regression:.*?^        default:\s*(\S+)", text, flags=re.S | re.M
    )
    assert m, "could not read fail_on_regression's default"
    assert m.group(1) == "false", (
        f"fail_on_regression must default to false, got {m.group(1)!r} — 27 "
        "repos consume this reusable via @main"
    )

    assert "FAIL_ON_REGRESSION: ${{ inputs.fail_on_regression }}" in text, (
        "the input must be bound to the script's FAIL_ON_REGRESSION env var — "
        "without it an opted-in repo runs report-only and believes it is gated"
    )
    assert "codex-verdict.mjs" in text, (
        "codex-review.yml must fetch and run codex-verdict.mjs"
    )

    # The prompt and the parser are one contract. codex-verdict.mjs reads the
    # `VERDICT:` trailer and fails closed without it, so a prompt edit that
    # drops the instruction would fail every enforced repo's PRs — and it
    # would look like Codex breaking, not like an edit here.
    assert "VERDICT: CLEAN" in text and "VERDICT: REGRESSION" in text, (
        "the review prompt must require the VERDICT: trailer — codex-verdict.mjs "
        "reads it and fails closed when it is absent"
    )

    # The gate must read the UNtruncated verdict. The `VERDICT:` trailer is the
    # last line, and the 4KB comment cap is a prefix cut — pointing the gate at
    # the capped file would classify any long-but-clean review as no_verdict and
    # fail an enforced PR closed. (Codex review round 3.)
    assert "VERDICT_FILE: /tmp/codex.verdict.full" in text, (
        "the verdict gate must read the untruncated verdict file — the 4KB cap "
        "is for the PR comment and would drop the trailer the gate reads"
    )
    # And the cap must truncate from a file, not a pipe. In the `... | head -c`
    # form head exits at its limit and the writer takes SIGPIPE, which pipefail
    # turns into a failed step. Measured, that needs the verdict to outgrow the
    # OS pipe buffer (fine at 128KB, aborts at 2MB), so this is hygiene rather
    # than a live failure at realistic verdict sizes — kept because the file
    # form is free and this shell trap has bitten the fleet before. Comments are
    # stripped so naming the anti-pattern in prose does not trip the guard.
    code = "\n".join(
        line for line in text.splitlines() if not line.lstrip().startswith("#")
    )
    assert not re.search(r"\|\s*head -c", code), (
        "truncate from a FILE (`head -c N file`), never `... | head -c N` — "
        "the early pipe close SIGPIPEs the writer and pipefail fails the step"
    )

    comment_at = text.find("gh pr comment")
    evaluate_at = text.find("node .github/scripts/codex-verdict.mjs")
    assert comment_at != -1 and evaluate_at != -1
    assert comment_at < evaluate_at, (
        "the verdict evaluation must run after the review comment is posted, "
        "so a failing job still shows the reader what Codex found"
    )


def test_codex_review_covers_every_automergeable_class():
    """Codex must review every risk class that can merge unread.

    2026-07-26 (whois-api-llc/wxa_vpn): pr-codex-review.yml gated on
    `risk_class == 'sensitive'` alone, but `standard` is BOTH the default
    class for ordinary src/** work AND a class claude-author-automerge.yml
    will auto-merge. #1270 (+839 lines under src/**) and #1273 (+786) both
    classified `standard`, passed CI clean, and never saw Codex; a manual
    run on #1270 afterwards found four P1s, including a forgeable-identity
    hole that let a customer attribute a leaked artifact to a competitor.

    `blocked` is intentionally NOT required here — it cannot auto-merge, so
    a human is already the gate.

    Spend is bounded downstream by codex-gate.mjs (small-diff and
    docs/tests-only skips), so this assertion is about coverage, not cost.
    """
    text = (WORKFLOWS_DIR / "pr-codex-review.yml").read_text()
    # Strip comments so a class named only in prose can't satisfy the gate.
    code = "\n".join(
        line for line in text.splitlines() if not line.lstrip().startswith("#")
    )
    for risk_class in ("sensitive", "standard"):
        assert f"risk_class == '{risk_class}'" in code, (
            f"pr-codex-review.yml must run Codex on risk:{risk_class} — it is "
            "auto-mergeable, so nothing else guarantees a second reader"
        )


def test_standard_codex_lane_cannot_satisfy_the_automerge_bypass():
    """The risk:standard Codex lane must not publish the bypass-trusted check.

    claude-author-automerge.yml bypasses its risk-tier manual-merge gate when
    the check named by `codex_check_name` (default "review / Codex Review")
    concludes SUCCESS. That check name is "<job id> / Codex Review".

    The bypass trusts a CONCLUSION, not a review: when codex-gate.mjs skips
    (small diff, or docs/tests-only), the review steps are skipped but the
    job still concludes `success`. So routing risk:standard through job id
    `review` would let a small change to an auth/billing/migration path —
    classified `standard` because the repo's risk-paths.yml `sensitive:`
    list is empty, yet flagged risky=1 by the central regex — auto-merge
    with Codex having read nothing. Today that combination has no Codex
    check at all, so the risk gate holds.

    Keep the two lanes on distinct job ids. (Codex review round 2 caught
    this on the first draft of the standard-class widening, 2026-07-27.)
    """
    text = (WORKFLOWS_DIR / "pr-codex-review.yml").read_text()

    def job_id_for(risk_class):
        # Job ids are top-level (2-space) keys under `jobs:`; find the one
        # whose body gates on this risk class.
        current, found = None, None
        for line in text.splitlines():
            m = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
            if m:
                current = m.group(1)
            if (
                not line.lstrip().startswith("#")
                and f"risk_class == '{risk_class}'" in line
            ):
                found = current
        return found

    sensitive_job = job_id_for("sensitive")
    standard_job = job_id_for("standard")
    assert sensitive_job, "no job gates on risk_class == 'sensitive'"
    assert standard_job, "no job gates on risk_class == 'standard'"
    assert sensitive_job != standard_job, (
        "risk:standard and risk:sensitive must run in DIFFERENT jobs — a "
        "shared job id publishes the bypass-trusted check name for standard "
        f"PRs too (both are '{sensitive_job}')"
    )

    # And the standard lane's id must not be the one claude-author-automerge
    # trusts by default.
    automerge = (WORKFLOWS_DIR / "claude-author-automerge.yml").read_text()
    m = re.search(r'default:\s*"([^"]*?)\s*/\s*Codex Review"', automerge)
    assert m, "could not read codex_check_name default from claude-author-automerge.yml"
    trusted_job = m.group(1).strip()
    assert standard_job != trusted_job, (
        f"the risk:standard lane uses job id '{standard_job}', which is the "
        f"bypass-trusted check name '{trusted_job} / Codex Review' — a "
        "cost-gated SKIP would then read as a passed review and bypass the "
        "risk-tier manual-merge gate"
    )


def test_safe_paths_never_automerges_customer_facing_legal():
    """docs/legal/** must be excluded from the docs safe-paths carve-out.

    2026-07-25 (whois-api-llc/wxa_vpn#1268): an Acceptable Use Policy change
    matched the built-in `^docs/.*` glob and auto-merged unreviewed. This
    workflow decides on diff content alone and never consults the risk
    classifier, so a caller's risk-paths.yml `sensitive:` list cannot close
    the hole — the override list in the workflow is the only gate.

    Behavior is pinned by selftest/test_safe_paths_unsafe_overrides.sh; this
    asserts the override list itself did not quietly lose the entry.
    """
    text = (WORKFLOWS_DIR / "safe-paths-automerge.yml").read_text()
    assert "unsafe_overrides='^docs/legal/'" in text, (
        "safe-paths-automerge.yml must keep docs/legal/ in unsafe_overrides — "
        "customer-facing legal wording is not revertable in one cycle"
    )

    # Rename bypass: the pull-files API reports only the DESTINATION in
    # .filename, so moving docs/legal/aup.md to docs/archive/ would read as
    # an ordinary docs change without this. (Codex review round 1.)
    assert "previous_filename" in text, (
        "the override must also match rename SOURCES (.previous_filename) — "
        "otherwise moving a legal doc out of docs/legal/ auto-merges"
    )

    # Already-armed bypass: GitHub preserves an auto-merge request across
    # pushes, so computing all_safe=0 does not disarm a PR armed on an
    # earlier safe revision. (Codex review round 5.)
    assert "--disable-auto" in text, (
        "safe-paths-automerge.yml must REVOKE an existing auto-merge arm when "
        "an unsafe-override path appears — recomputing all_safe=0 leaves a "
        "previously-armed PR armed, and the legal change merges anyway"
    )
    assert "steps.classify.outputs.reason == 'unsafe-override'" in text, (
        "the revoke must be scoped to the override branch only — revoking on "
        "every all_safe=0 would fight the workflows that legitimately arm"
    )
    # A legal path can hide past the API's 3000-entry cap: the override scan
    # sees no hit, but the revision cannot be proven clean either, so an arm
    # from an earlier safe revision must not survive. (Codex round 10.)
    assert "steps.classify.outputs.reason == 'file-list-truncated'" in text, (
        "revoke must also fire on a truncated file list — a docs/legal/ path "
        "beyond the 3000-entry cap would otherwise keep a stale arm alive"
    )

    # The central risk scan is the DURABLE gate (it decides before arming,
    # so it has no revoke race). It must see rename sources too, or moving a
    # legal doc out of docs/legal/ escapes it. (Codex review round 9.)
    automerge = (WORKFLOWS_DIR / "claude-author-automerge.yml").read_text()
    assert "^docs/legal/.*" in automerge, (
        "claude-author-automerge.yml's risk patterns must include "
        "^docs/legal/.* — safe-paths revocation alone races this workflow's arm"
    )
    assert "previous_filename" in automerge, (
        "the risk scan must also match rename SOURCES — otherwise moving a "
        "risky file to a safe path escapes the gate"
    )


def test_no_global_git_config_writes_in_workflows():
    """No reusable may write to global git config.

    2026-07-16 (wxa-secrets#28 codex review): tests-runner.yml and
    coverage-floor.yml wrote AUTOMERGE_PAT into a global insteadOf rewrite
    before running PR-controlled code (uv sync build hooks, pytest) on
    pull_request events — any same-repo PR could read the cross-org PAT
    via `git config --global --get-regexp url` and exfiltrate it.
    Credentials must go into a scoped throwaway file (GIT_CONFIG_GLOBAL
    pointed at $RUNNER_TEMP) that is deleted before the default test
    invocation (the test_command override path scrubs afterward and accepts
    the wider window).
    """
    offenders = [
        wf.name
        for wf in sorted(WORKFLOWS_DIR.glob("*.yml"))
        if "git config --global" in wf.read_text()
    ]
    assert not offenders, (
        f"global git config writes in {offenders} — use a scoped "
        "GIT_CONFIG_GLOBAL temp file scrubbed before the default test run"
    )


def test_lint_never_runs_python_m_with_the_checkout_as_cwd():
    """lint.yml must not invoke `python -m <module>` from the checkout.

    `python3 -m X` prepends the CWD to sys.path (sys.path[0]), so with the
    checkout as CWD a top-level `pip.py` / `pip/` in PR content shadows the
    installed pip and executes on the runner. The shim picks its own exit
    code, so it can report SUCCESS and leave no trace in the check. Verified
    locally: a `pip.py` dropped beside the workflow's CWD ran with
    argv=['...', 'install', '--quiet', 'pyyaml'] and exited 0.

    Codex rated this exact pattern P1 on PR #137, where the new ruff job
    reached it via `python3 -m pip install ruff`; that job now uses pipx.
    pyyaml is an import dependency rather than a console tool, so pipx does
    not apply to the draft-gate checker — it runs the install from
    $RUNNER_TEMP instead.

    The escape must use the `${RUNNER_TEMP:?...}` form, not a bare
    "$RUNNER_TEMP". Measured: bash's `cd ""` is a no-op that returns 0 and
    stays in the current directory, so an empty RUNNER_TEMP would silently
    run the install from the checkout again — the same hole, reported green.
    Accepting only the :? form keeps the failure mode closed.

    Only that one form is accepted, so an equally safe step-level
    `working-directory: ${{ runner.temp }}` is rejected too. Deliberate: the
    guard fails CLOSED and its message names the accepted form, so the cost
    is one conversation, while a second accepted spelling is more surface to
    keep correct. (Codex review round 1 raised the false positive.)

    Scoped to lint.yml deliberately. It is a CHECKER workflow: actionlint,
    the draft-gate checker, prettier (--ignore-scripts) and ruff (pipx) all
    hold the property that no checkout content is ever executed, so a
    shadowed import is the whole attack. The repo's other `python -m` sites
    are not in that class and are intentionally excluded:
    tty-tests.yml runs `python -m pytest` on the PR's own test files, and
    the `python -m venv` calls in tests-runner.yml / coverage-floor.yml sit
    directly above `pip install -r requirements.txt`, which already executes
    PR-declared build hooks (an exposure the credential-scrub guard above
    documents and accepts). Shadowing gains an attacker nothing in a job
    whose purpose is to run checkout content.
    """
    text = (WORKFLOWS_DIR / "lint.yml").read_text()
    # Order matters: drop whole-line comments FIRST, then fold continuations.
    # Comments go first so prose naming the anti-pattern cannot trip the
    # guard. Folding must come second because a comment ending in `\` does
    # NOT continue in shell, but a fold-first pass would splice the next
    # (real) line into the comment and then discard it -- hiding a live
    # invocation. (Codex review round 2.)
    code = []
    for line in text.splitlines():
        if line.lstrip().startswith("#"):
            continue
        # INLINE comments go too, for the same reason and one more: a `\`
        # inside one does not continue the line in shell, but folding would
        # splice the next line onto it and let the comment's text stand in
        # for real code -- `echo ok # cd "${RUNNER_TEMP:?fake}" \` would
        # lend a fake escape to the command below it. (Codex round 4.)
        code.append(re.sub(r"(?<=\s)#.*$", "", line))
    # Now rejoin `python3 \` + newline + `-m pip`, which would otherwise
    # split one invocation across two lines and slip past a line scan.
    folded = re.sub(r"\\\n[ \t]*", " ", "\n".join(code)).splitlines()

    escape = 'cd "${RUNNER_TEMP:?'
    offenders = []
    for line in folded:
        # Anything from `python`/`python3` up to the next command separator,
        # then `-m`. Matching `-m` immediately after the interpreter would
        # miss interpreter flags -- `python3 -B -m pip` and
        # `python3 -X importtime -m pip` are equally vulnerable.
        # (Codex review round 2.)
        invocation = re.search(r"\bpython3?\b[^;&|]*?\s-m\s+\S", line)
        if not invocation:
            continue
        # The escape must come BEFORE the invocation on the line. A trailing
        # comment that merely mentions it -- `python3 -m pip ...  # cd
        # "${RUNNER_TEMP:?` -- runs from the checkout and must not pass.
        escaped_at = line.find(escape)
        if escaped_at == -1 or escaped_at > invocation.start():
            offenders.append(line.strip())
            continue
        # ...and the invocation must still be inside that subshell, gated on
        # the cd having SUCCEEDED. Two ways to lose that while keeping the
        # text in place, both plausible as accidental edits:
        #   `(cd "${RUNNER_TEMP:?x}") && python3 -m pip ...`  -- subshell
        #     closes first, so the CWD is the checkout again (round 3)
        #   `cd "${RUNNER_TEMP:?x}" || python3 -m pip ...`    -- runs python
        #     precisely when the cd FAILED (round 6)
        # So: no `)` may close the group before the invocation, and the two
        # must be joined by `&&`.
        span = line[escaped_at : invocation.start()]
        if ")" in span or "&&" not in span:
            offenders.append(line.strip())
    assert not offenders, (
        "lint.yml runs `python -m <module>` with the checkout as CWD, so PR "
        "content can shadow the module and execute on the runner:\n  "
        + "\n  ".join(offenders)
        + "\nRun it outside the checkout, failing closed on an empty var:"
        + '\n  (cd "${RUNNER_TEMP:?RUNNER_TEMP is not set}" && python3 -m ...)'
    )


@pytest.mark.parametrize("workflow", ["tests-runner.yml", "coverage-floor.yml"])
def test_scoped_git_credential_gated_and_scrubbed(workflow):
    """The cross-org git credential must be (a) opt-in on pull_request
    events, (b) written to a scoped file, and (c) deleted before the DEFAULT
    test invocation, which executes PR-controlled code and must not be able
    to re-resolve dependencies. (A caller `test_command` runs install+tests
    as one command and is scrubbed only afterward — the wider window is
    accepted for that path, so this guard only checks the default
    invocations.)"""
    text = (WORKFLOWS_DIR / workflow).read_text()

    # (a) The credential is ALLOWLIST-gated: auto-materialized only on a
    # push to the default branch (post-review code); every other event —
    # PRs, branch pushes, schedule, workflow_dispatch — needs the explicit
    # caller opt-in input. Denylist forms ("not a PR") regressed this once
    # (codex round-2 P1).
    assert "inputs.use_pat_for_git_deps" in text, workflow
    allowlist = (
        "github.event_name == 'push' && github.ref == "
        "format('refs/heads/{0}', github.event.repository.default_branch)"
    )
    assert allowlist in text, workflow

    # (b) The credential lives in a scoped throwaway file, not ~/.gitconfig,
    # and a least-privilege GIT_DEPS_PAT (fine-grained read-only) wins over
    # the fleet-wide AUTOMERGE_PAT when forwarded.
    assert 'CROSS_ORG_GITCONFIG="$RUNNER_TEMP/cross-org-gitconfig"' in text, workflow
    assert "secrets.GIT_DEPS_PAT || secrets.AUTOMERGE_PAT" in text, workflow

    # (c) Every install branch (test_command / uv / pip fallback) scrubs the
    # credential, and each test invocation is LOCALLY preceded by a scrub
    # with no install command in between. A global first-scrub-vs-last-
    # invocation comparison would still pass if one branch's scrub moved
    # below its own pytest (codex round-4 P2), so check per invocation.
    scrub = 'rm -f "$CROSS_ORG_GITCONFIG"; unset GIT_CONFIG_GLOBAL'
    assert text.count(scrub) >= 3, (
        f"{workflow}: every install branch must scrub the scoped credential "
        "(before the default test invocation; test_command scrubs afterward)"
    )
    invocations = {
        "tests-runner.yml": ["uv run --no-sync pytest -q", ".venv/bin/pytest -q"],
        "coverage-floor.yml": [
            "uv run --no-sync pytest --cov",
            ".venv/bin/pytest --cov",
        ],
    }[workflow]
    install_markers = ("uv sync", "pip install", 'eval "$INPUT_TEST_COMMAND"')
    for marker in invocations:
        # Line-anchored so header/comment mentions of the command don't
        # count as invocations.
        sites = [
            m.start()
            for m in re.finditer(rf"^\s*{re.escape(marker)}", text, flags=re.M)
        ]
        assert sites, f"{workflow}: expected test invocation {marker!r} not found"
        for pos in sites:
            last_scrub = text.rfind(scrub, 0, pos)
            assert last_scrub != -1, (
                f"{workflow}: no credential scrub precedes {marker!r}"
            )
            last_install = max(text.rfind(i, 0, pos) for i in install_markers)
            assert last_scrub > last_install, (
                f"{workflow}: an install command sits between the scrub and "
                f"{marker!r} — credential would be reachable by PR-controlled "
                "test code"
            )

    # Regression trip-wire: a plain `uv run pytest` implicitly re-syncs the
    # environment, which would re-fetch git deps mid-test-invocation.
    assert "uv run pytest" not in text, (
        f"{workflow}: test invocation must be `uv run --no-sync pytest` so "
        "tests can never trigger a credential-needing re-resolve"
    )
