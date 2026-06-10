---
template_version: 1
template_name: solution
parent_problem: ../problem.md
node_kind: leaf
synthesised_from: [proposals/proposal-2.md, proposals/proposal-4.md, proposals/proposal-1.md]
selection_method: hybrid
revision: 0
---

# Solution: Append-only NDJSON verdict log on disk + Exqlite projector + LiveDashboard `PageBuilder` page; shared Python hook/CI script enforces `parent-on-main` and worktree hygiene; branch-protection + verdict-coverage gate make silent-skip impossible.

## Recommendation

Treat the factory's operability surface as **one append-only verdict log
on disk** (`.factory/verdicts.ndjson`, in-repo, `grep`-able, deployment-
independent) plus **one Elixir projector** (`Tau.Factory.ReadModel`,
supervised under the `:tau_web` poncho per SPEC-WEB-DASHBOARD) that
materialises the log into a small `priv/factory_state.db` SQLite read
model, plus **one LiveDashboard `PageBuilder` page** (`TauWeb.FactoryLive.Page`,
mounted at `/dev/dashboard/factory`). Treat hygiene enforcement as **one
Python script** (`.claude/hooks/factory-hygiene.py`) invoked by both the
Claude Code `PreToolUse(Task)` + `SessionStart` hooks (local enforcement)
and a GitHub Actions cron + push-to-main workflow (remote enforcement) —
so the local and remote enforcement points share a single source-of-truth.
Treat silent-skip as **structurally impossible** via three independent
layers stacked: (i) the verdict schema (`Tau.Factory.Verdict`) admits
only `:pass | :fail | :checked_no_findings | :infra_fail` — no `:skipped`
constructor exists; (ii) a `bin/factory-gate <name> -- <cmd>` shell
wrapper is the only sanctioned producer of verdict records (every CI
gate is wrapped); a meta-`mix tau.factory.gate.assert_complete` task runs
at CI-job tail and fails the job when any declared `gate_id` for the
current `run_id` produced no verdict; (iii) GitHub branch-protection
(`.github/branch-protection.json`, applied by a one-shot workflow)
requires every named gate check AND a synthetic `factory-verdict-coverage`
check on `main`, so a missing or renamed gate is treated as failure by
GitHub itself. The dashboard renders an explicit error state (never a
blank panel) on any data-source error.

## Selected from

- **Chosen:** hybrid of `proposals/proposal-2.md` (substrate +
  enforcement-script unification), `proposals/proposal-4.md` (NDJSON
  append-only verdict log + adversarial constructions + the
  `bin/factory-gate` wrapper + `factory-verdict-coverage` synthetic gate),
  with `proposals/proposal-1.md` contributing **`mix tau.factory.gate.assert_complete`**
  (run-tail verdict-set completeness assertion) and the **`mix tau.factory.emit`**
  validating mutator pattern.
- **Why chosen:** see the comparison table below. No single proposal
  dominated; the hybrid is justified element-by-element rather than as an
  average.

### Score table (acceptance criterion in `../problem.md`)

| # | Fit (AC a–f) | Decomplecting depth | Migration cost | Risk | Reversibility |
|---|---|---|---|---|---|
| 1 — Event-sourced + Mix-task emitter on `:tau_web` | Yes (a–f) | Substantial — one mutator/one reader, but couples log to Elixir runtime via the Mix task | Medium (≈ 900 LOC, ≈ 11 build steps) | Medium — projection is reprojectable but the log artefact lives on GitHub releases, an unusual substrate | Hard — once gates emit through `mix tau.factory.emit`, switching mutators is a rewrite |
| 2 — LiveDashboard + shared Python script + branch-protection | Yes (a–f) | Deep — adopts existing primitives (LiveDashboard PageBuilder, Phoenix.PubSub, `:exqlite`, branch protection); ONE script enforces locally AND in CI | Low–Medium (≈ 830 LOC, ≈ 200 LOC declarative; reuses LiveDashboard) | Low — every dep is already in tree; failure modes are LiveDashboard's well-known failure modes | Easy — every component swappable in isolation (page, projector, script, protection rules) |
| 3 — LiveDashboard read-model + janitor cron + alarm channel | Yes (a–f) | Substantial — but 4 moving parts duplicate state knowledge across read-model, janitor, hook, alarm channel | Medium (≈ 840 LOC across 7 files) | Medium — alarm channel adds an issue-spam circuit-breaker concern; alarm rate-limiting sketched but not specified | Medium — alarm channel and read-model are coupled via `Phoenix.PubSub` topic conventions |
| 4 — Adversarial NDJSON log + Datasette + `bin/factory-gate` + branch protection | Yes (a–f) | Deep — verdict log is the universal substrate, language-independent, `grep`-able in an outage; layered silent-skip impossibility proof | Low–Medium (≈ 600 LOC; Datasette is publish-only) | Medium — Datasette + Vercel/Fly publishing introduces a new deployment surface and Python tool | Easy on substrate (NDJSON is forever-readable); Hard on Datasette deployment if it gets entrenched |

