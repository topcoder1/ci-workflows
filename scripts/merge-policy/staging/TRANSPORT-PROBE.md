# Inactive staging transport probe

`transport-probe.workflow.yml` is an inactive template outside `.github/workflows`. Committing this template does not install or dispatch a workflow. It performs no model review and requests no model secret. Its artifact is a measurement fingerprint report and must never enter structured review intake or satisfy a merge-policy review lane.

## Fixed execution contract

The only proposed destination is `.github/workflows/merge-policy-selftest.yml` in private repository `topcoder1/techrecon-merge-policy-staging` (repository ID `1364800834`), on the exact protected tag `refs/tags/merge-policy-transport-probe-v1`. The staging workflow path is already registered as workflow ID `355220095`; registration and permissions still require fresh verification before installation or dispatch.

The template permits only direct `workflow_dispatch`, without inputs, on attempt 1. Its one job checks repository name and ID, the exact protected tag, the full workflow ref, and equality of `github.sha` and `github.workflow_sha`. The CLI repeats the native runtime checks and verifies that the source checkout's `HEAD` equals `GITHUB_WORKFLOW_SHA`. GitHub context flags and values copied into an artifact are preliminary execution claims; they do not replace independent source, run, identity or effective-protection verification. A skipped job or green run alone is not successful probe evidence.

The source checkout uses that workflow SHA and full history, with persistent checkout credentials, LFS and submodules disabled. There is no target checkout. The approved source history must already contain both fixed target Git objects; the collector fails if either is absent. No command, action, hook, package, dependency or model tool from target PR content is run. The CLI uses native `import.meta.main` (Node22.18 or later) so aliased or symlinked entry paths cannot silently skip execution. The sole shell step invokes the reviewed `.github/scripts/merge-policy-transport-probe.mjs` from the approved source checkout.

The template pins the complete action references:

| Component       | Pinned candidate                                                           |
| --------------- | -------------------------------------------------------------------------- |
| Checkout        | `actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1`                |
| Node setup      | `actions/setup-node@249970729cb0ef3589644e2896645e5dc5ba9c38`              |
| Node runtime    | `22.23.2`, with latest-version checks and package-manager caching disabled |
| Artifact upload | `actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02`         |
| Hosted runner   | `ubuntu-24.04`, with a 10-minute job timeout                               |

Only `contents: read` is requested through workflow permissions. No provider secret, App private key, maintainer token, OIDC grant or write permission is injected. Checkout still obtains its normal read credential, and artifact upload uses GitHub's artifact service authority. Trust therefore covers the whole approved workflow execution, action dependencies and action post phases, including checkout cleanup. Disabling credential persistence does not remove an action from that trust boundary. Hosted runner images, GitHub services and runtime-download infrastructure remain trusted mutable infrastructure; this is not a fully hermetic execution claim.

## Fixed measurement and artifact

The synthetic target is staging PR 1 with:

- Base: `8d46f6dd7c02287d3fd0a66e797554651dde6ba0`
- Head: `3bae7ba0a625e0199c4203bcca9f4f1bfe009a09`
- Independently measured comparison SHA256: `cd663d3aa45e822cadb97651940d004b06ede75f8468c25b9d893dfabe67dca7`
- Measured inventory: 3 changed files, 103,622 bytes of before/after content and 110,131 bytes in the full comparison packet.

The CLI recollects the complete supported comparison and requires its exact expected digest. It always projects a measurement fingerprint report containing every measured path, status, mode, Git blob ID, byte count and blob SHA256, plus the full comparison SHA256. It does not include blob text. This projection is the probe's unconditional format, not a fallback that drops content when an artifact is oversized. The full measured packet exceeds the local JSON reader's 64 KiB bound; the complete fingerprint report must itself fit the CLI's 64 KiB bound or the probe fails.

The report is written exclusively to `${RUNNER_TEMP}/merge-policy-transport-probe/merge-policy-transport-probe.json`; a pre-existing output is an error. Upload selects only that exact file, with artifact name `merge-policy-transport-probe.json`, missing-file failure, no overwrite, compression level 0, one-day retention and hidden files excluded. There is no fallback upload of a directory, workspace, partial report or model output.

The report's comparison digest binds the complete measured packet. It cannot be recomputed from the text-free report alone. The report's own byte digest and GitHub archive digest are separate values and must not be substituted for that comparison digest. Every report authentication and enforcement flag remains false. A valid upload proves neither a review nor a complete authenticated reviewer execution.

## Prerequisites before any live bootstrap

1. Review the concrete future source commit: the installed workflow, CLI, collector and every executable dependency must be present at immutable approved revisions. This template must remain inactive until that installation is separately authorized and prepared. Verify that its source history contains the fixed target objects. Do not change staging `main`, its required checks, the PR 1 finding ledger or the control repository to make the probe work.
2. Verify the actual bootstrap actor can publish the workflow/ref and the dispatch actor can invoke it. The current staging App has Contents/Checks write and Pull requests/Metadata read; it does not supply Workflows or Actions access. Source installation, dispatch and private Actions metadata/artifact reads require independently verified capabilities. This source template adds no permissions or credentials.
3. Establish exact-tag creation, update and deletion restrictions before creating the tag, permitting only the intended bootstrap actor for creation and no continuing author bypass for updates or deletion. Verify effective rules and the tag's resolved approved commit before dispatch. A create-then-protect interval is untrusted; `ref_protected: true` alone does not prove the required restrictions. Administrators capable of editing those rules remain trusted. Preserve existing main and control protections.
4. Dispatch only the exact protected named tag and capture the returned run ID and URLs. Independently confirm repository ID, workflow ID/path, direct dispatch, selected tag, approved source SHA, current attempt 1, terminal success and the exact artifact ID/digest. Do not select the newest run from a list or treat a rerun as this first-attempt probe. The artifact's one-day retention makes prompt evidence collection necessary; absence or expiry is a failed validation prerequisite.
5. Keep this no-model probe separate from any later credential-bearing review. Before a future model run, verify the exact secret exposure boundary and repository plan/configuration. A protected tag does not by itself prevent another writable ref from accessing a repository-wide secret. Never expose the App private key or a broad maintainer credential to model execution.

The September 11 coordinator evidence packet retains the earlier bounded bootstrap analysis and unresolved capability checks. GitHub documents the [default-branch registration and dispatch event](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#workflow_dispatch), [named-ref dispatch API](https://docs.github.com/en/rest/actions/workflows#create-a-workflow-dispatch-event), [runtime variables](https://docs.github.com/en/actions/reference/workflows-and-actions/variables) and [pinned upload action](https://github.com/actions/upload-artifact/blob/ea165f8d65b6e75b540449e92b4886f43607fa02/README.md). Historical observations are not fresh installation authorization or proof of current GitHub configuration.

## Reader compatibility remains unresolved

The current artifact reader accepts a bare workflow path or `workflowPath@<approved source SHA>`. A tag-dispatched run may return a named `path@ref` suffix instead. This probe must establish that actual metadata form. If the reader rejects it, preserve the refusal and review a narrowly scoped adapter change that independently binds the exact selected ref, source commit, workflow identity and execution mode. Do not strip or ignore the suffix to obtain a pass.

Even after transport succeeds, this report is not a review receipt. Real reviewer execution, independent target/policy authentication, authenticated intake, producer administration, failure recovery and a clean accepted merge remain separate unfinished validations. No production or fleet enforcement is activated by this template.
