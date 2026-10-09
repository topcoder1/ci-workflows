"""The Claude review lanes never put the model's comment text through a shell.

Both lanes used to tell the model to post its PR comment itself, with
`gh pr comment <PR_NUMBER> --body "..."` through an allowed
`Bash(gh pr comment:*)` rule. Inside double quotes bash still runs backtick
spans and `$( )`, and a markdown code span in the model's prose is a backtick
span: the shell ran it and the comment carried its output in place of the
span. On 2026-10-09 a review summary on a fleet PR came out as 1,162 lines of
`find` output from the runner's checkout that way. A prefix rule matches the
first words of a command; it cannot constrain what the shell does inside the
quoted body.

So the model has no tool that posts a PR comment. It ends its run with the
comment as its final message, and a workflow step reads that message from the
action's transcript (`execution_file`) with jq and posts it with
`gh pr comment --body-file`. The text is data from end to end.

Pinned here:
1. The hazard, as a positive control: the command shape the lanes prescribed,
   run through bash with a harmless span, substitutes the span.
2. Every claude-code-action step: no allow rule lets the model reach a gh
   command that writes to a PR or issue. The two lanes' prompts do not ask
   the model to post at all.
3. Each lane's posting step follows the model step, reads the transcript the
   model step wrote, takes no `${{ }}` expression into its script, and passes
   the body as a file.
4. Run as shipped against a stub gh, the posting step posts a final message
   full of shell syntax byte for byte without running any of it, posts
   nothing for a run that did not finish, and logs the message only with the
   runner's workflow-command prefixes broken (`::` at a line start, `##[`
   anywhere in a line). A mutant that hands the body to `eval` is caught.
"""

import json
import os
import re
import shlex
import subprocess
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
ACTION = "anthropics/claude-code-action@"

# workflow -> (job, id of the step that posts the model's final message)
LANES = {
    "claude-review.yml": ("review", "summary"),
    "claude-adversarial-review.yml": ("adversarial-review", "verdict"),
}

ALLOW_FLAGS = ("--allowedTools", "--allowed-tools")
# gh commands that write to a PR or an issue. A Bash rule that reaches any of
# them gives the model a shell for text that ends up on the PR.
POSTING_COMMANDS = (
    ("gh", "pr", "comment"),
    ("gh", "pr", "review"),
    ("gh", "pr", "edit"),
    ("gh", "pr", "create"),
    ("gh", "issue", "comment"),
    ("gh", "issue", "edit"),
    ("gh", "issue", "create"),
    ("gh", "api"),
)
# A prompt line that asks the model to post through gh. A bare `gh api` is a
# read as often as a write (claude-review's prompt names it to say "do not
# retry"), so only `gh api` with a field or input flag counts.
POSTING_INSTRUCTION = re.compile(
    r"\bgh\s+(?:pr|issue)\s+(?:comment|review)\b"
    r"|\bgh\s+api\b[^\n]*\s(?:-f|-F|--field|--raw-field|--input)\b"
    r"|--body\b"
)
# Commands that, allowed as a `Bash(<cmd>:*)` prefix rule, run an arbitrary
# OTHER program — so a prefix rule naming only them still reaches any command,
# `gh pr comment` included. A prefix match cannot exclude the flag or argument
# that does it. rg runs `--pre <cmd>`; sed runs the `e`/`s///e` command; awk
# runs `system()`; the shells and the wrapper tools run their argument. (Not
# grep, git, gh, cat, head, tail, wc, ls, file: none runs another program. find
# is excluded here because Claude Code always-prompts `find -exec`/`-delete`,
# which a `Bash(find:*)` rule never auto-approves — see the verifier lane.)
EXEC_GADGETS = frozenset(
    "rg sed awk env xargs sh bash zsh ksh dash timeout nice stdbuf "
    "watch parallel nohup setsid".split()
)


def load(workflow):
    return yaml.safe_load((WORKFLOWS / workflow).read_text())


