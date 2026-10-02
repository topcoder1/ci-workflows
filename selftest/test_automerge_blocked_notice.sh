#!/usr/bin/env bash
# Behavioral test for claude-author-automerge.yml's "Comment when
# classifier-blocked" step: one manual-merge notice per blocked PR, not two.
#
# Context (WS2 step 4, 2026-10-02): pr-classify posts its own notice on every
# risk:blocked PR ("Risk class: `blocked` — manual merge required", which also
# says this workflow refuses auto-merge), and this step posted a second one.
# Measured on 104 blocked PRs in five repos (09-15..10-02): 103 carried both.
# pr-classify writes the risk:blocked label one step before its notice, so
# either on the PR means the notice exists or is seconds away. Two automerge
# callers run no pr-classify at all (topcoder1/dotclaude, topcoder1/jz_skills),
# and pr-classify never annotates risk:sensitive: there this step's comment is
# the only notice.
#
# The test EXTRACTS the step's bash from the workflow (the shipped script, not
# a copy) and runs it against a stubbed `gh` that applies each call's real
# `--jq` filter to fixture JSON:
#
#   1. blocked, `risk:blocked` label on the PR       ⇒ no comment created
#   2. blocked, pr-classify's notice on the PR       ⇒ no comment created
#   3. blocked, neither (a repo without pr-classify)  ⇒ one comment created
#   4. sensitive                                      ⇒ one comment created
#   5. sensitive beside a stale pr-classify notice    ⇒ one comment created
#   6. an existing comment of this step               ⇒ PATCHed in place, none
#      created (also the positive control for the stub's --jq application)
#   7. blocked, labels unreadable, no notice found    ⇒ one comment created
#      (a failed read counts as absent: a duplicate notice beats none)
#   8. blocked, labels unreadable, notice present     ⇒ no comment created
#
# Structural pins: the run block is `${{ }}`-free (extraction- and
# injection-safe), and the sensitive and blocked bodies keep their text.
#
# Run from the repo root:
#   bash selftest/test_automerge_blocked_notice.sh
set -euo pipefail

WF=.github/workflows/claude-author-automerge.yml
failed=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

awk '
  /^      - name: Comment when classifier-blocked$/ { in_step=1 }
  in_step && /^        run: \|/ { in_run=1; next }
  in_run {
    if ($0 ~ /^          / || $0 == "") { sub(/^          /, ""); print }
    else { exit }
  }
' "$WF" > "$T/step.sh"

if ! grep -q 'claude-author-automerge:classifier-blocked' "$T/step.sh"; then
  echo "✗ could not extract the classifier-blocked comment step from $WF"
  exit 1
fi
echo "✓ extracted classifier-blocked comment step ($(wc -l < "$T/step.sh" | tr -d ' ') lines)"

if grep -q '\${{' "$T/step.sh"; then
  echo "✗ the step's run block embeds a \${{ }} expression — pass values through env (GITHUB_REPOSITORY is set by the runner)"
  failed=1
else
  echo "✓ run block is \${{ }}-free"
fi

for text in "sensitive-class PRs are reviewed" "blocked-class PRs require admin click-merge"; do
  if grep -qF "$text" "$T/step.sh"; then
    echo "✓ comment body still says: $text"
  else
    echo "✗ comment body lost: $text"
    failed=1
  fi
done

mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Records every call; applies --jq with real jq to the fixtures, like gh does.
echo "gh $*" >> "$GH_LOG"
if [ "$1" = "pr" ] && [ "$2" = "comment" ]; then
  exit 0
fi
if [ "$1" != "api" ]; then
  echo "stub: unexpected gh call: $*" >&2
  exit 99
fi
shift
jqf="" method="GET" path=""
while [ $# -gt 0 ]; do
  case "$1" in
    --jq) jqf="$2"; shift 2 ;;
    --paginate) shift ;;
    -X) method="$2"; shift 2 ;;
    -f) shift 2 ;;
    *) path="$1"; shift ;;
  esac
done
case "$method $path" in
  "PATCH "*) exit 0 ;;
  "GET "*/labels*)
    if [ "${STUB_LABELS_FAIL:-0}" = "1" ]; then
      # gh prints an HTTP error's JSON body to STDOUT and exits 1.
      echo '{"message":"Server Error","status":"502"}'
      exit 1
    fi
    src="$FIXTURES/labels.json" ;;
  "GET "*/comments*) src="$FIXTURES/comments.json" ;;
  *) echo "stub: unexpected gh api call: $method $path" >&2; exit 99 ;;
