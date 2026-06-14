# SPEC: Factory Governance (egress chain · policy/engine-clamp · action classifier · observability/audit)

| | |
|---|---|
| **Status** | Draft |
| **Date** | 2026-06-10 |
| **Scope** | The `:tau_factory` **governance plane (Γ)**: the `Tau.Factory.Egress` chokepoint composing the load-bearing `RateLimiter → CircuitBreaker → Budget` chain; the `Tau.Factory.Policy` plane (versioned data + `Policy.Owner` ETS snapshot + the pure engine-`clamp/1`, HR-8); the pure `Tau.Factory.ActionClassifier` denylist; and the observability/audit spine (paired `[:tau,:factory,…]` telemetry, the supervised OTel reporter, the queryable lineage record). Owns the no-unilateral-destruction, composed-egress, full-telemetry-coverage, and full-audit-traceability contracts. |
| **Method** | PSDH (`.claude/skills/design-reasoning`); L0 + boundary contracts. Derived from the verified architecture in `docs/arch/` (software-architecture §governance.md; system-architecture §Policy/egress; invariants INV-20/21/24; nfrs NFR-EGRESS/OBS/AUDIT/BUDGET-PRECISION; synthesis HR-8; traceability D-319/D-351–D-353). |
| **Issue** | TBD — file before the first implementation PR (`tau-github-workflow`); reference as `Closes #N`. |

**Changelog:** Initial draft — §0–§7 + Appendix B. Introduces D-319, D-351,
D-352, D-353. Cites (does not own) D-320/D-321 (budget ceiling / clean kill —
SPEC-FACTORY-CORE), D-300/D-306/D-312/D-318/D-354 (gate-floor, mutation,
conflict-gate, retry bound, game-resistance — SPEC-FACTORY-{MERGE,GATE,CORE}),
all of which the engine-clamp *protects* but none of which it owns. Reuses
SPEC-CIRCUIT-BREAKER (D-029/D-030/D-043/D-044), ADR-0011 rate limiter,
SPEC-OTEL-REPORTER (D-050..D-055), and SPEC-FACTORY-CORE's Ledger (L) as
lineage writer-of-record.

## 0. Why this spec exists

The factory runs many concurrent agents, each issuing outbound provider calls
and each capable of requesting an irreversible action (a force-push, a release).
The prior attempt governed both by **prose an agent was asked to obey** (arch
`tau-current-analysis.md` GAP-2): "don't force-push", "respect the budget",
"check the kill file" — rules with no structural enforcement, every one observed
to fail. Three governance functions were therefore unenforced: nothing stopped a
5xx storm from burning quota in a fail→retry loop, nothing stopped aggregate
spend from blowing past a ceiling no single provider breaker could see, and
nothing stopped an agent from executing a destructive action it had been *told*
not to.

This spec makes governance **structural, not prose**. Every outbound call passes
through one chokepoint (`Tau.Factory.Egress`) that composes three fail-closed
guards in a load-bearing order; every billable action pre-checks an aggregate
budget; every destructive action is denied at the action boundary by a pure
classifier; and every governed value an operator might tune is **versioned
policy data clamped by a pure engine function** so that no safety invariant's
*enforcement* can ever move into policy — only its *parameters*, and only inside
a safe envelope. Observability is 100% paired telemetry; audit is a 100%
traceable lineage join, not a grep.

The governance plane is coordination-heavy (triage 4/5; §1) and therefore
requires this spec before any implementation PR modifies its boundary, per
`.claude/rules/spec-before-code.md`.

## 1. Triage

| # | Property | Score | Evidence |
|---|----------|-------|----------|
| 1 | Shared mutable state | 1 | The circuit-breaker ETS table, the budget ETS snapshot, and the policy ETS snapshot are each read by every concurrent agent's egress call and written on outcomes/version bumps — concurrently consulted, owner-held. |
| 2 | Temporal coupling | 1 | The egress chain is strictly ordered (rate-limit → breaker → budget → call → record); a policy version is pinned *at admission* and frozen for the unit's life; the breaker's `opened_at_ms`/`now_ms` coupling is load-bearing. |
| 3 | Cross-process coordination | 1 | `Egress` (chokepoint) + `RateLimiter` (per-provider) + `CircuitBreaker.Store` (ETS owner) + `Budget.Owner` (ETS owner) + `Policy.Owner` (ETS owner) + the OTel reporter — coordination spans many owners with no shared mailbox; reads bypass mailboxes. |
| 4 | Feedback loops | 1 | Provider 5xx → breaker opens → egress short-circuits → fewer calls → cooldown probe → close; spend → admission denial → E-BUDGET. The plane's own behaviour feeds back into admission. |
| 5 | State accumulation | 0 | Governance state is mostly bounded/snapshot-derived (breaker counters reset on transition; budget truth lives in L; policy is pinned, not accumulated). The accumulation that matters (budget spend) is owned by SPEC-FACTORY-CORE's Ledger. |

**Triage score: 4/5. L0 + boundary contracts indicated.**

## 2. Component decomposition

Naming is precise so §4 contracts attach to specific operations. All modules are
under `Tau.Factory.*`, supervised by `Egress.Supervisor` / `Policy.Owner` under
`Tau.Factory.Supervisor` (arch `supervision-tree.md` §3). The plane is mostly
**composition of reused, property-tested subsystems** (§Appendix B reuse map),
not new mechanism.

