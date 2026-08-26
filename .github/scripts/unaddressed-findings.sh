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
# Signal: an INLINE review comment newer than the newest commit (human threaded
# REPLIES excluded — see the reply rule in check_pr). Inline comments are
# reserved for "issues you're 80%+ sure are real bugs" (claude-review.yml
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
#
# Post-merge disposition (MERGED PRs only — see THE ACKNOWLEDGMENT PATH in
# check_pr): a top-level HUMAN comment carrying a line that OPENS with
#   findings-disposition: <why the finding is fixed elsewhere / does not apply>
# answers every finding older than it. Open PRs ignore the marker by design —
# pre-merge, the answer to a finding is still a commit.

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
# --------------------------------------------------------------------------
# The `regression:` marker: NORMALIZE, THEN TEST.
#
# The body is first reduced to a canonical form (`def canon:` in the jq program
# below), and only then is a small expression applied to the residue. THREE
# earlier attempts went the other way — one expression enumerating markdown's
# formatting space — and each closed a hole while silently opening another:
#
#   round 1  `regression: \S+:[0-9]+`. Permissive about WRAPPING (its `\S+`
#            reached a path inside bold, a markdown link, quotes or parens) but
#            it demanded a `:LINE` suffix and could not skip a leading backtick.
#            Missed wxa-jake-ai#1054 — see the burn note below.
#   round 2  Path SHAPE + LABEL POSITION. Fixed #1054, and silently dropped the
#            numbered, paren-numbered, heading and blockquote prefixes.
#   round 3  Widened the prefix alphabet to a repeated single-character class.
#            Fixed those four, and STILL matched less than round 1 on: every
#            path wrapper except one backtick, checkbox list items, table rows.
#   round 4  Normalize-then-test — the design below, which is right. But it
#            required a bullet to be FOLLOWED BY WHITESPACE (losing every TIGHT
#            bullet, which rounds 1 AND 3 both matched) and it could not see an
#            opening wrapper in front of the marker word at all.
#
# Measured against the round-5 corpus (tests/regression, 44,000 accept shapes ×
# 17,250 reject shapes): round 3 loses 3686 shapes round 1 matched, of which
# 2686 are undeclared narrowings; round 4 loses 3430, of which 2430 are
# undeclared; round 5 loses 1000 which — OVER THAT ALPHABET — are all negations,
# the one narrowing the label-position anchor exists to make. Every number here
# describes the enumerated corpus, not markdown: see THE SUPERSET INVARIANT
# below for the families the alphabet does not reach, and for what is being
# accepted by leaving them out. Round 4's own corpus reported zero, because it
# composed every body as `prefix + spelling + " " + wrap(path)` with every
# prefix ending in a space, so neither defect was expressible in it.
#
# The formatting space is bigger than any alternation, so the next reviewer
# always finds the next spelling. Normalizing first ends that: the alternation
# shrinks to something readable and the marker itself fits on one line. What
# round 5 adds is that the CORPUS has to be widened on the same schedule as the
# regex, because a cross product only covers the axes it has.
#
# canon runs PER LINE, in two anchored passes:
#
#   1. _BLOCK_PREFIX strips leading markdown block markers — indentation, `>`,
#      `-`/`*`/`+`, `[ ]`/`[x]`/`[X]` checkboxes, `N.`/`N)` ordered items, `#`
#      headings, and a `|` table cell — in any combination and any nesting, so
#      `> - [ ] `, `| - `, `  > 1. ` and `###### ` all reduce to nothing.
#   2. _MARKER_CANON rewrites every emphasis spelling of the marker word AND
#      the opening wrapper punctuation in front of the path to one canonical
#      `regression: `. It covers `**regression:**`, `**regression**:`,
#      `*regression:*`, `__regression__:`, `` `regression:` `` and the path
#      wrappers `` ` ``, `**`, `__`, `"`, `'`, `(` and `[` (so a markdown link,
#      a quoted path and a backtick-inside-bold path all reduce alike).
#
# So the shipped marker only ever sees `regression: <path>` at the start of a
# line, and both original intents survive intact:
#
#   PATH SHAPE — the sole admission gate. The run of non-space characters after
#   the canonical marker must carry ONE of three signals: a `/`, a `.` followed
#   by a LETTER (an extension), or a `:LINE` suffix on a LETTER-led token.
#   Admits `main.go:267`, `docs/package.json:13`, `` `tests/ci/x.test.ts` ``,
#   the extensionless `scripts/deploy` and the root-level `Dockerfile:12`;
#   rejects `none`, `nothing to report`, `3.2 seconds slower` and `12:30`
#   (a time, not a path — which is why the `:LINE` token must start with a
#   letter). Without this gate a marker would flag every comment containing the
#   word, and a sweeper that cries wolf gets ignored — strictly more expensive
#   than the miss it fixes.
#
#   The `:LINE` signal is not decoration: it is what round 1 relied on
#   exclusively, and dropping it would trade this bug for its mirror image —
#   `regression: Dockerfile:12` and `regression: Makefile:8` are root-level
#   extensionless files the other two signals cannot see. `n/a` is excluded BY
#   NAME because it is the one empty-bucket token whose own slash satisfies the
#   shape test; `_NOT_EMPTY` below already treats it as empty for the P-labels.
#   Residual, deliberately: a root-level extensionless file with NO line number
#   (`regression: Dockerfile — the base image is stale`) carries none of the
#   three signals and is missed. It is indistinguishable from a bare word
#   without an allowlist of famous filenames, and round 1 missed it too.
#
#   LABEL POSITION — the marker must OPEN its line, after nothing but block
#   markers, which is the line format codex's own prompt mandates
#   (`regression: <file:line> - <sentence>`). What the block alphabet excludes
#   is WORDS, and that exclusion is the entire mechanism for rejecting NEGATED
#   uses, which the shape test cannot see: "No regression: package.json is
#   unchanged" (codex wrote exactly that reviewing round 2), "Not a regression:
#   main.go:267 is covered", "the diff shows no regression: ...". Every negation
#   phrasing puts a word between the line start and the marker, so all of them
#   are answered at once — including quoted, numbered and checkboxed ones —
#   without parsing English negation, which the note below explains does not
#   converge.
#
# THE SUPERSET INVARIANT, which is what rounds 2 and 3 actually violated: if
# round 1's marker matches an input, this one must match it too. It may match
# strictly more — that is the point of every fix — but never less.
# tests/regression/test_unaddressed_findings.py asserts it differentially over
# the full cross product of block prefix × TIGHT-OR-SPACED × marker spelling ×
# WHOLE-MARKER WRAPPING × path wrapping × with/without `:LINE`, because a
# hand-listed set of bodies only ever contains the shapes its author already
# thought of — and, round 5's lesson, a cross product only contains the shapes
# its AXES can compose. The two axes in capitals are the ones round 4 lacked,
# and each of them hid one of round 4's two defects. The same test refuses to
# accept a corpus containing two byte-identical bodies, because round 4's shell
# twin silently lost a wrapper to shell quoting while its case count stayed
# exactly where it was expected to be.
#
# IT IS ASSERTED OVER AN ENUMERATED CORPUS, NOT UNIVERSALLY. That distinction is
# the correction round 6 owes anyone who read the previous wording, which said
# "exactly TWO declared exceptions" flatly and led a reviewer to treat the
# invariant as a property of the marker rather than of the test's alphabet.
# Inside the corpus the claim stands: the divergences carry exactly two declared
# tags, both of them round 2's reason for existing — a WORD before the marker
# (the negations above), and a `:LINE`-like token that is not a plausible path
# (`12:30 elapsed`). A divergence inside the corpus that is neither is a
# regression, and the test names it. A tag is for a narrowing someone argued for
# — never for making a red test go green.
#
# OUTSIDE the corpus the invariant does not hold, and saying so is cheaper than
# discovering it again. Independent corpora put the residual at roughly 10,200
# bodies round 1 matched and this marker misses, and NONE of them are negations.
# They are whole families the block alphabet and the wrapper classes do not
# enumerate: unicode leads beyond the three listed (small square, triangle
# bullet, hyphen bullet, middot, guillemet, arrow, and the warning and cross
# emoji), paren-wrapped ordered items such as `(1)`, HTML tags such as
# `<summary>` and `<b>`, strikethrough `~~`, a leading colon, caret or tilde, a
# zero-width space, and a BOM.
#
# ACCEPTED RESIDUAL, deliberately — this list is a boundary, not a to-do. Two
# reasons, and the second is the load-bearing one. None of these families is
# attested in the harvested bot traffic this detector runs against. And every
# addition widens FINDING_RE, which is the SOLE admission gate: the only thing
# standing between this sweeper and flagging every comment that contains the
# word. An unmatched shape costs one unswept finding; an admission gate that
# starts accepting prose costs a sweeper nobody reads, which this file argues
# twice over is the more expensive failure. Add a family only when a real body
# turns up that needed it.
#
# BACKTRACKING DISCIPLINE. An Oniguruma retry-limit abort is a SILENT FALSE
# NEGATIVE here, not a slowdown: the jq calls below send stderr to /dev/null, so
# the abort empties the finding list and the sweeper prints "no unaddressed
# findings" — byte-identical to a genuine pass. Round 3 measured a `>+`/`#{1,6}`
# prefix loop dying on 20 consecutive `>`, and runs like that are ordinary in
# bot comments (nested quoted replies; a pasted conflict marker is seven).
# Every repetition here therefore consumes a FIXED number of characters per
# iteration, so the parse is unique and there is nothing to backtrack over.
# _BLOCK_PREFIX is stronger still: it is `^`-anchored with NOTHING after it, so
# it always succeeds and the engine never has a failing continuation to retry
# against — it cannot backtrack at all, structurally rather than by tuning.
#
# THE BURN. whois-api-llc/wxa-jake-ai#1054: claude[bot] posted, 3m41s after the
# last commit and 1m23s before the merge:
#
#   regression: `tests/ci/prod-model-health-author-scope.test.ts` — no test pins
#   the cron schedule value `7,22,37,52 * * * *` ...
#
# The path was BACKTICKED and carried NO line number, so round 1's `\S+:[0-9]+`
# matched nothing, the comment never reached CLEAN_RE, and the PR merged with
# the finding live. Both deviations are ordinary: findings routinely name a
# whole file rather than a line in one, and both bots write paths in code spans.
# #1067 is the second live instance — the marker on its own line beneath a bold
# header.
#
# Shared with SEVERITY_RE below so the admission gate and the clean-marker
# override can never disagree about what a regression line looks like.
# --------------------------------------------------------------------------
# ROUND 5 DELETED a guard round 4 put here: "a `-`/`*`/`+` bullet must be
# FOLLOWED BY WHITESPACE". That guard had exactly one job — this pass was eating
# the opening `**` of `**P1** unscoped token ...` as two bullets, and round 4
# had routed SEVERITY_RE's `\*\*P[012]\*\*` clause through the NORMALIZED body,
# so the clause stopped matching. SEVERITY_RE reads the RAW body again (see the
# note above it for why that is not a style choice), which means the collision
# it guarded against can no longer occur, and the guard protected nothing while
# costing ~99 corpus shapes: a TIGHT `-regression: src/foo.ts:12` or
# `+regression: ...` was never stripped, never reached the marker, and went
# unflagged — matched by BOTH round 1 and round 3, so it was a two-way loss.
# The bold-P case is still pinned by test, from the raw side now.
#
# `•` (U+2022), `–` (U+2013) and `—` (U+2014) are block markers too: a model
# rendering a list as `• item` is ordinary, and an em dash opens a quoted aside.
# Only ASCII `-` is a range operator inside a bracket expression, so all three
# are literals here.
_BLOCK_PREFIX='^[[:blank:]]*(([>|#•–—]|[-*+]|\[[ xX]\]|[0-9]{1,9}[.)])[[:blank:]]*)*'
# `\x27` is an apostrophe. Spelling it as an escape keeps this a single-quoted
# shell string with no embedded quote, which is what lets the tests read these
# values straight out of the file instead of keeping a second copy that rots.
#
# The wrapper class appears TWICE — once before the word and once after the
# colon — because punctuation wraps the WHOLE marker as often as it wraps the
# path alone: `"regression: src/foo.ts:12"`, `(regression: main.go)` and
# `[regression: main.go](url)` are all shapes round 1 matched (its `\S+` never
# looked left) and rounds 2, 3 and 4 all silently dropped, because none of them
# could express an opening wrapper in front of the marker word at all. Smart
# quotes and `<` are in both classes for the same reason: a model that
# autocorrects `"` to `“` is not writing a different finding.
#
# Only the OPENING half of each bracket pair is a member — `(`, `[` and `<`,
# with no `)`, `]` or `>` anywhere in either class. (An earlier version of this
# comment said `<`/`>`, describing a class the file has never shipped.) Both
# positions the class occupies sit IN FRONT of something — the marker word and
# the path — so a closing bracket never reaches it: the path run
# `[A-Za-z0-9_./@+-]+` simply stops at one and leaves it in the tail, where
# nothing needs to strip it. All FOUR smart quotes are listed rather than the
# two opening ones because autocorrection picks a half from surrounding context
# and gets it wrong often enough to matter.
# shellcheck disable=SC2016,SC1112  # a regex, not a shell expansion: the
# backticks are code-span characters the normalizer strips, and the four smart
# quotes are CHARACTER-CLASS MEMBERS — punctuation a model wrote around a path,
# not shell quoting that got autocorrected. SC1112 is exactly the right warning
# to have somewhere else and exactly wrong here, so it is silenced on this line
# only rather than by a repo-wide setting.
_MARKER_CANON='^[*_`"\x27(\[<“”‘’]*regression[*_`]*:([[:blank:]]|[*_`"\x27(\[<“”‘’])*'
_REGRESSION_MARKER='(^|\n)regression: (?!n/a\b)(?=[^[:space:]]*(/|\.[A-Za-z])|[A-Za-z_][A-Za-z0-9_.@+-]*:[0-9])[A-Za-z0-9_./@+-]+(:[0-9]+)?'
# --------------------------------------------------------------------------
# The flagged-count clause: `[Ff]lagged N <words> issue`, gap SENTENCE-BOUNDED.
#
# THE BURN. whois-api-llc/wxa_webcat#927, 2026-08-16: claude[bot]'s inline
# posting failed wholesale — all four of its inline comments predate the last
# commit — so the round's findings existed ONLY in the top-level summary
# posted 26 minutes after it: "Flagged 4 confirmed issues inline: (1) ...".
# This clause then read `[Ff]lagged [0-9]+ issue`, demanding "issue"
# IMMEDIATELY after the count; one adjective broke adjacency, no other
# alternative matched (no P-token, no VERDICT trailer, the word "regression"
# never appears), and the sweeper printed "no unaddressed findings". The
# clause keys on the CLAIM — a count of issues — so it tolerates the words a
# model puts between the count and the noun.
#
# The gap is `[^.!?\n]{0,60}?`, NOT `.*`, because this clause also sits in
# SEVERITY_RE below as a suppressor-cancelling override, where widening
# manufactures false positives (the round-5 lesson): with `.*` the gap
# crosses a sentence boundary, so a re-review PASS like "the earlier round
# flagged 2 findings, all addressed. No issues found." matches
# flagged-N-issues and overrides its own clean verdict — a false "do not
# merge yet". Same sentence-bounding idiom as SEVERITY_RE's contrast-
# conjunction clause; bounded lazy repetition, one character per step,
# nothing to backtrack over pathologically.
#
# The clause appears TWICE, with a deliberate count asymmetry: `[0-9]+` here
# (the admission gate must examine a zero count so CLEAN_RE can weigh the
# clean phrase beside it) and `[1-9][0-9]*` in SEVERITY_RE (a zero count must
# never OVERRIDE that clean phrase — "No issues found. Flagged 0 confirmed
# issues inline." stays clean). Widen both together, or the adjective reopens
# the same hole one suppressor later.
# --------------------------------------------------------------------------
FINDING_RE="([Ff]lagged [0-9]+[^.!?\n]{0,60}? issue|\bP[012]\b|VERDICT: REGRESSION|${_REGRESSION_MARKER})"
# THE SAME MARKER, IN RAW-BODY FORM. Used in exactly one place: the CLEAN
# override in the jq select below. Never in FINDING_RE.
#
# Round 5 applied the marker ABOVE to the normalized body as its own
# clean-override term, on the reasoning that demoting it to RAW alongside
# SEVERITY_RE would lose round 3's `- regression: src/foo.ts:12` override. The
# trap is real — that marker delegates ALL prefix handling to canon, so on a raw
# body it sees `- regression:` and matches nothing. The conclusion drawn from it
# was wrong: pointing the term at canon's output hands a SUPPRESSOR-CANCELLING
# test the entire block alphabet, which is precisely the widening the note above
# SEVERITY_RE says manufactures false positives.
#
# Measured, round 3 vs round 5, over bodies that carry a clean verdict: 76 of
# 484 suppressor-side shapes flipped from rc=0 to rc=1, and on a 9-prefix ×
# 8-whole-marker-wrapping grid over "a quoted previous regression line above a
# clean verdict" round 3 flags 6 of 72 while round 5 flags 72 of 72 — 66 new
# false positives from one term. The sharpest instance, confirmed end-to-end
# through both twins including the automerge gate:
#
#   - [x] regression: src/foo.ts:12 - fixed in 2a5937e
#   No issues found. VERDICT: CLEAN
#
# A CHECKED checkbox is the universal notation for an ADDRESSED finding, so
# round 5 declined the merge exactly when the evidence said the finding was
# resolved. Round 5's own deviation note called the widening "marginal
# (checkbox, table-pipe, tight bullet, wrapped paths)"; only 20 of the 76 fall
# in those classes — 44 are whole-marker wrapping and 12 are unicode block
# markers, so 74% of the deviation sat outside its own declaration.
#
# So the override term gets its own raw-capable spelling instead: ROUND 3'S
# MARKER, VERBATIM out of commit 5bcc1ca, which carried its prefix alternation
# INTERNALLY and therefore needs no normalizer. Reusing it rather than deriving
# one is what makes the parity EXACT rather than argued — `- regression:` still
# overrides, `- [x] regression:` no longer does, and the differential in
# tests/regression/test_unaddressed_findings.py reports new-flags and
# lost-overrides against round 3 as zero in both directions.
#
# It is a SEVERITY signal, so it now reads the same body every other severity
# signal reads, and the routing note in the jq select has one fewer exception in
# it. FINDING_RE keeps reading the NORMALIZED body: that is the admission gate,
# where widening is safe, and it is where round 5's two genuine wins live
# (wxa-jake-ai#1054 and #1067, both still flagged).
#
# BACKTRACKING: its prefix loop is `([[:space:]]*(>|[-*+]|[0-9]+[.)]|#))*`. Each
# alternative either consumes exactly one character or is a digit run TERMINATED
# by `[.)]`, which a digit cannot be — so each iteration's extent is fixed by
# the input rather than chosen, and there is no partition to enumerate. The loop
# round 3 was measured dying on was the earlier `(>+|#{1,6}|...)` shape, which
# this is not. Re-measured here at 400-plus characters, in both twins.
#
# shellcheck disable=SC2016  # a regex, not a shell expansion: the backticks are
# the OPTIONAL code-span character round 3 stepped over in front of a path
# (`regression: `main.go``, the #1054 shape) and a member of the negated class
# that keeps the lookahead off it. Silenced on this line only, like the
# _MARKER_CANON directive above, rather than by a repo-wide setting.
_REGRESSION_MARKER_RAW='(^|\n)([[:space:]]*(>|[-*+]|[0-9]+[.)]|#))*[[:space:]]*\**regression:\**[[:space:]]*`?(?!n/a\b)(?=[^[:space:]`]*(/|\.[A-Za-z])|[A-Za-z_][A-Za-z0-9_.@+-]*:[0-9])[A-Za-z0-9_./@+-]+(:[0-9]+)?'
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
#     line — or `P2:` anywhere. This is how codex emits findings ("- [P2] Title
#     — file:lines"), and why the bracket form is anchored: "No [P1] or [P2]
#     issues found" is a disclaimer in a label's clothes. A severity
#     mid-sentence in prose is mentioned, not asserted.
#
#     "Label position" here is a BULLET AND NOTHING ELSE, and this clause is
#     tested against the RAW body, not the normalized one. Round 4 did the
#     opposite — it deleted this prefix and routed the clause through canon, on
#     the argument that widening an assertion test can only ever flag more. That
#     argument is wrong for THIS test, and the asymmetry is the whole lesson of
#     round 5: SEVERITY_RE does not decide whether a comment is a finding, it
#     OVERRIDES A SUPPRESSOR. Widening a suppressor loses findings; widening
#     something that CANCELS a suppressor manufactures false positives.
#
#     Measured, 8 shapes out of 8: a re-review that QUOTES the previous round's
#     finding and then passes — `> [P1] ...`, `> **P1** ...`, `> P1 — ...`,
#     `1. [P2] ...`, `### **P1** ...`, `| [P1] ... |`, `- [x] [P1] ...`,
#     `>> [P0] ...`, each above a "No issues found. VERDICT: CLEAN" — returned
#     rc=0 in round 3 and rc=1 in round 4. That is the sweeper crying wolf on a
#     PASS, which this file argues twice over is strictly more expensive than
#     the miss it would be trading against.
#
#     So the prefix asymmetry between this clause and the regression marker is
#     DELIBERATE, not the drift round 4 read it as. The marker carries its own
#     admission gate — a path-shaped token in label position — and cannot fire
#     on quoted prose; a bare `[P1]` is quoted constantly. The two tests are
#     allowed to disagree about prefixes precisely because they are not the same
#     kind of test.
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
# assume claude[bot] findings always arrive as inline comments (which never see
# CLEAN_RE or the severity override; their only filter is the human-reply
# exclusion in check_pr). On
# wxa-jake-ai#1054 claude[bot] posted its finding TOP-LEVEL, as a `regression:`
# line, with zero inline comments on the PR. The top-level path is load-bearing
# for both bots. A live instance of the residual gap: the codex comment on that
# same PR ("No regression found. Missing coverage: no test pins the new cron
# expression at `...yml:63`") is a real finding phrased with no marker at all,
# and it is still missed — closing it means matching bare prose, which is the
# trade this design deliberately refuses.
_NOT_EMPTY='(?![[:blank:]]*(none|nothing|n/a|not applicable|no findings|no issues|(0|zero)[[:blank:]]+(finding|issue)s?)\b)[[:blank:]]*[^[:space:]]'
# Tested against the RAW body — every clause here, and the regression marker
# too. The marker is still applied as its OWN term in the jq select below rather
# than spliced into this string, but in its `_REGRESSION_MARKER_RAW` spelling:
# `${_REGRESSION_MARKER}` delegates its prefix handling to canon and matches
# nothing on a raw body, which is the constraint round 5 read as "this one
# signal must see the normalized body". The answer is the other way round — give
# the override term the prefix-carrying marker round 3 shipped, and it reads RAW
# like everything else here while still overriding `- regression: src/foo.ts:12`.
# Keeping it a separate term is only so the two spellings stay legible; it is
# semantically one more alternative in this alternation.
SEVERITY_RE="(\bP[012]:${_NOT_EMPTY}|(^|\n)[[:space:]]*([-*+][[:space:]]*)?(\[P[012]\]|\*\*P[012]\*\*|P[012][[:space:]]*[-—:])${_NOT_EMPTY}|\b(but|however|except|although|though|yet)\b((?!\b(no|not|zero|none|neither|without)\b)[^.!?\n]){0,30}?\bP[012]\b|flagged [1-9][0-9]*[^.!?\n]{0,60}? issue|VERDICT: REGRESSION)"

