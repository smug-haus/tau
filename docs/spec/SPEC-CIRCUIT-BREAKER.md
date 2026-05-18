# SPEC: Circuit Breaker

| | |
|---|---|
| **Status** | Draft |
| **Date** | 2026-05-18 |
| **Scope** | Per-provider circuit breaker: `:closed/:open/:half_open` state machine, ETS-owner lifecycle anchor, façade. |
| **Method** | PSDH (`.claude/skills/design-reasoning`); L0 + boundary contracts. |
| **Issue** | #65 (M2) |

**Changelog:** Initial draft — §0–§7 + Appendix B. D-029, D-030, D-043, D-044 introduced.

## 0. Why this spec exists

The provider layer (ADR-0011, ADR-0012) already handles back-pressure from rate
limiters and provider errors, but has no mechanism to stop hammering a provider
that is returning consistent hard errors. Without a circuit breaker, a
session experiencing a sustained 5xx storm loops at the provider indefinitely:
each turn spawns a provider task, which fails immediately, which triggers
fallback logic, which retries — consuming quota, billing tokens that yield no
useful output, and delaying the user's error feedback.

A circuit breaker wraps this at the provider-call level. After N consecutive
failures it opens a gate that short-circuits calls immediately (`:open`), waits
a configurable cooldown (`cooldown_ms`), then admits a single probe call
(`:half_open`). Success closes the breaker; failure re-opens it.

The component is coordination-heavy (triage score 5/5; see §1) and therefore
requires this spec before any implementation PR modifies the breaker boundary.

## 1. Triage

| # | Property | Score | Evidence |
|---|----------|-------|----------|
| 1 | Shared mutable state | 1 | Breaker state per provider is read by every concurrent session turn and written on every provider-call outcome; the ETS table is the shared structure. |
| 2 | Temporal coupling | 1 | `opened_at_ms` determines when `:open → :half_open` fires; wall-clock progression is load-bearing; `check/2` must be called with a consistent `now_ms` relative to `opened_at_ms`. |
| 3 | Cross-process coordination | 1 | `Tau.CircuitBreaker.Store` (GenServer, PR2) owns the ETS table; concurrent session-turn tasks read and write probe slots via ETS atomics — no mailbox serialisation. |
| 4 | Feedback loops | 1 | Provider failure → breaker opens → sessions see `:open` → error surfaced to user → user retries → breaker admits probe → success closes → normal flow resumes. |
| 5 | State accumulation | 1 | `failure_count` and `success_count` accumulate across turns until a threshold triggers a transition; `opened_at_ms` persists until the cooldown expires. |

**Triage score: 5/5. L0 + boundary contracts indicated.**

## 2. Component decomposition

Three layers. Naming is precise so that contracts in §4 attach to specific
operations.

| # | Component | Role |
|---|-----------|------|
| C1 | `Tau.CircuitBreaker.State` | Pure state-machine module. `%State{}` struct + `record_failure/2`, `record_success/2`, `check/2`. No process, no ETS. |
| C2 | `Tau.CircuitBreaker.Store` | GenServer lifecycle anchor. Owns the ETS table `:tau_circuit_breakers`. Exposes `transition/2` (atomically CAS a full row) and `probe_admitted?/1` (atomic half-open single-probe gate). |
| C3 | `Tau.CircuitBreaker` | Public façade. `call/3 :: (provider, opts, thunk) → result`. Checks state, admits or short-circuits, records outcome, drives transitions. |

Boundaries between layers:

| # | Boundary | Operation |
|---|----------|-----------|
| B1 | `Tau.CircuitBreaker` (C3) ↔ `Tau.CircuitBreaker.Store` (C2) | ETS read for `check`; atomic write for `transition` and probe-slot bump. |
| B2 | `Tau.CircuitBreaker.Store` (C2) ↔ ETS (`:tau_circuit_breakers`) | Table create/destroy in `init/1` / `terminate/2`; all reads and writes via ETS primitives. |
| B3 | `Tau.Session` / provider task ↔ `Tau.CircuitBreaker` (C3) | `call/3` wraps the provider `stream/3` thunk; returns `{:error, :circuit_open}` when the breaker is open. |
| B4 | `Tau.CircuitBreaker.State` (C1) ↔ callers | Pure function calls; no side effects. |

## 3. L0 constraints

Format: `[Cn-Bm]` = constraint number + boundary. **★** marks non-obvious.

### Q1: What can be written by more than one actor?

- **★ [C56-B1]** The ETS row for a provider can be updated by N concurrent
  session-turn tasks simultaneously — each records a success or failure
  independently. Counter fields (`failure_count`, `success_count`) MUST be
  updated with `:ets.update_counter/3` (atomic); full-row state transitions
  MUST use `:ets.select_replace/2` with a guard so no two processes race a
  non-atomic multi-field write.
