#!/usr/bin/env bash
# Behavioral test for prettier's changed-file scoping fail-safe in
# lint.yml / prettier-autofix.yml, and prettier-autofix.yml's
# workflow-file commit guard.
#
# Incident (whois-api-llc/wxa-secrets#27, run 29542573990): a transient
# GitHub API error (HTML error body made gh's --jq die with "invalid
# character '<' looking for beginning of value") failed the changed-file
# listing on a Python-only PR. The failure branch fell OPEN to full-glob
# mode: prettier --write ran on the entire tree, picked up pre-existing
# drift in .github/workflows/pr-review.yml — a file the PR never touched
# — and the push was rejected ("refusing to allow a Personal Access
# Token to create or update workflow ... without `workflow` scope").
# Red X on every such PR until the drift is manually cleared.
#
# Pins two invariants:
#   1. A failed changed-file listing SKIPS the run (mode=none). A
#      scoping failure must never widen the target set to the full tree.
#   2. Autofix never commits writes under .github/workflows/ — the push
#      PAT (automerge_pat) deliberately lacks workflow scope (fleet
#      policy), so such a commit can never be pushed.
#
# Blocks are EXTRACTED from the workflow YAML and executed, so this
# exercises the shipped bash, not a mirrored copy. A drift check asserts
# lint.yml and prettier-autofix.yml carry an identical listing block.
#
# Run from the repo root:
#   bash selftest/test_prettier_scope_failsafe.sh
set -euo pipefail

failed=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

AUTOFIX=.github/workflows/prettier-autofix.yml
LINT=.github/workflows/lint.yml

# ---------------------------------------------------------------------------
# 1. Listing block: identical in both workflows; failure path sets
#    mode=none and never mode=glob.
# ---------------------------------------------------------------------------

extract_listing_block() {
  awk '/^[[:space:]]*PR_FILES_LOG="\$\(mktemp\)"/{grab=1} grab{print} grab && /mapfile -t CHANGED/{exit}' "$1"
}

a=$(extract_listing_block "$LINT")
b=$(extract_listing_block "$AUTOFIX")
if [ -z "$a" ] || [ -z "$b" ]; then
  echo "✗ could not extract the changed-file listing block from one of the workflows"
  exit 1
fi
if [ "$a" = "$b" ]; then
  echo "✓ lint.yml and prettier-autofix.yml listing blocks are identical"
else
  echo "✗ listing block drifted between lint.yml and prettier-autofix.yml:"
  diff <(echo "$a") <(echo "$b") | sed 's/^/    /' || true
  failed=1
fi

for wf in "$LINT" "$AUTOFIX"; do
  blk=$(extract_listing_block "$wf")
  if echo "$blk" | grep -q 'mode=glob'; then
    echo "✗ ${wf}: listing-failure branch falls open to mode=glob (must skip with mode=none)"
    failed=1
  elif echo "$blk" | grep -q 'mode=none'; then
    echo "✓ ${wf}: listing failure skips with mode=none"
  else
    echo "✗ ${wf}: listing-failure branch sets neither mode=none nor mode=glob"
    failed=1
  fi
done

# ---------------------------------------------------------------------------
# 2. Workflow-file commit guard in prettier-autofix.yml: present, and
#    runs before `git add -A` stages the tree.
# ---------------------------------------------------------------------------

guard_line=$(grep -n 'git checkout -- \.github/workflows' "$AUTOFIX" | head -1 | cut -d: -f1 || true)
add_line=$(grep -n 'git add -A' "$AUTOFIX" | head -1 | cut -d: -f1 || true)
if [ -z "$guard_line" ]; then
  echo "✗ prettier-autofix.yml: no workflow-file revert guard (git checkout -- .github/workflows)"
  failed=1
elif [ -z "$add_line" ] || [ "$guard_line" -ge "$add_line" ]; then
  echo "✗ prettier-autofix.yml: revert guard must run BEFORE git add -A"
  failed=1
else
  echo "✓ prettier-autofix.yml reverts .github/workflows/ writes before staging"
fi

extract_workflow_guard() {
  awk '/if ! git diff --quiet -- \.github\/workflows/{grab=1} grab{print} grab && /^[[:space:]]*fi$/{exit}' "$AUTOFIX"
}

guard=$(extract_workflow_guard)
if [ -z "$guard" ]; then
  echo "✗ could not extract the workflow-file revert guard block"
  failed=1
