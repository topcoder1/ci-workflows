// Disconnected structured-review intake. Readers and protected configuration are
// trust inputs; this module does not authenticate GitHub or publish decisions.
import { createHash } from "node:crypto";
import { TextDecoder, types } from "node:util";
import { validateContext, validatePolicy } from "./merge-policy-core.mjs";
import { appendEvent } from "./merge-policy-state.mjs";

export const INTAKE_LIMITS = Object.freeze({
  artifactBytes: 65536,
  metadataBytes: 16384,
  findings: 64,
  producers: 16,
  ledgerEvents: 4096,
  readDeadlineMs: 2000,
});
const SHA = /^[a-f0-9]{40}$/;
const DIGEST = /^[a-f0-9]{64}$/;
const ID = /^[a-z][a-z0-9_-]{0,63}$/;
const REPOSITORY = /^[A-Za-z0-9][A-Za-z0-9-]{0,38}\/[A-Za-z0-9_.-]{1,100}$/;
const PRODUCER_FIELDS = [
  "repository",
  "repositoryId",
  "workflowId",
  "workflowPath",
  "workflowRevision",
];
const RUN_FIELDS = [...PRODUCER_FIELDS, "runId", "runAttempt"];
const TARGET_FIELDS = [
  "repository",
  "pullRequest",
  "headSha",
  "baseSha",
  "policyDigest",
];

class IntakeError extends Error {
  constructor(code) {
    super(`Review intake: ${code}`);
    this.name = "IntakeError";
    this.code = code;
  }
}
function requireThat(condition, code = "invalid_input") {
  if (!condition) throw new IntakeError(code);
}
function shape(value, names) {
  requireThat(
    value !== null &&
      typeof value === "object" &&
      !types.isProxy(value) &&
      !Array.isArray(value),
  );
  requireThat([Object.prototype, null].includes(Object.getPrototypeOf(value)));
  const own = Reflect.ownKeys(value);
  requireThat(
    own.length === names.length && own.every((name) => names.includes(name)),
  );
  for (const name of own) {
    const descriptor = Object.getOwnPropertyDescriptor(value, name);
    requireThat(descriptor.enumerable && Object.hasOwn(descriptor, "value"));
  }
}
// Inspect descriptors before reading values. Bound even protected inputs, and do
// reject proxies before reflection; do not invoke accessors, toJSON, iterators,
// or user-defined prototype methods.
function copyData(value) {
  const ancestors = new Set();
  let nodes = 0;
  let characters = 0;
  function copy(item, depth = 0) {
    requireThat(++nodes <= 100000 && depth <= 16, "input_limit");
    if (typeof item === "string") {
      characters += item.length;
      requireThat(
        item.length <= 8192 && characters <= 8 * 1024 * 1024,
        "input_limit",
      );
      return item;
    }
    if (item === null || typeof item === "boolean") return item;
    if (typeof item === "number") {
      requireThat(Number.isFinite(item));
      return item;
    }
    requireThat(
      item &&
        typeof item === "object" &&
        !types.isProxy(item) &&
        !ancestors.has(item),
    );
    const array = Array.isArray(item);
    requireThat(
      array
        ? Object.getPrototypeOf(item) === Array.prototype
        : [Object.prototype, null].includes(Object.getPrototypeOf(item)),
    );
    const descriptors = Object.getOwnPropertyDescriptors(item);
    const own = Reflect.ownKeys(descriptors);
    const length = array ? descriptors.length.value : 0;
    requireThat(
      array
        ? length <= INTAKE_LIMITS.ledgerEvents && own.length === length + 1
        : own.length <= 128,
      "input_limit",
    );
    const entries = [];
    ancestors.add(item);
    for (const name of own) {
      if (array && name === "length") continue;
      const descriptor = descriptors[name];
      requireThat(
        typeof name === "string" &&
          descriptor.enumerable &&
          Object.hasOwn(descriptor, "value"),
      );
      if (array) requireThat(name === String(entries.length));
      entries.push([name, copy(descriptor.value, depth + 1)]);
    }
    ancestors.delete(item);
    return array
      ? entries.map(([, child]) => child)
      : Object.fromEntries(entries);
  }
  return copy(value);
}
function positive(value) {
  requireThat(Number.isSafeInteger(value) && value > 0);
}
function matches(value, pattern) {
  requireThat(typeof value === "string" && pattern.test(value));
}
function text(value, maximum) {
  requireThat(
    typeof value === "string" &&
      value.trim() &&
      value.length <= maximum &&
      !value.includes("\0"),
  );
}
function repository(value) {
  matches(value, REPOSITORY);
  requireThat(![".", ".."].includes(value.split("/")[1]));
}
function canonical(value) {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${canonical(value[key])}`)
      .join(",")}}`;
  }
  return JSON.stringify(value);
}
function digest(value) {
  return createHash("sha256").update(value).digest("hex");
}
function equal(left, right, code = "binding_mismatch") {
  requireThat(canonical(left) === canonical(right), code);
}
function select(value, fields) {
  return Object.fromEntries(fields.map((key) => [key, value[key]]));
}
function validateProducer(producer) {
  shape(producer, [
    "id",
    ...PRODUCER_FIELDS,
    "lane",
    "publisherActorId",
    "artifactName",
  ]);
  matches(producer.id, ID);
  repository(producer.repository);
  positive(producer.repositoryId);
  positive(producer.workflowId);
  matches(
    producer.workflowPath,
    /^\.github\/workflows\/[A-Za-z0-9_-]+\.ya?ml$/,
  );
  matches(producer.workflowRevision, SHA);
  matches(producer.lane, ID);
  positive(producer.publisherActorId);
  matches(producer.artifactName, /^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\.json$/);
}
function freezeData(value) {
  if (value && typeof value === "object") {
    for (const child of Object.values(value)) freezeData(child);
    Object.freeze(value);
  }
  return value;
}