- **★ [C57-B1]** The half-open probe slot is a single counter field
  `probe_slot` (position in the ETS row). Admission is an `:ets.update_counter/3`
  bump with a threshold guard: the call that increments `probe_slot` from 0 to 1
  is the admitted probe; any call that finds `probe_slot >= 1` MUST be rejected
  as `:circuit_open`. This is the only correct way to admit exactly one probe
  under concurrent access — no lock, no GenServer serialisation.
- **[C58-B2]** The `Store` GenServer creates the table in `init/1` and is the
  only process that calls `:ets.new/2` or `:ets.delete/1` on it. Any process
  may read or update counters directly via ETS.

### Q2: What ordering assumptions are implicit?

- **★ [C59-B3]** `check/2` (via `Store` ETS read) MUST be called before the
  provider thunk is invoked. The result of `check/2` at the instant of the
  call is authoritative — the breaker state may transition between `check` and
  the thunk returning, but that is handled by the next call, not this one.
- **★ [C60-B1]** State transitions MUST be confined to a single atomic
  operation: either a single counter field update (`update_counter`) or a
  full-row CAS (`select_replace`). No transition may require two separate ETS
  writes to be atomic — there is no ETS transaction API.
- **[C61-B2]** `Store` `init/1` MUST create the ETS table before returning
  `{:ok, state}`, so any caller of `Tau.CircuitBreaker.call/3` can rely on the
  table existing if `Store` is running.

### Q3: What happens if a component fails silently?

- **★ [C62-B3]** If the breaker is `:open` and the caller does not check the
  return value of `call/3`, the short-circuit error `{:error, :circuit_open}`
  is swallowed. The façade MUST log a telemetry event
  `[:tau, :circuit_breaker, :open]` so the TUI and session FSM have an
  observable signal.
- **★ [C63-B2]** If `Store` crashes, the ETS table is destroyed (it is
  `:private` to the owner process — see §4). All concurrent reads and writes
  fail. The supervisor MUST restart `Store` and the table is recreated empty —
  all breakers reset to `:closed`. This is acceptable: a restart means the
  crash cost is a momentary reset of error counters, not data loss of
  user-visible state.
- **[C64-B1]** If the ETS row for a provider does not exist (first call ever),
  `check/2` MUST default to `:closed` — absence of state means the breaker is
  healthy. Row creation MUST be idempotent (`:ets.insert_new/2` or equivalent).

### Q4: What information crosses a boundary, and what is lost?

- **★ [C65-B3]** `call/3` wraps the thunk result. The full error term from the
  provider is preserved and returned to the caller; only the outcome tag
  (`:ok` or `:error`) is used to drive the breaker transition. No information
  is stripped.
- **[C66-B1]** The ETS row carries `opened_at_ms` (wall clock, milliseconds).
  Time is not shared across nodes — this spec is BEAM-local only. Distributed
  circuit breaking is out of scope.

## 4. Boundary contracts

### B1: `Tau.CircuitBreaker` (C3) ↔ `Tau.CircuitBreaker.Store` (C2)

**Read contract** (`check/2`):

- Input: `provider :: module()`, `now_ms :: non_neg_integer()`
- Output: `:closed | :open | :half_open`
- Pre: `Store` is running; ETS table exists.
- Post: returns `:closed` if no row exists for `provider`.
- Invariant: `:half_open` is returned only if `now_ms >= opened_at_ms + cooldown_ms`.

**Write contract** (`transition/2` — full-row CAS):

- Input: `provider :: module()`, `new_state :: %State{}`
- Operation: `:ets.select_replace/2` with a guard on the current row's state
  field. Returns `0` (no match — concurrent transition won) or `1` (replaced).
- Invariant: the caller that returns `1` is the sole writer of the new row;
  callers that return `0` treat it as a no-op (their transition lost the race).

**Probe-admission contract** (`probe_admitted?/1`):

- Input: `provider :: module()`
- Operation: `:ets.select_replace/2` with a match spec that matches the row
  when `probe_slot == 0` and replaces it with the same row with `probe_slot = 1`.
  Return value `1` → admitted (this process is the sole probe); `0` → rejected
  (another process already claimed the slot).
- Why not `update_counter`: `:ets.update_counter/3` returns only the
  post-increment value. With a clamp-at-1 spec, both the first and all
  subsequent callers receive `1` — there is no way to distinguish the first
  caller from the nth using the return value alone. `select_replace` performs a
  conditional full-row CAS (match only when `probe_slot == 0`), so exactly one
  caller receives match count `1`; all others receive `0`.

### B2: `Tau.CircuitBreaker.Store` (C2) ↔ ETS

