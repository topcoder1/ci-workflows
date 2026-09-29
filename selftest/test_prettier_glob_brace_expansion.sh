#!/usr/bin/env bash
# Brace expansion of markdown_glob in lint.yml / prettier-autofix.yml's
# "Resolve prettier targets" step.
#
# `compgen -G` does pathname expansion but no brace expansion, so the step
# splits `{a,b}` alternatives itself (expand_braces) before globbing. The
# old splitter handled exactly one brace group: a second group or a nested
# one was mangled (`{docs,.github}/**/*.{md,json}` became the bare directory
# names `docs` and `.github`), so the changed-files check matched nothing
# and passed having checked nothing. It also split its alternatives with an
# unquoted `for x in $middle` after `shopt -s globstar nullglob`, so an
# alternative such as `**/*.md` was pathname-expanded against the tree
# before it was ever used as a glob.
#
# Pins:
#   1. expand_braces is identical in both workflows (drift check).
#   2. For a corpus of globs it yields exactly what bash's own brace
#      expansion yields, in the same order: multiple groups, nesting, empty
#      alternatives, dropped empty results, and literal braces with no comma.
#      2b fuzzes the same comparison over 300 seeded random globs whose
#      braces all form comma groups, the domain the function claims to match
#      bash on. The oracle is bash itself, run with noglob so nothing is
#      pathname-expanded.
#   3. It never pathname-expands an alternative, even with globstar and
#      nullglob on, as they are in the step.
#   4. End to end: each workflow's real resolve script, with a stubbed gh,
#      targets the changed files that a two-group glob names.
#
# Blocks are EXTRACTED from the workflow YAML and executed, so this
# exercises the shipped bash. Sections 1-3 run on any bash (incl. macOS
# 3.2); section 4 needs bash >= 4 (mapfile, declare -A), as CI has.
#
# Run from the repo root:
#   bash selftest/test_prettier_glob_brace_expansion.sh
set -euo pipefail

failed=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

AUTOFIX=.github/workflows/prettier-autofix.yml
LINT=.github/workflows/lint.yml

