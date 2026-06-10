# Software architecture — resource governance, policy, observability & control

This layer-04 file details the **governance** column of the supervision tree
(`supervision-tree.md`): the `Egress.Supervisor` (`Provider.RateLimiter` +
`CircuitBreaker.Store`), `Policy.Owner`, the budget pre-check seam into
`Ledger.Supervisor`/`Budget.Owner` (owned by `durable-spine.md`), the action
classifier, the telemetry/OTel observability spine, the kill switch as a
`Coordinator` between-unit check, and the reporting cadence. It is the concrete
Elixir/OTP mapping of the **Policy data plane (Π)** and the **egress chain** from
`../03-system-architecture/system-architecture.md`, and of HR-8 (engine-clamp).

It enforces, structurally (no prose-only MUSTs — INV-24 floor): **INV-20** (no
unilateral destruction), **INV-21** (budget ceiling), **INV-22** (clean kill),
**INV-24** (OTP non-negotiables); **CON-3** (budget conservation), **CON-4**
(cost attribution), **CON-7** (escalation conservation); **NFR-EGRESS**,
**NFR-BUDGET-PRECISION**, **NFR-OBS-COVERAGE=100%**, **NFR-AUDIT=100%**;
**FR-7.x**, **FR-9.x**, **FR-5.3**, **HR-8**.

Sibling files: `supervision-tree.md` (the tree), `durable-spine.md` (L: Ledger,
Budget.Owner, lineage records, Oban spine), `control-plane.md` (K/S/U: the
Coordinator FSM, Scheduler, conflict check, escalation set E),
`gate-and-toolchain.md` (G: gate manifest, mechanical gates). HR/INV/CON/NFR IDs
are defined in `../02-requirements/` and `../03-system-architecture/`.