else
  snippet=$(echo "$guard" | sed 's/^[[:space:]]*//')
  (
    cd "$T"
    git init -q fixture && cd fixture
    git config user.email selftest@example.invalid
    git config user.name selftest
    mkdir -p .github/workflows
    printf 'name: x\n' > .github/workflows/wf.yml
    printf '# readme\n' > README.md
    git add -A && git commit -qm init

    printf 'name: x\nchanged: true\n' > .github/workflows/wf.yml
    printf '# readme\nchanged\n' > README.md
    eval "$snippet" > /dev/null
    if git diff --quiet -- .github/workflows && ! git diff --quiet -- README.md; then
      echo "✓ guard reverts workflow writes, keeps non-workflow writes"
    else
      echo "✗ guard: expected .github/workflows clean and README.md dirty"
      exit 1
    fi

    git checkout -q -- README.md
    printf 'name: x\nchanged: again\n' > .github/workflows/wf.yml
    eval "$snippet" > /dev/null
    if git diff --quiet; then
      echo "✓ workflow-only drift becomes a full no-op"
    else
      echo "✗ guard: expected fully clean tree after workflow-only drift"
      exit 1
    fi
  ) || failed=1
fi

# ---------------------------------------------------------------------------
# 3. Behavioral scenarios with a stubbed `gh`.
#    3a runs the extracted listing block alone — its failure path exits
#    before `mapfile`, so it works on any bash (incl. macOS 3.2).
#    3b/3c run the full resolve-targets script and need bash >= 4
#    (mapfile, declare -A) — CI runners execute this with bash 5.
# ---------------------------------------------------------------------------

stub="$T/stub"; mkdir -p "$stub"
tree="$T/tree"; mkdir -p "$tree"
printf 'x = 1\n' > "$tree/app.py"
printf 'k: v\n' > "$tree/config.yml"
printf '# hi\n' > "$tree/README.md"

# 3a. Listing failure (the wxa-secrets#27 shape) → skip, not full-glob.
printf '#!/bin/sh\necho "gh: HTTP 502 from api.github.com" >&2\nexit 1\n' > "$stub/gh"
chmod +x "$stub/gh"
out="$T/out.failure"
: > "$out"
blk=$(extract_listing_block "$AUTOFIX")
(
  cd "$tree" &&
    env PATH="$stub:$PATH" \
      GITHUB_OUTPUT="$out" GITHUB_REPOSITORY="o/r" \
      GH_TOKEN=x PR_NUMBER=27 \
      bash -c "set -euo pipefail
$blk" > "$out.log" 2>&1
) || true
if grep -q '^mode=none$' "$out" && ! grep -q 'mode=glob' "$out"; then
  echo "✓ listing failure → mode=none (skip), never full-glob"
else
  echo "✗ listing failure must set mode=none; GITHUB_OUTPUT was:"
  sed 's/^/    /' "$out"
  sed 's/^/    log: /' "$out.log"
  failed=1
fi

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "– skipping full-script scenarios (bash ${BASH_VERSION%%(*} lacks mapfile; CI enforces them)"
else
  extract_resolve_script() {
    awk '
      /- name: Resolve prettier targets/ {in_step=1}
      in_step && /^        run: \|/ {in_run=1; next}
      in_run {
        if ($0 ~ /^          /) { print substr($0, 11); next }
        if ($0 ~ /^[[:space:]]*$/) { print ""; next }
        exit
      }
    ' "$AUTOFIX"
  }
  script=$(extract_resolve_script)
  if [ -z "$script" ]; then
    echo "✗ could not extract the resolve-targets script from prettier-autofix.yml"
    failed=1
  else
    scenario=0
    run_scenario() { # $1 = gh stub body → prints path to GITHUB_OUTPUT file
      scenario=$((scenario + 1))
      local out="$T/out.$scenario"
      : > "$out"
      printf '#!/usr/bin/env bash\n%s\n' "$1" > "$stub/gh"
      chmod +x "$stub/gh"
      (
        cd "$tree" &&
          env PATH="$stub:$PATH" \
            GITHUB_OUTPUT="$out" GITHUB_REPOSITORY="o/r" \
            GH_TOKEN=x PR_NUMBER=27 CHANGED_ONLY=true \
            GLOB='**/*.{md,yml,yaml,json}' \
            bash -c "$script" > "$out.log" 2>&1
      ) || true
      echo "$out"
    }

    # 3b. PR with zero prettier-relevant files (Python-only) → skip.
    out=$(run_scenario 'printf "app.py\n"')
    if grep -q '^mode=none$' "$out" && ! grep -q 'mode=glob' "$out"; then
      echo "✓ python-only PR → mode=none (skip)"
    else
      echo "✗ python-only PR must set mode=none; GITHUB_OUTPUT was:"
      sed 's/^/    /' "$out"
      sed 's/^/    log: /' "$out.log"
      failed=1
    fi

    # 3c. Positive control: a matching changed file → mode=files with it.
    out=$(run_scenario 'printf "README.md\n"')
    if grep -q '^mode=files$' "$out" && grep -q '^README\.md$' "$out"; then
      echo "✓ matching changed file → mode=files targeting it"
    else
      echo "✗ expected mode=files with README.md; GITHUB_OUTPUT was:"
      sed 's/^/    /' "$out"
      sed 's/^/    log: /' "$out.log"
      failed=1
    fi
  fi
fi

exit "$failed"
