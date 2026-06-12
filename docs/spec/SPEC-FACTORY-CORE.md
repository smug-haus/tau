# SPEC: Factory Core (control loop · ledger · scheduler · unit FSM)

| | |
|---|---|
| **Status** | Draft |
| **Date** | 2026-06-09 |
| **Scope** | The `:tau_factory` control core: the Coordinator loop (K), the durable Ledger (L), the Scheduler/admission authority (S), and the per-PR Unit FSM (U). Owns the total-escalation, durable-decision, conflict-gated-admission, and bounded-retry contracts. |
| **Method** | PSDH (`.claude/skills/design-reasoning`); L0 + boundary contracts. Derived from the verified architecture in `docs/arch/` (system-architecture §1; control-plane.md; durable-spine.md; traceability.md). |
| **Issue** | TBD — file before the first implementation PR (`tau-github-workflow`); reference as `Closes #N`. |

**Changelog:** Initial draft — §0–§7 + Appendix B. Introduces D-312, D-315,
D-317, D-318, D-320, D-321, D-330–D-333, D-335, D-336, D-340, D-342, D-343,
D-344. Cites (does not own) D-300–D-303 (SPEC-FACTORY-MERGE),
P5b amendment (PR #455): §4 B3 — adds precise contract for `snapshot_unit/2`
(WAL-before-ack, idempotency-keyed) and `latest_unit_snapshots/1` (resume-read
op, routed through Writer); §5 — adds Coordinator `:ledger` start option and
`init/1` resume semantics (D-344); §3 — adds [C113-B3] resume-read routing
constraint. D-344 is now fully specified and enforced by
`coordinator_recovery_test.exs`.
D-304–D-308/D-322/D-323 (SPEC-FACTORY-GATE),
D-309–D-311/D-313/D-314/D-316/**D-334**/**D-326** (SPEC-FACTORY-FLEET — D-334/CON-5
is owned by FLEET, whose capture mechanism is the enforcer, and **D-326** the
worker-completion `work_ready` contract; CORE only audits the disposition and
consumes the `worker_event` set at U's `implementing → gating` edge — §4 B8,
[C111b-B8]), D-319 (SPEC-FACTORY-GOV). Durable store decided:
**SQLite/Exqlite** (arch OQ-1).

## 0. Why this spec exists

The factory's control core is the brain of an autonomous loop that takes a
GitHub issue to a gate-passed, merged PR with **no human in the per-step loop**
(arch D-S1). The prior attempt ran this brain as a prompt-driven Claude session
whose state was a degrading context window plus a JSON file an agent had to
remember to update (arch `tau-current-analysis.md` GAP-1). The consequences on
file: the "compress-to-≤1000-tokens meta-restart" machinery exists *only*
because the state store is volatile, and every worktree-discipline rule that is
"prose an agent must obey" has been observed to fail.

This spec makes the control core a **supervised OTP application**: the
Coordinator is a `gen_statem`, the Unit lifecycle is a `gen_statem`-per-PR, the
Scheduler is a single-writer admission authority, and the solution tree is a
**durable transactional ledger** (SQLite/Exqlite, RPO=0) — not a context window.
The load-bearing properties are **total escalation** (the loop can always either
progress or name exactly why it cannot), **durable decisions** (a crash loses no
recorded decision), **conflict-gated admission** (concurrency never violates
isolation), and **bounded retry** (no infinite refine).

The component is maximally coordination-heavy (triage 5/5; §1) and therefore
requires this spec before any implementation PR modifies the control-core
boundary, per `.claude/rules/spec-before-code.md`.

## 1. Triage

| # | Property | Score | Evidence |
|---|----------|-------|----------|
| 1 | Shared mutable state | 1 | The solution tree (units, attempts, verdicts, budget) is read by the loop and written on every decision; the Scheduler's in-flight set `F` is read/written on every admission. Both are concurrently consulted. |
| 2 | Temporal coupling | 1 | `select → admit → drive → unit_terminal` is strictly ordered; a decision is durable only *before* its effect is visible (WAL-before-ack); the kill switch acts only at a unit boundary. |
| 3 | Cross-process coordination | 1 | K (`gen_statem`), S (`GenServer`), N× U (`gen_statem`), L (`GenServer`/Exqlite), plus monitored refs to workers and PubSub to observers — coordination spans many processes with no shared mailbox. |
| 4 | Feedback loops | 1 | gate FAIL → refine/pivot → re-gate; a stall → timeout → retry ladder → escalation; budget spend → admission denial. The loop's behaviour feeds back into its own admission and retry decisions. |
| 5 | State accumulation | 1 | Attempt count `k` accumulates per PR until the N bound; the budget ledger accumulates spend until exhaustion; the solution tree accumulates the full decision history that survives restarts. |

**Triage score: 5/5. L0 + boundary contracts indicated.**

## 2. Component decomposition

Naming is precise so §4 contracts attach to specific operations. All modules are
under the `Tau.Factory.*` namespace and supervised by `Tau.Factory.Supervisor`
(arch `supervision-tree.md`).

| # | Component | Role |
|---|-----------|------|
| C1 | `Tau.Factory.Ledger.Writer` | **L.** Single durable-decision writer (`GenServer` over Ecto/Exqlite). WAL-before-ack; the append-only system of record for units, attempts, verdicts, challenges, escalations, budget, policy versions. Sole writer of every decision datum (arch HR-9). |
| C2 | `Tau.Factory.Budget.Owner` | **L (hot-read).** `GenServer` owning a `read_concurrency` ETS snapshot of remaining budget. Truth is in L (C1); the snapshot is a derived projection rebuilt in `init/1`. Admission reads bypass its mailbox. |
| C3 | `Tau.Factory.Coordinator` | **K.** `gen_statem` (`running`/`halting`/`halted`). Selects work, drives admitted units, classifies every non-progress trigger into exactly one escalation reason, runs the clean kill. |
| C4 | `Tau.Factory.Scheduler` | **S.** `GenServer` admission authority. Holds the in-flight set `F` and per-unit policy pins; admits a unit only when the conflict check clears and budget headroom exists; monotone. |
| C5 | `Tau.Factory.ConflictCheck` | Pure 5-clause admission predicate over **declared** scope (arch HR-4). No process. Properties before examples. |
| C6 | `Tau.Factory.Unit` | **U.** `gen_statem` per PR, `:temporary` under `UnitSupervisor`, keyed in `UnitRegistry`. Owns the *entire* PR lifecycle; bounded refine→pivot→escalate; snapshots each transition to L. |
| C7 | `Tau.Factory.Escalation` | Pure classifier `classify/1 → {e, scope}`; the total escalation set `E`. No process. |
| C8 | `Tau.Factory.Retry` | Pure retry-ladder decision `next/3 → {:refine,k} \| :pivot \| :exhausted`. No process. |
| C9 | `Tau.Factory.KillSwitch` | Supervised owner watching the operator sentinel/control channel; emits one PubSub event. The kill *mechanism*; K consumes it at a unit boundary. |

Boundaries (B-N attach contracts in §4):

| # | Boundary | Operation |
|---|----------|-----------|
| B1 | C3 Coordinator ↔ C4 Scheduler | `admit(unit, declared_scope)` → `:admit \| {:defer, reason}` (`call`). |
| B2 | C4 Scheduler ↔ C5 ConflictCheck | `clear?(declared, F)` pure call (five clauses). |
| B3 | {C3,C6} ↔ C1 Ledger.Writer | `record_decision` / `append_verdict` / `revoke_verdict` / `debit_budget` / `record_challenge` / `record_escalation` (`call`, WAL-before-ack). |
| B4 | C4 Scheduler ↔ C2 Budget.Owner | `budget_precheck/1` — ETS snapshot read, bypasses the mailbox. |
| B5 | C6 Unit ↔ C3 Coordinator | `unit_terminal(u, outcome)` / `escalate(e)` (the loop's progress + escalation feed). |
| B6 | C6 Unit ↔ **M** (SPEC-FACTORY-MERGE) | `request_merge(unit, hash)` — non-blocking submit; async `:merged`/`:rejected`. **Cited boundary.** |
| B7 | C6 Unit ↔ **G** (SPEC-FACTORY-GATE) | `request_gate(unit, diff, frozen_paths, pin)` / `gate_outcome`. **Cited boundary.** |
| B8 | C6 Unit ↔ **W** (SPEC-FACTORY-FLEET) | `spawn(role, brief, ref)` / `{:DOWN,…}` / `worker_stalled`. **Cited boundary.** |
| B9 | C9 KillSwitch ↔ C3 Coordinator | `:halt_requested` over PubSub `"factory:control"`. |
| B10 | C3 Coordinator ↔ external tracker | `select_next` / `reconcile` (issue source; reconciliation, CON-2). |

## 3. L0 constraints

Format: `[Cn-Bm]` = constraint number + boundary. **★** marks non-obvious.

### Q1: What can be written by more than one actor?

- **★ [C100-B3]** Every durable decision datum has **exactly one writer**:
  `Ledger.Writer` (C1). The Coordinator, Units, and Gate all *request* writes;
  none writes the store directly. This single-writer discipline is what makes
  the conservation laws (D-330..D-336) hold by construction — no datum has two
  writers, so no update is lost or double-counted (arch HR-9). Splitting the
  decision writers (the rejected authority-split) reintroduces a distributed
  transaction across writers and is forbidden.
- **★ [C101-B4]** The budget *truth* is written only by `Ledger.Writer`
  (`debit_budget`); `Budget.Owner` (C2) holds a **derived** ETS snapshot. The
  snapshot is never the writer of record. A debit updates L first, then the
  snapshot write-through; a crash between them is healed by `init/1` rebuild
  from L (the snapshot is reconstructable, never authoritative).
- **[C102-B1]** The in-flight set `F` is written only by the Scheduler (C4) on
  admit/terminal. The Coordinator and Units *read* admission results; they never
  mutate `F`.

### Q2: What ordering assumptions are implicit?

- **★ [C103-B3]** **WAL-before-ack.** `Ledger.Writer` MUST commit a decision to
  the SQLite WAL (`synchronous=FULL`, `fsync`) **before** replying `{:ok, ref}`,
  and the decision's external effect (a merge, a spawn, a report) MUST happen
  only *after* that reply. This ordering is the whole of RPO=0 (D-315): a
  decision is externally visible only once durable.
- **★ [C104-B1]** The conflict check runs over **declared** scope fixed at
  scope-freeze (arch FR-1.3), **not** post-hoc actual paths. Admission is
  therefore a pure function of pre-frozen declarations, which is what makes it
  *monotone* (D-343): a deferred unit keeps its place; no admit→withdraw→re-admit
  cycle. A post-hoc check on actual paths is non-monotone and forbidden.
- **★ [C105-B5]** A **semantic** failure (gate FAIL, bad model output) is an
  *outcome transition* inside U; an **infrastructure** failure (worker `:DOWN`)
  is an *event* U handles. These MUST NOT be conflated: encoding a gate FAIL as a
  process crash crash-loops the supervisor and burns budget (arch FR-8.2, the
  dominant BEAM-for-agents mistake). Supervision recovers infrastructure; the FSM
  + ledger recover semantics.
- **[C106-B9]** The kill switch is consumed by K **only at a unit boundary**
  (after `unit_terminal`), never mid-unit. Worst-case halt latency is one unit;
  the halt is clean (`main` synced, never mid-merge).

### Q3: What happens if a component fails silently?

- **★ [C107-B5]** A **wedged-but-not-crashed** worker (Port alive, no `:exit_status`,
  no `:DOWN`) emits **no trigger** — so K would idle with nothing to classify and
  the loop would silently livelock. Every U state that awaits an external actor
  (`oracle`, `implementing`, `gating`, `awaiting_merge`) MUST arm a mandatory
  `:state_timeout`, and the fleet MUST run a heartbeat watchdog that synthesizes
  a `worker_stalled` event on heartbeat absence. This is the only thing that
  makes total escalation hold over reachable *states*, not merely over the
  classifier's domain (D-317; arch final-validation H-2).
- **★ [C108-B3]** If `Ledger.Writer` is briefly unavailable, callers **block on
  that specific datum** (`call`, the reply is back-pressure); the system never
  guesses past the authority (fail-closed). A `cast` into L would risk losing a
  decision on crash and is forbidden.
- **[C109-B5]** A non-progress state with no foreseen cause MUST escalate
  `E-UNCLASSIFIED` (the catch-all), never spin. Its firing is logged as a defect
  signal.

### Q4: What information crosses a boundary, and what is lost?

- **★ [C110-B7]** A gate verdict crossing from G to L is **append-only and
  immutable per `(hash, run)`** — a later challenge or finding appends a
  *superseding revocation*, never an in-place mutation (arch HR-2). "Latest
  status for a hash" is a query over the append-only rows. The merge boundary
  (B6, SPEC-FACTORY-MERGE) reads the *latest* inside its CAS; hash-keying alone
  closes content staleness but **not value staleness**, so immutability is
  load-bearing.
- **★ [C111-B5]** When U reports `unit_terminal`, the *outcome* (`merged` /
  `escalated` / `rejected`) is preserved with its full provenance (attempt count,
  last verdict hash, challenge log). No outcome is reduced to a bare boolean —
  the conservation laws need the full lineage (NFR-AUDIT).
- **★ [C111b-B8]** **Worker completion crosses as an asserted event, not an exit
  code (cited D-326, owned by FLEET).** The fact "the agent produced a stable
  diff" crosses to U **only** as `work_ready(worker_id, branch, head_sha)` — an
  in-band frame the agent emits before exit. A clean Port exit (`:exit_status 0`)
  carries one bit and **loses** the distinction between "did the work / pushed a
  real diff", "ran and pushed nothing", and "crashed but exited 0"; U must not
  infer completion from it. The `branch`/`head_sha` is the evidence U needs to
  confirm a non-empty diff before `request_gate`; exit-0-without-`work_ready`
  crosses as `worker_exit(w, :no_work_product)` and is routed to the retry
  ladder, never gated. The three worker-outcome events (`work_ready`,
  `worker_exit`, `worker_stalled`) are disjoint and keyed by `worker_id`.
- **[C112-B10]** The external tracker is the authority for *what to build*; L is
  the authority for *what has been done*. The reconciliation pass crosses this
  boundary read-only (the tracker is projected, never a second writer of L).
- **★ [C113-B3]** **Resume-read routed through the writer process.** The
  resume-read op `Ledger.Reader.latest_unit_snapshots/1` is routed through
  the `Ledger.Writer` GenServer process via `GenServer.call/2` — NOT through a
  separate SQLite connection. This guarantees that the read sees all prior
  WAL-committed writes (visibility ⊐ commit, D-315). Opening a second
  connection for reads would require WAL-reader synchronisation and is
  forbidden for this low-frequency op.

### Q5: Where are the feedback loops, and are they bounded?

- **★ [C113-B5]** The refine loop (gate FAIL → refine_k → re-gate) is bounded at
  **N** refines (Policy-clamped, `N = min(policy, ceiling)`; ∞ rejected — arch
  HR-8), then one pivot, then `E-RETRY-EXHAUSTED`. The attempt count is durable
  PR state (D-318). Unbounded refine is forbidden (LIV-1).
- **★ [C114-B1]** The admission ↔ merge feedback (each merge re-stales in-flight
  branches, forcing re-gates) is bounded by `W_cap`, derived from gate-stage
  utilization `ρ_g < 1 − margin`, **not** the naïve `W*` (arch system-arch §5).
  The Scheduler MUST route back-pressure to the fleet, not only to intake.

### Q6: What are the pre/post-conditions at each boundary?

- **[C115-B1]** `admit/2` pre: `Store`/L running. Post: returns `:admit` only if
  the conflict check cleared against the *current* `F` and budget headroom holds;
  on `:admit`, the unit is added to `F` (a write) before the reply.
- **[C116-B3]** `append_verdict` pre: the `(hash, run)` coordinate is not already
  present (a partial unique index enforces one original per coordinate). Post: a
  later `revoke_verdict` is a *new* row with `supersedes_id`, never an update.

### Q7: What is the message-ordering protocol?

- **★ [C117]** The **control path is `call`** (the reply is back-pressure):
  K→S admit, U→L writes, U→M submit. The **observation plane is PubSub**
  (`"factory:report"`, `"factory:pr:#{id}"`, `"factory:escalation"`) — decoupled
  fan-out to observers, never the control path. **Liveness is monitored refs**
  (`:DOWN`). No `:global`, no `Process.whereis |> send` (OTP non-negotiable #4).
- **[C118]** Identity is a **Registry key**, never a pid. No pid is stored in any
  durable record (a stored pid is a dangling pointer after restart). On resume, U
  and worker refs are re-resolved by key.

### Q8: What is the change-impact (what else must move if this changes)?

- **[C119]** Adding a new escalation reason changes the **total set `E`** and the
  pure classifier (C7); the totality proof (D-317) MUST be re-discharged. Adding a
  new durable decision kind changes the Ledger schema and a conservation law
  (CON-*) — both in the same PR (no new state at a SPEC'd boundary without its §3
  constraint + §4 contract). Changing `W_cap` sizing is policy, engine-clamped,
  and never touches an invariant.

## 4. Boundary contracts

### B1: Coordinator (C3) ↔ Scheduler (C4)

- `admit/2 :: (unit_id, declared_scope) -> :admit | {:defer, reason}` (`call`).
- Pre: Scheduler running; `Ledger.Writer` running.
- Post: `:admit` ⟺ `ConflictCheck.clear?(declared_scope, F)` ∧
  `budget_precheck(unit) == :ok` ∧ `|F| < W_cap`; on `:admit`, `unit_id` is added
  to `F` before the reply (single-writer of `F`).
- Invariant (**D-343, monotone**): a `{:defer, _}` never demotes a unit's queue
  position; deferred units are served in arrival order with aging.

### B2: Scheduler (C4) ↔ ConflictCheck (C5)

- `clear?/2 :: (scope, %{unit_id => scope}) -> boolean()` — pure, total.
- `pairwise_clear?/2` is the conjunction of five clauses: no-dependency,
  disjoint-files (**including declared gating-test paths** — a shared
  `test/support` collision surface), disjoint-codepoints, no-shared-SPEC/D-NNN,
  resource-isolatable.
- Invariants (properties, §6 D-312): symmetry; non-trivial self-conflict;
  monotone-in-`F`; each clause necessary; gating-path collision blocks.

### B3: {Coordinator, Unit} ↔ Ledger.Writer (C1)

- Write API (all `call`, WAL-before-ack): `record_decision/2`,
  `append_verdict/3`, `revoke_verdict/2`, `debit_budget/3`, `record_challenge/2`,
  `record_escalation/3`, `snapshot_unit/2`.
- Pre: `Repo` (Exqlite) up; an **idempotency key** (deterministic, e.g.
  `{unit_id, kind, coordinate}`) accompanies every write.
- Post: the SQLite WAL commit (`synchronous=FULL`) completes **before** the
  `{:ok, ref}` reply; a replayed write with the same idempotency key is a no-op.
- Invariant (**D-315, RPO=0**): visibility(effect) ⊐ commit(decision). A
  coordinator restart resumes from L with no decision lost or re-applied.
- **Verdict immutability (D-335, [C110-B7]):** `append_verdict`/`revoke_verdict`
  are **inserts only**; a partial unique index `(unit_hash, gate_run, gate_half)
  WHERE kind='verdict'` enforces one original per coordinate; a revoke is a new
  row with `supersedes_id`. No `update` changeset exists for verdicts.

#### B3 — `snapshot_unit/2` (durable unit-state write op, D-344 / P5b)

```
Ledger.Writer.snapshot_unit(server, attrs) :: {:ok, ref} | {:error, term}
  attrs :: %{
    unit_id:         String.t(),   # PR/unit identifier
    state:           atom(),       # Unit FSM state at this snapshot
                                   # (one of: planned | oracle | implementing |
                                   #  gating | refine_k | awaiting_merge |
                                   #  merged | escalated)
    idempotency_key: String.t()    # deterministic per {unit_id, kind, coordinate}
  }
```

Append-only (no UPDATE path); WAL-before-ack (D-315). A replay with the same
`idempotency_key` is a no-op: `INSERT OR IGNORE` returns the existing row id.
`{:ok, ref}` arrives only after the SQLite WAL commit is durable, so a snapshot
survives a Coordinator crash. `:merged` and `:escalated` are terminal sinks.

#### B3 — `latest_unit_snapshots/1` (resume-read op, D-344 / P5b)

```
Ledger.Reader.latest_unit_snapshots(server) :: %{unit_id => state_atom}
```

Returns the latest snapshotted state per `unit_id` (highest row `id` wins)
across the whole ledger. Routed through the `Ledger.Writer` process (sole
connection owner) to guarantee reads see all prior WAL-committed writes.
Used exclusively by `Coordinator.init/1` to rebuild the in-flight set on
resume (D-344). Terminal units (`:merged`/`:escalated`) appear in the map;
the Coordinator filters them. Returns `%{}` when no snapshots exist.

#### B3 — Unit `:ledger` start option (durable per-transition snapshotting, D-318 / P5c-1)

`Unit.start_link/1` accepts an optional `:ledger` key:

```
:ledger — GenServer.server() | nil
```

When `:ledger` is present and non-nil, the Unit calls
`Ledger.Writer.snapshot_unit(ledger, attrs)` on **each state entry**, before the
state's external effect (WAL-before-ack, D-315). This makes the Unit's FSM
state crash-durable and enables the Coordinator's D-344 resume to rehydrate
**real** units (not only the injected test seam).

The `idempotency_key` coordinate is `"<unit_id>:snapshot:<entry_seq>"` —
per-entry-unique because `entry_seq` is a monotonic counter (initialised to 0
in `init/1`, incremented on every `snapshot_unit/2` call). Every state entry
— including backward-edge re-entries such as `:gating` after a merge-reject
or `:implementing` after a gate-fail refine — writes a **new row** with a
distinct key. `INSERT OR IGNORE` remains the writer contract: a genuine replay
of the same `entry_seq` (same coordinate) is still a no-op (D-315). The
highest row `id` per `unit_id` in `latest_unit_snapshots/1` therefore returns
the **genuinely-latest** FSM state, not the forward-stale state that a
per-state key would leave when a backward edge re-enters an already-visited
state.

When `:ledger` is `nil` or absent, snapshotting is a **no-op** — existing
callers that pass no `:ledger` opt are unaffected (back-compat).

### B4: Scheduler (C4) ↔ Budget.Owner (C2)

- `budget_precheck/1 :: (unit_id) -> :ok | {:exhausted, dimension}` — reads the
  ETS snapshot directly (bypasses the owner mailbox; reads are not serialized).
- Pre: snapshot rebuilt in `Budget.Owner.init/1` from L truth.
- Post: `:ok` only if every budget dimension (token/cost/wall-time/iteration) has
  headroom for the unit's admission.
- Invariant (**D-320**): admission is denied at the ceiling **before** the unit
  becomes billable; overrun ≤ one in-flight action.

### B5: Unit (C6) ↔ Coordinator (C3)

- `unit_terminal/2 :: (unit_id, outcome)` where `outcome ∈ {merged, escalated,
  rejected}` with full provenance ([C111]).
- `escalate/1 :: (trigger)` — routes to K, which classifies via C7.
- Invariant (**D-340**): every admitted unit ◇ reaches a terminal outcome
  (exhausting the retry ladder *is* a terminal `escalated`).

### B6: Unit (C6) ↔ Merge Authority (M) — *cited, SPEC-FACTORY-MERGE*

- `request_merge/2 :: (unit_id, hash) -> :queued` (non-blocking; the result
  `:merged`/`:rejected` arrives asynchronously via `"factory:pr:#{id}"`). A
  blocking `call` across a minutes-long merge build is forbidden (arch H-1b).
- M owns INV-1..4 / D-300..D-303; U only submits and consumes the result.

### B7: Unit (C6) ↔ Gate (G) — *cited, SPEC-FACTORY-GATE*

- `request_gate/4` / `gate_outcome` (`:pass` | `{:fail, findings}`). The gate is
  the only legal producer of a verdict (G appends to L per B3 / D-335). G owns
  D-304..D-308, D-322, D-323.

### B8: Unit (C6) ↔ Worker fleet (W) — *cited, SPEC-FACTORY-FLEET*

- `spawn(role, brief, ref)`; U holds a `Process.monitor/1` ref for liveness. W
  surfaces the **disjoint** `worker_event` set, all keyed by `worker_id`, which U
  consumes (U `E_in`): `work_ready(w, branch, head_sha)` (**success** — the agent
  asserted a stable diff in-band; the sole trigger of `implementing → gating`),
  `worker_exit(w, reason)` (the `:DOWN` death certificate — infra path,
  gate NOT called), and `worker_stalled(w)` (the watchdog's synthetic
  heartbeat-absence trigger, [C107]). U tags the **current** `worker_id` and
  discards events from a superseded worker. Clean Port exit (`:exit_status 0`)
  without `work_ready` is NOT completion — it arrives as
  `worker_exit(w, :no_work_product)` (**D-326, cited owner: SPEC-FACTORY-FLEET**).
  W owns isolation/capture D-309..D-311, D-313, D-314, D-316 and the completion
  contract D-326.

### B9: KillSwitch (C9) ↔ Coordinator (C3)

- `:halt_requested` broadcast on PubSub `"factory:control"`; K sets
  `halt_pending` and acts at the next `unit_terminal` (**D-321**). The sentinel
  is operator state (git-ignored), never project state.

### B10: Coordinator (C3) ↔ external tracker

- `select_next` reads open issues (smallest shippable increment, arch FR-2.1);
  `reconcile` is a read-only projection used to discharge CON-2 (D-331). The
  tracker is never a second writer of L.

## 5. State enumeration

### Coordinator (K) — `gen_statem`, `state_functions`

| State | Meaning | Entry | Exit |
|-------|---------|-------|------|
| `running` | The loop: select → admit → drive → next | start (resume from L) | global `e` → `halting`; per-unit `e` → stay (unit→escalated) |
| `halting` | Drain in-flight units to a clean checkpoint | global escalation or kill at a unit boundary | all units quiesced, `main` synced, `¬mid_merge` → `halted` |
| `halted` | Terminal; awaits operator / next milestone | drain complete | operator resumes / assigns |

`running` is the **only** non-progress-capable state; the totality argument
(D-317) is discharged there.

#### Coordinator `:ledger` start option and `init/1` resume semantics (D-344 / P5b)

`Coordinator.start_link/1` accepts an optional `:ledger` key:

```
:ledger — GenServer.server() | nil
```

When `:ledger` is present and non-nil, `init/1` performs a **durable resume**:

1. Calls `Ledger.Reader.latest_unit_snapshots(ledger)` to read the snapshotted
   state per `unit_id` at crash time.
2. **Rehydrates** each NON-terminal unit (state ∉ {`:merged`, `:escalated`}) by
   driving it forward — these units resume the loop at their snapshotted state.
3. **Skips** every unit already at a terminal sink (`:merged` / `:escalated`) —
   no work is re-done; exactly-once on resume (D-344 crux).
4. After rehydration the loop falls through to `select_fun` as normal.

The `running` state entry text "start (resume from L)" refers to this path
(D-344, D-315 / RPO=0). The `data` map carries a `rehydrated` key that
records which unit_ids were resumed (observable via `:sys.get_state/1`).

### Unit (U) — `gen_statem`, one per PR

```
state ∈ {planned, oracle, implementing, gating, refine_k, awaiting_merge, merged, escalated}

 planned ─admit(S)→ oracle ─test-author frozen→ implementing ─work_ready(w,branch,head_sha) ⇒ request_gate→ gating
                                                            (D-326: in-band success event keyed by worker_id; NOT exit 0)
   gating + :pass            → awaiting_merge ─M :merged→ merged (terminal)
   gating + {:fail,f}        → refine_k        (k<N → implementing; k=N → pivot → implementing; pivot red → escalated [E-RETRY-EXHAUSTED])
   awaiting_merge + M reject → gating          (re-gate; INV-2)
   {oracle,implementing,gating,awaiting_merge} + :state_timeout/worker_stalled → refine/pivot/escalate
   any non-terminal + escalation(e) → escalated (terminal)
```

Illegal transitions are **unrepresentable** (no clause): e.g. `gating → merged`
directly cannot happen; an attempt crashes the FSM rather than merging an ungated
diff (INV-1). `merged` and `escalated` are terminal sinks. Every transition
`snapshot_unit/2`s durable state to L before its external effect (D-315, LIV-5).

### The total escalation set `E` (D-317)

| `e` | Trigger | Scope |
|-----|---------|-------|
| `E-AMBIGUITY` | irreducible spec/product ambiguity | per-unit |
| `E-RETRY-EXHAUSTED` | N refines + failed pivot | per-unit |
| `E-CONFLICT` | unresolvable merge conflict | per-unit |
| `E-DESTRUCTIVE` | destructive action requested (*cited, GOV/D-319*) | per-action |
| `E-BUDGET` | budget exhausted | global |
| `E-RED-MAIN` | post-merge health red (*cited, MERGE/D-303*) | global |
| `E-CHALLENGE` | > 2 upheld challenges on one PR | per-unit |
| `E-UNCLASSIFIED` | catch-all (any non-progress trigger) | global |

## 6. D-NNN invariants

> Owned by this SPEC. Each names its detection method. Cited D-NNN (merge/gate/
> fleet/gov) are enforced by their owner SPEC and only *consumed* here.

**D-312 — Conflict-gated admission is sound and monotone:**
`Scheduler` admits a unit iff `ConflictCheck.clear?/2` returns true over the
*declared* scope against the current `F`. The predicate is symmetric, self-
conflicting on non-trivial scope, **monotone in `F`** (adding to `F` only removes
admissions), every clause is necessary, and any shared gating-test path blocks.
Enforced by the property suite `conflict_check_property_test.exs` (properties
P-CC-1..5, tagged `:property`). A non-monotone or post-hoc-actual-path check
falsifies this and LIV-4.

**D-315 — Durable decisions, RPO=0:**
Every decision write commits to the SQLite WAL (`synchronous=FULL`) **before**
its `{:ok, ref}` reply, and its external effect happens only after the reply.
A coordinator killed immediately after a decision resumes from L with that
decision present exactly once (idempotency key) and no later decision lost.
Enforced by a crash test `ledger_durability_test.exs` (kill the writer between
commit and effect; assert exactly-once on resume) and the WAL-before-ack ordering
in `Ledger.Writer`.

**D-317 — Escalation is total over reachable states:**
(a) `Escalation.classify/1` is **total over `term()`** — its catch-all returns
`{:unclassified, :global}`; AND (b) every reachable non-progress state **emits a
trigger** within a bounded window — every U waiting state arms a mandatory
`:state_timeout` and a fleet watchdog synthesizes `worker_stalled` on heartbeat
absence. Together: no reachable state is both non-progress and unclassified.
Enforced by `escalation_property_test.exs` (classify totality, tagged
`:property`) **and** `unit_timeout_test.exs` (a wedged-worker simulation reaches
`escalated`, not a spin). Both halves are required — classifier totality alone is
insufficient (arch final-validation H-2).

**D-318 — Retry is bounded and laddered:**
`Retry.next/3` yields `{:refine,k}` only while `k < N` (`N = min(policy,
ceiling)`; ∞ rejected), then `:pivot` once, then `:exhausted`. The attempt count
is durable PR state; total attempts ≤ `N_refine + N_pivot`. Enforced by
`retry_property_test.exs` (no input sequence exceeds the bound; tagged
`:property`) and the durable `units.attempt_count` column.

**D-320 — Budget ceiling is a hard pre-admission gate:**
`budget_precheck/1` denies admission at the ceiling **before** the unit becomes
billable; recorded spend never exceeds budget by more than one in-flight action;
exhaustion raises `E-BUDGET`. Enforced by `budget_admission_test.exs` (drive
spend to the ceiling; assert the next admission is denied and `E-BUDGET` fires).

**D-321 — Clean kill at a unit boundary:**
A kill sets `halt_pending`; the loop transitions to `halting` only at the next
`unit_terminal`, completing that unit's terminal fold (incl. any merge + sync)
first; `halting → halted` fires only with `main` synced and `¬mid_merge`.
Worst-case latency is one unit. Enforced by `kill_switch_test.exs` (kill mid-unit;
assert halt occurs after the unit, `main` synced, never mid-merge).

**D-330 — Work conservation:** every accepted unit reaches exactly one terminal
state; `accepted = merged ⊎ escalated ⊎ rejected ⊎ in_flight`. Enforced by the
reconciliation pass `reconcile_test.exs` (no unit in zero or two terminal sets).

**D-331 — Issue reconciliation:** `state_tree(i) ≡ state_tracker(i)` for every
in-scope issue; `|steps_recorded| = |steps_executed|`. Enforced by
`reconcile_test.exs` against a tracker snapshot.

**D-332 — Budget conservation:** `Σ recorded_action_cost = total − remaining` at
all times (single-writer double-entry). Enforced by a ledger balance assertion in
`budget_admission_test.exs`.

**D-333 — Cost attribution:** every spend has exactly one owner (step/agent/gate
run); `Σ attributed = total_spent`. Enforced by `cost_attribution_test.exs`.

**D-334 — Artifact conservation (CITED — owned by SPEC-FACTORY-FLEET):** a
terminated worker's dirty state is `committed ⊎ captured ⊎ discarded-by-decision`
— never lost by omission. The **capture mechanism is FLEET's `WorkspaceJanitor`
(D-314)** and FLEET owns the CON-5 invariant; CORE's role is only that **the
Ledger records the disposition**, audited by the join in `reconcile_test.exs`.
Listed here as a consumed contract, not a CORE-owned D-NNN.

**D-335 — Verdict conservation (append-only):** a unit is `merged` only with a
fresh PASS verdict per required gate half for its exact `hash`; verdicts are
immutable per `(hash, run)`, a revoke is a superseding insert. Enforced by the
partial unique index migration and `verdict_append_only_test.exs` (attempt to
update a verdict ⇒ no update path exists; latest-status query returns the
superseding row).

**D-336 — Escalation conservation:** every raised escalation is delivered to the
operator and recorded with reason + state snapshot; none is raised-and-swallowed.
Enforced by `escalation_delivery_test.exs`.

**D-340 — Unit termination (liveness):** under fair scheduling every accepted
unit ◇ reaches `merged \| escalated \| rejected`. Discharged by D-318 (bounded
retry) + D-317 (total escalation). Enforced by a model-style test
`unit_termination_test.exs` driving each failure path to a terminal sink.

**D-342 — Milestone termination (liveness):** the assigned milestone ◇ reaches
zero open issues ∨ escalated. Discharged by D-340 per issue + D-331. Enforced by
an integration test over a synthetic milestone.

**D-343 — No livelock (liveness):** the Scheduler's admission is monotone (D-312
P-CC-3) and the scope-amendment path re-admits as a fresh monotone decision; no
reachable admit→withdraw→re-admit cycle. Enforced by `conflict_check_property_test.exs`
(monotonicity) + `scope_amendment_test.exs`.

**D-344 — Recovery progress (liveness):** after a coordinator crash the loop
resumes from L and continues; in-flight units rehydrate at their snapshotted
state; no terminal work is re-done. Enforced by `coordinator_recovery_test.exs`
(kill the Coordinator mid-drive; assert resume + idempotent rehydrate).

## 7. Acceptance criteria

Each is expressed against the user-facing path with an observable signal.
PR groupings are indicative.

- **AC-1 (PR-CORE-1):** `mix compile --warnings-as-errors` passes with the
  `Tau.Factory.{Ledger.Writer, Budget.Owner}` + Exqlite repo present; `Tau.Factory.Supervisor`
  starts them under `Tau.Application`. Signal: `mix test` boots the tree.
- **AC-2 (PR-CORE-1, D-315):** `mix test test/tau/factory/ledger_durability_test.exs`
  passes — a writer killed between WAL commit and effect resumes with the decision
  present exactly once. Signal: the test asserts exactly-once on resume.
- **AC-3 (PR-CORE-2, D-312/D-343):** `mix test --only property` passes including
  `conflict_check_property_test.exs` (P-CC-1..5, incl. monotonicity).
- **AC-4 (PR-CORE-2, D-320/D-332):** `budget_admission_test.exs` passes — spend
  driven to the ceiling denies the next admission and raises `E-BUDGET`; the
  ledger balance holds.
- **AC-5 (PR-CORE-3, D-318):** `mix test --only property` passes including
  `retry_property_test.exs` — no input sequence exceeds `N_refine + N_pivot`.
- **AC-6 (PR-CORE-3, D-317):** `escalation_property_test.exs` (classify totality)
  **and** `unit_timeout_test.exs` (a wedged-worker simulation reaches `escalated`)
  both pass. Both are required.
- **AC-7 (PR-CORE-4, D-321):** `kill_switch_test.exs` passes — a kill mid-unit
  halts *after* the unit with `main` synced and never mid-merge.
- **AC-8 (PR-CORE-4, D-344):** `coordinator_recovery_test.exs` passes — the
  Coordinator killed mid-drive resumes from L and re-does no terminal work.
- **AC-9 (PR-CORE-5, D-335):** `verdict_append_only_test.exs` passes — no update
  path exists for a verdict; the latest-status query returns the superseding row
  (the merge-CAS value-staleness contract this SPEC supplies to SPEC-FACTORY-MERGE).
- **AC-10 (PR-CORE-5, D-330/D-331/D-336):** `reconcile_test.exs` passes — no unit
  in zero or two terminal sets; tree ≡ tracker; every escalation recorded+delivered.
- **AC-11 (meta):** the gating tests above run in CI as a blocking job.
  *(meta — verified by CI wiring; exempt from the unit-test-linkage check.)*
- **AC-12 (PR-CORE-6, end-to-end / substance):** the control core drives one real
  PR on the self-hosting Elixir toolchain from an open issue to a gate-passed,
  merged result with `main` health-checked, **no human in the loop**. Signal: the
  exact command + the observable merged commit + the green health check (the
  dogfood proof; arch `06-roadmap/spec-factory.md` AC-10). *This AC depends on
  SPEC-FACTORY-{GATE,FLEET,MERGE} landing; it is the integration gate, not a
  CORE-only unit.*

## Appendix B — Source map

Files that bring a PR into scope of this SPEC (`D-NNN`/`C-N` → file:symbol):

- `lib/tau/factory/ledger/writer.ex` (C1; D-315, D-330–D-333, D-335, D-336) — PR-CORE-1/5
- `lib/tau/factory/ledger/schema/*.ex` + `lib/tau/factory/ledger/migrations.ex` (Exqlite schema; D-335 partial unique index) — PR-CORE-1/5
- `lib/tau/factory/budget/owner.ex` (C2; D-320, D-332) — PR-CORE-2
- `lib/tau/factory/coordinator.ex` (C3; D-317, D-321, D-342, D-344) — PR-CORE-3/4
- `lib/tau/factory/escalation.ex` (C7; D-317) — PR-CORE-3
- `lib/tau/factory/scheduler.ex` (C4; D-312, D-320, D-343) — PR-CORE-2
- `lib/tau/factory/conflict_check.ex` (C5; D-312, D-343) — PR-CORE-2
- `lib/tau/factory/unit.ex` (C6; D-318, D-340, plus B6/B7/B8 cited edges) — PR-CORE-3
- `lib/tau/factory/retry.ex` (C8; D-318) — PR-CORE-3
- `lib/tau/factory/kill_switch.ex` (C9; D-321) — PR-CORE-4
- `lib/tau/factory/supervisor.ex` + `lib/tau/application.ex` (tree; rest_for_one spine) — PR-CORE-1
- `test/tau/factory/ledger_durability_test.exs` (D-315) — PR-CORE-1
- `test/tau/factory/conflict_check_property_test.exs` (D-312, D-343) — PR-CORE-2
- `test/tau/factory/budget_admission_test.exs` (D-320, D-332) — PR-CORE-2
- `test/tau/factory/retry_property_test.exs` (D-318) — PR-CORE-3
- `test/tau/factory/escalation_property_test.exs` + `unit_timeout_test.exs` (D-317) — PR-CORE-3
- `test/tau/factory/kill_switch_test.exs` (D-321) — PR-CORE-4
- `test/tau/factory/coordinator_recovery_test.exs` (D-344) — PR-CORE-4
- `test/tau/factory/verdict_append_only_test.exs` (D-335) — PR-CORE-5
- `test/tau/factory/cost_attribution_test.exs` (D-333) — PR-CORE-5
- `test/tau/factory/reconcile_test.exs` (D-330, D-331, D-336; audits D-334 disposition) — PR-CORE-5
- `test/tau/factory/unit_termination_test.exs` (D-340) + `scope_amendment_test.exs` (D-343) — PR-CORE-3/2

**Cross-SPEC boundaries (cited, not owned here):** B6 → `SPEC-FACTORY-MERGE`
(D-300–D-303, D-341); B7 → `SPEC-FACTORY-GATE` (D-304–D-308, D-322, D-323);
B8 → `SPEC-FACTORY-FLEET` (D-309–D-311, D-313, D-314, D-316); `E-DESTRUCTIVE` →
`SPEC-FACTORY-GOV` (D-319).

**Catalog registration required before first implementation PR:** add
`SPEC-FACTORY-CORE` to `.claude/rules/spec-before-code.md` (catalog) and the
`D-NNN` block table in `docs/MISSION.md` (D-312, D-315, D-317, D-318, D-320,
D-321, D-330–D-333, D-335, D-336, D-340, D-342–D-344 → this SPEC).