Idioms used throughout: **ETS-under-owner** (reads bypass the mailbox), **paired
`[:tau,…]` telemetry** (`:telemetry.span/3`), **clamp logic as pure functions**
(properties before examples — INV-24 #6), **behaviours for seams** (INV-24 #2).

---

## 1. LLM egress overload control (NFR-EGRESS, FR-7.2)

Many concurrent agents → many concurrent provider calls → three *distinct*
overload risks, each with its own primitive, composed in a **load-bearing order**
(research OTP §5; already the live boot order). The order is not arbitrary: the
cheapest, most-local rejection runs first, the global accounting last.

```
RateLimiter  →  CircuitBreaker  →  Budget ledger        (admission order)
(per-provider   (per-provider       (global cost
 token bucket)   :closed/:open       runaway)
                 /:half_open FSM)
   429s            5xx storms          cost overrun
```

### The call path of one outbound provider request

`Tau.Factory.Egress.call/3` is the single chokepoint; **no provider call may
bypass it** (INV-24 #4 — cross-process discipline; the chokepoint is the only
caller of the provider adapter's `stream/3`). Each layer is a *fail-closed*
guard returning a tagged tuple, never raising across the boundary (INV-24 #7):

```
Egress.call(provider, req, ctx)
  │
  1. RateLimiter.acquire(provider)         # token-bucket checkout = back-pressure
  │     ├─ token available → proceed
  │     └─ bucket empty   → BLOCK (the *agent* waits; provider never sees a 429)
  │                          └ if wait > deadline → {:error, :rate_limited}
  │
  2. CircuitBreaker.check(provider)         # ETS read, NO GenServer.call (hot path)
  │     ├─ :closed     → proceed
  │     ├─ :open       → {:error, :circuit_open}        # short-circuit, no call made
  │     └─ :half_open  → admit ONE probe; others get {:error, :circuit_open}
  │
  3. Budget.admit(owner, est_cost)          # ETS snapshot read (durable-spine.md)
  │     ├─ spent + est_cost ≤ budget → DEBIT (reserve) → proceed
  │     └─ else                       → {:error, :budget_exhausted} → E-BUDGET
  │
  4. Finch pool checkout                     # bounded pool; checkout = back-pressure
  │     └─ provider adapter stream/3 ...
  │
  5. on result: CircuitBreaker.record(provider, :ok | :error)   # ETS CAS write
  │             Budget.reconcile(owner, actual_cost)            # true-up reserve→actual
  │             Cost.attribute(owner, model, role, actual)      # CON-4 (cost/tracker)
  └─ emit [:tau, :factory, :egress, :call] span at every layer (NFR-OBS-COVERAGE)
```

**What each layer rejects:**

| Layer | Rejects | Verdict | Why this layer / not another |
|---|---|---|---|
| RateLimiter | a call that would breach the provider's req/s | block then `:rate_limited` | the agent *waits* — provider never emits the 429 the limiter exists to avoid (NFR-EGRESS: 0 sustained 429s) |
| CircuitBreaker | a call to a provider mid-5xx-storm | `:circuit_open` (no call made) | stops the fail→retry→burn-quota feedback loop; cost governance, not just latency |
| Budget | a call that would push spend past the ceiling | `:budget_exhausted` → E-BUDGET | per-provider breakers cannot see *aggregate* cost; only the ledger does (CON-3) |
| Finch pool | a call with no free connection | block (checkout) | the pool checkout *is* the lowest back-pressure layer |

**Pool checkout as back-pressure (FR-7.3).** Each guard that *blocks* (rate
limiter, Finch pool) propagates back-pressure **up to the calling agent**, which
waits rather than the system spawning unboundedly or the provider rejecting. This
is the same pattern `supervision-tree.md` §5 lists: *the checkout is the
back-pressure*. No `try/rescue` wraps the stream — the breaker is the 5xx handler
(INV-24 #7).

### Reuse (no new code where the subsystem exists)

- `Provider.RateLimiter` — reuse `lib/tau/providers/rate_limiter/` verbatim
  (token-bucket + supervisor, ADR-0011). Booted as `Egress.Supervisor`'s first
  child (it must exist before the breaker; `one_for_one` since the two are
  independent — `supervision-tree.md` §3).
- `CircuitBreaker` — reuse `lib/tau/circuit_breaker/` whole: the pure
  `CircuitBreaker.State` FSM (`:closed/:open/:half_open`, property-tested) + the
  `CircuitBreaker.Store` ETS owner (`:tau_circuit_breakers`, `read_concurrency`)
  + the `CircuitBreaker` façade, per SPEC-CIRCUIT-BREAKER (D-029,D-030,D-043,
  D-044). **The FSM is pure; the process is the Store** — reads (step 2) bypass
  the owner mailbox; writes (step 5) are ETS-CAS guarded with a consistent
  `now_ms` (the `opened_at_ms`/`now_ms` temporal coupling is load-bearing).
- `Budget` admission/debit lives in `Budget.Owner` (durable-spine.md); Egress
  only *reads the snapshot and reserves*. `cost/tracker.ex` does CON-4
  attribution.

---

## 2. Budget governance (INV-21, CON-3, NFR-BUDGET-PRECISION)

**Admission pre-check.** Every billable action pre-checks the **budget ETS
snapshot** (owned by `Budget.Owner`, `read_concurrency` table; truth in SQLite,
snapshot rebuilt in `init/1` — `durable-spine.md`, Step-2 durability partition)
*before* the action runs (step 3 above). The read bypasses the owner mailbox;
the *reserve* (`update_counter` reserve, trued-up on completion) is the only
serialized write.

**Overrun bound (NFR-BUDGET-PRECISION).** Admission is checked *pre-action* and
debits a reservation, so spend exceeds budget by **≤ one in-flight action's
cost** — the action already admitted when the ceiling was crossed. There is no
mid-action ceiling check (an action is atomic w.r.t. the budget). Exhaustion →
`{:error, :budget_exhausted}` → the Coordinator raises **E-BUDGET** (global halt;
`liveness.md`), in-flight units run to a clean checkpoint (FC-6).

**Four budgets, one ledger (FR-7.1).** `token`, `cost`, `wall_time`, `iteration`
are four counters in the same single-owner durable ledger (CON-3:
`spent + remaining = total`, single writer-of-record). `Budget.admit/2` checks
the relevant counter(s) for the action class; any breach denies.

**Cost attribution (CON-4, reuse `cost/tracker.ex`).** Every debit is attributed
to **exactly one owner** — `{factory_step, agent, gate_run}` — tagged by **model
and role** (D-038 adapter-tagged line items). `Σ_owners attributed(o) =
total_spent` is the CON-4 balance; a reconciliation pass each cycle audits it
(`durable-spine.md`).

**Model selection per role is policy, not code (FR-7.4).** The model used by each
role (cheaper for mechanical roles, stronger for adjudication) is a field in
`Tau.Factory.Policy` (§3), pinned per unit at admission, and cost is attributed
per the resolved `(model, role)`. No role's model is hardcoded.

---

## 3. Policy plane — `Tau.Factory.Policy` (HR-8)

Policy is **versioned data interpreted by a stable engine** (INV-24 #2: data, not
a code seam). The process is `Policy.Owner` (a boring ETS owner high in the spine,
`supervision-tree.md`); the *logic* is pure functions in `Tau.Factory.Policy`
(properties before examples — INV-24 #6). Reads hit the **policy ETS snapshot**
directly (no owner bottleneck).

### Versioned fields

```
%Policy{
  version:             v,                       # monotone; pinned per unit
  model_per_role:      %{role => model},        # FR-7.4
  retry_bound_n:       N,                        # refine bound (clamped, below)
  budget:              %{token:, cost:, wall_time:, iteration:},  # INV-21 params
  priority_order:      [...],                    # work selection
  conflict_predicate:  pred,                     # may only TIGHTEN the engine floor
  gate_manifest:       [mutation, critic, reviewer, ...],  # IN the pin set
  escalation_thresholds: %{upheld_challenges: 2, ...}      # E-CHALLENGE etc.
}
```

### Pin-per-unit (the volatility-split payoff)

A unit's policy version is **pinned at admission** (Scheduler, `control-plane.md`)
and frozen for the unit's life (FR-1.3 frozen scope). A mid-flight policy change
bumps `version` and touches **only units admitted after it** — in-flight units
keep their pin. This is the stable/volatile split: the engine is stable, the
policy volatile, and the pin keeps a volatile change from perturbing live work.
**The gate manifest is *in* the pin set** — a unit is gated by exactly the
manifest pinned at its admission, so a manifest edit cannot retroactively weaken
or alter an in-flight unit's gate.

### Engine-clamp (the pure function — HR-8)

No safety invariant's **enforcement** lives in policy; only its **parameters**,
and only where the invariant holds for **all** admissible parameter values. The
clamp is the pure function that makes this true by construction — it runs at
admission, rejecting or tightening any policy value that could weaken a floor:

```elixir
@hard_ceiling_n 3
@gate_floor MapSet.new([:mutation, :critic, :reviewer])

# Pure. Property-tested: ∀ admissible p, clamp(p) preserves every floor.
@spec clamp(Policy.t()) :: {:ok, Policy.t()} | {:error, term()}
def clamp(%Policy{} = p) do
  with :ok <- reject_infinite_budget(p.budget),          # ∞ sentinel REJECTED
       {:ok, manifest} <- enforce_gate_floor(p.gate_manifest),
       {:ok, pred} <- floor_conflict_predicate(p.conflict_predicate) do
    {:ok, %{p |
      retry_bound_n:     min(p.retry_bound_n, @hard_ceiling_n),  # N = min(policy, ceiling)
      gate_manifest:     manifest,        # floor halves cannot be removed
      conflict_predicate: pred            # plugins may only TIGHTEN
    }}
  end
end

# {mutation, critic, reviewer} are non-shrinkable; a manifest may ADD halves, never drop a floor half.
defp enforce_gate_floor(manifest) do
  m = MapSet.new(manifest)
  if MapSet.subset?(@gate_floor, m), do: {:ok, manifest}, else: {:error, {:gate_floor_violation, MapSet.difference(@gate_floor, m)}}
end

# An infinite-budget sentinel (:infinity / nil / <=0) defeats INV-21 → REJECT, not clamp.
defp reject_infinite_budget(b) do
  if Enum.all?([b.token, b.cost, b.wall_time, b.iteration], &(is_integer(&1) and &1 > 0)),
    do: :ok, else: {:error, :infinite_budget_rejected}
end

# Engine supplies a file+codepoint disjointness FLOOR for the 5-clause conflict check (INV-13);
# a policy predicate is composed as (engine_floor AND policy_pred) — it can only narrow the admissible set.
defp floor_conflict_predicate(policy_pred),
  do: {:ok, &(ConflictCheck.engine_floor(&1, &2) and policy_pred.(&1, &2))}
```

**The rule, stated:** the clamp guarantees that for every policy value the engine
accepts, the safety invariant it parameterises (INV-1 via the gate floor, INV-19
via `N`, INV-21 via finite budgets, INV-13 via the disjointness floor) still
holds. A value that could falsify the invariant is **rejected** (∞ budget) or
**clamped** (`N`, gate halves, predicate), never admitted. Enforcement stays in
the engine (G's gate run, U's retry ladder, S's conflict check); policy supplies
only parameters within a safe envelope.

---

## 4. Action classification (INV-20, FR-5.3)

A destructive/irreversible action is **denied at the action boundary**,
structurally — not by an agent choosing to obey. The classifier is a pure
function over a **data** whitelist/denylist (INV-24 #2: pattern-match on
atoms/structs, no string-keyed dispatch):

```elixir
@destructive MapSet.new([
  :force_push, :history_rewrite, :release, :external_publish, :data_migration
])

@spec classify(action :: Action.t()) :: :allow | {:deny, :destructive}
def classify(%Action{kind: k}) when k in @destructive, do: {:deny, :destructive}
def classify(%Action{}), do: :allow
```

The deny is **structural**: the `MergeAuthority` (M) and any effecting path call
`classify/1` before executing; a `{:deny, :destructive}` routes to the
Coordinator as **E-DESTRUCTIVE** (per-action escalation; `liveness.md`) and the
action **never auto-executes** (INV-20 `□(destructive(a) → escalate ∧
¬auto_execute)`; FC-7). `M` therefore never force-pushes autonomously — the
classifier sits in front of every `git push` it issues. The denylist is data, so
a new destructive class is one MapSet entry, not a code path.

---

## 5. Observability (NFR-OBS-COVERAGE=100%, FR-9.1) & audit (NFR-AUDIT=100%)

### Telemetry coverage

Every user-visible or perf-sensitive event emits a **paired** `[:tau, :factory,
…]` span via `:telemetry.span/3` (`*.start` / `*.stop` / `*.exception` — INV-24
#5; unpaired starts leak open spans on crash). The namespace extends the live
`[:tau, …]` (research §9). Covered events (non-exhaustive, ≥1 per user-visible
transition for 100% coverage):

| Span | Emitted by | Measurements |
|---|---|---|
| `[:tau,:factory,:unit,*]` | U FSM | attempt count, duration_ms |
| `[:tau,:factory,:gate,:half,*]` | G | half name, verdict, duration_ms |
| `[:tau,:factory,:merge,*]` | M | batch size, main_health, duration_ms |
| `[:tau,:factory,:worker,*]` | W | role, captured-dirty, reclaim |
| `[:tau,:factory,:egress,:call]` | Egress | provider, layer-rejection, tokens, cost |
| `[:tau,:factory,:budget,:debit]` | Budget.Owner | owner, model, role, amount |
| `[:tau,:factory,:escalation]` | K | reason ∈ E, state snapshot |

Handlers are **observers, never control** (a handler crash must not affect a
decision; research §9). The **supervised OTel reporter** — reuse
`lib/tau/otel_reporter/` (SPEC-OTEL-REPORTER, D-050..D-055) — subscribes to
`[:tau,…]` and exports spans/metrics via OTLP. It is a GenServer high in the
tree; its crash never blocks the factory.

### Decision traceability (NFR-AUDIT=100%) — the lineage record

Every merge is traceable, with **no missing link**, along:

```
main-commit → gate-verdicts → gating-test-paths → AC/D-NNN → SPEC → issue
```

This is made queryable by **lineage records** in the durable store (coupled to
`durable-spine.md`'s L; the record IS the audit log, FR-5.2). The
writer-of-record is L; the shape:

```
%Lineage{
  main_commit:       sha,                 # the landed commit (M is sole writer)
  unit_id:           u,
  gate_verdicts:     [%{half:, verdict:, diff_hash:}],   # CON-6: ∀ required half a fresh verdict
  gating_test_paths: [...],               # the frozen oracle boundary (INV-5/6)
  claims:            [AC-N | D-NNN, ...],  # from the draft-PR ## Acceptance criteria
  specs:             [SPEC-*, ...],        # INV-23 membership
  issues:            [#N, ...]            # FR-1.1 intent authority
}
```

Each link is a foreign-key edge in L, so `100%` traceability is a **join, not a
grep**: a merge with any null edge is a CON-6 / NFR-AUDIT violation surfaced by
the per-cycle reconciliation pass (`durable-spine.md`). The lineage is written in
the same transaction as the merge record (WAL before the merge ack — INV-16,
RPO=0), so an audit can never observe a merge without its lineage.

---

## 6. Kill switch (INV-22, FR-9.3) as a supervised mechanism

The kill switch is **not** a start-of-step file read (the current attempt's
prose-enforced sentinel; research GAP-2). It is a **between-unit check the
`Coordinator` gen_statem consults** as a guard on its `select_next` transition:

```
Coordinator (gen_statem):  running --[unit_terminal]--> running   (if ¬kill)
                           running --[unit_terminal]--> halting    (if kill)
                           halting --[in_flight drained]--> halted  (main synced)
```

- **Operator control state separate from project state.** The kill signal lives
  in operator state (an ETS flag under a control owner, or a durable
  `control` row), **never** in the project's git/solution tree. (The current
  `.claude/STOP-FACTORY` sentinel is gitignored *precisely* to keep these
  separate; here it becomes durable operator state read by the FSM, not a file
  the agent must remember to check.)
- **Checked at unit boundaries → bounded latency ≤ 1 atomic unit**
  (NFR-KILL-LATENCY). Setting the flag mid-unit does not interrupt the unit; the
  unit runs to its clean checkpoint, then the FSM transitions to `halting`.
- **Clean halt: `main` synced, never mid-merge** (INV-22 `□(kill ↝
  halt_between_units ∧ main_synced ∧ ¬mid_merge)`). Because M is concurrency-1 and
  the FSM checks the flag *between* units, a kill can never land inside M's
  critical section. `halting` waits for in-flight units to drain to terminal
  states, confirms `main = origin/main`, then `halted`.

The halt itself is an escalation-class event recorded in L (CON-7) and reported
(FR-9.2). This makes INV-22 a structural property of the FSM's transition guard,
not a rule an agent obeys.

---

## 7. Reporting cadence (FR-9.2, D-S1)

Under **D-S1 (escalation-only autonomy)** there are **no per-step human
checkpoints**. The reporter (a telemetry handler / Coordinator output) emits to
the operator **only**:

- **Milestone boundary** — the assigned milestone's open-issue count reaches 0
  (the completion signal; `control-plane.md`). The loop reports and awaits the
  next assignment; it does not auto-advance.
- **Escalation** — any `e ∈ E` fires (E-BUDGET, E-DESTRUCTIVE, E-RED-MAIN,
  E-CHALLENGE, E-AMBIGUITY, E-UNCLASSIFIED; `liveness.md`). CON-7: every raised
  escalation is delivered *and* recorded with reason + state snapshot.

**Numbers cited from their source, never estimated (substance-over-ceremony,
research INV-F9).** Token counts come from the telemetry measurement
(`total_tokens`), wall-times from `duration_ms` — both *measured*, sourced from
the span that recorded them (§5), not rounded or guessed. **"Works" is not a
valid claim**: a report asserting a unit functions MUST carry the exact command
and the observable signal against the user-facing path (FR-1.4, INV-8). The
reporter has no path to emit an unsourced number — measurements flow from
telemetry, which is the only number source.

---

## 8. Migration seam — directly-reusable current subsystems

Each current subsystem slots into the governance layer with minimal change; the
governance code is mostly *composition* of these, not new mechanism (research §4
reuse candidates; `tau-current-analysis.md`).

| Current subsystem (`lib/tau/…`) | Slots in as | Change required |
|---|---|---|
| `circuit_breaker/` (State FSM + Store ETS owner + façade) | Egress layer 2 (§1); SPEC-CIRCUIT-BREAKER D-029/030/043/044 | **None** — `Egress.call` calls the existing façade; Store moves under `Egress.Supervisor` |
| `providers/rate_limiter/` (token-bucket + supervisor, ADR-0011) | Egress layer 1 (§1) | **None** — first child of `Egress.Supervisor` |
| `cost/tracker.ex` (+ `cost.ex`, D-038 adapter-tagged) | CON-4 cost attribution per `(model, role)` (§2) | thin — attribute to the factory owner `{step,agent,gate_run}` not just turn |
| `otel_reporter/` (OTLP exporter, SPEC-OTEL-REPORTER D-050..055) | the observability reporter (§5) | subscribe the new `[:tau,:factory,…]` namespace |
| `settings/{loader,cache,schema,vault,watcher}` (property-tested merge; live-reload) | `Policy.Owner` source + secrets for provider creds | `loader`+`schema` define the `%Policy{}` shape; `cache` (persistent_term) backs the policy snapshot; `vault` holds provider keys; `watcher` triggers a `version`-bumping reload (which, by pin-per-unit §3, touches only new units) |
| `telemetry/` (handlers + supervisor) | the `[:tau,:factory,…]` span substrate (§5) | extend the namespace; reuse the supervisor |
| `memory/` (SQLite store, FTS5/vec) | (adjacent) the durable solution tree / lineage store backing | owned by `durable-spine.md`; lineage records (§5) are rows here |

The governance layer adds, net-new: `Tau.Factory.Egress` (the chokepoint
composing the three reused guards), `Tau.Factory.Policy` (clamp + pin, pure),
`Tau.Factory.ActionClassifier` (pure denylist), the lineage schema, and the
Coordinator's kill-flag guard — each thin, each composing or guarding an existing
property-tested subsystem rather than reimplementing one.

---

## Cross-reference index

| This file enforces | Owned/detailed in |
|---|---|
| Egress chain order, the three guards | here §1; reuses SPEC-CIRCUIT-BREAKER |
| Budget ledger, snapshot, reconciliation | here §2 (admission); `durable-spine.md` (Budget.Owner, ledger truth) |
| Policy fields, pin, clamp (HR-8) | here §3; `control-plane.md` (Scheduler pins at admission) |
| Action classifier (INV-20) | here §4; `control-plane.md` (E-DESTRUCTIVE routing) |
| Telemetry coverage, OTel, lineage (NFR-OBS/AUDIT) | here §5; `durable-spine.md` (L is lineage writer-of-record) |
| Kill switch (INV-22) | here §6; `control-plane.md` (Coordinator FSM) |
| Reporting cadence (FR-9.2) | here §7; `control-plane.md` (escalation set E) |
| Supervision placement of all the above | `supervision-tree.md` §3 |
