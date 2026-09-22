# Current-target review dispatch package

This inactive source package is PR-A of the [shadow phase plan](../SHADOW-PHASE-PLAN.md): the fixed historical probe generalized to review the pull request named by a `workflow_dispatch`. It is not an execution verifier, an intake adapter or a merge-policy acceptance adapter. No provider call, dispatch, installation, secret configuration or enforcement change is performed by adding these files, and no producer is registered anywhere.

## Operation

The future entrypoint is `.github/scripts/merge-policy-review-dispatch.mjs`. Its CLI accepts no arguments. The target comes from the dispatch inputs, each of which the template maps to an `INPUT_<NAME>` environment variable and never into a shell line:

| Input           | Meaning                                                      | Accepted form                            |
| --------------- | ------------------------------------------------------------ | ---------------------------------------- |
| `pull_request`  | The pull request under review                                | Positive integer, no sign, no leading 0  |
| `head_sha`      | The head commit under review                                 | 40 lower-case hex                        |
| `base_sha`      | The live base commit the review is bound to                  | 40 lower-case hex, not equal to the head |
| `policy_digest` | The authority digest of the policy and producer documents    | 64 hex                                   |
| `workflow_id`   | The registered id of this workflow in the producers document | Positive integer                         |

The inputs are trusted caller input: only the owner can dispatch a private repository's workflow. They are validated before any Git or credential work and authenticated nowhere in this package. The intake authenticates the run through the API and compares the receipt's target with the target its caller supplies from the dispatcher's own durable record; a receipt whose target differs is refused there. `workflow_id` is an input rather than an API lookup so that the workflow requests no `actions: read` permission; the intake compares the run's real workflow id with the registered one, so a wrong value only fails intake.

Fixed values: the review lane is `shadow`; the dispatch ref is `refs/tags/merge-policy-review-v4`; the workflow path is `.github/workflows/merge-policy-review-dispatch.yml` in the repository whose pull requests it reviews; the supported attempt is `1`; the provider is the existing `claude-sonnet-4-6` data-only producer, one request, no tools or retry. The repository and its id are taken from the runtime and pinned by the template's job condition, whose literals are the staging repository's; a techrecon packet edits those literals and nothing else. No expected comparison digest exists for a live target, so the producer's optional `expectedComparisonSha256` is not used. The template's Node pin is load-bearing: the entrypoint's `import.meta.main` guard needs Node 22.18 or later, and on an older runtime the CLI is a silent no-op that exits 0 and the upload steps fail on missing files.

The workflow's concurrency group is one fixed name, so reviews are serialized, and GitHub replaces a run that is still pending in that group when a newer one is queued, whatever `cancel-in-progress` says. A dispatcher must therefore hold one dispatch at a time: dispatch, wait for the run to complete, then dispatch the next. A cancelled pending run leaves no artifact and no failure document. The shadow driver refuses to dispatch while a run of this workflow is queued or in progress.

## Execution and output

The native runtime checks require workflow dispatch, the exact ref, the workflow path under the runtime's own repository, protected-ref observation, matching source and workflow SHA, and attempt 1. The approved producer source may never be one of the two commits under review. Checkout HEAD is checked before and after the review. These are local execution observations; they do not independently authenticate environment variables, the complete executable source or a hostile local Git directory.

The commits under review must already be present. The template's single checkout at the approved revision fetches every branch with full history, which covers a pull request from a branch of the same repository. A head in a fork, or a head that no branch or tag reaches any more (deleted, or force-pushed away), is never present and fails closed the same way; nothing fetches after that step, nothing checks out pull request content, and Git plumbing only ever reads the objects. A commit that is not present, for instance a head force-pushed away after dispatch, fails closed as `target_unavailable` before any paid work, with evidence.

The entrypoint reserves a new private directory before paid work, then measures the comparison and makes the existing single structured provider call. Every validated finding is retained; a clean outcome is not manufactured from prose. Invalid inputs, invalid context or an unavailable target make no provider call. Failed or partial review emits no receipt.

Three files are written with exclusive creation and private permissions:

- `merge-policy-review-receipt.json`: the receipt as exact canonical bytes, the wire format the intake reads and hashes. Uploaded under the same name, which is what the producers document registers as `artifactName`.
- `merge-policy-review-dispatch.json`: the non-acceptance report, at most 16 KiB. It carries the observed runtime and target, the receipt's SHA-256 and byte length, the measured comparison SHA-256 and the provider identifiers, now including the provider's reported token usage so a cost can be computed per review. It does not contain the receipt. It records `targetAuthenticated`, `githubIdentityAuthenticated`, `executionAuthenticated` and `enforcementPublished` as false.
- `merge-policy-review-dispatch-failure.json`: after the reservation, any failure produces this separate document of at most 8 KiB with the observed runtime and target, a closed failure code, phase and provider-outcome observation, and a validated numeric HTTP status when one was observed. Raw exception text, headers, response bodies, credentials and stacks are excluded. It always sets `acceptance`, `reviewCompleted` and every authority flag to false and is never accepted as a review.

Provider outcome semantics, reservation semantics and the one-run rule are those of the [historical probe](REVIEW-EXECUTION-PROBE.md): the reservation prevents a second call within the same output directory and is not a global dispatch lock; a timeout may still be billed; the live packet must authorize exactly one run and retain a durable record before the effect.

## Complete package and live prerequisites

The inactive workflow template is `review-dispatch.workflow.yml`. It pins checkout, Node setup and upload actions and an exact Node version, requests `contents: read` only, and scopes the `MERGE_POLICY_REVIEW_API_KEY` secret to the review step. Install it only as part of an independently reviewed immutable source tree of the repository whose pull requests it reviews, with all local transitive imports included:

- `merge-policy-review-dispatch.mjs`
- `merge-policy-review-producer.mjs`
- `merge-policy-review-comparison.mjs`
- `merge-policy-anthropic-review.mjs`

Each packet follows the v2 procedure: a reviewed shared-source commit, the resulting candidate commit and tree, a complete material manifest, a new immutable tag (`merge-policy-review-v4` for this source; `v3` carried the reviewer before its output schema named the finding-key pattern and the changed paths) under creation, immutability and branch-reservation protections (or one pattern-based set for `merge-policy-review-*`, an owner decision in the plan), verified native workflow identity, the secret route, and a durable dispatch record before every request. Unlike the probe, this workflow may be dispatched more than once, once per review; each dispatch is its own recorded operation, and a rerun of an existing run is refused by attempt 1 everywhere.

## Local validation

Run `node --test selftest/test_merge_policy_review_dispatch.mjs`, then all `selftest/test_merge_policy_*.mjs` suites. Fixtures construct actual Git objects; only provider transport is mocked, and no test makes a provider call. Cases cover the exact receipt bytes, the receipt passing the existing intake with every finding, every malformed input and every native-context mismatch refusing before credentials, the producer source never being a reviewed commit, an absent target commit refusing with evidence, source drift, the reservation, provider failure evidence without response text, the CLI, and the template's literal pins (ref, path, inputs reaching the environment, artifact names, `persist-credentials: false`, one secret scope, no input in a shell line).
