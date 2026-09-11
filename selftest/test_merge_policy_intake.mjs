import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";
import {
  INTAKE_LIMITS,
  prepareReviewIntake,
} from "../.github/scripts/merge-policy-intake.mjs";
import { evaluate } from "../.github/scripts/merge-policy-core.mjs";
import { emptyLedger } from "../.github/scripts/merge-policy-state.mjs";

const clone = (value) => structuredClone(value);
const sha256 = (bytes) => createHash("sha256").update(bytes).digest("hex");
function fixture() {
  const context = {
    repository: "example/application",
    pullRequest: 17,
    headSha: "a".repeat(40),
    baseSha: "b".repeat(40),
    policyDigest: "c".repeat(64),
    authorId: 100,
    draft: false,
    state: "OPEN",
    headAssociationCount: 1,
  };
  const producer = {
    id: "independent",
    repository: "example/review-control",
    repositoryId: 91,
    workflowId: 123,
    workflowPath: ".github/workflows/review.yml",
    workflowRevision: "d".repeat(40),
    lane: "independent",
    publisherActorId: 200,
    artifactName: "review-receipt.json",
  };
  const policy = {
    schemaVersion: 1,
    repository: context.repository,
    requiredReviews: ["independent"],
    reviewActors: { independent: [200] },
    dispositionActors: [300],
    findingActors: [200],
    allowNotApplicable: {},
    blockingPriorityMax: 2,
  };
  const request = {
    producerId: "independent",
    runId: 456,
    runAttempt: 1,
    artifactId: 789,
  };
  const producerRun = {
    repository: producer.repository,
    repositoryId: producer.repositoryId,
    workflowId: producer.workflowId,
    workflowPath: producer.workflowPath,
    workflowRevision: producer.workflowRevision,
    runId: request.runId,
    runAttempt: request.runAttempt,
  };
  const target = Object.fromEntries(
    ["repository", "pullRequest", "headSha", "baseSha", "policyDigest"].map(
      (key) => [key, context[key]],
    ),
  );
  const receipt = {
    schemaVersion: 1,
    producer: clone(producerRun),
    target: clone(target),
    lane: "independent",
    complete: true,
    outcome: "findings",
    findingCount: 1,
    summary: "One material finding delivered.",
    findings: [
      {
        key: "unchecked-hold",
        title: "Writer hold is unverified",
        priority: 1,
        path: "deploy/ReleasePrep.sh",
        reason: "The declaration has no current hold evidence.",
      },
    ],
  };
  const state = {
    receipt,
    bytes: null,
    metadata: {
      schemaVersion: 1,
      producer: clone(producerRun),
      target: clone(target),
      status: "completed",
      conclusion: "success",
      latestRunAttempt: 1,
      artifact: {
        id: 789,
        name: producer.artifactName,
        byteLength: 0,
        sha256: "",
      },
    },
    calls: [],
  };
  function seal(bytes = Buffer.from(JSON.stringify(state.receipt))) {
    state.bytes = bytes;
    state.metadata.artifact.byteLength = bytes.length;
    state.metadata.artifact.sha256 = sha256(bytes);
  }
  seal();
  const input = {
    request,
    producers: [producer],
    policy,
    context,
    ledger: emptyLedger(context.repository, context.pullRequest),
    readers: {
      metadata: async (selector, options) => {
        state.calls.push({ kind: "metadata", selector, options });
        return clone(state.metadata);
      },
      artifact: async (selector, options) => {
        state.calls.push({ kind: "artifact", selector, options });
        return Buffer.from(state.bytes);
      },
    },
  };
  return { input, state, seal };
}
const fails = (input, code) =>
  assert.rejects(prepareReviewIntake(input), (error) => {
    assert.equal(error.code, code);
    assert.equal(error.message, `Review intake: ${code}`);
    return true;
  });
function decision(input, ledger) {
  return evaluate({
    policy: input.policy,
    context: input.context,
    ledger,
    now: "2026-09-11T01:00:00Z",
  });
}

