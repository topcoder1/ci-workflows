import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  symlinkSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { performance } from "node:perf_hooks";
import test from "node:test";
import {
  collectReviewComparison,
  REVIEW_COMPARISON_LIMITS,
} from "../.github/scripts/merge-policy-review-comparison.mjs";

const gitEnv = {
  PATH: "/usr/bin:/bin",
  LANG: "C",
  LC_ALL: "C",
  GIT_CONFIG_NOSYSTEM: "1",
  GIT_CONFIG_GLOBAL: "/dev/null",
  GIT_AUTHOR_NAME: "Synthetic reviewer fixture",
  GIT_AUTHOR_EMAIL: "fixture@example.invalid",
  GIT_COMMITTER_NAME: "Synthetic reviewer fixture",
  GIT_COMMITTER_EMAIL: "fixture@example.invalid",
};
function fixture(
  t,
  initial = { "changed.txt": "before\n", "unchanged.txt": "unchanged\n" },
) {
  const root = mkdtempSync(join(tmpdir(), "review-comparison-test-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const git = (...args) =>
    execFileSync("/usr/bin/git", args, {
      cwd: root,
      env: gitEnv,
      encoding: "utf8",
      stdio: ["pipe", "pipe", "pipe"],
      timeout: 5000,
    }).trim();
  const gitInput = (input, ...args) =>
    execFileSync("/usr/bin/git", args, {
      cwd: root,
      env: gitEnv,
      input,
      encoding: "utf8",
      stdio: ["pipe", "pipe", "pipe"],
      timeout: 5000,
    }).trim();
  git("init", "-q");
  let number = 0;
  function write(path, content) {
    mkdirSync(dirname(join(root, path)), { recursive: true });
    writeFileSync(join(root, path), content);
  }
  function commit(changes = {}) {
    for (const [path, content] of Object.entries(changes)) {
      if (content === null) unlinkSync(join(root, path));
      else write(path, content);
    }
    git("add", "-A");
    git("commit", "-q", "--allow-empty", "-m", `fixture ${++number}`);
    return git("rev-parse", "HEAD");
  }
  const baseSha = commit(initial);
  return { root, git, gitInput, write, commit, baseSha };
}
const sha256 = (bytes) => createHash("sha256").update(bytes).digest("hex");
const collect = (f, headSha, options, baseSha = f.baseSha) =>
  collectReviewComparison(
    { repositoryPath: f.root, baseSha, headSha },
    options,
  );
async function failure(operation, code) {
  await assert.rejects(operation, (error) => {
    assert.equal(error.name, "ReviewComparisonError");
    assert.equal(error.code, code);
    assert.equal(error.message, `Review comparison: ${code}`);
    assert.equal(error.cause, undefined);
    return true;
  });
}

test("measures exact committed before/after bytes, objects, inventory and deterministic hash", async (t) => {
  const f = fixture(t);
  const headSha = f.commit({
    "changed.txt": "after\n",
    "added.txt": "new",
    "unchanged.txt": null,
  });
  f.write("changed.txt", "UNCOMMITTED working tree must not be reviewed");
  f.write("untracked.txt", "Untracked content must not appear");
  const result = await collect(f, headSha);
  assert.equal(result.baseSha, f.baseSha);
  assert.equal(result.headSha, headSha);
  assert.equal(result.mergeBaseSha, f.baseSha);
  assert.equal(result.comparisonKind, "git-ancestor-text-v1");
  assert.equal(result.baseTreeOid, f.git("rev-parse", `${f.baseSha}^{tree}`));
  assert.equal(result.headTreeOid, f.git("rev-parse", `${headSha}^{tree}`));
  assert.deepEqual(
    result.files.map(({ path, status }) => [path, status]),
    [
      ["added.txt", "A"],
      ["changed.txt", "M"],
      ["unchanged.txt", "D"],
    ],
  );
  assert.equal(result.files[0].before, null);
  assert.equal(result.files[0].after.text, "new");
  assert.equal(result.files[1].before.text, "before\n");
  assert.equal(result.files[1].after.text, "after\n");
  assert.equal(result.files[2].after, null);
  let total = 0;
  for (const file of result.files) {
    assert.ok(Object.isFrozen(file));
    for (const snapshot of [file.before, file.after]) {
      if (!snapshot) continue;
      assert.ok(Object.isFrozen(snapshot));
      const bytes = Buffer.from(snapshot.text);
      assert.equal(snapshot.byteLength, bytes.length);
      assert.equal(snapshot.sha256, sha256(bytes));
      assert.equal(
        snapshot.oid,
        createHash("sha1")
          .update(`blob ${bytes.length}\0`)
          .update(bytes)
          .digest("hex"),
      );
      total += bytes.length;
    }
  }
  assert.equal(result.totalContentBytes, total);
  const {
    comparisonSha256,
    githubIdentityAuthenticated,
    reviewCompleted,
    enforcementPublished,
    ...measured
  } = result;
  assert.equal(comparisonSha256, sha256(Buffer.from(JSON.stringify(measured))));
  assert.equal(githubIdentityAuthenticated, false);
  assert.equal(reviewCompleted, false);
  assert.equal(enforcementPublished, false);
  assert.ok(Object.isFrozen(result) && Object.isFrozen(result.files));
  assert.throws(() => {
    result.files[1].after.text = "mutated";
  }, TypeError);
  assert.equal(Object.hasOwn(result, "repositoryPath"), false);
  assert.equal(Object.hasOwn(result, "outcome"), false);
  assert.equal((await collect(f, headSha)).comparisonSha256, comparisonSha256);
});
test("copies exact selectors before asynchronous work", async (t) => {
  const f = fixture(t);
  const headSha = f.commit({ "changed.txt": "after" });
  const input = { repositoryPath: f.root, baseSha: f.baseSha, headSha };
  const pending = collectReviewComparison(input);
  input.headSha = "f".repeat(40);
  input.repositoryPath = "/does-not-exist";
  assert.equal((await pending).headSha, headSha);
});
test("identical commits give a complete empty inventory", async (t) => {
  const f = fixture(t);
  const result = await collect(f, f.baseSha);
  assert.deepEqual(result.files, []);
  assert.equal(result.totalContentBytes, 0);
});
test("renames are represented completely as add/delete", async (t) => {
  const f = fixture(t, { "old.txt": "same\n" });
  const head = f.commit({ "old.txt": null, "new.txt": "same\n" });
  const result = await collect(f, head);
  assert.deepEqual(
    result.files.map((file) => [file.path, file.status]),
    [
      ["new.txt", "A"],
      ["old.txt", "D"],
    ],
  );
  assert.equal(result.totalContentBytes, 10);
});
test("mode-only changes remain visible and executable files are data only", async (t) => {
  const f = fixture(t, { "script.sh": "#!/bin/sh\nexit 77\n" });
  chmodSync(join(f.root, "script.sh"), 0o755);
  const result = await collect(f, f.commit());
  assert.equal(result.files[0].before.mode, "100644");
  assert.equal(result.files[0].after.mode, "100755");
  assert.equal(result.files[0].before.oid, result.files[0].after.oid);
});
test("retains BOM, UTF8, CRLF, tabs and absence of final newline exactly", async (t) => {
  const f = fixture(t, { "text.txt": "before" });
  const text = "\uFEFFhéllo\t世界\r\nno final newline";
  const result = await collect(f, f.commit({ "text.txt": text }));
  assert.equal(result.files[0].after.text, text);
  assert.equal(result.files[0].after.byteLength, Buffer.byteLength(text));
});
test("empty text blobs are supported", async (t) => {
  const f = fixture(t);
  const result = await collect(f, f.commit({ "empty.txt": "" }));
  assert.equal(result.files[0].after.text, "");
  assert.equal(result.files[0].after.byteLength, 0);
});
for (const [name, content] of [
  ["NUL", Buffer.from([65, 0, 66])],
  ["malformed UTF8", Buffer.from([0xff, 0xfe])],
  ["terminal escape", "before\u001b[0m"],
]) {
  test(`refuses binary or unsafe text: ${name}`, async (t) => {
    const f = fixture(t);
    await failure(
      collect(f, f.commit({ "changed.txt": content })),
      "unsupported_binary",
    );
  });
}
test("refuses symbolic links", async (t) => {
  const f = fixture(t);
  symlinkSync("changed.txt", join(f.root, "link"));
  await failure(collect(f, f.commit()), "unsupported_file_mode");
});
test("refuses gitlink/submodule entries without opening a submodule", async (t) => {
  const f = fixture(t);
  f.git("update-index", "--add", "--cacheinfo", `160000,${f.baseSha},module`);
  f.git("commit", "-q", "-m", "submodule fixture");
  await failure(
    collect(f, f.git("rev-parse", "HEAD")),
    "unsupported_file_mode",
  );
});
test("refuses control and separator-ambiguous paths", async (t) => {
  for (const path of ["line\nbreak.txt", "back\\slash.txt", "bidi\u202etxt"]) {
    const f = fixture(t);
    await failure(collect(f, f.commit({ [path]: "text" })), "unsupported_path");
  }
});
for (const mode of ["unused-input", "required-input"]) {
  test(`${mode} pipe closure cannot become an accepted comparison`, (t) => {
    const f = fixture(t);
    const headSha = f.commit({ "line\nbreak.txt": "text" });
    // Fault injection is isolated in another Node process. Actual Git commands
    // still execute: no-input closure must not mask the inventory refusal, and
    // an error delivering required batch input must remain a hard failure.
    const script = `
      import assert from "node:assert/strict";
      import childProcess from "node:child_process";
      import { syncBuiltinESMExports } from "node:module";
      const [moduleUrl, repositoryPath, baseSha, headSha, mode] = process.argv.slice(1);
      const originalSpawn = childProcess.spawn;
      let noInputCommands = 0;
      let batchCommands = 0;
      childProcess.spawn = (command, args, options) => {
        assert.equal(command, "/usr/bin/git");
        const child = originalSpawn(command, args, options);
        const batch = args.includes("cat-file");
        if (batch) {
          batchCommands++;
          assert.notEqual(child.stdin, null);
        } else {
          noInputCommands++;
        }
        if (child.stdin && ((mode === "unused-input" && !batch) ||
                            (mode === "required-input" && batch))) {
          process.nextTick(() => child.stdin.emit("error",
            Object.assign(new Error("synthetic closed input"), { code: "EPIPE" })));
        }
        return child;
      };
      syncBuiltinESMExports();
      const { collectReviewComparison } = await import(moduleUrl);
      await assert.rejects(collectReviewComparison({ repositoryPath, baseSha, headSha }), {
        name: "ReviewComparisonError",
        code: mode === "unused-input" ? "unsupported_path" : "git_io_failed",
      });
      assert.ok(noInputCommands > 0);
      assert.ok(batchCommands > 0);
    `;
    execFileSync(
      process.execPath,
      [
        "--input-type=module",
        "--eval",
        script,
        new URL(
          "../.github/scripts/merge-policy-review-comparison.mjs",
          import.meta.url,
        ).href,
        f.root,
        f.baseSha,
        headSha,
        mode,
      ],
      { env: gitEnv, stdio: ["ignore", "pipe", "pipe"], timeout: 10000 },
    );
  });
}
test("refuses malformed UTF8 path bytes", async (t) => {
  const f = fixture(t);
  // APFS refuses malformed path bytes; Git tree objects can still contain them.
  const blob = f.gitInput("text", "hash-object", "-w", "--stdin");
  const treeBytes = Buffer.concat([
    Buffer.from(`100644 blob ${blob}\t`),
    Buffer.from([0xff]),
    Buffer.from(".txt\0"),
  ]);
  const tree = f.gitInput(treeBytes, "mktree", "-z");
  const head = f.gitInput(
    "malformed path",
    "commit-tree",
    tree,
    "-p",
    f.baseSha,
  );
  await failure(collect(f, head), "unsupported_path");
});
test("refuses more files than the complete inventory bound", async (t) => {
  const f = fixture(t);
  const changes = Object.fromEntries(
    Array.from({ length: REVIEW_COMPARISON_LIMITS.files + 1 }, (_, i) => [
      `file-${i}.txt`,
      "x",
    ]),
  );
  await failure(collect(f, f.commit(changes)), "file_limit");
});
test("refuses oversized blobs before collecting blob contents", async (t) => {
  const f = fixture(t);
  await failure(
    collect(
      f,
      f.commit({
        "changed.txt": "x".repeat(REVIEW_COMPARISON_LIMITS.blobBytes + 1),
      }),
    ),
    "blob_limit",
  );
});
test("aggregate limit counts repeated before/after bytes, including duplicate objects", async (t) => {
  const contents = "x".repeat(40000);
  const initial = Object.fromEntries(
    Array.from({ length: 4 }, (_, i) => [`file-${i}.txt`, contents]),
  );
  const f = fixture(t, initial);
  const changed = Object.fromEntries(
    Object.keys(initial).map((path) => [path, `${contents.slice(0, -1)}y`]),
  );
  await failure(collect(f, f.commit(changed)), "content_limit");
});
test("raw subprocess output is bounded even for oversized commit objects", async (t) => {
  const f = fixture(t);
  const tree = f.git("rev-parse", `${f.baseSha}^{tree}`);
  const head = f.gitInput(
    "x".repeat(REVIEW_COMPARISON_LIMITS.commitBytes * 4),
    "commit-tree",
    tree,
    "-p",
    f.baseSha,
  );
  await failure(collect(f, head), "subprocess_output_limit");
});
test("refuses diverged histories instead of treating merge-base as requested base", async (t) => {
  const f = fixture(t);
  const tree = f.git("rev-parse", `${f.baseSha}^{tree}`);
  const left = f.gitInput("left", "commit-tree", tree, "-p", f.baseSha);
  const right = f.gitInput("right", "commit-tree", tree, "-p", f.baseSha);
  await failure(collect(f, right, undefined, left), "base_not_ancestor");
});
test("refuses multiple merge bases in criss-cross history", async (t) => {
  const f = fixture(t);
  const tree = f.git("rev-parse", `${f.baseSha}^{tree}`);
  const left = f.gitInput("left", "commit-tree", tree, "-p", f.baseSha);
  const right = f.gitInput("right", "commit-tree", tree, "-p", f.baseSha);
  const first = f.gitInput(
    "first merge",
    "commit-tree",
    tree,
    "-p",
    left,
    "-p",
    right,
  );
  const second = f.gitInput(
    "second merge",
    "commit-tree",
    tree,
    "-p",
    right,
    "-p",
    left,
  );
  assert.equal(
    f.git("merge-base", "--all", first, second).split("\n").length,
    2,
  );
  await failure(collect(f, second, undefined, first), "ambiguous_merge_base");
});
test("exact commit input excludes refs, abbreviated IDs, missing objects and annotated tags", async (t) => {
  const f = fixture(t);
  await failure(collect(f, "HEAD"), "invalid_input");
  await failure(collect(f, f.baseSha.slice(0, 8)), "invalid_input");
  await failure(collect(f, "f".repeat(40)), "invalid_git_objects");
  f.git("tag", "-a", "synthetic", "-m", "annotated");
  await failure(
    collect(f, f.git("rev-parse", "synthetic")),
    "invalid_git_objects",
  );
});
test("replace refs cannot substitute the measured commit or blob contents", async (t) => {
  const f = fixture(t);
  const head = f.commit({ "changed.txt": "actual new bytes" });
  const baseTree = f.git("rev-parse", `${f.baseSha}^{tree}`);
  const replacement = f.gitInput(
    "replacement commit",
    "commit-tree",
    baseTree,
    "-p",
    f.baseSha,
  );
  f.git("replace", head, replacement);
  const result = await collect(f, head);
  assert.equal(result.files[0].after.text, "actual new bytes");
  assert.equal(result.headSha, head);
});
test("shallow histories and legacy graft overrides are refused", async (t) => {
  const shallow = fixture(t);
  writeFileSync(join(shallow.root, ".git", "shallow"), `${shallow.baseSha}\n`);
  await failure(collect(shallow, shallow.baseSha), "unsupported_repository");
  const graft = fixture(t);
  writeFileSync(join(graft.root, ".git", "info", "grafts"), "");
  await failure(collect(graft, graft.baseSha), "unsupported_repository");
});
test("repository subdirectories cannot silently select a parent repository", async (t) => {
  const f = fixture(t);
  mkdirSync(join(f.root, "nested"));
  await failure(
    collectReviewComparison({
      repositoryPath: join(f.root, "nested"),
      baseSha: f.baseSha,
      headSha: f.baseSha,
    }),
    "unsupported_repository",
  );
});
test("no attributes, textconv, filter, hook or inherited Git execution override runs", async (t) => {
  const f = fixture(t, {
    ".gitattributes": "*.txt diff=hostile filter=hostile\n",
    "changed.txt": "before",
  });
  const head = f.commit({ "changed.txt": "after" });
  const marker = join(f.root, "executed-marker");
  const helper = join(f.root, "hostile-helper");
  writeFileSync(
    helper,
    `#!/bin/sh\nprintf executed > '${marker.replaceAll("'", "'\\''")}'\nexit 1\n`,
    { mode: 0o755 },
  );
  for (const key of [
    "diff.external",
    "diff.hostile.command",
    "diff.hostile.textconv",
    "filter.hostile.clean",
    "filter.hostile.smudge",
    "core.fsmonitor",
  ])
    f.git("config", key, helper);
  f.git("config", "filter.hostile.required", "true");
  const hooks = join(f.root, ".git", "hooks");
  for (const name of ["post-checkout", "pre-commit", "post-index-change"])
    writeFileSync(join(hooks, name), `#!/bin/sh\nexec '${helper}'\n`, {
      mode: 0o755,
    });
  const fakeBin = join(f.root, "fake-bin");
  mkdirSync(fakeBin);
  writeFileSync(join(fakeBin, "git"), `#!/bin/sh\nexec '${helper}'\n`, {
    mode: 0o755,
  });
  const overrides = {
    PATH: fakeBin,
    GIT_EXEC_PATH: fakeBin,
    GIT_EXTERNAL_DIFF: helper,
    GIT_CONFIG_COUNT: "1",
    GIT_CONFIG_KEY_0: "core.fsmonitor",
    GIT_CONFIG_VALUE_0: helper,
    GIT_DIR: join(f.root, "wrong-git-dir"),
    GIT_WORK_TREE: join(f.root, "wrong-worktree"),
    GIT_OBJECT_DIRECTORY: join(f.root, "wrong-objects"),
    GIT_INDEX_FILE: join(f.root, "wrong-index"),
    GIT_TRACE: marker,
    GIT_TRACE2_EVENT: marker,
  };
  const previous = Object.fromEntries(
    Object.keys(overrides).map((key) => [key, process.env[key]]),
  );
  try {
    Object.assign(process.env, overrides);
    const result = await collect(f, head);
    assert.equal(result.files[0].before.text, "before");
    assert.equal(result.files[0].after.text, "after");
    assert.equal(existsSync(marker), false);
  } finally {
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  }
});
test("missing promisor objects fail without launching a remote helper", async (t) => {
  const f = fixture(t);
  const head = f.commit({ "changed.txt": "missing local blob" });
  const blob = f.git("rev-parse", `${head}:changed.txt`);
  const marker = join(f.root, "fetch-marker");
  const helper = join(f.root, "remote-helper");
  writeFileSync(helper, `#!/bin/sh\nprintf attempted > '${marker}'\nexit 1\n`, {
    mode: 0o755,
  });
  f.git("config", "extensions.partialClone", "origin");
  f.git("config", "remote.origin.promisor", "true");
  f.git("config", "remote.origin.url", `ext::${helper}`);
  f.git("config", "protocol.ext.allow", "always");
  unlinkSync(join(f.root, ".git", "objects", blob.slice(0, 2), blob.slice(2)));
  await failure(collect(f, head), "invalid_git_objects");
  assert.equal(existsSync(marker), false);
});
test("pre-aborted parent rejects without reading the repository", async () => {
  const controller = new AbortController();
  controller.abort(new Error("private reason"));
  await failure(
    collectReviewComparison(
      {
        repositoryPath: "/does-not-exist",
        baseSha: "a".repeat(40),
        headSha: "b".repeat(40),
      },
      { signal: controller.signal },
    ),
    "aborted",
  );
});
for (const mode of ["deadline", "parent abort"]) {
  test(`${mode} terminates a real Git subprocess stalled reading configuration`, async (t) => {
    const f = fixture(t);
    const fifo = join(f.root, "blocked-config");
    execFileSync("/usr/bin/mkfifo", [fifo]);
    f.git("config", "include.path", fifo);
    const controller = new AbortController();
    const started = performance.now();
    const timer =
      mode === "parent abort"
        ? setTimeout(() => controller.abort(new Error("private reason")), 30)
        : undefined;
    try {
      await failure(
        collect(f, f.baseSha, {
          signal: controller.signal,
          deadlineMs: mode === "deadline" ? 30 : 1000,
        }),
        mode === "deadline" ? "deadline_exceeded" : "aborted",
      );
      assert.ok(performance.now() - started < 1000);
    } finally {
      clearTimeout(timer);
    }
  });
}
test("input accessors and unknown fields are refused without invoking getters", async () => {
  let invoked = false;
  const input = { baseSha: "a".repeat(40), headSha: "b".repeat(40) };
  Object.defineProperty(input, "repositoryPath", {
    enumerable: true,
    get() {
      invoked = true;
      return "/tmp";
    },
  });
  await failure(collectReviewComparison(input), "invalid_input");
  assert.equal(invoked, false);
  await failure(
    collectReviewComparison({
      repositoryPath: "/tmp",
      baseSha: "a".repeat(40),
      headSha: "b".repeat(40),
      extra: true,
    }),
    "invalid_input",
  );
  await failure(
    collectReviewComparison(
      {
        repositoryPath: "/tmp",
        baseSha: "a".repeat(40),
        headSha: "b".repeat(40),
      },
      { deadlineMs: 10001 },
    ),
    "invalid_input",
  );
});
