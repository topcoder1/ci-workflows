#!/usr/bin/env bash
# Behavioral test for claude-review.yml's caller check and review-ran check:
# a required `review / Claude Review` must never pass with nothing reviewed.
#
# THE GAP. claude-code-action (pinned at v1.0.229) gets its GitHub token by
# exchanging the job's OIDC token for a Claude GitHub App token, and the
# exchange refuses any run whose calling workflow differs from the default
# branch's copy. The action then logs "Skipping action due to workflow
# validation" as a warning and returns without failing its step
# (src/github/token.ts, src/entrypoints/run.ts). Every PR that added or
# edited its caller (.github/workflows/pr-review.yml) therefore concluded
# `success` in about 30 seconds with nothing reviewed, the rest of its diff
# included, and a ruleset that requires the check accepted that green.
# Fleet evidence: topcoder1/dotclaude#519.
#
# TWO STEPS, pinned by extracting the workflow's SHIPPED bash and running it
# against a stubbed `gh` (the caller check also against a real git checkout),
# never a mirrored copy:
#
#   1. Caller check. Compares the caller's blob at HEAD with the default
#      branch's (contents API) and writes changed=false only on a proven
#      match. Whenever changed != 'false' the review step passes
#      `github_token: github.token`, which skips the OIDC exchange, so those
#      PRs get a real review, and the lost-findings guard's REVIEW_BOT
#      follows with the same predicate. A read failure is changed=true: the
#      review runs either way.
#
#   2. Review-ran check. A review step that ended `success` with no
#      `conclusion` output reviewed nothing. The check writes reviewed=false
#      first, posts or PATCHes ONE sticky comment, and fails the job. A
#      failed post degrades to a warning and never changes the verdict.
#
# The steps' `if:` conditions and the `github_token` / `REVIEW_BOT`
# expressions are EVALUATED, by a small evaluator for the GitHub expression
# subset they use, not compared as text. That catches an expression that
# reads right and evaluates wrong: `x == 'false' && '' || github.token`
# hands out the job token on every run, because its falsy middle always
# falls through to the `||`.
#
# Run from the repo root:
#   bash selftest/test_claude_review_ran_check.sh
set -euo pipefail

WF=.github/workflows/claude-review.yml
CALLER_STEP="Caller check (review with the job token when this PR changes its calling workflow)"
RAN_STEP="Review-ran check (claude-code-action can exit 0 without reviewing)"
GUARD_STEP="Lost-findings guard (summary claim vs inline comments posted)"
CALLER_FILE=".github/workflows/pr-review.yml"
MARKER="<!-- claude-review:not-reviewed -->"

failed=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/calls" "$T/runner_temp"

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
# 1. Wiring, with the expressions evaluated
# ---------------------------------------------------------------------------
echo "== claude-review.yml: caller check and review-ran check wiring, expressions evaluated =="

python3 - "$WF" "$T/expr.env" <<'PY' || failed=1
import math, re, sys, yaml

path, env_out = sys.argv[1], sys.argv[2]
with open(path) as fh:
    doc = yaml.safe_load(fh)
job = doc["jobs"]["review"]
steps = job["steps"]
by_id = {s.get("id"): s for s in steps if s.get("id")}
order = [s.get("id") or s.get("name") for s in steps]
problems = []

# ---- a GitHub expression evaluator for the subset these steps use ----------
# Literals ('...', true, false, null), dotted context paths, status
# functions, !, ==, !=, && and || and parentheses, with GitHub's semantics:
# && and || return an OPERAND, not a boolean; == and != compare two strings
# case-insensitively and coerce mismatched types to numbers; '', 0, NaN,
# false and null are falsy. An unset context value is null.
TOKEN = re.compile(r"\s*('(?:[^']|'')*'|==|!=|&&|\|\||!|\(|\)|[A-Za-z_][\w-]*(?:\.[\w-]+)*(?:\(\))?)")


def tokenize(text):
    tokens, pos, text = [], 0, text.strip()
    while pos < len(text):
        m = TOKEN.match(text, pos)
        if not m:
            raise ValueError(f"cannot tokenize {text[pos:]!r}")
        tokens.append(m.group(1))
        pos = m.end()
    return tokens


def number(v):
    if v is None:
        return 0.0
    if isinstance(v, bool):
        return 1.0 if v else 0.0
    if isinstance(v, (int, float)):
        return float(v)
    try:
        return float(v.strip()) if v.strip() else 0.0
    except ValueError:
        return math.nan


def truthy(v):
    if isinstance(v, bool):
        return v
    if v is None:
        return False
    if isinstance(v, (int, float)):
        return v != 0 and not math.isnan(v)
    return v != ""


def equal(a, b):
    if isinstance(a, str) and isinstance(b, str):
        return a.lower() == b.lower()
    return number(a) == number(b)  # NaN equals nothing


class Expr:
    def __init__(self, text, ctx, status):
        self.tokens, self.i, self.ctx, self.status = tokenize(text), 0, ctx, status

    def peek(self):
        return self.tokens[self.i] if self.i < len(self.tokens) else None

    def take(self):
        token = self.peek()
        self.i += 1
        return token

    def value(self):
        v = self.disjunction()
        if self.peek() is not None:
            raise ValueError(f"trailing tokens {self.tokens[self.i:]}")
        return v

    def disjunction(self):
        v = self.conjunction()
        while self.peek() == "||":
            self.take()
            right = self.conjunction()
            v = v if truthy(v) else right
        return v

    def conjunction(self):
        v = self.comparison()
        while self.peek() == "&&":
            self.take()
            right = self.comparison()
            v = right if truthy(v) else v
        return v

    def comparison(self):
        v = self.unary()
        while self.peek() in ("==", "!="):
            op = self.take()
            right = self.unary()
            v = equal(v, right) if op == "==" else not equal(v, right)
        return v

    def unary(self):
        if self.peek() == "!":
            self.take()
            return not truthy(self.unary())
        return self.primary()

    def primary(self):
        token = self.take()
        if token is None:
            raise ValueError("unexpected end of expression")
        if token == "(":
            v = self.disjunction()
            if self.take() != ")":
                raise ValueError("unbalanced parentheses")
            return v
        if token.startswith("'"):
            return token[1:-1].replace("''", "'")
        if token in ("true", "false"):
            return token == "true"
        if token == "null":
            return None
        if token.endswith("()"):
            return self.status[token[:-2]]
        return self.ctx.get(token)


