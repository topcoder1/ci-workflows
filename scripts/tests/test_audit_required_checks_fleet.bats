#!/usr/bin/env bats

setup() {
  STUB_DIR="$(mktemp -d)"
  PATH="$STUB_DIR:$PATH"
  # Stub validate-required-checks.sh so we don't hit GH API in tests. Exit
  # codes follow the real validator's header: 0 clean (it always prints a
  # header), 1 finding, 3 GitHub API error.
  cat > "$STUB_DIR/validate-required-checks.sh" <<'STUB'
#!/usr/bin/env bash
# Strip owner/ prefix so case patterns can match the repo name.
repo="${1#*/}"
case "$repo" in
  ok-*)  echo "==> Validating required status checks for $1 (branch: main)"; exit 0 ;;
  warn-*) echo "    ⚠  codeql (looks external)"; exit 0 ;;
  find-*) echo "    ✗  foo / bar"; echo "==> FAIL: one or more required contexts will never report on PRs."; exit 1 ;;
  err-*) echo "  API error: GET /repos/$1/rules/branches/main failed (HTTP 401)" >&2; exit 3 ;;
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

@test "exit-0 output (header, warnings) still counts as clean" {
  run "$SCRIPT" --repos "topcoder1/ok-a topcoder1/warn-b topcoder1/ok-c"
  [ "$status" -eq 0 ]
  [[ "$output" == *"All 3 repos clean"* ]]
  [[ "$output" != *"warn-b"* ]]
}

@test "a finding exits 1 and is worded as a finding" {
  # bats' `run` merges stdout+stderr into $output (no $stderr var).
  run "$SCRIPT" --repos "topcoder1/ok-a topcoder1/find-b"
  [ "$status" -eq 1 ]
  [[ "$output" == *"### topcoder1/find-b — FINDING"* ]]
  [[ "$output" != *"ERROR"* ]]
}

@test "an error exits 3 and is worded as an error" {
  run "$SCRIPT" --repos "topcoder1/find-a topcoder1/err-b"
  [ "$status" -eq 3 ]
  [[ "$output" == *"### topcoder1/err-b — ERROR: not audited (exit 3: GitHub API error)"* ]]
  [[ "$output" == *"### topcoder1/find-a — FINDING"* ]]
}

@test "missing --repos flag prints usage" {
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "--out writes digest to file (not stdout)" {
  out_file="$BATS_TEST_TMPDIR/digest.md"
  run "$SCRIPT" --repos "topcoder1/ok-a topcoder1/find-b" --out "$out_file"
  [ "$status" -eq 1 ]
  [ -f "$out_file" ]
  grep -q "find-b" "$out_file"
  grep -q "foo / bar" "$out_file"
}

@test "--out writes 'all clean' digest to file when nothing flagged" {
  out_file="$BATS_TEST_TMPDIR/digest.md"
  run "$SCRIPT" --repos "topcoder1/ok-a topcoder1/ok-b" --out "$out_file"
  [ "$status" -eq 0 ]
  [ -f "$out_file" ]
  grep -q "All 2 repos clean" "$out_file"
}
