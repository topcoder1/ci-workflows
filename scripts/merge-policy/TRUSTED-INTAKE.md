# Trusted structured-review intake

`prepareReviewIntake` in `.github/scripts/merge-policy-intake.mjs` converts a complete structured review receipt into a validated candidate ledger. It is disconnected from GitHub, credentials, persistence and check publication. The existing Claude and Codex review workflows are not connected to it.

The module accepts a protected producer allowlist, current protected policy/context/ledger, a receipt selector and two injected readers. It verifies the complete batch before returning anything. Finding events precede the terminal review event. Existing findings remain open until separately disposed of through the policy's authorized process; a later clean review does not close them.

## Trust inputs

The caller must run trusted code outside the application PR's execution environment. Neither an artifact's claims nor a JSON object supplied by a PR author authenticates a review. The readers are trusted adapters, not user-supplied callbacks.

Each protected producer entry has these exact fields:

| Fields                                           | Meaning                                                                                                                                                            |
| ------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `id`                                             | Local producer selector. It does not establish authority or define receipt replay identity.                                                                        |
| `repository`, `repositoryId`                     | Expected producer repository name and immutable numeric identity.                                                                                                  |
| `workflowId`, `workflowPath`, `workflowRevision` | Approved workflow identity, path and exact 40-character lowercase commit SHA.                                                                                      |
| `lane`, `publisherActorId`                       | Review lane and authenticated publishing principal mapped by protected configuration. The actor must be authorized for that lane and different from the PR author. |
| `artifactName`                                   | Exact expected JSON artifact name.                                                                                                                                 |

Approve the complete executing producer and its dependencies. Pinning a workflow path, an actor name or only one reusable workflow is insufficient if that execution downloads mutable scripts, executes PR code or accepts author-provided review results. Producer entries with the same repository ID, workflow ID and revision are rejected as ambiguous. One producer run represents one review lane.

`policy`, `context` and `ledger` use the existing core/state contracts. The caller must obtain authoritative live context and use the controller's current authority digest. That digest includes exact protected policy and producer bytes when producers are configured; it remains the legacy policy-only digest only for a repository with no producer configuration history. The intake snapshots these inputs before asynchronous reads. This protects it from caller mutation; it does not replace a later live-context and policy recheck before persistence/publication.

## Reader contract

The request is exactly `{producerId, runId, runAttempt, artifactId}`. Both readers receive the frozen selector `{repository, runId, runAttempt, artifactId}` and `{signal, deadlineMs, maximumBytes}`. Metadata is read before and after the artifact. The second read must freshly verify the run's current latest attempt and the same authenticated artifact identity; it must not return stale cached run metadata.

The metadata reader returns this exact normalized schema:

```text
schemaVersion: 1
producer:
  repository, repositoryId, workflowId, workflowPath, workflowRevision,
  runId, runAttempt
target:
  repository, pullRequest, headSha, baseSha, policyDigest
status: "completed"
conclusion: "success"
latestRunAttempt: <current attempt number>
artifact:
  id, name, byteLength, sha256
```

These are adapter-attested facts, not a claim that the GitHub REST run response natively supplies every field. The adapter must independently authenticate actual producer execution and the exact commit pair it reviewed. It must not copy the payload's provenance fields into metadata, infer completeness from a green job, or stamp current PR metadata onto a review of different commits. Failed, skipped, running and superseded attempts are refused.

The artifact reader returns a bounded `Buffer` or plain `Uint8Array` containing the exact receipt bytes. The metadata digest is SHA256 of those exact JSON bytes. GitHub archive digests and inner-file digests are different: a real archive adapter must verify the authenticated outer archive digest, enforce archive/extraction limits, and bind the extracted receipt bytes to that verified artifact. It must not blindly use an archive digest as the JSON digest or trust a manifest supplied by the application PR. A digest-mismatch warning is insufficient; mismatches must fail intake.

Adapters must enforce streaming byte limits, request deadlines, cancellation, endpoint/redirect restrictions and authentication before returning. The module's byte checks and abort signal are additional checks; JavaScript cannot stop a reader that ignores cancellation, blocks synchronously or has already allocated an oversized response. Adapter exceptions are replaced by fixed error codes so response bodies and credentials are not returned.

## Receipt format

The wire format is UTF-8 bytes produced by `JSON.stringify(receipt)`, with no BOM, indentation or trailing newline. This intentionally strict format rejects duplicate keys and alternate representations. Property order need not be sorted, but the exact bytes are bound by the authenticated digest.

The receipt has exactly these fields:

```text
schemaVersion: 1
producer: <same exact producer/run fields as metadata>
target: <same exact target fields as metadata>
lane: <protected producer lane>
complete: true
outcome: "clean" | "findings"
findingCount: <exact findings array length>
summary: <nonempty original text>
findings:
  - key, title, priority, path, reason
```

