// Disconnected GitHub transport. These facts do NOT attest the reviewed commit
// pair, receipt completeness, or even the artifact's producing run attempt.
import { createHash } from "node:crypto";
import { performance } from "node:perf_hooks";

export const GITHUB_ARTIFACT_LIMITS = Object.freeze({
  metadataBytes: 65536,
  archiveBytes: 262144,
  deadlineMs: 2000,
  maximumDeadlineMs: 10000,
});
const API = "https://api.github.com";
const VERSION = "2026-03-10";
const PRODUCER_FIELDS = [
  "repository", "repositoryId", "workflowId", "workflowPath",
  "workflowRevision", "artifactName",
];
class ArtifactError extends Error {
  constructor(code) {
    super(`GitHub artifact: ${code}`);
    this.name = "GitHubArtifactError";
    this.code = code;
  }
}
function requireThat(condition, code) {
  if (!condition) throw new ArtifactError(code);
}
function positive(value) {
  return Number.isSafeInteger(value) && value > 0;
}
function record(value, fields) {
  requireThat(value && [Object.prototype, null].includes(Object.getPrototypeOf(value)), "invalid_input");
  const descriptors = Object.getOwnPropertyDescriptors(value);
  const keys = Reflect.ownKeys(descriptors);
  requireThat(keys.length === fields.length && keys.every((key) => fields.includes(key)), "invalid_input");
  const result = {};
  for (const key of keys) {
    const descriptor = descriptors[key];
    requireThat(descriptor.enumerable && Object.hasOwn(descriptor, "value"), "invalid_input");
    result[key] = descriptor.value;
  }
  return result;
}
function producerCopy(value) {
  const p = record(value, PRODUCER_FIELDS);
  requireThat(typeof p.repository === "string" && /^[A-Za-z0-9][A-Za-z0-9-]{0,38}\/[A-Za-z0-9_.-]{1,100}$/.test(p.repository) && ![".", ".."].includes(p.repository.split("/")[1]), "invalid_input");
  requireThat(positive(p.repositoryId) && positive(p.workflowId), "invalid_input");
  requireThat(typeof p.workflowPath === "string" && /^\.github\/workflows\/[A-Za-z0-9_-]+\.ya?ml$/.test(p.workflowPath), "invalid_input");
  requireThat(typeof p.workflowRevision === "string" && /^[a-f0-9]{40}$/.test(p.workflowRevision), "invalid_input");
  requireThat(typeof p.artifactName === "string" && /^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\.json$/.test(p.artifactName), "invalid_input");
  return Object.freeze(p);
}
function storageURL(value) {
  requireThat(typeof value === "string" && value.length <= 8192 && !/[\s\\#]/.test(value), "invalid_download_url");
  let url;
  try { url = new URL(value); } catch { throw new ArtifactError("invalid_download_url"); }
  const authority = value.match(/^[^:]+:\/\/([^/?#]*)/)?.[1];
  requireThat(url.protocol === "https:" && !url.username && !url.password && !url.hash && !url.port && url.hostname && url.origin !== API && typeof authority === "string" && !authority.includes("@"), "invalid_download_url");
  return url;
}
function originsCopy(value) {
  requireThat(Array.isArray(value) && Object.getPrototypeOf(value) === Array.prototype && value.length > 0 && value.length <= 8, "invalid_input");
  const descriptors = Object.getOwnPropertyDescriptors(value);
  requireThat(Reflect.ownKeys(descriptors).length === value.length + 1, "invalid_input");
  const origins = new Set();
  for (let index = 0; index < value.length; index++) {
    const descriptor = descriptors[index];
    requireThat(descriptor?.enumerable && Object.hasOwn(descriptor, "value"), "invalid_input");
    const url = storageURL(descriptor.value);
    requireThat(descriptor.value === url.origin && !origins.has(url.origin), "invalid_input");
    origins.add(url.origin);
  }
  return origins;
}
function date(value) {
  requireThat(typeof value === "string" && /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/.test(value) && Number.isFinite(Date.parse(value)), "invalid_metadata");
  return value;
}
function runFacts(raw, producer, selector) {
  requireThat(raw?.id === selector.runId && raw.workflow_id === producer.workflowId && raw.repository?.id === producer.repositoryId && raw.repository?.full_name === producer.repository && raw.head_repository?.id === producer.repositoryId && raw.head_repository?.full_name === producer.repository && raw.head_sha === producer.workflowRevision, "run_binding_mismatch");
  requireThat(raw.run_attempt === selector.runAttempt && raw.status === "completed" && raw.conclusion === "success", "run_not_current_success");
  // Direct dispatch is the only supported execution mode. A mutable path suffix
  // or any reusable workflow needs a separately authenticated execution chain.
  requireThat(raw.event === "workflow_dispatch" && (raw.path === producer.workflowPath || raw.path === `${producer.workflowPath}@${producer.workflowRevision}`) && Array.isArray(raw.referenced_workflows) && raw.referenced_workflows.length === 0 && Array.isArray(raw.pull_requests) && raw.pull_requests.length === 0, "unsupported_execution");
  return Object.freeze({
    id: raw.id,
    attempt: raw.run_attempt,
    repository: producer.repository,
    repositoryId: raw.repository.id,
    workflowId: raw.workflow_id,
    workflowPath: raw.path,
    headSha: raw.head_sha,
    event: raw.event,
    status: raw.status,
    conclusion: raw.conclusion,
    createdAt: date(raw.created_at),
    updatedAt: date(raw.updated_at),
    startedAt: date(raw.run_started_at),
  });
}
function artifactFacts(raw, producer, selector, run) {
  requireThat(raw?.id === selector.artifactId && raw.name === producer.artifactName && raw.workflow_run?.id === selector.runId && raw.workflow_run.repository_id === producer.repositoryId && raw.workflow_run.head_repository_id === producer.repositoryId && raw.workflow_run.head_sha === producer.workflowRevision, "artifact_binding_mismatch");
  requireThat(raw.expired === false && Date.parse(date(raw.expires_at)) > Date.now(), "artifact_expired");
  requireThat(positive(raw.size_in_bytes) && raw.size_in_bytes <= GITHUB_ARTIFACT_LIMITS.archiveBytes, "archive_limit");
  requireThat(typeof raw.digest === "string" && /^sha256:[a-f0-9]{64}$/.test(raw.digest), "archive_digest_missing");
  const createdAt = date(raw.created_at);
  const updatedAt = date(raw.updated_at);
  requireThat(Date.parse(createdAt) >= Date.parse(run.createdAt) && Date.parse(updatedAt) >= Date.parse(createdAt), "artifact_binding_mismatch");
  return Object.freeze({
    id: raw.id,
    name: raw.name,
    archiveByteLength: raw.size_in_bytes,
    archiveSha256: raw.digest.slice(7),
    runId: raw.workflow_run.id,
    repositoryId: raw.workflow_run.repository_id,
    headRepositoryId: raw.workflow_run.head_repository_id,
    headSha: raw.workflow_run.head_sha,
    createdAt,
    updatedAt,
    expiresAt: raw.expires_at,
  });
}
function same(left, right) {
  requireThat(JSON.stringify(left) === JSON.stringify(right), "metadata_changed");
}
function deadlineScope(signal, milliseconds) {
  const controller = new AbortController();
  const deadline = performance.now() + milliseconds;
  let reason;
  let rejectStop;
  const stopped = new Promise((_, reject) => { rejectStop = reject; });
  // The caller may already be aborted before the first raced operation.
  stopped.catch(() => {});
  function stop(code) {
    if (reason) return;
    reason = new ArtifactError(code);
    controller.abort();
    rejectStop(reason);
  }
  const onAbort = () => stop("aborted");
  if (signal) signal.addEventListener("abort", onAbort, { once: true });
  if (signal?.aborted) onAbort();
  const timer = setTimeout(() => stop("deadline_exceeded"), milliseconds);
  function check() {
    if (!reason && performance.now() >= deadline) stop("deadline_exceeded");
    if (reason) throw reason;
  }
  return {
    signal: controller.signal,
    check,
    async wait(operation) {
      check();
      const result = await Promise.race([Promise.resolve().then(operation), stopped]);
      check();
      return result;
    },
    close() {
      clearTimeout(timer);
      signal?.removeEventListener("abort", onAbort);
      controller.abort();
    },
  };
}
function cancelBody(response) {
  // Cancellation is best effort and never allowed to extend the call deadline.
  try { Promise.resolve(response?.body?.cancel()).catch(() => {}); } catch { /* sanitized */ }
}
async function bytes(response, maximum, scope) {
  let reader;
  let finished = false;
  try {
    const encoding = response.headers.get("content-encoding")?.trim().toLowerCase();
    requireThat(encoding === undefined || ["identity", "gzip", "deflate", "br"].includes(encoding), "unsupported_response_encoding");
    const decoded = encoding !== undefined && encoding !== "identity";
    // Native Node fetch decodes these content codings while retaining the wire
    // Content-Length. Bound both declared wire size and streamed decoded bytes;
    // only an identity representation has comparable wire and stream lengths.
    const length = response.headers.get("content-length");
    requireThat(length === null || (/^\d+$/.test(length) && Number(length) <= maximum), "response_limit");
    requireThat(response.body && typeof response.body.getReader === "function", "invalid_response");
    reader = response.body.getReader();
    let total = 0;
    const chunks = [];
    while (true) {
      const { done, value } = await scope.wait(() => reader.read());
      if (done) break;
      requireThat(value instanceof Uint8Array && !(value.buffer instanceof SharedArrayBuffer), "invalid_response");
      total += value.byteLength;
      requireThat(total <= maximum, "response_limit");
      chunks.push(Buffer.from(value));
    }
    requireThat(total > 0 && (decoded || length === null || Number(length) === total), "response_length_mismatch");
    finished = true;
    return Buffer.concat(chunks, total);
  } finally {
    if (!finished) {
      if (reader) {
        try { Promise.resolve(reader.cancel()).catch(() => {}); } catch { /* sanitized */ }
      } else cancelBody(response);
    }
    try { reader?.releaseLock(); } catch { /* sanitized */ }
  }
}

/** No I/O before read(). tokenProvider and fetchImpl must themselves be trusted.
 * fetchImpl must follow native Node fetch's decoded-response stream contract.
 * Supported HTTP content codings are identity, gzip, deflate and br (one only).
 * downloadOrigins is an exact administrator-selected origin list, never a URL
 * list extracted from a receipt or PR. No target/intake metadata is returned.
 */
export function createGitHubArtifactClient({ producer, tokenProvider, downloadOrigins, fetchImpl = globalThis.fetch }) {
  let trustedProducer;
  let origins;
  try {
    trustedProducer = producerCopy(producer);
    origins = originsCopy(downloadOrigins);
    requireThat(typeof tokenProvider === "function" && typeof fetchImpl === "function", "invalid_input");
  } catch (error) {
    if (error instanceof ArtifactError) throw error;
    throw new ArtifactError("invalid_input");
  }
  return Object.freeze({
    async read(input, { signal, deadlineMs = GITHUB_ARTIFACT_LIMITS.deadlineMs } = {}) {
      let scope;
      let token;
      try {
        const selector = Object.freeze(record(input, ["runId", "runAttempt", "artifactId"]));
        requireThat(Object.values(selector).every(positive), "invalid_input");
        requireThat(Number.isSafeInteger(deadlineMs) && deadlineMs > 0 && deadlineMs <= GITHUB_ARTIFACT_LIMITS.maximumDeadlineMs, "invalid_input");
        requireThat(signal === undefined || signal instanceof AbortSignal, "invalid_input");
        scope = deadlineScope(signal, deadlineMs);
        try {
          token = await scope.wait(() => tokenProvider(Object.freeze({ repository: trustedProducer.repository, repositoryId: trustedProducer.repositoryId, signal: scope.signal })));
        } catch (error) {
          scope.check();
          throw new ArtifactError("credential_unavailable");
        }
        requireThat(typeof token === "string" && token.length > 0 && token.length <= 8192 && /^[A-Za-z0-9_.-]+$/.test(token), "credential_unavailable");
        const base = `${API}/repos/${trustedProducer.repository}/actions`;
        const runURL = `${base}/runs/${selector.runId}`;
        const attemptURL = `${runURL}/attempts/${selector.runAttempt}`;
        const artifactURL = `${base}/artifacts/${selector.artifactId}`;
        async function request(url, authenticated) {
          let response;
          try {
            response = await scope.wait(async () => {
              const received = await fetchImpl(url, {
              method: "GET",
              redirect: "manual",
              credentials: "omit",
              referrerPolicy: "no-referrer",
              cache: "no-store",
              signal: scope.signal,
              headers: authenticated ? {
                accept: "application/vnd.github+json",
                authorization: `Bearer ${token}`,
                "x-github-api-version": VERSION,
              } : { accept: "application/octet-stream" },
              });
              response = received;
              // A trusted transport may still settle after cancellation. Do not
              // leave such a late response's body/socket unconsumed and open.
              if (scope.signal.aborted) cancelBody(received);
              return received;
            });
          } catch {
            cancelBody(response);
            scope.check();
            throw new ArtifactError("request_failed");
          }
          if (!response || response.redirected || (response.url && response.url !== url)) {
            cancelBody(response);
            throw new ArtifactError("unexpected_redirect");
          }
          return response;
        }
        async function metadata(url) {
          const response = await request(url, true);
          if (response.status !== 200) {
            cancelBody(response);
            throw new ArtifactError("metadata_http_error");
          }
          const raw = await bytes(response, GITHUB_ARTIFACT_LIMITS.metadataBytes, scope);
          try { return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(raw)); }
          catch { throw new ArtifactError("invalid_metadata"); }
        }
        const run = runFacts(await metadata(runURL), trustedProducer, selector);
        same(runFacts(await metadata(attemptURL), trustedProducer, selector), run);
        const artifact = artifactFacts(await metadata(artifactURL), trustedProducer, selector, run);
        let archiveResponse = await request(`${artifactURL}/zip`, true);
        if (archiveResponse.status === 302) {
          let location;
          try {
            location = storageURL(archiveResponse.headers.get("location"));
            requireThat(origins.has(location.origin), "untrusted_download_origin");
          } finally { cancelBody(archiveResponse); }
          archiveResponse = await request(location.href, false);
        }
        if (archiveResponse.status !== 200) {
          cancelBody(archiveResponse);
          throw new ArtifactError("archive_http_error");
        }
        const archive = await bytes(archiveResponse, GITHUB_ARTIFACT_LIMITS.archiveBytes, scope);
        requireThat(archive.length === artifact.archiveByteLength, "archive_length_mismatch");
        requireThat(createHash("sha256").update(archive).digest("hex") === artifact.archiveSha256, "archive_digest_mismatch");
        // upload-artifact can also publish raw files. This transport supports
        // ZIP only; the separate extractor must validate the entire structure.
        requireThat(archive.length >= 4 && archive.readUInt32LE(0) === 0x04034b50, "unsupported_archive_format");
        same(runFacts(await metadata(runURL), trustedProducer, selector), run);
        same(artifactFacts(await metadata(artifactURL), trustedProducer, selector, run), artifact);
        scope.check();
        return Object.freeze({
          schemaVersion: 1,
          producer: trustedProducer,
          run,
          artifact,
          get archiveBytes() { return Buffer.from(archive); },
          artifactAttemptAuthenticated: false,
          executionComparisonAuthenticated: false,
          enforcementPublished: false,
        });
      } catch (error) {
        if (error instanceof ArtifactError) throw error;
        throw new ArtifactError("read_failed");
      } finally {
        token = undefined;
        scope?.close();
      }
    },
  });
}
