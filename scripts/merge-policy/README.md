# Merge acceptance pilot

This is an opt-in building block for a TechRecon staging pilot. It does not change any existing repository protection, review lane or auto-merge workflow. Other projects can reuse the engine with their own reviewed policy; there is no fleet-wide activation.

The engine requires completed, trusted reviews and persistent disposition of material findings. Existing native CI checks remain authoritative. The GitHub adapter stores policy and history outside the application repository, serializes operations with conditional Git-backed locks, and publishes `merge-policy / decision` from an expected dedicated App.

## Trust boundary

Run this adapter only in a trusted control environment. Never pass an application PR's arbitrary JSON to the App and treat it as an independent review. The App authenticates the publisher; the trusted review workflow must separately produce or verify the review's evidence. Staging synthetic receipts test mechanics, not actual model review quality.

Keep the App credential out of application repositories and PR-controlled jobs, caches and artifacts. Policy files, journal records and locks belong in a separate protected private control repository. The adapter currently reads its `main` branch. Grant the App only the repository permissions necessary for the selected staging/control repositories: checks write on the target, metadata/PR/content read for context, and content write for the control state. GitHub permissions apply per installation; use separate installations/identities if different repository scopes require stricter separation.

Do not use the shared GitHub Actions identity as a substitute for the dedicated App in production: a source-bound check tied to the shared identity does not distinguish trusted from arbitrary workflows.

Mutable review-comment bodies are intentionally not an authenticated intake. Human operators may submit an event file using their authenticated `gh` identity. A publishing App may submit only evidence generated or verified by its trusted workflow. Reviewer/disposition principals must be explicitly allowlisted and different from the PR author. An App's bot ID is resolved from the actual check-publisher identity; callers cannot supply an actor ID to override it.

The separate [trusted receipt intake](TRUSTED-INTAKE.md) validates structured review artifacts against protected producer configuration and independently obtained run metadata before producing a complete event batch. It has no persistence or publishing path. Its injected adapters must authenticate the real producer and retrieve the bounded artifact; synthetic adapter tests do not establish that trust. The existing Claude and Codex review lanes are not connected to this intake.

## Control files

For application `owner/repo` and PR 17:

- `policies/owner/repo.json`: reviewed per-project policy.
- `state/owner/repo/17.json`: append-only ledger with revision equal to event count.
- `locks/owner/repo/17.json`: operation owner, sequence, start time, process/run identity and check receipt.

The adapter distinguishes a never-initialized ledger from previously recorded state that is now missing using the control repository's file history. Missing historical state requires restoration. A first evaluation without review records publishes a failure, not success.

Policy shape:

```json
{
  "schemaVersion": 1,
  "repository": "example/application",
  "requiredReviews": ["independent"],
  "reviewActors": { "independent": [200] },
  "dispositionActors": [300],
  "findingActors": [200, 300],
  "allowNotApplicable": {},
  "blockingPriorityMax": 2
}
```

Actor IDs above are synthetic, not configured accounts. Bind real reviewer actors to the trusted review integration before activation. The adapter computes the policy digest from the exact protected policy bytes. Review and disposition records must match the current head, live base and policy digest. Historical findings persist across unrelated commits; a new clean review does not close them. v1 conservatively requires targeted revalidation of closed dispositions after any binding changes.

## Commands

Use Node 22 or newer and an authenticated `gh` CLI. Do not put tokens in command arguments. A trusted workflow can supply its App installation token through `GH_TOKEN`; the adapter never prints authentication values or raw API failures.

```sh
node .github/scripts/merge-policy-github.mjs snapshot \
  --repo owner/repo --pr 17 --control-repo owner/policy-control

node .github/scripts/merge-policy-github.mjs evaluate \
  --repo owner/repo --pr 17 --control-repo owner/policy-control

node .github/scripts/merge-policy-github.mjs record \
  --repo owner/repo --pr 17 --control-repo owner/policy-control \
  --event /absolute/path/to/verified-event.json

node .github/scripts/merge-policy-github.mjs evaluate \
  --repo owner/repo --pr 17 --control-repo owner/policy-control \
  --publish --expected-app-id 123456
```

