#!/usr/bin/env bash
# Defense-in-depth: prettier-autofix.yml must never execute code that the
# PR head can influence.
#
# THREAT (topcoder1/ci-workflows, 2026-09): the reusable checks out the PR
# HEAD with automerge_pat readable from .git/config, then runs prettier over
# the head's files. Prettier's default behavior searches upward from each
# target and LOADS config as code — prettier.config.js / .prettierrc.cjs, a
# package.json "prettier" module ref, and any plugin those name. A PR head
# (model- or attacker-written) can therefore run arbitrary Node on the runner
# with the PAT in scope, the moment the PR opens (draft does not stop it).
# The same head `.npmrc` can redirect the registry that a bare
# `npx --yes prettier@3` resolves the prettier package itself from.
#
# The hardening keeps prettier's behavior for normal PRs (whose config, if
# any, lives on the protected base branch) while refusing to run head-reachable
# code:
#   - Config comes from the BASE branch only: `--no-config` when the base
#     declares none (the fleet's universal case), else `--config` materialized
#     from `git show <base>:<config>`. Either flag suppresses the head search.
#     A base config that is itself JS/TS, or that names plugins, degrades to
#     `--no-config` + a ::warning:: — autofix never loads plugin or config JS,
#     from head OR base.
#   - The prettier CLI is installed OUTSIDE the checkout ($RUNNER_TEMP), with a
#     pinned --registry, --ignore-scripts, and a neutralized npm user-config,
#     so the head's package.json and .npmrc are never read. (Mirrors lint.yml's
#     "run the install from $RUNNER_TEMP, not the checkout" idiom.)
#   - Checkout uses `persist-credentials: false`; the PAT is supplied only to
#     the push step via an inline http.extraheader, never persisted to
#     .git/config where head-reachable code could read it.
#   - The changed-file list is passed after `--`, so a head file literally
#     named `--plugin=x` cannot be reparsed as a flag.
#
# Blocks are EXTRACTED from the shipped YAML and executed, so this exercises
# the real bash, not a mirror. Behavioral checks use a canary config that
# writes a marker IFF prettier loads it — the marker's ABSENCE is the proof
# that head config never ran.
#
# Run from the repo root:
#   bash selftest/test_prettier_untrusted_head_config.sh
set -uo pipefail

AUTOFIX=.github/workflows/prettier-autofix.yml
failed=0
ok()  { printf '  ok   — %s\n' "$1"; }
bad() { printf '  FAIL — %s\n' "$1"; failed=1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# ---------------------------------------------------------------------------
# Extractors (keyed on step name, mirroring test_prettier_scope_failsafe.sh).
# ---------------------------------------------------------------------------
extract_run_block() { # $1 = step-name substring, $2 = workflow
  awk -v want="$1" '
    $0 ~ ("- name: " want) {in_step=1}
    in_step && /^        run: \|/ {in_run=1; next}
    in_run {
      if ($0 ~ /^          /) { print substr($0, 11); next }
      if ($0 ~ /^[[:space:]]*$/) { print ""; next }
      exit
    }
  ' "$2"
}

# ===========================================================================
# 1. Behavioral: the "prettier --write" step must not load a head config.
# ===========================================================================
echo "1. head prettier config is never executed by the write step"

# A local prettier CLI, installed off to the side so the fixture checkout's own
# package.json/.npmrc never enter the picture for this behavioral probe.
PTOOL="$T/ptool"
if ! npm install --no-save --ignore-scripts --no-audit --no-fund \
       --prefix "$PTOOL" prettier@3 >/tmp/ptool_install.log 2>&1; then
  echo "  – skipping behavioral checks (could not install prettier@3 locally):"
  sed 's/^/      /' /tmp/ptool_install.log | tail -5
else
  PRETTIER_BIN="$PTOOL/node_modules/.bin/prettier"

  # A stub `npx` in case the step still reaches for it: it execs the local
  # prettier, dropping a leading `--yes` and any `prettier@*` token. If the
  # hardened step used PRETTIER_BIN it never calls this; if the OLD step is
  # under test, this is how its `npx --yes prettier@3` runs — and then the
  # head config load is exactly what we catch.
  stub="$T/stub"; mkdir -p "$stub"
  cat > "$stub/npx" <<STUB
#!/usr/bin/env bash
args=()
for a in "\$@"; do
  case "\$a" in --yes|prettier|prettier@*) continue;; esac
  args+=("\$a")
