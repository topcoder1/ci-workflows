// Execute measurement and one data-only review; emit the existing receipt wire
// format. Dispatch context is trusted caller input, NOT authenticated here.
import { createHash } from "node:crypto";
import { performance } from "node:perf_hooks";
import { types } from "node:util";
import {
  collectReviewComparison,
  REVIEW_COMPARISON_LIMITS,
} from "./merge-policy-review-comparison.mjs";
import {
  createAnthropicReviewer,
  ANTHROPIC_REVIEW_LIMITS,
} from "./merge-policy-anthropic-review.mjs";

export const REVIEW_PRODUCER_LIMITS = Object.freeze({
  receiptBytes: 65536,
  deadlineMs: 120000,
  maximumDeadlineMs: 180000,
});
const RUN_FIELDS = [
  "repository",
  "repositoryId",
  "workflowId",
  "workflowPath",
  "workflowRevision",
  "runId",
  "runAttempt",
];
const TARGET_FIELDS = [
  "repository",
  "pullRequest",
  "headSha",
  "baseSha",
  "policyDigest",
];
const SHA = /^[a-f0-9]{40}$/;
const DIGEST = /^[a-f0-9]{64}$/;
const ID = /^[a-z][a-z0-9_-]{0,63}$/;
const REPOSITORY = /^[A-Za-z0-9][A-Za-z0-9-]{0,38}\/[A-Za-z0-9_.-]{1,100}$/;
class ProducerError extends Error {
  constructor(code) {
    super(`Review producer: ${code}`);
    this.name = "ReviewProducerError";
    this.code = code;
  }
}
function requireThat(condition, code = "invalid_input") {
  if (!condition) throw new ProducerError(code);
}
function record(input, required, optional = []) {
  requireThat(input && typeof input === "object" && !types.isProxy(input));
  requireThat([Object.prototype, null].includes(Object.getPrototypeOf(input)));
  const descriptors = Object.getOwnPropertyDescriptors(input);
  const keys = Reflect.ownKeys(descriptors);
  requireThat(
    required.every((key) => keys.includes(key)) &&
      keys.every((key) => required.includes(key) || optional.includes(key)),
  );
  const copy = {};
  for (const key of keys) {
    const descriptor = descriptors[key];
    requireThat(descriptor.enumerable && Object.hasOwn(descriptor, "value"));
    copy[key] = descriptor.value;
  }
  return copy;
}
const positive = (value) => Number.isSafeInteger(value) && value > 0;
function repository(value) {
  return (
    typeof value === "string" &&
    REPOSITORY.test(value) &&
    ![".", ".."].includes(value.split("/")[1])
  );
}
function dispatchCopy(input) {
  const dispatch = record(input, ["producer", "target", "lane"]);
  const producer = record(dispatch.producer, RUN_FIELDS);
  const target = record(dispatch.target, TARGET_FIELDS);
  requireThat(repository(producer.repository) && repository(target.repository));
  requireThat(
    [
      producer.repositoryId,
      producer.workflowId,
      producer.runId,
      target.pullRequest,
    ].every(positive),
  );
  requireThat(producer.runAttempt === 1, "unsupported_attempt");
  requireThat(
    typeof producer.workflowPath === "string" &&
      producer.workflowPath.length <= 280 &&
      /^\.github\/workflows\/[A-Za-z0-9_-]+\.ya?ml$/.test(
        producer.workflowPath,
      ),
  );
  requireThat(
    [producer.workflowRevision, target.headSha, target.baseSha].every(
      (value) => typeof value === "string" && SHA.test(value),
    ),
  );
  requireThat(
    typeof target.policyDigest === "string" && DIGEST.test(target.policyDigest),
  );
  requireThat(typeof dispatch.lane === "string" && ID.test(dispatch.lane));
  return Object.freeze({
    producer: Object.freeze(producer),
    target: Object.freeze(target),
    lane: dispatch.lane,
  });
}
function scopeFor(signal, deadlineMs) {
  const controller = new AbortController();
  const deadline = performance.now() + deadlineMs;
  let failure;
  const stop = (code) => {
    if (failure) return;
    failure = new ProducerError(code);
    controller.abort();
  };
  const onAbort = () => stop("aborted");
  signal?.addEventListener("abort", onAbort, { once: true });
  if (signal?.aborted) onAbort();
  const timer = setTimeout(() => stop("deadline_exceeded"), deadlineMs);
  function check() {
    if (!failure && performance.now() >= deadline) stop("deadline_exceeded");
    if (failure) throw failure;
  }
  return {
    signal: controller.signal,
    check,
    remaining(maximum) {
      check();
      return Math.max(
        1,
        Math.min(maximum, Math.ceil(deadline - performance.now())),
      );
    },
    close() {
      clearTimeout(timer);
      signal?.removeEventListener("abort", onAbort);
      controller.abort();
    },
  };
}
const sha256 = (bytes) => createHash("sha256").update(bytes).digest("hex");

