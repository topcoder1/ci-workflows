#!/usr/bin/env bash
# Behavioral test: codex-review.yml's "Compute PR diff stats" step must FAIL
# CLOSED when a changed file's name, or a rename source, holds a control
# character: a C0 character (U+0000-U+001F, which takes in the line break and
# the tab) or DEL (U+007F).
#
# Why. The step writes the PR's paths one per line to the file codex-gate.mjs
# reads, and the gate splits that file on line breaks. Git allows a line break
# in a file name, and such a name is then read as two names, each judged
# alone. The halves can miss an always_review glob the whole name matches:
# `docs/customer/terms<LF>docs/guide.md` matches `docs/customer/**/*.md`,
# while its halves are plain docs paths. On a 100-line diff the gate then
# skips Codex as docs-only (should_run=false): the review the caller requires
# for that path never runs, and the job still concludes `success`. Found by
# the Codex pre-review of topcoder1/ci-workflows#312, which closed the same
# hole in the classifier and automerge workflows. The guard and its marker
# are #312's, so this test mirrors selftest/test_classify_control_char_paths.sh.
#
# The step's bash is EXTRACTED from the workflow and run against a stub `gh`
# that answers each files-API call by running the step's OWN --jq filter over
# a gh-shaped JSON response with real jq. The step's path-list file and line
# count then go to the REAL codex-gate.mjs, as the "Codex cost gate" step
# passes them. Pins:
#   1. A changed name holding a line break fails closed: a nonzero exit, an
#      ::error:: naming the control character, no `lines` output and no
#      path-list file, so the gate cannot run on a split list.
#   2. A rename SOURCE holding a tab fails closed the same way: every C0
#      character counts, and the rename listing is guarded too.
#   3. Both ends of the range: DEL in a changed name, U+001F in a rename
#      source.
#   4. A listing that fails still fails closed when a marker was already
#      printed: a marked changed-file listing followed by a failing rename
#      listing, and either listing failing after printing the marker (a later
#      page failing). With plain names too, either listing failing after a page
#      printed fails closed, so a list cut short never reaches the gate.
#   5. Controls: plain names with spaces, accents and an emoji, and one ending
#      in the marker's own text (the match is on whole lines), reach the gate
#      byte for byte, rename source included, and an always_review match among
#      them still runs Codex; a plain docs-only diff still skips.
#   6. Mutation controls: the step with the guard's test replaced by `false`
#      reproduces the escape (the line-break name skips Codex) and lets the tab
#      rename source through, so the verdicts of 1 and 2 come from the guard,
#      not from the harness.
#   7. Both files-API calls in the workflow end in the guard, however the
#      --jq is quoted. The count is hardcoded, and two negative controls (one
#      guard broken, one unguarded listing added) prove the check can fail.
#   8. The escape fixture's WHOLE name matches `docs/customer/**/*.md` and
#      neither half does, under codex-gate.mjs's own minimatch options.
#
# Run from the repo root:
#   bash selftest/test_codex_review_control_char_paths.sh
set -euo pipefail