`clean` requires zero findings. `findings` requires at least one. Every finding needs a unique lowercase key, original title/reason, priority 0–3 and a repository-relative path. Case is preserved. Missing fields, unknown fields, contradictory outcomes, duplicate findings, malformed paths and partial finding counts fail. Prose is never parsed into a clean outcome. This version accepts no disposition or not-applicable receipts; those need a separately reviewed authorized path.

Bounds are 64 KiB per receipt, 16 KiB normalized metadata, 64 findings, 16 producer entries, 4,096 ledger events, and two seconds per reader call. Input structures also have depth, node and text limits. Accessors, sparse arrays, hidden properties and cycles are refused. Shared-memory bytes and byte-array subclasses are refused.

## Candidate batch and replay

The output contains `receiptId`, `artifactSha256`, `publisherActorId`, `events`, a candidate `ledger`, `changed` and `enforcementPublished: false`. Event actors come from protected producer configuration. Event evidence links point to the verified run attempt. The terminal event commits to metadata and producer configuration, including the exact artifact digest.

Receipt identity is derived from immutable producer repository ID, workflow ID, run ID and run attempt. It deliberately excludes the caller's alias, artifact ID, content digest and workflow revision, so replacing any of those cannot turn a changed delivery into a new receipt for the same run. Identical deliveries are idempotent, including at ledger capacity. Changed duplicates and partially persisted receipts fail; intake does not silently finish or repair them.

All events are validated through the existing `appendEvent` journal contract against a copied ledger. A bad later finding or terminal review therefore yields no partial candidate and changes no caller state. A consumer must persist the complete candidate in one conditional write against the exact ledger revision it read, under the controller's lock, and recheck live head/base/policy before publishing. Do not feed this batch through independent single-event `record` calls and claim atomic intake. The separate `PolicyController.recordReviewIntake` API now implements that batch-persistence step, with a protected producer document, conditional lock, current-context/configuration checks and authoritative readback. It calls this validator itself; it does not accept a caller-supplied candidate. The pure intake module still performs no persistence or publication.

## Protected controller integration

### Durable intake hold

The controller stores a schema-2 `intake` object in the existing per-PR lock
document. The initial owner and `validating` hold are written in the same
conditional update, so a process crash cannot leave an operation owner without
an unresolved durable block. The hold carries the immutable selector, the
current target and producer binding, the ledger revision before intake, the
candidate receipt and ledger digest, and (when a publishing integration is
used) the check identity and decision digest.

The phases are `validating`, `ledger_pending`, `receipt_committed`,
`publication_pending`, `failed` and `completed`. Every snapshot and decision
reads the lock; any phase other than `completed` returns
`REVIEW_INTAKE_UNRESOLVED`, even when an older clean review is present. Ordinary
evaluation, event recording, unlock and stopped-owner recovery preserve the
hold. A definite validation rejection records a bounded failure code before
releasing the owner; an uncertain ledger, lock or check write retains the
owner for exact reconciliation. Recovery changes the lock sequence while
retaining the intake operation identity and unresolved phase.

The durable state is intentionally separate from GitHub check publication.
The protected-state CAS and a remote check update cannot be one transaction, so
`publication_pending` is reconciled only with the exact lock SHA, generation,
operation ID, check identity and current target/configuration. Timestamps are
diagnostic and never expire a hold automatically. The implementation and its
state-machine tests live in `.github/scripts/merge-policy-intake-hold.mjs` and
`selftest/test_merge_policy_intake-hold.mjs`.

The controller loads `producers/<owner>/<repo>.json` from the separate control repository. Its exact envelope is `{ "schemaVersion": 1, "repository": "owner/repo", "producers": [...] }`, where each producer entry follows the contract above. The document is pinned to the same immutable control commit as policy and ledger, and its blob identity is rechecked after the asynchronous readers finish and during persistence confirmation. Its exact bytes also participate in the authority digest used by all controller evaluations, so producer changes invalidate prior acceptance. A missing document with reachable path history fails closed instead of resurrecting legacy policy-only reviews. This does not make already-published GitHub checks immediately self-invalidating; trusted change triggers and live enforcement validation remain required.

The operation accepts only the request selector and trusted reader adapters. It retains the operation lock around intake, the single whole-ledger conditional write and readback. Definite pre-write failures cannot persist any receipt event; uncertain mutation outcomes retain the lock and require reconciliation. Identical complete replay performs no ledger write. No check publication, merge, new CLI command or workflow activation is connected to this API.

## Disconnected artifact retrieval

`merge-policy-github-artifact.mjs` retrieves authenticated GitHub run and artifact storage facts and verifies the downloaded archive. `merge-policy-artifact-zip.mjs` extracts one exact receipt filename in memory. These are building blocks for the reader contract above; they do not return acceptance-capable intake metadata or connect to `recordReviewIntake`.