| # | Component | Role |
|---|-----------|------|
| C1 | `Tau.Factory.Egress` | **Γ.** The single outbound chokepoint. `call/3` composes the three fail-closed guards in load-bearing order, makes the provider call, then records outcome + cost + telemetry. **No provider call may bypass it.** Net-new (thin composition). |
| C2 | `Tau.Providers.RateLimiter` | **Egress layer 1 (lift).** Per-provider token-bucket + supervisor (ADR-0011). Reused verbatim from `lib/tau/providers/rate_limiter/`; first child of `Egress.Supervisor`. Bucket-empty = back-pressure (the *agent* waits). |
| C3 | `Tau.CircuitBreaker` (+ `.State`, `.Store`) | **Egress layer 2 (lift).** Reused whole from `lib/tau/circuit_breaker/` per SPEC-CIRCUIT-BREAKER: pure `:closed/:open/:half_open` FSM + the `:tau_circuit_breakers` ETS owner + façade. `Store` moves under `Egress.Supervisor`. Reads (check) bypass the owner mailbox; writes (record) are ETS-CAS. |
| C4 | `Tau.Factory.Budget.Owner` | **Egress layer 3 (cited, lift).** ETS budget-snapshot owner; **owned by SPEC-FACTORY-CORE** (D-320). Egress only *reads the snapshot and reserves*; truth is in L. |
| C5 | `Tau.Factory.Policy` | **Π logic.** Pure functions over `%Policy{}`: the engine-`clamp/1` (HR-8) and field resolution. Properties before examples. No process. |
| C6 | `Tau.Factory.Policy.Owner` | **Π process.** Boring ETS-snapshot owner high in the spine; holds the pinned `%Policy{}` versions; reads hit the ETS snapshot directly. Source is `settings/{loader,schema,cache}` (lift). |
| C7 | `Tau.Factory.ActionClassifier` | Pure `classify/1 :: Action.t() → :allow \| {:deny, :destructive}` over a **data** denylist (MapSet of atoms). No process. Properties before examples. |
| C8 | `Tau.Factory.Cost.Tracker` | **Cost attribution (lift).** Reused from `lib/tau/cost/tracker.ex` (D-038 adapter-tagged); attributes each debit to one factory owner `{step, agent, gate_run}` tagged by `(model, role)` (CON-4). |
| C9 | `Tau.OtelReporter` | **Observability reporter (lift).** Reused from `lib/tau/otel_reporter/` (SPEC-OTEL-REPORTER); subscribes the new `[:tau,:factory,…]` namespace, exports OTLP. Supervised high in the tree; its crash never blocks a decision. |
| C10 | `%Lineage{}` record | The queryable audit record (commit→verdict→paths→AC/D-NNN→SPEC→issue). **Co-owned with L (SPEC-FACTORY-CORE):** L is the writer-of-record; this SPEC owns the record *shape* and the join contract (D-353). |

Boundaries (B-N attach contracts in §4):

| # | Boundary | Operation |
|---|----------|-----------|
| B1 | agent/U ↔ C1 Egress | `call(provider, req, ctx)` → `{:ok, stream} \| {:error, reason}` (the chokepoint; reason ∈ `:rate_limited \| :circuit_open \| :budget_exhausted`). |
| B2 | C1 Egress ↔ C2 RateLimiter | `acquire(provider)` → token | block-then-`:rate_limited` (back-pressure). |
| B3 | C1 Egress ↔ C3 CircuitBreaker | `check(provider)` (ETS read, no `call`) / `record(provider, :ok\|:error)` (ETS CAS). |
| B4 | C1 Egress ↔ C4 Budget.Owner | `admit(owner, est_cost)` reserve / `reconcile(owner, actual)` — *cited, SPEC-FACTORY-CORE D-320*. |
| B5 | C1 Egress ↔ C8 Cost.Tracker | `attribute(owner, model, role, actual)` (CON-4). |
| B6 | C6 Policy.Owner ↔ C5 Policy | `clamp/1` at admission (pure); `pin/2` freezes a version per unit; `resolve/2` reads the pinned snapshot. |
| B7 | {M, any effecting path} ↔ C7 ActionClassifier | `classify(action)` → `:allow \| {:deny, :destructive}` before any side-effecting execution. |
| B8 | C7 ActionClassifier ↔ K (Coordinator) | `{:deny, :destructive}` routes to K as **E-DESTRUCTIVE** (per-action escalation). *Cited escalation set E (SPEC-FACTORY-CORE).* |
| B9 | all governed components ↔ C9 OtelReporter | paired `[:tau,:factory,…]` spans over `:telemetry`; handler is an observer, never control. |
| B10 | C10 Lineage ↔ L (Ledger.Writer) | the lineage row is written in the **same transaction as the merge record** (WAL-before-ack); audit is a join over its FK edges. *L is writer-of-record (cited, SPEC-FACTORY-CORE).* |

## 3. L0 constraints (includes D-374 amendment — PR #510)

### Amendment: metered-API spend is a fail-closed admission boundary (D-374)

Metered Anthropic-API spend (a charge against a raw `ANTHROPIC_API_KEY`) is
an **irreversible resource action** with no in-band undo — it is structurally
the same class of destructive action that `ActionClassifier` (C7) guards at
the effecting path. Absent a structural guard, any `Port.open` of a
`:claude_code` worker could silently consume metered quota even when the
factory is intended to operate exclusively on the user's Claude
Pro/Max subscription.

The governance plane therefore adds a fail-closed preflight at the single
`Worker.open_port_and_finish/1` funnel (the only `Port.open` site in the
factory worker path):

