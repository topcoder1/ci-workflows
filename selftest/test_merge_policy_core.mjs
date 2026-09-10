import assert from "node:assert/strict";
import test from "node:test";
import {
  evaluate,
  validateContext,
  validateEvent,
  validatePolicy,
} from "../.github/scripts/merge-policy-core.mjs";

const NOW = "2026-09-10T12:00:00Z";
const HEAD = "a".repeat(40);
const BASE = "b".repeat(40);
const DIGEST = "c".repeat(64);

function policy(overrides = {}) {
  return {
    schemaVersion: 1,
    repository: "example/merge-policy-staging",
    requiredReviews: ["claude", "codex"],
    reviewActors: { claude: [20], codex: [30] },
    dispositionActors: [40],
    findingActors: [50],
    allowNotApplicable: { codex: ["non_risk_path"] },
    blockingPriorityMax: 2,
    ...overrides,
  };
}
function context(overrides = {}) {
  return {
    repository: "example/merge-policy-staging",
    pullRequest: 17,
    headSha: HEAD,
    baseSha: BASE,
    policyDigest: DIGEST,
    authorId: 10,
    draft: false,
    state: "OPEN",
    headAssociationCount: 1,
    ...overrides,
  };
}
function common(id, overrides = {}) {
  return {
    id,
    actorId: 50,
    headSha: HEAD,
    baseSha: BASE,
    policyDigest: DIGEST,
    evidenceUrl:
      "https://github.com/example/merge-policy-staging/pull/17#discussion_r1",
    reason: "Synthetic staging evidence.",
    ...overrides,
  };
}
function finding(id = "F1", overrides = {}) {
  return {
    ...common(`finding-${id}`),
    type: "finding",
    findingId: id,
    title: "Required prerequisite is not verified",
    priority: 1,
    path: "scripts/release.sh",
    ...overrides,
  };
}
function review(lane = "claude", overrides = {}) {
  return {
    ...common(`review-${lane}`, { actorId: lane === "claude" ? 20 : 30 }),
    type: "review",
    lane,
    outcome: "clean",
    findingIds: [],
    ...overrides,
  };
}
function disposition(overrides = {}) {
  return {
    ...common("dispose-F1", { actorId: 40 }),
    type: "disposition",
    findingId: "F1",
    action: "fixed",
    ...overrides,
  };
}
function ledger(events, overrides = {}) {
  return {
    schemaVersion: 1,
    repository: "example/merge-policy-staging",
    pullRequest: 17,
    revision: events.length,
    events,
    ...overrides,
  };
}
function run(events, overrides = {}) {
  return evaluate({
    policy: policy(),
    context: context(),
    ledger: ledger(events),
    now: NOW,
    ...overrides,
  });
}
const clean = () => [review(), review("codex")];

test("pass requires both current independent reviews and reports exact identity", () => {
  const result = run(clean());
  assert.equal(result.decision, "pass");
  assert.deepEqual(result.reasons, []);
  assert.deepEqual(result.pendingReviews, []);
  assert.deepEqual(result.identity, {
    repository: "example/merge-policy-staging",
    pullRequest: 17,
    headSha: HEAD,
    baseSha: BASE,
    policyDigest: DIGEST,
    ledgerRevision: 2,
  });
});

test("empty ledger and a missing required lane hold", () => {
  assert.deepEqual(run([]).pendingReviews, ["claude", "codex"]);
  assert.deepEqual(run([review()]).pendingReviews, ["codex"]);
});

test("latest matching review controls completion, including reviewer errors", () => {
  const events = [
    ...clean(),
    review("claude", { id: "error", outcome: "error" }),
  ];
  assert.equal(run(events).decision, "hold");
  assert.equal(run(events).reasons[0].code, "REVIEW_ERROR");
  events.push(review("claude", { id: "recovered" }));
  assert.equal(run(events).decision, "pass");
});

for (const [field, value] of [
  ["headSha", "d".repeat(40)],
  ["baseSha", "e".repeat(40)],
  ["policyDigest", "f".repeat(64)],
]) {
  test(`a changed ${field} invalidates reviews and closes no historical findings`, () => {
    const current = context({ [field]: value });
    const historical = [finding(), ...clean(), disposition()];
    assert.deepEqual(run(historical, { context: current }).pendingReviews, [
      "claude",
      "codex",
    ]);
    assert.equal(
      run(historical, { context: current }).reasons.at(-1).code,
      "DISPOSITION_STALE",
    );
    const fresh = [
      review("claude", { id: "fresh-c", [field]: value }),
      review("codex", { id: "fresh-x", [field]: value }),
    ];
    const result = run([...historical, ...fresh], { context: current });
    assert.equal(result.decision, "hold");
    assert.equal(result.openFindings[0].findingId, "F1");
    assert.deepEqual(result.pendingReviews, []);
    assert.throws(
      () => validateEvent(review(), policy(), current, []),
      /current head\/base\/policy/,
    );
  });
}