esac
if [ -n "$jqf" ]; then jq -r "$jqf" "$src"; else cat "$src"; fi
STUB
chmod +x "$T/bin/gh"

AM_MARKER='<!-- claude-author-automerge:classifier-blocked -->'
PC_MARKER='<!-- pr-classify:blocked -->'

# run_case NAME VERDICT LABELS_JSON COMMENTS_JSON [STUB_LABELS_FAIL]
run_case() {
  local name="$1" verdict="$2" labels="$3" comments="$4" labels_fail="${5:-0}"
  mkdir -p "$T/$name"
  printf '%s\n' "$labels" > "$T/$name/labels.json"
  printf '%s\n' "$comments" > "$T/$name/comments.json"
  : > "$T/$name/gh.log"
  set +e
  ( export PATH="$T/bin:$PATH" GH_LOG="$T/$name/gh.log" FIXTURES="$T/$name" \
      STUB_LABELS_FAIL="$labels_fail" GITHUB_REPOSITORY="stub/repo" PR="42" \
      GH_TOKEN=x VERDICT="$verdict" VERDICT_SOURCE="label"
    bash "$T/step.sh" ) > "$T/$name/out" 2>&1
  echo $? > "$T/$name/rc"
  set -e
}

created() { grep -c '^gh pr comment 42 --body-file' "$T/$1/gh.log" || true; }
patched() { grep -c '^gh api -X PATCH /repos/stub/repo/issues/comments/777' "$T/$1/gh.log" || true; }

expect() {
  local name="$1" want_created="$2" want_patched="$3" why="$4"
  local rc c p
  rc=$(cat "$T/$name/rc"); c=$(created "$name"); p=$(patched "$name")
  if [ "$rc" = "0" ] && [ "$c" = "$want_created" ] && [ "$p" = "$want_patched" ]; then
    echo "✓ $name: $why"
  else
    echo "✗ $name: $why — rc=$rc created=$c patched=$p (want created=$want_created patched=$want_patched)"
    sed 's/^/    | /' "$T/$name/out"
    failed=1
  fi
}

run_case blocked-label "risk:blocked" '[{"name":"risk:blocked"},{"name":"automerge:blocked-classifier"}]' '[]'
expect blocked-label 0 0 "a risk:blocked label means pr-classify's notice exists or is seconds away"
if grep -q "pr-classify's risk:blocked notice covers this PR" "$T/blocked-label/out"; then
  echo "✓ blocked-label: the skip is logged"
else
  echo "✗ blocked-label: the skip left no log line"
  failed=1
fi

run_case blocked-notice "risk:blocked" '[]' "[{\"id\":5,\"body\":\"$PC_MARKER\\n**Risk class: blocked**\"}]"
expect blocked-notice 0 0 "pr-classify's notice on the PR covers it"

run_case blocked-alone "risk:blocked" '[]' '[]'
expect blocked-alone 1 0 "a repo without pr-classify still gets the one notice"

run_case sensitive "risk:sensitive" '[{"name":"risk:sensitive"}]' '[]'
expect sensitive 1 0 "pr-classify never annotates risk:sensitive"

run_case sensitive-stale "risk:sensitive" '[{"name":"risk:sensitive"}]' "[{\"id\":5,\"body\":\"$PC_MARKER old\"}]"
expect sensitive-stale 1 0 "a stale blocked notice does not cover a sensitive PR"

run_case existing "risk:blocked" '[{"name":"risk:blocked"}]' "[{\"id\":777,\"body\":\"$AM_MARKER\\nold sensitive text\"}]"
expect existing 0 1 "an existing comment is edited in place (an edit notifies nobody)"

run_case labels-down "risk:blocked" '[]' '[]' 1
expect labels-down 1 0 "an unreadable label list counts as absent"

run_case labels-down-notice "risk:blocked" '[]' "[{\"id\":5,\"body\":\"$PC_MARKER\"}]" 1
expect labels-down-notice 0 0 "with labels unreadable, pr-classify's notice still covers it"

if [ "$failed" -ne 0 ]; then
  echo "FAIL"
  exit 1
fi
echo "PASS"
