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

`policy`, `context` and `ledger` use the existing core/state contracts. The caller must obtain authoritative live context and compute its policy digest from exact protected policy bytes. The intake snapshots these inputs before asynchronous reads. This protects it from caller mutation; it does not replace a later live-context and policy recheck before persistence/publication.

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

All events are validated through the existing `appendEvent` journal contract against a copied ledger. A bad later finding or terminal review therefore yields no partial candidate and changes no caller state. A consumer must persist the complete candidate in one conditional write against the exact ledger revision it read, under the controller's lock, and recheck live head/base/policy before publishing. Do not feed this batch through independent single-event `record` calls and claim atomic intake. That batch-persistence integration is not implemented here.

## Existing producers and validation limits

Current Claude output is primarily comments and a local transcript; its delivery guard does not prove the complete finding set. Current Codex output is prose plus a classifier that can call unrecognized nonempty text clean. Codex also reviews a default merge checkout with a separately fetched base. Neither is an acceptable structured receipt or actual-comparison attestation. Their mutable workflow/helper references must also be addressed before trusted integration.

The next live integration must add opt-in complete structured output, capture the actual reviewed commits, authenticate the approved workflow and executable dependencies, and retrieve the artifact with the bounds above. Keep existing comments as presentation. Synthetic tests exercise this module's validation behavior; they do not prove model completeness, real producer authenticity, App-source enforcement or merge blocking.

Run the focused tests with:

```sh
node --test selftest/test_merge_policy_intake.mjs
```
