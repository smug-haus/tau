# Software architecture — supervision tree & process topology

This layer maps the verified system shape (`../03-system-architecture/
system-architecture.md`, components L/K/S/G/W/U/M + Toolchain + Policy) onto
concrete Elixir/OTP, following the OTP design ordering (topology and failure
structure first, modules last) and the imposed constraints (D-S1..S4). It is the
authoritative spine; the per-subsystem files (`durable-spine.md`,
`control-plane.md`, `worker-fleet.md`, `gate-and-toolchain.md`,
`governance.md`) detail each component and all reference the tree defined here.

The factory is **its own OTP application** (`:tau_factory`), distinct from any
product it builds — closing the central gap that today's factory is a
prompt-loop, not a supervised process (research: `tau-current-analysis.md`
GAP-1).

## Step 0–1 — Process gate (every process justifies a runtime property)

| Component | Process? | Runtime property justifying it | OTP form |
|-----------|----------|--------------------------------|----------|
| L Ledger writer | yes | serialization of durable writes | `GenServer` (single writer) over Ecto/SQLite (Exqlite) |
| L Budget owner | yes | ETS ownership + serialized debit | `GenServer` owning a `read_concurrency` ETS table |
| K Coordinator | yes | lifecycle + serialized work-selection + total escalation | `gen_statem` (`running`/`halting`/`halted`) |
| S Scheduler | yes | serialization of admission decisions; back-pressure | `GenServer` |
| U Unit (PR) | yes (per-entity) | lifecycle + legal-transition FSM + failure isolation | `gen_statem` per PR, `DynamicSupervisor`+`Registry` |
| W Worker | yes (per-entity) | concurrency + failure isolation + lifecycle | supervised process/port, `DynamicSupervisor`+`Registry` |
| M Merge Authority | yes | **serialization (concurrency 1)** + sole `main` writer | `gen_statem` (`:idle/:integrating/:committing`) |
| G Gate run | **no** (transient) | bounded concurrent fan-out, then result | `Task.async_stream` under a `Task.Supervisor` |
| Conflict check, gate predicates, message folding | **no** | pure transformations | plain modules (properties before examples) |
| Toolchain adapter | **no** | declarative descriptor (data) | `behaviour`; engine executes via `Port` |
| Policy | **no** (data) | versioned config | ETS snapshot under an owner; pinned per unit |
| Egress: rate limiter, circuit breaker | yes | rate boundary + shared FSM state | reuse existing `RateLimiter`, `CircuitBreaker.Store` (ETS owner) |

Gate runs and pure logic are **not** processes — organizing them as processes
would add bottlenecks and failure domains for no runtime gain (the canonical
anti-pattern). The gate is a *bounded fan-out of known work* → `Task.async_stream`,
**not** Broadway (research OTP §6: Broadway only at a genuinely unbounded intake
boundary, which this is not).

## Step 2 — State durability partition

| State | Class | Home | On crash |
|-------|-------|------|----------|
| solution tree (units, attempts, verdicts, challenges, kill reasons, escalations), plan-of-record, policy versions, cost | **durable** | SQLite (Exqlite) via Ecto; backlog/jobs via Oban-Lite or a hand-rolled SQLite backlog | survives by construction (INV-16, RPO=0) |
| budget ledger | **durable** + hot-read | SQLite (truth) + ETS snapshot (admission reads) | truth survives; snapshot rebuilt in `init/1` |
| policy snapshot, circuit-breaker state, catalogs | **shared hot-read** | ETS under boring owners high in the tree | rebuilt from durable source on owner restart |
| worker workspace, in-flight gate context, agent conversation, derived views | **ephemeral/derived** | process heap / worker filesystem | rebuilt — losing it is the point of let-it-crash; uncommitted work captured first (INV-14) |

**Litmus (OTP skill):** no irreplaceable state in a process heap. Every factory
*decision* is WAL-committed to SQLite before its effect is visible; a worker's
*uncommitted* work is captured (staged+unstaged+untracked) by a monitor before
reclaim. Restart = recovery everywhere.

## Step 3 — The supervision tree

`rest_for_one` for the control-plane spine (later children depend on earlier;
research confirms this is already the live `Tau.Application` pattern), with the
error-kernel near the root (durable, simple) and risky restartable work in the
leaves.

