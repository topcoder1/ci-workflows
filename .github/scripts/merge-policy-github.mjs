#!/usr/bin/env node
// Trusted control-plane adapter. Never execute code or shell text from a PR.
import { execFileSync } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import { hostname } from "node:os";
import { pathToFileURL } from "node:url";
import {
  evaluate,
  validateContext,
  validatePolicy,
} from "./merge-policy-core.mjs";
import { appendEvent, emptyLedger } from "./merge-policy-state.mjs";
import {
  prepareReviewIntake,
  validateProducerConfiguration,
} from "./merge-policy-intake.mjs";
import {
  blockedDecision,
  createIntakeHold,
  assertIntakeTransition,
  unresolvedIntake,
  validateBinding,
  validateIntakeHold,
} from "./merge-policy-intake-hold.mjs";

export const CHECK_NAME = "merge-policy / decision";
const REPO = /^[A-Za-z0-9_-]+\/[A-Za-z0-9_.-]+$/;
const SHA = /^[a-f0-9]{40}$/;
const MAX_BYTES = 2 * 1024 * 1024;

function assert(condition, message) {
  if (!condition) throw new Error(message);
}
function repo(value) {
  assert(typeof value === "string" && REPO.test(value), "Invalid repository");
  assert(
    !value.split("/").some((part) => part === "." || part === ".."),
    "Invalid repository",
  );
  return value;
}
function positive(value, name) {
  assert(Number.isSafeInteger(value) && value > 0, `Invalid ${name}`);
  return value;
}
function same(a, b) {
  return JSON.stringify(a) === JSON.stringify(b);
}
function validateLock(value) {
  assert(
    value && typeof value === "object" && !Array.isArray(value),
    "Invalid publication lock",
  );
  assert(
    value.schemaVersion === 1 || value.schemaVersion === 2,
    "Invalid publication lock",
  );
  assert(
    typeof value.owner === "string" || value.owner === null,
    "Invalid publication lock owner",
  );
  assert(
    Number.isSafeInteger(value.sequence) &&
      value.sequence >= 0 &&
      value.sequence < Number.MAX_SAFE_INTEGER,
    "Invalid publication lock sequence",
  );
  if (value.schemaVersion === 2)
    assert(
      typeof value.startedAt === "string",
      "Invalid publication lock timestamp",
    );
  if (value.schemaVersion === 2) {
    assert(
      Object.hasOwn(value, "intake"),
      "Invalid publication lock intake state",
    );
    try {
      validateIntakeHold(value.intake, value.sequence);
    } catch (error) {
      throw new Error(error.message);
    }
  }
  return value;
}
export function policyDigest(policyBytes, producerBytes) {
  if (producerBytes === undefined)
    return createHash("sha256").update(policyBytes).digest("hex");
  // Length framing binds the exact two protected documents unambiguously. Keep
  // the legacy policy-only digest only when no producer document is present.
  return createHash("sha256")
    .update("merge-policy-with-producers-v1\0")
    .update(`${policyBytes.length}\0`)
    .update(policyBytes)
    .update(`${producerBytes.length}\0`)
    .update(producerBytes)
    .digest("hex");
}
function executionIdentity() {
  return process.env.GITHUB_ACTIONS === "true"
    ? {
        kind: "actions",
        repository: repo(process.env.GITHUB_REPOSITORY),
        runId: positive(Number(process.env.GITHUB_RUN_ID), "run ID"),
      }
    : { kind: "local", host: hostname(), pid: process.pid };
}
export function parseDocument(bytes) {
  assert(
    Buffer.byteLength(bytes) <= MAX_BYTES,
    "JSON document exceeds size limit",
  );
  try {
    return JSON.parse(String(bytes));
  } catch {
    throw new Error("Invalid JSON document; contents withheld");
  }
}

