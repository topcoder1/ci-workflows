#!/usr/bin/env bash
# Behavioral test for claude-author-automerge.yml's "Comment when
# classifier-blocked" step: one manual-merge notice per blocked PR, not two.
#
# Context (WS2 step 4, 2026-10-02): pr-classify posts its own notice on every
# risk:blocked PR ("Risk class: `blocked` — manual merge required", which also
# says this workflow refuses auto-merge), and this step posted a second one.
# Measured on 104 blocked PRs in five repos (09-15..10-02): 103 carried both.
# Only pr-classify's COMMENT suppresses this one: a risk:blocked label can be
# applied by hand and pr-classify's comment step is non-fatal, so a label
# proves nothing (Codex pre-review round 1). Both workflows start from the
# same event, so the step looks for the notice every 15 s for up to 90 s
# before posting its own. Two automerge callers run no pr-classify at all
# (topcoder1/dotclaude, topcoder1/jz_skills), and pr-classify never annotates
# risk:sensitive: there this step's comment is the only notice.
#
# The test EXTRACTS the step's bash from the workflow (the shipped script, not
# a copy) and runs it against a stubbed `gh` that applies each call's real
# `--jq` filter to fixture JSON:
#
#   1. blocked, pr-classify's notice already there   ⇒ none created, no wait
#   2. blocked, the notice lands on the 3rd look      ⇒ none created, 2 waits
#   3. blocked, the notice never comes (no pr-classify) ⇒ one created after
#      7 looks and 6 waits of 15 s
#   4. blocked, a hand-applied `risk:blocked` label, no notice ⇒ one created
#   5. sensitive                                      ⇒ one created, no wait
#   6. sensitive beside a stale pr-classify notice    ⇒ one created, no wait
#   7. an existing comment of this step               ⇒ PATCHed in place, none
#      created, no wait (also the positive control for the stub's --jq)
#   8. blocked, every comment read fails              ⇒ one created after the
#      bounded wait (a failed read counts as absent)
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
cat > "$T/bin/sleep" <<'STUB'
#!/usr/bin/env bash
echo "sleep $*" >> "$GH_LOG"
STUB
chmod +x "$T/bin/sleep"
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
jqf="" method="GET" path="" paginate=0
while [ $# -gt 0 ]; do
  case "$1" in
    --jq) jqf="$2"; shift 2 ;;
    --paginate) paginate=1; shift ;;
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
  "GET "*/comments*)
    src="$FIXTURES/comments.json"
    if [ "$paginate" = "1" ]; then
      # The notice lookups paginate; the step's own-comment lookup does not.
      looks=$(( $(cat "$FIXTURES/looks" 2>/dev/null || echo 0) + 1 ))
      echo "$looks" > "$FIXTURES/looks"
      if [ "${STUB_NOTICE_READS_FAIL:-0}" = "1" ]; then
        echo '{"message":"Server Error","status":"502"}'
        exit 1
      fi
      if [ -n "${STUB_NOTICE_FROM_LOOK:-}" ] && [ "$looks" -ge "$STUB_NOTICE_FROM_LOOK" ]; then
        src="$FIXTURES/comments_later.json"
      fi
    fi ;;
  *) echo "stub: unexpected gh api call: $method $path" >&2; exit 99 ;;
esac
if [ -n "$jqf" ]; then jq -r "$jqf" "$src"; else cat "$src"; fi
STUB
chmod +x "$T/bin/gh"

AM_MARKER='<!-- claude-author-automerge:classifier-blocked -->'
PC_MARKER='<!-- pr-classify:blocked -->'