extract_expand_braces() { # $1 = workflow → the function's source, de-indented
  awk '
    !grab && /^[[:space:]]*expand_braces\(\) \{[[:space:]]*$/ {
      grab = 1; match($0, /^[[:space:]]*/); ind = substr($0, 1, RLENGTH)
    }
    grab { print substr($0, length(ind) + 1) }
    grab && $0 == ind "}" { exit }
  ' "$1"
}

# ---------------------------------------------------------------------------
# 1. Drift check.
# ---------------------------------------------------------------------------
fa=$(extract_expand_braces "$AUTOFIX")
fl=$(extract_expand_braces "$LINT")
if [ -z "$fa" ] || [ -z "$fl" ]; then
  echo "✗ could not extract expand_braces from one of the workflows"
  exit 1
fi
if [ "$fa" = "$fl" ]; then
  echo "✓ expand_braces is identical in lint.yml and prettier-autofix.yml"
else
  echo "✗ expand_braces drifted between lint.yml and prettier-autofix.yml:"
  diff <(printf '%s\n' "$fl") <(printf '%s\n' "$fa") | sed 's/^/    /' || true
  failed=1
fi

printf '%s\n' "$fa" > "$T/expand_braces.sh"
# shellcheck source=/dev/null
. "$T/expand_braces.sh"

# ---------------------------------------------------------------------------
# 2. Same output as bash's own brace expansion, in the same order.
# ---------------------------------------------------------------------------
oracle() { # $1 = glob → bash's brace expansion of it, one word per line
  (
    set -f
    eval "printf '%s\n' $1"
  )
}

for p in \
  '**/*.md' \
  '**/*.{md,yml,yaml,json}' \
  '{**/*.md,.github/**/*.md}' \
  '{docs,.github}/**/*.{md,json}' \
  '{**/*.{md,json},.github/**/*.md}' \
  'a{b,c{d,e}f}g' \
  '{a,b}{c,d}{e,f}' \
  'x{,a}y' \
  'x{,}y' \
  '{,a}' \
  '{foo}' \
  '{a{b,c}}' \
  'a{b' \
  'a}b{c,d}'; do
  want=$(oracle "$p")
  got=$(expand_braces "$p")
  if [ "$got" = "$want" ]; then
    echo "✓ expand_braces '$p' matches bash ($(printf '%s' "$want" | tr '\n' ' '))"
  else
    echo "✗ expand_braces '$p':"
    echo "    want: $(printf '%s' "$want" | tr '\n' ' ')"
    echo "    got:  $(printf '%s' "$got" | tr '\n' ' ')"
    failed=1
  fi
done

# 2b. Differential fuzz over the supported domain: random globs whose braces
#     all form comma groups (nested, with empty alternatives), compared with
#     bash's own expansion. Seeded, so a failure reproduces on the same bash.
LIT=(a b / '*' . -)
G=""
gen() { # $1 = nesting budget; appends a random well-formed glob to $G
  local d=$1 n=$((RANDOM % 3)) k=0 m=0 a=0
  while [ "$k" -le "$n" ]; do
    if [ "$d" -gt 0 ] && [ $((RANDOM % 3)) -eq 0 ]; then
      m=$(( (RANDOM % 3) + 2 )); a=0; G="$G{"
      while [ "$a" -lt "$m" ]; do
        if [ "$a" -gt 0 ]; then G="$G,"; fi
        if [ $((RANDOM % 4)) -ne 0 ]; then gen $((d - 1)); fi
        a=$((a + 1))
      done
      G="$G}"
    else
      G="$G${LIT[$((RANDOM % ${#LIT[@]}))]}"
    fi
    k=$((k + 1))
  done
}
RANDOM=4242
fuzz_n=300; fuzz_bad=0; fuzz_i=0
while [ "$fuzz_i" -lt "$fuzz_n" ]; do
  G=""; gen 2
  want=$(oracle "$G")
  got=$(expand_braces "$G")
  if [ "$got" != "$want" ]; then
    fuzz_bad=$((fuzz_bad + 1))
    if [ "$fuzz_bad" -le 3 ]; then
      echo "✗ fuzz: expand_braces '$G'"
      echo "    want: $(printf '%s' "$want" | tr '\n' ' ')"
      echo "    got:  $(printf '%s' "$got" | tr '\n' ' ')"
    fi
  fi
  fuzz_i=$((fuzz_i + 1))
done
if [ "$fuzz_bad" -eq 0 ]; then
  echo "✓ fuzz: $fuzz_n random well-formed globs expand exactly as bash expands them"
else
  echo "✗ fuzz: $fuzz_bad of $fuzz_n random well-formed globs differ from bash"
  failed=1
fi

# ---------------------------------------------------------------------------
# 3. No pathname expansion of alternatives (globstar and nullglob on, as in
#    the step, in a tree where `**/*.md` matches files).
# ---------------------------------------------------------------------------
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "– skipping the globstar check (bash ${BASH_VERSION%%(*} has no globstar; CI enforces it)"
else
  mkdir -p "$T/g/docs"
  : > "$T/g/a.md"
  : > "$T/g/docs/b.md"
  got=$(cd "$T/g" && shopt -s globstar nullglob && expand_braces '{**/*.md,x}')
  want=$(printf '%s\n' '**/*.md' 'x')
  if [ "$got" = "$want" ]; then
    echo "✓ alternatives stay patterns (not pathname-expanded) under globstar+nullglob"
  else
    echo "✗ expand_braces pathname-expanded an alternative:"
    echo "    want: $(printf '%s' "$want" | tr '\n' ' ')"
    echo "    got:  $(printf '%s' "$got" | tr '\n' ' ')"
    failed=1
  fi
fi

# ---------------------------------------------------------------------------
# 4. End to end through each workflow's real resolve script.
# ---------------------------------------------------------------------------
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "– skipping end-to-end scenarios (bash ${BASH_VERSION%%(*} lacks mapfile; CI enforces them)"
else
  extract_resolve_script() { # $1 = workflow
    awk '
      /- name: Resolve prettier targets/ {in_step=1}
      in_step && /^        run: \|/ {in_run=1; next}
      in_run {
        if ($0 ~ /^          /) { print substr($0, 11); next }
        if ($0 ~ /^[[:space:]]*$/) { print ""; next }
        exit
      }
    ' "$1"
  }

  stub="$T/stub"; mkdir -p "$stub"
  tree="$T/tree"; mkdir -p "$tree/docs" "$tree/.github" "$tree/other"
  for f in docs/guide.md docs/data.json .github/notes.md .github/cfg.json other/skip.md; do
    printf 'x\n' > "$tree/$f"
  done
  # The PR changed four files; the glob names three of them.
  printf '#!/usr/bin/env bash\nprintf "docs/guide.md\\ndocs/data.json\\n.github/notes.md\\nother/skip.md\\n"\n' > "$stub/gh"
  chmod +x "$stub/gh"
  want=$(printf '%s\n' .github/notes.md docs/data.json docs/guide.md)

  for wf in "$LINT" "$AUTOFIX"; do
    script=$(extract_resolve_script "$wf")
    if [ -z "$script" ]; then
      echo "✗ could not extract the resolve-targets script from $wf"
      failed=1
      continue
    fi
    out="$T/out.$(basename "$wf")"
    : > "$out"
    (
      cd "$tree" &&
        env PATH="$stub:$PATH" \
          GITHUB_OUTPUT="$out" GITHUB_REPOSITORY="o/r" \
          GH_TOKEN=x PR_NUMBER=27 EVENT_NAME=pull_request CHANGED_ONLY=true \
          GLOB='{docs,.github}/**/*.{md,json}' \
          bash -c "$script" > "$out.log" 2>&1
    ) || true
    got=$(awk '/^files<</{f=1; next} /^__EOF__$/{f=0} f' "$out" | sort)
    if grep -q '^mode=files$' "$out" && [ "$got" = "$want" ]; then
      echo "✓ $(basename "$wf"): two-group glob targets exactly the changed files it names"
    else
      echo "✗ $(basename "$wf"): expected mode=files with $(printf '%s' "$want" | tr '\n' ' '); GITHUB_OUTPUT was:"
      sed 's/^/    /' "$out"
      sed 's/^/    log: /' "$out.log"
      failed=1
    fi
  done
fi

exit "$failed"
