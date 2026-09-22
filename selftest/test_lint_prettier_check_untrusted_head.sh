#!/usr/bin/env bash
# Defense in depth: lint.yml's read-only `prettier --check` must never execute
# code the PR head can influence — the same threat prettier-autofix.yml closes,
# minus the push PAT.
#
# On a pull_request the checked-out merge ref carries the attacker-/model-
# writable head content, and prettier's default search LOADS config and plugins
# as code (prettier.config.js, .prettierrc.cjs, a package.json "prettier" ref).
# So even a read-only `--check` runs arbitrary Node on the runner the moment the
# PR opens. The hardening mirrors prettier-autofix.yml:
#   - config from the BASE branch only (`--config <file>`: the base config, or
#     an empty {} that still honors .editorconfig); JS/plugin configs degrade to
#     {} + a ::warning::;
#   - the prettier CLI installed off-checkout (pinned registry, --ignore-scripts,
#     neutralized npm user-config); no `npm ci` in the checkout;
#   - checkout `persist-credentials: false`;
#   - the target list passed after `--`.
#
# CRITICAL consistency property: the check lane (lint.yml) and the write lane
# (prettier-autofix.yml) MUST resolve config identically — otherwise autofix
# "fixes" a file the check still rejects, or vice versa. This test drift-checks
# that the two "Resolve base prettier config" and "Install prettier" step bodies
# are BYTE-IDENTICAL, the same way test_prettier_scope_failsafe.sh /
# test_prettier_symlink_filter.sh pin the listing and symlink blocks.
#
# Blocks are EXTRACTED from the shipped YAML and executed (not mirrored).
#
# Run from the repo root:
#   bash selftest/test_lint_prettier_check_untrusted_head.sh
set -uo pipefail

