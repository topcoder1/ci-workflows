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
#    skips Codex. Every warning yaml reports now fails closed, not only errors
#    — including the one it raises only while converting the document, for a
#    collection used as a mapping key ('[blocked]:'), which silently drops the
#    class that key named (cases 1-3).
#
# 2. An empty or whitespace-only string matches no changed file, and a
#    non-string entry ('- 42', a bare '-', '- key: value') is skipped by every
#    guard pass. classify() hands it to minimatch, which throws on it only for
#    a changed file that gets that far down the list, and codex-gate.mjs throws
#    on it in always_review:, failing the Codex job instead of naming the line.
#    Both now fail closed in every class, in exclude: and in always_review
#    (cases 4-5). So do three kinds of string no changed path can match (case
#    6): one with leading or trailing whitespace — a '|' or '>' block scalar
#    keeps a trailing newline — one with a line break inside, which is what a
#    '|' block of several lines or a "\n" escape becomes (a '>-' block or a
#    scalar wrapped over lines folds into spaces instead, and is NOT caught),
#    and one that starts with '#', which
#    minimatch reads as a comment. The last is where the non-string message's
#    own advice would otherwise lead: quoting a '- #scripts/deploy.sh' line
#    (null) as written gives '#scripts/deploy.sh'. Found by the independent
#    review and by Codex round 5 of this change.
#
# Cases 7-8 are the positive controls: a QUOTED '!x' is a real string and must
# still reach the negation guard with that guard's own reason, and ordinary
# entries must still load and classify. Case 9 pins that the conversion-warning
# capture puts process.emitWarning back once conversion ends.
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
#    no real path, minimatch throws on a non-string, and it matches neither a
#    pattern that starts with '#' (a comment) nor a padded one. A collection
#    used as a mapping key warns only on conversion, never in doc.warnings,
#    which is why classify.mjs also collects what yaml emits while converting.
#    If a future bundle changed any of these, this case says so and the
#    guard's rationale needs a second look. (parse() prints its warning on
#    stderr, discarded here.)
premise=$(cd "$tmp" && node --input-type=module -e "
import { parse, parseDocument, minimatch } from './classifier-deps.mjs';
const opts = { dot: true, matchBase: false };
const out = [JSON.stringify(parse('always_review:\n  - !scripts/la1_deploy_ssh_setup.sh\n'))];
out.push(minimatch('scripts/la1_deploy_ssh_setup.sh', '', opts));
try { minimatch('src/app.py', 42, opts); out.push('no throw'); } catch (e) { out.push(e.message); }
out.push(minimatch('#notes/x.md', '#notes/**', opts));
out.push(minimatch('scripts/deploy.sh', 'scripts/deploy.sh ', opts));
out.push(parseDocument('[blocked]: [a]\n').warnings.length);
console.log(out.join(' | '));
" 2>/dev/null)
want='{"always_review":[""]} | false | invalid pattern | false | false | 0'
if [ "$premise" = "$want" ]; then
  echo "✓ premise: an unquoted '!' entry parses to '', which matches nothing; a non-string makes minimatch throw; '#…' and padded patterns match nothing"
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
# A mapping KEY that is a collection never reaches doc.warnings: yaml warns
# only while converting the document, when it stringifies '[blocked]' to
# '[ blocked ]' and so silently drops the gate that key named. Found by Codex
# review round 2 of this change.
printf '%s\n' "[blocked]: ['**/.env*']" "sensitive:" "  - 'cmd/**'" > "$tmp/repo/.github/risk-paths.yml"
expect_fail_closed "a flow-list key '[blocked]:' fails closed on the conversion warning" \
  "the YAML parser warned" "Keys with collection values will be stringified" "(while converting)" \
  "write the plain key"
printf '%s\n' "? [sensitive]" ": - 'cmd/**'" > "$tmp/repo/.github/risk-paths.yml"
expect_fail_closed "an explicit '? [sensitive]' key fails closed on the conversion warning" \
  "the YAML parser warned" "Keys with collection values will be stringified" "(while converting)" \
  "write the plain key"
printf '%s\n' "sensitive:" "  - 'cmd/**'" "exclude:" "  [sensitive]:" "    - 'cmd/**/*_test.go'" > "$tmp/repo/.github/risk-paths.yml"
expect_fail_closed "a collection key inside exclude: fails closed on the conversion warning" \
  "the YAML parser warned" "Keys with collection values will be stringified" "(while converting)" \
  "write the plain key"
printf '%s\n' "blocked:" "  - 'a/**'" "blocked:" "  - 'b/**'" > "$tmp/repo/.github/risk-paths.yml"
expect_fail_closed "a duplicate key (a parser ERROR) still fails closed through 'failed to read'" \
  "failed to read .github/risk-paths.yml" "Map keys must be unique"

# 4. Empty and whitespace-only strings fail closed in every location. The last
#    two carry no warning at all: a bare '!' is YAML's non-specific tag and
#    '!!str' its string tag, and both resolve an empty node to ''.
for where in sensitive safe_test exclude.sensitive always_review; do
  for raw in "''" "' '" '"\t"' '"\u00a0"' '!' '!!str'; do
    place "$where" "$raw"
    expect_fail_closed "- $raw under $where: fails closed as empty" \
      "(under '$where:') is empty or whitespace-only" "matches no changed path"
  done
done

# 5. Non-string entries fail closed in every location, each named by its kind
#    and by what it does THERE: an exclusion is skipped and exempts nothing,
#    while minimatch throws on it in a class list (this script) or in
#    always_review (codex-gate.mjs). A bare '-' and a '#' after it (a comment,
#    not a pattern) are both null.
for where in sensitive safe_test exclude.sensitive always_review; do
  case "$where" in
    exclude.*) consequence="it silently exempts nothing" ;;
    always_review) consequence="codex-gate.mjs fails the Codex job" ;;
    *) consequence="this script crashes" ;;
  esac
  place "$where" ''
  expect_fail_closed "a bare '-' under $where: fails closed as null" \
    "(under '$where:') is null, not a string" "$consequence"
  place "$where" '#scripts/deploy.sh'
  expect_fail_closed "'- #scripts/deploy.sh' (a comment) under $where: fails closed as null" \
    "(under '$where:') is null, not a string" "$consequence"
  place "$where" '~'
  expect_fail_closed "'- ~' under $where: fails closed as null" \
    "(under '$where:') is null, not a string" "$consequence"
  place "$where" '42'
  expect_fail_closed "'- 42' under $where: fails closed as a number" \
    "(under '$where:') is a number, not a string" "$consequence"
  place "$where" 'true'
  expect_fail_closed "'- true' under $where: fails closed as a boolean" \
    "(under '$where:') is a boolean, not a string" "$consequence"
  place "$where" 'key: value'
  expect_fail_closed "'- key: value' under $where: fails closed as a mapping" \
    "(under '$where:') is a mapping, not a string" "$consequence"
  place "$where" '[a, b]'
  expect_fail_closed "'- [a, b]' under $where: fails closed as a list" \
    "(under '$where:') is a list, not a string" "$consequence"
  # An alias to its own anchor is a legal YAML cycle, and JSON.stringify throws
  # on one: the message must still come from fail(), not a stack trace. (Codex
  # review round 3 of this change.)
  place "$where" '&x [*x]'
  expect_fail_closed "'- &x [*x]' (a recursive list) under $where: fails closed as a list" \
    "(under '$where:') is a list, not a string" "$consequence"
  place "$where" '&y {k: *y}'
  expect_fail_closed "'- &y {k: *y}' (a recursive mapping) under $where: fails closed as a mapping" \
    "(under '$where:') is a mapping, not a string" "$consequence"
