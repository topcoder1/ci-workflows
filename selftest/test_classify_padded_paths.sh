#!/usr/bin/env bash
# Behavioral test: classify.mjs must judge each changed path EXACTLY as named,
# and FAIL CLOSED on a path that starts or ends with whitespace, instead of
# trimming it into a different path.
#
# Why. classify.mjs trimmed every changed path before matching it, so a real
# file name with leading or trailing whitespace was classified as another
# path. With `sensitive: ['docs/customer/*']`,
# `exclude: {sensitive: ['docs/customer/public.md']}` and `trivial: ['docs/**']`:
#   - `docs/customer/public.md ` (a trailing space) is not the excluded file,
#     but it was trimmed into it and classified `trivial`, where `sensitive`
#     is right;
#   - a file named ` ` in docs/customer/ is `docs/customer/ `, which matches
#     `docs/customer/*`; trimmed to `docs/customer/`, it did not, and it
#     classified `trivial`;
#   - a whitespace-only name at the root was trimmed to nothing and dropped,
#     so the classifier never saw it.
# JavaScript's trim() also strips a no-break space (U+00A0), U+2028, U+3000 and
# the byte-order mark U+FEFF, which show as a space or as nothing, and a tab or
# carriage return. Found by the Codex pre-review of topcoder1/ci-workflows#312,
# whose guard stops control characters (the tab and CR among them) before a
# name reaches classify.mjs from the workflows; this stop covers the rest, for
# every caller.
#
# classify.mjs now keeps each path as given, drops only EMPTY lines, and exits
# nonzero, naming the path, on any path trim() would change. Pins:
#   1. It stops on each padded shape: a trailing space (the exclude example), a
#      whitespace-only name in a gated directory, a leading space, a
#      whitespace-only name at the root, a trailing tab, a trailing CR, a
#      no-break space, U+2028, a leading BOM and U+3000. It exits nonzero
#      through its own fail() ('classify.mjs: '), prints no class, and names
#      the path JSON-quoted with every whitespace character but the plain space
#      escaped, so the padding shows in a log.
#   2. A padded path among plain ones stops the run too.
#   3. Controls: the excluded file itself is still excluded, a gated file still
#      gates, names with interior spaces, accents and an emoji classify as
#      before, blank lines are still dropped, and an empty list is still
#      `standard`.
#   4. Mutation controls: with the stop's test replaced by `false`, the padded
#      names classify by their REAL names, so nothing else trims them; and each
#      one's trimmed reading classifies `trivial` under the same rules, so the
#      fixtures reproduce the escape a trim made.
#   5. Every workflow caller fails closed in its existing shape. The shipped
#      steps run against a stub `gh` and the real classify.mjs on a PR adding
#      `docs/customer/public.md `: pr-classify.yml's compute step exits nonzero
#      and writes no class, so no new risk:* label is written (one from an
#      earlier revision stays, as on any failure of that step);
#      claude-author-automerge.yml's classifier lane exits nonzero and writes no
#      verdict, so its error revoke disarms; safe-paths-automerge.yml's tier 3
#      holds with `classifier-error`, which its revoke acts on. The same PR
#      without the space classifies `trivial` in all three, as the exclusion
#      says. (dotclaude's bb-pr-deploy-gated.sh, the fourth caller, reports a
#      nonzero classify.mjs exit as FAIL-CLOSED; it is not in this repo.)
#
# Every fixture and expected verdict is HARDCODED, never read back from
# classify.mjs.
#
# Run from the repo root:
#   bash selftest/test_classify_padded_paths.sh
set -euo pipefail

NEEDLE='starts or ends with whitespace'
failed=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# Whitespace trim() strips, built from bytes: bash 3.2 has no \u escapes.
TAB=$(printf '\t')
CR=$(printf '\r')
NBSP=$(printf '\302\240')     # U+00A0 NO-BREAK SPACE
LSEP=$(printf '\342\200\250') # U+2028 LINE SEPARATOR
IDSP=$(printf '\343\200\200') # U+3000 IDEOGRAPHIC SPACE
BOM=$(printf '\357\273\277')  # U+FEFF BYTE ORDER MARK

# classify.mjs imports its deps from classifier-deps.mjs beside it, and runs
# from the caller's checkout, where .github/risk-paths.yml sits.
mkdir -p "$T/repo/.github" "$T/scripts" "$T/bin" "$T/fx"
cp .github/scripts/classify.mjs .github/scripts/classifier-deps.mjs "$T/scripts/"
cat > "$T/rules.yml" <<'YAML'
sensitive:
  - 'docs/customer/*'
