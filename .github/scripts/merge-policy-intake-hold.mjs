// Durable state for trusted review intake. This module has no GitHub or I/O
// dependencies; callers persist the returned value with their existing CAS.

import { randomUUID } from "node:crypto";

export const INTAKE_PHASES = Object.freeze([
  "validating",
  "ledger_pending",
  "receipt_committed",
  "publication_pending",
  "failed",
  "completed",
]);

const SHA = /^[a-f0-9]{40}$/;
const DIGEST = /^[a-f0-9]{64}$/;
const ID = /^[a-z][a-z0-9_-]{0,63}$/;
const REPOSITORY = /^[A-Za-z0-9][A-Za-z0-9-]{0,38}\/\w[\w.-]{0,99}$/;
const EXACT_SELECTOR = ["producerId", "runId", "runAttempt", "artifactId"];
const EXACT_BINDING = [
  "repository",
  "pullRequest",
  "headSha",
  "baseSha",
  "authorId",
  "policyDigest",
  "producersSha",
  "producerRepositoryId",
  "workflowId",
  "workflowRevision",
  "lane",
  "publisherActorId",
];
const EXACT_LEDGER_BEFORE = ["sha", "revision"];
const EXACT_CANDIDATE = [
  "receiptId",
  "artifactSha256",
  "ledgerBytesSha256",
  "ledgerRevision",
];
const EXACT_PUBLICATION = [
  "checkId",
  "headSha",
  "appId",
  "externalId",
  "desiredConclusion",
  "decisionSha256",
];
const EXACT_HOLD = [
  "generation",
  "operationId",
  "phase",
  "selector",
  "binding",
  "ledgerBefore",
  "candidate",
  "publication",
  "failureCode",
];

function fail(message) {
  throw new Error(`Invalid intake hold: ${message}`);
}
function object(value, fields, name) {
  if (!value || typeof value !== "object" || Array.isArray(value))
    fail(`${name} must be an object`);
  const keys = Reflect.ownKeys(value);
  if (
    keys.length !== fields.length ||
    keys.some((key) => typeof key !== "string" || !fields.includes(key))
  )
    fail(`${name} has unexpected fields`);
  for (const key of keys) {
    const descriptor = Object.getOwnPropertyDescriptor(value, key);
    if (!descriptor.enumerable || !Object.hasOwn(descriptor, "value"))
      fail(`${name} contains an accessor`);
  }
}
function text(value, maximum, name) {
  if (
    typeof value !== "string" ||
    value.length === 0 ||
    value.length > maximum ||
    value.includes("\0")
  )
    fail(`${name} is invalid`);
}
function positive(value, name) {
  if (!Number.isSafeInteger(value) || value <= 0) fail(`${name} is invalid`);
}
function nullableSha(value, name) {
  if (value !== null && (typeof value !== "string" || !SHA.test(value)))
    fail(`${name} is invalid`);
}
function sha(value, name) {
  if (typeof value !== "string" || !SHA.test(value)) fail(`${name} is invalid`);
}
function digest(value, name) {
  if (typeof value !== "string" || !DIGEST.test(value))
    fail(`${name} is invalid`);
}

export function validateSelector(selector) {
  object(selector, EXACT_SELECTOR, "selector");
  text(selector.producerId, 64, "producerId");
  if (!ID.test(selector.producerId)) fail("producerId is invalid");
  positive(selector.runId, "runId");
  positive(selector.runAttempt, "runAttempt");
  positive(selector.artifactId, "artifactId");
  return selector;
}

export function validateBinding(binding) {
  if (binding === null) return null;
  object(binding, EXACT_BINDING, "binding");
  if (!REPOSITORY.test(binding.repository)) fail("repository is invalid");
  positive(binding.pullRequest, "pullRequest");
  sha(binding.headSha, "headSha");
  sha(binding.baseSha, "baseSha");
  positive(binding.authorId, "authorId");
  digest(binding.policyDigest, "policyDigest");
  sha(binding.producersSha, "producersSha");
  positive(binding.producerRepositoryId, "producerRepositoryId");
  positive(binding.workflowId, "workflowId");
  sha(binding.workflowRevision, "workflowRevision");
  if (typeof binding.lane !== "string" || !ID.test(binding.lane))
    fail("lane is invalid");
  positive(binding.publisherActorId, "publisherActorId");
  return binding;
}

