// Deterministic acceptance policy. No GitHub calls, clocks, or mutable state.
// The adapter must supply authenticated actor IDs and protected policy bytes.

const ID = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/;
const LANE = /^[a-z][a-z0-9_-]{0,63}$/;
const SHA = /^[a-f0-9]{40}$/i;
const DIGEST = /^[a-f0-9]{64}$/i;
const COMMON = [
  "id",
  "type",
  "actorId",
  "headSha",
  "baseSha",
  "policyDigest",
  "evidenceUrl",
  "reason",
];

function fail(message) {
  throw new Error(`Merge policy: ${message}`);
}

function object(value, label) {
  if (
    !value ||
    typeof value !== "object" ||
    Array.isArray(value) ||
    ![Object.prototype, null].includes(Object.getPrototypeOf(value))
  ) {
    fail(`${label} must be a plain object`);
  }
}

function keys(value, required, optional, label) {
  object(value, label);
  for (const key of required) {
    if (!Object.hasOwn(value, key)) fail(`${label}.${key} is required`);
  }
  for (const key of Object.keys(value)) {
    if (!required.includes(key) && !optional.includes(key))
      fail(`${label}.${key} is unknown`);
  }
}

function string(value, label, max = 4096) {
  if (
    typeof value !== "string" ||
    !value.trim() ||
    value.length > max ||
    /\u0000/.test(value)
  ) {
    fail(`${label} must be a nonempty string of at most ${max} characters`);
  }
}

function pattern(value, expression, label) {
  if (typeof value !== "string" || !expression.test(value))
    fail(`${label} has an invalid format`);
}

function integer(value, minimum, label) {
  if (!Number.isSafeInteger(value) || value < minimum)
    fail(`${label} must be a safe integer >= ${minimum}`);
}

function uniqueArray(value, validate, label, nonempty = false) {
  if (!Array.isArray(value) || (nonempty && !value.length))
    fail(`${label} must be ${nonempty ? "a nonempty" : "an"} array`);
  const seen = new Set();
  for (const item of value) {
    validate(item, label);
    if (seen.has(item)) fail(`${label} contains duplicates`);
    seen.add(item);
  }
}

function repository(value) {
  if (typeof value !== "string") fail("repository must be a string");
  const parts = value.split("/");
  if (
    parts.length !== 2 ||
    !/^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$/.test(parts[0]) ||
    !/^[A-Za-z0-9_.-]{1,100}$/.test(parts[1]) ||
    [".", ".."].includes(parts[1])
  ) {
    fail("repository must be a safe GitHub owner/repository identifier");
  }
}

function actor(value, label) {
  integer(value, 1, label);
}
function lane(value, label) {
  pattern(value, LANE, label);
}

function utcTime(value, label) {
  if (
    typeof value !== "string" ||
    !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?Z$/.test(value)
  ) {
    fail(`${label} must be a strict UTC ISO8601 timestamp`);
  }
  const millis = Date.parse(value);
  const canonical = value.replace(
    /(?:\.(\d{1,3}))?Z$/,
    (_, fraction) => `.${(fraction || "").padEnd(3, "0")}Z`,
  );
  if (!Number.isFinite(millis) || new Date(millis).toISOString() !== canonical)
    fail(`${label} is not a valid calendar time`);
  return millis;
}

function evidence(value) {
  string(value, "event.evidenceUrl", 2048);
  let url;
  try {
    url = new URL(value);
  } catch {
    fail("event.evidenceUrl must be a valid URL");
  }
  if (
    url.protocol !== "https:" ||
    !["github.com", "api.github.com"].includes(url.hostname) ||
    url.username ||
    url.password ||
    url.port ||
    /[\s\\]/.test(value)
  ) {
    fail(
      "event.evidenceUrl must be HTTPS github.com or api.github.com without credentials",
    );
  }
}

function path(value) {
  string(value, "event.path", 1024);
  if (
    value.startsWith("/") ||
    /^[a-z]:/i.test(value) ||
    value.includes("\\") ||
    value.split("/").some((part) => !part || part === "." || part === "..")
  ) {
    fail("event.path must be a repository-relative path");
  }
}

function sameBinding(left, right) {
  return (
    left.headSha === right.headSha &&
    left.baseSha === right.baseSha &&
    left.policyDigest === right.policyDigest
  );
}