exclude:
  sensitive:
    - 'docs/customer/public.md'
trivial:
  - 'docs/**'
YAML
cp "$T/rules.yml" "$T/repo/.github/risk-paths.yml"

# Mutant: the stop's test replaced by `false`. It must differ from the shipped
# script, or the mutation controls below would prove nothing.
sed 's/if (f !== f\.trim())/if (false)/' .github/scripts/classify.mjs > "$T/scripts/classify-unstopped.mjs"
if cmp -s .github/scripts/classify.mjs "$T/scripts/classify-unstopped.mjs"; then
  echo "✗ no stop to cut out of classify.mjs — it does not test each changed path with 'f !== f.trim()'"
  failed=1
  mutant_ok=0
else
  mutant_ok=1
fi

# run_classify <script> <path...> — the paths one per line on stdin, run from
# the caller's checkout as every caller runs it; sets RC, OUT and ERR.
run_classify() {
  local script=$1
  shift
  set +e
  OUT=$(printf '%s\n' "$@" | (cd "$T/repo" && node "$T/scripts/$script") 2> "$T/err")
  RC=$?
  set -e
  ERR=$(cat "$T/err")
}

bad() {
  echo "✗ $1 — $2. stderr:"
  printf '%s\n' "$ERR" | sed 's/^/    /'
  failed=1
}

# expect_stop <desc> <shown> <path...> — a nonzero exit through fail(), no class
# on stdout, and a message naming the padded path as <shown>. Matched with
# `case`, so no pipe can race it.
expect_stop() {
  local desc=$1 shown=$2 named=0
  shift 2
  run_classify classify.mjs "$@"
  case "$ERR" in
    "classify.mjs: changed path $shown $NEEDLE"*) named=1 ;;
  esac
  if [ "$RC" -ne 0 ] && [ -z "$OUT" ] && [ "$named" = 1 ]; then
    echo "✓ $desc"
  else
    bad "$desc" "want a nonzero exit, no class, and stderr starting 'classify.mjs: changed path $shown $NEEDLE'; got rc=$RC, stdout '$OUT'"
  fi
}

# expect_class <script> <want> <desc> <path...> — exit 0 and <want> on stdout.
expect_class() {
  local script=$1 want=$2 desc=$3
  shift 3
  run_classify "$script" "$@"
  if [ "$RC" -eq 0 ] && [ "$OUT" = "$want" ]; then
    echo "✓ $desc"
  else
    bad "$desc" "want exit 0 and '$want'; got rc=$RC, stdout '$OUT'"
  fi
}

# 1. Each padded shape stops.
expect_stop "a trailing space stops: the excluded file's padded twin is not read as the excluded file" \
  '"docs/customer/public.md "' 'docs/customer/public.md '
expect_stop "a whitespace-only name in a gated directory stops" '"docs/customer/ "' 'docs/customer/ '
expect_stop "a leading space stops" '" docs/customer/public.md"' ' docs/customer/public.md'
expect_stop "a whitespace-only name at the root stops instead of being dropped" '" "' 'docs/guide.md' ' '
expect_stop "a trailing tab stops" '"docs/customer/public.md\t"' "docs/customer/public.md$TAB"
expect_stop "a trailing carriage return stops" '"docs/customer/public.md\r"' "docs/customer/public.md$CR"
expect_stop "a trailing no-break space stops, shown escaped" '"docs/customer/public.md\u00a0"' "docs/customer/public.md$NBSP"
expect_stop "a trailing U+2028 stops, shown escaped" '"docs/customer/public.md\u2028"' "docs/customer/public.md$LSEP"
expect_stop "a leading byte-order mark stops, shown escaped" '"\ufeffdocs/customer/public.md"' "${BOM}docs/customer/public.md"
expect_stop "a trailing ideographic space stops, shown escaped" '"docs/customer/public.md\u3000"' "docs/customer/public.md$IDSP"

# 2. Among plain names.
expect_stop "a padded path after plain ones stops the run" '"docs/customer/ "' \
  'docs/guide.md' 'docs/My Notes/a.md' 'docs/customer/ '

# 3. Controls.
expect_class classify.mjs trivial "control: the excluded file itself is still excluded" 'docs/customer/public.md'
expect_class classify.mjs sensitive "control: a gated file still gates" 'docs/customer/terms.md'
expect_class classify.mjs sensitive "control: a gated name with interior spaces, accents and an emoji still gates" \
  'docs/customer/My Terms résumé 🚀.md'
