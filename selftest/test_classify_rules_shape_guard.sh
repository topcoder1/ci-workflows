#!/usr/bin/env bash
# Guards classify.mjs against risk-paths.yml SHAPES that silently drop a gate:
# each passed every fail-closed pass with exit 0 (or crashed without naming
# itself), so the gate its author wrote did not exist.
#
# 1. The top level is not a mapping (cases 1-2). '- blocked: [...]' makes the
#    whole file ONE list: rules[cls] is undefined for every class, so every
#    gate is gone and every PR classifies 'standard'. A top-level scalar does
#    the same. An empty or comment-only file crashed on rules[cls] with a
#    TypeError instead of saying what is wrong.
#
# 2. An unknown top-level key (case 3) was ignored. 'sensitve:' — or
#    'SENSITIVE:', 'blocked_paths:', 'exclusions:' — is a gate that does not
#    exist. Unknown keys now fail closed against a STRICT allowlist of the nine
#    keys the fleet uses: the eight this script reads, plus
#    sensitive_deploy_gated, which dotclaude's /babysit-prs tooling reads. That
#    is the owner's pick over rejecting only keys within two edits of a known
#    one, which lets 'SENSITIVE:' (nine edits) and 'blocked_paths:' through.
#
# 3. An entry that ends with '/' ('infra/', a CODEOWNERS habit) or starts with
#    './' or '/' (case 4) matches no changed path: GitHub lists changed FILES,
#    repo-relative, so none ends with '/' or starts with '/' or './', and
#    minimatch keeps the '.' segment. Checked in every location, and in every
#    brace alternative, since '{infra/,terraform/}' spells the same dead shape.
#
# 4. A pattern wrapped over lines (case 5). YAML folds the line break inside a
#    plain or quoted scalar, and between the lines of a '>' block, into a
#    space: '- cmd/**' + an indented 'internal/**' on the next line is ONE
#    pattern, 'cmd/** internal/**', which matches neither path. The value
#    cannot be told apart from a real interior space ('docs/My Notes/**'), so
#    the check reads the SOURCE: a plain or single-quoted entry whose text spans
#    lines is rejected, as is a double-quoted one written over lines whose value
#    holds whitespace, and a '>' block of more than one content line. An escaped
#    line join ('\' at the end of a double-quoted line) folds nothing and stays
#    legal; a '|' block keeps its line breaks, which the dead-entry guard
#    already rejects. The walk reads keys the way yaml's toJS() does, through
#    alias keys ('? *cls'), and refuses a '<<' merge key, which would copy a
#    class list in from elsewhere in the file.
#
# Case 6 is the positive control: every key and every legitimate spelling
# still loads and classifies, in an LF and a CRLF file.
#
# Every key, location, shape and expected message fragment below is
# HARDCODED, never read back from classify.mjs: a test that derives its
# expectations from the artifact under test cannot catch that artifact
# narrowing.
#
# Run from the repo root:
#   bash selftest/test_classify_rules_shape_guard.sh
set -euo pipefail

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# classify.mjs imports its deps from classifier-deps.mjs sitting beside it —
# the same committed, version-pinned bundle pr-classify.yml fetches into
# .github/scripts/. Copying both mirrors the workflow's on-disk layout exactly.
cp .github/scripts/classify.mjs .github/scripts/classifier-deps.mjs "$tmp/"

mkdir -p "$tmp/repo/.github"
rules="$tmp/repo/.github/risk-paths.yml"
failed=0
nl='
'
tab=$(printf '\t')
cr=$(printf '\r')

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
# check is what tells a guard apart from a crash: the TypeError an empty file
# used to raise also exits nonzero with an empty stdout, but node prints a
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
# nothing at all on stderr.
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

