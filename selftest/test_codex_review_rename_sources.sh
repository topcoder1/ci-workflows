#!/usr/bin/env bash
# Behavioral test: codex-review.yml's "Compute PR diff stats" step must hand
# codex-gate.mjs a renamed file's OLD path as well as its new one.
#
# codex-gate.mjs runs Codex whenever a changed path matches the caller's
# always_review list, however small the diff. The files API lists a rename
# under its destination in `.filename`; the source path is only in
# `.previous_filename`. A step that passes `.filename` alone lets the gate
# judge a moved file by where it landed, never by where it came from.
#
# The step's bash is EXTRACTED from the workflow and executed against a stub
# `gh` that answers each call by running the step's OWN --jq filter over
# gh-shaped JSON, so a wrong filter or a missing --paginate changes the answer
# the way the real API would. The step's `files` and `lines` outputs are then
# handed to the REAL codex-gate.mjs, wired as the "Codex cost gate" step wires
# them. Every expected verdict is hardcoded. Pins:
#
#   1. A rename whose source matches always_review, with 5 changed lines,
#      runs Codex (the gate's small-diff skip would otherwise apply).
#   2. Negative control: a rename with neither end listed skips as a small
#      diff, so case 1 cannot pass by running Codex on every rename.
#   3. Mutation controls: the same step with its rename read cut out, and with
#      --paginate dropped from it, skip on cases 1 and 7. The RUN verdicts
#      come from the rename read, not from the harness.
#   4. The docs/tests-only skip sees the appended sources: a docs-to-docs
#      rename still skips, and a rename from code into docs/ runs, because
#      its source is not docs.
#   5. FAIL CLOSED: a rename listing that fails exits nonzero with no outputs,
#      so the gate never runs on a partial path list.
#   6. The 3000-entry cap is on the listing endpoint: rename sources are
#      appended after the count, so 2999 entries with a rename are classified,
#      while a listing of 3000 still fails closed.
#   7. A rename past the first page (per_page=100) still reaches the gate.
#
# Run from the repo root:
#   bash selftest/test_codex_review_rename_sources.sh
set -euo pipefail

WF=.github/workflows/codex-review.yml
failed=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# The chain below feeds the step's outputs to the gate the way the workflow
# does. If the gate stopped reading them, this test would exercise a path
# production no longer takes, so pin that wiring first.
wf_code=$(grep -vE '^[[:space:]]*#' "$WF" || true)
# shellcheck disable=SC2016 # literal ${{ }} expressions, matched verbatim
if grep -qF 'CHANGED_FILES: ${{ steps.diff.outputs.files }}' <<<"$wf_code" \
  && grep -qF 'DIFF_LINES: ${{ steps.diff.outputs.lines }}' <<<"$wf_code"; then
  echo "✓ the cost gate reads the diff step's files and lines outputs"
else
  echo "✗ $WF no longer feeds steps.diff.outputs.files/lines to the cost gate — this test no longer models it"
  failed=1
fi

# The step's run block, de-indented: from its `run: |` to the next step.
awk '
  /^[[:space:]]*id: diff[[:space:]]*$/ { in_step = 1; next }
  in_step && /^[[:space:]]*run: \|[[:space:]]*$/ { grab = 1; next }
  grab && /^      - name:/ { exit }
  grab { print }
' "$WF" | sed -e 's/^          //' > "$T/step.sh"

if ! grep -q 'pulls/' "$T/step.sh" || ! grep -q 'GITHUB_OUTPUT' "$T/step.sh"; then
  echo "✗ could not extract the diff step's run block from $WF"
  exit 1
fi
echo "✓ extracted the diff step ($(wc -l < "$T/step.sh" | tr -d ' ') lines)"

# Mutants for the controls. Each must change the step, or the control would
# pass against the unmutated step and prove nothing.
# shellcheck disable=SC2016 # a literal `$(` in the sed address, not an expansion
sed '/renamed_from=\$(/,/^fi$/d' "$T/step.sh" > "$T/step-no-rename-read.sh"
sed '/previous_filename/ s/--paginate //' "$T/step.sh" > "$T/step-rename-read-unpaginated.sh"
no_read_code=$(grep -vE '^[[:space:]]*#' "$T/step-no-rename-read.sh" || true)
if cmp -s "$T/step.sh" "$T/step-no-rename-read.sh" \
  || grep -qE 'previous_filename|renamed_from' <<<"$no_read_code" \
  || ! grep -q 'GITHUB_OUTPUT' <<<"$no_read_code"; then
  echo "✗ could not cut the rename read cleanly out of the step — update this test's sed range"
  failed=1
  no_read_ok=0
