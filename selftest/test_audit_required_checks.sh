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
#      the central listing with no response; a listing that is not one; a
#      file answer that is not base64 content) => exit 3, with no verdict
#      lines, no FAIL line and none of the answer's bytes; no gh call uses
#      --jq. A repo with no .github/workflows (listing 404) is audited when
#      its root listing is readable (a finding), and exits 3 when that 404s
#      too
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
#   g  against stub validators: exits 4 and 5 are ERRORs worded "validator
#      crashed" and "unexpected exit code"; exit 1 is a FINDING only with the
#      `==> FAIL` verdict, so an unbound variable or a SyntaxError (both exit
#      1) is an ERROR; and malformed answers reach the digest, a PUBLIC issue,
#      as API errors carrying none of their bytes
#   h  the rules call reads every page (2026-10-17): a required_status_checks
#      rule as rule 31 (past the 30 an unpaginated call read) or rule 101
#      (past a page of 100) is validated, in both forms gh --paginate prints;
#      a bad rule on page 1 of 2, a page 2 that is not a list, and a page 2
#      that fails each exit 3, echoing none of the answer
#   i  --branch and workflow file names go into the URL percent-encoded, `/`
#      kept (2026-10-17): a file name with `#`, `?`, `%` or a space is read as
#      that file, a branch with `#` or `%41` is read as that branch, and an
#      API error names the endpoint as it was sent
# Negative controls (the shim reproduces each old failure, run verbatim):
#   n1 the old rules fetch + filter dies with jq exit 5 on case a's 401
#   n4 the old rules fetch reads case a's no-response failure as "no branch
#      rules found" and exits 0: a repo it never reached passes as clean
#   n2 the old listing fetch reads case b's 403 as zero workflow names
#   n3 the old per-file fetch turns case b's 404 into an empty workflow file
# Shim controls: cases h and i tell the fix from the bug only while the shim
# reads a request as gh and GitHub do, so these pin it on the requests the
# validator sent before them (the rules call without --paginate, each value
# as it was given) and on both forms --paginate prints:
#   s1 the rules answer comes 30 rules a page, and per_page and page select
#   s2 --paginate prints every page, as one array or as an array per page
#   s3 explicit page bytes print as given, a failing page included
#   s4 an unencoded `#`, `?` or bad `%` reads another file or fails in gh,
#      and an unencoded branch reads another branch's rules
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
# Failure diagnostics. Never fatal: under set -e a dump with nothing to show
# (a grep without a match, a file the failed run never wrote) would end the
# run and hide every check after it.
show() { cat -- "$@" 2>/dev/null || true; }

# ---------------------------------------------------------------------------
# The shim. One fake repo per directory; `fail` holds "<rest> <status>" lines
# (<rest> is the endpoint after /repos/<owner>/<repo>/ in the request gh
# sends, query string included), `listing.json`, when present, replaces the
# generated directory listing, and `answers/<file>` replaces a workflow file's
# contents answer. With a `branch-rules/` directory, each branch's rules are
# in branch-rules/<branch>/rules.json and any other branch has none;
# `pages_apart` prints a --paginate rules answer as an array per page; and
# `rule-pages/<n>.json` holds the bytes gh prints for page <n> of the rules
# answer, or `<n>.fail` the status that page fails with. Every call is
# logged. Like gh, it applies a --jq filter itself, and a filter that fails
# prints part of the response in its error (measured 2026-10-16, gh 2.97.0:
# `expected an object but got: array ([{"_links":{"git":"https: ...])`).
#
# It reads an endpoint the way gh 2.97.0 and GitHub did, measured 2026-10-16
# on topcoder1/dotclaude and against a local server, and 2026-10-17 on this
# repo. gh parses the endpoint as a URL. It never sends a #fragment
# (`rules/branches/main#x` read main's rules), and a % in the path that starts
# no %XX escape fails in gh before anything is sent (`invalid URL escape
# "%zz"`, rc 1). GitHub decodes %XX in the path (`rules/branches/ma%69n` read
# main's rules) and in the query, where `&` starts the next parameter and a
# parameter with a bad % is dropped. It pages the rules answer, 30 rules a
# page unless per_page asks for up to 100. gh --paginate asks for 100 unless
# the endpoint names a per_page, follows every next page, and prints the pages
# of an array as one array, the `]` only after the last page (a null page 2
# printed `[{"type":"deletion"}null`, rc 0; a 403 on page 2 printed page 1,
# then the error body, rc 1). gh's help instead describes an array per page,
# the form `pages_apart` gives.
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
url="${2%%#*}"
bad_escape='%($|[^0-9A-Fa-f]|[0-9A-Fa-f]($|[^0-9A-Fa-f]))'
if grep -Eq "$bad_escape" <<< "${url%%\?*}"; then
  echo "parse \"https://api.github.com/${url#/}\": invalid URL escape" >&2
  exit 1
fi
ep="${url#/}"
ep="${ep#repos/}"
owner="${ep%%/*}"
ep="${ep#*/}"
repo="${ep%%/*}"
rest="${ep#*/}"
dir="$GH_FAKE/$owner/$repo"
filter=""
paginate=no
prev=""
for a in "$@"; do
  if [ "$prev" = "--jq" ]; then filter="$a"; fi
  if [ "$a" = --paginate ]; then paginate=yes; fi
  prev="$a"
done
pct_decode() { printf '%b' "${1//%/\\x}"; }
path=$(pct_decode "${rest%%\?*}")
per_page="" page=1
case "$rest" in
  *\?*) query="${rest#*\?}" ;;
  *) query="" ;;
