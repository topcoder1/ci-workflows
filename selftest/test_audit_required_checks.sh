#!/usr/bin/env bash
# Behavioral test for the required-checks audit's exit-code contract:
# validate-required-checks.sh exits 1 for a FINDING and for nothing else, and
# audit-required-checks-fleet.sh files a 1 as a finding and every other
# non-zero code as an error.
#
# 2026-10-12, run 38234284948: every topcoder1 repo reported "script error,
# exit 5". `gh api` prints an HTTP error's JSON body to STDOUT and exits 1; the
# validator's `2>/dev/null || true` fed the dead token's 401 body to its rules
# filter, and jq died with its runtime-error code 5 ("Cannot index string with
# string "type""). The contents calls' `|| echo '[]'` / `|| true` turned the
# same failure into "no workflows", which is a false phantom-check FINDING.
# And the fleet wrapper headed every validator exit 1, the code for a REAL
# finding, "script error".
#
# The validator runs against a PATH-shim `gh` serving a fake GitHub from
# $T/gh/<owner>/<repo>/ (rules.json, workflows/*.yml). Scripted failures take
# gh's real shape (measured 2026-10-15, gh 2.97.0): the JSON error body on
# STDOUT, `gh: <message> (HTTP <status>)` on stderr, rc=1. Every expected value
# below is hardcoded; none is read from the scripts under test.
#
# Cases:
#   0  control: a repo whose required check has a PR producer exits 0
#   a  the rules call answers 401 => exit 3 naming HTTP 401 and "Bad
#      credentials"; never 5, no jq error. A 404 => exit 3 (a private repo
#      answers 404 to a token that cannot see it, so it is not "no rules");
#      no response => exit 3; 200 `[]` => exit 0; 200 with anything but an
#      array of rules => exit 3
#   b  a contents call on a private repo fails (the listing 403, one file 404,
#      the central listing with no response; a listing that is not one)
#      => exit 3, with no verdict lines and no FAIL line
#   c  a required check with no PR producer => exit 1 with its ✗ line, and
#      the fleet wrapper files it under FINDING and exits 1
#   d  Attaxion repos are skipped by name, as in dotclaude's fleet red-workflow
#      digest: ^(asm-|attaxion) against the lowercased repo name, owner
#      excluded. They are never validated, and are named on stderr and in the
#      digest; look-alikes are still audited; skipping every repo exits 2
#   e  an uncaught Python exception exits 4, an unexpected command failure
#      exits 4, and a value flag given no value exits 2: none exits 1
#   f  the fleet wrapper over clean + finding + error repos exits 3 with
#      distinct headings and counts and no block for the clean repo; the
#      workflow's digest step opens the issue for a finding and not for an
#      all-clean run
# Negative controls (the shim reproduces each old failure, run verbatim):
#   n1 the old rules fetch + filter dies with jq exit 5 on case a's 401
#   n4 the old rules fetch reads case a's no-response failure as "no branch
#      rules found" and exits 0: a repo it never reached passes as clean
#   n2 the old listing fetch reads case b's 403 as zero workflow names
#   n3 the old per-file fetch turns case b's 404 into an empty workflow file
#
# Run from the repo root:
#   bash selftest/test_audit_required_checks.sh
set -euo pipefail

VALIDATOR="$PWD/scripts/validate-required-checks.sh"
FLEET="$PWD/scripts/audit-required-checks-fleet.sh"
WORKFLOW=.github/workflows/audit-required-checks.yml
failed=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

pass() { echo "✓ $1"; }
fail() {
  echo "✗ $1"
  failed=1
}
has() { grep -qF -- "$2" "$1"; } # file, literal

# ---------------------------------------------------------------------------
# The shim. One fake repo per directory; `fail` holds "<rest> <status>" lines
# (<rest> is the endpoint after /repos/<owner>/<repo>/), and `listing.json`,
# when present, replaces the generated directory listing. Every call is logged.
# ---------------------------------------------------------------------------
mkdir -p "$T/bin" "$T/gh"
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >> "$GH_FAKE/calls.log"
if [ "${1:-}" != api ]; then
  echo "shim: unexpected gh $*" >&2
  exit 98
