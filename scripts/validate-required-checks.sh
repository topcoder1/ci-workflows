#!/usr/bin/env bash
# validate-required-checks.sh — verify a repo's required-status-check contexts
# are actually produced by a workflow that triggers on pull_request.
#
# Catches the "phantom required check" class of bug: a context is in the
# branch ruleset but no workflow ever reports a status with that name on PRs,
# so PRs hang forever on a status that will never arrive.
#
# Usage:
#   validate-required-checks.sh <owner/repo> [--ruleset-name "main-protection*"]
#                                            [--branch main]
#                                            [--strict]   # exit 1 on warnings too
#
# Exits 0 if every required context has a pull_request-triggered job that
# produces it, non-zero with a clear report otherwise.
#
# What it checks for each context:
#   - finds the workflow whose top-level `name:` matches the prefix before " / "
#     (or any workflow if the context has no slash)
#   - finds a job inside it whose `name:` matches the part after " / " (or the
#     whole context if no slash)
#   - confirms that workflow's `on:` block includes `pull_request`
#
# Limitations (v1):
#   - Reports `unverified` (warning, not error) for contexts that look like
#     external services (Semgrep cloud, CodeQL, etc.) since their workflows
#     may live outside this repo. Use --strict to fail on warnings too.
#   - Caller workflows (`uses: org/repo/.github/workflows/foo.yml@ref`) are
#     resolved via gh API into the central ci-workflows repo when possible.

set -euo pipefail

REPO="${1:-}"
RULESET_NAME_GLOB="main-protection*"
BRANCH="main"
STRICT=0

if [[ -z "$REPO" ]]; then
  echo "Usage: $0 <owner/repo> [--ruleset-name <glob>] [--branch <name>] [--strict]" >&2
  exit 2
fi
shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ruleset-name) RULESET_NAME_GLOB="$2"; shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    --strict) STRICT=1; shift ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

