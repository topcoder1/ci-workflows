#!/usr/bin/env bash
# Behavioral test: pr-classify.yml's "Compute highest-priority class" step
# must classify a renamed file's OLD path as well as its new one.
#
# The files API lists a rename under its destination in `.filename`; the
# source path is only in `.previous_filename`. A step that reads `.filename`
# alone judges a moved file by where it landed, never by where it came from.
# That class becomes the risk:* label, a gating input for
# claude-author-automerge.yml, and the reusable's risk_class output, which
# decides whether pr-codex-review.yml runs Codex at all.
#
# The step's bash is EXTRACTED from the workflow and executed against a stub
# `gh` that answers each files-API call by running the step's OWN --jq filter
# over a gh-shaped response, so a wrong filter or a missing --paginate changes
# the answer the way the real API would, and against the REAL classify.mjs.
# Every expected class is hardcoded. Pins:
#
#   1. A rename whose source is blocked or sensitive, and whose destination is
#      trivial, classifies as the source's class. Sources are added to the
#      list, not swapped in for it: a modified blocked file beside a docs
#      rename still classifies blocked.
#   2. Negative control: a rename with neither end gated stays trivial, so
#      case 1 cannot pass by gating every rename.
#   3. Mutation controls: the same step with its rename read cut out, and with
#      --paginate dropped from it, classify cases 1 and 6 trivial. The gated
#      verdicts come from the rename read, not from the harness.
#   4. FAIL CLOSED: a rename listing that keeps failing exits nonzero and
#      writes no class. A single failure is retried, like the step's other
#      gh calls.
#   5. The 3000-entry cap is on the listing endpoint: rename sources are
#      appended after the count, so 2999 entries with a rename are classified,
#      while a listing of 3000 still fails closed.
#   6. A rename past the first page (per_page=100) is still classified.
#   7. A path list over 128 KiB (Linux's cap on one environment string) is
#      classified whole: the step pipes the list to the classifier.
#
# Run from the repo root:
#   bash selftest/test_pr_classify_rename_sources.sh
set -euo pipefail

WF=.github/workflows/pr-classify.yml
failed=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# The step's run block, de-indented: from its `run: |` to the next step.
awk '
  /^[[:space:]]*id: compute[[:space:]]*$/ { in_step = 1; next }
  in_step && /^[[:space:]]*run: \|[[:space:]]*$/ { grab = 1; next }
  grab && /^      - name:/ { exit }
  grab { print }
' "$WF" | sed -e 's/^          //' > "$T/step.sh"

if ! grep -q 'classify\.mjs' "$T/step.sh" || ! grep -q 'GITHUB_OUTPUT' "$T/step.sh"; then
  echo "✗ could not extract the compute step's run block from $WF"
  exit 1
fi
echo "✓ extracted the compute step ($(wc -l < "$T/step.sh" | tr -d ' ') lines)"

# Mutants for the controls. Each must change the step, or the control would
# pass against the unmutated step and prove nothing.
# shellcheck disable=SC2016 # a literal `$(` in the sed address, not an expansion
sed '/renamed_from=\$(/,/^fi$/d' "$T/step.sh" > "$T/step-no-rename-read.sh"
sed '/previous_filename/ s/--paginate //' "$T/step.sh" > "$T/step-rename-read-unpaginated.sh"
no_read_code=$(grep -vE '^[[:space:]]*#' "$T/step-no-rename-read.sh" || true)
if cmp -s "$T/step.sh" "$T/step-no-rename-read.sh" \
  || grep -qE 'previous_filename|renamed_from' <<<"$no_read_code" \
  || ! grep -q 'classify\.mjs' <<<"$no_read_code"; then
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

# The job runs this step from the caller's checkout, where risk-paths.yml sits
# beside the classifier and the vendored deps it imports (the previous step
# fetches both into .github/scripts/).
mkdir -p "$T/repo/.github/scripts" "$T/state" "$T/bin"
cp .github/scripts/classify.mjs .github/scripts/classifier-deps.mjs "$T/repo/.github/scripts/"
cat > "$T/repo/.github/risk-paths.yml" <<'YAML'
blocked:
  - 'src/auth/**'
sensitive:
  - 'src/billing/**'
trivial:
  - 'docs/**'
YAML

# Stub `gh`. Serves the files API from $STUB_FILES_JSON: one page (per_page,
# default 30) without --paginate, every entry up to the API's 3000-file cap
# with it, filtered by the caller's own --jq. The first $STUB_RENAME_FAILS
# rename-source calls (told apart by their --jq text) fail like an API blip.
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
jq_filter() { while [ $# -gt 0 ]; do [ "$1" = "--jq" ] && { printf '%s' "$2"; return 0; }; shift; done; return 1; }
url="${2:-}"
case "${1:-}:$url" in
  "api:repos/${GITHUB_REPOSITORY}/pulls/${PR}/files"*) ;;
  *) echo "gh-stub: unexpected call: $*" >&2; exit 64 ;;
esac
filter=$(jq_filter "$@") || { echo "gh-stub: files call without --jq: $*" >&2; exit 64; }
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
# The step's retry helper sleeps between attempts.
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/sleep"
chmod +x "$T/bin/sleep"

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
# run_step <script> — resets the stub's call counter and RENAME_FAILS.
run_step() {
  : > "$T/ghout"
  echo 0 > "$T/state/rename_calls"
  set +e
  LOG=$(cd "$T/repo" && PATH="$T/bin:$PATH" GH_TOKEN=stub PR=7 GITHUB_REPOSITORY=acme/fixture \
    GITHUB_OUTPUT="$T/ghout" STUB_FILES_JSON="$T/files.json" STUB_STATE="$T/state" \
    STUB_RENAME_FAILS="$RENAME_FAILS" bash "$1" 2>&1 < /dev/null)
  RC=$?
  set -e
  RENAME_FAILS=0
}

