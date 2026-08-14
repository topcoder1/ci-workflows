#!/usr/bin/env bash
# Behavioral test for the three "is this really a bot's PR?" gates.
#
# INCIDENT (whois-api-llc/wxa-jake-ai#1064, 2026-08-13). A dependabot PR
# carried two commits:
#
#   890ef310  dependabot[bot]  bump prettier-plugin-tailwindcss 0.8.0->0.8.1
#   18bd99d0  topcoder1        hand-written, two files under src/routes/**
#
# `review / Claude Review` — a REQUIRED context on the repo's main ruleset —
# reported SUCCESS at 22:54:25Z->22:54:36Z. Eleven seconds, no diff read: the
# skip keyed on `pull_request.user.login`, which is fixed at open time and
# says nothing about who wrote the commits now on the branch. The PR merged
# at 22:57:59Z. Neither compensating control named in the skip message was
# present — the risk classifier is a classifier rather than a gate, and there
# was no human merge gate because auto-merge had been armed for the bump-only
# diff three days earlier and stayed armed across the later push.
#
# The content that landed was prettier output and was benign. The mechanism
# was not: any commit pushed onto any bot branch inherited a green required
# review, and (via the stale arm) a merge decision made about a version bump.
#
# THE INVARIANT, in one line: a skip must be earned by the COMMITS, not
# granted by the OPENER.
#
# This pins it in all three places the opener was trusted, by extracting each
# workflow's SHIPPED bash and executing it — not a mirrored copy — against a
# stubbed `gh` and, for regression-convention, a real throwaway git repo.
#
#   claude-review.yml         the required review itself
#   dependabot-auto-merge.yml the stale arm that let the merge proceed
#   regression-convention.yml same defect, same required-check status:
#                             a human could land a Lessons bullet with no
#                             paired regression test via any bot branch
#
# "Bot-authored" is deliberately a three-part test — author AND committer AND
# signature. Author alone is not enough: `--amend` and rebase PRESERVE the
# original author and rewrite only the committer, and a locally crafted commit
# can name any author it likes. Those two shapes are pinned below as
# `amend-spoof` and `crafted-unsigned`; both were live bypasses of the first
# cut of this fix (Codex round-1 P1).
#
# Every uncertain branch must fail CLOSED. For the two review gates that
# means "run the real review"; for the arm it means "revoke". Getting those
# wrong costs CI minutes or one human click. Getting them wrong the other way
# costs an unreviewed merge.
#
# Run from the repo root:
#   bash selftest/test_bot_skip_commit_authorship.sh
set -euo pipefail

REVIEW_WF=.github/workflows/claude-review.yml
MERGE_WF=.github/workflows/dependabot-auto-merge.yml
REGRESSION_WF=.github/workflows/regression-convention.yml

failed=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

pass() { echo "✓ $1"; }
fail() {
  echo "✗ $1"
  failed=1
}

extract_run() {
  local wf="$1" step_name="$2" out="$3"
  awk -v name="      - name: $step_name" '
    $0 == name { in_step = 1; next }
    in_step && /^        run: \|/ { in_run = 1; next }
    in_run {
      if ($0 ~ /^          / || $0 == "") { sub(/^          /, ""); print }
      else { exit }
    }
  ' "$wf" > "$out"
  if [ ! -s "$out" ]; then
    fail "could not extract '$step_name' from $wf — step renamed or reindented?"
    return 1
  fi
}

# Extract a single job's YAML block, for asserting on its `if:`/`needs:`.
extract_job() {
  awk -v job="  $1:" '$0 == job { p = 1; next } p && /^  [a-z]/ { exit } p' "$2"
}

