#!/usr/bin/env bash
# Behavioral test: safe-paths-automerge.yml's classify step must check a
# renamed file's OLD path against the safe globs, as well as its new one.
#
# The workflow arms auto-merge only when every path a PR changes matches a
# safe glob (docs and tests by default). The files API lists a rename under
# its destination in `.filename`; the source is only in `.previous_filename`.
# A rename source is a path the PR removes, so a safe-glob check that reads
# `.filename` alone passes a move of runtime code into docs/ or tests/ as a
# docs/tests-only diff, while the same change listed as a removal plus an
# addition does not pass.
#
# The step's bash is EXTRACTED from the workflow and executed against a stub
# `gh` that answers each call by running the step's OWN --jq filter over
# gh-shaped JSON, so a wrong filter or a missing --paginate changes the answer
# the way the real API would. Every expected verdict is hardcoded. Pins:
#
#   1. A rename from outside the safe globs into docs/, tests/ or a
#      test-named file is not all-safe and sets no reason, the same verdict
#      as the same change listed as a removal plus an addition. No reason
#      means "defer to the other automerge workflows"; the revoke step does
#      not act on it.
#   2. Old paths are added to the check, not swapped in for new ones: a
#      rename out of docs/ into an unsafe path is still not all-safe.
#   3. Negative controls: renames with both ends safe, under the built-in
#      globs or the caller's extra_safe_globs, stay all-safe, so case 1
#      cannot pass by refusing every rename.
#   4. A risk-tier source outside the safe globs gets the same verdict as
#      its removal-plus-addition twin, with or without the bypass label. A
#      risk-tier source that is safe-by-glob (an auth spec moved out of
#      auth/) still reaches the risk-tier hold.
#   5. Mutation controls: the step with the rename sources cut from the
#      safe-glob loop, and with --paginate dropped from the rename read,
#      reads cases 1 and 8 as all-safe. The verdicts come from the step, not
#      from the harness.
#   6. FAIL CLOSED: a rename listing that fails exits nonzero and writes no
#      all_safe, so nothing is armed on a partial list.
#   7. The 3000-file cap counts the listing's entries only: 2998 files and
#      a rename are 2999 entries, checked rather than truncated.
#   8. A rename past the first page (per_page=100) is checked.
#
# Run from the repo root:
#   bash selftest/test_safe_paths_rename_sources.sh
set -euo pipefail

WF=.github/workflows/safe-paths-automerge.yml
failed=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# The step's run block, de-indented: from its `run: |` to the next step.
awk '
  /^[[:space:]]*id: classify[[:space:]]*$/ { in_step = 1; next }
  in_step && /^[[:space:]]*run: \|[[:space:]]*$/ { grab = 1; next }
  grab && /^      - name:/ { exit }
  grab { print }
' "$WF" | sed -e 's/^          //' > "$T/step.sh"

if ! grep -q 'builtin_globs=' "$T/step.sh" || ! grep -q 'GITHUB_OUTPUT' "$T/step.sh"; then
  echo "✗ could not extract the classify step's run block from $WF"
  exit 1
fi
echo "✓ extracted the classify step ($(wc -l < "$T/step.sh" | tr -d ' ') lines)"

# Mutants for the controls. Each must change exactly one line of the step,
# or the control would pass against the unmutated step and prove nothing.
# The safe-glob loop starts at `unsafe_files=""`, and its closing `done <<<`
# line names what it reads. Tier 1's loop closes the same way, so the edit is
# anchored after that start line.
awk '
  /^unsafe_files=""$/ { in_loop = 1 }
  in_loop && /^done <<< / { print "done <<< \"$changed\""; in_loop = 0; next }
  { print }
' "$T/step.sh" > "$T/step-loop-without-sources.sh"
sed '/previous_filename/ s/--paginate //' "$T/step.sh" > "$T/step-rename-read-unpaginated.sh"

# one_line_changed <mutant> — true when the mutant differs from the step in
# exactly one line.
one_line_changed() {
  [ "$(diff "$T/step.sh" "$1" | grep -c '^[<>]' || true)" -eq 2 ]
}
if one_line_changed "$T/step-loop-without-sources.sh"; then
  no_sources_ok=1
else
  echo "✗ could not cut the rename sources out of the safe-glob loop — update this test's awk"
  failed=1
  no_sources_ok=0
fi
if one_line_changed "$T/step-rename-read-unpaginated.sh"; then
  unpaginated_ok=1
else
  echo "✗ could not drop --paginate from the step's rename read — update this test's sed"
  failed=1
  unpaginated_ok=0