`record --publish --expected-app-id ...` uses the authenticated dedicated App principal and publishes the updated decision. The App must independently verify the event before this call. Non-publishing commands return `enforcementPublished: false`; they do not claim GitHub is holding the PR. CLI exit codes: 0 for accepted/read-only utility results, 1 for a policy hold, and 2 for invalid input or infrastructure failure. A recorded finding commonly exits 1 because the resulting decision correctly blocks merging; do not blindly resubmit it. Identical event IDs are idempotent, while changed duplicates are rejected.

Events share `id`, `type`, `headSha`, `baseSha`, `policyDigest`, nonempty `reason` and an HTTPS GitHub `evidenceUrl`. The journal assigns authenticated `actorId`. A finding adds `findingId`, `title`, priority 0–3 and repository-relative `path`. A review adds `lane`, `outcome` (`clean`, `findings`, `not_applicable`, `error`) and `findingIds`. A findings review must reference previously delivered finding records in the same scope. A disposition adds `findingId`, action (`fixed`, `disproved`, `accepted_risk`, `reopen`), and a strictly valid UTC `expiresAt` for accepted risk. Consult the engine tests for complete valid examples.

## Publication and recovery

Publishing starts an in-progress check before evaluating evidence and replaces it with success or failure. Invalid/unavailable evidence completes the started check as failure when the API is available. Conditional locks prevent cooperating record/publish operations from overlapping. Live context and control document versions are checked again before the final write, then the decision is recalculated using the current clock so an acceptance that expired during verification cannot pass. Same-head multiple-PR associations are conservatively held.

The lock is not automatically stolen on a timer. It records enough identity to verify that the previous operation stopped. Recovery checks a completed Actions run, or an absent local process on its recorded host; it refuses active or unverifiable owners. Recovery first claims a new owner and the current process/run identity with a conditional write. Competing recovery attempts cannot publish checks after losing that claim. Recovery publishes failure, conditionally clears only its claimed lock, and never approves the PR.

```sh
node .github/scripts/merge-policy-github.mjs inspect-lock \
  --repo owner/repo --pr 17 --control-repo owner/policy-control

node .github/scripts/merge-policy-github.mjs recover \
  --repo owner/repo --pr 17 --control-repo owner/policy-control \
  --expected-owner EXACT_OWNER --expected-lock-sha EXACT_BLOB_SHA \
  --expected-app-id 123456
```

After recovery, reevaluate current state. If a preceding event write had an uncertain result, inspect the journal and retry the same event ID only if necessary. Do not delete history or change event IDs to conceal uncertainty. A scheduled reconciler should enumerate only opted-in projects and open eligible PRs; it must not automatically recover a lock whose owner cannot be proven stopped.

Limits remain explicit: check writes and merge operations are not one atomic transaction; a newly arriving external finding can race with a merge. A timestamp inside a result is not a GitHub-enforced expiry. An outage after success can prevent immediate revocation. The current implementation therefore does not claim instantaneous enforcement of arbitrary later comments or production readiness before the staging matrix passes.

## Staging and rollout

1. Use synthetic content in a dedicated staging repository and isolated control state.
2. Install the dedicated App only on those repositories; provision its credential in a trusted control environment.
3. Configure a real required check bound to that App, retain independent CI, and prevent ordinary bypass during the staging cases.
4. Verify absent review, open finding, unrelated push, stale review, unauthorized disposition, expiry, duplicate event, deleted state, stale publisher, API outage, lock recovery and ambiguous shared-head cases. Verify a clean case can merge automatically. Test manual and API paths against the same enforcement.
5. Prove application PRs cannot acquire the App credential, modify the authoritative policy/ledger, or satisfy the required context with a different publisher.
6. Only then wire actual trusted reviewer receipts and run observationally on TechRecon. No production enforcement is enabled by these source files.

`node --test selftest/test_merge_policy_core.mjs selftest/test_merge_policy_state.mjs selftest/test_merge_policy_github.mjs selftest/test_merge_policy_intake.mjs` runs the local deterministic and mocked-API checks. These tests do not substitute for authenticated live review producers, App-source enforcement and live merge tests on GitHub.
