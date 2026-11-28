"""Guard: no selftest pipes text into a grep that stops reading at a match.

2026-11-25: the required "Tests (Python)" check failed on
topcoder1/ci-workflows#315 in test_bot_skip_commit_authorship.sh, at a check
whose text was there:

    printf '%s' "$revoke_job" | grep -q 'contents: write'

`grep -q` exits at its first match. That job's text is 9,330 bytes and the
match sits at byte 489, so printf was still writing when grep left: it died of
SIGPIPE (status 141), and `set -o pipefail`, which every selftest here turns
on, made 141 the pipeline's status. The check failed on a match. In an
ubuntu:26.04 container (bash 5.3.9, CI's runner image) that line failed 11
times in 12,000, and its here-string form 0 times in the same run; it was not
seen in 2,000 runs on macOS (bash 3.2), so a local run will not show it.
`grep -m N`, `grep -l` and `grep -L` stop at a match too. A negative check
(`! ... | grep -q`) fails the other way: when the text it exists to catch is
there, it can read as absent and pass.

The shipped workflows already avoid this shape where a test pins it: the
CONTROL cases in test_automerge_detect_authorship.sh,
test_automerge_hold_gate.sh, test_automerge_riskfile_gate.sh,
test_claude_review_lost_findings_guard.sh,
test_prettier_untrusted_head_config.sh,
test_regression_convention_bullet_cap.sh and
test_safe_paths_risk_tier_hold.sh hold the old piped form as quoted data and
show it failing on a large input. This guard holds the selftests' own code to
the same rule: give such a grep a here-string or a file, never a pipe.

    grep -q 'contents: write' <<<"$revoke_job"
    grep -q -- '--paginate' <<<"$(grep -A1 'labels?per_page=100' "$T/hold.sh")"

Three layers:

1. `stopping_grep_pipes` finds a pipe into grep (also behind variable
   assignments or `command`) run with -q/--quiet/--silent, -m/--max-count,
   -l/--files-with-matches or -L/--files-without-match. It reads shell, not
   lines: quoted text and comments are blanked first, so the CONTROL fixtures
   (the old form held as data) and comments that name the shape do not count,
   while a "$(...)" inside double quotes and here-document bodies are read as
   code (the selftests write their stubs as here-documents). A quote or a "$("
   the scanner cannot close fails the scan rather than hiding the rest of a
   file.
2. Synthetic snippets pin what the scanner flags and what it leaves alone, so
   a scanner that finds nothing fails here instead of passing the repo scan
   vacuously. A fixture strings together awkward but real shapes (spliced
   quotes, quotes inside "${...}", here-documents, awk, `case`), each
   followed by a pipe that must be found on its line, so a lexer that
   misreads one and recovers later fails too.
3. The repo scan reads every selftest/*.sh and fails on each hit with its
   file, line and the rewrite. A floor on the file count and a named file keep
   a moved glob from passing. A pipe appended to each script, which the scan
   must report at that script's last line, keeps a scanner that stops before
   the end of a file from passing (on a clean tree the repo scan alone would
   find nothing either way).

Not covered, and none of it occurs today: grep behind a wrapper or a group
(`timeout 5 grep`, `{ grep ...; }`), an option after a redirection
(`grep y 2>/dev/null -q`) or in quotes (`grep '-q'`), abbreviated long
options (`--qui`), an apostrophe in the body of an unquoted here-document
(bash reads it as a plain character; the scanner as a quote, which hides the
rest of that body), and a `case` inside a double-quoted "$(...)".
"""

import pathlib
import re

import pytest

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
SELFTEST_DIR = REPO_ROOT / "selftest"