**Why hybrid, not single:** proposal 2 wins on substrate density (every
component is already a load-bearing Tau dep — LiveDashboard, PubSub,
Exqlite — and the shared-script invariant collapses the local/remote
enforcement-drift surface to zero). Proposal 4 wins on silent-skip
proof rigour (the NDJSON-on-disk substrate is `grep`-able when both
Tau and Datasette are down; the `bin/factory-gate` wrapper makes the
verdict-writing path the only sanctioned production path; the
`factory-verdict-coverage` synthetic gate plus branch protection forces
GitHub itself to refuse merges missing verdicts). Proposal 1 wins on
**verdict-set completeness assertion at run tail** — a discrete primitive
proposals 2/4 lack: their schemas reject `:skipped` but neither closes
the case where a gate step is silently omitted from a workflow file.
Proposal 3's PagerDuty-style deduped alarm channel was rejected as
scope-creep (root §Acceptance E asks for a queryable surface; an
issue-opening fallback already covers the "actionable" requirement
through proposal 2's `peter-evans/create-issue-from-file@v5` on workflow
failure).

The combination is more than the sum of parts: the verdict log is the
single source-of-truth (proposal 4); the LiveDashboard page is the
single visual surface (proposal 2); `bin/factory-gate` is the single
producer pipeline (proposal 4); the shared Python script is the
single hygiene-enforcement pipeline (proposal 2); the run-tail
completeness assertion is the single anti-omission backstop (proposal 1);
branch protection is the single load-bearing merge gate (proposals 2 + 4).
Each "single" is a Hickey decomplecting move; none recreates the
others' coupling.

## What changes

The change-set names every concrete artifact. File paths, plugin/agent/
skill/task/workflow/hook/settings/registry/schema entries.

### Read-model substrate (Elixir, under `:tau_web` poncho)

- **`Tau.Factory.Verdict`** (`web/lib/tau/factory/verdict.ex`, new, ≈ 60 LOC):
  the typed envelope. Constructor `Verdict.new!/1` pattern-matches
  `status` against the closed set `[:pass, :fail, :checked_no_findings, :infra_fail]`
  and raises on any other atom; **`:skipped` cannot be constructed**.
  Fields: `id` (ULID), `ts`, `gate_id`, `pr_number`, `run_id`, `sha`,
  `status`, `rationale` (non-empty for any non-`:pass` status —
  validated in constructor), `evidence_url`, `payload`.

- **`Tau.Factory.Log`** (`web/lib/tau/factory/log.ex`, new, ≈ 80 LOC):
  the single sanctioned writer to `.factory/verdicts.ndjson`. One
  function — `append/1` — takes a `%Verdict{}`, JSON-encodes it,
  appends one line with `:file.write/2` in append mode (atomic per
  line up to PIPE_BUF). No reader API here; readers consume the
  projector's SQLite read model.

- **`Tau.Factory.Projector`** (`web/lib/tau/factory/projector.ex`,
  new, ≈ 220 LOC; `GenServer` under `Tau.Factory.Supervisor`):
  reads `.factory/verdicts.ndjson` on startup (warm projection),
  then `:telemetry.attach_many/4` on `[:tau, :factory, :verdict, :written]`
  for incremental projection, plus `:timer.send_interval(60_000, :poll)`
  for the `Tau.Factory.Hygiene.scan/0` git/`gh` snapshot. Owns the
  `priv/factory_state.db` `Exqlite.Connection`. Broadcasts each row
  on `Tau.PubSub` topic `"factory:state"`. Restart strategy `:transient`
  — projector crash is non-fatal; data is reprojectable from the
  NDJSON log.

- **`Tau.Factory.ReadModel.Schema`** (`web/lib/tau/factory/read_model/schema.ex`,
  new, ≈ 100 LOC): the 6-table SQLite schema (`gate_run`, `pr_state`,
  `worktree_state`, `stale_branch`, `main_coherence_run`, `audit_finding`).
  Every status column is `NOT NULL CHECK(status IN ('pass','fail','checked_no_findings','infra_fail'))`.
  **No `NULL` and no `'skipped'`** at the schema layer.

- **`Tau.Factory.ReadModel.Query`** (`web/lib/tau/factory/read_model/query.ex`,
  new, ≈ 150 LOC): pure read API used by `FactoryLive.Page` and
  Mix-task introspection. Functions: `snapshot/0`, `gate_verdicts_for_pr/1`,
  `leaked_worktrees/0`, `stale_branches/0`, `last_main_coherence/0`,
  `open_audit_findings_by_surface/0`, `missing_verdicts/2`.

- **`Tau.Factory.Hygiene`** (`web/lib/tau/factory/hygiene.ex`, new,
  ≈ 80 LOC): pure functions over `git worktree list --porcelain`,
  `git for-each-ref refs/heads/`, and `gh pr list --json headRefName`
  output. Returns `[%Worktree{}]` and `[%StaleBranch{}]` for the
  projector to insert.

- **`Tau.Factory.Supervisor`** (`web/lib/tau/factory/supervisor.ex`,
  new, ≈ 40 LOC): supervises the `Projector`; mounted under
  `TauWeb.Application`'s supervision tree per SPEC-WEB-DASHBOARD's
  poncho convention.

### Visualisation surface (Elixir, under `:tau_web`)

