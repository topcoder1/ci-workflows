// Turn the authenticated GitHub artifact client into the two readers that
// prepareReviewIntake() consumes, for one shadow cycle at a time.
//
// The intake asks for metadata, then the artifact, then metadata again, each
// within INTAKE_LIMITS.readDeadlineMs (2 s). A real artifact read is about nine
// sequential HTTPS requests plus a download, so it cannot answer inside that
// deadline. The adapter therefore reads the artifact ONCE, up front, under the
// client's own 10 s deadline (prefetchReviewReceipt), and answers the first two
// reader calls from that result. The second metadata call does not repeat the
// answer: it runs client.recheck(), one fresh authenticated pass over the run,
// its attempt and the artifact, and fails if any fact moved (TRUSTED-INTAKE.md
// "The second read must freshly verify the run's current latest attempt").
//
// metadata.target comes from the dispatcher's own durable dispatch record and
// from nothing else. The receipt's target is data; the intake compares the two
// and refuses a receipt whose target is not the one that was dispatched.
//
// The adapter never sees a credential: the client takes one from its
// tokenProvider inside each call and drops it before returning.
import { createHash } from "node:crypto";

import { extractReviewReceipt } from "./merge-policy-artifact-zip.mjs";

const SHA = /^[a-f0-9]{40}$/;
const DIGEST = /^[a-f0-9]{64}$/;
const REPOSITORY = /^[A-Za-z0-9][A-Za-z0-9-]{0,38}\/[A-Za-z0-9_.-]{1,100}$/;
const TARGET_FIELDS = Object.freeze([
  "repository",
  "pullRequest",
  "headSha",
  "baseSha",
  "policyDigest",
]);
const SELECTOR_FIELDS = Object.freeze([
  "repository",
  "runId",
  "runAttempt",
  "artifactId",
]);
export const INTAKE_ADAPTER_LIMITS = Object.freeze({
  prefetchDeadlineMs: 10_000,
});

export class IntakeAdapterError extends Error {
  constructor(code) {
    super(`Review intake adapter: ${code}`);
    this.name = "IntakeAdapterError";
    this.code = code;
  }
}
function requireThat(condition, code) {
  if (!condition) throw new IntakeAdapterError(code);
}
function positive(value) {
  return Number.isSafeInteger(value) && value > 0;
}
/** A plain object with exactly these own enumerable data properties. */
function plain(value, fields) {
  requireThat(
    value &&
      typeof value === "object" &&
      [Object.prototype, null].includes(Object.getPrototypeOf(value)),
    "invalid_input",
  );
  const descriptors = Object.getOwnPropertyDescriptors(value);
  const keys = Reflect.ownKeys(descriptors);
  requireThat(
    keys.length === fields.length &&
      fields.every(
        (key) =>
          keys.includes(key) &&
          descriptors[key].enumerable &&
          Object.hasOwn(descriptors[key], "value"),
      ),
    "invalid_input",
  );
  return Object.fromEntries(fields.map((key) => [key, value[key]]));
}
/** The dispatch record's target, copied field by field and validated. It is
 * the dispatcher's statement of what it asked the producer to review. */
export function dispatchTarget(record) {
  const target = plain(record, TARGET_FIELDS);
  requireThat(
    typeof target.repository === "string" && REPOSITORY.test(target.repository),
    "invalid_target",
  );
  requireThat(positive(target.pullRequest), "invalid_target");
  requireThat(
    typeof target.headSha === "string" &&
      SHA.test(target.headSha) &&
      typeof target.baseSha === "string" &&
      SHA.test(target.baseSha) &&
      target.headSha !== target.baseSha,
    "invalid_target",
  );
  requireThat(
    typeof target.policyDigest === "string" && DIGEST.test(target.policyDigest),
    "invalid_target",
  );
  return Object.freeze(target);
}
function selectorOf(value) {
  const selector = plain(value, SELECTOR_FIELDS);
  requireThat(
    typeof selector.repository === "string" &&
      positive(selector.runId) &&
      positive(selector.runAttempt) &&
      positive(selector.artifactId),
    "invalid_input",
  );
  return Object.freeze(selector);
}
function sameSelector(left, right) {
  return SELECTOR_FIELDS.every((key) => left[key] === right[key]);
}
/** The intake's normalized metadata document (TRUSTED-INTAKE.md), built from
 * facts the client authenticated and the target the dispatcher recorded. The
 * artifact digest is that of the exact receipt bytes inside the archive, which
 * is what the intake hashes; the archive's own digest stays in the report. */