esac
while [ -n "$query" ]; do
  param="${query%%&*}"
  case "$query" in
    *'&'*) query="${query#*&}" ;;
    *) query="" ;;
  esac
  if grep -Eq "$bad_escape" <<< "$param"; then continue; fi
  case "$param" in
    per_page=*) per_page=$(pct_decode "${param#*=}") ;;
    page=*) page=$(pct_decode "${param#*=}") ;;
  esac
done
if [ -z "$per_page" ]; then
  if [ "$paginate" = yes ]; then per_page=100; else per_page=30; fi
fi
respond() { # the answer on stdin -> stdout, through --jq when one was given
  local body
  body=$(cat)
  if [ -z "$filter" ]; then
    printf '%s\n' "$body"
    return
  fi
  if ! printf '%s' "$body" | jq -r "$filter" 2>/dev/null; then
    echo "expected an object but got: $(printf '%s' "$body" | jq -r type 2>/dev/null) (${body:0:30} ...)" >&2
    exit 1
  fi
}
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
serve_rules() { # rules file -> the rules answer, paged
  local n from total
  if [ -d "$dir/rule-pages" ]; then
    # Page after page, as given; with --paginate, up to the first page that
    # fails, which ends the call with that page's error.
    n="$page"
    while :; do
      if [ -f "$dir/rule-pages/$n.fail" ]; then
        fail_with "$(cat "$dir/rule-pages/$n.fail")"
      fi
      cat "$dir/rule-pages/$n.json"
      n=$((n + 1))
      if [ "$paginate" = no ]; then break; fi
      if [ ! -f "$dir/rule-pages/$n.json" ] && [ ! -f "$dir/rule-pages/$n.fail" ]; then
        break
      fi
    done
    return
  fi
  if ! jq -e 'type == "array"' "$1" > /dev/null 2>&1; then
    cat "$1" # not a list: nothing to page
    return
  fi
  case "$per_page" in '' | *[!0-9]*) per_page=30 ;; esac
  case "$page" in '' | *[!0-9]*) page=1 ;; esac
  if [ "$per_page" -gt 100 ]; then per_page=100; fi
  from=$(((page - 1) * per_page))
  if [ "$paginate" = no ]; then
    jq -c --argjson from "$from" --argjson n "$per_page" '.[$from:$from + $n]' "$1"
  elif [ -f "$dir/pages_apart" ]; then
    total=$(jq length "$1")
    while :; do
      jq -jc --argjson from "$from" --argjson n "$per_page" '.[$from:$from + $n]' "$1"
      from=$((from + per_page))
      if [ "$from" -ge "$total" ]; then break; fi
    done
  else
    jq -c --argjson from "$from" '.[$from:]' "$1"
  fi
}
case "$path" in
  rules/branches/*)
    branch="${path#rules/branches/}"
    if [ ! -d "$dir/branch-rules" ]; then
      serve_rules "$dir/rules.json"
    elif [ -f "$dir/branch-rules/$branch/rules.json" ]; then
      serve_rules "$dir/branch-rules/$branch/rules.json"
    else
      echo '[]'
    fi ;;
  contents)
    echo '[{"name":"README.md","type":"file"}]' | respond ;;
  contents/.github/workflows)
    [ -d "$dir/workflows" ] || fail_with 404
    if [ -f "$dir/listing.json" ]; then
      respond < "$dir/listing.json"
    else
      (cd "$dir/workflows" && ls) | jq -R . | jq -s 'map({name: ., type: "file"})' | respond
    fi ;;
  contents/.github/workflows/*)
    name="${path#contents/.github/workflows/}"
    if [ -f "$dir/answers/$name" ]; then
      respond < "$dir/answers/$name"
    else
      f="$dir/workflows/$name"
      [ -f "$f" ] || fail_with 404
      jq -n --arg n "$name" --arg c "$(base64 < "$f")" \
        '{type: "file", name: $n, encoding: "base64", content: $c}' | respond
    fi ;;
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
rules_after() { # count, required contexts... -> a rules answer: count rules
  # that require no check, then a required_status_checks rule listing the
  # contexts, rule count + 1
  jq -nc --argjson n "$1" '
    [range(1; $n + 1)
     | {type: "deletion", ruleset_source_type: "Repository", ruleset_source: "o/r", ruleset_id: .}]
    + [{type: "required_status_checks",
        parameters: {strict_required_status_checks_policy: false, do_not_enforce_on_create: false,
                     required_status_checks: [$ARGS.positional[] | {context: .}]},
        ruleset_source_type: "Repository", ruleset_source: "o/r", ruleset_id: ($n + 1)}]' \
    --args "${@:2}"
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
# Each malformed answer carries a canary: the digest is a PUBLIC issue, so an
# error must name the endpoint and the status, never echo the response.
fake_repo topcoder1/oddrules '{"message":"not a list","leak":"PRIVATE-BODY-CANARY-rules"}' ci.yml
fake_repo topcoder1/oddrules2 '["PRIVATE-BODY-CANARY-rules2"]' ci.yml
fake_repo topcoder1/nolisting "$(rules_json test)" ci.yml
echo "contents/.github/workflows 403" > "$T/gh/topcoder1/nolisting/fail"
fake_repo topcoder1/nofile "$(rules_json test)" ci.yml
echo "contents/.github/workflows/ci.yml 404" > "$T/gh/topcoder1/nofile/fail"
fake_repo topcoder1/oddlisting "$(rules_json test)" ci.yml
echo '{"name":"workflows","type":"file","content":"PRIVATE-BODY-CANARY-listing"}' > "$T/gh/topcoder1/oddlisting/listing.json"
fake_repo topcoder1/emptylisting "$(rules_json test)" ci.yml
echo '{}' > "$T/gh/topcoder1/emptylisting/listing.json"
fake_repo topcoder1/noworkflows "$(rules_json test)"
rmdir "$T/gh/topcoder1/noworkflows/workflows"
fake_repo topcoder1/nocontents "$(rules_json test)"
rmdir "$T/gh/topcoder1/nocontents/workflows"
echo "contents 404" > "$T/gh/topcoder1/nocontents/fail"
answer() { # owner/repo, workflow file, contents answer
  mkdir -p "$T/gh/$1/answers"
  printf '%s\n' "$3" > "$T/gh/$1/answers/$2"
}
fake_repo topcoder1/notbase64 "$(rules_json test)" ci.yml
answer topcoder1/notbase64 ci.yml '{"type":"file","name":"ci.yml","encoding":"base64","content":"PRIVATE-BODY-CANARY not base64!"}'
fake_repo topcoder1/notafile "$(rules_json test)" ci.yml
answer topcoder1/notafile ci.yml '[{"name":"PRIVATE-BODY-CANARY-dir","type":"file"}]'
fake_repo topcoder1/bigfile "$(rules_json test)" ci.yml
answer topcoder1/bigfile ci.yml '{"type":"file","name":"ci.yml","encoding":"none","content":""}'
# Base64-alphabet characters in no valid shape: macOS base64 -d exits 0 on
# both and writes nothing (measured 2026-10-16), an empty workflow.
fake_repo topcoder1/badpadding "$(rules_json test)" ci.yml
answer topcoder1/badpadding ci.yml '{"type":"file","name":"ci.yml","encoding":"base64","content":"===="}'
fake_repo topcoder1/shortb64 "$(rules_json test)" ci.yml
answer topcoder1/shortb64 ci.yml '{"type":"file","name":"ci.yml","encoding":"base64","content":"A"}'

run_validator() { # repo [flags...] -> $VRC, $T/v.out, $T/v.err
  VRC=0
  PATH="$T/bin:$PATH" GH_FAKE="$T/gh" bash "$VALIDATOR" "$@" \
    > "$T/v.out" 2> "$T/v.err" < /dev/null || VRC=$?
}
api_error_only() { # stopped on the API error: judged nothing, claimed no crash
  ! grep -qE '✗|✓|==> (FAIL|OK)|internal error' "$T/v.out" "$T/v.err"
}
no_body_bytes() { # no byte of a malformed answer reached the output
  ! grep -q "PRIVATE-BODY-CANARY" "$T/v.out" "$T/v.err"
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
  show "$T/v.out" "$T/v.err"
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
  show "$T/v.out" "$T/v.err"
fi
if has "$T/gh/calls.log" "api /repos/topcoder1/badtoken/rules/branches/main" &&
  ! grep -q "contents" "$T/gh/calls.log"; then
  pass "a: the 401 reached the validator, which stopped before any contents call"
else
  fail "a: expected exactly the rules call in the shim log"
  show "$T/gh/calls.log"
fi

run_validator topcoder1/gone
if [[ $VRC -eq 3 ]] &&
  has "$T/v.err" "API error: GET /repos/topcoder1/gone/rules/branches/main failed (HTTP 404)" &&
  has "$T/v.err" "a 404 is also what a private repo answers to a token that cannot see it" &&
  api_error_only; then
  pass "a: a 404 on the rules call exits 3, not 'no rules'"
else
  fail "a: a 404 on the rules call should exit 3 (got $VRC)"
  show "$T/v.out" "$T/v.err"
fi

run_validator topcoder1/offline
if [[ $VRC -eq 3 ]] &&
  has "$T/v.err" "API error: GET /repos/topcoder1/offline/rules/branches/main failed (no HTTP status)" &&
  has "$T/v.err" "error connecting to api.github.com" && api_error_only; then
  pass "a: a rules call with no response exits 3, not 'no branch rules found'"
else
  fail "a: a rules call with no response should exit 3 (got $VRC)"
  show "$T/v.out" "$T/v.err"
fi

run_validator topcoder1/norules
if [[ $VRC -eq 0 ]] && has "$T/v.out" "no required_status_checks rule on main"; then
  pass "a: 200 [] (no rule applies) still exits 0"
else
  fail "a: 200 [] should exit 0 with 'no required_status_checks rule on main' (got $VRC)"
  show "$T/v.out" "$T/v.err"
fi

for r in oddrules oddrules2; do
  run_validator "topcoder1/$r"
  if [[ $VRC -eq 3 ]] &&
    has "$T/v.err" "API error: GET /repos/topcoder1/$r/rules/branches/main did not answer an array of rules" &&
    ! grep -q "jq: error" "$T/v.err" && api_error_only && no_body_bytes; then
    pass "a: a 200 that is not an array of rules ($r) exits 3 and echoes none of it"
  else
    fail "a: $r should exit 3 without running the filter (got $VRC)"
    show "$T/v.out" "$T/v.err"
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
  show "$T/v.out" "$T/v.err"
fi

run_validator topcoder1/nofile
if [[ $VRC -eq 3 ]] &&
  has "$T/v.err" "API error: GET /repos/topcoder1/nofile/contents/.github/workflows/ci.yml failed (HTTP 404)" &&
  ! has "$T/v.out" "==> FAIL" && api_error_only; then
  pass "b: a 404 reading one workflow exits 3, not a finding"
else
  fail "b: a 404 on a workflow file should exit 3 with no verdict (got $VRC)"
  show "$T/v.out" "$T/v.err"
fi

# A file's object, and `{}`: `.[]` over `{}` yields nothing, which would read
# as an empty directory and so as a missing producer.
for r in oddlisting emptylisting; do
  run_validator "topcoder1/$r"
  if [[ $VRC -eq 3 ]] &&
    has "$T/v.err" "API error: GET /repos/topcoder1/$r/contents/.github/workflows did not answer a directory listing" &&
    api_error_only && no_body_bytes; then
    pass "b: a listing that is not a directory listing ($r) exits 3 and echoes none of it"
  else
    fail "b: a non-listing answer ($r) should exit 3 (got $VRC)"
    show "$T/v.out" "$T/v.err"
  fi
done

# A workflow file's answer must be base64 file content: invalid base64 (stray
# characters, or alphabet characters in no valid shape), an array (a
# directory under that name) and `encoding: none` (a file over 1 MB has no
# inline content) exit 3, and echo none of the answer.
for r in notbase64 badpadding shortb64 notafile bigfile; do
  run_validator "topcoder1/$r"
  if [[ $VRC -eq 3 ]] &&
    has "$T/v.err" "API error: GET /repos/topcoder1/$r/contents/.github/workflows/ci.yml did not answer base64 file content" &&
    api_error_only && no_body_bytes; then
    pass "b: a workflow file answer that is not base64 content ($r) exits 3 and echoes none of it"
  else
    fail "b: $r should exit 3 without echoing the answer (got $VRC)"
    show "$T/v.out" "$T/v.err"
  fi
done

# No gh call may pass --jq: a failing filter prints part of the response in
# gh's own error, which api_get would relay to the public digest.
: > "$T/gh/calls.log"
run_validator topcoder1/clean-a
if [[ $VRC -eq 0 ]] && has "$T/gh/calls.log" "api /repos/topcoder1/clean-a/contents/.github/workflows/ci.yml" &&
  ! grep -q -- "--jq" "$T/gh/calls.log"; then
  pass "b: no gh api call uses --jq (the file read is in the log; no filter is)"
else
  fail "b: the validator should read every answer without gh --jq"
  show "$T/gh/calls.log"
fi

# No .github/workflows: the listing answers 404, which a private repo also
# answers to a token that cannot read its contents. The directory counts as
# absent only once the root listing proves this token can read them.
run_validator topcoder1/noworkflows
if [[ $VRC -eq 1 ]] && has "$T/v.out" "topcoder1/noworkflows has no .github/workflows directory" &&
  has "$T/v.out" "✗  test" && ! grep -q "API error" "$T/v.err"; then
  pass "b: no workflows directory (contents readable) is audited: its required check is a finding"
else
  fail "b: an absent workflows directory should exit 1 with a ✗ (got $VRC)"
  show "$T/v.out" "$T/v.err"
fi
run_validator topcoder1/nocontents
if [[ $VRC -eq 3 ]] &&
  has "$T/v.err" "API error: GET /repos/topcoder1/nocontents/contents failed (HTTP 404)" &&
  api_error_only; then
  pass "b: a 404 listing with an unreadable root exits 3, never a finding"
else
  fail "b: a 404 listing plus an unreadable root should exit 3 (got $VRC)"
  show "$T/v.out" "$T/v.err"
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
  show "$T/v.out" "$T/v.err"
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
  show "$T/v.out" "$T/v.err"
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
  show "$T/digest.md" "$T/f.err"
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
  show "$T/stub.log" "$T/d.err"
fi
if has "$T/d.err" "audit-required-checks-fleet: $skip_line" &&
  [[ "$(sed -n 1p "$T/digest-d.md")" == "All 3 repos clean. Last run: "* ]] &&
  [[ "$(sed -n 2p "$T/digest-d.md")" == "$skip_line" ]]; then
  pass "d: the skipped names are on stderr and in the digest, under an all-clean first line"
else
  fail "d: the skip should be logged and noted under 'All 3 repos clean.'"
  show "$T/digest-d.md" "$T/d.err"
fi
DRC=0
PATH="$T/stubbin:$PATH" STUB_LOG="$T/stub-all.log" bash "$FLEET" \
  --repos "topcoder1/attaxion_dev whois-api-llc/asm-infra-v2" \
  > /dev/null 2> "$T/d.err" < /dev/null || DRC=$?
if [[ $DRC -eq 2 && ! -e "$T/stub-all.log" ]] && has "$T/d.err" "no repo left to audit"; then
  pass "d: a list that is all Attaxion exits 2, never 'All 0 repos clean'"
else
  fail "d: skipping every repo should exit 2 (got $DRC)"
  show "$T/d.err"
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
    show "$T/p.err"
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
  show "$T/v.out" "$T/v.err"
fi

run_validator topcoder1/clean-a --branch
if [[ $VRC -eq 2 ]] && has "$T/v.err" "--branch needs a value"; then
  pass "e: --branch with no value exits 2, not set -u's 1"
else
  fail "e: --branch with no value should exit 2 (got $VRC)"
  show "$T/v.out" "$T/v.err"
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
  show "$T/digest.md" "$T/f.err"
fi
cp "$T/digest.md" "$T/mixed.md"

run_fleet "topcoder1/clean-a topcoder1/norules"
if [[ $FRC -eq 0 && "$(sed -n 1p "$T/digest.md")" == "All 2 repos clean. Last run: "* ]] &&
  [[ $(wc -l < "$T/digest.md") -eq 1 ]]; then
  pass "f: clean repos exit 0 and write only the all-clean line"
else
  fail "f: an all-clean run should exit 0 with one 'All 2 repos clean.' line (got $FRC)"
  show "$T/digest.md" "$T/f.err"
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
# g. How the fleet wrapper files each exit code, against stub validators: a 4
#    and a 5 are ERRORs with their own wording; an exit 1 is a FINDING only
#    with the validator's `==> FAIL` verdict (bash exits 1 on an unbound
#    variable under set -u, Python on a SyntaxError); and no byte of a
#    malformed answer reaches the digest, which is posted in a public repo.
# ---------------------------------------------------------------------------
mkdir -p "$T/stubbin2"
cat > "$T/stubbin2/validate-required-checks.sh" <<'STUB'
#!/usr/bin/env bash
echo "==> Validating required status checks for $1 (branch: main)"
case "${1#*/}" in
  ok-*) exit 0 ;;
  find-*)
    echo "    ✗  plan-proofs / verify"
    echo "==> FAIL: one or more required contexts will never report on PRs."
    exit 1 ;;
  crash-*)
    echo "Traceback (most recent call last):" >&2
    echo "ValueError: not enough values to unpack (expected 4, got 3)" >&2
    exit 4 ;;
  weird-*)
    echo 'jq: error (at <stdin>:5): Cannot index string with string "type"' >&2
    exit 5 ;;
  unbound-*)
    echo "validate-required-checks.sh: line 80: BRANCH: unbound variable" >&2
    exit 1 ;;
  syntax-*)
    echo "SyntaxError: invalid syntax" >&2
    exit 1 ;;
