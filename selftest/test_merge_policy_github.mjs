import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";
import {
  CHECK_NAME,
  GitHubAPI,
  PolicyController,
  parseArgs,
  parseDocument,
} from "../.github/scripts/merge-policy-github.mjs";
import {
  appendEvent,
  emptyLedger,
} from "../.github/scripts/merge-policy-state.mjs";

const repository = "policy-staging/example";
const controlRepository = "policy-staging/control";
const pullRequest = 7;
const appId = 7001;
const actorId = 50;
const policyPath = `policies/${repository}.json`;
const ledgerPath = `state/${repository}/${pullRequest}.json`;
const lockPath = `locks/${repository}/${pullRequest}.json`;
const hash = (value, algorithm = "sha1") =>
  createHash(algorithm).update(value).digest("hex");
const jsonBytes = (value) => Buffer.from(`${JSON.stringify(value, null, 2)}\n`);
const clone = (value) => structuredClone(value);
const initialPolicy = () => ({
  schemaVersion: 1,
  repository,
  requiredReviews: ["claude"],
  reviewActors: { claude: [20, actorId] },
  dispositionActors: [30, actorId],
  findingActors: [40, actorId],
  allowNotApplicable: { claude: ["docs_only"] },
  blockingPriorityMax: 2,
});
function httpError(status) {
  const error = new Error(`Synthetic HTTP ${status}`);
  error.status = status;
  return error;
}

// Contents reads resolve against immutable commit snapshots. Writes implement
// file-SHA compare-and-swap and retain path history even after file deletion.
// This fake never invokes the network, filesystem, subprocesses or real GitHub.
class FakeGitHub {
  constructor() {
    this.calls = [];
    this.files = new Map();
    this.commits = new Map();
    this.history = new Set();
    this.generation = 0;
    this.checks = [];
    this.runs = new Map();
    this.userId = 20;
    this.appId = appId;
    this.appSlug = "merge-policy-staging";
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
    this.extraPRs = [];
    this.setFile(policyPath, initialPolicy());
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
  deleteFile(path) {
    this.files.delete(path);
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
      policyDigest: hash(this.files.get(policyPath).bytes, "sha256"),
      authorId: this.pr.user.id,
      draft: this.pr.draft,
      state: "OPEN",
      headAssociationCount:
        1 +
        this.extraPRs.filter((pr) => pr.head.sha === this.pr.head.sha).length,
    };
  }
  seed(event, authenticatedActor = 20) {
    const ledger =
      this.value(ledgerPath) ?? emptyLedger(repository, pullRequest);
    const result = appendEvent({
      ledger,
      event,
      actorId: authenticatedActor,
      policy: this.value(policyPath),
      context: this.context,
    });
    this.setFile(ledgerPath, result.ledger);
    return result.ledger;
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
    const result = this.route(request);
    this.afterCall?.(request, result, this);
    return result;
  }
  route({ method, endpoint, body }) {
    if (method === "GET" && endpoint === "user")
      return { id: this.userId, type: "User" };
    if (method === "GET" && endpoint === "app")
      return { id: this.appId, slug: this.appSlug };
    if (method === "GET" && endpoint === `users/${this.appSlug}[bot]`)
      return { id: actorId, type: "Bot", login: `${this.appSlug}[bot]` };
    if (
      method === "GET" &&
      endpoint === `repos/${repository}/pulls/${pullRequest}`
    )
      return clone(this.pr);
    if (
      method === "GET" &&
      endpoint === `repos/${repository}/git/ref/heads/main`
    )
      return { object: { sha: this.baseSha } };
    if (
      method === "GET" &&
      endpoint === `repos/${repository}/pulls?state=open&per_page=100`
    )
      return [[clone(this.pr), ...clone(this.extraPRs)]];
    if (
      method === "GET" &&
      endpoint === `repos/${controlRepository}/git/ref/heads/main`
    )
      return { object: { sha: this.controlSha } };
    if (
      method === "GET" &&
      endpoint.startsWith(`repos/${controlRepository}/actions/runs/`)
    ) {
      const id = Number(endpoint.split("/").at(-1));
      return clone(this.runs.get(id));
    }
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
        assert.equal(body.branch, "main");
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
    if (method === "POST" && endpoint === `repos/${repository}/check-runs`) {
      const check = {
        ...clone(body),
        id: this.checks.length + 1,
        app: { id: this.appId, slug: this.appSlug },
        html_url: `https://github.com/${repository}/runs/${this.checks.length + 1}`,
      };
      this.checks.push(check);
      return clone(check);
    }
    if (
      method === "GET" &&
      endpoint.startsWith(`repos/${repository}/check-runs/`)
    ) {
      const id = Number(endpoint.split("/").at(-1));
      return clone(this.checks.find((item) => item.id === id));
    }
    if (
      method === "PATCH" &&
      endpoint.startsWith(`repos/${repository}/check-runs/`)
    ) {
      const id = Number(endpoint.split("/").at(-1));
      const check = this.checks.find((item) => item.id === id);
      if (!check) throw httpError(404);
      Object.assign(check, clone(body));
      return clone(check);
    }
    throw new Error(`Unhandled synthetic endpoint: ${method} ${endpoint}`);
  }
}
const controller = (api, extra = {}) =>
  new PolicyController({
    api,
    repository,
    pullRequest,
    controlRepository,
    expectedAppId: appId,
    now: () => new Date("2026-09-10T12:00:00Z"),
    ...extra,
  });