LINT=.github/workflows/lint.yml
AUTOFIX=.github/workflows/prettier-autofix.yml
failed=0
ok()  { printf '  ok   — %s\n' "$1"; }
bad() { printf '  FAIL — %s\n' "$1"; failed=1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

extract_run_block() { # $1 = step-name substring, $2 = workflow
  # Literal substring match (index), not `~` — step names contain regex
  # metacharacters, e.g. "Install prettier (isolated from PR head)"; a regex
  # match silently returns nothing and a byte-compare of two nothings passes.
  awk -v want="- name: $1" '
    index($0, want) {in_step=1}
    in_step && /^        run: \|/ {in_run=1; next}
    in_run {
      if ($0 ~ /^          /) { print substr($0, 11); next }
      if ($0 ~ /^[[:space:]]*$/) { print ""; next }
      exit
    }
  ' "$2"
}

# ===========================================================================
# 1. DRIFT: the resolve + install steps must be byte-identical to autofix's,
#    so `prettier --check` and `prettier --write` resolve config the same way.
# ===========================================================================
echo "1. resolve + install steps are byte-identical to prettier-autofix.yml"
for step in "Resolve base prettier config" "Install prettier (isolated from PR head)"; do
  a=$(extract_run_block "$step" "$LINT")
  b=$(extract_run_block "$step" "$AUTOFIX")
  if [ -z "$a" ]; then
    bad "lint.yml is missing the '$step' step"
  elif [ "$a" = "$b" ]; then
    ok "'$step' is identical in lint.yml and prettier-autofix.yml"
  else
    bad "'$step' drifted between lint.yml and prettier-autofix.yml:"
    diff <(printf '%s\n' "$a") <(printf '%s\n' "$b") | sed 's/^/      /' | head -30
  fi
done
# The check lane must consume the shared step outputs.
lint_check=$(extract_run_block "prettier --check" "$LINT")
if printf '%s' "$lint_check" | grep -q 'PRETTIER_BIN' \
     && grep -q 'CONFIG_FILE: ${{ steps.baseconfig.outputs.config_file }}' "$LINT" \
     && grep -q 'PRETTIER_BIN: ${{ steps.ptool.outputs.prettier_bin }}' "$LINT"; then
  ok "the check step consumes the base config + isolated binary"
else
  bad "the check step must bind CONFIG_FILE (baseconfig) and PRETTIER_BIN (ptool)"
fi
# The CFG-construction block (--config the base file, else the defensive
# --no-config) must be byte-identical to the write lane's, so the two lanes
# pass the SAME config flag to prettier — the resolve-step drift check pins the
# inputs, this pins how they're consumed.
cfg_block() { awk '/if \[ -n "\$\{CONFIG_FILE/{g=1} g{print} g&&/^[[:space:]]*fi$/{exit}'; }
lc=$(printf '%s\n' "$lint_check" | cfg_block)
wc=$(printf '%s\n' "$(extract_run_block "prettier --write" "$AUTOFIX")" | cfg_block)
if [ -n "$lc" ] && [ "$lc" = "$wc" ]; then
  ok "the check step's --config/--no-config block matches the write lane's"
else
  bad "the check step's CFG block drifted from prettier-autofix.yml's write step:"
  diff <(printf '%s\n' "$lc") <(printf '%s\n' "$wc") | sed 's/^/      /' | head
fi

# ===========================================================================
# 2. Behavioral: `prettier --check` never executes a head prettier.config.cjs.
# ===========================================================================
echo "2. head prettier config is never executed by the check step"
PTOOL="$T/ptool"
if ! npm install --no-save --ignore-scripts --no-audit --no-fund \
       --prefix "$PTOOL" prettier@3 >/tmp/lint_ptool.log 2>&1; then
  echo "  – skipping behavioral checks (could not install prettier@3 locally):"
  sed 's/^/      /' /tmp/lint_ptool.log | tail -5
elif [ -z "$lint_check" ]; then
  bad "could not extract the 'prettier --check' step body"
else
  PRETTIER_BIN="$PTOOL/node_modules/.bin/prettier"

  # Sets LAST_RC / LAST_MARK. The check step exits 0 when the target is already
  # formatted under the active config, 1 when it would reformat — a clean
  # differential for proving which config is in force.
  LAST_RC=0; LAST_MARK=""
  run_check() { # $1 label $2 config_file [$3 editorconfig] [$4 target] [$5 mode]
    local label="$1" cfgfile="$2" ecbody="${3:-}" target="${4:-}" mode="${5:-files}"
    [ -n "$target" ] || target='{ "x": { "y": 1 } }'
    local ck="$T/ck"; rm -rf "$ck"; mkdir -p "$ck"
    local mark; mark=$(mktemp -d "$T/mark.XXXXXX")
    cat > "$ck/prettier.config.cjs" <<CANARY
require('fs').writeFileSync(process.env.CANARY_MARK + '/head-config-ran', 'x');
module.exports = { printWidth: 200 };
CANARY
    printf 'registry=http://127.0.0.1:1/\n' > "$ck/.npmrc"
    [ -n "$ecbody" ] && printf '%s' "$ecbody" > "$ck/.editorconfig"
    printf '%s\n' "$target" > "$ck/t.json"
    (
      cd "$ck" &&
        env CANARY_MARK="$mark" PRETTIER_BIN="$PRETTIER_BIN" \
          MODE="$mode" GLOB='**/*.{md,yml,yaml,json}' FILES=$'t.json\n' \
          CONFIG_FILE="$cfgfile" \
          bash -c "set -uo pipefail
$lint_check" >"$T/c.log" 2>&1
    )
    LAST_RC=$?
    LAST_MARK="$mark"
    if [ -e "$mark/head-config-ran" ]; then
      bad "$label: head prettier.config.cjs EXECUTED during the check step"
    else
      ok "$label: head prettier.config.cjs not executed"
    fi
  }

  empty_cfg="$T/empty.json"; printf '{}\n' > "$empty_cfg"

  # 2a. Empty config: a target already formatted under prettier defaults passes
  #     the check (rc 0), and the head canary stays dormant.
  run_check "empty config" "$empty_cfg"
  if [ "$LAST_RC" -eq 0 ]; then
    ok "check passes a prettier-formatted file under the empty config (rc 0)"
  else
    bad "expected rc 0 for an already-formatted file under the empty config (got $LAST_RC)"
    sed 's/^/      /' "$T/c.log"
  fi

  # 2b. Base config differential: the SAME file, under a base printWidth:1,
  #     is now "unformatted" (rc 1) — proving the BASE config, not the head's
  #     printWidth:200, is what applied.
  base_cfg="$T/base.json"; printf '{"printWidth": 1}\n' > "$base_cfg"
  run_check "base config (--config)" "$base_cfg"
  if [ "$LAST_RC" -eq 1 ]; then
    ok "base --config applied (printWidth:1 makes the one-line file unformatted, rc 1)"
  else
    bad "base --config was not applied — expected rc 1 under printWidth:1 (got $LAST_RC)"
    sed 's/^/      /' "$T/c.log"
  fi

  # 2c. Editorconfig parity: prep the target to the editorconfig-honored form
  #     (empty config honors .editorconfig), then the check under the empty
  #     config must PASS it (rc 0). Under `--no-config` editorconfig is ignored,
  #     prettier expects 2-space, and the tab file fails (rc 1) — so this bites
  #     a `--no-config` regression.
  ec=$'root = true\n[*.json]\nindent_style = tab\n'
  big='{"key1":"aaaaaaaaaaaaaaaaaaaa","key2":"bbbbbbbbbbbbbbbbbbbb","key3":"cccccccccccccccccccc"}'
  prep="$T/prep"; rm -rf "$prep"; mkdir -p "$prep"
  printf '%s' "$ec" > "$prep/.editorconfig"; printf '%s\n' "$big" > "$prep/t.json"
  ( cd "$prep" && "$PRETTIER_BIN" --config "$empty_cfg" --write t.json >/dev/null 2>&1 )
  honored=$(cat "$prep/t.json")
  run_check "editorconfig honored under empty config" "$empty_cfg" "$ec" "$honored"
  if [ "$LAST_RC" -eq 0 ]; then
    ok "empty config honors head .editorconfig on --check (rc 0) — parity with lint's write lane"
  else
    bad "empty config did not honor .editorconfig on --check (got rc $LAST_RC) — --no-config regression"
    sed 's/^/      /' "$T/c.log"
  fi

  # 2d. glob mode (the changed_only=false path) has the same guarantees: the
  #     head canary stays dormant and a formatted file passes.
  run_check "glob mode (changed_only=false)" "$empty_cfg" "" "" glob
  if [ "$LAST_RC" -eq 0 ]; then
    ok "glob mode passes a formatted file under the empty config (rc 0)"
  else
    bad "glob mode: expected rc 0 for a formatted file under the empty config (got $LAST_RC)"
    sed 's/^/      /' "$T/c.log"
  fi
fi

# ===========================================================================
# 3. Structural: the prettier JOB's checkout, isolated install, argv terminator.
# ===========================================================================
echo "3. structural: checkout credentials, isolated install, -- terminator"

# Slice the `prettier:` job, then its first checkout step (up to the next step
# marker), comment-stripped. Scoping to THIS job matters — the file has other
# checkouts (draft-gate, actionlint) whose credential posture is separate.
prettier_job=$(awk '
  /^  prettier:/ {inj=1}
  inj && /^  [a-z]/ && !/^  prettier:/ {exit}
  inj {print}
' "$LINT")
checkout_with=$(printf '%s\n' "$prettier_job" | awk '
  /^      - uses: actions\/checkout@v7/ {grab=1; next}
  grab && /^      - / {exit}
  grab {print}
' | grep -vE '^[[:space:]]*#')
if [ -z "$checkout_with" ]; then
  bad "could not locate the prettier job's checkout step"
else
  if printf '%s' "$checkout_with" | grep -q 'persist-credentials: false'; then
    ok "prettier job checkout sets persist-credentials: false"
  else
    bad "the prettier job's checkout must set persist-credentials: false"
  fi
  if printf '%s' "$checkout_with" | grep -qE '^[[:space:]]*token:'; then
    bad "the prettier job's checkout must not pass a token: (no persisted credential)"
  else
    ok "prettier job checkout passes no token: (negative control)"
  fi
fi

BODY=$(grep -vE '^[[:space:]]*#' "$LINT")
# Isolated prettier install off-checkout; no in-checkout npm ci.
if printf '%s' "$BODY" | grep -Eq 'RUNNER_TEMP' \
     && printf '%s' "$BODY" | grep -q -- '--registry' \
     && printf '%s' "$BODY" | grep -q -- '--ignore-scripts' \
     && printf '%s' "$BODY" | grep -q 'NPM_CONFIG_USERCONFIG'; then
  ok "prettier CLI installed off-checkout (registry, --ignore-scripts, neutralized user-config)"
else
  bad "the prettier install must be off-checkout with --registry, --ignore-scripts and NPM_CONFIG_USERCONFIG"
fi
if printf '%s' "$BODY" | grep -qF 'npm ci'; then
  bad "an npm ci runs in non-comment code — the old in-checkout install must be gone"
else
  ok "no npm ci in non-comment code (the in-checkout install is gone)"
fi
if printf '%s' "$BODY" | grep -Eq '\[ -x node_modules/\.bin/prettier|PRETTIER=\(node_modules/\.bin/prettier'; then
  bad "the head-controlled relative node_modules/.bin/prettier preference must be removed"
else
  ok "no relative node_modules/.bin/prettier preference (head cannot supply the binary)"
fi
# The check invocation terminates options with -- before the target list.
if printf '%s' "$lint_check" | grep -q -- '--check -- '; then
  ok "prettier --check terminates options with -- before the file/glob list"
else
  bad "the prettier --check invocation must place -- before the target list"
fi

echo
if [ "$failed" -eq 0 ]; then echo "ALL PASS"; else echo "FAILURES ABOVE"; fi
exit "$failed"