- **`TauWeb.FactoryLive.Page`** (`web/lib/tau_web/live/factory_live/page.ex`,
  new, ≈ 220 LOC): `Phoenix.LiveDashboard.PageBuilder` page mounted
  via `web/lib/tau_web/router.ex` under the existing `live_dashboard
  "/dashboard"` block. Five panels (`gates`, `prs`, `hygiene`,
  `main_coherence`, `audits`) rendered via `nav_bar/1`. **Each panel's
  render function wraps its `Query` call in `case ... do {:ok, ...}
  | {:error, reason} -> render_error_banner(reason) end`** — every
  panel surfaces its data-source failure inline. No blank panel is
  reachable.

- **Router delta** (`web/lib/tau_web/router.ex`, ≈ 5 LOC): inside
  the existing `if Application.compile_env(:tau_web, :dev_routes)`
  block, add `additional_pages: [factory: TauWeb.FactoryLive.Page]`
  to the existing `live_dashboard "/dashboard"` call. The page
  surfaces at `/dev/dashboard/factory` in dev; production-exposure
  is governed by SPEC-WEB-DASHBOARD's auth plug story (out of scope
  here).

### Verdict-production substrate (shell + Mix)

- **`bin/factory-gate`** (new, shell, ≈ 60 LOC, executable; Bash
  with `set -euo pipefail`): the only sanctioned wrapper for a gate
  command. Usage: `bin/factory-gate <gate_id> -- <cmd...>`. Captures
  stdout/stderr; emits one NDJSON record to `.factory/verdicts.ndjson`
  with `{ts, gate_id, pr_number, run_id, sha, status, rationale,
  output_head, output_tail, evidence_url}` regardless of pass/fail.
  Status is `pass` if `<cmd>` exits 0, `fail` if non-zero, `infra_fail`
  if the wrapper itself cannot run the command (e.g., missing binary).
  Exits with the command's exit code (so the CI step still fails on
  `fail`). **No path through this script exits without writing exactly
  one verdict record.**

- **`mix tau.factory.emit`** (`web/lib/mix/tasks/tau.factory.emit.ex`,
  new, ≈ 80 LOC): Elixir-side mutator API for non-shell producers
  (the projector itself for `infra_fail` events; future Elixir-side
  gates). Reads a JSON `%Verdict{}` envelope on stdin; constructs
  via `Verdict.new!/1` (which raises on invalid status); calls
  `Tau.Factory.Log.append/1`. Refuses an envelope missing mandatory
  fields per `kind` with exit code 2 and the missing-field list on
  stderr.

- **`mix tau.factory.gate.assert_complete`**
  (`web/lib/mix/tasks/tau.factory.gate.assert_complete.ex`, new,
  ≈ 120 LOC): the **run-tail verdict-set completeness asserter**
  (from proposal 1). Args: `--run-id <id> --declared-gate-ids
  <csv>`. Queries `Tau.Factory.ReadModel.Query.missing_verdicts/2`;
  exits 0 with `checked, all <n> gates emitted` if complete; exits
  non-zero with the list of missing gate IDs if not. **This task is
  the only mechanism that catches "gate step silently omitted from
  workflow YAML."** Runs as the final step of every CI workflow that
  contains gates (wired via the composite action below).

- **`mix tau.factory.sweep`** (`web/lib/mix/tasks/tau.factory.sweep.ex`,
  new, ≈ 200 LOC): invokes `Tau.Factory.Hygiene.scan/0` then performs
  the worktree-cleanup sequence from `.claude/rules/worktree-discipline.md`
  (capture-before-destroy, then `git worktree remove -f -f`, then
  `git branch -D`); appends one verdict per action plus a summary.
  Failed removal (locked, dirty) emits a `:fail` verdict with the
  blocker named. **Invoked by both `factory-hygiene.py` (local) and
  the GHA workflow (remote)** — never inlined in a workflow YAML.

- **`mix tau.factory.alarm`** (`web/lib/mix/tasks/tau.factory.alarm.ex`,
  new, ≈ 80 LOC): reads the read-model snapshot; if leaked-worktree
  count > threshold OR an expected gate verdict is absent for > T
  hours OR `main`-coherence has not run for > 24h, opens a GitHub
  issue (deterministic title; idempotent on `kind + detail` digest)
  via `gh issue create --label hygiene,factory-v2`. Invoked by the
  scheduled workflow.

### Hygiene-enforcement substrate (Python script + Claude Code hooks + GHA workflow)

- **`.claude/hooks/factory-hygiene.py`** (new, ≈ 180 LOC, Python
  stdlib only per `.claude/rules/hooks-and-scripts.md`): the
  shared-script enforcement core. Modes via `--mode`:

  - `--mode pre-spawn` (invoked by `PreToolUse(Task)` and `SessionStart`):
    runs the pre-spawn checklist from `worktree-discipline.md` —
    `git fetch origin`, `branch == main`, `main == origin/main`,
    `git status --porcelain` empty. Exits 2 (= blocking deny) with
    a diagnostic naming the failed invariant and the recovery
    command. Pipes a `pass`/`fail` verdict via stdin to `mix
    tau.factory.emit` regardless of outcome.

  - `--mode sweep` (invoked by `.github/workflows/hygiene-sweep.yml`):
    delegates to `mix tau.factory.sweep`, then `mix tau.factory.alarm`.

  - `--mode protect-check` (invoked by both): asserts
    `.github/branch-protection.json` matches the live branch
    protection via `gh api repos/.../branches/main/protection`;
    fails on drift.

  **One script. Two invocation surfaces. Drift impossible.**