expect_class classify.mjs trivial "control: a docs name with interior spaces, accents and an emoji classifies as before" \
  'docs/My Notes/résumé 🚀.md'
expect_class classify.mjs trivial "control: blank lines are still dropped (kept, one would read as an unmatched path: standard)" \
  '' 'docs/guide.md' '' '' 'docs/My Notes/a.md' ''
expect_class classify.mjs standard "control: an empty list is still standard" ''

# 4. Mutation controls: the real names gate, and their trimmed readings do not.
if [ "$mutant_ok" = 1 ]; then
  expect_class classify-unstopped.mjs sensitive "control: unstopped, 'docs/customer/public.md ' classifies by its real name" \
    'docs/customer/public.md '
  expect_class classify-unstopped.mjs sensitive "control: unstopped, 'docs/customer/ ' classifies by its real name" \
    'docs/customer/ '
  expect_class classify-unstopped.mjs standard "control: unstopped, a root ' ' is judged by its real name, not dropped" \
    'docs/guide.md' ' '
fi
expect_class classify.mjs trivial "escape: trimmed, 'docs/customer/public.md ' reads as the excluded file" \
  'docs/customer/public.md'
expect_class classify.mjs trivial "escape: trimmed, 'docs/customer/ ' misses docs/customer/*" 'docs/customer/'
expect_class classify.mjs trivial "escape: trimmed away, a root ' ' leaves plain docs" 'docs/guide.md'

# ---------------------------------------------------------------------------
# 5. Every workflow caller fails closed in its existing shape. Each step's bash
#    is extracted from its workflow, de-indented, and run against a stub `gh`
#    that answers the files API through the step's own --jq with real jq and
#    serves this repo's classify.mjs and the rules above as the base ref's, as
#    in selftest/test_classify_control_char_paths.sh.
# ---------------------------------------------------------------------------
extract_step() {
  awk -v id="$2" '
    $0 ~ ("^        id: " id "[[:space:]]*$") { in_step = 1; next }
    in_step && /^        run: \|[[:space:]]*$/ { in_run = 1; next }
    in_run {
      if ($0 ~ /^          / || $0 ~ /^[[:space:]]*$/) { sub(/^          /, ""); print }
      else exit
    }
  ' "$1"
}
LANES="pr_classify am_classifier sp_tier3"
lane_wf() {
  case "$1" in
    pr_classify) echo .github/workflows/pr-classify.yml ;;
    am_classifier) echo .github/workflows/claude-author-automerge.yml ;;
    sp_tier3) echo .github/workflows/safe-paths-automerge.yml ;;
  esac
}
lane_id() {
  case "$1" in
    pr_classify) echo compute ;;
    am_classifier) echo classifier_verdict ;;
    sp_tier3) echo classifier_hold ;;
  esac
}
for lane in $LANES; do
  extract_step "$(lane_wf "$lane")" "$(lane_id "$lane")" > "$T/$lane.sh"
  if ! grep -q 'classify\.mjs' "$T/$lane.sh" || ! grep -q 'GITHUB_OUTPUT' "$T/$lane.sh"; then
    echo "✗ could not extract the $(lane_id "$lane") step from $(lane_wf "$lane")"
    exit 1
  fi
done

printf '%s' '[{"filename":"docs/customer/public.md ","status":"added"}]' > "$T/fx/padded.json"
printf '%s' '[{"filename":"docs/customer/public.md","status":"modified"}]' > "$T/fx/plain.json"

