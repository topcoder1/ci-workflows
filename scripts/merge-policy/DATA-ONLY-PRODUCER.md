# Data-only review producer

`createReviewProducer` executes the missing measurement and reviewer protocol: it reads actual local Git objects, sends the measured before/after text through one data-only provider call and emits the existing canonical receipt. It does not accept a caller-supplied clean result, run PR code, publish checks or connect to controller intake.

This source is not an authenticated live producer. A trusted caller supplies the dispatch repository, workflow/run and target context. The result explicitly retains `githubIdentityAuthenticated: false`, `executionAuthenticated: false` and `enforcementPublished: false`. A valid receipt shape is not proof of those identities.

## Execution flow

1. Snapshot and validate the exact dispatch envelope `{producer, target, lane}`. Producer and target fields are the existing receipt fields; only run attempt 1 is supported. Unknown fields, accessors, proxies, malformed identities and invalid options refuse before credentials.
2. `collectReviewComparison({repositoryPath, baseSha, headSha}, {signal, deadlineMs})` measures the actual SHA-1 commits, unique merge base, changed-file inventory and complete before/after blob text. The base must be an ancestor of the head. Empty comparisons stop before a provider request.
3. `createAnthropicReviewer({tokenProvider, fetchImpl}).review(comparison, options)` sends the measured packet as JSON data to the fixed Messages endpoint and fixed `claude-sonnet-4-6` model, with a static structured-output schema and no tools, CLI, MCP, files API or automatic retry.
4. Accept only an HTTP 200 assistant message from the exact model with one valid text result, `end_turn`, no refusal details and an explicit `complete: true`. The locally checked complete finding set must match its outcome/count, contain unique keys and refer only to measured paths. Missing completion, partial output, duplicate JSON keys, malformed fields or contradictory outcomes fail. Model text never supplies producer, run, target or policy identity.
5. Build the existing receipt with every validated finding and the snapshotted dispatch context. Return frozen data, defensive receipt bytes and SHA256 digests of the receipt, comparison, provider input/output and request. No receipt is returned if the final canonical bytes exceed 64 KiB.

Explicit completion records the model's assertion and successful protocol delivery. It does not prove that the model examined every token, found every real defect or correctly interpreted the code. A later clean review must not erase durable earlier findings. Failure/partial-finding recording and invalidation of prior acceptance still need to be implemented in the authenticated controller integration; this source does not manage that state.

## Git measurement boundary

The repository path and local Git installation/object store belong to the trusted caller. The collector never authenticates a GitHub remote or infers repository identity from `.git/config`. It uses `/usr/bin/git` with fixed plumbing commands and scrubbed execution overrides. It disables replacement objects, lazy fetch, external diffs/text conversion, hooks and checkout; complete blob contents prevent `.gitattributes` from hiding review input through a patch driver.

Commit and blob bytes are checked against their object IDs. Tree traversal and local object-store integrity remain the trusted Git implementation's responsibility. This is not an adversarial `.git` filesystem verifier. It requires Git with `--no-lazy-fetch` support and SHA-1 repositories. Shallow history, grafts, ambiguous/non-ancestor comparisons, symlinks, submodules, binary/invalid text and unsafe paths refuse.

Initial limits are 32 changed files, 64 KiB per blob, 256 KiB of aggregate before/after text and a 512 KiB measured packet. Duplicate content appearing in multiple file snapshots still counts toward the aggregate limit. There is no truncation or partial-review fallback. Git subprocesses share a monotonic deadline and output caps; cancellation stops their process groups. The producer's own deadline spans Git measurement and the provider call.

## Provider and invocation boundary

Import and construction do not look up credentials or perform I/O. The caller injects a trusted `tokenProvider` and optionally a trusted native-fetch-compatible transport. `produce({repositoryPath, dispatch}, {signal, deadlineMs})` is the first executing operation. Provider input contains measured comparison data only; API key and dispatch authority are excluded from model messages.

The request uses a fixed first-party endpoint, bounded input/output bytes and at most 8,192 generated tokens. Redirects are refused and raw errors, paths, model output and credential values are not reflected in error messages. Only one request is made; a timeout does not establish that no provider work was billed. Byte/token limits bound work but do not guarantee an exact dollar cost.

`claude-sonnet-4-6` is a fixed snapshot, and the response must match that identifier. The API's structured-output support does not enforce every semantic constraint, so completion, bounds, duplicates and finding consistency are independently checked. [Model versioning](https://platform.claude.com/docs/en/about-claude/models/model-ids-and-versions), [Messages API](https://platform.claude.com/docs/en/api/messages/create), [structured outputs](https://platform.claude.com/docs/en/build-with-claude/structured-outputs)

## Remaining live setup

This change adds no producer workflow, dispatch command, App permission, secret configuration, policy administration or acceptance adapter. The existing reusable Claude workflow uses `ANTHROPIC_API_KEY`; its availability to a future staging producer is not assumed.

Before a live probe, approve the entire immutable executing workflow and dependencies, exact target/dispatch/ref/bootstrap route and protected producer authority. Only then bind the complete receipt to authenticated run/artifact facts. For an initial first-attempt-only design, recheck that the current run remains attempt 1 before intake and reject any rerun or artifact replacement. Runtime artifact-upload authority belongs to the whole workflow execution, not exclusively to a finalizer job; untrusted earlier jobs cannot be made safe merely by adding a separate finalizer.

Private staging currently has no registered actual producer workflow, and its main checks/control protections must remain intact. Synthetic local Git fixtures and mocked provider responses establish source behavior only. Actual authenticated reviewer execution, partial-failure handling, live atomic persistence, recovery/race probes and a clean accepted merge remain separate acceptance work.

## Validation

Run all policy suites with `node --test selftest/test_merge_policy_*.mjs`. The comparison tests use actual independent local Git fixtures. Provider tests use mocked responses. Producer tests connect the real collector and provider protocol to canonical receipt creation and then validate that wire format through an explicitly synthetic existing-intake fixture. They do not send code or credentials to a model service.