- **`.claude/settings.json` delta** (≈ 10 LOC JSON):

  ```jsonc
  "hooks": {
    "SessionStart": [
      { "hooks": [{ "type": "command",
                    "command": "${CLAUDE_PROJECT_DIR}/.claude/hooks/factory-hygiene.py --mode pre-spawn",
                    "timeout": 10 }] }
    ],
    "PreToolUse": [
      { "matcher": "Task",
        "hooks": [{ "type": "command",
                    "command": "${CLAUDE_PROJECT_DIR}/.claude/hooks/factory-hygiene.py --mode pre-spawn",
                    "timeout": 10 }] }
    ]
  }
  ```

  Registration is the discriminator: if the hook is registered, Claude
  Code invokes it before every `Task` spawn. A missing hook script
  causes Claude Code to deny the tool call by default (verified
  behaviour). There is no path where the hook is registered but does
  not run.

### CI substrate (GitHub Actions)

- **`.github/actions/factory-gate/action.yml`** (new, ≈ 40 LOC):
  composite action wrapping a gate command in `bin/factory-gate` and
  emitting a `[:tau, :factory, :gate, :wrapped]` annotation. Required
  inputs: `gate-id`, `cmd`. Used by every gate step in
  `.github/workflows/ci.yml`. A grep meta-check fails the workflow if
  any `mix tau.gate.*` invocation in `.github/workflows/*.yml` is
  NOT inside `uses: ./.github/actions/factory-gate`.

- **`.github/workflows/ci.yml` delta** (≈ 30 LOC changed, ≈ 60 LOC
  added): every gate step rewritten to use `factory-gate` composite
  action. **Removes** the `exit 0` early-skip patterns at lines 88-100
  and 213-223; **removes** the `|| true` at line 115. Adds a final
  job-tail step:

  ```yaml
  - name: assert all declared gates produced verdicts
    run: mix tau.factory.gate.assert_complete \
           --run-id "$GITHUB_RUN_ID" \
           --declared-gate-ids "ac_linkage,masking,mutation,contract_drift,nn7,capability_flag,telemetry_consumer,behaviour_callback,spec_consistency"
  ```

  Adds a meta-check job (`gate-wrapping-check`) that greps for any
  `mix tau.gate.*` invocation not wrapped in `factory-gate`.

- **`.github/workflows/hygiene-sweep.yml`** (new, ≈ 60 LOC):
  scheduled (`*/15 * * * *`) + on-`push: main` + `workflow_dispatch`.
  Steps: checkout, setup-beam, `.claude/hooks/factory-hygiene.py
  --mode sweep`, `factory-hygiene.py --mode protect-check`, then
  `peter-evans/create-issue-from-file@v5` on `if: failure()`. The
  named check `hygiene-sweep / sweep` becomes a required branch-
  protection check (see below).

- **`.github/workflows/branch-protection-apply.yml`** (new, ≈ 30 LOC):
  one-shot + `workflow_dispatch`. Reads `.github/branch-protection.json`
  and applies via `gh api -X PUT repos/.../branches/main/protection
  -F input=@.github/branch-protection.json`. Documents the required
  `admin:repo` token in the workflow comments. Runs daily as
  reconciliation (drift detector → FAIL verdict).

- **`.github/branch-protection.json`** (new, declarative JSON):
  required status checks include **every named gate** plus
  `hygiene-sweep / sweep` plus the synthetic `factory-verdict-coverage`
  check. `enforce_admins: true`, `allow_force_pushes: false`,
  `allow_deletions: false`. **This is the load-bearing artefact** —
  it makes the verdict pipeline merge-blocking without any bespoke
  daemon.

- **`bin/factory-verdict-coverage`** (new, shell, ≈ 50 LOC): the
  synthetic gate that fails any PR whose verdict count in
  `.factory/verdicts.ndjson` (for `PR_NUMBER`, `GITHUB_SHA`) does not
  match the expected gate count for the surface the diff touches.
  The expected-gate-count mapping is a static table
  `bin/factory-verdict-coverage.yml` keyed by file glob → required
  gate set. Wrapped in `bin/factory-gate verdict_coverage -- bin/factory-verdict-coverage`.

### Verdict log substrate (filesystem)

- **`.factory/verdicts.ndjson`** (new, in-repo, appended-only;
  monthly rotation via `.github/workflows/verdict-log-rotate.yml`):
  one JSON object per line; `grep`-able; readable without any Tau
  process running; the substrate of last resort during outages.

- **`.factory/snapshots.ndjson`** (new, in-repo, gitignored — written
  by every projector poll and every hygiene sweep): point-in-time
  git/`gh` snapshots used by the read model for hygiene state.

- **`.factory/factory_state.db`** (gitignored, built artefact):
  Exqlite-rendered projection. Rebuildable from the two NDJSON files
  via `mix tau.factory.projector.reproject`.