export class GitHubAPI {
  constructor({ run = execFileSync, env = process.env } = {}) {
    this.run = run;
    this.env = env;
  }
  call(method, endpoint, body, { pages = false } = {}) {
    const args = ["api", "--method", method, endpoint];
    if (pages) args.push("--paginate", "--slurp");
    if (body !== undefined) args.push("--input", "-");
    try {
      const output = this.run("gh", args, {
        env: this.env,
        encoding: "utf8",
        input: body === undefined ? undefined : JSON.stringify(body),
        maxBuffer: 8 * MAX_BYTES,
        timeout: 60_000,
        stdio: ["pipe", "pipe", "pipe"],
      });
      return output.trim() ? JSON.parse(output) : null;
    } catch (error) {
      // Never dump request bodies, authentication environment, or raw API output.
      const status = String(error.stderr || "").match(/HTTP (\d{3})/)?.[1];
      const failure = new Error(
        `GitHub ${method} failed${status ? ` (HTTP ${status})` : " or returned invalid data"}`,
      );
      failure.status = status ? Number(status) : null;
      failure.uncertainWrite =
        method !== "GET" && (!status || Number(status) >= 500);
      throw failure;
    }
  }
}

export class PolicyController {
  constructor({
    api,
    repository,
    pullRequest,
    controlRepository,
    expectedAppId,
    now = () => new Date(),
  }) {
    this.api = api;
    this.repository = repo(repository);
    this.pullRequest = positive(pullRequest, "pull request");
    this.controlRepository = repo(controlRepository);
    assert(
      repository.toLowerCase() !== controlRepository.toLowerCase(),
      "Control state must be outside the application repository",
    );
    if (expectedAppId !== undefined) positive(expectedAppId, "expected App ID");
    this.expectedAppId = expectedAppId;
    this.now = now;
    const stem = `${repository}/${pullRequest}`;
    this.policyPath = `policies/${repository}.json`;
    this.producersPath = `producers/${repository}.json`;
    this.ledgerPath = `state/${stem}.json`;
    this.lockPath = `locks/${stem}.json`;
  }
  document(path, ref = "main", optional = false) {
    let response;
    try {
      response = this.api.call(
        "GET",
        `repos/${this.controlRepository}/contents/${path}?ref=${encodeURIComponent(ref)}`,
      );
    } catch (error) {
      if (optional && error.status === 404) return null;
      throw error;
    }
    assert(
      response?.type === "file" &&
        response.encoding === "base64" &&
        SHA.test(response.sha),
      "Invalid control document metadata",
    );
    const bytes = Buffer.from(response.content, "base64");
    assert(bytes.length <= MAX_BYTES, "Control document exceeds size limit");
    return { value: parseDocument(bytes), sha: response.sha, bytes };
  }
  write(path, value, previousSha, message) {
    const content = Buffer.from(`${JSON.stringify(value, null, 2)}\n`);
    assert(content.length <= MAX_BYTES, "Control document exceeds size limit");
    const body = {
      message,
      branch: "main",
      content: content.toString("base64"),
    };
    if (previousSha) body.sha = previousSha;
    return this.api.call(
      "PUT",
      `repos/${this.controlRepository}/contents/${path}`,
      body,
    );
  }
  snapshot({ allowMissingLedger = false, includeProducers = false } = {}) {
    const controlSha = this.api.call(
      "GET",
      `repos/${this.controlRepository}/git/ref/heads/main`,
    )?.object?.sha;
    assert(SHA.test(controlSha), "Invalid control revision");
    const policy = this.document(this.policyPath, controlSha);
    validatePolicy(policy.value);
    assert(
      policy.value.repository === this.repository,
      "Policy repository mismatch",
    );
    const producers = this.document(
      this.producersPath,
      controlSha,
      !includeProducers,
    );
    let producerConfiguration;
    if (producers) {
      producerConfiguration = validateProducerConfiguration({
        configuration: producers.value,
        policy: policy.value,
      });
    } else {
      const history = this.api.call(
        "GET",
        `repos/${this.controlRepository}/commits?sha=${controlSha}&path=${encodeURIComponent(this.producersPath)}&per_page=1`,
      );
      assert(
        Array.isArray(history) && history.length === 0,
        "Previously recorded producer configuration is missing; restore configuration before proceeding",
      );
    }
    const pr = this.api.call(
      "GET",
      `repos/${this.repository}/pulls/${this.pullRequest}`,
    );
    assert(
      pr?.number === this.pullRequest &&
        pr.base?.repo?.full_name === this.repository,
      "PR identity mismatch",
    );
    const baseSha = this.api.call(
      "GET",
      `repos/${this.repository}/git/ref/heads/${encodeURIComponent(pr.base.ref)}`,
    )?.object?.sha;
    const pages = this.api.call(
      "GET",
      `repos/${this.repository}/pulls?state=open&per_page=100`,
      undefined,
      { pages: true },
    );
    assert(
      Array.isArray(pages) && pages.every(Array.isArray),
      "Invalid PR association list",
    );
    const open = pages.flat();
    assert(open.length < 10_000, "PR association list exceeds supported limit");
    const count = open.filter((item) => item.head?.sha === pr.head?.sha).length;
    const context = {
      repository: this.repository,
      pullRequest: this.pullRequest,
      headSha: pr.head?.sha,
      baseSha,
      policyDigest: policyDigest(policy.bytes, producers?.bytes),
      authorId: pr.user?.id,
      draft: pr.draft,
      state: pr.merged_at ? "MERGED" : pr.state === "open" ? "OPEN" : "CLOSED",
      headAssociationCount: Math.max(count, 1),
    };
    validateContext(context);
    if (context.state === "OPEN")
      assert(
        open.some((item) => item.number === this.pullRequest),
        "Current PR absent from association list",
      );
    const ledger = this.document(
      this.ledgerPath,
      controlSha,
      allowMissingLedger,
    );
    if (!ledger) {
      const history = this.api.call(
        "GET",
        `repos/${this.controlRepository}/commits?sha=${controlSha}&path=${encodeURIComponent(this.ledgerPath)}&per_page=1`,
      );
      assert(
        Array.isArray(history) && history.length === 0,
        "Previously recorded ledger is missing; restore state before proceeding",
      );
    }
    const lock = this.document(this.lockPath, controlSha, true);
    if (!lock) {
      const history = this.api.call(
        "GET",
        `repos/${this.controlRepository}/commits?sha=${controlSha}&path=${encodeURIComponent(this.lockPath)}&per_page=1`,
      );
      assert(
        Array.isArray(history) && history.length === 0,
        "Previously recorded publication lock is missing; restore lock state before proceeding",
      );
    } else validateLock(lock.value);
    return {
      context,
      policy: policy.value,
      policySha: policy.sha,
      ledger: ledger?.value ?? emptyLedger(this.repository, this.pullRequest),
      ledgerSha: ledger?.sha ?? null,
      lock: lock?.value ?? null,
      lockSha: lock?.sha ?? null,
      intake: lock?.value?.intake ?? null,
      ...(producers
        ? {
            producers: producerConfiguration.producers,
            producersSha: producers.sha,
          }
        : {}),
    };
  }
  lock({ intake = undefined, intakeSelector = undefined } = {}) {
    const previous = this.document(this.lockPath, "main", true);
    if (previous) {
      validateLock(previous.value);
      assert(
        previous.value.owner === null,
        "Policy operation already active; reconcile the owning run before recovery",
      );
      assert(
        !unresolvedIntake(previous.value),
        "Trusted review intake is unresolved; reconcile the intake generation before starting another operation",
      );
    }
    const sequence = (previous?.value.sequence ?? 0) + 1;
    assert(
      !(intake !== undefined && intakeSelector !== undefined),
      "Specify either an intake hold or its selector",
    );
    const persistedIntake =
      intakeSelector !== undefined
        ? createIntakeHold(intakeSelector, sequence)
        : intake === undefined
          ? (previous?.value?.intake ?? null)
          : validateIntakeHold(intake, sequence);
    const lock = {
      schemaVersion: 2,
      owner: randomUUID(),
      sequence,
      startedAt: this.now().toISOString(),
      execution: executionIdentity(),
      intake: persistedIntake,
    };
    this.write(
      this.lockPath,
      lock,
      previous?.sha,
      `Acquire policy operation ${this.repository}#${this.pullRequest}`,
    );
    return lock;
  }
  assertLock(lock) {
    const document = this.document(this.lockPath);
    validateLock(document.value);
    assert(
      same(document.value, lock),
      "Policy operation ownership changed; obsolete publisher refused",
    );
    return document;
  }
  unlock(lock) {
    const current = this.assertLock(lock);
    validateLock(current.value);
    this.write(
      this.lockPath,
      { ...lock, owner: null },
      current.sha,
      `Complete policy operation ${this.repository}#${this.pullRequest}`,
    );
  }
  noteCheck(lock, check) {
    const current = this.assertLock(lock);
    validateLock(current.value);
    const next = {
      ...lock,
      check: { id: check.id, headSha: check.head_sha, appId: check.app.id },
    };
    this.write(
      this.lockPath,
      next,
      current.sha,
      `Record policy publication ${this.repository}#${this.pullRequest}`,
    );
    Object.assign(lock, next);
  }
  ownerStopped(execution) {
    if (execution?.kind === "actions") {
      repo(execution.repository);
      positive(execution.runId, "owning run ID");
      const run = this.api.call(
        "GET",
        `repos/${execution.repository}/actions/runs/${execution.runId}`,
      );
      return run?.id === execution.runId && run.status === "completed";
    }
    assert(
      execution?.kind === "local" && execution.host === hostname(),
      "Local lock recovery must run on the owning host",
    );
    positive(execution.pid, "owning process ID");
    try {
      process.kill(execution.pid, 0);
      return false;
    } catch (error) {
      if (error.code === "ESRCH") return true;
      throw error;
    }
  }
  recover({ expectedOwner, expectedLockSha }) {
    positive(this.expectedAppId, "expected App ID for recovery");
    assert(
      typeof expectedOwner === "string" &&
        expectedOwner.length > 0 &&
        SHA.test(expectedLockSha),
      "Recovery requires exact lock owner and blob SHA",
    );
    const current = this.document(this.lockPath);
    validateLock(current.value);
    assert(
      current.sha === expectedLockSha && current.value.owner === expectedOwner,
      "Recovery lock identity changed",
    );
    assert(
      this.ownerStopped(current.value.execution),
      "Owning operation is still active; recovery refused",
    );
    // Claim a new active owner before touching checks. A delayed competing
    // recoverer must lose this CAS without invalidating a newer decision.
    const lock = {
      ...current.value,
      schemaVersion: 2,
      owner: randomUUID(),
      sequence: current.value.sequence + 1,
      startedAt: this.now().toISOString(),
      execution: executionIdentity(),
      intake: current.value.intake
        ? { ...current.value.intake, generation: current.value.sequence + 1 }
        : null,
      recoveryOf: { owner: expectedOwner, blobSha: expectedLockSha },
    };
    validateLock(lock);
    this.write(
      this.lockPath,
      lock,
      expectedLockSha,
      `Claim policy recovery ${this.repository}#${this.pullRequest}`,
    );
    this.assertLock(lock);
    const check = this.startCheck();
    this.assertLock(lock);
    this.failCheck(check);
    if (current.value.check) {
      const prior = this.api.call(
        "GET",
        `repos/${this.repository}/check-runs/${positive(current.value.check.id, "prior check ID")}`,
      );
      assert(
        prior.app?.id === this.expectedAppId &&
          prior.name === CHECK_NAME &&
          prior.head_sha === current.value.check.headSha,
        "Prior check identity mismatch",
      );
      this.assertLock(lock);
      this.failCheck(prior);
    }
    const unchanged = this.assertLock(lock);
    this.write(
      this.lockPath,
      {
        ...lock,
        owner: null,
        recoveredAt: this.now().toISOString(),
        recoveryCheckId: check.id,
      },
      unchanged.sha,
      `Recover stopped policy operation ${this.repository}#${this.pullRequest}`,
    );
    return {
      recovered: true,
      accepted: false,
      checkId: check.id,
      instruction:
        "Reevaluate current evidence; recovery does not approve a merge.",
    };
  }
  decide(snapshot) {
    if (unresolvedIntake(snapshot.lock))
      return blockedDecision(snapshot.intake);
    return evaluate({
      policy: snapshot.policy,
      context: snapshot.context,
      ledger: snapshot.ledger,
      now: this.now(),
    });
  }
  verifyFresh(snapshot, lock) {
    this.assertLock(lock);
    const current = this.snapshot({
      allowMissingLedger: snapshot.ledgerSha === null,
      includeProducers: snapshot.producersSha !== undefined,
    });
    assert(
      same(current.context, snapshot.context) &&
        current.policySha === snapshot.policySha &&
        current.ledgerSha === snapshot.ledgerSha &&
        current.producersSha === snapshot.producersSha,
      "State changed during evaluation; stale publication refused",
    );
  }
  startCheck() {
    positive(this.expectedAppId, "expected App ID for publication");
    const pr = this.api.call(
      "GET",
      `repos/${this.repository}/pulls/${this.pullRequest}`,
    );
    assert(
      pr?.number === this.pullRequest &&
        pr.base?.repo?.full_name === this.repository &&
        SHA.test(pr.head?.sha),
      "Invalid publication PR identity",
    );
    const check = this.api.call("POST", `repos/${this.repository}/check-runs`, {
      name: CHECK_NAME,
      head_sha: pr.head.sha,
      status: "in_progress",
      output: {
        title: "Checking review acceptance",
        summary: "Required review and finding evidence is being evaluated.",
      },
    });
    if (
      check?.app?.id !== this.expectedAppId ||
      check.head_sha !== pr.head.sha ||
      check.name !== CHECK_NAME
    ) {
      const error = new Error(
        "Unexpected check publisher or identity; bind protection to the dedicated App",
      );
      error.retainLock = true;
      throw error;
    }
    return check;
  }
  failCheck(check) {
    return this.api.call(
      "PATCH",
      `repos/${this.repository}/check-runs/${check.id}`,
      {
        status: "completed",
        conclusion: "failure",
        output: {
          title: "Acceptance evidence unavailable",
          summary:
            "Evaluation failed. Reconcile the control state or API failure; no successful acceptance was issued.",
        },
      },
    );
  }
  publish(snapshot, lock, startedCheck) {
    this.verifyFresh(snapshot, lock);
    assert(
      startedCheck?.head_sha === snapshot.context.headSha &&
        startedCheck.app?.id === this.expectedAppId,
      "PR moved after check started; publication refused",
    );
    // Freshness checks may take long enough for a risk acceptance to expire.
    // Reevaluate with the current clock after the final remote reads.
    const result = this.decide(snapshot);
    const body = {
      status: "completed",
      conclusion: result.decision === "pass" ? "success" : "failure",
      external_id: `${this.repository}#${this.pullRequest}:${lock.sequence}:${snapshot.context.policyDigest}:${snapshot.ledger.revision}`,
      output: {
        title:
          result.decision === "pass"
            ? "Required reviews and findings accepted"
            : "Merge acceptance is blocked",
        summary: JSON.stringify(result, null, 2),
      },
    };
    assert(
      body.output.summary.length <= 60_000,
      "Decision summary exceeds check limit",
    );
    const check = this.api.call(
      "PATCH",
      `repos/${this.repository}/check-runs/${startedCheck.id}`,
      body,
    );
    assert(
      check?.app?.id === this.expectedAppId,
      "Unexpected check publisher; bind protection to the dedicated App before relying on enforcement",
    );
    assert(
      check.head_sha === snapshot.context.headSha && check.name === CHECK_NAME,
      "Check publication identity mismatch",
    );
    return {
      result,
      check: {
        id: check.id,
        url: check.html_url,
        appId: check.app.id,
        conclusion: check.conclusion,
      },
    };
  }
  evaluate({ publish = false } = {}) {
    if (!publish)
      return {
        result: this.decide(this.snapshot({ allowMissingLedger: true })),
        enforcementPublished: false,
      };
    positive(this.expectedAppId, "expected App ID for publication");
    const lock = this.lock();
    let startedCheck;
    try {
      startedCheck = this.startCheck();
      this.noteCheck(lock, startedCheck);
      const snapshot = this.snapshot({ allowMissingLedger: true });
      const { result, check } = this.publish(snapshot, lock, startedCheck);
      this.unlock(lock);
      return { result, check, enforcementPublished: true };
    } catch (error) {
      if (startedCheck) {
        try {
          this.failCheck(startedCheck);
          if (!error.uncertainWrite) this.unlock(lock);
        } catch {
          throw new Error(
            `${error.message}; publication lock retained for explicit reconciliation`,
          );
        }
        if (error.uncertainWrite)
          throw new Error(
            `${error.message}; publication lock retained for explicit reconciliation`,
          );
      } else {
        // Unknown create outcome or wrong publisher: require explicit recovery.
        throw new Error(
          `${error.message}; publication lock retained for explicit reconciliation`,
        );
      }
      throw error;
    }
  }
  record({ event, publish = false }) {
    assert(
      event && typeof event === "object" && !Array.isArray(event),
      "record requires an event object",
    );
    if (publish)
      positive(this.expectedAppId, "expected App ID for publication");
    const lock = this.lock();
    let startedCheck;
    try {
      let actorId;
      if (publish) {
        startedCheck = this.startCheck();
        this.noteCheck(lock, startedCheck);
        assert(
          /^[a-z0-9-]+$/.test(startedCheck.app.slug),
          "Invalid publisher slug",
        );
        const principal = this.api.call(
          "GET",
          `users/${startedCheck.app.slug}[bot]`,
        );
        assert(
          principal?.type === "Bot" &&
            principal.login === `${startedCheck.app.slug}[bot]`,
          "Invalid authenticated App principal",
        );
        actorId = principal.id;
      } else {
        actorId = this.api.call("GET", "user")?.id;
      }
      positive(actorId, "authenticated event actor");
      const snapshot = this.snapshot({ allowMissingLedger: true });
      const transition = appendEvent({
        ledger: snapshot.ledger,
        event,
        policy: snapshot.policy,
        context: snapshot.context,
        actorId,
      });
      this.verifyFresh(snapshot, lock);
      if (transition.changed) {
        this.write(
          this.ledgerPath,
          transition.ledger,
          snapshot.ledgerSha,
          `Record policy event ${event.id}`,
        );
      }
      const current = this.snapshot();
      let result;
      let check;
      if (publish) {
        ({ result, check } = this.publish(current, lock, startedCheck));
      } else result = this.decide(current);
      this.unlock(lock);
      return {
        changed: transition.changed,
        result,
        check,
        enforcementPublished: publish,
      };
    } catch (error) {
      if (startedCheck) {
        try {
          this.failCheck(startedCheck);
        } catch {
          throw new Error(
            `${error.message}; operation lock retained for explicit reconciliation`,
          );
        }
      }
      const retainLock = error.uncertainWrite || error.retainLock;
      if (!retainLock) this.unlock(lock);
      throw new Error(
        `${error.message}${retainLock ? "; operation lock retained for explicit reconciliation" : ""}`,
      );
    }
  }
  updateIntake(lock, patch, message) {
    const current = this.assertLock(lock);
    validateLock(current.value);
    assert(
      current.value.schemaVersion === 2 && current.value.intake,
      "No intake hold is active",
    );
    const nextHold = { ...current.value.intake, ...patch };
    if (patch.phase !== undefined)
      assertIntakeTransition(current.value.intake.phase, patch.phase);
    validateIntakeHold(nextHold, current.value.sequence);
    const next = { ...current.value, intake: nextHold };
    this.write(
      this.lockPath,
      next,
      current.sha,
      message ?? `Advance review intake ${this.repository}#${this.pullRequest}`,
    );
    Object.assign(lock, next);
    return next;
  }
  intakeBinding(snapshot, producer) {
    const binding = {
      repository: snapshot.context.repository,
      pullRequest: snapshot.context.pullRequest,
      headSha: snapshot.context.headSha,
      baseSha: snapshot.context.baseSha,
      authorId: snapshot.context.authorId,
      policyDigest: snapshot.context.policyDigest,
      producersSha: snapshot.producersSha,
      producerRepositoryId: producer.repositoryId,
      workflowId: producer.workflowId,
      workflowRevision: producer.workflowRevision,
      lane: producer.lane,
      publisherActorId: producer.publisherActorId,
    };
    validateBinding(binding);
    return binding;
  }
  // Trusted library entry point only: the adapters authenticate the producer;
  // producer authority comes from protected control state, never caller JSON.
  // Persist one complete receipt without creating or changing any GitHub check.
  async recordReviewIntake(input) {
    assert(
      input &&
        [Object.prototype, null].includes(Object.getPrototypeOf(input)) &&
        Reflect.ownKeys(input).length === 2 &&
        Reflect.ownKeys(input).every((key) =>
          ["readers", "request"].includes(key),
        ) &&
        Object.values(Object.getOwnPropertyDescriptors(input)).every(
          (descriptor) =>
            descriptor.enumerable && Object.hasOwn(descriptor, "value"),
        ),
      "Review batch requires only a request and trusted readers",
    );
    const lock = this.lock({ intakeSelector: input.request });
    let writeAttempted = false;
    let writeAcknowledged = false;
    let writeConfirmed = false;
    try {
      const snapshot = this.snapshot({
        allowMissingLedger: true,
        includeProducers: true,
      });
      const producer = snapshot.producers.find(
        (candidate) => candidate.id === input.request.producerId,
      );
      assert(producer, "Review producer selector is not configured");
      this.updateIntake(
        lock,
        {
          binding: this.intakeBinding(snapshot, producer),
          ledgerBefore: {
            sha: snapshot.ledgerSha,
            revision: snapshot.ledger.revision,
          },
        },
        `Bind review intake ${this.repository}#${this.pullRequest}`,
      );
      const candidate = await prepareReviewIntake({
        request: input.request,
        readers: input.readers,
        producers: snapshot.producers,
        policy: snapshot.policy,
        context: snapshot.context,
        ledger: snapshot.ledger,
      });
      this.verifyFresh(snapshot, lock);
      this.assertLock(lock);
      let expectedLedgerSha = snapshot.ledgerSha;
      const ledgerBytesSha256 = createHash("sha256")
        .update(`${JSON.stringify(candidate.ledger, null, 2)}\n`)
        .digest("hex");
      this.updateIntake(
        lock,
        {
          phase: "ledger_pending",
          candidate: {
            receiptId: candidate.receiptId,
            artifactSha256: candidate.artifactSha256,
            ledgerBytesSha256,
            ledgerRevision: candidate.ledger.revision,
          },
        },
        `Prepare review receipt ${candidate.receiptId}`,
      );
      if (candidate.changed) {
        // There is exactly one durable transition for all findings and the
        // terminal review. Never split a receipt across single-event record().
        assert(
          Buffer.byteLength(`${JSON.stringify(candidate.ledger, null, 2)}\n`) <=
            MAX_BYTES,
          "Control document exceeds size limit",
        );
        writeAttempted = true;
        const written = this.write(
          this.ledgerPath,
          candidate.ledger,
          snapshot.ledgerSha,
          `Record complete policy receipt ${candidate.receiptId}`,
        );
        writeAcknowledged = true;
        expectedLedgerSha = written?.content?.sha;
        assert(
          SHA.test(expectedLedgerSha),
          "Invalid review batch write receipt",
        );
      }
      this.updateIntake(
        lock,
        { phase: "receipt_committed" },
        `Commit review receipt ${candidate.receiptId}`,
      );
      const current = this.snapshot({ includeProducers: true });
      this.assertLock(lock);
      assert(
        current.ledgerSha === expectedLedgerSha &&
          same(current.ledger, candidate.ledger),
        "Review batch readback does not match the complete candidate",
      );
      writeConfirmed = true;
      assert(
        same(current.context, snapshot.context) &&
          current.policySha === snapshot.policySha &&
          current.producersSha === snapshot.producersSha,
        "State changed after review intake; no current receipt confirmation issued",
      );
      this.updateIntake(
        lock,
        { phase: "completed" },
        `Complete review intake ${candidate.receiptId}`,
      );
      this.unlock(lock);
      return {
        receiptId: candidate.receiptId,
        artifactSha256: candidate.artifactSha256,
        changed: candidate.changed,
        ledgerRevision: current.ledger.revision,
        ledgerSha: current.ledgerSha,
        enforcementPublished: false,
      };
    } catch (error) {
      // A definite HTTP rejection cannot have committed the ledger. An absent
      // acknowledgement or failed readback might have: keep the lock for an
      // explicit reconciliation rather than silently replaying the batch.
      const rejectedWrite =
        !writeAcknowledged &&
        Number.isInteger(error.status) &&
        error.status >= 400 &&
        error.status < 500;
      const retainLock =
        error.uncertainWrite ||
        error.retainLock ||
        (writeAttempted && !writeConfirmed && !rejectedWrite);
      // Once the receipt is marked completed, a later unlock failure cannot
      // be represented as a failed intake: completed -> failed is invalid and
      // would misstate a durable commit. Retain the exact lock for recovery.
      if (lock.intake?.phase === "completed") {
        const failure = new Error(
          `${error.message}; operation lock retained for explicit reconciliation`,
        );
        failure.retainLock = true;
        throw failure;
      }
      if (retainLock) {
        const failure = new Error(
          `${error.message}; operation lock retained for explicit reconciliation`,
        );
        failure.retainLock = true;
        throw failure;
      }
      try {
        this.updateIntake(
          lock,
          {
            phase: "failed",
            failureCode: rejectedWrite
              ? "LEDGER_WRITE_REJECTED"
              : "VALIDATION_FAILED",
          },
          `Fail review intake ${this.repository}#${this.pullRequest}`,
        );
        this.unlock(lock);
      } catch {
        const failure = new Error(
          "Review batch failed; operation lock retained for explicit reconciliation",
        );
        failure.retainLock = true;
        throw failure;
      }
      throw error;
    }
  }
}