def text_of(v):
    if v is None:
        return ""
    if isinstance(v, bool):
        return "true" if v else "false"
    return str(v)


def field(value, ctx, status):
    """A `with:`/`env:` value: every ${{ }} evaluated into the text around it."""
    return re.sub(
        r"\$\{\{(.*?)\}\}",
        lambda m: text_of(Expr(m.group(1), ctx, status).value()),
        str(value),
    )


def runs(step, ctx, status):
    """A step's `if:`; without a status function GitHub prepends success() &&."""
    cond = str(step.get("if", "")).strip()
    m = re.fullmatch(r"\$\{\{(.*)\}\}", cond, re.S)
    if m:
        cond = m.group(1).strip()
    if not cond:
        cond = "success()"
    elif not re.search(r"\b(success|failure|cancelled|always)\(\)", cond):
        cond = f"success() && ({cond})"
    return truthy(Expr(cond, ctx, status).value())


OK = {"success": True, "failure": False, "cancelled": False, "always": True}
FAILED = {"success": False, "failure": True, "cancelled": False, "always": True}
CANCELLED = {"success": False, "failure": False, "cancelled": True, "always": True}

# The evaluator's own controls: the semantics everything below leans on.
for text, want in (
    ("'a' && '' || 'c'", "c"),  # a falsy middle falls through to the ||
    ("'' != 'false'", True),
    ("null != 'false'", True),  # null vs a string: 0 vs NaN, never equal
    ("'FALSE' != 'false'", False),  # strings compare case-insensitively
    ("!cancelled() && ('x' == 'x')", True),
):
    got = Expr(text, {}, OK).value()
    if got != want:
        problems.append(f"evaluator control {text!r} gave {got!r}, want {want!r}")

# ---- static wiring -----------------------------------------------------------
caller, review, ran = by_id.get("caller"), by_id.get("claude"), by_id.get("ran")
summary, guard = by_id.get("summary"), by_id.get("guard")
if None in (caller, review, ran, summary, guard):
    problems.append(f"missing step id(s): need caller, claude, ran, summary, guard; have {order}")
else:
    checkout = next(
        (i for i, s in enumerate(steps) if str(s.get("uses", "")).startswith("actions/checkout@")), -1
    )
    at = [order.index(k) for k in ("caller", "claude", "ran", "summary", "guard")]
    if not (0 <= checkout < at[0] < at[1] < at[2] < at[3] < at[4]):
        problems.append(f"step order must be checkout < caller < claude < ran < summary < guard, got {order}")
    if caller.get("continue-on-error") is not True:
        problems.append(
            "the caller check lacks `continue-on-error: true`: a crash there would skip the "
            "review instead of reviewing with the job token"
        )
    if "continue-on-error" in ran:
        problems.append("the review-ran check carries continue-on-error: its exit 1 IS the verdict")
    want = {
        "GH_TOKEN": "${{ github.token }}",
        "REPO": "${{ github.repository }}",
        "CALLER_REF": "${{ github.workflow_ref }}",
        "DEFAULT_BRANCH": "${{ github.event.repository.default_branch }}",
    }
    if (caller.get("env") or {}) != want:
        problems.append(f"caller check env is {caller.get('env')!r}, want {want!r}")
    want = {
        "GH_TOKEN": "${{ github.token }}",
        "REPO": "${{ github.repository }}",
        "PR": "${{ github.event.pull_request.number }}",
        "CONCLUSION": "${{ steps.claude.outputs.conclusion }}",
        "CALLER_CHANGED": "${{ steps.caller.outputs.changed }}",
        "CALLER_CAUSE": "${{ steps.caller.outputs.cause }}",
        "CALLER_PATH": "${{ steps.caller.outputs.path }}",
        "RUN_URL": "${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}",
    }
    if (ran.get("env") or {}) != want:
        problems.append(f"review-ran check env is {ran.get('env')!r}, want {want!r}")
    for step in (caller, ran):
        if "${{" in str(step.get("run", "")):
            problems.append(f"step {step.get('id')!r}: the runner would substitute an expression into its script")
    # The job token the review may now run with holds exactly these.
    perms = job.get("permissions")
    if perms != {"contents": "read", "pull-requests": "write", "id-token": "write"}:
        problems.append(f"job permissions are {perms!r}; widening them widens the token caller-PR reviews run with")

    # ---- the token and the identity, evaluated -------------------------------
    JOB_TOKEN = "ghs_job_token_stub"
    token_expr = (review.get("with") or {}).get("github_token")
    bot_expr = (guard.get("env") or {}).get("REVIEW_BOT")
    if token_expr is None or bot_expr is None:
        problems.append("the review step has no `github_token` input, or the guard no REVIEW_BOT")
    else:
        bots = {}
        # changed as the caller check writes it, empty, and unset: a step
        # that died before writing its outputs leaves it unset.
        for changed, want_token, want_bot in (
            ("true", JOB_TOKEN, "github-actions[bot]"),
            ("false", "", "claude[bot]"),
            ("", JOB_TOKEN, "github-actions[bot]"),
            (None, JOB_TOKEN, "github-actions[bot]"),
        ):
            ctx = {"steps.caller.outputs.changed": changed, "github.token": JOB_TOKEN}
            got = (field(token_expr, ctx, OK), field(bot_expr, ctx, OK))
            if got != (want_token, want_bot):
                problems.append(
                    f"changed={changed!r}: github_token={got[0]!r} REVIEW_BOT={got[1]!r}, "
                    f"want {want_token!r} / {want_bot!r}"
                )
            bots[changed] = got[1]
        # The trap the evaluator is here for: `&& '' ||` hands out the job
        # token even on a proven match. If this stops holding, the evaluator
        # has lost the semantics the checks above rely on.
        trap = "${{ steps.caller.outputs.changed == 'false' && '' || github.token }}"
        ctx = {"steps.caller.outputs.changed": "false", "github.token": JOB_TOKEN}
        if field(trap, ctx, OK) != JOB_TOKEN:
            problems.append("evaluator control: the `&& '' ||` mutant must yield the job token on a matching caller")
        with open(env_out, "w") as fh:
            fh.write(f"REVIEW_BOT_CHANGED={bots['true']}\nREVIEW_BOT_SAME={bots['false']}\n")

    # ---- which steps run ------------------------------------------------------
    # bot_check's output is unset outside a bot-authored PR.
    for name, ctx, status, want in (
        (
            "bot-skip path (every commit bot-authored)",
            {"steps.bot_check.outputs.skipped": "true", "steps.claude.outcome": "skipped"},
            OK,
            {"caller": False, "claude": False, "ran": False, "summary": False, "guard": False},
        ),
        (
            "ordinary PR, review step succeeded",
            {"steps.claude.outcome": "success"},
            OK,
            {"caller": True, "claude": True, "ran": True, "summary": True, "guard": True},
        ),
        (
            "bot-opened PR with a human commit, review step succeeded",
            {"steps.bot_check.outputs.skipped": "", "steps.claude.outcome": "success"},
            OK,
            {"caller": True, "claude": True, "ran": True},
        ),
        (
            "review step failed: the action's own verdict stands",
            {"steps.claude.outcome": "failure"},
            FAILED,
            {"ran": False, "summary": True, "guard": True},
        ),
        ("run cancelled", {"steps.claude.outcome": "success"}, CANCELLED, {"ran": False}),
    ):
        for key, expected in want.items():
            got = runs(by_id[key], ctx, status)
            if got != expected:
                problems.append(f"{name}: step {key!r} runs={got}, want {expected}")

