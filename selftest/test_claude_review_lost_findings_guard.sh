#!/usr/bin/env bash
# Behavioral test for claude-review.yml's lost-findings guard, plus the
# tool-surface pin (`--disallowedTools`) that removes the cause.
#
# INCIDENT (whois-api-llc/wxa-graph#403, run 31925279662, 2026-08-16). The
# `review / Claude Review` lane — a REQUIRED context fleet-wide — ran 52 min,
# posted the summary "Flagged 6 issues inline — most critical: ...", created
# ZERO inline review comments, and concluded SUCCESS. The run log held only
# `num_turns: 3`, `permission_denials_count: 3` and the action post-step's
# "No buffered inline comments"; the action hides the SDK stream, keeps no
# transcript artifact, and so nothing on record said which tool was denied
# or what four of the six findings were. They were lost. The babysitting
# session recovered the two the summary happened to spell out, by hand.
#
# ROOT CAUSE, established from the fleet's run history and a local replay on
# the same CLI build (2.1.227): the reviewer's first tool call is
# `Skill(code-review)` — the CLI's bundled multi-agent review — which runs as
# a background subagent and fans out finder/verifier agents of its own. That
# work all sits inside ONE parent tool call, so `--max-turns` bounds nothing:
# every PR Review across the fleet went from 1-8 min to 20-134 min the
# minute the action's 1.0.181->1.0.190 bump (Claude Code 2.1.218->2.1.227)
# merged, 2026-08-14 19:10Z. The findings come back to the parent as text;
# whether they reach the PR depends on the parent re-posting them through
# the inline-comment MCP tool. Sometimes it does (the 03:41Z run on the same
# PR posted 7 for a summary that said 3), sometimes it does not (this run).
#
# TWO PROPERTIES, pinned here by extracting the workflow's SHIPPED bash and
# executing it against a stubbed `gh` — never a mirrored copy:
#
#   1. Tool surface. `claude_args` names `Task`, `Agent`, `Skill` and
#      `Workflow` in `--disallowedTools`. Verified on 2.1.227 `-p`: all four
#      vanish from the init tool list, the review is single-pass again, and
#      the turn cap is real. Both subagent spellings stay named because the
#      tool has carried each across CLI versions.
#
#   2. The guard. The bot's summary is its CLAIM; inline review comments on
#      the PR are the FACT. Claim > fact in the losing direction is no longer
#      silent: the guard prints the transcript's permission denials WITH tool
#      names, recovers what the transcript still holds (bodies of denied or
#      errored inline-comment calls, any subagent/skill report), posts it as
#      one fallback comment phrased so bb-unaddressed-findings.sh admits it
#      (`flagged N issue`), and FAILS the job only when nothing beyond the
#      summary was recoverable, or when the recovered findings could not be
#      posted — recovered findings that reached the PR leave the check green
#      with a warning.
#
# FAIL-SAFE ON ITS OWN INPUTS is asserted as hard as the catch: an API error
# listing comments, a missing transcript, or a summary phrased outside the
# mandated "Flagged N issue(s) inline" shape all end in exit 0 — a guard that
# reddens a required check on its own flakiness costs the fleet more than the
# gap it closes. The last of those is an accepted, explicit miss.
#
# Run from the repo root:
#   bash selftest/test_claude_review_lost_findings_guard.sh
set -euo pipefail

WF=.github/workflows/claude-review.yml
STEP="Lost-findings guard (summary claim vs inline comments posted)"
INLINE_TOOL="mcp__github_inline_comment__create_inline_comment"

failed=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

pass() { echo "✓ $1"; }
fail() {
  echo "✗ $1"
  failed=1
}

