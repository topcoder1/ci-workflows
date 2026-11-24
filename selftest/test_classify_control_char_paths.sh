#!/usr/bin/env bash
# Behavioral test: every step that hands a PR's changed-file names to a
# one-name-per-line classifier must FAIL CLOSED when a name, or a rename
# source, holds a control character: a C0 character (U+0000-U+001F, which
# takes in the line break and the tab) or DEL (U+007F).
#
# Why. The files API returns each name whole, but these steps pass the names
# on one per line: to classify.mjs, and to `while read` loops over the fleet
# risk-tier regex. Git allows a line break in a file name, and such a name is
# then read as two names, each judged alone. The halves can slip past a glob
# the whole name matches: `docs/customer/terms<LF>docs/guide.md` matches
# `docs/customer/**/*.md`, while its halves match only `docs/**`. A
# `sensitive:` path then classifies `trivial`, the automerge bot arms
# standard and trivial PRs, and safe-paths arms docs-only ones. Found by the
# Codex pre-review of topcoder1/dotclaude#738 (2026-11-24), which closed the
# same hole in the babysit-prs loop.
#
# The steps:
#   pr-classify.yml              compute             the risk:* label and risk_class
#   claude-author-automerge.yml  classifier_verdict  the caller's risk-paths.yml lane
#   claude-author-automerge.yml  risk                the fleet risk-tier regex lane
#   safe-paths-automerge.yml     classify            tiers 1 and 2
#   safe-paths-automerge.yml     classifier_hold     tier 3, the caller's risk-paths.yml
#
# Each step's bash is EXTRACTED from its workflow and run against a stub `gh`
# that answers every files-API call by running the step's OWN --jq filter over
# a gh-shaped JSON response with real jq, and against the REAL classify.mjs.
# Pins, per step:
#   1. A changed file whose name holds a line break fails closed, in the shape
#      that step fails closed elsewhere: pr-classify and both automerge lanes
#      exit nonzero with an ::error:: and write no verdict (the automerge job's
#      error revoke then disarms); the two safe-paths steps exit 0 with a
#      verdict that withholds the arm and fires the revoke step (a failed step
#      there would skip that revoke).
#   2. A rename SOURCE holding a tab fails closed the same way: every C0
#      character counts, not only the line break, and the rename listing is
#      guarded as well as the changed-file listing.
#   3. Both ends of the range: DEL in a changed name, and U+001F in a rename
#      source.
#   4. Controls: plain names, with spaces and non-ASCII letters, classify as
#      before; a plain gated path still gates.
#   5. Mutation controls: the same step with the guard's test replaced by
#      `false` does NOT fail closed on the cases of 1 and 2, so those verdicts
#      come from the guard and not from the harness. On the line-break case the
#      unguarded step reproduces the escape: a benign verdict for a name whose
#      whole is gated (pin 8).
# And structurally:
#   6. Every files-API listing in the three workflows ends in the guard, so a
#      new listing that forgets it fails here. Expected counts are hardcoded,
#      and a negative control proves the check can fail.
#   7. safe-paths' revoke step fires on the classify step's new verdict.
#   8. The line-break fixture's WHOLE name matches the gated glob and neither
#      half does (minimatch from the vendored bundle classify.mjs uses), so the
#      benign verdict in 5 is an escape, not a correct answer.
#
# Run from the repo root:
#   bash selftest/test_classify_control_char_paths.sh
set -euo pipefail

GUARD='if (explode | any(. < 32 or . == 127)) then "/CONTROL-CHARACTER-IN-PATH" else . end'
NEEDLE='holds a control character'
REASON='control-character-path'
failed=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# ---------------------------------------------------------------------------
# Extract each step's run block, de-indented: from its `run: |` to the end of
# the block scalar.
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

LANES="pr_classify am_classifier am_risk sp_classify sp_tier3"
lane_wf() {
  case "$1" in
    pr_classify) echo .github/workflows/pr-classify.yml ;;
    am_classifier | am_risk) echo .github/workflows/claude-author-automerge.yml ;;
    sp_classify | sp_tier3) echo .github/workflows/safe-paths-automerge.yml ;;
  esac
}
lane_id() {
  case "$1" in
    pr_classify) echo compute ;;
    am_classifier) echo classifier_verdict ;;
    am_risk) echo risk ;;
    sp_classify) echo classify ;;
    sp_tier3) echo classifier_hold ;;
  esac
}

