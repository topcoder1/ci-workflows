#!/usr/bin/env bash
# VENDORED TWIN — the canonical operator-CLI copy lives in topcoder1/dotclaude
# at templates/ci-workflows/scripts/bb-unaddressed-findings.sh. THIS copy is
# what claude-author-automerge.yml's quiet+findings gate fetches at runtime
# from this repo's default branch (the same fetch pattern as
# .github/scripts/classify.mjs). Keep the two byte-identical below this header
# block when either changes: the operator sweep and the automerge gate must
# flag the same findings, or a PR the sweep flags will have already armed.
#
# bb-unaddressed-findings: detect review findings that landed AFTER the last
# commit — i.e. nothing was pushed in response to them.
#
# Why: review bots post findings continuously, but a PR can be merged seconds
# later. Two defects reached main this way (techrecon#655, ipgeo_core#168 —
# inline findings 41s and 22s before a human click-merge) and both stayed live
# for days. Required-check machinery cannot catch this: the fleet rulesets run
# `required_approving_review_count: 0` and the review bot only has
# `create_inline_comment` + `gh pr comment`, so a finding can never block a
# merge. Detection is the available lever.
#
# Signal: an INLINE review comment newer than the newest commit. Inline comments
# are reserved for "issues you're 80%+ sure are real bugs" (claude-review.yml
# prompt), so they carry far less noise than top-level summaries — the bot posts
# a top-level line on every run, including "No issues found". Top-level comments
# count only when they match a finding marker and no clean marker.
#
# Usage:
#   bb-unaddressed-findings <owner/repo> <pr-number>
#   bb-unaddressed-findings --scan <owner/repo> [merged-pr-count]   # post-merge sweep
#   bb-unaddressed-findings --fixture <dir> <owner/repo> <pr-number> # offline (tests)
#
# Fixture dir (testing seam) holds: meta.json (single PR object with
# .merged_at + .last_commit), inline.json, issue.json, and optionally
# timeline.json — same shapes the REST API returns.
#
# Exit codes:
#   0 — no unaddressed findings
#   1 — unaddressed findings present
#   2 — invocation error

set -uo pipefail

FIXTURE=""
SCAN=""
if [[ "${1:-}" == "--fixture" ]]; then
  FIXTURE="${2:-}"; shift 2
elif [[ "${1:-}" == "--scan" ]]; then
  SCAN=1; shift
fi

REPO="${1:-}"
PR="${2:-}"

if [[ -z "$REPO" ]] || { [[ -z "$SCAN" ]] && [[ -z "$PR" ]]; }; then
  echo "usage: $0 <owner/repo> <pr-number> | $0 --scan <owner/repo> [count]" >&2
  exit 2
fi

if ! command -v jq >/dev/null; then
  echo "error: jq required" >&2; exit 2
fi
if [[ -z "$FIXTURE" ]] && ! command -v gh >/dev/null; then
  echo "error: gh required" >&2; exit 2
fi

if [[ -t 1 ]]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
  RED=''; GREEN=''; BOLD=''; DIM=''; RESET=''
fi

