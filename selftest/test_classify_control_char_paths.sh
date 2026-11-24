#!/usr/bin/env bash
# Behavioral test: every step that hands a PR's changed-file names to a
# one-name-per-line check must FAIL CLOSED when a name, or a rename source,
# holds a control character: a C0 character (U+0000-U+001F, which takes in the
# line break and the tab) or DEL (U+007F).
#
# Why. The files API returns each name whole, but these steps pass the names
# on one per line: to classify.mjs, and to `while read` loops over the fleet
# risk-tier regex. Git allows a line break in a file name, and such a name is
# then read as two names, each judged alone. The halves can slip past a rule
# the whole name matches:
#   - `docs/customer/terms<LF>docs/guide.md` matches a caller's
#     `docs/customer/**/*.md`, while its halves match only `docs/**`;
#   - `docs/deploy<LF>docs/x.sh` matches the fleet regex
#     `(^|/)deploy.*\.(sh|ya?ml)$`, while neither half does.
# A gated path then reads as plain docs: the automerge bot arms standard and
# trivial PRs, and safe-paths arms docs-only ones. Found by the Codex
# pre-review of topcoder1/dotclaude#738 (2026-11-24), which fixes the same hole
# in the babysit-prs loop.
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
#      there would skip that revoke). Both example names above are used.
#   2. A rename SOURCE holding a tab fails closed the same way: every C0
#      character counts, not only the line break, and the rename listing is
#      guarded as well as the changed-file listing.
#   3. Both ends of the range: DEL in a changed name, and U+001F in a rename
#      source.
#   4. A marked changed-file listing followed by a FAILING rename listing still
#      fails closed. In safe-paths' classify step that means its revoking
#      verdict: waiting for the rename call would let its failure kill the
#      step with no verdict, and the revoke step would not fire.
#   5. Controls: plain names, with spaces and non-ASCII letters, classify as
#      before; a plain gated path still gates.
#   6. Mutation controls: the same step with the guard's test replaced by
#      `false` does NOT fail closed on the cases of 1 and 2, so those verdicts
#      come from the guard and not from the harness. The unguarded step also
#      reproduces the escape: a benign verdict for a name whose whole is gated
#      (the caller's glob in the three classify.mjs steps, pin 9; the fleet
#      regex in the two regex steps, pin 10).
# And structurally:
#   7. Every files-API call in the three workflows ends in the guard, however
#      its --jq is quoted, so a new listing that forgets it fails here.
#      Expected counts are hardcoded, and two negative controls (one guard
#      broken, one unguarded listing added) prove the check can fail.
#   8. safe-paths' revoke step fires on the classify step's new verdict.
#   9. The caller-glob fixture's WHOLE name matches `docs/customer/**/*.md` and
#      neither half does (minimatch from the vendored bundle classify.mjs
#      uses).
#  10. The fleet-regex fixture's WHOLE name matches `(^|/)deploy.*\.(sh|ya?ml)$`
#      read as one string (a JavaScript regex with `.` matching a line break)
#      and neither half does, and both workflows still carry that pattern.
#
# Run from the repo root:
#   bash selftest/test_classify_control_char_paths.sh
set -euo pipefail

GUARD='if (explode | any(. < 32 or . == 127)) then "/CONTROL-CHARACTER-IN-PATH" else . end'
NEEDLE='holds a control character'
REASON='control-character-path'
DEPLOY_RE='(^|/)deploy.*\.(sh|ya?ml)$'
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
# Fixtures. The caller's risk-paths.yml gates customer docs; the fleet regex
# gates deploy scripts. Each line-break name is gated whole, and its halves
# are plain docs paths.
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
printf '%s' '[{"filename":"docs/deploy\ndocs/x.sh","status":"added"}]' > "$T/fx/newline-deploy.json"
printf '%s' '[{"filename":"docs/guide.md","previous_filename":"docs/old\tguide.md","status":"renamed"}]' > "$T/fx/tab-rename.json"
printf '%s' '[{"filename":"docs/notes\u007f.md","status":"added"}]' > "$T/fx/del.json"
printf '%s' '[{"filename":"docs/guide.md","previous_filename":"docs/old\u001fguide.md","status":"renamed"}]' > "$T/fx/us-rename.json"
printf '%s' '[{"filename":"docs/My Notes/résumé.md","status":"modified"},{"filename":"docs/guide.md","previous_filename":"docs/old guide.md","status":"renamed"}]' > "$T/fx/plain.json"
printf '%s' '[{"filename":"docs/customer/terms.md","status":"modified"},{"filename":"docs/legal/aup.md","status":"modified"}]' > "$T/fx/gated.json"