# place <location> <raw> — write a rules file with ordinary entries in all five
# locations, then append ONE more entry, <raw> exactly as written (it may span
# lines), to <location>'s list. Every rejected entry shape below is placed in
# all five: both gating classes (blocked, sensitive), a safe class (safe_test),
# an exclusion list (exclude.sensitive) and always_review.
place() {
  local b="" s="" t="" x="" a=""
  case "$1" in
    blocked) b="  - $2" ;;
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
    printf '%s\n' "blocked:" "  - '**/.env*'"
    if [ -n "$b" ]; then printf '%s\n' "$b"; fi
    printf '%s\n' "sensitive:" "  - 'cmd/**'"
    if [ -n "$s" ]; then printf '%s\n' "$s"; fi
    printf '%s\n' "safe_test:" "  - 'tests/**'"
    if [ -n "$t" ]; then printf '%s\n' "$t"; fi
    printf '%s\n' "exclude:" "  sensitive:" "    - 'cmd/**/*_test.go'"
    if [ -n "$x" ]; then printf '%s\n' "$x"; fi
    printf '%s\n' "always_review:" "  - 'scripts/deploy.sh'"
    if [ -n "$a" ]; then printf '%s\n' "$a"; fi
  } > "$rules"
}

# crlf <file> — rewrite <file> with CRLF line endings, in place.
crlf() {
  awk '{ printf "%s\r\n", $0 }' "$1" > "$1.crlf"
  mv "$1.crlf" "$1"
}