export function validateIntakeHold(hold, expectedGeneration) {
  if (hold === null) return null;
  object(hold, EXACT_HOLD, "hold");
  if (
    !Number.isSafeInteger(hold.generation) ||
    hold.generation <= 0 ||
    (expectedGeneration !== undefined && hold.generation !== expectedGeneration)
  )
    fail("generation is invalid");
  if (
    typeof hold.operationId !== "string" ||
    !/^[0-9a-f-]{36}$/.test(hold.operationId)
  )
    fail("operationId is invalid");
  if (!INTAKE_PHASES.includes(hold.phase)) fail("phase is invalid");
  validateSelector(hold.selector);
  validateBinding(hold.binding);
  if (hold.ledgerBefore !== null) {
    object(hold.ledgerBefore, EXACT_LEDGER_BEFORE, "ledgerBefore");
    nullableSha(hold.ledgerBefore.sha, "ledgerBefore.sha");
    if (
      !Number.isSafeInteger(hold.ledgerBefore.revision) ||
      hold.ledgerBefore.revision < 0
    )
      fail("ledgerBefore.revision is invalid");
  }
  if (hold.candidate !== null) {
    object(hold.candidate, EXACT_CANDIDATE, "candidate");
    text(hold.candidate.receiptId, 256, "candidate.receiptId");
    digest(hold.candidate.artifactSha256, "candidate.artifactSha256");
    digest(hold.candidate.ledgerBytesSha256, "candidate.ledgerBytesSha256");
    if (
      !Number.isSafeInteger(hold.candidate.ledgerRevision) ||
      hold.candidate.ledgerRevision < 0
    )
      fail("candidate.ledgerRevision is invalid");
  }
  if (hold.publication !== null) {
    object(hold.publication, EXACT_PUBLICATION, "publication");
    positive(hold.publication.checkId, "publication.checkId");
    sha(hold.publication.headSha, "publication.headSha");
    positive(hold.publication.appId, "publication.appId");
    text(hold.publication.externalId, 512, "publication.externalId");
    if (
      !["success", "failure", "neutral"].includes(
        hold.publication.desiredConclusion,
      )
    )
      fail("publication.desiredConclusion is invalid");
    digest(hold.publication.decisionSha256, "publication.decisionSha256");
  }
  if (hold.failureCode !== null) {
    if (!/^[A-Z][A-Z0-9_]{0,63}$/.test(hold.failureCode))
      fail("failureCode is invalid");
  }
  if (
    [
      "ledger_pending",
      "receipt_committed",
      "publication_pending",
      "completed",
    ].includes(hold.phase)
  ) {
    if (hold.binding === null || hold.ledgerBefore === null)
      fail("bound phase requires binding and ledgerBefore");
  }
  if (
    ["receipt_committed", "publication_pending", "completed"].includes(
      hold.phase,
    )
  ) {
    if (hold.candidate === null) fail("committed phase requires candidate");
  }
  if (hold.phase === "failed" && hold.failureCode === null)
    fail("failed hold requires failureCode");
  if (hold.phase !== "failed" && hold.failureCode !== null)
    fail("failureCode only belongs to failed hold");
  return hold;
}

export function unresolvedIntake(lock) {
  return Boolean(lock?.intake && lock.intake.phase !== "completed");
}

export function assertIntakeTransition(from, to) {
  const allowed = {
    validating: new Set(["validating", "ledger_pending", "failed"]),
    ledger_pending: new Set(["ledger_pending", "receipt_committed", "failed"]),
    receipt_committed: new Set([
      "receipt_committed",
      "publication_pending",
      "completed",
      "failed",
    ]),
    publication_pending: new Set([
      "publication_pending",
      "completed",
      "failed",
    ]),
    failed: new Set(["failed"]),
    completed: new Set(["completed"]),
  };
  if (!allowed[from]?.has(to))
    fail(`invalid phase transition ${from} -> ${to}`);
}

export function blockedDecision(hold) {
  return {
    decision: "hold",
    code: "REVIEW_INTAKE_UNRESOLVED",
    reason: `Trusted review intake is unresolved (${hold?.phase ?? "unknown"})`,
  };
}

export function createIntakeHold(selector, generation) {
  validateSelector(selector);
  if (!Number.isSafeInteger(generation) || generation <= 0)
    fail("generation is invalid");
  return {
    generation,
    operationId: randomUUID(),
    phase: "validating",
    selector: { ...selector },
    binding: null,
    ledgerBefore: null,
    candidate: null,
    publication: null,
    failureCode: null,
  };
}