WF=.github/workflows/codex-review.yml
GUARD='if (explode | any(. < 32 or . == 127)) then "/CONTROL-CHARACTER-IN-PATH" else . end'
NEEDLE='holds a control character'
ALWAYS='docs/customer/**/*.md'
failed=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# The gate reads the path list from a file in the runner's temp dir. Its name
# comes from the gate step, as in test_codex_review_rename_sources.sh, which
# pins the rest of that wiring. The plain-name control below reads the file
# back, so a wrong name fails there instead of letting the "no path-list file"
# checks pass by default.
handoff=$(awk '
  /^[[:space:]]*id: gate[[:space:]]*$/ { in_step = 1; next }
  in_step && /^      - name:/ { exit }
  in_step { print }
' "$WF" | sed -n 's/^[[:space:]]*CHANGED_FILES_FILE: \${{ runner\.temp }}\/\([A-Za-z0-9._-]*\)[[:space:]]*$/\1/p')
if [ -z "$handoff" ]; then
  echo "✗ could not find the cost gate's CHANGED_FILES_FILE under runner.temp in $WF — this test no longer models the hand-off"
  exit 1
fi

# The step's run block, de-indented: from its `run: |` to the next step.
awk '
  /^[[:space:]]*id: diff[[:space:]]*$/ { in_step = 1; next }
  in_step && /^[[:space:]]*run: \|[[:space:]]*$/ { grab = 1; next }
  grab && /^      - name:/ { exit }
  grab { print }
' "$WF" | sed -e 's/^          //' > "$T/step.sh"
if ! grep -q 'previous_filename' "$T/step.sh" || ! grep -q 'GITHUB_OUTPUT' "$T/step.sh"; then
  echo "✗ could not extract the diff step's run block from $WF"
  exit 1
fi
echo "✓ extracted the diff step ($(wc -l < "$T/step.sh" | tr -d ' ') lines)"

# Mutant: the guard's test replaced by `false`, so both listings print names as
# they come. It must differ from the shipped step, or the mutation controls
# below would pass against the unmutated step and prove nothing.
sed 's/explode | any(\. < 32 or \. == 127)/false/g' "$T/step.sh" > "$T/step-unguarded.sh"
if cmp -s "$T/step.sh" "$T/step-unguarded.sh"; then
  echo "✗ no guard to cut out of the diff step — its listings do not carry the control-character filter"
  failed=1
  mutant_ok=0
else
  mutant_ok=1
fi

# ---------------------------------------------------------------------------
# Fixtures. The caller requires a Codex read of customer docs; the line-break
# name is one whole, and its halves are plain docs paths.
# ---------------------------------------------------------------------------
mkdir -p "$T/repo/.github" "$T/scripts" "$T/bin" "$T/fx" "$T/rt"
cp .github/scripts/codex-gate.mjs .github/scripts/classifier-deps.mjs "$T/scripts/"
printf '%s\n' 'always_review:' "  - '$ALWAYS'" > "$T/repo/.github/risk-paths.yml"

printf '%s' '[{"filename":"docs/customer/terms\ndocs/guide.md","status":"added"}]' > "$T/fx/newline.json"
printf '%s' '[{"filename":"docs/guide.md","previous_filename":"docs/old\tguide.md","status":"renamed"}]' > "$T/fx/tab-rename.json"
printf '%s' '[{"filename":"docs/notes\u007f.md","status":"added"}]' > "$T/fx/del.json"
printf '%s' '[{"filename":"docs/guide.md","previous_filename":"docs/old\u001fguide.md","status":"renamed"}]' > "$T/fx/us-rename.json"
printf '%s' '[{"filename":"docs/customer/My Terms/résumé 🚀.md","status":"modified"},{"filename":"docs/x/CONTROL-CHARACTER-IN-PATH","status":"added"},{"filename":"docs/guide.md","previous_filename":"docs/old guide.md","status":"renamed"}]' > "$T/fx/plain-gated.json"
printf '%s' '[{"filename":"docs/My Notes/résumé.md","status":"modified"},{"filename":"docs/guide.md","previous_filename":"docs/old guide.md","status":"renamed"}]' > "$T/fx/plain.json"

# Under a plain `.filename` filter the line-break fixture prints two lines for
# one name: the fixture exercises the split, so a fail-closed verdict on it is
# about the split, not about a malformed fixture.
if [ "$(jq -r '.[].filename' "$T/fx/newline.json" | wc -l | tr -d ' ')" = 2 ]; then
  echo "✓ instrument: the line-break fixture reads as two names without the guard"
else
  echo "✗ instrument: the line-break fixture does not split under a plain filter — it tests nothing"
  failed=1
fi

# ---------------------------------------------------------------------------
# Stub `gh`. Serves the files API from $STUB_FILES_JSON through the caller's
# own --jq (one page of per_page, default 30, without --paginate; up to the
# API's 3000-entry cap with it), and `pr view` {additions, deletions} through
# the caller's --jq. STUB_FAIL makes a listing (the rename one told apart by
# its --jq text) fail like an API error: `rename` fails the rename listing
# with no output; `changed-partial` and `rename-partial` fail that listing
# after printing its answer, as gh does when a later page fails.
# ---------------------------------------------------------------------------
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
jq_filter() { while [ $# -gt 0 ]; do [ "$1" = "--jq" ] && { printf '%s' "$2"; return 0; }; shift; done; return 1; }
filter=$(jq_filter "$@") || { echo "gh-stub: call without --jq: $*" >&2; exit 64; }
url="${2:-}"
case "${1:-}:$url" in
  "api:repos/${GITHUB_REPOSITORY}/pulls/${PR}/files"*) ;;
  "pr:view")
    [ "${3:-}" = "$PR" ] || { echo "gh-stub: pr view of the wrong PR: $*" >&2; exit 64; }
    printf '{"additions":%s,"deletions":%s}\n' "$STUB_ADDITIONS" "$STUB_DELETIONS" | jq -r "$filter"
    exit 0
    ;;
  *) echo "gh-stub: unexpected call: $*" >&2; exit 64 ;;
