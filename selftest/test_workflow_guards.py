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
        "selftest/test_classify_exclude.sh",
        "selftest/test_classify_nocase.sh",
        "selftest/test_codex_verdict_gate.sh",
        "selftest/test_pr_files_listing.sh",
        "selftest/test_prettier_scope_failsafe.sh",
        "selftest/test_prettier_symlink_filter.sh",
        "selftest/test_ruff_ruleset_warning.sh",
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


PYTHON_M_ESCAPE = 'cd "${RUNNER_TEMP:?'


def checkout_cwd_python_invocations(text):
    """Return the `python -m` invocations in `text` that run from the CWD.

    Shared by the lint.yml guard below and by its own vacuum test, so the
    shapes that test pins are the same code path the guard runs.
    """
    # Order matters: drop comments FIRST, then fold continuations. Comments
    # go first so prose naming the anti-pattern cannot trip the guard, and
    # because a `\` inside a comment does NOT continue the line in shell --
    # a fold-first pass would splice the next real line into the comment and
    # then discard it, hiding a live invocation. Inline comments go too, or
    # `echo ok # cd "${RUNNER_TEMP:?fake}" \` lends a fake escape to the
    # command below it. (Codex review rounds 2 and 4.)
    code = []
    for line in text.splitlines():
        if line.lstrip().startswith("#"):
            continue
        code.append(re.sub(r"(?<=\s)#.*$", "", line))
    # Now rejoin `python3 \` + newline + `-m pip`, which would otherwise
    # split one invocation across two lines and slip past a line scan.
    folded = re.sub(r"\\\n[ \t]*", " ", "\n".join(code)).splitlines()

    offenders = []
    for line in folded:
        # Anything from `python`/`python3` up to the next command separator,
        # then `-m`. Matching `-m` immediately after the interpreter would
        # miss interpreter flags -- `python3 -B -m pip` and
        # `python3 -X importtime -m pip` are equally vulnerable. EVERY match
        # is checked, not just the first: a second command can sit past the
        # closed subshell and run from the checkout.
        # (Codex review rounds 2 and 8.)
        for invocation in re.finditer(r"\bpython3?\b[^;&|]*?\s-m\s+\S", line):
            # The escape must come BEFORE this invocation; take the NEAREST
            # preceding one so each invocation is judged against the cd that
            # actually governs it. A trailing comment merely mentioning it --
            # `python3 -m pip ...  # cd "${RUNNER_TEMP:?` -- runs from the
            # checkout and must not pass.
            escaped_at = line.rfind(PYTHON_M_ESCAPE, 0, invocation.start())
            if escaped_at == -1:
                offenders.append(line.strip())
                break
            # ...and the invocation must still be inside that subshell, gated
            # on the cd having SUCCEEDED. Two ways to lose that while keeping
            # the text in place, both plausible as accidental edits:
            #   `(cd "${RUNNER_TEMP:?x}") && python3 -m pip ...`  -- subshell
            #     closes first, so the CWD is the checkout again (round 3)
            #   `cd "${RUNNER_TEMP:?x}" || python3 -m pip ...`    -- runs
            #     python precisely when the cd FAILED (round 6)
            span = line[escaped_at : invocation.start()]
            if ")" in span or "&&" not in span:
                offenders.append(line.strip())
                break
    return offenders