def model_steps():
    """(workflow, job, step) for every claude-code-action step."""
    found = []
    for path in sorted(WORKFLOWS.glob("*.y*ml")):
        document = yaml.safe_load(path.read_text()) or {}
        for job_id, job in (document.get("jobs") or {}).items():
            for step in job.get("steps") or []:
                if str(step.get("uses", "")).startswith(ACTION):
                    found.append((path.name, job_id, step))
    return found


def split_rules(value):
    """Split on commas and whitespace outside parentheses."""
    rules, current, depth = [], "", 0
    for char in value:
        if char == "(":
            depth += 1
        elif char == ")":
            depth = max(depth - 1, 0)
        if depth == 0 and (char == "," or char.isspace()):
            if current.strip():
                rules.append(current.strip())
            current = ""
        else:
            current += char
    if current.strip():
        rules.append(current.strip())
    return rules


def allowed_rules(step):
    """Every allow rule a claude-code-action step passes the CLI."""
    with_ = step.get("with") or {}
    tokens = shlex.split(str(with_.get("claude_args") or ""))
    values, index = [], 0
    while index < len(tokens):
        token = tokens[index]
        index += 1
        if token in ALLOW_FLAGS:
            while index < len(tokens) and not tokens[index].startswith("-"):
                values.append(tokens[index])
                index += 1
        elif token.startswith(tuple(flag + "=" for flag in ALLOW_FLAGS)):
            values.append(token.split("=", 1)[1])
    if with_.get("allowed_tools"):
        values.append(str(with_["allowed_tools"]))
    return [rule for value in values for rule in split_rules(value)]


def can_post(rule):
    """Whether an allow rule lets the model run a gh command that writes."""
    if rule == "Bash":
        return True
    match = re.fullmatch(r"Bash\((.*)\)", rule, re.DOTALL)
    if not match:
        return False
    words = re.sub(r"(?::\*|\s\*|\*)$", "", match.group(1).strip()).split()
    if not words:
        return True
    # A rule allows every command its words begin: Bash(gh:*) allows them
    # all, and Bash(gh pr comment 12:*) still allows one.
    return any(
        tuple(words[: len(command)]) == command
        or tuple(words) == command[: len(words)]
        for command in POSTING_COMMANDS
    )


def reaches_shell(rule):
    """Whether an allow rule lets the model run an arbitrary other program
    (an exec gadget, or a bare `Bash`/`Bash(*)`)."""
    if rule == "Bash":
        return True
    match = re.fullmatch(r"Bash\((.*)\)", rule, re.DOTALL)
    if not match:
        return False
    words = re.sub(r"(?::\*|\s\*|\*)$", "", match.group(1).strip()).split()
    if not words:  # Bash(*) / Bash(:*)
        return True
    # The gadget is the command word, however the rule is scoped after it
    # (`rg`, `rg -n`, `/usr/bin/rg` all reach ripgrep's --pre).
    return words[0].rsplit("/", 1)[-1] in EXEC_GADGETS


def lane_steps(workflow):
    job, _ = LANES[workflow]
    return load(workflow)["jobs"][job]["steps"]


def post_step(workflow):
    _, step_id = LANES[workflow]
    steps = [s for s in lane_steps(workflow) if s.get("id") == step_id]
    assert len(steps) == 1, (
        f"{workflow}: expected one step with id {step_id!r} that posts the "
        "model's final message"
    )
    return steps[0]


def shipped_run(step):
    run = step["run"]
    assert "${{" not in run, "the runner would substitute into this script"
    return run


def write_executable(path, text):
    path.write_text(text)
    path.chmod(0o755)


# The stub gh records each call's argv (NUL-separated) and the body file it was
# handed, and fails a post on request the way the 2026-08-17 outage did.
GH_STUB = r"""#!/usr/bin/env bash
n=$(find "$GH_CALLS" -name 'call.*' | wc -l | tr -d ' ')
printf '%s\0' "$@" > "$GH_CALLS/call.$n"
prev=""
for arg in "$@"; do
  if [ "$prev" = "--body-file" ]; then cp "$arg" "$GH_CALLS/body.$n"; fi
  prev="$arg"
done
if [ "${GH_COMMENT_FAIL:-0}" = "1" ]; then
  echo "HTTP 503: No server is currently available to service your request" >&2
  exit 1
fi
echo "https://github.com/o/r/pull/478#issuecomment-1"
"""


