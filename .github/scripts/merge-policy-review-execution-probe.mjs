// Inactive fixed synthetic execution package. Native context is observed, not
// independently authenticated. No controller intake or check publisher is used.
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, realpath, writeFile } from "node:fs/promises";
import { isAbsolute, join } from "node:path";
import { promisify, types } from "node:util";
import {
  createReviewProducer,
  reviewProducerFailure,
} from "./merge-policy-review-producer.mjs";
import { STAGING_PROBE_TARGET } from "./merge-policy-transport-probe.mjs";

export const REVIEW_PROBE_REF = "refs/tags/merge-policy-review-execution-v1";
export const REVIEW_PROBE_DIRECTORY = "merge-policy-review-execution-probe";
export const REVIEW_PROBE_FILE = "merge-policy-review-execution-probe.json";
export const REVIEW_PROBE_FAILURE_FILE =
  "merge-policy-review-execution-failure.json";
export const REVIEW_PROBE_FAILURE_MAX_BYTES = 8192;
export const REVIEW_PROBE_MAX_BYTES = 98304;
export const REVIEW_PROBE_WORKFLOW = Object.freeze({
  id: 355220095,
  path: ".github/workflows/merge-policy-selftest.yml",
});
const digest = (bytes) => createHash("sha256").update(bytes).digest("hex");
export const REVIEW_PROBE_POLICY_DIGEST = digest(
  JSON.stringify({
    schemaVersion: 1,
    kind: "historical-review-execution-probe-policy-v1",
    acceptance: false,
    target: STAGING_PROBE_TARGET,
  }),
);
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
const SHA = /^[a-f0-9]{40}$/;
const DIGEST = /^[a-f0-9]{64}$/;
const failures = new WeakMap();
class ProbeError extends Error {
  constructor(code) {
    super(`Review execution probe: ${code}`);
    this.name = "ReviewExecutionProbeError";
    this.code = code;
    failures.set(this, Object.freeze({ code }));
  }
}
function requireThat(condition, code) {
  if (!condition) throw new ProbeError(code);
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
function context(runtimeInput, targetInput) {
  const runtime = record(runtimeInput, RUNTIME_FIELDS);
  const target = record(targetInput, Object.keys(STAGING_PROBE_TARGET));
  requireThat(
    Object.values(runtime).every(
      (v) => typeof v === "string" && v.length <= 400,
    ),
    "invalid_runtime",
  );
  requireThat(
    target.repository === STAGING_PROBE_TARGET.repository &&
      target.repositoryId === STAGING_PROBE_TARGET.repositoryId &&
      target.pullRequest === 1 &&
      [target.headSha, target.baseSha].every(
        (v) => typeof v === "string" && SHA.test(v),
      ) &&
      typeof target.comparisonSha256 === "string" &&
      DIGEST.test(target.comparisonSha256),
    "invalid_target",
  );
  requireThat(
    runtime.eventName === "workflow_dispatch" &&
      runtime.repository === target.repository &&
      runtime.repositoryId === String(target.repositoryId) &&
      runtime.ref === REVIEW_PROBE_REF &&
      runtime.refProtected === "true" &&
      runtime.runAttempt === "1" &&
      /^[1-9][0-9]{0,15}$/.test(runtime.runId) &&
      Number.isSafeInteger(Number(runtime.runId)) &&
      SHA.test(runtime.sha) &&
      runtime.sha === runtime.workflowSha &&
      runtime.workflowRef ===
        `${target.repository}/${REVIEW_PROBE_WORKFLOW.path}@${REVIEW_PROBE_REF}`,
    "unsupported_runtime",
  );
  return { runtime, target };
}
async function checkSource(root, sha) {
  let source;
  try {
    source = await promisify(execFile)(
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
        "rev-parse",
        "--verify",
        "HEAD",
      ],
      {
        cwd: root,
        timeout: 2000,
        maxBuffer: 8192,
        encoding: "utf8",
        env: {
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
        },
      },
    );
  } catch {
    throw new ProbeError("source_unavailable");
  }
  requireThat(source.stdout === `${sha}\n`, "source_mismatch");
}

/** Trusted local invocation only. target and reviewer transport are test seams;
 * the CLI uses the fixed historical staging fixture and real producer protocol.
 * Environment checks do not authenticate a workflow or arbitrary local .git.
 */