esac
echo "stub: no behavior for $1" >&2
exit 99
STUB
chmod +x "$T/stubbin2/validate-required-checks.sh"
run_stub_fleet() { # repos -> $SRC, $T/digest-g.md, $T/g.err
  SRC=0
  PATH="$T/stubbin2:$PATH" bash "$FLEET" --repos "$1" --out "$T/digest-g.md" \
    > /dev/null 2> "$T/g.err" < /dev/null || SRC=$?
}

run_stub_fleet "topcoder1/ok-a topcoder1/crash-b topcoder1/weird-c"
if [[ $SRC -eq 3 ]] &&
  has "$T/digest-g.md" "Fleet: 3 repos audited (1 clean, 0 with findings, 2 could not be audited)" &&
  has "$T/digest-g.md" "### topcoder1/crash-b — ERROR: not audited (exit 4: validator crashed)" &&
  has "$T/digest-g.md" "### topcoder1/weird-c — ERROR: not audited (exit 5: unexpected exit code)" &&
  ! has "$T/digest-g.md" "### topcoder1/ok-a" &&
  has "$T/g.err" "audit-required-checks-fleet: ERRORS: 2 repo(s) could not be audited: topcoder1/crash-b (exit 4: validator crashed), topcoder1/weird-c (exit 5: unexpected exit code)"; then
  pass "g: validator exits 4 and 5 are ERRORs (validator crashed / unexpected exit code), and the wrapper exits 3"