# Quoted text becomes a run of this character: still one shell word, so the
# option scan sees a pattern there, never a pipe or an option.
_QUOTED = "_"
_WORD_BREAK = frozenset(" \t\n;&|()<>")
_HEREDOC = re.compile(
    r"<<(?P<strip>-?)[ \t]*"
    r"(?:'(?P<sq>[^'\n]*)'|\"(?P<dq>[^\"\n]*)\"|\\?(?P<bare>[A-Za-z_][A-Za-z0-9_]*))"
)
# A single pipe (not `||`, not the `>|` redirect), `|&` too, into grep by any
# name or path, after any variable assignments (`LC_ALL=C grep`) or
# `command`. Runs on masked text, where only real operators survive.
_PIPE_INTO_GREP = re.compile(
    r"(?<![|>])\|&?(?!\|)\s*"
    r"(?:[A-Za-z_][A-Za-z0-9_]*=(?:[^\s;&|()<>`]|\$\([^()]*\))*[ \t]+)*(?:command[ \t]+)?"
    r"(?:\S*/)?[ef]?grep(?=[\s;&|)]|$)"
)

# grep options that stop reading at a match, and the ones that take an
# argument (so the next characters or word are that argument, not options).
_STOP_SHORT = frozenset("qlLm")
_STOP_LONG = frozenset(
    {"quiet", "silent", "files-with-matches", "files-without-match", "max-count"}
)
_ARG_SHORT = frozenset("ABCDdef")
_ARG_LONG = frozenset(
    {
        "regexp",
        "group-separator",
        "file",
        "after-context",
        "before-context",
        "context",
        "devices",
        "directories",
        "binary-files",
        "label",
        "include",
        "exclude",
        "exclude-dir",
        "exclude-from",
    }
)


class ShellScanError(ValueError):
    """A script the scanner cannot read: a quote left open at the end."""


def mask_shell(text: str, *, strict: bool = True) -> str:
    """Return `text` with quoted text and comments blanked, same length.

    '...', $'...' and the literal part of "..." become runs of `_`; a
    "$(...)" or `...` inside double quotes is read as code, with its own
    quoting, since a pipe there is as real as one outside. A comment becomes
    spaces, an escaped character `_`, and a backslash-newline two spaces, so
    every offset keeps its line and a continued command reads as one.
    Here-document bodies are masked as scripts of their own, leniently, so an
    apostrophe in a data body cannot leak into the code after it. `strict`
    raises on a quote or a substitution left open at the end of the text.
    """
    out = list(text)
    n = len(text)

    def blank(start: int, end: int, ch: str) -> None:
        for k in range(start, end):
            if out[k] != "\n":
                out[k] = ch

    def unclosed(start: int, what: str) -> int:
        if strict:
            line = text.count("\n", 0, start) + 1
            raise ShellScanError(f"{what} opened on line {line} never closes")
        return n

    def code(i: int, closer: str = "", opened_at: int = 0) -> int:
        """Lex code from `i`. With a `closer` (")" for "$(", "`" for a
        backtick) return the offset of the character that closes it, else
        lex to the end."""
        pending: list[tuple[str, bool]] = []  # here-documents opened on this line
        depth = 0
        while i < n:
            c = text[i]
            if c == "\n":
                i += 1
                if pending:
                    i = _mask_heredoc_bodies(text, i, pending, out)
                    pending = []
                continue
            if c == "\\":
                if text.startswith("\\\n", i):
                    out[i] = out[i + 1] = " "
                elif i + 1 < n:
                    out[i + 1] = _QUOTED
                i += 2
                continue
            if closer == "`" and c == "`":
                return i
            if closer == ")" and c in "()":
                if c == ")" and depth == 0:
                    return i
                depth += 1 if c == "(" else -1
            if c == "'" or text.startswith("$'", i):
                ansi = c == "$"
                j = i + (2 if ansi else 1)
                while j < n and text[j] != "'":
                    j += 2 if ansi and text[j] == "\\" else 1
                if j >= n:
                    j = unclosed(i, "quote") - 1
                blank(i, j + 1, _QUOTED)
                i = j + 1
                continue
            if c == '"':
                i = dquote(i)
                continue
            if c == "#" and (i == 0 or text[i - 1] in _WORD_BREAK):
                j = text.find("\n", i)
                j = n if j < 0 else j
                blank(i, j, " ")
                i = j
                continue
            if text.startswith("<<<", i):
                i += 3
                continue
            if text.startswith("<<", i):
                m = _HEREDOC.match(text, i)
                if m:
                    delim = next(
                        d for d in m.group("sq", "dq", "bare") if d is not None
                    )
                    pending.append((delim, bool(m.group("strip"))))
                    blank(m.start(), m.end(), _QUOTED)
                    i = m.end()
                    continue
            i += 1
        return unclosed(opened_at, "substitution") if closer else n

    def dquote(i: int) -> int:
        """Mask the double-quoted string that opens at `i`, reading any
        "$(...)" or `...` in it as code; return the offset just after it."""
        start = i
        out[i] = _QUOTED
        i += 1
        while i < n:
            c = text[i]
            if c == "\\":
                blank(i, min(i + 2, n), _QUOTED)
                i += 2
                continue
            if c == '"':
                out[i] = _QUOTED
                return i + 1
            if text.startswith("$(", i) or c == "`":
                body = i + (2 if c == "$" else 1)
                i = code(body, ")" if c == "$" else "`", opened_at=i) + 1
                continue
            if c != "\n":
                out[i] = _QUOTED
            i += 1
        return unclosed(start, "quote")

    code(0)
    return "".join(out)