# Stub `gh`: the files API from $STUB_FILES_JSON through the caller's own --jq
# (one page of per_page without --paginate, up to the API's 3000-entry cap
# with it), a fixed head, no labels, no standing arm, and the base ref's rules
# and classifier as base64 contents.
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
args="$*"
jq_filter() { while [ $# -gt 0 ]; do [ "$1" = "--jq" ] && { printf '%s' "$2"; return 0; }; shift; done; return 1; }
case "$args" in
  *pulls/*/files*)
    filter=$(jq_filter "$@") || { echo "gh-stub: files call without --jq: $args" >&2; exit 64; }
    url="${2:-}"
    limit=30
    case "$url" in *per_page=*) limit="${url##*per_page=}"; limit="${limit%%&*}" ;; esac
    case " $args " in *" --paginate "*) limit=3000 ;; esac
    jq -r ".[:$limit] | $filter" "$STUB_FILES_JSON"
    ;;
  *"--jq .head.sha"*) printf '%s\n' "$STUB_HEAD" ;;
  *auto_merge*) echo none ;;
  *labels*) : ;;
  *contents/.github/risk-paths.yml*) base64 < "$STUB_RULES" ;;
  *contents/.github/scripts/classify.mjs*) base64 < "$STUB_SCRIPTS/classify.mjs" ;;
  *contents/.github/scripts/classifier-deps.mjs*) base64 < "$STUB_SCRIPTS/classifier-deps.mjs" ;;
  *) echo "gh-stub: unexpected call: $args" >&2; exit 64 ;;
esac
STUB
chmod +x "$T/bin/gh"
# The steps' retry helpers sleep between attempts.
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/sleep"
chmod +x "$T/bin/sleep"

# run_lane <lane> <fixture> — sets RC and LOG; outputs in $T/out.
run_lane() {
  : > "$T/out"
  set +e
  LOG=$(cd "$T/repo" && PATH="$T/bin:$PATH" GH_TOKEN=stub PR=7 \
    GITHUB_REPOSITORY=acme/fixture REPO=acme/fixture BASE_REF=main DEFAULT_BRANCH=main \
    CLASSIFY_SCRIPTS="$T/scripts" GITHUB_OUTPUT="$T/out" RISK_MAIN_GO=true BYPASS_LABEL='' \
    EXTRA_GLOBS='' PR_AUTHOR=someone STANDING_ARM='' \
    STUB_FILES_JSON="$T/fx/$2.json" STUB_RULES="$T/rules.yml" STUB_SCRIPTS="$T/scripts" \
    STUB_HEAD=c0ffee0000000000000000000000000000000001 \
    bash "$T/$1.sh" 2>&1 < /dev/null)
  RC=$?
  set -e
}
out_get() { grep "^$1=" "$T/out" | tail -1 | cut -d= -f2- || true; }
lane_bad() {
  echo "✗ $1 — $2. Output:"
  printf '%s\n' "$LOG" | sed 's/^/    /'
  failed=1
}

run_lane pr_classify padded
if [ "$RC" -ne 0 ] && ! grep -q '^class=' "$T/out" && grep -q "$NEEDLE" <<<"$LOG"; then
  echo "✓ pr-classify: a padded name stops the compute step with no class, so no new risk:* label is written"
else
  lane_bad "pr-classify: a padded name stops the compute step" "want a nonzero exit, no class= and '$NEEDLE' in the log; got rc=$RC, class='$(out_get class)'"
fi
run_lane am_classifier padded
if [ "$RC" -ne 0 ] && ! grep -q '^blocked=' "$T/out" && grep -q "$NEEDLE" <<<"$LOG"; then
  echo "✓ automerge: a padded name fails the classifier lane with no verdict, so its error revoke disarms"
else
  lane_bad "automerge: a padded name fails the classifier lane" "want a nonzero exit, no blocked= and '$NEEDLE' in the log; got rc=$RC, blocked='$(out_get blocked)'"
fi
run_lane sp_tier3 padded
if [ "$RC" -eq 0 ] && [ "$(out_get hold)" = 1 ] && [ "$(out_get reason)" = classifier-error ] \
  && ! grep -q '^hold=0$' "$T/out" && grep -q "$NEEDLE" <<<"$LOG"; then
  echo "✓ safe-paths: a padded name holds tier 3 with classifier-error, naming the path"
else
  lane_bad "safe-paths: a padded name holds tier 3" "want rc=0, hold=1, reason=classifier-error and '$NEEDLE' in the log; got rc=$RC, hold='$(out_get hold)', reason='$(out_get reason)'"
fi
for lane in $LANES; do
  run_lane "$lane" plain
  case "$lane" in
    pr_classify) key=class want=trivial ;;
    am_classifier) key=blocked want=0 ;;
    sp_tier3) key=hold want=0 ;;
  esac
  if [ "$RC" -eq 0 ] && [ "$(out_get "$key")" = "$want" ] && ! grep -q "$NEEDLE" <<<"$LOG"; then
    echo "✓ $lane control: the same PR without the space reads $key=$want (the excluded file)"
  else
    lane_bad "$lane control: the same PR without the space" "want rc=0 and $key=$want; got rc=$RC, $key='$(out_get "$key")'"
  fi
done

echo ""
if [ "$failed" -ne 0 ]; then
  echo "FAIL: classify.mjs does not judge padded paths as named, or a caller does not fail closed."
  exit 1
fi
echo "OK: classify.mjs stops on padded paths, and every caller fails closed."