export function validatePolicy(policy) {
  keys(
    policy,
    [
      "schemaVersion",
      "repository",
      "requiredReviews",
      "reviewActors",
      "dispositionActors",
      "findingActors",
      "allowNotApplicable",
      "blockingPriorityMax",
    ],
    [],
    "policy",
  );
  if (policy.schemaVersion !== 1) fail("unsupported policy schemaVersion");
  repository(policy.repository);
  uniqueArray(policy.requiredReviews, lane, "policy.requiredReviews", true);
  object(policy.reviewActors, "policy.reviewActors");
  for (const [name, actors] of Object.entries(policy.reviewActors)) {
    lane(name, "policy.reviewActors lane");
    uniqueArray(actors, actor, `policy.reviewActors.${name}`, true);
  }
  for (const name of policy.requiredReviews) {
    if (!Object.hasOwn(policy.reviewActors, name))
      fail(`required review ${name} has no actors`);
  }
  uniqueArray(policy.dispositionActors, actor, "policy.dispositionActors");
  uniqueArray(policy.findingActors, actor, "policy.findingActors");
  object(policy.allowNotApplicable, "policy.allowNotApplicable");
  for (const [name, reasons] of Object.entries(policy.allowNotApplicable)) {
    lane(name, "policy.allowNotApplicable lane");
    if (!Object.hasOwn(policy.reviewActors, name))
      fail(`not-applicable lane ${name} is not configured`);
    uniqueArray(reasons, lane, `policy.allowNotApplicable.${name}`);
  }
  if (policy.blockingPriorityMax !== 2)
    fail("policy.blockingPriorityMax must be 2 in schemaVersion 1");
  return policy;
}

export function validateContext(context) {
  keys(
    context,
    [
      "repository",
      "pullRequest",
      "headSha",
      "baseSha",
      "policyDigest",
      "authorId",
      "draft",
      "state",
      "headAssociationCount",
    ],
    [],
    "context",
  );
  repository(context.repository);
  integer(context.pullRequest, 1, "context.pullRequest");
  pattern(context.headSha, SHA, "context.headSha");
  pattern(context.baseSha, SHA, "context.baseSha");
  pattern(context.policyDigest, DIGEST, "context.policyDigest");
  actor(context.authorId, "context.authorId");
  if (typeof context.draft !== "boolean") fail("context.draft must be boolean");
  if (!["OPEN", "CLOSED", "MERGED"].includes(context.state))
    fail("context.state is invalid");
  integer(context.headAssociationCount, 1, "context.headAssociationCount");
  return context;
}

function validateScope(policy, context) {
  validatePolicy(policy);
  validateContext(context);
  if (policy.repository !== context.repository)
    fail("policy repository does not match current context");
}

function historyState() {
  return {
    ids: new Set(),
    findings: new Map(),
    dispositions: new Map(),
    reviews: new Map(),
  };
}

// Check each historical record against current trust policy, but retain its
// original binding. A push or a clean review never deletes a finding.
function checkEvent(event, policy, context, history, current) {
  object(event, "event");
  const required = {
    finding: ["findingId", "title", "priority", "path"],
    review: ["lane", "outcome", "findingIds"],
    disposition: ["findingId", "action"],
  };
  if (!Object.hasOwn(required, event.type)) fail("event.type is invalid");
  keys(
    event,
    [...COMMON, ...required[event.type]],
    event.type === "review"
      ? ["notApplicableReason"]
      : event.type === "disposition"
        ? ["expiresAt"]
        : [],
    "event",
  );
  pattern(event.id, ID, "event.id");
  if (history.ids.has(event.id)) fail(`duplicate event id ${event.id}`);
  actor(event.actorId, "event.actorId");
  pattern(event.headSha, SHA, "event.headSha");
  pattern(event.baseSha, SHA, "event.baseSha");
  pattern(event.policyDigest, DIGEST, "event.policyDigest");
  evidence(event.evidenceUrl);
  string(event.reason, "event.reason");
  if (current && !sameBinding(event, context))
    fail("new event must match current head/base/policy binding");

  if (event.type === "finding") {
    const allowed =
      policy.findingActors.includes(event.actorId) ||
      Object.values(policy.reviewActors).some((actors) =>
        actors.includes(event.actorId),
      );
    if (!allowed) fail("finding actor is not authorized");
    pattern(event.findingId, ID, "event.findingId");
    if (history.findings.has(event.findingId))
      fail(`finding ${event.findingId} cannot be redefined`);
    string(event.title, "event.title", 256);
    integer(event.priority, 0, "event.priority");
    if (event.priority > 3) fail("event.priority must be between 0 and 3");
    path(event.path);
    history.findings.set(event.findingId, event);
  } else if (event.type === "review") {
    lane(event.lane, "event.lane");
    if (
      !Object.hasOwn(policy.reviewActors, event.lane) ||
      !policy.reviewActors[event.lane].includes(event.actorId)
    )
      fail("review actor is not authorized for lane");
    if (
      policy.requiredReviews.includes(event.lane) &&
      event.actorId === context.authorId
    )
      fail("required review cannot be issued by PR author");
    if (
      !["clean", "findings", "not_applicable", "error"].includes(event.outcome)
    )
      fail("event.outcome is invalid");
    uniqueArray(
      event.findingIds,
      (value, label) => pattern(value, ID, label),
      "event.findingIds",
    );
    if (event.outcome === "findings") {
      if (!event.findingIds.length)
        fail("findings review must deliver one or more finding records");
      for (const id of event.findingIds) {
        const finding = history.findings.get(id);
        if (!finding || !sameBinding(finding, event))
          fail(
            `review finding ${id} is missing or bound to another head/base/policy`,
          );
      }
    } else if (event.findingIds.length)
      fail("only findings reviews may reference findings");
    if (event.outcome === "not_applicable") {
      lane(event.notApplicableReason, "event.notApplicableReason");
      if (
        !Object.hasOwn(policy.allowNotApplicable, event.lane) ||
        !policy.allowNotApplicable[event.lane].includes(
          event.notApplicableReason,
        )
      )
        fail("not-applicable reason is not authorized by policy");
    } else if (Object.hasOwn(event, "notApplicableReason"))
      fail("notApplicableReason only applies to not_applicable reviews");
    if (sameBinding(event, context)) history.reviews.set(event.lane, event);
  } else {
    if (!policy.dispositionActors.includes(event.actorId))
      fail("disposition actor is not authorized");
    if (event.actorId === context.authorId)
      fail("PR author cannot dispose of a finding");
    pattern(event.findingId, ID, "event.findingId");
    if (!history.findings.has(event.findingId))
      fail("disposition references an unknown finding");
    if (
      !["fixed", "disproved", "accepted_risk", "reopen"].includes(event.action)
    )
      fail("event.action is invalid");
    if (event.action === "accepted_risk")
      utcTime(event.expiresAt, "event.expiresAt");
    else if (Object.hasOwn(event, "expiresAt"))
      fail("expiresAt only applies to accepted_risk dispositions");
    history.dispositions.set(event.findingId, event);
  }
  history.ids.add(event.id);
}

