#!/usr/bin/env bash
# Behavioral test for the ruff version pin and rule-set warning in lint.yml.
#
# The ruff job shipped (#137, 2026-07-31) running a bare `pipx run ruff`,
# justified in-line as "unpinned on purpose: bb-preflight runs whatever ruff
# the workstation ships, so a CI pin would re-open the local-vs-CI rule-set
# gap in the other direction." That is backwards. The two sides never floated
# together — bb-preflight resolves `command -v ruff` (the workstation build)
# and this job resolved `pipx run ruff` (newest on PyPI). They agreed only by
# coincidence, and stopped agreeing the same day: ruff's BUILT-IN defaults
# (what you get with no `select`) widened in 0.16, so dotclaude's unchanged
# tests/ tree was clean on 0.15.10 and threw 25 errors on 0.16.1 — ISC004 x12,
# PLW1510 x8, FURB167 x3, RUF059, PIE810 (dotclaude#186). The job meant to
# close a local-green/CI-red asymmetry recreated it inverted.
#
# Pins, in order of what actually breaks if they regress:
#   1. The default is an exact version, and the job never floats implicitly.
#      This is the regression guard for the incident above.
#   2. The null-inputs `||` fallback equals the declared default. On this
#      repo's own self-test triggers the `inputs` context is null and
#      stringifies to '', so a drifted fallback would silently dogfood a
#      different ruff than callers get — the same class of bug, one level up.
#   3. `latest` is the only way to float, and it announces itself.
#   4. The rule-set detector reads ONLY `[tool.ruff*]` tables. A `select =`
#      under some other tool must not suppress the warning, or a repo gets
#      told it declared a rule set it did not.
#   5. ruff is never invoked via `python3 -m` (see the job comment: that
#      resolves a top-level module from the checkout CWD first, letting PR
#      content execute on the runner or fake a pass).
#
# The version-construction and rule-set-detection blocks are EXTRACTED from
# the workflow YAML and executed, so this exercises the shipped bash rather
# than a mirrored copy.
#
# Run from the repo root:
#   bash selftest/test_ruff_version_pin.sh
set -euo pipefail

WF=.github/workflows/lint.yml
failed=0

pass() { echo "✓ $1"; }
fail() {
  echo "✗ $1"
  failed=1
}

# Strip the YAML block indentation so the extracted bash can be eval'd.
dedent() { sed 's/^[[:space:]]*//'; }