test("findings persist after unrelated pushes and clean reviews", () => {
  const newHead = "d".repeat(40);
  const events = [
    finding(),
    review("claude", { outcome: "findings", findingIds: ["F1"] }),
    review("codex"),
    review("claude", { id: "clean-later" }),
  ];
  assert.equal(run(events).decision, "hold");
  events.push(
    review("claude", { id: "new-c", headSha: newHead }),
    review("codex", { id: "new-x", headSha: newHead }),
  );
  assert.equal(
    run(events, { context: context({ headSha: newHead }) }).decision,
    "hold",
  );
});

test("P3 suggestions remain visible without blocking, P0 through P2 hold", () => {
  const result = run([finding("suggestion", { priority: 3 }), ...clean()]);
  assert.equal(result.decision, "pass");
  assert.equal(result.openFindings.length, 1);
  assert.equal(result.openFindings[0].blocking, false);
  for (const priority of [0, 1, 2])
    assert.equal(
      run([finding("blocking", { priority }), ...clean()]).decision,
      "hold",
    );
});

test("fixed and disproved require current independent disposition, and reopening wins", () => {
  for (const action of ["fixed", "disproved"]) {
    const events = [finding(), ...clean(), disposition({ action })];
    assert.equal(run(events).decision, "pass");
    events.push(disposition({ id: "reopen", action: "reopen" }));
    assert.equal(run(events).decision, "hold");
    events.push(disposition({ id: "reverified", action }));
    assert.equal(run(events).decision, "pass");
  }
});

test("historical finding may be reverified on a new head without model rerun history deletion", () => {
  const newHead = "d".repeat(40);
  const current = context({ headSha: newHead });
  const events = [
    finding(),
    ...clean(),
    disposition(),
    review("claude", { id: "fresh-c", headSha: newHead }),
    review("codex", { id: "fresh-x", headSha: newHead }),
  ];
  const fix = disposition({ id: "reverified", headSha: newHead });
  assert.equal(validateEvent(fix, policy(), current, events), fix);
  assert.equal(run([...events, fix], { context: current }).decision, "pass");
});

test("risk acceptance expires at its exact boundary and cannot survive changed binding", () => {
  const events = [
    finding(),
    ...clean(),
    disposition({ action: "accepted_risk", expiresAt: "2026-09-10T12:00:01Z" }),
  ];
  assert.equal(run(events).decision, "pass");
  const expired = run(events, { now: "2026-09-10T12:00:01.000Z" });
  assert.equal(expired.decision, "hold");
  assert.equal(expired.reasons[0].code, "RISK_ACCEPTANCE_EXPIRED");
  assert.equal(
    run(events, { now: new Date("2026-09-11T00:00:00Z") }).decision,
    "hold",
  );
  const newBase = "e".repeat(40);
  assert.equal(
    run(events, { context: context({ baseSha: newBase }) }).openFindings[0]
      .findingId,
    "F1",
  );
});

test("reopen remains open after head advances", () => {
  const newHead = "d".repeat(40);
  const events = [
    finding(),
    disposition(),
    disposition({ id: "reopen", action: "reopen" }),
    review("claude", { headSha: newHead }),
    review("codex", { headSha: newHead }),
  ];
  const result = run(events, { context: context({ headSha: newHead }) });
  assert.equal(result.decision, "hold");
  assert.equal(result.reasons[0].code, "FINDING_OPEN");
});

test("not applicable requires an explicit authorized lane reason", () => {
  const exempt = review("codex", {
    outcome: "not_applicable",
    notApplicableReason: "non_risk_path",
  });
  assert.equal(run([review(), exempt]).decision, "pass");
  for (const reason of [undefined, "anything_else"]) {
    assert.throws(() =>
      run([review(), { ...exempt, notApplicableReason: reason }]),
    );
  }
  assert.throws(
    () =>
      run([
        review("claude", {
          outcome: "not_applicable",
          notApplicableReason: "non_risk_path",
        }),
      ]),
    /not authorized/,
  );
  assert.throws(
    () => run([review("codex", { notApplicableReason: "non_risk_path" })]),
    /only applies/,
  );
});