// Validate protected repository-wide authority, without authenticating a caller
// or applying the selected PR's author/reviewer separation rule.
export function validateProducerConfiguration(input) {
  try {
    shape(input, ["configuration", "policy"]);
    const { configuration, policy } = copyData(input);
    validatePolicy(policy);
    shape(configuration, ["schemaVersion", "repository", "producers"]);
    requireThat(
      configuration.schemaVersion === 1 &&
        configuration.repository === policy.repository,
    );
    const { producers } = configuration;
    requireThat(
      Array.isArray(producers) && producers.length <= INTAKE_LIMITS.producers,
      "producer_limit",
    );
    const ids = new Set();
    const identities = new Set();
    for (const producer of producers) {
      validateProducer(producer);
      const identity = canonical([
        producer.repositoryId,
        producer.workflowId,
        producer.workflowRevision,
      ]);
      requireThat(
        !ids.has(producer.id) && !identities.has(identity),
        "ambiguous_producer",
      );
      ids.add(producer.id);
      identities.add(identity);
      requireThat(
        Object.hasOwn(policy.reviewActors, producer.lane) &&
          policy.reviewActors[producer.lane].includes(
            producer.publisherActorId,
          ),
        "unauthorized_producer",
      );
    }
    // Empty configuration is a valid suspension. Intake still needs a selected
    // producer; no historical authority is recovered by emptying this array.
    return freezeData(configuration);
  } catch (error) {
    if (error instanceof IntakeError) throw error;
    throw new IntakeError("invalid_input");
  }
}
function validateMetadata(metadata, producer, request, target) {
  requireThat(
    Buffer.byteLength(canonical(metadata)) <= INTAKE_LIMITS.metadataBytes,
    "metadata_limit",
  );
  shape(metadata, [
    "schemaVersion",
    "producer",
    "target",
    "status",
    "conclusion",
    "latestRunAttempt",
    "artifact",
  ]);
  requireThat(metadata.schemaVersion === 1);
  shape(metadata.producer, RUN_FIELDS);
  equal(metadata.producer, {
    ...select(producer, PRODUCER_FIELDS),
    runId: request.runId,
    runAttempt: request.runAttempt,
  });
  shape(metadata.target, TARGET_FIELDS);
  equal(metadata.target, target);
  requireThat(
    metadata.status === "completed" &&
      metadata.conclusion === "success" &&
      metadata.latestRunAttempt === request.runAttempt,
    "producer_incomplete",
  );
  shape(metadata.artifact, ["id", "name", "byteLength", "sha256"]);
  requireThat(
    metadata.artifact.id === request.artifactId &&
      metadata.artifact.name === producer.artifactName,
    "artifact_mismatch",
  );
  positive(metadata.artifact.byteLength);
  requireThat(
    metadata.artifact.byteLength <= INTAKE_LIMITS.artifactBytes,
    "artifact_limit",
  );
  matches(metadata.artifact.sha256, DIGEST);
}
async function readBounded(reader, selector, kind) {
  const controller = new AbortController();
  let timer;
  try {
    const timeout = new Promise((_, reject) => {
      timer = setTimeout(() => {
        controller.abort();
        reject(new IntakeError("adapter_timeout"));
      }, INTAKE_LIMITS.readDeadlineMs);
    });
    return await Promise.race([
      Promise.resolve()
        .then(() =>
          reader(
            Object.freeze({ ...selector }),
            Object.freeze({
              signal: controller.signal,
              deadlineMs: INTAKE_LIMITS.readDeadlineMs,
              maximumBytes:
                kind === "artifact"
                  ? INTAKE_LIMITS.artifactBytes
                  : INTAKE_LIMITS.metadataBytes,
            }),
          ),
        )
        .catch(() => {
          throw new IntakeError(`${kind}_read_failed`);
        }),
      timeout,
    ]);
  } finally {
    clearTimeout(timer);
    controller.abort();
  }
}

