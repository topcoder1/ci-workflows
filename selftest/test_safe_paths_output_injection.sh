#!/usr/bin/env bash
# Behavioral test for safe-paths-automerge.yml's `classify` step: a PR author
# controls every changed-file NAME, and those names flow into what the step
# emits — both to $GITHUB_OUTPUT and to the step LOG (which the runner scans
# for ::workflow commands::). This pins that a crafted name can NEITHER change
# the `all_safe` decision, NOR add another $GITHUB_OUTPUT key, NOR emit a
# ::workflow command:: line. The step's output/log is a function of the
# classification, never of the file names.
#
# Backslashes are legal in git paths, so a file name may contain literal
# escape bytes. The step must treat such a name as opaque data.
#
# The classify block is EXTRACTED from the shipped workflow YAML and executed,
# so this exercises the real bash rather than a mirrored copy that can drift.
#
# Run from the repo root:
#   bash selftest/test_safe_paths_output_injection.sh
set -euo pipefail

failed=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

WF=.github/workflows/safe-paths-automerge.yml

# Extract the `run: |` body of the step with `id: classify`, then strip the
# block's 10-space YAML indent so it runs as a standalone script. (Same
# extraction the sibling test_safe_paths_unsafe_overrides.sh uses.)
awk '
  /^[[:space:]]*id: classify[[:space:]]*$/ { in_step = 1 }
  in_step && /^[[:space:]]*run: \|[[:space:]]*$/ { grab = 1; next }
  grab && /^      - name:/ { exit }
  grab { print }
' "$WF" | sed -e 's/^          //' > "$T/classify.sh"

if ! grep -q 'unsafe_files=' "$T/classify.sh"; then
  echo "FAIL: could not extract the classify block from $WF (no unsafe_files found)"
  exit 1
fi
# The extracted body must be pure shell — a stray inline ${{ }} expression
# would mean we grabbed a templated line and the standalone run is bogus.
if grep -q '\${{' "$T/classify.sh"; then
  echo "FAIL: extracted classify block contains an unresolved \${{ }} expression"
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
export GH_TOKEN=stub REPO=owner/repo PR=1 EXTRA_GLOBS=""

# A single backslash byte, built at runtime — never typed as a literal escape
# in this source (tool input silently decodes some escape sequences).
bs=$(printf '\\')

# A file name a PR author could choose. It is unsafe-by-glob (starts with
# "zzz"), so classification defers with all_safe=0. The bytes after it carry
# backslash-escape sequences and two payloads: an all_safe=1 line (would be an
# injected $GITHUB_OUTPUT key) and a ::notice:: line (would be an injected
# runner workflow-command). Both only materialize if the step expands the
# name's bytes (printf "%b") instead of treating it as opaque data.
crafted="zzz${bs}n::notice::injected${bs}nall_safe=1${bs}nEOF${bs}nx<<EOF"

# --- Main assertion: run the SHIPPED block; inspect GITHUB_OUTPUT and log. ---
printf '%s\n' "src/evil.py" "$crafted" > "$T/files.txt"
export FAKE_FILES="$T/files.txt"
: > "$T/renames.txt"; export FAKE_RENAMES="$T/renames.txt"
: > "$T/gh_output"; export GITHUB_OUTPUT="$T/gh_output"

if ! bash "$T/classify.sh" > "$T/log" 2>&1; then
  echo "FAIL[shipped-run]: classify block exited non-zero"
  sed 's/^/    /' "$T/log"
  failed=1
fi

# (a) GITHUB_OUTPUT: exactly one all_safe= line, value 0, nothing else.
n_all_safe=$(grep -c '^all_safe=' "$T/gh_output" || true)
if [ "$n_all_safe" -ne 1 ]; then
  echo "FAIL[single-decision]: expected exactly one all_safe= line in GITHUB_OUTPUT, got $n_all_safe"
  sed 's/^/    /' "$T/gh_output"
  failed=1
fi
if ! grep -qx 'all_safe=0' "$T/gh_output"; then
  echo "FAIL[defers]: expected all_safe=0 (unsafe files present)"
  failed=1
fi
if grep -qx 'all_safe=1' "$T/gh_output"; then
  echo "FAIL[injected-decision]: a crafted file name produced all_safe=1 in GITHUB_OUTPUT"
  failed=1
fi
stray=$(grep -vx 'all_safe=0' "$T/gh_output" | grep -v '^$' || true)
if [ -n "$stray" ]; then
  echo "FAIL[stray-output]: unexpected line(s) in GITHUB_OUTPUT beyond all_safe=0:"
  printf '%s\n' "$stray" | sed 's/^/    /'
  failed=1
fi

# (b) Step LOG: no injected ::workflow command:: line, no bare injected key.
# The deferring branch emits no ::commands:: of its own, so any ::-prefixed
# line here would be author-controlled bytes the runner would execute.
if grep -Eq '^::' "$T/log"; then
  echo "FAIL[stdout-command-injection]: a crafted file name produced a ::workflow command:: line in the step log:"
  grep -nE '^::' "$T/log" | sed 's/^/    /'
  failed=1
fi
if grep -qx 'all_safe=1' "$T/log"; then
  echo "FAIL[stdout-key-injection]: a crafted file name produced a standalone all_safe=1 line in the step log"
  failed=1
fi
[ "$failed" -eq 0 ] && echo "ok[shipped-run] GITHUB_OUTPUT carries only all_safe=0; log has no injected command/key"

# --- Positive control (same run): prove the harness CAN see a breakout. ---
# Reproduce the historically-vulnerable render shape — the author-controlled
# value %b-expanded — into both sinks (a fixed-delimiter $GITHUB_OUTPUT heredoc
# and the step log) on the same crafted input, and confirm the assertions above
# would have caught it. A green main assertion is only meaningful if this
# control is RED in both sinks.
ctrl_files=$(printf '%s\n' "src/evil.py" "$crafted")
inj=""
while IFS= read -r f; do
  [ -z "$f" ] && continue
  inj="$inj$f${bs}n"
done <<< "$ctrl_files"

: > "$T/ctrl_output"
{
  echo "all_safe=0"
  { echo "unsafe<<EOF"; printf "%b" "$inj"; echo "EOF"; }
} >> "$T/ctrl_output"
: > "$T/ctrl_log"
printf "%b" "$inj" > "$T/ctrl_log"

ctrl_ok=1
grep -qx 'all_safe=1' "$T/ctrl_output" || ctrl_ok=0     # output-file breakout
grep -Eq '^::notice::' "$T/ctrl_log"   || ctrl_ok=0     # stdout command breakout
if [ "$ctrl_ok" -ne 1 ]; then
  echo "FAIL[positive-control]: the vulnerable %b render shape did NOT inject in both"
  echo "  sinks, so a green main assertion proves nothing."
  echo "  --- ctrl_output ---"; sed 's/^/    /' "$T/ctrl_output"
  echo "  --- ctrl_log ---";    sed 's/^/    /' "$T/ctrl_log"
  failed=1
else
  echo "ok[positive-control] vulnerable %b render injects into output AND log (harness is live)"
fi

if [ "$failed" -ne 0 ]; then
  echo "FAILED"
  exit 1
fi
echo "All safe-paths output-injection cases passed."