# expect_class <description> <want class>
expect_class() {
  local got
  got=$(sed -n 's/^class=//p' "$T/ghout")
  if [ "$RC" -eq 0 ] && [ "$got" = "$2" ]; then
    echo "✓ $1"
  else
    echo "✗ $1 — want rc=0 and class=$2; got rc=$RC, class='$got'. Output:"
    printf '%s\n' "$LOG" | sed 's/^/    /'
    failed=1
  fi
}

# expect_fail_closed <description> <log needle>
expect_fail_closed() {
  if [ "$RC" -ne 0 ] && ! grep -q '^class=' "$T/ghout" && grep -q "$2" <<<"$LOG"; then
    echo "✓ $1"
  else
    echo "✗ $1 — want a nonzero rc, no class written and '$2' in the log; got rc=$RC. Output:"
    printf '%s\n' "$LOG" | sed 's/^/    /'
    failed=1
  fi
}

# 0. Baseline: a plain change classifies as before.
printf '%s\n' 'src/misc/session.py' | files_fixture
run_step "$T/step.sh"
expect_class "a modified unlisted file classifies standard" standard

# 1. The rename source decides. Each destination is trivial on its own.
printf '%s\n' 'src/auth/session.md=>docs/session.md' | files_fixture
run_step "$T/step.sh"
expect_class "a rename from a blocked path to docs/ classifies blocked" blocked

printf '%s\n' 'src/billing/rates.py=>docs/archive/rates.py' | files_fixture
run_step "$T/step.sh"
expect_class "a rename from a sensitive path to docs/ classifies sensitive" sensitive

printf '%s\n' 'src/auth/login.py' 'docs/old.md=>docs/new.md' | files_fixture
run_step "$T/step.sh"
expect_class "a modified blocked file beside a docs rename classifies blocked" blocked

# 2. Negative control: neither end is gated.
printf '%s\n' 'docs/old-guide.md=>docs/guide.md' | files_fixture
run_step "$T/step.sh"
expect_class "control: a docs-to-docs rename stays trivial" trivial

# 3. Mutation control: case 1's fixture, the step without its rename read.
if [ "$no_read_ok" = 1 ]; then
  printf '%s\n' 'src/auth/session.md=>docs/session.md' | files_fixture
  run_step "$T/step-no-rename-read.sh"
  expect_class "control: without the rename read, that rename classifies trivial" trivial
fi

# 4. FAIL CLOSED on an unreadable rename listing; one blip is retried.
printf '%s\n' 'src/auth/session.md=>docs/session.md' | files_fixture
RENAME_FAILS=99
run_step "$T/step.sh"
expect_fail_closed "a rename listing that keeps failing fails closed" "could not list PR rename sources"

RENAME_FAILS=1
run_step "$T/step.sh"
expect_class "a rename listing that fails once is retried, then classified" blocked

# 5. The cap counts the listing only. 2998 docs files plus the rename are 2999
#    entries, and 3000 paths once the source is appended.
{ seq 1 2998 | sed 's|.*|docs/f&.md|'; echo 'src/auth/session.md=>docs/session.md'; } | files_fixture
run_step "$T/step.sh"
expect_class "2999 listed files and a rename: counted before the append, then classified" blocked

{ seq 1 2999 | sed 's|.*|docs/f&.md|'; echo 'src/auth/session.md=>docs/session.md'; } | files_fixture
run_step "$T/step.sh"
expect_fail_closed "a listing of 3000 files still fails closed" "file listing is truncated"

# 6. Pagination: the rename is entry 150, on page 2 at per_page=100.
{ seq 1 149 | sed 's|.*|docs/f&.md|'; echo 'src/auth/session.md=>docs/session.md'; } | files_fixture
run_step "$T/step.sh"
expect_class "a rename on page 2 of the listing classifies blocked" blocked

if [ "$unpaginated_ok" = 1 ]; then
  run_step "$T/step-rename-read-unpaginated.sh"
  expect_class "control: an unpaginated rename read misses it (trivial)" trivial
fi

# 7. A path list over 128 KiB is classified whole. 1500 long-path renames into
#    docs/ list 3000 paths. The only blocked path is the last rename's source,
#    which comes last in the list, so the class is blocked only if the end of
#    the list reached the classifier. Linux refuses to start a process with an
#    environment string over 128 KiB, so a list handed over in the environment
#    would fail here on a Linux runner.
{ seq 1 1499 | awk '{ printf "packages/app/src/components/widget%05d/index.tsx=>docs/archive/components/widget%05d/index.tsx\n", $1, $1 }'
  echo 'src/auth/session.md=>docs/archive/session.md'; } | files_fixture
fixture_bytes=$(jq -r '.[] | .filename, (.previous_filename // empty)' "$T/files.json" | wc -c | tr -d ' ')
if [ "$fixture_bytes" -gt 131072 ]; then
  echo "✓ the 1500-rename fixture's path list is over 128 KiB ($fixture_bytes bytes)"
else
  echo "✗ the 1500-rename fixture's path list is $fixture_bytes bytes, not over 128 KiB — it no longer tests the limit"
  failed=1
fi
run_step "$T/step.sh"
expect_class "a path list over 128 KiB is classified whole" blocked

echo ""
if [ "$failed" -ne 0 ]; then
  echo "FAIL: pr-classify rename-source case(s) regressed."
  exit 1
fi
echo "OK: all pr-classify rename-source cases pass."
