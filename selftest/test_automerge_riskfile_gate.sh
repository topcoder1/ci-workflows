#!/usr/bin/env bash
# Behavioral test for the classifier-verdict gate in
# claude-author-automerge.yml — the step that decides whether a
# Claude-authored PR may arm auto-merge.
#
# Incident (whois-api-llc/wxa-secrets#27, 2026-07-17T00:40Z): pr-classify
# and claude-author-automerge both fired on the same ready_for_review
# event. The automerge run queried live labels at :43 (none yet) and
# armed auto-merge at :46; pr-classify applied risk:blocked at :50 — 4s
# late — and the PR squash-merged when required checks went green. The
# workflow's documented mitigation ("caller wires `labeled` into trigger
# types so a re-run revokes") was structurally unreachable: pr-classify
# labels with GITHUB_TOKEN, and GITHUB_TOKEN-attributed events never
# trigger workflows.
#
# The fix: the verdict step no longer depends on the label round-trip.
# It reads .github/risk-paths.yml from the PR's BASE branch and runs the
# same classify.mjs pr-classify uses, synchronously, at decision time.
# This test EXTRACTS that step's bash from the workflow YAML and executes
# it against a stubbed `gh` + the REAL classify.mjs, pinning:
#
#   1. THE RACE: blocked-path PR with no labels yet ⇒ blocked=1
#      (source=risk-paths). This is the wxa-secrets#27 shape.
#   2. sensitive-path PR, no labels ⇒ blocked=1.
#   3. clean PR ⇒ blocked=0.
#   4. label belt-and-suspenders: risk:blocked label + clean files ⇒
#      blocked=1 (source=label).
#   5. BASE-REF PINNING: every rules read must carry ref=<base> (the gh
#      stub hard-fails otherwise), and a non-default base ref works — a
#      PR must never be able to consult its own (head) risk file.
#   6. no risk-paths.yml on base OR default branch (404 twice) ⇒
#      blocked=0; the global regex step still gates downstream (that
#      regex has its own selftest, test_automerge_risk_patterns.sh).
#   7. FAIL CLOSED: rules file unreadable (non-404 API failure) ⇒ the
#      step exits nonzero — auto-merge is never armed under an
#      unreadable policy.
#   8. FAIL CLOSED: 3000+ changed files (REST listing cap) ⇒ nonzero.
#   9. nocase parity: docs/SECRETS.md vs a lowercase '**/secrets*'
#      blocked glob ⇒ blocked=1 — proves the gate inherits classify.mjs
#      semantics (minimatch, dot:true, nocase on gating classes) instead
#      of reimplementing them.
#  10. FAIL CLOSED on an unreadable label set — with blocked files AND
#      with clean files. A hand-applied risk label is an independent
#      signal the file classification cannot reconstruct, so a failed
#      label read must never degrade to "no label" (codex round-3 P1:
#      the clean-files variant is the one a blocked-path-only case
#      masks).
#  11. DEFAULT-BRANCH FALLBACK (codex round-2 P1): base ref lacks the
#      file (release branch predating the policy) ⇒ the default
#      branch's policy is applied — a legacy base must not dodge it.
#  12. FAIL CLOSED on classifier-output enum violation (codex round-2
#      P2): classify.mjs printing anything outside the documented class
#      set ⇒ nonzero, never silently benign.
#  13. RENAME ESCAPE (dotclaude#336, 2026-09-17): a rename reports only
#      its DESTINATION in `.filename`. Moving a file out of a gated
#      path — `sensitive:` → `docs/archive/**` — classified `standard`
#      and armed, and a docs destination was then armed by
#      safe-paths-automerge.yml as well. Rename SOURCES must be
#      classified too, for both gating classes, with a benign rename as
#      the negative control so the case cannot pass by over-blocking.
#  14. Rename sources are appended AFTER the 3000-file count, like the
#      global-regex lane: they must never push a large-but-listable PR
#      over the cap, and must still be classified when they don't.
#  15. FAIL CLOSED on an unreadable rename listing — a rename source
#      that cannot be read is a gate that cannot be evaluated.
#
# Structural pins on the surrounding job (codex rounds 2 & 4): the arm
# is bound to the event head SHA via `--match-head-commit`; an always()
# cleanup step revokes any existing arm when a gating step ERRORS (a red
# run must not leave a stale arm alive — "refusing to arm" is not fail
# closed for a PR a previous run already armed); and the label read
# paginates (a hand-applied risk label past the 30-label default page
# must not read as absent).
#
# Run from the repo root:
#   bash selftest/test_automerge_riskfile_gate.sh
set -euo pipefail