def _mask_heredoc_bodies(
    text: str, i: int, pending: list[tuple[str, bool]], out: list[str]
) -> int:
    """Mask each pending here-document body from offset `i`; return the
    offset just past the last one's delimiter line."""
    n = len(text)
    for delim, strip_tabs in pending:
        start = i
        while i < n:
            j = text.find("\n", i)
            end = n if j < 0 else j
            line = text[i:end]
            if (line.lstrip("\t") if strip_tabs else line) == delim:
                out[start:i] = mask_shell(text[start:i], strict=False)
                i = n if j < 0 else j + 1
                break
            i = n if j < 0 else j + 1
        else:  # never closed: bash reads to the end, so do we
            out[start:n] = mask_shell(text[start:n], strict=False)
    return i


def _stops_early(words: list[str]) -> bool:
    """True when grep's argument words make it stop reading at a match.

    GNU grep (CI's) takes options after the pattern too, so every word up to
    `--` counts.
    """
    it = iter(words)
    for word in it:
        if word == "--":
            return False
        if word.startswith("--"):
            name, eq, _ = word[2:].partition("=")
            if name in _STOP_LONG:
                return True
            if name in _ARG_LONG and not eq:
                next(it, None)
            continue
        if word.startswith("-") and len(word) > 1:
            for k, ch in enumerate(word[1:], start=1):
                if ch in _STOP_SHORT:
                    return True
                if ch in _ARG_SHORT:
                    if k == len(word) - 1:  # its argument is the next word
                        next(it, None)
                    break
    return False


def stopping_grep_pipes(text: str) -> list[tuple[int, str]]:
    """(line number, line) of each pipe into a grep that stops at a match."""
    masked = mask_shell(text)
    lines = text.split("\n")
    hits = []
    for m in _PIPE_INTO_GREP.finditer(masked):
        words = re.split(r"[\n;&|)<>`]", masked[m.end() :], maxsplit=1)[0].split()
        if _stops_early(words):
            line_no = text.count("\n", 0, m.start()) + 1
            hits.append((line_no, lines[line_no - 1].strip()))
    return hits


# --- layer 2: what the scanner flags and what it leaves alone ---------------

