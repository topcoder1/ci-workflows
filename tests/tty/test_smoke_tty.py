"""Smoke test for the tty-tests.yml reusable.

Verifies the pty plumbing works on a GitHub-hosted ubuntu-latest runner
with TERM=xterm-256color. If this passes, pexpect-based behavioral tests
in downstream repos can be trusted to actually exercise terminal behavior
rather than silently falling through to a piped-stdin codepath.

Scope is deliberately minimal — exercise the core spawn/expect/sendline
contract. Signal-handling tests (Ctrl-C, SIGTERM) are flaky across
runner platforms because signal delivery through a pty depends on
foreground process group state; real callers can write their own
signal tests against their own CLIs where they control the
process tree.
"""

import pexpect


def test_pty_read_prompt_and_echo():
    """Spawn a tiny bash script that reads from the prompt, echoes back."""
    child = pexpect.spawn(
        "bash",
        ["-c", 'read -p "go? " ans; echo "got=$ans"'],
        timeout=5,
        encoding="utf-8",
    )
    child.expect(r"go\? ")
    child.sendline("yes")
    child.expect(r"got=yes")
    child.expect(pexpect.EOF)


def test_pty_multiline_interaction():
    """Verify multi-prompt interaction works through the pty."""
    child = pexpect.spawn(
        "bash",
        [
            "-c",
            'read -p "name? " n; read -p "age? " a; echo "hello $n age $a"',
        ],
        timeout=5,
        encoding="utf-8",
    )
    child.expect(r"name\? ")
    child.sendline("alice")
    child.expect(r"age\? ")
    child.sendline("30")
    child.expect("hello alice age 30")
    child.expect(pexpect.EOF)
