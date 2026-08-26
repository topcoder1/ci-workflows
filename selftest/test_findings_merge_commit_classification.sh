#!/usr/bin/env bash
# Behavioral test for LAST_COMMIT_JQ's merge-commit classification in the
# unaddressed-findings detector (ci-workflows#175, Codex pre-review P2:
# "No test asserts the selected last-commit timestamp for authored
# two-parent commits versus subject-identified or GitHub-committed base
# merges").
#
# BACKGROUND. The "last commit" a finding is measured against must be a
# commit that could plausibly ANSWER it. techrecon#826 (2026-08-06): a real
# inline finding was followed by four `Merge branch 'main' into ...`
# commits and nothing else; the detector picked up the last merge's
# timestamp and reported "no unaddressed findings" while the finding's
# actual text was still wrong on main at merge time. The original fix
# excluded every commit with 2+ parents.
#
# THE OVER-REACH. wxa_vpn#1529 (2026-08-16): "parents >= 2" excluded an
# AUTHORED 2-parent merge too — a hand-written `merge origin/main; reduce to
# the two setup guards main still lacks` commit that also added the tests
# two Codex P2s had asked for. The detector kept reporting the P2s as
# unaddressed after the very commit that addressed them, because parent
# count alone cannot separate a base merge from an authored one.
#
# THE FIX (#175): classify by SUBJECT, not parent count. git's fmt-merge-msg
# labels a single-source merge by how the source was named — `Merge branch
# '...'`, `Merge remote-tracking branch '...'`, `Merge commit '...'`,
# `Merge tag '...'` — and GitHub's merge button writes `Merge pull request
# #...`. Only those five enumerated, quote-anchored forms are excluded.
# PLUS a second, subject-independent gate: any commit GitHub itself commits
# (auto-update-branch, "Update branch", the merge queue) carries committer
# email noreply@github.com and is excluded regardless of subject wording, so
# a GitHub-authored subject reword cannot dodge the exclusion.
#
# All nine cases drive the vendored twin's `commits.json` fixture (the raw
# REST /pulls/{n}/commits shape LAST_COMMIT_JQ actually reduces, not a
# mirrored copy) through the --fixture seam. Each places one authored
# 1-parent commit (C1) before a bot P1 finding, then a second, 2-parent
# commit (C2) under test AFTER the finding — so the finding's fate (rc=0
# addressed by C2, or rc=1 still unaddressed because C2 was excluded and
# only C1's earlier timestamp counts) directly reveals whether C2 was
# classified as authored or as a base merge:
#
#   MC-A  the wxa_vpn#1529 shape itself: an authored 2-parent merge (custom
#         lowercase subject, non-GitHub committer email) counts as the last
#         commit -> the finding before it is addressed (rc=0).
#   MC-B  the techrecon#826 shape: `Merge branch 'main' into feature-x`
#         (2-parent) is excluded -> the finding stays unaddressed (rc=1).
#   MC-C  NEGATIVE CONTROL sweep: the other four enumerated base-merge
#         subjects (remote-tracking branch, commit, tag, GitHub's own pull
#         request wording) are each excluded the same way (rc=1 each).
#   MC-D  the other direction: merge-LIKE subjects that do NOT match the
#         enumerated, quote-anchored forms count as authored (rc=0 each) —
#         an octopus-merge subject ("Merge branches 'a' and 'b'", plural,
#         no exclusion), and a hand-written subject that only OPENS with
#         "Merge branch" but has no quote right after it (the quote is
#         load-bearing per #175's own design note).
#   MC-E  the subject-independent gate: a GitHub-committed merge
#         (committer email noreply@github.com) is excluded even when its
#         subject matches none of the five enumerated forms (rc=1).
#   MC-F  BASELINE negative control: a single 1-parent commit with no merge
#         involved at all -> a finding after it stays unaddressed (rc=1),
#         proving the harness isn't tautologically clean.
#
# Run from the repo root:
#   bash selftest/test_findings_merge_commit_classification.sh
set -euo pipefail