WF=.github/workflows/claude-author-automerge.yml
CLASSIFY=.github/scripts/classify.mjs
DEPS=.github/scripts/classifier-deps.mjs
failed=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# ---------------------------------------------------------------------------
# 0a. Structural drift guards: the gate must use the SAME classifier, the
#     SAME dependency pins, and read the rules from the BASE ref.
# ---------------------------------------------------------------------------
# Both workflows fetch their scripts by name from one shared API prefix. The
# assertion is split into prefix + filename because both now pull several files
# in a loop ("…/scripts/$s"), so no single literal path string appears any more.
#
# Comments are stripped first: these workflows discuss classify.mjs at length in
# prose, and matching that would let a workflow that had STOPPED fetching the
# script still pass. Assigned to a variable rather than piped into `grep -q` —
# under `set -o pipefail` a match makes grep -q exit early, SIGPIPEs the
# upstream grep, and the pipeline reports 141, i.e. a match reads as a failure.
MJS_SOURCE='repos/topcoder1/ci-workflows/contents/.github/scripts/'
DEPS_SOURCE='classifier-deps.mjs'
for wf in .github/workflows/pr-classify.yml "$WF"; do
  wf_code=$(grep -vE '^[[:space:]]*#' "$wf" || true)
  if grep -q "$MJS_SOURCE" <<<"$wf_code" && grep -q 'classify\.mjs' <<<"$wf_code"; then
    echo "✓ $wf fetches classify.mjs from the shared source"
  else
    echo "✗ $wf does not fetch classify.mjs from $MJS_SOURCE — matchers can drift"
    failed=1
  fi
  # Both workflows must load the SAME dependency bytes, or the two matchers
  # can disagree. This used to assert the shared `yaml@2 minimatch@10` npm
  # pins; those were floating majors resolved independently at run time, so
  # they only ever pinned the two sides to the same MAJOR. They are now a
  # committed, exact-version bundle fetched from the same shared source.
  if grep -q "$DEPS_SOURCE" <<<"$wf_code"; then
    echo "✓ $wf fetches the shared vendored dep bundle"
  else
    echo "✗ $wf does not fetch classifier deps from $DEPS_SOURCE — matchers can drift"
    failed=1
  fi
done
if grep -q -- '-f ref="\$ref"' "$WF" && grep -q 'read_rules "\$rules_ref"' "$WF"; then
  echo "✓ $WF reads risk-paths.yml pinned to an explicit ref (base, then default-branch fallback)"
else
  echo "✗ $WF does not pin the risk-paths.yml read to an explicit ref"
  failed=1
fi
if grep -q -- '--match-head-commit "\$HEAD_SHA"' "$WF"; then
  echo "✓ $WF binds the auto-merge arm to the event head SHA (--match-head-commit)"
else
  echo "✗ $WF does not bind the arm to the classified head SHA — a mid-run push could inherit the arm"
  failed=1
fi
if grep -q 'name: Revoke auto-merge if gates errored' "$WF" \
  && grep -A5 'name: Revoke auto-merge if gates errored' "$WF" | grep -q 'always()' \
  && grep -q "steps.classifier_verdict.outcome == 'failure'" "$WF" \
  && grep -q "steps.risk.outcome == 'failure'" "$WF" \
  && grep -q "steps.setup_node.outcome == 'failure'" "$WF" \
  && grep -q "steps.checkout.outcome == 'failure'" "$WF" \
  && grep -A40 'name: Revoke auto-merge if gates errored' "$WF" | grep -q 'skipping stale revoke'; then
  echo "✓ $WF revokes an existing arm under always() when a gating or prerequisite step errors (head-ownership-guarded)"
else
  echo "✗ $WF error-revoke step missing, not covering gate + prerequisite failures, or lacking the head-ownership guard"
  failed=1
fi