fi
ep="${2#/}"
ep="${ep#repos/}"
owner="${ep%%/*}"
ep="${ep#*/}"
repo="${ep%%/*}"
rest="${ep#*/}"
dir="$GH_FAKE/$owner/$repo"
fail_with() { # status -> gh's stdout and stderr for that failure, rc=1
  case "$1" in
    401)
      printf '{\n  "message": "Bad credentials",\n  "documentation_url": "https://docs.github.com/rest",\n  "status": "401"\n}\n'
      echo "gh: Bad credentials (HTTP 401)" >&2 ;;
    403)
      echo '{"message":"Resource not accessible by personal access token","documentation_url":"https://docs.github.com/rest/repos/contents#get-repository-content","status":"403"}'
      echo "gh: Resource not accessible by personal access token (HTTP 403)" >&2 ;;
    404)
      echo '{"message":"Not Found","documentation_url":"https://docs.github.com/rest/repos/contents#get-repository-content","status":"404"}'
      echo "gh: Not Found (HTTP 404)" >&2 ;;
    none)
      echo "error connecting to api.github.com" >&2 ;;
    *)
      echo "shim: no failure shape for $1" >&2
      exit 99 ;;
  esac
  exit 1
}
if [ -f "$dir/fail" ]; then
  while read -r f_rest f_status; do
    if [ "$rest" = "$f_rest" ]; then fail_with "$f_status"; fi
  done < "$dir/fail"
