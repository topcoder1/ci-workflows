#!/usr/bin/env bash
# Behavioral test for safe-paths-automerge.yml's TIER 3 hold — the step that
# makes this workflow honor the CALLER's own .github/risk-paths.yml.
#
# Why the tier exists. Tiers 1 and 2 are fleet-wide lists; neither has ever
# read the caller's risk-paths.yml. So a path a repo declared `sensitive:` or
# `blocked:` in its OWN policy was armed here regardless — and the sibling
# gate declining to arm it changes nothing, because a decline is an
# ABSTENTION, not a veto: this workflow is the only one that arms a
# docs/tests diff (inbox_superpilot#215, 2026-08-10). The fleet had been
# patching this one pattern at a time — docs/legal, docs/decisions,
# docs/marketing, docs/pricing, docs/product-page all entered the CENTRAL
# lists because some repo's own `sensitive:` entry could not reach here.
#
# The rename half (dotclaude#336, 2026-09-17): a rename reports only its
# DESTINATION in `.filename`, so a gated file moved to `docs/archive/x.md`
# is judged solely on its new, safe-by-glob path — and this is the workflow
# that would arm it.
#
# Pins:
#   1. No caller policy (404 on base AND default) ⇒ hold=0. The majority of
#      the fleet; it must stay armable and cost one 404.
#   2. A caller-gated path ⇒ hold=1 reason=classifier-hold, for both gating
#      classes, with clean-docs and benign-rename NEGATIVE CONTROLS so the
#      hold cannot pass by blocking everything.
#   3. Rename SOURCES are classified, with a benign destination.
#   4. BASE-REF PINNING: every rules read carries ref=<base> (the gh stub
#      hard-fails otherwise) — a PR must never consult its own head policy.
#   5. DEFAULT-BRANCH FALLBACK: a legacy base that predates the policy file
#      does not dodge it.
#   6. FAIL CLOSED on every unreadable input — rules, file listing, rename
#      listing, truncation, classifier error, enum violation.
#   7. THE STEP NEVER EXITS NONZERO. This is load-bearing and is asserted on
#      every case: a failed step SKIPS the revoke step below it, leaving an
#      arm a previous run placed standing — the opposite of fail-closed for
#      the PR that most needs it. Fail-closed here means hold=1 + a reason,
#      which both withholds the arm and triggers the revoke.
#   8. Rename sources are appended AFTER the 3000-file count, so they cannot
#      push a large-but-listable PR over the cap.
#   9. Structural: the enable step requires hold == '0' (positive evidence,
#      not merely "not 1"), the revoke step fires on hold == '1', and the
#      bypass label does NOT release a caller-policy verdict.
#
# The step's bash is EXTRACTED from the workflow YAML and executed against
# the REAL classify.mjs, so this exercises the shipped gate rather than a
# mirrored copy that can drift.
#
# Run from the repo root:
#   bash selftest/test_safe_paths_classifier_hold.sh
set -euo pipefail

WF=.github/workflows/safe-paths-automerge.yml
SIB=.github/workflows/claude-author-automerge.yml
CLASSIFY=.github/scripts/classify.mjs
DEPS=.github/scripts/classifier-deps.mjs
failed=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# ---------------------------------------------------------------------------
# 0a. Structural pins on the surrounding job.
# ---------------------------------------------------------------------------
# Comments are stripped first: this workflow discusses the tier at length in
# prose, and matching that would let a job that had STOPPED wiring the step
# still pass.
wf_code=$(grep -vE '^[[:space:]]*#' "$WF" || true)

if grep -qE "steps\.classifier_hold\.outputs\.hold == '0'" <<<"$wf_code"; then
  echo "✓ enable step arms only on POSITIVE evidence (hold == '0')"
else
  echo "✗ enable step does not require hold == '0' — a skipped or hard-failed classifier step reads as permission to arm"
  failed=1
fi

if grep -qE "steps\.classifier_hold\.outputs\.hold == '1'" <<<"$wf_code"; then
  echo "✓ revoke step fires on a classifier hold (an arm from an earlier revision cannot survive)"