# The "last commit" a finding is measured against must be a commit that could
# plausibly ANSWER it — i.e. one carrying the author's changes. `auto-update-branch`
# merges main into every open PR on each push to main, and those merge commits
# post-date any outstanding finding, silently resetting this comparison.
#
# 2026-08-06, techrecon#826: a real inline finding at 02:16:05Z (an operator-facing
# log.Fatalf citing a reason its own adjacent comment says is obsolete) was followed
# by FOUR `Merge branch 'main' into ...` commits and nothing else. This script
# reported "no unaddressed findings", and the PR merged at 03:34:17Z with the
# message still wrong on main. Excluding those merges is the fix: a base merge
# introduces no authored change, so it cannot address a review finding.
#
# 2026-08-16, wxa_vpn#1529: the exclusion as first written was "parents >= 2",
# and that over-reaches. Two Codex P2s at 23:43:53Z were answered by 2cfeb271 —
# a 2-parent commit the author wrote by hand ("merge origin/main; reduce to the
# two setup guards main still lacks") that ALSO added the two requested tests.
# Codex re-reviewed it clean; this script kept reporting "last commit:
# 2026-08-14T21:53:02Z" and the P2s as unaddressed. Parent count cannot separate
# a base merge from an authored merge; the SUBJECT can. A base merge has ONE
# source, and git's fmt-merge-msg labels a single-source merge by how the source
# was named — `Merge branch '...'`, `Merge remote-tracking branch '...'`,
# `Merge commit '...'` (raw sha) or `Merge tag '...'` — while GitHub's merge
# button writes `Merge pull request #...`. Those are every label fmt-merge-msg
# emits when it can NAME the source, so they are enumerated below and only
# those are excluded. Deliberately not enumerated: `git pull <url>` with no
# refspec yields an unlabeled `Merge <url> into ...` — a bare URL/path is a
# suffix-open family, and the fleet lesson is to enumerate closed label sets,
# never open ones. That shape counts as authored, an accepted fail-open corner:
# fleet base merges come from auto-update-branch / "Update branch" and from
# `git merge origin/main`, both labeled, and nothing here pulls a bare URL.
# The plural forms, `Merge branches 'a' and 'b'`, exist only
# for octopus merges (more than one source at once) — nobody octopus-merges a
# base into a PR head, so they count as authored, like any subject not listed.
# The quote after the label is load-bearing: it is git's ref syntax, so a
# hand-written subject that merely opens with "Merge branch protection ..." is
# not excluded. Any 2-parent commit with another subject counts as authored,
# same as a 1-parent commit — the trust model is unchanged: an author's own
# push, of any shape, is taken as the response, so a base-only merge typed as
# `-m "sync main"` clears findings exactly like `commit --allow-empty` always
# has (fleet automation keeps git's default subject for that reason; see
# commands/babysit-prs.md). The mirror residual is over-report: a
# default-subject merge whose conflict resolution carries the fix stays
# excluded and the finding is re-flagged until a 1-parent commit follows —
# fail-closed, accepted. `^` is string-anchored in jq (Oniguruma SINGLELINE),
# so `test` reads the subject line only, never a body line.
#
# Second, subject-independent gate (fleet "two gates" rule): every merge GitHub
# itself commits — auto-update-branch, "Update branch", "Resolve conflicts", the
# merge queue — carries committer `noreply@github.com` (login web-flow; verified
# on techrecon#826). Such a merge is a base merge whatever its subject says, so
# a GitHub subject reword cannot resurrect #826 through the subject gate alone.
# `// ""` on the email is safe here: an absent email simply fails to match
# GitHub's, and the subject gate still decides.
#
# `// empty` rather than `// null`: a PR whose only commits are base merges
# yields no usable value, which must fall through to the hard error below (fail
# closed), not compare as the string "null".
BASE_MERGE_SUBJECT_RE="^Merge branch '|^Merge remote-tracking branch '|^Merge commit '|^Merge tag '|^Merge pull request #"
GITHUB_COMMITTER_EMAIL="noreply@github.com"
LAST_COMMIT_JQ="[.[] | select((.parents | length) < 2 or ((.commit.message | test(\"$BASE_MERGE_SUBJECT_RE\") | not) and ((.commit.committer.email // \"\") != \"$GITHUB_COMMITTER_EMAIL\"))) | .commit.committer.date] | max // empty"

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

  # --------------------------------------------------------------------------
  # THE ACKNOWLEDGMENT PATH (ci-workflows#163) — MERGED PRs ONLY.
  #
  # A merged PR can never receive this detector's one clear-signal (an authored
  # commit newer than the finding), so before this block every post-merge
  # finding re-flagged on every sweep until ~25 newer-CREATED merges pushed the
  # PR out of the scan window: wxa_vpn#1587 accumulated 6-hourly reports for
  # two days after every finding on wxa_vpn#1629/#1630 was fixed or adjudicated
  # (2026-08-24..26). The sweep's own issue text has always asked the operator
  # to "record why the finding does not apply" — this gives that record a
  # spelling the detector reads.
  #
  # The marker: a TOP-LEVEL comment by a KNOWN HUMAN whose body has a line
  # opening (column 0) with `findings-disposition:` followed by content. Its
  # created_at then acts like a commit: findings OLDER than the newest valid
  # marker are answered; a finding posted AFTER it re-flags and needs a new
  # decision. Every leg fails CLOSED, deliberately:
  #   * MERGED PRs only. On an OPEN PR — the automerge gate's entire domain —
  #     behavior is byte-identical with or without a marker: pre-merge, the
  #     answer to a finding remains a commit (or the human's click past the
  #     gate's decline), per the 2026-08-09 Option-1 deferral on wxa_vpn#1392.
  #   * The author must be a string login NOT ending `[bot]`: a bot cannot
  #     disposition its own finding, and a null/non-string author is nobody's
  #     decision (same type-guard as late_issue below, same reason).
  #   * Column 0, lowercase, content required. A quoted `> findings-...`, a
  #     mid-sentence mention, or a bare marker with nothing after the colon
  #     dispositions nothing. Operators type this marker on purpose — it is a
  #     literal, not model prose — so it gets no normalizer and no case
  #     folding: the marker is a SUPPRESSOR, and widening a suppressor is the
  #     false-negative direction this file argues against twice already.
  #   * A malformed created_at is ignored (the SHAPE rule above, same class).
  #   * Edits don't count: created_at never moves on edit, so retro-editing an
  #     old comment cannot acknowledge a newer finding.
  # An applied disposition is ALWAYS named in the report, on both verdicts —
  # a quiet PR must show WHY it is quiet; suppression is never silent.
  local ack_row ack_ts ack_who cutoff
  cutoff="$last"
  ack_row=""
  if [[ "$merged" != "null" && -n "$merged" ]]; then
    ack_row=$(printf '%s' "$issue" | jq -r '
      [ .[] | select(.user.login | type == "string" and (endswith("[bot]") | not))
            | select((.body // "")
                     | test("(^|\\n)findings-disposition:[[:blank:]]*[^[:space:]]")) ]
      | sort_by(.created_at) | last // empty
      | [.created_at, .user.login] | @tsv' 2>/dev/null)
  fi
  if [[ -n "$ack_row" ]]; then
    ack_ts="${ack_row%%$'\t'*}"
    ack_who="${ack_row#*$'\t'}"
    if [[ "$ack_ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2} && "$ack_ts" > "$cutoff" ]]; then
      cutoff="$ack_ts"
    fi
  fi

  # A comment stream spanning pages arrives as concatenated arrays; jq handles
  # each as an independent input and the per-page results concatenate, so no
  # reduction is needed for those.

  # Inline comments strictly newer than the newest commit. Author-agnostic at
  # TOP LEVEL — a human's own inline comment on the diff is a deliberate
  # code-level finding, same as a bot's. HUMAN THREADED REPLIES are the one
  # exclusion: replying to a finding's thread is how a fix is RECORDED
  # ("Fixed in <sha>"), and that reply necessarily post-dates the commit it
  # cites, so every resolution round trips the newer-than-last-commit signal
  # and the report re-flags resolved threads forever. Measured on wxa_vpn#1523:
  # the report's top three hits were the PR's own "Fixed in 38774043" replies,
  # posted 7-12s after the fix commit — 5/5 false positives carried
  # in_reply_to_id, 0/14 genuine bot findings did. BOT replies still count: a
  # reviewer bot answering a thread with "still broken after the fix" is a
  # live finding, and keeping them cost zero false positives in that corpus.
  # A reply whose author is UNKNOWN (deleted/suspended account -> .user null)
  # also still counts: the exclusion drops only a KNOWN-human reply, because
  # reading an absent login as "not a bot" would silently convert an unknown
  # author into a false negative — the fail direction this detector must
  # never take. Accepted residual: a human typing a NEW finding into an
  # existing thread is skipped — the operator wrote it, so the operator
  # already knows it, and the alternative re-flags every resolved thread on
  # every sweep, which is the cry-wolf failure this file argues twice over is
  # the more expensive one.
  #
  # The null test and the bot test are ONE pipeline expression on the login
  # (`. == null or endswith`), not two sibling arms of the outer `or`. As
  # siblings the null-safety was POSITIONAL — it held only because the null
  # arm happened to be evaluated first, and swapping them in a refactor would
  # send null into `endswith`, a jq TYPE ERROR that `2>/dev/null` swallows:
  # late_inline comes back empty and every inline finding on the PR silently
  # vanishes (exit 0). Inside one pipeline the short-circuit is structural:
  # the type test guards `endswith` no matter how the outer arms are
  # arranged. It is `type != "string"` rather than `. == null` so a NON-null
  # non-string login (an integer id from a caching proxy, a schema change)
  # takes the same safe path: anything that is not a string cannot be a
  # known bot, so it is an unknown author, and unknown authors COUNT here.
  # Same `type` guard as late_issue's below, same reason, opposite default
  # (there, unknown does not count).
  local late_inline
  late_inline=$(printf '%s' "$inline" | jq -r --arg cutoff "$cutoff" '
    [ .[] | select(.created_at > $cutoff)
          | select(.in_reply_to_id == null
                   or (.user.login | type != "string" or endswith("[bot]"))) ]
    | .[] | [.created_at, (.user.login // "-"), (.path // "-"),
             ((.body // "") | gsub("\n"; " ") | .[0:90])] | @tsv' 2>/dev/null)

  # Top-level findings count only from review BOTS. Humans post round-summary
  # comments ("REVIEW-LOOP: round 7 — 1 finding, fixed in 2a5937e") that match
  # the finding markers while actually reporting a FIX — counting those cost a
  # false positive on wxa-secrets#27. Top-level inline comments stay
  # author-agnostic — a human's own comment on the diff is a deliberate
  # code-level finding; the one inline exclusion is human REPLIES, per the
  # reply rule above.
  #
  # The `type == "string" and` on the login below is load-bearing. A comment
  # whose author account was deleted/suspended arrives with `.user: null`,
  # and `null | endswith(...)` is a jq TYPE ERROR — with stderr discarded
  # that would abort the whole program, empty late_issue, and silence EVERY
  # top-level finding on the PR because one unrelated comment lost its
  # author (exit 0, the fail direction this detector must never take). It is
  # a TYPE test rather than `// ""` because `//` only rescues null/false: an
  # integer login (a caching proxy, a schema change) sails through `//` into
  # `endswith` and is the same swallowed abort. With the guard, an unknown
  # or non-string author simply falls to this path's DEFAULT: it is not a
  # known bot, so it does not count — the mirror of the inline path, whose
  # default is to count and whose unknown authors therefore do.
  #
  # `canon` is the normalizer described at _BLOCK_PREFIX above: per line, strip
  # markdown block markers, then reduce any emphasis spelling of `regression:`
  # and the opening wrapper punctuation after it to one canonical form. Both
  # passes are `^`-anchored, so each runs once per line with no scanning.
  #
  # WHICH BODY EACH TEST SEES IS NOT UNIFORM, and round 5 exists because round 4
  # made it uniform on the wrong side. The rule is not "normalize everything"; it
  # is normalize what ADMITS, leave alone what CANCELS:
  #
  #   $body (normalized) — FINDING_RE, the admission gate. Widening it can only
  #     admit more comments for classification, and every miss it fixes is a
  #     finding that would otherwise never be examined at all.
  #   RAW — CLEAN_RE, the suppressor. Widening a suppressor is the
  #     false-negative direction: `> LGTM` becoming a clean marker would quietly
  #     drop coverage, the exact failure this whole file exists to prevent.
  #   RAW — SEVERITY_RE, which OVERRIDES the suppressor. Round 4 normalized this
  #     one too, reasoning that widening an assertion only flags more. It does —
  #     but a test that cancels a suppressor flags more by MANUFACTURING false
  #     positives, and eight measured shapes flipped a passing re-review that
  #     merely QUOTED its previous `[P1]` into "do not merge yet".
  #   RAW — the regression marker, as its own override term, in its
  #     `_REGRESSION_MARKER_RAW` spelling. It is a severity signal, so it reads
  #     the body every severity signal reads; there is no third rule. Round 5
  #     pointed this one term at the NORMALIZED body to keep round 3's
  #     `- regression: ...` override, and bought that one shape by handing a
  #     suppressor-cancelling test the whole block alphabet — 76 of 484 measured
  #     suppressor-side shapes flipped to a false "do not merge yet", including
  #     a CHECKED checkbox recording a fix. The raw spelling keeps the override
  #     and drops the widening: exact parity with round 3, measured both ways.
  local late_issue
  late_issue=$(printf '%s' "$issue" | jq -r --arg cutoff "$cutoff" \
                 --arg find "$FINDING_RE" --arg clean "$CLEAN_RE" \
                 --arg sev "$SEVERITY_RE" --arg rmark "$_REGRESSION_MARKER_RAW" \
                 --arg blk "$_BLOCK_PREFIX" --arg mark "$_MARKER_CANON" '
    def canon: split("\n") | map(sub($blk; "") | sub($mark; "regression: "; "i")) | join("\n");
    [ .[] | select(.created_at > $cutoff)
          | select(.user.login | type == "string" and endswith("[bot]"))
          | select(((.body // "") | canon) as $body
                   | ((.body // "")) as $raw
                   | ($body | test($find; "i"))
                     and ((($raw | test($clean; "i")) | not)
                          or ($raw | test($sev; "i"))
                          or ($raw | test($rmark; "i")))) ]
    | .[] | [.created_at, (.user.login // "-"), "-",
             ((.body // "") | gsub("\n"; " ") | .[0:90])] | @tsv' 2>/dev/null)
  # `(.user.login // "-")` on BOTH output lines is an OUTPUT CONVENTION, not
  # a null guard: the two @tsv rows land in the same report, so a missing
  # login must render the same way in each ("-", never jq'\''s "null"). It is
  # unreachable on this path today (the select above admits only string
  # logins) and load-bearing on late_inline (unknown authors count there);
  # keeping it symmetric means extending this path later cannot desync the
  # report. The GUARDS are the two selects, not this.

  local all
  all=$(printf '%s\n%s' "$late_inline" "$late_issue" | grep -v '^$' || true)

  if [[ -z "$all" ]]; then
    if [[ "$cutoff" != "$last" ]]; then
      # Suppression is never silent: the sweep's rolling report must show WHY
      # a previously-flagged PR went quiet, or a disposition is a laundering.
      printf '%s%s#%s%s — %sno unaddressed findings%s (last commit %s; findings before %s dispositioned by %s)\n' \
        "$BOLD" "$repo" "$pr" "$RESET" "$GREEN" "$RESET" "$last" "$cutoff" "$ack_who"
    else
      printf '%s%s#%s%s — %sno unaddressed findings%s (last commit %s)\n' \
        "$BOLD" "$repo" "$pr" "$RESET" "$GREEN" "$RESET" "$last"
    fi
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
  if [[ "$cutoff" != "$last" ]]; then
    printf '  %sdisposition:%s findings before %s dispositioned by %s — the finding(s) below POST-DATE it and need a new decision\n' \
      "$DIM" "$RESET" "$cutoff" "$ack_who"
  fi
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

  # A cross-reference can ORIGINATE IN ANOTHER REPO, and .source.issue.number is
  # local to that source repo — so a bare "#213" walks the operator to whatever
  # #213 happens to be in the repo being scanned. Qualify the slug whenever the
  # source repo differs; same-repo hits stay terse, because this hint is already
  # dense and every scanned PR's followups are usually local.
  #
  # full_name is the documented field, but fall back to parsing html_url: an
  # event that omits the repository object is exactly where a bare number
  # misleads most. Slugs compare case-insensitively — GitHub treats them that
  # way, and an operator typing `Owner/Repo` must not qualify every local hit.
  followups=$(printf '%s' "$timeline" | jq -r --arg since "$since" --arg repo "$repo" '
    [ .[] | select(.event == "cross-referenced")
          | select(.source.issue.pull_request != null)
          | select(.created_at > $since) ]
    | .[]
    | (.source.issue.repository.full_name
       // (.source.issue.html_url // "" | split("/")
           | if length > 4 then "\(.[3])/\(.[4])" else null end)
       // $repo) as $src
    | [(if ($src | ascii_downcase) == ($repo | ascii_downcase)
        then "#\(.source.issue.number)"
        else "\($src)#\(.source.issue.number)" end),
       (if .source.issue.pull_request.merged_at then "MERGED"
        else ((.source.issue.state // "?") | ascii_upcase) end),
       ((.source.issue.title // "") | gsub("\n"; " ") | .[0:80])] | @tsv' 2>/dev/null)

  if [[ -n "$followups" ]]; then
    printf '  %spossible follow-up%s — later PR(s) reference this one; %sverify before redoing the work%s:\n' \
      "$BOLD" "$RESET" "$BOLD" "$RESET"
    printf '%s\n' "$followups" | while IFS=$'\t' read -r ref state title; do
      printf '    %s %s%s%s  %s\n' "$ref" "$DIM" "$state" "$RESET" "$title"
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
