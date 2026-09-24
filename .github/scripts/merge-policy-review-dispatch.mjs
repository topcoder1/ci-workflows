// Inactive current-target review package. The target comes from workflow_dispatch
// inputs: trusted caller input, validated here, authenticated nowhere in this
// file. Only the owner can dispatch a private repository's workflow, the intake
// authenticates the run through the API, and the dispatcher's own durable record
// supplies the target the receipt must match. No controller intake or check
// publisher is used. Native context is observed, not independently authenticated.
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, realpath, writeFile } from "node:fs/promises";
import { isAbsolute, join } from "node:path";
import { promisify, types } from "node:util";
import {
  createReviewProducer,
  reviewProducerFailure,
} from "./merge-policy-review-producer.mjs";

export const REVIEW_DISPATCH_REF = "refs/tags/merge-policy-review-v5";
export const REVIEW_DISPATCH_WORKFLOW_PATH =
  ".github/workflows/merge-policy-review-dispatch.yml";
export const REVIEW_DISPATCH_LANE = "shadow";
export const REVIEW_DISPATCH_DIRECTORY = "merge-policy-review-dispatch";
export const REVIEW_DISPATCH_RECEIPT_FILE = "merge-policy-review-receipt.json";
export const REVIEW_DISPATCH_REPORT_FILE = "merge-policy-review-dispatch.json";
export const REVIEW_DISPATCH_FAILURE_FILE =
  "merge-policy-review-dispatch-failure.json";
export const REVIEW_DISPATCH_FAILURE_MAX_BYTES = 8192;
export const REVIEW_DISPATCH_REPORT_MAX_BYTES = 16384;
// The workflow_dispatch inputs, in the order the template declares them. Each
// reaches the entrypoint as INPUT_<NAME> in the environment, never as an
// argument and never interpolated into a shell line.
export const REVIEW_DISPATCH_INPUTS = Object.freeze([
  "pull_request",
  "head_sha",
  "base_sha",
  "policy_digest",
  "workflow_id",
]);
const RUNTIME_FIELDS = [
  "eventName",
  "repository",
  "repositoryId",
  "ref",
  "refProtected",
  "sha",
  "workflowSha",
  "workflowRef",
  "runId",
  "runAttempt",
];
const TARGET_FIELDS = [
  "pullRequest",
  "headSha",
  "baseSha",
  "policyDigest",
  "workflowId",
];
const SHA = /^[a-f0-9]{40}$/;
const DIGEST = /^[a-f0-9]{64}$/;
const COUNT = /^[1-9][0-9]{0,15}$/;
const REPOSITORY = /^[A-Za-z0-9][A-Za-z0-9-]{0,38}\/[A-Za-z0-9_.-]{1,100}$/;
const digest = (bytes) => createHash("sha256").update(bytes).digest("hex");
const failures = new WeakMap();
class DispatchError extends Error {
  constructor(code) {
    super(`Review dispatch: ${code}`);
    this.name = "ReviewDispatchError";
    this.code = code;
    failures.set(this, Object.freeze({ code }));
  }
}
export function reviewDispatchFailure(error) {
  return failures.get(error);
}
function requireThat(condition, code) {
  if (!condition) throw new DispatchError(code);
}
function record(value, required, optional = []) {
  requireThat(
    value && typeof value === "object" && !types.isProxy(value),
    "invalid_input",
  );
  requireThat(
    [Object.prototype, null].includes(Object.getPrototypeOf(value)),
    "invalid_input",
  );
  const descriptors = Object.getOwnPropertyDescriptors(value);
  const keys = Reflect.ownKeys(descriptors);
  requireThat(
    required.every((k) => keys.includes(k)) &&
      keys.every((k) => required.includes(k) || optional.includes(k)),
    "invalid_input",
  );
  const result = {};
  for (const key of keys) {
    const d = descriptors[key];
    requireThat(d.enumerable && Object.hasOwn(d, "value"), "invalid_input");
    result[key] = d.value;
  }
  return Object.freeze(result);
}
const count = (value) =>
  typeof value === "string" &&
  COUNT.test(value) &&
  Number.isSafeInteger(Number(value));