else
  fail "g: exits 4 and 5 should be filed as ERRORs with exit 3 (got $SRC)"
  show "$T/digest-g.md" "$T/g.err"
fi

run_stub_fleet "topcoder1/unbound-a topcoder1/syntax-b topcoder1/find-c"
if [[ $SRC -eq 3 ]] &&
  has "$T/digest-g.md" "Fleet: 3 repos audited (0 clean, 1 with findings, 2 could not be audited)" &&
  has "$T/digest-g.md" "### topcoder1/unbound-a — ERROR: not audited (exit 1: no FAIL verdict in the output)" &&
  has "$T/digest-g.md" "### topcoder1/syntax-b — ERROR: not audited (exit 1: no FAIL verdict in the output)" &&
  has "$T/digest-g.md" "### topcoder1/find-c — FINDING: a required check will never report on PRs" &&
  ! has "$T/digest-g.md" "### topcoder1/unbound-a — FINDING" &&
  ! has "$T/digest-g.md" "### topcoder1/syntax-b — FINDING" &&
  has "$T/g.err" "audit-required-checks-fleet: FINDINGS in 1 repo(s), a required check that will never report on PRs: topcoder1/find-c" &&
  has "$T/g.err" "audit-required-checks-fleet: ERRORS: 2 repo(s) could not be audited: topcoder1/unbound-a (exit 1: no FAIL verdict in the output), topcoder1/syntax-b (exit 1: no FAIL verdict in the output)"; then
  pass "g: exit 1 is a FINDING only with the FAIL verdict; an unbound variable or a SyntaxError is an ERROR"