```
Tau.Factory.Supervisor              [rest_for_one]   -- the control-plane spine
├── Tau.Repo                         (Ecto/SQLite via Exqlite)  -- durable store; root of all dependence
├── Oban                             (SQLite/Lite engine — durable jobs/backlog/retries/cron) [E1]
├── Tau.Factory.PubSub               (Phoenix.PubSub)  -- cross-proc events (never :global)
├── Ledger.Supervisor               [rest_for_one]     -- L
│   ├── Ledger.Writer               (GenServer: single durable-decision writer)
│   └── Budget.Owner                (GenServer: owns budget ETS, read_concurrency)
├── Policy.Owner                     (GenServer: owns versioned policy ETS snapshot)
├── Egress.Supervisor               [one_for_one]      -- reuse
│   ├── Provider.RateLimiter        (token-bucket)
│   └── CircuitBreaker.Store        (ETS owner; per-provider FSM)
├── Registries                      [one_for_one]
│   ├── Registry  UnitRegistry      (keys: unit/PR id)
│   └── Registry  WorkerRegistry    (keys: worker id)
├── Task.Supervisor  GateTasks       -- bounded gate fan-out (async_stream)
├── Tau.Factory.MergeAuthority      (gen_statem: :idle/:integrating/:committing; SOLE main writer)  -- M
├── Tau.Factory.WorkerSupervisor    [DynamicSupervisor, one_for_one, :temporary] -- W fleet
├── Tau.Factory.UnitSupervisor      [DynamicSupervisor, one_for_one, :temporary] -- U PR-FSMs
├── Tau.Factory.Scheduler           (GenServer: admission authority)             -- S
└── Tau.Factory.Coordinator         (gen_statem: the loop)  -- K, started LAST
```

**Strategy rationale (shared-fate declarations):**

- **Spine = `rest_for_one`.** Order *is* dependency order. If `Repo` dies,
  everything downstream restarts (they all read durable state). If `Coordinator`
  dies, only it restarts — and it **resumes from L** (LIV-5), re-deriving
  in-flight units; it does not resurrect them blindly.
- **`Ledger.Supervisor = rest_for_one`** — `Budget.Owner`'s ETS snapshot depends
  on `Ledger.Writer`/Repo being up first.
- **Fleet & units = `DynamicSupervisor` + `:temporary`.** The supervisor is a
  **death-certificate issuer, not a resurrector** (research OTP §3): a crashed
  worker/unit is **not** auto-restarted — its death is an *outcome* the owning
  FSM (U) or the Coordinator (K) decides via the durable state (FR-8.2). This is
  the decisive split: **supervision recovers *infrastructure*; the FSM + solution
  tree recover *semantics*.** A gate FAIL or bad LLM output is an outcome, never
  a crash to restart (the dominant BEAM-for-agents mistake).
- **`MergeAuthority` is a single `gen_statem`** — INV-3 (serialized merge) holds
  because at most one `:integrating` train exists at a time and the commit/push is
  serialized in the single M process; no lock discipline needed.
- **Error kernel:** `Repo`, `Ledger`, `Budget.Owner`, `MergeAuthority` near the
  root (precious state, simple logic); implementers/critics/toolchain runs in the
  leaves (risky, complex, restartable). Risk pushed down the tree.

[E1] **Oban** (on its **SQLite/Lite engine** per OQ-1; a hand-rolled SQLite
backlog is the fallback — `durable-spine.md` §8) provides the durable backlog,
retry, and cron-driver — it is the durable spine for *what work exists and what
is owed* (research OTP durability ruling: Oban-as-system-of-record, `gen_statem`
for live reactivity). Detail in `durable-spine.md`.

### Config-gating layer — the factory is OFF by default (P5c-6, #474; D-357)

The composition above is the subtree that exists **only when the factory is
enabled**. The control loop drives autonomous work that merges to `main`, so it
must never start merely because the binary launched. A boolean config gate sits
in front of the assembly:

```
config :tau, :factory, enabled: false   # default — opt-in is an operator action
```

`Tau.Factory.Supervisor.start_link/1` (and `Tau.Application`, which reads the
gate at boot — mirroring the established `Tau.OtelReporter` `:enabled`
precedent) consults this flag:

- **disabled (default)** → assemble **no** Coordinator-bearing subtree (the
  ledger-and-below children may still start for non-factory subsystems, but the
  Coordinator, Scheduler, Merge Authority, fleet, and Unit supervisors do not).
  `Process.whereis(Tau.Factory.Coordinator)` is `nil`; no work is driven. This is
  the "no-uncontrolled-work-on-normal-boot" safety property (**D-357**).
- **enabled** → assemble the full subtree in the order above, **Coordinator
  started LAST** (it depends on every sibling — D-344 resume reads the started
  Ledger; its seams reference the started fleet/merge/registry processes).