/** Validate the dispatch inputs before any Git or credential work. Every value
 * is a string from the environment; the receipt carries the parsed numbers. */
function targetOf(inputs) {
  const t = record(inputs, TARGET_FIELDS);
  requireThat(
    Object.values(t).every((v) => typeof v === "string" && v.length <= 400),
    "invalid_target",
  );
  requireThat(
    count(t.pullRequest) &&
      count(t.workflowId) &&
      SHA.test(t.headSha) &&
      SHA.test(t.baseSha) &&
      t.headSha !== t.baseSha &&
      DIGEST.test(t.policyDigest),
    "invalid_target",
  );
  return Object.freeze({
    pullRequest: Number(t.pullRequest),
    headSha: t.headSha,
    baseSha: t.baseSha,
    policyDigest: t.policyDigest,
    workflowId: Number(t.workflowId),
  });
}
function context(runtimeInput, inputs) {
  const runtime = record(runtimeInput, RUNTIME_FIELDS);
  requireThat(
    Object.values(runtime).every(
      (v) => typeof v === "string" && v.length <= 400,
    ),
    "invalid_runtime",
  );
  const target = targetOf(inputs);
  requireThat(
    runtime.eventName === "workflow_dispatch" &&
      REPOSITORY.test(runtime.repository) &&
      ![".", ".."].includes(runtime.repository.split("/")[1]) &&
      count(runtime.repositoryId) &&
      runtime.ref === REVIEW_DISPATCH_REF &&
      runtime.refProtected === "true" &&
      runtime.runAttempt === "1" &&
      count(runtime.runId) &&
      SHA.test(runtime.sha) &&
      runtime.sha === runtime.workflowSha &&
      runtime.workflowRef ===
        `${runtime.repository}/${REVIEW_DISPATCH_WORKFLOW_PATH}@${REVIEW_DISPATCH_REF}`,
    "unsupported_runtime",
  );
  // The approved producer source is never one of the commits under review.
  requireThat(
    runtime.workflowSha !== target.headSha &&
      runtime.workflowSha !== target.baseSha,
    "invalid_target",
  );
  return { runtime, target };
}
const GIT_ENV = Object.freeze({
  PATH: "/usr/bin:/bin",
  LANG: "C",
  LC_ALL: "C",
  GIT_CONFIG_NOSYSTEM: "1",
  GIT_CONFIG_GLOBAL: "/dev/null",
  GIT_CONFIG_SYSTEM: "/dev/null",
  GIT_NO_LAZY_FETCH: "1",
  GIT_NO_REPLACE_OBJECTS: "1",
  GIT_TERMINAL_PROMPT: "0",
  GIT_ALLOW_PROTOCOL: "",
});
async function git(root, args, code) {
  try {
    return await promisify(execFile)(
      "/usr/bin/git",
      [
        "--no-replace-objects",
        "--no-lazy-fetch",
        "-c",
        "protocol.allow=never",
        "-c",
        "core.hooksPath=/dev/null",
        "-c",
        "core.fsmonitor=false",
        ...args,
      ],
      {
        cwd: root,
        timeout: 2000,
        maxBuffer: 8192,
        encoding: "utf8",
        env: GIT_ENV,
      },
    );
  } catch {
    throw new DispatchError(code);
  }
}
async function checkSource(root, sha) {
  const source = await git(
    root,
    ["rev-parse", "--verify", "HEAD"],
    "source_unavailable",
  );
  requireThat(source.stdout === `${sha}\n`, "source_mismatch");
}
/** Both commits under review must already be present: the checkout at the
 * approved revision fetches every branch, and nothing here fetches anything. */