function event(api, type = "review", extra = {}) {
  const { headSha, baseSha, policyDigest } = api.context;
  const detail =
    type === "review"
      ? { lane: "claude", outcome: "clean", findingIds: [] }
      : type === "finding"
        ? {
            findingId: "defect-1",
            title: "Synthetic defect",
            priority: 1,
            path: "src/example.mjs",
          }
        : { findingId: "defect-1", action: "fixed" };
  return {
    id: `${type}-1`,
    type,
    headSha,
    baseSha,
    policyDigest,
    evidenceUrl: `https://github.com/${repository}/pull/${pullRequest}`,
    reason: "Synthetic verified evidence.",
    ...detail,
    ...extra,
  };
}
const mutations = (api) => api.calls.filter((call) => call.method !== "GET");
const ledgerWrites = (api) =>
  api.calls.filter(
    (call) =>
      call.method === "PUT" &&
      call.endpoint === `repos/${controlRepository}/contents/${ledgerPath}`,
  );
function ready() {
  const api = new FakeGitHub();
  api.seed(event(api));
  api.calls = [];
  return api;
}

test("CLI wrapper passes event bytes over stdin with no shell interpolation", () => {
  const secret = "token-never-expose";
  const body = {
    reason: "$(touch /tmp/never-execute); `secret`\n${TOKEN}",
    evidence: secret,
  };
  const calls = [];
  const api = new GitHubAPI({
    env: { GH_TOKEN: secret },
    run(...args) {
      calls.push(args);
      return '{"ok":true}';
    },
  });
  assert.deepEqual(
    api.call("POST", "repos/synthetic/example/check-runs", body),
    { ok: true },
  );
  assert.equal(calls[0][0], "gh");
  assert.deepEqual(calls[0][1], [
    "api",
    "--method",
    "POST",
    "repos/synthetic/example/check-runs",
    "--input",
    "-",
  ]);
  assert.deepEqual(JSON.parse(calls[0][2].input), body);
  assert.equal(calls[0][2].shell, undefined);
  assert.ok(!calls[0][1].some((arg) => arg.includes(secret)));
});

test("CLI wrapper strips secrets and server content from exceptions", () => {
  const secret = "token-never-expose";
  for (const run of [
    () => {
      const error = new Error(secret);
      error.stderr = `HTTP 403 ${secret}`;
      throw error;
    },
    () => `${secret} invalid JSON`,
  ]) {
    const api = new GitHubAPI({ run, env: { GH_TOKEN: secret } });
    assert.throws(
      () => api.call("GET", "user"),
      (error) =>
        !error.message.includes(secret) &&
        /^GitHub GET failed/.test(error.message),
    );
  }
});

test("API failures distinguish rejected writes from uncertain remote mutations", () => {
  for (const [method, status, uncertain] of [
    ["GET", 500, false],
    ["PUT", 403, false],
    ["PUT", 409, false],
    ["PUT", 500, true],
    ["POST", null, true],
  ]) {
    const api = new GitHubAPI({
      run() {
        const error = new Error("Synthetic API failure");
        error.stderr =
          status === null ? "Synthetic transport failure" : `HTTP ${status}`;
        throw error;
      },
    });
    assert.throws(
      () => api.call(method, "synthetic/endpoint"),
      (error) => error.uncertainWrite === uncertain,
    );
  }
});