done

# 6. Strings no changed path can match fail closed in every location. Changed
#    paths are trimmed before matching, so a pattern with leading or trailing
#    whitespace never matches; the double-quoted "…\n" entry is the value a
#    '|' or '>' block scalar produces, on one line. A pattern that starts with
#    '#' is a minimatch COMMENT and matches nothing — and it is where case 5's
#    '- #scripts/deploy.sh' leads if its author quotes the line as written.
for where in sensitive safe_test exclude.sensitive always_review; do
  for raw in "' scripts/deploy.sh'" "'scripts/deploy.sh '" '"scripts/deploy.sh\n"'; do
    place "$where" "$raw"
    expect_fail_closed "- $raw under $where: fails closed as padded" \
      "(under '$where:') has leading or trailing whitespace" "matches no changed path"
  done
  place "$where" "'#scripts/deploy.sh'"
  expect_fail_closed "quoted '#scripts/deploy.sh' under $where: fails closed as a minimatch comment" \
    "(under '$where:') starts with '#'" "matches no changed path"
  # A line break INSIDE a pattern can never match either: changed paths
  # arrive one per line. (Codex review round 5 of this change.)
  place "$where" '"cmd/**\nsrc/**"'
  expect_fail_closed "- \"cmd/**\\nsrc/**\" under $where: fails closed on the line break" \
    "(under '$where:') contains a line break" "matches no changed path"
done
# A '|-' block holding two lines is ONE pattern with a line break inside,
# not a list of two.
{
  printf '%s\n' "blocked:" "  - '**/.env*'" "sensitive:" "  - |-"
  printf '%s\n' "    cmd/**" "    internal/**"
} > "$tmp/repo/.github/risk-paths.yml"
expect_fail_closed "a two-line '|-' block scalar fails closed on the line break" \
  "(under 'sensitive:') contains a line break" "matches no changed path"
# A '>' or '>+' block of several lines folds into spaces but keeps its
# trailing newline, so the padded check still catches it. Only '>-' (and a
# wrapped plain or quoted scalar) folds away every newline: not caught here.
for style in '>' '>+'; do
  {
    printf '%s\n' "blocked:" "  - '**/.env*'" "sensitive:" "  - $style"
    printf '%s\n' "    cmd/**" "    internal/**"
  } > "$tmp/repo/.github/risk-paths.yml"
  expect_fail_closed "a two-line '$style' block (folded, trailing newline kept) fails closed as padded" \
    "(under 'sensitive:') has leading or trailing whitespace"
