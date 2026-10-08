#!/usr/bin/env bash
# Behavioral test for the "Detect Claude authorship" step in
# claude-author-automerge.yml: its claude_authored=1 is the first condition of
# every arm.
#
# INCIDENT CLASS (topcoder1/dotclaude#458, 2026-10-08): the trailer check was
# `git log --format=%B BASE..HEAD | grep -qiE '^Co-Authored-By:\s*Claude'`
# under `set -euo pipefail`. grep -q exits at its first match and closes the
# pipe; git log, still writing the older commits' bodies, takes EPIPE and
# exits 141, and pipefail turns a FOUND trailer into "not Claude-authored".
# The direction is fail-closed (the arm is skipped), but nondeterministic, and
# it lands on exactly the multi-commit PRs whose newest commit has the trailer.
#
# Cases, on a branch outside claude/* so only the trailer can decide:
#   * trailer in the PR's only commit              -> 1 (the harness detects)
#   * no trailer, no override label                -> 0 (the harness can refuse)
#   * trailer in the newest commit of a ~300 KB    -> 1 (the race; deterministic
#     log                                               at this size, see
#                                                       test_regression_convention_bullet_cap.sh)
#   * CONTROL: the old pipe on that same log       -> 0 (if this passes, the
#                                                       fixture no longer
#                                                       exercises the race)
#
# Run from the repo root:
#   bash selftest/test_automerge_detect_authorship.sh
set -euo pipefail

WF=.github/workflows/claude-author-automerge.yml
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
failed=0

awk '
  /^      - name: Detect Claude authorship$/ { in_step=1; next }
  in_step && /^      - name: / { exit }
  in_step && /^        run: \|$/ { in_run=1; next }
  in_run && /^          / { sub(/^          /, ""); print; next }
  in_run && /^[[:space:]]*$/ { print ""; next }
  in_run { exit }
' "$WF" > "$T/detect.sh"
if ! grep -q 'claude_authored=' "$T/detect.sh"; then
  echo "✗ could not extract the Detect Claude authorship run block from $WF"
  exit 1
fi
echo "✓ extracted the detect step ($(wc -l < "$T/detect.sh" | tr -d ' ') lines)"

TRAILER="Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
awk 'BEGIN { print "chore: vendor a large generated changelog"; print ""
             for (i = 1; i <= 5000; i++) printf "  changelog entry %05d copied into this commit message body\n", i }' > "$T/big_msg.txt"

make_repo() {  # $1 = layout: small-trailer | no-trailer | big-log-trailer; prints "dir base head"
  local d; d=$(mktemp -d "$T/repo.XXXXXX")
  cd "$d"
  git init -q . && git config user.email t@t && git config user.name t
  git commit -q --allow-empty -m base
  local base; base=$(git rev-parse HEAD)
  case "$1" in
    small-trailer)   git commit -q --allow-empty -m "fix: x" -m "$TRAILER" ;;
    no-trailer)      git commit -q --allow-empty -m "fix: x" ;;
    big-log-trailer) git commit -q --allow-empty -F "$T/big_msg.txt"
                     git commit -q --allow-empty -m "fix: x" -m "$TRAILER" ;;
  esac
  echo "$d $base $(git rev-parse HEAD)"
}

run_case() {  # $1 label, $2 expected claude_authored, $3 layout, $4 step script
  local label="$1" want="$2" script="${4-$T/detect.sh}" d base head rc=0
  read -r d base head <<<"$(make_repo "$3")"
  : > "$T/output"
  ( cd "$d" && BRANCH="feature/x" BASE_SHA="$base" HEAD_SHA="$head" \
      OVERRIDE_LABEL="claude-authored" LABELS_JSON='[]' GITHUB_OUTPUT="$T/output" \
      bash "$script" ) > "$T/out" 2>&1 || rc=$?
  local got; got=$(sed -n 's/^claude_authored=//p' "$T/output")
  if [ "$rc" -eq 0 ] && [ "$got" = "$want" ]; then
    echo "✓ $label (claude_authored=$got)"
  else
    echo "✗ $label: expected claude_authored=$want, got '$got' (rc=$rc)"
    sed 's/^/    /' "$T/out" | head -6
    failed=1
  fi
}

if [ "$(git -C "$(make_repo big-log-trailer | cut -d' ' -f1)" log --format=%B -2 | wc -c)" -lt 262144 ]; then
  echo "✗ the big-log fixture is under the 256 KiB the race needs"
  failed=1
fi

run_case "trailer in the only commit is detected"                    1 small-trailer
run_case "no trailer and no override label is not Claude-authored"   0 no-trailer
run_case "trailer in the newest commit of a ~300 KB log is detected" 1 big-log-trailer

# shellcheck disable=SC2016  # the step's own text, matched literally
SHIPPED_TEST='if bodies=$(git log --format=%B "$BASE_SHA..$HEAD_SHA") && grep -qiE '"'^Co-Authored-By:\\s*Claude'"' <<<"$bodies"; then'
# shellcheck disable=SC2016
PIPED_TEST='if git log --format=%B "$BASE_SHA..$HEAD_SHA" | grep -qiE '"'^Co-Authored-By:\\s*Claude'"'; then'
if SHIPPED="$SHIPPED_TEST" PIPED="$PIPED_TEST" awk '
     (i = index($0, ENVIRON["SHIPPED"])) > 0 {
       $0 = substr($0, 1, i - 1) ENVIRON["PIPED"] substr($0, i + length(ENVIRON["SHIPPED"]))
       n++
     }
     { print }
     END { exit n != 1 }
   ' "$T/detect.sh" > "$T/detect_pipe.sh"; then
  run_case "CONTROL: the old git log | grep -qiE form misses that trailer" 0 big-log-trailer "$T/detect_pipe.sh"
else
  echo "✗ could not build the pipe-form control: the step no longer contains exactly one"
  echo "    $SHIPPED_TEST"
  failed=1
fi

if (( failed )); then
  echo "FAIL"
  exit 1
fi
echo "PASS"
