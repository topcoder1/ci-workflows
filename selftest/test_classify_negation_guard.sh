#!/usr/bin/env bash
# Guards classify.mjs's glob-negation ban in the SAFE classes (safe_test,
# safe_deps, safe_config, trivial).
#
# The ban used to cover only the gating classes (blocked/sensitive, where
# negation breaks the case-fold invariant — test_classify_nocase.sh case 10)
# and the exclude: lists. In a safe class, negation is a fail-OPEN with no fold
# involved. Under minimatch a negated pattern matches every path EXCEPT the one
# it names, and classify() returns the first class with a match, so a single
# gitignore-style entry,
#
#     safe_test: ['tests/**', '!tests/fixtures/**']
#
# classifies every file that is not blocked or sensitive as safe_test: all of
# the repo's `standard` code, and every file a future PR adds, becomes
# auto-merge eligible. Found by an independent code review during work on
# topcoder1/webcrawl#579 (2026-09-22). The fleet audit taken before the ban was
# extended is recorded on the guard itself in classify.mjs.
#
# Case 5 covers a spelling the raw-string check could not see: brace expansion
# SYNTHESIZES an extglob negation ('{!,@}(tests)/**' -> '!(tests)/**'), in any
# class and in exclude: alike.
#
# Case 9 covers always_review, which the ban skipped until 2026-09-23 although
# the list-shape and bracket passes already validated it: codex-gate.mjs forces
# a Codex review on any match, so a negated entry exempts the one path it names
# from that forced review. test_codex_gate_priority.sh pins the rule order that
# gives always_review its force in the first place.
#
# The class list and every expected verdict below are HARDCODED, never read
# back from classify.mjs: a test that derives its expectations from the
# artifact under test cannot catch that artifact narrowing.
#
# Run from the repo root:
#   bash selftest/test_classify_negation_guard.sh
set -euo pipefail

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# classify.mjs imports its deps from classifier-deps.mjs sitting beside it —
# the same committed, version-pinned bundle pr-classify.yml fetches into
# .github/scripts/. Copying both mirrors the workflow's on-disk layout exactly.
cp .github/scripts/classify.mjs .github/scripts/classifier-deps.mjs "$tmp/"

mkdir -p "$tmp/repo/.github"
failed=0

rules() { printf '%s' "$1" > "$tmp/repo/.github/risk-paths.yml"; }

# run_classifier <file...> — sets $rc, $out (stdout) and $err (stderr).
run_classifier() {
  set +e
  out=$(printf '%s\n' "$@" | (cd "$tmp/repo" && node "$tmp/classify.mjs") 2> "$tmp/stderr")
  rc=$?
  set -e
  err=$(cat "$tmp/stderr")
}

# expect_class <want> <description> <file...>
expect_class() {
  local want="$1" desc="$2"
  shift 2
  run_classifier "$@"
  if [ "$rc" -eq 0 ] && [ "$out" = "$want" ]; then
    echo "✓ $desc"
  else
    echo "✗ $desc — expected exit 0 + '$want'; got rc=$rc, stdout '$out':"
    if [ -n "$err" ]; then printf '%s\n' "$err" | sed 's/^/    /'; fi
    failed=1
  fi
}

