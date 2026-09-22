# Shadow mode: runbook

The driver for [SHADOW-PHASE-PLAN.md](SHADOW-PHASE-PLAN.md) § 3. One command runs
one cycle: preflight, durable dispatch record, producer dispatch on the
protected tag, wait, trusted intake, read-only verdict, one log line. Nothing
here publishes a check: the App stays idle, `evaluate` is always called
without publication, and the CLI has no publish option.

Files: `.github/scripts/merge-policy-shadow.mjs` (the driver),
`.github/scripts/merge-policy-intake-adapter.mjs` (the intake readers built
from the artifact client), `.github/scripts/merge-policy-github-artifact.mjs`
(`read` and the new `recheck`). Tests: `selftest/test_merge_policy_shadow.mjs`,
`selftest/test_merge_policy_intake_adapter.mjs`.

## Execution packet (owner, once per stage)

Everything below is the owner's, under the owner's `gh` identity. A session
may prepare files and commands; it does not mint tags, rulesets or secrets.

1. PR-A merged: `.github/scripts/merge-policy-review-dispatch.mjs` and the
   template `scripts/merge-policy/staging/review-dispatch.workflow.yml` on
   `main`.
2. In the producer repository (Stage A: `topcoder1/techrecon-merge-policy-staging`):
   the workflow file at `.github/workflows/merge-policy-review-dispatch.yml`
   from the template, with the job condition's repository literals for that
   repository; the entrypoint and its imports at the same commit; the tag
   `merge-policy-review-v4` on that commit; rulesets that forbid updating or
   deleting the tag and creating a same-name branch (the v2 packet procedure);
   the secret `MERGE_POLICY_REVIEW_API_KEY`. Node is pinned in the template
   and load-bearing: the entrypoint's `import.meta.main` guard needs Node
   22.18 or later.
3. In the control repository: `producers/<owner>/<repo>.json` with one entry
   whose `id` and `lane` are `shadow`, whose `repository`, `repositoryId`,
   `workflowId`, `workflowPath` and `workflowRevision` name the tagged workflow
   at the tagged commit, whose `publisherActorId` the policy's
   `reviewActors.shadow` lists, and whose `artifactName` is
   `merge-policy-review-receipt.json`. The `workflowId` is the workflow's
   numeric id (`gh api repos/<repo>/actions/workflows` shows it); it is also
   passed to the producer as an input and compared against the run by the
   intake.
4. The download origin list. Artifact archives redirect to numbered Azure
   storage hosts; the one observed on 2026-09-17 was
   `https://productionresultssa*.blob.core.windows.net` — pass exactly that,
   star included. GitHub picks one of a pool of numbered storage hosts per
   artifact (sa3, sa12, sa14 and sa16 all appeared within five consecutive runs
   of one workflow), so naming them one at a time does not work: the list is
   capped at eight entries and the pool is wider. A single `*` in an origin
   stands for one to three digits at the end of the first host label and nothing
   else, so it widens the allowlist across that one family and no further. A
   cycle that still fails `untrusted_download_origin` met a host outside the
   family; the cycle never prints it (the redirect target is untrusted input),
   so read the `Location` header from
   `gh api -i repos/<producer>/actions/artifacts/<id>/zip`. Adding an origin is
   an intervention.
5. A log location per the plan: `docs/audits/merge-policy-shadow-<start-date>/`
   in techrecon, holding `shadow.jsonl` and the `dispatch/` records.
6. **Land at least one more commit on `main` before the first cycle.** The tag is
   cut at `main`'s head, so until `main` moves, every new pull request's base _is_
   the producer's own source commit and the entrypoint refuses the dispatch with
   `invalid_target` — "the approved producer source is never one of the commits
   under review". Any commit clears it; the producer's own documentation is a
   good one.
