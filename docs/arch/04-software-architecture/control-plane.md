# Software architecture — control plane (K · S · U)

This file details the **control plane** of the `:tau_factory` OTP application:
the **Coordinator (K)**, the **Scheduler (S)**, and the per-PR **Unit FSM (U)**.
It is subordinate to and consistent with the authoritative topology in
`supervision-tree.md`; the system-level component contracts are in
`../03-system-architecture/system-architecture.md` §1–§5; the requirements are
in `../02-requirements/{invariants,liveness,R-list}.md`; the OTP primitive
choices are justified in `../01-research/otp-capabilities.md`. Where this file
and `supervision-tree.md` appear to disagree, `supervision-tree.md` wins.

Companion layer-04 files (forward references): `durable-spine.md` (L, Oban,
budget ETS, `W_cap`/`B` sizing), `worker-fleet.md` (W), `gate-and-toolchain.md`
(G, Σ_T), `governance.md` (Policy clamp Π / HR-8).

**Design spine in one line:** *supervision recovers infrastructure; the FSM +
durable solution tree recover semantics* (research §10; FR-8.2). Every decision
below is a corollary of that split.

---

## 0. Process roster recap (from `supervision-tree.md` Step 0–1)

| Comp | OTP form | States | Restart type | Registry key |
|------|----------|--------|--------------|--------------|
| **K** Coordinator | `gen_statem` (`state_functions`) | `running` / `halting` / `halted` | `:permanent` (spine, started LAST) | named singleton |
| **S** Scheduler | `GenServer` (admission authority) | in-flight set `F`, pins | `:permanent` (spine) | named singleton |
| **U** Unit/PR | `gen_statem` (`state_functions`), one per PR | 8 states (§3) | `:temporary` under `UnitSupervisor` | `{:via, Registry, {UnitRegistry, unit_id}}` |

