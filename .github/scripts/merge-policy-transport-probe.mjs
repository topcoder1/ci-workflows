// Inactive probe entrypoint. Real Git measurement, no model invocation or review
// receipt. A future trusted workflow must separately authenticate this execution.
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, realpath, writeFile } from "node:fs/promises";
import { isAbsolute, join } from "node:path";
import { promisify, types } from "node:util";
import { collectReviewComparison } from "./merge-policy-review-comparison.mjs";

export const PROBE_REF = "refs/tags/merge-policy-transport-probe-v1";
export const PROBE_FILE = "merge-policy-transport-probe.json";
export const PROBE_DIRECTORY = "merge-policy-transport-probe";
export const PROBE_MAX_BYTES = 65536;
export const STAGING_PROBE_TARGET = Object.freeze({
  repository: "topcoder1/techrecon-merge-policy-staging",
  repositoryId: 1364800834,
  pullRequest: 1,
  baseSha: "8d46f6dd7c02287d3fd0a66e797554651dde6ba0",
  headSha: "3bae7ba0a625e0199c4203bcca9f4f1bfe009a09",
  comparisonSha256:
    "cd663d3aa45e822cadb97651940d004b06ede75f8468c25b9d893dfabe67dca7",
});
const SHA = /^[a-f0-9]{40}$/;
const DIGEST = /^[a-f0-9]{64}$/;
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
class ProbeError extends Error {
  constructor(code) {
    super(`Transport probe: ${code}`);
    this.name = "TransportProbeError";
    this.code = code;
  }
}
function requireThat(condition, code) {
  if (!condition) throw new ProbeError(code);
}
function dataRecord(value, keys) {
  requireThat(
    value && typeof value === "object" && !types.isProxy(value),
    "invalid_input",
  );
  requireThat(
    [Object.prototype, null].includes(Object.getPrototypeOf(value)),
    "invalid_input",
  );
  const descriptors = Object.getOwnPropertyDescriptors(value);
  const actual = Reflect.ownKeys(descriptors);
  requireThat(
    actual.length === keys.length && actual.every((k) => keys.includes(k)),
    "invalid_input",
  );
  const result = {};
  for (const key of keys) {
    const d = descriptors[key];
    requireThat(d?.enumerable && Object.hasOwn(d, "value"), "invalid_input");
    result[key] = d.value;
  }
  return Object.freeze(result);
}
function context(runtimeInput, targetInput) {
  const runtime = dataRecord(runtimeInput, RUNTIME_FIELDS);
  const target = dataRecord(targetInput, Object.keys(STAGING_PROBE_TARGET));
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
      [target.baseSha, target.headSha].every(
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
      runtime.ref === PROBE_REF &&
      runtime.refProtected === "true" &&
      runtime.runAttempt === "1" &&
      /^[1-9][0-9]{0,15}$/.test(runtime.runId) &&
      SHA.test(runtime.sha) &&
      runtime.sha === runtime.workflowSha &&
      runtime.workflowRef ===
        `${target.repository}/.github/workflows/merge-policy-selftest.yml@${PROBE_REF}`,
    "unsupported_runtime",
  );
  return { runtime, target };
}
const digest = (bytes) => createHash("sha256").update(bytes).digest("hex");
const fingerprint = (side) =>
  side === null
    ? null
    : Object.freeze({
        oid: side.oid,
        mode: side.mode,
        byteLength: side.byteLength,
        sha256: side.sha256,
      });

/** Trusted local invocation. target is injectable only for isolated local tests;
 * the command-line entrypoint always supplies the fixed staging fixture above.
 * Runtime fields remain observations, never independently authenticated facts.
 */
export async function runTransportProbe({
  repositoryPath,
  outputParentPath,
  runtime: runtimeInput,
  target: targetInput = STAGING_PROBE_TARGET,
}) {
  try {
    const { runtime, target } = context(runtimeInput, targetInput);
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
    const root = await realpath(repositoryPath);
    const outputParent = await realpath(outputParentPath);
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
    requireThat(
      source.stdout === `${runtime.workflowSha}\n`,
      "source_mismatch",
    );
    let comparison;
    try {
      comparison = await collectReviewComparison({
        repositoryPath: root,
        baseSha: target.baseSha,
        headSha: target.headSha,
      });
    } catch {
      throw new ProbeError("measurement_failed");
    }
    requireThat(
      comparison.comparisonSha256 === target.comparisonSha256,
      "comparison_mismatch",
    );
    // This projection is unconditional: it is a fingerprint report, never an
    // abbreviated or fallback review packet. Every measured file is retained.
    const report = {
      schemaVersion: 1,
      kind: "transport-probe-fingerprint-v1",
      runtime,
      target,
      comparison: {
        comparisonKind: comparison.comparisonKind,
        baseSha: comparison.baseSha,
        headSha: comparison.headSha,
        mergeBaseSha: comparison.mergeBaseSha,
        baseTreeOid: comparison.baseTreeOid,
        headTreeOid: comparison.headTreeOid,
        totalContentBytes: comparison.totalContentBytes,
        comparisonSha256: comparison.comparisonSha256,
        files: comparison.files.map((f) => ({
          path: f.path,
          status: f.status,
          before: fingerprint(f.before),
          after: fingerprint(f.after),
        })),
      },
      fullReviewContentIncluded: false,
      reviewPerformed: false,
      githubIdentityAuthenticated: false,
      executionAuthenticated: false,
      enforcementPublished: false,
    };
    const bytes = Buffer.from(JSON.stringify(report));
    requireThat(bytes.length <= PROBE_MAX_BYTES, "report_limit");
    const directory = join(outputParent, PROBE_DIRECTORY);
    try {
      await mkdir(directory, { mode: 0o700 });
    } catch (error) {
      throw new ProbeError(
        error.code === "EEXIST" ? "output_exists" : "output_unavailable",
      );
    }
    const path = join(directory, PROBE_FILE);
    await writeFile(path, bytes, { flag: "wx", mode: 0o600 });
    return Object.freeze({
      path,
      byteLength: bytes.length,
      reportSha256: digest(bytes),
      comparisonSha256: comparison.comparisonSha256,
    });
  } catch (error) {
    if (error instanceof ProbeError) throw error;
    throw new ProbeError("probe_failed");
  }
}

// Native entrypoint identity also handles symlinked or aliased script paths.
// Available since Node22.18; the inactive workflow pins Node22.23.2.
if (import.meta.main) {
  const e = process.env;
  const operation =
    process.argv.length === 2
      ? runTransportProbe({
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
        })
      : Promise.reject(new ProbeError("unexpected_arguments"));
  operation.then(
    () =>
      process.stdout.write("Non-acceptance transport fingerprint written.\n"),
    (error) => {
      process.stderr.write(
        `${error instanceof ProbeError ? error.message : "Transport probe: probe_failed"}\n`,
      );
      process.exitCode = 1;
    },
  );
}