# A `gh` stub. Behaviour is driven entirely by env vars so each scenario can
# describe an API shape without touching the stub.
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
echo "gh $*" >> "$GH_LOG"
case "${1:-}" in
  api)
    case "${2:-}" in
      */commits)
        if [ "${GH_API_FAIL:-0}" = "1" ]; then
          echo "HTTP 502: Bad Gateway" >&2
          exit 1
        fi
        cat "$GH_ROWS_FILE"
        ;;
      *)
        # PR head read, used by the revoke job's ownership guard.
        if [ "${GH_HEAD_FAIL:-0}" = "1" ]; then
          echo "HTTP 500: could not read PR" >&2
          exit 1
        fi
        echo "${GH_HEAD:-EVENTSHA}"
        ;;
    esac
    ;;
  pr)
    case "${2:-}" in
      comment) exit 0 ;;
      merge)   exit 0 ;;
      view)
        if [ "${GH_VIEW_FAIL:-0}" = "1" ]; then
          echo "HTTP 500: could not read PR" >&2
          exit 1
        fi
        echo "${GH_ARMED:-true}"
        ;;
      *) echo "STUB: unexpected 'gh pr ${2:-}'" >&2; exit 99 ;;
    esac
    ;;
  *) echo "STUB: unexpected 'gh ${1:-}'" >&2; exit 99 ;;
esac
STUB
chmod +x "$T/bin/gh"

# Rows are `author|committer|verified`, one per commit.
# A genuine dependabot commit is author=dependabot[bot], committer=web-flow,
# verified=true — measured on wxa-jake-ai#1063/#1064 and ci-workflows#136.
rows_genuine=$'dependabot[bot]|web-flow|true'
rows_renovate=$'renovate[bot]|web-flow|true'
rows_1064=$'dependabot[bot]|web-flow|true\ntopcoder1|topcoder1|false'
rows_human=$'topcoder1|topcoder1|false'
rows_amend=$'dependabot[bot]|topcoder1|false'          # human amended the bot's commit
rows_crafted=$'dependabot[bot]|dependabot[bot]|false'  # spoofed locally, unsigned
rows_unmapped=$'UNMAPPED|UNMAPPED|false'
# A DIFFERENT signed app appending to the bump. Signed and bot-authored, but
# not part of the dependency update and not what the arm was granted for.
rows_otherbot=$'dependabot[bot]|web-flow|true\ngithub-actions[bot]|web-flow|true'
rows_capped=$(awk 'BEGIN { for (i = 0; i < 250; i++) print "dependabot[bot]|web-flow|true" }')

# ===========================================================================
# 1. claude-review.yml — the required review.
#    Discriminator is `skipped=true` in GITHUB_OUTPUT. Both branches exit 0;
#    the exit code is NOT the signal (a nonzero here would fail the required
#    check itself, which is not what "run the review" means).
# ===========================================================================
extract_run "$REVIEW_WF" "Skip review for bot-authored PRs (dependabot/renovate)" "$T/review.sh" || true