for p in problems:
    print(f"✗ {p}")
sys.exit(1 if problems else 0)
PY
[ "$failed" -eq 0 ] && pass "checkout < caller < claude < ran < summary < guard; caller continue-on-error, env exact, permissions unchanged; github_token and REVIEW_BOT evaluated for changed=true/false/empty/unset; bot-skip, failed-review and cancelled paths never run the review-ran check"

# ---------------------------------------------------------------------------
# 2. The shipped bash, extracted
# ---------------------------------------------------------------------------
extract_run "$WF" "$CALLER_STEP" "$T/caller.sh" || { echo "FAILED"; exit 1; }
extract_run "$WF" "$RAN_STEP" "$T/ran.sh" || { echo "FAILED"; exit 1; }
extract_run "$WF" "$GUARD_STEP" "$T/guard.sh" || { echo "FAILED"; exit 1; }
for f in caller ran; do
  /bin/bash -n "$T/$f.sh" || fail "the $f step does not parse under /bin/bash (macOS 3.2 / runner 5)"
done

# One stub for every step here. Reads serve fixtures, writes are captured
# (never sent), anything else fails loudly. Each call is logged, with a note
# of whether the decision (reviewed=false) was already in GITHUB_OUTPUT.
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
echo "gh $*" >> "$GH_LOG"
if [ -n "${GITHUB_OUTPUT:-}" ] && grep -qx 'reviewed=false' "$GITHUB_OUTPUT" 2>/dev/null; then
  echo decided >> "$GH_LOG.decision"
else
  echo undecided >> "$GH_LOG.decision"
fi
capture() {  # capture NAME FILE: keep what a write would have sent
  local n
  n=$(find "$GH_CALLS" -type f | wc -l | tr -d ' ')
  cp "$2" "$GH_CALLS/$n.$1"
}
arg_after() {  # arg_after FLAG ARGS...: the argument that follows FLAG
  local flag="$1" prev=""
  shift
  for a in "$@"; do
    if [ "$prev" = "$flag" ]; then printf '%s' "$a"; return 0; fi
    prev=$a
  done
}
case "$*" in
  "api -X GET repos/o/r/contents/"*)
    case "${GH_CONTENTS:-}" in
      file:*) printf '{"type":"file","name":"pr-review.yml","sha":"%s"}\n' "${GH_CONTENTS#file:}" ;;
      dir) echo '[{"type":"file","name":"pr-review.yml","sha":"0123456789abcdef0123456789abcdef01234567"}]' ;;
      # The two 404 shapes the real API returns, body on stdout as gh prints it.
      notfound)
        echo '{"message":"Not Found","documentation_url":"https://docs.github.com/rest/repos/contents#get-repository-content","status":"404"}'
        echo "gh: Not Found (HTTP 404)" >&2
        exit 1 ;;
      noref)
        echo '{"message":"No commit found for the ref main","documentation_url":"https://docs.github.com/v3/repos/contents/","status":"404"}'
        echo "gh: No commit found for the ref main (HTTP 404)" >&2
        exit 1 ;;
      down)
        echo '{"message":"Server Error"}'
        echo "gh: Server Error (HTTP 502)" >&2
        exit 1 ;;
      *) echo "STUB: no GH_CONTENTS fixture" >&2; exit 98 ;;
    esac
    ;;
  "api repos/o/r/issues/7/comments?per_page=100 --paginate")
    if [ "${GH_LIST_FAIL:-0}" = 1 ]; then
      echo '{"message":"Server Error"}'
      echo "gh: Server Error (HTTP 502)" >&2
      exit 1
    fi
    cat "$GH_ISSUE_COMMENTS"
    ;;
  "api -X PATCH repos/o/r/issues/comments/"*)
    file=$(arg_after -F "$@")
    capture "patch.${4##*/}" "${file#body=@}"
    if [ "${GH_PATCH_FAIL:-0}" = 1 ]; then echo "gh: Server Error (HTTP 502)" >&2; exit 1; fi
    echo '{"id":1}'
    ;;
  "pr comment 7 -R o/r --body-file "*)
    capture post "$(arg_after --body-file "$@")"
    if [ "${GH_POST_FAIL:-0}" = 1 ]; then
      echo "HTTP 503: No server is currently available to service your request" >&2
      exit 1
    fi
    echo "https://github.com/o/r/pull/7#issuecomment-1"
    ;;
  "api repos/o/r/pulls/7/comments?per_page=100 --paginate")
    cat "$GH_PULLS_JSON"
    ;;
  *) echo "STUB: unexpected 'gh $*'" >&2; exit 99 ;;