The GitHub client reconstructs its API endpoints from validated selectors and copied producer configuration. It reads the current run, selected attempt and artifact, requires the approved repository/workflow/commit identities and a completed successful latest attempt, and rechecks run/artifact identity after downloading. The supported producer mode is a direct `workflow_dispatch` at an approved revision, with a bare workflow path or that path suffixed by the exact approved SHA and explicit empty referenced-workflow/PR arrays. Without the explicit tag option below, named path suffixes, other execution modes and reusable workflow ambiguity fail closed. The caller supplies trusted authentication and an explicit set of allowed storage origins. Construction/import does not read credentials or perform I/O.

A trusted caller may explicitly set `producer.workflowRef` to a restricted lightweight tag such as `refs/tags/merge-policy-transport-probe-v1`. This mode requires attempt1 and accepts only `workflowPath@<tagName>` or `workflowPath@refs/tags/<tagName>`, with an exact matching native `head_branch`. Before and after archive retrieval, authenticated exact-ref reads must bind the tag to the approved workflow revision and show that a same-name branch is absent. Annotated tags, moved/deleted tags, ambiguous branches, other HTTP statuses, path mismatches and reruns fail closed. The additional `currentTagRefSnapshot` is frozen and contains only the current ref and commit SHA. Existing callers without this option retain their original request sequence and result shape.

Current snapshots cannot prove dispatch-time namespace/protection or detect a transient create/delete between reads. Actual native tag-dispatch compatibility is still unverified; the no-model probe must establish it under independent creation/update/deletion controls. This option requires Contents read as well as Actions read, grants neither, and preserves all false provenance/enforcement flags. A matched named suffix is not execution authentication.

Authenticated API requests do not automatically follow redirects. The archive download permits one validated HTTPS storage redirect and sends no GitHub authorization header to storage. Streaming bounds and a shared deadline apply across the operation, including response bodies and cancellation. An injected fetch implementation must follow native Node fetch's decoded-response-stream contract: single gzip/deflate/br encodings are supported, with separate bounds for declared wire size and decoded bytes; unsupported or stacked encodings fail closed. The authenticated outer archive SHA256 and byte length must match the decoded archive bytes. Neither signed download URLs nor raw API/credential errors belong in logs or surfaced errors.

The ZIP extractor accepts one expected top-level JSON file within fixed archive and decompressed-byte bounds. It checks archive structure, CRC and local/central directory consistency, and rejects unsafe or unsupported formats. The producer must upload a single-file ZIP; raw-file uploads (`archive: false`) are unsupported. Extraction performs no filesystem writes. Its output is still untrusted receipt content, and its inner JSON digest is distinct from the authenticated archive digest.

Storage authentication does not establish which commits a reviewer examined. In particular, GitHub's artifact metadata binds a workflow run but does not expose the artifact's run attempt. The client therefore returns `artifactAttemptAuthenticated: false`, `executionComparisonAuthenticated: false` and `enforcementPublished: false`. A separately reviewed execution verifier must bind the exact inner receipt digest to the producer attempt and actual reviewed repository/PR/head/base/policy before a future adapter can return the normalized intake metadata. Copying those fields from the receipt or current PR would not provide that verification.

These modules require a trusted caller outside PR-controlled execution. Reading Actions metadata/artifacts requires Actions-read access; the current staging App does not have that permission. This source change does not enlarge its permissions, create credentials, publish checks, configure producers or change any production consumer.

## Existing producers and validation limits

The separate [data-only producer implementation](DATA-ONLY-PRODUCER.md) now measures an ancestor-only local comparison, makes one structured API call with no tools and emits the existing canonical receipt after explicit completion. Its library result still reports GitHub identity and execution authentication as false. The dispatch context must come from a separately trusted caller; these new files do not make the existing workflows below acceptable intake sources or authenticate a first-attempt execution.

Current Claude output is primarily comments and a local transcript; its delivery guard does not prove the complete finding set. Current Codex output is prose plus a classifier that can call unrecognized nonempty text clean. Codex also reviews a default merge checkout with a separately fetched base. Neither is an acceptable structured receipt or actual-comparison attestation. Their mutable workflow/helper references must also be addressed before trusted integration.

The next live integration must add opt-in complete structured output, capture the actual reviewed commits, authenticate the approved workflow and executable dependencies, and retrieve the artifact with the bounds above. Keep existing comments as presentation. Synthetic tests exercise this module's validation behavior; they do not prove model completeness, real producer authenticity, App-source enforcement or merge blocking.

Run the focused tests with:

```sh
node --test selftest/test_merge_policy_intake.mjs
```