# The safe form, and every unsafe shape a review round found slipping past an
# earlier version of the scanner. Pinned by the vacuum test below: this guard
# went through five rounds of evasions, so "it passes" means nothing without
# evidence it still rejects what it is supposed to reject.
SAFE_INSTALL = (
    '        run: (cd "${RUNNER_TEMP:?RUNNER_TEMP is not set}"'
    " && python3 -m pip install --quiet pyyaml)"
)
UNSAFE_INSTALLS = {
    "original bug": "        run: python3 -m pip install --quiet pyyaml",
    "bare $RUNNER_TEMP (cd '' is a no-op returning 0)": (
        '        run: (cd "$RUNNER_TEMP" && python3 -m pip install --quiet pyyaml)'
    ),
    "trailing-comment ruse": (
        '        run: python3 -m pip install --quiet pyyaml  # cd "${RUNNER_TEMP:?x}"'
    ),
    "line-continuation split": (
        "        run: python3 \\\n          -m pip install --quiet pyyaml"
    ),
    "comment ending in a backslash": (
        "        run: |\n          # install the dep \\\n"
        "          python3 -m pip install --quiet pyyaml"
    ),
    "interpreter flag before -m": (
        "        run: python3 -B -m pip install --quiet pyyaml"
    ),
    "-X flag with a value": (
        "        run: python3 -X importtime -m pip install --quiet pyyaml"
    ),
    "subshell closed before python runs": (
        '        run: (cd "${RUNNER_TEMP:?x}") && python3 -m pip install --quiet pyyaml'
    ),
    "inline-comment fake escape": (
        '        run: |\n          echo ok # cd "${RUNNER_TEMP:?fake}" \\\n'
        "          python3 -m pip install --quiet pyyaml"
    ),
    "|| runs python exactly when the cd failed": (
        '        run: cd "${RUNNER_TEMP:?x}" || python3 -m pip install --quiet pyyaml'
    ),
    "second invocation past the closed subshell": (
        '        run: (cd "${RUNNER_TEMP:?x}" && python3 -m pip install --quiet pyyaml)'
        " && python3 -m pip check"
    ),
}


@pytest.mark.parametrize("shape", UNSAFE_INSTALLS.values(), ids=UNSAFE_INSTALLS.keys())
def test_checkout_cwd_scanner_rejects_every_known_unsafe_shape(shape):
    """The scanner must not go vacuous.

    Each shape here slipped past some earlier version of it and would have
    run pip from the checkout. A refactor that stops catching one of these
    turns the guard below into decoration that reports green forever.
    """
    assert checkout_cwd_python_invocations(shape), (
        f"scanner no longer flags an unsafe shape:\n{shape}"
    )


def test_checkout_cwd_scanner_accepts_the_safe_form():
    """...and it must not reject the form the workflow actually ships."""
    assert not checkout_cwd_python_invocations(SAFE_INSTALL)


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
    offenders = checkout_cwd_python_invocations(
        (WORKFLOWS_DIR / "lint.yml").read_text()
    )
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


def test_lint_ruff_is_opt_in_and_mirrors_preflight_scope():
    """lint.yml's ruff job must stay opt-in and scope-matched to bb-preflight.

    Motivation (2026-07-31, topcoder1/dotclaude — fixed by its #183):
    bb-preflight.sh runs `ruff check` locally and verdicts NOT READY on any
    violation, but no CI lane ran ruff at all — an F541 merged to main with
    every check green, after which every LOCAL preflight was blocked while
    CI stayed green. The fix is the lint.yml ruff job; these properties
    keep it safe:

    1. `default: false`. Consumers opted into lint checks one at a time; a
       default-on ruff would redden every Python consumer's PRs the moment
       it merges (same rule the codex verdict gate pins above).
    2. The enable-guard uses the format() stringify dodge (GHA `==` does
       loose numeric coercion, so `true == null` comparisons lie), the
       input is actually bound into the run step, and the always-on
       self-test arm stays pinned to this repo.
    3. Scope parity: with no explicit ruff_paths the job must scan src/
       and tests/ when present, else the repo root — the exact PYTHON_DIRS
       logic in bb-preflight.sh. A wider CI scope re-opens the asymmetry
       in the other direction (preflight says READY, push, CI blocks on
       paths the local gate never checked).
    """
    text = (WORKFLOWS_DIR / "lint.yml").read_text()

    m = re.search(
        r"^      run_ruff:.*?^        default:\s*(\S+)", text, flags=re.S | re.M
    )
    assert m, "lint.yml must declare the run_ruff input (with a default)"
    assert m.group(1) == "false", (
        f"run_ruff must default to false, got {m.group(1)!r} — consumers "
        "with pre-existing ruff drift would redden the moment this merges"
    )

    assert "format('{0}', inputs.run_ruff) == 'true'" in text, (
        "the ruff job's enable-guard must use the format() stringify dodge"
    )
    assert (
        "github.repository == 'topcoder1/ci-workflows' "
        "&& format('{0}', inputs.run_ruff) == ''" in text
    ), "the ruff self-test arm must stay pinned to this repo"
    assert "RUFF_PATHS: ${{ inputs.ruff_paths }}" in text, (
        "ruff_paths must be bound into the run step's env — without it the "
        "job silently ignores a caller's scope override"
    )

    # Scope-parity markers: the auto-detect branch of the run step.
    for marker in (
        "if [ -d src ]; then DIRS+=(src); fi",
        "if [ -d tests ]; then DIRS+=(tests); fi",
    ):
        assert marker in text, (
            f"ruff scope auto-detect lost {marker!r} — it must mirror "
            "bb-preflight's src/tests-else-root PYTHON_DIRS logic"
        )


