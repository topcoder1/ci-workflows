// Local, data-only comparison measurement. No GitHub identity, reviewer result,
// publication authority or executed-code provenance is inferred from this data.
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { lstat, realpath } from "node:fs/promises";
import { isAbsolute, join } from "node:path";
import { performance } from "node:perf_hooks";

export const REVIEW_COMPARISON_LIMITS = Object.freeze({
  files: 32,
  pathBytes: 1024,
  blobBytes: 65536,
  contentBytes: 262144,
  commitBytes: 16384,
  inventoryBytes: 65536,
  subprocessBytes: 393216,
  stderrBytes: 8192,
  packetBytes: 524288,
  deadlineMs: 5000,
  maximumDeadlineMs: 10000,
});
const SHA = /^[a-f0-9]{40}$/;
const ZERO = "0".repeat(40);
const CONTROL = /[\u0000-\u001f\u007f-\u009f\u202a-\u202e\u2066-\u2069]/;
const GIT = "/usr/bin/git";
const ENV = Object.freeze({
  PATH: "/usr/bin:/bin",
  LANG: "C",
  LC_ALL: "C",
  GIT_CONFIG_NOSYSTEM: "1",
  GIT_CONFIG_SYSTEM: "/dev/null",
  GIT_CONFIG_GLOBAL: "/dev/null",
  GIT_ATTR_NOSYSTEM: "1",
  GIT_NO_REPLACE_OBJECTS: "1",
  GIT_NO_LAZY_FETCH: "1",
  GIT_ALLOW_PROTOCOL: "",
  GIT_TERMINAL_PROMPT: "0",
  GIT_OPTIONAL_LOCKS: "0",
});
const PREFIX = Object.freeze([
  "--no-pager", "--no-replace-objects", "--no-lazy-fetch", "--literal-pathspecs",
  "-c", "protocol.allow=never",
  "-c", "core.hooksPath=/dev/null",
  "-c", "core.attributesFile=/dev/null",
  "-c", "core.fsmonitor=false",
  "-c", "core.commitGraph=false",
]);
class ComparisonError extends Error {
  constructor(code) {
    super(`Review comparison: ${code}`);
    this.name = "ReviewComparisonError";
    this.code = code;
  }
}
function requireThat(condition, code) {
  if (!condition) throw new ComparisonError(code);
}
function inputRecord(input, fields, optional = []) {
  requireThat(input && [Object.prototype, null].includes(Object.getPrototypeOf(input)), "invalid_input");
  const descriptors = Object.getOwnPropertyDescriptors(input);
  const keys = Reflect.ownKeys(descriptors);
  requireThat(fields.every((key) => keys.includes(key)) && keys.every((key) => fields.includes(key) || optional.includes(key)), "invalid_input");
  const copy = {};
  for (const key of keys) {
    const descriptor = descriptors[key];
    requireThat(descriptor.enumerable && Object.hasOwn(descriptor, "value"), "invalid_input");
    copy[key] = descriptor.value;
  }
  return copy;
}
function utf8(bytes, code) {
  try {
    const text = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(bytes);
    requireThat(Buffer.from(text).equals(bytes), code);
    return text;
  } catch { throw new ComparisonError(code); }
}
function digest(bytes, algorithm = "sha256") {
  return createHash(algorithm).update(bytes).digest("hex");
}
function kill(child) {
  if (!child?.pid) return;
  // Every child owns a fresh process group. Never signal the caller's group.
  try { process.kill(-child.pid, "SIGKILL"); }
  catch { try { child.kill("SIGKILL"); } catch { /* sanitized */ } }
}
function operationScope(signal, milliseconds) {
  const deadline = performance.now() + milliseconds;
  const children = new Set();
  let reason;
  let byteCount = 0;
  let rejectStop;
  const stopped = new Promise((_, reject) => { rejectStop = reject; });
  stopped.catch(() => {});
  function stop(code) {
    if (reason) return;
    reason = new ComparisonError(code);
    for (const child of children) kill(child);
    rejectStop(reason);
  }
  const onAbort = () => stop("aborted");
  signal?.addEventListener("abort", onAbort, { once: true });
  if (signal?.aborted) onAbort();
  const timer = setTimeout(() => stop("deadline_exceeded"), milliseconds);
  function check() {
    if (!reason && performance.now() >= deadline) stop("deadline_exceeded");
    if (reason) throw reason;
  }
  return {
    check,
    add(child) { children.add(child); },
    remove(child) { children.delete(child); },
    count(bytes) {
      byteCount += bytes;
      if (byteCount > REVIEW_COMPARISON_LIMITS.subprocessBytes) stop("subprocess_output_limit");
      check();
    },
    async wait(operation) {
      check();
      const result = await Promise.race([Promise.resolve().then(operation), stopped]);
      check();
      return result;
    },
    close() {
      clearTimeout(timer);
      signal?.removeEventListener("abort", onAbort);
      for (const child of children) kill(child);
    },
  };
}
async function git(repositoryPath, args, scope, maximumBytes, stdin = "", accepted = [0]) {
  return scope.wait(() => new Promise((resolve, reject) => {
    scope.check();
    const chunks = [];
    let stdoutBytes = 0;
    let stderrBytes = 0;
    let failure;
    let child;
    function fail(code) {
      failure ??= new ComparisonError(code);
      kill(child);
      reject(failure);
    }
    try {
      child = spawn(GIT, [...PREFIX, ...args], {
        cwd: repositoryPath,
        env: { ...ENV },
        shell: false,
        detached: true,
        stdio: ["pipe", "pipe", "pipe"],
      });
      scope.add(child);
    } catch { fail("git_unavailable"); return; }
    child.on("error", () => fail("git_unavailable"));
    child.stdin.on("error", () => fail("git_io_failed"));
    child.stdout.on("error", () => fail("git_io_failed"));
    child.stderr.on("error", () => fail("git_io_failed"));
    child.stdout.on("data", (chunk) => {
      if (failure) return;
      try {
        scope.count(chunk.length);
        stdoutBytes += chunk.length;
        requireThat(stdoutBytes <= maximumBytes, "subprocess_output_limit");
        chunks.push(Buffer.from(chunk));
      } catch (error) { fail(error instanceof ComparisonError ? error.code : "git_io_failed"); }
    });
    child.stderr.on("data", (chunk) => {
      if (failure) return;
      try {
        scope.count(chunk.length);
        stderrBytes += chunk.length;
        requireThat(stderrBytes <= REVIEW_COMPARISON_LIMITS.stderrBytes, "subprocess_output_limit");
      } catch (error) { fail(error instanceof ComparisonError ? error.code : "git_io_failed"); }
    });
    child.on("close", (code) => {
      scope.remove(child);
      if (failure) return;
      if (!accepted.includes(code)) { fail("git_command_failed"); return; }
      resolve({ bytes: Buffer.concat(chunks, stdoutBytes), exitCode: code });
    });
    child.stdin.end(stdin);
  }));
}
function parseBatch(bytes, ids, type, maximumBytes) {
  const result = new Map();
  let position = 0;
  for (const id of ids) {
    const newline = bytes.indexOf(10, position);
    requireThat(newline >= position && newline - position <= 100, "invalid_git_objects");
    const header = bytes.subarray(position, newline).toString("ascii");
    const match = /^([a-f0-9]{40}) (blob|commit) (0|[1-9][0-9]*)$/.exec(header);
    requireThat(match && match[1] === id && match[2] === type, "invalid_git_objects");
    const size = Number(match[3]);
    requireThat(Number.isSafeInteger(size) && size <= maximumBytes, "object_limit");
    const start = newline + 1;
    const end = start + size;
    requireThat(end < bytes.length && bytes[end] === 10, "invalid_git_objects");
    const content = bytes.subarray(start, end);
    const objectHash = createHash("sha1").update(`${type} ${size}\0`).update(content).digest("hex");
    requireThat(objectHash === id, "object_digest_mismatch");
    result.set(id, Buffer.from(content));
    position = end + 1;
  }
  requireThat(position === bytes.length, "invalid_git_objects");
  return result;
}
function inventory(bytes) {
  if (bytes.length === 0) return [];
  requireThat(bytes.at(-1) === 0, "invalid_inventory");
  const fields = [];
  let start = 0;
  for (let index = 0; index < bytes.length; index++) {
    if (bytes[index] !== 0) continue;
    fields.push(bytes.subarray(start, index));
    start = index + 1;
    requireThat(fields.length <= REVIEW_COMPARISON_LIMITS.files * 2, "file_limit");
  }
  requireThat(fields.length % 2 === 0, "invalid_inventory");
  const entries = [];
  const names = new Set();
  for (let index = 0; index < fields.length; index += 2) {
    const match = /^:([0-7]{6}) ([0-7]{6}) ([a-f0-9]{40}) ([a-f0-9]{40}) ([AMDT])$/.exec(fields[index].toString("ascii"));
    requireThat(match, "invalid_inventory");
    const [, beforeMode, afterMode, beforeOid, afterOid, status] = match;
    requireThat(["000000", "100644", "100755"].includes(beforeMode) && ["000000", "100644", "100755"].includes(afterMode), "unsupported_file_mode");
    requireThat((beforeMode === "000000") === (beforeOid === ZERO) && (afterMode === "000000") === (afterOid === ZERO), "invalid_inventory");
    requireThat((status === "A" && beforeOid === ZERO && afterOid !== ZERO) || (status === "D" && beforeOid !== ZERO && afterOid === ZERO) || (status === "M" && beforeOid !== ZERO && afterOid !== ZERO), "invalid_inventory");
    const pathBytes = fields[index + 1];
    requireThat(pathBytes.length > 0 && pathBytes.length <= REVIEW_COMPARISON_LIMITS.pathBytes, "unsupported_path");
    const path = utf8(pathBytes, "unsupported_path");
    requireThat(!CONTROL.test(path) && !path.includes("\\") && !path.includes("\uFEFF") && path.split("/").every((part) => part && part !== "." && part !== "..") && !names.has(path), "unsupported_path");
    names.add(path);
    entries.push({ path, status, beforeMode, afterMode, beforeOid, afterOid });
  }
  return entries.sort((a, b) => Buffer.compare(Buffer.from(a.path), Buffer.from(b.path)));
}
function blobSizes(bytes, ids) {
  const lines = bytes.toString("ascii").split("\n");
  requireThat(lines.pop() === "" && lines.length === ids.length, "invalid_git_objects");
  const sizes = new Map();
  for (let index = 0; index < ids.length; index++) {
    const match = /^([a-f0-9]{40}) blob (0|[1-9][0-9]*)$/.exec(lines[index]);
    requireThat(match && match[1] === ids[index], "invalid_git_objects");
    const size = Number(match[2]);
    requireThat(Number.isSafeInteger(size) && size <= REVIEW_COMPARISON_LIMITS.blobBytes, "blob_limit");
    sizes.set(ids[index], size);
  }
  return sizes;
}
function snapshot(oid, mode, blobs, sizes) {
  if (oid === ZERO) return null;
  const bytes = blobs.get(oid);
  requireThat(bytes && bytes.length === sizes.get(oid), "object_changed");
  const text = utf8(bytes, "unsupported_binary");
  requireThat(!/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f-\u009f]/.test(text), "unsupported_binary");
  return Object.freeze({ oid, mode, byteLength: bytes.length, sha256: digest(bytes), text });
}