export function parseArgs(args) {
  const command = args.shift();
  assert(
    ["evaluate", "record", "snapshot", "recover", "inspect-lock"].includes(
      command,
    ),
    "Command must be evaluate, record, snapshot, inspect-lock, or recover",
  );
  const values = { command };
  const names = new Set([
    "repo",
    "pr",
    "control-repo",
    "expected-app-id",
    "event",
    "expected-owner",
    "expected-lock-sha",
  ]);
  while (args.length) {
    const flag = args.shift();
    if (flag === "--publish") {
      assert(values.publish === undefined, "Duplicate --publish");
      values.publish = true;
      continue;
    }
    assert(
      flag?.startsWith("--") && names.has(flag.slice(2)),
      "Unknown argument",
    );
    const key = flag.slice(2);
    assert(
      values[key] === undefined && args.length > 0 && !args[0].startsWith("--"),
      "Missing or duplicate argument",
    );
    values[key] = args.shift();
  }
  return values;
}

export function main(args = process.argv.slice(2)) {
  const options = parseArgs(args);
  const controller = new PolicyController({
    api: new GitHubAPI(),
    repository: options.repo,
    pullRequest: Number(options.pr),
    controlRepository: options["control-repo"],
    expectedAppId:
      options["expected-app-id"] === undefined
        ? undefined
        : Number(options["expected-app-id"]),
  });
  let response;
  if (options.command === "recover") {
    response = controller.recover({
      expectedOwner: options["expected-owner"],
      expectedLockSha: options["expected-lock-sha"],
    });
  } else if (options.command === "inspect-lock") {
    const lock = controller.document(controller.lockPath, "main", true);
    response = lock ? { lock: lock.value, blobSha: lock.sha } : { lock: null };
  } else if (options.command === "snapshot") {
    assert(!options.publish, "snapshot cannot publish");
    response = controller.snapshot({ allowMissingLedger: true });
  } else if (options.command === "record") {
    const event = options.event
      ? parseDocument(readFileSync(options.event))
      : undefined;
    assert(event, "record requires an event file from the authenticated actor");
    response = controller.record({ event, publish: options.publish });
  } else {
    assert(!options.event, "evaluate does not accept event inputs");
    response = controller.evaluate({ publish: options.publish });
  }
  process.stdout.write(`${JSON.stringify(response, null, 2)}\n`);
  if (response.result && response.result.decision !== "pass")
    process.exitCode = 1;
}

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(process.argv[1]).href
) {
  try {
    main();
  } catch (error) {
    process.stderr.write(`merge-policy: ${error.message}\n`);
    process.exitCode = 2;
  }
}