esac
STUB
chmod +x "$T/bin/gh"

# Retry cadences run through this stub: logged, never slept.
cat > "$T/bin/sleep" <<'STUB'
#!/usr/bin/env bash
echo "sleep $*" >> "${GH_LOG:-/dev/null}"
STUB
chmod +x "$T/bin/sleep"

reset_calls() {
  : > "$T/gh.log"
  : > "$T/gh.log.decision"
  rm -rf "$T/calls"
  mkdir -p "$T/calls"
}
posts() { find "$T/calls" -type f -name '*.post' | wc -l | tr -d ' '; }
patches() { find "$T/calls" -type f -name '*.patch.*' | wc -l | tr -d ' '; }
calls_to() { grep -cF -- "$1" "$T/gh.log" || true; }

# ---------------------------------------------------------------------------
# 3. Caller check: a real checkout, the contents API stubbed
# ---------------------------------------------------------------------------
echo
echo "== caller check: shipped bash against a git checkout and a stubbed gh =="

git_q() { git -c core.hooksPath=/dev/null -c commit.gpgsign=false -c user.name=selftest -c user.email=selftest@example.test "$@"; }
CHECKOUT="$T/checkout"
git_q init -q "$CHECKOUT"
mkdir -p "$CHECKOUT/.github/workflows"
printf 'name: PR Review\n# the PR copy\n' > "$CHECKOUT/$CALLER_FILE"
git_q -C "$CHECKOUT" add -A
git_q -C "$CHECKOUT" commit -qm base
echo "x" > "$CHECKOUT/README.md"
git_q -C "$CHECKOUT" add -A
git_q -C "$CHECKOUT" commit -qm head
HEAD_BLOB=$(git -C "$CHECKOUT" rev-parse "HEAD:$CALLER_FILE")
OTHER_BLOB=$(printf 'name: PR Review\n# the default branch copy\n' | git hash-object --stdin)
SHALLOW="$T/shallow"
git_q clone -q --depth 1 "file://$CHECKOUT" "$SHALLOW"
[ "$(git -C "$SHALLOW" rev-parse --is-shallow-repository)" = true ] || fail "fixture: the depth-1 clone is not shallow"
NOCALLER="$T/nocaller"
git_q init -q "$NOCALLER"
echo "x" > "$NOCALLER/README.md"
git_q -C "$NOCALLER" add -A
git_q -C "$NOCALLER" commit -qm head
CONTENTS_CALL="gh api -X GET repos/o/r/contents/$CALLER_FILE -f ref=main"

# run_caller NAME WORKSPACE [CALLER_REF] [DEFAULT_BRANCH]: GH_CONTENTS holds
# the contents API's answer. Sets RC and C_CHANGED / C_CAUSE / C_PATH from
# the step's GITHUB_OUTPUT, the last value per key, as the runner keeps it.
run_caller() {
  local name="$1" ws="$2" ref="${3-o/r/$CALLER_FILE@refs/pull/7/merge}" branch="${4-main}"
  local out="$T/caller.$name.out"
  reset_calls
  : > "$out"
  set +e
  (cd "$ws" && GH_LOG="$T/gh.log" GH_CALLS="$T/calls" PATH="$T/bin:$PATH" GH_TOKEN=stub \
     REPO=o/r CALLER_REF="$ref" DEFAULT_BRANCH="$branch" GH_CONTENTS="${GH_CONTENTS:-}" \
     GITHUB_WORKSPACE="$ws" RUNNER_TEMP="$T/runner_temp" GITHUB_OUTPUT="$out" \
     /bin/bash -e -o pipefail "$T/caller.sh") > "$T/caller.$name.txt" 2>&1
  RC=$?
  set -e
  C_CHANGED=$(sed -n 's/^changed=//p' "$out" | tail -1)
  C_CAUSE=$(sed -n 's/^cause=//p' "$out" | tail -1)
  C_PATH=$(sed -n 's/^path=//p' "$out" | tail -1)
}
show_caller() {
  fail "$1 (rc=$RC changed=$C_CHANGED cause=$C_CAUSE path=$C_PATH):"
  sed 's/^/    /' "$T/caller.$2.txt"
  sed 's/^/    gh: /' "$T/gh.log"
}

GH_CONTENTS="file:$OTHER_BLOB" run_caller c1 "$CHECKOUT"
if [ "$RC" -eq 0 ] && [ "$C_CHANGED" = true ] && [ "$C_CAUSE" = edit ] && [ "$C_PATH" = "$CALLER_FILE" ] \
   && [ "$(cat "$T/gh.log")" = "$CONTENTS_CALL" ] \
   && grep -qF "::notice::caller check: cause=edit ($CALLER_FILE) - reviewing with the job token" "$T/caller.c1.txt"; then
  pass "C1 caller differs from the default branch's copy: changed=true cause=edit, one contents read at ref=main, a notice names the job token"