else
  fail "g: exit 1 without '==> FAIL' should be an ERROR, with it a FINDING (got $SRC)"
  show "$T/digest-g.md" "$T/g.err"
fi

run_fleet "topcoder1/oddrules topcoder1/oddlisting topcoder1/notbase64 topcoder1/notafile"
if [[ $FRC -eq 3 ]] &&
  [[ $(grep -c "— ERROR: not audited (exit 3: GitHub API error)" "$T/digest.md") -eq 4 ]] &&
  ! grep -q "PRIVATE-BODY-CANARY" "$T/digest.md" "$T/f.err"; then
  pass "g: four malformed answers reach the digest as ERRORs naming the endpoint, with none of their bytes"
else
  fail "g: the digest should hold 4 API errors and no answer bytes (got $FRC)"
  grep -n "PRIVATE-BODY-CANARY" "$T/digest.md" "$T/f.err" || true
fi

# ---------------------------------------------------------------------------
# h. The rules call reads every page. The endpoint pages its answer, 30 rules
#    a page unless per_page asks for up to 100, and the required_status_checks
#    rule can be on any page. Read without --paginate, one past page 1 was
#    never seen, and the branch passed as having no required checks, exit 0,
#    even with a required context that has no producer. Each case runs in
#    both forms --paginate output takes: gh 2.97.0 prints the pages of an
#    array as one array, and gh's help describes an array per page.
# ---------------------------------------------------------------------------
# Rule 31 is past the 30 rules an unpaginated call reads; rule 101 is past
# the first page of 100 that --paginate asks for.
for rule_no in 31 101; do
  for form in one-array array-per-page; do
    r="topcoder1/rule$rule_no-$form"
    fake_repo "$r" "$(rules_after $((rule_no - 1)) test "plan-proofs / verify")" ci.yml
    if [[ $form == array-per-page ]]; then touch "$T/gh/$r/pages_apart"; fi
    run_validator "$r"
    if [[ $VRC -eq 1 ]] && has "$T/v.out" "found 2 required context(s):" &&
      has "$T/v.out" "✓  test" && has "$T/v.out" "✗  plan-proofs / verify"; then
      pass "h: a required check rule as rule $rule_no is read and validated ($form)"
    else
      fail "h: rule $rule_no ($form) should be read and its phantom found, exit 1 (got $VRC)"
      show "$T/v.out" "$T/v.err"
    fi
  done