# A top-level comment is a finding only if it announces one and is not a
# clean/skip summary. Inline comments need no such filter.
# NOTE what is NOT here: `^### Codex review`. That header opens 100% of codex
# comments, passes included, so it cannot discriminate within the population it
# matches — it made every clean review a finding that CLEAN_RE then had to
# rescue BY NAME, and a free-form model verdict cannot be enumerated (measured
# 2026-07-31: wxa_vpn #1366/#1360/#1358 were still falsely flagged a day after
# CLEAN_RE was widened, each a pass phrased in prose no marker knew). Removing
# the non-signal deletes the rescue problem rather than lengthening the list.
#
# Codex's finding forms are therefore named explicitly, because its mandated
# regression shape carries no P-token at all (wxa-mcp-server #374/#369/#384) and
# would otherwise have gone silent along with the header.
#
# P0 is in the range because it was previously detected only INCIDENTALLY, by
# the header rather than by its own severity — dropping the header without this
# would have blinded the most urgent class of finding. P3 stays out: widening
# upward from P1 costs nothing, widening downward re-admits nits.
#
# Matched CASE-INSENSITIVELY, like CLEAN_RE and SEVERITY_RE and for the same
# reason — these are model-written words, not literals a workflow prints. It
# matters more here than anywhere else now: with the header gone this is the
# sole admission gate, so a lowercased `verdict: regression` that fails to match
# is not a comment classified wrongly, it is a comment never examined at all.
# The `regression:` marker matches its path by SHAPE, not by a `file:line`
# literal. Demanding the `:LINE` suffix — via a `\S+` a backtick also breaks —
# is what made this script report "no unaddressed findings" on
# whois-api-llc/wxa-jake-ai#1054. claude[bot] posted, 3m41s after the last
# commit and 1m23s before the merge:
#
#   regression: `tests/ci/prod-model-health-author-scope.test.ts` — no test pins
#   the cron schedule value `7,22,37,52 * * * *` ...
#
# The path was BACKTICKED and carried NO line number, so `\S+:[0-9]+` matched
# nothing, the comment never reached CLEAN_RE, and the PR merged with the
# finding live. Both deviations are ordinary: the path a finding names is often
# a whole file rather than a line in one, and both bots write paths in code
# spans.
#
# The replacement still demands a PLAUSIBLE SOURCE PATH IN LABEL POSITION — two
# independent constraints, and both are load-bearing. This is the sole
# admission gate, so a marker that accepted any prose after `regression:` would
# flag every comment containing the word; a sweeper that cries wolf gets
# ignored, which costs strictly more than the miss it fixes.
#
#   1. PATH SHAPE. The unbroken run of non-space characters starting
#      immediately after `regression:` must carry ONE of three signals: a `/`,
#      a `.` followed by a LETTER (an extension), or a `:LINE` suffix on a
#      token that starts with a letter. Admits `main.go:267`,
#      `docs/package.json:13`, `.github/workflows/x.yml:96`,
#      `` `tests/ci/x.test.ts` ``, the extensionless `scripts/deploy` and the
#      root-level `Dockerfile:12`; rejects `regression: none`,
#      `regression: nothing to report`, `regression: 3.2 seconds slower`.
#
#      The `:LINE` signal is not decoration — it is what the ORIGINAL marker
#      relied on exclusively, so dropping it would have traded this bug for its
#      mirror image: codex caught `regression: Dockerfile:12` and
#      `regression: Makefile:8` going dark, root-level extensionless files that
#      the old expression matched and the first two shapes do not. Requiring a
#      leading letter keeps `12:30` (a time, not a path) out.
#
#      Residual, and deliberately so: a root-level extensionless file with NO
#      line number (`regression: Dockerfile — the base image is stale`) carries
#      none of the three signals and is missed. It is indistinguishable from a
#      bare word without an allowlist of famous filenames, and the pre-fix
#      marker missed it too — this change is strictly additive here.
#      `n/a` is excluded BY NAME because it is the one empty-bucket token whose
#      own slash satisfies the shape test — `_NOT_EMPTY` below already treats it
#      as empty for the P-labels, and codex raised the inconsistency reviewing
#      this change. The other empty tokens need no naming: they carry neither a
#      slash nor a dotted extension, so the shape test rejects them already.
#
#   2. LABEL POSITION. The marker must OPEN its line, after nothing but
#      MARKDOWN BLOCK MARKERS — the same rule LGTM and the `[P2]` labels follow
#      below, and the line format codex's own prompt mandates
#      (`regression: <file:line> - <sentence>`). Allowed prefixes, in any
#      combination and any nesting, each optionally indented:
#
#        >   blockquote, nested as `>>` or `> >`
#        -   bullet, also `*` and `+`
#        1.  numbered list, also `1)`
#        #   heading, `#` through `######`
#        **  bold, around the word itself (`**regression:**`)
#
#      so `regression:`, `- regression:`, `1. regression:`, `### regression:`,
#      `> regression:` and `> 1. **regression:**` all qualify. The FIRST cut of
#      this anchor allowed only a bullet or bold and silently dropped the other
#      four — a narrower version of the very bug it shipped alongside, in the
#      fleet's only post-merge findings detector. Bots write findings as
#      numbered lists and under headings routinely; two independent reviews
#      caught the drop before it merged.
#
#      What the prefix alphabet deliberately excludes is WORDS, and that is the
#      whole mechanism for rejecting NEGATED uses, which shape 1 cannot see:
#      codex's review OF THIS CHANGE produced "No regression: package.json is
#      unchanged", a clean summary CLEAN_RE does not recognise (it knows only
#      the plural "No regressions found") and that SEVERITY_RE would then
#      override anyway — a false "do not merge yet" on a pass. Every negation
#      phrasing puts a word between the line start and the marker ("No ",
#      "Not a ", "the diff shows no "), so all of them are answered at once —
#      including quoted and numbered ones ("> No regression:", "1. No
#      regression:") — without parsing English negation, which the note below
#      explains does not converge.
#
#      The prefix loop repeats SINGLE characters (`>`, `#`) rather than runs
#      (`>+`, `#{1,6}`), and holds trailing whitespace outside the loop. This is
#      not style. A repeated group whose body also repeats is the classic
#      `(a+)+` shape: a run of N markers has 2^(N-1) partitions, and Oniguruma
#      walks them all before failing. Measured with `>+`/`#{1,6}` on this exact
#      marker, a body of 20 `>` then `regression: none` aborts jq with "Regex
#      failure: retry-limit-in-match over" — and because the jq calls below send
#      stderr to /dev/null, the abort empties the finding list and the sweeper
#      reports "no unaddressed findings". A silent false negative, in the
#      detector whose entire job is to not have those. Repeating one character
#      makes the parse unique: iterations equal marker characters, nothing to
#      backtrack over. Runs of `>` are ordinary in bot comments (nested quoted
#      replies; a pasted conflict marker is seven).
#
# Both observed burn bodies satisfy the anchor: #1054 opens with the marker,
# #1067 puts it on its own line beneath a bold header.
#
# Backticks are optional and sit OUTSIDE the captured path; `:LINE` is optional.
# Shared with SEVERITY_RE below so the admission gate and the clean-marker
# override can never disagree about what a regression line looks like.
_REGRESSION_MARKER='(^|\n)([[:space:]]*(>|[-*+]|[0-9]+[.)]|#))*[[:space:]]*\**regression:\**[[:space:]]*`?(?!n/a\b)(?=[^[:space:]`]*(/|\.[A-Za-z])|[A-Za-z_][A-Za-z0-9_.@+-]*:[0-9])[A-Za-z0-9_./@+-]+(:[0-9]+)?'
FINDING_RE="([Ff]lagged [0-9]+ issue|\bP[012]\b|VERDICT: REGRESSION|${_REGRESSION_MARKER})"
# With the header gone from FINDING_RE, CLEAN_RE no longer has to rescue every
# codex pass — those now never match a finding marker in the first place. What
# still reaches it is the LOOSE `\bP[012]\b` alternative, which a clean summary
# trips whenever it names the severities it did not find ("No P1/P2 issues
# found"). CLEAN_RE suppresses those; SEVERITY_RE below decides when a clean
# phrase is contradicted and must be overridden.
#
# A clean verdict landing after the last commit is the DESIRED end state of the
# iterate-until-clean protocol, not a reason to withhold a merge; a sweeper that
# cries wolf gets ignored, which costs exactly as much as not having one.
# Measured 2026-07-30 on wxa_vpn: 6 of the last 15 merged PRs were flagged, 4 of
# them falsely (#1364/#1341/#1343 clean verdicts plus a pr-classify comment);
# wxa-mcp-server#376 was the same shape.
#
# Matched CASE-INSENSITIVELY (see the `test(...; "i")` calls below). These are
# model-generated prose, not literals a workflow prints: README.md documents the
# pass verdict as lowercase `no regressions found` while every body observed live
# capitalises it, and the same drift applies to the `VERDICT:` trailer.
#
# LGTM is the one entry anchored to the start of a line. Every other marker is a
# phrase carrying its own polarity — "No issues found" cannot be negated into a
# finding — whereas LGTM is a bare token, so an unanchored substring test reads
# "Not LGTM: authentication can be bypassed" as a pass and buries an explicitly
# negative review. Same rule as the severity side below: a verdict counts when it
# OPENS its line, not when it turns up inside a sentence.
CLEAN_RE='(No issues found|Skipped:|Bugbot is not enab|Coverage Floor|claude-author-automerge|VERDICT: CLEAN|No regressions found|(^|\n)[[:space:]]*\**LGTM\b|<!-- pr-classify)'

