---
template_version: 1
template_name: proposal
proposal_id: 4
parent_problem: ../problem.md
---

# Proposal 4: Adversarial fail-loud — hook-blocked invariants plus a verdict-log read model

## Approach

Treat operability and hygiene as an adversarial problem: enumerate exact
failure constructions, derive one mechanism per construction that fails
**loud** (refuses to spawn, refuses to merge, opens an issue, paints the
dashboard red), and unify them through a single append-only verdict log
(`.factory/verdicts.ndjson`) served by a tiny Datasette/SQLite read
model. Hooks under `.claude/hooks/` enforce pre-spawn invariants; CI
workflows enforce post-merge invariants; both write the same verdict
records the dashboard reads. No mechanism may exit 0 on a precondition
it cannot evaluate — the canonical exit codes are PASS (0),
FAIL (non-zero), and BLOCKED (non-zero with reason). There is no SKIP.

## Rationale

The complecting hypothesis names three weaves: state-vs-where-you-look,
hygiene-vs-agent-discipline, and invariant-checking-vs-attention. A
prose rule and a dashboard that *aggregates* state do not break those
weaves — they ride on top of agents continuing to follow the rule. The
decomplecting move is to deny the action when the precondition fails
(hook) and to make the *only* path that produces a verdict the path
that writes the verdict to the read model (no out-of-band manual
entry). The adversarial framing is load-bearing: each construction
below is a concrete production failure observable today (61 orphan
`worktree-agent-*` branches in `refs/heads/` at the moment this
proposal was written, out of 599 total local branches), and the
mechanism is chosen so that *the construction cannot occur silently*.
Diversity vs sibling proposals: where Proposal 1/2/3 are likely to
lean on `:tau_web` LiveView or GitHub Projects as the surface, this
proposal commits to a minimal flat-file substrate (NDJSON +
SQLite-from-NDJSON + Datasette) so the read model has no shared mutable
state with Tau's runtime — the dashboard cannot be downed by a Tau
crash, and the verdict log is `grep`-able in an outage.

## Sketch

### Adversarial failure constructions and mechanisms

Five concrete constructions, each a real failure mode observed in v1 or
constructible today.

---

**Construction A — orphan worktree-agent-* branch accumulation.**

*Construction.* An implementer spawns with `isolation: worktree` into
`worktree-agent-<id>`. The agent is killed mid-run; its worktree at
`~/.tau/worktrees/<uuid>/` is force-removed without `git branch -D`;
the branch persists in `refs/heads/`. Repeat across 60+ sessions; the
parent repo accumulates 61 orphan `worktree-agent-*` branches (current
empirical count, `git for-each-ref refs/heads/ | grep -c
'^worktree-agent-' = 61`), invisibly until someone greps for them.

*Mechanism — `branch-orphan-sweeper` (CI workflow, scheduled +
post-merge).* A workflow at `.github/workflows/branch-hygiene.yml`
runs on every `push` to `main` and hourly via `schedule:`. It executes:

```bash
git for-each-ref refs/heads/ --format='%(refname:short) %(committerdate:unix)' \
  | awk '$1 ~ /^worktree-agent-/ || $1 ~ /^tau\/coding-agent\// {print}' \
  > /tmp/agent-branches.txt
```

For each candidate it checks `gh worktree list` (does any registered
worktree still hold the branch?) and `gh pr list --head <branch>`
(does an open PR claim it?). Branches with neither are appended to
`.factory/verdicts.ndjson` as `{kind: "orphan_branch", branch: ...,
age_seconds: ...}` and deleted via `git push origin :<branch>` (remote)
plus `git branch -D` (local-on-the-runner does not apply; the deletion
is the remote push). The workflow writes a verdict `{gate:
"branch-hygiene", status: "PASS"|"FAIL", orphans_swept: N}` regardless
of whether any orphans existed. If `gh` is unavailable the verdict is
`BLOCKED` and the workflow exits non-zero. **Silent-skip impossibility:**
the workflow has no conditional that exits 0 without writing a verdict;
the verdict-writing step is `set -euo pipefail` and runs unconditionally.

---

**Construction B — parent on stale main when an agent is spawned.**