test("malformed control documents cannot leak their contents in errors", () => {
  const api = new FakeGitHub();
  const secret = "S3CRET";
  const bytes = Buffer.from(`${secret} malformed JSON`);
  api.files.set(policyPath, { sha: hash(bytes), bytes });
  api.commit();
  assert.throws(
    () => controller(api).snapshot(),
    (error) => !error.message.includes(secret),
  );
});

test("event document parsing rejects malformed and oversized bytes without echoing them", () => {
  assert.throws(
    () => parseDocument("S3CRET malformed"),
    (error) => !error.message.includes("S3CRET"),
  );
  assert.throws(
    () => parseDocument("x".repeat(2 * 1024 * 1024 + 1)),
    /size|limit|large/i,
  );
});

test("initial missing ledger publishes failure instead of silently omitting the gate", () => {
  const api = new FakeGitHub();
  const result = controller(api).evaluate({ publish: true });
  assert.equal(result.result.decision, "hold");
  assert.equal(result.check.conclusion, "failure");
  assert.equal(api.checks.at(-1).name, CHECK_NAME);
  assert.equal(api.value(lockPath).owner, null);
});

test("deleting a historically recorded ledger never resets it to empty", () => {
  const api = ready();
  api.deleteFile(ledgerPath);
  assert.throws(
    () => controller(api).snapshot({ allowMissingLedger: true }),
    /Previously recorded ledger is missing/,
  );
  assert.throws(
    () => controller(api).evaluate({ publish: true }),
    /Previously recorded ledger is missing/,
  );
  assert.equal(api.checks.at(-1)?.conclusion, "failure");
  assert.equal(ledgerWrites(api).length, 0);
});

test("read-only evaluation never writes locks, ledgers, or checks", () => {
  const api = ready();
  const result = controller(api).evaluate();
  assert.equal(result.result.decision, "pass");
  assert.equal(result.enforcementPublished, false);
  assert.equal(mutations(api).length, 0);
});

test("unauthorized actor and forged actor claim cannot change ledger or strand a lock", () => {
  for (const scenario of ["unauthorized", "forged"]) {
    const api = new FakeGitHub();
    api.userId = scenario === "unauthorized" ? 999 : 40;
    const input = event(
      api,
      "finding",
      scenario === "forged" ? { actorId: 30 } : {},
    );
    assert.throws(() => controller(api).record({ event: input }));
    assert.equal(ledgerWrites(api).length, 0, scenario);
    assert.equal(api.value(lockPath)?.owner ?? null, null);
  }
});

test("author self-review and self-disposition are refused even when allowlisted", () => {
  for (const type of ["review", "disposition"]) {
    const api = new FakeGitHub();
    const policy = api.value(policyPath);
    policy.reviewActors.claude.push(10);
    policy.dispositionActors.push(10);
    api.setFile(policyPath, policy);
    if (type === "disposition") api.seed(event(api, "finding"), 40);
    api.userId = 10;
    api.calls = [];
    assert.throws(() => controller(api).record({ event: event(api, type) }));
    assert.equal(ledgerWrites(api).length, 0, type);
    assert.equal(api.value(lockPath)?.owner ?? null, null);
  }
});

test("intake is idempotent and altered duplicate IDs never change the ledger", () => {
  const api = new FakeGitHub();
  api.userId = 40;
  const input = event(api, "finding");
  assert.equal(controller(api).record({ event: input }).changed, true);
  assert.equal(ledgerWrites(api).length, 1);
  assert.equal(controller(api).record({ event: input }).changed, false);
  assert.equal(ledgerWrites(api).length, 1);
  api.calls = [];
  assert.throws(
    () =>
      controller(api).record({
        event: { ...input, reason: "Altered duplicate" },
      }),
    /different content/,
  );
  assert.equal(ledgerWrites(api).length, 0);
  assert.equal(api.value(lockPath)?.owner ?? null, null);
});