else
  show_caller "C1" c1
fi

GH_CONTENTS=notfound run_caller c2 "$CHECKOUT"
if [ "$RC" -eq 0 ] && [ "$C_CHANGED" = true ] && [ "$C_CAUSE" = install ] && [ "$C_PATH" = "$CALLER_FILE" ] \
   && grep -qF "::notice::caller check: cause=install" "$T/caller.c2.txt"; then
  pass "C2 caller absent on the default branch (404 Not Found): changed=true cause=install (an install PR)"
else
  show_caller "C2" c2
fi

# The positive control: the one outcome that keeps the App token. Without it
# every changed=true above could be a check that never says false.
GH_CONTENTS="file:$HEAD_BLOB" run_caller c3 "$CHECKOUT"
if [ "$RC" -eq 0 ] && [ "$C_CHANGED" = false ] && [ "$C_CAUSE" = same ] \
   && grep -qF "matches the default branch's copy - reviewing with the Claude App token" "$T/caller.c3.txt" \
   && ! grep -qF "::notice::" "$T/caller.c3.txt"; then
  pass "C3 caller matches the default branch's copy: changed=false cause=same, App token kept, no notice"
else
  show_caller "C3" c3
fi

GH_CONTENTS="file:$HEAD_BLOB" run_caller c3b "$SHALLOW"
if [ "$RC" -eq 0 ] && [ "$C_CHANGED" = false ] && [ "$C_CAUSE" = same ]; then
  pass "C3b same answer from a depth-1 checkout: HEAD's blob needs no history"
else
  show_caller "C3b" c3b
fi

for shape in down noref dir "file:not-a-sha"; do
  GH_CONTENTS="$shape" run_caller c4 "$CHECKOUT"
  if [ "$RC" -eq 0 ] && [ "$C_CHANGED" = true ] && [ "$C_CAUSE" = unknown ] && [ "$C_PATH" = "$CALLER_FILE" ]; then
    pass "C4 contents read '$shape' (fail safe): changed=true cause=unknown, the step itself exits 0"
  else
    show_caller "C4 contents read '$shape'" c4
  fi
done

GH_CONTENTS="file:$HEAD_BLOB" run_caller c5 "$NOCALLER"
if [ "$RC" -eq 0 ] && [ "$C_CHANGED" = true ] && [ "$C_CAUSE" = unknown ] && [ ! -s "$T/gh.log" ]; then
  pass "C5 caller missing at HEAD: changed=true cause=unknown, and no API read without a HEAD blob"
else
  show_caller "C5" c5
fi

# Refs that do not reduce to one plain workflow file, a newline that would
# forge a `changed=false` output line among them, are never read.
for ref in "" \
           "o/r/.github/workflows/sub/pr-review.yml@refs/pull/7/merge" \
           "o/r/src/pr-review.yml@refs/pull/7/merge" \
           "o/r/$CALLER_FILE@refs/heads/a@b" \
           $'o/r/.github/workflows/pr-review.yml\nchanged=false@refs/pull/7/merge'; do
  GH_CONTENTS="file:$HEAD_BLOB" run_caller c6 "$CHECKOUT" "$ref"
  if [ "$RC" -eq 0 ] && [ "$C_CHANGED" = true ] && [ "$C_CAUSE" = unknown ] && [ -z "$C_PATH" ] \
     && [ ! -s "$T/gh.log" ] && ! grep -qx 'changed=false' "$T/caller.c6.out"; then
    pass "C6 workflow_ref $(printf '%q' "$ref"): unread, changed=true cause=unknown, no forged output"
  else
    show_caller "C6 workflow_ref $(printf '%q' "$ref")" c6
  fi
done

GH_CONTENTS="file:$HEAD_BLOB" run_caller c7 "$CHECKOUT" "o/r/$CALLER_FILE@refs/pull/7/merge" ""
if [ "$RC" -eq 0 ] && [ "$C_CHANGED" = true ] && [ "$C_CAUSE" = unknown ] && [ ! -s "$T/gh.log" ]; then
  pass "C7 no default branch in the event: changed=true cause=unknown, nothing read"
else
  show_caller "C7" c7
fi

# ---------------------------------------------------------------------------
# 4. Review-ran check
# ---------------------------------------------------------------------------
echo
echo "== review-ran check: shipped bash against a stubbed gh =="

# run_ran NAME: CONCLUSION, CALLER_CHANGED, CALLER_CAUSE, CALLER_PATH_IN,
# RUN_URL_IN and the GH_* switches come from the environment. Sets RC,
# REVIEWED (the last value written) and BODY (the last write's body file).
run_ran() {
  local name="$1" script="${RAN_SH:-$T/ran.sh}" written
  reset_calls
  : > "$T/ran.$name.out"
  set +e
  GH_LOG="$T/gh.log" GH_CALLS="$T/calls" PATH="$T/bin:$PATH" GH_TOKEN=stub \
    REPO=o/r PR=7 CONCLUSION="${CONCLUSION-}" \
    CALLER_CHANGED="${CALLER_CHANGED-}" CALLER_CAUSE="${CALLER_CAUSE-}" CALLER_PATH="${CALLER_PATH_IN-}" \
    RUN_URL="${RUN_URL_IN-https://github.example/o/r/actions/runs/42}" \
    RUNNER_TEMP="$T/runner_temp" GITHUB_OUTPUT="$T/ran.$name.out" \
    GH_ISSUE_COMMENTS="${GH_ISSUE_COMMENTS:-$T/none.json}" GH_LIST_FAIL="${GH_LIST_FAIL:-0}" \
    GH_POST_FAIL="${GH_POST_FAIL:-0}" GH_PATCH_FAIL="${GH_PATCH_FAIL:-0}" \
    /bin/bash -e -o pipefail "$script" > "$T/ran.$name.txt" 2>&1
  RC=$?
  set -e
  REVIEWED=$(sed -n 's/^reviewed=//p' "$T/ran.$name.out" | tail -1)
  written=$(find "$T/calls" -type f | sed 's|.*/||' | sort -n | tail -1)
  BODY="$T/calls/${written:-none}"
}
show_ran() {
  fail "$1 (rc=$RC reviewed=$REVIEWED posts=$(posts) patches=$(patches)):"
  sed 's/^/    /' "$T/ran.$2.txt"
  sed 's/^/    gh: /' "$T/gh.log"
  [ -f "$BODY" ] && sed 's/^/    | /' "$BODY"
  return 0
}
echo '[]' > "$T/none.json"
# shellcheck disable=SC2016  # the comment's own markdown, matched literally
HEADING='### ⚠️ Not reviewed: `review / Claude Review` did not review this PR'
JOB_TOKEN_EDIT="This PR changes its calling workflow \`$CALLER_FILE\`. The action's App-token exchange refuses such a PR (workflow validation), so this run gave the action the job token instead."

