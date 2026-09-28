#!/usr/bin/env bash
# Behavioral test for claude-author-automerge.yml's `risk` step. That step
# emits the `risky` output that gates the arm step (a risk-tier match blocks
# auto-merge). Alongside `risky` it emits `matched`, a human-readable list of
# the files that hit a risk pattern — built from PR-controlled file names.
#
# `risky` must be a function of path classification ALONE. A PR author picks
# every changed-file name, and backslashes are legal in git paths, so a name
# may carry escape bytes. This pins that no such name can add or alter an
# output key — in particular it can never flip `risky` from 1 to 0 and unblock
# its own risky PR — while the legitimate `matched` list is still emitted.
#
# The `risk` block is EXTRACTED from the shipped workflow YAML and executed,
# so this exercises the real bash rather than a mirrored copy that can drift.
#
# Run from the repo root:
#   bash selftest/test_automerge_output_injection.sh
set -euo pipefail

failed=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

WF=.github/workflows/claude-author-automerge.yml

# Extract the `run: |` body of the step with `id: risk`, then strip the
# block's 10-space YAML indent so it runs as a standalone script.
awk '
  /^[[:space:]]*id: risk[[:space:]]*$/ { in_step = 1 }
  in_step && /^[[:space:]]*run: \|[[:space:]]*$/ { grab = 1; next }
  grab && /^      - name:/ { exit }
  grab { print }
' "$WF" | sed -e 's/^          //' > "$T/risk.sh"

if ! grep -q 'matched=""' "$T/risk.sh"; then
  echo "FAIL: could not extract the risk block from $WF (no matched accumulator found)"
  exit 1
fi
# The extracted body must be pure shell — a stray inline ${{ }} expression
# would mean we grabbed a templated line and the standalone run is bogus.
if grep -q '\${{' "$T/risk.sh"; then
  echo "FAIL: extracted risk block contains an unresolved \${{ }} expression"
  exit 1
fi

# Stub `gh`: the block makes two files-API calls — `.filename` (changed list)
# and `.previous_filename` (rename sources). Discriminate on the --jq text.
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
export GH_TOKEN=stub GITHUB_REPOSITORY=owner/repo PR=1 RISK_MAIN_GO=true BYPASS_LABEL=auto-merge-approved

# A single backslash byte, built at runtime — never typed as a literal escape
# in this source (tool input silently decodes some escape sequences).
bs=$(printf '\\')

# A file name a PR author could choose. It is inside a risk path (secret/...),
# so classification MUST set risky=1; the bytes after it carry backslash-escape
# sequences and a risky=0 payload. If the step ever lets a name's bytes reach
# $GITHUB_OUTPUT, this is where a second risky line would appear.
crafted="secret/a${bs}nEOF${bs}nrisky=0${bs}nx<<EOF"

# --- Main assertion: run the SHIPPED block and inspect its GITHUB_OUTPUT. ---
printf '%s\n' "$crafted" > "$T/files.txt"
export FAKE_FILES="$T/files.txt"
: > "$T/renames.txt"; export FAKE_RENAMES="$T/renames.txt"
: > "$T/gh_output"; export GITHUB_OUTPUT="$T/gh_output"

if ! bash "$T/risk.sh" > "$T/log" 2>&1; then
  echo "FAIL[shipped-run]: risk block exited non-zero"
  sed 's/^/    /' "$T/log"
  failed=1
fi

n_risky=$(grep -c '^risky=' "$T/gh_output" || true)
if [ "$n_risky" -ne 1 ]; then
  echo "FAIL[single-decision]: expected exactly one risky= line in GITHUB_OUTPUT, got $n_risky"
  echo "  GITHUB_OUTPUT was:"
  sed 's/^/    /' "$T/gh_output"
  failed=1
fi
if ! grep -qx 'risky=1' "$T/gh_output"; then
  echo "FAIL[classifies-risky]: expected risky=1 (a secret/ path was changed)"
  failed=1
fi
if grep -qx 'risky=0' "$T/gh_output"; then
  echo "FAIL[injected-decision]: a crafted file name produced risky=0 in GITHUB_OUTPUT"
  failed=1
fi
# The legitimate matched list must still be emitted (guard against a fix that
# over-deletes) — its value carries the file name but as heredoc BODY, which
# is never applied as a key.
if ! grep -q '^matched<<' "$T/gh_output"; then
  echo "FAIL[matched-emitted]: the matched output heredoc is missing"
  failed=1
fi
[ "$failed" -eq 0 ] && echo "ok[shipped-run] risky=1 only; matched emitted; no injected key"

# --- Positive control (same run): prove the harness CAN see a breakout. ---
# Reproduce the historically-vulnerable write shape — a fixed heredoc
# delimiter with the author-controlled value %b-expanded — on the same
# crafted input, and confirm the assertion above would have caught it. A
# green main assertion is only meaningful if this control is RED.
: > "$T/ctrl_output"
matched_ctrl="$crafted (matched: PAT)${bs}n"
{
  echo "risky=1"
  echo "matched<<EOF"
  printf "%b" "$matched_ctrl"
  echo "EOF"
} >> "$T/ctrl_output"

ctrl_risky=$(grep -c '^risky=' "$T/ctrl_output" || true)
if [ "$ctrl_risky" -lt 2 ] || ! grep -qx 'risky=0' "$T/ctrl_output"; then
  echo "FAIL[positive-control]: the vulnerable write shape did NOT inject a second"
  echo "  risky line, so a green main assertion proves nothing. Control output:"
  sed 's/^/    /' "$T/ctrl_output"
  failed=1
else
  echo "ok[positive-control] vulnerable write shape injects risky=0 (harness is live)"
fi

if [ "$failed" -ne 0 ]; then
  echo "FAILED"
  exit 1
fi
echo "All claude-author output-injection cases passed."