done
exec "$PRETTIER_BIN" "\${args[@]}"
STUB
  chmod +x "$stub/npx"

  write_block=$(extract_run_block "prettier --write" "$AUTOFIX")
  if [ -z "$write_block" ]; then
    bad "could not extract the 'prettier --write' step body"
  else
    # Sets LAST_CK to the fixture checkout dir; logs its own ok/bad to stdout.
    # The resolve step ALWAYS emits a config file (a base config, or an empty
    # {}), so the write step is always driven with a CONFIG_FILE.
    LAST_CK=""
    run_write() { # $1=label $2=config_file [$3=editorconfig body] [$4=target json]
      local label="$1" cfgfile="$2" ecbody="${3:-}" target="${4:-}"
      [ -n "$target" ] || target='{"x":{"y":1}}'
      local ck="$T/ck"; rm -rf "$ck"; mkdir -p "$ck"
      local mark; mark=$(mktemp -d "$T/mark.XXXXXX")
      # Canary config: if prettier ever loads head config, this Node runs.
      cat > "$ck/prettier.config.cjs" <<CANARY
require('fs').writeFileSync(process.env.CANARY_MARK + '/head-config-ran', 'x');
module.exports = { printWidth: 200 };
CANARY
      # A head .npmrc pointing the registry at an unroutable address: if the
      # write step shelled out to npm/npx in-checkout it would try this.
      printf 'registry=http://127.0.0.1:1/\n' > "$ck/.npmrc"
      [ -n "$ecbody" ] && printf '%s' "$ecbody" > "$ck/.editorconfig"
      printf '%s\n' "$target" > "$ck/t.json"
      (
        cd "$ck" &&
          env PATH="$stub:$PATH" \
            CANARY_MARK="$mark" \
            PRETTIER_BIN="$PRETTIER_BIN" \
            MODE=files \
            GLOB='**/*.{md,yml,yaml,json}' \
            FILES=$'t.json\n' \
            CONFIG_FILE="$cfgfile" \
            PRETTIER_SPEC=3 \
            bash -c "set -uo pipefail
$write_block" >"$T/w.log" 2>&1
      )
      if [ -e "$mark/head-config-ran" ]; then
        bad "$label: head prettier.config.cjs EXECUTED during the write step"
      else
        ok "$label: head prettier.config.cjs not executed"
      fi
      LAST_CK="$ck"
    }

    empty_cfg="$T/empty.json"; printf '{}\n' > "$empty_cfg"

    run_write "empty config (no base config)" "$empty_cfg"
    # Positive control: prettier still formatted the file.
    if grep -q '{ "x": { "y": 1 } }' "$LAST_CK/t.json" 2>/dev/null; then
      ok "write step still formats the target under the empty config"
    else
      bad "write step did not format the target (expected prettier default output)"
      sed 's/^/      /' "$LAST_CK/t.json" 2>/dev/null
    fi

    # A BASE data config (materialized on disk) must apply, while the head
    # canary still stays dormant.
    base_cfg="$T/base.prettierrc.json"
    printf '{"printWidth": 1}\n' > "$base_cfg"
    run_write "base config (--config)" "$base_cfg"
    if grep -q '"y": 1' "$LAST_CK/t.json" && [ "$(wc -l < "$LAST_CK/t.json")" -gt 1 ]; then
      ok "base --config applied (printWidth:1 forced a wrap)"
    else
      bad "base --config was not applied — expected the base printWidth to wrap the JSON"
      sed 's/^/      /' "$LAST_CK/t.json" 2>/dev/null
    fi

    # Editorconfig parity: the empty-{} default (unlike --no-config) must still
    # honor a repo .editorconfig, so autofix output matches lint.yml's
    # `prettier --check` and prettier's pre-hardening default. Uses a wrapping
    # JSON so the indent style is visible. Would FAIL under `--no-config`.
    big='{"key1":"aaaaaaaaaaaaaaaaaaaa","key2":"bbbbbbbbbbbbbbbbbbbb","key3":"cccccccccccccccccccc"}'
    run_write "editorconfig honored under empty config" "$empty_cfg" \
      "$(printf 'root = true\n[*.json]\nindent_style = tab\n')" "$big"
    if sed -n '2p' "$LAST_CK/t.json" | grep -q "$(printf '\t')"; then
      ok "empty config still honors head .editorconfig (tab indent) — parity with lint.yml"
    else
      bad "empty config did not honor .editorconfig — output diverges from lint.yml (--no-config regression)"
      sed 's/^/      /' "$LAST_CK/t.json" 2>/dev/null
    fi
  fi