- **`.gitignore` delta**: add `.factory/snapshots.ndjson`,
  `.factory/factory_state.db`, `.factory/factory_state.db-wal`,
  `.factory/factory_state.db-shm`.

### Verdict-log rotation

- **`.github/workflows/verdict-log-rotate.yml`** (new, monthly cron):
  renames `.factory/verdicts.ndjson` → `.factory/verdicts-YYYY-MM.ndjson`
  on the first of each month and starts a fresh log. The projector
  reads all rotated logs on warm projection. Bound by repo size; at
  v1 PR rate (~50 PRs/month × ~10 gates × ~500 bytes/verdict ≈
  250 KB/month), a year of history is ~3 MB.

### Test surface

- `web/test/tau/factory/verdict_test.exs` — property test on
  `Verdict.new!/1`: any non-`{:pass,:fail,:checked_no_findings,:infra_fail}`
  status raises; any non-`:pass` status with empty `rationale` raises.

- `web/test/tau/factory/projector_test.exs` — integration test:
  append 100 events to a tempfile NDJSON, start `Projector`, assert
  `Query.snapshot/0` matches.

- `web/test/tau_web/live/factory_live/page_test.exs` — LiveView
  test via `Phoenix.LiveViewTest`: fault-injection deletes a row
  from `gate_run`; assert the panel renders the error banner, not
  a blank panel.

- `test/hooks/factory_hygiene_test.sh` — shell test matrix for
  `factory-hygiene.py` against 10 scenarios (orphan worktree,
  locked-finished, in-flight-protected, stale-with-PR,
  stale-no-PR, dirty parent, branch-not-main, main-behind-origin,
  drifted-protection, healthy).

- `test/integration/silent_skip_resistance_test.exs` — the
  meta-test: synthesise a workflow with one gate step deleted;
  assert `mix tau.factory.gate.assert_complete` exits non-zero
  with the missing gate named.

## What does not change

- **`Tau.PubSub` remains the only `Phoenix.PubSub` instance.**
  D-184 unchanged; the projector broadcasts on the existing topic
  namespace.
- **The `:telemetry` event namespace `[:tau, ...]` is the only
  channel for in-process events.** New events (`[:tau, :factory,
  :verdict, :written]`, `[:tau, :factory, :hygiene, :scan, :stop]`)
  extend the namespace without forking it.
- **The Exqlite single-writer pattern.** The projector is the only
  process holding a write handle to `factory_state.db`; readers
  open read-only handles or query through `Tau.Factory.ReadModel.Query`.
- **The existing `/dev/dashboard` LiveDashboard mount.** Adding the
  factory page is a `PageBuilder` extension, not a new mount point.
- **`.claude/rules/worktree-discipline.md`** is unchanged — it
  remains the prose source-of-truth that `factory-hygiene.py`
  mechanises. The script's behaviour is the rule's invariants
  literalised.
- **`.claude/rules/hooks-and-scripts.md`** is unchanged — Python
  stdlib only; this solution stays inside that constraint.
- **`.claude/rules/factory-loop.md`'s structure** — the factory
  cycle, the N=3 refine bound, the safety circuit, the parent-on-
  main invariant. This solution **enforces** the rule with mechanism;
  the rule's text remains the canonical statement of policy.
- **No new Hex dependency.** Every Elixir piece uses `:exqlite`,
  `:phoenix_live_view`, `:phoenix_live_dashboard`, `:phoenix_pubsub`,
  `:telemetry` — all already in `web/mix.exs` per SPEC-WEB-DASHBOARD
  / SPEC-MEMORY-STORE.
- **No new pip dependency at hook scope.** Python stdlib only.
  Datasette is explicitly **rejected** from this solution (proposal 4's
  publish path); the LiveDashboard `PageBuilder` page replaces it.
- **The agents under `.claude/agents/`** are untouched. The factory
  loop's `critic` and `reviewer` continue as quality checks; this
  solution adds mechanism *underneath* them, not in place of them.
- **GitHub Issues remains the alarm channel.** No PagerDuty, no
  Slack, no third-party service. `peter-evans/create-issue-from-file@v5`
  (already widely-used in the ecosystem) is the only new GH Action.

## Silent-skip impossibility — implementation-level proof

A silent-skip would require **defeating all four layers simultaneously**.
Each layer is named at the implementation level so a reviewer can verify
the proof against actual files.

1. **Constructor layer — `Tau.Factory.Verdict.new!/1` refuses
   `:skipped`.** Source: `web/lib/tau/factory/verdict.ex`. The function
   pattern-matches against the closed status set; any other atom raises
   `ArgumentError`. A gate cannot construct a `:skipped` verdict.
   Property-tested in `web/test/tau/factory/verdict_test.exs`.

2. **Schema layer — SQLite `CHECK` constraint rejects `:skipped` and
   `NULL`.** Source: `web/lib/tau/factory/read_model/schema.ex`.
   `verdict TEXT NOT NULL CHECK (verdict IN ('pass','fail','checked_no_findings','infra_fail'))`.
   The DB rejects insertion of any other value. Even if a future
   producer bypassed the constructor (e.g., raw SQL), the schema
   refuses.