**Table options (binding):**
```
:ets.new(:tau_circuit_breakers, [
  :named_table, :public, :set,
  read_concurrency: true,
  write_concurrency: true
])
```

**Row layout (binding — every field position is fixed):**

```
{provider_key, state_atom, failure_count, success_count, opened_at_ms, probe_slot}
```

- Position 1: `provider_key :: module()` — the ETS key.
- Position 2: `state_atom :: :closed | :open | :half_open`
- Position 3: `failure_count :: non_neg_integer()` — consecutive failure count.
- Position 4: `success_count :: non_neg_integer()` — consecutive success count in `:half_open`.
- Position 5: `opened_at_ms :: non_neg_integer()` — monotonic ms at which breaker opened; `0` when `:closed`.
- Position 6: `probe_slot :: 0 | 1` — `0` = probe available; `1` = probe in flight or completed.

**Why fixed positions:** `:ets.update_counter/3` and `:ets.select_replace/2`
operate on positional fields. A future schema change that moves a field breaks
all active `:update_counter` calls silently. Positions MUST NOT be renumbered
without a data-migration step.

**State transition atomicity (binding):**

- `failure_count` increments: `:ets.update_counter(:tau_circuit_breakers, key, {3, 1})`
- `success_count` increments: `:ets.update_counter(:tau_circuit_breakers, key, {4, 1})`
- Full state transition (`:closed → :open`, `:open → :half_open`, `:half_open → :closed`, `:half_open → :open`): `:ets.select_replace/2` with a guard on position 2 (current `state_atom`). A match count of `0` means a concurrent process already transitioned; treat as no-op.
- Probe-slot admission: `:ets.select_replace/2` matching `probe_slot == 0`, replacing with `probe_slot = 1`. Match count `1` → admitted; `0` → rejected.

**No transition requires two separate ETS writes** — each is either a single
`update_counter` (counter bump) or a single `select_replace` (full-row CAS).

### B3: `Tau.Session` / provider task ↔ `Tau.CircuitBreaker` (C3)

- `call/3 :: (provider :: module(), opts :: keyword(), thunk :: (-> result)) -> result | {:error, :circuit_open}`
- Pre: `Store` is running.
- Post: if `:open`, returns `{:error, :circuit_open}` without invoking `thunk`.
- Post: if `:closed` or `:half_open` (and admitted), invokes `thunk`, records outcome.
- Telemetry events: `[:tau, :circuit_breaker, :check]`, `[:tau, :circuit_breaker, :open]` (when short-circuited), `[:tau, :circuit_breaker, :transition]` (on state change).

### B4: `Tau.CircuitBreaker.State` (C1) ↔ callers

- Pure functions, no side effects.
- `record_failure/2 :: (%State{}, opts :: keyword()) -> %State{}`
- `record_success/2 :: (%State{}, opts :: keyword()) -> %State{}`
- `check/2 :: (%State{}, now_ms :: non_neg_integer()) -> :closed | :open | :half_open`
- All functions are total — no raises on valid inputs.

**`opts` keys for `record_failure/2` and `record_success/2`:**

| Key | Type | Required? | Default | Purpose |
|-----|------|-----------|---------|---------|
| `:now_ms` | `non_neg_integer()` | **REQUIRED** when call can trigger `:open` transition (i.e. in `:closed` or `:half_open` state) | — | Wall-clock milliseconds at time of call; stored as `opened_at_ms` on `:open` transition. Omitting it raises `KeyError`. |
| `:failure_threshold` | `pos_integer()` | optional | `5` | Consecutive failures before opening. |
| `:success_threshold` | `pos_integer()` | optional | `1` | Successes in `:half_open` before closing. |

`:now_ms` is a required key for any state that can transition to `:open`. Callers must supply a monotonic millisecond timestamp. Omitting `:now_ms` where it is required raises a `KeyError` (fail loud — silent `0` defaults cause the cooldown to appear already elapsed on any subsequent `check/2`).

## 5. State enumeration

| State | Meaning | Entry condition | Exit condition |
|-------|---------|-----------------|----------------|
| `:closed` | Normal operation | Initial; or success in `:half_open` | `failure_count >= failure_threshold` |
| `:open` | Short-circuiting all calls | `failure_count >= failure_threshold`; or failure in `:half_open` | `now_ms >= opened_at_ms + cooldown_ms` |
| `:half_open` | Admitting exactly one probe | `cooldown_ms` elapsed since opening | Probe succeeds → `:closed`; probe fails → `:open` |

**Transition table:**