esac
which=changed
case "$filter" in *previous_filename*) which=rename ;; esac
if [ "${STUB_FAIL:-}" = "$which" ]; then
  echo "gh: Internal Server Error (HTTP 500)" >&2
  exit 1
fi
limit=30
case "$url" in *per_page=*) limit="${url##*per_page=}"; limit="${limit%%&*}" ;; esac
case " $* " in *" --paginate "*) limit=3000 ;; esac
jq -r ".[:$limit] | $filter" "$STUB_FILES_JSON"
if [ "${STUB_FAIL:-}" = "$which-partial" ]; then
  echo "gh: Bad Gateway (HTTP 502)" >&2
  exit 1
fi
STUB
chmod +x "$T/bin/gh"

FAIL=""
# run_step <script> <fixture> — sets RC and LOG. A 100-line diff (60 + 40),
# over the gate's 30-line threshold, so only the always_review rule and the
# docs/tests-only skip decide. The step's outputs land in $T/ghout and its
# path list at $T/rt/$handoff. Passes FAIL to the stub as STUB_FAIL, then
# resets it.
run_step() {
  : > "$T/ghout"
  rm -f "$T/rt/$handoff"
  set +e
  LOG=$(cd "$T/repo" && PATH="$T/bin:$PATH" GH_TOKEN=stub PR=7 GITHUB_REPOSITORY=acme/fixture \
    GITHUB_OUTPUT="$T/ghout" RUNNER_TEMP="$T/rt" STUB_FILES_JSON="$T/fx/$2.json" \
    STUB_FAIL="$FAIL" STUB_ADDITIONS=60 STUB_DELETIONS=40 \
    bash "$1" 2>&1 < /dev/null)
  RC=$?
  set -e
  FAIL=""
}

report_bad() {
  echo "✗ $1 — $2. Output:"
  printf '%s\n' "$LOG" | sed 's/^/    /'
  failed=1
}

# expect_closed <desc> — the step's fail-closed shape, naming the control
# character: a nonzero exit, an ::error::, no outputs and no path-list file.
expect_closed() {
  if [ "$RC" -ne 0 ] && [ ! -s "$T/ghout" ] && [ ! -e "$T/rt/$handoff" ] \
    && grep -q "^::error::.*$NEEDLE" <<<"$LOG"; then
    echo "✓ $1"
  else
    report_bad "$1" "want a nonzero exit, an ::error:: with '$NEEDLE', no outputs and no path-list file; got rc=$RC, outputs '$(tr '\n' ' ' < "$T/ghout")'"
  fi
}

# expect_closed_any <desc> — fails closed for any reason: a nonzero exit, no
# outputs and no path-list file.
expect_closed_any() {
  if [ "$RC" -ne 0 ] && [ ! -s "$T/ghout" ] && [ ! -e "$T/rt/$handoff" ]; then
    echo "✓ $1"
  else
    report_bad "$1" "want a nonzero exit, no outputs and no path-list file; got rc=$RC, outputs '$(tr '\n' ' ' < "$T/ghout")'"
  fi
}