if [ -s "$T/review.sh" ]; then
  if grep -q 'commits' "$T/review.sh" && grep -q 'NON_BOT' "$T/review.sh"; then
    pass "$REVIEW_WF decides from the PR's commit list, not the opener alone"
  else
    fail "$REVIEW_WF skip no longer inspects commit authorship — the #1064 regression"
  fi
  if grep -q 'committer' "$T/review.sh" && grep -q 'verification' "$T/review.sh"; then
    pass "$REVIEW_WF checks committer and signature, not just author"
  else
    fail "$REVIEW_WF checks author only — amended and crafted commits still inherit the skip"
  fi

  review_case() {
    local label="$1" rows="$2" expect="$3" api_fail="${4:-0}"
    printf '%s\n' "$rows" > "$T/rows"
    : > "$T/out"
    : > "$T/ghlog"
    local rc=0
    (
      PATH="$T/bin:$PATH" \
      GH_ROWS_FILE="$T/rows" GH_LOG="$T/ghlog" GH_API_FAIL="$api_fail" \
      GITHUB_OUTPUT="$T/out" GH_TOKEN=stub PR=1064 ACTOR='dependabot[bot]' \
      REPO='whois-api-llc/wxa-jake-ai' \
      bash "$T/review.sh"
    ) > "$T/stdout" 2>&1 || rc=$?

    local got=review
    grep -q '^skipped=true$' "$T/out" && got=skip

    if [ "$rc" -ne 0 ]; then
      fail "review/$label: step exited $rc — a required check must not go red here"
      sed 's/^/    /' "$T/stdout"
      return
    fi
    if [ "$got" = "$expect" ]; then
      pass "review/$label -> $got"
    else
      fail "review/$label -> $got (expected $expect)"
      sed 's/^/    /' "$T/stdout"
    fi
  }

  review_case "genuine dependabot bump"          "$rows_genuine"  skip
  review_case "genuine renovate bump"            "$rows_renovate" skip
  review_case "THE #1064 SHAPE: bot + human"     "$rows_1064"     review
  review_case "human-only commits"               "$rows_human"    review
  review_case "amend-spoof: bot author, human committer" "$rows_amend"   review
  review_case "crafted-unsigned: both spoofed"   "$rows_crafted"  review
  review_case "third-party signed bot commit"    "$rows_otherbot" review
  review_case "author unmapped to an account"    "$rows_unmapped" review
  review_case "250-commit API cap reached"       "$rows_capped"   review
  review_case "commit list empty"                ""               review
  review_case "commit API unreachable"           "$rows_genuine"  review 1

  # A skip must be announced. Silent skips are how this went unnoticed.
  printf '%s\n' "$rows_genuine" > "$T/rows"
  : > "$T/out"; : > "$T/ghlog"
  (
    PATH="$T/bin:$PATH" \
    GH_ROWS_FILE="$T/rows" GH_LOG="$T/ghlog" GH_API_FAIL=0 \
    GITHUB_OUTPUT="$T/out" GH_TOKEN=stub PR=1064 ACTOR='dependabot[bot]' \
    REPO='whois-api-llc/wxa-jake-ai' \
    bash "$T/review.sh"
  ) > /dev/null 2>&1 || true
  if grep -q '^gh pr comment' "$T/ghlog"; then
    pass "review/skip is announced on the PR"
  else
    fail "review/skip posted no comment — a silent skip is indistinguishable from a review"
  fi
fi

# ===========================================================================
# 2. dependabot-auto-merge.yml
#
#    2a. Structure. The arm and the revoke must be ORDERED, not racing. As
#        two independent top-level jobs, a dependabot push to an
#        already-human-touched branch could have the arming job re-arm while
#        the revoke job read "no arm present" and exited. (Codex round-1 P1.)
# ===========================================================================
merge_job=$(extract_job auto-merge "$MERGE_WF")
revoke_job=$(extract_job revoke-stale-arm "$MERGE_WF")

if [ -n "$revoke_job" ]; then
  pass "$MERGE_WF has a revoke job"
else
  fail "$MERGE_WF has no revoke job — an arm outlives the diff it was granted for"
fi

if printf '%s' "$merge_job" | grep -q 'needs: \[authorship\]' \
  && printf '%s' "$merge_job" | grep -q "needs.authorship.outputs.non_bot == '0'"; then
  pass "$MERGE_WF refuses to ARM a PR carrying non-bot commits (fix at the source)"
else
  fail "$MERGE_WF still arms without consulting commit authorship"
fi

if printf '%s' "$revoke_job" | grep -q 'needs: \[authorship, auto-merge\]' \
  && printf '%s' "$revoke_job" | grep -q 'always()'; then
  pass "$MERGE_WF revoke is ordered after the arm (needs + always) — no arm/revoke race"
else
  fail "$MERGE_WF revoke does not depend on the arming job — they can race"
fi

