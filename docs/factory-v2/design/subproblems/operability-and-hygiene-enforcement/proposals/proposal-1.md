---
template_version: 1
template_name: proposal
proposal_id: 1
parent_problem: ../problem.md
---

# Proposal 1: Event-sourced Factory Read Model on `:tau_web` + Mechanical Hygiene Hooks (`tau.factory` Mix tasks as the only mutator)

## Approach

Introduce a single read model — `Tau.FactoryState` — backed by a SQLite
event log written *only* by `mix tau.factory.emit` (a Mix task that no
other component may bypass). Every gate verdict (PR-merge gate, hygiene
gate, coherence gate), every worktree event (spawn, prune), every
`parent-on-main` invariant check, and every audit-finding state change
is appended as a typed event by the producer (a CI job, a hook script,
or a scheduled workflow) via that one task. The read model is projected
into queryable Ecto schemas under `:tau_web` and rendered as a single
LiveView at `/factory` (the existing `SPEC-WEB-DASHBOARD` poncho gains
a new `FactoryLive` route). Hygiene enforcement is a small set of hook
scripts that block tool calls or fail PRs — `parent-on-main`
verification runs as a `PreToolUse` hook on `Task` and as a CI job; an
hourly scheduled GitHub Action runs `mix tau.factory.sweep` to prune
finished worktrees and emit a `hygiene.swept` event. Silent-skip is
made impossible because (i) every check emits exactly one of three
verdict atoms — `:pass | :fail | :not_applicable_with_reason` — and the
read model alarms on the absence of an expected verdict (a missing
event is itself a `:missing` row), and (ii) all CI jobs are wired
through a single composite action `factory-gate` whose post-step asserts
that *every declared gate ID produced an event in this run*, failing
the job if any did not.

## Rationale

The complecting hypothesis is that factory state lives in five
substrates (`.claude/logs/`, PR bodies, Actions runs, agent context,
human memory) and that hygiene rules are complected with agent
discipline. Decomplecting requires (a) a single mutator and a single
read model — every producer writes by the same protocol, every consumer
reads by the same protocol — and (b) mechanical enforcement substrates
that cannot be reasoned around: a `PreToolUse` hook either lets the
spawn through or it doesn't; a CI composite action either records all
verdicts or it fails. By making the producer-of-record `mix
tau.factory.emit` and the consumer-of-record a single LiveView reading
one SQLite database, we replace "where you happened to look" with one
schema. By having the composite action assert verdict-set completeness
*after* the gate job runs, silent-skip is structurally impossible —
absence is itself an alarm. The hygiene hooks make `parent-on-main`
violation impossible at spawn-time, removing the "coordinator's
attention" coupling. The choice to host the dashboard inside the
existing `:tau_web` poncho satisfies Root §Acceptance D (reuse over
reinvention) because `SPEC-WEB-DASHBOARD` already commits the
substrate.

## Sketch

### Read-model store (event log + projections)

A new sub-application `:tau_factory_state` under the poncho:

```
poncho/
  factory_state/
    lib/tau/factory_state/
      event.ex            # %Event{} typed envelope
      log.ex              # append-only Ecto/Sqlite writer (single mutator API)
      projector.ex        # GenServer; consumes Log and updates projections
      schema/
        gate_verdict.ex   # one row per (pr_number, gate_id, run_id)
        worktree.ex       # one row per active worktree
        invariant_check.ex
        audit_finding.ex
        run.ex            # one row per CI run, with declared_gate_ids
      query.ex            # the read API used by LiveView and Mix tasks
    priv/repo/migrations/...
```

Event envelope:

```elixir
defmodule Tau.FactoryState.Event do
  @type t :: %__MODULE__{
          id: String.t(),          # ULID
          kind: kind(),
          source: String.t(),      # "ci:lint", "hook:pre-task", "sweep:cron"
          pr_number: pos_integer() | nil,
          run_id: String.t() | nil,
          gate_id: String.t() | nil,   # e.g. "ac_linkage", "mutation", "parent_on_main"
          verdict: :pass | :fail | :not_applicable | :error | nil,
          reason: String.t() | nil,    # MANDATORY when :not_applicable | :error
          payload: map(),
          emitted_at: DateTime.t()
        }
end
```

### Single mutator: `mix tau.factory.emit`

The only sanctioned way to write to the log. Reads a JSON event on
stdin, validates against `Event.t()`, refuses anything that lacks the
mandatory fields per `kind`. Refusal exits non-zero, which fails the
CI step that emitted it.