else
  echo "✗ revoke step does not fire on classifier_hold — GitHub preserves an arm across pushes, so a later caller-gated push would keep it"
  failed=1
fi

# The tier-3 verdict must NOT be releasable by the bypass label, mirroring the
# sibling gate, where a blocked/sensitive classifier verdict skips the bypass
# step entirely. The fleet lists are our guess about a repo; risk-paths.yml is
# that repo's stated policy, and a label click is not an amendment to it.
#
# Asserted on what the step CONSUMES — the BYPASS_LABEL env it would need and
# any label read it would have to make — not on the word "bypass", which the
# step's own hold message uses to tell the operator the label will not help.
# (A bare `grep -i bypass` here failed on exactly that sentence.)
step_block=$(awk '
  /^      - name: Check the caller/ { f=1 }
  f && /^      - name: Revoke/      { f=0 }
  f { print }
' "$WF")
if grep -qE 'BYPASS_LABEL|risk_bypass_label|labels\[\]\.name|issues/[^ ]*/labels' <<<"$step_block"; then
  echo "✗ the classifier hold reads the bypass label — a label click must not amend the repo's own risk-paths.yml"
  failed=1
else
  echo "✓ the bypass label does not release a caller-policy verdict (sibling parity)"
fi

# Same classifier as the other two lanes, from the same source: three gates
# disagreeing about glob semantics is the bug class this tier exists to close.
if grep -q 'repos/topcoder1/ci-workflows/contents/.github/scripts/' <<<"$wf_code" \
  && grep -q 'classify\.mjs' <<<"$wf_code" \
  && grep -q 'classifier-deps\.mjs' <<<"$wf_code"; then
  echo "✓ $WF fetches the shared classifier + vendored dep bundle (one matcher across all three lanes)"
else
  echo "✗ $WF does not fetch the shared classifier — glob semantics can drift from the sibling gates"
  failed=1
fi

if grep -q -- '-f ref="\$ref"' "$WF"; then
  echo "✓ rules read is pinned to an explicit ref (base, then default-branch fallback)"
else
  echo "✗ rules read is not pinned to an explicit ref — a PR could consult its own head policy"
  failed=1
fi

# The sibling must keep enforcing the same policy file; if it ever stopped,
# this tier would be the only reader and the asymmetry that motivated it
# would have silently inverted.
if grep -q 'contents/.github/risk-paths.yml' "$SIB"; then
  echo "✓ sibling gate still reads the caller's risk-paths.yml too"
else
  echo "✗ $SIB no longer reads risk-paths.yml — the two gates have diverged"
  failed=1
fi

# ---------------------------------------------------------------------------
# 0b. Extract the shipped step.
# ---------------------------------------------------------------------------
awk '
  /^        id: classifier_hold[[:space:]]*$/ { in_step=1 }
  in_step && /^        run: \|/ { in_run=1; next }
  in_run {
    if ($0 ~ /^          / || $0 == "") { sub(/^          /, ""); print }
    else { exit }
  }
' "$WF" > "$T/hold.sh"

if ! grep -q 'risk-paths.yml' "$T/hold.sh" || ! grep -q 'GITHUB_OUTPUT' "$T/hold.sh"; then
  echo "✗ could not extract the classifier_hold run block from $WF"
  exit 1
fi
echo "✓ extracted classifier_hold step ($(wc -l < "$T/hold.sh" | tr -d ' ') lines)"

# ---------------------------------------------------------------------------
# 0c. Stubs.
#   Knobs (env):
#     STUB_RISK_FILE         — BASE-ref risk-paths.yml fixture; '' = 404
#     STUB_RISK_DEFAULT_FILE — DEFAULT-branch fixture; '' = 404
#     STUB_RISK_RC           — nonzero: base-ref read fails NON-404
#     STUB_FILES             — file holding the changed-file list
#     STUB_FILES_RC          — nonzero: the changed-file listing fails
#     STUB_RENAMES           — newline-separated rename SOURCES
#     STUB_RENAMES_RC        — nonzero: the rename listing fails
#     STUB_CLASSIFY_FILE     — classifier served (default: the real one)
#
#   Any rules read whose ref is neither the base ref nor the default branch
#   exits 64, so base-ref pinning is asserted on EVERY case, not just one.
# ---------------------------------------------------------------------------
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
args="$*"
case "$args" in
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
    # Two calls hit this endpoint — the changed-file listing (.filename) and
    # the rename sources (.previous_filename). Discriminate on the --jq
    # expression: a stub answering both with the same fixture would make
    # every rename case pass vacuously, since the destination it already
    # returns is precisely what we are proving is insufficient.
    case "$args" in
      *previous_filename*)
        [ "${STUB_RENAMES_RC:-0}" != "0" ] && { echo "gh: Internal Server Error (HTTP 500)" >&2; exit 1; }
        printf '%s' "${STUB_RENAMES:-}"
        ;;
      *)
        [ "${STUB_FILES_RC:-0}" != "0" ] && { echo "gh: Internal Server Error (HTTP 500)" >&2; exit 1; }
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