test("App intake uses authenticated bot identity and preserves independent review checks", () => {
  const api = new FakeGitHub();
  const result = controller(api).record({ event: event(api), publish: true });
  assert.equal(result.result.decision, "pass");
  assert.equal(api.value(ledgerPath).events[0].actorId, actorId);
  assert.equal(api.checks.at(-1).conclusion, "success");
  assert.equal(api.value(lockPath).owner, null);
});

for (const change of ["head", "base", "policy", "ledger"]) {
  test(`${change} changes before publication refuse stale success and publish failure`, () => {
    const api = ready();
    let snapshots = 0;
    api.beforeCall = ({ method, endpoint }) => {
      if (
        method !== "GET" ||
        endpoint !== `repos/${controlRepository}/git/ref/heads/main` ||
        ++snapshots !== 2
      )
        return;
      if (change === "head") api.pr.head.sha = "d".repeat(40);
      if (change === "base") api.baseSha = "d".repeat(40);
      if (change === "policy")
        api.setFile(policyPath, {
          ...api.value(policyPath),
          findingActors: [40, 41, actorId],
        });
      if (change === "ledger") api.seed(event(api, "finding"), 40);
    };
    assert.throws(
      () => controller(api).evaluate({ publish: true }),
      /stale publication refused|PR moved/,
    );
    assert.equal(api.checks.at(-1).conclusion, "failure");
    assert.equal(
      api.calls.some(
        (call) => call.method === "PATCH" && call.body.conclusion === "success",
      ),
      false,
    );
  });
}

test("wrong expected publisher never produces successful acceptance", () => {
  const api = ready();
  api.appId = 7002;
  assert.throws(
    () => controller(api).evaluate({ publish: true }),
    /publisher|App/,
  );
  assert.equal(
    api.checks.some((check) => check.conclusion === "success"),
    false,
  );
});

test("wrong publisher during App intake retains the lock for explicit recovery", () => {
  const api = new FakeGitHub();
  api.appId = 7002;
  assert.throws(
    () => controller(api).record({ event: event(api), publish: true }),
    /lock retained/,
  );
  assert.equal(typeof api.value(lockPath).owner, "string");
  assert.equal(ledgerWrites(api).length, 0);
  assert.equal(
    api.checks.some((check) => check.conclusion === "success"),
    false,
  );
});

test("multiple PRs on the same head are conservatively held", () => {
  const api = ready();
  api.extraPRs = [{ number: 8, head: { sha: api.pr.head.sha } }];
  const result = controller(api).evaluate({ publish: true });
  assert.equal(result.result.decision, "hold");
  assert.equal(result.check.conclusion, "failure");
});

test("an active publication lock refuses competing writes", () => {
  const api = ready();
  api.setFile(lockPath, {
    schemaVersion: 1,
    owner: "other-operation",
    sequence: 1,
  });
  api.calls = [];
  assert.throws(
    () => controller(api).evaluate({ publish: true }),
    /already active/,
  );
  assert.equal(mutations(api).length, 0);
  assert.equal(api.value(lockPath).owner, "other-operation");
});

test("lock CAS prevents a concurrent operation from stealing ownership", () => {
  const api = ready();
  let raced = false;
  api.beforeCall = ({ method, endpoint }) => {
    if (
      raced ||
      method !== "PUT" ||
      endpoint !== `repos/${controlRepository}/contents/${lockPath}`
    )
      return;
    raced = true;
    api.setFile(lockPath, {
      schemaVersion: 1,
      owner: "concurrent-operation",
      sequence: 1,
    });
  };
  assert.throws(() => controller(api).evaluate({ publish: true }), /409/);
  assert.equal(api.value(lockPath).owner, "concurrent-operation");
  assert.equal(api.checks.length, 0);
});

test("a known-invalid event cannot strand an operation lock", () => {
  const api = ready();
  assert.throws(() =>
    controller(api).record({ event: { ...event(api), unexpected: "invalid" } }),
  );
  assert.equal(ledgerWrites(api).length, 0);
  assert.equal(api.value(lockPath)?.owner ?? null, null);
});

test("missing required publisher identity is refused before lock acquisition", () => {
  const api = ready();
  assert.throws(() =>
    controller(api, { expectedAppId: undefined }).evaluate({ publish: true }),
  );
  assert.equal(mutations(api).length, 0);
  assert.equal(api.value(lockPath), null);
});