# ---------------------------------------------------------------------------
# 0b. Extract the classifier-verdict step's run block — the shipped bash,
#     not a mirrored copy.
# ---------------------------------------------------------------------------
awk '
  /^      - name: Check classifier verdict$/ { in_step=1 }
  in_step && /^        run: \|/ { in_run=1; next }
  in_run {
    if ($0 ~ /^          / || $0 == "") { sub(/^          /, ""); print }
    else { exit }
  }
' "$WF" > "$T/gate.sh"

if ! grep -q 'risk-paths.yml' "$T/gate.sh" || ! grep -q 'GITHUB_OUTPUT' "$T/gate.sh"; then
  echo "✗ could not extract the classifier-verdict run block from $WF"
  exit 1
fi
echo "✓ extracted classifier-verdict step ($(wc -l < "$T/gate.sh" | tr -d ' ') lines)"

# Rename sources must be scanned by BOTH lanes. Asserted per-lane, not with
# one file-wide grep: the two lanes gate different things (this one the
# repo's own risk-paths.yml, the other the central regex) and a file-wide
# match would pass with either half deleted — which is precisely the state
# this change found the fleet in. Comments are stripped first, for the same
# reason the classify.mjs guard above strips them: both lanes discuss the
# rename escape at length in prose.
gate_code=$(grep -vE '^[[:space:]]*#' "$T/gate.sh" || true)
if grep -q 'previous_filename' <<<"$gate_code"; then
  echo "✓ classifier lane classifies rename SOURCES (a gated file moved out cannot escape)"
else
  echo "✗ classifier lane does not read .previous_filename — a rename out of a gated path escapes the repo's own risk-paths.yml"
  failed=1
fi
wf_code_all=$(grep -vE '^[[:space:]]*#' "$WF" || true)
rename_reads=$(grep -c 'previous_filename' <<<"$wf_code_all" || true)
if [ "${rename_reads:-0}" -ge 2 ]; then
  echo "✓ both automerge lanes read .previous_filename ($rename_reads code references)"
else
  echo "✗ only ${rename_reads:-0} lane(s) in $WF read .previous_filename — want both (classifier + global regex)"
  failed=1
fi
# Neither rename read may swallow its own failure. `2>/dev/null || echo ""`
# turns an API blip into "this PR renames nothing", which is the escape the
# scan exists to close — fail-open, silent, and invisible in the run log.
if grep -A2 'previous_filename' <<<"$wf_code_all" | grep -qE '2>/dev/null|\|\| echo'; then
  echo "✗ a rename listing in $WF swallows its own failure — an API blip reads as 'no renames' (fail open)"
  failed=1
else
  echo "✓ neither rename listing swallows a read failure"
fi

if grep -q 'labels?per_page=100' "$T/gate.sh" && grep -B1 -A1 'labels?per_page=100' "$T/gate.sh" | grep -q -- '--paginate'; then
  echo "✓ label read paginates (a hand-applied label past page 1 cannot read as absent)"
else
  echo "✗ label read does not paginate — a risk label past the 30-label default page reads as absent"
  failed=1
fi