function metadataFrom(facts, target, receipt) {
  const { producer, run, artifact } = facts;
  // The producer identity is what the run's own API object says (the client
  // has held each field to the configuration, but the intake's comparison with
  // the registered producer must not be fed the registered values back). The
  // path is the one exception: the run spells it with the approved tag suffix
  // in tag mode, and the client has already bound it to the configured path.
  return Object.freeze({
    schemaVersion: 1,
    producer: Object.freeze({
      repository: run.repository,
      repositoryId: run.repositoryId,
      workflowId: run.workflowId,
      workflowPath: producer.workflowPath,
      workflowRevision: run.headSha,
      runId: run.id,
      runAttempt: run.attempt,
    }),
    target,
    status: run.status,
    conclusion: run.conclusion,
    latestRunAttempt: run.attempt,
    artifact: Object.freeze({
      id: artifact.id,
      name: artifact.name,
      byteLength: receipt.length,
      sha256: createHash("sha256").update(receipt).digest("hex"),
    }),
  });
}
function factsChanged(before, after) {
  const fields = [
    ["run", "id"],
    ["run", "attempt"],
    ["run", "repository"],
    ["run", "repositoryId"],
    ["run", "workflowId"],
    ["run", "workflowPath"],
    ["run", "headSha"],
    ["run", "status"],
    ["run", "conclusion"],
    ["artifact", "id"],
    ["artifact", "name"],
    ["artifact", "archiveByteLength"],
    ["artifact", "archiveSha256"],
  ];
  return fields.some(
    ([group, key]) => before[group][key] !== after[group][key],
  );
}

/** Read the artifact once under the client's checks, extract the exact receipt
 * bytes, and build the metadata document. Everything the intake will be told
 * about this run is fixed here; no later call re-downloads. */
export async function prefetchReviewReceipt({
  client,
  selector,
  dispatchRecord,
  signal,
  deadlineMs = INTAKE_ADAPTER_LIMITS.prefetchDeadlineMs,
}) {
  requireThat(
    client &&
      typeof client.read === "function" &&
      typeof client.recheck === "function",
    "invalid_client",
  );
  const target = dispatchTarget(dispatchRecord);
  const wanted = selectorOf(selector);
  const { repository, ...clientSelector } = wanted;
  const facts = await client.read(clientSelector, { signal, deadlineMs });
  requireThat(facts.producer.repository === repository, "repository_mismatch");
  // The client has bound the artifact's name to the configured one; the
  // archive must carry the receipt under that exact name.
  const receipt = extractReviewReceipt(
    facts.archiveBytes,
    facts.producer.artifactName,
  );
  return Object.freeze({
    selector: wanted,
    target,
    metadata: metadataFrom(facts, target, receipt),
    receipt,
    facts: Object.freeze({
      producer: facts.producer,
      run: facts.run,
      artifact: facts.artifact,
    }),
    archiveSha256: facts.artifact.archiveSha256,
  });
}

/** The `{metadata, artifact}` readers for prepareReviewIntake(), bound to one
 * prefetched receipt. Call order is the intake's: metadata, artifact, metadata.
 * The first metadata answer and the artifact come from the prefetch; every
 * later metadata answer first re-reads the run and artifact through
 * client.recheck() under the intake's own deadline and signal and refuses if
 * any authenticated fact moved. Readers reject any other selector. */
export function createIntakeReaders({ client, prefetch }) {
  requireThat(client && typeof client.recheck === "function", "invalid_client");
  requireThat(
    prefetch &&
      Object.isFrozen(prefetch) &&
      Buffer.isBuffer(prefetch.receipt) &&
      prefetch.metadata?.schemaVersion === 1,
    "invalid_input",
  );
  // The intake requires exactly {metadata, artifact}; nothing else is exposed.
  let metadataCalls = 0;
  const { repository, ...clientSelector } = prefetch.selector;
  function accept(selector) {
    requireThat(
      sameSelector(selectorOf(selector), prefetch.selector),
      "selector_mismatch",
    );
  }
  return Object.freeze({
    async metadata(selector, { signal, deadlineMs } = {}) {
      accept(selector);
      metadataCalls += 1;
      if (metadataCalls > 1) {
        const current = await client.recheck(clientSelector, {
          signal,
          deadlineMs,
        });
        requireThat(
          current.producer.repository === repository,
          "repository_mismatch",
        );
        requireThat(!factsChanged(prefetch.facts, current), "facts_changed");
        requireThat(
          current.run.attempt === prefetch.metadata.latestRunAttempt &&
            current.run.status === "completed" &&
            current.run.conclusion === "success",
          "producer_incomplete",
        );
      }
      return prefetch.metadata;
    },
    async artifact(selector) {
      accept(selector);
      return Buffer.from(prefetch.receipt);
    },
  });
}