for c in success failure; do
  CONCLUSION="$c" CALLER_CHANGED=true CALLER_CAUSE=edit CALLER_PATH_IN="$CALLER_FILE" run_ran r1
  if [ "$RC" -eq 0 ] && [ "$REVIEWED" = true ] && [ ! -s "$T/gh.log" ]; then
    pass "R1 reviewed run (conclusion=$c): reviewed=true, exit 0, no API call"
  else
    show_ran "R1 conclusion=$c" r1
  fi
done

# R2: the gap itself, on a caller edit the job token did not cure.
CONCLUSION="" CALLER_CHANGED=true CALLER_CAUSE=edit CALLER_PATH_IN="$CALLER_FILE" run_ran r2
if [ "$RC" -eq 1 ] && [ "$REVIEWED" = false ] && [ "$(posts)" -eq 1 ] && [ "$(patches)" -eq 0 ] \
   && [ "$(head -1 "$BODY")" = "$MARKER" ] \
   && grep -qF -- "$HEADING" "$BODY" \
   && grep -qF -- "$JOB_TOKEN_EDIT" "$BODY" \
   && grep -qF "No file in this PR was reviewed." "$BODY" \
   && grep -qF "[workflow run](https://github.example/o/r/actions/runs/42)" "$BODY" \
   && grep -q "^::error::claude-code-action exited without reviewing PR #7 (step success, conclusion ''; caller changed, job token used)" "$T/ran.r2.txt" \
   && ! grep -qx undecided "$T/gh.log.decision"; then
  pass "R2 skip, caller changed: reviewed=false recorded before any API call, ONE sticky posted (marker first), ::error::, exit 1"
else
  show_ran "R2" r2
fi

CONCLUSION="" CALLER_CHANGED=true CALLER_CAUSE=install CALLER_PATH_IN="$CALLER_FILE" run_ran r3
if [ "$RC" -eq 1 ] && [ "$REVIEWED" = false ] && [ "$(posts)" -eq 1 ] \
   && grep -qF "This PR adds its calling workflow \`$CALLER_FILE\`. The action's App-token exchange refuses such a PR (workflow validation)" "$BODY" \
   && grep -qF "caller added, job token used" "$T/ran.r3.txt"; then
  pass "R3 skip, caller absent on the default branch (install PR): says the PR adds it, exit 1"
else
  show_ran "R3" r3
fi

CONCLUSION="" CALLER_CHANGED=false CALLER_CAUSE=same CALLER_PATH_IN="$CALLER_FILE" run_ran r4
if [ "$RC" -eq 1 ] && [ "$REVIEWED" = false ] && [ "$(posts)" -eq 1 ] \
   && grep -qF "This PR's calling workflow \`$CALLER_FILE\` matches the default branch's copy, so this run asked for the Claude App token as usual: this is not the action's workflow-validation skip." "$BODY" \
   && grep -qF "why is not known: see the run log" "$BODY" \
   && ! grep -qF "job token" "$BODY"; then
  pass "R4 skip, caller unchanged: cause unknown, not the validation skip, exit 1"
else
  show_ran "R4" r4
fi

for state in "true|unknown|$CALLER_FILE" "||"; do
  IFS='|' read -r ch ca pa <<<"$state"
  CONCLUSION="" CALLER_CHANGED="$ch" CALLER_CAUSE="$ca" CALLER_PATH_IN="$pa" run_ran r4b
  if [ "$RC" -eq 1 ] && [ "$REVIEWED" = false ] && [ "$(posts)" -eq 1 ] \
     && grep -qF "This run could not compare its calling workflow" "$BODY" \
     && grep -qF "so it gave the action the job token as a precaution." "$BODY"; then
    pass "R4b skip, caller check '${state}': says the comparison failed and the job token was used, exit 1"
  else
    show_ran "R4b caller check '${state}'" r4b
  fi
done

# R5: the comments API is down. The verdict stands; the body reaches the log
# with the runner's workflow-command prefixes broken, whatever it holds.
HOSTILE_URL=$'https://github.example/o/r/actions/runs/42\n::error::injected by a hostile line\r::warning::injected behind a carriage return ##[set-output name=reviewed;]true'
CONCLUSION="" CALLER_CHANGED=true CALLER_CAUSE=edit CALLER_PATH_IN="$CALLER_FILE" \
  GH_POST_FAIL=1 RUN_URL_IN="$HOSTILE_URL" run_ran r5