function checkHistory(events, policy, context) {
  if (!Array.isArray(events)) fail("events must be an array");
  const history = historyState();
  for (const event of events)
    checkEvent(event, policy, context, history, false);
  return history;
}

export function validateEvent(event, policy, context, priorEvents) {
  validateScope(policy, context);
  const history = checkHistory(priorEvents, policy, context);
  checkEvent(event, policy, context, history, true);
  return event;
}

export function evaluate({ policy, context, ledger, now }) {
  validateScope(policy, context);
  const time = now instanceof Date ? now.getTime() : utcTime(now, "now");
  if (!Number.isFinite(time))
    fail("now must be a valid explicit evaluation time");
  keys(
    ledger,
    ["schemaVersion", "repository", "pullRequest", "revision", "events"],
    [],
    "ledger",
  );
  if (ledger.schemaVersion !== 1) fail("unsupported ledger schemaVersion");
  repository(ledger.repository);
  integer(ledger.pullRequest, 1, "ledger.pullRequest");
  integer(ledger.revision, 0, "ledger.revision");
  if (
    ledger.repository !== context.repository ||
    ledger.pullRequest !== context.pullRequest
  )
    fail("ledger scope does not match current pull request");
  if (!Array.isArray(ledger.events) || ledger.revision !== ledger.events.length)
    fail("ledger revision does not equal event count");
  const history = checkHistory(ledger.events, policy, context);
  const reasons = [];
  const pendingReviews = [];
  const openFindings = [];
  if (context.draft)
    reasons.push({
      code: "DRAFT",
      message: "Draft pull requests cannot pass acceptance.",
    });
  if (context.state !== "OPEN")
    reasons.push({ code: "PR_NOT_OPEN", message: "Pull request is not open." });
  if (context.headAssociationCount !== 1)
    reasons.push({
      code: "SHARED_HEAD",
      message: "Head commit is associated with multiple pull requests.",
    });
  for (const name of policy.requiredReviews) {
    const review = history.reviews.get(name);
    if (!review || review.outcome === "error") {
      pendingReviews.push(name);
      reasons.push({
        code: review ? "REVIEW_ERROR" : "REVIEW_MISSING",
        message: `Required review ${name} has no successful result for the current head/base/policy.`,
      });
    }
  }
  for (const [findingId, finding] of history.findings) {
    const disposition = history.dispositions.get(findingId);
    let code;
    if (!disposition || disposition.action === "reopen") code = "FINDING_OPEN";
    else if (!sameBinding(disposition, context)) code = "DISPOSITION_STALE";
    else if (
      disposition.action === "accepted_risk" &&
      utcTime(disposition.expiresAt, "event.expiresAt") <= time
    )
      code = "RISK_ACCEPTANCE_EXPIRED";
    if (code) {
      const blocking = finding.priority <= policy.blockingPriorityMax;
      openFindings.push({
        findingId,
        title: finding.title,
        priority: finding.priority,
        path: finding.path,
        blocking,
      });
      if (blocking)
        reasons.push({
          code,
          message: `Finding ${findingId} has no current valid disposition.`,
          findingId,
        });
    }
  }
  return {
    schemaVersion: 1,
    decision: reasons.length ? "hold" : "pass",
    reasons,
    identity: {
      repository: context.repository,
      pullRequest: context.pullRequest,
      headSha: context.headSha,
      baseSha: context.baseSha,
      policyDigest: context.policyDigest,
      ledgerRevision: ledger.revision,
    },
    pendingReviews,
    openFindings,
  };
}
