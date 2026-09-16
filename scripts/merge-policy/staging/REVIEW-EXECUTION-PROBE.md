# Fixed historical review execution package

This inactive source package makes the next bounded producer test executable. It is not an execution verifier, a current PR review or a merge-policy acceptance adapter. No provider call, dispatch, installation, secret configuration or enforcement change is performed by adding these files.

## Fixed operation

The future entrypoint is `.github/scripts/merge-policy-review-execution-probe.mjs`. Its CLI accepts no arguments and uses only the fixed synthetic fixture already measured by the transport probe:

| Field                      | Fixed value                                                                     |
| -------------------------- | ------------------------------------------------------------------------------- |
| Repository                 | `topcoder1/techrecon-merge-policy-staging`                                      |
| Repository ID              | `1364800834`                                                                    |
| Historical PR reference    | `1`                                                                             |
| Base                       | `8d46f6dd7c02287d3fd0a66e797554651dde6ba0`                                      |
| Head                       | `3bae7ba0a625e0199c4203bcca9f4f1bfe009a09`                                      |
| Measured comparison SHA256 | `cd663d3aa45e822cadb97651940d004b06ede75f8468c25b9d893dfabe67dca7`              |
| Workflow path / ID         | `.github/workflows/merge-policy-selftest.yml` / `355220095`                     |
| New dispatch ref           | `refs/tags/merge-policy-review-execution-v1`                                    |
| Supported attempt          | `1`                                                                             |
| Review lane                | `staging-review-probe`                                                          |
| Provider                   | Existing `claude-sonnet-4-6` data-only producer, one request, no tools or retry |

The policy digest is deterministically derived from the canonical synthetic policy document in the entrypoint: a schema version, historical probe kind, `acceptance: false` and the fixed target above. It is not the current protected controller policy digest. The historical target is not refreshed or relabeled with a current PR's commits.

## Execution and output

The native runtime checks require workflow dispatch, the exact repository/ID/ref/workflow path, protected-ref observation, matching source/workflow SHA and attempt 1. Checkout HEAD is checked before and after the review. These are local execution observations; they do not independently authenticate environment variables, the complete executable source or a hostile local Git directory.

The entrypoint reserves a new private directory before paid work. The real producer measures the fixed Git objects and verifies the approved comparison digest before credentials are acquired. It then makes the existing single structured provider call. Every validated finding is retained; a clean outcome is not manufactured from prose. Invalid context, malformed input or an unapproved comparison makes no provider call. Failed or partial review emits no successful review report.

After the reservation is written, any failure produces a separate, at most 8 KiB `merge-policy-review-execution-failure.json` with observed runtime/target, a closed failure code, phase and provider-outcome observation. A validated numeric HTTP status may be included; raw exception text, headers, response bodies, credentials and stacks are excluded. The failure document always sets `acceptance`, `reviewCompleted` and all authority flags to false, contains no receipt and is never accepted as a completed review. An unavailable or colliding failure file still fails the operation. Invalid context or an existing output directory fails before reservation and creates no new failure report.

Provider outcome is `not_requested` before a transport attempt, `unknown` once transport is invoked without a response, `response_received` after headers arrive, or `review_completed` after a complete validated result but a later receipt/source/output failure. A received response can still be truncated or malformed; neither a timeout nor a transport failure proves the provider did no work or billed nothing. Deadline limits remain unchanged. The template uploads only the reservation and separate failure document after a failed review step; successful upload does not change the job's failure status.

The report contains the canonical receipt object, its exact JSON SHA256, measured comparison SHA256 and provider request/input/output identifiers. The entrypoint checks the canonical receipt bytes against the producer's returned digest. The outer report's digest differs from the receipt digest and from a future uploaded archive's digest. Native output omits raw error bodies and credentials; findings remain original model text. The report is bounded to 96 KiB and written with exclusive creation and private file permissions.

The wrapper kind is `historical-review-execution-probe-v1`, not the intake receipt wire format. It always records `currentPullRequestObserved`, `githubIdentityAuthenticated`, `executionAuthenticated` and `enforcementPublished` as false. Copying the nested receipt out of the report does not confer authority. No producer registration or acceptance publication is connected.

Reservation remains after success or failure. It prevents a second call within the same output directory; it is not a durable global dispatch lock. GitHub concurrency serializes matching jobs but does not deduplicate new workflow runs. A timeout may still be billed. The live packet must authorize exactly one run, identify it, verify no prior dispatch and retain a durable execution record. A second run or retry requires explicit handling of that record, not a cleared directory.

## Complete package and live prerequisites

The inactive workflow template is `review-execution-probe.workflow.yml`. It pins checkout, Node setup and upload actions and an exact Node version. Install it only as part of an independently reviewed immutable staging source tree, with all local transitive imports included:

- `merge-policy-review-execution-probe.mjs`
- `merge-policy-review-producer.mjs`
- `merge-policy-review-comparison.mjs`
- `merge-policy-anthropic-review.mjs`
- `merge-policy-transport-probe.mjs` (fixed synthetic target)

Approve the whole execution and downloaded runtime/action dependency chain; the template alone does not verify those materials. Hosted-runner trust remains an explicit assumption. No target PR checkout or package installation runs in this workflow.

Before dispatch, the exact execution packet must include the reviewed shared-source commit, resulting staging commit/tree, complete material manifest, fixed target and policy digests, new immutable tag and no-same-name-branch protections, verified native workflow identity, actor and one-run scope, bounded provider cost and secret route, storage/readback limits and failure evidence procedure. `MERGE_POLICY_REVIEW_API_KEY` availability is not assumed. The existing staging App installation is complete and must not be requested again; its current permissions do not include Actions read. This package grants no new permission or secret access.

The original v1 ref has already been used by staging run `35033080135` attempt 1, which failed with a collapsed `review_failed` code and no report artifact. Its roughly 71-second review step does not establish that the configured 120-second deadline caused the failure. This source repair does not move that immutable tag, enlarge limits or authorize another request. A later run needs a newly reviewed execution packet and new protected ref.

The expected successful result is a completed structured review of this historical synthetic comparison with exact bytes and provenance observations. The result may contain findings. It is not a clean-merge acceptance test. Current-target binding, independent execution authentication, durable intake/publication and protected merge enforcement remain subsequent work.

## Local validation

Run `node --test selftest/test_merge_policy_review_producer.mjs selftest/test_merge_policy_review_execution_probe.mjs`, then all `selftest/test_merge_policy_*.mjs` suites. Fixtures independently construct actual Git objects and expected comparison digests. Only provider transport is mocked. Cases cover findings retention, mismatch before credentials, partial/failing responses, source drift, caller mutation, output collision and CLI refusal. These tests make no provider calls and cannot establish live GitHub authentication.