3. **Producer-pipeline layer — `bin/factory-gate` always writes
   exactly one verdict.** Source: `bin/factory-gate`. The script's
   `set -euo pipefail` plus the unconditional verdict-emission step at
   its tail guarantees one verdict per invocation. Renaming or
   removing the wrapper is caught by `gate-wrapping-check` (grep
   meta-check in CI workflows for any unwrapped `mix tau.gate.*`
   invocation). Source: `.github/workflows/ci.yml` (the `gate-wrapping-check`
   job).

4. **Workflow layer — `mix tau.factory.gate.assert_complete` fails
   the CI job when any declared `gate_id` for the current `run_id`
   produced no verdict.** Source:
   `web/lib/mix/tasks/tau.factory.gate.assert_complete.ex`. This
   layer catches the case where a gate step is **silently omitted
   from the workflow YAML entirely** — the constructor and schema
   layers cannot, because no producer ever ran. The asserter
   queries `Query.missing_verdicts(run_id, declared)` and exits
   non-zero with the list.

5. **GitHub layer — branch protection requires named checks AND a
   `factory-verdict-coverage` synthetic check.** Source:
   `.github/branch-protection.json` + `bin/factory-verdict-coverage`.
   Renaming a gate step in `ci.yml` makes the required check go
   "missing"; GitHub refuses the merge. A workflow that produces
   fewer verdicts than expected for the diff's surface fails the
   synthetic gate.

A silent-skip would require: (1) a producer that bypasses the
constructor, AND (2) raw SQL that bypasses the schema, AND (3) a
gate command not wrapped in `bin/factory-gate` AND not caught by the
grep meta-check, AND (4) all declared gate IDs in
`assert_complete`'s `--declared-gate-ids` arg matched by verdicts
(or the arg list itself tampered with), AND (5) branch protection
disabled or the named check renamed (caught by the daily
`branch-protection-apply.yml` reconciliation as drift → FAIL
verdict). Each of (1)–(5) is independently caught; all five must
simultaneously fail.

The v1 patterns at `ci.yml:88-100`, `:213-223` (early-exit-on-empty)
and `:115` (`|| true`) are **deleted, not rewritten** by this
solution. The script-meta-check job greps for both patterns and
fails the workflow if either is reintroduced.

## Migration sketch

Sequence is dependency-driven: each step produces an artefact the
next assumes. None may be skipped without silently disabling a
downstream guarantee.

The sequence is summarised here; the week-by-week deliverables are
in **§Build-order** below.

The substrate (verdict struct, log, projector, schema, query, page)
lands first behind `dev_routes`-gated visibility — no production
impact. The shell wrapper and asserter Mix task land next, validated
end-to-end on one existing gate (`ac_linkage`) as the pilot. The
hygiene script lands in **read-only mode** (always exits 0) so it
cannot block local agent work during the bedding-in period; flipping
to deny-mode is a one-line settings change once the script's behaviour
is verified across the 10-scenario shell test matrix. Branch protection
lands last, because once applied it makes every named check
load-bearing on `main` and a misconfiguration becomes a blocker.

Reversibility is high: removing the LiveView page is a router-delta
revert; removing the hooks is a settings-delta revert; removing
branch protection is a `gh api` DELETE; the NDJSON log can be
truncated or deleted without affecting Tau's runtime (the projector
will simply replay nothing).

## §Build-order — week-by-week with dependencies

Eight weeks, one named deliverable per week. Each week's deliverable
is the input the next week consumes. Strict ordering — Wk N cannot
ship before Wk N-1's artefact exists.

### Wk 1 — Verdict substrate

- **Ship:** `Tau.Factory.Verdict` (`web/lib/tau/factory/verdict.ex`)
  + `Tau.Factory.Log` (`web/lib/tau/factory/log.ex`) + property
  tests (`web/test/tau/factory/verdict_test.exs`).
- **Demonstrates:** `Verdict.new!/1` refuses `:skipped`; `Log.append/1`
  produces a parseable NDJSON line.
- **Depends on:** nothing (pure Elixir; no `:tau_web` dependency yet).
- **Gate (self):** property test for status closed set; round-trip
  NDJSON encode/decode.

### Wk 2 — Projector + schema + query

- **Ship:** `Tau.Factory.Projector` + `Tau.Factory.ReadModel.Schema`
  + `Tau.Factory.ReadModel.Query` + `Tau.Factory.Supervisor` +
  integration test (`web/test/tau/factory/projector_test.exs`).
  Mount `Supervisor` under `TauWeb.Application`.
- **Demonstrates:** writing to `.factory/verdicts.ndjson` results in
  rows in `priv/factory_state.db` within 100 ms; `Query.snapshot/0`
  returns the projected state.
- **Depends on:** Wk 1.
- **Gate (self):** `mix test` for projector with a tempfile NDJSON
  fixture; SQLite CHECK constraint integration test.

### Wk 3 — `bin/factory-gate` + pilot gate wrapping

- **Ship:** `bin/factory-gate` shell wrapper + wrap `mix
  tau.gate.ac_linkage` in `.github/workflows/ci.yml` via the new
  `.github/actions/factory-gate/action.yml` composite action +
  `Tau.Factory.Hygiene.scan/0` (Elixir).
