#!/usr/bin/env bash
# Behavioral test for the "Cap test-backed lessons bullets" step in
# regression-convention.yml — the gate that stops a lessons section from
# growing back after a compression.
#
# Why the gate exists (topcoder1/dotclaude, measured from git history): a
# hand-run compression cut CLAUDE.md 71,436B -> 40,951B in 2026-07, taking its
# `## Lessons` section from 20,217B to 6,200B. Two months later that section
# was 8,013B — back up 29%, ~900B/month — while `## Process notes` held flat
# (14,577 -> 14,108B). One section grows; a manual cycle does not hold. The
# gate targets the bullets whose paired regression test is already the control,
# so capping the prose removes a second copy rather than a protection.
#
# Policy pinned here — each case is a way the gate could be wrong in the
# direction that matters (failing a PR it has no business failing):
#
#   * added over-cap bullet WITH a test citation  -> refuse
#   * bullet unchanged from base, even if over    -> PASS (no backlog tax:
#                                                    adopting the gate must not
#                                                    fail PRs for old text)
#   * over-cap bullet with NO test citation       -> PASS (prose is still the
#                                                    only control for those)
#   * added bullet under the cap                  -> PASS
#   * empty lessons_files                         -> PASS (opt-in by config)
#
# Run from the repo root:
#   bash selftest/test_regression_convention_bullet_cap.sh
set -euo pipefail

WF=.github/workflows/regression-convention.yml
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
failed=0

# ---------------------------------------------------------------------------
# Extract the step's run block (the lines under `run: |`, de-indented).
# ---------------------------------------------------------------------------
awk '
  /^      - name: Cap test-backed lessons bullets$/ { in_step=1; next }
  in_step && /^      - name: / { exit }
  in_step && /^        run: \|$/ { in_run=1; next }
  in_run && /^          / { sub(/^          /, ""); print; next }
  in_run && /^[[:space:]]*$/ { print ""; next }
  in_run { exit }
' "$WF" > "$T/cap.sh"
if ! grep -q 'VIOLATIONS' "$T/cap.sh"; then
  echo "✗ could not extract the bullet-cap run block from $WF"
  exit 1
fi
echo "✓ extracted bullet-cap step ($(wc -l < "$T/cap.sh" | tr -d ' ') lines)"

if grep -q '\${{' "$T/cap.sh"; then
  echo "✗ the run block contains \${{ }} interpolation (must read inputs from env only)"
  failed=1
else
  echo "✓ no \${{ }} interpolation inside the run block"
fi

# The gate must be opt-in: a default-on cap would fail PRs fleet-wide the day
# it lands, in every repo that already has a long lessons bullet.
if grep -A4 'max_test_backed_bullet_chars:' "$WF" | grep -q 'default: 0'; then
  echo "✓ input defaults to 0 (disabled unless a caller opts in)"
else
  echo "✗ max_test_backed_bullet_chars must default to 0"
  failed=1
fi
if grep -q "inputs.max_test_backed_bullet_chars > 0" "$WF"; then
  echo "✓ step is guarded by an if: on a non-zero cap"
else
  echo "✗ step is missing the non-zero-cap if: guard"
  failed=1
fi

# ---------------------------------------------------------------------------
# Fixture repo: base commit, then a head commit that edits the lessons file.
# ---------------------------------------------------------------------------
BIG_CITED="- **$(printf 'x%.0s' {1..400})** something. Test: repo \`tests/regression/test_x.py\`. [2026-09-18]"
BIG_UNCITED="- **$(printf 'y%.0s' {1..400})** something with no paired test. [2026-09-18]"
SMALL_CITED="- **short rule** detail. Test: repo \`tests/regression/test_y.py\`. [2026-09-18]"

make_repo() {  # $1 = base lessons body, $2 = head lessons body
  local d="$T/repo$RANDOM"
  mkdir -p "$d" && cd "$d"
  git init -q . && git config user.email t@t && git config user.name t
  { echo "## Lessons"; printf '%s\n' "$1"; echo; echo "## Other"; } > CLAUDE.md
  git add -A && git commit -qm base
  BASE=$(git rev-parse HEAD)
  { echo "## Lessons"; printf '%s\n' "$2"; echo; echo "## Other"; } > CLAUDE.md
  # --allow-empty: the "bullet unchanged" case is a PR that edits other
  # files and leaves the lessons text alone. Without it git refuses the
  # commit and the function returns git's message instead of a SHA.
  git add -A && git commit -q --allow-empty -m head
  HEAD_S=$(git rev-parse HEAD)
  echo "$d $BASE $HEAD_S"
}

run_case() {  # $1 label, $2 expected rc, $3 base body, $4 head body, $5 cap, $6 files
  local label="$1" want="$2" cap="$5" files="${6-CLAUDE.md}"
  read -r d base head <<<"$(make_repo "$3" "$4")"
  local rc=0
  ( cd "$d" && LESSONS_FILES_RAW="$files" LESSONS_HEADER='## Lessons' \
      MAX_CHARS="$cap" BASE_SHA="$base" HEAD_SHA="$head" \
      bash "$T/cap.sh" ) >"$T/out" 2>&1 || rc=$?
  if [[ "$rc" == "$want" ]]; then
    echo "✓ $label (rc=$rc)"
  else
    echo "✗ $label: expected rc=$want, got rc=$rc"
    sed 's/^/    /' "$T/out" | head -6
    failed=1
  fi
}

run_case "over-cap bullet WITH a test citation is refused"        1 "$SMALL_CITED" "$BIG_CITED"   300
run_case "same over-cap bullet UNCHANGED from base is allowed"    0 "$BIG_CITED"   "$BIG_CITED"   300
run_case "over-cap bullet with NO test citation is allowed"       0 "$SMALL_CITED" "$BIG_UNCITED" 300
run_case "added bullet under the cap is allowed"                  0 "$SMALL_CITED" "$SMALL_CITED
$SMALL_CITED"                                                                                     300
run_case "empty lessons_files skips"                              0 "$SMALL_CITED" "$BIG_CITED"   300 ""

if (( failed )); then
  echo "FAIL"
  exit 1
fi
echo "PASS"