test("complete finding receipt yields one atomic candidate, preserves text and leaves caller state unchanged", async () => {
  const { input, state } = fixture();
  const before = clone(input.ledger);
  const result = await prepareReviewIntake(input);
  assert.equal(result.changed, true);
  assert.equal(result.enforcementPublished, false);
  assert.equal(result.publisherActorId, 200);
  assert.equal(result.ledger.revision, 2);
  assert.deepEqual(
    result.events.map((event) => event.type),
    ["finding", "review"],
  );
  assert.equal(result.events[0].path, "deploy/ReleasePrep.sh");
  assert.equal(result.events[0].title, "Writer hold is unverified");
  assert.deepEqual(result.events[1].findingIds, [result.events[0].findingId]);
  assert.equal(decision(input, result.ledger).decision, "hold");
  assert.deepEqual(input.ledger, before);
  assert.deepEqual(
    state.calls.map((call) => call.kind),
    ["metadata", "artifact", "metadata"],
  );
  for (const call of state.calls) {
    assert.equal(Object.isFrozen(call.selector), true);
    assert.equal(
      call.options.maximumBytes,
      call.kind === "artifact"
        ? INTAKE_LIMITS.artifactBytes
        : INTAKE_LIMITS.metadataBytes,
    );
    assert.equal(call.options.deadlineMs, 2000);
    assert.equal(call.options.signal.aborted, true);
  }
});

test("an explicit complete clean receipt can satisfy the engine without publishing", async () => {
  const { input, state, seal } = fixture();
  Object.assign(state.receipt, {
    outcome: "clean",
    findings: [],
    findingCount: 0,
  });
  seal();
  const result = await prepareReviewIntake(input);
  assert.equal(result.events.length, 1);
  assert.equal(decision(input, result.ledger).decision, "pass");
  assert.equal(result.enforcementPublished, false);
});

test("identical delivery is idempotent and a later clean run does not close an earlier finding", async () => {
  const { input, state, seal } = fixture();
  const first = await prepareReviewIntake(input);
  input.ledger = first.ledger;
  const replay = await prepareReviewIntake(input);
  assert.equal(replay.changed, false);
  assert.deepEqual(replay.ledger, first.ledger);
  input.request.runId += 1;
  state.metadata.producer.runId += 1;
  state.receipt.producer.runId += 1;
  Object.assign(state.receipt, {
    outcome: "clean",
    findings: [],
    findingCount: 0,
  });
  seal();
  const later = await prepareReviewIntake(input);
  assert.equal(decision(input, later.ledger).openFindings.length, 1);
  assert.equal(decision(input, later.ledger).decision, "hold");
});

