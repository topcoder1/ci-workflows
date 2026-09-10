import { isDeepStrictEqual } from "node:util";
import {
  validateContext,
  validateEvent,
  validatePolicy,
} from "./merge-policy-core.mjs";

// Keep this module free of persistence and credentials. The caller authenticates
// the event actor and commits the returned ledger with a conditional write.
function copyJson(value, ancestors = new Set()) {
  if (
    value === null ||
    typeof value === "string" ||
    typeof value === "boolean"
  ) {
    return value;
  }
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value !== "object" || ancestors.has(value)) {
    throw new Error("Journal input must be acyclic JSON data");
  }
  const prototype = Object.getPrototypeOf(value);
  if (
    !Array.isArray(value) &&
    prototype !== Object.prototype &&
    prototype !== null
  ) {
    throw new Error("Journal input must contain only plain JSON objects");
  }
  const keys = Reflect.ownKeys(value);
  for (const key of keys) {
    if (Array.isArray(value) && key === "length") continue;
    const descriptor = Object.getOwnPropertyDescriptor(value, key);
    if (
      typeof key !== "string" ||
      !descriptor.enumerable ||
      !("value" in descriptor)
    ) {
      throw new Error(
        "Journal input must not contain accessors or hidden properties",
      );
    }
  }
  ancestors.add(value);
  let result;
  if (Array.isArray(value)) {
    if (
      keys.length !== value.length + 1 ||
      keys.some((key, index) => index < value.length && key !== String(index))
    ) {
      throw new Error("Journal input must contain dense JSON arrays");
    }
    result = value.map((item) => copyJson(item, ancestors));
  } else {
    result = Object.fromEntries(
      Object.entries(value).map(([key, item]) => [
        key,
        copyJson(item, ancestors),
      ]),
    );
  }
  ancestors.delete(value);
  return result;
}

function checkLedgerEnvelope(ledger, context) {
  if (!ledger || Array.isArray(ledger) || typeof ledger !== "object") {
    throw new Error("Ledger must be an object");
  }
  const expectedKeys = [
    "schemaVersion",
    "repository",
    "pullRequest",
    "revision",
    "events",
  ].sort();
  if (!isDeepStrictEqual(Object.keys(ledger).sort(), expectedKeys)) {
    throw new Error("Ledger contains missing or unknown keys");
  }
  if (
    ledger.schemaVersion !== 1 ||
    ledger.repository !== context.repository ||
    ledger.pullRequest !== context.pullRequest
  ) {
    throw new Error(
      "Ledger schema or repository/pull request identity does not match",
    );
  }
  if (
    !Number.isSafeInteger(ledger.revision) ||
    ledger.revision < 0 ||
    !Array.isArray(ledger.events) ||
    ledger.revision !== ledger.events.length
  ) {
    throw new Error("Ledger revision must equal its event count");
  }
  const ids = new Set();
  for (const event of ledger.events) {
    if (
      !event ||
      typeof event !== "object" ||
      Array.isArray(event) ||
      ids.has(event.id)
    ) {
      throw new Error("Ledger contains an invalid event or duplicate event id");
    }
    ids.add(event.id);
  }
}

function validateHistory(ledger, policy, context) {
  if (!ledger.events.length) return;
  const last = ledger.events.at(-1);
  // validateEvent validates the whole prior history without requiring historical
  // bindings to equal today's head. Reconstruct only this historical scope; keep
  // the current author and actor policy so authority changes fail closed.
  validateEvent(
    last,
    policy,
    {
      ...context,
      headSha: last.headSha,
      baseSha: last.baseSha,
      policyDigest: last.policyDigest,
    },
    ledger.events.slice(0, -1),
  );
}

export function emptyLedger(repository, pullRequest) {
  // Use the shared identity validator without duplicating repository syntax.
  // These placeholders are never persisted or used as review evidence.
  validateContext({
    repository,
    pullRequest,
    headSha: "0".repeat(40),
    baseSha: "0".repeat(40),
    policyDigest: "0".repeat(64),
    authorId: 1,
    draft: false,
    state: "OPEN",
    headAssociationCount: 1,
  });
  return { schemaVersion: 1, repository, pullRequest, revision: 0, events: [] };
}

export function appendEvent({ ledger, event, policy, context, actorId }) {
  if (!Number.isSafeInteger(actorId) || actorId <= 0) {
    throw new Error("Authenticated actorId must be a positive safe integer");
  }
  const policyCopy = copyJson(policy);
  const contextCopy = copyJson(context);
  const next = copyJson(ledger);
  const candidate = copyJson(event);
  validatePolicy(policyCopy);
  validateContext(contextCopy);
  if (policyCopy.repository !== contextCopy.repository) {
    throw new Error("Policy repository does not match current context");
  }
  checkLedgerEnvelope(next, contextCopy);
  validateHistory(next, policyCopy, contextCopy);
  if (!candidate || Array.isArray(candidate) || typeof candidate !== "object") {
    throw new Error("Event must be an object");
  }
  if (Object.hasOwn(candidate, "actorId") && candidate.actorId !== actorId) {
    throw new Error("Event actorId does not match authenticated actor");
  }
  candidate.actorId = actorId;
  const existing = next.events.find((previous) => previous.id === candidate.id);
  if (existing) {
    if (!isDeepStrictEqual(existing, candidate)) {
      throw new Error("Event id already exists with different content");
    }
    // A replay is not a new event. It stays idempotent after a subsequent push,
    // but only after the entire ledger and authenticated actor were validated.
    return { ledger: next, changed: false };
  }
  validateEvent(candidate, policyCopy, contextCopy, next.events);
  next.events.push(candidate);
  next.revision = next.events.length;
  return { ledger: next, changed: true };
}