# `needs:` only orders jobs WITHIN a run. Across runs, an older dependabot run
# that classified the pre-push head can still reach the arm step after a human
# push. Binding the arm to the classified SHA is what closes that.
if printf '%s' "$merge_job" | grep -q -- '--match-head-commit'; then
  pass "$MERGE_WF binds the arm to the classified head SHA — a stale run cannot re-arm"
else
  fail "$MERGE_WF arm is not bound to a head SHA — an overlapping run can arm a since-pushed PR"
fi

# The arming job's `github.actor` gate is precisely what blinds it to the
# human push. A revoke job reusing that gate would reproduce the bug.
if printf '%s' "$revoke_job" | grep -q 'github.actor'; then
  fail "$MERGE_WF revoke is gated on github.actor — blind to the human push, same as the arming job"
else
  pass "$MERGE_WF revoke is not gated on github.actor"
fi

# `gh pr merge --disable-auto` needs contents write. Without it the revoke
# fails and the stale arm survives — the job would exist but not work.
if printf '%s' "$revoke_job" | grep -q 'contents: write'; then
  pass "$MERGE_WF revoke job has contents: write — --disable-auto can actually run"
else
  fail "$MERGE_WF revoke job lacks contents: write — --disable-auto may fail, leaving the arm"
fi

# Scope: this workflow only ever ARMS dependabot PRs, so it must not DISARM a
# renovate PR — that arm belongs to safe-paths-automerge or a human.
if printf '%s' "$revoke_job" | grep -q "user.login == 'dependabot\[bot\]'"; then
  pass "$MERGE_WF revoke is scoped to dependabot — cannot revoke another workflow's arm"
else
  fail "$MERGE_WF revoke fires on any [bot] PR — may revoke an arm it never granted"
fi

# 2b. The shared classifier's behaviour.
extract_run "$MERGE_WF" "Count non-bot commits" "$T/scan.sh" || true

if [ -s "$T/scan.sh" ]; then
  scan_case() {
    local label="$1" rows="$2" expect="$3" api_fail="${4:-0}"
    printf '%s\n' "$rows" > "$T/rows"
    : > "$T/out"
    : > "$T/ghlog"
    local rc=0
    (
      PATH="$T/bin:$PATH" \
      GH_ROWS_FILE="$T/rows" GH_LOG="$T/ghlog" GH_API_FAIL="$api_fail" \
      GITHUB_OUTPUT="$T/out" GH_TOKEN=stub PR=1064 \
      REPO='whois-api-llc/wxa-jake-ai' \
      bash "$T/scan.sh"
    ) > "$T/stdout" 2>&1 || rc=$?

    if [ "$rc" -ne 0 ]; then
      fail "scan/$label: exited $rc — the classifier must never fail, it reports uncertainty as non_bot=1"
      sed 's/^/    /' "$T/stdout"
      return
    fi
    local got
    got=$(sed -n 's/^non_bot=//p' "$T/out" | tail -1)
    # Consumers compare against the literal '0'; anything else means "arm-ineligible".
    local verdict=arm-ineligible
    [ "$got" = "0" ] && verdict=bot-only
    if [ "$verdict" = "$expect" ]; then
      pass "scan/$label -> $verdict (non_bot=$got)"
    else
      fail "scan/$label -> $verdict (non_bot=$got), expected $expect"
      sed 's/^/    /' "$T/stdout"
    fi
  }

  scan_case "genuine dependabot bump"         "$rows_genuine"  bot-only
  scan_case "THE #1064 SHAPE: bot + human"    "$rows_1064"     arm-ineligible
  scan_case "amend-spoof"                     "$rows_amend"    arm-ineligible
  scan_case "crafted-unsigned"                "$rows_crafted"  arm-ineligible
  scan_case "third-party signed bot commit"   "$rows_otherbot" arm-ineligible
  scan_case "author unmapped to an account"   "$rows_unmapped" arm-ineligible
  scan_case "250-commit API cap reached"      "$rows_capped"   arm-ineligible
  scan_case "commit list empty"               ""               arm-ineligible
  scan_case "commit API unreachable"          "$rows_genuine"  arm-ineligible 1