# expect_gate <desc> <want should_run> — the step succeeds without naming a
# control character, and the REAL gate, given the step's results as the gate
# step gives them, decides <want>. SIZE_THRESHOLD is what the workflow passes.
# GITHUB_STEP_SUMMARY is redirected so a run under Actions does not append to
# the real summary.
expect_gate() {
  local lines got gate_rc gate_log
  if [ "$RC" -ne 0 ] || grep -q "$NEEDLE" <<<"$LOG"; then
    report_bad "$1" "want the diff step to succeed; got rc=$RC"
    return
  fi
  lines=$(sed -n 's/^lines=//p' "$T/ghout")
  : > "$T/gateout"
  set +e
  gate_log=$(cd "$T/repo" && CHANGED_FILES_FILE="$T/rt/$handoff" DIFF_LINES="$lines" SIZE_THRESHOLD=30 \
    GITHUB_OUTPUT="$T/gateout" GITHUB_STEP_SUMMARY="$T/summary" \
    node "$T/scripts/codex-gate.mjs" 2>&1 < /dev/null)
  gate_rc=$?
  set -e
  got=$(sed -n 's/^should_run=//p' "$T/gateout")
  if [ "$gate_rc" -eq 0 ] && [ "$got" = "$2" ]; then
    echo "✓ $1"
  else
    LOG=$(printf '%s\n%s' "$LOG" "$gate_log")
    report_bad "$1" "want should_run=$2; got gate rc=$gate_rc, should_run='$got' (step, then gate)"
  fi
}

# 1-3. Fail closed.
run_step "$T/step.sh" newline;    expect_closed "a changed name holding a line break fails closed"
run_step "$T/step.sh" tab-rename; expect_closed "a rename source holding a tab fails closed"
run_step "$T/step.sh" del;        expect_closed "a changed name holding DEL fails closed"
run_step "$T/step.sh" us-rename;  expect_closed "a rename source holding U+001F fails closed"

# 4. Listings that fail after the marker was printed.
FAIL=rename;          run_step "$T/step.sh" newline
expect_closed_any "a marked changed-name listing still fails closed when the rename listing then fails"
FAIL=changed-partial; run_step "$T/step.sh" newline
expect_closed_any "a changed-name listing that fails after printing the marker still fails closed"
FAIL=rename-partial;  run_step "$T/step.sh" tab-rename
expect_closed_any "a rename listing that fails after printing the marker still fails closed"
# The same with plain names: a failed page must not leave the gate a list cut
# short. Both pass with the guard cut out; they pin the step's exits.
FAIL=changed-partial; run_step "$T/step.sh" plain
expect_closed_any "control: a changed-name listing that fails after printing plain names still fails closed"
FAIL=rename-partial;  run_step "$T/step.sh" plain
expect_closed_any "control: a rename listing that fails after printing plain names still fails closed"

# 5. Controls.
run_step "$T/step.sh" plain-gated
printf '%s\n' 'docs/customer/My Terms/résumé 🚀.md' 'docs/x/CONTROL-CHARACTER-IN-PATH' 'docs/guide.md' 'docs/old guide.md' > "$T/want-list"
if [ "$RC" -eq 0 ] && [ -e "$T/rt/$handoff" ] && cmp -s "$T/want-list" "$T/rt/$handoff"; then
  echo "✓ control: plain names with spaces, accents, an emoji and the marker's text reach the gate byte for byte, rename source included"
else
  report_bad "control: plain names reach the gate byte for byte" \
    "want rc=0 and $T/rt/$handoff equal to $(tr '\n' '|' < "$T/want-list"); got rc=$RC, list '$( [ -e "$T/rt/$handoff" ] && tr '\n' '|' < "$T/rt/$handoff")'"
