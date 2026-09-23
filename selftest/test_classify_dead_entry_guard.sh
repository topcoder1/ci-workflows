#!/usr/bin/env bash
# Guards classify.mjs against risk-paths.yml entries that parse to nothing a
# glob can use. Two such shapes passed every fail-closed pass with exit 0:
#
# 1. An UNQUOTED entry that starts with '!' is a YAML tag, not text.
#    '- !scripts/la1_deploy_ssh_setup.sh' and '- !secrets/**' name tags the
#    parser cannot resolve, so yaml@2 drops the tag with only a WARNING
#    (TAG_RESOLVE_FAILED) and keeps an EMPTY string. The negation pass looks
#    for a '!' that is no longer there, and the entry matches nothing: under
#    blocked:/sensitive: that gate disappears, and under always_review:
#    codex-gate.mjs stops forcing a review of that path, so a 5-line diff to it
#    skips Codex. Every parser warning now fails closed, not only errors
#    (cases 1-3).
#
# 2. An empty or whitespace-only string matches no changed file, and a
#    non-string entry ('- 42', a bare '-', '- key: value') is skipped by every
#    guard pass. classify() hands it to minimatch, which throws on it only for
#    a changed file that gets that far down the list, and codex-gate.mjs throws
#    on it in always_review:, failing the Codex job instead of naming the line.
#    Both now fail closed in every class, in exclude: and in always_review
#    (cases 4-5).
#
# Cases 6-7 are the positive controls: a QUOTED '!x' is a real string and must
# still reach the negation guard with that guard's own reason, and ordinary
# entries must still load and classify.
#
# ci-workflows#227 named this as out of scope ("Rejecting empty patterns or
# YAML warnings would be a separate hardening"); the independent review of
# ci-workflows#228 raised it again.
#
# Every location, shape and expected message fragment below is HARDCODED, never
# read back from classify.mjs: a test that derives its expectations from the
# artifact under test cannot catch that artifact narrowing.
#
# Run from the repo root:
#   bash selftest/test_classify_dead_entry_guard.sh
set -euo pipefail

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# classify.mjs imports its deps from classifier-deps.mjs sitting beside it —
# the same committed, version-pinned bundle pr-classify.yml fetches into
# .github/scripts/. Copying both mirrors the workflow's on-disk layout exactly.
cp .github/scripts/classify.mjs .github/scripts/classifier-deps.mjs "$tmp/"

mkdir -p "$tmp/repo/.github"
failed=0

# run_classifier <file...> — sets $rc, $out (stdout) and $err (stderr).
run_classifier() {
  set +e
  out=$(printf '%s\n' "$@" | (cd "$tmp/repo" && node "$tmp/classify.mjs") 2> "$tmp/stderr")
  rc=$?
  set -e
  err=$(cat "$tmp/stderr")
}

# expect_fail_closed <description> <needle...> — the classifier must exit
# nonzero, print NO class on stdout, and fail through classify.mjs's own fail()
# (whose messages all start 'classify.mjs: ') naming every needle. The prefix
# check is what tells a guard apart from a crash: minimatch's TypeError on a
# non-string entry also exits nonzero with an empty stdout, but node prints a
# stack trace instead. Needles are matched with `case`, not `grep -q`, so no
# pipe can race them.
expect_fail_closed() {
  local desc="$1" needle missing=""
  shift
  run_classifier "src/app.py"
  case "$err" in
    "classify.mjs: "*) ;;
    *) missing="$missing <the 'classify.mjs: ' prefix of fail()>" ;;
  esac
  for needle in "$@"; do
    case "$err" in
      *"$needle"*) ;;
      *) missing="$missing '$needle'" ;;
    esac
  done
  if [ "$rc" -ne 0 ] && [ -z "$out" ] && [ -z "$missing" ]; then
    echo "✓ $desc"
  else
    echo "✗ $desc — expected nonzero exit, empty stdout, stderr naming every needle (missing:${missing:- none}); got rc=$rc, stdout '$out':"
    if [ -n "$err" ]; then printf '%s\n' "$err" | sed 's/^/    /'; fi
    failed=1
  fi
}

# expect_err_lacks <needle> <description> — the message from the LAST run must
# not contain <needle>. An EMPTY message fails too: a check that passes on
# silence proves nothing.
expect_err_lacks() {
  case "$err" in
    "")
      echo "✗ $2 — no stderr to check: the classifier printed no message at all"
      failed=1
      ;;
    *"$1"*)
      echo "✗ $2 — stderr unexpectedly contains '$1':"
      printf '%s\n' "$err" | sed 's/^/    /'
      failed=1
      ;;
    *) echo "✓ $2" ;;
  esac
}

