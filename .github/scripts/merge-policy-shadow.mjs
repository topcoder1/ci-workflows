// Shadow-mode driver for the merge-policy pilot (SHADOW-PHASE-PLAN.md § 3).
//
// One cycle: preflight the PR from a control snapshot, write a durable dispatch
// record, dispatch the producer workflow on its protected tag, wait for the
// attempt-1 run, take its receipt through the trusted intake adapter, evaluate
// the policy WITHOUT publishing, and append one JSON line to the shadow log.
//
// What this driver never does: request or write a check run (there is no
// --publish and PolicyController.evaluate is always called with publish:false),
// accept receipt bytes from the operator (only a selector and a dispatch
// record), or print a credential (the GitHub token is read inside the artifact
// client's token provider and dropped there; provider keys never reach this
// process). Every GitHub call goes through the owner's `gh` identity.
import { execFileSync } from "node:child_process";
import {
  appendFileSync,
  closeSync,
  fsyncSync,
  mkdirSync,
  openSync,
  readFileSync,
  renameSync,
  writeSync,
} from "node:fs";
import { dirname, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

import { extractReviewReceipt } from "./merge-policy-artifact-zip.mjs";
import { GitHubAPI, PolicyController } from "./merge-policy-github.mjs";
import { createGitHubArtifactClient } from "./merge-policy-github-artifact.mjs";
import {
  createIntakeReaders,
  prefetchReviewReceipt,
} from "./merge-policy-intake-adapter.mjs";
import { unresolvedIntake } from "./merge-policy-intake-hold.mjs";
import {
  REVIEW_DISPATCH_REF,
  REVIEW_DISPATCH_REPORT_FILE,
} from "./merge-policy-review-dispatch.mjs";

export const SHADOW_CYCLE_KIND = "merge-policy-shadow-cycle-v1";
export const SHADOW_DISPATCH_RECORD_KIND = "merge-policy-shadow-dispatch-v1";
export const SHADOW_LIMITS = Object.freeze({
  runLocateMs: 90_000,
  runWaitMs: 20 * 60_000,
  runPollMs: 15_000,
  prefetchDeadlineMs: 10_000,
  logLineBytes: 65_536,
});
/** List prices for the pinned reviewer model (merge-policy-anthropic-review.mjs),
 * USD per million tokens; the plan's cost criteria are computed from these. */
export const PROVIDER_LIST_PRICE = Object.freeze({
  model: "claude-sonnet-4-6",
  inputPerMillion: 3,
  outputPerMillion: 15,
});
/** Preflight refusals: no paid work was requested. */
export const REFUSALS = Object.freeze([
  "DRAFT_OR_CLOSED",
  "LOCK_HELD",
  "UNKNOWN_PRODUCER",
  "STALE_BASE",
  "PRODUCER_BUSY",
]);
const REPOSITORY = /^[A-Za-z0-9][A-Za-z0-9-]{0,38}\/[A-Za-z0-9_.-]{1,100}$/;
const TAG_REF = /^refs\/tags\/[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
const ORIGIN =
  /^https:\/\/[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$/;

export class ShadowError extends Error {
  constructor(code, detail) {
    super(`Shadow cycle: ${code}${detail ? ` (${detail})` : ""}`);
    this.name = "ShadowError";
    this.code = code;
  }
}
function requireThat(condition, code, detail) {
  if (!condition) throw new ShadowError(code, detail);
}
const positive = (value) => Number.isSafeInteger(value) && value > 0;
const iso = (date) => date.toISOString().replace(/\.\d{3}Z$/, "Z");

/** Step 1. Read the live PR and control state and refuse, without paid work,
 * anything the plan says a shadow cycle must not review. */
export function preflight({ controller, api, producerId, workflowRef }) {
  const snapshot = controller.snapshot({
    allowMissingLedger: true,
    includeProducers: true,
  });
  const { context } = snapshot;
  const facts = {
    repository: context.repository,
    pullRequest: context.pullRequest,
    headSha: context.headSha,
    baseSha: context.baseSha,
    policyDigest: context.policyDigest,
    policySha: snapshot.policySha,
    producersSha: snapshot.producersSha,
    ledgerRevision: snapshot.ledger.revision,
  };
  const refuse = (refusal, detail) => ({ ok: false, refusal, detail, facts });
  if (context.draft || context.state !== "OPEN")
    return refuse("DRAFT_OR_CLOSED", context.state);
  // The lock document outlives every operation (owner null, intake
  // completed). What refuses a cycle is an operation still owned, or an
  // intake hold that is not completed: a `failed` hold is terminal and needs
  // the owner's reconciliation, which the plan counts as an intervention.
  if (
    snapshot.lock &&
    (snapshot.lock.owner !== null || unresolvedIntake(snapshot.lock))
  )
    return refuse(
      "LOCK_HELD",
      snapshot.lock.owner !== null
        ? "operation active"
        : `intake ${snapshot.intake?.phase ?? "unknown"}`,
    );
  const producer = snapshot.producers.find((entry) => entry.id === producerId);
  if (!producer) return refuse("UNKNOWN_PRODUCER", producerId);
  // The controller binds a review to the live base tip and the collector
  // requires that tip to be an ancestor of the head: a PR behind its base
  // cannot be reviewed, so do not pay for the attempt.
  const compare = api.call(
    "GET",
    `repos/${context.repository}/compare/${context.baseSha}...${context.headSha}`,
  );
  if (compare?.status !== "ahead")
    return refuse("STALE_BASE", String(compare?.status ?? "unknown"));
  // The producer workflow's concurrency group cancels a pending run when a
  // newer one is queued: one dispatch at a time, or a cycle loses its run.
  for (const status of ["queued", "in_progress", "pending", "waiting"]) {
    const runs = api.call(
      "GET",
      `repos/${producer.repository}/actions/workflows/${producer.workflowId}/runs?status=${status}&per_page=1`,
    );
    if ((runs?.total_count ?? runs?.workflow_runs?.length ?? 0) > 0)
      return refuse("PRODUCER_BUSY", status);
  }
  return {
    ok: true,
    facts,
    producer: Object.freeze({
      id: producer.id,
      lane: producer.lane,
      repository: producer.repository,
      repositoryId: producer.repositoryId,
      workflowId: producer.workflowId,
      workflowPath: producer.workflowPath,
      workflowRevision: producer.workflowRevision,
      artifactName: producer.artifactName,
      workflowRef,
    }),
  };
}

/** The newest run of the producer workflow before a dispatch. Run ids are
 * monotonic, so the run a dispatch creates is the one whose id exceeds this;
 * timestamps are never compared (the local clock and GitHub's differ). */
export function newestRunId({ api, producer }) {
  const page = api.call(
    "GET",
    `repos/${producer.repository}/actions/workflows/${producer.workflowId}/runs?per_page=1`,
  );
  const id = page?.workflow_runs?.[0]?.id ?? 0;
  requireThat(Number.isSafeInteger(id) && id >= 0, "invalid_run");
  return id;
}
/** Step 2a. The dispatcher's own statement of what it asks the producer to
 * review. metadata.target at intake is taken from this record and nothing
 * else; the receipt's target must equal it. */
export function dispatchRecord({ facts, producer, now, newestRunId }) {
  requireThat(
    Number.isSafeInteger(newestRunId) && newestRunId >= 0,
    "invalid_run",
  );
  return {
    schemaVersion: 1,
    kind: SHADOW_DISPATCH_RECORD_KIND,
    dispatchedAt: iso(now()),
    runsBefore: { newestId: newestRunId },
    producer,
    target: {
      repository: facts.repository,
      pullRequest: facts.pullRequest,
      headSha: facts.headSha,
      baseSha: facts.baseSha,
      policyDigest: facts.policyDigest,
    },
    control: {
      policySha: facts.policySha,
      producersSha: facts.producersSha,
      ledgerRevision: facts.ledgerRevision,
    },
    ref: producer.workflowRef.slice("refs/tags/".length),
    inputs: {
      pull_request: String(facts.pullRequest),
      head_sha: facts.headSha,
      base_sha: facts.baseSha,
      policy_digest: facts.policyDigest,
      workflow_id: String(producer.workflowId),
    },
    run: null,
  };
}
function durableWrite(path, value) {
  const bytes = Buffer.from(`${JSON.stringify(value, null, 2)}\n`);
  const temporary = `${path}.${process.pid}.tmp`;
  const fd = openSync(temporary, "wx", 0o600);
  try {
    writeSync(fd, bytes);
    fsyncSync(fd);
  } finally {
    closeSync(fd);
  }
  renameSync(temporary, path);
  const directory = openSync(dirname(path), "r");
  try {
    fsyncSync(directory);
  } finally {
    closeSync(directory);
  }
}
/** Step 2b. Written and synced BEFORE the dispatch request, so a dispatch
 * that was requested is never unrecorded. Refuses to overwrite. */
export function writeDispatchRecord(directory, record) {
  mkdirSync(directory, { recursive: true, mode: 0o700 });
  const stamp = record.dispatchedAt.replace(/[-:]/g, "");
  const path = join(
    directory,
    `${record.target.repository.replace("/", "--")}-${record.target.pullRequest}-${stamp}.json`,
  );
  const fd = openSync(path, "wx", 0o600);
  closeSync(fd);
  durableWrite(path, record);
  return path;
}
export function readDispatchRecord(path) {
  const record = JSON.parse(readFileSync(path, "utf8"));
  requireThat(
    record?.kind === SHADOW_DISPATCH_RECORD_KIND &&
      record.schemaVersion === 1 &&
      record.target &&
      record.producer &&
      REPOSITORY.test(record.producer.repository) &&
      positive(record.producer.workflowId) &&
      TAG_REF.test(record.producer.workflowRef) &&
      Number.isSafeInteger(record.runsBefore?.newestId) &&
      record.runsBefore.newestId >= 0,
    "invalid_dispatch_record",
  );
  return record;
}
/** Step 2c. The request itself: the workflow at the protected tag, the five
 * inputs the record states. GitHub answers 204 with no run identity. */
export function dispatchProducer({ api, record }) {
  api.call(
    "POST",
    `repos/${record.producer.repository}/actions/workflows/${record.producer.workflowId}/dispatches`,
    { ref: record.ref, inputs: record.inputs },
  );
}
/** Step 2d. Find the one run the dispatch created: same workflow, dispatched
 * on the tag at the approved revision, with an id above the newest run the
 * record saw before the request. Two candidates mean another dispatcher
 * raced; refuse rather than guess. A lost POST response that still reached
 * GitHub is found the same way. */
export async function locateRun({ api, record, sleep, now }) {
  const started = now();
  for (;;) {
    const page = api.call(
      "GET",
      `repos/${record.producer.repository}/actions/workflows/${record.producer.workflowId}/runs?event=workflow_dispatch&per_page=10`,
    );
    const candidates = (page?.workflow_runs ?? []).filter(
      (run) =>
        positive(run.id) &&
        run.id > record.runsBefore.newestId &&
        run.event === "workflow_dispatch" &&
        run.head_branch === record.ref &&
        run.head_sha === record.producer.workflowRevision,
    );
    requireThat(candidates.length <= 1, "AMBIGUOUS_RUN");
    if (candidates.length === 1) {
      requireThat(positive(candidates[0].id), "invalid_run");
      return candidates[0].id;
    }
    requireThat(now() - started < SHADOW_LIMITS.runLocateMs, "RUN_NOT_FOUND");
    await sleep(SHADOW_LIMITS.runPollMs);
  }
}
/** Step 3. Wait for attempt 1 to complete. Anything but a first-attempt
 * success is a producer failure the cycle records and stops on. */
export async function waitForRun({ api, record, runId, sleep, now }) {
  const started = now();
  for (;;) {
    const run = api.call(
      "GET",
      `repos/${record.producer.repository}/actions/runs/${runId}`,
    );
    requireThat(run?.id === runId, "invalid_run");
    if (run.status === "completed") {
      const summary = {
        id: runId,
        attempt: run.run_attempt,
        status: run.status,
        conclusion: run.conclusion,
      };
      requireThat(
        run.run_attempt === 1 && run.conclusion === "success",
        "PRODUCER_FAILED",
        `attempt ${run.run_attempt} ${run.conclusion}`,
      );
      return summary;
    }
    requireThat(now() - started < SHADOW_LIMITS.runWaitMs, "RUN_TIMEOUT");
    await sleep(SHADOW_LIMITS.runPollMs);
  }
}
/** Step 3b. The receipt artifact by its exact configured name. */
export function locateArtifact({ api, record, runId, name }) {
  const page = api.call(
    "GET",
    `repos/${record.producer.repository}/actions/runs/${runId}/artifacts?per_page=100`,
  );
  const matches = (page?.artifacts ?? []).filter(
    (artifact) => artifact.name === name && !artifact.expired,
  );
  requireThat(matches.length === 1, "ARTIFACT_NOT_FOUND", name);
  requireThat(positive(matches[0].id), "invalid_artifact");
  return matches[0].id;
}

/** The artifact client for one producer, credentialed by the owner's gh
 * identity at call time; the token never leaves the provider closure. */
export function artifactClient({
  producer,
  artifactName = producer.artifactName,
  downloadOrigins,
  ghToken,
  fetchImpl,
}) {
  return createGitHubArtifactClient({
    producer: {
      repository: producer.repository,
      repositoryId: producer.repositoryId,
      workflowId: producer.workflowId,
      workflowPath: producer.workflowPath,
      workflowRevision: producer.workflowRevision,
      artifactName,
      workflowRef: producer.workflowRef,
    },
    downloadOrigins,
    fetchImpl,
    tokenProvider: async () => ghToken(),
  });
}
/** Step 4. The receipt through the trusted intake, target from the record. */
export async function intake({
  controller,
  client,
  record,
  runId,
  artifactId,
}) {
  const selector = {
    repository: record.producer.repository,
    runId,
    runAttempt: 1,
    artifactId,
  };
  const prefetch = await prefetchReviewReceipt({
    client,
    selector,
    dispatchRecord: record.target,
    deadlineMs: SHADOW_LIMITS.prefetchDeadlineMs,
  });
  const receipt = JSON.parse(prefetch.receipt.toString("utf8"));
  const review = {
    outcome: receipt.outcome,
    findingCount: receipt.findingCount,
    findings: (receipt.findings ?? []).map((finding) => ({
      key: finding.key,
      priority: finding.priority,
      path: finding.path,
      title: String(finding.title ?? "").slice(0, 200),
    })),
  };
  const result = await controller.recordReviewIntake({
    readers: createIntakeReaders({ client, prefetch }),
    request: {
      producerId: record.producer.id,
      runId,
      runAttempt: 1,
      artifactId,
    },
  });
  return {
    outcome: "recorded",
    receiptId: result.receiptId,
    receiptSha256: prefetch.metadata.artifact.sha256,
    archiveSha256: prefetch.archiveSha256,
    changed: result.changed,
    ledgerRevision: result.ledgerRevision,
    ledgerSha: result.ledgerSha,
    review,
  };
}
/** Optional. Token usage from the producer's non-acceptance report, read under
 * the same client checks; a missing or unreadable report costs the cycle its
 * provider figures, never its receipt. */
export async function providerUsage({ api, record, runId, client }) {
  let artifactId;
  try {
    artifactId = locateArtifact({
      api,
      record,
      runId,
      name: REVIEW_DISPATCH_REPORT_FILE,
    });
    const facts = await client.read(
      { runId, runAttempt: 1, artifactId },
      { deadlineMs: SHADOW_LIMITS.prefetchDeadlineMs },
    );
    const report = JSON.parse(
      extractReviewReceipt(
        facts.archiveBytes,
        REVIEW_DISPATCH_REPORT_FILE,
      ).toString("utf8"),
    );
    const usage = report?.provider?.usage;
    requireThat(
      positive(usage?.inputTokens) && positive(usage?.outputTokens),
      "usage_missing",
    );
    const costUsd =
      (usage.inputTokens * PROVIDER_LIST_PRICE.inputPerMillion +
        usage.outputTokens * PROVIDER_LIST_PRICE.outputPerMillion) /
      1_000_000;
    return {
      model: String(report.provider.model ?? "").slice(0, 64),
      inputTokens: usage.inputTokens,
      outputTokens: usage.outputTokens,
      costUsd: Math.round(costUsd * 10_000) / 10_000,
    };
  } catch (error) {
    return { unavailable: error.code ?? "report_unreadable" };
  }
}
/** Step 5. The policy decision, read-only: no check run is created. */
export function verdict({ controller }) {
  const { result, enforcementPublished } = controller.evaluate({
    publish: false,
  });
  requireThat(enforcementPublished === false, "published");
  // Either the core evaluation ({decision, reasons[], openFindings[]}) or the
  // intake-hold block ({decision, code, reason}) when an intake is unresolved.
  return {
    decision: result.decision,
    reasons: result.reasons
      ? result.reasons.map((reason) => ({
          code: reason.code,
          ...(reason.findingId ? { findingId: reason.findingId } : {}),
        }))
      : [
          {
            code: result.code,
            // The hold's reason names its phase (a fixed template).
            reason: String(result.reason ?? "").slice(0, 200),
          },
        ],
    openFindings: (result.openFindings ?? []).map((finding) => ({
      findingId: finding.findingId,
      priority: finding.priority,
      path: finding.path,
      title: String(finding.title ?? "").slice(0, 200),
      blocking: finding.blocking,
    })),
    pendingReviews: result.pendingReviews ?? [],
  };
}
/** Step 6. One line per cycle. Bounded; nothing secret is ever an input. */
export function appendCycle(logPath, entry) {
  const line = `${JSON.stringify(entry)}\n`;
  requireThat(
    Buffer.byteLength(line) <= SHADOW_LIMITS.logLineBytes,
    "log_line_too_long",
  );
  mkdirSync(dirname(logPath), { recursive: true, mode: 0o700 });
  appendFileSync(logPath, line, { mode: 0o600 });
}
function failureOf(error) {
  return {
    name: error?.name ?? "Error",
    code: error?.code ?? null,
    // Controller and adapter errors are closed codes or sanitized HTTP
    // statuses; the message is kept short and never a response body.
    message: String(error?.message ?? "").slice(0, 200),
    retainLock: error?.retainLock === true,
  };
}

/** One complete cycle. deps: {api, controller, ghToken, fetchImpl, now, sleep}.
 * Returns the log entry it appended (or would have appended). */
export async function runShadowCycle(deps, options) {
  const { api, controller, ghToken, fetchImpl, now, sleep } = deps;
  const {
    producerId,
    workflowRef,
    downloadOrigins,
    dispatchDirectory,
    logPath,
  } = options;
  requireThat(TAG_REF.test(workflowRef), "invalid_workflow_ref");
  requireThat(
    Array.isArray(downloadOrigins) &&
      downloadOrigins.length > 0 &&
      downloadOrigins.every((origin) => ORIGIN.test(origin)),
    "invalid_download_origins",
  );
  const startedAt = now();
  const entry = {
    schemaVersion: 1,
    kind: SHADOW_CYCLE_KIND,
    startedAt: iso(startedAt),
    finishedAt: null,
    repository: controller.repository,
    pullRequest: controller.pullRequest,
    facts: null,
    refusal: null,
    producer: null,
    dispatch: null,
    intake: null,
    provider: null,
    verdict: null,
    durationsMs: {},
    interventions: { count: 0, note: "" },
    triage: null,
    failure: null,
    enforcementPublished: false,
  };
  const timed = async (name, work) => {
    const before = now();
    try {
      return await work();
    } finally {
      entry.durationsMs[name] = now() - before;
    }
  };
  const finish = () => {
    entry.finishedAt = iso(now());
    if (!logPath) return entry;
    try {
      appendCycle(logPath, entry);
    } catch (error) {
      // Keep the line: once more with the finding lists as counts. A second
      // failure is reported on the entry, which main() prints regardless.
      const reduced = {
        ...entry,
        logReduced: error.code ?? "append_failed",
        intake:
          entry.intake?.review === undefined
            ? entry.intake
            : {
                ...entry.intake,
                review: {
                  ...entry.intake.review,
                  findings: entry.intake.review.findings.length,
                },
              },
        verdict:
          entry.verdict === null
            ? null
            : {
                ...entry.verdict,
                openFindings: entry.verdict.openFindings.length,
              },
      };
      try {
        appendCycle(logPath, reduced);
        entry.logReduced = reduced.logReduced;
      } catch (second) {
        entry.logFailure = second.code ?? "append_failed";
      }
    }
    return entry;
  };
  try {
    const gate = await timed("preflight", async () =>
      preflight({ controller, api, producerId, workflowRef }),
    );
    entry.facts = gate.facts;
    if (!gate.ok) {
      entry.refusal = { code: gate.refusal, detail: gate.detail ?? null };
      return finish();
    }
    entry.producer = gate.producer;
    const record = dispatchRecord({
      facts: gate.facts,
      producer: gate.producer,
      now,
      newestRunId: newestRunId({ api, producer: gate.producer }),
    });
    const recordPath = writeDispatchRecord(dispatchDirectory, record);
    entry.dispatch = {
      recordPath,
      dispatchedAt: record.dispatchedAt,
      run: null,
      artifactId: null,
    };
    const runId = await timed("dispatch", async () => {
      dispatchProducer({ api, record });
      return locateRun({ api, record, sleep, now });
    });
    durableWrite(recordPath, { ...record, run: { id: runId } });
    entry.dispatch.run = { id: runId };
    const run = await timed("wait", async () =>
      waitForRun({ api, record, runId, sleep, now }),
    );
    entry.dispatch.run = run;
    const artifactId = locateArtifact({
      api,
      record,
      runId,
      name: record.producer.artifactName,
    });
    entry.dispatch.artifactId = artifactId;
    const client = artifactClient({
      producer: record.producer,
      downloadOrigins,
      ghToken,
      fetchImpl,
    });
    try {
      entry.intake = await timed("intake", async () =>
        intake({ controller, client, record, runId, artifactId }),
      );
    } catch (error) {
      entry.intake = { outcome: "failed", failure: failureOf(error) };
    }
    entry.provider = await timed("provider", async () =>
      providerUsage({
        api,
        record,
        runId,
        client: artifactClient({
          producer: record.producer,
          artifactName: REVIEW_DISPATCH_REPORT_FILE,
          downloadOrigins,
          ghToken,
          fetchImpl,
        }),
      }),
    );
    entry.verdict = await timed("verdict", async () => verdict({ controller }));
    return finish();
  } catch (error) {
    entry.failure = failureOf(error);
    return finish();
  }
}

/** The Section 4 metrics from the log's lines, computed where the data
 * allows and null where triage has not supplied it. */
export function summarize(entries) {
  const cycles = entries.filter((entry) => entry?.kind === SHADOW_CYCLE_KIND);
  const refusals = {};
  for (const entry of cycles)
    if (entry.refusal)
      refusals[entry.refusal.code] = (refusals[entry.refusal.code] ?? 0) + 1;
  const dispatched = cycles.filter((entry) => entry.dispatch?.run?.id);
  const producerSucceeded = dispatched.filter(
    (entry) => entry.dispatch.run.conclusion === "success",
  );
  const intakeRecorded = producerSucceeded.filter(
    (entry) => entry.intake?.outcome === "recorded",
  );
  const intakeFailures = {};
  for (const entry of producerSucceeded)
    if (entry.intake?.outcome !== "recorded") {
      const code =
        entry.intake?.failure?.code ?? entry.intake?.failure?.name ?? "unknown";
      intakeFailures[code] = (intakeFailures[code] ?? 0) + 1;
    }
  // K3: intake failure on 2 of any 5 consecutive successful producer runs.
  let intakeFailedTwoOfFive = false;
  for (let index = 0; index + 5 <= producerSucceeded.length; index++) {
    const window = producerSucceeded.slice(index, index + 5);
    if (
      window.filter((entry) => entry.intake?.outcome !== "recorded").length >= 2
    )
      intakeFailedTwoOfFive = true;
  }
  const costs = cycles
    .map((entry) => entry.provider?.costUsd)
    .filter((cost) => typeof cost === "number");
  const verdicts = {};
  for (const entry of cycles)
    if (entry.verdict)
      verdicts[entry.verdict.decision] =
        (verdicts[entry.verdict.decision] ?? 0) + 1;
  // Triage labels: blocking findings the owner has judged.
  const labels = { true_positive: 0, false_positive: 0, should_be_p3: 0 };
  const outcomes = {};
  // K1's second clause is a share of PRs, not of cycles: a PR reviewed three
  // times counts once, and is "held on false findings" if any of its cycles
  // was held only on findings the owner labelled false.
  const prOutcome = new Map();
  const prHeldFalse = new Set();
  for (const entry of cycles) {
    const triage = entry.triage;
    if (!triage) continue;
    const key = `${entry.repository}#${entry.pullRequest}`;
    if (triage.outcome) {
      outcomes[triage.outcome] = (outcomes[triage.outcome] ?? 0) + 1;
      prOutcome.set(key, triage.outcome);
    }
    const judged = Object.values(triage.findings ?? {});
    for (const label of judged) if (label in labels) labels[label] += 1;
    if (
      entry.verdict?.decision !== "pass" &&
      judged.length > 0 &&
      judged.every((label) => label === "false_positive")
    )
      prHeldFalse.add(key);
  }
  const judgedBlocking = labels.true_positive + labels.false_positive;
  const precision =
    judgedBlocking > 0 ? labels.true_positive / judgedBlocking : null;
  const mergedAsIsPRs = [...prOutcome]
    .filter(([, outcome]) => outcome === "merged_as_is")
    .map(([key]) => key);
  const mergedAsIs = mergedAsIsPRs.length;
  const heldFalseShare =
    mergedAsIs > 0
      ? mergedAsIsPRs.filter((key) => prHeldFalse.has(key)).length / mergedAsIs
      : null;
  // Reviews per merged PR (K2): cycles that dispatched, grouped by PR, among
  // PRs whose triage says merged.
  const perPR = new Map();
  for (const entry of dispatched) {
    const key = `${entry.repository}#${entry.pullRequest}`;
    perPR.set(key, (perPR.get(key) ?? 0) + 1);
  }
  const mergedPRs = new Set(
    cycles
      .filter((entry) => /^merged_/.test(entry.triage?.outcome ?? ""))
      .map((entry) => `${entry.repository}#${entry.pullRequest}`),
  );
  const reviewsPerMergedPR = [...mergedPRs]
    .map((key) => perPR.get(key) ?? 0)
    .sort((a, b) => a - b);
  const median = (values) =>
    values.length
      ? values.length % 2
        ? values[(values.length - 1) / 2]
        : (values[values.length / 2 - 1] + values[values.length / 2]) / 2
      : null;
  // K3: interventions per ISO week.
  const weeks = {};
  for (const entry of cycles) {
    const week = isoWeek(entry.startedAt);
    weeks[week] = (weeks[week] ?? 0) + (entry.interventions?.count ?? 0);
  }
  const mean = (values) =>
    values.length ? values.reduce((a, b) => a + b, 0) / values.length : null;
  const k4 = cycles.filter((entry) => entry.triage?.k4 === true).length;
  const recentWeeks = Object.keys(weeks).sort().slice(-3);
  const interventionsAtMostOnePerWeekLast3 =
    recentWeeks.length < 3
      ? null
      : recentWeeks.every((week) => weeks[week] <= 1);
  return {
    cycles: cycles.length,
    refusals,
    dispatched: dispatched.length,
    producerSucceeded: producerSucceeded.length,
    intakeRecorded: intakeRecorded.length,
    intakeFailures,
    intakeSuccessRate: producerSucceeded.length
      ? intakeRecorded.length / producerSucceeded.length
      : null,
    verdicts,
    cost: {
      reviews: costs.length,
      meanUsd: mean(costs),
      maxUsd: costs.length ? Math.max(...costs) : null,
    },
    triage: {
      outcomes,
      labels,
      precision,
      mergedAsIsHeldOnFalseFindings: heldFalseShare,
      medianReviewsPerMergedPR: median(reviewsPerMergedPR),
    },
    interventionsPerWeek: weeks,
    kill: {
      K1: {
        evaluable: judgedBlocking >= 20 || mergedAsIs >= 20,
        triggered:
          (precision !== null && judgedBlocking >= 20 && precision < 0.5) ||
          (heldFalseShare !== null && mergedAsIs >= 20 && heldFalseShare > 0.4),
      },
      K2: {
        triggered:
          (mean(costs) ?? 0) > 0.75 ||
          costs.some((cost) => cost > 1.5) ||
          (median(reviewsPerMergedPR) ?? 0) > 3 ||
          (cycles.length > 0 &&
            (refusals.STALE_BASE ?? 0) / cycles.length > 0.5),
      },
      K3: {
        triggered:
          Object.values(weeks).some((count) => count > 2) ||
          intakeFailedTwoOfFive,
      },
      K4: { events: k4, triggered: k4 > 0 },
      K5: {
        note: "owner click-merges and the calendar date are counted by hand",
      },
    },
    success: {
      precisionAtLeast70: precision === null ? null : precision >= 0.7,
      intakeSuccessAtLeast90:
        producerSucceeded.length === 0
          ? null
          : intakeRecorded.length / producerSucceeded.length >= 0.9,
      meanCostAtMost050: mean(costs) === null ? null : mean(costs) <= 0.5,
      interventionsAtMostOnePerWeekLast3,
      zeroK4: k4 === 0,
      passesOnMergedPRs: cycles.filter(
        (entry) =>
          entry.verdict?.decision === "pass" &&
          /^merged_/.test(entry.triage?.outcome ?? ""),
      ).length,
      holdsWithConfirmedTruePositives: cycles.filter(
        (entry) =>
          entry.verdict?.decision !== "pass" &&
          entry.verdict &&
          Object.values(entry.triage?.findings ?? {}).includes("true_positive"),
      ).length,
    },
  };
}
function isoWeek(timestamp) {
  const date = new Date(timestamp);
  const day = (date.getUTCDay() + 6) % 7;
  date.setUTCDate(date.getUTCDate() - day + 3);
  const firstThursday = new Date(Date.UTC(date.getUTCFullYear(), 0, 4));
  const week =
    1 +
    Math.round(
      ((date - firstThursday) / 86_400_000 -
        3 +
        ((firstThursday.getUTCDay() + 6) % 7)) /
        7,
    );
  return `${date.getUTCFullYear()}-W${String(week).padStart(2, "0")}`;
}
export function readLog(path) {
  return readFileSync(path, "utf8")
    .split("\n")
    .filter((line) => line.trim())
    .map((line) => JSON.parse(line));
}

export function parseArgs(args) {
  const command = args.shift();
  requireThat(
    ["cycle", "preflight", "summarize"].includes(command),
    "usage",
    "command must be cycle, preflight or summarize",
  );
  const values = { command, downloadOrigins: [] };
  const names = new Set([
    "repo",
    "pr",
    "control-repo",
    "producer",
    "workflow-ref",
    "download-origin",
    "dispatch-dir",
    "log",
  ]);
  while (args.length) {
    const flag = args.shift();
    requireThat(
      flag?.startsWith("--") && names.has(flag.slice(2)),
      "usage",
      "unknown argument",
    );
    const key = flag.slice(2);
    requireThat(
      args.length > 0 && !args[0].startsWith("--"),
      "usage",
      `missing value for --${key}`,
    );
    const value = args.shift();
    if (key === "download-origin") {
      values.downloadOrigins.push(value);
      continue;
    }
    requireThat(values[key] === undefined, "usage", `duplicate --${key}`);
    values[key] = value;
  }
  return values;
}
export async function main(args = process.argv.slice(2)) {
  const options = parseArgs(args);
  if (options.command === "summarize") {
    requireThat(options.log, "usage", "--log is required");
    process.stdout.write(
      `${JSON.stringify(summarize(readLog(resolve(options.log))), null, 2)}\n`,
    );
    return;
  }
  for (const key of ["repo", "pr", "control-repo", "producer"])
    requireThat(options[key], "usage", `--${key} is required`);
  const api = new GitHubAPI();
  const controller = new PolicyController({
    api,
    repository: options.repo,
    pullRequest: Number(options.pr),
    controlRepository: options["control-repo"],
  });
  const workflowRef = options["workflow-ref"] ?? REVIEW_DISPATCH_REF;
  if (options.command === "preflight") {
    const gate = preflight({
      controller,
      api,
      producerId: options.producer,
      workflowRef,
    });
    process.stdout.write(`${JSON.stringify(gate, null, 2)}\n`);
    if (!gate.ok) process.exitCode = 1;
    return;
  }
  requireThat(options["dispatch-dir"], "usage", "--dispatch-dir is required");
  requireThat(options.log, "usage", "--log is required");
  const entry = await runShadowCycle(
    {
      api,
      controller,
      fetchImpl: globalThis.fetch,
      // The owner's gh token, read at call time inside the client and never
      // held by this process beyond the call.
      ghToken: () =>
        execFileSync("gh", ["auth", "token"], {
          encoding: "utf8",
          stdio: ["ignore", "pipe", "ignore"],
          timeout: 10_000,
        }).trim(),
      now: () => new Date(),
      sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
    },
    {
      producerId: options.producer,
      workflowRef,
      downloadOrigins: options.downloadOrigins,
      dispatchDirectory: resolve(options["dispatch-dir"]),
      logPath: resolve(options.log),
    },
  );
  process.stdout.write(`${JSON.stringify(entry, null, 2)}\n`);
  if (
    entry.refusal ||
    entry.failure ||
    entry.logFailure ||
    entry.intake?.outcome !== "recorded"
  )
    process.exitCode = 1;
}

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(process.argv[1]).href
) {
  main().catch((error) => {
    process.stderr.write(`${error?.message ?? "Shadow cycle failed"}\n`);
    process.exitCode = 2;
  });
}