`ConflictCheck`, the escalation classifier, and the retry-ladder decision are
**pure modules** — no process (research §3; OTP non-negotiable #8). K, S, and U
are processes only because each carries a Step-0 runtime property (serialized
work-selection + total escalation; serialized admission; per-entity lifecycle +
legal-transition FSM).

---

## 1. K — Coordinator (`gen_statem`)

### 1.1 Why `gen_statem`, not GenServer

K's value is **serialized work-selection** plus a **total, classified
escalation surface** (INV-18) plus a **lifecycle with a clean halt** (INV-22).
These are transition-legality properties: "you cannot select new work while
`halting`", "every non-progress exit names exactly one `e ∈ E`". Encoding them
as missing/explicit `gen_statem` clauses makes the illegal transition
*unrepresentable* (research §2), rather than as a `cond` ladder a reviewer must
audit. State timeouts give the escalation-on-stall for free.

`callback_mode/0 → :state_functions` — three states, one callback each.

### 1.2 States and the loop

```
        start (resume from L, LIV-5)
            │
            ▼
   ┌─────────────────┐  unit_terminal / select-next (the loop)
   │     running     │◀─────────────────────────────┐
   │  select → admit │                               │
   │  → drive → next │──────────────────────────────┘
   └───────┬─────┬───┘
           │     │ escalation(e∈E)        (global e: E-BUDGET, E-RED-MAIN, E-UNCLASSIFIED)
  halt_req │     ▼
 (INV-22)  │  [report(e) → L+PubSub] ─▶ halting   (per-unit e: stay running, unit→escalated)
           ▼                              │ in-flight units reach clean checkpoint
       halting ◀─────────────────────────┘
           │ all units quiesced; main synced; ¬mid_merge
           ▼
        halted   (terminal; awaits operator / new milestone assignment)
```

The **loop** (the `running` state body) is the factory cycle reduced to control
logic: `select_next` (smallest shippable increment, FR-2.1) → `S.admit/1` (the
admission authority decides, §2) → drive the admitted unit's U-FSM → on
`unit_terminal(u, outcome)`, fold the outcome into L and `select_next` again.
K **never** implements; it *selects, admits, and classifies* (D-S1).

`running` is the only state that selects work. `halting` accepts no new
selection — it only drains in-flight units to a clean checkpoint, then
transitions to `halted`. This is the structural form of INV-22.

### 1.3 The total escalation set E (INV-18) as explicit transitions

`E` is closed and total (`../02-requirements/liveness.md`). K routes each
trigger through a **pure classifier**, `Tau.Factory.Escalation.classify/1`,
which returns exactly one `e ∈ E`. Every escalation is an explicit transition;
the catch-all guarantees totality.

```elixir
defmodule Tau.Factory.Escalation do
  @type e :: :ambiguity | :retry_exhausted | :conflict | :destructive
           | :budget | :red_main | :challenge | :unclassified
  @type scope :: :per_unit | :per_action | :global

  @spec classify(term()) :: {e(), scope()}
  def classify({:spec_ambiguity, _u}),        do: {:ambiguity, :per_unit}     # E-AMBIGUITY
  def classify({:retry_exhausted, _u}),       do: {:retry_exhausted, :per_unit} # E-RETRY-EXHAUSTED (INV-19)
  def classify({:merge_conflict, _u}),        do: {:conflict, :per_unit}      # E-CONFLICT
  def classify({:destructive_action, _a}),    do: {:destructive, :per_action} # E-DESTRUCTIVE (INV-20)
  def classify({:budget_exhausted, _}),       do: {:budget, :global}          # E-BUDGET   (INV-21)
  def classify({:main_red, _health}),         do: {:red_main, :global}        # E-RED-MAIN (INV-4)
  def classify({:challenges_exceeded, _u}),   do: {:challenge, :per_unit}     # E-CHALLENGE (>2 upheld)
  def classify(_anything_else),               do: {:unclassified, :global}    # E-UNCLASSIFIED catch-all
end
```

In K, each `e` is a guarded transition out of `running`:

```elixir
def running({:call, from}, {:escalation, trigger}, data) do
  {e, scope} = Tau.Factory.Escalation.classify(trigger)
  :ok = Tau.Factory.Ledger.record_escalation(data.ledger, e, scope, trigger) # CON-7, WAL before effect
  :ok = Phoenix.PubSub.broadcast(Tau.Factory.PubSub, "factory:escalation", {e, scope, trigger})
  case scope do
    :global ->
      {:next_state, :halting, halt_scope(data, :global), [{:reply, from, {:halt, e}}]}
    _per ->                                            # per-unit / per-action: unit→escalated, loop continues
      {:keep_state, mark_unit_escalated(data, trigger), [{:reply, from, {:escalated, e}}]}
  end
end
```

### 1.4 The totality argument (INV-18 proof obligation)

> **Claim.** No reachable state of K is simultaneously (a) not making progress
> and (b) not emitting exactly one `e ∈ E`.

*Argument.* The only state that can *fail to progress* is `running` (the loop):
`halting` always advances toward `halted` by draining; `halted` is a terminal
sink awaiting operator input (it is *progress-complete*, not non-progress). In
`running`, every inbound trigger that is **not** a normal loop event
(`unit_terminal`, `select_next`, `worker_event` U handles, kill at a boundary)
is fed to `Escalation.classify/1`. That function is **total over `term()`**: its
last clause `classify(_anything_else)` matches every value, returning
`{:unclassified, :global}`. Therefore there is *no* trigger value for which K
neither loops nor emits an `e`. The seven named clauses discharge the foreseen
non-progress causes; the catch-all `E-UNCLASSIFIED` discharges the unforeseen —
and its firing is itself logged as a defect signal (liveness.md). A
`gen_statem` event arriving in `running` with **no** matching clause crashes the
process — which is a supervised restart (LIV-5 resume from L), not a silent
livelock; the design preference is that the classifier's totality means this
crash path is unreachable for *non-progress* triggers.

**Totality over reachable *states*, not just over `classify/1`'s domain
(final-validation H-2).** The argument above shows every *trigger* maps to an
`e`; it must also be shown that every non-progress *state* eventually *produces* a
trigger — otherwise a unit could stall silently with K idle in `running` and no
event to classify (a wedged worker that never crashes is the witness). That gap
is closed structurally by U's **mandatory per-state timeouts + worker watchdog**
(§3.2): every U state that awaits an external actor arms a `:state_timeout`, and a
heartbeat-absence watchdog synthesizes a `worker_stalled` event. So a stall always
becomes a trigger within a bounded window, and the trigger is always classified.
The two facts together — *every reachable non-progress state emits a trigger* (U
timeouts) and *every trigger maps to exactly one `e`* (classifier totality) —
discharge INV-18. ∎

This is the single most important whole-system property (FR Axis-10): **the loop
can always either make progress or name exactly why it cannot.**

### 1.5 Kill switch (INV-22) — supervised, checked at unit boundaries

The kill is **not** a start-of-step file read (the current-repo anti-pattern,
`factory-loop.md` "do not reread"). It is a **supervised mechanism**: a small
`Tau.Factory.KillSwitch` (an owner that watches the operator sentinel — a file
*or* a control message — and emits a single PubSub event on
`"factory:control"`). K subscribes in `init/1` (PubSub is high in the tree,
`init/1`-subscribe-safe). The kill arrives as an event, but K **acts on it only
at a unit boundary**:

```elixir
def running(:info, {:control, :halt_requested}, data) do
  # Defer the halt until the current unit reaches its clean checkpoint.
  {:keep_state, %{data | halt_pending: true}}                 # postpone effect, not the event
end

def running({:call, from}, {:unit_terminal, u, outcome}, %{halt_pending: true} = data) do
  data = fold_outcome(data, u, outcome)                       # L write, WAL
  {:next_state, :halting, halt_scope(data, :global), [{:reply, from, :acknowledged}]}
end
```

A halt requested mid-unit sets `halt_pending`; the loop finishes the current
unit's terminal fold (its merge + post-merge sync, if any), then transitions to
`halting`. Worst-case latency is one unit (INV-22). `halting → halted` only
fires once `main` is synced and no merge is in flight (`¬mid_merge`) — the
`halting` state's drain logic asserts both before completing. Operator control
state lives on `"factory:control"`, never in project state (the sentinel path is
git-ignored).

### 1.6 Reporting cadence (D-S1 / FR-9.2)

K reports to the operator at exactly two points, via telemetry +
`"factory:report"` PubSub:

- **Milestone boundary** — when the assigned milestone's open-issue count
  (reconciled against L, CON-2) reaches zero (LIV-3). K reports completion and
  **awaits** the next milestone assignment; it does not auto-advance.
- **Escalation** — every `e ∈ E` fires a report (§1.3), with the reason and a
  durable state snapshot (CON-7).

No per-step checkpoint exists in `running` (D-S1). Numbers in reports are sourced
from telemetry (`total_tokens`, `duration_ms`), never estimated (FR-9.2).

---

## 2. S — Scheduler (`GenServer`, admission authority)

### 2.1 Why a GenServer

S is the **sole serialization point for admission decisions** (research §3): it
holds the mutable in-flight set `F` and decides admit/defer against it. The
mailbox *is* the serialization; two candidates cannot be admitted against a
stale view of `F`. It is **not** a god-process — the *decision logic* is the
pure `ConflictCheck` module (§2.3); S owns only `F`, the per-unit declared-scope
records, and the policy-version pins. K calls S with `call` (not `cast`): the
reply is the back-pressure on the control path (research §3 pitfall).

### 2.2 State and the admission predicate

```
S.state = %{
  inflight: %{unit_id => declared_scope},   # F: declared file+gating-test paths, SPECs, D-NNN
  pins:     %{unit_id => policy_version},    # HR-8 per-unit policy pin at admission
}
```

`admit(unit, declared_scope)` returns `:admit | {:defer, reason}`. The predicate
(system-architecture.md §1 S.δ):

```
admit(u) ⟺  ConflictCheck.clear?(declared(u), F)            # five clauses, HR-4
        ∧  budget_precheck(u) = :ok                          # INV-21, ETS snapshot
        ∧  fleet_headroom?(W_cap)                            # |F| < W_cap (§2.5)
```

`W_cap` is **not** the naïve `W*`. It is derived from measured gate-stage
utilization `ρ_g < 1 − margin` with `T_unit(W)` modeled *endogenously*
(system-architecture.md §5; sizing detail in `durable-spine.md`). Until measured,
S operates conservatively (small `W_cap`). Back-pressure is **routed to the
fleet**: when `fleet_headroom?` is false, S defers and the deficit propagates to
K's loop (no new select succeeds), not just to intake.

### 2.3 `Tau.Factory.ConflictCheck` — pure, properties before examples (HR-4)

The five-clause check (INV-13) over **declared** sets — never post-hoc actual
paths (that breaks LIV-4 monotonicity; system-architecture.md §7 "rejected").

```elixir
defmodule Tau.Factory.ConflictCheck do
  @moduledoc "Pure 5-clause admission predicate over DECLARED scope (HR-4, INV-13)."

  @type scope :: %{
          deps: MapSet.t(unit_id),       files: MapSet.t(path),
          gating_paths: MapSet.t(path),  codepoints: MapSet.t({path, region}),
          specs: MapSet.t(spec_id),      d_nnn: MapSet.t(d_id),
          resources: MapSet.t(resource)  # non-worktree mutable resources it will touch
        }

  @spec clear?(scope(), %{unit_id => scope()}) :: boolean()
  def clear?(cand, inflight), do: Enum.all?(inflight, fn {_id, v} -> pairwise_clear?(cand, v) end)

  @spec pairwise_clear?(scope(), scope()) :: boolean()
  def pairwise_clear?(a, b) do
    no_dependency?(a, b) and disjoint_files?(a, b) and disjoint_codepoints?(a, b)
      and disjoint_spec_dnnn?(a, b) and resource_isolatable?(a, b)
  end

  defp disjoint_files?(a, b),
    do: MapSet.disjoint?(MapSet.union(a.files, a.gating_paths),     # gating-test paths are a shared collision surface
                         MapSet.union(b.files, b.gating_paths))
  # … no_dependency?, disjoint_codepoints?, disjoint_spec_dnnn?, resource_isolatable? …
end
```

**Properties (StreamData), authored before any example test** (OTP
non-negotiable #6, FR-4 oracle discipline):

- **P-CC-1 (symmetry).** `pairwise_clear?(a, b) ⟺ pairwise_clear?(b, a)` for all
  scopes — admission order must not change the verdict.
- **P-CC-2 (self-conflict).** A non-trivial scope never clears against itself:
  `files(a) ≠ ∅ ⟹ ¬pairwise_clear?(a, a)`.
- **P-CC-3 (monotone in `F`).** Adding a unit to `F` can only *remove* admissions:
  `clear?(c, F ∪ {v}) ⟹ clear?(c, F)` (the LIV-4 monotonicity lever — a deferred
  unit keeps its place, and a smaller `F` never *forbids* what a larger `F`
  allowed).
- **P-CC-4 (each clause is necessary).** For each clause `cᵢ`, ∃ a witness pair
  failing only `cᵢ` and otherwise clear — no clause is redundant.
- **P-CC-5 (gating-path collision).** Two scopes sharing any gating-test path
  never clear (encodes the new shared-`test/support` collision surface).

### 2.4 How declared-scope admission resolves the INV-13 / LIV-4 dilemma

The dilemma: a *post-hoc* conflict check on **actual** changed paths cannot be
monotone — a unit could be admitted, then discovered to conflict only after it
writes, forcing a withdraw → re-admit cycle (livelock; LIV-4 falsified). HR-4's
resolution is to check **declared** scope at admission time, so the verdict is a
pure function of declarations fixed *before* any worker runs (FR-1.3 frozen
scope). Monotonicity (P-CC-3) then holds by construction: a deferred unit's place
is stable; it admits as soon as its blocker terminates and leaves `F`.

The escape valve for the inevitable "declaration was wrong" case is the
**scope-amendment → re-admission** path: if the **test-author exceeds its
declared gating-test paths** (or an implementer's frozen scope must grow), that
is *not* a silent in-flight mutation — U emits a `scope_amendment`, the unit is
**withdrawn from `F` and re-submitted to S** with the amended declaration, which
re-runs `ConflictCheck` against the *current* `F`. Re-admission is a fresh,
monotone decision; there is no in-flight scope drift, and INV-13 holds against
the *amended* declaration. This is the structural reading of `factory-loop.md`'s
"scope growth becomes a separate PR or a deliberate, logged re-plan".

### 2.5 Budget pre-check (INV-21) and monotone admission (LIV-4)

`budget_precheck(u)` reads the **budget ETS snapshot directly** (not via a
`GenServer.call` to L's `Budget.Owner` — reads bypass the owner mailbox;
research §8, supervision-tree.md Step 4). The snapshot is owned by
`Budget.Owner` high in the tree and rebuilt from SQLite truth on owner restart.
Admission is denied at the ceiling **before** the unit becomes billable (FC-6).
Admission is **monotone** (LIV-4): a `{:defer, _}` never demotes a unit's
queue position; S serves deferred units in arrival order with aging once their
blocker clears (the fairness analogue of M's merge queue, Q-L1).

---

## 3. U — Unit/PR FSM (`gen_statem` per entity)

### 3.1 One owner of the PR lifecycle

U is **one** `gen_statem` per PR, owning the *entire* PR lifecycle — this
deliberately fixes the authority-split FATAL (system-architecture.md §7:
smearing the lifecycle across ~15 writers produced a distributed transaction and
a value-stale verdict read). The lifecycle owner is singular; verdicts it reads
are *append-only* from L (HR-2). U is `:temporary` under `UnitSupervisor`
(`DynamicSupervisor`, `one_for_one`) and addressed by key via `UnitRegistry`
(§4) — never by pid.

### 3.2 States and legal transitions (illegal ones unrepresentable)

```
state ∈ {planned, oracle, implementing, gating, refine_k, awaiting_merge, merged, escalated}

  planned ──admit(S)──▶ oracle ──test-author frozen (INV-5)──▶ implementing
                                                                  │
                            work_ready(w,branch,head_sha) ⇒ request_gate
                                  (D-326: in-band success signal; NOT exit 0)
                                                                  ▼
                                                               gating
                          ┌──────────── gate FAIL (FR-8.2, an OUTCOME) ──────────┐
                          ▼                                                       │
   gate PASS          refine_k ──k<N (HR-8 clamp)──▶ implementing                │
        │             (durable k)─k=N──▶ pivot (fresh diff)──▶ implementing      │
        ▼                          └──pivot also red──▶ escalated  (E-RETRY-EXHAUSTED)
  awaiting_merge ──M merged──▶ merged   (terminal, exits :normal)
        │
        └── M reject (stale/revoked verdict, ref moved) ──▶ gating   (re-gate, INV-2)

  any non-terminal ──escalation(e)──▶ escalated   (terminal)
```

Legality is encoded as the presence/absence of `gen_statem` clauses
(`state_functions` mode). `gating` has **no** clause that transitions directly
to `merged` — "merge from a non-`awaiting_merge` state" is therefore
*unrepresentable*; an attempt crashes the FSM rather than silently merging an
ungated diff (research §2; INV-1). `merged` and `escalated` are terminal sinks
with no outbound clauses.

```elixir
defmodule Tau.Factory.Unit do
  @behaviour :gen_statem
  def callback_mode, do: :state_functions

  # gate verdict arrives in :gating — the ONLY legal place to consume it
  def gating(:info, {:gate_outcome, :pass}, data) do
    {:next_state, :awaiting_merge, data, [{:next_event, :internal, :request_merge}]}
  end
  def gating(:info, {:gate_outcome, {:fail, findings}}, data) do
    # SEMANTIC failure = an OUTCOME transition here, NOT a crash/restart (FR-8.2)
    case Tau.Factory.Retry.next(data.k, data.attempt_kind, data.policy_pin) do
      {:refine, k} -> {:next_state, :refine_k, snapshot(%{data | k: k, findings: findings})}
      :pivot       -> {:next_state, :implementing, snapshot(pivot_reset(data))}
      :exhausted   -> escalate(data, {:retry_exhausted, data.unit_id})   # E-RETRY-EXHAUSTED
    end
  end

  # MANDATORY state-timeout on EVERY state that awaits an external actor.
  # A wedged-but-not-crashed worker (Port alive, no :exit_status, no :DOWN) emits
  # NO trigger — so the timeout is what synthesizes one (final-validation H-2).
  def oracle(:state_timeout, :stall, data),         do: stall_escalate(data, :oracle)
  def implementing(:state_timeout, :stall, data),   do: stall_escalate(data, :implementing)
  def gating(:state_timeout, :stall, data),         do: stall_escalate(data, :gating)
  def awaiting_merge(:state_timeout, :stall, data), do: stall_escalate(data, :awaiting_merge)

  # Each waiting state arms the timeout on entry; progress heartbeats reset it.
  defp enter_waiting(state, ms, data),
    do: {:next_state, state, data, [{:state_timeout, ms, :stall}]}

  # A wedged worker is first a SEMANTIC stall (refine/pivot on a fresh worker),
  # escalating to E-* only if the stall persists past the retry ladder.
  defp stall_escalate(data, _state) do
    case Tau.Factory.Retry.next(data.k, data.attempt_kind, data.policy_pin) do
      {:refine, k} -> {:next_state, :refine_k, snapshot(%{data | k: k, stalled: true})}
      :pivot       -> {:next_state, :implementing, snapshot(pivot_reset(data))}
      :exhausted   -> escalate(data, {:retry_exhausted, data.unit_id})  # → E-RETRY-EXHAUSTED
    end
  end
end
```

**Two complementary liveness guards close every non-progress state (H-2):**

1. **Per-state timeout (above).** `oracle`, `implementing`, `gating`, and
   `awaiting_merge` each arm a `{:state_timeout, ms, :stall}` on entry, reset by
   worker progress heartbeats. A stall (including a silently-wedged worker that
   never crashes) fires the timeout → the retry ladder → escalation. No waiting
   state can sit forever without emitting a trigger.
2. **Worker watchdog.** The worker (`worker-fleet.md`) emits periodic progress
   events over its `Port`; a `WorkerSupervisor`-side watchdog converts *absence*
   of heartbeats beyond a threshold into a synthetic `worker_stalled` event to U
   — covering the case where the Port is alive but the sub-agent is hung (no
   `:DOWN` would ever fire). This is the missing trigger source the bare monitor
   cannot provide.

Together these guarantee the property INV-18 totality actually needs: **every
reachable non-progress state eventually produces a trigger**, which the
classifier (§1.4) then maps to exactly one `e ∈ E`. Totality over `classify/1`'s
domain is necessary but not sufficient on its own; the mandatory timeouts make it
sufficient over reachable *states*.

### 3.2.1 The `implementing ──request_gate──▶ gating` trigger (D-326)

The `implementing → gating` edge has exactly **one** trigger: a `work_ready`
*work-product-ready* event the agent emits **in-band over its `Port`**, decoded
to a typed struct (`worker-fleet.md` §4 — `dispatch(decode_event(frame), st)`),
and surfaced by the worker to its owning U keyed by `worker_id`:

```elixir
# implementing: the ONLY legal completion trigger is the in-band work_ready event.
def implementing(:info, {:work_ready, w, branch, head_sha}, %{worker_id: w} = data) do
  # The agent has declared a stable diff; verify it is non-empty before gating
  # (a clean exit conflates "did the work" with "ran and pushed nothing" — V1).
  {:next_state, :gating, %{data | branch: branch, head_sha: head_sha},
   [{:next_event, :internal, :request_gate}]}
end
# A work_ready from a SUPERSEDED worker (stale worker_id) is discarded, not gated.
def implementing(:info, {:work_ready, _other, _b, _s}, data), do: {:keep_state, data}
```

Three keyed-by-`worker_id` worker triggers are **disjoint** and U distinguishes
them structurally (the `worker_event` family of system-architecture.md §1, U
`E_in`):

| trigger | meaning | U action |
|---------|---------|----------|
| `work_ready(w, branch, head_sha)` | agent declared a **stable diff** (success) | → `gating` (`request_gate`) |
| `worker_exit(w, reason)` (`:DOWN`) | worker/agent **crashed or exited** | infra path → `escalated`; gate NOT called (FR-8.2) |
| `worker_stalled(w)` | watchdog saw **heartbeat absence** (wedged, no `:DOWN`) | retry ladder (semantic stall) → refine/pivot/escalate |

**Why a clean Port exit is NOT the completion trigger (the load-bearing
decision).** The discriminating question is operational: *can a normally-exiting
agent ("did the work, pushed a real diff") be distinguished from a no-op exit
("ran, pushed nothing") and from a crash that happens to exit 0, by exit status
alone?* It cannot — `:exit_status 0` is a single bit that conflates all three.
Trusting it would let U fire `request_gate` on an **empty or absent diff**, and
the gate's mutation check (D-306, "≥1 gating test fails on the reverted tree")
silently degenerates when there is no production change to revert — a false-green
path into merge. The in-band `work_ready(branch, head_sha)` frame carries the
**evidence** (the branch and head SHA the agent pushed) U needs to confirm the
diff is real *before* gating; exit status remains only the `worker_exit`
death-certificate input, never a success signal. This mirrors the existing
in-band `{:coding_agent_event, pid, %Event.Done{}}` contract in `Tau.Session`:
completion is a typed event the agent *asserts*, never an exit code the harness
*infers* (D-326; OTP non-negotiable — extend `Tau.Provider.Event`, never scrape).

### 3.3 Bounded retry ladder (INV-19, HR-8 clamp)

The ladder is a **pure decision function**, `Tau.Factory.Retry.next/3`; `N` is
the policy-pinned refine bound, **clamped** by the engine
(`N = min(policy_N, ceiling)`; ∞ rejected — HR-8, detail in `governance.md`).
The attempt count `k` is **durable PR-process state** (snapshotted to L on every
transition; INV-19 enforcer is "attempt count is durable").

```elixir
defmodule Tau.Factory.Retry do
  @spec next(non_neg_integer(), :refine | :pivot, policy()) ::
          {:refine, pos_integer()} | :pivot | :exhausted
  def next(k, :refine, %{n_refine: n}) when k + 1 <= n, do: {:refine, k + 1}
  def next(_k, :refine, _policy),                       do: :pivot       # refines exhausted → pivot once
  def next(_k, :pivot, _policy),                        do: :exhausted   # pivot also red → E-RETRY-EXHAUSTED
end
```

`refine_k` stays on the **same draft PR / same diff base**; `pivot` opens a
**fresh diff** (resets the refine count, materially different approach). A failed
pivot is terminal → `escalated` with `E-RETRY-EXHAUSTED`. This bounds the ladder
at `N_refine + N_pivot` (INV-19) and guarantees `LIV-1` (exhausting the ladder
*is* a transition to `escalated`).

### 3.4 Semantic failure vs infrastructure crash (FR-8.2) — the decisive split

| Event class | Example | Mechanism | U's response |
|-------------|---------|-----------|--------------|
| **Semantic failure** | gate FAIL, bad LLM output, model refusal | **a transition in U** | refine/pivot/escalate (§3.3) — *never* a supervisor restart |
| **Infrastructure crash** | worker `:DOWN`, gate-task crash, OOM | a monitored process exit | U handles the `:DOWN` *as an event*; W captures-before-destroy; U decides outcome |

A gate FAIL is data U consumes (a `:gate_outcome` message), **not** a process
crash — encoding it as a crash would crash-loop and burn tokens (research §10,
the dominant BEAM-for-agents mistake). Conversely, a worker crash is an
*infrastructure* event: U holds a `Process.monitor/1` ref on its worker and
receives `{:DOWN, ref, :process, _pid, reason}`. U does **not** restart the
worker (the `DynamicSupervisor` is `:temporary` — a death-certificate issuer, not
a resurrector; supervision-tree.md Step 3). Instead U treats the exit as an
*outcome*: W has already captured staged+unstaged+untracked (INV-14, FC-2), and U
chooses refine/pivot on a fresh worker. The supervisor recovers *infrastructure*;
U recovers *semantics*.

```elixir
def implementing(:info, {:DOWN, ref, :process, _pid, reason}, %{worker_ref: ref} = data) do
  # infrastructure crash — NOT a restart; W has captured dirty state (INV-14/15)
  {:next_state, :refine_k, snapshot(%{data | last_crash: reason})}
end
```

### 3.5 Challenge protocol (FR-4.4, E-CHALLENGE)

An implementer may challenge a gating test **only** when it contradicts a SPEC §4
contract (not because it is hard). U is the router; it **never** adjudicates
(adjudication by the coordinator's own judgement is forbidden — FR-4.4):

1. U receives `{:challenge, test, spec_clause}` from its worker. U **stops** the
   implementer on that point and routes the challenge to an **independent critic**
   (a read-only oracle spawned under the gate fan-out, *not* K, *not* the same
   critic that gated — `gate-and-toolchain.md`).
2. The critic rules **upheld** (test contradicts the contract) or **rejected**
   (implementer must comply). U **logs the ruling to L** (durable; CON-7).
3. If **upheld**: the *test-author* corrects the test (the implementer may not —
   INV-6), and the mutation gate re-runs against the corrected test.
4. U counts upheld challenges. On the **3rd upheld** (`> 2`), U escalates
   `{:challenges_exceeded, unit_id}` → **E-CHALLENGE** (weak oracle / underspecified
   SPEC; safety-circuit condition).

```elixir
def implementing(:info, {:challenge, test, clause}, data) do
  ruling = Tau.Factory.Gate.adjudicate_challenge(test, clause)   # independent critic, not U
  data   = log_challenge(data, test, clause, ruling)            # → L, CON-7
  case {ruling, data.upheld} do
    {:upheld, n} when n + 1 > 2 -> escalate(data, {:challenges_exceeded, data.unit_id})
    {:upheld, n}                -> {:keep_state, %{data | upheld: n + 1}}  # test-author corrects
    {:rejected, _}              -> {:keep_state, data}                     # implementer complies
  end
end
```

### 3.6 Per-transition snapshot to L (couples to `durable-spine.md`)

Every U transition `snapshot/1`s the unit's durable state — `{state, k,
attempt_kind, frozen_scope, policy_pin, upheld_challenges, last_verdict_hash}` —
to L **transactionally, before the transition's external effect is visible**
(write-ahead; INV-16, RPO=0). On a coordinator restart (LIV-5), `UnitSupervisor`
re-reads the durable unit rows and **rehydrates each U at its saved state**, so a
restart resumes *exactly* — no unit double-processed, none lost (FC-1). The
snapshot must be transactional with the side-effect (the merge, the verdict): a
crash *between* act and snapshot is guarded by an idempotency key (PR number +
merge SHA) checked on resume (research §13 pitfall). The mechanism (Oban-backed
spine + thin rehydratable FSM) is detailed in `durable-spine.md`.

---

## 4. Identity — address by key, never pid

Per supervision-tree.md Step 4:

- **U** is registered `{:via, Registry, {Tau.Factory.UnitRegistry, unit_id}}`;
  **W** (workers) via `{Tau.Factory.WorkerRegistry, worker_id}`. Lookup-or-start
  is race-safe through the registry's uniqueness guarantee (handle
  `{:error, {:already_started, pid}}`).
- **No pid is ever stored as identity** in L or in any durable record — a stored
  pid is a dangling pointer after restart (research §4). Durable state holds the
  *key*; the process is re-resolved through the registry on resume.
- U → W relationship: U **holds a `Process.monitor/1` ref** on its worker for
  *liveness only* (the `:DOWN` in §3.4). The monitor ref is not identity — U
  re-resolves the worker by `worker_id` through `WorkerRegistry` if it must
  re-address it. This keeps the FSM rehydratable: on restart, U re-resolves and
  re-monitors by key, never by a stale pid.

---

## 5. K · S · U interaction — PubSub + monitored refs, and where `call` matters

Cross-process events use `Phoenix.PubSub` or monitored refs — **never `:global`,
never `Process.whereis |> send`** (OTP non-negotiable #4; research §6).

| Edge | Mechanism | Why `call` vs `cast` / PubSub |
|------|-----------|-------------------------------|
| K → S `admit(unit, scope)` | `GenServer.call` | **`call`** — the admit/defer reply *is* back-pressure on the control path; a `cast` would let K outrun S's view of `F` (research §3). |
| K → U drive / S → U admitted | `gen_statem` event (`call` for the synchronous handshake) | **`call`** on the control path; the reply gates K's next select. |
| U → G `request_gate` | monitored `Task` (gate fan-out) + result message | `async_nolink` + monitor: a gate-task crash is *data* (a `:DOWN`), not a cascade into U (research §5). |
| U → M `request_merge` ; M → U `merge_result` | `cast`/enqueue to MergeAuthority **+ async result on PubSub `"factory:pr:#{id}"`** | **NOT a blocking `call`** — M is concurrency-1 and a single integration is a *minutes-long* merge-train build; a synchronous `call` across it would block U (and pin a caller process) for the whole build and risk a `call` timeout misclassifying "still merging" as failure (final-validation H-1b). U enqueues the request, then `awaiting_merge` consumes `{:merge_result, :merged \| :rejected}` from the per-PR PubSub topic; M's reply *is* the back-pressure, decoupled. A `:rejected` (stale/revoked verdict, ref moved) re-gates (INV-2). |
| U → W spawn / `work_ready` / `:DOWN` | `DynamicSupervisor.start_child` + `Process.monitor` + in-band `Port` event | monitored ref for point-to-point liveness (the `:DOWN` → `worker_exit`, §3.4); the **success** trigger `work_ready(w, branch, head_sha)` arrives as a decoded in-band `Port` event keyed by `worker_id` (§3.2.1, D-326) — never inferred from exit status. |
| K/U/M → L record/verdict/debit | `GenServer.call` to the single writer | **`call`** — WAL-before-ack; a `cast` would risk losing a decision on crash (INV-16). |
| any → K `escalation` | `GenServer.call` (or PubSub for fan-out notice) | **`call`** for the control decision; PubSub `"factory:escalation"` for the *observer* fan-out (dashboard, OTel). |
| KillSwitch → K | PubSub `"factory:control"` | a *fan-out* control signal K consumes at a unit boundary (§1.5); not request/reply. |
| reports, gate verdicts, merge events | PubSub topics (`"factory:pr:#{id}"`, `"factory:report"`) | fan-out to observers (LiveView, OTel, solution-tree projector); decoupled from the control path. |

**Rule of thumb (research §3):** the control path is `call` (the reply is
back-pressure); the *observation* plane is PubSub (decoupled fan-out); liveness
is monitored refs (`:DOWN`). Reads of hot shared state (budget/policy snapshots)
**bypass owner mailboxes** entirely via ETS (§2.5; research §8).

---

## 6. Traceability — which control-plane process enforces what

| Requirement | Enforcer in this file | § |
|-------------|------------------------|---|
| INV-13 conflict-gated concurrency | S + `ConflictCheck` (declared sets, HR-4) | 2.3–2.4 |
| INV-18 total escalation | K + `Escalation.classify/1` (catch-all totality) | 1.3–1.4 |
| INV-19 bounded retry | U + `Retry.next/3` (N clamped, durable k) | 3.3 |
| INV-21 budget ceiling (pre-check) | S `budget_precheck` (ETS snapshot) | 2.5 |
| INV-22 clean kill | K `halt_pending` at unit boundary | 1.5 |
| FR-8.2 semantic≠infrastructure | U: gate FAIL = transition; `:DOWN` = event | 3.4 |
| FR-4.4 / E-CHALLENGE | U routes to independent critic; >2 upheld escalates | 3.5 |
| LIV-4 no livelock | S monotone admission (P-CC-3); amendment re-admits | 2.4–2.5 |
| LIV-5 recovery progress | U per-transition snapshot; rehydrate by key | 3.6, 4 |
| INV-16 durable decisions | `call`-to-single-writer, WAL before ack | 5 |

No row is orphaned; each maps to a named process boundary or pure predicate, per
the traceability obligation (R-list.md).