else
  no_read_ok=1
fi
if cmp -s "$T/step.sh" "$T/step-rename-read-unpaginated.sh"; then
  echo "✗ could not drop --paginate from the step's rename read — update this test's sed"
  failed=1
  unpaginated_ok=0
else
  unpaginated_ok=1
fi

# The gate runs from the caller's checkout, where risk-paths.yml sits beside
# the gate script and the vendored deps it imports (fetched by an earlier
# step into .github/scripts/).
mkdir -p "$T/repo/.github/scripts" "$T/state" "$T/bin"
cp .github/scripts/codex-gate.mjs .github/scripts/classifier-deps.mjs "$T/repo/.github/scripts/"
cat > "$T/repo/.github/risk-paths.yml" <<'YAML'
always_review:
  - 'src/auth/**'
YAML

# Stub `gh`. Serves the files API from $STUB_FILES_JSON: one page (per_page,
# default 30) without --paginate, every entry up to the API's 3000-file cap
# with it, filtered by the caller's own --jq. `pr view` answers
# {additions, deletions} through the caller's --jq. The first
# $STUB_RENAME_FAILS rename-source calls (told apart by their --jq text) fail
# like an API blip.
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
limit=30
case "$url" in *per_page=*) limit="${url##*per_page=}"; limit="${limit%%&*}" ;; esac
case " $* " in *" --paginate "*) limit=3000 ;; esac
case "$filter" in
  *previous_filename*)
    n=$(( $(cat "$STUB_STATE/rename_calls") + 1 ))
    echo "$n" > "$STUB_STATE/rename_calls"
    if [ "$n" -le "$STUB_RENAME_FAILS" ]; then
      echo "gh: Internal Server Error (HTTP 500)" >&2
      exit 1
    fi
    ;;
esac
jq -r ".[:$limit] | $filter" "$STUB_FILES_JSON"
STUB
chmod +x "$T/bin/gh"

# files_fixture — reads one entry per line on stdin and writes the files-API
# response the stub serves: `path` is a modified file, `old=>new` a rename
# (status renamed, previous_filename set), as the real API reports them.
files_fixture() {
  jq -R -s '
    split("\n") | map(select(length > 0)) | map(
      if contains("=>") then split("=>") | {filename: .[1], previous_filename: .[0], status: "renamed"}
      else {filename: ., status: "modified"} end)' > "$T/files.json"
}

RENAME_FAILS=0
# run_step <script> <additions> <deletions> — resets RENAME_FAILS.
run_step() {
  : > "$T/ghout"
  echo 0 > "$T/state/rename_calls"
  set +e
  LOG=$(cd "$T/repo" && PATH="$T/bin:$PATH" GH_TOKEN=stub PR=7 GITHUB_REPOSITORY=acme/fixture \
    GITHUB_OUTPUT="$T/ghout" STUB_FILES_JSON="$T/files.json" STUB_STATE="$T/state" \
    STUB_RENAME_FAILS="$RENAME_FAILS" STUB_ADDITIONS="$2" STUB_DELETIONS="$3" \
    bash "$1" 2>&1 < /dev/null)
  RC=$?
  set -e
  RENAME_FAILS=0
}

# The step's `files` output, read up to the delimiter the step declared.
out_files() {
  awk '
    !d && /^files<</ { d = substr($0, 8); next }
    d && $0 == d { exit }
    d { print }
  ' "$T/ghout"
}

# expect_gate <description> <want should_run> — the gate on the step's outputs.
# SIZE_THRESHOLD is what the workflow passes. GITHUB_STEP_SUMMARY is
# redirected so a run under Actions does not append to the real summary.
expect_gate() {
  local lines got gate_rc gate_log
  if [ "$RC" -ne 0 ]; then
    echo "✗ $1 — the diff step failed (rc=$RC). Output:"
    printf '%s\n' "$LOG" | sed 's/^/    /'
    failed=1
    return
  fi
  lines=$(sed -n 's/^lines=//p' "$T/ghout")
  : > "$T/gateout"
  set +e
  gate_log=$(cd "$T/repo" && CHANGED_FILES="$(out_files)" DIFF_LINES="$lines" SIZE_THRESHOLD=30 \
    GITHUB_OUTPUT="$T/gateout" GITHUB_STEP_SUMMARY="$T/summary" \
    node .github/scripts/codex-gate.mjs 2>&1 < /dev/null)
  gate_rc=$?
  set -e
  got=$(sed -n 's/^should_run=//p' "$T/gateout")
  if [ "$gate_rc" -eq 0 ] && [ "$got" = "$2" ]; then
    echo "✓ $1"
  else
    echo "✗ $1 — want should_run=$2; got rc=$gate_rc, should_run='$got'. Step, then gate:"
    printf '%s\n%s\n' "$LOG" "$gate_log" | sed 's/^/    /'
    failed=1
  fi
}

