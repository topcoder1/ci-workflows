import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";
import {
  GITHUB_ARTIFACT_LIMITS,
  createGitHubArtifactClient,
} from "../.github/scripts/merge-policy-github-artifact.mjs";
import {
  createIntakeReaders,
  dispatchTarget,
  INTAKE_ADAPTER_LIMITS,
  prefetchReviewReceipt,
} from "../.github/scripts/merge-policy-intake-adapter.mjs";
import {
  INTAKE_LIMITS,
  prepareReviewIntake,
} from "../.github/scripts/merge-policy-intake.mjs";
import { emptyLedger } from "../.github/scripts/merge-policy-state.mjs";
import { storedZip } from "./merge_policy_fixtures.mjs";

// The producer as the control repository configures it and as the client is
// built: the shadow phase's tag mode, so only attempt 1 is admissible.
const revision = "c".repeat(40);
const tagName = "merge-policy-review-v3";
const workflowRef = `refs/tags/${tagName}`;
const artifactName = "merge-policy-review-receipt.json";
const producer = () => ({
  repository: "example/reviewer",
  repositoryId: 11,
  workflowId: 21,
  workflowPath: ".github/workflows/merge-policy-review-dispatch.yml",
  workflowRevision: revision,
  artifactName,
  workflowRef,
});
const target = () => ({
  repository: "example/app",
  pullRequest: 7,
  headSha: "a".repeat(40),
  baseSha: "b".repeat(40),
  policyDigest: "d".repeat(64),
});
const selector = () => ({
  repository: "example/reviewer",
  runId: 101,
  runAttempt: 1,
  artifactId: 301,
});
const receiptProducer = () => ({
  repository: "example/reviewer",
  repositoryId: 11,
  workflowId: 21,
  workflowPath: ".github/workflows/merge-policy-review-dispatch.yml",
  workflowRevision: revision,
  runId: 101,
  runAttempt: 1,
});
/** A canonical clean receipt: the wire format the intake admits. */
function receiptBytes(patch = {}) {
  return Buffer.from(
    JSON.stringify({
      schemaVersion: 1,
      producer: receiptProducer(),
      target: target(),
      lane: "shadow",
      complete: true,
      outcome: "clean",
      findingCount: 0,
      summary: "No findings.",
      findings: [],
      ...patch,
    }),
  );
}
const hash = (bytes) => createHash("sha256").update(bytes).digest("hex");
const now = Date.now();
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");
const api = "https://api.github.com/repos/example/reviewer";
const runURL = `${api}/actions/runs/101`;
const attemptURL = `${runURL}/attempts/1`;
const artifactURL = `${api}/actions/artifacts/301`;
const zipURL = `${artifactURL}/zip`;
const tagURL = `${api}/git/ref/tags/${tagName}`;
const branchURL = `${api}/git/ref/heads/${tagName}`;
const origin = "https://artifacts.example.test";
const signedURL = `${origin}/archive.zip?opaque=signed-test`;
function run() {
  return {
    id: 101,
    workflow_id: 21,
    repository: { id: 11, full_name: "example/reviewer" },
    head_repository: { id: 11, full_name: "example/reviewer" },
    head_sha: revision,
    head_branch: tagName,
    run_attempt: 1,
    status: "completed",
    conclusion: "success",
    event: "workflow_dispatch",
    path: `.github/workflows/merge-policy-review-dispatch.yml@${tagName}`,
    referenced_workflows: [],
    pull_requests: [],
    created_at: iso(now - 100000),
    updated_at: iso(now - 10000),
    run_started_at: iso(now - 50000),
  };
}
function artifact(archive) {
  return {
    id: 301,
    name: artifactName,
    size_in_bytes: archive.length,
    digest: `sha256:${hash(archive)}`,
    expired: false,
    created_at: iso(now - 40000),
    updated_at: iso(now - 20000),
    expires_at: iso(now + 3600000),
    workflow_run: {
      id: 101,
      repository_id: 11,
      head_repository_id: 11,
      head_sha: revision,
    },
  };
}
const json = (value, init = {}) =>
  new Response(JSON.stringify(value), { status: 200, ...init });