fi
[ -d "$dir" ] || fail_with 404
case "$rest" in
  rules/branches/*)
    cat "$dir/rules.json" ;;
  contents/.github/workflows)
    [ -d "$dir/workflows" ] || fail_with 404
    if [ -f "$dir/listing.json" ]; then
      cat "$dir/listing.json"
    else
      (cd "$dir/workflows" && ls) | jq -R . | jq -s 'map({name: ., type: "file"})'
    fi ;;
  contents/.github/workflows/*)
    f="$dir/workflows/${rest#contents/.github/workflows/}"
    [ -f "$f" ] || fail_with 404
    base64 < "$f" ;; # what `--jq .content` prints: the file's base64
  *)
    echo "shim: unexpected endpoint $2" >&2
    exit 97 ;;
esac
STUB
chmod +x "$T/bin/gh"

# Workflow fixtures.
mkdir -p "$T/wf"
cat > "$T/wf/ci.yml" <<'YML'
name: CI
on:
  pull_request:
  push:
    branches: [main]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
YML

rules_json() { # required contexts... -> a rules answer in the API's shape
  local ctx="" c
  for c in "$@"; do ctx="$ctx${ctx:+,}{\"context\":\"$c\"}"; done
  printf '[{"type":"deletion","ruleset_source_type":"Repository","ruleset_source":"o/r","ruleset_id":1},{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"do_not_enforce_on_create":false,"required_status_checks":[%s]},"ruleset_source_type":"Repository","ruleset_source":"o/r","ruleset_id":1}]\n' "$ctx"
}
fake_repo() { # owner/repo, rules answer, workflow fixtures...
  local d="$T/gh/$1" w
  mkdir -p "$d/workflows"
  printf '%s\n' "$2" > "$d/rules.json"
  shift 2
  for w in "$@"; do cp "$T/wf/$w" "$d/workflows/"; done
}

# The central repo every validation also reads: present, no workflows needed.
fake_repo topcoder1/ci-workflows '[]'
fake_repo topcoder1/clean-a "$(rules_json test)" ci.yml
fake_repo topcoder1/phantom "$(rules_json test "plan-proofs / verify")" ci.yml
fake_repo topcoder1/badtoken "$(rules_json test)" ci.yml
echo "rules/branches/main 401" > "$T/gh/topcoder1/badtoken/fail"
fake_repo topcoder1/gone "$(rules_json test)" ci.yml
echo "rules/branches/main 404" > "$T/gh/topcoder1/gone/fail"
fake_repo topcoder1/offline "$(rules_json test)" ci.yml
echo "rules/branches/main none" > "$T/gh/topcoder1/offline/fail"
fake_repo topcoder1/norules '[]' ci.yml
fake_repo topcoder1/oddrules '{"message":"not a list"}' ci.yml
fake_repo topcoder1/oddrules2 '["required_status_checks"]' ci.yml
fake_repo topcoder1/nolisting "$(rules_json test)" ci.yml
echo "contents/.github/workflows 403" > "$T/gh/topcoder1/nolisting/fail"
fake_repo topcoder1/nofile "$(rules_json test)" ci.yml
echo "contents/.github/workflows/ci.yml 404" > "$T/gh/topcoder1/nofile/fail"
fake_repo topcoder1/oddlisting "$(rules_json test)" ci.yml
echo '{"name":"workflows","type":"file","content":""}' > "$T/gh/topcoder1/oddlisting/listing.json"

run_validator() { # repo [flags...] -> $VRC, $T/v.out, $T/v.err
  VRC=0
  PATH="$T/bin:$PATH" GH_FAKE="$T/gh" bash "$VALIDATOR" "$@" \
    > "$T/v.out" 2> "$T/v.err" < /dev/null || VRC=$?
}
api_error_only() { # stopped on the API error: judged nothing, claimed no crash
  ! grep -qE '✗|✓|==> (FAIL|OK)|internal error' "$T/v.out" "$T/v.err"
}

# ---------------------------------------------------------------------------
# 0. Control: the shim serves a repo the validator can pass.
# ---------------------------------------------------------------------------
run_validator topcoder1/clean-a
if [[ $VRC -eq 0 ]] && has "$T/v.out" "✓  test" &&
  has "$T/v.out" "==> OK: every required context has a pull_request-triggered producer."; then
  pass "0: a required check with a PR producer exits 0"
else
  fail "0: the control repo should exit 0 with a ✓ (got $VRC)"
  cat "$T/v.out" "$T/v.err"
fi

# ---------------------------------------------------------------------------
# a. The rules call.
# ---------------------------------------------------------------------------
: > "$T/gh/calls.log"
run_validator topcoder1/badtoken
if [[ $VRC -eq 3 ]] &&
  has "$T/v.err" "API error: GET /repos/topcoder1/badtoken/rules/branches/main failed (HTTP 401)" &&
  has "$T/v.err" "gh: Bad credentials (HTTP 401)" &&
  ! grep -q "jq: error" "$T/v.out" "$T/v.err" && api_error_only; then
  pass "a: a 401 on the rules call exits 3 with the status and gh's message"
else
  fail "a: a 401 on the rules call should exit 3 naming HTTP 401 / Bad credentials (got $VRC)"
  cat "$T/v.out" "$T/v.err"
fi
if has "$T/gh/calls.log" "api /repos/topcoder1/badtoken/rules/branches/main" &&
  ! grep -q "contents" "$T/gh/calls.log"; then
  pass "a: the 401 reached the validator, which stopped before any contents call"
else
  fail "a: expected exactly the rules call in the shim log"
  cat "$T/gh/calls.log"
fi

run_validator topcoder1/gone
if [[ $VRC -eq 3 ]] &&
  has "$T/v.err" "API error: GET /repos/topcoder1/gone/rules/branches/main failed (HTTP 404)" &&
  has "$T/v.err" "a 404 is also what a private repo answers to a token that cannot see it" &&
  api_error_only; then
  pass "a: a 404 on the rules call exits 3, not 'no rules'"
else
  fail "a: a 404 on the rules call should exit 3 (got $VRC)"
  cat "$T/v.out" "$T/v.err"
fi

run_validator topcoder1/offline
if [[ $VRC -eq 3 ]] &&
  has "$T/v.err" "API error: GET /repos/topcoder1/offline/rules/branches/main failed (no HTTP status)" &&
  has "$T/v.err" "error connecting to api.github.com" && api_error_only; then
  pass "a: a rules call with no response exits 3, not 'no branch rules found'"
else
  fail "a: a rules call with no response should exit 3 (got $VRC)"
  cat "$T/v.out" "$T/v.err"
fi

run_validator topcoder1/norules
if [[ $VRC -eq 0 ]] && has "$T/v.out" "no required_status_checks rule on main"; then
  pass "a: 200 [] (no rule applies) still exits 0"
else
  fail "a: 200 [] should exit 0 with 'no required_status_checks rule on main' (got $VRC)"
  cat "$T/v.out" "$T/v.err"
fi

for r in oddrules oddrules2; do
  run_validator "topcoder1/$r"
  if [[ $VRC -eq 3 ]] &&
    has "$T/v.err" "API error: GET /repos/topcoder1/$r/rules/branches/main did not answer an array of rules" &&
    ! grep -q "jq: error" "$T/v.err" && api_error_only; then
    pass "a: a 200 that is not an array of rules ($r) exits 3"
  else
    fail "a: $r should exit 3 without running the filter (got $VRC)"
    cat "$T/v.out" "$T/v.err"
  fi
done

# ---------------------------------------------------------------------------
# b. The contents calls, on a private repo.
# ---------------------------------------------------------------------------
run_validator topcoder1/nolisting
if [[ $VRC -eq 3 ]] &&
  has "$T/v.err" "API error: GET /repos/topcoder1/nolisting/contents/.github/workflows failed (HTTP 403)" &&
  has "$T/v.err" "gh: Resource not accessible by personal access token (HTTP 403)" &&
  ! has "$T/v.out" "==> FAIL" && api_error_only; then
  pass "b: a 403 listing the workflows exits 3, not a finding"
else
  fail "b: a 403 on the listing should exit 3 with no verdict (got $VRC)"
  cat "$T/v.out" "$T/v.err"
fi

run_validator topcoder1/nofile
if [[ $VRC -eq 3 ]] &&
  has "$T/v.err" "API error: GET /repos/topcoder1/nofile/contents/.github/workflows/ci.yml failed (HTTP 404)" &&
  ! has "$T/v.out" "==> FAIL" && api_error_only; then
  pass "b: a 404 reading one workflow exits 3, not a finding"
else
  fail "b: a 404 on a workflow file should exit 3 with no verdict (got $VRC)"
  cat "$T/v.out" "$T/v.err"
fi

run_validator topcoder1/oddlisting
if [[ $VRC -eq 3 ]] &&
  has "$T/v.err" "API error: GET /repos/topcoder1/oddlisting/contents/.github/workflows did not answer a directory listing" &&
  api_error_only; then
  pass "b: a listing that is not a directory listing exits 3"
else
  fail "b: a non-listing answer should exit 3 (got $VRC)"
  cat "$T/v.out" "$T/v.err"
fi

echo "contents/.github/workflows none" > "$T/gh/topcoder1/ci-workflows/fail"
run_validator topcoder1/clean-a
rm "$T/gh/topcoder1/ci-workflows/fail"
if [[ $VRC -eq 3 ]] &&
  has "$T/v.err" "API error: GET /repos/topcoder1/ci-workflows/contents/.github/workflows failed (no HTTP status)" &&
  has "$T/v.err" "error connecting to api.github.com" && api_error_only; then
  pass "b: the central listing failing with no response exits 3"
else
  fail "b: a no-response failure on the central listing should exit 3 (got $VRC)"
  cat "$T/v.out" "$T/v.err"
fi

# ---------------------------------------------------------------------------
# c. A genuine missing producer.
# ---------------------------------------------------------------------------
run_validator topcoder1/phantom
if [[ $VRC -eq 1 ]] && has "$T/v.out" "✗  plan-proofs / verify" && has "$T/v.out" "✓  test" &&
  has "$T/v.out" "==> FAIL: one or more required contexts will never report on PRs."; then
  pass "c: a required check with no PR producer exits 1"
else
  fail "c: the phantom repo should exit 1 with a ✗ line (got $VRC)"
  cat "$T/v.out" "$T/v.err"
fi

# The fleet wrapper finds the validator on PATH first; pin it to this repo's.
mkdir -p "$T/vbin"
ln -s "$VALIDATOR" "$T/vbin/validate-required-checks.sh"
run_fleet() { # repos -> $FRC, $T/digest.md, $T/f.err
  FRC=0
  PATH="$T/vbin:$T/bin:$PATH" GH_FAKE="$T/gh" bash "$FLEET" --repos "$1" --out "$T/digest.md" \
    > /dev/null 2> "$T/f.err" < /dev/null || FRC=$?
}

run_fleet "topcoder1/phantom"
if [[ $FRC -eq 1 ]] &&
  has "$T/digest.md" "### topcoder1/phantom — FINDING: a required check will never report on PRs" &&
  has "$T/digest.md" "✗  plan-proofs / verify" &&
  has "$T/digest.md" "Fleet: 1 repos audited (0 clean, 1 with findings, 0 could not be audited)" &&
  ! has "$T/digest.md" "ERROR" &&
  has "$T/f.err" "audit-required-checks-fleet: FINDINGS in 1 repo(s), a required check that will never report on PRs: topcoder1/phantom" &&
  ! has "$T/f.err" "ERRORS"; then
  pass "c: the fleet wrapper files a validator exit 1 as a FINDING and exits 1"
else
  fail "c: a finding should be filed as FINDING, exit 1 (got $FRC)"
  cat "$T/digest.md" "$T/f.err"
fi

# ---------------------------------------------------------------------------
# d. The Attaxion skip, against a stub validator that logs what it was given.
# ---------------------------------------------------------------------------
mkdir -p "$T/stubbin"
cat > "$T/stubbin/validate-required-checks.sh" <<'STUB'
#!/usr/bin/env bash
echo "$1" >> "$STUB_LOG"
echo "==> Validating required status checks for $1 (branch: main)"
exit 0
STUB
chmod +x "$T/stubbin/validate-required-checks.sh"
DRC=0
PATH="$T/stubbin:$PATH" STUB_LOG="$T/stub.log" bash "$FLEET" \
  --repos "topcoder1/clean-a topcoder1/attaxion_dev topcoder1/Attaxion-Portal whois-api-llc/asm-infra-v2 topcoder1/my-attaxion-tool topcoder1/asmx" \
  --out "$T/digest-d.md" > /dev/null 2> "$T/d.err" < /dev/null || DRC=$?
expected_audited=$'topcoder1/clean-a\ntopcoder1/my-attaxion-tool\ntopcoder1/asmx'
skip_line="Skipped by name (^(asm-|attaxion)): topcoder1/attaxion_dev, topcoder1/Attaxion-Portal, whois-api-llc/asm-infra-v2."
if [[ $DRC -eq 0 && "$(cat "$T/stub.log")" == "$expected_audited" ]]; then
  pass "d: attaxion_dev, Attaxion-Portal and asm-infra-v2 are never validated; look-alikes are"
else
  fail "d: expected exactly clean-a, my-attaxion-tool, asmx validated (exit $DRC)"
  cat "$T/stub.log" "$T/d.err"
fi
if has "$T/d.err" "audit-required-checks-fleet: $skip_line" &&
  [[ "$(sed -n 1p "$T/digest-d.md")" == "All 3 repos clean. Last run: "* ]] &&
  [[ "$(sed -n 2p "$T/digest-d.md")" == "$skip_line" ]]; then
  pass "d: the skipped names are on stderr and in the digest, under an all-clean first line"
else
  fail "d: the skip should be logged and noted under 'All 3 repos clean.'"
  cat "$T/digest-d.md" "$T/d.err"
fi
DRC=0
PATH="$T/stubbin:$PATH" STUB_LOG="$T/stub-all.log" bash "$FLEET" \
  --repos "topcoder1/attaxion_dev whois-api-llc/asm-infra-v2" \
  > /dev/null 2> "$T/d.err" < /dev/null || DRC=$?
if [[ $DRC -eq 2 && ! -e "$T/stub-all.log" ]] && has "$T/d.err" "no repo left to audit"; then
  pass "d: a list that is all Attaxion exits 2, never 'All 0 repos clean'"
else
  fail "d: skipping every repo should exit 2 (got $DRC)"
  cat "$T/d.err"
fi

# ---------------------------------------------------------------------------
# e. Nothing but a finding exits 1.
# ---------------------------------------------------------------------------
# The Python block on its own, with its contexts file missing: an uncaught
# exception wherever it happens must exit 4.
awk '/^python3 - <<.PY. /{f=1; next} /^PY$/{f=0} f' "$VALIDATOR" > "$T/block.py"
if ! grep -q "for ctx in contexts" "$T/block.py"; then
  fail "e: could not extract the validator's Python block"
else
  PRC=0
  TMP="$T" CONTEXTS_FILE="$T/does-not-exist" STRICT=0 python3 - < "$T/block.py" \
    > /dev/null 2> "$T/p.err" || PRC=$?
  if [[ $PRC -eq 4 ]] && has "$T/p.err" "Traceback" && has "$T/p.err" "FileNotFoundError"; then
    pass "e: an uncaught Python exception exits 4"
  else
    fail "e: an uncaught Python exception should exit 4 (got $PRC)"
    cat "$T/p.err"
  fi
fi

mkdir -p "$T/badtmp"
printf '#!/bin/sh\necho "mktemp: cannot create temp dir" >&2\nexit 1\n' > "$T/badtmp/mktemp"
chmod +x "$T/badtmp/mktemp"
VRC=0
PATH="$T/badtmp:$T/bin:$PATH" GH_FAKE="$T/gh" bash "$VALIDATOR" topcoder1/clean-a \
  > "$T/v.out" 2> "$T/v.err" < /dev/null || VRC=$?
if [[ $VRC -eq 4 ]] && has "$T/v.err" "internal error: a command failed unexpectedly (exit 1, line"; then
  pass "e: a command failing with 1 unexpectedly exits 4"
else
  fail "e: an unexpected failure should exit 4 (got $VRC)"
  cat "$T/v.out" "$T/v.err"
fi

run_validator topcoder1/clean-a --branch
if [[ $VRC -eq 2 ]] && has "$T/v.err" "--branch needs a value"; then
  pass "e: --branch with no value exits 2, not set -u's 1"
else
  fail "e: --branch with no value should exit 2 (got $VRC)"
  cat "$T/v.out" "$T/v.err"
fi

# ---------------------------------------------------------------------------
# f. Clean + finding + error through the fleet wrapper, then the workflow's
#    digest step on its output.
# ---------------------------------------------------------------------------
run_fleet "topcoder1/clean-a topcoder1/phantom topcoder1/badtoken"
if [[ $FRC -eq 3 ]] &&
  has "$T/digest.md" "Fleet: 3 repos audited (1 clean, 1 with findings, 1 could not be audited)" &&
  has "$T/digest.md" "### topcoder1/phantom — FINDING: a required check will never report on PRs" &&
  has "$T/digest.md" "### topcoder1/badtoken — ERROR: not audited (exit 3: GitHub API error)" &&
  has "$T/digest.md" "gh: Bad credentials (HTTP 401)" &&
  ! has "$T/digest.md" "### topcoder1/clean-a" &&
  has "$T/f.err" "audit-required-checks-fleet: FINDINGS in 1 repo(s), a required check that will never report on PRs: topcoder1/phantom" &&
  has "$T/f.err" "audit-required-checks-fleet: ERRORS: 1 repo(s) could not be audited: topcoder1/badtoken (exit 3: GitHub API error)"; then
  pass "f: a finding and an error get distinct headings, and the wrapper exits 3"
else
  fail "f: expected FINDING + ERROR headings, counts, no clean block, exit 3 (got $FRC)"
  cat "$T/digest.md" "$T/f.err"
fi
cp "$T/digest.md" "$T/mixed.md"

run_fleet "topcoder1/clean-a topcoder1/norules"
if [[ $FRC -eq 0 && "$(sed -n 1p "$T/digest.md")" == "All 2 repos clean. Last run: "* ]] &&
  [[ $(wc -l < "$T/digest.md") -eq 1 ]]; then
  pass "f: clean repos exit 0 and write only the all-clean line"
else
  fail "f: an all-clean run should exit 0 with one 'All 2 repos clean.' line (got $FRC)"
  cat "$T/digest.md" "$T/f.err"
fi
cp "$T/digest.md" "$T/clean.md"

extract_run() { # workflow, step name -> that step's run block
  awk -v name="      - name: $2" '
    $0 == name { in_step = 1; next }
    in_step && /^      - name: / { exit }
    in_step && /^        run: \|/ { in_run = 1; next }
    in_run {
      if ($0 ~ /^          / || $0 == "") { sub(/^          /, ""); print }
      else { exit }
    }
  ' "$1"
}
extract_run "$WORKFLOW" "Combine per-org digests + decide whether to open issue" > "$T/combine.sh"
if ! grep -q "needs_issue" "$T/combine.sh"; then
  fail "f: could not extract the workflow's digest step"
else
  needs_issue() { # topcoder1 digest, whois-api-llc digest -> the step's verdict
    local d="$T/combine-run"
    rm -rf "$d" && mkdir -p "$d"
    cp "$1" "$d/per-org-digest-topcoder1.md"
    cp "$2" "$d/per-org-digest-whois-api-llc.md"
    (cd "$d" && GITHUB_OUTPUT="$d/out" bash "$T/combine.sh" > /dev/null)
    sed -n 's/^needs_issue=//p' "$d/out"
  }
  if [[ "$(needs_issue "$T/clean.md" "$T/clean.md")" == no &&
    "$(needs_issue "$T/clean.md" "$T/digest-d.md")" == no &&
    "$(needs_issue "$T/mixed.md" "$T/clean.md")" == yes ]]; then
    pass "f: the digest step opens the issue for a finding, not for clean runs (skip note included)"
  else
    fail "f: needs_issue should be no/no/yes for clean, clean+skip, finding"
  fi
fi

# ---------------------------------------------------------------------------
# Negative controls: the old code, verbatim from origin/main at bd86424
# (scripts/validate-required-checks.sh lines 61-72, 94-95, 97-98), in its own
# bash process under the old script's `set -euo pipefail`, against the same
# shim answers. (A function in this script would run with -e ignored, since
# every call here sits left of a `||`.)
# ---------------------------------------------------------------------------
cat > "$T/old.sh" <<'OLD'
set -euo pipefail
case "$1" in
  rules)
    REPO="$2" BRANCH=main RULESET_NAME_GLOB="main-protection*"
    RULESET_DATA=$(gh api "/repos/$REPO/rules/branches/$BRANCH" 2>/dev/null || true)
    if [[ -z "$RULESET_DATA" || "$RULESET_DATA" == "null" ]]; then
      echo "  no branch rules found for $BRANCH" >&2
      exit 0
    fi
    CONTEXTS=$(echo "$RULESET_DATA" | jq -r \
      --arg glob "$RULESET_NAME_GLOB" \
      '.[]
       | select(.type=="required_status_checks")
       | select((.ruleset_source_type // "") | ascii_downcase == "repository" or true)
       | .parameters.required_status_checks[]?.context' \
      | sort -u)
    echo "$CONTEXTS" ;;
  listing)
    repo="$2"
    listing=$(gh api "/repos/$repo/contents/.github/workflows" 2>/dev/null || echo '[]')
    echo "$listing" | jq -r '.[]? | select(.name | endswith(".yml") or endswith(".yaml")) | .name' | while read -r f; do
      echo "$f"
    done ;;
  file)
    repo="$2" f="$3" out_dir="$4"
    gh api "/repos/$repo/contents/.github/workflows/$f" --jq '.content' 2>/dev/null \
      | base64 -d > "$out_dir/$f" || true ;;
esac
OLD
old() { PATH="$T/bin:$PATH" GH_FAKE="$T/gh" bash "$T/old.sh" "$@" < /dev/null; }

NRC=0
old rules topcoder1/badtoken > /dev/null 2> "$T/n1.err" || NRC=$?
if [[ $NRC -eq 5 ]] && has "$T/n1.err" 'jq: error (at <stdin>:5): Cannot index string with string "type"'; then
  pass "n1: the old rules fetch dies with run 38234284948's jq exit 5 on the same 401"
else
  fail "n1: the old rules fetch should reproduce jq exit 5 (got $NRC)"
  cat "$T/n1.err"
fi

NRC=0
old rules topcoder1/offline > /dev/null 2> "$T/n4.err" || NRC=$?
if [[ $NRC -eq 0 ]] && has "$T/n4.err" "no branch rules found for main"; then
  pass "n4: the old rules fetch passed a repo it never reached as 'no branch rules found' (rc 0)"
else
  fail "n4: the old rules fetch should read no response as no rules (got $NRC)"
  cat "$T/n4.err"
fi

NRC=0
old listing topcoder1/nolisting > "$T/n2.out" 2> /dev/null || NRC=$?
if [[ $NRC -eq 0 && ! -s "$T/n2.out" ]]; then
  pass "n2: the old listing fetch read the 403 as an empty workflow directory (rc 0)"
else
  fail "n2: the old listing fetch should swallow the 403 (got rc $NRC)"
  cat "$T/n2.out"
fi

mkdir -p "$T/old-target"
NRC=0
old file topcoder1/nofile ci.yml "$T/old-target" > /dev/null 2>&1 || NRC=$?
if [[ $NRC -eq 0 && -f "$T/old-target/ci.yml" && ! -s "$T/old-target/ci.yml" ]]; then
  pass "n3: the old per-file fetch turned the 404 into an empty ci.yml (rc 0)"
else
  fail "n3: the old per-file fetch should swallow the 404 (got rc $NRC)"
fi

echo
if [[ $failed -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "all audit exit-code cases pass"
