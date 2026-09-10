import assert from "node:assert/strict";
import test from "node:test";
import {
  appendEvent,
  emptyLedger,
} from "../.github/scripts/merge-policy-state.mjs";
import { evaluate } from "../.github/scripts/merge-policy-core.mjs";

const policy = {
  schemaVersion: 1,
  repository: "policy-staging/example",
  requiredReviews: ["claude"],
  reviewActors: { claude: [20] },
  dispositionActors: [30],
  findingActors: [40],
  allowNotApplicable: { claude: ["docs_only"] },
  blockingPriorityMax: 2,
};
const context = {
  repository: policy.repository,
  pullRequest: 7,
  headSha: "a".repeat(40),
  baseSha: "b".repeat(40),
  policyDigest: "c".repeat(64),
  authorId: 10,
  draft: false,
  state: "OPEN",
  headAssociationCount: 1,
};
const scope = ({ headSha, baseSha, policyDigest }) => ({
  headSha,
  baseSha,
  policyDigest,
});
function finding(id = "finding-event", extra = {}) {
  return {
    id,
    type: "finding",
    ...scope(context),
    evidenceUrl: "https://github.com/policy-staging/example/pull/7",
    reason: "Synthetic regression demonstrates a material defect.",
    findingId: "defect-1",
    title: "Synthetic defect",
    priority: 1,
    path: "src/example.mjs",
    ...extra,
  };
}
function review(id = "review-event", extra = {}) {
  return {
    id,
    type: "review",
    ...scope(context),
    evidenceUrl: "https://github.com/policy-staging/example/pull/7",
    reason: "Independent synthetic review completed.",
    lane: "claude",
    outcome: "clean",
    findingIds: [],
    ...extra,
  };
}
function disposition(id = "disposition-event", extra = {}) {
  return {
    id,
    type: "disposition",
    ...scope(context),
    evidenceUrl: "https://github.com/policy-staging/example/pull/7",
    reason: "Independent synthetic verification completed.",
    findingId: "defect-1",
    action: "fixed",
    ...extra,
  };
}
const fresh = () => emptyLedger(context.repository, context.pullRequest);
const append = (ledger, event, actorId = 40, extra = {}) =>
  appendEvent({ ledger, event, actorId, policy, context, ...extra });
const decision = (ledger, extra = {}) =>
  evaluate({ policy, context, ledger, now: "2026-09-10T12:00:00Z", ...extra })
    .decision;
function freeze(value) {
  if (value && typeof value === "object") {
    Object.freeze(value);
    Object.values(value).forEach(freeze);
  }
  return value;
}

test("empty ledger has strict identity and independent event arrays", () => {
  assert.deepEqual(fresh(), {
    schemaVersion: 1,
    repository: context.repository,
    pullRequest: 7,
    revision: 0,
    events: [],
  });
  assert.notEqual(fresh().events, fresh().events);
  for (const repository of [
    "../escape",
    "owner/../repo",
    "https://github.com/owner/repo",
    "owner/repo/extra",
    "",
  ]) {
    assert.throws(() => emptyLedger(repository, 7));
  }
  for (const pullRequest of [0, -1, 1.5, "7", Number.MAX_SAFE_INTEGER + 1]) {
    assert.throws(() => emptyLedger(context.repository, pullRequest));
  }
});

test("append authenticates actor, increments revision and never mutates its inputs", () => {
  const ledger = freeze(fresh());
  const event = freeze(finding());
  const inputPolicy = freeze(structuredClone(policy));
  const inputContext = freeze(structuredClone(context));
  const result = append(ledger, event, 40, {
    policy: inputPolicy,
    context: inputContext,
  });
  assert.equal(result.changed, true);
  assert.equal(result.ledger.revision, 1);
  assert.deepEqual(result.ledger.events[0], { ...event, actorId: 40 });
  assert.equal(ledger.revision, 0);
  assert.equal(Object.hasOwn(event, "actorId"), false);
});