# CLEAN_RE suppresses on SUBSTRING, so a clean phrase anywhere cancels the whole
# comment — and the codex prompt scopes each review to "three axes ONLY", which
# invites exactly the body that passes two axes and itemizes a real finding on
# the third. SEVERITY_RE re-flags those: an asserted finding outranks any clean
# phrasing around it, including a VERDICT: CLEAN trailer the items above it
# contradict. Verified across 45 merged PRs that routine chatter — Coverage
# Floor, automerge, pr-classify, Bugbot, skip notices — carries none of these
# markers, so the override cannot resurrect the false positives above.
#
# What counts as ASSERTED is decided by STRUCTURE, not by wording:
#
#   * a LABEL IN LABEL POSITION — `[P2]`, `**P2**` or `P2 —` opening its own
#     line, optionally bulleted — or `P2:` anywhere. This is how codex emits
#     findings ("- [P2] Title — file:lines"), and why the bracket form is
#     anchored: "No [P1] or [P2] issues found" is a disclaimer in a label's
#     clothes. A severity mid-sentence in prose is mentioned, not asserted.
#   * ...FOLLOWED BY CONTENT, since an empty bucket is in label position and
#     means the opposite of one. The requirement is positive, so a bare "P1:"
#     or "- [P1]" needs no phrase in any list; only buckets that are non-empty
#     yet say nothing ("none", "0 findings") are named, and that list never
#     includes a bare leading "no" — "P2: no test exercises the new error path"
#     is the most ordinary finding codex writes. Content means any NON-BLANK
#     character, not an alphanumeric: titles are routinely Markdown
#     ("- [P1] **Authentication bypass**", "P2: `handler` accepts ...").
#   * codex's own regression markers, which carry NO P-token at all
#     (wxa-mcp-server#374, #369 are `regression: <file:line>` bodies). Without
#     them a scoped "No regressions found on axis A" would suppress a real
#     regression line on axis B. Shape only — the line number is optional and
#     the path may be backticked; see _REGRESSION_MARKER above for why.
#   * a severity introduced by a CONTRAST conjunction ("No issues found on
#     coverage, but P1 unscoped token reaches push"), the one prose form that
#     is an assertion: clean phrase and finding share a sentence, and only the
#     conjunction marks the turn. Being a POSITIVE signal it adds no negation
#     parsing; its inner guard declines to fire on "but no P1 issues remain".
#
# The alternative — deciding this by parsing English negation — does not
# converge. "No P1/P2 issues", "Neither P1 nor P2" and "0 P1/P2 issues" each
# need their own rule, and "not validated, making this P1" INVERTS it: a real
# finding whose prose happens to contain a negation. Three review rounds chased
# those before this rewrite; the structural test answers all of them at once.
#
# Residual gap: a bot that asserts a finding ONLY in unstructured prose while
# also emitting a clean marker, no VERDICT: REGRESSION and no `regression:`
# line. Codex itemizes and stamps a trailer, so this is narrow — but do NOT
# assume claude[bot] findings always arrive as inline comments (which this
# filter never touches: author-agnostic, no clean-marker check at all). On
# wxa-jake-ai#1054 claude[bot] posted its finding TOP-LEVEL, as a `regression:`
# line, with zero inline comments on the PR. The top-level path is load-bearing
# for both bots. A live instance of the residual gap: the codex comment on that
# same PR ("No regression found. Missing coverage: no test pins the new cron
# expression at `...yml:63`") is a real finding phrased with no marker at all,
# and it is still missed — closing it means matching bare prose, which is the
# trade this design deliberately refuses.
_NOT_EMPTY='(?![[:blank:]]*(none|nothing|n/a|not applicable|no findings|no issues|(0|zero)[[:blank:]]+(finding|issue)s?)\b)[[:blank:]]*[^[:space:]]'
SEVERITY_RE="(\bP[012]:${_NOT_EMPTY}|(^|\n)[[:space:]]*([-*+][[:space:]]*)?(\[P[012]\]|\*\*P[012]\*\*|P[012][[:space:]]*[-—:])${_NOT_EMPTY}|\b(but|however|except|although|though|yet)\b((?!\b(no|not|zero|none|neither|without)\b)[^.!?\n]){0,30}?\bP[012]\b|flagged [1-9][0-9]* issue|VERDICT: REGRESSION|${_REGRESSION_MARKER})"