- **Worker spawn boundary contract** (added at PR #510):
  - `agent_mode` opt on `WorkerSupervisor.spawn/5` → threaded to
    `Worker`. `:claude_code` = metered-capable (D-374 preflight fires).
    Absence or any other value → no preflight (test/legacy paths
    unchanged).
  - `creds_check_fun` opt on `WorkerSupervisor.spawn/5` → `Worker`.
    Type `(-> :ok | {:error, :subscription_creds_absent})`. Default
    wraps `Tau.Providers.Anthropic.Auth.resolve/1` against
    `~/.claude/.credentials.json`. Tests inject a stub.
  - Preflight fires **after** the death-monitor is spawned (so a
    `:metered_path_refused` stop is observable via the death-cert) and
    **before** `Port.open` (so no metered call can escape).
  - On `{:error, _}` from `creds_check_fun.()`: do NOT open the Port;
    stop with reason `:metered_path_refused` (fail-closed; NO fallback).
    The death-cert monitor maps this to
    `{:worker_exit, worker_id, :metered_path_refused}`.
  - Env scrub: append `{~c"ANTHROPIC_API_KEY", false}` to the Port's
    `{:env, list}` when `agent_mode == :claude_code`. Erlang Port treats
    `{key, false}` as "remove from child env" (POSIX unsetenv). This
    ensures the child never inherits a metered key even if one is set in
    the calling process env.

**[C223-B1 addition]** A metered-capable worker spawn MUST pass the D-374
preflight at the `Worker.open_port_and_finish/1` funnel before `Port.open`.
Fail-closed: a false negative (creds absent, Port opens anyway) is a
metered-spend violation; a false positive (creds present, Port refused)
surfaces as `:metered_path_refused` and the unit retries. The preflight
is structurally identical to the `ActionClassifier` deny: it runs at the
admission boundary, not after execution.



Format: `[Cn-Bm]` = constraint number + boundary. **★** marks non-obvious.

### Q1: What can be written by more than one actor?

- **★ [C200-B3]** The circuit-breaker ETS row for a provider is written by **N
  concurrent egress calls** recording outcomes. There is **no `Egress`-level
  serialization** — the writes go through `CircuitBreaker.Store`'s ETS-CAS path
  (SPEC-CIRCUIT-BREAKER C56/C57). Egress MUST NOT wrap the breaker in its own
  GenServer (that reintroduces a mailbox bottleneck the ETS owner exists to
  avoid; OTP non-negotiable #3).
- **★ [C201-B4]** The budget *truth* is written only by L's `Ledger.Writer`
  (cited, D-320); Egress's reserve (`admit`) is a derived `update_counter`
  reservation on `Budget.Owner`'s snapshot, trued-up on completion
  (`reconcile`). Egress is **never** the writer-of-record of budget.
- **★ [C202-B6]** A `%Policy{}` version is written only by `Policy.Owner` on a
  watcher-triggered reload; it is **immutable once pinned** to a unit. Two units
  may pin two different versions concurrently; neither can mutate the other's
  pin. The pin is read-only after admission (FR-1.3 frozen scope).
- **[C203-B7]** The denylist is a compile-time constant `MapSet`; it has no
  runtime writer. A new destructive class is a one-line `MapSet` edit, not a
  mutable-state write.

### Q2: What ordering assumptions are implicit?

- **★ [C204-B1]** **The egress chain order is load-bearing, not arbitrary:**
  `RateLimiter → CircuitBreaker → Budget → call`. The cheapest, most-local
  rejection runs first; the global accounting last. Each layer is fail-closed
  and returns a tagged tuple, never raising across the boundary (OTP
  non-negotiable #7). Reordering (e.g. budget before rate-limit) breaks
  NFR-EGRESS's "0 sustained 429s" guarantee — a rejected-on-budget call still
  consumed a rate-limiter token under the wrong order. (D-351.)
- **★ [C205-B3]** The breaker `check` (ETS read) MUST precede the provider call
  and MUST NOT be a `GenServer.call` — it is on the hot path (SPEC-CIRCUIT-BREAKER
  C59). The `record` (ETS CAS) happens *after* the result. A breaker that is
  `:open` short-circuits **with no call made**, and that short-circuit MUST emit
  a visible event (`[:tau,:circuit_breaker,:open]`), never a silent drop
  ([C211]).
- **★ [C206-B6]** The engine-`clamp/1` runs **at admission, before the pin** —
  the pinned version is the *clamped* one. A policy value that could falsify a
  protected invariant is rejected/clamped *before* it ever governs a unit; an
  un-clamped value never reaches the engine. Clamping after the pin would let an
  unsafe value govern in the window between pin and clamp — forbidden.
- **★ [C207-B7]** `classify/1` MUST be called **before** any side-effecting
  execution of the action (the `git push`, the release), not after. A
  classify-after-execute ordering defeats INV-20 entirely — the destruction has
  already happened. The classifier sits structurally in front of every effecting
  path (M's `git push`, any release path).

### Q3: What happens if a component fails silently?

- **★ [C208-B3]** If `CircuitBreaker.Store` crashes, the ETS table is destroyed
  and all breakers reset to `:closed` on restart (SPEC-CIRCUIT-BREAKER C63). For
  Egress this is **acceptable degradation, not data loss**: the worst case is a
  brief window where a recovering provider is probed again — the next outcome
  re-opens the breaker. Egress MUST NOT cache breaker state across a `Store`
  restart (a stale `:open` would suppress a healthy provider).
- **★ [C209-B9]** A telemetry **handler crash MUST NOT affect a decision**
  (handlers are observers, never control). An unpaired `*.start` leaks an open
  span on a crash, so every governed span MUST be emitted via `:telemetry.span/3`
  (pairs `start`/`stop`/`exception` by construction; OTP non-negotiable #5).
  100% coverage means ≥1 paired span per user-visible governance transition
  (D-352).
- **★ [C210-B10]** A merge record written **without** its lineage row is an
  audit hole the per-cycle reconciliation cannot heal after the fact. The
  lineage MUST be written in the *same transaction* as the merge record (WAL
  before the merge ack), so an audit can never observe a merge without its
  lineage (D-353; INV-16/RPO=0, cited).
- **[C211-B1]** Any egress short-circuit (`:circuit_open`, `:budget_exhausted`,
  `:rate_limited`) MUST surface a visible telemetry event AND a tagged error to
  the caller — never a silent swallow (OTP non-negotiable: never swallow errors).

### Q4: What information crosses a boundary, and what is lost?

- **★ [C212-B5]** Every debit crossing to `Cost.Tracker` carries its **full
  attribution** `{owner, model, role, amount}` — never a bare amount. `Σ_owners
  attributed = total_spent` (CON-4) cannot hold if attribution is stripped at the
  boundary. The model+role tag is load-bearing for per-role cost (FR-7.4).
- **★ [C213-B10]** The lineage record crossing to L carries **every link**:
  `main_commit → gate_verdicts → gating_test_paths → claims(AC/D-NNN) → specs →
  issues`. A null edge on any link is an NFR-AUDIT violation. The record IS the
  audit log; nothing is reconstructed from a grep.
- **[C214-B1]** Egress returns the **full provider error term** to the caller;
  only the outcome tag (`:ok`/`:error`) drives the breaker transition
  (SPEC-CIRCUIT-BREAKER C65). No error information is stripped.

### Q5: Where are the feedback loops, and are they bounded?

- **★ [C215-B3]** The provider-failure → breaker-open → fewer-calls → probe →
  close loop is bounded by the breaker FSM (SPEC-CIRCUIT-BREAKER): N consecutive
  failures open it, a single probe tests recovery, the chain of all-open
  breakers **terminates in ≤ N calls** (D-043, cited). Egress relies on this
  termination; it adds no retry loop of its own around an open breaker.
- **★ [C216-B4]** The spend → admission-denial loop is bounded by the budget
  ceiling: admission is denied **before** the unit is billable, so overrun ≤ one
  in-flight action (NFR-BUDGET-PRECISION; D-320 cited). Exhaustion raises
  E-BUDGET (global). Egress's reserve participates in this bound; it never
  admits past a denied precheck.

### Q6: What are the pre/post-conditions at each boundary?

- **[C217-B1]** `Egress.call/3` pre: `RateLimiter`, `CircuitBreaker.Store`,
  `Budget.Owner` running. Post: returns `{:ok, stream}` only if **all three**
  guards passed in order; on any guard rejection, returns the layer's tagged
  error and makes **no provider call** for breaker/budget rejections.
- **[C218-B6]** `clamp/1` pre: a candidate `%Policy{}`. Post: `{:ok, p'}` where
  every protected floor holds in `p'` (gate-floor ⊆ manifest; `N ≤ ceiling`;
  every budget dimension finite & positive; conflict predicate only-tightened),
  or `{:error, reason}` for a value that cannot be clamped (∞ budget, missing
  gate-floor half) — **rejected, not silently weakened**.
- **[C219-B7]** `classify/1` pre: an `%Action{}` struct. Post: total — exactly
  one of `:allow` / `{:deny, :destructive}`; no raise on any input.

### Q7: What is the message-ordering protocol?

- **★ [C220]** The **egress control path is synchronous back-pressure**: a
  rate-limiter token checkout and a Finch pool checkout *block the calling agent*
  (the checkout *is* the back-pressure; FR-7.3), rather than spawning unboundedly
  or letting the provider emit a 429. Breaker `check` and budget precheck are
  **ETS reads that bypass owner mailboxes** (hot path). The **observation plane
  is `:telemetry`/PubSub** — decoupled fan-out, never the control path. No
  `:global`; no `Process.whereis |> send` (OTP non-negotiable #4).
- **[C221]** Provider, breaker-key, budget-owner, and policy-version identities
  are **stable keys** (module/atom/version), never pids. No pid is stored in any
  durable governance record.

### Q8: What is the change-impact (what else must move if this changes)?

- **★ [C222]** Adding a destructive class is a one-entry `@destructive` MapSet
  edit (C7) — no code path, by INV-24 #2 (data, not a string-keyed dispatch).
  Adding a governed parameter to `%Policy{}` requires a **clamp clause proving
  the protected invariant holds for all admissible values** (HR-8) **in the same
  PR** — a new policy field without its clamp clause is a safety hole. Changing
  the egress chain order re-discharges D-351 (the load-bearing-order proof).
  Adding a user-visible governance transition adds a paired span (D-352) and, if
  it lands a merge, a lineage edge (D-353).

## 4. Boundary contracts

### B1: agent/U ↔ Egress (C1)

- `call/3 :: (provider :: module(), req, ctx) -> {:ok, stream} | {:error, reason}`
  where `reason ∈ {:rate_limited, :circuit_open, :budget_exhausted}` ∪ provider
  error terms (`call`/back-pressure on the rate-limiter and pool checkouts).
- Pre: `RateLimiter`, `CircuitBreaker.Store`, `Budget.Owner` running.
- Post: `{:ok, stream}` ⟺ `acquire` returned a token ∧ `check == :closed`
  (or `:half_open` ∧ admitted) ∧ `admit ≤ budget`; on a breaker/budget
  rejection, **no provider `stream/3` is invoked**.
- Invariant (**D-351, composed-egress in load-bearing order**): the three guards
  are applied in the order `RateLimiter → CircuitBreaker → Budget`; no provider
  call bypasses the chokepoint; every short-circuit is visible ([C211]).

### B2: Egress (C1) ↔ RateLimiter (C2)

- `acquire/1 :: (provider) -> :ok | {:error, :rate_limited}` — token-bucket
  checkout; bucket-empty **blocks** the agent up to a deadline, then
  `:rate_limited`. The provider never sees the 429 the limiter exists to avoid.
- Reused verbatim (ADR-0011); first child of `Egress.Supervisor`.

### B3: Egress (C1) ↔ CircuitBreaker (C3)

- `check/2 :: (provider, now_ms) -> :closed | :open | :half_open` — ETS read, **no
  `GenServer.call`** ([C205]); `record/3` — ETS CAS on the outcome.
- Pre: `CircuitBreaker.Store` running. Post: `:open` → `{:error, :circuit_open}`
  with **no call made** and a `[:tau,:circuit_breaker,:open]` event;
  `:half_open` admits exactly one probe (D-030 cited).
- Reused whole from SPEC-CIRCUIT-BREAKER (D-029/D-030/D-043/D-044); the `Store`
  ETS owner moves under `Egress.Supervisor`.

### B4: Egress (C1) ↔ Budget.Owner (C4) — *cited, SPEC-FACTORY-CORE D-320*

- `admit/2 :: (owner, est_cost) -> :ok | {:error, :budget_exhausted}` — ETS
  snapshot read + reserve (`update_counter`); `reconcile/2` trues the reservation
  to actual on completion.
- Post: admission denied at the ceiling **before** the action is billable;
  overrun ≤ one in-flight action; exhaustion → E-BUDGET. **Budget.Owner and the
  D-320 contract are owned by SPEC-FACTORY-CORE;** Egress only reads-and-reserves.

### B5: Egress (C1) ↔ Cost.Tracker (C8)

- `attribute/4 :: (owner, model, role, actual) -> :ok` — records the debit to
  exactly one owner `{step, agent, gate_run}`, tagged `(model, role)`.
- Invariant (**CON-4, cited**): `Σ_owners attributed = total_spent`. The full
  tuple crosses the boundary ([C212]); no bare amount.
- Reused from `lib/tau/cost/tracker.ex` (D-038 adapter-tagged line items).

### B6: Policy.Owner (C6) ↔ Policy (C5)

- `clamp/1 :: (Policy.t()) -> {:ok, Policy.t()} | {:error, term()}` — **pure,
  property-tested**; runs at admission before the pin ([C206]). The engine-clamp
  rule, stated as a pure-function contract:

  > **HR-8 engine-clamp.** No safety invariant's *enforcement* lives in policy —
  > only its *parameters*, and only where the invariant holds for **all**
  > admissible parameter values. `clamp/1` makes this true by construction:

  - **Gate-floor non-shrinkable** — `enforce_gate_floor`: the manifest MUST be a
    superset of `{:mutation, :critic, :reviewer}`; a manifest may *add* halves,
    never drop a floor half. A missing floor half is **rejected**
    (`{:error, {:gate_floor_violation, _}}`). *Protects D-300/D-306/D-354 (cited).*
  - **`N = min(policy, ceiling)`** — `retry_bound_n` is clamped to a hard ceiling
    (`@hard_ceiling_n`); a larger policy value is *tightened*, never honoured.
    *Protects D-318 (cited).*
  - **∞-budget rejected** — `reject_infinite_budget`: every budget dimension
    (`token`, `cost`, `wall_time`, `iteration`) MUST be a positive integer; an
    `:infinity`/`nil`/`≤0` sentinel is **rejected**, not clamped (an ∞ budget
    defeats INV-21 outright). *Protects D-320/D-321 (cited).*
  - **Conflict predicate only-tightenable** — `floor_conflict_predicate`: a
    policy predicate is composed as `engine_floor(a,b) ∧ policy_pred(a,b)`; a
    plugin predicate can only *narrow* the admissible set, never relax the engine
    file+codepoint disjointness floor. *Protects D-312 (cited).*

- `pin/2 :: (unit_id, version) -> :ok` — freezes the **clamped** version to a
  unit for its life; in-flight units keep their pin across a `version` bump.
- `resolve/2 :: (unit_id, field) -> value` — reads the pinned ETS snapshot
  directly (no owner bottleneck). The **gate manifest is in the pin set** — a
  manifest edit cannot retroactively re-gate an in-flight unit.
- Invariant: every value the engine accepts keeps its parameterised invariant
  true for all admissible values; an unsafe value is rejected or clamped, never
  admitted. Enforcement stays in the engine (G's gate, U's ladder, S's conflict
  check); policy supplies only parameters within a safe envelope.

### B7: {M, effecting path} ↔ ActionClassifier (C7)

- `classify/1 :: (Action.t()) -> :allow | {:deny, :destructive}` — pure, total,
  over a **data** denylist `@destructive = MapSet.new([:force_push,
  :history_rewrite, :release, :external_publish, :data_migration])`; pattern-match
  on the action's `kind` atom (INV-24 #2 — no string-keyed dispatch).
- Pre: called **before** any side-effecting execution ([C207]). Post: a
  destructive `kind` ⇒ `{:deny, :destructive}` and the action **never
  auto-executes** (INV-20 `□(destructive(a) → escalate ∧ ¬auto_execute)`).
- Invariant (**D-319**): the deny is structural — `M` calls `classify/1` in front
  of every `git push`; a deny routes to K as E-DESTRUCTIVE.

### B8: ActionClassifier (C7) ↔ Coordinator (K) — *cited escalation set E*

- A `{:deny, :destructive}` routes to K as **E-DESTRUCTIVE** (per-action scope;
  E owned by SPEC-FACTORY-CORE). K records + delivers it (CON-7); the action does
  not auto-execute. The escalation set `E` and its delivery contract are cited,
  not owned here.

### B9: governed components ↔ OtelReporter (C9)

- Every user-visible/perf-sensitive governance event emits a **paired**
  `[:tau,:factory,…]` span via `:telemetry.span/3` (`*.start`/`*.stop`/
  `*.exception`). Covered spans (≥1 per user-visible transition):

  | Span | Emitted by | Measurements |
  |---|---|---|
  | `[:tau,:factory,:egress,:call]` | Egress (C1) | provider, layer-rejection, tokens, cost |
  | `[:tau,:factory,:budget,:debit]` | Budget.Owner (C4) | owner, model, role, amount |
  | `[:tau,:factory,:escalation]` | K | reason ∈ E (incl. E-DESTRUCTIVE, E-BUDGET), state snapshot |
  | `[:tau,:circuit_breaker,:open]` | CircuitBreaker (C3) | provider, opened_at_ms |

- Handlers are **observers, never control** ([C209]); a handler crash never
  blocks a decision. The supervised `Tau.OtelReporter` (reused, SPEC-OTEL-REPORTER
  D-050..D-055) subscribes the namespace and exports OTLP; its crash never blocks
  the factory.
- Invariant (**D-352**): 100% of user-visible governance transitions have a
  paired span.

### B10: Lineage (C10) ↔ Ledger.Writer (L) — *cited, SPEC-FACTORY-CORE*

- The `%Lineage{}` shape (owned here):

  ```
  %Lineage{
    main_commit:       sha,                                  # M is sole writer
    unit_id:           u,
    gate_verdicts:     [%{half:, verdict:, diff_hash:}],     # ∀ required half a fresh verdict
    gating_test_paths: [...],                                # the frozen oracle boundary
    claims:            [AC-N | D-NNN, ...],                  # from the draft-PR ## Acceptance criteria
    specs:             [SPEC-*, ...],                        # SPEC membership
    issues:            [#N, ...]                             # intent authority
  }
  ```

- Each link is a foreign-key edge in L; `100%` traceability is a **join, not a
  grep** ([C213]). The lineage row is written in the **same transaction as the
  merge record** (WAL before the merge ack; RPO=0, cited), so no audit observes a
  merge without its lineage.
- Invariant (**D-353**): every merge is fully traceable
  `main_commit → gate_verdicts → gating_test_paths → claims → specs → issues`
  with no null edge. **L is the writer-of-record (cited);** this SPEC owns the
  shape + join contract.

## 5. State enumeration

Governance is mostly *stateless guards over owner-held ETS snapshots*; the only
genuine state machine it consumes (the circuit breaker) is owned by
SPEC-CIRCUIT-BREAKER and *cited* here. The governance-owned "states" are the
egress chain's per-call outcome and the policy lifecycle.

### Egress chain — per-call outcome (C1), not a persisted FSM

```
outcome ∈ {ok, rate_limited, circuit_open, budget_exhausted, provider_error}

 acquire(provider) ─token─→ check(provider) ─:closed/:half_open(admitted)─→ admit(owner,est)
   acquire bucket-empty (> deadline)            → rate_limited      (no call; visible event)
   check :open                                  → circuit_open      (no call; visible event)
   check :half_open + ¬admitted                 → circuit_open      (no call)
   admit > budget                               → budget_exhausted  (no call; → E-BUDGET, cited)
   all pass → provider stream/3 → record(:ok|:error) + reconcile + attribute
     stream error                               → provider_error    (full term preserved)
```

The order is **load-bearing** (D-351): a later guard's rejection never consumes
an earlier guard's resource out of order. Every non-`ok` outcome is **visible**
(telemetry + tagged error), never silent ([C211]).

### Circuit breaker — `:closed/:open/:half_open` (cited, SPEC-CIRCUIT-BREAKER)

The breaker FSM (D-029) is consumed read-only on the hot path; its transition
table, ETS row layout (D-044), and probe-exclusivity (D-030) are owned by
SPEC-CIRCUIT-BREAKER and not redefined here.

### Policy lifecycle (C5/C6)

```
candidate %Policy{} ─clamp/1─→ {:ok, clamped} ─pin(unit,version)─→ pinned (frozen for unit life)
                              └ {:error, reason}  (∞ budget | missing gate-floor half)  → reject; no pin
   version bump (watcher reload) → new units pin the new clamped version; in-flight units keep their pin
```

A pinned version is **immutable** for the unit's life ([C202]); the clamp runs
**before** the pin ([C206]) so an unsafe value never governs a unit.

### Cited escalation classes raised by this plane (E owned by SPEC-FACTORY-CORE)

| `e` | Raised by | Scope |
|-----|-----------|-------|
| `E-DESTRUCTIVE` | ActionClassifier (C7) → K | per-action (**owned trigger, D-319**) |
| `E-BUDGET` | Egress budget rejection → K | global (cited, D-320) |

## 6. D-NNN invariants

> Owned by this SPEC. Each names its detection method. Cited D-NNN
> (core/gate/merge) are enforced by their owner SPEC and only *consumed* here.

**D-319 — No unilateral destruction (action classifier):**
`ActionClassifier.classify/1` is pure and total; every `kind ∈ @destructive`
yields `{:deny, :destructive}`; the deny is structural — every effecting path
(notably `M`'s `git push`) calls `classify/1` *before* executing, and a deny
routes to K as **E-DESTRUCTIVE** with the action **never auto-executing** (INV-20
`□(destructive(a) → escalate ∧ ¬auto_execute)`). Enforced by the property suite
`action_classifier_property_test.exs` (classify totality + every denylist member
denied, tagged `:property`) **and** `action_classifier_test.exs` (a classified
destructive action is denied + raises E-DESTRUCTIVE + does not execute — the
structural-deny test). A denylist member that auto-executes falsifies this.

**D-351 — Egress chain composed in load-bearing order (NFR-EGRESS):**
`Egress.call/3` is the single chokepoint; it applies the three fail-closed guards
in the exact order `RateLimiter → CircuitBreaker → Budget`, each returning a
tagged tuple (never raising across the boundary), and **no provider call bypasses
it**. An `:open` breaker short-circuits with no call made; a budget-over call is
denied before billing; a rate-limited call back-pressures the agent (0 sustained
429s). Enforced by `egress_chain_test.exs` (assert the guard order; assert a
bypass is impossible — every provider call routes through `call/3`; assert each
layer's rejection short-circuits the rest) and a steady-load smoke asserting 0
sustained 429/5xx-driven failures.

**D-352 — Telemetry coverage = 100% (NFR-OBS-COVERAGE):**
Every user-visible or perf-sensitive governance transition emits a **paired**
`[:tau,:factory,…]` span via `:telemetry.span/3` (`*.start`/`*.stop`/
`*.exception`); handlers are observers (a handler crash never affects a
decision); the supervised `Tau.OtelReporter` exports the namespace via OTLP.
Enforced by `telemetry_coverage_test.exs` (a coverage scan: for each enumerated
user-visible governance transition, assert a paired span is emitted; assert no
unpaired `*.start`) and the OTel reporter's subscription test.

**D-353 — Audit traceability = 100% (NFR-AUDIT):**
Every merge is fully traceable along `main_commit → gate_verdicts →
gating_test_paths → claims(AC/D-NNN) → specs → issues` with **no null edge**; the
`%Lineage{}` row is written in the **same transaction as the merge record** (WAL
before the merge ack), so an audit never observes a merge without its lineage;
traceability is a **join over FK edges, not a grep**. Enforced by
`lineage_audit_test.exs` (insert a merge + lineage; the join returns the full
chain end-to-end; a lineage row with any null edge fails a CON-6/NFR-AUDIT
assertion in the per-cycle reconciliation) and the same-transaction durability
test (kill between merge-record and lineage-write ⇒ neither lands; never a merge
without lineage).

**D-374 — No metered-API spend (factory plane, fail-closed):**
When `agent_mode == :claude_code`, `Worker.open_port_and_finish/1` MUST
call `creds_check_fun.()` BEFORE `Port.open`. If it returns
`{:error, _}`, the Port is NEVER opened; the worker stops with
`:metered_path_refused` (the death-cert monitor maps this to
`{:worker_exit, worker_id, :metered_path_refused}`). The Port env MUST
include `{~c"ANTHROPIC_API_KEY", false}` to prevent the child from
inheriting a metered key. NO fallback to the metered path is permitted.
Non-`:claude_code` modes are unchanged.
Enforced by `test/tau/factory/cost_safety_fence_test.exs`
(tags `:d_374` — 3 tests): (a) fail-closed: absent creds → refusal, no
Port open; (b) env scrub: canary `ANTHROPIC_API_KEY` absent from child;
(c) creds-present: preflight passes, worker proceeds normally.

## 7. Acceptance criteria

Each is expressed against the user-facing path with an observable signal.
PR groupings are indicative.

- **AC-1 (PR-GOV-1):** `mix compile --warnings-as-errors` passes with
  `Tau.Factory.Egress` present and `Egress.Supervisor` starting the reused
  `RateLimiter` + `CircuitBreaker.Store` under `Tau.Factory.Supervisor`. Signal:
  `mix test` boots the tree with the egress chain wired.
- **AC-2 (PR-GOV-1, D-351):** `mix test test/tau/factory/egress_chain_test.exs`
  passes — the guards apply in order `RateLimiter → CircuitBreaker → Budget`; an
  `:open` breaker short-circuits with **no provider call made** and surfaces a
  **visible** `[:tau,:circuit_breaker,:open]` event (not a silent drop). Signal:
  the test asserts the order, the no-call, and the visible event.
- **AC-3 (PR-GOV-1, D-351):** a steady-load egress smoke records **0 sustained
  429/5xx-driven failures** under the composed chain. Signal: the load test's
  sustained-failure count is 0.
- **AC-4 (PR-GOV-2, D-319):** `mix test --only property` passes including
  `action_classifier_property_test.exs` (classify total; every `@destructive`
  member denied). Signal: the property suite green.
- **AC-5 (PR-GOV-2, D-319):** `action_classifier_test.exs` passes — a classified
  destructive action (e.g. a `:force_push`) is **denied, raises E-DESTRUCTIVE,
  and never auto-executes**; an `:allow` action proceeds. Signal: the test
  asserts deny + escalation + no execution.
- **AC-6 (PR-GOV-3, HR-8):** `mix test --only property` passes including
  `policy_clamp_property_test.exs` — `∀` admissible `p`, `clamp(p)` preserves
  every floor (gate-floor ⊆ manifest; `N ≤ ceiling`; every budget dimension
  finite > 0; conflict predicate only-tightened). Signal: the property green.
- **AC-7 (PR-GOV-3, HR-8):** `policy_clamp_test.exs` passes — an ∞-budget policy
  is **rejected** (not clamped); a manifest missing a gate-floor half is
  **rejected**; an over-ceiling `N` is **clamped** to the ceiling; a relaxing
  conflict predicate is **tightened** by the engine floor. Signal: the test
  asserts reject/clamp per case.
- **AC-8 (PR-GOV-4, D-320):** `budget_egress_test.exs` passes — spend driven to
  the ceiling **denies the next `Egress.call`** with `:budget_exhausted` and
  raises E-BUDGET; the action is not billed. Signal: the test asserts the denial
  + escalation. *(Budget.Owner/D-320 owned by SPEC-FACTORY-CORE; this AC verifies
  the egress consumption.)*
- **AC-9 (PR-GOV-5, D-352):** `telemetry_coverage_test.exs` passes — every
  enumerated user-visible governance transition emits a **paired** span; no
  unpaired `*.start`. Signal: the coverage scan reports 100%.
- **AC-10 (PR-GOV-6, D-353):** `lineage_audit_test.exs` passes — an audit query
  **traces one merge end-to-end** `commit → verdicts → paths → AC/D-NNN → SPEC →
  issue` as a join; a null edge fails the reconciliation assertion. Signal: the
  join returns the full chain; the null-edge case fails.
- **AC-11 (meta):** the gating tests above run in CI as a blocking job; the
  `[:tau,:factory,…]` telemetry namespace is subscribed by the supervised OTel
  reporter. *(meta — verified by CI wiring + supervision-tree inspection; exempt
  from the unit-test-linkage check.)*
- **AC-12 (PR-GOV-7, end-to-end / substance):** the governance plane governs one
  real PR end-to-end on the self-hosting toolchain: outbound calls route through
  `Egress` (visible egress spans), a synthetic destructive action is denied
  (E-DESTRUCTIVE), spend is bounded, and the merged commit's lineage is
  fully queryable. Signal: the exact command + the observable egress span + the
  E-DESTRUCTIVE record + the end-to-end lineage join. *This AC depends on
  SPEC-FACTORY-{CORE,GATE,MERGE} landing; it is the integration gate, not a
  GOV-only unit.*

## Appendix B — Source map

Files that bring a PR into scope of this SPEC (`D-NNN`/`C-N` → file:symbol):

- `lib/tau/factory/egress.ex` (C1; D-351, D-352 egress span) — PR-GOV-1
- `lib/tau/factory/egress/supervisor.ex` (Egress.Supervisor tree wiring) — PR-GOV-1
- `lib/tau/providers/rate_limiter/` (C2; **reuse**, ADR-0011 — Egress layer 1) — PR-GOV-1
- `lib/tau/circuit_breaker/` (C3; **reuse**, SPEC-CIRCUIT-BREAKER D-029/030/043/044 — Egress layer 2; `Store` moves under `Egress.Supervisor`) — PR-GOV-1
- `lib/tau/factory/policy.ex` (C5; HR-8 `clamp/1`/`resolve/2`) — PR-GOV-3
- `lib/tau/factory/policy/owner.ex` (C6; pin-per-unit ETS snapshot) — PR-GOV-3
- `lib/tau/factory/action_classifier.ex` (C7; D-319) — PR-GOV-2
- `lib/tau/cost/tracker.ex` (C8; **reuse**, CON-4 attribution, D-038) — PR-GOV-4
- `lib/tau/otel_reporter/` (C9; **reuse**, SPEC-OTEL-REPORTER D-050..055 — subscribe `[:tau,:factory,…]`) — PR-GOV-5
- `lib/tau/factory/lineage/schema.ex` + L's `Ledger.Writer` lineage path (C10; D-353 same-txn write) — PR-GOV-6
- `lib/tau/settings/{loader,schema,cache}.ex` (**reuse**, the `%Policy{}` source/snapshot) — PR-GOV-3
- `lib/tau/factory/supervisor.ex` + `lib/tau/application.ex` (placement of `Egress.Supervisor`, `Policy.Owner`, OTel reporter) — PR-GOV-1
- `test/tau/factory/egress_chain_test.exs` (D-351) — PR-GOV-1
- `test/tau/factory/action_classifier_property_test.exs` + `action_classifier_test.exs` (D-319) — PR-GOV-2
- `test/tau/factory/policy_clamp_property_test.exs` + `policy_clamp_test.exs` (HR-8) — PR-GOV-3
- `test/tau/factory/budget_egress_test.exs` (D-320 consumption) — PR-GOV-4
- `test/tau/factory/telemetry_coverage_test.exs` (D-352) — PR-GOV-5
- `test/tau/factory/lineage_audit_test.exs` (D-353) — PR-GOV-6

**Reuse map (no new code where the subsystem exists — arch governance.md §8):**

| Reuse candidate (`lib/tau/…`) | Slots in as | Component |
|---|---|---|
| `providers/rate_limiter/` (token-bucket + supervisor, ADR-0011) | Egress layer 1 | C2 |
| `circuit_breaker/` (State FSM + Store ETS owner + façade) | Egress layer 2 | C3 |
| `cost/tracker.ex` (+ `cost.ex`, D-038) | CON-4 cost attribution | C8 |
| `otel_reporter/` (OTLP exporter, SPEC-OTEL-REPORTER) | observability reporter | C9 |
| `settings/{loader,schema,cache}` (property-tested merge; live-reload) | `%Policy{}` source + snapshot | C5/C6 |

**Cross-SPEC boundaries (cited, not owned here):** B4 → `SPEC-FACTORY-CORE`
(`Budget.Owner`, D-320/D-321 budget ceiling + clean kill); B8/B10 →
`SPEC-FACTORY-CORE` (the escalation set `E` and the Ledger `L` as lineage
writer-of-record); the engine-clamp **protects** but does not own
D-300/D-306/D-354 (`SPEC-FACTORY-{MERGE,GATE}` — gate-floor / mutation /
game-resistance), D-312 (`SPEC-FACTORY-CORE` — conflict gate), and D-318
(`SPEC-FACTORY-CORE` — bounded retry).

**Catalog registration required before first implementation PR:** add
`SPEC-FACTORY-GOV` to `.claude/rules/spec-before-code.md` (catalog) and the
`D-NNN` block table in `docs/MISSION.md` (**D-319, D-351, D-352, D-353** → this
SPEC).