# run_case NAME VERDICT LABELS_JSON COMMENTS_JSON [LATER_COMMENTS_JSON]
#   env knobs: STUB_NOTICE_FROM_LOOK=N (the notice lookups return
#   LATER_COMMENTS_JSON from look N), STUB_NOTICE_READS_FAIL=1.
run_case() {
  local name="$1" verdict="$2" labels="$3" comments="$4" later="${5:-[]}"
  mkdir -p "$T/$name"
  printf '%s\n' "$labels" > "$T/$name/labels.json"
  printf '%s\n' "$comments" > "$T/$name/comments.json"
  printf '%s\n' "$later" > "$T/$name/comments_later.json"
  : > "$T/$name/gh.log"
  set +e
  ( export PATH="$T/bin:$PATH" GH_LOG="$T/$name/gh.log" FIXTURES="$T/$name" \
      GITHUB_REPOSITORY="stub/repo" PR="42" \
      GH_TOKEN=x VERDICT="$verdict" VERDICT_SOURCE="label"
    bash "$T/step.sh" ) > "$T/$name/out" 2>&1
  echo $? > "$T/$name/rc"
  set -e
}

created() { grep -c '^gh pr comment 42 --body-file' "$T/$1/gh.log" || true; }
patched() { grep -c '^gh api -X PATCH /repos/stub/repo/issues/comments/777' "$T/$1/gh.log" || true; }
waits() { grep -c '^sleep 15$' "$T/$1/gh.log" || true; }

# expect NAME CREATED PATCHED WAITS WHY
expect() {
  local name="$1" want_created="$2" want_patched="$3" want_waits="$4" why="$5"
  local rc c p w
  rc=$(cat "$T/$name/rc"); c=$(created "$name"); p=$(patched "$name"); w=$(waits "$name")
  if [ "$rc" = "0" ] && [ "$c" = "$want_created" ] && [ "$p" = "$want_patched" ] && [ "$w" = "$want_waits" ]; then
    echo "✓ $name: $why"
  else
    echo "✗ $name: $why — rc=$rc created=$c patched=$p waits=$w (want created=$want_created patched=$want_patched waits=$want_waits)"
    sed 's/^/    | /' "$T/$name/out"
    failed=1
  fi
}

run_case notice-present "risk:blocked" '[]' "[{\"id\":5,\"body\":\"$PC_MARKER\\n**Risk class: blocked**\"}]"
expect notice-present 0 0 0 "pr-classify's notice already on the PR covers it"
if grep -q "pr-classify's risk:blocked notice covers this PR" "$T/notice-present/out"; then
  echo "✓ notice-present: the skip is logged"
else
  echo "✗ notice-present: the skip left no log line"
  failed=1
fi

STUB_NOTICE_FROM_LOOK=3 run_case notice-arrives "risk:blocked" '[]' '[]' "[{\"id\":5,\"body\":\"$PC_MARKER\"}]"
expect notice-arrives 0 0 2 "a notice that lands while the step waits still covers it"

run_case notice-never "risk:blocked" '[]' '[]'
expect notice-never 1 0 6 "no notice after 90 s (a repo without pr-classify) ⇒ this step's one notice"
looks=$(cat "$T/notice-never/looks" 2>/dev/null || echo 0)
if [ "$looks" = "7" ]; then
  echo "✓ notice-never: the wait is bounded at 7 looks"
else
  echo "✗ notice-never: expected 7 notice lookups, got $looks"
  failed=1
fi

run_case hand-label "risk:blocked" '[{"name":"risk:blocked"}]' '[]'
expect hand-label 1 0 6 "a risk:blocked label alone (hand-applied, or a failed pr-classify comment) suppresses nothing"

run_case sensitive "risk:sensitive" '[{"name":"risk:sensitive"}]' '[]'
expect sensitive 1 0 0 "pr-classify never annotates risk:sensitive"

run_case sensitive-stale "risk:sensitive" '[{"name":"risk:sensitive"}]' "[{\"id\":5,\"body\":\"$PC_MARKER old\"}]"
expect sensitive-stale 1 0 0 "a stale blocked notice does not cover a sensitive PR"

run_case existing "risk:blocked" '[]' "[{\"id\":777,\"body\":\"$AM_MARKER\\nold sensitive text\"}]"
expect existing 0 1 0 "an existing comment is edited in place (an edit notifies nobody)"

STUB_NOTICE_READS_FAIL=1 run_case reads-down "risk:blocked" '[]' '[]'
expect reads-down 1 0 6 "an unreadable comment list counts as absent"

if [ "$failed" -ne 0 ]; then
  echo "FAIL"
  exit 1
fi
echo "PASS"