test("known-invalid App intake leaves a failure check and released lock", () => {
  const api = ready();
  assert.throws(() =>
    controller(api).record({
      event: { ...event(api), unexpected: true },
      publish: true,
    }),
  );
  assert.equal(ledgerWrites(api).length, 0);
  assert.equal(api.checks.at(-1)?.conclusion, "failure");
  assert.equal(api.value(lockPath)?.owner ?? null, null);
});

test("an uncertain ledger write retains its lock even if remote write succeeded", () => {
  const api = new FakeGitHub();
  api.userId = 40;
  api.afterCall = ({ method, endpoint }) => {
    if (
      method === "PUT" &&
      endpoint === `repos/${controlRepository}/contents/${ledgerPath}`
    ) {
      const error = new Error("Synthetic connection lost after accepted write");
      error.uncertainWrite = true;
      throw error;
    }
  };
  assert.throws(
    () => controller(api).record({ event: event(api, "finding") }),
    /lock retained/,
  );
  assert.equal(api.value(ledgerPath).revision, 1);
  assert.equal(typeof api.value(lockPath).owner, "string");
});

test("ledger CAS preserves a concurrent finding instead of overwriting it", () => {
  const api = new FakeGitHub();
  api.userId = 40;
  let raced = false;
  api.beforeCall = ({ method, endpoint }) => {
    if (
      raced ||
      method !== "PUT" ||
      endpoint !== `repos/${controlRepository}/contents/${ledgerPath}`
    )
      return;
    raced = true;
    api.seed(
      event(api, "finding", {
        id: "concurrent-event",
        findingId: "concurrent-defect",
      }),
      40,
    );
  };
  assert.throws(
    () => controller(api).record({ event: event(api, "finding") }),
    /409/,
  );
  assert.equal(api.value(ledgerPath).revision, 1);
  assert.equal(api.value(ledgerPath).events[0].id, "concurrent-event");
});

test("uncertain check creation retains the lock and never issues success", () => {
  const api = ready();
  api.afterCall = ({ method, endpoint }) => {
    if (method === "POST" && endpoint === `repos/${repository}/check-runs`)
      throw new Error("Synthetic check create response lost");
  };
  assert.throws(
    () => controller(api).evaluate({ publish: true }),
    /lock retained/,
  );
  assert.equal(typeof api.value(lockPath).owner, "string");
  assert.equal(api.checks.at(-1).status, "in_progress");
  assert.equal(api.checks.at(-1).conclusion, undefined);
});

test("uncertain App intake check creation retains its operation lock", () => {
  const api = new FakeGitHub();
  api.afterCall = ({ method, endpoint }) => {
    if (method === "POST" && endpoint === `repos/${repository}/check-runs`) {
      const error = new Error("Synthetic check create response lost");
      error.uncertainWrite = true;
      throw error;
    }
  };
  assert.throws(
    () => controller(api).record({ event: event(api), publish: true }),
    /lock retained/,
  );
  assert.equal(typeof api.value(lockPath).owner, "string");
  assert.equal(api.checks.at(-1).status, "in_progress");
  assert.equal(ledgerWrites(api).length, 0);
});

test("uncertain successful check update is failed closed and retains recovery lock", () => {
  const api = ready();
  let lost = false;
  api.afterCall = ({ method, body }) => {
    if (lost || method !== "PATCH" || body.conclusion !== "success") return;
    lost = true;
    const error = new Error("Synthetic successful patch response lost");
    error.uncertainWrite = true;
    throw error;
  };
  assert.throws(
    () => controller(api).evaluate({ publish: true }),
    /lock retained/,
  );
  assert.equal(api.checks.at(-1).conclusion, "failure");
  assert.equal(typeof api.value(lockPath).owner, "string");
});

test("a new finding publishes failure after a previous successful decision", () => {
  const api = ready();
  controller(api).evaluate({ publish: true });
  assert.equal(api.checks.at(-1).conclusion, "success");
  api.seed(event(api, "finding"), 40);
  const result = controller(api).evaluate({ publish: true });
  assert.equal(result.result.decision, "hold");
  assert.equal(api.checks.length, 2);
  assert.equal(api.checks.at(-1).conclusion, "failure");
});