async function checkTarget(root, target) {
  for (const sha of [target.headSha, target.baseSha])
    await git(
      root,
      ["cat-file", "-e", `${sha}^{commit}`],
      "target_unavailable",
    );
}

/** Trusted local invocation only. runtime, inputs and reviewer transport are the
 * caller's; the CLI takes them from the environment. Environment checks do not
 * authenticate a workflow or an arbitrary local .git.
 */
export async function runReviewDispatch(input) {
  let reservation;
  let phase = "setup";
  let providerOutcome = "not_requested";
  try {
    const {
      repositoryPath,
      outputParentPath,
      runtime: rawRuntime,
      inputs,
      reviewer,
    } = record(input, [
      "repositoryPath",
      "outputParentPath",
      "runtime",
      "inputs",
      "reviewer",
    ]);
    const { runtime, target } = context(rawRuntime, inputs);
    requireThat(
      [repositoryPath, outputParentPath].every(
        (p) =>
          typeof p === "string" &&
          p.length <= 4096 &&
          isAbsolute(p) &&
          !/[\x00-\x1f\x7f]/.test(p),
      ),
      "invalid_path",
    );
    const producer = createReviewProducer(reviewer);
    const root = await realpath(repositoryPath);
    const outputParent = await realpath(outputParentPath);
    await checkSource(root, runtime.workflowSha);
    const directory = join(outputParent, REVIEW_DISPATCH_DIRECTORY);
    phase = "output";
    try {
      await mkdir(directory, { mode: 0o700 });
    } catch (error) {
      throw new DispatchError(
        error.code === "EEXIST" ? "output_exists" : "output_unavailable",
      );
    }
    // Retained on any failure: no duplicate paid work within this output
    // directory. It is not a global execution lock.
    await writeFile(
      join(directory, "started.json"),
      JSON.stringify({
        kind: "review-dispatch-reservation-v1",
        runtime,
        target,
        acceptance: false,
      }),
      { flag: "wx", mode: 0o600 },
    );
    reservation = { directory, runtime, target };
    phase = "target";
    await checkTarget(root, target);
    phase = "comparison";
    const result = await producer.produce({
      repositoryPath: root,
      dispatch: {
        producer: {
          repository: runtime.repository,
          repositoryId: Number(runtime.repositoryId),
          workflowId: target.workflowId,
          workflowPath: REVIEW_DISPATCH_WORKFLOW_PATH,
          workflowRevision: runtime.workflowSha,
          runId: Number(runtime.runId),
          runAttempt: 1,
        },
        target: {
          repository: runtime.repository,
          pullRequest: target.pullRequest,
          headSha: target.headSha,
          baseSha: target.baseSha,
          policyDigest: target.policyDigest,
        },
        lane: REVIEW_DISPATCH_LANE,
      },
    });
    providerOutcome = "review_completed";
    phase = "source";
    await checkSource(root, runtime.workflowSha);
    phase = "receipt";
    const receiptBytes = result.receiptBytes;
    requireThat(
      digest(receiptBytes) === result.receiptSha256 &&
        receiptBytes.equals(Buffer.from(JSON.stringify(result.receipt))) &&
        result.receipt.target.repository === runtime.repository &&
        result.receipt.target.headSha === target.headSha &&
        result.receipt.target.baseSha === target.baseSha &&
        result.receipt.target.pullRequest === target.pullRequest &&
        result.receipt.target.policyDigest === target.policyDigest,
      "result_mismatch",
    );
    phase = "output";
    // The receipt is the wire format the intake reads: exact bytes, nothing
    // wrapped around them. The report beside it carries the observations.
    const receiptPath = join(directory, REVIEW_DISPATCH_RECEIPT_FILE);
    await writeFile(receiptPath, receiptBytes, { flag: "wx", mode: 0o600 });
    const report = Buffer.from(
      JSON.stringify({
        schemaVersion: 1,
        kind: "review-dispatch-v1",
        runtime,
        target,
        receiptSha256: result.receiptSha256,
        receiptByteLength: receiptBytes.length,
        comparisonSha256: result.comparisonSha256,
        provider: result.provider,
        targetAuthenticated: false,
        githubIdentityAuthenticated: false,
        executionAuthenticated: false,
        enforcementPublished: false,
      }),
    );
    requireThat(
      report.length <= REVIEW_DISPATCH_REPORT_MAX_BYTES,
      "report_limit",
    );
    const reportPath = join(directory, REVIEW_DISPATCH_REPORT_FILE);
    await writeFile(reportPath, report, { flag: "wx", mode: 0o600 });
    return Object.freeze({
      receiptPath,
      reportPath,
      receiptSha256: result.receiptSha256,
      receiptByteLength: receiptBytes.length,
      reportSha256: digest(report),
      comparisonSha256: result.comparisonSha256,
      enforcementPublished: false,
    });
  } catch (error) {
    const detail =
      reviewProducerFailure(error) ??
      Object.freeze({
        code:
          failures.get(error)?.code ??
          (phase === "output" ? "output_failed" : "dispatch_failed"),
        phase,
        providerOutcome,
      });
    if (reservation) {
      const bytes = Buffer.from(
        JSON.stringify({
          schemaVersion: 1,
          kind: "review-dispatch-failure-v1",
          runtime: reservation.runtime,
          target: reservation.target,
          failure: detail,
          acceptance: false,
          reviewCompleted: false,
          targetAuthenticated: false,
          githubIdentityAuthenticated: false,
          executionAuthenticated: false,
          enforcementPublished: false,
        }),
      );
      requireThat(
        bytes.length <= REVIEW_DISPATCH_FAILURE_MAX_BYTES,
        "failure_report_limit",
      );
      try {
        await writeFile(
          join(reservation.directory, REVIEW_DISPATCH_FAILURE_FILE),
          bytes,
          { flag: "wx", mode: 0o600 },
        );
      } catch {
        throw new DispatchError("failure_report_unavailable");
      }
    }
    throw new DispatchError(detail.code);
  }
}

