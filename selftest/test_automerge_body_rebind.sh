#!/usr/bin/env bash
# Behavioral test for the body re-bind in claude-author-automerge.yml's
# "Enable auto-merge" step.
#
# The closing-keyword gate ("Check PR body closing keywords") judges the PR
# body from the event payload and publishes a hash of it. A body edit fires
# only `pull_request: edited`, which no caller subscribes to, so the arm step
# re-reads the live body right before arming and stands down on ANY change.
#
# Incident (topcoder1/ipgeo_core#387, 2026-11-22): a description quoting
# `\u0000` twice stood down as "PR body changed" on every run and was
# labeled automerge:body-changed, though nobody had edited it. The re-read
# went through `gh api --jq`, and gh passes every JSON response through
# go-gh's ASCII sanitizer before --jq sees it. Measured 2026-11-23 on gh
# 2.89.0 (go-gh v2.13.0) against a local JSON server: gh rewrites, into caret
# notation (^@ … ^_), the JSON escapes \u0000–\u0008, \u000c, \u000e–\u001f
# and \u0080–\u009f in either hex case, the raw C1 characters U+0080–U+009F,
# and the literal text a description quotes: a backslash, then u00XX of the
# same set (`\u0000` came back `\^@`). TAB, LF, VT, CR, DEL (U+007F), the
# short escapes \b and \f, and everything from U+00A0 up pass unchanged. The
# gate hashed the event payload's exact text, so those bodies never matched.
#
# The test runs the SHIPPED gate step for the hash, then the SHIPPED arm step
# against a local server that serves the PR the way GitHub's REST API does
# (a 404 without the token, as for a private repo). `gh` is a stub, except
# that a `.body` read is handed to the REAL gh CLI pointed at that server, so
# a re-read through gh meets gh's real sanitizer, not an imitation of it.
# `curl` (behind a wrapper that logs its arguments) and `jq` are real.
#
#   1. a plain body, unchanged                     ⇒ arms (positive control)
#   2. an empty description (the API's body is null) ⇒ arms
#   3. the incident: `\u0000` quoted twice         ⇒ arms
#   4. a real ESC colour sequence (pasted output)  ⇒ arms
#   5. a C1 control character (U+0085)             ⇒ arms
#   6. the body edited after the gate              ⇒ stands down as "body",
#                                                    disarms, no arm
#   7. an edit only gh's sanitizer would hide: the ⇒ stands down; the re-read
#      gate saw `\^[`, the live body says `\u001b`   is exact, not normalised
#   8. the re-read fails (HTTP 502)                ⇒ exit 1, disarms, no arm
#   9. the re-read sends the token, and never on a command line
# Negative control:
#  10. the old `gh api … --jq '.body // ""'` read planted back ⇒ case 4
#      stands down, read through the real gh: the harness sees the incident.
#
# Needs gh, curl, jq and python3 (all on GitHub's ubuntu runners).
# Run from the repo root:
#   bash selftest/test_automerge_body_rebind.sh
set -euo pipefail

WF=.github/workflows/claude-author-automerge.yml
failed=0
T=$(mktemp -d)
SERVER_PID=""
trap '[ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true; rm -rf "$T"' EXIT

pass() { echo "✓ $1"; }
fail() {
  echo "✗ $1"
  failed=1
}

for tool in gh curl jq python3; do
  if ! command -v "$tool" > /dev/null; then
    echo "✗ this test needs $tool on PATH"
    exit 1
  fi
done
REAL_GH=$(command -v gh)
REAL_CURL=$(command -v curl)

extract_run() { # step name → that step's run block, de-indented
  awk -v name="      - name: $1" '
    $0 == name { in_step = 1; next }
    in_step && /^      - name: / { exit }
    in_step && /^        run: \|/ { in_run = 1; next }
    in_run {
      if ($0 ~ /^          / || $0 == "") { sub(/^          /, ""); print }
      else { exit }
    }
  ' "$WF"
}
extract_run "Check PR body closing keywords" > "$T/gate.sh"
extract_run "Enable auto-merge" > "$T/arm.sh"
if ! grep -q 'body_sha=' "$T/gate.sh" || ! grep -q 'gh pr merge --auto' "$T/arm.sh" \
  || ! grep -q 'GATE_BODY_SHA' "$T/arm.sh"; then
  echo "✗ could not extract the gate step and the arm step's body re-bind from $WF"
  exit 1
fi
pass "extracted the gate step and the arm step"