- **Demonstrates:** one full PR's `ac_linkage` gate emits a verdict
  visible in `.factory/verdicts.ndjson` AND in `Query.snapshot/0`;
  a synthetic gate failure produces a `fail` verdict that the next
  Wk-4 dashboard renders red.
- **Depends on:** Wk 2.
- **Gate (self):** `bin/factory-gate` test matrix (pass, fail,
  command-not-found → `infra_fail`); composite-action smoke test
  via `act` or a throwaway PR.

### Wk 4 — `FactoryLive.Page` + router delta

- **Ship:** `TauWeb.FactoryLive.Page` + router delta + LiveViewTest
  fault-injection test (`web/test/tau_web/live/factory_live/page_test.exs`).
- **Demonstrates:** five panels render at `/dev/dashboard/factory`;
  deleting a `gate_run` row makes that panel show its error banner,
  not a blank tile (leaf-AC b).
- **Depends on:** Wk 3 (need real verdicts to render).
- **Gate (self):** LiveView fault-injection test asserts the error
  banner is visible.

### Wk 5 — `assert_complete` + meta-checks + universal gate wrapping

- **Ship:** `mix tau.factory.gate.assert_complete` + adopt
  `factory-gate` composite action on **every** gate in `ci.yml` +
  `gate-wrapping-check` grep meta-check + final-step
  `assert_complete` call in every gate-containing workflow + delete
  the `exit 0` early-exits at `ci.yml:88-100` and `:213-223` and
  the `|| true` at `:115`.
- **Demonstrates:** the silent-skip integration test
  (`test/integration/silent_skip_resistance_test.exs`) — synthesise
  a workflow with one gate step deleted; CI fails on `assert_complete`
  with the missing gate named. This is the formal closure of Failure
  Class #5 (silent-skip).
- **Depends on:** Wk 3 + Wk 4 (need wrapper + dashboard for visible
  confirmation).
- **Gate (self):** synthetic silent-skip test passes; meta-check
  catches an unwrapped `mix tau.gate.*` invocation.

### Wk 6 — Hygiene script + log-only deployment

- **Ship:** `.claude/hooks/factory-hygiene.py` (all three modes:
  `pre-spawn`, `sweep`, `protect-check`) + `mix tau.factory.sweep`
  + `mix tau.factory.alarm` + shell test matrix
  (`test/hooks/factory_hygiene_test.sh`) + `.claude/settings.json`
  delta — but **the hooks are wired in LOG-ONLY mode** (script
  emits a verdict but always exits 0; recovery commands surfaced
  only as warnings).
- **Demonstrates:** every Task spawn produces a `pre-spawn` verdict
  visible on the dashboard; the 10-scenario shell matrix passes;
  no agent work is blocked.
- **Depends on:** Wk 5 (need the verdict pipeline before the script
  can write verdicts).
- **Gate (self):** shell test matrix passes 10/10 scenarios;
  one-week bake on the local coordinator with no false denies.

### Wk 7 — Hygiene script flips to deny-mode + scheduled workflow

- **Ship:** `.github/workflows/hygiene-sweep.yml` (cron + push-to-main +
  workflow_dispatch) + flip `factory-hygiene.py --mode pre-spawn`
  to exit 2 on invariant violation (one-line change). Closes leaf-AC (c)
  and (d).
- **Demonstrates:** a deliberately-stale parent causes the next
  Task spawn to be denied with the diagnostic naming the failed
  invariant and the recovery command; the GHA workflow runs every
  15 min and emits one sweep verdict per pass; orphan worktrees
  are removed within the SLA.
- **Depends on:** Wk 6 (need the script verified before it can
  start denying).
- **Gate (self):** one-week bake; alarm threshold tuned; no
  legitimate work blocked.

### Wk 8 — Branch protection + verdict coverage + reconciliation

- **Ship:** `.github/branch-protection.json` +
  `.github/workflows/branch-protection-apply.yml` +
  `bin/factory-verdict-coverage` + `bin/factory-verdict-coverage.yml`
  (the surface→required-gates table) + daily reconciliation. **Branch
  protection is applied — `main` becomes merge-gated on every named
  check including the synthetic coverage gate.**
- **Demonstrates:** a PR with a missing verdict cannot merge;
  drifting branch-protection via the GitHub UI is caught within 24h
  as a `fail` verdict on the dashboard; the Wk 5 silent-skip test
  PLUS the Wk 7 hygiene tests PLUS the verdict-coverage gate
  collectively close Failure Class #5 AND Failure Class #7 AND
  Failure Class #8.
- **Depends on:** Wk 5 + Wk 6 + Wk 7 (every prerequisite verdict
  pipeline must be live before merge-blocking is turned on).
- **Gate (self):** end-to-end test on a throwaway PR — try every
  silent-skip construction from proposal 4 (orphan branch, stale
  parent, mis-wired gate, dashboard outage); each is caught at
  the named layer; branch protection refuses the merge.

### Dependency DAG

```
Wk1 ─→ Wk2 ─→ Wk3 ─→ Wk4
                │
                └─→ Wk5 ─→ Wk6 ─→ Wk7 ─→ Wk8
```