done
# The block scalars themselves, which take a second line.
for style in '|' '>'; do
  {
    printf '%s\n' "blocked:" "  - '**/.env*'" "sensitive:" "  - 'cmd/**'"
    printf '%s\n' "  - $style" "    scripts/deploy.sh"
  } > "$tmp/repo/.github/risk-paths.yml"
  expect_fail_closed "a '$style' block scalar (it keeps a trailing newline) fails closed as padded" \
    "(under 'sensitive:') has leading or trailing whitespace"
done

# 7. POSITIVE CONTROL: quoted, '!x' is a real string, so it must reach the
#    negation guard and fail with THAT guard's reason — not be swallowed by
#    the warning or entry guards, which would hide why it is wrong.
for where in sensitive safe_test exclude.sensitive always_review; do
  place "$where" "'!x'"
  expect_fail_closed "quoted '!x' under $where: still gets the negation guard's message" \
    "pattern '!x'" "uses glob negation"
  expect_err_lacks "the YAML parser warned" "quoted '!x' under $where: no parser warning"
  expect_err_lacks "empty or whitespace-only" "quoted '!x' under $where: not reported as empty"
  expect_err_lacks "not a string" "quoted '!x' under $where: not reported as a non-string"
  expect_err_lacks "leading or trailing whitespace" "quoted '!x' under $where: not reported as padded"
  expect_err_lacks "starts with '#'" "quoted '!x' under $where: not reported as a comment"
done

# 8. POSITIVE CONTROL: ordinary entries still load and classify, in the
#    spellings a rules file can use — plain, single- and double-quoted,
#    '!!str'-tagged, a '|-' block scalar (which strips its newline), a flow
#    list, an interior space, a '#' escaped as '\#', a key left empty, and a
#    '!' that sits in a comment.
cat > "$tmp/repo/.github/risk-paths.yml" <<'YAML'
# - !scripts/commented_out.sh   (a comment: the parser never sees it)
blocked:
  - '**/.env*'
sensitive:
  - cmd/**
  - "internal/auth/**"
  - !!str scripts/deploy.sh
  - |-
    scripts/stripped.sh
safe_test:
  - 'tests/**'
  - '**/*_test.go'
safe_deps: ['go.sum', 'package-lock.json']
safe_config:
trivial:
  - 'docs/My Notes/**'
  - '\#notes/**'
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
expect_class sensitive "a '|-' block scalar gates (scripts/stripped.sh)" scripts/stripped.sh
expect_class safe_test "an exclusion still subtracts (cmd/svc/main_test.go)" cmd/svc/main_test.go
expect_class safe_deps "a flow-list entry matches (go.sum)" go.sum
expect_class trivial "an entry with an interior space matches" "docs/My Notes/a.md"
expect_class trivial "an escaped '\\#' entry matches a path that starts with '#'" "#notes/x.md"
expect_class standard "an unmatched path still falls back to standard" src/app.py

# 9. The conversion-warning capture swaps process.emitWarning for the length of
#    doc.toJS() alone, and must put the original back in its finally. The CLI
#    runs in its own process, so a preload (node --import) records the original
#    and reports at exit whether classify.mjs restored it: on a clean run, and
#    on one that captured a warning and failed closed. (Codex CI review of this
#    change: the restore was untested.)
cat > "$tmp/probe-emitwarning.mjs" <<'EOF'
const original = process.emitWarning;
process.on('exit', () => {
  process.stderr.write(process.emitWarning === original ? 'EMITWARNING=restored\n' : 'EMITWARNING=replaced\n');
});
EOF
# expect_restored <description> — run with the probe preloaded and require it
# to report the original process.emitWarning in place at exit.
expect_restored() {
  set +e
  out=$(printf '%s\n' "src/app.py" | (cd "$tmp/repo" && node --import "$tmp/probe-emitwarning.mjs" "$tmp/classify.mjs") 2> "$tmp/stderr")
  rc=$?
  set -e
  err=$(cat "$tmp/stderr")
  case "$err" in
    *"EMITWARNING=restored"*) echo "✓ $1" ;;
    *)
      echo "✗ $1 — process.emitWarning was not restored (rc=$rc, stdout '$out'):"
      printf '%s\n' "$err" | sed 's/^/    /'
      failed=1
      ;;
  esac
}
printf '%s\n' "blocked:" "  - '**/.env*'" > "$tmp/repo/.github/risk-paths.yml"
expect_restored "a clean run restores process.emitWarning after conversion"
printf '%s\n' "[blocked]: ['**/.env*']" > "$tmp/repo/.github/risk-paths.yml"
expect_restored "a run that captures a conversion warning and fails closed still restores process.emitWarning"

exit "$failed"