# The "last commit" a finding is measured against must be a commit that could
# plausibly ANSWER it — i.e. one carrying the author's changes. `auto-update-branch`
# merges main into every open PR on each push to main, and those merge commits
# post-date any outstanding finding, silently resetting this comparison.
#
# 2026-08-06, techrecon#826: a real inline finding at 02:16:05Z (an operator-facing
# log.Fatalf citing a reason its own adjacent comment says is obsolete) was followed
# by FOUR `Merge branch 'main' into ...` commits and nothing else. This script
# reported "no unaddressed findings", and the PR merged at 03:34:17Z with the
# message still wrong on main. Excluding merge commits (parents >= 2) is the fix:
# a base merge introduces no authored change, so it cannot address a review finding.
#
# `// empty` rather than `// null`: a PR whose only commits are merges yields no
# usable value, which must fall through to the hard error below (fail closed),
# not compare as the string "null".
LAST_COMMIT_JQ='[.[] | select((.parents | length) < 2) | .commit.committer.date] | max // empty'

# check_pr <repo> <pr> -> prints report, returns 0 clean / 1 findings
check_pr() {
  local repo="$1" pr="$2"
  local meta inline issue last merged commits

  if [[ -n "$FIXTURE" ]]; then
    meta=$(cat "$FIXTURE/meta.json" 2>/dev/null) || { echo "error: bad fixture dir" >&2; exit 2; }
    inline=$(cat "$FIXTURE/inline.json" 2>/dev/null || echo '[]')
    issue=$(cat "$FIXTURE/issue.json" 2>/dev/null || echo '[]')
    # commits.json (raw REST shape) exercises the same reduction the live path
    # uses, including the merge-commit filter. meta.json's precomputed
    # last_commit remains supported so existing fixtures keep working.
    if [[ -f "$FIXTURE/commits.json" ]]; then
      last=$(jq -r "$LAST_COMMIT_JQ" < "$FIXTURE/commits.json")
    else
      last=$(printf '%s' "$meta" | jq -r '.last_commit')
    fi
    merged=$(printf '%s' "$meta" | jq -r '.merged_at // "null"')
  else
    # Fail CLOSED on any gh failure. This is a pre-merge gate, so "clean
    # because the API was unreachable" is the one answer it must never give.
    # The `|| echo '[]'` these replaced did exactly that.
    if ! commits=$(gh api "repos/$repo/pulls/$pr/commits" --paginate 2>/dev/null); then
      echo "error: gh api failed listing commits for $repo#$pr (auth? network?)" >&2; exit 2
    fi
    last=$(printf '%s' "$commits" | jq -r "$LAST_COMMIT_JQ")
    if ! merged=$(gh api "repos/$repo/pulls/$pr" --jq '.merged_at // "null"' 2>/dev/null); then
      echo "error: gh api failed reading $repo#$pr (auth? network?)" >&2; exit 2
    fi
    if ! inline=$(gh api "repos/$repo/pulls/$pr/comments" --paginate 2>/dev/null); then
      echo "error: gh api failed listing inline comments for $repo#$pr (auth? network?)" >&2; exit 2
    fi
    if ! issue=$(gh api "repos/$repo/issues/$pr/comments" --paginate 2>/dev/null); then
      echo "error: gh api failed listing issue comments for $repo#$pr (auth? network?)" >&2; exit 2
    fi
  fi

  # `gh api --paginate --jq` applies the filter to EACH page and concatenates,
  # so `max` over a >30-commit PR emits one timestamp per page and `$last`
  # arrives multi-line. Reduce again here — ISO-8601 Z sorts chronologically —
  # so a single value reaches the comparison either way. Both branches share
  # this so the fixture path exercises the same reduction.
  last=$(printf '%s\n' "$last" | grep -v '^$' | sort | tail -1)
  if [[ -z "$last" || "$last" == "null" ]]; then
    echo "error: could not resolve last commit for $repo#$pr" >&2; exit 2
  fi
  # SHAPE, not just emptiness. 2026-08-05: with an expired token `gh api --jq`
  # printed the error BODY to stdout, the filter failed, and the raw JSON flowed
  # through — `sort | tail -1` picked "}", which is neither empty nor "null", so
  # the check above passed. Every comment then compared as older than "}" and two
  # PRs reported "no unaddressed findings" while the API was returning 401. The
  # exit-status checks above close that specific hole; this closes the class,
  # for any future path that yields a non-timestamp.
  if [[ ! "$last" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2} ]]; then
    echo "error: last-commit timestamp for $repo#$pr is not ISO-8601 (got: ${last:0:60})" >&2; exit 2
  fi

  # A comment stream spanning pages arrives as concatenated arrays; jq handles
  # each as an independent input and the per-page results concatenate, so no
  # reduction is needed for those.

  # Inline comments strictly newer than the newest commit.
  local late_inline
  late_inline=$(printf '%s' "$inline" | jq -r --arg last "$last" '
    [ .[] | select(.created_at > $last) ]
    | .[] | [.created_at, .user.login, (.path // "-"),
             ((.body // "") | gsub("\n"; " ") | .[0:90])] | @tsv' 2>/dev/null)

  # Top-level findings count only from review BOTS. Humans post round-summary
  # comments ("REVIEW-LOOP: round 7 — 1 finding, fixed in 2a5937e") that match
  # the finding markers while actually reporting a FIX — counting those cost a
  # false positive on wxa-secrets#27. Inline comments stay author-agnostic: a
  # human's inline comment is a deliberate code-level finding either way.
  local late_issue
  late_issue=$(printf '%s' "$issue" | jq -r --arg last "$last" \
                 --arg find "$FINDING_RE" --arg clean "$CLEAN_RE" \
                 --arg sev "$SEVERITY_RE" '
    [ .[] | select(.created_at > $last)
          | select(.user.login | endswith("[bot]"))
          | select((.body // "") | test($find; "i"))
          | select((((.body // "") | test($clean; "i")) | not)
                   or ((.body // "") | test($sev; "i"))) ]
    | .[] | [.created_at, .user.login, "-",
             ((.body // "") | gsub("\n"; " ") | .[0:90])] | @tsv' 2>/dev/null)

  local all
  all=$(printf '%s\n%s' "$late_inline" "$late_issue" | grep -v '^$' || true)

  if [[ -z "$all" ]]; then
    printf '%s%s#%s%s — %sno unaddressed findings%s (last commit %s)\n' \
      "$BOLD" "$repo" "$pr" "$RESET" "$GREEN" "$RESET" "$last"
    return 0
  fi

  local verdict
  if [[ "$merged" != "null" && -n "$merged" ]]; then
    verdict="MERGED WITH UNADDRESSED FINDINGS (merged $merged)"
  else
    verdict="UNADDRESSED FINDINGS — do not merge yet"
  fi

  printf '%s%s#%s%s — %s%s%s\n' "$BOLD" "$repo" "$pr" "$RESET" "$RED$BOLD" "$verdict" "$RESET"
  printf '  %slast commit:%s %s — findings below arrived after it, with no commit in response\n' \
    "$DIM" "$RESET" "$last"
  printf '%s\n' "$all" | while IFS=$'\t' read -r ts who path body; do
    printf '  %s%s%s  %s  %s%s%s\n    %s\n' \
      "$DIM" "$ts" "$RESET" "$who" "$DIM" "$path" "$RESET" "$body"
  done

  # A fix can land in a LATER PR, which this detector cannot see: its whole
  # signal is "no commit on THIS PR answered the finding", and that stays true
  # forever once the follow-up merges elsewhere. So the report never expires,
  # and each sweep re-dispatches work that is already done.
  #
  # 2026-08-09, inbox_superpilot#211: a Codex P2 posted 78s before merge was
  # fixed by #213 (merged 29 min later, a test file the finding asked for).
  # #211 still reads unaddressed. THREE sessions were dispatched from that
  # report — #213 did the work, #214 re-did it byte-identically (its squash
  # landed empty), and a third rediscovered #213 only after writing the test.
  #
  # The cross-reference is the cheap signal: any PR whose title or body mentions
  # this one appears in its timeline. NOT the search API — a fine-grained PAT
  # missing a permission returns silently-empty results there (CLAUDE.md,
  # 2026-06-24), which would read as "no follow-up" and restore the false alarm.
  #
  # Deliberately ADVISORY: prints, never clears. A cross-reference proves a PR
  # mentioned this one, not that the finding was fixed — auto-resolving on it
  # would fail OPEN on the exact class this script exists to catch. Exit stays 1
  # and the caller still verifies; it just no longer starts from scratch.
  local timeline followups since
  if [[ -n "$FIXTURE" ]]; then
    timeline=$(cat "$FIXTURE/timeline.json" 2>/dev/null || echo '[]')
  else
    # Non-fatal, unlike the fetches above: this is a hint attached to a report
    # that already stands on its own, so a timeline failure must not turn a
    # correctly-detected finding into a hard error.
    timeline=$(gh api "repos/$repo/issues/$pr/timeline" --paginate 2>/dev/null || echo '[]')
  fi

  # Oldest finding on the report. A cross-reference that predates every finding
  # cannot be a response to one.
  since=$(printf '%s\n' "$all" | cut -f1 | sort | head -1)

  followups=$(printf '%s' "$timeline" | jq -r --arg since "$since" '
    [ .[] | select(.event == "cross-referenced")
          | select(.source.issue.pull_request != null)
          | select(.created_at > $since) ]
    | .[] | [(.source.issue.number | tostring),
             (if .source.issue.pull_request.merged_at then "MERGED"
              else ((.source.issue.state // "?") | ascii_upcase) end),
             ((.source.issue.title // "") | gsub("\n"; " ") | .[0:80])] | @tsv' 2>/dev/null)

  if [[ -n "$followups" ]]; then
    printf '  %spossible follow-up%s — later PR(s) reference this one; %sverify before redoing the work%s:\n' \
      "$BOLD" "$RESET" "$BOLD" "$RESET"
    printf '%s\n' "$followups" | while IFS=$'\t' read -r num state title; do
      printf '    #%s %s%s%s  %s\n' "$num" "$DIM" "$state" "$RESET" "$title"
    done
  fi
  return 1
}

if [[ -n "$SCAN" ]]; then
  COUNT="${PR:-20}"
  echo "${BOLD}post-merge sweep:${RESET} $REPO (last $COUNT merged PRs)"
  echo
  prs=$(gh pr list -R "$REPO" --state merged --limit "$COUNT" --json number --jq '.[].number' 2>/dev/null)
  if [[ -z "$prs" ]]; then
    echo "error: could not list merged PRs for $REPO" >&2; exit 2
  fi
  hits=0
  # Iterate a literal newline-delimited list: zsh does not word-split unquoted
  # $VAR, so `for n in $prs` silently yields one element (CLAUDE.md, 2026-07-05).
  while IFS= read -r n; do
    [[ -z "$n" ]] && continue
    if ! check_pr "$REPO" "$n"; then
      hits=$((hits + 1))
      echo
    fi
  done <<< "$prs"
  echo
  if [[ "$hits" -gt 0 ]]; then
    echo "${RED}${BOLD}$hits PR(s) merged with unaddressed review findings.${RESET}"
    exit 1
  fi
  echo "${GREEN}${BOLD}clean — every merged PR addressed its review findings.${RESET}"
  exit 0
fi

check_pr "$REPO" "$PR"
exit $?