/** A real client over a fake GitHub: every request is recorded. */
function fixture(options = {}) {
  const receipt = options.receipt ?? receiptBytes();
  const archive = storedZip(options.entryName ?? artifactName, receipt);
  const calls = [];
  const state = { runAttempt: 1, tagSha: revision, artifactDigest: undefined };
  const fetchImpl = async (url, init) => {
    calls.push({ url, init });
    const custom = await options.respond?.({ url, init, calls, state });
    if (custom !== undefined) return custom;
    if (url === tagURL)
      return json({
        ref: workflowRef,
        url: `${api}/git/${workflowRef}`,
        object: {
          type: "commit",
          sha: state.tagSha,
          url: `${api}/git/commits/${state.tagSha}`,
        },
      });
    if (url === branchURL) return new Response(null, { status: 404 });
    if (url === runURL || url === attemptURL)
      return json({ ...run(), run_attempt: state.runAttempt });
    if (url === artifactURL)
      return json({
        ...artifact(archive),
        ...(state.artifactDigest ? { digest: state.artifactDigest } : {}),
      });
    if (url === zipURL)
      return new Response(null, {
        status: 302,
        headers: { location: signedURL },
      });
    if (url === signedURL) return new Response(archive);
    throw new Error(`Unexpected fake request ${url}`);
  };
  let credentialCalls = 0;
  const client = createGitHubArtifactClient({
    producer: producer(),
    downloadOrigins: [origin],
    fetchImpl,
    tokenProvider: async () => {
      credentialCalls++;
      return "synthetic-token";
    },
  });
  return {
    client,
    calls,
    state,
    receipt,
    archive,
    credentialCalls: () => credentialCalls,
  };
}
async function prefetch(f, patch = {}) {
  return prefetchReviewReceipt({
    client: f.client,
    selector: selector(),
    dispatchRecord: target(),
    ...patch,
  });
}
function rejects(promise, code) {
  return assert.rejects(promise, (error) => {
    assert.equal(error.name, "IntakeAdapterError");
    assert.equal(error.code, code);
    assert.equal(error.message, `Review intake adapter: ${code}`);
    assert.equal(error.cause, undefined);
    return true;
  });
}
/** The intake inputs a shadow cycle would take from the controller snapshot. */
function intakeInputs(readers) {
  const context = {
    ...target(),
    authorId: 100,
    draft: false,
    state: "OPEN",
    headAssociationCount: 1,
  };
  return {
    request: {
      producerId: "shadow",
      runId: 101,
      runAttempt: 1,
      artifactId: 301,
    },
    producers: [
      {
        id: "shadow",
        repository: "example/reviewer",
        repositoryId: 11,
        workflowId: 21,
        workflowPath: ".github/workflows/merge-policy-review-dispatch.yml",
        workflowRevision: revision,
        lane: "shadow",
        publisherActorId: 200,
        artifactName,
      },
    ],
    policy: {
      schemaVersion: 1,
      repository: "example/app",
      requiredReviews: ["shadow"],
      reviewActors: { shadow: [200] },
      dispositionActors: [300],
      findingActors: [200],
      allowNotApplicable: {},
      blockingPriorityMax: 2,
    },
    context,
    ledger: emptyLedger(context.repository, context.pullRequest),
    readers,
  };
}

test("prefetch reads the archive once, extracts the exact receipt and builds the intake's metadata", async () => {
  const f = fixture();
  const result = await prefetch(f);
  assert.ok(Object.isFrozen(result));
  assert.deepEqual(
    f.calls.map(({ url }) => url),
    [
      tagURL,
      branchURL,
      runURL,
      attemptURL,
      artifactURL,
      zipURL,
      signedURL,
      runURL,
      artifactURL,
      tagURL,
      branchURL,
    ],
  );
  assert.equal(f.credentialCalls(), 1);
  assert.ok(result.receipt.equals(f.receipt));
  assert.deepEqual(result.metadata, {
    schemaVersion: 1,
    producer: receiptProducer(),
    target: target(),
    status: "completed",
    conclusion: "success",
    latestRunAttempt: 1,
    artifact: {
      id: 301,
      name: artifactName,
      byteLength: f.receipt.length,
      sha256: hash(f.receipt),
    },
  });
  assert.equal(result.archiveSha256, hash(f.archive));
  assert.notEqual(result.archiveSha256, result.metadata.artifact.sha256);
  assert.equal(result.metadata.producer.workflowPath, producer().workflowPath);
  assert.equal(INTAKE_ADAPTER_LIMITS.prefetchDeadlineMs, 10_000);
  assert.equal(Object.hasOwn(result, "archiveBytes"), false);
});

test("the readers admit the receipt through the real intake, with one fresh recheck on the second metadata read", async () => {
  const f = fixture();
  const readers = createIntakeReaders({
    client: f.client,
    prefetch: await prefetch(f),
  });
  const afterPrefetch = f.calls.length;
  const admitted = await prepareReviewIntake(intakeInputs(readers));
  assert.equal(admitted.events.at(-1).type, "review");
  assert.equal(admitted.enforcementPublished, false);
  assert.deepEqual(Object.keys(readers), ["metadata", "artifact"]);
  assert.deepEqual(
    f.calls.slice(afterPrefetch).map(({ url }) => url),
    [tagURL, branchURL, runURL, attemptURL, artifactURL],
  );
  assert.equal(f.credentialCalls(), 2);
  for (const { init } of f.calls) {
    assert.equal(init.method, "GET");
    assert.equal(init.redirect, "manual");
  }
});