test("findings review is complete only with preexisting records in the same binding", () => {
  const findingReview = review("claude", {
    outcome: "findings",
    findingIds: ["F1"],
  });
  const result = run([finding(), findingReview, review("codex")]);
  assert.deepEqual(result.pendingReviews, []);
  assert.equal(result.decision, "hold");
  assert.throws(() => run([findingReview, finding()]), /missing or bound/);
  assert.throws(
    () => run([finding(), { ...findingReview, headSha: "d".repeat(40) }]),
    /missing or bound/,
  );
  assert.throws(
    () => run([{ ...findingReview, findingIds: [] }]),
    /must deliver/,
  );
  assert.throws(
    () => run([finding(), { ...findingReview, outcome: "clean" }]),
    /only findings reviews/,
  );
  assert.throws(
    () => run([finding(), { ...findingReview, findingIds: ["F1", "F1"] }]),
    /duplicates/,
  );
});

test("unauthorized, wrong-lane and self reviews cannot pass, including historical events", () => {
  for (const actorId of [999, 30, 10])
    assert.throws(() => run([review("claude", { actorId })]), /not authorized/);
  const selfPolicy = policy({ reviewActors: { claude: [10], codex: [30] } });
  assert.throws(
    () => run([review("claude", { actorId: 10 })], { policy: selfPolicy }),
    /PR author/,
  );
  assert.throws(
    () =>
      run(clean(), {
        policy: policy({ reviewActors: { claude: [21], codex: [30] } }),
        context: context({ headSha: "d".repeat(40) }),
      }),
    /not authorized/,
  );
});

test("only trusted actors create findings, including configured reviewer actors", () => {
  for (const actorId of [20, 30, 50])
    assert.doesNotThrow(() =>
      validateEvent(finding("F", { actorId }), policy(), context(), []),
    );
  assert.throws(
    () => validateEvent(finding("F", { actorId: 40 }), policy(), context(), []),
    /not authorized/,
  );
});

test("author may report a finding but cannot dispose of it even when allowlisted", () => {
  const configured = policy({
    findingActors: [10],
    dispositionActors: [10, 40],
  });
  const ownFinding = finding("F1", { actorId: 10 });
  assert.doesNotThrow(() =>
    validateEvent(ownFinding, configured, context(), []),
  );
  assert.throws(
    () =>
      run([ownFinding, disposition({ actorId: 10 })], { policy: configured }),
    /PR author/,
  );
  assert.throws(
    () => run([finding(), disposition({ actorId: 50 })]),
    /not authorized/,
  );
});

test("review lane names cannot inherit actor permissions through object prototypes", () => {
  assert.throws(
    () => run([review("constructor", { actorId: 20 })]),
    /not authorized/,
  );
  assert.throws(
    () => validatePolicy(policy({ requiredReviews: ["constructor"] })),
    /no actors/,
  );
});

test("all dispositions require existing finding, evidence, reason and correct action shape", () => {
  assert.throws(() => run([disposition()]), /unknown finding/);
  for (const overrides of [
    { evidenceUrl: "" },
    { reason: " " },
    { action: "ignore" },
    { expiresAt: "2027-01-01T00:00:00Z" },
    { action: "accepted_risk" },
  ]) {
    assert.throws(() => run([finding(), disposition(overrides)]));
  }
});

test("expiry validation rejects normalized invalid dates, offsets and non-time values", () => {
  for (const expiresAt of [
    "2026-02-30T00:00:00Z",
    "2026-09-10T24:00:00Z",
    "2026-09-10T12:00:00+00:00",
    "2026-09-10",
    "infinity",
    0,
    "2026-09-10T12:00:00.1234Z",
  ]) {
    assert.throws(() =>
      run([finding(), disposition({ action: "accepted_risk", expiresAt })]),
    );
  }
  assert.equal(
    run([
      finding(),
      ...clean(),
      disposition({
        action: "accepted_risk",
        expiresAt: "2026-09-10T12:00:00.1Z",
      }),
    ]).decision,
    "pass",
  );
});

test("evaluation must supply a valid explicit time", () => {
  for (const now of [
    undefined,
    null,
    0,
    NaN,
    new Date(NaN),
    "2026-02-30T00:00:00Z",
  ])
    assert.throws(() => run(clean(), { now }));
});

test("drafts, closed PRs and shared head commits hold despite clean reviews", () => {
  for (const overrides of [
    { draft: true },
    { state: "CLOSED" },
    { state: "MERGED" },
    { headAssociationCount: 2 },
  ])
    assert.equal(
      run(clean(), { context: context(overrides) }).decision,
      "hold",
    );
});