The gate is read **once at boot** from `config` (not `Application.put_env/3`
runtime mutation — OTP non-negotiable #1). The contract for the option surface
and seam-threading (the supervisor *derives* every per-child opt and wraps the
arity-1 `IssueSelector.select/1` and arity-2 `UnitDriver.drive/2` seams into the
arity-0/arity-1 forms the Coordinator expects; the caller hand-threads none of
the per-child opts) is recorded in `docs/spec/SPEC-FACTORY-CORE.md` §4 B11 /
D-357. This layer **records** the gate on top of the composition above; it does
not alter the composition or the start-order.

## Step 4 — Identity & read/write split

- **Logical identity, never pid.** Units and workers are addressed by key via
  `{:via, Registry, {UnitRegistry, unit_id}}` / `WorkerRegistry`. Lookup-or-start
  is race-safe through the registry's uniqueness guarantee. No held pids in
  durable state (a stored pid is a dangling pointer after restart).
- **Writes serialize through owners; reads bypass the mailbox.** `Ledger.Writer`
  is the single writer of decisions; admission reads the **budget ETS snapshot**
  directly (not via `GenServer.call`), and policy reads hit the **policy ETS
  snapshot** — copy-free, no owner bottleneck.
- **The merge CAS (HR-1/HR-2).** `MergeAuthority` is a `gen_statem`. The slow
  `T_int` work (rebase + gate + **health check**) runs **off the mailbox** in a
  monitored `Task` (`:integrating` state) so M stays responsive — see
  `merge-and-integration.md` §1 (final-validation H-1). The serialized **commit**
  is a short critical section (`:committing`): (a) **re-read** the *latest*
  verdict for every train member from L (append-only; a revoke that landed during
  the build supersedes — HR-2/H-3), then (b) apply via `git push` with
  `--force-with-lease`/expected-old-oid (the VCS conditional ref-update closes the
  external ref TOCTOU — HR-1). INV-3 holds because at most one train integrates at
  a time and the push is serialized in the single M process — not because the
  mailbox blocks for `T_int`.
- **`call` over `cast`** everywhere on the control path — the reply is
  back-pressure. `cast` into the merge authority or ledger would be a mailbox
  time-bomb.

## Step 5 — Back-pressure (designed in)

Speed mismatches and their explicit controls:

| Mismatch | Control |
|----------|---------|
| many parallel implementers → serial merge | **merge-train batch** in M (HR-5) + admission cap `W_cap` in S; back-pressure routed to the fleet, not just intake |
| gate fan-out → fan-in | `Task.async_stream` with bounded `max_concurrency` (not unbounded spawn) |
| factory → provider APIs | pool checkout + `RateLimiter` + `CircuitBreaker` (the checkout *is* the back-pressure) |
| budget → billable actions | admission pre-check against the budget ETS snapshot (INV-21) |

`W_cap` and merge-train size `B` are derived from the measured gate-stage
utilization `ρ_g < 1` (not the naïve `W*`); see `system-architecture.md` §5 and
`durable-spine.md`. No Broadway in v1 — the intake is bounded, known work.

## Step 6 — Distribution boundary (D-S4: single-node, dist-ready)

- **Control plane stays single-node** (L, S, K, **M**). The merge serialization
  point must be strongly consistent; clustering it imports split-brain risk into
  the one place that cannot tolerate it (research OTP ruling).
- **Only agent *execution* scales horizontally**, later, via an **explicit queue
  boundary** (Oban): remote workers *pull* work; they are idempotent and
  ref-correlated. This is an honest API boundary, not distributed-BEAM magic.
- **Location-transparency discipline now (cheap on BEAM):** addressing is by
  logical key (Registry), events via PubSub, **no `:global`, no cross-node ETS
  reliance**. Durable state on disk (the SQLite file, a node-local resource)
  survives a node *restart*; whole-machine loss is the HA question (deferred,
  `distribution-readiness.md`). Off-node workers reach the control node's queue
  over an **API boundary** (never a shared SQLite file); moving execution off-node
  is configuration + that queue, not a rearchitecture.

## Step 7 — Modules & behaviours (last)

Behaviours unify *interfaces*; processes isolate *blast radius*. The seams:

- `Tau.Factory.Toolchain` — behaviour; per-language adapters return **declarative
  descriptors** (engine executes — HR-3). `gate-and-toolchain.md`.
- `Tau.Provider` — reuse existing provider behaviour + adapters.
- `Tau.Factory.Gate.{AcLinkage,Masking,Mutation}` — pure functions (properties
  before examples). `gate-and-toolchain.md`.
- `Tau.Factory.ConflictCheck` — pure 5-clause predicate over *declared* sets
  (HR-4). `control-plane.md`.
- `Tau.Factory.Escalation` — the total set `E` (INV-18). `control-plane.md`.
- `Tau.Factory.Policy` — clamp logic (gate-floor non-shrinkable, `N=min(…)`, ∞
  rejected — HR-8). `governance.md`.

## Anti-pattern review (OTP checklist, applied)

1. No process exists only to namespace functions (gate/predicates are modules). ✓
2. No irreplaceable state in a heap (decisions durable; WIP captured). ✓
3. No long-lived process outside the tree. ✓
4. `rest_for_one` used where siblings depend (spine, ledger) — not defaulted. ✓
5. Reads bypass owner mailboxes (budget/policy ETS snapshots). ✓
6. No `cast` into slower processes on the control path (`call` = back-pressure). ✓
7. No pids as identity (Registry keys). ✓
8. No selective receive on hot processes (`gen_statem`/`call` use ref correlation). ✓
9. Extract fields before send (ids, not whole structs, across the wire). ✓
10. Node-crossing (future) is idempotent + ref-correlated via Oban. ✓
11. `terminate/2` NOT relied on for must-happen cleanup — capture is done by an
    independent **monitor** (survives `:kill`; INV-14). ✓
12. State machines are `gen_statem`, not GenServer-with-a-state-field (K, U). ✓