extract_run() {
  local wf="$1" step_name="$2" out="$3"
  awk -v name="      - name: $step_name" '
    $0 == name { in_step = 1; next }
    in_step && /^        run: \|/ { in_run = 1; next }
    in_run {
      if ($0 ~ /^          / || $0 == "") { sub(/^          /, ""); print }
      else { exit }
    }
  ' "$wf" > "$out"
  if [ ! -s "$out" ]; then
    fail "could not extract '$step_name' from $wf — step renamed or reindented?"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 1. Static: tool surface + step wiring
# ---------------------------------------------------------------------------
echo "== claude-review.yml: tool surface and guard wiring =="

python3 - "$WF" <<'PY' || failed=1
import re, sys, yaml

path = sys.argv[1]
with open(path) as fh:
    doc = yaml.safe_load(fh)
steps = doc["jobs"]["review"]["steps"]
by_id = {s.get("id"): s for s in steps if s.get("id")}
problems = []

review = by_id.get("claude")
if review is None:
    problems.append("the claude-code-action step has no `id: claude` — the guard reads steps.claude.outputs.execution_file")
else:
    args = review.get("with", {}).get("claude_args", "")
    m = re.search(r'--disallowedTools\s+"([^"]*)"', args)
    if not m:
        problems.append("claude_args has no `--disallowedTools \"...\"` — the subagent/skill fan-out is back")
    else:
        names = {t.strip() for t in m.group(1).split(",")}
        for want in ("Task", "Agent", "Skill", "Workflow"):
            if want not in names:
                problems.append(f"--disallowedTools is missing {want!r} (has {sorted(names)})")
    if "--allowedTools" not in args or "mcp__github_inline_comment__create_inline_comment" not in args:
        problems.append("claude_args no longer allowlists the inline-comment MCP tool")

# The anchor must be taken BEFORE the action runs, and the guard AFTER it.
order = [s.get("id") or s.get("name") for s in steps]
def idx(key):
    return order.index(key) if key in order else -1
if idx("clock") < 0:
    problems.append("no `id: clock` step (the guard's since-anchor)")
elif not (idx("clock") < idx("claude") < idx("guard")):
    problems.append(f"step order must be clock < claude < guard, got {order}")

guard = by_id.get("guard")
if guard is None:
    problems.append("no `id: guard` step")
else:
    cond = str(guard.get("if", ""))
    for want in ("!cancelled()", "steps.claude.outcome != 'skipped'", "steps.bot_check.outputs.skipped != 'true'"):
        if want not in cond:
            problems.append(f"guard `if:` lacks {want!r}: {cond!r}")
    env = guard.get("env", {})
    if env.get("EXECUTION_FILE") != "${{ steps.claude.outputs.execution_file }}":
        problems.append(f"guard EXECUTION_FILE not wired to steps.claude.outputs.execution_file: {env.get('EXECUTION_FILE')!r}")
    if env.get("STARTED_AT") != "${{ steps.clock.outputs.started_at }}":
        problems.append(f"guard STARTED_AT not wired to steps.clock.outputs.started_at: {env.get('STARTED_AT')!r}")
    if env.get("REVIEW_BOT") != "claude[bot]":
        problems.append(f"guard REVIEW_BOT must match the action's bot_name default 'claude[bot]': {env.get('REVIEW_BOT')!r}")

for p in problems:
    print(f"✗ {p}")
sys.exit(1 if problems else 0)
PY
[ "$failed" -eq 0 ] && pass "Task/Agent/Skill/Workflow disallowed; clock < claude < guard; guard wired to execution_file + anchor"

# ---------------------------------------------------------------------------
# 2. Behavioral: extract the shipped guard and run it against a gh stub
# ---------------------------------------------------------------------------
echo
echo "== lost-findings guard: shipped bash against a stubbed gh =="

extract_run "$WF" "$STEP" "$T/guard.sh" || { echo "FAILED"; exit 1; }
/bin/bash -n "$T/guard.sh" || fail "guard block does not parse under /bin/bash (macOS 3.2 / runner 5)"

# The stub. Reads serve fixture files verbatim (the shape real `gh api
# --paginate` prints: one JSON array per page, back to back). Writes are
# captured, never sent.
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
echo "gh $*" >> "$GH_LOG"
case "${1:-} ${2:-}" in
  "pr comment")
    # gh pr comment N -R o/r --body-file FILE  (same call the bot-skip step
    # in this job already makes under the same token permissions)
    prev=""
    for a in "$@"; do
      if [ "$prev" = "--body-file" ]; then cp "$a" "$GH_POSTED"; fi
      prev="$a"
    done
    if [ "${GH_POST_FAIL:-0}" = "1" ]; then echo "HTTP 403" >&2; exit 1; fi
    echo "https://github.com/o/r/pull/403#issuecomment-1"
    ;;
  api*)
    case "${2:-}" in
      */pulls/*/comments*)
        if [ "${GH_PULLS_FAIL:-0}" = "1" ]; then echo "HTTP 502: Bad Gateway" >&2; exit 1; fi
        cat "$GH_PULLS_JSON" ;;
      */issues/*/comments*)
        if [ "${GH_ISSUES_FAIL:-0}" = "1" ]; then echo "HTTP 502: Bad Gateway" >&2; exit 1; fi
        cat "$GH_ISSUES_JSON" ;;
      *) echo "STUB: unexpected endpoint '${2:-}'" >&2; exit 99 ;;
    esac
    ;;
  *) echo "STUB: unexpected 'gh $*'" >&2; exit 99 ;;
esac
STUB
chmod +x "$T/bin/gh"

SINCE="2026-08-16T03:52:32Z"

# --- fixtures: GitHub comment listings -------------------------------------
# One inline review comment per entry; `login` and `created_at` are what
# the guard filters on.
inline_json() {  # inline_json N [login] [created_at]  -> JSON array of N comments
  local n="$1" login="${2:-claude[bot]}" at="${3:-2026-08-16T04:40:00Z}"
  jq -nc --argjson n "$n" --arg login "$login" --arg at "$at" \
    '[range($n) | {id: (100 + .), user: {login: $login}, created_at: $at, path: "x.go", line: (10 + .), body: ("**Bug** #" + (.|tostring))}]'
}
issue_json() {  # issue_json BODY [login] [created_at]
  local body="$1" login="${2:-claude[bot]}" at="${3:-2026-08-16T04:44:54Z}"
  jq -nc --arg body "$body" --arg login "$login" --arg at "$at" \
    '[{id: 900, user: {login: $login}, created_at: $at, body: $body}]'
}
# The literal 04:44Z summary — the backticks are the model's markdown, not shell.
# shellcheck disable=SC2016
SUMMARY6='Flagged 6 issues inline — most critical: `t.Fatalf` on the probe-floor check (line 325) calls `runtime.Goexit()` before `scanForLiteralHCPingKey` runs.'

# --- fixtures: transcripts (the action's execution_file: an SDK message array)
FINDING1='t.Fatalf on the probe-floor check (line 325) calls runtime.Goexit() before scanForLiteralHCPingKey runs, so a broken scan never reports key hits'
FINDING2='first-win stage-1 semantics in parseLsFilesZ route a type-changed conflict entry through os.Readlink on a plain file'
transcript_denied_inline() {
  jq -nc --arg t "$INLINE_TOOL" --arg f1 "$FINDING1" --arg f2 "$FINDING2" '[
    {type: "system", subtype: "init"},
    {type: "assistant", message: {content: [{type: "tool_use", id: "tu_diff", name: "Bash", input: {command: "gh pr diff 403"}}]}},
    {type: "user", message: {content: [{type: "tool_result", tool_use_id: "tu_diff", is_error: false, content: "diff --git ..."}]}},
    {type: "result", subtype: "success", is_error: false, num_turns: 3,
     result: "Review complete. Flagged 6 issues inline.",
     permission_denials: [
       {tool_name: $t, tool_use_id: "tu_i1", tool_input: {path: "tests/regression/hc_ping_key_literal_test.go", line: 325, body: $f1}},
       {tool_name: $t, tool_use_id: "tu_i2", tool_input: {path: "tests/regression/hc_ping_key_literal_test.go", startLine: 240, line: 262, body: $f2}},
       {tool_name: "Bash", tool_use_id: "tu_b1", tool_input: {command: "go test ./tests/regression/..."}}
     ]}
  ]'
}
transcript_unrelated_denials() {
  jq -nc '[
    {type: "system", subtype: "init"},
    {type: "result", subtype: "success", is_error: false, num_turns: 3,
     result: "Done — posted the summary.",
     permission_denials: [
       {tool_name: "Bash", tool_use_id: "b1", tool_input: {command: "git diff origin/main...HEAD"}},
       {tool_name: "Bash", tool_use_id: "b2", tool_input: {command: "go test ./..."}},
       {tool_name: "WebFetch", tool_use_id: "w1", tool_input: {url: "https://example.com"}}
     ]}
  ]'
}
transcript_subagent_report() {
  local report
  report=$(printf 'Findings (verified):\n1. CONFIRMED tests/regression/hc_ping_key_literal_test.go:325 — %s\n2. PLAUSIBLE tests/regression/hc_ping_key_literal_test.go:262 — %s\n3. PLAUSIBLE deploy/systemd/README.md:221 — pre-flight grep rejects a double-quoted key that systemd accepts.\n' "$FINDING1" "$FINDING2")
  jq -nc --arg r "$report" '[
    {type: "system", subtype: "init"},
    {type: "assistant", message: {content: [{type: "tool_use", id: "tu_skill", name: "Skill", input: {skill: "code-review"}}]}},
    {type: "user", message: {content: [{type: "tool_result", tool_use_id: "tu_skill", is_error: false, content: [{type: "text", text: $r}]}]}},
    {type: "result", subtype: "success", is_error: false, num_turns: 3,
     result: "Flagged 3 issues inline — see comments.",
     permission_denials: [
       {tool_name: "Bash", tool_use_id: "b1", tool_input: {command: "gh api repos/whois-api-llc/wxa-graph/pulls/403/comments -f body=..."}}
     ]}
  ]'
}
transcript_errored_inline() {
  jq -nc --arg t "$INLINE_TOOL" --arg f1 "$FINDING1" '[
    {type: "system", subtype: "init"},
    {type: "assistant", message: {content: [{type: "tool_use", id: "tu_i1", name: $t, input: {path: "tests/regression/hc_ping_key_literal_test.go", line: 325, body: $f1}}]}},
    {type: "user", message: {content: [{type: "tool_result", tool_use_id: "tu_i1", is_error: true, content: "Error creating inline comment: Validation Failed"}]}},
    {type: "result", subtype: "success", is_error: false, num_turns: 4, result: "Flagged 1 issue inline.", permission_denials: []}
  ]'
}

# run_guard NAME  (env vars carry the scenario) -> sets RC, OUT
run_guard() {
  local name="$1"
  : > "$T/gh.log"
  rm -f "$T/posted.md"
  set +e
  OUT=$(GH_LOG="$T/gh.log" GH_POSTED="$T/posted.md" \
        PATH="$T/bin:$PATH" \
        REPO="whois-api-llc/wxa-graph" PR="403" STARTED_AT="$SINCE" \
        REVIEW_BOT="claude[bot]" RUN_URL="https://example.test/run/1" GITHUB_RUN_ID="31925279662" \
        EXECUTION_FILE="${EXECUTION_FILE:-}" \
        GH_PULLS_JSON="${GH_PULLS_JSON:-$T/none.json}" GH_ISSUES_JSON="${GH_ISSUES_JSON:-$T/none.json}" \
        GH_PULLS_FAIL="${GH_PULLS_FAIL:-0}" GH_ISSUES_FAIL="${GH_ISSUES_FAIL:-0}" GH_POST_FAIL="${GH_POST_FAIL:-0}" \
        /bin/bash "$T/guard.sh" 2>&1)
  RC=$?
  set -e
  echo "$OUT" > "$T/out.$name.txt"
}
posted() { [ -s "$T/posted.md" ]; }
posted_has() { grep -qF -- "$1" "$T/posted.md" 2>/dev/null; }
echo '[]' > "$T/none.json"

# --- S1: the incident shape, transcript holds the denied inline bodies -------
inline_json 0 > "$T/p1.json"
issue_json "$SUMMARY6" > "$T/i1.json"
transcript_denied_inline > "$T/x1.json"
EXECUTION_FILE="$T/x1.json" GH_PULLS_JSON="$T/p1.json" GH_ISSUES_JSON="$T/i1.json" run_guard s1
if [ "$RC" -eq 0 ] && posted \
   && posted_has "<!-- claude-review:lost-findings run=31925279662 -->" \
   && posted_has "flagged 6 issue(s) inline, but 0 inline comments were posted" \
   && posted_has "tests/regression/hc_ping_key_literal_test.go:325" \
   && posted_has "$FINDING1" \
   && posted_has "tests/regression/hc_ping_key_literal_test.go:240-262" \
   && posted_has "$FINDING2" \
   && grep -qF "permission denied for $INLINE_TOOL" "$T/out.s1.txt" \
   && grep -qF "permission denied for Bash" "$T/out.s1.txt" \
   && grep -qF "permission denials=3 (Bash,$INLINE_TOOL)" "$T/out.s1.txt" \
   && grep -qF "recovered findings were posted as a fallback comment" "$T/out.s1.txt"; then
  pass "S1 claim 6 / posted 0 / denied inline bodies in transcript: recovered, comment posted with both bodies + denial digest, exit 0"
else
  fail "S1 (rc=$RC):"; sed 's/^/    /' "$T/out.s1.txt"; [ -s "$T/posted.md" ] && sed 's/^/    | /' "$T/posted.md"
fi

# --- S2: the incident as it actually looked — nothing recoverable -------------
transcript_unrelated_denials > "$T/x2.json"
EXECUTION_FILE="$T/x2.json" GH_PULLS_JSON="$T/p1.json" GH_ISSUES_JSON="$T/i1.json" run_guard s2
if [ "$RC" -eq 1 ] && posted \
   && posted_has "Nothing beyond the summary was recoverable" \
   && posted_has "flagged 6 issue(s) inline" \
   && grep -qF "::error::review-guard: summary claims 6 inline finding(s), 0 posted, nothing recoverable" "$T/out.s2.txt" \
   && grep -qF "permission denied for Bash: {\"command\":\"go test ./...\"}" "$T/out.s2.txt" \
   && grep -qF "permission denied for WebFetch" "$T/out.s2.txt"; then
  pass "S2 claim 6 / posted 0 / only unrelated denials: comment says unrecoverable, denials named, job FAILS (exit 1)"
else
  fail "S2 (rc=$RC):"; sed 's/^/    /' "$T/out.s2.txt"
fi

# --- S3: the 03:41Z shape — summary undercounts, 7 posted -----------------------
inline_json 7 > "$T/p3.json"
issue_json "Flagged 3 issues inline — see comments." > "$T/i3.json"
EXECUTION_FILE="$T/x1.json" GH_PULLS_JSON="$T/p3.json" GH_ISSUES_JSON="$T/i3.json" run_guard s3
if [ "$RC" -eq 0 ] && ! posted && grep -qF "summary claims 3 inline finding(s); 7 inline review comment(s)" "$T/out.s3.txt"; then
  pass "S3 claim 3 / posted 7: silent, exit 0, no comment"
else
  fail "S3 (rc=$RC):"; sed 's/^/    /' "$T/out.s3.txt"
fi

# --- S4: clean review --------------------------------------------------------
issue_json "No issues found. Diff is small and contained." > "$T/i4.json"
EXECUTION_FILE="$T/x2.json" GH_PULLS_JSON="$T/p1.json" GH_ISSUES_JSON="$T/i4.json" run_guard s4
if [ "$RC" -eq 0 ] && ! posted && grep -qF "summary claims 0 inline finding(s); 0 inline" "$T/out.s4.txt"; then
  pass "S4 'No issues found': exit 0, no comment"
else
  fail "S4 (rc=$RC):"; sed 's/^/    /' "$T/out.s4.txt"
fi

# --- S5: subagent/skill report in the transcript is recoverable -------------------
transcript_subagent_report > "$T/x5.json"
issue_json "Flagged 3 issues inline — see comments." > "$T/i5.json"
EXECUTION_FILE="$T/x5.json" GH_PULLS_JSON="$T/p1.json" GH_ISSUES_JSON="$T/i5.json" run_guard s5
if [ "$RC" -eq 0 ] && posted \
   && posted_has "Subagent / skill report" \
   && posted_has "CONFIRMED tests/regression/hc_ping_key_literal_test.go:325" \
   && posted_has "deploy/systemd/README.md:221" \
   && grep -qF "subagent/skill calls=1" "$T/out.s5.txt"; then
  pass "S5 claim 3 / posted 0 / Skill(code-review) report in transcript: report posted verbatim, exit 0"
else
  fail "S5 (rc=$RC):"; sed 's/^/    /' "$T/out.s5.txt"
fi

# --- S6: errored (not denied) inline call is recovered from tool_use input --------
transcript_errored_inline > "$T/x6.json"
issue_json "Flagged 1 issue inline." > "$T/i6.json"
EXECUTION_FILE="$T/x6.json" GH_PULLS_JSON="$T/p1.json" GH_ISSUES_JSON="$T/i6.json" run_guard s6
if [ "$RC" -eq 0 ] && posted && posted_has "$FINDING1" \
   && grep -qF "inline-comment calls=1 (errored=1)" "$T/out.s6.txt"; then
  pass "S6 claim 1 / posted 0 / inline call errored (422): body recovered from tool_use input, exit 0"
else
  fail "S6 (rc=$RC):"; sed 's/^/    /' "$T/out.s6.txt"
fi

# --- S7: fail-safe — listing review comments errors --------------------------
EXECUTION_FILE="$T/x1.json" GH_PULLS_JSON="$T/p1.json" GH_ISSUES_JSON="$T/i1.json" GH_PULLS_FAIL=1 run_guard s7
if [ "$RC" -eq 0 ] && ! posted && grep -qF "could not list review comments" "$T/out.s7.txt"; then
  pass "S7 pulls/comments API error: warning, exit 0, no comment (fail-safe)"
else
  fail "S7 (rc=$RC):"; sed 's/^/    /' "$T/out.s7.txt"
fi
EXECUTION_FILE="$T/x1.json" GH_PULLS_JSON="$T/p1.json" GH_ISSUES_JSON="$T/i1.json" GH_ISSUES_FAIL=1 run_guard s7b
if [ "$RC" -eq 0 ] && ! posted && grep -qF "could not list issue comments" "$T/out.s7b.txt"; then
  pass "S7b issues/comments API error: warning, exit 0, no comment (fail-safe)"
else
  fail "S7b (rc=$RC):"; sed 's/^/    /' "$T/out.s7b.txt"
fi

# --- S8: accepted miss — claim phrased outside the mandated shape ---------------
issue_json "Found 2 problems, see the inline notes." > "$T/i8.json"
EXECUTION_FILE="$T/x1.json" GH_PULLS_JSON="$T/p1.json" GH_ISSUES_JSON="$T/i8.json" run_guard s8
if [ "$RC" -eq 0 ] && ! posted && grep -qF "summary claims 0 inline finding(s)" "$T/out.s8.txt"; then
  pass "S8 'Found 2 problems, see the inline notes': reads as 0 — the accepted, explicit miss (no guessing at prose)"
else
  fail "S8 (rc=$RC):"; sed 's/^/    /' "$T/out.s8.txt"
fi

# --- S9: partial loss with recoverable bodies -------------------------------------
inline_json 1 > "$T/p9.json"
issue_json "Flagged 3 issues inline — see comments." > "$T/i9.json"
EXECUTION_FILE="$T/x1.json" GH_PULLS_JSON="$T/p9.json" GH_ISSUES_JSON="$T/i9.json" run_guard s9
if [ "$RC" -eq 0 ] && posted && posted_has "but only 1 inline comment(s) were posted" && posted_has "$FINDING2"; then
  pass "S9 claim 3 / posted 1 / denied inline bodies: partial — bodies posted, exit 0"
else
  fail "S9 (rc=$RC):"; sed 's/^/    /' "$T/out.s9.txt"
fi

# --- S10: partial loss, nothing recoverable — warn only, never fail ------------------
EXECUTION_FILE="$T/x2.json" GH_PULLS_JSON="$T/p9.json" GH_ISSUES_JSON="$T/i9.json" run_guard s10
if [ "$RC" -eq 0 ] && ! posted && grep -qF "but only 1 posted; transcript holds nothing recoverable beyond the summary" "$T/out.s10.txt"; then
  pass "S10 claim 3 / posted 1 / nothing recoverable: warning only, exit 0"
else
  fail "S10 (rc=$RC):"; sed 's/^/    /' "$T/out.s10.txt"
fi

# --- S11: no transcript at all — still judges claim vs fact ---------------------------
EXECUTION_FILE="" GH_PULLS_JSON="$T/p1.json" GH_ISSUES_JSON="$T/i1.json" run_guard s11
if [ "$RC" -eq 1 ] && posted && posted_has "Nothing beyond the summary was recoverable" \
   && grep -qF "no readable transcript" "$T/out.s11.txt"; then
  pass "S11 no execution_file: warns, still fails on claim 6 / posted 0 with nothing recoverable"
else
  fail "S11 (rc=$RC):"; sed 's/^/    /' "$T/out.s11.txt"
fi

# --- S12: only THIS run's bot comments count -----------------------------------------
{ inline_json 3 "claude[bot]" "2026-08-16T03:41:22Z"; } | jq -c '.' > "$T/p12a.json"   # earlier run
{ inline_json 2 "topcoder1"  "2026-08-16T04:50:00Z"; } | jq -c '.' > "$T/p12b.json"   # human, this window
jq -sc 'add' "$T/p12a.json" "$T/p12b.json" > "$T/p12.json"
EXECUTION_FILE="$T/x2.json" GH_PULLS_JSON="$T/p12.json" GH_ISSUES_JSON="$T/i1.json" run_guard s12
if [ "$RC" -eq 1 ] && grep -qF "summary claims 6 inline finding(s); 0 inline review comment(s)" "$T/out.s12.txt"; then
  pass "S12 bot comments before the anchor and human comments after it do not count as this run's output"
else
  fail "S12 (rc=$RC):"; sed 's/^/    /' "$T/out.s12.txt"
fi

# --- S13: --paginate shape — two pages back to back are summed -----------------------
{ inline_json 2; inline_json 1 "claude[bot]" "2026-08-16T04:41:00Z"; } > "$T/p13.json"
issue_json "Flagged 3 issues inline — see comments." > "$T/i13.json"
EXECUTION_FILE="$T/x2.json" GH_PULLS_JSON="$T/p13.json" GH_ISSUES_JSON="$T/i13.json" run_guard s13
if [ "$RC" -eq 0 ] && ! posted && grep -qF "summary claims 3 inline finding(s); 3 inline review comment(s)" "$T/out.s13.txt"; then
  pass "S13 multi-page --paginate output ([..][..]) is flattened and summed"
else
  fail "S13 (rc=$RC):"; sed 's/^/    /' "$T/out.s13.txt"
fi

# --- S14: recovered findings, but the fallback comment cannot be posted ----------------
# Findings that live only in a job log are still lost to the PR. The body is
# echoed into the log and the job FAILS (Codex round 1).
EXECUTION_FILE="$T/x1.json" GH_PULLS_JSON="$T/p1.json" GH_ISSUES_JSON="$T/i1.json" GH_POST_FAIL=1 run_guard s14
if [ "$RC" -eq 1 ] && grep -qF "could not post the lost-findings comment" "$T/out.s14.txt" \
   && grep -qF "recovered findings could not be posted" "$T/out.s14.txt" \
   && grep -qF "    | - \`tests/regression/hc_ping_key_literal_test.go:325\`" "$T/out.s14.txt"; then
  pass "S14 recovered + POST failure: body echoed to the log, job FAILS (findings are not on the PR)"
else
  fail "S14 (rc=$RC):"; sed 's/^/    /' "$T/out.s14.txt"
fi

# --- S15: partial loss where the only recoverable content is a subagent report ------------
EXECUTION_FILE="$T/x5.json" GH_PULLS_JSON="$T/p9.json" GH_ISSUES_JSON="$T/i9.json" run_guard s15
if [ "$RC" -eq 0 ] && posted && posted_has "but only 1 inline comment(s) were posted" \
   && posted_has "Subagent / skill report" && posted_has "deploy/systemd/README.md:221"; then
  pass "S15 claim 3 / posted 1 / only a Skill report recoverable: report posted, exit 0 (Codex round 1)"
else
  fail "S15 (rc=$RC):"; sed 's/^/    /' "$T/out.s15.txt"
fi

# --- S16: malformed transcript entries never break the digest or the recovery ------------
# Valid JSON array, but permission_denials carries a number and a string next
# to a real denial, and a content array carries a non-object. Every read
# tolerates it: the real denial is still named and its body still recovered,
# and no jq error leaks into the log.
jq -nc --arg t "$INLINE_TOOL" --arg f1 "$FINDING1" '[
  {type: "system", subtype: "init"},
  {type: "assistant", message: {content: [7, {type: "tool_use", id: "tu_x", name: "Bash", input: {command: "gh pr diff 403"}}]}},
  {type: "user", message: {content: ["oops", {type: "tool_result", tool_use_id: "tu_x", content: "diff"}]}},
  {type: "result", subtype: "success", result: "Flagged 6 issues inline.",
   permission_denials: [1, "bare", {tool_name: $t, tool_use_id: "tu_i1", tool_input: {path: "tests/regression/hc_ping_key_literal_test.go", line: 325, body: $f1}}]}
]' > "$T/x16.json"
EXECUTION_FILE="$T/x16.json" GH_PULLS_JSON="$T/p1.json" GH_ISSUES_JSON="$T/i1.json" run_guard s16
if [ "$RC" -eq 0 ] && posted && posted_has "$FINDING1" \
   && grep -qF "permission denied for $INLINE_TOOL" "$T/out.s16.txt" \
   && grep -qF "permission denials=1 ($INLINE_TOOL)" "$T/out.s16.txt" \
   && ! grep -q "jq: error" "$T/out.s16.txt"; then
  pass "S16 malformed transcript entries are skipped; the real denial is named and its body recovered, no jq error leaks (Codex round 1)"
else
  fail "S16 (rc=$RC):"; sed 's/^/    /' "$T/out.s16.txt"
fi

# --- S16b: an inline-comment call with no body is not a finding ------------------------------
# A denied call whose tool_input has a path but an empty/missing body must not
# render as a placeholder line and count as recovered (Codex round 3).
jq -nc --arg t "$INLINE_TOOL" '[
  {type: "system", subtype: "init"},
  {type: "result", subtype: "success", result: "Flagged 6 issues inline.",
   permission_denials: [
     {tool_name: $t, tool_use_id: "tu_i1", tool_input: {path: "a.go", line: 3, body: ""}},
     {tool_name: $t, tool_use_id: "tu_i2", tool_input: {path: "b.go", line: 4}}
   ]}
]' > "$T/x16b.json"
EXECUTION_FILE="$T/x16b.json" GH_PULLS_JSON="$T/p1.json" GH_ISSUES_JSON="$T/i1.json" run_guard s16b
if [ "$RC" -eq 1 ] && posted && posted_has "Nothing beyond the summary was recoverable" && ! posted_has "\`a.go:3\`" && ! posted_has "\`b.go:4\`"; then
  pass "S16b denied inline calls with empty/missing body are not recovery: no placeholder lines, job fails (Codex round 3)"
else
  fail "S16b (rc=$RC):"; sed 's/^/    /' "$T/out.s16b.txt"; [ -s "$T/posted.md" ] && sed 's/^/    | /' "$T/posted.md"
fi

# --- S18: buffered inline calls that the action's post-step dropped are recovered -----------
# With classify_inline_comments the first call only buffers; if the classifier
# drops it as a "probe" (or the post-step fails) the body exists only in the
# transcript's tool_use.input. Two successful (non-error) calls, nothing
# posted: both bodies must come back (Codex round 4).
jq -nc --arg t "$INLINE_TOOL" --arg f1 "$FINDING1" --arg f2 "$FINDING2" '[
  {type: "system", subtype: "init"},
  {type: "assistant", message: {content: [
     {type: "tool_use", id: "tu_i1", name: $t, input: {path: "tests/regression/hc_ping_key_literal_test.go", line: 325, body: $f1}},
     {type: "tool_use", id: "tu_i2", name: $t, input: {path: "tests/regression/hc_ping_key_literal_test.go", startLine: 240, line: 262, body: $f2}}]}},
  {type: "user", message: {content: [
     {type: "tool_result", tool_use_id: "tu_i1", is_error: false, content: "{\"success\":true,\"buffered\":true}"},
     {type: "tool_result", tool_use_id: "tu_i2", is_error: false, content: "{\"success\":true,\"buffered\":true}"}]}},
  {type: "result", subtype: "success", result: "Flagged 2 issues inline.", permission_denials: []}
]' > "$T/x18.json"
issue_json "Flagged 2 issues inline — see comments." > "$T/i18.json"
EXECUTION_FILE="$T/x18.json" GH_PULLS_JSON="$T/p1.json" GH_ISSUES_JSON="$T/i18.json" run_guard s18
if [ "$RC" -eq 0 ] && posted && posted_has "$FINDING1" && posted_has "$FINDING2" \
   && posted_has "tests/regression/hc_ping_key_literal_test.go:240-262" \
   && grep -qF "inline-comment calls=2 (errored=0)" "$T/out.s18.txt"; then
  pass "S18 buffered-then-dropped inline calls: both bodies recovered from tool_use.input, exit 0 (Codex round 4)"
else
  fail "S18 (rc=$RC):"; sed 's/^/    /' "$T/out.s18.txt"
fi

# --- S18b: a successful call whose body DID land is not double-reported ---------------------
# posted holds FINDING1 verbatim; the transcript has both calls; only FINDING2
# is unlanded. Claim 2 / posted 1 -> partial, FINDING2 recovered, FINDING1 not
# repeated.
jq -nc --arg f1 "$FINDING1" '[{id: 1, user: {login: "claude[bot]"}, created_at: "2026-08-16T04:40:00Z", path: "tests/regression/hc_ping_key_literal_test.go", line: 325, body: $f1}]' > "$T/p18b.json"
EXECUTION_FILE="$T/x18.json" GH_PULLS_JSON="$T/p18b.json" GH_ISSUES_JSON="$T/i18.json" run_guard s18b
if [ "$RC" -eq 0 ] && posted && posted_has "$FINDING2" && ! posted_has "$FINDING1" \
   && posted_has "but only 1 inline comment(s) were posted"; then
  pass "S18b a buffered call whose body was posted is excluded; only the unlanded body is recovered"
else
  fail "S18b (rc=$RC):"; sed 's/^/    /' "$T/out.s18b.txt"; [ -s "$T/posted.md" ] && sed 's/^/    | /' "$T/posted.md"
fi

# --- S17: a substantive final message counts as recovered; a bare restatement does not ------
LONG_FINAL=$(printf 'Review of PR 403 - findings:\n1. tests/regression/hc_ping_key_literal_test.go:325 - %s\n2. tests/regression/hc_ping_key_literal_test.go:262 - %s\n3. deploy/systemd/README.md:221 - pre-flight grep rejects a double-quoted key that systemd accepts, so a valid unit file fails the check.\n4. docs/runbooks/netblocks-ingest.md:148 - semicolon between the two pulls masks a failed yesterday-ingest; use && so the daily recipe stops on the first failure.\n5. deploy/systemd/wxa-graph-cluster.service:12 - EnvironmentFile is optional (-) so a missing .env silently starts the unit without the ping key.\n6. scripts/govulncheck-alert.sh:40 - jq filter assumes .Vulns is always an array; null on a clean scan makes the script exit non-zero.\n' "$FINDING1" "$FINDING2")
jq -nc --arg r "$LONG_FINAL" '[
  {type: "system", subtype: "init"},
  {type: "result", subtype: "success", result: $r, permission_denials: [{tool_name: "Bash", tool_use_id: "b1", tool_input: {command: "go test ./..."}}]}
]' > "$T/x17.json"
EXECUTION_FILE="$T/x17.json" GH_PULLS_JSON="$T/p1.json" GH_ISSUES_JSON="$T/i1.json" run_guard s17
if [ "$RC" -eq 0 ] && posted && posted_has "#### Final message" && posted_has "scripts/govulncheck-alert.sh:40" \
   && ! posted_has "Nothing beyond the summary was recoverable"; then
  pass "S17 final message >= 600 chars and >= 2x the summary counts as recovered: posted, exit 0 (Codex round 1)"
else
  fail "S17 (rc=$RC):"; sed 's/^/    /' "$T/out.s17.txt"
fi
jq -nc '[
  {type: "system", subtype: "init"},
  {type: "result", subtype: "success", result: "Flagged 6 issues inline - most critical: t.Fatalf on the probe-floor check calls runtime.Goexit() before scanForLiteralHCPingKey runs; and first-win stage-1 semantics in parseLsFilesZ can route a type-changed conflict entry through os.Readlink on a plain file, silently skipping it.", permission_denials: []}
]' > "$T/x17b.json"
EXECUTION_FILE="$T/x17b.json" GH_PULLS_JSON="$T/p1.json" GH_ISSUES_JSON="$T/i1.json" run_guard s17b
if [ "$RC" -eq 1 ] && posted && posted_has "Nothing beyond the summary was recoverable"; then
  pass "S17b a final message that merely restates the summary is NOT recovery: job still fails"
else
  fail "S17b (rc=$RC):"; sed 's/^/    /' "$T/out.s17b.txt"
fi

echo
if [ "$failed" -ne 0 ]; then
  echo "FAILED"
  exit 1
fi
echo "PASSED"