# ---------------------------------------------------------------------------
# 0c. Stubs. `gh` dispatches on the requested URL; `sleep` no-ops the retry
#     backoffs; `npm` links a prebuilt node_modules so each gate run is
#     offline and fast while the shipped `npm install` line still executes.
#     Knobs (env):
#       STUB_LABELS            — newline-separated label names ('' = none)
#       STUB_LABELS_RC         — nonzero: the labels call fails (API blip)
#       STUB_RISK_FILE         — BASE-ref risk-paths.yml fixture; '' = 404
#       STUB_RISK_DEFAULT_FILE — DEFAULT-branch fixture; '' = 404
#       STUB_RISK_RC           — nonzero: base-ref read fails NON-404
#       STUB_FILES             — newline-separated changed-file list (path)
#       STUB_RENAMES           — newline-separated rename SOURCES
#                                (.previous_filename); '' = no renames
#       STUB_RENAMES_RC        — nonzero: the rename listing fails (blip)
#       STUB_CLASSIFY_FILE     — classifier served to the gate (defaults to
#                                the real classify.mjs via REAL_CLASSIFY)
#       REAL_DEPS              — the real vendored dep bundle
#                                (classifier-deps.mjs) served verbatim;
#                                classify.mjs imports it relatively, so the
#                                gate cannot run without it
#
#     Any rules read whose ref is neither the base ref nor the default
#     branch exits 64 — pinning is asserted on EVERY case, not just one.
# ---------------------------------------------------------------------------
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *issues/*/labels*)
    [ "${STUB_LABELS_RC:-0}" != "0" ] && { echo "gh: Internal Server Error (HTTP 500)" >&2; exit 1; }
    printf '%s\n' "${STUB_LABELS:-}"
    ;;
  *contents/.github/scripts/classify.mjs*)
    base64 < "${STUB_CLASSIFY_FILE:-$REAL_CLASSIFY}"
    ;;
  *contents/.github/scripts/classifier-deps.mjs*)
    base64 < "$REAL_DEPS"
    ;;
  *contents/.github/risk-paths.yml*)
    _ref=""
    case "$args" in *"ref=${BASE_REF}"*) _ref=base ;; esac
    if [ -z "$_ref" ]; then
      case "$args" in *"ref=${DEFAULT_BRANCH}"*) _ref=default ;; esac
    fi
    case "$_ref" in
      base)
        [ "${STUB_RISK_RC:-0}" != "0" ] && { echo "gh: Internal Server Error (HTTP 500)" >&2; exit 1; }
        [ -z "${STUB_RISK_FILE:-}" ] && { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
        base64 < "$STUB_RISK_FILE"
        ;;
      default)
        [ -z "${STUB_RISK_DEFAULT_FILE:-}" ] && { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
        base64 < "$STUB_RISK_DEFAULT_FILE"
        ;;
      *)
        echo "gh-stub: risk-paths read with an unexpected ref (head read?): $args" >&2
        exit 64
        ;;
    esac
    ;;
  *pulls/*/files*)
    # The gate makes TWO calls against this endpoint — the changed-file
    # listing (.filename) and the rename sources (.previous_filename).
    # Discriminate on the --jq expression: a stub answering both with the
    # same fixture would make every rename case pass vacuously, since the
    # destination it already returns is what we are trying to prove is
    # insufficient.
    case "$args" in
      *previous_filename*)
        [ "${STUB_RENAMES_RC:-0}" != "0" ] && { echo "gh: Internal Server Error (HTTP 500)" >&2; exit 1; }
        printf '%s' "${STUB_RENAMES:-}"
        ;;
      *)
        cat "$STUB_FILES"
        ;;
    esac
    ;;
  *)
    echo "gh-stub: unexpected call: $args" >&2
    exit 64
    ;;
esac
STUB
chmod +x "$T/bin/gh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/sleep"
chmod +x "$T/bin/sleep"

# Prebuild the classifier deps once (same pins pr-classify.yml installs).
mkdir -p "$T/deps"
(cd "$T/deps" && npm install --no-save --silent yaml@2 minimatch@10 >/dev/null 2>&1)
cat > "$T/bin/npm" <<STUB
#!/usr/bin/env bash
ln -sfn "$T/deps/node_modules" ./node_modules
STUB
chmod +x "$T/bin/npm"

REAL_CLASSIFY="$PWD/$CLASSIFY"
REAL_DEPS="$PWD/$DEPS"

# ---------------------------------------------------------------------------
# Runner + assertions.
# ---------------------------------------------------------------------------
STUB_LABELS=""; STUB_LABELS_RC=0; STUB_RISK_FILE=""; STUB_RISK_DEFAULT_FILE=""
STUB_RISK_RC=0; STUB_CLASSIFY_FILE=""; STUB_RENAMES=""; STUB_RENAMES_RC=0
STUB_FILES="$T/files.txt"; CASE_BASE_REF="main"; CASE_DEFAULT_BRANCH="main"

reset_case() {
  STUB_LABELS=""; STUB_LABELS_RC=0; STUB_RISK_FILE=""; STUB_RISK_DEFAULT_FILE=""
  STUB_RISK_RC=0; STUB_CLASSIFY_FILE=""; STUB_RENAMES=""; STUB_RENAMES_RC=0
  CASE_BASE_REF="main"; CASE_DEFAULT_BRANCH="main"
  : > "$STUB_FILES"
}

