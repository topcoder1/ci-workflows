#!/usr/bin/env bash
# Behavioral test for safe-paths-automerge.yml's built-in unsafe-override
# list — the paths that sit inside an otherwise-safe tree but must never be
# auto-merged on diff content alone.
#
# Incident (whois-api-llc/wxa_vpn#1268, 2026-07-25): a change to
# docs/legal/acceptable-use-policy.md — customer-facing legal wording that
# asserted all bulk deliveries are watermarked — matched the built-in
# `^docs/.*` safe glob and auto-merged in seconds with no human review. The
# assertion was false for two formats (.mmdb, .parquet). The `^docs/.*`
# safety argument is "zero runtime impact, can never break code paths",
# which is true of a runbook and false of a contractual commitment.
#
# Note this workflow NEVER consults the risk classifier — it decides on diff
# content alone — so listing docs/legal/** as `sensitive:` in a caller's
# .github/risk-paths.yml does NOT close this hole. The override list here is
# the only gate on this path.
#
# Pins:
#   1. A docs/legal/** file is NOT safe (all_safe=0, reason=unsafe-override).
#   2. The override wins even when mixed with genuinely-safe files.
#   3. Ordinary docs/** are STILL safe — the fix must not over-block and
#      regress the carve-out this workflow exists to provide.
#   4. tests/** remain safe.
#
# The classify block is EXTRACTED from the workflow YAML and executed, so
# this exercises the shipped bash rather than a mirrored copy that can drift.
#
# Run from the repo root:
#   bash selftest/test_safe_paths_unsafe_overrides.sh
set -euo pipefail

failed=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

WF=.github/workflows/safe-paths-automerge.yml

# Extract the `run: |` body of the step with `id: classify`, then strip the
# block's 10-space YAML indent so it runs as a standalone script.
awk '
  /^[[:space:]]*id: classify[[:space:]]*$/ { in_step = 1 }
  in_step && /^[[:space:]]*run: \|[[:space:]]*$/ { grab = 1; next }
  grab && /^      - name:/ { exit }
  grab { print }
' "$WF" | sed -e 's/^          //' > "$T/classify.sh"

if ! grep -q 'unsafe_overrides=' "$T/classify.sh"; then
  echo "FAIL: could not extract the classify block from $WF (no unsafe_overrides found)"
  exit 1
fi

# Stub `gh`: the shipped block makes TWO calls to the files API — one for
# `.filename` (the changed-file listing) and one for `.previous_filename`
# (rename sources, override-only). Discriminate on the --jq expression so
# each returns its own fixture; a stub that returned the same list for both
# would make the rename-bypass cases pass vacuously.
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    *previous_filename*) cat "$FAKE_RENAMES"; exit 0 ;;
  esac
done
cat "$FAKE_FILES"
STUB
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"

# Args are irrelevant to the stub but the block references them under `set -u`.
export GH_TOKEN=stub REPO=owner/repo PR=1 EXTRA_GLOBS=""

# RENAMED_FROM: newline-separated rename SOURCE paths for the next case.
# Reset after every run_case so it never leaks between cases.
RENAMED_FROM=""

# run_case <name> <expected all_safe> <expected reason|-> <file>...
run_case() {
  local name="$1" want_safe="$2" want_reason="$3"
  shift 3
  printf '%s\n' "$@" > "$T/files.txt"
  export FAKE_FILES="$T/files.txt"
  printf '%s' "$RENAMED_FROM" > "$T/renames.txt"
  export FAKE_RENAMES="$T/renames.txt"
  RENAMED_FROM=""
  : > "$T/gh_output"
  export GITHUB_OUTPUT="$T/gh_output"

  if ! bash "$T/classify.sh" > "$T/log" 2>&1; then
    echo "FAIL[$name]: classify block exited non-zero"
    sed 's/^/    /' "$T/log"
    failed=1
    return
  fi

  local got_safe got_reason
  got_safe=$(grep -E '^all_safe=' "$T/gh_output" | tail -1 | cut -d= -f2)
  got_reason=$(grep -E '^reason=' "$T/gh_output" | tail -1 | cut -d= -f2- || true)
  [ -n "$got_reason" ] || got_reason="-"

  if [ "$got_safe" != "$want_safe" ]; then
    echo "FAIL[$name]: all_safe=$got_safe, want $want_safe (files: $*)"
    failed=1
    return
  fi
  if [ "$want_reason" != "-" ] && [ "$got_reason" != "$want_reason" ]; then
    echo "FAIL[$name]: reason=$got_reason, want $want_reason"
    failed=1
    return
  fi
  echo "ok[$name] all_safe=$got_safe reason=$got_reason"
}

# 1. The incident case: legal wording alone must NOT be safe.
run_case "legal-aup" 0 unsafe-override "docs/legal/acceptable-use-policy.md"
run_case "legal-tos" 0 unsafe-override "docs/legal/terms-of-service.md"
run_case "legal-nested" 0 unsafe-override "docs/legal/archive/2025/privacy.md"