CHECKER=.github/scripts/unaddressed-findings.sh
failed=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

FX="$T/fixture"
mkdir -p "$FX"

T1='2026-01-01T00:00:00Z'   # C1: authored, 1-parent
T1_5='2026-01-01T01:00:00Z' # bot finding, between C1 and C2
T2='2026-01-01T02:00:00Z'   # C2: the commit under test

FINDING_BODY='P1 unscoped token reaches the delete endpoint — no test covers it.'

# commit_obj <date> <email> <nparents> <message> -> one REST-shaped commit object
commit_obj() {
  local date="$1" email="$2" nparents="$3" message="$4"
  jq -nc --arg date "$date" --arg email "$email" --arg msg "$message" --argjson n "$nparents" \
    '{parents: [range($n) | {sha: ("p" + (.|tostring))}], commit: {message: $msg, committer: {date: $date, email: $email}}}'
}

C1=$(commit_obj "$T1" "dev@example.com" 1 "add the delete endpoint guard")

# run_case <expected-rc> <name> <commits-json-array> -> sets RC, OUT
run_case() {
  local want_rc="$1" name="$2" commits_json="$3"
  printf '%s' "$commits_json" > "$FX/commits.json"
  printf '{"merged_at": null}' > "$FX/meta.json"
  jq -nc --arg at "$T1_5" --arg body "$FINDING_BODY" \
    '[{"created_at":$at,"user":{"login":"codex[bot]"},"body":$body}]' > "$FX/issue.json"
  echo '[]' > "$FX/inline.json"
  set +e
  OUT=$(bash "$CHECKER" --fixture "$FX" o/r 1 2>&1); RC=$?
  set -e
  if [ "$RC" -eq "$want_rc" ]; then
    echo "✓ $name"
  else
    echo "✗ $name — rc=$RC, expected $want_rc"
    printf '%s\n' "$OUT" | sed 's/^/    /'
    failed=1
  fi
}

# two_commits <c2-json> -> C1 followed by the given C2, as a JSON array
two_commits() { jq -sc 'add' <(echo "[$C1]") <(echo "[$1]"); }

C2A=$(commit_obj "$T2" "dev@example.com" 2 "merge origin/main; reduce to the two setup guards main still lacks")
run_case 0 "MC-A authored 2-parent merge counts as last commit (wxa_vpn#1529 shape)" "$(two_commits "$C2A")"

C2B=$(commit_obj "$T2" "dev@example.com" 2 "Merge branch 'main' into feature-x")
run_case 1 "MC-B 'Merge branch <quote>...' base merge is excluded (techrecon#826 shape)" "$(two_commits "$C2B")"

while IFS= read -r subj; do
  C2=$(commit_obj "$T2" "dev@example.com" 2 "$subj")
  run_case 1 "MC-C excluded base-merge subject: $subj" "$(two_commits "$C2")"
done <<'SUBJECTS'
Merge remote-tracking branch 'origin/main' into feature-x
Merge commit 'a1b2c3d4' into feature-x
Merge tag 'v1.2.0' into feature-x
Merge pull request #42 from acme/feature-x
SUBJECTS

while IFS= read -r subj; do
  C2=$(commit_obj "$T2" "dev@example.com" 2 "$subj")
  run_case 0 "MC-D counted as authored despite looking merge-like: $subj" "$(two_commits "$C2")"
done <<'SUBJECTS'
Merge branches 'topic-a' and 'topic-b'
Merge branch protection settings update
SUBJECTS

C2E=$(commit_obj "$T2" "noreply@github.com" 2 "Resolve merge conflicts via web editor")
run_case 1 "MC-E GitHub-committer-email gate excludes despite a non-enumerated subject" "$(two_commits "$C2E")"

run_case 1 "MC-F baseline: a single 1-parent commit, finding after it stays unaddressed [negative control]" "[$C1]"

echo
if [ "$failed" -ne 0 ]; then
  echo "FAILED"
  exit 1
fi
echo "PASSED"