fi

# 2c. The revoke step itself. Gating is the job `if:` asserted above; this
#     step's job is to act only when an arm exists, and to fail loudly rather
#     than read an unreadable state as "no arm".
extract_run "$MERGE_WF" "Revoke the arm if a non-bot commit is present" "$T/revoke.sh" || true

if [ -s "$T/revoke.sh" ]; then
  revoke_case() {
    local label="$1" expect="$2" armed="${3:-true}" view_fail="${4:-0}" \
      head="${5:-EVENTSHA}" head_fail="${6:-0}"
    : > "$T/ghlog"
    local rc=0
    (
      PATH="$T/bin:$PATH" \
      GH_LOG="$T/ghlog" GH_ARMED="$armed" GH_VIEW_FAIL="$view_fail" \
      GH_HEAD="$head" GH_HEAD_FAIL="$head_fail" HEAD_SHA=EVENTSHA \
      GH_TOKEN=stub PR=1064 ACTOR='dependabot[bot]' NON_BOT=1 \
      REPO='whois-api-llc/wxa-jake-ai' \
      bash "$T/revoke.sh"
    ) > "$T/stdout" 2>&1 || rc=$?

    local got=keep
    grep -q '^gh pr merge --disable-auto' "$T/ghlog" && got=revoke
    [ "$rc" -ne 0 ] && got=error

    if [ "$got" = "$expect" ]; then
      pass "revoke/$label -> $got"
    else
      fail "revoke/$label -> $got (expected $expect)"
      sed 's/^/    /' "$T/stdout"
    fi
  }

  revoke_case "arm present"              revoke
  # Idempotence: synchronize fires on every push to a human-touched bot branch.
  revoke_case "no arm present"           keep   false
  # An unreadable auto-merge state must not read as "no arm".
  revoke_case "auto-merge state unreadable" error true 1
  # Ownership: a dependabot rebase can restore a bot-only head and validly
  # re-arm. This older run must not disarm it — nothing would re-arm it.
  revoke_case "head moved since this event" keep true 0 NEWERSHA
  # ...but only on a POSITIVE head-moved read. An unreadable head fails
  # toward safety and still revokes.
  revoke_case "head read failed"         revoke true 0 EVENTSHA 1

  : > "$T/ghlog"
  (
    PATH="$T/bin:$PATH" \
    GH_LOG="$T/ghlog" GH_ARMED=true GH_VIEW_FAIL=0 GH_HEAD=EVENTSHA \
    GH_HEAD_FAIL=0 HEAD_SHA=EVENTSHA GH_TOKEN=stub PR=1064 \
    ACTOR='dependabot[bot]' NON_BOT=1 REPO='whois-api-llc/wxa-jake-ai' \
    bash "$T/revoke.sh"
  ) > /dev/null 2>&1 || true
  if grep -q '^gh pr comment' "$T/ghlog"; then
    pass "revoke/explains itself on the PR"
  else
    fail "revoke/silently disarmed — the author gets no idea why it stopped merging"
  fi
fi

# ===========================================================================
# 3. regression-convention.yml — same defect, real git.
#    This gate reads git rather than the API (its checkout is fetch-depth: 0),
#    so drive the shipped script against a throwaway repo whose commits carry
#    the authorship under test.
# ===========================================================================
extract_run "$REGRESSION_WF" "Check lessons-vs-regression-tests contract" "$T/regression.sh" || true