7. **Upgrading an installed producer to a new tag** (Stage A moved from `v3` to
   `v4` for the reviewer's schema fix): install the new source at one commit as
   in step 2 — the same workflow path keeps the same `workflowId` — tag it, then
   land another commit per step 6. Switch the producers entry's
   `workflowRevision` to the tagged commit only then; that edit changes the
   authority digest. Until the switch, cycles from `main` pass
   `--workflow-ref refs/tags/merge-policy-review-v3` and keep using the old tag,
   whose own workflow copy still runs; the driver defaults to the new ref.

## One cycle

```bash
node .github/scripts/merge-policy-shadow.mjs cycle \
  --repo topcoder1/techrecon-merge-policy-staging --pr <N> \
  --control-repo <owner>/<control> --producer shadow \
  --download-origin 'https://productionresultssa*.blob.core.windows.net' \
  --dispatch-dir <audit-dir>/dispatch --log <audit-dir>/shadow.jsonl
```

Order of operations, and what each step refuses:

1. **Preflight** (`snapshot` with producers): refuses without paid work when
   the PR is draft or not open (`DRAFT_OR_CLOSED`), when a policy operation is
   still owned or an intake hold is not `completed` (`LOCK_HELD`; a `failed`
   hold is terminal until the owner reconciles it), when the producer id is not
   configured (`UNKNOWN_PRODUCER`), when the live base tip is not an ancestor
   of the head (`STALE_BASE`, from the compare API; the collector would refuse
   the same PR after paying for the run), and when the producer workflow has a
   queued, pending, waiting or running run (`PRODUCER_BUSY`: the workflow's
   concurrency group replaces a pending run with a newer one, so one dispatch
   at a time).
2. **Dispatch record**, written and fsynced to `--dispatch-dir` BEFORE the
   request, mode 0600, never overwritten. It carries the producer entry, the
   target `{repository, pullRequest, headSha, baseSha, policyDigest}`, the
   control blob SHAs and the exact inputs. After the run is found, the record
   is rewritten with `run.id`.
3. **Dispatch**: the newest run id of the workflow is read and stored in the
   record (`runsBefore.newestId`), then `POST .../workflows/<id>/dispatches`
   with the tag name as `ref` and the five inputs. The run is located among
   the workflow's `workflow_dispatch` runs by an id above that one, on the
   tag at the approved revision; timestamps are never compared, so a local
   clock ahead of or behind GitHub's changes nothing. Two candidates refuse
   (`AMBIGUOUS_RUN`).
4. **Wait** for completion (polling every 15 s, 20 min at most). Anything but
   attempt 1 with conclusion `success` is `PRODUCER_FAILED`; nothing is read.
5. **Intake**: the receipt artifact is found by its exact configured name; the
   adapter reads it once through the authenticated client (10 s deadline), and
   `recordReviewIntake` runs with `metadata.target` taken from the dispatch
   record. The intake's second metadata read is a fresh `recheck` of the run,
   its attempt and the artifact. A failed intake is recorded with its closed
   code and leaves the control repo's `failed` hold; provider figures and the
   verdict are still logged.
6. **Provider figures** from the non-acceptance report artifact
   (`merge-policy-review-dispatch.json`), read under the same client checks;
   cost at list price for the pinned model (`PROVIDER_LIST_PRICE`). An
   unreadable report costs the cycle its figures only.
7. **Verdict**: `evaluate` without publication. A hold on
   `REVIEW_INTAKE_UNRESOLVED` after a failed intake is expected.
8. **Log**: one JSON line appended to `--log` (mode 0600).

Exit code 0 when the intake recorded; 1 on a refusal, a failure or a failed
intake (all logged); 2 on usage errors. `preflight` alone runs step 1 and
prints its result. `summarize --log <file>` prints the Section 4 metrics.

## Log schema (`merge-policy-shadow-cycle-v1`)

| Field                       | Content                                                                                                                                                                                                                                                                                     |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `startedAt`, `finishedAt`   | UTC timestamps                                                                                                                                                                                                                                                                              |
| `repository`, `pullRequest` | The application PR                                                                                                                                                                                                                                                                          |
| `facts`                     | Live head, live base, `policyDigest`, policy and producers blob SHAs, ledger revision at preflight                                                                                                                                                                                          |
| `refusal`                   | `{code, detail}` when preflight refused; the cycle ends there                                                                                                                                                                                                                               |
| `producer`                  | The producer entry used, with `workflowRef`                                                                                                                                                                                                                                                 |
| `dispatch`                  | `recordPath`, `dispatchedAt`, `run {id, attempt, status, conclusion}`, `artifactId`                                                                                                                                                                                                         |
| `intake`                    | `outcome: recorded` with `receiptId`, `receiptSha256` (the exact receipt bytes), `archiveSha256`, `changed`, `ledgerRevision`, `ledgerSha`, `review {outcome, findingCount, findings[{key, priority, path, title}]}`; or `outcome: failed` with `failure {name, code, message, retainLock}` |
| `provider`                  | `{model, inputTokens, outputTokens, costUsd}` or `{unavailable: <code>}`                                                                                                                                                                                                                    |
| `verdict`                   | `{decision, reasons[{code, findingId? \| reason?}], openFindings[{findingId, priority, path, title, blocking}], pendingReviews}`; a hold on an unresolved intake carries the hold's phase in `reason`                                                                                       |
| `durationsMs`               | Per step                                                                                                                                                                                                                                                                                    |
| `interventions`             | `{count, note}`: written as `0`; the operator edits the line when a cycle needed a hand (a cleared hold, an added origin, a redispatch)                                                                                                                                                     |
| `triage`                    | `null` until triage; then `{outcome, findings, k4?, note?}` (below)                                                                                                                                                                                                                         |
| `failure`                   | `{name, code, message, retainLock}` when a step other than intake failed                                                                                                                                                                                                                    |
| `enforcementPublished`      | Always `false`                                                                                                                                                                                                                                                                              |

If a line would exceed 64 KiB or the append fails, the driver appends the line once more with the finding lists replaced by counts and marks the entry `logReduced`; if that fails too, the entry carries `logFailure` and the cycle exits 1. The entry the driver returns and prints to stdout is always the complete one; only the persisted line is reduced.

Finding ids are per receipt (`<receipt id>finding:<index>`, the receipt id
being a digest of the run selector, not of the receipt bytes): a re-review of
the same head records its findings again, and every set stays open until
disposed of. Triage counts a hold by receipt, not by open finding.

## Triage protocol (weekly, 30 minutes)

For each logged cycle without `triage`, the owner (a session may pre-fill and
propose) sets:

- `triage.outcome`: `merged_as_is`, `merged_after_changes`, `closed`, or
  `open` (still open; revisit).
- `triage.findings`: one label per blocking finding of that cycle's receipt,
  keyed by `findingId`: `true_positive`, `false_positive`, `should_be_p3`.
  A hold caused only by a finding the re-review no longer reports is
  `needs_disposition` in `triage.note`, not disagreement.
- `triage.k4: true` on any K4 event (below), with the evidence in `note`.
- `interventions.count` and `note` corrected for what the cycle needed.

Then `summarize`. Its `kill` and `success` objects are computed where the data
allows and `null` where triage has not supplied it; K5 is counted by hand.

## Kill and success criteria (Section 4 of the plan, verbatim)

Cost basis: the pinned model `claude-sonnet-4-6` (`merge-policy-anthropic-review.mjs:7`); the v2 comparison used about 36.9K input and 1.5 to 2.2K output tokens, about $0.14 per review at list prices; the 512 KiB packet cap (`merge-policy-review-comparison.mjs:18`) bounds one review near $0.65.

**Kill (any one stops the phase and parks the pilot; evaluated at each weekly triage):**

- **K1 Agreement.** After 20 blocking findings or 20 Stage B PRs: blocking-finding precision (TP / (TP + FP)) below 50%, or more than 40% of `merged_as_is` PRs held on findings the owner labels false.
- **K2 Cost and fit.** Mean provider cost above $0.75 per review, any single review above $1.50, median reviews per merged PR above 3 (re-reviews forced by base moves), or more than 50% of Stage B PRs refused by the collector (`STALE_BASE`, or the file and byte limits at `merge-policy-review-comparison.mjs:9-21`).
- **K3 Operations.** More than 2 operator interventions in any week (manual control-repo edits to clear `failed` holds or retained locks, redispatches), or intake failure on 2 of any 5 consecutive successful producer runs.
- **K4 Security (immediate, no threshold).** Any credential or token in logs, artifacts, errors or the shadow log; any receipt admitted from a non-tag ref, attempt > 1, or with a target not equal to the dispatch record; any workflow change reaching the tag without the packet procedure.
- **K5 Budget.** More than 5 owner click-merges attributable to this phase (2 for Stage A, 1 for Stage B, 2 in reserve), or calendar date 2026-10-31 without the Stage B sample.

**Success (all required to open the enforcement decision):** the Stage B sample reached; precision at least 70%; intake success on at least 90% of successful producer runs; at most 1 intervention per week over the last 3 weeks; mean cost at most $0.50 per review; zero K4 events; at least 3 `pass` verdicts on merged PRs and 3 holds with owner-confirmed true positives; a written answer to owner decision 6 (who may dispose findings).

## Failure modes and recovery

| Seen                            | Meaning                                                                 | Do                                                                                                                                                                   |
| ------------------------------- | ----------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `LOCK_HELD (intake failed)`     | The last intake for this PR failed; the hold is terminal                | Owner reconciles the lock in the control repository (the intake's documented recovery). Count one intervention.                                                      |
| `LOCK_HELD (operation active)`  | Another operation owns the lock (a crashed cycle, or one still running) | Find the owner in the lock document; `recover` per the controller's docs once it has stopped. Count one intervention.                                                |
| `PRODUCER_BUSY`                 | A run is queued or running                                              | Wait; never dispatch a second run into the concurrency group.                                                                                                        |
| `AMBIGUOUS_RUN`                 | Two runs match the dispatch                                             | Identify the run by hand in the Actions UI; do not redispatch blindly. The record has no run id; note it in `interventions`.                                         |
| `RUN_NOT_FOUND` / `RUN_TIMEOUT` | No run appeared in 90 s, or none completed in 20 min                    | Check the Actions UI; a run that completes later can be taken in with a manual `intake` only after a code change that adds one (not in this version).                |
| `PRODUCER_FAILED`               | Attempt ≠ 1 or conclusion ≠ success                                     | Read the failure evidence artifact; a rerun is never admissible, dispatch a fresh cycle.                                                                             |
| `untrusted_download_origin`     | The archive redirected to an origin not listed                          | The cycle does not print it: read the `Location` header from `gh api -i repos/<producer>/actions/artifacts/<id>/zip`, add the origin, rerun. Count one intervention. |
| intake `binding_mismatch`       | The receipt's target or producer is not what was dispatched             | K4 candidate: compare the receipt against the dispatch record before anything else.                                                                                  |

Never redispatch the consumed `v1`/`v2` tags or alter their protections; never
paste receipt bytes into any command (the CLI accepts none); never run a cycle
with a token other than the owner's `gh` session.
