#!/usr/bin/env bats

setup() {
  TMPD="$(mktemp -d)"
  PATTERNS="$TMPD/patterns"
  cat > "$PATTERNS" <<'EOF'
^(.*/)?(auth|login|session|oauth|sso)(/|$)
^(.*/)?secrets(/|$)
^\.github/workflows/.*
EOF
  SCRIPT="$BATS_TEST_DIRNAME/../verifier-classify-diff.sh"
}

teardown() { rm -rf "$TMPD"; }

@test "no matches → exit 1, no output" {
  PATHS="$TMPD/paths"
  printf 'src/Foo.tsx\nsrc/Bar.ts\nREADME.md\n' > "$PATHS"
  run "$SCRIPT" --patterns "$PATTERNS" --paths "$PATHS"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "single auth match → exit 0, prints path + pattern" {
  PATHS="$TMPD/paths"
  printf 'src/Foo.tsx\nsrc/auth/login.ts\nREADME.md\n' > "$PATHS"
  run "$SCRIPT" --patterns "$PATTERNS" --paths "$PATHS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"src/auth/login.ts"* ]]
}

@test "workflow file match → exit 0" {
  PATHS="$TMPD/paths"
  printf '.github/workflows/deploy.yml\n' > "$PATHS"
  run "$SCRIPT" --patterns "$PATTERNS" --paths "$PATHS"
  [ "$status" -eq 0 ]
  [[ "$output" == *".github/workflows/deploy.yml"* ]]
}

@test "missing --patterns flag → exit 2" {
  run "$SCRIPT" --paths /dev/null
  [ "$status" -eq 2 ]
}