/** Return a fully validated candidate ledger; never persist or publish it. */
export async function prepareReviewIntake(input) {
  try {
    shape(input, [
      "request",
      "producers",
      "policy",
      "context",
      "ledger",
      "readers",
    ]);
    shape(input.readers, ["metadata", "artifact"]);
    const readMetadata = input.readers.metadata;
    const readArtifact = input.readers.artifact;
    requireThat(
      typeof readMetadata === "function" && typeof readArtifact === "function",
    );
    const {
      request,
      producers: configuredProducers,
      policy,
      context,
      ledger,
    } = copyData(
      select(input, ["request", "producers", "policy", "context", "ledger"]),
    );
    shape(request, ["producerId", "runId", "runAttempt", "artifactId"]);
    matches(request.producerId, ID);
    for (const key of ["runId", "runAttempt", "artifactId"])
      positive(request[key]);
    validatePolicy(policy);
    validateContext(context);
    requireThat(context.repository === policy.repository);
    const { producers } = validateProducerConfiguration({
      configuration: {
        schemaVersion: 1,
        repository: context.repository,
        producers: configuredProducers,
      },
      policy,
    });
    requireThat(producers.length > 0, "producer_limit");
    const producer = producers.find((entry) => entry.id === request.producerId);
    requireThat(producer, "unknown_producer");
    requireThat(
      producer.publisherActorId !== context.authorId,
      "unauthorized_producer",
    );
    const target = select(context, TARGET_FIELDS);
    const selector = {
      repository: producer.repository,
      runId: request.runId,
      runAttempt: request.runAttempt,
      artifactId: request.artifactId,
    };
    const metadata = copyData(
      await readBounded(readMetadata, selector, "metadata"),
    );
    validateMetadata(metadata, producer, request, target);
    const delivered = await readBounded(readArtifact, selector, "artifact");
    requireThat(
      (Buffer.isBuffer(delivered) &&
        Object.getPrototypeOf(delivered) === Buffer.prototype) ||
        (delivered instanceof Uint8Array &&
          Object.getPrototypeOf(delivered) === Uint8Array.prototype),
      "artifact_not_bytes",
    );
    requireThat(
      !(delivered.buffer instanceof SharedArrayBuffer),
      "artifact_not_bytes",
    );
    requireThat(
      delivered.byteLength === metadata.artifact.byteLength &&
        delivered.byteLength <= INTAKE_LIMITS.artifactBytes,
      "artifact_limit",
    );
    const bytes = Buffer.from(delivered);
    requireThat(
      digest(bytes) === metadata.artifact.sha256,
      "artifact_digest_mismatch",
    );
    let receipt;
    try {
      receipt = JSON.parse(
        new TextDecoder("utf-8", { fatal: true }).decode(bytes),
      );
      // A deliberately strict wire format also rejects duplicate JSON keys.
      requireThat(
        Buffer.from(JSON.stringify(receipt)).equals(bytes),
        "noncanonical_receipt",
      );
    } catch (error) {
      if (error instanceof IntakeError) throw error;
      throw new IntakeError("invalid_receipt_json");
    }
    receipt = copyData(receipt);
    shape(receipt, [
      "schemaVersion",
      "producer",
      "target",
      "lane",
      "complete",
      "outcome",
      "findingCount",
      "summary",
      "findings",
    ]);
    requireThat(
      receipt.schemaVersion === 1 && receipt.complete === true,
      "receipt_incomplete",
    );
    shape(receipt.producer, RUN_FIELDS);
    equal(receipt.producer, metadata.producer);
    shape(receipt.target, TARGET_FIELDS);
    equal(receipt.target, target);
    requireThat(receipt.lane === producer.lane, "lane_mismatch");
    text(receipt.summary, 3000);
    requireThat(
      Array.isArray(receipt.findings) &&
        receipt.findings.length <= INTAKE_LIMITS.findings,
      "finding_limit",
    );
    requireThat(
      Number.isSafeInteger(receipt.findingCount) &&
        receipt.findingCount === receipt.findings.length,
      "incomplete_findings",
    );
    requireThat(
      (receipt.outcome === "clean" && receipt.findingCount === 0) ||
        (receipt.outcome === "findings" && receipt.findingCount > 0),
      "contradictory_outcome",
    );
    const findingKeys = new Set();
    for (const finding of receipt.findings) {
      shape(finding, ["key", "title", "priority", "path", "reason"]);
      matches(finding.key, ID);
      requireThat(!findingKeys.has(finding.key), "duplicate_finding");
      findingKeys.add(finding.key);
      text(finding.title, 256);
      text(finding.reason, 3000);
      // Core validates priority and repository-relative path in the batch.
    }
    const refreshed = copyData(
      await readBounded(readMetadata, selector, "metadata"),
    );
    validateMetadata(refreshed, producer, request, target);
    equal(refreshed, metadata, "metadata_changed");

    // Deliberately exclude artifact ID, digest, revision and caller alias: an
    // altered delivery of the same producer run/attempt must collide and fail.
    const receiptId = digest(
      canonical([
        producer.repositoryId,
        producer.workflowId,
        request.runId,
        request.runAttempt,
      ]),
    );
    const prefix = `intake:${receiptId}:`;
    const evidenceUrl = `https://github.com/${producer.repository}/actions/runs/${request.runId}/attempts/${request.runAttempt}`;
    const binding = select(context, ["headSha", "baseSha", "policyDigest"]);
    const events = receipt.findings.map((finding, index) => ({
      id: `${prefix}finding:${index}`,
      type: "finding",
      ...binding,
      evidenceUrl,
      reason: `${finding.key}: ${finding.reason}`,
      findingId: `${prefix}finding:${index}`,
      title: finding.title,
      priority: finding.priority,
      path: finding.path,
    }));
    const commitment = digest(canonical({ metadata, producer }));
    events.push({
      id: `${prefix}review`,
      type: "review",
      ...binding,
      evidenceUrl,
      reason: `Receipt commitment sha256:${commitment}; ${receipt.summary}`,
      lane: producer.lane,
      outcome: receipt.outcome,
      findingIds: events.map((event) => event.findingId),
    });
    // A consumer must commit the complete candidate in one conditional write.
    // Do not silently repair or finish a partially persisted receipt.
    requireThat(
      Array.isArray(ledger.events) &&
        ledger.events.length <= INTAKE_LIMITS.ledgerEvents,
      "ledger_limit",
    );
    const previous = ledger.events.filter(
      (event) => typeof event?.id === "string" && event.id.startsWith(prefix),
    );
    requireThat(
      previous.length === 0 ||
        (previous.length === events.length &&
          previous.every((event, index) => event.id === events[index].id)),
      "partial_receipt_history",
    );
    requireThat(
      previous.length > 0 ||
        ledger.events.length + events.length <= INTAKE_LIMITS.ledgerEvents,
      "ledger_limit",
    );
    let candidate = ledger;
    let changed = false;
    try {
      for (const event of events) {
        const transition = appendEvent({
          ledger: candidate,
          event,
          policy,
          context,
          actorId: producer.publisherActorId,
        });
        candidate = transition.ledger;
        changed ||= transition.changed;
      }
    } catch {
      throw new IntakeError("invalid_event_batch");
    }
    return {
      schemaVersion: 1,
      receiptId,
      artifactSha256: metadata.artifact.sha256,
      publisherActorId: producer.publisherActorId,
      events: events.map((event) => ({
        ...event,
        actorId: producer.publisherActorId,
      })),
      ledger: candidate,
      changed,
      enforcementPublished: false,
    };
  } catch (error) {
    if (error instanceof IntakeError) throw error;
    throw new IntakeError("invalid_input");
  }
}