if [ -s "$T/regression.sh" ]; then
  if grep -q 'NON_BOT_COMMITS' "$T/regression.sh" && grep -q '%cn' "$T/regression.sh"; then
    pass "$REGRESSION_WF decides from commit author AND committer, not the opener"
  else
    fail "$REGRESSION_WF skip no longer inspects commit authorship — the #1064 regression"
  fi

  # $1 label, $2 who writes the lesson: bot|human|amend, $3 test|notest,
  # $4 expected exit code
  regression_case() {
    local label="$1" who="$2" with_test="$3" expect_rc="$4"
    local repo="$T/repo-$RANDOM$RANDOM"
    mkdir -p "$repo"
    (
      cd "$repo"
      git init -q -b main .
      # A genuine bot commit: author dependabot[bot], committer GitHub.
      git config user.email 'noreply@github.com'
      git config user.name 'GitHub'
      mkdir -p tests/regression
      printf '## Lessons\n\n- existing bullet\n\n## Other\n\ntail\n' > CLAUDE.md
      git add -A
      git commit -q --author='dependabot[bot] <49699333+dependabot[bot]@users.noreply.github.com>' -m 'base'

      printf 'dep: 0.8.1\n' > package.json
      git add -A
      git commit -q --author='dependabot[bot] <49699333+dependabot[bot]@users.noreply.github.com>' -m 'bump'

      # The commit that adds a Lessons bullet, authored by whoever is on test.
      printf '## Lessons\n\n- existing bullet\n- NEW bullet about a real bug\n\n## Other\n\ntail\n' > CLAUDE.md
      if [ "$with_test" = "test" ]; then
        printf 'def test_it():\n    assert True\n' > tests/regression/test_new.py
      fi
      git add -A
      case "$who" in
        bot)
          git commit -q --author='dependabot[bot] <49699333+dependabot[bot]@users.noreply.github.com>' -m 'lesson'
          ;;
        human)
          git -c user.name='Jonathan Zhang' -c user.email='jz@example.invalid' \
            commit -qm 'lesson'
          ;;
        amend)
          # The bypass: a human amends/rebases the bot's commit. Git PRESERVES
          # the bot author and records the human only as committer.
          git -c user.name='Jonathan Zhang' -c user.email='jz@example.invalid' \
            commit -q --author='dependabot[bot] <49699333+dependabot[bot]@users.noreply.github.com>' \
            -m 'lesson'
          ;;
      esac
    )

    local base head rc=0
    base=$(git -C "$repo" rev-parse main~2)
    head=$(git -C "$repo" rev-parse main)
    (
      cd "$repo"
      LESSONS_FILES_RAW='CLAUDE.md' LESSONS_HEADER='## Lessons' \
      REGRESSION_DIR='tests/regression' BASE_SHA="$base" HEAD_SHA="$head" \
      PR_AUTHOR='dependabot[bot]' \
      PR_HEAD_BRANCH='dependabot/npm_and_yarn/prettier-plugin-tailwindcss-0.8.1' \
      bash "$T/regression.sh"
    ) > "$T/stdout" 2>&1 || rc=$?

    if [ "$rc" -eq "$expect_rc" ]; then
      pass "regression/$label -> exit $rc"
    else
      fail "regression/$label -> exit $rc (expected $expect_rc)"
      sed 's/^/    /' "$T/stdout"
    fi
  }

  # Unchanged behaviour: a genuine all-bot PR still skips. Bots cannot add
  # paired regression tests, which is the whole reason the skip exists.
  regression_case "all-bot PR still skips"                bot   notest 0
  # THE FIX: a human riding a bot branch is held to the convention...
  regression_case "human lesson on a bot branch, no test" human notest 1
  # ...including when they amend, which preserves the bot as author...
  regression_case "amend-spoof lesson, no test"           amend notest 1
  # ...and is not merely blocked — satisfying the convention still passes.
  regression_case "human lesson on a bot branch, w/ test" human test   0
fi

# ---------------------------------------------------------------------------
if [ "$failed" -eq 0 ]; then
  echo
  echo "ALL PASS: a skip is earned by the commits, not granted by the opener."
else
  echo
  echo "FAILURES above."
fi
exit "$failed"