class Run:
    def __init__(self, proc, calls):
        self.returncode = proc.returncode
        self.stdout = proc.stdout
        self.stderr = proc.stderr
        names = sorted(calls.glob("call.*"), key=lambda p: int(p.suffix[1:]))
        self.calls = [p.read_bytes().split(b"\0")[:-1] for p in names]
        # Bytes, not read_text(): universal newlines would turn the message's
        # carriage return into \n and hide whether the step kept it.
        self.bodies = [
            (calls / f"body.{p.suffix[1:]}").read_bytes().decode()
            for p in names
            if (calls / f"body.{p.suffix[1:]}").exists()
        ]


def run_post_step(
    workflow, tmp_path, execution_file="", fail_post=False, run=None, outcome="success"
):
    """Run the lane's posting step the way the runner does, against stubs."""
    step = post_step(workflow)
    script = run if run is not None else shipped_run(step)
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir(exist_ok=True)
    write_executable(bin_dir / "gh", GH_STUB)
    write_executable(bin_dir / "sleep", "#!/usr/bin/env bash\nexit 0\n")
    calls = tmp_path / "calls"
    calls.mkdir(exist_ok=True)
    runner_temp = tmp_path / "runner_temp"
    runner_temp.mkdir(exist_ok=True)
    values = {
        "github.token": "stub-token",
        "github.repository": "o/r",
        "github.event.pull_request.number": "478",
        "steps.claude.outputs.execution_file": str(execution_file),
        "steps.claude.outcome": outcome,
        "github.server_url": "https://github.example",
        "github.run_id": "1",
    }

    def evaluate(match):
        assert match.group(1) in values, f"no fixture value for {match.group(0)}"
        return values[match.group(1)]

    environment = {
        "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
        "HOME": str(tmp_path),
        "RUNNER_TEMP": str(runner_temp),
        "GITHUB_OUTPUT": str(tmp_path / "github_output"),
        "GITHUB_STEP_SUMMARY": str(tmp_path / "step_summary"),
        "GH_CALLS": str(calls),
        "GH_COMMENT_FAIL": "1" if fail_post else "0",
    }
    for name, value in (step.get("env") or {}).items():
        environment[name] = re.sub(r"\$\{\{\s*(.*?)\s*\}\}", evaluate, str(value))
    script_file = tmp_path / "step.sh"
    script_file.write_text(script)
    proc = subprocess.run(
        ["bash", "--noprofile", "--norc", "-eo", "pipefail", str(script_file)],
        cwd=tmp_path,
        env=environment,
        capture_output=True,
        text=True,
    )
    return Run(proc, calls)


def transcript(tmp_path, result, subtype="success", is_error=False):
    """An execution_file: the SDK messages claude-code-action writes."""
    path = tmp_path / "claude-execution-output.json"
    path.write_text(
        json.dumps(
            [
                {"type": "system", "subtype": "init"},
                {
                    "type": "assistant",
                    "message": {"content": [{"type": "text", "text": "Reading."}]},
                },
                {
                    "type": "result",
                    "subtype": subtype,
                    "is_error": is_error,
                    "num_turns": 4,
                    "result": result,
                    "permission_denials": [],
                },
            ]
        )
    )
    return path


def hostile_message(canary):
    """Prose a model plausibly writes, holding everything a shell acts on: a
    bare code span, an escaped one, a $( ) span, parameter expansions,
    quotes and separators; and the runner's two workflow-command prefixes,
    one behind a carriage return, which the runner reads as a line break."""
    return (
        f"No issues found. Docs-only change — four consistent `touch {canary}`"
        f" probe updates to exclude \\`skills/synced/\\` plus $(touch {canary})"
        " and ${HOME} $HOME; \"double\" 'single' * ; | & && || > /dev/null\n"
        "::error::injected by the model's text\n"
        "a carriage return\r::error::injected behind a carriage return\n"
        f"a line carrying ##[set-output name=file;]{canary} in the middle\n"
    )