if [ "$RC" -eq 1 ] && [ "$REVIEWED" = false ] && [ "$(posts)" -eq 3 ] && [ "$(patches)" -eq 0 ] \
   && [ "$(calls_to "issues/7/comments")" -eq 3 ] \
   && [ "$(grep -c '^sleep' "$T/gh.log")" -eq 2 ] && grep -qx 'sleep 5' "$T/gh.log" && grep -qx 'sleep 10' "$T/gh.log" \
   && grep -qF "::warning::could not post the not-reviewed comment on PR #7 after 3 attempts" "$T/ran.r5.txt" \
   && grep -qxF "    | $MARKER" "$T/ran.r5.txt" \
   && grep -qF "    | ::error::injected by a hostile line" "$T/ran.r5.txt" \
   && ! grep -qE '^[[:space:]]*::(error|warning)::injected' "$T/ran.r5.txt" \
   && ! grep -qF '##[' "$T/ran.r5.txt" \
   && grep -q '^::error::claude-code-action exited without reviewing PR #7' "$T/ran.r5.txt"; then
  pass "R5 comment post fails 3x (sleep 5, 10): warning, body logged with :: and ##[ broken, verdict stands (exit 1)"
else
  show_ran "R5" r5
fi

# A caller path that is not a plain workflow file never reaches the comment.
CONCLUSION="" CALLER_CHANGED=true CALLER_CAUSE=edit \
  CALLER_PATH_IN=$'.github/workflows/pr-review.yml\n::error::evil' run_ran r5b
if [ "$RC" -eq 1 ] && [ "$(posts)" -eq 1 ] \
   && grep -qF "This PR changes its calling workflow. The action's" "$BODY" \
   && ! grep -qF evil "$BODY" && ! grep -qF evil "$T/ran.r5b.txt"; then
  pass "R5b a malformed caller path is dropped: the comment names no path, nothing of it reaches the log"
else
  show_ran "R5b" r5b
fi

# R6: a second run PATCHes its own sticky and posts nothing new.
jq -nc --arg m "$MARKER" '[
  {id: 101, user: {login: "github-actions[bot]"}, body: "No issues found. Diff is small and contained.\n\n<sub>Claude Review</sub>"},
  {id: 555, user: {login: "github-actions[bot]"}, body: ($m + "\n### ⚠️ Not reviewed: an earlier run")}
]' > "$T/sticky.json"
CONCLUSION="" CALLER_CHANGED=true CALLER_CAUSE=edit CALLER_PATH_IN="$CALLER_FILE" \
  GH_ISSUE_COMMENTS="$T/sticky.json" run_ran r6
if [ "$RC" -eq 1 ] && [ "$REVIEWED" = false ] && [ "$(posts)" -eq 0 ] && [ "$(patches)" -eq 1 ] \
   && [ "${BODY##*.}" = 555 ] \
   && grep -qF "gh api -X PATCH repos/o/r/issues/comments/555 -F body=@" "$T/gh.log" \
   && [ "$(head -1 "$BODY")" = "$MARKER" ] && grep -qF -- "$JOB_TOKEN_EDIT" "$BODY"; then
  pass "R6 second run: PATCHes sticky 555 with the new body, posts no duplicate"
else
  show_ran "R6" r6
fi

# Only github-actions[bot]'s own marked comment is the sticky: a human quoting
# the marker, or another bot carrying it, is never edited.
jq -nc --arg m "$MARKER" '[
  {id: 111, user: {login: "a-maintainer"}, body: ("> " + $m + "\n> quoted from an earlier run")},
  {id: 112, user: {login: "claude[bot]"}, body: ($m + "\nnot this step'"'"'s comment")},
  {id: 113, user: null, body: $m}
]' > "$T/others.json"
CONCLUSION="" CALLER_CHANGED=true CALLER_CAUSE=edit CALLER_PATH_IN="$CALLER_FILE" \
  GH_ISSUE_COMMENTS="$T/others.json" run_ran r6b
if [ "$RC" -eq 1 ] && [ "$(posts)" -eq 1 ] && [ "$(patches)" -eq 0 ]; then
  pass "R6b the marker in a human's, another bot's or a deleted account's comment: never PATCHed, a new sticky is posted"
else
  show_ran "R6b" r6b
fi

# --paginate prints one array per page back to back; with two stickies the
# oldest is the one kept.
{
  jq -nc '[{id: 101, user: {login: "github-actions[bot]"}, body: "No issues found."}]'
  jq -nc --arg m "$MARKER" '[{id: 555, user: {login: "github-actions[bot]"}, body: ($m + "\nolder")},
                             {id: 556, user: {login: "github-actions[bot]"}, body: ($m + "\nnewer")}]'
} > "$T/paged.json"
CONCLUSION="" CALLER_CHANGED=true CALLER_CAUSE=edit CALLER_PATH_IN="$CALLER_FILE" \
  GH_ISSUE_COMMENTS="$T/paged.json" run_ran r6c
if [ "$RC" -eq 1 ] && [ "$(posts)" -eq 0 ] && [ "$(patches)" -eq 1 ] && [ "${BODY##*.}" = 555 ]; then
  pass "R6c sticky on page 2 of --paginate output, two candidates: the oldest (555) is PATCHed, nothing posted"
else
  show_ran "R6c" r6c
fi

# R7: the comments cannot be listed. Posting blind could duplicate the sticky,
# so nothing is written; the verdict stands and the body goes to the log.
CONCLUSION="" CALLER_CHANGED=true CALLER_CAUSE=edit CALLER_PATH_IN="$CALLER_FILE" GH_LIST_FAIL=1 run_ran r7
if [ "$RC" -eq 1 ] && [ "$REVIEWED" = false ] && [ "$(posts)" -eq 0 ] && [ "$(patches)" -eq 0 ] \
   && [ "$(calls_to "issues/7/comments")" -eq 3 ] \
   && grep -qF "::warning::could not post the not-reviewed comment" "$T/ran.r7.txt" \
   && grep -qxF "    | $MARKER" "$T/ran.r7.txt"; then
  pass "R7 listing fails 3x: no blind post, warning, body in the log, exit 1"
