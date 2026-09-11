import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { performance } from "node:perf_hooks";
import { brotliCompressSync, gzipSync } from "node:zlib";
import test from "node:test";
import {
  createGitHubArtifactClient,
  GITHUB_ARTIFACT_LIMITS,
} from "../.github/scripts/merge-policy-github-artifact.mjs";

const revision = "a".repeat(40);
const archive = Buffer.concat([
  Buffer.from("504b0304", "hex"),
  Buffer.from("synthetic archive bytes; structural ZIP validation is separate"),
]);
const hash = (bytes) => createHash("sha256").update(bytes).digest("hex");
const selector = () => ({ runId: 101, runAttempt: 2, artifactId: 301 });
const producer = () => ({
  repository: "example/reviewer",
  repositoryId: 11,
  workflowId: 21,
  workflowPath: ".github/workflows/review.yml",
  workflowRevision: revision,
  artifactName: "review.json",
});
const origin = "https://artifacts.example.test";
const root = "https://api.github.com/repos/example/reviewer/actions";
const runURL = `${root}/runs/101`;
const attemptURL = `${runURL}/attempts/2`;
const artifactURL = `${root}/artifacts/301`;
const zipURL = `${artifactURL}/zip`;
const signedURL = `${origin}/archive.zip?opaque=signed-test`;
const now = Date.now();
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");
function run() {
  return {
    id: 101,
    workflow_id: 21,
    repository: { id: 11, full_name: "example/reviewer" },
    head_repository: { id: 11, full_name: "example/reviewer" },
    head_sha: revision,
    run_attempt: 2,
    status: "completed",
    conclusion: "success",
    event: "workflow_dispatch",
    path: ".github/workflows/review.yml",
    referenced_workflows: [],
    pull_requests: [],
    created_at: iso(now - 100000),
    updated_at: iso(now - 10000),
    run_started_at: iso(now - 50000),
  };
}
function artifact() {
  return {
    id: 301,
    name: "review.json",
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
function fixture(options = {}) {
  const calls = [];
  const counts = new Map();
  let credentialCalls = 0;
  const fetchImpl = async (url, init) => {
    calls.push({ url, init });
    const count = (counts.get(url) ?? 0) + 1;
    counts.set(url, count);
    const custom = await options.respond?.({ url, init, count, calls });
    if (custom !== undefined) return custom;
    if (url === runURL || url === attemptURL) return json(run());
    if (url === artifactURL) return json(artifact());
    if (url === zipURL)
      return options.direct
        ? new Response(archive)
        : new Response(null, { status: 302, headers: { location: signedURL } });
    if (url === signedURL) return new Response(archive);
    throw new Error(`Unexpected fake request ${url}`);
  };
  const client = createGitHubArtifactClient({
    producer: options.producer ?? producer(),
    downloadOrigins: options.origins ?? [origin],
    fetchImpl,
    tokenProvider: async (request) => {
      credentialCalls++;
      assert.equal(request.repositoryId, 11);
      assert.equal(request.repository, "example/reviewer");
      assert.ok(Object.isFrozen(request));
      return options.tokenProvider
        ? options.tokenProvider(request)
        : "synthetic-token";
    },
  });
  return { client, calls, credentialCalls: () => credentialCalls };
}
async function fails(client, code, selection = selector(), options) {
  await assert.rejects(client.read(selection, options), (error) => {
    assert.equal(error.name, "GitHubArtifactError");
    assert.equal(error.code, code);
    assert.equal(error.message, `GitHub artifact: ${code}`);
    assert.equal(error.cause, undefined);
    return true;
  });
}

test("construction is inert; verified facts are frozen and archive access is defensive", async () => {
  const f = fixture();
  assert.equal(f.calls.length, 0);
  assert.equal(f.credentialCalls(), 0);
  const result = await f.client.read(selector());
  assert.equal(f.credentialCalls(), 1);
  assert.deepEqual(
    f.calls.map((call) => call.url),
    [runURL, attemptURL, artifactURL, zipURL, signedURL, runURL, artifactURL],
  );
  assert.ok(
    Object.isFrozen(result) &&
      Object.isFrozen(result.producer) &&
      Object.isFrozen(result.run) &&
      Object.isFrozen(result.artifact),
  );
  assert.equal(result.artifact.archiveSha256, hash(archive));
  assert.equal(result.artifact.archiveByteLength, archive.length);
  assert.deepEqual(result.archiveBytes, archive);
  result.archiveBytes.fill(0);
  assert.deepEqual(result.archiveBytes, archive);
  for (const field of [
    "artifactAttemptAuthenticated",
    "executionComparisonAuthenticated",
    "enforcementPublished",
  ])
    assert.equal(result[field], false);
  for (const field of [
    "target",
    "metadata",
    "events",
    "ledger",
    "publisherActorId",
    "complete",
    "outcome",
    "policyDigest",
  ])
    assert.equal(Object.hasOwn(result, field), false);
  for (const { url, init } of f.calls) {
    assert.equal(init.method, "GET");
    assert.equal(init.redirect, "manual");
    assert.equal(init.credentials, "omit");
    assert.equal(init.referrerPolicy, "no-referrer");
    assert.equal(init.cache, "no-store");
    if (url.startsWith(origin))
      assert.deepEqual(init.headers, { accept: "application/octet-stream" });
    else assert.equal(init.headers.authorization, "Bearer synthetic-token");
  }
});
test("direct API archive response and exact immutable path suffix are supported", async () => {
  const f = fixture({
    direct: true,
    respond: ({ url }) => {
      if (url === runURL || url === attemptURL)
        return json({
          ...run(),
          path: `${producer().workflowPath}@${revision}`,
        });
    },
  });
  assert.deepEqual((await f.client.read(selector())).archiveBytes, archive);
  assert.equal(f.calls.length, 6);
});
test("configuration and selector are copied before asynchronous work", async () => {
  const p = producer();
  const origins = [origin];
  const input = selector();
  const f = fixture({
    producer: p,
    origins,
    tokenProvider: async () => {
      input.runId = 999;
      input.artifactId = 999;
      return "synthetic-token";
    },
  });
  p.repository = "attacker/other";
  p.repositoryId = 999;
  origins[0] = "https://other.example.test";
  assert.equal((await f.client.read(input)).run.id, 101);
});

const runMutations = [
  [
    "run id",
    (r) => {
      r.id++;
    },
    "run_binding_mismatch",
  ],
  [
    "workflow id",
    (r) => {
      r.workflow_id++;
    },
    "run_binding_mismatch",
  ],
  [
    "repository id",
    (r) => {
      r.repository.id++;
    },
    "run_binding_mismatch",
  ],
  [
    "repository name",
    (r) => {
      r.repository.full_name = "other/repo";
    },
    "run_binding_mismatch",
  ],
  [
    "fork id",
    (r) => {
      r.head_repository.id++;
    },
    "run_binding_mismatch",
  ],
  [
    "fork name",
    (r) => {
      r.head_repository.full_name = "other/repo";
    },
    "run_binding_mismatch",
  ],
  [
    "approved source",
    (r) => {
      r.head_sha = "b".repeat(40);
    },
    "run_binding_mismatch",
  ],
  [
    "attempt",
    (r) => {
      r.run_attempt++;
    },
    "run_not_current_success",
  ],
  [
    "running",
    (r) => {
      r.status = "in_progress";
    },
    "run_not_current_success",
  ],
  [
    "failed",
    (r) => {
      r.conclusion = "failure";
    },
    "run_not_current_success",
  ],
  [
    "PR event",
    (r) => {
      r.event = "pull_request";
    },
    "unsupported_execution",
  ],
  [
    "path",
    (r) => {
      r.path = ".github/workflows/other.yml";
    },
    "unsupported_execution",
  ],
  [
    "mutable suffix",
    (r) => {
      r.path += "@main";
    },
    "unsupported_execution",
  ],
  [
    "reusable workflow",
    (r) => {
      r.referenced_workflows = [{ sha: revision }];
    },
    "unsupported_execution",
  ],
  [
    "missing reuse metadata",
    (r) => {
      delete r.referenced_workflows;
    },
    "unsupported_execution",
  ],
  [
    "PR association",
    (r) => {
      r.pull_requests = [{ number: 1 }];
    },
    "unsupported_execution",
  ],
];
for (const [name, mutate, code] of runMutations) {
  test(`rejects mismatched ${name}`, async () => {
    const f = fixture({
      respond: ({ url }) => {
        if (url === runURL) {
          const value = run();
          mutate(value);
          return json(value);
        }
      },
    });
    await fails(f.client, code);
    assert.equal(f.calls.length, 1);
  });
}
test("attempt endpoint must independently match authenticated current run", async () => {
  const f = fixture({
    respond: ({ url }) =>
      url === attemptURL
        ? json({ ...run(), updated_at: iso(now - 5000) })
        : undefined,
  });
  await fails(f.client, "metadata_changed");
});
const artifactMutations = [
  [
    "id",
    (a) => {
      a.id++;
    },
    "artifact_binding_mismatch",
  ],
  [
    "name",
    (a) => {
      a.name = "other.json";
    },
    "artifact_binding_mismatch",
  ],
  [
    "run",
    (a) => {
      a.workflow_run.id++;
    },
    "artifact_binding_mismatch",
  ],
  [
    "repo",
    (a) => {
      a.workflow_run.repository_id++;
    },
    "artifact_binding_mismatch",
  ],
  [
    "head repo",
    (a) => {
      a.workflow_run.head_repository_id++;
    },
    "artifact_binding_mismatch",
  ],
  [
    "head SHA",
    (a) => {
      a.workflow_run.head_sha = "b".repeat(40);
    },
    "artifact_binding_mismatch",
  ],
  [
    "expired flag",
    (a) => {
      a.expired = true;
    },
    "artifact_expired",
  ],
  [
    "expired date",
    (a) => {
      a.expires_at = iso(now - 1000);
    },
    "artifact_expired",
  ],
  [
    "missing digest",
    (a) => {
      delete a.digest;
    },
    "archive_digest_missing",
  ],
  [
    "wrong digest algorithm",
    (a) => {
      a.digest = `md5:${"a".repeat(64)}`;
    },
    "archive_digest_missing",
  ],
  [
    "oversize",
    (a) => {
      a.size_in_bytes = GITHUB_ARTIFACT_LIMITS.archiveBytes + 1;
    },
    "archive_limit",
  ],
  [
    "zero size",
    (a) => {
      a.size_in_bytes = 0;
    },
    "archive_limit",
  ],
];
for (const [name, mutate, code] of artifactMutations) {
  test(`rejects artifact ${name}`, async () => {
    const f = fixture({
      respond: ({ url }) => {
        if (url === artifactURL) {
          const value = artifact();
          mutate(value);
          return json(value);
        }
      },
    });
    await fails(f.client, code);
    assert.equal(f.calls.length, 3);
  });
}
test("changed bytes fail the authenticated archive digest", async () => {
  const changed = Buffer.from(archive);
  changed[10] ^= 1;
  const f = fixture({
    respond: ({ url }) =>
      url === signedURL ? new Response(changed) : undefined,
  });
  await fails(f.client, "archive_digest_mismatch");
});
test("archive length must match authenticated size", async () => {
  const f = fixture({
    respond: ({ url }) =>
      url === signedURL ? new Response(archive.subarray(1)) : undefined,
  });
  await fails(f.client, "archive_length_mismatch");
});
test("raw upload-artifact output is refused even with a valid authenticated digest", async () => {
  const raw = Buffer.from('{"complete":true,"outcome":"clean"}');
  const f = fixture({
    respond: ({ url }) => {
      if (url === artifactURL)
        return json({
          ...artifact(),
          size_in_bytes: raw.length,
          digest: `sha256:${hash(raw)}`,
        });
      if (url === signedURL) return new Response(raw);
    },
  });
  await fails(f.client, "unsupported_archive_format");
});
test("run association never authenticates the artifact attempt", async () => {
  const f = fixture({
    respond: ({ url }) =>
      url === artifactURL
        ? json({ ...artifact(), created_at: iso(now - 90000) })
        : undefined,
  });
  const result = await f.client.read(selector());
  assert.equal(result.artifactAttemptAuthenticated, false);
  assert.equal(result.executionComparisonAuthenticated, false);
  assert.equal(Object.hasOwn(result.artifact, "runAttempt"), false);
});
test("rerun beginning during download is rejected", async () => {
  const f = fixture({
    respond: ({ url, count }) =>
      url === runURL && count === 2
        ? json({ ...run(), run_attempt: 3, status: "queued" })
        : undefined,
  });
  await fails(f.client, "run_not_current_success");
});
for (const change of ["deleted", "expired", "digest", "updated", "binding"]) {
  test(`fresh artifact check rejects ${change}`, async () => {
    const f = fixture({
      respond: ({ url, count }) => {
        if (url !== artifactURL || count !== 2) return;
        if (change === "deleted")
          return new Response("not surfaced", { status: 404 });
        const a = artifact();
        if (change === "expired") a.expired = true;
        if (change === "digest") a.digest = `sha256:${"b".repeat(64)}`;
        if (change === "updated") a.updated_at = iso(now - 1000);
        if (change === "binding") a.workflow_run.id++;
        return json(a);
      },
    });
    await fails(
      f.client,
      {
        deleted: "metadata_http_error",
        expired: "artifact_expired",
        digest: "metadata_changed",
        updated: "metadata_changed",
        binding: "artifact_binding_mismatch",
      }[change],
    );
  });
}
for (const [location, code] of [
  [
    "https://artifacts.example.test.attacker.test/x?secret=signed",
    "untrusted_download_origin",
  ],
  ["http://artifacts.example.test/x", "invalid_download_url"],
  ["https://user:secret@artifacts.example.test/x", "invalid_download_url"],
  ["https://artifacts.example.test:444/x", "invalid_download_url"],
  ["https://artifacts.example.test/x#signed", "invalid_download_url"],
  ["https://artifacts.example.test/x#", "invalid_download_url"],
  ["https://@artifacts.example.test/x", "invalid_download_url"],
  ["/relative", "invalid_download_url"],
  ["https://api.github.com/private", "invalid_download_url"],
]) {
  test(`rejects forbidden storage location (${code}, ${location.length})`, async () => {
    const f = fixture({
      respond: ({ url }) =>
        url === zipURL
          ? new Response(null, { status: 302, headers: { location } })
          : undefined,
    });
    await fails(f.client, code);
    assert.equal(f.calls.length, 4);
  });
}
test("second storage redirect is refused without forwarding sensitive headers", async () => {
  const f = fixture({
    respond: ({ url }) =>
      url === signedURL
        ? new Response(null, {
            status: 302,
            headers: {
              location: "https://other.example.test/?credential=secret",
            },
          })
        : undefined,
  });
  await fails(f.client, "archive_http_error");
  assert.equal(f.calls.length, 5);
  assert.deepEqual(f.calls[4].init.headers, {
    accept: "application/octet-stream",
  });
});
test("metadata redirect is refused, including implicit redirect by a broken fetch adapter", async () => {
  await fails(
    fixture({
      respond: ({ url }) =>
        url === runURL
          ? new Response(null, {
              status: 302,
              headers: { location: signedURL },
            })
          : undefined,
    }).client,
    "metadata_http_error",
  );
  const response = json(run());
  Object.defineProperty(response, "redirected", { value: true });
  await fails(
    fixture({ respond: () => response }).client,
    "unexpected_redirect",
  );
});
test("metadata body cap is enforced during streaming without content-length", async () => {
  let cancelled = false;
  const body = new ReadableStream({
    start(c) {
      c.enqueue(Buffer.alloc(GITHUB_ARTIFACT_LIMITS.metadataBytes));
      c.enqueue(Buffer.from("x"));
    },
    cancel() {
      cancelled = true;
    },
  });
  await fails(
    fixture({
      respond: ({ url }) => (url === runURL ? new Response(body) : undefined),
    }).client,
    "response_limit",
  );
  assert.equal(cancelled, true);
});
test("archive streaming cap cancels the reader", async () => {
  let cancelled = false;
  const body = new ReadableStream({
    start(c) {
      c.enqueue(Buffer.alloc(GITHUB_ARTIFACT_LIMITS.archiveBytes));
      c.enqueue(Buffer.from("x"));
    },
    cancel() {
      cancelled = true;
    },
  });
  await fails(
    fixture({
      respond: ({ url }) =>
        url === signedURL ? new Response(body) : undefined,
    }).client,
    "response_limit",
  );
  assert.equal(cancelled, true);
});
test("oversized content-length is rejected without consuming the body", async () => {
  let cancelled = false;
  const body = new ReadableStream({
    cancel() {
      cancelled = true;
    },
  });
  await fails(
    fixture({
      respond: ({ url }) =>
        url === runURL
          ? new Response(body, {
              headers: {
                "content-length": String(
                  GITHUB_ARTIFACT_LIMITS.metadataBytes + 1,
                ),
              },
            })
          : undefined,
    }).client,
    "response_limit",
  );
  assert.equal(cancelled, true);
});
test("declared length mismatch and malformed JSON are sanitized", async () => {
  await fails(
    fixture({
      respond: ({ url }) =>
        url === runURL
          ? json(run(), { headers: { "content-length": "1" } })
          : undefined,
    }).client,
    "response_length_mismatch",
  );
  await fails(
    fixture({
      respond: ({ url }) =>
        url === runURL ? new Response("secret malformed {") : undefined,
    }).client,
    "invalid_metadata",
  );
});
test("decoded gzip metadata and br ZIP use wire lengths only as wire bounds", async () => {
  const f = fixture({
    respond: ({ url }) => {
      // Native fetch presents decoded streams but preserves encoding and wire
      // Content-Length headers. These offline fixtures reproduce that contract.
      if (url === runURL || url === attemptURL || url === artifactURL) {
        const raw = Buffer.from(
          JSON.stringify(url === artifactURL ? artifact() : run()),
        );
        const wireLength = gzipSync(raw).length;
        assert.notEqual(wireLength, raw.length);
        return new Response(raw, {
          headers: {
            "content-encoding": "gzip",
            "content-length": String(wireLength),
          },
        });
      }
      if (url === signedURL) {
        const wireLength = brotliCompressSync(archive).length;
        assert.notEqual(wireLength, archive.length);
        return new Response(archive, {
          headers: {
            "content-encoding": "br",
            "content-length": String(wireLength),
          },
        });
      }
    },
  });
  const result = await f.client.read(selector());
  assert.deepEqual(result.archiveBytes, archive);
  assert.equal(result.artifact.archiveByteLength, archive.length);
  assert.equal(result.artifact.archiveSha256, hash(archive));
});
test("small encoded Content-Length cannot bypass the decoded streaming cap", async () => {
  let cancelled = false;
  const decoded = Buffer.alloc(GITHUB_ARTIFACT_LIMITS.metadataBytes + 1, 32);
  const wireLength = gzipSync(decoded).length;
  assert.ok(wireLength < GITHUB_ARTIFACT_LIMITS.metadataBytes);
  const body = new ReadableStream({
    start(c) {
      c.enqueue(decoded);
    },
    cancel() {
      cancelled = true;
    },
  });
  await fails(
    fixture({
      respond: ({ url }) =>
        url === runURL
          ? new Response(body, {
              headers: {
                "content-encoding": "gzip",
                "content-length": String(wireLength),
              },
            })
          : undefined,
    }).client,
    "response_limit",
  );
  assert.equal(cancelled, true);
});
test("unsupported or stacked response encodings are refused and cancelled", async () => {
  for (const encoding of ["compress", "gzip, br"]) {
    let cancelled = false;
    const body = new ReadableStream({
      cancel() {
        cancelled = true;
      },
    });
    await fails(
      fixture({
        respond: ({ url }) =>
          url === runURL
            ? new Response(body, { headers: { "content-encoding": encoding } })
            : undefined,
      }).client,
      "unsupported_response_encoding",
    );
    assert.equal(cancelled, true);
  }
});
test("pre-aborted parent prevents credential access and all requests", async () => {
  const f = fixture();
  const controller = new AbortController();
  controller.abort(new Error("private reason"));
  await fails(f.client, "aborted", selector(), { signal: controller.signal });
  assert.equal(f.credentialCalls(), 0);
  assert.equal(f.calls.length, 0);
});
test("parent cancellation interrupts a stalled stream and cancels its reader", async () => {
  let cancelled = false;
  const controller = new AbortController();
  const f = fixture({
    respond: ({ url }) => {
      if (url !== signedURL) return;
      setTimeout(() => controller.abort(new Error("private reason")), 10);
      return new Response(
        new ReadableStream({
          cancel() {
            cancelled = true;
          },
        }),
      );
    },
  });
  await fails(f.client, "aborted", selector(), { signal: controller.signal });
  assert.equal(cancelled, true);
});
test("deadline spans all requests rather than restarting per response", async () => {
  const f = fixture({
    respond: async () => {
      await new Promise((resolve) => setTimeout(resolve, 15));
    },
  });
  const start = performance.now();
  await fails(f.client, "deadline_exceeded", selector(), { deadlineMs: 40 });
  assert.ok(performance.now() - start < 500);
  assert.ok(f.calls.length <= 3);
});
test("deadline interrupts slow body even if fetch does not implement abort", async () => {
  let cancelled = false;
  const f = fixture({
    respond: ({ url }) =>
      url === signedURL
        ? new Response(
            new ReadableStream({
              cancel() {
                cancelled = true;
              },
            }),
          )
        : undefined,
  });
  await fails(f.client, "deadline_exceeded", selector(), { deadlineMs: 25 });
  assert.equal(cancelled, true);
});
test("credential timeout never starts requests, even after provider eventually resolves", async () => {
  let finish;
  const f = fixture({
    tokenProvider: () =>
      new Promise((resolve) => {
        finish = resolve;
      }),
  });
  await fails(f.client, "deadline_exceeded", selector(), { deadlineMs: 10 });
  finish("synthetic-token");
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(f.calls.length, 0);
});
test("a fetch settling after the shared deadline has its response body cancelled", async () => {
  let finish;
  let cancelled = false;
  const f = fixture({
    respond: () =>
      new Promise((resolve) => {
        finish = resolve;
      }),
  });
  await fails(f.client, "deadline_exceeded", selector(), { deadlineMs: 10 });
  finish(
    new Response(
      new ReadableStream({
        cancel() {
          cancelled = true;
        },
      }),
    ),
  );
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(cancelled, true);
  assert.equal(f.calls.length, 1);
});
test("credential and transport exceptions cannot surface sensitive strings", async () => {
  await fails(
    fixture({
      tokenProvider: () => {
        throw new Error("private-token");
      },
    }).client,
    "credential_unavailable",
  );
  await fails(
    fixture({ tokenProvider: () => "bad\r\ncredential" }).client,
    "credential_unavailable",
  );
  await fails(
    fixture({
      respond: () => {
        throw new Error("private signed URL or response body");
      },
    }).client,
    "request_failed",
  );
});
test("invalid selectors and deadline configuration fail before credentials", async () => {
  const f = fixture();
  await fails(f.client, "invalid_input", { ...selector(), runId: "101" });
  await fails(f.client, "invalid_input", { ...selector(), extra: true });
  await fails(f.client, "invalid_input", selector(), { deadlineMs: 10001 });
  await fails(f.client, "invalid_input", selector(), { deadlineMs: 0 });
  assert.equal(f.credentialCalls(), 0);
});
test("producer and origin input accessors are not invoked", () => {
  let invoked = false;
  const p = producer();
  Object.defineProperty(p, "repository", {
    enumerable: true,
    get() {
      invoked = true;
      return "other/repo";
    },
  });
  assert.throws(() => fixture({ producer: p }), { code: "invalid_input" });
  const origins = [];
  Object.defineProperty(origins, "0", {
    enumerable: true,
    get() {
      invoked = true;
      return origin;
    },
  });
  assert.throws(() => fixture({ origins }), { code: "invalid_input" });
  assert.equal(invoked, false);
});

// These injected responses exercise a supported contract; they do not establish
// the shape of a native GitHub tag dispatch or authenticate historical execution.
const tagName = "review-probe-v1.0";
const workflowRef = `refs/tags/${tagName}`;
const refRoot = "https://api.github.com/repos/example/reviewer/git";
const tagURL = `${refRoot}/ref/tags/${tagName}`;
const branchURL = `${refRoot}/ref/heads/${tagName}`;
const firstAttemptURL = `${runURL}/attempts/1`;
const tagSelector = () => ({ ...selector(), runAttempt: 1 });
const tagProducer = () => ({ ...producer(), workflowRef });
function tagRef() {
  return {
    ref: workflowRef,
    url: `${refRoot}/${workflowRef}`,
    object: {
      type: "commit",
      sha: revision,
      url: `${refRoot}/commits/${revision}`,
    },
  };
}
function tagRun() {
  return {
    ...run(),
    run_attempt: 1,
    head_branch: tagName,
    path: `${producer().workflowPath}@${tagName}`,
  };
}
function tagFixture(options = {}) {
  return fixture({
    ...options,
    producer: options.producer ?? tagProducer(),
    respond: async (request) => {
      const custom = await options.respond?.(request);
      if (custom !== undefined) return custom;
      if (request.url === tagURL) return json(tagRef());
      if (request.url === branchURL) return new Response(null, { status: 404 });
      if (request.url === runURL || request.url === firstAttemptURL)
        return json(tagRun());
    },
  });
}
const tagFails = (client, code, options) =>
  fails(client, code, tagSelector(), options);

test("tag opt-in binds exact current lightweight ref before and after the complete artifact read", async () => {
  const f = tagFixture();
  assert.equal(f.credentialCalls(), 0);
  assert.deepEqual(f.calls, []);
  const result = await f.client.read(tagSelector());
  assert.deepEqual(
    f.calls.map(({ url }) => url),
    [
      tagURL,
      branchURL,
      runURL,
      firstAttemptURL,
      artifactURL,
      zipURL,
      signedURL,
      runURL,
      artifactURL,
      tagURL,
      branchURL,
    ],
  );
  assert.deepEqual(result.currentTagRefSnapshot, {
    ref: workflowRef,
    sha: revision,
  });
  assert.ok(Object.isFrozen(result.currentTagRefSnapshot));
  assert.equal(result.producer.workflowRef, workflowRef);
  assert.equal(result.run.attempt, 1);
  assert.equal(result.artifactAttemptAuthenticated, false);
  assert.equal(result.executionComparisonAuthenticated, false);
  assert.equal(result.enforcementPublished, false);
  assert.equal(Object.hasOwn(result, "historicalRefAuthenticated"), false);
  assert.equal(Object.hasOwn(result, "executionAuthenticated"), false);
  assert.equal(f.credentialCalls(), 1);
  for (const { url, init } of f.calls) {
    assert.equal(init.method, "GET");
    assert.equal(init.redirect, "manual");
    if (url === signedURL)
      assert.deepEqual(init.headers, { accept: "application/octet-stream" });
    else assert.equal(init.headers.authorization, "Bearer synthetic-token");
  }
});
test("tag opt-in accepts only the other explicitly enumerated full-ref path spelling", async () => {
  const f = tagFixture({
    respond: ({ url }) =>
      url === runURL || url === firstAttemptURL
        ? json({
            ...tagRun(),
            path: `${producer().workflowPath}@${workflowRef}`,
          })
        : undefined,
  });
  const result = await f.client.read(tagSelector());
  assert.equal(
    result.run.workflowPath,
    `${producer().workflowPath}@${workflowRef}`,
  );
  assert.deepEqual(result.currentTagRefSnapshot, {
    ref: workflowRef,
    sha: revision,
  });
});
test("callers without workflowRef retain their old request sequence and result shape", async () => {
  const f = fixture();
  const result = await f.client.read(selector());
  assert.equal(Object.hasOwn(result, "currentTagRefSnapshot"), false);
  assert.equal(Object.hasOwn(result.producer, "workflowRef"), false);
  assert.deepEqual(
    f.calls.map(({ url }) => url),
    [runURL, attemptURL, artifactURL, zipURL, signedURL, runURL, artifactURL],
  );
});
test("opt-in workflowRef is copied at construction and must be an inert property", async () => {
  const p = tagProducer();
  const f = tagFixture({ producer: p });
  p.workflowRef = "refs/tags/other";
  assert.deepEqual((await f.client.read(tagSelector())).currentTagRefSnapshot, {
    ref: workflowRef,
    sha: revision,
  });
  let invoked = false;
  const accessor = producer();
  Object.defineProperty(accessor, "workflowRef", {
    enumerable: true,
    get() {
      invoked = true;
      return workflowRef;
    },
  });
  assert.throws(() => tagFixture({ producer: accessor }), {
    code: "invalid_input",
  });
  assert.equal(invoked, false);
});
for (const unsafe of [
  undefined,
  "refs/heads/review",
  "refs/tags/",
  "refs/tags/nested/name",
  "refs/tags/a..b",
  "refs/tags/a.lock",
  "refs/tags/a.",
  "refs/tags/a@b",
  "refs/tags/a%2fb",
  "refs/tags/a\nb",
  `refs/tags/${"a".repeat(65)}`,
]) {
  test(`refuses unsafe workflowRef configuration (${String(unsafe).length})`, () => {
    assert.throws(
      () => tagFixture({ producer: { ...producer(), workflowRef: unsafe } }),
      { code: "invalid_input" },
    );
  });
}
test("tag opt-in refuses rerun selectors before credential access", async () => {
  const f = tagFixture();
  await fails(f.client, "unsupported_run_attempt", selector());
  assert.equal(f.credentialCalls(), 0);
  assert.deepEqual(f.calls, []);
});
const refMutations = [
  [
    "wrong ref",
    (ref) => {
      ref.ref = "refs/tags/other";
    },
  ],
  [
    "wrong SHA",
    (ref) => {
      ref.object.sha = "b".repeat(40);
    },
  ],
  [
    "annotated tag",
    (ref) => {
      ref.object.type = "tag";
    },
  ],
  [
    "wrong ref repository",
    (ref) => {
      ref.url = ref.url.replace("example/reviewer", "other/reviewer");
    },
  ],
  [
    "wrong object repository",
    (ref) => {
      ref.object.url = ref.object.url.replace(
        "example/reviewer",
        "other/reviewer",
      );
    },
  ],
  [
    "wrong object URL SHA",
    (ref) => {
      ref.object.url = `${refRoot}/commits/${"b".repeat(40)}`;
    },
  ],
];
for (const [name, mutate] of refMutations) {
  test(`refuses tag metadata ${name}`, async () => {
    const f = tagFixture({
      respond: ({ url }) => {
        if (url !== tagURL) return;
        const ref = tagRef();
        mutate(ref);
        return json(ref);
      },
    });
    await tagFails(f.client, "workflow_ref_binding_mismatch");
    assert.equal(f.calls.length, 1);
  });
}
test("tag opt-in rejects a same-name branch even when both refs point at the approved SHA", async () => {
  const f = tagFixture({
    respond: ({ url }) =>
      url === branchURL
        ? json({ ...tagRef(), ref: `refs/heads/${tagName}` })
        : undefined,
  });
  await tagFails(f.client, "ambiguous_workflow_ref");
  assert.equal(f.calls.length, 2);
});
for (const path of [
  producer().workflowPath,
  `${producer().workflowPath}@${revision}`,
  `${producer().workflowPath}@other`,
  `${producer().workflowPath}@refs/heads/${tagName}`,
  `${producer().workflowPath}@${tagName}@other`,
]) {
  test(`opt-in refuses unbound path spelling (${path.length})`, async () => {
    const f = tagFixture({
      respond: ({ url }) =>
        url === runURL ? json({ ...tagRun(), path }) : undefined,
    });
    await tagFails(f.client, "unsupported_execution");
  });
}
test("tag run head_branch must exactly equal the bound tag name", async () => {
  for (const head_branch of [undefined, "other", workflowRef]) {
    const f = tagFixture({
      respond: ({ url }) =>
        url === runURL ? json({ ...tagRun(), head_branch }) : undefined,
    });
    await tagFails(f.client, "unsupported_execution");
  }
});
test("tag current run and selected attempt must both remain first-attempt success", async () => {
  for (const changedURL of [runURL, firstAttemptURL]) {
    const f = tagFixture({
      respond: ({ url }) =>
        url === changedURL ? json({ ...tagRun(), run_attempt: 2 }) : undefined,
    });
    await tagFails(f.client, "run_not_current_success");
  }
});
test("tag mode retains authenticated numeric run repository binding", async () => {
  const f = tagFixture({
    respond: ({ url }) =>
      url === runURL
        ? json({
            ...tagRun(),
            repository: { id: 12, full_name: producer().repository },
          })
        : undefined,
  });
  await tagFails(f.client, "run_binding_mismatch");
});
for (const [name, response, code] of [
  [
    "tag deleted",
    () => new Response(null, { status: 404 }),
    "metadata_http_error",
  ],
  [
    "tag moved",
    () =>
      json({
        ...tagRef(),
        object: { ...tagRef().object, sha: "b".repeat(40) },
      }),
    "workflow_ref_binding_mismatch",
  ],
  [
    "tag replaced by annotated tag",
    () => json({ ...tagRef(), object: { ...tagRef().object, type: "tag" } }),
    "workflow_ref_binding_mismatch",
  ],
]) {
  test(`refuses post-download race: ${name}`, async () => {
    const f = tagFixture({
      respond: ({ url, count }) =>
        url === tagURL && count === 2 ? response() : undefined,
    });
    await tagFails(f.client, code);
    assert.equal(f.calls.at(-1).url, tagURL);
    assert.equal(f.calls.length, 10);
  });
}
test("refuses a same-name branch appearing during artifact download", async () => {
  const f = tagFixture({
    respond: ({ url, count }) =>
      url === branchURL && count === 2
        ? json({ ...tagRef(), ref: `refs/heads/${tagName}` })
        : undefined,
  });
  await tagFails(f.client, "ambiguous_workflow_ref");
  assert.equal(f.calls.length, 11);
});
test("refuses a rerun beginning while the tag-bound archive is downloaded", async () => {
  const f = tagFixture({
    respond: ({ url, count }) =>
      url === runURL && count === 2
        ? json({ ...tagRun(), run_attempt: 2 })
        : undefined,
  });
  await tagFails(f.client, "run_not_current_success");
});
test("fresh reads cannot switch even between supported path spellings", async () => {
  const f = tagFixture({
    respond: ({ url, count }) =>
      url === runURL && count === 2
        ? json({
            ...tagRun(),
            path: `${producer().workflowPath}@${workflowRef}`,
          })
        : undefined,
  });
  await tagFails(f.client, "metadata_changed");
});
test("tag and branch endpoints reject redirects without forwarding any credential", async () => {
  for (const endpoint of [tagURL, branchURL]) {
    const f = tagFixture({
      respond: ({ url }) =>
        url === endpoint
          ? new Response(null, {
              status: 302,
              headers: { location: signedURL },
            })
          : undefined,
    });
    await tagFails(f.client, "metadata_http_error");
    assert.equal(
      f.calls.some(({ url }) => url === signedURL),
      false,
    );
  }
});
test("non404 branch failures are not treated as authenticated absence", async () => {
  for (const status of [401, 403, 409, 500]) {
    const f = tagFixture({
      respond: ({ url }) =>
        url === branchURL
          ? new Response("private failure body", { status })
          : undefined,
    });
    await tagFails(f.client, "metadata_http_error");
  }
});
test("tag metadata shares streaming caps and cancellation with the entire read", async () => {
  let cancelled = false;
  const f = tagFixture({
    respond: ({ url }) =>
      url === tagURL
        ? new Response(
            new ReadableStream({
              start(controller) {
                controller.enqueue(
                  Buffer.alloc(GITHUB_ARTIFACT_LIMITS.metadataBytes + 1),
                );
              },
              cancel() {
                cancelled = true;
              },
            }),
          )
        : undefined,
  });
  await tagFails(f.client, "response_limit");
  assert.equal(cancelled, true);
});
test("deadline includes the final tag recheck and cancels stalled metadata", async () => {
  let cancelled = false;
  const f = tagFixture({
    respond: ({ url, count }) =>
      url === tagURL && count === 2
        ? new Response(
            new ReadableStream({
              cancel() {
                cancelled = true;
              },
            }),
          )
        : undefined,
  });
  await tagFails(f.client, "deadline_exceeded", { deadlineMs: 25 });
  assert.equal(cancelled, true);
  assert.equal(f.calls.length, 10);
});
test("parent abort cancels the initial tag request before any run lookup", async () => {
  let cancelled = false;
  const controller = new AbortController();
  const f = tagFixture({
    respond: ({ url }) => {
      if (url !== tagURL) return;
      setTimeout(() => controller.abort(new Error("private reason")), 10);
      return new Response(
        new ReadableStream({
          cancel() {
            cancelled = true;
          },
        }),
      );
    },
  });
  await tagFails(f.client, "aborted", { signal: controller.signal });
  assert.equal(cancelled, true);
  assert.equal(f.calls.length, 1);
});
