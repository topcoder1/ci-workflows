import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import {
  existsSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import {
  PolicyController,
  policyDigest,
} from "../.github/scripts/merge-policy-github.mjs";
import {
  REVIEW_DISPATCH_REF,
  REVIEW_DISPATCH_REPORT_FILE,
} from "../.github/scripts/merge-policy-review-dispatch.mjs";
import {
  PROVIDER_LIST_PRICE,
  REFUSALS,
  SHADOW_CYCLE_KIND,
  SHADOW_DISPATCH_RECORD_KIND,
  parseArgs,
  readDispatchRecord,
  runShadowCycle,
  summarize,
  writeDispatchRecord,
} from "../.github/scripts/merge-policy-shadow.mjs";
import { storedZip } from "./merge_policy_fixtures.mjs";

// Stage A shape: the producer runs in the repository whose PR it reviews; the
// control repository is separate. Nothing here touches the network, `gh`, or
// a real filesystem outside one temporary directory per test.
const repository = "policy-staging/example";
const controlRepository = "policy-staging/control";
const pullRequest = 7;
const policyPath = `policies/${repository}.json`;
const producersPath = `producers/${repository}.json`;
const ledgerPath = `state/${repository}/${pullRequest}.json`;
const lockPath = `locks/${repository}/${pullRequest}.json`;
const revision = "c".repeat(40);
const tagName = REVIEW_DISPATCH_REF.slice("refs/tags/".length);
const artifactName = "merge-policy-review-receipt.json";
const hash = (value, algorithm = "sha1") =>
  createHash(algorithm).update(value).digest("hex");
const jsonBytes = (value) => Buffer.from(`${JSON.stringify(value, null, 2)}\n`);
const clone = (value) => structuredClone(value);
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");
const producerEntry = () => ({
  id: "shadow",
  repository,
  repositoryId: 11,
  workflowId: 21,
  workflowPath: ".github/workflows/merge-policy-review-dispatch.yml",
  workflowRevision: revision,
  lane: "shadow",
  publisherActorId: 200,
  artifactName,
});
const policy = () => ({
  schemaVersion: 1,
  repository,
  requiredReviews: ["shadow"],
  reviewActors: { shadow: [200] },
  dispositionActors: [300],
  findingActors: [200],
  allowNotApplicable: {},
  blockingPriorityMax: 2,
});
function httpError(status) {
  const error = new Error(`Synthetic HTTP ${status}`);
  error.status = status;
  return error;
}

/** The `gh api` surface a shadow cycle touches: the control repository's
 * contents with file-SHA compare-and-swap, the application PR, the producer
 * workflow's runs and artifacts. Anything else is an error, so a new request
 * the cycle makes must be added here on purpose. */
class FakeGitHub {
  constructor(clock) {
    this.clock = clock;
    this.calls = [];
    this.files = new Map();
    this.commits = new Map();
    this.history = new Set();
    this.generation = 0;
    this.baseSha = "b".repeat(40);
    this.pr = {
      number: pullRequest,
      state: "open",
      draft: false,
      merged_at: null,
      head: { sha: "a".repeat(40) },
      base: { ref: "main", repo: { full_name: repository } },
      user: { id: 10 },
    };
    this.compareStatus = "ahead";
    this.busy = { queued: 0, in_progress: 0 };
    this.dispatches = [];
    this.runs = [];
    this.runState = { status: "completed", conclusion: "success", attempt: 1 };
    this.artifacts = [];
    this.setFile(policyPath, policy());
    this.setFile(producersPath, {
      schemaVersion: 1,
      repository,
      producers: [producerEntry()],
    });
  }
  commit() {
    this.controlSha = hash(`control-commit-${++this.generation}`);
    this.commits.set(this.controlSha, new Map(this.files));
  }
  setFile(path, value) {
    const bytes = jsonBytes(value);
    this.files.set(path, { sha: hash(bytes), bytes });
    this.history.add(path);
    this.commit();
  }
  value(path) {
    return this.files.has(path)
      ? JSON.parse(this.files.get(path).bytes.toString("utf8"))
      : null;
  }
  get context() {
    return {
      repository,
      pullRequest,
      headSha: this.pr.head.sha,
      baseSha: this.baseSha,
      policyDigest: policyDigest(
        this.files.get(policyPath).bytes,
        this.files.get(producersPath).bytes,
      ),
    };
  }
  call(method, endpoint, body, options) {
    const request = {
      method,
      endpoint,
      body: body === undefined ? undefined : clone(body),
      options,
    };
    this.calls.push(request);
    this.beforeCall?.(request, this);
    return this.route(request);
  }
  route({ method, endpoint, body }) {
    const prefix = `repos/${repository}`;
    if (method === "GET" && endpoint === `${prefix}/pulls/${pullRequest}`)
      return clone(this.pr);
    if (method === "GET" && endpoint === `${prefix}/git/ref/heads/main`)
      return { object: { sha: this.baseSha } };
    if (
      method === "GET" &&
      endpoint === `${prefix}/pulls?state=open&per_page=100`
    )
      return [[clone(this.pr)]];
    if (
      method === "GET" &&
      endpoint === `${prefix}/compare/${this.baseSha}...${this.pr.head.sha}`
    )
      return { status: this.compareStatus };
    if (
      method === "GET" &&
      endpoint === `repos/${controlRepository}/git/ref/heads/main`
    )
      return { object: { sha: this.controlSha } };
    const contentsPrefix = `repos/${controlRepository}/contents/`;
    if (endpoint.startsWith(contentsPrefix)) {
      const url = new URL(`https://api.github.com/${endpoint}`);
      const path = decodeURIComponent(
        url.pathname.slice(`/${contentsPrefix}`.length),
      );
      if (method === "GET") {
        const ref = url.searchParams.get("ref") ?? "main";
        const files = ref === "main" ? this.files : this.commits.get(ref);
        const file = files?.get(path);
        if (!file) throw httpError(404);
        return {
          type: "file",
          encoding: "base64",
          sha: file.sha,
          content: file.bytes.toString("base64"),
        };
      }
      if (method === "PUT") {
        const previous = this.files.get(path);
        if (
          (previous && body.sha !== previous.sha) ||
          (!previous && body.sha !== undefined)
        )
          throw httpError(409);
        const bytes = Buffer.from(body.content, "base64");
        JSON.parse(bytes.toString("utf8"));
        this.files.set(path, { bytes, sha: hash(bytes) });
        this.history.add(path);
        this.commit();
        return {
          content: { sha: hash(bytes) },
          commit: { sha: this.controlSha },
        };
      }
    }
    if (
      method === "GET" &&
      endpoint.startsWith(`repos/${controlRepository}/commits?`)
    ) {
      const path = new URL(
        `https://api.github.com/${endpoint}`,
      ).searchParams.get("path");
      return this.history.has(path) ? [{ sha: hash(`prior-${path}`) }] : [];
    }
    const workflows = `${prefix}/actions/workflows/21`;
    for (const status of ["queued", "in_progress", "pending", "waiting"])
      if (
        method === "GET" &&
        endpoint === `${workflows}/runs?status=${status}&per_page=1`
      )
        return { total_count: this.busy[status] ?? 0, workflow_runs: [] };
    if (method === "POST" && endpoint === `${workflows}/dispatches`) {
      this.dispatches.push(clone(body));
      const id = 100 + this.dispatches.length;
      // GitHub's clock is 3 s behind the driver's: a run is never located
      // by comparing timestamps, only by its id.
      this.runs.push({
        id,
        event: "workflow_dispatch",
        head_branch: tagName,
        head_sha: revision,
        created_at: iso(this.clock.t - 3000),
      });
      if (this.duplicateRun)
        this.runs.push({ ...this.runs.at(-1), id: id + 1000 });
      return null;
    }
    if (method === "GET" && endpoint === `${workflows}/runs?per_page=1`)
      return { workflow_runs: clone(this.runs.slice(-1)) };
    if (
      method === "GET" &&
      endpoint === `${workflows}/runs?event=workflow_dispatch&per_page=10`
    )
      return { workflow_runs: clone(this.runs).reverse() };
    const run = endpoint.match(
      /^repos\/policy-staging\/example\/actions\/runs\/(\d+)$/,
    );
    if (method === "GET" && run)
      return {
        id: Number(run[1]),
        run_attempt: this.runState.attempt,
        status: this.runState.status,
        conclusion: this.runState.conclusion,
      };
    const artifacts = endpoint.match(
      /^repos\/policy-staging\/example\/actions\/runs\/(\d+)\/artifacts\?per_page=100$/,
    );
    if (method === "GET" && artifacts)
      return { artifacts: clone(this.artifacts) };
    throw new Error(`Unhandled synthetic endpoint: ${method} ${endpoint}`);
  }
}

/** The GitHub REST responses the artifact client reads, for the receipt and
 * the report of run 101; the fetch never reaches a network. */
function fakeFetch(api, { receiptFor, report, state }) {
  const base = `https://api.github.com/repos/${repository}`;
  const origin = "https://productionresultssa12.blob.core.windows.net";
  const built = new Map();
  const archives = (runId) => {
    if (!built.has(runId))
      built.set(
        runId,
        new Map([
          [
            301,
            {
              name: artifactName,
              bytes: storedZip(artifactName, receiptFor(runId)),
            },
          ],
          [
            302,
            {
              name: REVIEW_DISPATCH_REPORT_FILE,
              bytes: storedZip(REVIEW_DISPATCH_REPORT_FILE, report),
            },
          ],
        ]),
      );
    return built.get(runId);
  };
  const calls = [];
  const json = (value, init = {}) =>
    new Response(JSON.stringify(value), { status: 200, ...init });
  const run = (id) => ({
    id,
    workflow_id: 21,
    repository: { id: 11, full_name: repository },
    head_repository: { id: 11, full_name: repository },
    head_sha: revision,
    head_branch: tagName,
    run_attempt: state.attempt,
    status: "completed",
    conclusion: "success",
    event: "workflow_dispatch",
    path: `.github/workflows/merge-policy-review-dispatch.yml@${tagName}`,
    referenced_workflows: [],
    pull_requests: [],
    created_at: iso(api.clock.t - 100000),
    updated_at: iso(api.clock.t - 10000),
    run_started_at: iso(api.clock.t - 50000),
  });
  // Artifact ids are fixed per cycle in this fake; each belongs to the run
  // the cycle dispatched, which is the newest run the API answered with.
  const currentRun = () => api.runs.at(-1)?.id ?? 101;
  const artifact = (id) => {
    const entry = archives(currentRun()).get(id);
    return {
      id,
      name: entry.name,
      size_in_bytes: entry.bytes.length,
      digest: `sha256:${hash(entry.bytes, "sha256")}`,
      expired: false,
      created_at: iso(api.clock.t - 40000),
      updated_at: iso(api.clock.t - 20000),
      // The fixture clock, like every timestamp here: the cycle hands deps.now
      // to its artifact clients, so expiry is never judged on the real clock.
      expires_at: iso(api.clock.t + 3600000),
      workflow_run: {
        id: currentRun(),
        repository_id: 11,
        head_repository_id: 11,
        head_sha: revision,
      },
    };
  };
  const fetchImpl = async (url, init) => {
    calls.push({ url, init });
    if (url === `${base}/git/ref/tags/${tagName}`)
      return json({
        ref: REVIEW_DISPATCH_REF,
        url: `${base}/git/${REVIEW_DISPATCH_REF}`,
        object: {
          type: "commit",
          sha: revision,
          url: `${base}/git/commits/${revision}`,
        },
      });
    if (url === `${base}/git/ref/heads/${tagName}`)
      return new Response(null, { status: 404 });
    const runURL = url.match(/\/actions\/runs\/(\d+)(\/attempts\/1)?$/);
    if (runURL) return json(run(Number(runURL[1])));
    const id = url.match(/\/actions\/artifacts\/(\d+)(\/zip)?$/);
    if (id && !id[2]) return json(artifact(Number(id[1])));
    if (id)
      return new Response(null, {
        status: 302,
        headers: { location: `${origin}/${id[1]}.zip?opaque=signed` },
      });
    const signed = url.match(
      /^https:\/\/productionresultssa12\.blob\.core\.windows\.net\/(\d+)\.zip/,
    );
    if (signed)
      return new Response(archives(currentRun()).get(Number(signed[1])).bytes);
    throw new Error(`Unexpected fake fetch ${url}`);
  };
  return { fetchImpl, calls, origin };
}
function receiptBytes(api, runId, patch = {}) {
  return Buffer.from(
    JSON.stringify({
      schemaVersion: 1,
      producer: {
        repository,
        repositoryId: 11,
        workflowId: 21,
        workflowPath: producerEntry().workflowPath,
        workflowRevision: revision,
        runId,
        runAttempt: 1,
      },
      target: api.context,
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
const reportBytes = (usage = { inputTokens: 36900, outputTokens: 2000 }) =>
  Buffer.from(
    JSON.stringify({
      kind: "review-dispatch-v1",
      provider: { model: PROVIDER_LIST_PRICE.model, usage },
    }),
  );
function fixture(t, options = {}) {
  const clock = { t: Date.parse("2026-09-20T12:00:00Z") };
  const api = new FakeGitHub(clock);
  const controller = new PolicyController({
    api,
    repository,
    pullRequest,
    controlRepository,
    now: () => new Date(clock.t),
  });
  options.prepare?.(api, controller);
  const state = { attempt: 1 };
  const receiptFor = (runId) =>
    options.receipt?.(api, runId) ?? receiptBytes(api, runId);
  const report = options.report ?? reportBytes();
  api.artifacts = [
    { id: 301, name: artifactName, expired: false },
    { id: 302, name: REVIEW_DISPATCH_REPORT_FILE, expired: false },
  ];
  const fetch = fakeFetch(api, { receiptFor, report, state });
  const directory = mkdtempSync(join(tmpdir(), "merge-policy-shadow-"));
  const deps = {
    api,
    controller,
    fetchImpl: fetch.fetchImpl,
    ghToken: () => "synthetic-gh-token",
    now: () => new Date(clock.t),
    sleep: async (ms) => {
      clock.t += ms;
    },
  };
  const cycleOptions = {
    producerId: "shadow",
    workflowRef: REVIEW_DISPATCH_REF,
    downloadOrigins: [fetch.origin],
    dispatchDirectory: join(directory, "dispatch"),
    logPath: join(directory, "log", "shadow.jsonl"),
  };
  const cycle = () => runShadowCycle(deps, cycleOptions);
  const log = () =>
    readFileSync(cycleOptions.logPath, "utf8")
      .split("\n")
      .filter(Boolean)
      .map((line) => JSON.parse(line));
  return { api, clock, fetch, deps, cycleOptions, cycle, log, directory };
}
const nonGet = (api) => api.calls.filter((call) => call.method !== "GET");

test("a clean cycle: durable record before the dispatch, one run, intake recorded, read-only verdict, one log line", async (t) => {
  const f = fixture(t);
  let recordAtDispatch;
  f.api.beforeCall = (request) => {
    if (request.method === "POST") {
      const files = readdirSync(f.cycleOptions.dispatchDirectory);
      assert.equal(files.length, 1);
      recordAtDispatch = readDispatchRecord(
        join(f.cycleOptions.dispatchDirectory, files[0]),
      );
    }
  };
  const entry = await f.cycle();
  assert.equal(entry.kind, SHADOW_CYCLE_KIND);
  assert.equal(entry.refusal, null);
  assert.equal(entry.failure, null);
  // No step slept, so the cycle finished at the instant it started.
  assert.equal(entry.startedAt, "2026-09-20T12:00:00Z");
  assert.equal(entry.finishedAt, iso(f.clock.t));
  assert.equal(entry.finishedAt, entry.startedAt);
  // The record existed, complete but for the run, before GitHub was asked.
  assert.equal(recordAtDispatch.kind, SHADOW_DISPATCH_RECORD_KIND);
  assert.equal(recordAtDispatch.run, null);
  assert.deepEqual(recordAtDispatch.target, f.api.context);
  assert.deepEqual(f.api.dispatches, [
    {
      ref: tagName,
      inputs: {
        pull_request: "7",
        head_sha: "a".repeat(40),
        base_sha: "b".repeat(40),
        policy_digest: f.api.context.policyDigest,
        workflow_id: "21",
      },
    },
  ]);
  const record = readDispatchRecord(entry.dispatch.recordPath);
  assert.deepEqual(record.run, { id: 101 });
  assert.deepEqual(record.runsBefore, { newestId: 0 });
  assert.ok(
    f.api.calls.every((call) => !call.endpoint.includes("created=")),
    "runs are located by id, never by timestamp",
  );
  assert.deepEqual(entry.dispatch.run, {
    id: 101,
    attempt: 1,
    status: "completed",
    conclusion: "success",
  });
  assert.equal(entry.dispatch.artifactId, 301);
  assert.equal(entry.intake.outcome, "recorded");
  assert.equal(entry.intake.changed, true);
  assert.equal(entry.intake.review.outcome, "clean");
  assert.match(entry.intake.receiptSha256, /^[a-f0-9]{64}$/);
  assert.notEqual(entry.intake.receiptSha256, entry.intake.archiveSha256);
  assert.deepEqual(entry.provider, {
    model: PROVIDER_LIST_PRICE.model,
    inputTokens: 36900,
    outputTokens: 2000,
    costUsd: 0.1407,
  });
  assert.equal(entry.verdict.decision, "pass");
  assert.deepEqual(entry.verdict.reasons, []);
  assert.equal(entry.enforcementPublished, false);
  assert.deepEqual(Object.keys(entry.durationsMs), [
    "preflight",
    "dispatch",
    "wait",
    "intake",
    "provider",
    "verdict",
  ]);
  // The ledger in the control repository now carries the review.
  const ledger = f.api.value(ledgerPath);
  assert.equal(ledger.events.at(-1).type, "review");
  assert.equal(f.api.value(lockPath).owner, null);
  assert.equal(f.api.value(lockPath).intake.phase, "completed");
  // Never a check run; the only writes are the dispatch and control state.
  assert.ok(f.api.calls.every((call) => !call.endpoint.includes("check-runs")));
  for (const call of nonGet(f.api))
    assert.ok(
      (call.method === "POST" && call.endpoint.endsWith("/dispatches")) ||
        (call.method === "PUT" &&
          call.endpoint.startsWith(`repos/${controlRepository}/contents/`)),
      `${call.method} ${call.endpoint}`,
    );
  // The token is used by the client and appears nowhere the cycle writes.
  const written = [
    JSON.stringify(entry),
    readFileSync(f.cycleOptions.logPath, "utf8"),
    readFileSync(entry.dispatch.recordPath, "utf8"),
  ].join("\n");
  assert.equal(written.includes("synthetic-gh-token"), false);
  assert.ok(
    f.fetch.calls.every(
      (call) => call.init.method === "GET" && call.init.redirect === "manual",
    ),
  );
  assert.deepEqual(f.log(), [entry]);
});

test("both artifact clients judge expiry on the cycle's clock, never the real one", async (t) => {
  const f = fixture(t);
  // Both artifacts expire an hour past the fixture clock, an instant the real
  // clock passed long ago: on the real clock each reads as expired.
  const pinned = new Set();
  const fetchImpl = f.deps.fetchImpl;
  f.deps.fetchImpl = async (url, init) => {
    const response = await fetchImpl(url, init);
    const id = url.match(/\/actions\/artifacts\/(\d+)$/)?.[1];
    if (!id) return response;
    pinned.add(Number(id));
    const raw = await response.json();
    return new Response(
      JSON.stringify({ ...raw, expires_at: "2026-09-20T13:00:00Z" }),
      { status: 200 },
    );
  };
  const entry = await f.cycle();
  assert.equal(entry.startedAt, "2026-09-20T12:00:00Z");
  assert.deepEqual([...pinned].sort(), [301, 302]);
  assert.equal(entry.failure, null);
  assert.equal(entry.intake.outcome, "recorded");
  assert.equal(entry.provider.costUsd, 0.1407);
});

test("findings hold the verdict, and a second cycle is not refused by the lock a completed one leaves", async (t) => {
  const f = fixture(t, {
    receipt: (api, runId) =>
      receiptBytes(api, runId, {
        outcome: "findings",
        findingCount: 2,
        findings: [
          {
            key: "sql-injection",
            title: "Unparameterized query",
            priority: 1,
            path: "src/db.mjs",
            reason: "User input reaches the query text.",
          },
          {
            key: "style-nit",
            title: "Inconsistent naming",
            priority: 3,
            path: "src/util.mjs",
            reason: "Two spellings of one identifier.",
          },
        ],
      }),
  });
  const first = await f.cycle();
  assert.equal(first.intake.outcome, "recorded");
  assert.equal(first.intake.review.findingCount, 2);
  assert.equal(first.verdict.decision, "hold");
  assert.equal(first.verdict.openFindings.length, 2);
  assert.deepEqual(
    first.verdict.openFindings.map((finding) => finding.blocking),
    [true, false],
  );
  assert.equal(first.verdict.reasons.length, 1);
  assert.equal(first.verdict.reasons[0].code, "FINDING_OPEN");
  // Same head again: a new review event, the same open findings; the lock
  // the first cycle left (owner null, intake completed) refuses nothing.
  f.clock.t += 60_000;
  const second = await f.cycle();
  assert.equal(second.refusal, null);
  assert.equal(second.failure, null);
  assert.equal(second.intake.outcome, "recorded");
  assert.ok(second.intake.ledgerRevision > first.intake.ledgerRevision);
  assert.equal(second.verdict.decision, "hold");
  // Finding ids are per receipt (`<receipt>finding:<index>`): a re-review
  // records its findings again, and both sets stay open until disposed of.
  // Triage must count a hold by receipt, not by open finding.
  assert.equal(second.verdict.openFindings.length, 4);
  assert.equal(f.log().length, 2);
});

test("preflight refuses draft, closed, an active lock, an unknown producer, a stale base and a busy producer without dispatching", async (t) => {
  const cases = [
    ["DRAFT_OR_CLOSED", (api) => (api.pr.draft = true)],
    ["DRAFT_OR_CLOSED", (api) => (api.pr.state = "closed")],
    // An operation another process still owns: the controller's own lock.
    ["LOCK_HELD", (api, controller) => controller.lock()],
    ["STALE_BASE", (api) => (api.compareStatus = "diverged")],
    ["PRODUCER_BUSY", (api) => (api.busy.queued = 1)],
    ["PRODUCER_BUSY", (api) => (api.busy.in_progress = 1)],
  ];
  for (const [code, prepare] of cases) {
    const f = fixture(t, { prepare });
    const prepared = f.api.calls.length;
    const entry = await f.cycle();
    assert.equal(entry.refusal?.code, code, code);
    assert.equal(entry.dispatch, null);
    assert.equal(f.api.dispatches.length, 0);
    assert.ok(
      f.api.calls.slice(prepared).every((call) => call.method === "GET"),
    );
    assert.equal(existsSync(f.cycleOptions.dispatchDirectory), false);
    assert.equal(f.fetch.calls.length, 0);
    assert.ok(REFUSALS.includes(code));
    assert.deepEqual(
      f.log().map((line) => line.refusal.code),
      [code],
    );
  }
  const unknown = fixture(t);
  const entry = await runShadowCycle(unknown.deps, {
    ...unknown.cycleOptions,
    producerId: "other",
  });
  assert.equal(entry.refusal.code, "UNKNOWN_PRODUCER");
  assert.equal(nonGet(unknown.api).length, 0);
  // The unresolved-intake refusal is exercised by the failed-intake test.
});

test("a failed or rerun producer stops the cycle before any artifact read", async (t) => {
  for (const runState of [
    { status: "completed", conclusion: "failure", attempt: 1 },
    { status: "completed", conclusion: "success", attempt: 2 },
  ]) {
    const f = fixture(t, { prepare: (api) => (api.runState = runState) });
    const entry = await f.cycle();
    assert.equal(entry.failure.code, "PRODUCER_FAILED");
    assert.equal(entry.intake, null);
    assert.equal(entry.verdict, null);
    assert.equal(f.fetch.calls.length, 0);
    assert.equal(f.api.value(lockPath), null);
    assert.equal(f.log()[0].failure.code, "PRODUCER_FAILED");
  }
  const slow = fixture(t, {
    prepare: (api) => (api.runState = { status: "in_progress", attempt: 1 }),
  });
  const entry = await slow.cycle();
  assert.equal(entry.failure.code, "RUN_TIMEOUT");
  assert.ok(entry.durationsMs.wait >= 20 * 60_000);
  // The wait advanced the clock; the completion timestamp is taken after it.
  assert.equal(entry.finishedAt, iso(slow.clock.t));
  assert.ok(entry.finishedAt > entry.startedAt);
});

test("two runs answering one dispatch is refused rather than guessed", async (t) => {
  const f = fixture(t, { prepare: (api) => (api.duplicateRun = true) });
  const entry = await f.cycle();
  assert.equal(entry.failure.code, "AMBIGUOUS_RUN");
  assert.equal(entry.intake, null);
  assert.equal(f.fetch.calls.length, 0);
  assert.deepEqual(readDispatchRecord(entry.dispatch.recordPath).run, null);
});

test("a receipt for another target fails the intake closed, leaves a failed hold, and the next cycle is refused", async (t) => {
  const f = fixture(t, {
    receipt: (api, runId) =>
      receiptBytes(api, runId, {
        target: { ...api.context, headSha: "f".repeat(40) },
      }),
  });
  const entry = await f.cycle();
  assert.equal(entry.intake.outcome, "failed");
  assert.equal(entry.intake.failure.name, "IntakeError");
  assert.equal(entry.intake.failure.code, "binding_mismatch");
  assert.equal(f.api.value(ledgerPath), null);
  assert.equal(f.api.value(lockPath).intake.phase, "failed");
  // Provider figures and the verdict are still recorded for the log.
  assert.equal(entry.provider.costUsd, 0.1407);
  assert.equal(entry.verdict.decision, "hold");
  assert.deepEqual(entry.verdict.reasons, [
    {
      code: "REVIEW_INTAKE_UNRESOLVED",
      reason: "Trusted review intake is unresolved (failed)",
    },
  ]);
  f.clock.t += 60_000;
  const next = await f.cycle();
  assert.equal(next.refusal.code, "LOCK_HELD");
  assert.equal(next.refusal.detail, "intake failed");
});

test("an unreadable report costs the provider figures only", async (t) => {
  const f = fixture(t, { report: Buffer.from("{}") });
  const entry = await f.cycle();
  assert.equal(entry.intake.outcome, "recorded");
  assert.deepEqual(entry.provider, { unavailable: "usage_missing" });
  assert.equal(entry.verdict.decision, "pass");
  const missing = fixture(t);
  missing.api.artifacts = missing.api.artifacts.filter((a) => a.id === 301);
  const other = await missing.cycle();
  assert.deepEqual(other.provider, { unavailable: "ARTIFACT_NOT_FOUND" });
});

test("dispatch records are exclusive, validated and never overwritten", async (t) => {
  const directory = join(
    mkdtempSync(join(tmpdir(), "merge-policy-shadow-")),
    "records",
  );
  const record = {
    schemaVersion: 1,
    kind: SHADOW_DISPATCH_RECORD_KIND,
    dispatchedAt: "2026-09-20T12:00:00Z",
    runsBefore: { newestId: 0 },
    producer: { ...producerEntry(), workflowRef: REVIEW_DISPATCH_REF },
    target: { repository, pullRequest, headSha: "a".repeat(40) },
    ref: tagName,
    inputs: {},
    run: null,
  };
  const path = writeDispatchRecord(directory, record);
  assert.deepEqual(readDispatchRecord(path), record);
  assert.throws(() => writeDispatchRecord(directory, record), /EEXIST/);
  assert.throws(
    () => readDispatchRecord(join(directory, "..", "missing.json")),
    /ENOENT/,
  );
  let minute = 0;
  for (const bad of [
    { ...record, kind: "other" },
    {
      ...record,
      producer: { ...record.producer, workflowRef: "refs/heads/main" },
    },
    { ...record, producer: { ...record.producer, workflowId: "21" } },
    { ...record, runsBefore: { newestId: -1 } },
    { ...record, runsBefore: undefined },
  ]) {
    const badPath = writeDispatchRecord(directory, {
      ...bad,
      // Distinct by construction: random stamps collided about one run in 60.
      dispatchedAt: `2026-09-20T13:${String(++minute).padStart(2, "0")}:00Z`,
    });
    assert.throws(
      () => readDispatchRecord(badPath),
      (error) => error.code === "invalid_dispatch_record",
    );
  }
});

test("the CLI has no publish option and never names check runs", () => {
  assert.throws(
    () => parseArgs(["cycle", "--publish"]),
    (error) => error.code === "usage",
  );
  assert.throws(
    () => parseArgs(["evaluate"]),
    (error) => error.code === "usage",
  );
  assert.throws(
    () => parseArgs(["cycle", "--repo", "a/b", "--repo", "a/b"]),
    (error) => error.code === "usage",
  );
  assert.deepEqual(
    parseArgs([
      "cycle",
      "--repo",
      repository,
      "--pr",
      "7",
      "--control-repo",
      controlRepository,
      "--producer",
      "shadow",
      "--download-origin",
      "https://one.example",
      "--download-origin",
      "https://two.example",
      "--dispatch-dir",
      "d",
      "--log",
      "l",
    ]),
    {
      command: "cycle",
      downloadOrigins: ["https://one.example", "https://two.example"],
      repo: repository,
      pr: "7",
      "control-repo": controlRepository,
      producer: "shadow",
      "dispatch-dir": "d",
      log: "l",
    },
  );
  const source = readFileSync(
    new URL("../.github/scripts/merge-policy-shadow.mjs", import.meta.url),
    "utf8",
  );
  assert.equal(source.includes("check-runs"), false);
  assert.equal(source.includes('"--publish"'), false);
  assert.equal(source.includes("publish: true"), false);
  assert.match(source, /publish: false/);
});

test("cycle options are validated before any request", async (t) => {
  const f = fixture(t);
  for (const patch of [
    { workflowRef: "refs/heads/main" },
    { downloadOrigins: [] },
    { downloadOrigins: ["http://insecure.example"] },
    { downloadOrigins: ["https://host.example/path"] },
    // The family form is the client's; malformed ones fail here, unpaid.
    { downloadOrigins: ["https://*.blob.core.windows.net"] },
    { downloadOrigins: ["https://productionresultssa*blob.core.windows.net"] },
    { downloadOrigins: ["https://productionresultssa*.blob.*.windows.net"] },
  ]) {
    await assert.rejects(
      runShadowCycle(f.deps, { ...f.cycleOptions, ...patch }),
      (error) => error.name === "ShadowError",
    );
  }
  assert.equal(f.api.calls.length, 0);
});

test("summarize computes the Section 4 metrics from the log and leaves untriaged ones null", () => {
  const base = (patch) => ({
    kind: SHADOW_CYCLE_KIND,
    startedAt: "2026-09-21T10:00:00Z",
    repository,
    pullRequest: 1,
    refusal: null,
    dispatch: { run: { id: 1, conclusion: "success" } },
    intake: { outcome: "recorded" },
    provider: { costUsd: 0.2 },
    verdict: { decision: "pass" },
    interventions: { count: 0 },
    triage: null,
    ...patch,
  });
  const empty = summarize([]);
  assert.equal(empty.cycles, 0);
  assert.equal(empty.intakeSuccessRate, null);
  assert.equal(empty.triage.precision, null);
  assert.equal(empty.kill.K1.triggered, false);
  const entries = [
    base({ pullRequest: 1, triage: { outcome: "merged_as_is" } }),
    base({
      pullRequest: 2,
      verdict: { decision: "hold" },
      triage: {
        outcome: "merged_after_changes",
        findings: { a: "true_positive", b: "false_positive" },
      },
    }),
    base({
      pullRequest: 3,
      verdict: { decision: "hold" },
      triage: { outcome: "merged_as_is", findings: { c: "false_positive" } },
    }),
    base({
      pullRequest: 4,
      startedAt: "2026-09-28T10:00:00Z",
      dispatch: null,
      intake: null,
      provider: null,
      verdict: null,
      refusal: { code: "STALE_BASE" },
      interventions: { count: 3 },
    }),
    base({
      pullRequest: 5,
      intake: { outcome: "failed", failure: { code: "binding_mismatch" } },
      provider: { costUsd: 1.6 },
      verdict: { decision: "hold" },
    }),
  ];
  const s = summarize(entries);
  assert.equal(s.cycles, 5);
  assert.deepEqual(s.refusals, { STALE_BASE: 1 });
  assert.equal(s.dispatched, 4);
  assert.equal(s.producerSucceeded, 4);
  assert.equal(s.intakeRecorded, 3);
  assert.deepEqual(s.intakeFailures, { binding_mismatch: 1 });
  assert.equal(s.intakeSuccessRate, 0.75);
  assert.deepEqual(s.verdicts, { pass: 1, hold: 3 });
  assert.equal(s.cost.reviews, 4);
  assert.equal(s.cost.maxUsd, 1.6);
  assert.deepEqual(s.triage.labels, {
    true_positive: 1,
    false_positive: 2,
    should_be_p3: 0,
  });
  assert.equal(s.triage.precision, 1 / 3);
  assert.equal(s.triage.mergedAsIsHeldOnFalseFindings, 0.5);
  assert.equal(s.triage.medianReviewsPerMergedPR, 1);
  assert.deepEqual(s.interventionsPerWeek, { "2026-W39": 0, "2026-W40": 3 });
  assert.equal(s.success.interventionsAtMostOnePerWeekLast3, null);
  assert.equal(s.kill.K1.evaluable, false);
  assert.equal(s.kill.K1.triggered, false);
  assert.equal(s.kill.K2.triggered, true);
  assert.equal(s.kill.K3.triggered, true);
  assert.equal(s.kill.K4.triggered, false);
  assert.equal(s.success.precisionAtLeast70, false);
  assert.equal(s.success.intakeSuccessAtLeast90, false);
  assert.equal(s.success.passesOnMergedPRs, 1);
  assert.equal(s.success.holdsWithConfirmedTruePositives, 1);
});

test("an older run on the same tag is never taken for the dispatch, and a skewed clock changes nothing", async (t) => {
  const f = fixture(t, {
    prepare: (api) => {
      api.runs.push({
        id: 50,
        event: "workflow_dispatch",
        head_branch: tagName,
        head_sha: revision,
        created_at: iso(api.clock.t + 120_000),
      });
    },
  });
  const entry = await f.cycle();
  assert.equal(entry.failure, null);
  assert.equal(entry.dispatch.run.id, 101);
  assert.deepEqual(readDispatchRecord(entry.dispatch.recordPath).runsBefore, {
    newestId: 50,
  });
  assert.equal(entry.intake.outcome, "recorded");
});

test("a failed intake logs the hold's phase, and a log the driver cannot append survives as a reduced line", async (t) => {
  const f = fixture(t, {
    receipt: (api, runId) =>
      receiptBytes(api, runId, {
        target: { ...api.context, headSha: "f".repeat(40) },
      }),
  });
  const entry = await f.cycle();
  assert.deepEqual(entry.verdict.reasons, [
    {
      code: "REVIEW_INTAKE_UNRESOLVED",
      reason: "Trusted review intake is unresolved (failed)",
    },
  ]);
  // A receipt with 64 findings (under the intake's 64 KiB artifact cap),
  // re-reviewed five times: the accumulated open findings outgrow the line
  // limit and the log keeps a reduced line rather than nothing.
  const g = fixture(t, {
    receipt: (api, runId) =>
      receiptBytes(api, runId, {
        outcome: "findings",
        findingCount: 64,
        findings: Array.from({ length: 64 }, (_, index) => ({
          key: `finding-${index}`,
          title: "t".repeat(200),
          priority: 1,
          path: `src/${"p".repeat(100)}-${index}.mjs`,
          reason: "r".repeat(100),
        })),
      }),
  });
  let last;
  for (let cycle = 0; cycle < 5; cycle++) {
    last = await g.cycle();
    g.clock.t += 60_000;
  }
  assert.equal(last.intake.outcome, "recorded");
  assert.equal(last.logReduced, "log_line_too_long");
  // The returned (printed) entry stays complete; only the line is reduced.
  assert.ok(Array.isArray(last.verdict.openFindings));
  assert.equal(last.verdict.openFindings.length, 320);
  assert.equal(last.intake.review.findings.length, 64);
  assert.equal(last.logFailure, undefined);
  const lines = g.log();
  assert.equal(lines.length, 5);
  assert.equal(typeof lines.at(-1).verdict.openFindings, "number");
  assert.equal(lines.at(-1).verdict.openFindings, 320);
  assert.equal(lines.at(-1).intake.review.findings, 64);
  assert.ok(lines.every((line) => JSON.stringify(line).length <= 65_536));
});

test("the CLI exits 2 on usage errors with the message and no stack", () => {
  const script = new URL(
    "../.github/scripts/merge-policy-shadow.mjs",
    import.meta.url,
  ).pathname;
  for (const args of [[], ["bogus"], ["cycle", "--publish"], ["summarize"]]) {
    const result = spawnSync(process.execPath, [script, ...args], {
      encoding: "utf8",
      env: { PATH: process.env.PATH, HOME: process.env.HOME },
      stdio: ["ignore", "pipe", "pipe"],
      timeout: 20_000,
    });
    assert.equal(result.status, 2, JSON.stringify(args));
    assert.match(result.stderr, /^Shadow cycle: usage/);
    assert.doesNotMatch(result.stderr, /\n\s+at /);
    assert.equal(result.stdout, "");
  }
});

test("a log that cannot be written at all leaves the cycle's entry intact with the second failure's code", async (t) => {
  const f = fixture(t);
  // The log's parent path is a file, so neither the full line nor the reduced
  // one can be appended; the intake has already been recorded by then.
  const blocker = join(f.directory, "blocker");
  writeFileSync(blocker, "");
  const entry = await runShadowCycle(f.deps, {
    ...f.cycleOptions,
    logPath: join(blocker, "shadow.jsonl"),
  });
  assert.equal(entry.intake.outcome, "recorded");
  assert.equal(entry.verdict.decision, "pass");
  // Node's recursive mkdir over a file reports EEXIST or ENOTDIR by platform.
  assert.ok(
    ["EEXIST", "ENOTDIR"].includes(entry.logFailure),
    String(entry.logFailure),
  );
  assert.equal(entry.logReduced, undefined);
  assert.equal(entry.failure, null);
  assert.equal(existsSync(join(blocker, "shadow.jsonl")), false);
  assert.equal(f.api.value(ledgerPath).events.at(-1).type, "review");
});

test("the family origin the runbook documents drives a whole cycle to a recorded intake", async (t) => {
  // SHADOW-MODE.md tells the operator to pass this exact string. The driver once
  // refused it with its own stricter origin regex while the client accepted
  // it, so every documented cycle would have failed before dispatch; no test
  // drove the family form through a cycle.
  const f = fixture(t);
  const entry = await runShadowCycle(f.deps, {
    ...f.cycleOptions,
    downloadOrigins: ["https://productionresultssa*.blob.core.windows.net"],
  });
  assert.equal(entry.refusal, null);
  assert.equal(entry.failure, null);
  assert.equal(entry.intake.outcome, "recorded");
  assert.equal(entry.verdict.decision, "pass");
  // The fake storage host is sa12, a member of the family.
  assert.ok(
    f.fetch.calls.some(({ url }) =>
      url.startsWith("https://productionresultssa12.blob.core.windows.net/"),
    ),
  );
});