done

# Printed as an array per page, the answer is several JSON values, and jq
# goes by the last one only, in `jq -e` and in its exit status alike (jq
# 1.7.1, measured 2026-10-17: an error on an earlier input still exits 0).
# Unmerged, a rule that is not an object on page 1 of 2 read as a clean pass;
# it must fail the answer as it does when there is one page.
fake_repo topcoder1/badpage "$(rules_after 100 test | jq -c '.[0] = "PRIVATE-BODY-CANARY-badpage"')" ci.yml
touch "$T/gh/topcoder1/badpage/pages_apart"
run_validator topcoder1/badpage
if [[ $VRC -eq 3 ]] &&
  has "$T/v.err" "API error: GET /repos/topcoder1/badpage/rules/branches/main did not answer an array of rules" &&
  api_error_only && no_body_bytes; then
  pass "h: a bad rule on page 1 of 2 exits 3 and echoes none of the answer"
else
  fail "h: a bad rule on page 1 of 2 should exit 3 (got $VRC)"
  show "$T/v.out" "$T/v.err"
fi

rule_pages() { # owner/repo, page-1 form, page 1's rules, page 2's bytes or HTTP status
  # Page 1 as gh prints it: an array of its own, or (gh 2.97.0) the array
  # left open for the pages after it.
  local d="$T/gh/$1/rule-pages"
  mkdir -p "$d"
  if [[ $2 == gh-2.97.0 ]]; then
    printf '%s' "${3%]}" > "$d/1.json"
  else
    printf '%s' "$3" > "$d/1.json"
  fi
  case "$4" in
    [0-9][0-9][0-9]) echo "$4" > "$d/2.fail" ;;
    *) printf '%s' "$4" > "$d/2.json" ;;
  esac
}
page1=$(rules_after 29 "plan-proofs / verify" | sed 's#"o/r"#"PRIVATE-BODY-CANARY-page1"#g')
for form in array-per-page gh-2.97.0; do
  # A null page 2. An array per page prints `[page 1]null`, and jq's `add`
  # takes a null for nothing at all: merged, it is page 1 alone, judged as if
  # it held every rule, and page 1's phantom would exit 1. gh 2.97.0 prints
  # `[page 1's rules null`, which is not JSON at all.
  r="topcoder1/nullpage-$form"
  fake_repo "$r" '[]' ci.yml
  rule_pages "$r" "$form" "$page1" null
  run_validator "$r"
  if [[ $VRC -eq 3 ]] &&
    has "$T/v.err" "API error: GET /repos/$r/rules/branches/main did not answer an array of rules" &&
    api_error_only && no_body_bytes; then
    pass "h: a page 2 that is not a list exits 3 and echoes none of the answer ($form)"
  else
    fail "h: a null page 2 ($form) should exit 3 (got $VRC)"
    show "$T/v.out" "$T/v.err"
  fi

  # A page 2 that fails: gh --paginate exits 1 there, after printing the
  # pages before it, and page 1's rules must never be judged on their own.
  r="topcoder1/failpage-$form"
  fake_repo "$r" '[]' ci.yml
  rule_pages "$r" "$form" "$(rules_after 29 test)" 403
  run_validator "$r"
  if [[ $VRC -eq 3 ]] &&
    has "$T/v.err" "API error: GET /repos/$r/rules/branches/main failed (HTTP 403)" &&
    has "$T/v.err" "gh: Resource not accessible by personal access token (HTTP 403)" &&
    api_error_only; then
    pass "h: a page 2 that fails exits 3 naming its status ($form)"
  else
    fail "h: a page 2 that fails ($form) should exit 3 with HTTP 403 (got $VRC)"
    show "$T/v.out" "$T/v.err"
  fi
done

# ---------------------------------------------------------------------------
# i. Values in the URL are percent-encoded. gh parses the endpoint as a URL,
#    so a value spliced in as it is can read something else: `#` starts a
#    fragment gh never sends, `?` starts the query, and a `%` that starts no
#    %XX escape stops gh before it sends anything, while GitHub decodes any
#    %XX that is left. A `/` is sent as it is.
# ---------------------------------------------------------------------------
# Each file is its repo's only producer of the required check. Unencoded,
# `#` and `?` cut the name to `ci`, a file the repo does not have, and `%.`
# stopped gh. A space always worked: gh escapes it itself.
n=0
for name in "ci#2.yml" "ci?2.yml" "50%.yml" "ci 2.yml"; do
  n=$((n + 1))
  r="topcoder1/filename$n"
  fake_repo "$r" "$(rules_json test)"
  cp "$T/wf/ci.yml" "$T/gh/$r/workflows/$name"
  run_validator "$r"
  if [[ $VRC -eq 0 ]] && has "$T/v.out" "✓  test" && has "$T/v.out" "target/$name (direct match"; then
    pass "i: a workflow file named '$name' is read as that file"
  else
    fail "i: the file '$name' should be read as the producer of test, exit 0 (got $VRC)"
    show "$T/v.out" "$T/v.err"
  fi
done