# ---------------------------------------------------------------------------
# The local API server. It serves GET /repos/stub/repo/pulls/42 from the
# files in $API: `live_body` (absent ⇒ null), `status` (an HTTP status to
# fail with), `token` (the only credential it accepts). Bodies are encoded as
# GitHub's encoder does: C0 controls escaped, C1 and DEL raw UTF-8. Every
# request is logged to requests.log with its auth verdict and User-Agent.
# ---------------------------------------------------------------------------
API="$T/api"
mkdir -p "$API"
cat > "$T/server.py" <<'PY'
import http.server
import json
import os
import sys

state = sys.argv[1]


def read(name, default=None):
    try:
        with open(os.path.join(state, name), "rb") as f:
            return f.read()
    except FileNotFoundError:
        return default


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        token = read("token", b"").decode()
        auth = self.headers.get("Authorization", "")
        verdict = "ok" if auth in (f"Bearer {token}", f"token {token}") else ("missing" if not auth else "wrong")
        with open(os.path.join(state, "requests.log"), "a") as log:
            log.write(f"GET {self.path} auth={verdict} ua={self.headers.get('User-Agent', '')}\n")
        status = int(read("status", b"200").decode().strip() or "200")
        if self.path != "/repos/stub/repo/pulls/42" or verdict != "ok":
            status, doc = 404, {"message": "Not Found", "status": "404"}
        elif status != 200:
            doc = {"message": "Server Error", "status": str(status)}
        else:
            body = read("live_body")
            doc = {
                "number": 42,
                "body": None if body is None else body.decode("utf-8"),
                "base": {"ref": "main"},
            }
        data = json.dumps(doc, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(os.path.join(state, "port.tmp"), "w") as f:
    f.write(str(server.server_address[1]))
os.rename(os.path.join(state, "port.tmp"), os.path.join(state, "port"))
server.serve_forever()
PY
python3 -I "$T/server.py" "$API" > "$T/server.log" 2>&1 < /dev/null &
SERVER_PID=$!
disown "$SERVER_PID" # the EXIT trap's kill must not print a job notice
for _ in $(seq 1 100); do
  [ -s "$API/port" ] && break
  sleep 0.05
done
if ! [ -s "$API/port" ]; then
  echo "✗ the local API server did not start:"
  sed 's/^/    /' "$T/server.log"
  exit 1
fi
API_URL="http://127.0.0.1:$(cat "$API/port")"
TOKEN="pat-stub-5c1e"
printf '%s' "$TOKEN" > "$API/token"

# ---------------------------------------------------------------------------
# Stubs. `gh` models the PR's auto-merge state (`arm`: ON|OFF) and answers
# the step's reads by running its --jq filter over API-shaped JSON; a `.body`
# read goes to the real gh against the server, with an empty config dir and
# a dummy login so no real credential is involved. `curl` logs its argv and
# runs the real curl. `sleep` no-ops the retry backoffs.
# ---------------------------------------------------------------------------
S="$T/state"
mkdir -p "$T/bin" "$S/gh-config" "$S/xdg"
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
d="$STUB_DIR"
printf 'gh %s\n' "$*" >> "$d/calls.log"
filter=""
prev=""
for a in "$@"; do
  [ "$prev" = "--jq" ] && filter="$a"
  prev="$a"
done
case "${1:-} ${2:-}" in
  "pr view")
    if [ "$(cat "$d/arm")" = "ON" ]; then
      echo '{"autoMergeRequest":{"enabledBy":{"login":"pat-user","is_bot":false}}}'
    else
      echo '{"autoMergeRequest":null}'
    fi | jq -r "$filter"
    exit ;;
  "pr merge")
    case " $* " in
      *" --disable-auto "*) echo OFF > "$d/arm"; exit 0 ;;
      *" --auto "*) echo ON > "$d/arm"; exit 0 ;;
    esac ;;
  "api user")
    echo '{"login":"pat-user","type":"User"}' | jq -r "$filter"
    exit ;;
  "api repos/stub/repo/pulls/42")
    case "$filter" in
      *.body*)
        step_token="$GH_TOKEN"
        exec env -u GH_HOST -u GH_ENTERPRISE_TOKEN -u GITHUB_TOKEN \
          GH_TOKEN=dummy-local-only GH_CONFIG_DIR="$d/gh-config" \
          XDG_CONFIG_HOME="$d/xdg" XDG_CACHE_HOME="$d/xdg" XDG_STATE_HOME="$d/xdg" XDG_DATA_HOME="$d/xdg" \
          GH_NO_UPDATE_NOTIFIER=1 GH_PROMPT_DISABLED=1 \
          "$REAL_GH" api "$API_URL/repos/stub/repo/pulls/42" \
          -H "Authorization: token $step_token" --jq "$filter" ;;
      *)
        jq -n --arg h "$EVENT_HEAD" '{head: {sha: $h}, base: {ref: "main"}}' | jq -r "$filter"
        exit ;;
    esac ;;