test("actor claims cannot override authenticated identity", () => {
  assert.throws(() => append(fresh(), finding("f", { actorId: 30 }), 40));
  for (const actorId of [0, -1, "40", null, 1.5, Number.MAX_SAFE_INTEGER + 1]) {
    assert.throws(() => append(fresh(), finding(), actorId));
  }
  assert.throws(() => append(fresh(), finding(), 999));
  assert.throws(() => append(fresh(), review(), 40));
});

test("identical event ID is idempotent with or without an explicit matching actor", () => {
  const event = finding();
  const first = append(fresh(), event);
  for (const request of [
    event,
    { ...event, actorId: 40 },
    Object.fromEntries(Object.entries(event).reverse()),
  ]) {
    const replay = append(first.ledger, request);
    assert.equal(replay.changed, false);
    assert.deepEqual(replay.ledger, first.ledger);
    assert.notEqual(replay.ledger, first.ledger);
  }
});

test("changed duplicate ID refuses every alteration and actor impersonation", () => {
  const ledger = append(fresh(), finding()).ledger;
  for (const extra of [
    { reason: "changed" },
    { priority: 3 },
    { id: "finding-event", findingId: "other" },
    { actorId: 20 },
    { headSha: "d".repeat(40) },
  ]) {
    assert.throws(() => append(ledger, finding("finding-event", extra)));
  }
  assert.throws(() => append(ledger, finding(), 20));
});

test("exact replay remains idempotent across pushes but fresh stale event is refused", () => {
  const ledger = append(fresh(), finding()).ledger;
  const current = { ...context, headSha: "d".repeat(40) };
  const replay = append(ledger, finding(), 40, { context: current });
  assert.equal(replay.changed, false);
  assert.throws(() => append(ledger, review(), 20, { context: current }));
  assert.throws(() => append(ledger, disposition(), 30, { context: current }));
  assert.equal(
    append(ledger, review("new-review", scope(current)), 20, {
      context: current,
    }).changed,
    true,
  );
});

test("corrupt ledger envelopes never pass, including on duplicate replay", () => {
  const valid = append(fresh(), finding()).ledger;
  const corruptions = [
    { ...valid, schemaVersion: 2 },
    { ...valid, revision: 0 },
    { ...valid, revision: 1.5 },
    { ...valid, repository: "elsewhere/project" },
    { ...valid, pullRequest: 8 },
    { ...valid, ignored: true },
    { ...valid, events: {} },
    { ...valid, revision: 2, events: [...valid.events, valid.events[0]] },
    { ...valid, events: [{ ...valid.events[0], actorId: 999 }] },
    { ...valid, events: [{ ...valid.events[0], arbitrary: true }] },
    { ...valid, events: [null] },
  ];
  for (const ledger of corruptions)
    assert.throws(() => append(ledger, finding()));
});

test("history corruption before the last event cannot hide behind a valid tail", () => {
  let ledger = append(fresh(), finding()).ledger;
  ledger = append(ledger, review(), 20).ledger;
  ledger.events[0].evidenceUrl = "https://attacker.example/untrusted";
  assert.throws(() => append(ledger, review()));
});

test("policy authority revocation fails closed even for exact duplicate replays", () => {
  const ledger = append(fresh(), finding()).ledger;
  const changedPolicy = { ...policy, findingActors: [41] };
  assert.throws(() => append(ledger, finding(), 40, { policy: changedPolicy }));
});

test("current policy, PR, base and policy digest must match new events", () => {
  assert.throws(() =>
    append(fresh(), finding(), 40, {
      policy: { ...policy, repository: "another/project" },
    }),
  );
  for (const extra of [
    { baseSha: "d".repeat(40) },
    { policyDigest: "d".repeat(64) },
  ]) {
    assert.throws(() =>
      append(fresh(), review(), 20, { context: { ...context, ...extra } }),
    );
  }
});