```sh
echo '{"kind":"gate_verdict","gate_id":"ac_linkage","pr_number":417,
       "run_id":"$GITHUB_RUN_ID","verdict":"pass","payload":{...}}' \
  | mix tau.factory.emit
```

Contract enforced at validation time:

- `kind: :gate_verdict` ⇒ `gate_id`, `pr_number`, `run_id`,
  `verdict` REQUIRED. If `verdict ∈ {:not_applicable, :fail, :error}`,
  `reason` REQUIRED and non-empty.
- `kind: :worktree_event` ⇒ `payload` has `op ∈ [:spawn, :prune,
  :leaked]`, `path`, `agent_id`.
- `kind: :invariant_check` ⇒ `gate_id` (e.g. `parent_on_main`),
  `verdict`, `reason` when not `:pass`.
- `kind: :run_declared` ⇒ `run_id`, `payload.declared_gate_ids: [String]`.
  Emitted once per CI run at job start.

### Verdict-completeness assertion (anti-silent-skip)

A new composite action `.github/actions/factory-gate/action.yml`
wraps every gate step. Its `post` step runs:

```sh
mix tau.factory.gate.assert_complete \
  --run-id "$GITHUB_RUN_ID" \
  --declared-gate-ids "ac_linkage,masking,mutation,contract_drift,..."
```

The task queries the read model: for each declared gate ID, does a
`gate_verdict` event exist for this `run_id`? If any is missing, the
task exits non-zero with the list of missing IDs — failing the CI
job. This is the structural impossibility: the gate either emits or
the job fails.

### Pre-spawn hygiene hook

New script `.claude/hooks/check-parent-on-main.py` wired into
`.claude/settings.json`:

```jsonc
"PreToolUse": [
  { "matcher": "Task",
    "hooks": [{ "type": "command",
                "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/check-parent-on-main.py",
                "timeout": 10 }] }
]
```

Behaviour: runs `git fetch origin && git rev-parse main` and compares
to `origin/main`; on mismatch prints the diagnostic *and the recovery
command* to stderr and exits non-zero (Claude Code blocks the tool
call). Also pipes a `kind: invariant_check, gate_id:
parent_on_main, verdict: :fail` event to `mix tau.factory.emit`.

### Scheduled sweep

`.github/workflows/factory-sweep.yml`, cron `*/30 * * * *`:

```yaml
jobs:
  sweep:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - uses: ./.github/actions/setup-beam
      - run: mix tau.factory.sweep --emit
```

`mix tau.factory.sweep` enumerates `git worktree list`, identifies
finished worktrees (whose agent process is dead and whose branch has
been merged or abandoned), removes them with the canonical
capture-before-destroy sequence from `worktree-discipline.md`, and
emits one `worktree_event` per action plus a single `hygiene.swept`
summary. Failure to remove (locked, dirty, etc.) emits `verdict: :fail`
with the blocker named — which surfaces on the LiveView as a red row
and opens an issue via `gh issue create`.

### Dashboard

`web/lib/tau_web/live/factory_live.ex` mounts `Phoenix.PubSub`
subscription on `"factory:events"` (the projector broadcasts there);
renders five panels — Gate verdicts (last N PRs), Worktrees (active +
leaked), Invariants (last `parent_on_main` check time + verdict),
Coherence (last `main`-coherence run), Audit findings (open count
per surface). Each panel handles `assigns.error` by rendering an
error state, never an empty panel.

### Read-only consumer API

`Tau.FactoryState.Query` exposes pure functions used by both LiveView
and Mix-task introspection:

```elixir
@spec gate_verdicts_for_pr(pos_integer()) :: [GateVerdict.t()]
@spec leaked_worktrees() :: [Worktree.t()]
@spec last_invariant_check(gate_id :: String.t()) :: InvariantCheck.t() | nil
@spec missing_verdicts(run_id :: String.t(), declared :: [String.t()]) :: [String.t()]
@spec open_audit_findings_by_surface() :: %{String.t() => pos_integer()}
```

### Verdict consumption

The read model is consumed by three classes of caller, each by a
narrow contract:

1. **`Tau.FactoryState.Query` callers** (LiveView, `mix tau.factory.status`)
   — read for display.
2. **The completeness asserter** (`mix tau.factory.gate.assert_complete`)
   — read at CI-job tail to enforce silent-skip impossibility.