# ---------------------------------------------------------------------------
# 1. The hazard.


def test_the_documented_command_shape_runs_a_backtick_span(tmp_path):
    """Control: the command the lanes prescribed, written the way the model
    wrote it on 2026-10-09 (one code span bare, one escaped), runs the bare
    span and posts its output; the escaped span stays literal."""
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    argv_file = tmp_path / "argv"
    write_executable(
        bin_dir / "gh", '#!/usr/bin/env bash\nprintf "%s\\0" "$@" > "$ARGV_FILE"\n'
    )
    command = (
        'gh pr comment 478 --body "No issues found. Docs-only change — four'
        " consistent `printf substituted` probe updates to exclude"
        ' \\`skills/synced/\\` plus matching runbook prose."'
    )
    subprocess.run(
        ["bash", "-c", command],
        env={
            **os.environ,
            "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
            "ARGV_FILE": str(argv_file),
        },
        check=True,
    )
    argv = argv_file.read_bytes().split(b"\0")[:-1]
    body = argv[argv.index(b"--body") + 1].decode()
    assert "four consistent substituted probe updates" in body
    assert "`printf substituted`" not in body
    assert "`skills/synced/`" in body


# ---------------------------------------------------------------------------
# 2. No model can post through the shell, and the lanes do not ask it to.


def test_both_lanes_are_found():
    found = {(workflow, job) for workflow, job, _ in model_steps()}
    for workflow, (job, _) in LANES.items():
        assert (workflow, job) in found, f"{workflow}: no claude-code-action step"


@pytest.mark.parametrize(
    "workflow, job, step",
    model_steps(),
    ids=lambda value: value if isinstance(value, str) else "",
)
def test_no_model_step_can_post_through_the_shell(workflow, job, step):
    posting = [rule for rule in allowed_rules(step) if can_post(rule)]
    assert not posting, (
        f"{workflow} ({job}): allow rule(s) {posting} let the model post to the "
        "PR through the shell, where code spans in its text run as commands. "
        "The lane's posting step posts the model's final message instead."
    )


@pytest.mark.parametrize(
    "workflow, job, step",
    model_steps(),
    ids=lambda value: value if isinstance(value, str) else "",
)
def test_no_model_step_allows_a_code_execution_gadget(workflow, job, step):
    # A no-posting-through-the-shell boundary also has to keep the model off
    # any command that runs ANOTHER command: `Bash(rg:*)` reaches `rg --pre
    # sh`, which runs an arbitrary program, `gh pr comment` included. A prefix
    # rule cannot exclude the flag that does it.
    gadgets = [rule for rule in allowed_rules(step) if reaches_shell(rule)]
    assert not gadgets, (
        f"{workflow} ({job}): allow rule(s) {gadgets} name a command that runs "
        "another program (rg --pre, sed e, awk system, a shell, a wrapper), so "
        "the model can still reach any command through it. Drop it; grep covers "
        "the searching."
    )


@pytest.mark.parametrize(
    "rule",
    [
        "Bash(gh pr comment:*)",
        "Bash(gh pr comment *)",
        "Bash(gh pr comment 478 --body:*)",
        "Bash(gh issue comment:*)",
        "Bash(gh pr review:*)",
        "Bash(gh api:*)",
        "Bash(gh pr:*)",
        "Bash(gh:*)",
        "Bash(*)",
        "Bash",
    ],
)
def test_the_check_flags_rules_that_reach_a_posting_command(rule):
    assert can_post(rule)


@pytest.mark.parametrize(
    "rule",
    [
        "Bash(gh pr diff:*)",
        "Bash(gh pr view:*)",
        "Bash(grep:*)",
        "Bash(git log:*)",
        "Read",
        "mcp__github_inline_comment__create_inline_comment",
    ],
)
def test_the_check_passes_rules_that_cannot_post(rule):
    assert not can_post(rule)