mutants_ok=1
for lane in $LANES; do
  extract_step "$(lane_wf "$lane")" "$(lane_id "$lane")" > "$T/$lane.sh"
  if ! grep -q 'previous_filename' "$T/$lane.sh" || ! grep -q 'GITHUB_OUTPUT' "$T/$lane.sh"; then
    echo "✗ could not extract the $(lane_id "$lane") step from $(lane_wf "$lane")"
    exit 1
  fi
  # Mutant: the guard's test replaced by `false`, so every listing prints
  # names as they come. It must differ from the shipped step, or the mutation
  # controls below would pass against the unmutated step and prove nothing.
  sed 's/explode | any(\. < 32 or \. == 127)/false/g' "$T/$lane.sh" > "$T/$lane-unguarded.sh"
  if cmp -s "$T/$lane.sh" "$T/$lane-unguarded.sh"; then
    echo "✗ $lane: no guard to cut out of the $(lane_id "$lane") step — its listings do not carry the control-character filter"
    failed=1
    mutants_ok=0
  fi
done
echo "✓ extracted all five steps"

# ---------------------------------------------------------------------------
# Fixtures. The caller's risk-paths.yml gates customer docs, and the
# line-break name is a customer doc whose halves are plain docs.
# ---------------------------------------------------------------------------
mkdir -p "$T/repo/.github" "$T/scripts" "$T/bin" "$T/fx"
cp .github/scripts/classify.mjs .github/scripts/classifier-deps.mjs "$T/scripts/"
cat > "$T/rules.yml" <<'YAML'
sensitive:
  - 'docs/customer/**/*.md'
trivial:
  - 'docs/**'
YAML
cp "$T/rules.yml" "$T/repo/.github/risk-paths.yml"

printf '%s' '[{"filename":"docs/customer/terms\ndocs/guide.md","status":"added"}]' > "$T/fx/newline.json"
printf '%s' '[{"filename":"docs/guide.md","previous_filename":"docs/old\tguide.md","status":"renamed"}]' > "$T/fx/tab-rename.json"
printf '%s' '[{"filename":"docs/notes\u007f.md","status":"added"}]' > "$T/fx/del.json"
printf '%s' '[{"filename":"docs/guide.md","previous_filename":"docs/old\u001fguide.md","status":"renamed"}]' > "$T/fx/us-rename.json"
printf '%s' '[{"filename":"docs/My Notes/résumé.md","status":"modified"},{"filename":"docs/guide.md","previous_filename":"docs/old guide.md","status":"renamed"}]' > "$T/fx/plain.json"
printf '%s' '[{"filename":"docs/customer/terms.md","status":"modified"},{"filename":"docs/legal/aup.md","status":"modified"}]' > "$T/fx/gated.json"

# The stub's output for the line-break fixture under a plain `.filename`
# filter: two lines for one name. The fixture exercises the split, so a
# fail-closed verdict on it is about the split, not about a malformed fixture.
if [ "$(jq -r '.[].filename' "$T/fx/newline.json" | wc -l | tr -d ' ')" = 2 ]; then
  echo "✓ instrument: the line-break fixture reads as two names without the guard"
else
  echo "✗ instrument: the line-break fixture does not split under a plain filter — it tests nothing"
  failed=1
fi

# ---------------------------------------------------------------------------
# Stubs. `gh` serves the files API from $STUB_FILES_JSON through the caller's
# own --jq (one page of per_page, default 30, without --paginate; up to the
# API's 3000-entry cap with it), the base-ref rules and the real classifier
# as base64 contents, a fixed head, no labels and no standing arm.
# ---------------------------------------------------------------------------
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

# run_lane <lane> <fixture> [unguarded] — sets RC, LOG; outputs in $T/out.
run_lane() {
  local script="$T/$1.sh"
  [ "${3:-}" = unguarded ] && script="$T/$1-unguarded.sh"
  : > "$T/out"
  set +e
  LOG=$(cd "$T/repo" && PATH="$T/bin:$PATH" GH_TOKEN=stub PR=7 \
    GITHUB_REPOSITORY=acme/fixture REPO=acme/fixture BASE_REF=main DEFAULT_BRANCH=main \
    CLASSIFY_SCRIPTS="$T/scripts" GITHUB_OUTPUT="$T/out" RISK_MAIN_GO=true BYPASS_LABEL='' \
    EXTRA_GLOBS='' PR_AUTHOR=someone STANDING_ARM='' \
    STUB_FILES_JSON="$T/fx/$2.json" STUB_RULES="$T/rules.yml" STUB_SCRIPTS="$T/scripts" \
    STUB_HEAD=c0ffee0000000000000000000000000000000001 \
    bash "$script" 2>&1 < /dev/null)
  RC=$?
  set -e
}