```
:closed  + record_failure → failure_count < threshold  → :closed (count bumped)
:closed  + record_failure → failure_count >= threshold → :open   (reset success_count; set opened_at_ms)
:closed  + record_success → any                        → :closed (reset failure_count)
:open    + check(now_ms)  → now_ms < opened_at_ms + cooldown_ms → :open
:open    + check(now_ms)  → now_ms >= opened_at_ms + cooldown_ms → :half_open (reset probe_slot = 0)
:half_open + probe_admitted? → true  → call thunk
:half_open + probe_admitted? → false → :open (reject, no thunk call)
:half_open + record_success → → :closed (reset failure_count, success_count, probe_slot)
:half_open + record_failure → → :open  (reset probe_slot; set new opened_at_ms)
```

**Defaults** (overridable via opts in PR2):

- `failure_threshold`: `5` consecutive failures.
- `cooldown_ms`: `30_000` ms (30 seconds).
- `success_threshold`: `1` success in `:half_open` to close.

## 6. D-NNN invariants

**D-029 — Circuit breaker state machine is total and deterministic:**
For any `%State{}` and any `now_ms`, `check/2` returns exactly one of
`:closed`, `:open`, `:half_open`. `record_failure/2` and `record_success/2`
return a valid `%State{}`. No combination of inputs reaches an undefined or
intermediate state. This invariant is enforced by the property suite in PR1
(`state_property_test.exs`) and by the ETS-level constraint that `state_atom`
is always one of the three atoms.

**D-030 — Probe admission is exclusive under concurrency:**
In `:half_open` state, at most one concurrent caller is admitted as a probe.
Enforced by the `probe_admitted?/1` implementation in `Store` (PR2) using
`:ets.select_replace/2` on `probe_slot` (0 → 1). The property suite in PR2
MUST include a concurrent-probe race property: N processes race a half-open
breaker simultaneously; exactly one receives `{:ok, admitted}`, the rest
receive `{:error, :circuit_open}`. This property MUST be tagged `:property`
and run under `async: false`.

**D-043 — All-open chain terminates:**
A chain of N providers where all breakers are `:open` terminates in at most N
`call/3` invocations, each returning `{:error, :circuit_open}`. The chain
MUST NOT loop. Enforced by the fallback logic in PR3: a fallback sequence that
encounters `:circuit_open` on every member reports the error immediately rather
than retrying indefinitely. The property suite in PR3 MUST include an
all-breakers-open fallback-termination property: given a list of providers all
in `:open` state, `call/3` over each returns `{:error, :circuit_open}` and the
total invocation count equals the length of the list (never exceeds it).

**D-044 — ETS row layout is immutable within a schema version:**
The positional field layout defined in §4 B2 MUST NOT be changed without a
schema-version bump and data migration. `update_counter` and `select_replace`
calls hardcode field positions; a silent reorder silently corrupts counters.
Any PR that changes the row layout MUST bump a `@schema_version` module
attribute in `Tau.CircuitBreaker.Store` and document the migration in the PR
description.

## 7. Acceptance criteria

- **AC-1 (PR1):** `mix compile --warnings-as-errors` passes with `lib/tau/circuit_breaker/state.ex` present.
- **AC-2 (PR1):** `mix test test/tau/circuit_breaker/state_property_test.exs` passes; all properties tagged `:property` exercise the D-029 invariant.
- **AC-3 (PR2):** `mix test --only property` passes including the concurrent-probe race property (D-030).
- **AC-3b (PR3):** `mix test --only property` passes including the all-open termination property (D-043).
- **AC-4 (PR2):** `Tau.CircuitBreaker.Store` starts under `Tau.Application` supervision; `mix test` passes.
- **AC-5 (PR3):** `Tau.CircuitBreaker.call/3` wraps a synthetic always-failing thunk; after `failure_threshold` failures, subsequent calls return `{:error, :circuit_open}` without invoking the thunk.
- **AC-6 (PR3):** After `cooldown_ms`, `call/3` admits exactly one probe; if the probe fails, all subsequent calls are again `:circuit_open` until the next cooldown.
- **AC-7 (PR4):** Integration with `Tau.Session` provider dispatch; a session turn against an open breaker surfaces a visible error event to the TUI (not a silent drop).

## Appendix B — Source map

Files that bring a PR into scope of this SPEC:

- `lib/tau/circuit_breaker.ex` (façade, C3) — PR3+
- `lib/tau/circuit_breaker/state.ex` (pure core, C1) — PR1
- `lib/tau/circuit_breaker/store.ex` (ETS owner, C2) — PR2
- `test/tau/circuit_breaker/state_property_test.exs` — PR1
- `test/tau/circuit_breaker/store_property_test.exs` — PR2
- `test/tau/circuit_breaker/circuit_breaker_test.exs` — PR3
- `lib/tau/application.ex` (supervision tree) — PR2
- `lib/tau/session.ex` or provider dispatch path — PR4