esac
echo "STUB: unexpected 'gh $*'" >&2
exit 99
STUB
cat > "$T/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$STUB_DIR/calls.log"
exec "$REAL_CURL" "$@"
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/sleep"
chmod +x "$T/bin/gh" "$T/bin/curl" "$T/bin/sleep"

EVENT_HEAD=$(printf 'c0ffee%034d' 1)

gate_sha() { # event body → the body_sha the shipped gate publishes
  : > "$T/gate-out"
  if ! (cd "$T" && PR_BODY="$1" BASE_REF=main DEFAULT_BRANCH=main GITHUB_OUTPUT="$T/gate-out" \
    bash gate.sh) > "$T/gate.log" 2>&1 < /dev/null; then
    echo "✗ the gate step failed:" >&2
    sed 's/^/    /' "$T/gate.log" >&2
    return 1
  fi
  sed -n 's/^body_sha=//p' "$T/gate-out" | tail -n 1
}

# run_arm <script> <event body> <live body> → $T/out, ending in rc=<n>. The
# PR starts armed by an earlier run. LIVE_NULL=1 serves a null body;
# API_STATUS fails the PR read with that HTTP status.
run_arm() {
  local sha rc=0
  sha=$(gate_sha "$2") || exit 1
  if [ -z "$sha" ]; then
    echo "✗ the gate step published no body_sha"
    exit 1
  fi
  if [ "${LIVE_NULL:-0}" = "1" ]; then
    rm -f "$API/live_body"
  else
    printf '%s' "$3" > "$API/live_body"
  fi
  echo "${API_STATUS:-200}" > "$API/status"
  : > "$API/requests.log"
  : > "$S/calls.log"
  : > "$S/ghout"
  echo ON > "$S/arm"
  (
    export PATH="$T/bin:$PATH" STUB_DIR="$S" REAL_GH REAL_CURL API_URL EVENT_HEAD \
      GITHUB_OUTPUT="$S/ghout" GITHUB_REPOSITORY=stub/repo GITHUB_API_URL="$API_URL" \
      GH_TOKEN="$TOKEN" BOT_TOKEN=bot-stub PR=42 PR_URL="https://github.com/stub/repo/pull/42" \
      HEAD_SHA="$EVENT_HEAD" METHOD=squash REASON="branch=claude/x" RISKY=0 \
      BYPASS_LABEL=0 BYPASS_CODEX=0 USING_PAT=1 PR_AUTHOR=topcoder1 \
      GATE_BASE_REF=main GATE_BODY_SHA="$sha" DEFAULT_BRANCH=main OPTIN_LABEL=auto-merge-nonmain \
      CLASSIFIER_HEAD="$EVENT_HEAD" RISK_HEAD="$EVENT_HEAD"
    bash "$1"
  ) > "$T/out" 2>&1 < /dev/null || rc=$?
  echo "rc=$rc" >> "$T/out"
}
has() { grep -qF -- "$1" "$T/out"; }
published() { grep -qxF -- "$1" "$S/ghout"; }
armed() { grep -q "^gh pr merge --auto --squash --match-head-commit $EVENT_HEAD " "$S/calls.log"; }
disarmed() { grep -q '^gh pr merge --disable-auto' "$S/calls.log"; }
arm_is() { [ "$(cat "$S/arm")" = "$1" ]; }
dump() {
  sed 's/^/    out: /' "$T/out"
  sed 's/^/    call: /' "$S/calls.log"
  sed 's/^/    api: /' "$API/requests.log"
  sed 's/^/    output: /' "$S/ghout"
}

expect_arms() { # description, event body, [live body — default: unchanged]
  run_arm "$T/arm.sh" "$2" "${3-$2}"
  if has "rc=0" && armed && ! disarmed && arm_is ON && published "armed=1" \
    && ! grep -q '^stood_down=' "$S/ghout" && ! has "PR body changed"; then
    pass "$1"
  else
    fail "$1"
    dump
  fi
}
expect_body_stand_down() { # description, event body, live body [, script]
  run_arm "${4:-$T/arm.sh}" "$2" "$3"
  if has "rc=0" && ! armed && disarmed && arm_is OFF && published "stood_down=body" \
    && has "PR body changed since this run's gate read"; then
    pass "$1"
  else
    fail "$1"
    dump
  fi
}