run_gate() {
  OUT_FILE="$T/gh-output.txt"
  : > "$OUT_FILE"
  set +e
  GATE_LOG=$(cd "$T" && \
    PATH="$T/bin:$PATH" \
    GITHUB_REPOSITORY="acme/fixture" PR=123 BASE_REF="$CASE_BASE_REF" \
    DEFAULT_BRANCH="$CASE_DEFAULT_BRANCH" \
    GITHUB_OUTPUT="$OUT_FILE" GH_TOKEN=stub \
    STUB_LABELS="$STUB_LABELS" STUB_LABELS_RC="$STUB_LABELS_RC" \
    STUB_RISK_FILE="$STUB_RISK_FILE" STUB_RISK_DEFAULT_FILE="$STUB_RISK_DEFAULT_FILE" \
    STUB_RISK_RC="$STUB_RISK_RC" STUB_CLASSIFY_FILE="$STUB_CLASSIFY_FILE" \
    STUB_FILES="$STUB_FILES" REAL_CLASSIFY="$REAL_CLASSIFY" \
    STUB_RENAMES="$STUB_RENAMES" STUB_RENAMES_RC="$STUB_RENAMES_RC" \
    REAL_DEPS="$REAL_DEPS" \
    bash gate.sh 2>&1)
  GATE_RC=$?
  set -e
}

out_get() { grep "^$1=" "$OUT_FILE" | tail -1 | cut -d= -f2- || true; }

# expect_verdict <desc> <blocked> <verdict_label> <verdict_source>
expect_verdict() {
  local desc="$1" want_blocked="$2" want_label="$3" want_source="$4"
  if [ "$GATE_RC" != "0" ]; then
    echo "✗ $desc — gate exited rc=$GATE_RC (want 0). Output:"
    echo "$GATE_LOG" | sed 's/^/    /'
    failed=1
    return
  fi
  local got_blocked got_label got_source
  got_blocked=$(out_get blocked); got_label=$(out_get verdict_label); got_source=$(out_get verdict_source)
  if [ "$got_blocked" = "$want_blocked" ] && [ "$got_label" = "$want_label" ] && [ "$got_source" = "$want_source" ]; then
    echo "✓ $desc"
  else
    echo "✗ $desc — got blocked='$got_blocked' verdict_label='$got_label' verdict_source='$got_source'" \
         "(want '$want_blocked'/'$want_label'/'$want_source'). Output:"
    echo "$GATE_LOG" | sed 's/^/    /'
    failed=1
  fi
}

# expect_fail_closed <desc> <needle>
expect_fail_closed() {
  local desc="$1" needle="$2"
  if [ "$GATE_RC" -ne 0 ] && echo "$GATE_LOG" | grep -q "$needle"; then
    echo "✓ $desc"
  else
    echo "✗ $desc — want nonzero rc + '$needle'; got rc=$GATE_RC. Output:"
    echo "$GATE_LOG" | sed 's/^/    /'
    failed=1
  fi
}

# Fixture rules — the wxa-secrets#27 shape: a repo-specific blocked tree the
# global risk-tier regex does NOT cover, plus a sensitive list.
cat > "$T/risk-fixture.yml" <<'YAML'
blocked:
  - 'src/wxa_secrets/**'
  - '**/secrets*'
sensitive:
  - 'src/agent/runtime/**'
safe_test:
  - 'tests/**'
trivial:
  - 'docs/**'
YAML

echo ""
echo "— behavioral cases —"

# 1. THE RACE: no labels yet, blocked path ⇒ refused via direct read.
reset_case
STUB_RISK_FILE="$T/risk-fixture.yml"
printf '%s\n' "src/wxa_secrets/onepassword.py" "tests/regression/test_op.py" > "$STUB_FILES"
run_gate
expect_verdict "race case: blocked path + no label yet ⇒ blocked (risk-paths)" 1 "risk:blocked" "risk-paths"

# 2. sensitive path, no labels.
reset_case
STUB_RISK_FILE="$T/risk-fixture.yml"
printf '%s\n' "src/agent/runtime/loop.py" > "$STUB_FILES"
run_gate
expect_verdict "sensitive path + no label ⇒ blocked (risk-paths)" 1 "risk:sensitive" "risk-paths"

# 3. clean PR.
reset_case
STUB_RISK_FILE="$T/risk-fixture.yml"
printf '%s\n' "src/util/helpers.py" "docs/notes.md" "tests/test_helpers.py" > "$STUB_FILES"
run_gate
expect_verdict "clean PR ⇒ not blocked" 0 "" ""