# --- 1. the default pin is an exact version ---------------------------------
DECLARED_DEFAULT=$(awk '
  /^[[:space:]]*ruff_version:/ { in_input = 1; next }
  in_input && /^[[:space:]]*default:/ {
    line = $0
    sub(/^[^:]*:[[:space:]]*/, "", line)
    gsub(/"/, "", line)
    print line
    exit
  }
  in_input && /^[[:space:]]*[a-z_]+:$/ { exit }
' "$WF")

if printf '%s' "$DECLARED_DEFAULT" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  pass "ruff_version default is an exact pin ($DECLARED_DEFAULT)"
else
  fail "ruff_version default must be an exact X.Y.Z version, got: '${DECLARED_DEFAULT:-<none>}'"
fi

# --- 2. the null-inputs fallback matches the declared default ----------------
FALLBACK=$(grep -o "inputs\.ruff_version || '[^']*'" "$WF" | head -1 | sed "s/.*|| '\(.*\)'/\1/")
if [ -z "$FALLBACK" ]; then
  fail "no \`inputs.ruff_version || '<default>'\` fallback — self-test runs would float"
elif [ "$FALLBACK" = "$DECLARED_DEFAULT" ]; then
  pass "null-inputs fallback matches the declared default ($FALLBACK)"
else
  fail "fallback '$FALLBACK' != declared default '$DECLARED_DEFAULT' — this repo would dogfood a different ruff than callers"
fi

# --- 3. no implicit float anywhere in the job -------------------------------
if grep -Eq '^[[:space:]]*pipx run ruff( |$)' "$WF"; then
  fail "job invokes a bare \`pipx run ruff\` — that is the unpinned form the pin exists to remove"
else
  pass "no bare \`pipx run ruff\` invocation in the workflow"
fi

# --- 4. ruff is never run via \`python3 -m\` ----------------------------------
# Comment lines are stripped first: the job comment names `python3 -m pip
# install ruff` precisely to say it is forbidden, and matching that prose
# would make this assertion fire on the correct implementation.
if grep -Ev '^[[:space:]]*#' "$WF" | grep -Eq 'python3? -m +(pip +install +)?ruff'; then
  fail "ruff invoked via \`python3 -m\` — resolves a top-level ruff.py from the checkout first"
else
  pass "ruff is not invoked via \`python3 -m\`"
fi

# --- 5. behavioral: version -> argv -----------------------------------------
version_block=$(awk '
  /^[[:space:]]*RUFF=\(pipx run\)/ { grab = 1 }
  grab { print }
  grab && /^[[:space:]]*fi[[:space:]]*$/ { exit }
' "$WF" | dedent)

if [ -z "$version_block" ]; then
  fail "could not extract the RUFF=() construction block from $WF"
else
  # Pinned version -> --spec ruff==X.Y.Z
  out=$(
    RUFF_VERSION=0.15.10
    eval "$version_block" >/dev/null
    printf '%s' "${RUFF[*]}"
  )
  if [ "$out" = "pipx run --spec ruff==0.15.10 ruff" ]; then
    pass "pinned version builds: pipx run --spec ruff==0.15.10 ruff"
  else
    fail "expected 'pipx run --spec ruff==0.15.10 ruff', got: '$out'"
  fi

  # A different pin must be threaded through verbatim.
  out=$(
    RUFF_VERSION=0.16.1
    eval "$version_block" >/dev/null
    printf '%s' "${RUFF[*]}"
  )
  if [ "$out" = "pipx run --spec ruff==0.16.1 ruff" ]; then
    pass "an overridden pin is threaded through verbatim"
  else
    fail "expected 'pipx run --spec ruff==0.16.1 ruff', got: '$out'"
  fi

  # 'latest' is the only float, and it warns.
  out=$(
    RUFF_VERSION=latest
    eval "$version_block" >/dev/null
    printf '%s' "${RUFF[*]}"
  )
  warn=$(
    RUFF_VERSION=latest
    eval "$version_block"
  )
  if [ "$out" = "pipx run ruff" ]; then
    pass "'latest' floats: pipx run ruff"
  else
    fail "expected 'latest' to build 'pipx run ruff', got: '$out'"
  fi
  case "$warn" in
    *"::warning::"*) pass "'latest' emits a ::warning:: annotation" ;;
    *) fail "'latest' floated silently — the escape hatch must announce itself" ;;
  esac
fi

# --- 6. behavioral: rule-set detection --------------------------------------
ruleset_block=$(awk '
  /^[[:space:]]*RULESET_DECLARED=0/ { grab = 1 }
  grab && /^[[:space:]]*echo "ruff check:/ { exit }
  grab { print }
' "$WF" | dedent)

if [ -z "$ruleset_block" ]; then
  fail "could not extract the rule-set detection block from $WF"
else
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT

  # Each case: name | expect_warning(yes/no) | file | contents
  check_case() {
    name=$1
    expect=$2
    shift 2
    case_dir="$tmp/case"
    rm -rf "$case_dir"
    mkdir -p "$case_dir"
    while [ "$#" -ge 2 ]; do
      printf '%s\n' "$2" >"$case_dir/$1"
      shift 2
    done
    got=$(
      cd "$case_dir"
      # Consumed by the eval'd block, which shellcheck cannot follow.
      # shellcheck disable=SC2034
      RUFF_VERSION=0.15.10
      eval "$ruleset_block" 2>&1 || true
    )
    case "$got" in
      *"::warning::No explicit ruff rule selection"*) actual=yes ;;
      *) actual=no ;;
    esac
    if [ "$actual" = "$expect" ]; then
      pass "$name (warning=$actual)"
    else
      fail "$name: expected warning=$expect, got warning=$actual"
    fi
  }

  check_case "pyproject with [tool.ruff.lint] select -> no warning" no \
    pyproject.toml '[tool.ruff.lint]
select = ["E4", "E7", "E9", "F"]'

  check_case "pyproject with legacy [tool.ruff] select -> no warning" no \
    pyproject.toml '[tool.ruff]
select = ["E", "F"]'

  check_case "pyproject with extend-select -> no warning" no \
    pyproject.toml '[tool.ruff.lint]
extend-select = ["I"]'

  check_case "pyproject with no ruff config -> warning" yes \
    pyproject.toml '[project]
name = "x"'

  # The false-negative that would matter: a `select` owned by another tool.
  check_case "select under a non-ruff table -> still warns" yes \
    pyproject.toml '[project]
name = "x"

[tool.someotherlinter]
select = ["ALL"]'

  # A ruff table that configures something other than the rule set.
  check_case "[tool.ruff] without any select -> warning" yes \
    pyproject.toml '[tool.ruff]
line-length = 100'

  check_case "ruff.toml with select -> no warning" no \
    ruff.toml 'select = ["E4", "F"]'

  check_case "ruff.toml without select -> warning" yes \
    ruff.toml 'line-length = 100'

  check_case ".ruff.toml with [lint] extend-select -> no warning" no \
    .ruff.toml '[lint]
extend-select = ["B"]'

  check_case "no config files at all -> warning" yes

  rm -rf "$tmp"
  trap - EXIT
fi

exit "$failed"