test("ledger corruption, cross-PR scope, duplicate events and redefined findings fail closed", () => {
  for (const overrides of [
    { revision: 99 },
    { revision: -1 },
    { revision: 1.5 },
    { repository: "example/other" },
    { pullRequest: 18 },
    { schemaVersion: 2 },
    { extra: true },
    { events: {} },
  ])
    assert.throws(() => run([], { ledger: ledger([], overrides) }));
  assert.throws(() => run([review(), review()]), /duplicate event id/);
  assert.throws(
    () => run([finding(), finding("F1", { id: "redefinition" })]),
    /cannot be redefined/,
  );
  assert.throws(
    () =>
      validateEvent(review("codex"), policy(), context(), [review(), review()]),
    /duplicate event id/,
  );
});

test("strict policy schema rejects missing, unknown, permissive or malformed fields", () => {
  for (const key of Object.keys(policy())) {
    const incomplete = policy();
    delete incomplete[key];
    assert.throws(() => validatePolicy(incomplete), /required/);
  }
  for (const overrides of [
    { extra: true },
    { schemaVersion: 2 },
    { requiredReviews: [] },
    { requiredReviews: ["claude", "claude"] },
    { reviewActors: { claude: [], codex: [30] } },
    { dispositionActors: [0] },
    { findingActors: [50, 50] },
    { blockingPriorityMax: 3 },
    { allowNotApplicable: { other: ["skip"] } },
  ])
    assert.throws(() => validatePolicy(policy(overrides)));
});

test("strict context schema rejects missing and malformed identity fields", () => {
  for (const key of Object.keys(context())) {
    const incomplete = context();
    delete incomplete[key];
    assert.throws(() => validateContext(incomplete), /required/);
  }
  for (const overrides of [
    { extra: true },
    { authorId: Number.MAX_SAFE_INTEGER + 1 },
    { pullRequest: 0 },
    { headSha: "short" },
    { policyDigest: "a".repeat(40) },
    { draft: "false" },
    { state: "open" },
    { headAssociationCount: 0 },
  ])
    assert.throws(() => validateContext(context(overrides)));
  for (const repository of [
    "owner/../repo",
    "owner/..",
    "owner/.",
    "owner//repo",
    "/repo",
    "owner\\repo",
    "https://github.com/owner/repo",
  ])
    assert.throws(() => validateContext(context({ repository })));
  assert.throws(
    () => run(clean(), { policy: policy({ repository: "example/other" }) }),
    /policy repository/,
  );
});

test("strict event schema rejects unknown or missing fields and invalid scalar values", () => {
  for (const key of Object.keys(finding())) {
    const incomplete = finding();
    delete incomplete[key];
    assert.throws(() => validateEvent(incomplete, policy(), context(), []));
  }
  for (const overrides of [
    { extra: "ignored" },
    { id: "../id" },
    { actorId: "50" },
    { priority: -1 },
    { priority: 4 },
    { title: " " },
    { path: "../outside" },
    { path: "/absolute" },
    { path: "a//b" },
    { reason: "x".repeat(4097) },
  ])
    assert.throws(() =>
      validateEvent(finding("F", overrides), policy(), context(), []),
    );
});

test("evidence requires an HTTPS GitHub URL without host spoofing or credentials", () => {
  for (const evidenceUrl of [
    "http://github.com/example",
    "https://github.com.evil.example/x",
    "https://evil.example/github.com",
    "https://name:password@github.com/x",
    "https://github.com:444/x",
    "https://github.com\\evil.example/x",
    "https://github.com/x\n",
  ])
    assert.throws(() =>
      validateEvent(finding("F", { evidenceUrl }), policy(), context(), []),
    );
  for (const evidenceUrl of [
    "https://github.com/example/repo/pull/1",
    "https://api.github.com/repos/example/repo/check-runs/123",
  ])
    assert.doesNotThrow(() =>
      validateEvent(finding("F", { evidenceUrl }), policy(), context(), []),
    );
});

test("evaluation and event validation leave caller-owned inputs unchanged", () => {
  const input = {
    policy: policy(),
    context: context(),
    ledger: ledger([finding(), ...clean(), disposition()]),
    now: NOW,
  };
  const before = JSON.stringify(input);
  assert.equal(evaluate(input).decision, "pass");
  validateEvent(
    review("claude", { id: "again" }),
    input.policy,
    input.context,
    input.ledger.events,
  );
  assert.equal(JSON.stringify(input), before);
});