/** Trusted invocation only. No CLI, environment lookup, network or credential
 * acquisition occurs until produce(). The measured Git repository must already
 * be bound to the dispatch target by a separate trusted caller. No configurable
 * collector/reviewer callback can substitute a caller-provided "clean" result.
 */
export function createReviewProducer(configuration) {
  const { tokenProvider, fetchImpl } = record(
    configuration,
    ["tokenProvider"],
    ["fetchImpl"],
  );
  const reviewer = createAnthropicReviewer({ tokenProvider, fetchImpl });
  return Object.freeze({
    async produce(input, options = {}) {
      let scope;
      let phase = "comparison";
      try {
        const { repositoryPath, dispatch: rawDispatch } = record(input, [
          "repositoryPath",
          "dispatch",
        ]);
        requireThat(
          typeof repositoryPath === "string" &&
            repositoryPath.length > 0 &&
            repositoryPath.length <= 4096 &&
            !repositoryPath.includes("\0"),
        );
        const dispatch = dispatchCopy(rawDispatch);
        const settings = record(options, [], ["signal", "deadlineMs"]);
        const signal = settings.signal;
        const deadlineMs =
          settings.deadlineMs ?? REVIEW_PRODUCER_LIMITS.deadlineMs;
        requireThat(
          signal === undefined ||
            (!types.isProxy(signal) && signal instanceof AbortSignal),
        );
        requireThat(
          Number.isSafeInteger(deadlineMs) &&
            deadlineMs > 0 &&
            deadlineMs <= REVIEW_PRODUCER_LIMITS.maximumDeadlineMs,
        );
        scope = scopeFor(signal, deadlineMs);
        scope.check();
        const comparison = await collectReviewComparison(
          {
            repositoryPath,
            baseSha: dispatch.target.baseSha,
            headSha: dispatch.target.headSha,
          },
          {
            signal: scope.signal,
            deadlineMs: scope.remaining(REVIEW_COMPARISON_LIMITS.deadlineMs),
          },
        );
        scope.check();
        requireThat(
          comparison.baseSha === dispatch.target.baseSha &&
            comparison.headSha === dispatch.target.headSha &&
            comparison.mergeBaseSha === dispatch.target.baseSha,
          "comparison_binding_mismatch",
        );
        requireThat(comparison.files.length > 0, "empty_comparison");
        phase = "provider";
        const result = await reviewer.review(comparison, {
          signal: scope.signal,
          deadlineMs: scope.remaining(ANTHROPIC_REVIEW_LIMITS.deadlineMs),
        });
        scope.check();
        requireThat(result.review.complete === true, "review_incomplete");
        requireThat(
          result.comparisonSha256 === comparison.comparisonSha256,
          "comparison_binding_mismatch",
        );
        phase = "receipt";
        // The provider has validated the complete result. Keep every finding;
        // never use spreads that could let model fields overwrite identities.
        const receipt = Object.freeze({
          schemaVersion: 1,
          producer: dispatch.producer,
          target: dispatch.target,
          lane: dispatch.lane,
          complete: true,
          outcome: result.review.outcome,
          findingCount: result.review.findingCount,
          summary: result.review.summary,
          findings: result.review.findings,
        });
        const bytes = Buffer.from(JSON.stringify(receipt), "utf8");
        requireThat(
          bytes.length <= REVIEW_PRODUCER_LIMITS.receiptBytes,
          "receipt_limit",
        );
        scope.check();
        return Object.freeze({
          receipt,
          get receiptBytes() {
            return Buffer.from(bytes);
          },
          receiptSha256: sha256(bytes),
          comparisonSha256: comparison.comparisonSha256,
          provider: Object.freeze({
            model: result.model,
            messageId: result.messageId,
            inputSha256: result.inputSha256,
            outputSha256: result.outputSha256,
            requestSha256: result.requestSha256,
          }),
          githubIdentityAuthenticated: false,
          executionAuthenticated: false,
          enforcementPublished: false,
        });
      } catch (error) {
        scope?.check();
        if (error instanceof ProducerError) throw error;
        throw new ProducerError(`${phase}_failed`);
      } finally {
        scope?.close();
      }
    },
  });
}