REAL_CLASSIFY="$PWD/$CLASSIFY"
REAL_DEPS="$PWD/$DEPS"

# ---------------------------------------------------------------------------
# Runner + assertions.
# ---------------------------------------------------------------------------
STUB_RISK_FILE=""; STUB_RISK_DEFAULT_FILE=""; STUB_RISK_RC=0
STUB_FILES="$T/files.txt"; STUB_FILES_RC=0
STUB_RENAMES=""; STUB_RENAMES_RC=0; STUB_CLASSIFY_FILE=""
CASE_BASE_REF="main"; CASE_DEFAULT_BRANCH="main"

reset_case() {
  STUB_RISK_FILE=""; STUB_RISK_DEFAULT_FILE=""; STUB_RISK_RC=0
  STUB_FILES_RC=0; STUB_RENAMES=""; STUB_RENAMES_RC=0; STUB_CLASSIFY_FILE=""
  CASE_BASE_REF="main"; CASE_DEFAULT_BRANCH="main"
  : > "$STUB_FILES"
}

run_hold() {
  OUT_FILE="$T/gh-output.txt"
  : > "$OUT_FILE"
  set +e
  HOLD_LOG=$(cd "$T" && \
    PATH="$T/bin:$PATH" \
    REPO="acme/fixture" PR=123 BASE_REF="$CASE_BASE_REF" \
    DEFAULT_BRANCH="$CASE_DEFAULT_BRANCH" \
    GITHUB_OUTPUT="$OUT_FILE" GH_TOKEN=stub \
    STUB_RISK_FILE="$STUB_RISK_FILE" STUB_RISK_DEFAULT_FILE="$STUB_RISK_DEFAULT_FILE" \
    STUB_RISK_RC="$STUB_RISK_RC" STUB_FILES="$STUB_FILES" STUB_FILES_RC="$STUB_FILES_RC" \
    STUB_RENAMES="$STUB_RENAMES" STUB_RENAMES_RC="$STUB_RENAMES_RC" \
    STUB_CLASSIFY_FILE="$STUB_CLASSIFY_FILE" \
    REAL_CLASSIFY="$REAL_CLASSIFY" REAL_DEPS="$REAL_DEPS" \
    bash hold.sh 2>&1)
  HOLD_RC=$?
  set -e
}

out_get() { grep "^$1=" "$OUT_FILE" | tail -1 | cut -d= -f2- || true; }

# expect <desc> <hold> <reason|->
#
# Asserts rc=0 unconditionally. A nonzero exit would skip the revoke step and
# strand an existing arm, so "the step held" and "the step succeeded" are the
# same requirement here — pin 7.
expect() {
  local desc="$1" want_hold="$2" want_reason="$3"
  if [ "$HOLD_RC" != "0" ]; then
    echo "✗ $desc — step exited rc=$HOLD_RC; it must ALWAYS exit 0 (a failed step skips the revoke and strands an arm). Output:"
    echo "$HOLD_LOG" | sed 's/^/    /'
    failed=1
    return
  fi
  local got_hold got_reason
  got_hold=$(out_get hold); got_reason=$(out_get reason)
  [ -n "$got_reason" ] || got_reason="-"
  if [ "$got_hold" = "$want_hold" ] && { [ "$want_reason" = "-" ] || [ "$got_reason" = "$want_reason" ]; }; then
    echo "✓ $desc (hold=$got_hold reason=$got_reason)"
  else
    echo "✗ $desc — got hold='$got_hold' reason='$got_reason', want '$want_hold'/'$want_reason'. Output:"
    echo "$HOLD_LOG" | sed 's/^/    /'
    failed=1
  fi
}