Wk 4 (dashboard) and Wk 5 (assert_complete) can parallelise after
Wk 3; the build-order serialises them only for review-burden reasons.
Wk 8 is the merge-gating activation; nothing depends on it within
this leaf, but the post-merge coherence sibling and the AC-binding
sibling consume `bin/factory-gate` and the verdict log from Wk 3
onward.

## Open questions

- **Production exposure of `/dev/dashboard/factory`.** Currently
  guarded by `dev_routes` per the existing router; this solution
  defers the auth-plug story to a follow-up tracked under SPEC-WEB-
  DASHBOARD. For a single-developer self-hosting factory, dev-only is
  sufficient; multi-operator setups need an auth plug. Not a leaf
  blocker.

- **`audit_finding` table write path.** This solution defines the
  table and reads from it via the dashboard. The **knowledge-memory-
  and-audit-ingestion sibling** owns the writer. The cross-leaf
  contract: the sibling either writes verdicts through `mix
  tau.factory.emit` with `kind: :audit_finding` (preferred) or
  writes directly to `factory_state.db.audit_finding` via a
  documented Ecto schema. If the sibling chooses a YAML registry,
  this leaf needs a 20-LOC importer task.

- **Per-PR expected-gate-count table.** `bin/factory-verdict-coverage.yml`
  maps file globs to required gate sets. The initial table is
  derived from `docs/spec/SPEC-*.md` source-maps; it must be kept
  in sync with the **pre-merge-code-gates** sibling's gate inventory.
  A test ensures every gate named in `ci.yml` appears in the
  coverage table.

- **GHA cron skew.** GitHub's `*/15` cron is best-effort; under low
  repo activity the sweep can lag up to ~25 min. Mitigated by
  `push: main` trigger (sweep runs after every merge) and the
  pre-spawn hook (local agent work cannot proceed against a stale
  parent regardless of cron timing). Residual: purely-server orphans
  during quiet periods may persist 25 min.

- **NDJSON log growth at scale.** Monthly rotation is sketched; first
  rotation will surface integration friction. At v1 PR rate (~50/mo
  × ~10 gates), the log grows ~250 KB/mo; rotation tested on a
  throwaway repo at 10× volume before the first scheduled rotation.

- **Branch-protection-as-code partial coverage.** GitHub's API does
  not expose every protection setting declaratively (e.g., some
  rules are admin-UI only). The daily reconciliation surfaces drift
  but cannot author every rule. Documented limitation; manual UI
  configuration for the residual settings is a one-time setup step.

- **Coordination with the `pre-merge-evidence-and-skip-integrity`
  sibling.** That sibling owns the gate-result evidence contract;
  this leaf consumes it. The agreed contract is the four allowed
  `status` values (`:pass`, `:fail`, `:checked_no_findings`,
  `:infra_fail`) and the `bin/factory-gate` wrapper as the
  evidence producer. If the sibling chooses a materially different
  evidence format, this leaf needs an adapter (≤ 50 LOC). Tracked
  as a cross-leaf dependency in §What changes.

## Linked sub-problems / proposals

- `proposals/proposal-1.md` — Event-sourced read model + `mix
  tau.factory.emit` mutator + run-tail verdict-set completeness
  assertion. **Contribution: `mix tau.factory.gate.assert_complete`
  primitive (the run-tail verdict-set completeness asserter — the
  catch for "gate step silently omitted from workflow YAML"), plus
  the validating-mutator pattern (`mix tau.factory.emit` for
  Elixir-side producers).**

- `proposals/proposal-2.md` — LiveDashboard `PageBuilder` page +
  shared Python script for local/CI enforcement + branch-protection.
  **Contribution: the substrate (LiveDashboard + Phoenix.PubSub +
  `:exqlite` — all in-tree deps), the shared-script invariant
  (`factory-hygiene.py` is the same file in `.claude/hooks/` and the
  GHA workflow), and branch protection as the load-bearing merge
  gate.**

- `proposals/proposal-3.md` — LiveDashboard read-model + janitor cron
  + alarm channel + pre-spawn hook. **Contribution: NONE adopted
  directly. The alarm-channel concept is folded into proposal 2's
  `peter-evans/create-issue-from-file@v5` on workflow failure; the
  janitor cron is folded into `hygiene-sweep.yml`; the four-moving-
  parts shape was rejected for the three-substrate shape (log,
  projector + view, hygiene script).**

- `proposals/proposal-4.md` — Adversarial NDJSON verdict log +
  Datasette + `bin/factory-gate` + branch protection + adversarial
  constructions. **Contribution: the append-only NDJSON verdict log
  as substrate-of-last-resort (`grep`-able when both Tau and the
  dashboard are down); `bin/factory-gate` shell wrapper as the only
  sanctioned producer pipeline; the `factory-verdict-coverage`
  synthetic gate; the five-construction silent-skip impossibility
  proof structure (reused above with one added layer from proposal 1).
  Datasette was rejected** in favour of proposal 2's LiveDashboard
  PageBuilder page — Datasette would introduce a new deployment
  surface (Vercel/Fly.io) and a pip-installed tool, where LiveDashboard
  PageBuilder is already an in-tree dep and the dashboard mount
  already exists.

## Revision history

- (revision 0 — initial)