@pytest.mark.parametrize(
    "rule",
    [
        "Bash(rg:*)",
        "Bash(rg --pre sh:*)",
        "Bash(/usr/bin/rg:*)",
        "Bash(sed:*)",
        "Bash(awk:*)",
        "Bash(env:*)",
        "Bash(xargs:*)",
        "Bash(sh:*)",
        "Bash(bash -c:*)",
        "Bash(timeout 5 rg:*)",
        "Bash(*)",
        "Bash",
    ],
)
def test_the_gadget_check_flags_exec_capable_rules(rule):
    assert reaches_shell(rule)


@pytest.mark.parametrize(
    "rule",
    [
        "Bash(grep:*)",
        "Bash(git log:*)",
        "Bash(gh pr diff:*)",
        "Bash(gh pr view:*)",
        "Bash(cat:*)",
        "Bash(find:*)",
        "Read",
        "mcp__github_inline_comment__create_inline_comment",
    ],
)
def test_the_gadget_check_passes_read_only_rules(rule):
    assert not reaches_shell(rule)


def test_the_check_reads_the_allowlist_however_it_is_written():
    step = {
        "with": {
            "claude_args": (
                "--model m\n"
                '--allowedTools "Bash(gh pr view:*),Bash(gh pr comment:*)"\n'
                "--disallowedTools Task"
            )
        }
    }
    assert [r for r in allowed_rules(step) if can_post(r)] == [
        "Bash(gh pr comment:*)"
    ]
    step = {"with": {"claude_args": '--allowed-tools="Bash(gh api:*)" --model m'}}
    assert [r for r in allowed_rules(step) if can_post(r)] == ["Bash(gh api:*)"]
    step = {"with": {"allowed_tools": "Read,Bash(gh pr comment:*)"}}
    assert [r for r in allowed_rules(step) if can_post(r)] == [
        "Bash(gh pr comment:*)"
    ]


@pytest.mark.parametrize("workflow", sorted(LANES))
def test_the_prompt_does_not_ask_the_model_to_post(workflow):
    (step,) = [s for s in lane_steps(workflow) if str(s.get("uses", "")).startswith(ACTION)]
    prompt = str((step.get("with") or {}).get("prompt") or "")
    assert prompt, f"{workflow}: the model step has no prompt"
    hits = [line.strip() for line in prompt.splitlines() if POSTING_INSTRUCTION.search(line)]
    assert not hits, (
        f"{workflow}: the prompt asks the model to post through gh: {hits}. The "
        "model ends with its comment as its final message; the posting step "
        "posts it."
    )


# ---------------------------------------------------------------------------
# 3. The posting step's wiring.


@pytest.mark.parametrize("workflow", sorted(LANES))
def test_the_post_step_follows_the_model_step_and_reads_its_transcript(workflow):
    steps = lane_steps(workflow)
    models = [i for i, s in enumerate(steps) if str(s.get("uses", "")).startswith(ACTION)]
    assert len(models) == 1, f"{workflow}: expected one model step"
    assert steps[models[0]].get("id") == "claude", (
        f"{workflow}: the model step needs `id: claude`; the posting step reads "
        "steps.claude.outputs.execution_file"
    )
    post = post_step(workflow)
    assert steps.index(post) > models[0], f"{workflow}: the posting step runs first"
    condition = str(post.get("if", ""))
    for want in ("!cancelled()", "steps.claude.outcome != 'skipped'"):
        assert want in condition, f"{workflow}: posting step `if:` lacks {want!r}"
    env = post.get("env") or {}
    assert env.get("EXECUTION_FILE") == "${{ steps.claude.outputs.execution_file }}"
    run = shipped_run(post)
    assert "--body-file" in run
    assert not re.search(r"\bgh\s+(?:pr|issue)\s+comment\b[^\n]*\s(?:--body|-b)\s", run), (
        f"{workflow}: the posting step passes the body on the command line"
    )


# ---------------------------------------------------------------------------
# 4. The posting step, run as shipped.