# ---------------------------------------------------------------------------
# 1–5. An unchanged body arms, whatever characters it quotes.
# ---------------------------------------------------------------------------
CRLF=$'\r\n'
ESC=$'\033'
NEL=$'\xc2\x85'
expect_arms "1: a plain body, unchanged ⇒ arms" "Small fix.${CRLF}${CRLF}Closes #12."
LIVE_NULL=1 expect_arms "2: an empty description (the API's body is null) ⇒ arms" ""
# shellcheck disable=SC2016  # the backticks and \u0000 are the body's text
INCIDENT='The parser now rejects names holding `\u0000`.

Before this fix a second `\u0000` slipped through as an empty label.'
expect_arms "3: the incident: a body quoting \`\\u0000\` twice ⇒ arms" "$INCIDENT"
COLOUR="Test output:${CRLF}${CRLF}\`\`\`${CRLF}${ESC}[32mPASS${ESC}[0m selftest${CRLF}\`\`\`"
expect_arms "4: a real ESC colour sequence (pasted test output) ⇒ arms" "$COLOUR"
expect_arms "5: a C1 control character (U+0085, from mis-decoded text) ⇒ arms" \
  "Pasted from a CP1252 document:${NEL}the next line."

# ---------------------------------------------------------------------------
# 6–7. A real edit still stands down, including one gh's sanitizer would
# have hidden: the re-read must be exact, not merely normalised the same way.
# ---------------------------------------------------------------------------
expect_body_stand_down "6: the body edited after the gate ⇒ stands down as 'body' and disarms" \
  "Closes #12." "Closes #12 follow-up (b)."
# shellcheck disable=SC2016
expect_body_stand_down "7: an edit only gh's sanitizer hides (\`\\^[\` → \`\\u001b\`) ⇒ stands down" \
  'Caret notation: `\^[` is ESC.' 'Caret notation: `\u001b` is ESC.'

# ---------------------------------------------------------------------------
# 8. A failed re-read fails closed: no arm, and an earlier arm comes off.
# ---------------------------------------------------------------------------
API_STATUS=502 run_arm "$T/arm.sh" "Closes #12." "Closes #12."
if has "rc=1" && has "could not re-read the PR body before arming" && ! armed && disarmed && arm_is OFF \
  && ! grep -q '^stood_down=' "$S/ghout"; then
  pass "8: the re-read fails (HTTP 502) ⇒ exit 1, disarmed, no arm"
else
  fail "8: a failed body re-read must fail closed and remove the standing arm"
  dump
fi

# ---------------------------------------------------------------------------
# 9. The re-read is authenticated (the server 404s anything else, as GitHub
# does for a private repo), and the token never sits on a command line.
# ---------------------------------------------------------------------------
run_arm "$T/arm.sh" "Closes #12." "Closes #12."
if grep -q 'auth=ok' "$API/requests.log" && ! grep -qE 'auth=(missing|wrong)' "$API/requests.log" \
  && ! grep -qF -- "$TOKEN" "$S/calls.log" && has "rc=0"; then
  pass "9: the re-read sends GH_TOKEN, and not on a command line"
else
  fail "9: the body re-read must authenticate with GH_TOKEN, passed off the command line"
  dump
fi

# ---------------------------------------------------------------------------
# 10. Negative control: plant the old gh read back; case 4 must stand down,
# through the real gh. Without this the harness could lose its real-gh path
# and every case above would still pass.
# ---------------------------------------------------------------------------
if python3 -I - "$T/arm.sh" "$T/arm_old.sh" <<'PY'; then
import re
import sys

src = open(sys.argv[1]).read()
old = """now_body=$(gh api "repos/${GITHUB_REPOSITORY}/pulls/${PR}" --jq '.body // ""') || {"""
read = re.compile(r"now_body=\$\(.*?\) \|\| \{", re.S)
if len(read.findall(src)) != 1:
    sys.exit("cannot plant the old read: the body re-read is not one `now_body=$(…) || {`")
open(sys.argv[2], "w").write(read.sub(lambda m: old, src, count=1))
PY
  expect_body_stand_down "10: negative control: the old gh read, planted back, stands down on case 4" \
    "$COLOUR" "$COLOUR" "$T/arm_old.sh"
  if grep -q 'ua=GitHub CLI' "$API/requests.log"; then
    pass "10: the planted read went through the real gh CLI"
  else
    fail "10: the planted read never reached the real gh; the harness no longer reproduces the incident"
    dump
  fi
else
  fail "10: negative control: could not plant the old read into the arm step"
fi

echo ""
if [ "$failed" -ne 0 ]; then
  echo "FAIL: the arm step's body re-bind misreads an unchanged body, or misses an edit."
  exit 1
fi
echo "PASS: the body re-bind arms on every unchanged body and stands down on every edit."