else
  show_ran "R7" r7
fi

CONCLUSION="" CALLER_CHANGED=true CALLER_CAUSE=edit CALLER_PATH_IN="$CALLER_FILE" \
  GH_ISSUE_COMMENTS="$T/sticky.json" GH_PATCH_FAIL=1 run_ran r8
if [ "$RC" -eq 1 ] && [ "$(posts)" -eq 0 ] && [ "$(patches)" -eq 3 ] \
   && [ "$(find "$T/calls" -type f -name '*.patch.555' | wc -l | tr -d ' ')" -eq 3 ] \
   && grep -qF "::warning::could not post the not-reviewed comment" "$T/ran.r8.txt"; then
  pass "R8 PATCH fails 3x: retried on the same sticky, never a duplicate post, warning, exit 1"
else
  show_ran "R8" r8
fi

# CONTROL for R2's ordering assertion: the same step with its decision moved
# after the posting loop must be caught, or R2 proves nothing about it.
python3 - "$T/ran.sh" "$T/ran_late_decision.sh" <<'PY'
import sys
src, dst = sys.argv[1:]
text = open(src).read()
early = 'echo "reviewed=false" >> "$GITHUB_OUTPUT"\n'
anchor = 'shown=${CONCLUSION:-}\n'
if text.count(early) != 1 or text.count(anchor) != 1:
    sys.exit("control: anchors not found exactly once in the shipped step")
open(dst, "w").write(text.replace(early, "").replace(anchor, early + anchor))
PY
CONCLUSION="" CALLER_CHANGED=true CALLER_CAUSE=edit CALLER_PATH_IN="$CALLER_FILE" \
  RAN_SH="$T/ran_late_decision.sh" run_ran r2c
if [ "$RC" -eq 1 ] && [ "$REVIEWED" = false ] && grep -qx undecided "$T/gh.log.decision"; then
  pass "R2 CONTROL: a step that records reviewed=false only after posting is caught by the decision log"
else
  show_ran "R2 CONTROL no longer sees a late decision" r2c
fi

# ---------------------------------------------------------------------------
# 5. The lost-findings guard counts the identity the review posted as
# ---------------------------------------------------------------------------
echo
echo "== lost-findings guard: REVIEW_BOT follows the review's token =="

# The values section 1 evaluated from the shipped REVIEW_BOT expression.
REVIEW_BOT_CHANGED=$(sed -n 's/^REVIEW_BOT_CHANGED=//p' "$T/expr.env" 2>/dev/null || true)
REVIEW_BOT_SAME=$(sed -n 's/^REVIEW_BOT_SAME=//p' "$T/expr.env" 2>/dev/null || true)
jq -nc '[
  {type: "system", subtype: "init"},
  {type: "result", subtype: "success", is_error: false, num_turns: 6, total_cost_usd: 0.4,
   result: "Flagged 2 issues inline — see comments.", permission_denials: []}
]' > "$T/guard_x.json"
printf 'Flagged 2 issues inline — see comments.\n' > "$T/guard_summary.md"
# Two inline comments posted with the job token, after the anchor.
jq -nc '[range(2) | {id: (900 + .), user: {login: "github-actions[bot]"}, created_at: "2026-10-16T08:05:00Z",
                     path: "x.go", line: (3 + .), body: ("**Bug** #" + (. | tostring))}]' > "$T/guard_pulls.json"

run_guard() {  # run_guard NAME REVIEW_BOT
  local name="$1"
  reset_calls
  set +e
  GH_LOG="$T/gh.log" GH_CALLS="$T/calls" PATH="$T/bin:$PATH" GH_TOKEN=stub \
    REPO=o/r PR=7 STARTED_AT="2026-10-16T08:00:00Z" REVIEW_BOT="$2" \
    RUN_URL="https://github.example/o/r/actions/runs/42" GITHUB_RUN_ID=42 MAX_BUDGET_USD=3 \
    EXECUTION_FILE="$T/guard_x.json" SUMMARY_FILE="$T/guard_summary.md" GH_PULLS_JSON="$T/guard_pulls.json" \
    /bin/bash -e -o pipefail "$T/guard.sh" > "$T/guard.$name.txt" 2>&1
  RC=$?
  set -e
}

run_guard g1 "$REVIEW_BOT_CHANGED"
if [ "$REVIEW_BOT_CHANGED" = "github-actions[bot]" ] && [ "$RC" -eq 0 ] && [ "$(posts)" -eq 0 ] \
   && grep -qF "summary claims 2 inline finding(s); 2 inline review comment(s) by github-actions[bot]" "$T/guard.g1.txt"; then
  pass "G1 job-token review: REVIEW_BOT evaluates to github-actions[bot], its 2 inline comments count, exit 0"
else
  fail "G1 (REVIEW_BOT='$REVIEW_BOT_CHANGED' rc=$RC):"; sed 's/^/    /' "$T/guard.g1.txt"
fi
# CONTROL: the identity the guard used to hardcode reads the same PR as a
# loss and fails the job over findings that are on it.
run_guard g2 "$REVIEW_BOT_SAME"
if [ "$REVIEW_BOT_SAME" = "claude[bot]" ] && [ "$RC" -eq 1 ] && [ "$(posts)" -eq 1 ] \
   && grep -qF "summary claims 2 inline finding(s); 0 inline review comment(s) by claude[bot]" "$T/guard.g2.txt"; then
  pass "G2 CONTROL: with claude[bot] (the App-token value) the same job-token comments count 0 and the guard fails"
else
  fail "G2 CONTROL (REVIEW_BOT='$REVIEW_BOT_SAME' rc=$RC):"; sed 's/^/    /' "$T/guard.g2.txt"
fi

echo
if [ "$failed" -ne 0 ]; then
  echo "FAILED"
  exit 1
fi
echo "PASSED"