@pytest.mark.parametrize("workflow", sorted(LANES))
def test_shell_syntax_in_the_final_message_is_posted_byte_for_byte(workflow, tmp_path):
    canary = tmp_path / "canary"
    message = hostile_message(canary)
    result = run_post_step(workflow, tmp_path, transcript(tmp_path, message))
    assert result.returncode == 0, result.stdout + result.stderr
    assert not canary.exists(), f"{workflow}: a span in the model's text ran"
    assert len(result.calls) == 1, result.calls
    argv = result.calls[0]
    assert argv[:3] == [b"pr", b"comment", b"478"]
    assert b"--body-file" in argv
    assert b"--body" not in argv and b"-b" not in argv
    (body,) = result.bodies
    assert body.startswith(message), (
        f"{workflow}: the posted body is not the model's message verbatim:\n{body}"
    )
    # Nothing of the message reaches the log on the success path.
    assert "injected by the model" not in result.stdout + result.stderr


@pytest.mark.parametrize("workflow", sorted(LANES))
def test_a_failed_post_logs_the_message_with_workflow_commands_broken(
    workflow, tmp_path
):
    canary = tmp_path / "canary"
    message = hostile_message(canary)
    result = run_post_step(
        workflow, tmp_path, transcript(tmp_path, message), fail_post=True
    )
    assert not canary.exists(), f"{workflow}: a span in the model's text ran"
    assert len(result.calls) == 3, f"{workflow}: expected 3 post attempts"
    log = result.stdout + result.stderr
    assert "injected by the model's text" in log, (
        f"{workflow}: a message that could not be posted must reach the log"
    )
    assert_no_workflow_commands(workflow, log)


def assert_no_workflow_commands(workflow, log):
    # The runner splits its log on \n and \r (and \r\n); so does splitlines.
    # It TrimStart()s a line before matching `::` (actions/runner
    # ActionCommand.TryParseV2), so a leading-whitespace prefix does not
    # protect the `::` form — lstrip before the check to see what it sees.
    lines = log.splitlines()
    assert not [
        line for line in lines if line.lstrip().startswith("::error::injected")
    ], (
        f"{workflow}: the runner would read the model's `::error::` line as a "
        "workflow command"
    )
    assert "##[" not in log, (
        f"{workflow}: the runner reads `##[` as a workflow command anywhere in a "
        "line, so the model's text could set this step's outputs"
    )


LOG_MUTANTS = {
    # Print the message without breaking carriage returns into lines.
    "keeps-carriage-returns": (
        r"tr '\\r' '\\n' < (\"\$\w+\") \| (sed -e '[^']*' -e '[^']*')",
        r"\2 \1",
    ),
    # Print it without breaking `##[`.
    "keeps-legacy-prefix": (r"-e 's/##\\\[/#\?\[/g' ", ""),
    # Indent with spaces but no `| `, so a `::` line sits at the start after
    # the runner's TrimStart() and is parsed.
    "leaves-colon-at-line-start": (r"-e 's/\^/    \| /'", r"-e 's/^/    /'"),
}


@pytest.mark.parametrize("mutant", sorted(LOG_MUTANTS))
@pytest.mark.parametrize("workflow", sorted(LANES))
def test_a_post_step_that_logs_the_message_raw_is_caught(workflow, mutant, tmp_path):
    """Mutation: drop either break from the log line and the check above
    fires. Proves it can see a workflow command, not just their absence."""
    run = shipped_run(post_step(workflow))
    pattern, replacement = LOG_MUTANTS[mutant]
    mutated, count = re.subn(pattern, replacement, run)
    assert count >= 1, "mutation did not apply; the anchor drifted"
    canary = tmp_path / "canary"
    result = run_post_step(
        workflow,
        tmp_path,
        transcript(tmp_path, hostile_message(canary)),
        fail_post=True,
        run=mutated,
    )
    with pytest.raises(AssertionError, match="workflow command"):
        assert_no_workflow_commands(workflow, result.stdout + result.stderr)