def test_lint_ruff_version_is_pinned():
    """The ruff job must resolve an EXACT version, never float to latest.

    2026-07-31, measured on the install PR (topcoder1/dotclaude#186): an
    unpinned `pipx run ruff` pulled 0.16.1 while the workstation and
    bb-preflight baseline was 0.15.10. 0.16 expanded ruff's DEFAULT rule
    set, so CI failed dotclaude's tests/ with 25 errors (ISC004, PLW1510,
    FURB167, RUF059, PIE810) that the local gate called clean — the same
    local-vs-CI asymmetry this job exists to close, just inverted. Worse,
    a floating resolve means the next ruff release reddens every consumer
    of this reusable with no code change at all.

    So: an exact `==` pin, defaulted, and reachable by callers who need a
    different one. Bumping it is then a deliberate PR that shows the new
    findings rather than a surprise fleet outage.
    """
    text = (WORKFLOWS_DIR / "lint.yml").read_text()

    m = re.search(
        r"^      ruff_version:.*?^        default:\s*\"([^\"]+)\"",
        text,
        flags=re.S | re.M,
    )
    assert m, "lint.yml must declare a ruff_version input with a default"
    assert re.fullmatch(r"\d+\.\d+\.\d+", m.group(1)), (
        f"ruff_version default must be an exact x.y.z version, got {m.group(1)!r}"
    )

    assert 'pipx run --spec "ruff==${RUFF_VERSION}" ruff check' in text, (
        "the ruff invocation must pin via --spec ruff==<version>; a bare "
        "`pipx run ruff` floats to latest and reddens the fleet on release day"
    )

    # The step env needs a literal fallback: on this repo's own self-test
    # events the `inputs` context is null, so an unguarded binding expands to
    # empty and installs `ruff==`.
    fb = re.search(
        r"RUFF_VERSION: \$\{\{ inputs\.ruff_version \|\| '([^']*)' \}\}", text
    )
    assert fb, "ruff_version must be bound into the step env with a fallback"
    # And the two literals must move together. Comparing the fallback against
    # a hardcoded version here would let a bump that touches only the input
    # default pass: callers would get the new ruff while direct self-test runs
    # silently kept the old one. (Codex review round 2.)
    assert fb.group(1) == m.group(1), (
        f"the self-test fallback ({fb.group(1)}) has drifted from the input "
        f"default ({m.group(1)}) — bump both or the two event paths run "
        "different ruff versions"
    )

    # A pin is only a pin if it is concrete — pip accepts wildcards/ranges.
    assert "ruff_version must be an exact x.y.z version" in text, (
        "the step must reject non-exact ruff_version values; a caller passing "
        "`0.15.*` would float to latest-matching while still looking pinned"
    )