fi
expect_gate "control: a plain always_review path among them still runs Codex" true
run_step "$T/step.sh" plain
expect_gate "control: a plain docs-only diff still skips" false

# 6. Mutation controls.
if [ "$mutant_ok" = 1 ]; then
  run_step "$T/step-unguarded.sh" newline
  expect_gate "control: unguarded, the line-break name is read as two docs paths and Codex is skipped (the escape)" false
  run_step "$T/step-unguarded.sh" tab-rename
  expect_gate "control: unguarded, the tab rename source is not failed closed" false
fi

# ---------------------------------------------------------------------------
# 7. Every files-API call ends in the guard. Comments are dropped, so prose
#    cannot satisfy it, and continuation lines are joined, so a call counts
#    wherever its --jq sits and however it is quoted.
# ---------------------------------------------------------------------------
logical_lines() {
  { grep -vE '^[[:space:]]*#' "$1" || true; } \
    | awk '{ if (sub(/\\[[:space:]]*$/, "")) { buf = buf $0; next } print buf $0; buf = "" }'
}
# check_listers <workflow file> <want> — 0 when exactly <want> files-API calls
# exist and every one ends in the guard.
check_listers() {
  local listers n guarded
  listers=$(logical_lines "$1" | grep -E 'pulls/[^[:space:]]*/files' || true)
  n=$(grep -c . <<<"$listers" || true)
  guarded=$(grep -cF -e "| $GUARD'" -e "| $GUARD\"" <<<"$listers" || true)
  LISTERS_SEEN="$n files-API call(s), $guarded ending in the guard"
  [ "$n" = "$2" ] && [ "$guarded" = "$2" ]
}
if check_listers "$WF" 2; then
  echo "✓ $WF: both files-API calls end in the control-character guard"
else
  echo "✗ $WF: want 2 files-API calls, each ending in the guard; found $LISTERS_SEEN"
  failed=1
fi
# Negative controls: one listing's guard broken, and one unguarded listing
# added with its --jq in double quotes, must each fail the check.
sed '/previous_filename/ s/explode/explod3/' "$WF" > "$T/wf-broken.yml"
{ cat "$WF"
  # shellcheck disable=SC2016,SC1003 # a literal workflow line, not an expansion or an escape
  printf '%s\n' '          extra=$(gh api "repos/o/r/pulls/1/files" \' '            --paginate --jq ".[].filename")'
} > "$T/wf-extra.yml"
for mutant in broken extra; do
  if cmp -s "$WF" "$T/wf-$mutant.yml"; then
    echo "✗ control: could not build the $mutant mutant of $WF — update this test"
    failed=1
  elif check_listers "$T/wf-$mutant.yml" 2; then
    echo "✗ control: the listing check passed on the $mutant mutant — it cannot fail that way"
    failed=1
  else
    echo "✓ control: the listing check fails on the $mutant mutant ($LISTERS_SEEN)"
  fi
done

# ---------------------------------------------------------------------------
# 8. The line-break name matches the always_review glob whole, and neither half
#    does, with codex-gate.mjs's options and the vendored minimatch it imports.
# ---------------------------------------------------------------------------
mm=$(node --input-type=module -e '
  const { minimatch } = await import(process.argv[1]);
  const o = { dot: true };
  console.log([
    "docs/customer/terms\ndocs/guide.md", "docs/customer/terms", "docs/guide.md",
  ].map((p) => minimatch(p, process.argv[2], o)).join(" "));
' "$PWD/.github/scripts/classifier-deps.mjs" "$ALWAYS")
if [ "$mm" = "true false false" ]; then
  echo "✓ the line-break name matches $ALWAYS whole, and neither half does"
else
  echo "✗ minimatch on the whole name and its halves: got '$mm', want 'true false false' — the escape fixture no longer escapes"
  failed=1
fi

echo ""
if [ "$failed" -ne 0 ]; then
  echo "FAIL: codex-review's diff step does not fail closed on a control character."
  exit 1
fi
echo "OK: codex-review's diff step fails closed on a control character."