fi

# Stub `gh`. Serves the files API from $STUB_FILES_JSON: one page (per_page,
# default 30) without --paginate, every entry up to the API's 3000-file cap
# with it, filtered by the caller's own --jq. The PR read (the bypass-label
# check) is answered from $STUB_PR_JSON the same way. The first
# $STUB_RENAME_FAILS rename-source calls (told apart by their --jq text) fail
# like an API outage.
mkdir -p "$T/state" "$T/bin"
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
jq_filter() { while [ $# -gt 0 ]; do [ "$1" = "--jq" ] && { printf '%s' "$2"; return 0; }; shift; done; return 1; }
filter=$(jq_filter "$@") || { echo "gh-stub: call without --jq: $*" >&2; exit 64; }
url="${2:-}"
case "${1:-}:$url" in
  "api:repos/${REPO}/pulls/${PR}/files"*) ;;
  "api:repos/${REPO}/pulls/${PR}")
    jq -r "$filter" "$STUB_PR_JSON"
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
# response the stub serves, shaped as the real API reports each change:
# `old=>new` is a rename (status renamed, previous_filename set), `-path` a
# removal, `+path` an addition, and any other line a modified file.
files_fixture() {
  jq -R -s '
    split("\n") | map(select(length > 0)) | map(
      if contains("=>") then split("=>") | {filename: .[1], previous_filename: .[0], status: "renamed"}
      elif startswith("-") then {filename: .[1:], status: "removed"}
      elif startswith("+") then {filename: .[1:], status: "added"}
      else {filename: ., status: "modified"} end)' > "$T/files.json"
}

RENAME_FAILS=0
EXTRA=""
LABELS='[]'
# run_step <script> — resets the stub's call counter, RENAME_FAILS, EXTRA
# and LABELS after the run.
run_step() {
  : > "$T/ghout"
  echo 0 > "$T/state/rename_calls"
  printf '{"labels":%s}\n' "$LABELS" > "$T/pr.json"
  set +e
  LOG=$(PATH="$T/bin:$PATH" GH_TOKEN=stub REPO=acme/fixture PR=7 \
    EXTRA_GLOBS="$EXTRA" BYPASS_LABEL=auto-merge-approved GITHUB_OUTPUT="$T/ghout" \
    STUB_FILES_JSON="$T/files.json" STUB_PR_JSON="$T/pr.json" STUB_STATE="$T/state" \
    STUB_RENAME_FAILS="$RENAME_FAILS" bash "$1" 2>&1 < /dev/null)
  RC=$?
  set -e
  RENAME_FAILS=0
  EXTRA=""
  LABELS='[]'
}

# expect <description> <want all_safe> <want reason, or - for none>
expect() {
  local got_safe got_reason
  got_safe=$(sed -n 's/^all_safe=//p' "$T/ghout")
  got_reason=$(sed -n 's/^reason=//p' "$T/ghout")
  [ -n "$got_reason" ] || got_reason="-"
  if [ "$RC" -eq 0 ] && [ "$got_safe" = "$2" ] && [ "$got_reason" = "$3" ]; then
    echo "✓ $1"
  else
    echo "✗ $1 — want rc=0, all_safe=$2, reason=$3; got rc=$RC, all_safe='$got_safe', reason=$got_reason. Output:"
    printf '%s\n' "$LOG" | sed 's/^/    /'
    failed=1
  fi
}

# expect_fail_closed <description>
expect_fail_closed() {
  if [ "$RC" -ne 0 ] && ! grep -q '^all_safe=' "$T/ghout" && grep -q 'HTTP 500' <<<"$LOG"; then
    echo "✓ $1"
  else
    echo "✗ $1 — want a nonzero rc from the failed rename read and no all_safe written; got rc=$RC. Output:"
    printf '%s\n' "$LOG" | sed 's/^/    /'
    failed=1
  fi
}

# 0. Baselines.
printf '%s\n' 'docs/guide.md' | files_fixture
run_step "$T/step.sh"
expect "a modified docs file is all-safe" 1 -

printf '%s\n' 'src/worker.py' | files_fixture
run_step "$T/step.sh"
expect "a modified source file is not all-safe and sets no reason" 0 -

# 1. The old path counts. Every destination here is safe on its own.
printf '%s\n' 'src/worker.py=>docs/archive/worker.py' | files_fixture
run_step "$T/step.sh"
expect "a rename from src/ into docs/ is not all-safe and sets no reason" 0 -
if grep -Fxq 'src/worker.py' <<<"$LOG"; then
  echo "✓ the step log lists the rename's old path as the unsafe file"