3. **The escalation issuer** (`mix tau.factory.alarm`) — read on cron;
   when leaked worktrees exceed threshold or an expected event is
   missing for > T hours, opens a GitHub issue tagged `factory:hygiene`.

No consumer mutates the log; the log is append-only and the single
mutator is `mix tau.factory.emit`.

## Tradeoffs

### Strengths

- **Single read model, single mutator.** Decomplects "where state
  lives" from "what state means" (Hickey: place ≠ value). One schema,
  one mutator API, one query API.
- **Silent-skip structural impossibility.** Verdict-set completeness
  is asserted *after* every gate run; missing events fail the job.
  Addresses Root §Acceptance C and Failure Class #5 directly.
- **`parent-on-main` enforced as a `PreToolUse` hook.** Agents
  cannot spawn from a stale parent; the rule is no longer prose.
  Addresses Failure Class #8.
- **Reuse of `:tau_web` poncho satisfies Root §Acceptance D.** No new
  web stack; new sub-app composes with `SPEC-WEB-DASHBOARD`.
- **Append-only event log** is debuggable, replayable, and survives
  projector schema changes — drop projections, replay log, rebuild.
- **Dashboard panels render error state on fetch failure**, never an
  empty panel, satisfying leaf-AC (b).

### Weaknesses

- **Producer compliance** still requires every gate author to call
  `mix tau.factory.emit`. The completeness asserter catches omission
  at run-tail but cannot validate semantic correctness of `payload`.
  Mitigation: per-`kind` JSON schema validation in `tau.factory.emit`;
  a `kind` not in the registry is refused.
- **Cron sweep latency.** Up to 30 minutes between leak and cleanup;
  during that window the dashboard shows the leak but no action is
  taken. Tightening the cron costs Actions minutes.
- **SQLite write contention** if many parallel CI jobs emit at high
  rate. The MVP uses a GitHub release artefact as the canonical log
  (one append per emit, downloaded by the projector); a future
  version may move to Postgres on a fly.io / Railway instance —
  schema is stable, migration is cheap.
- **Composite-action discipline.** A new gate authored without
  wrapping in `factory-gate` would still silent-skip. Mitigation: a
  meta-check job that greps `.github/workflows/` for jobs containing
  `tau.gate.*` invocations not inside `uses: ./.github/actions/factory-gate`
  and fails the workflow.
- **PreToolUse hook adds latency to every `Task` spawn.** ~1-2s for
  `git fetch`. Mitigation: cache the `origin/main` SHA in a
  `$CLAUDE_PROJECT_DIR/.claude/cache/origin-main-sha` file with TTL
  60s; refresh out-of-band.
- **LiveView itself is not yet live** in `:tau_web` (foundation
  package exists, no LiveViews mounted). This proposal depends on
  #374 (M7 foundation) landing.

### Costs

- New sub-app under poncho: ~400 LOC Elixir (Event, Log, Projector,
  Query, 4 schemas, 3 migrations).
- 3 Mix tasks: `tau.factory.emit`, `tau.factory.gate.assert_complete`,
  `tau.factory.sweep` — ~200 LOC.
- 1 LiveView + components: ~300 LOC.
- 1 PreToolUse hook script: ~80 LOC Python (stdlib only per
  `hooks-and-scripts.md`).
- 1 composite GitHub Action + 1 scheduled workflow.
- Test surface: property tests on `Event` validation, integration
  test on the projector, contract test on the composite action via
  `act` or a minimal CI matrix.
- Run-cost: GitHub Actions cron job every 30 min — ~48 runs/day at
  ~30s each, negligible.
- Knowledge: contributors must learn the `emit` protocol; mitigated
  by a single-page README and one example gate adoption.

## Dependencies

- **#374 (M7 web foundation)** — `:tau_web` Phoenix endpoint and
  PubSub up.
- **SPEC-WEB-DASHBOARD** — `Tau.PubSub` reuse invariant (D-184)
  applies; the projector broadcasts on the shared `Tau.PubSub`.
- **The `pre-merge-evidence-and-skip-integrity` sibling leaf's**
  decision about *where verdict authority lives* (CI artefact? PR
  body? both?) must be compatible — this proposal assumes CI is the
  authority, with the PR body summarising the read model.