/** Measure exact local SHA-1 commit objects with Git plumbing. The supplied path
 * is a caller-trusted repository root, not a PR-controlled path. Requires a Git
 * supporting --no-lazy-fetch. Only ancestor base..head, regular text files and
 * complete bounded before/after contents are supported. All returned text is
 * untrusted data; a separate reviewer must consume it without executing it.
 */
export async function collectReviewComparison(input, options = {}) {
  let scope;
  try {
    const { repositoryPath, baseSha, headSha } = inputRecord(input, ["repositoryPath", "baseSha", "headSha"]);
    const { signal, deadlineMs = REVIEW_COMPARISON_LIMITS.deadlineMs } = inputRecord(options, [], ["signal", "deadlineMs"]);
    requireThat(typeof repositoryPath === "string" && isAbsolute(repositoryPath) && repositoryPath.length <= 4096 && !CONTROL.test(repositoryPath), "invalid_input");
    requireThat(typeof baseSha === "string" && SHA.test(baseSha) && typeof headSha === "string" && SHA.test(headSha), "invalid_input");
    requireThat(signal === undefined || signal instanceof AbortSignal, "invalid_input");
    requireThat(Number.isSafeInteger(deadlineMs) && deadlineMs > 0 && deadlineMs <= REVIEW_COMPARISON_LIMITS.maximumDeadlineMs, "invalid_input");
    scope = operationScope(signal, deadlineMs);
    const root = await scope.wait(() => realpath(repositoryPath));
    const information = await git(root, ["rev-parse", "--path-format=absolute", "--git-common-dir", "--is-shallow-repository", "--show-object-format", "--show-prefix"], scope, 8192);
    const lines = utf8(information.bytes, "unsupported_repository").split("\n");
    requireThat(lines.length === 5 && lines[1] === "false" && lines[2] === "sha1" && lines[3] === "" && lines[4] === "" && isAbsolute(lines[0]) && !CONTROL.test(lines[0]), "unsupported_repository");
    const common = await scope.wait(() => realpath(lines[0]));
    let graftsExist = true;
    try { await scope.wait(() => lstat(join(common, "info", "grafts"))); }
    catch (error) {
      if (error?.code === "ENOENT") graftsExist = false;
      else throw error;
    }
    requireThat(!graftsExist, "unsupported_repository");
    const commitIds = [...new Set([baseSha, headSha])];
    const commitsResult = await git(root, ["cat-file", "--batch"], scope, commitIds.length * (REVIEW_COMPARISON_LIMITS.commitBytes + 128), `${commitIds.join("\n")}\n`);
    const commits = parseBatch(commitsResult.bytes, commitIds, "commit", REVIEW_COMPARISON_LIMITS.commitBytes);
    function tree(id) {
      const match = /^tree ([a-f0-9]{40})\n/.exec(commits.get(id).toString("ascii"));
      requireThat(match, "invalid_git_objects");
      return match[1];
    }
    const baseTreeOid = tree(baseSha);
    const headTreeOid = tree(headSha);
    const bases = await git(root, ["merge-base", "--all", baseSha, headSha], scope, 4096, "", [0, 1]);
    const mergeBases = bases.bytes.toString("ascii").trim().split("\n");
    requireThat(bases.exitCode === 0 && mergeBases.length === 1 && SHA.test(mergeBases[0]), "ambiguous_merge_base");
    requireThat(mergeBases[0] === baseSha, "base_not_ancestor");
    const changed = await git(root, ["diff-tree", "-r", "--raw", "-z", "--no-abbrev", "--no-renames", "--no-ext-diff", "--no-textconv", "--no-commit-id", "--ignore-submodules=none", "--no-relative", baseSha, headSha, "--"], scope, REVIEW_COMPARISON_LIMITS.inventoryBytes);
    const entries = inventory(changed.bytes);
    const blobIds = [...new Set(entries.flatMap((entry) => [entry.beforeOid, entry.afterOid]).filter((oid) => oid !== ZERO))];
    let sizes = new Map();
    let blobs = new Map();
    let totalContentBytes = 0;
    if (blobIds.length) {
      const sizeResult = await git(root, ["cat-file", "--batch-check=%(objectname) %(objecttype) %(objectsize)"], scope, blobIds.length * 128, `${blobIds.join("\n")}\n`);
      sizes = blobSizes(sizeResult.bytes, blobIds);
      totalContentBytes = entries.reduce((sum, entry) => sum + (sizes.get(entry.beforeOid) ?? 0) + (sizes.get(entry.afterOid) ?? 0), 0);
      requireThat(totalContentBytes <= REVIEW_COMPARISON_LIMITS.contentBytes, "content_limit");
      const uniqueBytes = [...sizes.values()].reduce((sum, size) => sum + size, 0);
      const objects = await git(root, ["cat-file", "--batch"], scope, uniqueBytes + blobIds.length * 128, `${blobIds.join("\n")}\n`);
      blobs = parseBatch(objects.bytes, blobIds, "blob", REVIEW_COMPARISON_LIMITS.blobBytes);
    }
    const files = Object.freeze(entries.map((entry) => Object.freeze({
      path: entry.path,
      status: entry.status,
      before: snapshot(entry.beforeOid, entry.beforeMode, blobs, sizes),
      after: snapshot(entry.afterOid, entry.afterMode, blobs, sizes),
    })));
    const measured = {
      schemaVersion: 1,
      comparisonKind: "git-ancestor-text-v1",
      baseSha, headSha, mergeBaseSha: mergeBases[0], baseTreeOid, headTreeOid,
      totalContentBytes, files,
    };
    const bytes = Buffer.from(JSON.stringify(measured));
    requireThat(bytes.length <= REVIEW_COMPARISON_LIMITS.packetBytes, "packet_limit");
    scope.check();
    return Object.freeze({
      ...measured,
      comparisonSha256: digest(bytes),
      githubIdentityAuthenticated: false,
      reviewCompleted: false,
      enforcementPublished: false,
    });
  } catch (error) {
    if (error instanceof ComparisonError) throw error;
    throw new ComparisonError("comparison_failed");
  } finally { scope?.close(); }
}
