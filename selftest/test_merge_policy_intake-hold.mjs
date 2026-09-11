import assert from "node:assert/strict";
import test from "node:test";
import {
  assertIntakeTransition,
  blockedDecision,
  createIntakeHold,
  unresolvedIntake,
  validateIntakeHold,
} from "../.github/scripts/merge-policy-intake-hold.mjs";

const selector = {
  producerId: "claude",
  runId: 11,
  runAttempt: 1,
  artifactId: 22,
};
const binding = {
  repository: "owner/repo",
  pullRequest: 7,
  headSha: "a".repeat(40),
  baseSha: "b".repeat(40),
  authorId: 10,
  policyDigest: "c".repeat(64),
  producersSha: "d".repeat(40),
  producerRepositoryId: 91,
  workflowId: 123,
  workflowRevision: "e".repeat(40),
  lane: "claude",
  publisherActorId: 20,
};

test("initial intake hold is generation-bound and blocks ordinary decisions", () => {
  const hold = createIntakeHold(selector, 4);
  validateIntakeHold(hold, 4);
  assert.equal(unresolvedIntake({ intake: hold }), true);
  assert.deepEqual(blockedDecision(hold), {
    decision: "hold",
    code: "REVIEW_INTAKE_UNRESOLVED",
    reason: "Trusted review intake is unresolved (validating)",
  });
});

test("hold phases preserve the binding and candidate contract", () => {
  const hold = createIntakeHold(selector, 4);
  hold.binding = binding;
  hold.ledgerBefore = { sha: null, revision: 0 };
  hold.phase = "ledger_pending";
  hold.candidate = {
    receiptId: "owner/repo:123:11:1",
    artifactSha256: "f".repeat(64),
    ledgerBytesSha256: "1".repeat(64),
    ledgerRevision: 1,
  };
  validateIntakeHold(hold, 4);
  hold.phase = "receipt_committed";
  validateIntakeHold(hold, 4);
  hold.phase = "completed";
  validateIntakeHold(hold, 4);
  assert.equal(unresolvedIntake({ intake: hold }), false);
});

test("failed holds remain unresolved and cannot be silently downgraded", () => {
  const hold = createIntakeHold(selector, 2);
  hold.phase = "failed";
  hold.failureCode = "ADAPTER_TIMEOUT";
  validateIntakeHold(hold, 2);
  assert.equal(unresolvedIntake({ intake: hold }), true);
  assert.throws(() => assertIntakeTransition("failed", "validating"));
  assert.throws(() => validateIntakeHold({ ...hold, generation: 3 }, 2));
  assert.throws(() => validateIntakeHold({ ...hold, failureCode: null }, 2));
});

test("malformed and publication identities fail closed", () => {
  const hold = createIntakeHold(selector, 1);
  assert.throws(() => validateIntakeHold({ ...hold, phase: "unknown" }, 1));
  hold.binding = binding;
  hold.ledgerBefore = { sha: null, revision: 0 };
  hold.phase = "ledger_pending";
  hold.publication = {
    checkId: 3,
    headSha: "not-a-sha",
    appId: 7001,
    externalId: "owner/repo#7:1",
    desiredConclusion: "success",
    decisionSha256: "0".repeat(64),
  };
  assert.throws(() => validateIntakeHold(hold, 1));
});