else
  echo "✗ the step log does not list src/worker.py as an unsafe file. Output:"
  printf '%s\n' "$LOG" | sed 's/^/    /'
  failed=1
fi

printf '%s\n' '-src/worker.py' '+docs/archive/worker.py' | files_fixture
run_step "$T/step.sh"
expect "the same change listed as a removal plus an addition gets that verdict" 0 -

printf '%s\n' 'src/worker.py=>tests/fixtures/worker.py' | files_fixture
run_step "$T/step.sh"
expect "a rename from src/ into tests/ is not all-safe" 0 -

printf '%s\n' 'pkg/worker.go=>pkg/worker_test.go' | files_fixture
run_step "$T/step.sh"
expect "a source file renamed to a test-named file is not all-safe" 0 -

# 2. Added, not swapped in: the new path still counts.
printf '%s\n' 'docs/deploy.md=>scripts/deploy.sh' | files_fixture
run_step "$T/step.sh"
expect "a rename out of docs/ into an unsafe path is not all-safe" 0 -

# 3. Negative controls: both ends safe.
printf '%s\n' 'docs/old-guide.md=>docs/guide.md' 'tests/test_old.py=>tests/test_new.py' | files_fixture
run_step "$T/step.sh"
expect "control: renames with both ends under the built-in globs stay all-safe" 1 -

printf '%s\n' 'examples/demo.py=>docs/examples/demo.py' | files_fixture
EXTRA='^examples/'
run_step "$T/step.sh"
expect "control: an old path safe under the caller's extra_safe_globs stays all-safe" 1 -

# 4. Risk-tier old paths.
printf '%s\n' 'src/auth/login.ts=>docs/archive/login.ts' | files_fixture
run_step "$T/step.sh"
expect "a risk-tier source file renamed into docs/ is not all-safe and sets no reason" 0 -

printf '%s\n' '-src/auth/login.ts' '+docs/archive/login.ts' | files_fixture
run_step "$T/step.sh"
expect "its removal-plus-addition twin gets that verdict" 0 -

printf '%s\n' 'src/auth/login.ts=>docs/archive/login.ts' | files_fixture
LABELS='[{"name":"auto-merge-approved"}]'
run_step "$T/step.sh"
expect "the bypass label does not make that rename all-safe" 0 -

printf '%s\n' 'web/tests/e2e/auth/signup.spec.ts=>web/tests/e2e/misc/signup.spec.ts' | files_fixture
run_step "$T/step.sh"
expect "an auth spec moved out of auth/ still reaches the risk-tier hold" 0 risk-tier-hold

# 5. Mutation control: case 1's fixture, the loop without the rename sources.
if [ "$no_sources_ok" = 1 ]; then
  printf '%s\n' 'src/worker.py=>docs/archive/worker.py' | files_fixture
  run_step "$T/step-loop-without-sources.sh"
  expect "control: with the old paths cut from the safe-glob loop, that rename reads all-safe" 1 -
fi

# 6. FAIL CLOSED on an unreadable rename listing.
printf '%s\n' 'src/worker.py=>docs/archive/worker.py' | files_fixture
RENAME_FAILS=99
run_step "$T/step.sh"
expect_fail_closed "a rename listing that fails exits nonzero and writes no all_safe"

# 7. The cap counts the listing only: 2998 docs files and the rename are 2999
#    entries, and 3000 paths once the old path is added.
{ seq 1 2998 | sed 's|.*|docs/f&.md|'; echo 'src/worker.py=>docs/archive/worker.py'; } | files_fixture
run_step "$T/step.sh"
expect "2998 files and a rename are checked, not truncated" 0 -

# 8. Pagination: the rename is entry 150, on page 2 at per_page=100.
{ seq 1 149 | sed 's|.*|docs/f&.md|'; echo 'src/worker.py=>docs/archive/worker.py'; } | files_fixture
run_step "$T/step.sh"
expect "a rename on page 2 of the listing is not all-safe" 0 -

if [ "$unpaginated_ok" = 1 ]; then
  run_step "$T/step-rename-read-unpaginated.sh"
  expect "control: an unpaginated rename read misses it (all-safe)" 1 -
fi

echo ""
if [ "$failed" -ne 0 ]; then
  echo "FAIL: safe-paths rename-source case(s) regressed."
  exit 1
fi
echo "OK: all safe-paths rename-source cases pass."