export async function runReviewExecutionProbe(input) {
  let reservation;
  let phase = "setup";
  let providerOutcome = "not_requested";
  try {
    const {
      repositoryPath,
      outputParentPath,
      runtime: rawRuntime,
      reviewer,
      target: rawTarget = STAGING_PROBE_TARGET,
    } = record(
      input,
      ["repositoryPath", "outputParentPath", "runtime", "reviewer"],
      ["target"],
    );
    const { runtime, target } = context(rawRuntime, rawTarget);
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
    const directory = join(outputParent, REVIEW_PROBE_DIRECTORY);
    phase = "output";
    try {
      await mkdir(directory, { mode: 0o700 });
    } catch (error) {
      throw new ProbeError(
        error.code === "EEXIST" ? "output_exists" : "output_unavailable",
      );
    }
    // Retain this reservation on any failure. It prevents duplicate paid work
    // within this private output directory; it is not a global execution lock.
    await writeFile(
      join(directory, "started.json"),
      JSON.stringify({
        kind: "review-execution-probe-reservation-v1",
        runtime,
        target,
        acceptance: false,
      }),
      { flag: "wx", mode: 0o600 },
    );
    reservation = { directory, runtime, target };
    phase = "comparison";
    const result = await producer.produce({
      repositoryPath: root,
      expectedComparisonSha256: target.comparisonSha256,
      dispatch: {
        producer: {
          repository: runtime.repository,
          repositoryId: target.repositoryId,
          workflowId: REVIEW_PROBE_WORKFLOW.id,
          workflowPath: REVIEW_PROBE_WORKFLOW.path,
          workflowRevision: runtime.workflowSha,
          runId: Number(runtime.runId),
          runAttempt: 1,
        },
        target: {
          repository: target.repository,
          pullRequest: target.pullRequest,
          headSha: target.headSha,
          baseSha: target.baseSha,
          policyDigest: REVIEW_PROBE_POLICY_DIGEST,
        },
        lane: "staging-review-probe",
      },
    });
    providerOutcome = "review_completed";
    phase = "source";
    await checkSource(root, runtime.workflowSha);
    phase = "receipt";
    const receiptBytes = result.receiptBytes;
    requireThat(
      result.comparisonSha256 === target.comparisonSha256 &&
        digest(receiptBytes) === result.receiptSha256 &&
        receiptBytes.equals(Buffer.from(JSON.stringify(result.receipt))),
      "result_mismatch",
    );
    phase = "output";
    const bytes = Buffer.from(
      JSON.stringify({
        schemaVersion: 1,
        kind: "historical-review-execution-probe-v1",
        runtime,
        target,
        receipt: result.receipt,
        receiptSha256: result.receiptSha256,
        comparisonSha256: result.comparisonSha256,
        provider: result.provider,
        currentPullRequestObserved: false,
        githubIdentityAuthenticated: false,
        executionAuthenticated: false,
        enforcementPublished: false,
      }),
    );
    requireThat(bytes.length <= REVIEW_PROBE_MAX_BYTES, "report_limit");
    const path = join(directory, REVIEW_PROBE_FILE);
    await writeFile(path, bytes, { flag: "wx", mode: 0o600 });
    return Object.freeze({
      path,
      byteLength: bytes.length,
      reportSha256: digest(bytes),
      receiptSha256: result.receiptSha256,
      comparisonSha256: result.comparisonSha256,
      enforcementPublished: false,
    });
  } catch (error) {
    const detail =
      reviewProducerFailure(error) ??
      Object.freeze({
        code:
          failures.get(error)?.code ??
          (phase === "output" ? "output_failed" : "probe_failed"),
        phase,
        providerOutcome,
      });
    if (reservation) {
      const bytes = Buffer.from(
        JSON.stringify({
          schemaVersion: 1,
          kind: "historical-review-execution-failure-v1",
          runtime: reservation.runtime,
          target: reservation.target,
          failure: detail,
          acceptance: false,
          reviewCompleted: false,
          currentPullRequestObserved: false,
          githubIdentityAuthenticated: false,
          executionAuthenticated: false,
          enforcementPublished: false,
        }),
      );
      requireThat(
        bytes.length <= REVIEW_PROBE_FAILURE_MAX_BYTES,
        "failure_report_limit",
      );
      try {
        await writeFile(
          join(reservation.directory, REVIEW_PROBE_FAILURE_FILE),
          bytes,
          { flag: "wx", mode: 0o600 },
        );
      } catch {
        throw new ProbeError("failure_report_unavailable");
      }
    }
    throw new ProbeError(detail.code);
  }
}

if (import.meta.main) {
  const e = process.env;
  const operation =
    process.argv.length === 2
      ? runReviewExecutionProbe({
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
          reviewer: {
            tokenProvider: async () => e.MERGE_POLICY_REVIEW_API_KEY,
          },
        })
      : Promise.reject(new ProbeError("unexpected_arguments"));
  operation.then(
    () =>
      process.stdout.write(
        "Non-acceptance historical review report written.\n",
      ),
    (error) => {
      process.stderr.write(
        `Review execution probe: ${failures.get(error)?.code ?? "probe_failed"}\n`,
      );
      process.exitCode = 1;
    },
  );
}