# 0. PREMISE, pinned against the shipped bundle with the options classify.mjs
#    uses: the hazards exist. A top-level '- key:' parses to a LIST, an empty or
#    comment-only file to null, minimatch matches no repo-relative file against
#    'infra/', './infra/**' or '/infra/**' (the control 'infra/**' does), and
#    YAML folds a wrapped plain entry and a two-line '>-' block into one
#    pattern that matches neither path. If a future bundle changed any of
#    these, this case says so and the guards' rationale needs a second look.
premise=$(cd "$tmp" && node --input-type=module -e "
import { parse, minimatch } from './classifier-deps.mjs';
const opts = { dot: true, matchBase: false };
const out = [JSON.stringify(parse(\"- blocked: ['**/.env*']\n\"))];
out.push(JSON.stringify(parse('')), JSON.stringify(parse('# only a comment\n')));
for (const p of ['infra/', './infra/**', '/infra/**', 'infra/**']) out.push(minimatch('infra/main.tf', p, opts));
const folded = parse('sensitive:\n  - cmd/**\n    internal/**\n  - >-\n    cmd/**\n    internal/**\n').sensitive;
out.push(JSON.stringify(folded));
out.push(minimatch('cmd/svc/main.go', folded[0], opts), minimatch('internal/x.go', folded[0], opts));
console.log(out.join(' | '));
" 2>/dev/null)
want='[{"blocked":["**/.env*"]}] | null | null | false | false | false | true | ["cmd/** internal/**","cmd/** internal/**"] | false | false'
if [ "$premise" = "$want" ]; then
  echo "✓ premise: a '- key:' top level is a list, an empty file is null; 'infra/', './…' and '/…' match nothing; a wrapped entry folds into one dead pattern"
else
  echo "✗ premise changed — want '$want', got '$premise'"
  failed=1
fi

# 1. A top level that is not a mapping fails closed, named by what it is. A
#    list of one-key mappings is the realistic shape: every line indented as a
#    list item by mistake.
printf '%s\n' "- blocked:" "    - '**/.env*'" "- sensitive:" "    - 'cmd/**'" > "$rules"
expect_fail_closed "a top-level list of '- blocked:' / '- sensitive:' items fails closed" \
  "the top level must be a mapping" "got a list"
printf '%s\n' "- '**/.env*'" "- 'cmd/**'" > "$rules"
expect_fail_closed "a top-level list of bare patterns fails closed" \
  "the top level must be a mapping" "got a list"
printf '%s\n' "blocked" > "$rules"
expect_fail_closed "a top-level bare word (a string) fails closed" \
  "the top level must be a mapping" "got a string"
printf '%s\n' "42" > "$rules"
expect_fail_closed "a top-level number fails closed" \
  "the top level must be a mapping" "got a number"
printf '%s\n' "true" > "$rules"
expect_fail_closed "a top-level boolean fails closed" \
  "the top level must be a mapping" "got a boolean"
# yaml resolves '!!set' and '!!omap' without a warning, even with no '%YAML
# 1.1' directive, into a JS Set and Map: objects, but with no own keys, so
# every gate is gone. The check is for a plain mapping, not for any object.
printf '%s\n' "!!set {blocked, sensitive}" > "$rules"
expect_fail_closed "a top-level '!!set' (a JS Set) fails closed" \
  "the top level must be a mapping" "got a Set"
printf '%s\n' "!!omap" "- blocked: ['**/.env*']" "- sensitive: ['cmd/**']" > "$rules"
expect_fail_closed "a top-level '!!omap' (a JS Map) fails closed" \
  "the top level must be a mapping" "got a Map"

# 2. A file with no rules at all fails closed through fail(), not a TypeError.
: > "$rules"
expect_fail_closed "an empty (0-byte) file fails closed with a message" "holds no rules"
printf '%s\n' "# every rule commented out" "# blocked:" "#   - '**/.env*'" > "$rules"
expect_fail_closed "a comment-only file fails closed with a message" "holds no rules"
printf '%s\n' "---" > "$rules"
expect_fail_closed "a bare '---' document fails closed with a message" "holds no rules"
printf '%s\n' "~" > "$rules"
expect_fail_closed "an explicit null ('~') fails closed with a message" "holds no rules"

# 3. An unknown top-level key fails closed, named exactly (JSON-quoted, so a
#    trailing space shows), with the full list of valid keys. The typos a near-
#    miss check catches, and the ones it does not: a wrong case, a suffix, a
#    synonym, and 'standard', which is the fallback and takes no list.
for key in sensitve Sensitive SENSITIVE BLOCKED safe-test exlcude blocked_paths \
  sensitive_paths exclusions secrets always-review standard 42; do
  printf '%s\n' "blocked:" "  - '**/.env*'" "$key:" "  - 'cmd/**'" > "$rules"
  expect_fail_closed "unknown top-level key '$key:' fails closed" \
    "unknown top-level key \"$key\"" \
    "valid keys are blocked, sensitive, safe_test, safe_deps, safe_config, trivial, always_review, exclude, sensitive_deploy_gated"
done
printf '%s\n' "blocked:" "  - '**/.env*'" "'sensitive ':" "  - 'cmd/**'" > "$rules"
expect_fail_closed "a quoted key with a trailing space ('sensitive ':) fails closed, the space shown" \
  "unknown top-level key \"sensitive \""
printf '%s\n' "blocked:" "  - '**/.env*'" "standard:" "  - 'src/**'" > "$rules"
expect_fail_closed "'standard:' fails closed and says why it is not a key" \
  "unknown top-level key \"standard\"" "'standard' is not a key"
printf '%s\n' "blocked:" "  - '**/.env*'" "sensitve:" "  - 'cmd/**'" "exlcude:" \
  "  sensitive:" "    - 'cmd/**/*_test.go'" > "$rules"
expect_fail_closed "two unknown keys are both named in one message" \
  "unknown top-level keys \"sensitve\", \"exlcude\""

# 4. An entry that ends with '/' or starts with './' or '/' fails closed in
#    every location, and so does one whose brace alternative has that shape.
for where in blocked sensitive safe_test exclude.sensitive always_review; do
  place "$where" "'infra/'"
  expect_fail_closed "'infra/' under $where: fails closed on the trailing '/'" \
    "entry \"infra/\" (under '$where:') ends with '/'" "and the entry matches no changed path" "'infra/**'"
  place "$where" "'infra/**/'"
  expect_fail_closed "'infra/**/' under $where: fails closed on the trailing '/'" \
    "entry \"infra/**/\" (under '$where:') ends with '/'" "matches no changed path"
  place "$where" "'./infra/**'"
  expect_fail_closed "'./infra/**' under $where: fails closed on the leading './'" \
    "entry \"./infra/**\" (under '$where:') starts with './'" "matches no changed path"
  place "$where" "'/infra/**'"
  expect_fail_closed "'/infra/**' under $where: fails closed on the leading '/'" \
    "entry \"/infra/**\" (under '$where:') starts with '/'" "matches no changed path"
  place "$where" "'{infra/,terraform/}'"
  expect_fail_closed "'{infra/,terraform/}' under $where: fails closed on a brace alternative's trailing '/'" \
    "entry \"{infra/,terraform/}\" (under '$where:') ends with '/'" "brace alternative \"infra/\""
  place "$where" "'{./infra,terraform}/**'"
  expect_fail_closed "'{./infra,terraform}/**' under $where: fails closed on a brace alternative's leading './'" \
    "entry \"{./infra,terraform}/**\" (under '$where:') starts with './'" "brace alternative \"./infra/**\""
  # Its other alternative, 'cmd/**', does match: the message must not say the
  # entry matches nothing. (Independent review of this change.)
  place "$where" "'{,./}cmd/**'"
  expect_fail_closed "'{,./}cmd/**' under $where: fails closed on its dead './' alternative alone" \
    "entry \"{,./}cmd/**\" (under '$where:') starts with './'" "and that alternative matches no changed path"
  expect_err_lacks "the entry matches no changed path" "'{,./}cmd/**' under $where: the whole entry is not called dead"
  # ESCAPED, minimatch reads '\.' as a literal '.', so '\./infra/**' is the
  # dead './infra/**' to it: the shape is judged as minimatch reads the entry.
  # A regex habit's '\.github/**' reads as '.github/**' and stays legal (case 6).
  # (Codex review round 6 of this change.)
  place "$where" "'\\./infra/**'"
  expect_fail_closed "'\\./infra/**' under $where: fails closed on the './' minimatch reads" \
    "entry \"\\\\./infra/**\" (under '$where:') starts with './'" "(minimatch reads it as \"./infra/**\")"
  # NEGATED, the same shapes match nearly every path, not none: the negation
  # guard must name them, with its fail-open reason, not this one. (Codex
  # review round 3 of this change.)
  for neg in '!infra/' '!./infra/**' '!/infra/**'; do
    place "$where" "'$neg'"
    expect_fail_closed "'$neg' under $where: gets the negation guard's message" \
      "pattern '$neg' (under '$where:') uses glob negation"
    expect_err_lacks "matches no changed path" "'$neg' under $where: not called dead"
  done
done

# 5. A pattern wrapped over lines fails closed in every location, in each
#    spelling that folds: plain, single- and double-quoted, a two-line '>-' or
#    '>' block, a double-quoted line that ends in an ESCAPED backslash ('\\'),
#    which is a literal '\', not a line join, and a double-quoted line join
#    with a space or tab typed before its '\' — YAML keeps that whitespace, so
#    the lines still join with a space between them (independent review) —
#    and so does an ESCAPED space ('\ '), even on a continuation line, and
#    whitespace spelled as an escape ('\x20', '\t', '\_', '\N') on either side
#    of the join. A double-quoted entry written over several lines is judged on
#    its VALUE: any whitespace in it means a line folded, however it was spelled.
#    (Independent review and Codex review round 5 of this change.)
for where in blocked sensitive safe_test exclude.sensitive always_review; do
  for raw in "cmd/**${nl}        internal/**" \
    "'cmd/**${nl}        internal/**'" \
    "\"cmd/**${nl}        internal/**\"" \
    ">-${nl}        cmd/**${nl}        internal/**" \
    ">${nl}        cmd/**${nl}        internal/**" \
    "\"cmd/\\\\${nl}        internal/**\"" \
    "\"cmd/** \\${nl}        internal/**\"" \
    "\"cmd/**${tab}\\${nl}        internal/**\"" \
    "\"cmd/**\\ \\${nl}        internal/**\"" \
    "\"cmd/\\${nl}        \\ \\${nl}        internal/**\"" \
    "\"cmd/**\\x20\\${nl}        internal/**\"" \
    "\"cmd/**\\t\\${nl}        internal/**\"" \
    "\"cmd/**\\_\\${nl}        internal/**\"" \
    "\"cmd/**\\N\\${nl}        internal/**\"" \
    "\"cmd/**\\${nl}        \\ internal/**\""; do
    place "$where" "$raw"
    expect_fail_closed "a wrapped entry under $where: fails closed — $(printf '%s' "$raw" | tr '\n' '|')" \
      "(under '$where:') is wrapped over" "ONE pattern"
  done
done
# A carriage return that is not part of a CRLF line ending splits readers:
# YAML 1.2, PyYAML, libyaml and Ruby's Psych read a lone CR as a line break,
# while yaml 2.9 (classify's parser) reads it as text. So
# '  - cmd/**<CR>  - internal/**' is two gates to every other reader and ONE
# dead pattern here, and a lone CR ending a comment hides the next "line".
# (Independent review, round 4, of this change.) A lone CR anywhere in the
# file therefore fails closed: in every scalar style, in a comment, and as
# classic-Mac line endings.
for raw in "cmd/**${cr}src/**" "'cmd/**${cr}src/**'" "\"cmd/**${cr}src/**\"" \
  "|-${nl}    cmd/**${cr}src/**" ">-${nl}    cmd/**${cr}src/**" "cmd/**${cr}  - internal/**"; do
  printf '%s\n' "blocked:" "  - '**/.env*'" "sensitive:" "  - $raw" > "$rules"
  expect_fail_closed "a lone CR ($(printf '%s' "$raw" | tr '\r\n' '^|')) fails closed" \
    "a carriage return outside a CRLF line ending"
done
printf '%s\n' "blocked:" "  - '**/.env*'" "sensitive:" "  - 'x/**'" "  # was:${cr}  - 'cmd/**'" > "$rules"
expect_fail_closed "a lone CR ending a comment (it hid the next line from this parser) fails closed" \
  "a carriage return outside a CRLF line ending"
printf 'blocked:\r  - %s\r' "'**/.env*'" > "$rules"
expect_fail_closed "a file with classic-Mac (lone CR) line endings fails closed" \
  "a carriage return outside a CRLF line ending"
# A CR INSIDE a pattern value is not dead, as ci-workflows#231 measured:
# changed paths are split on '\n' and trimmed only at the ends, and git allows
# a CR in a file name. Written explicitly as a '"\r"' escape, it stays legal
# and matches a changed path that holds the CR.
printf '%s\n' "blocked:" "  - '**/.env*'" "sensitive:" '  - "cmd/**\rsrc/**"' > "$rules"
expect_class sensitive "a '\"\\r\"' escape loads and matches a changed path holding the CR" "cmd/foo${cr}src/bar.go"
# The trade-off, pinned: a double-quoted entry with a REAL interior space,
# written over lines with an escaped join, is refused too — it fits on one line.
place sensitive "\"docs/My Notes/\\${nl}        **\""
expect_fail_closed "a double-quoted entry with a real space, written over lines, fails closed" \
  "entry \"docs/My Notes/**\" (under 'sensitive:') is wrapped over" "must hold no whitespace"
# A flow list that is missing a comma folds its two entries into one.
printf '%s\n' "blocked:" "  - '**/.env*'" "safe_deps: [go.sum" "  package-lock.json]" > "$rules"
expect_fail_closed "a flow list missing a comma ('[go.sum' / 'package-lock.json]') fails closed" \
  "entry \"go.sum package-lock.json\" (under 'safe_deps:') is wrapped over" "ONE pattern"
# The same wrapped entry in a CRLF file.
place sensitive "cmd/**${nl}        internal/**"
crlf "$rules"
expect_fail_closed "a wrapped plain entry in a CRLF file fails closed" \
  "entry \"cmd/** internal/**\" (under 'sensitive:') is wrapped over" "ONE pattern"
# Through an alias: the wrapped scalar is anchored under sensitive_deploy_gated,
# whose own entries this script never reads, and used under sensitive:.
printf '%s\n' "blocked:" "  - '**/.env*'" "sensitive_deploy_gated:" "  hold_variable: DEPLOY_HOLD" \
  "  paths:" "    - &wrapped cmd/**" "        internal/**" "sensitive:" "  - *wrapped" > "$rules"
expect_fail_closed "an alias to a wrapped entry fails closed where it is used" \
  "entry \"cmd/** internal/**\" (under 'sensitive:') is wrapped over"
printf '%s\n' "blocked:" "  - '**/.env*'" "sensitive_deploy_gated:" "  hold_variable: DEPLOY_HOLD" \
  "  paths: &gated" "    - cmd/**" "        internal/**" "sensitive: *gated" > "$rules"
expect_fail_closed "an alias to a whole list holding a wrapped entry fails closed" \
  "entry \"cmd/** internal/**\" (under 'sensitive:') is wrapped over"
# Through an alias KEY: '? *cls' is the key 'sensitive' to toJS, so the list
# under it must be walked too. (Codex review round 1 of this change.)
printf '%s\n' "blocked:" "  - '**/.env*'" "  - &cls sensitive" "? *cls" ": - cmd/**" \
  "    internal/**" > "$rules"
expect_fail_closed "a wrapped entry under an alias key ('? *cls' = sensitive) fails closed" \
  "entry \"cmd/** internal/**\" (under 'sensitive:') is wrapped over"
printf '%s\n' "blocked:" "  - '**/.env*'" "  - &cls sensitive" "sensitive:" "  - 'cmd/**'" \
  "exclude:" "  ? *cls" "  : - cmd/**" "      x_test.go" > "$rules"
expect_fail_closed "a wrapped entry under an alias key inside exclude: fails closed" \
  "entry \"cmd/** x_test.go\" (under 'exclude.sensitive:') is wrapped over"
# Through an alias to the whole exclude: map.
printf '%s\n' "blocked:" "  - '**/.env*'" "sensitive:" "  - 'cmd/**'" "sensitive_deploy_gated: &ex" \
  "  sensitive:" "    - cmd/**" "        x_test.go" "exclude: *ex" > "$rules"
expect_fail_closed "an alias to a whole exclude: map holding a wrapped entry fails closed" \
  "entry \"cmd/** x_test.go\" (under 'exclude.sensitive:') is wrapped over"
# A key repeated through an alias key: yaml checks only plain keys for
# duplicates, so toJS() silently keeps the LAST list and the first gate is
# gone ('cmd/**' here). (Independent review of this change.)
printf '%s\n' "blocked:" "  - '**/.env*'" "  - &k sensitive" "sensitive:" "  - 'cmd/**'" "*k :" \
  "  - 'docs/**'" > "$rules"
expect_fail_closed "a class repeated through an alias key fails closed" \
  "the top level repeats the key \"sensitive\""
printf '%s\n' "blocked:" "  - '**/.env*'" "  - &k sensitive" "sensitive:" "  - 'cmd/**'" "exclude:" \
  "  sensitive:" "    - 'cmd/**/*_test.go'" "  *k :" "    - 'cmd/**/*.md'" > "$rules"
expect_fail_closed "an exclude: class repeated through an alias key fails closed" \
  "'exclude:' repeats the key \"sensitive\""
# No alias needs to be involved: '1' beside '"1"' is a repeat to toJS() too,
# and the message must not claim an alias. (Independent review of this change.)
printf '%s\n' "blocked:" "  - '**/.env*'" "exclude:" "  1:" "    - 'a/**'" "  \"1\":" "    - 'b/**'" > "$rules"
expect_fail_closed "'1:' beside '\"1\":' in exclude: fails closed as a repeat" \
  "'exclude:' repeats the key \"1\""
expect_err_lacks "through an alias key" "'1:' beside '\"1\":': the message does not claim an alias"
# A '<<' merge key copies another mapping's keys into this one — with an
# explicit '!!merge' tag, or under '%YAML 1.1' — so a class list would come
# from elsewhere in the file. It is refused wherever classify.mjs reads keys:
# at the top level and in exclude:. Inside exclude: it used to crash.
printf '%s\n' "blocked:" "  - '**/.env*'" "exclude: &m" "  sensitive:" "    - 'cmd/**'" \
  "!!merge <<: *m" > "$rules"
expect_fail_closed "a '!!merge <<' key at the top level fails closed" \
  "the top level uses a '<<' merge key"
printf '%s\n' "%YAML 1.1" "---" "blocked:" "  - '**/.env*'" "exclude: &m" "  sensitive:" \
  "    - 'cmd/**'" "<<: *m" > "$rules"
expect_fail_closed "a '<<' merge key under '%YAML 1.1' fails closed" \
  "the top level uses a '<<' merge key"
printf '%s\n' "%YAML 1.1" "---" "blocked:" "  - '**/.env*'" "sensitive:" "  - &m 'cmd/**'" \
  "exclude:" "  sensitive: &x" "    - 'cmd/**/*_test.go'" "  <<: {sensitive: *x}" > "$rules"
expect_fail_closed "a '<<' merge key inside exclude: fails closed (it used to crash)" \
  "'exclude:' uses a '<<' merge key"

# 6. POSITIVE CONTROL: all nine keys load together — sensitive_deploy_gated in
#    the {hold_variable, paths} shape dotclaude reads — and classify.
cat > "$rules" <<'YAML'
blocked:
  - '**/.env*'
  - '.github/workflows/**'
sensitive:
  - 'cmd/**'
  - '{infra,terraform}/**'
safe_test:
  - 'tests/**'
  - '**/*_test.go'
safe_deps:
  - 'go.sum'
safe_config:
  - '.editorconfig'
trivial:
  - 'docs/**'
always_review:
  - 'scripts/deploy.sh'
exclude:
  sensitive:
    - 'cmd/**/*_test.go'
sensitive_deploy_gated:
  hold_variable: DEPLOY_HOLD
  paths:
    - 'cmd/svc/handler.go'
YAML
expect_class blocked "all nine keys: a workflow ('.github/workflows/ci.yml', leading '.') classifies blocked" .github/workflows/ci.yml
expect_class sensitive "all nine keys: a brace alternative ('terraform/main.tf') gates" terraform/main.tf
expect_class safe_test "all nine keys: an exclusion still subtracts (cmd/svc/main_test.go)" cmd/svc/main_test.go
expect_class safe_deps "all nine keys: go.sum classifies safe_deps" go.sum
expect_class safe_config "all nine keys: .editorconfig classifies safe_config" .editorconfig
expect_class trivial "all nine keys: docs/a.md classifies trivial" docs/a.md
expect_class standard "all nine keys: an unmatched path falls back to standard" src/app.py
# An alias key is legal YAML and stays legal: it resolves to the key it names.
printf '%s\n' "blocked:" "  - '**/.env*'" "  - &cls sensitive" "? *cls" ": - 'cmd/**'" > "$rules"
expect_class sensitive "an alias key ('? *cls' = sensitive) still gates (cmd/svc/main.go)" cmd/svc/main.go

# Every spelling that does NOT fold: a single-line '>-' block, a double-quoted
# escaped line join (the '\' joins the lines with nothing between them), a flow
# list that spans lines WITH its comma, a trailing comment, a blank line
# between keys, a plain entry with an interior space, and a pattern that starts
# with '.' but not './'. Run in LF, then again in CRLF.
cat > "$rules" <<'YAML'
# a comment line
blocked:
  - '**/.env*'   # a trailing comment

sensitive:
  - >-
    scripts/folded.sh
  - "scripts/\
    joined.sh"
  - "scripts/\
    \
    chained.sh"
  - '.github/actions/**'
  - '\.vscode/**'
safe_deps: ['go.sum',
  'package-lock.json']
trivial:
  - docs/My Notes/**
  - "docs/Team Notes/**"
YAML
for endings in LF CRLF; do
  if [ "$endings" = CRLF ]; then crlf "$rules"; fi
  expect_class sensitive "$endings: a single-line '>-' block gates (scripts/folded.sh)" scripts/folded.sh
  expect_class sensitive "$endings: an escaped double-quoted line join gates (scripts/joined.sh)" scripts/joined.sh
  # The middle line holds only its indentation and a '\': YAML strips that
  # indentation, so the value is 'scripts/chained.sh'. (Codex review round 4.)
  expect_class sensitive "$endings: a join chained over a line holding only '\\' gates (scripts/chained.sh)" scripts/chained.sh
  expect_class sensitive "$endings: a '.github/…' entry is not a './' entry" .github/actions/setup/action.yml
  expect_class sensitive "$endings: an escaped '\\.vscode/**' reads as '.vscode/**' and gates" .vscode/settings.json
  expect_class safe_deps "$endings: a flow list spanning lines with its comma matches (package-lock.json)" package-lock.json
  expect_class trivial "$endings: a plain entry with an interior space matches" "docs/My Notes/a.md"
  expect_class trivial "$endings: a one-line double-quoted entry with an interior space matches" "docs/Team Notes/a.md"
  expect_class blocked "$endings: an entry with a trailing comment matches (.env)" .env
done

exit "$failed"