# Only the named branch has rules. Unencoded, `#` cut it to `release` and
# GitHub decoded %41 to `A`: branches with no rules, which read as a clean
# pass.
fake_repo topcoder1/branches '[]' ci.yml
for branch in "release#2" "rel%41se"; do
  mkdir -p "$T/gh/topcoder1/branches/branch-rules/$branch"
  rules_json test "plan-proofs / verify" > "$T/gh/topcoder1/branches/branch-rules/$branch/rules.json"
done
for branch in "release#2" "rel%41se"; do
  run_validator topcoder1/branches --branch "$branch"
  if [[ $VRC -eq 1 ]] && has "$T/v.out" "(branch: $branch)" &&
    has "$T/v.out" "✓  test" && has "$T/v.out" "✗  plan-proofs / verify"; then
    pass "i: --branch '$branch' reads that branch's rules"
  else
    fail "i: --branch '$branch' should read its own rules and find the phantom, exit 1 (got $VRC)"
    show "$T/v.out" "$T/v.err"
  fi
done

# An API error names the endpoint as it was sent: a file read that fails, a
# file answer that is not base64 content, and a rules answer that is not a
# list, for a branch whose `/` is sent as it is.
fake_repo topcoder1/sent "$(rules_json test)"
cp "$T/wf/ci.yml" "$T/gh/topcoder1/sent/workflows/ci#2.yml"
echo "contents/.github/workflows/ci%232.yml 404" > "$T/gh/topcoder1/sent/fail"
run_validator topcoder1/sent
if [[ $VRC -eq 3 ]] &&
  has "$T/v.err" "API error: GET /repos/topcoder1/sent/contents/.github/workflows/ci%232.yml failed (HTTP 404)" &&
  api_error_only; then
  pass "i: a failed read of 'ci#2.yml' names its endpoint as sent"
else
  fail "i: the 404 on 'ci#2.yml' should name .../ci%232.yml (got $VRC)"
  show "$T/v.out" "$T/v.err"
fi
fake_repo topcoder1/sent2 "$(rules_json test)"
cp "$T/wf/ci.yml" "$T/gh/topcoder1/sent2/workflows/ci#2.yml"
answer topcoder1/sent2 "ci#2.yml" '{"type":"file","name":"ci#2.yml","encoding":"base64","content":"PRIVATE-BODY-CANARY not base64!"}'
run_validator topcoder1/sent2
if [[ $VRC -eq 3 ]] &&
  has "$T/v.err" "API error: GET /repos/topcoder1/sent2/contents/.github/workflows/ci%232.yml did not answer base64 file content" &&
  api_error_only && no_body_bytes; then
  pass "i: a 'ci#2.yml' answer that is not base64 content names its endpoint as sent"
else
  fail "i: the bad answer for 'ci#2.yml' should name .../ci%232.yml (got $VRC)"
  show "$T/v.out" "$T/v.err"
fi
fake_repo topcoder1/sent3 '[]' ci.yml
mkdir -p "$T/gh/topcoder1/sent3/branch-rules/rel/main#x"
echo '{"message":"not a list","leak":"PRIVATE-BODY-CANARY-branch"}' > "$T/gh/topcoder1/sent3/branch-rules/rel/main#x/rules.json"
run_validator topcoder1/sent3 --branch "rel/main#x"
if [[ $VRC -eq 3 ]] &&
  has "$T/v.err" "API error: GET /repos/topcoder1/sent3/rules/branches/rel/main%23x did not answer an array of rules" &&
  api_error_only && no_body_bytes; then
  pass "i: a rules answer for 'rel/main#x' that is not a list names its endpoint as sent"
else
  fail "i: the bad rules answer for 'rel/main#x' should name .../rel/main%23x (got $VRC)"
  show "$T/v.out" "$T/v.err"
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
  show "$T/n1.err"
fi

NRC=0
old rules topcoder1/offline > /dev/null 2> "$T/n4.err" || NRC=$?
if [[ $NRC -eq 0 ]] && has "$T/n4.err" "no branch rules found for main"; then
  pass "n4: the old rules fetch passed a repo it never reached as 'no branch rules found' (rc 0)"
else
  fail "n4: the old rules fetch should read no response as no rules (got $NRC)"
  show "$T/n4.err"
fi

NRC=0
old listing topcoder1/nolisting > "$T/n2.out" 2> /dev/null || NRC=$?
if [[ $NRC -eq 0 && ! -s "$T/n2.out" ]]; then
  pass "n2: the old listing fetch read the 403 as an empty workflow directory (rc 0)"
else
  fail "n2: the old listing fetch should swallow the 403 (got rc $NRC)"
  show "$T/n2.out"
fi

mkdir -p "$T/old-target"
NRC=0
old file topcoder1/nofile ci.yml "$T/old-target" > /dev/null 2>&1 || NRC=$?
if [[ $NRC -eq 0 && -f "$T/old-target/ci.yml" && ! -s "$T/old-target/ci.yml" ]]; then
  pass "n3: the old per-file fetch turned the 404 into an empty ci.yml (rc 0)"
else
  fail "n3: the old per-file fetch should swallow the 404 (got rc $NRC)"
fi

# ---------------------------------------------------------------------------
# Shim controls. Cases h and i tell the fix from the bug only while the shim
# reads a request the way gh and GitHub do (measured: see the shim). These pin
# it on the requests origin/main at 71322c5 sent, the rules call without
# --paginate and each value as it was given, and on both forms --paginate
# prints.
# ---------------------------------------------------------------------------
shim() { # endpoint [gh args...] -> $SHRC, $T/s.out, $T/s.err
  SHRC=0
  GH_FAKE="$T/gh" "$T/bin/gh" api "$@" > "$T/s.out" 2> "$T/s.err" < /dev/null || SHRC=$?
}