test("the adapter hands the intake's 10 s deadline to the live recheck (staging run 35810541667)", async () => {
  // Without it the client falls back to its own 2 s default, which the live
  // recheck (five sequential requests, 1.2-1.8 s) outruns in production.
  const f = fixture();
  const seen = [];
  const client = Object.freeze({
    read: (...args) => f.client.read(...args),
    recheck: (selector, options) => {
      seen.push({
        deadlineMs: options?.deadlineMs,
        signal: options?.signal instanceof AbortSignal,
      });
      return f.client.recheck(selector, options);
    },
  });
  const readers = createIntakeReaders({ client, prefetch: await prefetch(f) });
  await prepareReviewIntake(intakeInputs(readers));
  assert.deepEqual(seen, [{ deadlineMs: 10000, signal: true }]);
});

test("the intake's read deadline fits the artifact client's own maximum (staging run 35810541667)", () => {
  // Hardcoded, never derived: the live re-read took up to 1,769 ms against the
  // old 2,000 ms, and the client refuses a deadline above its own maximum as
  // invalid_input, which would stop the second metadata read before it starts.
  assert.equal(INTAKE_LIMITS.readDeadlineMs, 10000);
  assert.equal(GITHUB_ARTIFACT_LIMITS.maximumDeadlineMs, 10000);
  assert.ok(
    INTAKE_LIMITS.readDeadlineMs <= GITHUB_ARTIFACT_LIMITS.maximumDeadlineMs,
  );
});

test("the second metadata read runs under the intake's deadline and refuses moved facts", async () => {
  const f = fixture();
  const readers = createIntakeReaders({
    client: f.client,
    prefetch: await prefetch(f),
  });
  const options = () => ({
    signal: new AbortController().signal,
    deadlineMs: INTAKE_LIMITS.readDeadlineMs,
  });
  const first = await readers.metadata(selector(), options());
  assert.equal(f.calls.length, 11);
  // The artifact's authenticated digest moved after the prefetch: the client
  // does not pin it across calls, so this is the adapter's own refusal.
  f.state.artifactDigest = `sha256:${"9".repeat(64)}`;
  await rejects(readers.metadata(selector(), options()), "facts_changed");
  assert.equal(f.calls.length, 16);
  f.state.artifactDigest = undefined;
  // A rerun started after the prefetch: the client refuses attempt 2 itself.
  f.state.runAttempt = 2;
  await assert.rejects(readers.metadata(selector(), options()), (error) => {
    assert.equal(error.name, "GitHubArtifactError");
    return true;
  });
  f.state.runAttempt = 1;
  // The tag moved to another commit: the client refuses before any facts.
  f.state.tagSha = "e".repeat(40);
  await assert.rejects(readers.metadata(selector(), options()), (error) => {
    assert.equal(error.name, "GitHubArtifactError");
    assert.equal(error.code, "workflow_ref_binding_mismatch");
    return true;
  });
  f.state.tagSha = revision;
  // Every later read is fresh; nothing is answered from the first answer.
  const before = f.calls.length;
  const again = await readers.metadata(selector(), options());
  assert.deepEqual(again, first);
  assert.equal(f.calls.length - before, 5);
  // Through the intake, a moved fact is a closed failure of the batch.
  const g = fixture();
  const fresh = createIntakeReaders({
    client: g.client,
    prefetch: await prefetch(g),
  });
  g.state.artifactDigest = `sha256:${"9".repeat(64)}`;
  await assert.rejects(prepareReviewIntake(intakeInputs(fresh)), (error) => {
    assert.equal(error.name, "IntakeError");
    assert.equal(error.code, "metadata_read_failed");
    return true;
  });
});