# 4. label belt-and-suspenders: label present, files clean.
reset_case
STUB_LABELS="risk:blocked"
STUB_RISK_FILE="$T/risk-fixture.yml"
printf '%s\n' "docs/notes.md" > "$STUB_FILES"
run_gate
expect_verdict "hand-applied risk:blocked label alone still gates" 1 "risk:blocked" "label"

# 5. base-ref pinning on a non-default base (the stub exits 64 on any
#    rules read that does not carry ref=<base>, so every case above also
#    asserts the pin; this one proves a non-'main' base is honored).
reset_case
CASE_BASE_REF="release/1.2"
STUB_RISK_FILE="$T/risk-fixture.yml"
printf '%s\n' "src/wxa_secrets/store.py" > "$STUB_FILES"
run_gate
expect_verdict "rules read pinned to non-default base ref (release/1.2)" 1 "risk:blocked" "risk-paths"

# 6. no risk-paths.yml on base OR default branch ⇒ not blocked here;
#    global regex still gates downstream.
reset_case
CASE_BASE_REF="release/0.9"
printf '%s\n' "src/anything.py" > "$STUB_FILES"
run_gate
expect_verdict "risk-paths.yml absent on base AND default (404×2) ⇒ falls through to regex" 0 "" ""

# 7. FAIL CLOSED: rules unreadable (non-404).
reset_case
STUB_RISK_RC=1
printf '%s\n' "src/anything.py" > "$STUB_FILES"
run_gate
expect_fail_closed "unreadable risk-paths.yml (HTTP 500 ×3) fails closed" "refusing to arm auto-merge"

# 8. FAIL CLOSED: 3000-file listing cap.
reset_case
STUB_RISK_FILE="$T/risk-fixture.yml"
i=0
while [ "$i" -lt 3000 ]; do echo "docs/f$i.md"; i=$((i + 1)); done > "$STUB_FILES"
run_gate
expect_fail_closed "3000+ changed files fails closed" "file listing is truncated"

# 9. nocase parity with classify.mjs (wxa-jake-ai#875 shape): an uppercase
#    variant must still hit a lowercase blocked glob.
reset_case
STUB_RISK_FILE="$T/risk-fixture.yml"
printf '%s\n' "docs/SECRETS.md" > "$STUB_FILES"
run_gate
expect_verdict "docs/SECRETS.md hits lowercase '**/secrets*' (classify.mjs nocase inherited)" 1 "risk:blocked" "risk-paths"

# 10. FAIL CLOSED on an unreadable label set — a hand-applied risk label
#     is an independent signal the file check cannot reconstruct. The
#     clean-files variant is the load-bearing one: with blocked files,
#     Signal 2 would mask a fail-open here (codex round-3 P1).
reset_case
STUB_LABELS_RC=1
STUB_RISK_FILE="$T/risk-fixture.yml"
printf '%s\n' "src/wxa_secrets/store.py" > "$STUB_FILES"
run_gate
expect_fail_closed "unreadable label set (blocked path) fails closed" "could not read PR labels"

reset_case
STUB_LABELS_RC=1
STUB_RISK_FILE="$T/risk-fixture.yml"
printf '%s\n' "docs/notes.md" > "$STUB_FILES"
run_gate
expect_fail_closed "unreadable label set (clean files) fails closed — hand-applied label can't be silently lost" "could not read PR labels"

# 11. DEFAULT-BRANCH FALLBACK: base ref (legacy release branch) lacks the
#     file; the default branch's policy must be applied — a legacy base
#     must not dodge the repo's policy (codex round-2 P1).
reset_case
CASE_BASE_REF="release/0.9"
STUB_RISK_DEFAULT_FILE="$T/risk-fixture.yml"
printf '%s\n' "src/wxa_secrets/store.py" > "$STUB_FILES"
run_gate
expect_verdict "base 404 ⇒ default branch policy applied (legacy base can't dodge)" 1 "risk:blocked" "risk-paths"

# 12. FAIL CLOSED on classifier-output enum violation: a classifier that
#     prints something outside the documented class set must never be
#     read as benign (codex round-2 P2).
reset_case
printf '%s\n' "console.log('bogus');" > "$T/bogus-classify.mjs"
STUB_CLASSIFY_FILE="$T/bogus-classify.mjs"
STUB_RISK_FILE="$T/risk-fixture.yml"
printf '%s\n' "docs/notes.md" > "$STUB_FILES"
run_gate
expect_fail_closed "classifier output outside the class enum fails closed" "unexpected class"