out_get() { grep "^$1=" "$T/out" | tail -1 | cut -d= -f2- || true; }

report_bad() {
  echo "✗ $1 — $2. Output:"
  printf '%s\n' "$LOG" | sed 's/^/    /'
  failed=1
}

# The key each lane writes its verdict under.
verdict_key() {
  case "$1" in
    pr_classify) echo class ;;
    am_classifier) echo blocked ;;
    am_risk) echo risky ;;
    sp_classify) echo all_safe ;;
    sp_tier3) echo hold ;;
  esac
}

# expect_closed <lane> <desc> — the lane's own fail-closed shape.
expect_closed() {
  local lane=$1 desc="$1: $2"
  case "$lane" in
    pr_classify | am_classifier | am_risk)
      if [ "$RC" -ne 0 ] && grep -q "$NEEDLE" <<<"$LOG" && ! grep -q "^$(verdict_key "$lane")=" "$T/out"; then
        echo "✓ $desc"
      else
        report_bad "$desc" "want a nonzero exit, '$NEEDLE' in the log and no $(verdict_key "$lane")= verdict; got rc=$RC, $(verdict_key "$lane")='$(out_get "$(verdict_key "$lane")")'"
      fi
      ;;
    sp_classify | sp_tier3)
      local key want got_v got_r
      key=$(verdict_key "$lane")
      if [ "$lane" = sp_classify ]; then want=0; else want=1; fi
      got_v=$(out_get "$key"); got_r=$(out_get reason)
      if [ "$RC" -eq 0 ] && [ "$got_v" = "$want" ] && [ "$got_r" = "$REASON" ] \
        && grep -q "$NEEDLE" <<<"$LOG" && ! grep -q "^$key=$((1 - want))\$" "$T/out"; then
        echo "✓ $desc"
      else
        report_bad "$desc" "want rc=0, $key=$want, reason=$REASON and '$NEEDLE' in the log; got rc=$RC, $key='$got_v', reason='$got_r'"
      fi
      ;;
  esac
}

# expect_verdict <lane> <desc> <key=value>... — exit 0 and each output equals.
expect_verdict() {
  local lane=$1 desc="$1: $2" kv k v bad=""
  shift 2
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    [ "$(out_get "$k")" = "$v" ] || bad="$bad $k='$(out_get "$k")' (want '$v')"
  done
  if [ "$RC" -eq 0 ] && [ -z "$bad" ] && ! grep -q "$NEEDLE" <<<"$LOG"; then
    echo "✓ $desc"
  else
    report_bad "$desc" "want rc=0 with no control-character verdict; got rc=$RC,${bad:- outputs as wanted}"
  fi
}

# The benign verdict of each lane: what plain docs read as.
benign() {
  case "$1" in
    pr_classify) echo class=trivial ;;
    am_classifier) echo blocked=0 ;;
    am_risk) echo risky=0 ;;
    sp_classify) echo all_safe=1 ;;
    sp_tier3) echo hold=0 ;;
  esac
}
# The verdict of each lane on the gated fixture: a caller-sensitive customer
# doc beside a fleet-gated legal doc.
gated() {
  case "$1" in
    pr_classify) echo class=sensitive ;;
    am_classifier) echo blocked=1 verdict_label=risk:sensitive ;;
    am_risk) echo risky=1 ;;
    sp_classify) echo all_safe=0 reason=unsafe-override ;;
    sp_tier3) echo hold=1 reason=classifier-hold ;;
  esac
}

for lane in $LANES; do
  # 1-3. Fail closed.
  run_lane "$lane" newline;    expect_closed "$lane" "a changed name holding a line break fails closed"
  run_lane "$lane" tab-rename; expect_closed "$lane" "a rename source holding a tab fails closed"
  run_lane "$lane" del;        expect_closed "$lane" "a changed name holding DEL fails closed"
  run_lane "$lane" us-rename;  expect_closed "$lane" "a rename source holding U+001F fails closed"

  # 4. Controls.
  run_lane "$lane" plain
  # shellcheck disable=SC2046 # word-split the key=value list on purpose
  expect_verdict "$lane" "control: plain names with spaces and non-ASCII letters classify as before" $(benign "$lane")
  run_lane "$lane" gated
  # shellcheck disable=SC2046
  expect_verdict "$lane" "control: a plain gated path still gates" $(gated "$lane")

  # 5. Mutation controls.
  if [ "$mutants_ok" = 1 ]; then
    run_lane "$lane" newline unguarded
    # shellcheck disable=SC2046
    expect_verdict "$lane" "control: unguarded, the line-break name is read as two benign names (the escape)" $(benign "$lane")
    run_lane "$lane" tab-rename unguarded
    # shellcheck disable=SC2046
    expect_verdict "$lane" "control: unguarded, the tab rename source is not failed closed" $(benign "$lane")
  fi