fi

# ===========================================================================
# 2. Behavioral: base-config resolution reads BASE, never HEAD.
# ===========================================================================
echo "2. base prettier config is resolved from the base ref, not the head"

resolve_block=$(extract_run_block "Resolve base prettier config" "$AUTOFIX")
if [ -z "$resolve_block" ]; then
  bad "no 'Resolve base prettier config' step in prettier-autofix.yml"
else
  run_resolve() { # sets $out to the GITHUB_OUTPUT path; fixture prepared by caller in $T/repo
    local out="$T/out.$RANDOM"; : > "$out"
    local rt; rt=$(mktemp -d "$T/rt.XXXXXX")
    (
      cd "$T/repo" &&
        env GITHUB_OUTPUT="$out" BASE_SHA="$1" RUNNER_TEMP="$rt" \
          bash -c "set -uo pipefail
$resolve_block" >"$T/r.log" 2>&1
    ) || true
    printf '%s' "$out"
  }
  setup_repo() { rm -rf "$T/repo"; mkdir -p "$T/repo"; ( cd "$T/repo" && git init -q .
    git config user.email t@e.invalid && git config user.name t ); }

  # 2a. Base has a data config; head overwrites it and adds a canary. The
  #     resolver must select the BASE bytes.
  setup_repo
  ( cd "$T/repo"
    printf '{"printWidth": 1}\n' > .prettierrc.json
    git add -A && git commit -qm base
    BASE=$(git rev-parse HEAD)
    printf '{"printWidth": 999}\n' > .prettierrc.json          # head tampering
    printf "require('fs').writeFileSync('x'); module.exports={};\n" > prettier.config.cjs
    echo "$BASE" > "$T/base_sha" )
  out=$(run_resolve "$(cat "$T/base_sha")")
  mode=$(sed -n 's/^config_mode=//p' "$out")
  cfile=$(sed -n 's/^config_file=//p' "$out")
  # config_file is an absolute path under RUNNER_TEMP (outside the checkout, so
  # it can never be committed and its relative overrides do not resolve into
  # the head tree).
  if [ "$mode" = "base" ] && [ -n "$cfile" ] && grep -q '"printWidth": 1' "$cfile" 2>/dev/null \
       && ! grep -q '999' "$cfile" 2>/dev/null; then
    ok "base data config selected (config_mode=base, base bytes, not head's)"
  else
    bad "resolver did not materialize the BASE config; mode='$mode' file='$cfile'"
    sed 's/^/      out: /' "$out"; sed 's/^/      log: /' "$T/r.log"
  fi
  # And it must live outside the checkout (never committable).
  case "$cfile" in
    "$T/repo"/*) bad "materialized base config sits INSIDE the checkout ($cfile) — it could be committed" ;;
    *) [ "$mode" = "base" ] && ok "materialized base config is outside the checkout" ;;
  esac

  # A helper for the degrade-to-empty cases: config_mode=empty and config_file
  # must point at an existing empty {} outside the checkout (the write step
  # ALWAYS --configs a file; "empty" is the no-base default that still honors
  # editorconfig). Optionally require a warning substring in the log.
  assert_empty() { # $1=label $2=out $3=cfile [$4=warn-grep]
    local mode; mode=$(sed -n 's/^config_mode=//p' "$2")
    local cfile; cfile=$(sed -n 's/^config_file=//p' "$2")
    local warn_ok=1
    [ -n "${4:-}" ] && { grep -qi "$4" "$T/r.log" || warn_ok=0; }
    if [ "$mode" = "empty" ] && [ -n "$cfile" ] && [ "$(cat "$cfile" 2>/dev/null)" = "{}" ] \
         && [ "$warn_ok" -eq 1 ]; then
      case "$cfile" in "$T/repo"/*) bad "$1: empty config is inside the checkout";; *) ok "$1";; esac
    else
      bad "$1 (mode='$mode' file='$cfile' warn_ok=$warn_ok)"
      sed 's/^/      out: /' "$2"; sed 's/^/      log: /' "$T/r.log"
    fi
  }

  # 2b. Base has NO prettier config → empty {} (config_mode=empty), editorconfig
  #     still honored downstream.
  setup_repo
  ( cd "$T/repo"; printf '# r\n' > README.md; git add -A && git commit -qm base
    git rev-parse HEAD > "$T/base_sha" )
  out=$(run_resolve "$(cat "$T/base_sha")")
  assert_empty "no base config → config_mode=empty with an empty {} file" "$out"

  # 2c. Base config is JS → refuse to honor it, degrade to empty + warning.
  setup_repo
  ( cd "$T/repo"
    printf 'module.exports = { printWidth: 1 };\n' > prettier.config.cjs
    git add -A && git commit -qm base; git rev-parse HEAD > "$T/base_sha" )
  out=$(run_resolve "$(cat "$T/base_sha")")
  assert_empty "base JS config not honored → empty {} + warning" "$out" "warning"

  # 2d. Base config that names plugins → also degrade (no plugin code ever).
  setup_repo
  ( cd "$T/repo"
    printf '{"plugins": ["prettier-plugin-anything"]}\n' > .prettierrc.json
    git add -A && git commit -qm base; git rev-parse HEAD > "$T/base_sha" )
  out=$(run_resolve "$(cat "$T/base_sha")")
  assert_empty "base config naming plugins → empty {} (no plugin load)" "$out" "plugin"

  # 2e. Base config lives in package.json's "prettier" OBJECT key → honored
  #     (materialized from base). This path parses JSON via node.
  setup_repo
  ( cd "$T/repo"
    printf '{"name":"h","prettier":{"printWidth":1,"tabWidth":3}}\n' > package.json
    git add -A && git commit -qm base; git rev-parse HEAD > "$T/base_sha" )
  out=$(run_resolve "$(cat "$T/base_sha")")
  mode=$(sed -n 's/^config_mode=//p' "$out"); cfile=$(sed -n 's/^config_file=//p' "$out")
  if [ "$mode" = "base" ] && grep -q '"printWidth":1' "$cfile" 2>/dev/null; then
    ok "base package.json \"prettier\" object → materialized config (--config)"
  else
    bad "a base package.json prettier OBJECT must be honored; mode='$mode' file='$cfile'"
    sed 's/^/      out: /' "$out"; sed 's/^/      log: /' "$T/r.log"
  fi

  # 2f. package.json "prettier" as a STRING is a module ref (executable) → none.
  setup_repo
  ( cd "$T/repo"
    printf '{"name":"h","prettier":"some-shared-config"}\n' > package.json
    git add -A && git commit -qm base; git rev-parse HEAD > "$T/base_sha" )
  out=$(run_resolve "$(cat "$T/base_sha")")
  assert_empty "base package.json \"prettier\" string (module ref) → empty {}" "$out" "module"
fi

# ===========================================================================
# 3. Structural invariants (things the behavioral probes cannot see).
# ===========================================================================
echo "3. structural: credentials, isolated install, argv terminator"
code_only() { grep -vE '^[[:space:]]*#' "$AUTOFIX" || true; }
BODY=$(code_only)

# Extract one step's YAML block, from its `- name:`/`- uses:` line to the next
# step marker (6-space `      - `).
extract_step_block() { # $1=step name substring, $2=file
  awk -v want="$1" '
    $0 ~ ("- name: " want) {grab=1; print; next}
    grab && /^      - / {exit}
    grab {print}
  ' "$2"
}

# 3a. Checkout does not persist credentials into .git/config.
#
# MUST bite the surgical mutation: `persist-credentials: false` also appears in
# three COMMENT lines of this workflow, so a raw-file grep would pass even if
# the real setting were flipped to true or deleted (the "coverage test derived
# from the artifact" anti-pattern). So assert on the comment-stripped CHECKOUT
# step, and add a negative control — the step must NOT pass a `token:` (the old
# `token: ${{ secrets.automerge_pat }}` form persisted the PAT into .git/config,
# which is the whole vulnerability). A revert to that form fails both arms.
checkout_body=$(extract_step_block "Checkout PR head" "$AUTOFIX" | grep -vE '^[[:space:]]*#' || true)
if [ -z "$checkout_body" ]; then
  bad "could not locate the 'Checkout PR head' step (renamed?) — 3a cannot verify credential persistence"
else
  if printf '%s' "$checkout_body" | grep -q 'persist-credentials: false'; then
    ok "checkout step sets persist-credentials: false (comment-stripped — bites a flip to true)"
  else
    bad "the checkout step must set persist-credentials: false — the PAT/GITHUB_TOKEN must not sit in .git/config while head-reachable code runs"
  fi
  if printf '%s' "$checkout_body" | grep -qE '^[[:space:]]*token:'; then
    bad "the checkout step must not pass a token: — a persisted PAT in .git/config is the vulnerability; auth belongs only on the push extraheader"
  else
    ok "checkout step passes no token: (no persisted PAT — negative control)"
  fi
fi

# 3b. The push supplies the PAT itself via an inline extraheader (not persisted).
if printf '%s' "$BODY" | grep -q 'http.extraheader'; then
  ok "push supplies auth via http.extraheader (scoped to the push)"
else
  bad "the push step must supply the PAT via an inline http.extraheader, since checkout no longer persists it"
fi

# 3c. The prettier CLI install must run OUTSIDE the checkout, with a pinned
#     registry and neutralized npm user-config, so head package.json/.npmrc
#     are never consulted. And the head-controlled node_modules/.bin/prettier
#     preference must be gone.
if printf '%s' "$BODY" | grep -Eq 'RUNNER_TEMP' \
     && printf '%s' "$BODY" | grep -q -- '--registry' \
     && printf '%s' "$BODY" | grep -q -- '--ignore-scripts' \
     && printf '%s' "$BODY" | grep -q 'NPM_CONFIG_USERCONFIG'; then
  ok "prettier CLI installed off-checkout with pinned registry, --ignore-scripts, neutralized npm user-config"
else
  bad "the prettier install must run from \$RUNNER_TEMP with an explicit --registry, --ignore-scripts and NPM_CONFIG_USERCONFIG, so the head .npmrc/package.json are never read and no lifecycle scripts run"
fi
# The old in-checkout binary preference (`[ -x node_modules/.bin/prettier ]`,
# `PRETTIER=(node_modules/.bin/prettier)`) let a head postinstall plant the
# binary. The isolated `$DIR/node_modules/.bin/prettier` (absolute, under
# $RUNNER_TEMP) is fine — only the RELATIVE in-checkout form is the vector.
if printf '%s' "$BODY" | grep -Eq '\[ -x node_modules/\.bin/prettier|PRETTIER=\(node_modules/\.bin/prettier'; then
  bad "the head-controlled relative node_modules/.bin/prettier preference must be removed"
elif printf '%s' "$BODY" | grep -q 'PRETTIER_BIN'; then
  ok "prettier binary comes from PRETTIER_BIN (isolated install), not a head node_modules"
else
  bad "the write step must resolve the prettier binary from the isolated PRETTIER_BIN"
fi
# No `npm ci` at all (that was the in-checkout install), and every `npm install`
# must be the isolated one (`--prefix "$DIR"`, where $DIR is under RUNNER_TEMP).
if printf '%s' "$BODY" | grep -qF 'npm ci'; then
  bad "an npm ci runs somewhere in non-comment code — the old in-checkout install must be gone"
else
  ok "no npm ci in non-comment code (the in-checkout install is gone)"
fi
npm_lines=$(printf '%s\n' "$BODY" | grep -F 'npm install' || true)
if [ -z "$npm_lines" ]; then
  bad "no npm install found at all — expected exactly the isolated off-checkout install"
else
  npm_bad=0
  while IFS= read -r line; do
    case "$line" in *'--prefix "$DIR"'*) ;; *) npm_bad=1;; esac
  done <<EOF
$npm_lines
EOF
  if [ "$npm_bad" -eq 0 ]; then
    ok "every npm install is the isolated --prefix \"\$DIR\" form (off-checkout)"
  else
    bad "an npm install runs without the isolated --prefix \"\$DIR\" (may read head package.json/.npmrc)"
  fi
fi

# 3d. The changed-file list is passed after `--`.
if printf '%s' "$BODY" | grep -q -- '--write -- ' || printf '%s' "$BODY" | grep -Eq -- '--write[[:space:]].*[[:space:]]--[[:space:]]'; then
  ok "prettier invocation terminates options with -- before the file/glob list"
else
  bad "the prettier invocation must place '--' before the target list (a head file named --plugin=x must not reparse as a flag)"
fi

echo
if [ "$failed" -eq 0 ]; then echo "ALL PASS"; else echo "FAILURES ABOVE"; fi
exit "$failed"