test("metadata.target comes from the dispatch record only; the receipt's own target cannot substitute", async () => {
  const other = { ...target(), headSha: "f".repeat(40) };
  const f = fixture({ receipt: receiptBytes({ target: other }) });
  const result = await prefetch(f);
  assert.deepEqual(result.metadata.target, target());
  assert.deepEqual(JSON.parse(result.receipt).target, other);
  const readers = createIntakeReaders({ client: f.client, prefetch: result });
  await assert.rejects(prepareReviewIntake(intakeInputs(readers)), (error) => {
    assert.equal(error.name, "IntakeError");
    assert.equal(error.code, "binding_mismatch");
    return true;
  });
  // The dispatch record is validated field by field before any request.
  const g = fixture();
  const cases = [
    [{ ...target(), extra: true }, "invalid_input"],
    [{ ...target(), pullRequest: "7" }, "invalid_target"],
    [{ ...target(), headSha: target().baseSha }, "invalid_target"],
    [{ ...target(), policyDigest: "d".repeat(63) }, "invalid_target"],
    [{ ...target(), repository: "example/app/extra" }, "invalid_target"],
    [Object.create({ ...target() }), "invalid_input"],
  ];
  for (const [dispatchRecord, code] of cases)
    await rejects(prefetch(g, { dispatchRecord }), code);
  assert.equal(g.calls.length, 0);
  assert.equal(g.credentialCalls(), 0);
  assert.throws(() => dispatchTarget({ ...target(), baseSha: "B".repeat(40) }));
});

test("the receipt is taken under the producer's configured artifact name, not any entry", async () => {
  const f = fixture({ entryName: "review.json" });
  await assert.rejects(prefetch(f), (error) => {
    assert.equal(error.name, "ReviewArchiveError");
    return true;
  });
});

test("selectors are exact: another run, attempt, artifact or repository is refused before credentials", async () => {
  const f = fixture();
  const readers = createIntakeReaders({
    client: f.client,
    prefetch: await prefetch(f),
  });
  const after = f.calls.length;
  for (const patch of [
    { runId: 102 },
    { runAttempt: 2 },
    { artifactId: 302 },
    { repository: "example/other" },
  ]) {
    await rejects(
      readers.metadata({ ...selector(), ...patch }),
      "selector_mismatch",
    );
    await rejects(
      readers.artifact({ ...selector(), ...patch }),
      "selector_mismatch",
    );
  }
  await rejects(readers.metadata({ ...selector(), extra: 1 }), "invalid_input");
  await rejects(readers.metadata(null), "invalid_input");
  assert.equal(f.calls.length, after);
  await rejects(
    prefetch(f, { selector: { ...selector(), repository: "example/other" } }),
    "repository_mismatch",
  );
  await rejects(
    prefetch(f, { selector: { runId: 101, runAttempt: 1, artifactId: 301 } }),
    "invalid_input",
  );
  await rejects(prefetch(f, { client: { read() {} } }), "invalid_client");
  assert.throws(
    () => createIntakeReaders({ client: f.client, prefetch: { receipt: 1 } }),
    (error) => error.code === "invalid_input",
  );
});

test("the artifact reader hands out a fresh copy of the receipt bytes each time", async () => {
  const f = fixture();
  const readers = createIntakeReaders({
    client: f.client,
    prefetch: await prefetch(f),
  });
  const one = await readers.artifact(selector());
  one[0] = 0;
  const two = await readers.artifact(selector());
  assert.ok(two.equals(f.receipt));
  assert.notEqual(one, two);
});

test("a bad credential or a moved tag at prefetch fails closed with the client's code", async () => {
  const f = fixture({
    respond: ({ url }) => (url === tagURL ? json({}) : undefined),
  });
  await assert.rejects(prefetch(f), (error) => {
    assert.equal(error.name, "GitHubArtifactError");
    assert.equal(error.code, "workflow_ref_binding_mismatch");
    assert.equal(String(error).includes("synthetic-token"), false);
    return true;
  });
});

test("metadata.producer is read from the run's API object, not fed back from the registered configuration", async () => {
  // A stub client whose run facts disagree with its configuration: the real
  // client refuses such a run, so this can only show where the adapter reads.
  const facts = {
    producer: producer(),
    run: {
      id: 101,
      attempt: 1,
      repository: "example/reviewer",
      repositoryId: 12,
      workflowId: 99,
      workflowPath: `${producer().workflowPath}@${tagName}`,
      headSha: "f".repeat(40),
      status: "completed",
      conclusion: "success",
    },
    artifact: {
      id: 301,
      name: artifactName,
      archiveByteLength: 1,
      archiveSha256: "0".repeat(64),
    },
    archiveBytes: storedZip(artifactName, receiptBytes()),
  };
  const client = {
    async read() {
      return facts;
    },
    async recheck() {
      return facts;
    },
  };
  const result = await prefetch({ client });
  assert.deepEqual(result.metadata.producer, {
    repository: "example/reviewer",
    repositoryId: 12,
    workflowId: 99,
    workflowPath: producer().workflowPath,
    workflowRevision: "f".repeat(40),
    runId: 101,
    runAttempt: 1,
  });
});