test("finding references must already exist and cannot redefine finding IDs", () => {
  assert.throws(() =>
    append(
      fresh(),
      review("r", { outcome: "findings", findingIds: ["unknown"] }),
      20,
    ),
  );
  assert.throws(() => append(fresh(), disposition(), 30));
  const ledger = append(fresh(), finding()).ledger;
  assert.throws(() => append(ledger, finding("second-definition")));
});

test("author cannot issue review or disposition even if allowlisted", () => {
  const authorPolicy = {
    ...policy,
    reviewActors: { claude: [10, 20] },
    dispositionActors: [10, 30],
  };
  const ledger = append(fresh(), finding()).ledger;
  assert.throws(() => append(ledger, review(), 10, { policy: authorPolicy }));
  assert.throws(() =>
    append(ledger, disposition(), 10, { policy: authorPolicy }),
  );
});

test("later clean review does not erase a material finding", () => {
  let ledger = append(fresh(), finding()).ledger;
  ledger = append(ledger, review(), 20).ledger;
  assert.equal(decision(ledger), "hold");
  ledger = append(ledger, disposition(), 30).ledger;
  assert.equal(decision(ledger), "pass");
});

test("unrelated push invalidates disposition but preserves finding", () => {
  let ledger = append(fresh(), finding()).ledger;
  ledger = append(ledger, review(), 20).ledger;
  ledger = append(ledger, disposition(), 30).ledger;
  const current = { ...context, headSha: "d".repeat(40) };
  ledger = append(ledger, review("new-review", scope(current)), 20, {
    context: current,
  }).ledger;
  assert.equal(decision(ledger, { context: current }), "hold");
});

test("reopened and expired risk acceptances remain blocking", () => {
  let ledger = append(fresh(), finding()).ledger;
  ledger = append(ledger, review(), 20).ledger;
  ledger = append(
    ledger,
    disposition("risk", {
      action: "accepted_risk",
      expiresAt: "2026-09-11T12:00:00Z",
    }),
    30,
  ).ledger;
  assert.equal(decision(ledger), "pass");
  assert.equal(decision(ledger, { now: "2026-09-11T12:00:00Z" }), "hold");
  ledger = append(
    ledger,
    disposition("reopen", { action: "reopen" }),
    30,
  ).ledger;
  assert.equal(decision(ledger), "hold");
});

test("invalid risk expiry and unauthorized not-applicable reason cannot be registered", () => {
  const ledger = append(fresh(), finding()).ledger;
  for (const expiresAt of [
    undefined,
    "tomorrow",
    "2026-02-30T00:00:00Z",
    "2026-09-11T12:00:00+00:00",
  ]) {
    assert.throws(() =>
      append(
        ledger,
        disposition("risk", {
          action: "accepted_risk",
          ...(expiresAt === undefined ? {} : { expiresAt }),
        }),
        30,
      ),
    );
  }
  assert.throws(() =>
    append(
      fresh(),
      review("r", {
        outcome: "not_applicable",
        notApplicableReason: "please_skip",
      }),
      20,
    ),
  );
});

test("non-JSON input cannot execute getters or mutate journal state", () => {
  let invoked = false;
  const event = finding();
  Object.defineProperty(event, "surprise", {
    enumerable: true,
    get() {
      invoked = true;
      throw new Error("executed");
    },
  });
  assert.throws(() => append(fresh(), event));
  assert.equal(invoked, false);
  const cyclic = finding();
  cyclic.self = cyclic;
  for (const request of [
    cyclic,
    { ...finding(), value: undefined },
    { ...finding(), value: NaN },
    { ...finding(), value: () => {} },
  ]) {
    assert.throws(() => append(fresh(), request));
  }
  const ledger = fresh();
  ledger.events = new Array(1);
  ledger.revision = 1;
  assert.throws(() => append(ledger, finding()));
});