# expect_fail_closed <description> <needle...> — the classifier must exit
# nonzero, print NO class on stdout, and name every needle on stderr. The
# needles are matched with `case`, not `grep -q`, so no pipe can race them.
expect_fail_closed() {
  local desc="$1" needle missing=""
  shift
  run_classifier "src/app.py"
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
# not contain <needle>. Each tier's reason is distinct, so routing a class to
# the other tier's message has to show up as a failure, not pass silently. An
# EMPTY message fails too: a check that passes on silence proves nothing.
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

# 0. PREMISE, pinned against the shipped matcher with classify.mjs's own
#    options: a negated pattern matches paths it does not name. This is the
#    hazard the ban exists for. If a future bundle stopped inverting '!', this
#    case says so and the ban's rationale needs a second look.
premise=$(cd "$tmp" && node --input-type=module -e "
import { minimatch } from './classifier-deps.mjs';
const o = { dot: true, matchBase: false };
console.log([
  minimatch('src/webcrawl/aws_pipeline/crawl_lock.py', '!no_such_file', o),
  minimatch('src/app.py', '!tests/fixtures/**', o),
  minimatch('tests/fixtures/data.json', '!tests/fixtures/**', o),
  minimatch('src/deploy.sh', 'src/!(*.md)', o),
  minimatch('src/app.py', '{!,@}(tests)/**', o),
].join(' '));
" < /dev/null)
if [ "$premise" = "true true false true true" ]; then
  echo "✓ premise: a negated pattern matches every path except the one it names"
else
  echo "✗ premise: expected 'true true false true true' from the vendored minimatch, got '$premise'"
  failed=1
fi

# 1. THE BUG — the gitignore-style shape from the finding. Before the ban,
#    src/app.py matched only the negated entry, classified safe_test, and was
#    auto-merge eligible.
rules "blocked:
  - '**/.env'
sensitive:
  - 'src/auth/**'
safe_test:
  - 'tests/**'
  - '!tests/fixtures/**'
"
expect_fail_closed "gitignore-style '!tests/fixtures/**' under safe_test: fails closed" \
  "uses glob negation" "(under 'safe_test:')" "auto-merge-eligible tier"

# 2. POSITIVE CONTROL. The same rules minus the negated line load and classify
#    normally, so case 1 fails because of that line alone — not because this
#    harness cannot run the classifier.
rules "blocked:
  - '**/.env'
sensitive:
  - 'src/auth/**'
safe_test:
  - 'tests/**'
"
expect_class standard "control: without the '!' line, src/app.py falls back to standard" src/app.py
expect_class safe_test "control: without the '!' line, tests/unit/test_app.py is safe_test" tests/unit/test_app.py

# 3. Every safe class, not only safe_test. Hardcoded on purpose.
for cls in safe_test safe_deps safe_config trivial; do
  rules "blocked: []
$cls:
  - '!docs/**'
"
  expect_fail_closed "leading-'!' negation under $cls: fails closed" \
    "uses glob negation" "(under '$cls:')" "auto-merge-eligible tier"
  expect_err_lacks "case-insensitively" "...and $cls: is not given the case-fold reason"
done

# 4. ...and the extglob spelling of the same complement. 'src/!(*.md)' claims
#    every non-markdown file under src/, including ones a future PR adds (and
#    '**/!(*.md)' every non-markdown file in the repo).
for cls in safe_test safe_deps safe_config trivial; do
  rules "blocked: []
$cls:
  - 'src/!(*.md)'
"
  expect_fail_closed "segment extglob negation under $cls: fails closed" \
    "uses glob negation" "(under '$cls:')" "auto-merge-eligible tier"
done

# 5. Brace expansion can SYNTHESIZE an extglob negation the raw pattern never
#    spells: minimatch expands '{!,@}(tests)/**' to '!(tests)/**' plus
#    '@(tests)/**', which together match every path below the root. Neither a
#    leading '!' nor the substring '!(' appears in the raw pattern, so a
#    raw-string check passed it (Codex round 1 on this change). The guard must
#    read minimatch's own expansion, at every call site: safe class, gating
#    class, exclusion.
rules "blocked: []
safe_test:
  - '{!,@}(tests)/**'
"
expect_fail_closed "brace-synthesized '!(…)' under safe_test: fails closed" \
  "uses glob negation" "(under 'safe_test:')" "auto-merge-eligible tier"

rules "blocked: []
sensitive:
  - 'src/{!,x}(*.md)'
"
expect_fail_closed "brace-synthesized '!(…)' under sensitive: fails closed" \
  "uses glob negation" "(under 'sensitive:')" "case-insensitively"

rules "blocked: []
sensitive:
  - 'cmd/svc/**'
exclude:
  sensitive:
    - 'cmd/svc/{!,@}(*_test.go)'
"
expect_fail_closed "brace-synthesized '!(…)' in an exclusion fails closed" \
  "uses glob negation" "(under 'exclude.sensitive:')"

# 6. The gating classes keep THEIR reason — the case-fold downgrade pinned in
#    test_classify_nocase.sh case 10. Extending the ban must not blur the two
#    messages: an author told the wrong reason fixes the wrong thing.
for cls in blocked sensitive; do
  rules "$cls:
  - '!foo'
"
  expect_fail_closed "negation under $cls: still cites the case-fold reason" \
    "uses glob negation" "(under '$cls:')" "case-insensitively"
  expect_err_lacks "auto-merge-eligible tier" "...and $cls: is not given the safe-class reason"
done

# 7. POSITIVE CONTROL for the ban's precision. minimatch negates only on a
#    leading '!' or a '!(' extglob; a '!' anywhere else is a literal character,
#    so it must keep loading. The ban is on negation, not on the character.
rules "blocked: []
trivial:
  - 'docs/wow!/**'
"
expect_class trivial "control: a literal mid-pattern '!' still loads and matches" "docs/wow!/notes.md"

# ...and reading the brace expansion must not reject ordinary braces.
rules "blocked: []
safe_test:
  - '{tests,spec}/**'
"
expect_class safe_test "control: an ordinary brace pattern still loads and matches" spec/test_app.py

# 8. The rewrite the error message recommends does what the '!' line meant:
#    exclude: subtracts only the paths it names, so fixtures fall back to
#    standard while the rest of tests/ stays safe_test and src/ stays standard.
rules "blocked: []
safe_test:
  - 'tests/**'
exclude:
  safe_test:
    - 'tests/fixtures/**'
"
expect_class safe_test "rewrite: tests/unit/test_app.py is still safe_test" tests/unit/test_app.py
expect_class standard "rewrite: tests/fixtures/data.json falls back to standard" tests/fixtures/data.json
expect_class standard "rewrite: src/app.py stays standard" src/app.py

# 9. always_review. classify.mjs never matches it, but validates it for
#    codex-gate.mjs, which forces a Codex review when ANY changed file matches
#    ANY entry and applies a negated entry as the valid glob it is. A negated
#    entry forces review on every path EXCEPT the one it names, so that
#    path's small and docs/tests-only diffs skip Codex. The finding
#    (independent review on whois-api-llc/wxa_webcat#1612, 2026-09-23)
#    measured exactly this entry passing classify.mjs with exit 0. Every
#    spelling the other guard sites reject is rejected here too.
for pattern in '!scripts/la1_deploy_ssh_setup.sh' 'scripts/!(la1_deploy_ssh_setup.sh)' '{!,@}(scripts)/**'; do
  rules "blocked: []
always_review:
  - '$pattern'
"
  expect_fail_closed "negation '$pattern' under always_review: fails closed" \
    "uses glob negation" "(under 'always_review:')" "skip Codex"
  expect_err_lacks "case-insensitively" "...and always_review: is not given the case-fold reason"
  expect_err_lacks "auto-merge-eligible tier" "...and always_review: is not given the safe-class reason"
done

# 10. POSITIVE CONTROL. The same entry without the '!' loads, so case 9 fails
#     because of the negation alone. always_review is never a classify.mjs
#     class, so the named path falls back to standard. A literal mid-pattern
#     '!' stays legal here as everywhere else.
rules "blocked: []
always_review:
  - 'scripts/la1_deploy_ssh_setup.sh'
  - 'docs/wow!/**'
"
expect_class standard "control: a plain always_review entry loads and exits 0" scripts/la1_deploy_ssh_setup.sh

exit "$failed"