# The stub's output for a line-break fixture under a plain `.filename` filter:
# two lines for one name. The fixtures exercise the split, so a fail-closed
# verdict on them is about the split, not about a malformed fixture.
for fx in newline newline-deploy; do
  if [ "$(jq -r '.[].filename' "$T/fx/$fx.json" | wc -l | tr -d ' ')" = 2 ]; then
    echo "✓ instrument: the $fx fixture reads as two names without the guard"
  else
    echo "✗ instrument: the $fx fixture does not split under a plain filter — it tests nothing"
    failed=1
  fi
done

# ---------------------------------------------------------------------------
# Stubs. `gh` serves the files API from $STUB_FILES_JSON through the caller's
# own --jq (one page of per_page, default 30, without --paginate; up to the
# API's 3000-entry cap with it), the base-ref rules and the real classifier
# as base64 contents, a fixed head, no labels and no standing arm. With
# STUB_RENAME_FAILS=1 every rename-source listing (told apart by its --jq
# text) fails like an API error.
# ---------------------------------------------------------------------------
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
args="$*"
jq_filter() { while [ $# -gt 0 ]; do [ "$1" = "--jq" ] && { printf '%s' "$2"; return 0; }; shift; done; return 1; }
case "$args" in
  *pulls/*/files*)
    filter=$(jq_filter "$@") || { echo "gh-stub: files call without --jq: $args" >&2; exit 64; }
    case "$filter" in
      *previous_filename*)
        if [ "${STUB_RENAME_FAILS:-0}" = 1 ]; then
          echo "gh: Internal Server Error (HTTP 500)" >&2
          exit 1
        fi
        ;;
    esac
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

RENAME_FAILS=0
# run_lane <lane> <fixture> [unguarded] — sets RC, LOG; outputs in $T/out.
# Resets RENAME_FAILS.
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
    STUB_HEAD=c0ffee0000000000000000000000000000000001 STUB_RENAME_FAILS="$RENAME_FAILS" \
    bash "$script" 2>&1 < /dev/null)
  RC=$?
  set -e
  RENAME_FAILS=0
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

# expect_closed <lane> <desc> — the lane's own fail-closed shape, naming the
# control character.
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

# expect_closed_any <lane> <desc> — fails closed in the lane's shape, for any
# reason: no verdict and a nonzero exit, or a hold. safe-paths' classify step
# must still name the control character, since only a reason fires its revoke.
expect_closed_any() {
  local lane=$1 desc="$1: $2"
  case "$lane" in
    pr_classify | am_classifier | am_risk)
      if [ "$RC" -ne 0 ] && ! grep -q "^$(verdict_key "$lane")=" "$T/out"; then
        echo "✓ $desc"
      else
        report_bad "$desc" "want a nonzero exit and no $(verdict_key "$lane")= verdict; got rc=$RC, $(verdict_key "$lane")='$(out_get "$(verdict_key "$lane")")'"
      fi
      ;;
    sp_classify) expect_closed "$lane" "$2" ;;
    sp_tier3)
      if [ "$RC" -eq 0 ] && [ "$(out_get hold)" = 1 ] && ! grep -q '^hold=0$' "$T/out"; then
        echo "✓ $desc"
      else
        report_bad "$desc" "want rc=0 and hold=1; got rc=$RC, hold='$(out_get hold)', reason='$(out_get reason)'"
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
# The line-break fixture whose whole name this lane's own rules gate: the
# caller's glob for the classify.mjs steps, the fleet regex for the others.
escape_fixture() {
  case "$1" in
    am_risk | sp_classify) echo newline-deploy ;;
    *) echo newline ;;
  esac
}

for lane in $LANES; do
  # 1-3. Fail closed.
  run_lane "$lane" newline;        expect_closed "$lane" "a changed name holding a line break fails closed (caller-glob example)"
  run_lane "$lane" newline-deploy; expect_closed "$lane" "a changed name holding a line break fails closed (fleet-regex example)"
  run_lane "$lane" tab-rename;     expect_closed "$lane" "a rename source holding a tab fails closed"
  run_lane "$lane" del;            expect_closed "$lane" "a changed name holding DEL fails closed"
  run_lane "$lane" us-rename;      expect_closed "$lane" "a rename source holding U+001F fails closed"

  # 4. A marked changed-file listing, then a rename listing that fails.
  RENAME_FAILS=1
  run_lane "$lane" newline
  expect_closed_any "$lane" "a marked changed-name listing still fails closed when the rename listing then fails"

  # 5. Controls.
  run_lane "$lane" plain
  # shellcheck disable=SC2046 # word-split the key=value list on purpose
  expect_verdict "$lane" "control: plain names with spaces and non-ASCII letters classify as before" $(benign "$lane")
  run_lane "$lane" gated
  # shellcheck disable=SC2046
  expect_verdict "$lane" "control: a plain gated path still gates" $(gated "$lane")

  # 6. Mutation controls.
  if [ "$mutants_ok" = 1 ]; then
    run_lane "$lane" "$(escape_fixture "$lane")" unguarded
    # shellcheck disable=SC2046
    expect_verdict "$lane" "control: unguarded, the $(escape_fixture "$lane") name is read as two benign names (the escape)" $(benign "$lane")
    run_lane "$lane" tab-rename unguarded
    # shellcheck disable=SC2046
    expect_verdict "$lane" "control: unguarded, the tab rename source is not failed closed" $(benign "$lane")
  fi
done

# ---------------------------------------------------------------------------
# 7. Every files-API call ends in the guard. Comments are dropped, so prose
#    cannot satisfy it, and continuation lines are joined, so a call counts
#    wherever its --jq sits and however it is quoted.
# ---------------------------------------------------------------------------
logical_lines() {
  { grep -vE '^[[:space:]]*#' "$1" || true; } \
    | awk '{ if (sub(/\\[[:space:]]*$/, "")) { buf = buf $0; next } print buf $0; buf = "" }'
}
# check_listers <workflow file> <want> — 0 when exactly <want> files-API calls
# exist and every one ends in the guard.
check_listers() {
  local listers n guarded
  listers=$(logical_lines "$1" | grep -E 'pulls/[^[:space:]]*/files' || true)
  n=$(grep -c . <<<"$listers" || true)
  guarded=$(grep -cF -e "| $GUARD'" -e "| $GUARD\"" <<<"$listers" || true)
  LISTERS_SEEN="$n files-API call(s), $guarded ending in the guard"
  [ "$n" = "$2" ] && [ "$guarded" = "$2" ]
}
for pair in pr-classify:2 claude-author-automerge:4 safe-paths-automerge:4; do
  wf=".github/workflows/${pair%%:*}.yml"
  if check_listers "$wf" "${pair##*:}"; then
    echo "✓ $wf: all ${pair##*:} files-API calls end in the control-character guard"
  else
    echo "✗ $wf: want ${pair##*:} files-API calls, every one ending in the guard; found $LISTERS_SEEN"
    failed=1
  fi
done
# Negative controls: one listing's guard broken, and one unguarded listing
# added with its --jq in double quotes, must each fail the check.
sed '/previous_filename/ s/explode/explod3/' .github/workflows/pr-classify.yml > "$T/pr-classify-broken.yml"
{ cat .github/workflows/pr-classify.yml
  # shellcheck disable=SC2016,SC1003 # a literal workflow line, not an expansion or an escape
  printf '%s\n' '          extra=$(gh api "repos/o/r/pulls/1/files" \' '            --paginate --jq ".[].filename")'
} > "$T/pr-classify-extra.yml"
for mutant in broken extra; do
  if cmp -s .github/workflows/pr-classify.yml "$T/pr-classify-$mutant.yml"; then
    echo "✗ control: could not build the $mutant mutant of pr-classify.yml — update this test"
    failed=1
  elif check_listers "$T/pr-classify-$mutant.yml" 2; then
    echo "✗ control: the listing check passed on the $mutant mutant — it cannot fail that way"
    failed=1
  else
    echo "✓ control: the listing check fails on the $mutant mutant ($LISTERS_SEEN)"
  fi