# expect_fail_closed <description> <log needle>
expect_fail_closed() {
  if [ "$RC" -ne 0 ] && [ ! -s "$T/ghout" ] && grep -q "$2" <<<"$LOG"; then
    echo "✓ $1"
  else
    echo "✗ $1 — want a nonzero rc, no outputs and '$2' in the log; got rc=$RC. Output:"
    printf '%s\n' "$LOG" | sed 's/^/    /'
    failed=1
  fi
}

# 0. Baseline: small diffs skip, unless a listed path is modified in place.
printf '%s\n' 'src/misc/session.py' | files_fixture
run_step "$T/step.sh" 3 2
expect_gate "a 5-line change to an unlisted file skips" false

printf '%s\n' 'src/auth/session.py' | files_fixture
run_step "$T/step.sh" 3 2
expect_gate "a 5-line change to an always_review file runs" true

# 1. The rename source decides.
printf '%s\n' 'src/auth/session.py=>src/misc/session.py' | files_fixture
run_step "$T/step.sh" 3 2
expect_gate "a 5-line rename out of an always_review path runs" true

# 2. Negative control: neither end is listed.
printf '%s\n' 'src/misc/old.py=>src/misc/session.py' | files_fixture
run_step "$T/step.sh" 3 2
expect_gate "control: a 5-line rename between unlisted paths skips" false

# 3. Mutation control: case 1's fixture, the step without its rename read.
if [ "$no_read_ok" = 1 ]; then
  printf '%s\n' 'src/auth/session.py=>src/misc/session.py' | files_fixture
  run_step "$T/step-no-rename-read.sh" 3 2
  expect_gate "control: without the rename read, that rename skips" false
fi

# 4. The docs/tests-only skip, with sources appended. 400 lines clears the
#    size threshold, so only that rule can skip these.
printf '%s\n' 'docs/guide/old.md=>docs/guide/new.md' | files_fixture
run_step "$T/step.sh" 200 200
expect_gate "a docs-to-docs rename still skips as docs-only" false

printf '%s\n' 'src/misc/tool.py=>docs/archive/tool.py' | files_fixture
run_step "$T/step.sh" 200 200
expect_gate "a rename from code into docs/ is not docs-only, so it runs" true

# 5. FAIL CLOSED on an unreadable rename listing.
printf '%s\n' 'src/auth/session.py=>src/misc/session.py' | files_fixture
RENAME_FAILS=99
run_step "$T/step.sh" 3 2
expect_fail_closed "a rename listing that fails fails closed" "could not list PR rename sources"

# 6. The cap counts the listing only. 2998 docs files plus the rename are 2999
#    entries, and 3000 paths once the source is appended.
{ seq 1 2998 | sed 's|.*|docs/f&.md|'; echo 'src/auth/session.py=>src/misc/session.py'; } | files_fixture
run_step "$T/step.sh" 3 2
expect_gate "2999 listed files and a rename: counted before the append, then gated" true

{ seq 1 2999 | sed 's|.*|docs/f&.md|'; echo 'src/auth/session.py=>src/misc/session.py'; } | files_fixture
run_step "$T/step.sh" 3 2
expect_fail_closed "a listing of 3000 files still fails closed" "file listing is truncated"

# 7. Pagination: the rename is entry 150, on page 2 at per_page=100.
{ seq 1 149 | sed 's|.*|docs/f&.md|'; echo 'src/auth/session.py=>src/misc/session.py'; } | files_fixture
run_step "$T/step.sh" 3 2
expect_gate "a rename on page 2 of the listing runs" true

if [ "$unpaginated_ok" = 1 ]; then
  run_step "$T/step-rename-read-unpaginated.sh" 3 2
  expect_gate "control: an unpaginated rename read misses it and skips" false
fi

echo ""
if [ "$failed" -ne 0 ]; then
  echo "FAIL: codex-review rename-source case(s) regressed."
  exit 1
fi
echo "OK: all codex-review rename-source cases pass."