# ---------------------------------------------------------------------------
# 13-15. RENAME ESCAPE (dotclaude#336, 2026-09-17).
#
# A rename reports ONLY its destination in `.filename`. Moving a gated file
# to a path that matches nothing classified `standard` — auto-merge armed —
# and a docs/** destination was then armed by safe-paths-automerge.yml too.
# The global-regex lane has scanned `.previous_filename` since codex round 9;
# this lane, which enforces the repo's OWN risk-paths.yml, did not.
#
# Every case below keeps the DESTINATION deliberately benign, so the verdict
# can only come from the rename source.
# ---------------------------------------------------------------------------

# 13a. The headline case: a `sensitive:` file moved into docs/**.
reset_case
STUB_RISK_FILE="$T/risk-fixture.yml"
STUB_RENAMES="src/agent/runtime/loop.py"
printf '%s\n' "docs/archive/loop.py" > "$STUB_FILES"
run_gate
expect_verdict "rename OUT of a sensitive path still classifies sensitive" 1 "risk:sensitive" "risk-paths"

# 13b. Same shape one tier up — a `blocked:` file moved out.
reset_case
STUB_RISK_FILE="$T/risk-fixture.yml"
STUB_RENAMES="src/wxa_secrets/onepassword.py"
printf '%s\n' "docs/archive/onepassword.py" > "$STUB_FILES"
run_gate
expect_verdict "rename OUT of a blocked path still classifies blocked" 1 "risk:blocked" "risk-paths"

# 13c. NEGATIVE CONTROL. Without this the two cases above pass just as well
#      under a gate that blocks every PR carrying any rename at all — which
#      would arm nothing, fleet-wide. Neither end is gated ⇒ not blocked.
reset_case
STUB_RISK_FILE="$T/risk-fixture.yml"
STUB_RENAMES="docs/old-notes.md"
printf '%s\n' "docs/notes.md" > "$STUB_FILES"
run_gate
expect_verdict "benign rename (neither end gated) ⇒ not blocked" 0 "" ""

# 13d. Second negative control: the classifier must read the rename SOURCE,
#      not merely notice the field exists. A source under safe_test moved to
#      another safe_test path stays ungated even though the fixture gates
#      siblings of both paths.
reset_case
STUB_RISK_FILE="$T/risk-fixture.yml"
STUB_RENAMES="tests/regression/test_old.py"
printf '%s\n' "tests/regression/test_new.py" > "$STUB_FILES"
run_gate
expect_verdict "safe_test → safe_test rename ⇒ not blocked" 0 "" ""

# 14. ORDERING: rename sources are appended AFTER the 3000-file count, so
#     they can never push a large-but-listable PR over the cap — and are
#     still classified once past it. 2999 changed + 2 rename sources = 3001
#     paths; counting them together would fail closed on a PR that is
#     listable, which reads as "safe" but is really a fleet-wide false
#     alarm on every big rename-heavy PR.
reset_case
STUB_RISK_FILE="$T/risk-fixture.yml"
i=0
while [ "$i" -lt 2999 ]; do echo "docs/f$i.md"; i=$((i + 1)); done > "$STUB_FILES"
STUB_RENAMES=$(printf '%s\n%s' "docs/old-a.md" "src/agent/runtime/loop.py")
run_gate
expect_verdict "2999 files + rename sources: counted before the append, classified after" 1 "risk:sensitive" "risk-paths"

# 15. FAIL CLOSED on an unreadable rename listing. The pre-fix global-regex
#     lane swallowed this with `2>/dev/null || echo ""`, so an API blip read
#     as "this PR renames nothing" — handing back the exact escape the scan
#     closes, silently and with no annotation.
reset_case
STUB_RISK_FILE="$T/risk-fixture.yml"
STUB_RENAMES_RC=1
printf '%s\n' "docs/archive/loop.py" > "$STUB_FILES"
run_gate
expect_fail_closed "unreadable rename listing fails closed" "could not list PR rename sources"

echo ""
if [ "$failed" -gt 0 ]; then
  echo "FAIL: riskfile-gate case(s) regressed."
  exit 1
fi
echo "OK: all riskfile-gate cases pass."