test("an unreadable ledger replaces prior success with failure", () => {
  const api = ready();
  controller(api).evaluate({ publish: true });
  api.setFile(ledgerPath, { ...api.value(ledgerPath), revision: 100 });
  assert.throws(() => controller(api).evaluate({ publish: true }));
  assert.equal(api.checks.at(-1).conclusion, "failure");
});

function abandonedOperation(api, status = "completed") {
  const lock = {
    schemaVersion: 1,
    owner: "staging-owner",
    sequence: 1,
    startedAt: "2000-01-01T00:00:00Z",
    execution: { kind: "actions", repository: controlRepository, runId: 101 },
  };
  api.runs.set(101, { id: 101, status });
  api.setFile(lockPath, lock);
  return {
    expectedOwner: lock.owner,
    expectedLockSha: api.files.get(lockPath).sha,
  };
}

test("recovery refuses active owners regardless of old timestamps", () => {
  const api = ready();
  const expected = abandonedOperation(api, "in_progress");
  api.calls = [];
  assert.throws(() => controller(api).recover(expected), /still active/);
  assert.equal(mutations(api).length, 0);
  assert.equal(api.value(lockPath).owner, expected.expectedOwner);
  assert.throws(
    () => controller(api).evaluate({ publish: true }),
    /already active/,
  );
  assert.equal(mutations(api).length, 0);
});

test("recovery refuses changed owner or blob SHA before publication", () => {
  for (const changed of ["owner", "sha"]) {
    const api = ready();
    const expected = abandonedOperation(api);
    api.calls = [];
    const request = {
      ...expected,
      ...(changed === "owner"
        ? { expectedOwner: "another-owner" }
        : { expectedLockSha: "d".repeat(40) }),
    };
    assert.throws(() => controller(api).recover(request), /identity changed/);
    assert.equal(mutations(api).length, 0);
  }
});

test("stopped-owner recovery publishes failure and clears only its exact lock", () => {
  const api = ready();
  const expected = abandonedOperation(api);
  const result = controller(api).recover(expected);
  assert.equal(result.recovered, true);
  assert.equal(result.accepted, false);
  assert.equal(api.checks.at(-1).conclusion, "failure");
  assert.equal(api.value(lockPath).owner, null);
  assert.equal(api.value(lockPath).recoveryCheckId, api.checks.at(-1).id);
  assert.equal(
    api.calls.some((call) => call.body?.conclusion === "success"),
    false,
  );
});

test("recovery also invalidates an owned prior successful check", () => {
  const api = ready();
  controller(api).evaluate({ publish: true });
  const previousCheck = api.checks[0];
  abandonedOperation(api);
  api.setFile(lockPath, {
    ...api.value(lockPath),
    check: { id: previousCheck.id, headSha: previousCheck.head_sha, appId },
  });
  const result = controller(api).recover({
    expectedOwner: api.value(lockPath).owner,
    expectedLockSha: api.files.get(lockPath).sha,
  });
  assert.equal(result.accepted, false);
  assert.equal(api.checks.length, 2);
  assert.ok(api.checks.every((check) => check.conclusion === "failure"));
  assert.equal(api.value(lockPath).owner, null);
});

test("recovery cannot clear a lock replaced while failure was being published", () => {
  const api = ready();
  const expected = abandonedOperation(api);
  let reads = 0;
  api.beforeCall = ({ method, endpoint }) => {
    if (
      method !== "GET" ||
      !endpoint.startsWith(
        `repos/${controlRepository}/contents/${lockPath}?`,
      ) ||
      ++reads !== 2
    )
      return;
    api.setFile(lockPath, {
      ...api.value(lockPath),
      owner: "replacement-owner",
      sequence: 2,
    });
  };
  assert.throws(
    () => controller(api).recover(expected),
    /conditional ownership/,
  );
  assert.equal(api.value(lockPath).owner, "replacement-owner");
  assert.equal(api.checks.at(-1).conclusion, "failure");
});

test("argument parsing rejects mutable source-comment intake and duplicate options", () => {
  for (const args of [
    ["record", "--source-comment", "12"],
    ["record", "--event", "a", "--event", "b"],
    ["evaluate", "--publish", "--publish"],
    ["evaluate", "--repo"],
    ["unknown"],
  ])
    assert.throws(() => parseArgs(args));
});