*Construction.* The coordinator merged a PR an hour ago but the same
session never ran `git pull --ff-only`. Local `main` is at commit X,
`origin/main` is at commit Y (X is Y's parent). The coordinator now
spawns `implementer` with `isolation: worktree`. The worktree forks
from X, not Y. The implementer's PR diff is computed against a stale
base; the gate evaluates a diff that includes the previous PR's
contents as if they were new work.

*Mechanism — `pre-spawn-parent-on-main` (`PreToolUse` hook on
`Task`).* `.claude/hooks/pre-spawn-check.py` registered in
`.claude/settings.json` under `hooks.PreToolUse` with matcher `Task`:

```python
# .claude/hooks/pre-spawn-check.py
# Python stdlib only (per .claude/rules/hooks-and-scripts.md).
import json, subprocess, sys, time, pathlib

def run(*a): return subprocess.run(a, capture_output=True, text=True, check=False)

def fail(reason, recovery):
    verdict = {"ts": time.time(), "gate": "pre-spawn", "status": "BLOCKED",
               "reason": reason, "recovery": recovery}
    log = pathlib.Path(".factory/verdicts.ndjson")
    log.parent.mkdir(exist_ok=True)
    with log.open("a") as f: f.write(json.dumps(verdict) + "\n")
    print(f"BLOCKED: {reason}\nRecovery: {recovery}", file=sys.stderr)
    sys.exit(2)  # PreToolUse non-zero exit blocks the tool call.

# Invariant 1: parent HEAD is on main.
branch = run("git", "branch", "--show-current").stdout.strip()
if branch != "main":
    fail(f"parent HEAD on '{branch}', not main",
         "git checkout main && git pull --ff-only origin main")

# Invariant 2: local main == origin/main.
run("git", "fetch", "--quiet", "origin", "main")
local = run("git", "rev-parse", "main").stdout.strip()
remote = run("git", "rev-parse", "origin/main").stdout.strip()
if local != remote:
    fail(f"local main {local[:8]} != origin/main {remote[:8]}",
         "git pull --ff-only origin main")

# Invariant 3: no untracked leaks in parent (signal of prior reviewer collision).
status = run("git", "status", "--porcelain").stdout
if status.strip():
    fail("parent worktree dirty: " + status[:200],
         "inspect with 'git status'; clean before spawning")

print("pre-spawn OK", file=sys.stderr)
sys.exit(0)
```

The hook writes a PASS verdict on success too (every spawn produces
exactly one pre-spawn verdict). **Silent-skip impossibility:** the
hook is registered under `PreToolUse` for the `Task` matcher; the
Claude Code harness invokes it before every Task call. If the hook
script itself errors (Python missing, file deleted), Claude Code
treats the hook as failed and blocks the tool call by default — there
is no path where the hook is registered but does not run.

---

**Construction C — one gate silently mis-wired and no signal of it.**

*Construction.* `ci.yml` line 89-91 (verified at this proposal's
authoring) reads `if [ -z "$GATING_FILES" ]; then echo "...skipping";
exit 0; fi` — Gate 5.1 exits 0 when no gating-test paths are declared.
A PR author who forgets the "Gating-test paths" section gets a green
gate on a PR that was never actually checked. Same shape at lines
213-216 (Gate 5.3). Gate 5.2 has `|| true` at line 115 making any
failure non-blocking. The dashboard, the PR check status, and the
coordinator's `gh pr checks` output all say PASS. The mis-wire is
indistinguishable from a real pass.

*Mechanism — `gate-self-report contract + skipless-gate auditor`.*
Every gate (CI step or hook) MUST `POST` a verdict record to the
verdict log with one of three statuses: `PASS`, `FAIL`, `BLOCKED`.
`SKIP` is not a permitted status — a gate that has nothing to check on
this PR returns `PASS` with `findings: []` and `applicable: false`; a
gate that cannot run for infrastructure reasons returns `BLOCKED`,
which is treated as `FAIL` by branch protection. The mix tasks
`mix tau.gate.ac_linkage|masking|mutation` are wrapped in a shell
helper `bin/factory-gate` that:

```bash
#!/usr/bin/env bash
# bin/factory-gate <gate-name> -- <cmd...>
set -euo pipefail
gate="$1"; shift; shift  # drop "--"
start_ts=$(date +%s)
if out=$("$@" 2>&1); then status=PASS; else status=FAIL; fi
end_ts=$(date +%s)
jq -nc --arg g "$gate" --arg s "$status" --arg out "$out" \
  --argjson start "$start_ts" --argjson end "$end_ts" \
  --arg pr "${PR_NUMBER:-}" --arg sha "${GITHUB_SHA:-}" \
  '{ts: $end, gate: $g, status: $s, pr: $pr, sha: $sha,
    duration_s: ($end - $start), output: $out}' \
  >> .factory/verdicts.ndjson
[ "$status" = PASS ]
```

Every CI step that *is* a gate is rewritten to call `bin/factory-gate
<name> -- <cmd>`. The `branch-hygiene` workflow includes a
**skipless-gate auditor** that greps `.github/workflows/*.yml` for
the forbidden patterns:

```bash
# Forbidden patterns in any workflow file:
#   - exit 0$ inside a step whose name matches /Gate [0-9]/
#   - || true at the end of a 'mix tau.gate.' line
#   - if: github.event_name == 'pull_request'  on a gate step  (gates run on push too)
grep -nE '(exit 0|\|\| true)' .github/workflows/*.yml \
  | grep -E 'Gate [0-9]|tau\.gate\.' && exit 1 || true
```

The auditor itself uses `bin/factory-gate` so its verdict shows on the
dashboard. **Silent-skip impossibility:** branch protection on `main`
requires the *named* gate checks; if a CI step is renamed or
disappears, branch protection blocks the merge with "Required status
check X is missing." The verdict log is append-only — the read model
flags any PR that merged with `< N` verdicts (where N is the expected
gate count for the diff's surface).

---

**Construction D — CI status visible only via gh CLI, not from a
single dashboard.**

*Construction.* The operator wants to know "what's broken." Today they
must run `gh pr list`, then `gh pr checks <n>` for each, then
`gh run view <id>` to read failure detail, then `git log
--all --grep` to find the four most recent merges that bypassed the
gate (#411-#414 per root §Hypothesis). State is reconstructible only
by hand. The dashboard claim in `:tau_web` (SPEC-WEB-DASHBOARD)
remains aspirational — `web/lib/tau_web/live/` exists but is empty.

*Mechanism — `factory-dashboard`: Datasette over the verdict log.*
A scheduled GitHub Action (`.github/workflows/dashboard-publish.yml`)
runs every 5 minutes on `main` and on every workflow completion:

```yaml
# Pseudocode of the publish step
- run: |
    # Rebuild SQLite from the append-only verdict log.
    python3 bin/verdicts-to-sqlite.py \
      .factory/verdicts.ndjson \
      .factory/dashboard.db
    # Add live-queried tables (orphan branches, stale-main, open PRs).
    bin/factory-state-snapshot >> .factory/snapshots.ndjson
    python3 bin/snapshots-to-sqlite.py \
      .factory/snapshots.ndjson \
      .factory/dashboard.db
    # Publish via Datasette to GitHub Pages or a small Fly.io app.
    datasette publish vercel .factory/dashboard.db \
      --project=tau-factory --metadata bin/datasette-metadata.yml
```

The dashboard has named SQL views: `gate_health_last_50_prs`,
`orphan_branches`, `stale_main_violations`, `silent_skip_audit`,
`mainline_coherence`, `open_audit_findings`. Each view has a known
schema; if a view query errors, the dashboard renders a red panel with
the SQL error (NOT a blank panel). The verdict log is in-repo,
git-versioned, `grep`-able in an outage, and survives the dashboard
service being down. **Silent-skip impossibility:** the publish workflow
itself uses `bin/factory-gate dashboard-publish -- ...` so a publish
failure writes a `FAIL` verdict that the *next* run's dashboard shows.

---

**Construction E — the operator cannot see why merges are failing
without reading git log.**

*Construction.* Four merges (#411-#414) landed against red CI per root
§Hypothesis #7. The reason was distributed: PR-body `mix output` cited
as evidence, CI status not consulted, branch protection not enforcing
on `main`. To diagnose, an operator today runs `git log --merges
--first-parent main -20`, then `gh pr view <n>` for each, then
`gh pr checks <n> --json conclusion`, then cross-references with
`.claude/logs/solution-tree.json`. The root cause is rebuildable only
by hand.

*Mechanism — `merge-postmortem-extractor` plus branch protection
mandating the verdict-log evidence.* (i) `main` has branch protection
configured (via `.github/branch-protection.json` checked in and
applied by a workflow): required checks include every gate name plus
a `factory-verdict-coverage` check that fails if the PR does not have
the expected verdict count in `.factory/verdicts.ndjson` keyed by PR
number. (ii) Every push to `main` runs `bin/merge-postmortem` which:

```python
# bin/merge-postmortem (sketch)
# For the new merge commit on main:
#   - find the PR via `gh pr list --search 'merged sha:<sha>'`
#   - load all verdicts where pr == <number>
#   - assert: gate_count >= expected_for_surface(diff)
#   - assert: every verdict.status in {PASS}
#   - if any FAIL or BLOCKED: write a {kind: "post_merge_violation",
#     pr: ..., violations: [...]} verdict AND open an issue via
#     `gh issue create --label factory-violation,P0`
#   - else: write {kind: "post_merge_clean", pr: ..., gate_count: ...}
```

The dashboard has a `merges-vs-verdicts` view that lists every merge
to `main` for the last 30 days with its verdict coverage; merges with
`< expected_for_surface` or any non-PASS verdict are highlighted red.
**Silent-skip impossibility:** the postmortem step uses
`bin/factory-gate post-merge-coverage -- bin/merge-postmortem`. If the
script errors, that becomes a FAIL verdict the dashboard surfaces. If
the workflow itself doesn't run, the next scheduled hourly run of
`branch-hygiene` includes a "merges without postmortem" auditor that
walks `git log --merges` and cross-references the verdict log.

---

### Generalisation

The pattern across all five constructions is identical:

1. **Construct.** Name the exact failure (with grep-able evidence
   from the current repo where possible).
2. **Deny or detect.** Either a `PreToolUse` hook denies the action,
   or a CI workflow detects after the fact and writes a FAIL verdict.
3. **Write a verdict.** The mechanism appends an NDJSON record to
   `.factory/verdicts.ndjson` with `{ts, gate, status, pr, sha,
   details}`. There is no "did not run" outcome — every invocation
   produces a verdict.
4. **Surface in the read model.** Datasette renders verdicts and
   live-queried state side by side; each view fails red if its data
   source errors.
5. **Block the merge.** Branch protection on `main` requires named
   gate checks and a `factory-verdict-coverage` synthetic check;
   no missing-check or non-PASS verdict can be merged.

This generalises to every future failure class: write the
construction, write the mechanism that fails on it, register the
verdict gate, add a Datasette view. The verdict log is the universal
substrate.

### Silent-skip impossibility — the global proof obligation

Three independent layers prevent silent-skip:

- **No `SKIP` status exists.** The `bin/factory-gate` wrapper emits
  only `PASS|FAIL|BLOCKED`; a gate with nothing to check returns
  `PASS, applicable: false` (still a verdict). The current
  `exit 0` patterns in `ci.yml:89,97,213,219` and the `|| true` at
  `:115` are explicit targets of the skipless-gate auditor.
- **Branch protection requires named checks.** Renaming or removing a
  gate step in `ci.yml` makes the required check go "missing," which
  branch protection treats as failure. No PR can merge by dropping
  the gate.
- **Verdict coverage is itself a gate.** `factory-verdict-coverage`
  fails any PR whose `.factory/verdicts.ndjson` entries for that PR
  number do not match the expected count for the surface the diff
  touches (derived from a static table mapping changed-file globs to
  expected gates). The auditor's auditor.

A silent-skip therefore requires defeating all three layers
simultaneously: tamper with `bin/factory-gate`, mutate branch
protection, and either delete or forge verdict records. The verdict
log is append-only and git-versioned; tampering shows in the diff.

### Concrete artifacts

| Artifact | Path |
| --- | --- |
| Pre-spawn hook | `.claude/hooks/pre-spawn-check.py` |
| Hook registration | `.claude/settings.json` `hooks.PreToolUse` |
| Gate wrapper | `bin/factory-gate` |
| Verdict log | `.factory/verdicts.ndjson` (in-repo, append-only) |
| Snapshot log | `.factory/snapshots.ndjson` (in-repo) |
| Dashboard DB | `.factory/dashboard.db` (built artefact, .gitignored) |
| Branch hygiene workflow | `.github/workflows/branch-hygiene.yml` |
| Dashboard publish workflow | `.github/workflows/dashboard-publish.yml` |
| Merge postmortem | `bin/merge-postmortem` |
| Skipless-gate auditor | `bin/skipless-gate-audit` |
| Branch protection config | `.github/branch-protection.json` (declarative) |
| Datasette metadata | `bin/datasette-metadata.yml` |
| Verdict→SQLite ETL | `bin/verdicts-to-sqlite.py` (Python stdlib only) |

## Tradeoffs

### Strengths

- **Failure-construction provenance.** Every mechanism traces to a
  specific construction with current-repo evidence (61 orphans, the
  three `exit 0` line numbers, the `|| true`). Reviewing the proposal
  is reviewing falsifiable claims, not aspirations.
- **Decomplects on the right axes.** Hooks deny actions (breaks
  hygiene-vs-discipline). Verdict log unifies state
  (breaks state-vs-where-you-look). Pre-spawn check denies on
  precondition violation (breaks invariant-checking-vs-attention).
- **No new runtime substrate.** NDJSON + SQLite + Datasette are
  language-independent, `grep`-able in an outage, and survive
  `:tau_web` being down. The read model and Tau's runtime share
  nothing — a Tau crash cannot break dashboard observation of the
  crash.
- **Silent-skip impossibility is layered, not assumed.** Three
  independent layers (no SKIP status, branch protection, verdict
  coverage gate) must all fail simultaneously for a silent skip; the
  proof is in the layering, not in a single claim.
- **Adversarial-by-default.** Future failure classes are added by
  writing a new construction + mechanism pair; the pattern
  generalises rather than the spec growing case-by-case sections.
- **Acceptance criterion fully addressed.** (a) dashboard via
  Datasette; (b) auto-populated by gates writing the log directly,
  red-on-error views; (c) pre-spawn hook with recovery command;
  (d) post-merge workflow that fails loud and opens issues;
  (e) reuse-vs-build is explicit (Datasette + GitHub Actions reused,
  bespoke is only the gate wrapper and verdict schema); (f) concrete
  artefacts table above.

### Weaknesses

- **Datasette dependency.** Introduces a Python tool to the
  deployment surface (publish step needs `pip install datasette` on
  the Action runner). Mitigated by pinning a Datasette version in
  the workflow; failure to install yields a BLOCKED verdict, not a
  silent skip. Operator must learn one new tool.
- **NDJSON log can grow unbounded.** Mitigated by a monthly rotation
  workflow that archives `.factory/verdicts-YYYY-MM.ndjson` and
  re-derives the SQLite. Untested at scale; first rotation will
  surface issues.
- **`PreToolUse` hook adds latency to every Task spawn.** ~50-200ms
  for the git fetch. Acceptable for the coordinator pattern (low
  spawn rate). Hot paths (per-message hooks) are not in scope here.
- **No real-time push.** The dashboard updates every 5 minutes;
  during a fast-moving incident the operator may want sub-minute
  freshness. Mitigated by running `datasette serve` locally against
  the live `.factory/verdicts.ndjson`; the deployed dashboard is for
  shared visibility, not real-time triage.
- **Branch-protection-as-code is partial.** GitHub branch protection
  cannot be 100% declarative via API for all settings; the
  `.github/branch-protection.json` plus apply-workflow approach
  drifts if changed in the GitHub UI. Mitigated by a daily
  reconciliation workflow that diffs the live config against the
  checked-in JSON and writes a FAIL verdict on drift.
- **Operator must learn the verdict schema.** New concept; learning
  cost. Mitigated by `bin/factory-gate --help` printing the schema
  and an example, and by every verdict including its own field names
  via NDJSON keys (self-describing).
- **Does not detect** under-asserting or wrong-path tests (root
  §Hypothesis #6 residual). Owned by the AC-binding sibling. This
  proposal *displays* the AC-binding sibling's verdicts but does not
  produce them.

### Costs

- **Migration.** Replace ~8 CI steps with `bin/factory-gate` wraps
  (mechanical, ~2 hours). Write hooks + verdict ETL (~1 day).
  Stand up Datasette + initial views (~1 day). Configure branch
  protection from JSON (~2 hours; cannot be tested until landed).
- **Operational.** Add `datasette` to the Action runner image
  (`pip install`, cached); add a Vercel/Fly.io deployment target
  (free tier suffices at expected verdict volume).
- **Disruption.** First few PRs after landing will likely fail on
  `factory-verdict-coverage` until the expected-gate-count table
  matches the actual gate set. Mitigated by landing the gate in
  warn-only mode for the first week (verdicts written, dashboard
  surfaces, branch protection not yet requiring it), then flipping.
- **Knowledge.** Operator learns: the verdict schema; Datasette
  query basics; the `bin/factory-gate` wrapper; hook script
  conventions per `.claude/rules/hooks-and-scripts.md`. Estimated
  one-afternoon onboarding.
- **Build / deps.** Adds Python `datasette` to CI runners (already
  has Python 3.10 for `ex_termbox` waf per `ci.yml:36-40`). No new
  Elixir deps. No new in-tree runtime processes.

## Dependencies

- `.claude/rules/hooks-and-scripts.md` permits Python stdlib hooks;
  this proposal stays within stdlib (`json`, `subprocess`,
  `pathlib`, `sys`, `time`, `os`). No `pip install` for the hook
  itself (Datasette is publish-only, on the runner, not in-tree).
- `.claude/rules/worktree-discipline.md` provides the invariant
  prose this proposal mechanises. The rule's "capture-before-destroy"
  sequence and the canonical recovery procedure are referenced as-is.
- Branch protection on `main` must be configurable via the
  `.github/branch-protection.json` + apply-workflow pattern (GitHub
  API supports this for most fields).
- Sibling proposals must adopt `bin/factory-gate` as the gate
  wrapper. If sibling **pre-merge-code-gates** chooses a different
  evidence format, the verdict-log unification fails. Coordination
  required at selection time across sibling leaves.
- The empty `web/lib/tau_web/live/` directory implies SPEC-
  WEB-DASHBOARD's LiveView is not yet implemented. This proposal
  does NOT require it (deliberate: avoids coupling factory
  observability to Tau's runtime), but if a LiveView dashboard is
  later built, it can read the same `.factory/verdicts.ndjson` log
  and serve it as a second consumer.

## Confidence

**High** on the construction and mechanism side: every construction
has current-repo evidence and a deterministic mechanism with named
artefacts. **Medium** on the deployment side: Datasette + Vercel/Fly
is a known pattern but not yet in this repo; first rollout will
surface integration friction. **Confidence raising:** prototype the
`pre-spawn-check.py` hook plus `bin/factory-gate` plus one
`.github/workflows/branch-hygiene.yml` workflow against a throwaway
fork, demonstrate it blocks the construction-A and construction-B
scenarios end-to-end before declaring done.

## Prior art / references

- Datasette as a fail-loud-by-default read model:
  <https://datasette.io> — Simon Willison's pattern of "publish a
  SQLite database as a queryable HTTP API" is well-trodden, used by
  the New York Times and others for journalism dashboards.
- Append-only NDJSON event logs as the universal substrate: the
  Honeycomb / Lightstep observability pattern; in-repo precedent in
  `.claude/logs/observations.jsonl` already adopted.
- `PreToolUse` hooks blocking on invariant violation: documented in
  Claude Code's hook system; the precedent is the `.claude/hooks/`
  directory already used in this repo.
- Branch-protection-as-code: GitHub's REST API
  `repos/:owner/:repo/branches/:branch/protection` PUT endpoint;
  Terraform's `github_branch_protection` resource is the canonical
  declarative form, but for a single repo a JSON-plus-workflow
  approach is sufficient.
- The `worktree-discipline.md` rule's prose recovery procedure is
  the source-of-truth for what the workflows mechanise; this
  proposal does not invent new invariants, only enforces existing
  ones.
- Adversarial construction as a design method: standard in
  security review (STRIDE, attack-tree analysis) and increasingly in
  ML eval (red-teaming). The novelty here is applying it to a
  developer-tools factory's observability surface.