/** The environment names the template maps each input to: INPUT_<NAME> for
 * every name in REVIEW_DISPATCH_INPUTS, read as the camel-cased field. */
export function dispatchInputsFromEnvironment(e) {
  const inputs = {};
  for (const name of REVIEW_DISPATCH_INPUTS)
    inputs[name.replace(/_([a-z])/g, (_, letter) => letter.toUpperCase())] =
      e[`INPUT_${name.toUpperCase()}`];
  return inputs;
}

if (import.meta.main) {
  const e = process.env;
  const operation =
    process.argv.length === 2
      ? runReviewDispatch({
          repositoryPath: e.GITHUB_WORKSPACE,
          outputParentPath: e.RUNNER_TEMP,
          runtime: {
            eventName: e.GITHUB_EVENT_NAME,
            repository: e.GITHUB_REPOSITORY,
            repositoryId: e.GITHUB_REPOSITORY_ID,
            ref: e.GITHUB_REF,
            refProtected: e.GITHUB_REF_PROTECTED,
            sha: e.GITHUB_SHA,
            workflowSha: e.GITHUB_WORKFLOW_SHA,
            workflowRef: e.GITHUB_WORKFLOW_REF,
            runId: e.GITHUB_RUN_ID,
            runAttempt: e.GITHUB_RUN_ATTEMPT,
          },
          inputs: dispatchInputsFromEnvironment(e),
          reviewer: {
            tokenProvider: async () => e.MERGE_POLICY_REVIEW_API_KEY,
          },
        })
      : Promise.reject(new DispatchError("unexpected_arguments"));
  operation.then(
    () => process.stdout.write("Non-acceptance review receipt written.\n"),
    (error) => {
      process.stderr.write(
        `Review dispatch: ${failures.get(error)?.code ?? "dispatch_failed"}\n`,
      );
      process.exitCode = 1;
    },
  );
}