# 2. The override wins over co-changed safe files (all-or-nothing).
run_case "legal-mixed-docs" 0 unsafe-override \
  "docs/runbooks/deploy.md" "docs/legal/acceptable-use-policy.md"
run_case "legal-mixed-tests" 0 unsafe-override \
  "tests/test_thing.py" "docs/legal/acceptable-use-policy.md"

# 3. Regression guard: ordinary docs must STILL auto-merge. Over-blocking
#    would defeat the carve-out this workflow exists to provide.
run_case "plain-docs" 1 - "docs/architecture.md"
run_case "docs-nested" 1 - "docs/runbooks/webnx-cutover.md"
run_case "docs-multi" 1 - "docs/a.md" "docs/b/c.md"

# 4. A path that merely CONTAINS "legal" deeper in the tree is not the
#    override target — the pattern is anchored at docs/legal/.
run_case "not-anchored" 1 - "docs/notes/legal-review-process.md"

# 5. tests/** unaffected.
run_case "tests-only" 1 - "tests/test_a.py" "tests/test_b.py"

# 5b. Rename BYPASS (codex R1 P2): moving a legal doc out of docs/legal/
#     into another safe tree reports only the DESTINATION in .filename.
#     Relocating the policy out of its canonical home must not auto-merge.
RENAMED_FROM="docs/legal/acceptable-use-policy.md"
run_case "legal-renamed-out" 0 unsafe-override "docs/archive/acceptable-use-policy.md"

RENAMED_FROM="docs/legal/terms-of-service.md"
run_case "legal-renamed-to-tests" 0 unsafe-override "tests/fixtures/tos.md"

# 5c. Rename INTO docs/legal/ is caught on the destination path alone.
RENAMED_FROM="docs/drafts/aup.md"
run_case "legal-renamed-in" 0 unsafe-override "docs/legal/acceptable-use-policy.md"

# 5d. A rename with no legal path on EITHER end stays safe — the
#     previous_filename lookup must not blanket-block ordinary doc moves.
RENAMED_FROM="docs/old-name.md"
run_case "docs-renamed-benign" 1 - "docs/new-name.md"

# 6. Genuinely unsafe code still defers via the normal path (not the
#    override reason) — proves the override didn't swallow the old branch.
run_case "src-code" 0 - "src/app/main.py"

# 7. The override is evaluated BEFORE the 3000-file truncation exit. An
#    already-armed PR grown past the listing cap must still report
#    unsafe-override (the reason the revoke step keys on), not
#    file-list-truncated. (Codex review round 8 P2.)
{
  for i in $(seq 1 3200); do echo "docs/page_${i}.md"; done
  echo "docs/legal/acceptable-use-policy.md"
} > "$T/big.txt"
export FAKE_FILES="$T/big.txt"
: > "$T/renames.txt"; export FAKE_RENAMES="$T/renames.txt"
: > "$T/gh_output"; export GITHUB_OUTPUT="$T/gh_output"
if bash "$T/classify.sh" > "$T/log" 2>&1; then
  got_safe=$(grep -E '^all_safe=' "$T/gh_output" | tail -1 | cut -d= -f2)
  got_reason=$(grep -E '^reason=' "$T/gh_output" | tail -1 | cut -d= -f2-)
  if [ "$got_safe" = "0" ] && [ "$got_reason" = "unsafe-override" ]; then
    echo "ok[truncated-with-legal] all_safe=0 reason=unsafe-override"
  else
    echo "FAIL[truncated-with-legal]: all_safe=$got_safe reason=$got_reason, want 0/unsafe-override"
    failed=1
  fi
else
  echo "FAIL[truncated-with-legal]: classify block exited non-zero"
  failed=1
fi

# 7b. A truncated list with NO override path still defers as truncated.
{ for i in $(seq 1 3200); do echo "docs/page_${i}.md"; done; } > "$T/big2.txt"
export FAKE_FILES="$T/big2.txt"
: > "$T/gh_output"; export GITHUB_OUTPUT="$T/gh_output"
if bash "$T/classify.sh" > "$T/log" 2>&1; then
  got_reason=$(grep -E '^reason=' "$T/gh_output" | tail -1 | cut -d= -f2-)
  if [ "$got_reason" = "file-list-truncated" ]; then
    echo "ok[truncated-no-legal] reason=file-list-truncated"
  else
    echo "FAIL[truncated-no-legal]: reason=$got_reason, want file-list-truncated"
    failed=1
  fi
else
  echo "FAIL[truncated-no-legal]: classify block exited non-zero"
  failed=1
fi

if [ "$failed" -ne 0 ]; then
  echo "FAILED"
  exit 1
fi
echo "All safe-paths unsafe-override cases passed."