command -v gh >/dev/null || { echo "gh CLI required" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq required" >&2; exit 2; }
command -v python3 >/dev/null || { echo "python3 required" >&2; exit 2; }

echo "==> Validating required status checks for $REPO (branch: $BRANCH)"

# 1. Fetch ruleset for the branch and pull required contexts.
#    Use the branch-rules endpoint (lists rulesets that apply to a branch),
#    then filter to the matching ruleset name.
RULESET_DATA=$(gh api "/repos/$REPO/rules/branches/$BRANCH" 2>/dev/null || true)
if [[ -z "$RULESET_DATA" || "$RULESET_DATA" == "null" ]]; then
  echo "  no branch rules found for $BRANCH" >&2
  exit 0
fi
CONTEXTS=$(echo "$RULESET_DATA" | jq -r \
  --arg glob "$RULESET_NAME_GLOB" \
  '.[]
   | select(.type=="required_status_checks")
   | select((.ruleset_source_type // "") | ascii_downcase == "repository" or true)
   | .parameters.required_status_checks[]?.context' \
  | sort -u)

if [[ -z "$CONTEXTS" ]]; then
  echo "  no required_status_checks rule on $BRANCH"
  exit 0
fi

CTX_COUNT=$(echo "$CONTEXTS" | wc -l | tr -d ' ')
echo "  found $CTX_COUNT required context(s):"
echo "$CONTEXTS" | sed 's/^/    - /'
echo

# 2. List workflow files in target repo + the central ci-workflows reusable
#    workflows. Cache contents in a temp dir so we don't hammer the API.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

dump_workflows() {
  local repo="$1"
  local out_dir="$2"
  mkdir -p "$out_dir"
  local listing
  listing=$(gh api "/repos/$repo/contents/.github/workflows" 2>/dev/null || echo '[]')
  echo "$listing" | jq -r '.[]? | select(.name | endswith(".yml") or endswith(".yaml")) | .name' | while read -r f; do
    [[ -z "$f" ]] && continue
    gh api "/repos/$repo/contents/.github/workflows/$f" --jq '.content' 2>/dev/null \
      | base64 -d > "$out_dir/$f" || true
  done
}

dump_workflows "$REPO" "$TMP/target"
dump_workflows "topcoder1/ci-workflows" "$TMP/central"

# 3. For each context, parse YAML and look for a (workflow_name, job_name) match.
#    Done in Python because shell-level YAML parsing is masochism.
export TMP CONTEXTS_FILE STRICT
CONTEXTS_FILE="$TMP/contexts.txt"
echo "$CONTEXTS" > "$CONTEXTS_FILE"

EXIT=0
python3 - <<'PY' && RC=$? || RC=$?
import os, sys, glob, re

try:
    import yaml
except ImportError:
    print("  ! python3-yaml not installed; falling back to regex parser", file=sys.stderr)
    yaml = None

contexts = [l.strip() for l in open(os.environ["CONTEXTS_FILE"]) if l.strip()]
strict = os.environ.get("STRICT") == "1"
tmp = os.environ["TMP"]

# External-service contexts we don't fail on if not found locally.
KNOWN_EXTERNAL = {
    'codeql', 'snyk', 'sonarcloud', 'codacy', 'codecov',
}

def parse_workflow(path):
    """Return (workflow_name, jobs_by_name, on_keys) — robust enough for our needs."""
    txt = open(path).read()
    if yaml:
        try:
            doc = yaml.safe_load(txt) or {}
        except yaml.YAMLError:
            return None, {}, set()
        wname = doc.get('name', os.path.basename(path).rsplit('.', 1)[0])
        on = doc.get('on') or doc.get(True) or {}  # PyYAML quirk: `on:` can parse to True
        if isinstance(on, str):
            on_keys = {on}
        elif isinstance(on, list):
            on_keys = set(on)
        elif isinstance(on, dict):
            on_keys = set(on.keys())
        else:
            on_keys = set()
        jobs = {}
        job_ids = set()
        for jid, jdef in (doc.get('jobs') or {}).items():
            job_ids.add(jid)
            if isinstance(jdef, dict):
                # Stash the raw `if:` expression on the job dict so callers
                # can inspect whether the job will actually run on PRs.
                jdef = dict(jdef)
                jdef['_if_expr'] = jdef.get('if', '')
                jname = jdef.get('name', jid)
                jobs[jname] = jdef
                jobs[jid] = jdef  # match either display name or job id

                # Matrix template expansion: a job with
                #   name: Test (Python ${{ matrix.python-version }})
                #   strategy.matrix.python-version: [3.9, 3.11, 3.12]
                # produces three actual checks at runtime — register each
                # expansion so required-context lookups can match them.
                # Without this, every matrix-templated check reports as
                # phantom (false positive).
                strat = jdef.get('strategy') or {}
                mat = strat.get('matrix') if isinstance(strat, dict) else None
                if isinstance(mat, dict) and isinstance(jname, str) and '${{' in jname:
                    import re as _re
                    tpl_pat = _re.compile(r"\$\{\{\s*matrix\.([\w-]+)\s*\}\}")
                    refs = tpl_pat.findall(jname)
                    if refs and all(k in mat and isinstance(mat[k], list) for k in refs):
                        # Cross-product over referenced matrix axes only
                        # (other axes don't affect the name).
                        axes = [(k, [str(v) for v in mat[k]]) for k in refs]
                        from itertools import product
                        for combo in product(*[v for _, v in axes]):
                            expanded = jname
                            for (k, _), val in zip(axes, combo):
                                expanded = expanded.replace(
                                    "${{ matrix." + k + " }}", val
                                ).replace(
                                    "${{matrix." + k + "}}", val
                                )
                            jobs[expanded] = jdef
        return wname, jobs, job_ids, on_keys
    # Fallback regex parser (best-effort)
    wname = None
    on_keys = set()
    jobs = {}
    job_ids = set()
    m = re.search(r'^name:\s*(.+)$', txt, re.M)
    if m: wname = m.group(1).strip().strip('"\'')
    on_match = re.search(r'^on:\s*(.+?)^\S', txt, re.M | re.S)
    if on_match:
        on_text = on_match.group(1)
        for trigger in ('pull_request', 'push', 'workflow_run', 'workflow_dispatch', 'schedule'):
            if re.search(rf'\b{trigger}\b', on_text):
                on_keys.add(trigger)
    for jm in re.finditer(r'^\s{2}([\w-]+):\s*$\n\s+name:\s*(.+)$', txt, re.M):
        jobs[jm.group(2).strip().strip('"\'')] = {}
        jobs[jm.group(1)] = {}
        job_ids.add(jm.group(1))
    return wname, jobs, job_ids, on_keys

# Index every workflow we have access to.
index = []  # list of (workflow_name, jobs_dict, job_ids_set, on_keys, source_label, file)
for src in ("target", "central"):
    for f in sorted(glob.glob(os.path.join(tmp, src, "*.yml")) +
                    glob.glob(os.path.join(tmp, src, "*.yaml"))):
        wname, jobs, job_ids, on_keys = parse_workflow(f)
        index.append((wname, jobs, job_ids, on_keys, src, os.path.basename(f)))

def job_excluded_from_prs(if_expr):
    """Heuristic: does this `if:` guarantee the job WON'T run on pull_request?

    Returns (excluded, reason). Conservative — only flags well-known
    push-only patterns to avoid false positives on complex expressions.
    Patterns flagged:
      - `github.event_name == 'push'` (string literal, no PR alternative)
      - `github.ref == 'refs/heads/main'` style (PRs have refs/pull/N/merge)
      - `github.event_name != 'pull_request'`
    Patterns NOT flagged (treated as runs-on-PR by default):
      - empty string
      - any `if:` that mentions `pull_request` literally
      - anything else
    """
    if not if_expr:
        return False, ""
    s = str(if_expr).strip()
    # Strip the optional ${{ ... }} wrapper.
    if s.startswith("${{") and s.endswith("}}"):
        s = s[3:-2].strip()
    s_lower = s.lower()
    # Escape clause: if the expr explicitly mentions pull_request, assume
    # the author handled it.
    if "pull_request" in s_lower:
        return False, ""
    # Pattern A: event_name == 'push'  (or "push", or `push` etc.)
    import re as _re
    if _re.search(r"event_name\s*==\s*['\"]push['\"]", s_lower):
        return True, "if: contains event_name == 'push' without a pull_request alternative"
    # Pattern B: event_name != 'pull_request' (already handled above; redundant)
    if _re.search(r"event_name\s*!=\s*['\"]pull_request['\"]", s_lower):
        return True, "if: contains event_name != 'pull_request'"
    # Pattern C: github.ref == 'refs/heads/...'  (PR refs are refs/pull/N/merge)
    if _re.search(r"github\.ref\s*==\s*['\"]refs/heads/", s_lower):
        return True, "if: requires github.ref == 'refs/heads/...' (PRs use refs/pull/N/merge)"
    return False, ""

verdict_lines = []
fail = False
warn = False

for ctx in contexts:
    # Status check name shapes (GitHub):
    #   "Y"        — workflow has a top-level job named Y (rare for required checks)
    #   "X / Y"    — caller workflow has a job whose id is X; that job either uses
    #                a reusable workflow whose internal job display-name is Y, OR
    #                the workflow's display name is X and the job name is Y.
    if ' / ' in ctx:
        head, tail = ctx.split(' / ', 1)
    else:
        head, tail = None, ctx

    # Three plausible match shapes to try, in priority order:
    #   1. caller pattern: a workflow file with a job whose id == head
    #      (the reusable-workflow chain — Y is produced by the called workflow)
    #   2. display-name pattern: workflow.name == head AND a job (id or name) == tail
    #   3. no-slash pattern: any workflow with a job named tail
    matches = []  # (label, on_keys, src, f, if_excluded_reason)
    for wname, jobs, job_ids, on_keys, src, f in index:
        if head is not None:
            if head in job_ids:
                # Caller pattern — Y comes from the reusable workflow that this
                # job uses. Inspect the caller job's `if:` to catch
                # `if: github.event_name == 'push'` etc. that prevent PR runs.
                jdef = jobs.get(head, {})
                excluded, reason = job_excluded_from_prs(jdef.get('_if_expr', ''))
                matches.append(("caller", on_keys, src, f, reason if excluded else ""))
                continue
            if wname == head and tail in jobs:
                jdef = jobs.get(tail, {})
                excluded, reason = job_excluded_from_prs(jdef.get('_if_expr', ''))
                matches.append(("display-name", on_keys, src, f, reason if excluded else ""))
                continue
        else:
            if tail in jobs:
                jdef = jobs.get(tail, {})
                excluded, reason = job_excluded_from_prs(jdef.get('_if_expr', ''))
                matches.append(("direct", on_keys, src, f, reason if excluded else ""))

    if not matches:
        if any(k in ctx.lower() for k in KNOWN_EXTERNAL):
            verdict_lines.append(f"    ⚠  {ctx}\n        (no workflow file found locally — looks external; pass --strict to fail on this)")
            warn = True
        else:
            verdict_lines.append(f"    ✗  {ctx}\n        no caller workflow has a job id '{head}'" if head else
                                 f"    ✗  {ctx}\n        no workflow contains a job named '{tail}'")
            fail = True
        continue

    pr_matches = [m for m in matches if 'pull_request' in m[1]]
    if not pr_matches:
        on_summary = ", ".join(sorted(set(t for m in matches for t in m[1])) or ["<no triggers>"])
        verdict_lines.append(
            f"    ✗  {ctx}\n        matched in {matches[0][2]}/{matches[0][3]}, but workflow's on: only fires for {{{on_summary}}}"
            f"\n        (required-status will never report on PRs — this is the 'phantom check' bug)"
        )
        fail = True
        continue

    # Workflow's on: includes pull_request. But the matched job's `if:`
    # may still exclude PRs (canonical example: `if: github.ref ==
    # 'refs/heads/main' && github.event_name == 'push'` on a deploy job).
    # If every PR-trigger match has an exclusion reason, this is also a
    # phantom check — just one with a deeper hiding place.
    excluded_pr_matches = [m for m in pr_matches if m[4]]
    runnable_pr_matches = [m for m in pr_matches if not m[4]]
    if not runnable_pr_matches:
        m = excluded_pr_matches[0]
        verdict_lines.append(
            f"    ✗  {ctx}\n        matched in {m[2]}/{m[3]}, workflow on: pull_request — but the matched job is gated by an `if:` that excludes PRs"
            f"\n        ({m[4]})"
            f"\n        (required-status will never report on PRs — this is the 'phantom check' bug, job-level variant)"
        )
        fail = True
    else:
        m = runnable_pr_matches[0]
        verdict_lines.append(f"    ✓  {ctx}\n        {m[2]}/{m[3]} ({m[0]} match, triggers: {', '.join(sorted(m[1]))})")

print("\n".join(verdict_lines))
print()
if fail:
    print("==> FAIL: one or more required contexts will never report on PRs.")
    sys.exit(1)
if warn and strict:
    print("==> FAIL (--strict): one or more contexts unverified.")
    sys.exit(1)
print("==> OK: every required context has a pull_request-triggered producer.")
PY

exit $RC