- **The `knowledge-memory-and-audit-ingestion` sibling** owns the
  audit-finding write path; this leaf only renders the resulting
  counts. The sibling must emit `kind: audit_finding` events through
  `mix tau.factory.emit` (or write directly to the projector's
  schema with a documented contract).
- **A canonical event-log storage choice** — proposal MVP uses a
  GitHub release artefact (immutable, free, addressable); a
  follow-up may promote to Postgres if write rate justifies it.

## Confidence

**Medium.** The pattern (event sourcing + read model + completeness
assertion + pre-tool hook) is well-trodden; the only genuinely novel
piece is `mix tau.factory.gate.assert_complete`. What would raise
confidence: a 1-week prototype that wires `ac_linkage` and `mutation`
through `factory-gate` on a throwaway PR, plus a sample LiveView
mounted at `/factory` on a local endpoint.

## Prior art / references

- Event sourcing with a SQLite append-log: Datasette + `sqlite-utils`
  insert-rows pattern.
- The verdict-completeness pattern: GitHub's own required-checks API
  models it (a required check absent ≡ failing), but at the
  repository-settings layer rather than per-run; this proposal moves
  the assertion into the run itself for self-contained CI.
- `Tau.OtelReporter` already establishes the `[:tau, …]` telemetry
  namespace and a supervised subscriber pattern; the projector
  borrows the shape.
- `worktree-discipline.md` capture-before-destroy sequence is
  reused verbatim inside `mix tau.factory.sweep`.
- The composite-action wrapping pattern is the same one
  `actions/upload-artifact` uses for its post-step cleanup.

## Build-order

The build sequence is dependency-driven: each step produces an
artefact the next step assumes exists. None may be skipped without
silently disabling a downstream guarantee.

1. **B1 — Event envelope + log writer.** Land `Tau.FactoryState.Event`
   and `Tau.FactoryState.Log` (append-only, SQLite, single mutator).
   Tests: property test on `Event.validate/1`; integration test on
   `Log.append/1` round-trip. *Artefact:* `Event.t()` schema fixed.
2. **B2 — `mix tau.factory.emit`.** CLI wrapper around `Log.append`.
   Refuses invalid events with non-zero exit + named missing fields.
   *Artefact:* the single mutator that all subsequent producers call.
3. **B3 — Projector + schemas + `Query`.** Project events into
   `GateVerdict`, `Worktree`, `InvariantCheck`, `Run`,
   `AuditFinding`. *Artefact:* a queryable read model.
4. **B4 — `mix tau.factory.gate.assert_complete`.** The
   anti-silent-skip primitive. *Artefact:* the completeness check
   that downstream CI relies on.
5. **B5 — Composite GitHub Action `factory-gate` + adopt on one gate
   end-to-end.** Wrap `ac_linkage` first; demonstrate that
   completeness assertion catches a synthetic omission.
   *Artefact:* the wrapping contract, validated on one production gate.
6. **B6 — Adopt `factory-gate` on every existing gate.** Mutation,
   masking, dialyzer, credo, compile-warnings, etc. *Artefact:*
   universal wrapping; meta-check job greps for unwrapped invocations.
7. **B7 — `PreToolUse` hook `check-parent-on-main.py` +
   `.claude/settings.json` wiring.** *Artefact:* spawn-time
   `parent-on-main` enforcement.
8. **B8 — `mix tau.factory.sweep` + scheduled workflow
   `factory-sweep.yml`.** *Artefact:* hourly hygiene enforcement
   with verdict events.
9. **B9 — `mix tau.factory.alarm` + issue-opener integration.**
   *Artefact:* leaked-worktree threshold and missing-verdict
   timeout become open GitHub issues with `factory:hygiene` label.
10. **B10 — `FactoryLive` LiveView at `/factory`.** Mount on
    `:tau_web`; subscribe to `Tau.PubSub` topic `"factory:events"`;
    render five panels with error states. *Artefact:* single-query
    factory state surface (leaf-AC (a)).
11. **B11 — README + one-page adoption guide** for adding a new
    gate: declare the `gate_id`, wrap in `factory-gate`, emit on
    pass/fail. *Artefact:* operator-facing onboarding so future
    gates cannot bypass the mutator.

Order is strict: B5 cannot precede B4 (the wrapping has nothing to
assert); B7 should not precede B2 (the hook would have nowhere to
emit); B10 trails B3 (no schema, no LiveView). B6 may parallelise
across gates after B5 establishes the pattern. B11 lands with B5 so
adoption can begin immediately.