FLAGGED = {
    "printf into grep -q": "printf '%s' \"$x\" | grep -q 'y'\n",
    "echo into grep -qE, no space": 'echo "$x" |grep -qE y\n',
    "continued line": 'printf \'%s\' "$x" \\\n  | grep -Fxq -- "$line"\n',
    "pipe ending a line": "a |\n  grep -q y\n",
    "--quiet": "a | grep --quiet y\n",
    "--silent": "a | grep --silent y\n",
    "-q as its own word": "a | grep -E -q y\n",
    "|& pipe": "a |& grep -q y\n",
    "negated check": "if ! printf '%s' \"$x\" | grep -qF y; then :; fi\n",
    "egrep": "a | egrep -q y\n",
    "grep by path": "a | /usr/bin/grep -q y\n",
    "-m": "a | grep -m1 y\n",
    "--max-count": "a | grep --max-count=1 y\n",
    "-l": "a | grep -l y\n",
    "-L": "a | grep -L y\n",
    "--files-without-match": "a | grep --files-without-match y\n",
    "a variable assignment before grep": "a | LC_ALL=C grep -q y\n",
    "command grep": "a | command grep -q y\n",
    "quoted value with spaces": 'a | FOO="x y" grep -q z\n',
    "assignment with a $(...) value": "a | X=$(b c) grep -q z\n",
    "assignment with a quoted $(...) value": 'a | X="$(b c)" grep -q z\n',
    "continued line after an assignment": "a | X='1' \\\n  grep -q z\n",
    "option after the pattern": "a | grep 'y' -q\n",
    "inside $(...)": "x=$(a | grep -q y && echo 1)\n",
    "inside a double-quoted $(...)": 'x="$(a | grep -q y && echo 1)"\n',
    "inside double-quoted backticks": 'x="`a | grep -q y`"\n',
    "in a here-document stub": (
        "cat > \"$T/bin/gh\" <<'STUB'\n#!/usr/bin/env bash\nprintf x | grep -q y\nSTUB\n"
    ),
    "after a here-document": "cat <<'EOF'\nit's data\nEOF\na | grep -q y\n",
    "after a comment": "# a | grep -q y\na | grep -q y\n",
}

CLEAN = {
    "here-string": 'grep -q y <<<"$x"\n',
    "here-string of a command": "grep -q -- '--paginate' <<<\"$(grep -A1 x f)\"\n",
    "or-list": "a || grep -q y file\n",
    "grep -q writing the pipe": "grep -q y file | wc -l\n",
    "single-quoted fixture": "PIPED='if echo \"$l\" | grep -qx y; then'\n",
    "double-quoted test name": 'run_case "CONTROL: the old printf | grep -q form fails" 1\n',
    "spliced quotes": "P='if printf '\"'%s'\"' \"$b\" | grep -q '\"'plugins'\"'; then'\n",
    "ANSI-C string": "x=$'a | grep -q b'\n",
    "comment": "# printf '%s' \"$x\" | grep -q y\n",
    "trailing comment": "true  # a | grep -q y\n",
    "grep -c reads it all": "a | grep -c y\n",
    "a double-quoted $(...) ends at its )": '[ "$(a | grep -c y)" -lt 3 ]\n',
    "grep -v reads it all": "a | grep -v y\n",
    "-e takes the next word": "a | grep -e -q f\n",
    "-- ends the options": "a | grep -- -q f\n",
    "-e with its pattern attached": "a | grep -eq f\n",
    "--group-separator takes the next word": "a | grep --group-separator -q y\n",
    "case alternation that looks like an assignment": (
        "case $kv in A=1|B=2) grep -q x f ;; esac\n"
    ),
    "assignment-only element, then ; grep": "a | FOO=1; grep -q y f\n",
    "assignment-only element, newline, grep": "a | FOO=1\ngrep -q y f\n",
    "bare command, newline, grep": "a | command\ngrep -q y f\n",
    "escaped bar": "echo \\| grep -q y\n",
    ">| redirect": "a >| grep -q\n",
    "apostrophe in a data here-document": "cat <<'EOF'\nit's\nEOF\nb='x | grep -q y'\n",
}


@pytest.mark.parametrize("name", sorted(FLAGGED))
def test_scanner_flags(name):
    assert stopping_grep_pipes(FLAGGED[name]), f"missed: {FLAGGED[name]!r}"


@pytest.mark.parametrize("name", sorted(CLEAN))
def test_scanner_leaves_alone(name):
    assert stopping_grep_pipes(CLEAN[name]) == [], f"false hit: {CLEAN[name]!r}"


# Awkward but real shapes, each followed by a pipe the scan must find: a lexer
# that misreads one and recovers later would lose the pipe after it.
AWKWARD = """\
P='if printf '"'%s'"' "$b" | grep -q '"'plugins'"'; then'
a | grep -q one
x="${y#"pre"}"
a | grep -q two
check "t" "$(run 'a " b')"
a | grep -q three
python3 - <<'PY'
print("it's | grep -q")
PY
a | grep -q four
cat > "$T/bin/gh" <<STUB
it's an unquoted body
STUB
a | grep -q five
awk 'BEGIN { print "x | grep -q y" }' f
a | grep -q six
case "$v" in a|b) : ;; esac
a | grep -q seven
"""