def _no_message_transcript(shape, tmp_path):
    if shape == "no-file":
        return ""
    if shape == "missing-file":
        return tmp_path / "absent.json"
    if shape == "not-json":
        path = tmp_path / "x.json"
        path.write_text("Flagged 3 issues inline — not JSON")
        return path
    if shape == "not-an-array":
        path = tmp_path / "x.json"
        path.write_text(json.dumps({"type": "result", "result": "Flagged 3 inline."}))
        return path
    if shape == "max-turns":
        return transcript(tmp_path, None, subtype="error_max_turns", is_error=True)
    if shape == "is-error":
        return transcript(tmp_path, "API Error: 529 overloaded", is_error=True)
    if shape == "empty-result":
        return transcript(tmp_path, "")
    return transcript(tmp_path, " \n\t\n")  # blank-result


# Shapes where the model step did NOT succeed (the action fails the job
# itself). The post step runs under !cancelled() but the job is already red,
# so both lanes post nothing and exit 0.
_FAILED_RUN_SHAPES = ["no-file", "missing-file", "not-json", "max-turns", "is-error"]
# Shapes where the step SUCCEEDED but produced no readable final message (a
# broken transcript shape, or a genuinely blank result).
_SUCCESS_NO_MESSAGE_SHAPES = ["not-an-array", "empty-result", "blank-result"]


@pytest.mark.parametrize("workflow", sorted(LANES))
@pytest.mark.parametrize("shape", _FAILED_RUN_SHAPES)
def test_a_failed_run_posts_nothing_and_stays_green(workflow, shape, tmp_path):
    result = run_post_step(
        workflow, tmp_path, _no_message_transcript(shape, tmp_path), outcome="failure"
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert result.calls == [], f"{workflow}: posted for a run that did not finish"
    assert "::warning::" in result.stdout, (
        f"{workflow}: a run with nothing to post must say so in the log"
    )


@pytest.mark.parametrize("workflow", sorted(LANES))
@pytest.mark.parametrize("shape", _SUCCESS_NO_MESSAGE_SHAPES)
def test_a_successful_run_with_no_message_branches_by_lane(workflow, shape, tmp_path):
    # The review summary is reporting, so an empty summary after a successful
    # run is a warning (green). The adversarial verdict is findings delivery,
    # so an empty verdict after success is fail-closed (red): the run
    # completed and produced nothing, which cannot be read as "no regressions"
    # — and a transcript shape the step can no longer parse (a bad pin bump)
    # goes red on its first run rather than silently green.
    result = run_post_step(
        workflow, tmp_path, _no_message_transcript(shape, tmp_path), outcome="success"
    )
    assert result.calls == [], f"{workflow}: posted for a run with no final message"
    if workflow == "claude-review.yml":
        assert result.returncode == 0, result.stdout + result.stderr
        assert "::warning::" in result.stdout
    else:
        assert result.returncode == 1, result.stdout + result.stderr
        assert "::error::" in result.stdout, (
            "the adversarial lane must fail closed on an empty verdict after a "
            "successful run"
        )


EVAL_BODY = r'''--body "$(eval "printf '%s' \"$(cat "\1")\"")"'''


@pytest.mark.parametrize("workflow", sorted(LANES))
def test_a_post_step_that_parses_the_body_in_a_shell_is_caught(workflow, tmp_path):
    """Mutation: hand the body to the shell the way the old prescription did,
    via eval, and the canary runs. Proves the byte-for-byte test above can see
    a shell parse, not just the absence of one."""
    run = shipped_run(post_step(workflow))
    mutated, count = re.subn(r'--body-file "([^"]+)"', EVAL_BODY, run)
    assert count == 1, "mutation did not apply; the anchor drifted"
    canary = tmp_path / "canary"
    result = run_post_step(
        workflow, tmp_path, transcript(tmp_path, hostile_message(canary)), run=mutated
    )
    assert canary.exists(), (
        f"{workflow}: the eval mutant did not run the span; the harness cannot "
        f"see a shell parse:\n{result.stdout}{result.stderr}"
    )