for (const field of [
  "repository",
  "repositoryId",
  "workflowId",
  "workflowPath",
  "workflowRevision",
  "runId",
  "runAttempt",
]) {
  test(`metadata cannot forge producer ${field}`, async () => {
    const { input, state } = fixture();
    const value = state.metadata.producer[field];
    state.metadata.producer[field] =
      typeof value === "number" ? value + 1 : `${value}x`;
    await fails(input, "binding_mismatch");
    assert.equal(state.calls.length, 1);
  });
}
for (const field of [
  "repository",
  "pullRequest",
  "headSha",
  "baseSha",
  "policyDigest",
]) {
  test(`metadata cannot substitute target ${field}`, async () => {
    const { input, state } = fixture();
    const value = state.metadata.target[field];
    state.metadata.target[field] =
      typeof value === "number" ? value + 1 : `${value}x`;
    await fails(input, "binding_mismatch");
  });
}
test("payload provenance, lane and actor claims cannot establish authority", async () => {
  for (const change of [
    (receipt) => {
      receipt.producer.workflowRevision = "e".repeat(40);
    },
    (receipt) => {
      receipt.target.headSha = "e".repeat(40);
    },
    (receipt) => {
      receipt.lane = "other";
    },
    (receipt) => {
      receipt.actorId = 200;
    },
  ]) {
    const { input, state, seal } = fixture();
    change(state.receipt);
    seal();
    await assert.rejects(prepareReviewIntake(input));
  }
});
test("unknown, ambiguous, unauthorized and self-review producers fail before reads", async () => {
  for (const change of [
    (input) => {
      input.request.producerId = "unknown";
    },
    (input) => {
      input.producers.push({ ...input.producers[0], id: "alias" });
    },
    (input) => {
      input.producers[0].publisherActorId = 999;
    },
    (input) => {
      input.context.authorId = 200;
    },
    (input) => {
      input.producers[0].lane = "other";
    },
  ]) {
    const { input, state } = fixture();
    change(input);
    await assert.rejects(prepareReviewIntake(input));
    assert.equal(state.calls.length, 0);
  }
});
test("failed, skipped, running and superseded producer attempts cannot produce acceptance", async () => {
  for (const change of [
    { conclusion: "failure" },
    { conclusion: "skipped" },
    { status: "in_progress" },
    { latestRunAttempt: 2 },
  ]) {
    const { input, state } = fixture();
    Object.assign(state.metadata, change);
    await fails(input, "producer_incomplete");
  }
});
test("missing, contradictory, skipped and prose-only outcomes never become clean", async () => {
  for (const change of [
    { complete: false },
    { outcome: "clean" },
    { findingCount: 2 },
    { outcome: "not_applicable" },
    { outcome: "Looks good to me" },
    { outcome: "findings", findings: [], findingCount: 0 },
  ]) {
    const { input, state, seal } = fixture();
    Object.assign(state.receipt, change);
    seal();
    await assert.rejects(prepareReviewIntake(input));
    assert.equal(input.ledger.revision, 0);
  }
  const { input, state, seal } = fixture();
  delete state.receipt.findings;
  seal();
  await assert.rejects(prepareReviewIntake(input));
});
test("the complete batch rejects malformed, duplicate or invalid later findings without partial state", async () => {
  for (const change of [
    (finding) => {
      finding.priority = 4;
    },
    (finding) => {
      finding.path = "../outside";
    },
    (finding) => {
      finding.type = "disposition";
    },
    (finding) => {
      finding.key = "unchecked-hold";
    },
  ]) {
    const { input, state, seal } = fixture();
    const second = { ...state.receipt.findings[0], key: "second" };
    change(second);
    state.receipt.findings.push(second);
    state.receipt.findingCount = 2;
    seal();
    await assert.rejects(prepareReviewIntake(input));
    assert.deepEqual(input.ledger.events, []);
  }
});
test("wrong artifact identity, name and digest are refused", async () => {
  for (const change of [
    (state) => {
      state.metadata.artifact.id += 1;
    },
    (state) => {
      state.metadata.artifact.name = "untrusted.json";
    },
    (state) => {
      state.bytes[0] ^= 1;
    },
    (state) => {
      state.bytes = Buffer.concat([state.bytes, Buffer.from(" ")]);
    },
  ]) {
    const { input, state } = fixture();
    change(state);
    await assert.rejects(prepareReviewIntake(input));
  }
});
test("invalid UTF-8, duplicate keys and noncanonical JSON are refused even with a matching digest", async () => {
  for (const bytesFor of [
    () => Buffer.from([0xff]),
    (receipt) =>
      Buffer.from(
        JSON.stringify(receipt).replace(
          '"schemaVersion":1',
          '"schemaVersion":1,"schemaVersion":1',
        ),
      ),
    (receipt) => Buffer.from(JSON.stringify(receipt, null, 2)),
    (receipt) => Buffer.from(`${JSON.stringify(receipt)}\n`),
  ]) {
    const { input, state, seal } = fixture();
    seal(bytesFor(state.receipt));
    await assert.rejects(prepareReviewIntake(input));
  }
});
test("string, shared-memory and subclass artifact values are refused", async () => {
  class CustomBytes extends Uint8Array {}
  for (const bytes of [
    "{}",
    new Uint8Array(new SharedArrayBuffer(2)),
    new CustomBytes(2),
  ]) {
    const { input } = fixture();
    input.readers.artifact = async () => bytes;
    await fails(input, "artifact_not_bytes");
  }
});
test("plain Uint8Array receipt bytes are supported", async () => {
  const { input, state } = fixture();
  input.readers.artifact = async () => new Uint8Array(state.bytes);
  assert.equal((await prepareReviewIntake(input)).events.length, 2);
});
test("byte, metadata, finding and producer bounds refuse oversized inputs", async () => {
  {
    const { input, state } = fixture();
    state.metadata.artifact.byteLength = INTAKE_LIMITS.artifactBytes + 1;
    await fails(input, "artifact_limit");
  }
  {
    const { input, state } = fixture();
    state.metadata.extra = [
      "x".repeat(8000),
      "x".repeat(8000),
      "x".repeat(8000),
    ];
    await fails(input, "metadata_limit");
  }
  {
    const { input, state, seal } = fixture();
    state.receipt.findings = Array.from({ length: 65 }, (_, index) => ({
      ...state.receipt.findings[0],
      key: `finding-${index}`,
    }));
    state.receipt.findingCount = 65;
    seal();
    await fails(input, "finding_limit");
  }
  {
    const { input } = fixture();
    input.producers = Array(17).fill(input.producers[0]);
    await fails(input, "producer_limit");
  }
});
test("mutable caller configuration, context and ledger are snapshotted before asynchronous reads", async () => {
  const { input, state } = fixture();
  const metadataReader = input.readers.metadata;
  input.readers.metadata = async (...args) => {
    input.context.headSha = "f".repeat(40);
    input.producers[0].publisherActorId = 999;
    input.policy.reviewActors.independent = [999];
    input.ledger.events.push({ invalid: true });
    input.readers.artifact = async () => {
      throw new Error("changed reader");
    };
    return metadataReader(...args);
  };
  const result = await prepareReviewIntake(input);
  assert.equal(result.publisherActorId, 200);
  assert.equal(result.events[0].headSha, state.receipt.target.headSha);
  assert.equal(result.ledger.revision, 2);
});
test("metadata is copied before artifact reader can mutate it and revalidated after download", async () => {
  const { input, state, seal } = fixture();
  input.readers.metadata = async () => state.metadata;
  input.readers.artifact = async () => {
    state.receipt.summary = "one material finding delivered.";
    seal();
    return state.bytes;
  };
  await fails(input, "artifact_digest_mismatch");
  const other = fixture();
  let reads = 0;
  other.input.readers.metadata = async () => {
    const metadata = clone(other.state.metadata);
    if (++reads === 2) metadata.latestRunAttempt = 2;
    return metadata;
  };
  await fails(other.input, "producer_incomplete");
});
test("changed same-run receipt fails despite new artifact id or caller producer alias", async () => {
  for (const alias of [false, true]) {
    const { input, state, seal } = fixture();
    input.ledger = (await prepareReviewIntake(input)).ledger;
    state.receipt.summary = "Changed summary.";
    input.request.artifactId += 1;
    state.metadata.artifact.id += 1;
    if (alias) {
      input.request.producerId = "alias";
      input.producers[0].id = "alias";
    }
    seal();
    await fails(input, "invalid_event_batch");
  }
});
test("partial receipt history is refused instead of silently repaired", async () => {
  const { input } = fixture();
  const result = await prepareReviewIntake(input);
  input.ledger = {
    ...result.ledger,
    revision: 1,
    events: [result.ledger.events[0]],
  };
  await fails(input, "partial_receipt_history");
});
test("changed finding order or terminal clean replacement cannot evade prior receipt identity", async () => {
  const { input, state, seal } = fixture();
  input.ledger = (await prepareReviewIntake(input)).ledger;
  Object.assign(state.receipt, {
    outcome: "clean",
    findings: [],
    findingCount: 0,
  });
  seal();
  await fails(input, "partial_receipt_history");
});
test("identical replay remains idempotent at the ledger capacity while new events are refused", async () => {
  const { input } = fixture();
  const result = await prepareReviewIntake(input);
  const filler = Array.from(
    { length: INTAKE_LIMITS.ledgerEvents - 2 },
    (_, index) => ({
      ...result.ledger.events[1],
      id: `historical:${index}`,
      outcome: "clean",
      findingIds: [],
    }),
  );
  input.ledger = {
    ...result.ledger,
    events: [...filler, ...result.ledger.events],
    revision: INTAKE_LIMITS.ledgerEvents,
  };
  assert.equal((await prepareReviewIntake(input)).changed, false);
  const other = fixture();
  other.input.ledger = input.ledger;
  other.input.request.runId += 1;
  other.state.metadata.producer.runId += 1;
  other.state.receipt.producer.runId += 1;
  other.seal();
  await fails(other.input, "ledger_limit");
});
test("accessors, sparse arrays, hidden properties and cycles fail without invoking getters", async () => {
  let invoked = false;
  for (const change of [
    (input) => {
      Object.defineProperty(input.request, "runId", {
        enumerable: true,
        get() {
          invoked = true;
          return 456;
        },
      });
    },
    (input) => {
      input.producers.length = 2;
    },
    (input) => {
      Object.defineProperty(input.context, "hidden", { value: true });
    },
    (input) => {
      input.request.loop = input.request;
    },
  ]) {
    const { input, state } = fixture();
    change(input);
    await assert.rejects(prepareReviewIntake(input));
    assert.equal(state.calls.length, 0);
  }
  assert.equal(invoked, false);
});
test("adapter failures suppress response text and credentials", async () => {
  for (const kind of ["metadata", "artifact"]) {
    const { input } = fixture();
    input.readers[kind] = async () => {
      throw new Error("token=DO_NOT_PRINT response body");
    };
    await fails(input, `${kind}_read_failed`);
  }
});
test("a stalled reader times out and receives cancellation without returning a candidate", async () => {
  const { input } = fixture();
  let signal;
  input.readers.metadata = async (_selector, options) => {
    signal = options.signal;
    return new Promise(() => {});
  };
  await fails(input, "adapter_timeout");
  assert.equal(signal.aborted, true);
});