done

# ---------------------------------------------------------------------------
# 8. safe-paths' revoke step fires on the classify step's verdict, so an arm
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
# 9 and 10. Each line-break name is gated whole, and neither half is.
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
  echo "✓ the caller-glob name matches docs/customer/**/*.md whole, and neither half does"
else
  echo "✗ minimatch on the whole name and its halves: got '$mm', want 'true false false' — the escape fixture no longer escapes"
  failed=1
fi

for wf in claude-author-automerge safe-paths-automerge; do
  if ! grep -qF "$DEPLOY_RE" ".github/workflows/$wf.yml"; then
    echo "✗ $wf.yml no longer carries the fleet pattern $DEPLOY_RE — pick another fleet-regex example"
    failed=1
  fi
done
re=$(node -e '
  const re = new RegExp(process.argv[1], "s");
  console.log(["docs/deploy\ndocs/x.sh", "docs/deploy", "docs/x.sh"].map((p) => re.test(p)).join(" "));
' "$DEPLOY_RE")
if [ "$re" = "true false false" ]; then
  echo "✓ the fleet-regex name matches $DEPLOY_RE whole, and neither half does"
else
  echo "✗ $DEPLOY_RE on the whole name and its halves: got '$re', want 'true false false' — the escape fixture no longer escapes"
  failed=1
fi

echo ""
if [ "$failed" -ne 0 ]; then
  echo "FAIL: a classifier listing does not fail closed on a control character."
  exit 1
fi
echo "OK: every classifier listing fails closed on a control character."