# A caller policy that gates docs-shaped paths the CENTRAL lists do not
# cover — the whole point of the tier. `docs/runbooks/**` is not in any fleet
# list, and `docs/notes.md` beside it must stay armable.
cat > "$T/risk-fixture.yml" <<'YAML'
blocked:
  - '**/secrets*'
sensitive:
  - 'docs/runbooks/**'
  - 'src/agent/runtime/**'
safe_test:
  - 'tests/**'
trivial:
  - 'docs/**'
YAML

echo ""
echo "— behavioral cases —"

# 1. The majority of the fleet: no caller policy at all.
reset_case
printf '%s\n' "docs/architecture.md" > "$STUB_FILES"
run_hold
expect "no risk-paths.yml on base OR default (404×2) ⇒ armable" 0 -

# 2. A caller-gated docs path the central lists never cover.
reset_case
STUB_RISK_FILE="$T/risk-fixture.yml"
printf '%s\n' "docs/runbooks/prod-restore.md" > "$STUB_FILES"
run_hold
expect "caller's sensitive: docs path ⇒ held" 1 classifier-hold

reset_case
STUB_RISK_FILE="$T/risk-fixture.yml"
printf '%s\n' "docs/SECRETS.md" > "$STUB_FILES"
run_hold
expect "caller's blocked: glob (nocase, via the shared classifier) ⇒ held" 1 classifier-hold

# 2b. NEGATIVE CONTROLS. Without these, every case above passes just as well
#     under a tier that holds every PR in a policy-carrying repo — which
#     would kill the docs/tests carve-out in all 44 carriers.
reset_case
STUB_RISK_FILE="$T/risk-fixture.yml"
printf '%s\n' "docs/architecture.md" "docs/notes.md" > "$STUB_FILES"
run_hold
expect "ordinary docs under a policy that gates OTHER paths ⇒ armable" 0 -

reset_case
STUB_RISK_FILE="$T/risk-fixture.yml"
printf '%s\n' "tests/test_a.py" "tests/test_b.py" > "$STUB_FILES"
run_hold
expect "safe_test paths under a caller policy ⇒ armable" 0 -

# 3. RENAME. The destination is deliberately benign in both directions, so
#    the verdict can only come from the source.
reset_case
STUB_RISK_FILE="$T/risk-fixture.yml"
STUB_RENAMES="docs/runbooks/prod-restore.md"
printf '%s\n' "docs/archive/prod-restore.md" > "$STUB_FILES"
run_hold
expect "gated file renamed INTO docs/** ⇒ still held" 1 classifier-hold

reset_case
STUB_RISK_FILE="$T/risk-fixture.yml"
STUB_RENAMES="src/agent/runtime/loop.py"
printf '%s\n' "docs/archive/loop.py" > "$STUB_FILES"
run_hold
expect "sensitive source outside docs/ renamed into docs/** ⇒ still held" 1 classifier-hold

reset_case
STUB_RISK_FILE="$T/risk-fixture.yml"
STUB_RENAMES="docs/old-notes.md"
printf '%s\n' "docs/notes.md" > "$STUB_FILES"
run_hold
expect "benign rename (neither end gated) ⇒ armable" 0 -

# 4/5. Base-ref pinning and the legacy-base fallback. The stub exits 64 on
#      any rules read that is not ref=<base|default>, so every case above
#      also asserts the pin; these prove a non-'main' base is honored and
#      that a base predating the policy cannot dodge it.
reset_case
CASE_BASE_REF="release/1.2"
STUB_RISK_FILE="$T/risk-fixture.yml"
printf '%s\n' "docs/runbooks/prod-restore.md" > "$STUB_FILES"
run_hold
expect "rules read pinned to a non-default base ref (release/1.2)" 1 classifier-hold

