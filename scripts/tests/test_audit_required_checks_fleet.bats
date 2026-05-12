#!/usr/bin/env bats

setup() {
  STUB_DIR="$(mktemp -d)"
  PATH="$STUB_DIR:$PATH"
  # Stub validate-required-checks.sh so we don't hit GH API in tests.
  # Behavior: clean exit for repos starting with "ok-", warn for "warn-", error for "err-".
  cat > "$STUB_DIR/validate-required-checks.sh" <<'STUB'
#!/usr/bin/env bash
# Strip owner/ prefix so case patterns can match the repo name.
repo="${1#*/}"
case "$repo" in
  ok-*)  exit 0 ;;
  warn-*) echo "WARN: $1: phantom check 'foo / bar'"; exit 0 ;;
  err-*) echo "ERROR: $1: ruleset not found" >&2; exit 1 ;;
  *) echo "UNKNOWN STUB BEHAVIOR FOR $1"; exit 2 ;;
esac
STUB
  chmod +x "$STUB_DIR/validate-required-checks.sh"
  SCRIPT="$BATS_TEST_DIRNAME/../audit-required-checks-fleet.sh"
}

teardown() {
  rm -rf "$STUB_DIR"
}

@test "all-clean fleet exits 0 with empty digest body" {
  run "$SCRIPT" --repos "topcoder1/ok-a topcoder1/ok-b topcoder1/ok-c"
  [ "$status" -eq 0 ]
  [[ "$output" == *"All 3 repos clean"* ]]
}

@test "warn fleet exits 0 with non-empty digest body" {
  run "$SCRIPT" --repos "topcoder1/ok-a topcoder1/warn-b topcoder1/ok-c"
  [ "$status" -eq 0 ]
  [[ "$output" == *"warn-b"* ]]
  [[ "$output" == *"phantom check"* ]]
}

@test "err fleet exits non-zero (script error, not policy violation)" {
  # bats' `run` merges stdout+stderr into $output (no $stderr var).
  run "$SCRIPT" --repos "topcoder1/ok-a topcoder1/err-b"
  [ "$status" -ne 0 ]
  [[ "$output" == *"err-b"* ]]
}

@test "missing --repos flag prints usage" {
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "--out writes digest to file (not stdout)" {
  out_file="$BATS_TEST_TMPDIR/digest.md"
  run "$SCRIPT" --repos "topcoder1/ok-a topcoder1/warn-b" --out "$out_file"
  [ "$status" -eq 0 ]
  [ -f "$out_file" ]
  grep -q "warn-b" "$out_file"
  grep -q "phantom check" "$out_file"
}

@test "--out writes 'all clean' digest to file when nothing flagged" {
  out_file="$BATS_TEST_TMPDIR/digest.md"
  run "$SCRIPT" --repos "topcoder1/ok-a topcoder1/ok-b" --out "$out_file"
  [ "$status" -eq 0 ]
  [ -f "$out_file" ]
  grep -q "All 2 repos clean" "$out_file"
}