def test_scanner_recovers_after_awkward_shapes():
    found = [line_no for line_no, _ in stopping_grep_pipes(AWKWARD)]
    assert found == [2, 4, 6, 10, 14, 16, 18]


def test_scanner_reports_the_line_of_the_pipe():
    text = "true\n# a | grep -q y\n\nb='c'; d | grep -q e\n"
    assert stopping_grep_pipes(text) == [(4, "b='c'; d | grep -q e")]


def test_masking_keeps_every_offset():
    text = "a 'b | c' \"d\" $'e' # f\ncat <<'X'\ng'\nX\nh \\\n| i\n"
    masked = mask_shell(text)
    assert len(masked) == len(text)
    assert [i for i, ch in enumerate(masked) if ch == "\n"] == [
        i for i, ch in enumerate(text) if ch == "\n" and text[i - 1] != "\\"
    ]


def test_scanner_reads_quotes_inside_a_substitution():
    # test_codex_verdict_gate.sh's shape: a double quote inside single quotes
    # inside "$(...)". Read as plain string text, it flips every quote after.
    text = 'check "t" "$(run \'a " b\')"\nexit "$failed"\nx | grep -q y\n'
    assert stopping_grep_pipes(text) == [(3, "x | grep -q y")]


@pytest.mark.parametrize("text", ["echo 'never closed\n", 'x="$(a | b\n'])
def test_scanner_refuses_what_it_cannot_close(text):
    with pytest.raises(ShellScanError):
        stopping_grep_pipes(text)


# --- layer 3: the selftests themselves -------------------------------------

SCRIPTS = sorted(SELFTEST_DIR.glob("*.sh"))


def test_scan_reads_the_selftests():
    names = {p.name for p in SCRIPTS}
    assert len(SCRIPTS) >= 40, f"only {len(SCRIPTS)} selftest scripts found"
    assert "test_bot_skip_commit_authorship.sh" in names
    # Quote-blind, the CONTROL fixtures' old piped form is there to see; the
    # repo scan passes them only because they are quoted.
    sighted = {
        p.name for p in SCRIPTS if _PIPE_INTO_GREP.search(p.read_text(encoding="utf-8"))
    }
    assert {
        "test_automerge_hold_gate.sh",
        "test_automerge_riskfile_gate.sh",
        "test_safe_paths_risk_tier_hold.sh",
    } <= sighted


@pytest.mark.parametrize("path", SCRIPTS, ids=lambda p: p.name)
def test_scanner_reads_each_selftest_to_its_end(path):
    # On a clean tree the repo scan finds nothing, and so would a scanner that
    # stopped reading part of each file. A pipe appended to each real script
    # must be reported at that script's last line.
    text = path.read_text(encoding="utf-8").rstrip("\n") + "\n"
    probe = "printf x | grep -q y"
    assert (text.count("\n") + 1, probe) in stopping_grep_pipes(text + probe + "\n")


def test_no_selftest_pipes_into_a_stopping_grep():
    hits = []
    for p in SCRIPTS:
        try:
            found = stopping_grep_pipes(p.read_text(encoding="utf-8"))
        except ShellScanError as err:  # unreadable fails; it never passes
            hits.append(f"selftest/{p.name}: cannot scan: {err}")
            continue
        hits += [f"selftest/{p.name}:{line_no}: {line}" for line_no, line in found]
    assert not hits, (
        "pipe into a grep that stops at a match: under `set -o pipefail` the"
        " writer can die of SIGPIPE first and fail the check (see this"
        " file's docstring). Feed grep a here-string instead:"
        ' `grep -q PAT <<<"$x"` or `grep -q PAT <<<"$(cmd)"`. If the hit is'
        " data in a here-document (a fixture, not code the test runs), hold"
        " it in a quoted variable instead, as the CONTROL fixtures do.\n"
        + "\n".join(hits)
    )