# expect_class <want> <description> <file...> — exit 0, <want> on stdout, and
# nothing at all on stderr: a YAMLWarning printed beside a verdict is the very
# silence this file exists to end.
expect_class() {
  local want="$1" desc="$2"
  shift 2
  run_classifier "$@"
  if [ "$rc" -eq 0 ] && [ "$out" = "$want" ] && [ -z "$err" ]; then
    echo "✓ $desc"
  else
    echo "✗ $desc — expected exit 0, '$want' and an empty stderr; got rc=$rc, stdout '$out':"
    if [ -n "$err" ]; then printf '%s\n' "$err" | sed 's/^/    /'; fi
    failed=1
  fi
}

# place <location> <raw> — write a rules file with ordinary entries in all four
# locations, then append ONE more entry, <raw> exactly as written, to
# <location>'s list. The guard has to find the bad entry inside a real list,
# not in a file that holds nothing else. Every rejected shape below is placed
# in all four locations: a gating class (sensitive), a safe class (safe_test),
# an exclusion list (exclude.sensitive) and always_review.
place() {
  local s="" t="" x="" a=""
  case "$1" in
    sensitive) s="  - $2" ;;
    safe_test) t="  - $2" ;;
    exclude.sensitive) x="    - $2" ;;
    always_review) a="  - $2" ;;
    *)
      echo "place: unknown location '$1'" >&2
      exit 2
      ;;
  esac
  {
    printf '%s\n' "blocked:" "  - '**/.env*'" "sensitive:" "  - 'cmd/**'"
    if [ -n "$s" ]; then printf '%s\n' "$s"; fi
    printf '%s\n' "safe_test:" "  - 'tests/**'"
    if [ -n "$t" ]; then printf '%s\n' "$t"; fi
    printf '%s\n' "exclude:" "  sensitive:" "    - 'cmd/**/*_test.go'"
    if [ -n "$x" ]; then printf '%s\n' "$x"; fi
    printf '%s\n' "always_review:" "  - 'scripts/deploy.sh'"
    if [ -n "$a" ]; then printf '%s\n' "$a"; fi
  } > "$tmp/repo/.github/risk-paths.yml"
}