done

# ---------------------------------------------------------------------------
# 6. Every files-API listing ends in the guard. A listing is a code line whose
#    --jq expression reads `filename` (both `.filename` and
#    `.previous_filename`); comments are stripped so prose cannot satisfy it.
# ---------------------------------------------------------------------------
# check_listers <workflow file> <want> — 0 when exactly <want> listings exist
# and every one ends in the guard.
check_listers() {
  local code listers n guarded
  code=$(grep -vE '^[[:space:]]*#' "$1" || true)
  listers=$(grep -E -- "--jq '[^']*filename" <<<"$code" || true)
  n=$(grep -c . <<<"$listers" || true)
  guarded=$(grep -cF -- "| $GUARD'" <<<"$listers" || true)
  LISTERS_SEEN="$n listing(s), $guarded guarded"
  [ "$n" = "$2" ] && [ "$guarded" = "$2" ]
}
for pair in pr-classify:2 claude-author-automerge:4 safe-paths-automerge:4; do
  wf=".github/workflows/${pair%%:*}.yml"
  if check_listers "$wf" "${pair##*:}"; then
    echo "✓ $wf: all ${pair##*:} files-API listings end in the control-character guard"
  else
    echo "✗ $wf: want ${pair##*:} files-API listings, every one ending in the guard; found $LISTERS_SEEN"
    failed=1
  fi
done
# Negative control: one listing's guard broken must fail the check.
sed '/previous_filename/ s/explode/explod3/' .github/workflows/pr-classify.yml > "$T/pr-classify-broken.yml"
if cmp -s .github/workflows/pr-classify.yml "$T/pr-classify-broken.yml"; then
  echo "✗ control: could not break the rename listing's guard in pr-classify.yml — update this test's sed"
  failed=1
elif check_listers "$T/pr-classify-broken.yml" 2; then
  echo "✗ control: the listing check passed with one guard broken — it cannot fail"
  failed=1
else
  echo "✓ control: the listing check fails when one listing loses its guard ($LISTERS_SEEN)"
fi

# ---------------------------------------------------------------------------
# 7. safe-paths' revoke step fires on the classify step's verdict, so an arm
#    an earlier, clean revision placed cannot survive this push.
# ---------------------------------------------------------------------------
revoke_if=$(awk '
  /^      - name: Revoke/ { f = 1 }
  f && /^        env:/ { f = 0 }
  f { print }
' .github/workflows/safe-paths-automerge.yml | grep -vE '^[[:space:]]*#' || true)
if grep -qF "steps.classify.outputs.reason == '$REASON'" <<<"$revoke_if"; then
  echo "✓ safe-paths' revoke step fires on reason=$REASON"
else
  echo "✗ safe-paths' revoke step does not fire on reason=$REASON — an arm from an earlier revision would survive"
  failed=1
fi

# ---------------------------------------------------------------------------
# 8. The line-break fixture's whole name is gated; neither half is.
# ---------------------------------------------------------------------------
mm=$(node --input-type=module -e '
  const { minimatch } = await import(process.argv[1]);
  const o = { dot: true, matchBase: false, nocase: true };
  const g = "docs/customer/**/*.md";
  console.log([
    "docs/customer/terms\ndocs/guide.md", "docs/customer/terms", "docs/guide.md",
  ].map((p) => minimatch(p, g, o)).join(" "));
' "$PWD/.github/scripts/classifier-deps.mjs")
if [ "$mm" = "true false false" ]; then
  echo "✓ the line-break name matches docs/customer/**/*.md whole, and neither half does"
else
  echo "✗ minimatch on the whole name and its halves: got '$mm', want 'true false false' — the escape fixture no longer escapes"
  failed=1
fi

echo ""
if [ "$failed" -ne 0 ]; then
  echo "FAIL: a classifier listing does not fail closed on a control character."
  exit 1
fi
echo "OK: every classifier listing fails closed on a control character."