fake_repo topcoder1/rules31 "$(rules_after 30 test)"
shim /repos/topcoder1/rules31/rules/branches/main
s1_first=$(jq -c '[length, any(.[]; .type == "required_status_checks")]' "$T/s.out" 2> /dev/null || true)
shim "/repos/topcoder1/rules31/rules/branches/main?page=2"
s1_second=$(jq -c 'map(.ruleset_id)' "$T/s.out" 2> /dev/null || true)
shim "/repos/topcoder1/rules31/rules/branches/main?per_page=100"
s1_whole=$(jq -c length "$T/s.out" 2> /dev/null || true)
shim "/repos/topcoder1/rules31/rules/branches/main?per_page=1&page=2"
s1_amp=$(jq -c 'map(.ruleset_id)' "$T/s.out" 2> /dev/null || true)
shim "/repos/topcoder1/rules31/rules/branches/main?per_page=1%zz&page=2"
s1_bad=$(jq -c 'map(.ruleset_id)' "$T/s.out" 2> /dev/null || true)
if [[ $s1_first == "[30,false]" && $s1_second == "[31]" && $s1_whole == 31 &&
  $s1_amp == "[2]" && $s1_bad == "[31]" ]]; then
  pass "s1: the rules answer comes 30 rules a page; per_page and page select, & splits, a bad % drops its parameter"
else
  fail "s1: expected [30,false] [31] 31 [2] [31], got $s1_first $s1_second $s1_whole $s1_amp $s1_bad"
fi

fake_repo topcoder1/rules101 "$(rules_after 100 test)"
shim /repos/topcoder1/rules101/rules/branches/main --paginate
s2_one=$(jq -c length "$T/s.out" 2> /dev/null | tr '\n' ' ' || true)
touch "$T/gh/topcoder1/rules101/pages_apart"
shim /repos/topcoder1/rules101/rules/branches/main --paginate
s2_apart=$(jq -c length "$T/s.out" 2> /dev/null | tr '\n' ' ' || true)
if [[ $s2_one == "101 " && $s2_apart == "100 1 " ]]; then
  pass "s2: --paginate asks for 100 rules a page and prints every page, as one array or an array per page"
else
  fail "s2: expected page lengths '101 ' and '100 1 ', got '$s2_one' and '$s2_apart'"
fi

fake_repo topcoder1/pagebytes '[]'
pb="$T/gh/topcoder1/pagebytes/rule-pages"
mkdir -p "$pb"
printf '%s' '[{"type":"deletion"}]' > "$pb/1.json"
printf '%s' null > "$pb/2.json"
shim /repos/topcoder1/pagebytes/rules/branches/main
s3_plain="$SHRC $(cat "$T/s.out")"
shim /repos/topcoder1/pagebytes/rules/branches/main --paginate
s3_apart="$SHRC $(cat "$T/s.out")"
printf '%s' '[{"type":"deletion"}' > "$pb/1.json"
shim /repos/topcoder1/pagebytes/rules/branches/main --paginate
s3_open="$SHRC $(cat "$T/s.out")"
rm "$pb/2.json"
echo 403 > "$pb/2.fail"
shim /repos/topcoder1/pagebytes/rules/branches/main --paginate
s3_fail="$SHRC $(cat "$T/s.out")"
if [[ $s3_plain == '0 [{"type":"deletion"}]' && $s3_apart == '0 [{"type":"deletion"}]null' &&
  $s3_open == '0 [{"type":"deletion"}null' &&
  $s3_fail == '1 [{"type":"deletion"}{"message":"Resource not accessible by personal access token",'* ]] &&
  has "$T/s.err" "gh: Resource not accessible by personal access token (HTTP 403)"; then
  pass "s3: explicit pages print as given: one page, an array per page, gh 2.97.0's open array, a failing page 2"
else
  fail "s3: unexpected page bytes"
  printf '%s\n' "$s3_plain" "$s3_apart" "$s3_open" "$s3_fail"
fi

fake_repo topcoder1/unencoded '[]' ci.yml
uw="$T/gh/topcoder1/unencoded/workflows"
printf 'cut\n' > "$uw/ci"
for name in "ci#2.yml" "ci?2.yml" "50%.yml"; do cp "$T/wf/ci.yml" "$uw/$name"; done
for branch in release relAse; do
  mkdir -p "$T/gh/topcoder1/unencoded/branch-rules/$branch"
  rules_json "from $branch" > "$T/gh/topcoder1/unencoded/branch-rules/$branch/rules.json"
done
unencoded() { # endpoint after /repos/topcoder1/unencoded/, a jq filter, what it must read
  shim "/repos/topcoder1/unencoded/$1"
  local got
  got=$(jq -r "$2" "$T/s.out" 2> /dev/null || true)
  if [[ $SHRC -eq 0 && $got == "$3" ]]; then
    pass "s4: an unencoded '$1' reads $3"
  else
    fail "s4: '$1' should read $3, got '$got' (rc $SHRC)"
    show "$T/s.err"
  fi
}
unencoded "contents/.github/workflows/ci#2.yml" .name ci
unencoded "contents/.github/workflows/ci?2.yml" .name ci
unencoded "rules/branches/release#2" '.[1].parameters.required_status_checks[0].context' "from release"
unencoded "rules/branches/rel%41se" '.[1].parameters.required_status_checks[0].context' "from relAse"
shim "/repos/topcoder1/unencoded/contents/.github/workflows/50%.yml"
if [[ $SHRC -eq 1 && ! -s "$T/s.out" ]] && has "$T/s.err" "invalid URL escape"; then
  pass "s4: an unencoded '50%.yml' fails in gh, an invalid URL escape, before anything is sent"
else
  fail "s4: '50%.yml' should fail in gh with rc 1 and no answer (got rc $SHRC)"
  show "$T/s.out" "$T/s.err"
fi

echo
if [[ $failed -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "all audit exit-code cases pass"