# 0. PREMISE, pinned against the shipped bundle with the options classify.mjs
#    uses: the hazards exist. yaml's parse() turns an unquoted '!' entry into an
#    EMPTY string and only warns, minimatch matches that empty pattern against
#    no real path, and minimatch throws on a non-string. If a future bundle
#    changed any of these, this case says so and the guard's rationale needs a
#    second look. (parse() prints its warning on stderr, discarded here.)
premise=$(cd "$tmp" && node --input-type=module -e "
import { parse, minimatch } from './classifier-deps.mjs';
const opts = { dot: true, matchBase: false };
const out = [JSON.stringify(parse('always_review:\n  - !scripts/la1_deploy_ssh_setup.sh\n'))];
out.push(minimatch('scripts/la1_deploy_ssh_setup.sh', '', opts));
try { minimatch('src/app.py', 42, opts); out.push('no throw'); } catch (e) { out.push(e.message); }
console.log(out.join(' | '));
" 2>/dev/null)
want='{"always_review":[""]} | false | invalid pattern'
if [ "$premise" = "$want" ]; then
  echo "✓ premise: an unquoted '!' entry parses to '', '' matches nothing, and a non-string makes minimatch throw"
else
  echo "✗ premise changed — want '$want', got '$premise'"
  failed=1
fi

# 1. An unquoted tag fails closed on the parser's warning in every location.
#    The file-shaped tag is the one found on wxa_webcat#1612's always_review,
#    the glob-shaped one a secrets pattern. Both leave an empty string behind,
#    so this case asserts the WARNING's message, not merely a nonzero exit —
#    otherwise case 4's empty-entry guard would pass it on the warning guard's
#    behalf.
for where in sensitive safe_test exclude.sensitive always_review; do
  place "$where" '!scripts/la1_deploy_ssh_setup.sh'
  expect_fail_closed "unquoted '- !scripts/la1_deploy_ssh_setup.sh' under $where: fails closed on the parser warning" \
    "the YAML parser warned" "Unresolved tag: !scripts/la1_deploy_ssh_setup.sh" "(TAG_RESOLVE_FAILED)"
  place "$where" '!secrets/**'
  expect_fail_closed "unquoted '- !secrets/**' under $where: fails closed on the parser warning" \
    "the YAML parser warned" "Unresolved tag: !secrets/**" "(TAG_RESOLVE_FAILED)"
done

# 2. A tag followed by text leaves the text behind ('foo'), a non-empty string
#    no other guard can catch: only the warning guard stops it.
place sensitive '!secrets/** foo'
expect_fail_closed "'- !secrets/** foo' (a tag that leaves text behind) fails closed on the warning alone" \
  "the YAML parser warned" "Unresolved tag: !secrets/**" "(TAG_RESOLVE_FAILED)"

# 3. Every warning fails closed, not only tags, and an ERROR still fails closed
#    through the parse path's own message, exactly as before this guard.
{
  printf '%s\n' "%FOO bar" "---"
  printf '%s\n' "blocked:" "  - '**/.env*'"
} > "$tmp/repo/.github/risk-paths.yml"
expect_fail_closed "an unknown '%FOO' directive (a warning, not a tag) fails closed" \
  "the YAML parser warned" "Unknown directive %FOO" "(BAD_DIRECTIVE)"
printf '%s\n' "%YAML 1.3" "---" "blocked:" "  - '**/.env*'" > "$tmp/repo/.github/risk-paths.yml"
expect_fail_closed "an unsupported '%YAML 1.3' directive fails closed" \
  "the YAML parser warned" "Unsupported YAML version 1.3" "(BAD_DIRECTIVE)"
printf '%s\n' "blocked:" "  - 'a/**'" "blocked:" "  - 'b/**'" > "$tmp/repo/.github/risk-paths.yml"
expect_fail_closed "a duplicate key (a parser ERROR) still fails closed through 'failed to read'" \
  "failed to read .github/risk-paths.yml" "Map keys must be unique"

# 4. Empty and whitespace-only strings fail closed in every location. The last
#    two carry no warning at all: a bare '!' is YAML's non-specific tag and
#    '!!str' its string tag, and both resolve an empty node to ''.
for where in sensitive safe_test exclude.sensitive always_review; do
  for raw in "''" "' '" '"\t"' '" "' '!' '!!str'; do
    place "$where" "$raw"
    expect_fail_closed "- $raw under $where: fails closed as empty" \
      "(under '$where:') is empty or whitespace-only"
  done
done

# 5. Non-string entries fail closed in every location, each named by its kind.
#    A bare '-' and a '#' after it (a comment, not a pattern) are both null.
for where in sensitive safe_test exclude.sensitive always_review; do
  place "$where" ''
  expect_fail_closed "a bare '-' under $where: fails closed as null" \
    "(under '$where:') is null, not a string"
  place "$where" '#scripts/deploy.sh'
  expect_fail_closed "'- #scripts/deploy.sh' (a comment) under $where: fails closed as null" \
    "(under '$where:') is null, not a string"
  place "$where" '~'
  expect_fail_closed "'- ~' under $where: fails closed as null" \
    "(under '$where:') is null, not a string"
  place "$where" '42'
  expect_fail_closed "'- 42' under $where: fails closed as a number" \
    "(under '$where:') is a number, not a string"
  place "$where" 'true'
  expect_fail_closed "'- true' under $where: fails closed as a boolean" \
    "(under '$where:') is a boolean, not a string"
  place "$where" 'key: value'
  expect_fail_closed "'- key: value' under $where: fails closed as a mapping" \
    "(under '$where:') is a mapping, not a string"
  place "$where" '[a, b]'
  expect_fail_closed "'- [a, b]' under $where: fails closed as a list" \
    "(under '$where:') is a list, not a string"
done

# 6. POSITIVE CONTROL: quoted, '!x' is a real string, so it must reach the
#    negation guard and fail with THAT guard's reason — not be swallowed by
#    the warning or entry guards, which would hide why it is wrong.
for where in sensitive safe_test exclude.sensitive always_review; do
  place "$where" "'!x'"
  expect_fail_closed "quoted '!x' under $where: still gets the negation guard's message" \
    "pattern '!x'" "uses glob negation"
  expect_err_lacks "the YAML parser warned" "quoted '!x' under $where: no parser warning"
  expect_err_lacks "empty or whitespace-only" "quoted '!x' under $where: not reported as empty"
  expect_err_lacks "not a string" "quoted '!x' under $where: not reported as a non-string"
done

# 7. POSITIVE CONTROL: ordinary entries still load and classify, in every
#    spelling the fleet uses — plain, single- and double-quoted, '!!str'-tagged,
#    an interior space, a key left empty, and a '!' that sits in a comment.
cat > "$tmp/repo/.github/risk-paths.yml" <<'YAML'
# - !scripts/commented_out.sh   (a comment: the parser never sees it)
blocked:
  - '**/.env*'
sensitive:
  - cmd/**
  - "internal/auth/**"
  - !!str scripts/deploy.sh
safe_test:
  - 'tests/**'
  - '**/*_test.go'
safe_deps:
trivial:
  - 'docs/My Notes/**'
exclude:
  sensitive:
    - 'cmd/**/*_test.go'
always_review:
  - 'scripts/deploy.sh'
YAML
expect_class blocked ".env.prod classifies blocked" .env.prod
expect_class sensitive "a plain unquoted entry gates (cmd/svc/main.go)" cmd/svc/main.go
expect_class sensitive "a double-quoted entry gates (internal/auth/x.go)" internal/auth/x.go
expect_class sensitive "a '!!str'-tagged entry gates (scripts/deploy.sh)" scripts/deploy.sh
expect_class safe_test "an exclusion still subtracts (cmd/svc/main_test.go)" cmd/svc/main_test.go
expect_class trivial "an entry with an interior space matches" "docs/My Notes/a.md"
expect_class standard "an unmatched path still falls back to standard" src/app.py

exit "$failed"