reset_case
CASE_BASE_REF="release/0.9"
STUB_RISK_DEFAULT_FILE="$T/risk-fixture.yml"
printf '%s\n' "docs/runbooks/prod-restore.md" > "$STUB_FILES"
run_hold
expect "base 404 ⇒ default-branch policy applied (legacy base can't dodge)" 1 classifier-hold

# 6. FAIL CLOSED — each as hold=1 + a reason, never a nonzero exit.
reset_case
STUB_RISK_RC=1
printf '%s\n' "docs/notes.md" > "$STUB_FILES"
run_hold
expect "unreadable risk-paths.yml (HTTP 500 ×3) ⇒ held, not armed" 1 rules-unreadable

reset_case
STUB_RISK_FILE="$T/risk-fixture.yml"
STUB_FILES_RC=1
printf '%s\n' "docs/notes.md" > "$STUB_FILES"
run_hold
expect "unreadable changed-file listing ⇒ held" 1 file-list-unreadable

reset_case
STUB_RISK_FILE="$T/risk-fixture.yml"
STUB_RENAMES_RC=1
printf '%s\n' "docs/notes.md" > "$STUB_FILES"
run_hold
expect "unreadable rename listing ⇒ held" 1 file-list-unreadable

reset_case
STUB_RISK_FILE="$T/risk-fixture.yml"
i=0
while [ "$i" -lt 3000 ]; do echo "docs/f$i.md"; i=$((i + 1)); done > "$STUB_FILES"
run_hold
expect "3000+ changed files (REST listing cap) ⇒ held" 1 file-list-truncated

# An empty classifier body is the shape a partial/failed fetch leaves behind.
# Running it would print nothing, which the enum branch would reject anyway —
# but the emptiness check catches it first and names the real cause.
reset_case
: > "$T/empty-classify.mjs"
STUB_CLASSIFY_FILE="$T/empty-classify.mjs"
STUB_RISK_FILE="$T/risk-fixture.yml"
printf '%s\n' "docs/notes.md" > "$STUB_FILES"
run_hold
expect "empty classify.mjs fetched from ci-workflows ⇒ held" 1 classifier-unreadable

reset_case
printf '%s\n' "console.log('bogus');" > "$T/bogus-classify.mjs"
STUB_CLASSIFY_FILE="$T/bogus-classify.mjs"
STUB_RISK_FILE="$T/risk-fixture.yml"
printf '%s\n' "docs/notes.md" > "$STUB_FILES"
run_hold
expect "classifier output outside the class enum ⇒ held" 1 classifier-enum

# classify.mjs's own fail-closed guards (bracket / negation / scalar-where-a-
# list-belongs / YAML parse) exit nonzero. `set -e` would kill the step and
# skip the revoke, so the status is captured and converted to a hold.
cat > "$T/bad-rules.yml" <<'YAML'
sensitive:
  - 'src/routes/[id]/+page.ts'
YAML
reset_case
STUB_RISK_FILE="$T/bad-rules.yml"
printf '%s\n' "docs/notes.md" > "$STUB_FILES"
run_hold
expect "classify.mjs guard failure (bracket pattern) ⇒ held, step still exits 0" 1 classifier-error

# 8. ORDERING: rename sources are appended AFTER the 3000-file count, so they
#    can never push a large-but-listable PR over the cap — and are still
#    classified once past it. Counting them together would fail closed on a
#    listable PR, which reads as "safe" but is a false alarm on every big
#    rename-heavy docs PR.
reset_case
STUB_RISK_FILE="$T/risk-fixture.yml"
i=0
while [ "$i" -lt 2999 ]; do echo "docs/f$i.md"; i=$((i + 1)); done > "$STUB_FILES"
STUB_RENAMES=$(printf '%s\n%s' "docs/old-a.md" "docs/runbooks/prod-restore.md")
run_hold
expect "2999 files + rename sources: counted before the append, classified after" 1 classifier-hold

echo ""
if [ "$failed" -gt 0 ]; then
  echo "FAIL: safe-paths classifier-hold case(s) regressed."
  exit 1
fi
echo "OK: all safe-paths classifier-hold cases pass."
