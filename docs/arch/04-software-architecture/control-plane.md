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
admit(u) ⟺  ConflictCheck.clear?(declared(u), F ∖ {u})      # five clauses, HR-4; SELF-EXCLUDED (D-380)
        ∧  budget_precheck(u) = :ok                          # INV-21, ETS snapshot
        ∧  fleet_headroom?(|F ∖ {u}| < W_cap)                # capacity over F∖{u} (§2.5)
```

**Self-exclusion (D-380, #515).** The conflict and capacity checks evaluate over
`F ∖ {unit_id}`, never the raw `F` — a unit can never conflict with its own
in-flight entry. This is the structural reason (a) a single unscopable unit
(the `universal_conflict` sentinel, §2.6.D-371) admits against its excluded-empty
`F'` instead of self-conflicting, and (b) the §2.4 scope-amendment re-admit of an
already-present unit is **idempotent** (returns `:admit`, replaces the scope). The
exclusion is an **S-level set operation** keyed by `unit_id`; `ConflictCheck` (C5)
stays unit-id-agnostic and keeps P-CC-2 (a non-trivial *scope* self-conflicts).

**Single admission authority (D-380, #515).** `admit/3` has **exactly one** caller
— the Unit FSM `planned` state, which holds the real `declared_scope`. K
**selects and drives** but MUST NOT admit. An early implementation had K admit with
an `@empty_scope` placeholder *and* the Unit admit with the real scope — a
**double admission of one unit against one Scheduler**: the empty-scope `F` entry
both blinded other units' conflict checks (a soundness hole, the dual of the
under-declaration in §2.6) and made the Unit's real-scope admit self-conflict via
the sentinel (the first-real-run wedge). One unit, one admit, by the authority
that holds the real scope.

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
"scope growth becomes a separate PR or a deliberate, logged re-plan". The
re-admit is **idempotent** by §2.2's self-exclusion (D-380): because the check
runs over `F ∖ {unit_id}`, a re-submitted unit never conflicts with its *own*
prior `F` entry — even if the withdraw step has not yet landed — so the amended
admit is decided purely against the *other* in-flight units.

### 2.5 Budget pre-check (INV-21) and monotone admission (LIV-4)

`budget_precheck(u)` reads the **budget ETS snapshot directly** (not via a
`GenServer.call` to L's `Budget.Owner` — reads bypass the owner mailbox;
research §8, supervision-tree.md Step 4). The snapshot is owned by
`Budget.Owner` high in the tree and rebuilt from SQLite truth on owner restart.
Admission is denied at the ceiling **before** the unit becomes billable (FC-6).
Admission is **monotone** (LIV-4): a `{:defer, _}` never demotes a unit's
queue position; S serves deferred units in arrival order with aging once their
blocker clears (the fairness analogue of M's merge queue, Q-L1).

### 2.6 Where the declared scope comes from — issue → `ConflictCheck.scope()` (I2; D-369/D-370/D-371)

§2.3's five-clause check operates over a `declared_scope :: ConflictCheck.scope()`
(`%{deps, files, codepoints, specs, resources}`). §2.4 assumes that scope already
exists, *frozen, at admission time* (FR-1.3). **It does not say how a real issue's
text becomes that map.** `IssueSelector` (B10) is the intake that closes this gap:
it elaborates an open milestone issue into the structured scope the Scheduler
admits on. This subsection records the elaboration contract and its soundness
posture; the boundary detail is SPEC-FACTORY-CORE §4 B10 (PR #505 amendment).

**The soundness dependency (the load-bearing fact, V3).** `ConflictCheck` is the
*sole enforcer* of conflict-gated concurrency (INV-13), but it is a pure function
of *what it is told*. A scope that **under-declares** — omits a file two units
actually share — clears them as disjoint, and S admits both in parallel; they
then corrupt the omitted shared file. So the safety of the *check* is conditional
on the soundness of the *elaboration*, and free issue text cannot be turned into a
provably-complete impact set (V1 — the static-impact-analysis impossibility). The
design does not pretend otherwise. Instead it makes incompleteness *safe* by
construction through **directional soundness**:

- **Over-declare, never under-declare.** Uncertain membership → *include*. A false
  inclusion costs only a needless `{:defer, …}` (a unit serialises that could have
  parallelised — cheap, reversible). A false exclusion costs *correctness* (a
  missed conflict — a corrupting defect). The asymmetry dictates the bias:
  *serialize when unsure*.
- **Coarsen codepoints to whole files absent a `file:line` citation.** The
  parallel-on-disjoint-regions optimisation (§2.3 `disjoint_codepoints?`) is taken
  **only** where the issue cites `file:line`/`file#function` (the human author
  discharges the burden of proof). Otherwise the unit serialises against anything
  touching the file.
- **Serialize-on-unscopable fallback.** An issue too vague to yield any file or
  SPEC elaborates to a *universal-conflict sentinel scope* that fails
  `pairwise_clear?` against any non-empty in-flight member — admitted only into an
  empty `F`, never silently disjoint-from-everything.

This preserves §2.4's monotonicity (D-343): the elaborated scope is still a *fixed
declaration*, frozen before any worker runs — no post-hoc actual-path check is
introduced.

**The discriminating question — heuristic vs LLM vs required-template — and why a
heuristic is the default.** The fact that decides the mechanism is *who can be
held to soundness*: an LLM elaboration is unsound by nature (it omits or
hallucinates and cannot be audited on the synchronous admission path); a
required issue-template scope field shifts the burden to the human author but is
still unverifiable; a citation-driven heuristic over signals already in the
`issue_map` (`title`/`body`/`labels`) and the in-repo SPEC source-maps is the
**cheapest-to-reverse** shape that makes incompleteness *safe* rather than
*trusted*. The heuristic is therefore the default elaborator (D-369). It is
reached through an **injected pure seam** `:elaborate_fun :: (issue_map ->
ConflictCheck.scope())` (D-370), so a stronger LLM-assisted elaborator — gated
behind an out-of-band verification step, never trusted blindly — remains a
*substitution*, not a rewrite of `Scheduler`/`ConflictCheck`, if scope precision
ever justifies its cost. **Coupling to #492** (real `gh issue list`) is by
reference only: elaboration consumes the `issue_map` regardless of source; #492
populates real fields the `--json number,title,body,labels` projection already
names.

**Closing a latent type error.** Before this contract, `IssueSelector` emitted
`scope` as the string `"#{number}: #{title}"`, which `ConflictCheck.clear?/2`
would crash on (`Map.fetch!(string, :files)`). The seam was sound only because no
test wired a real string-scope work-item into a real Scheduler. The elaboration
makes `IssueSelector → Scheduler → ConflictCheck` type-correct on a real issue
(SPEC-FACTORY-CORE [C124-B10]).

### 2.7 Where the agent's prompt comes from — issue → `task.prompt` (A2; D-372/D-373)

§2.6 projects the issue onto the *Scheduler's* admission predicate (a
`ConflictCheck.scope()`). This subsection records the **disjoint, parallel
projection** onto the *agent's* task: the issue (and its full context) → the shim's
`Tau.CodingAgent.task.prompt :: String.t()`. It is the autonomous analogue of the
human coordinator's draft-PR-body implementer brief (`factory-loop.md`): without
it, a real agent (A1, `Tau.CodingAgents.ClaudeCode`) is handed an empty prompt and
has nothing to solve. The boundary detail is SPEC-FACTORY-CORE §4 B10 (PR #508
amendment); the D-NNN are D-372/D-373.

**The gap (V3, an orphaned input).** The `work_item` already carries every input a
brief needs — the `issue_map` (body/labels), the elaborated `declared_scope`
(§2.6), and downstream the test-author's gating-test paths and the cited SPEC/AC/
D-NNN. Yet `to_unit_work_item/1` sets `brief: title` and the shim hardcodes
`task.prompt = ""`. The brief crossing **loses everything but the title**: the
inputs exist but no component composes them into the prompt. The `BriefAssembler`
is the intake component that consumes those inputs (V3 — every stated input is
actually consumed; V12 — no machinery that enforces nothing).

**The composition contract (D-372).** The default assembler emits a labelled,
section-structured Markdown prompt with one section per input — issue body,
declared scope, gating-test paths, SPEC/AC/D-NNN refs — **plus a mandatory
arch-pointer section** carrying at least the `docs/arch/04-software-architecture/`
root. The arch section is non-negotiable: Tau memory
`feedback_brief_implementers_with_arch` requires pointing agents at the worked-out
architecture, not only SPEC §-refs. Every *present* input appears, labelled; an
*absent* optional input degrades to an explicit "(none declared)" placeholder — a
missing input never crashes the assembler and never silently drops its section.

**The discriminating question — static template vs richer assembly vs LLM, and why
a heuristic template is the default (the cheapest-to-reverse decision, mirroring
§2.6/D-370).** The fact that decides the mechanism is the same one that decided the
elaborator: *who can be held to the contract on the synchronous intake path*. An
LLM prompt author is unauditable and network-bound on a path that must be fast and
deterministic; a static template over inputs already in the `work_item` is pure,
testable with fixtures, and complete-over-its-inputs by construction. The heuristic
template is therefore the default (D-372), reached through an **injected pure seam**
`:assemble_fun :: (input -> String.t())` (D-373) — the established `*_fun` pattern —
so a stronger, separately-verified LLM prompt author is a *substitution*, not a
rewrite of `Supervisor`/`UnitDriver`/`Worker`, if prompt quality ever justifies the
cost. This is the exact shape §2.6 chose for `:elaborate_fun`, applied to the
prompt projection.

**No impossibility hidden here (V1).** Unlike the elaborator — where free issue
text cannot yield a *provably complete* impact set, forcing the over-declare bias —
the assembler has no completeness obligation to fake: it composes the inputs it
*has*; it does not infer inputs it lacks. Partial inputs are a *normal* state
(early-phase issues, no gating-test paths yet), handled by graceful degradation,
not an error. For any non-empty issue the assembler returns a non-empty prompt.

**Invocation point and the unchanged downstream path.** `to_unit_work_item/1`
(`supervisor.ex`) is the single assembly site; it swaps `brief: title` for
`brief: BriefAssembler.assemble(%{issue: issue, declared_scope: scope, …})`. The
assembled brief rides the *existing* `UnitDriver → WorkerSupervisor → Worker → shim`
path unchanged — no new boundary. A2 owns the assembler and the contract that
`task.prompt` equals the assembled brief.

**The consumer side — delivery across the Worker↔shim Port (D-381, #515).** A2
gets the brief as far as the Worker's `:brief`, but the **first real-`claude` run
showed the brief stops there**: the shim baked only adapter+branch (`agent_bin` is
resolved **once** at supervisor setup, `AgentBin.resolve/1`, D-376) and hardcoded
`task.prompt = ""`, so the real agent ran `claude -p ""`. The per-unit prompt
therefore cannot be a shim-write-time bake; it must cross the *existing* B4 `Port`
boundary at *spawn* time. The cheapest-to-reverse seam (V3, mirroring why A1 chose
the Port-shim over an in-process drive) is an **environment variable**:
the Worker — which is per-unit and already builds a per-spawn `:env` list — sets
`TAU_AGENT_PROMPT = brief` at `Port.open`, and the shim's `Runner.main/1` reads it
into `task.prompt`. Rejected: baking the brief per-unit by moving `AgentBin.resolve/1`
to unit-spawn time (a per-unit shim rewrite; re-homes the one-time `agent_bin`
construction). The delivery is **orthogonal to the #509/D-374 metered-spend scrub**
— that scrub removes only the three `ANTHROPIC_*` keys; `TAU_AGENT_PROMPT` is task
data, never a credential, and is never scrubbed. The boundary detail is
SPEC-FACTORY-FLEET §4 B4-A1 ("Prompt delivery"); the invariant is D-381.

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
  #
  # Worker-awaiting states (oracle/implementing): the OWN :state_timeout fires only
  # on TOTAL heartbeat silence (D-377 re-arms it on every progress pulse), so it is
  # the HARD-stall path → escalate E_WORKER_STALLED directly (NOT the retry ladder;
  # preserves #490/D-326). The event-message worker_stalled/worker_exit signals
  # (below) are the retryable path. (D-378 two-outcome split, by source.)
  def oracle(:state_timeout, :stall, data),         do: escalate(data, {:worker_stalled, data.unit_id}) # → E_WORKER_STALLED
  def implementing(:state_timeout, :stall, data),   do: escalate(data, {:worker_stalled, data.unit_id}) # → E_WORKER_STALLED
  # Non-worker waiting states keep the gate/merge-stall semantics unchanged.
  def gating(:state_timeout, :stall, data),         do: stall_escalate(data, :gating)
  def awaiting_merge(:state_timeout, :stall, data), do: stall_escalate(data, :awaiting_merge)

  # Each waiting state arms the timeout on entry; progress heartbeats reset it.
  defp enter_waiting(state, ms, data),
    do: {:next_state, state, data, [{:state_timeout, ms, :stall}]}

  # D-377 — heartbeat-driven liveness: a current-worker progress pulse RE-ARMS
  # the waiting-state timeout, so a progressing real agent never trips the cap.
  # The cap is thus a per-heartbeat *inactivity deadline*, not a run-duration cap.
  def oracle(:info, {:worker_heartbeat, w}, %{worker_id: w} = data),
    do: {:keep_state, data, [{:state_timeout, data.state_timeout_ms, :stall}]}
  def implementing(:info, {:worker_heartbeat, w}, %{worker_id: w} = data),
    do: {:keep_state, data, [{:state_timeout, data.state_timeout_ms, :stall}]}
  # A heartbeat from a SUPERSEDED worker does not re-arm (B8 stale-worker discard).
  def oracle(:info, {:worker_heartbeat, _other}, data),       do: {:keep_state, data}
  def implementing(:info, {:worker_heartbeat, _other}, data), do: {:keep_state, data}

  # D-378/D-379 — ONE symmetric rule for BOTH worker-awaiting states. The two
  # EVENT-MESSAGE stall-class signals — the Watchdog's heartbeat-absence
  # {:worker_stalled, w} and the dispatcher's semantic death-cert {:worker_exit,
  # w, reason} — route to the SAME retry ladder, which re-enters the ORIGINATING
  # waiting state (oracle→oracle re-runs the test-author; implementing→implementing
  # re-runs the implementer). The first signal clears worker_id so later stall
  # events for the now-superseded id are stale-discarded (D-378 exactly-once).
  def oracle(:info, {:worker_stalled, w}, %{worker_id: w} = data),
    do: advance_retry_ladder(:oracle, clear_worker(data))
  def implementing(:info, {:worker_stalled, w}, %{worker_id: w} = data),
    do: advance_retry_ladder(:implementing, clear_worker(data))
  def oracle(:info, {:worker_exit, w, _reason}, %{worker_id: w} = data),
    do: advance_retry_ladder(:oracle, clear_worker(data))
  def implementing(:info, {:worker_exit, w, _reason}, %{worker_id: w} = data),
    do: advance_retry_ladder(:implementing, clear_worker(data))
  # Stale-worker discard (other id) — both signals, both states.
  def oracle(:info, {:worker_stalled, _other}, data),       do: {:keep_state, data}
  def implementing(:info, {:worker_stalled, _other}, data), do: {:keep_state, data}
  def oracle(:info, {:worker_exit, _other, _r}, data),      do: {:keep_state, data}
  def implementing(:info, {:worker_exit, _other, _r}, data), do: {:keep_state, data}

  # A wedged/exited worker is first a SEMANTIC retry (refine/pivot on a fresh
  # worker in the SAME role), escalating to E-RETRY-EXHAUSTED only if the stall
  # persists past the ladder. Re-entering `state` (not always :implementing) keeps
  # the role correct. The :next_state's :on_enter bumps attempt_count and snapshots
  # the Ledger (D-315 RPO=0) before re-spawning — so durability and exactly-once
  # come for free; there is NO :deferred_spawn path. The Unit's OWN :state_timeout
  # (total heartbeat silence) is the SEPARATE hard-stall path: it escalates
  # E_WORKER_STALLED directly (def oracle/implementing(:state_timeout, :stall, …)
  # above), never the ladder.
  defp advance_retry_ladder(state, data) do
    case Tau.Factory.Retry.next(data.k, data.attempt_kind, data.policy_pin) do
      {:refine, k} -> {:next_state, state, snapshot(%{data | k: k}), [{:next_event, :internal, :on_enter}]}
      :pivot       -> {:next_state, state, snapshot(pivot_reset(data)), [{:next_event, :internal, :on_enter}]}
      :exhausted   -> escalate(data, {:retry_exhausted, data.unit_id})  # → E-RETRY-EXHAUSTED
    end
  end

  # gating/awaiting_merge stall: retry-then-escalate semantics unchanged.
  defp stall_escalate(data, state) do
    case Tau.Factory.Retry.next(data.k, data.attempt_kind, data.policy_pin) do
      {:refine, k} -> {:next_state, :refine_k, snapshot(%{data | k: k, stalled: true})}
      :pivot       -> {:next_state, state, snapshot(pivot_reset(data)), [{:next_event, :internal, :on_enter}]}
      :exhausted   -> escalate(data, {:retry_exhausted, data.unit_id})  # → E-RETRY-EXHAUSTED
    end
  end

  defp clear_worker(data), do: %{data | worker_id: nil}  # + Process.demonitor(mref, [:flush])
end
```

**Two complementary liveness guards close every non-progress state (H-2):**

1. **Per-state timeout (above), reset by progress heartbeats (D-377).** `oracle`,
   `implementing`, `gating`, and `awaiting_merge` each arm a `{:state_timeout, ms,
   :stall}` on entry. In the worker-awaiting states (`oracle`, `implementing`) the
   Unit **re-arms** that timeout on every current-worker `{:worker_heartbeat, w}`
   — the live pulse the Worker forwards from D-366 shim frames (`worker-fleet.md`).
   So `ms` is a *per-heartbeat inactivity deadline* (max silence between two
   progress pulses), not an absolute run-duration cap: a genuinely-progressing
   agent that pulses at least once per `ms` window NEVER trips the cap, while a
   silently-wedged worker (no pulse) trips it at `ms` → the retry ladder →
   escalation. This is the GOV4 refinement of D-358: the fixed cap no longer
   either spuriously kills a slow-but-healthy run or, when widened to mask that,
   masks a wedge — the deadline keys on silence, not elapsed time.
2. **Worker watchdog (D-379).** The worker (`worker-fleet.md`) emits periodic
   progress events over its `Port`; the fleet `Watchdog` converts *absence* of
   heartbeats beyond a threshold into a synthetic `worker_stalled(w)` event — the
   case where the Port is alive but the sub-agent is hung (no `:DOWN` ever fires).
   The wiring is load-bearing and previously orphaned (V3): the `UnitDriver`
   `worker_fun` seam **registers each spawned worker** (test-author AND
   implementer) with the `Watchdog` addressed to the owning Unit, and **both**
   `oracle` and `implementing` **consume** `{:worker_stalled, ^worker_id}`
   (above), routing it through the retry ladder back into the originating state.
   The Watchdog's `heartbeat_timeout` and the Unit's `state_timeout_ms` are set
   from the **same** `:unit_timeouts`-derived threshold (D-358) so the two
   heartbeat-absence detectors cannot disagree.

**One outcome per worker — ONE symmetric rule for `oracle` and `implementing`
(D-378, GOV4 re-shape).** Stall-class signals for a single wedge produce exactly
one outcome via `worker_id`-keyed disjointness: the first stall-class signal clears
`data.worker_id`; every later stall-class event for that superseded id hits the
stale-worker discard clause and advances nothing. There are **two outcome kinds**,
but they are split by *source*, not by signal — and the split is identical in both
states:

- **Event-message stall signals** — the Watchdog's `{:worker_stalled, ^worker_id}`
  (heartbeat-absence) **and** the dispatcher's `{:worker_exit, ^worker_id, reason}`
  (semantic death-cert) → the **retry ladder** (`advance_retry_ladder/2`), which re-enters
  the **originating** waiting state. The ladder's `:on_enter` bumps `attempt_count`
  and writes a Ledger snapshot (D-315 RPO=0) before re-spawning, so durability is
  intrinsic. **There is no `:deferred_spawn` path** — the plain `:next_state`
  transition IS the re-spawn, and exactly-once holds because the re-spawn produces
  a fresh `worker_id` (any stale signal for the old id is discarded by id, not by
  drain order; the `{:next_event, :internal, :on_enter}` is moreover processed
  ahead of pending mailbox `:info` messages). Does NOT escalate directly; escalates
  to `E-RETRY-EXHAUSTED` only when the ladder is spent.
- **The Unit's OWN `:state_timeout`** (D-377; fires only on total heartbeat silence
  past the cap) → `escalate(:E_WORKER_STALLED)` (the hard-stall path; gate NOT
  called; preserves #490/D-326). This is the only origin of `E_WORKER_STALLED`.

A real wedge resolves bounded (no hang; never both retries AND escalates for one
stall event). **The run-#2 gap closed:** `oracle` previously had no `worker_exit`
clause, so an oracle worker exiting `:no_work_product` fell through to
`handle_unexpected/4`, was ignored, and only the eventual `:state_timeout` fired —
a spurious `E_WORKER_STALLED` for a routine semantic retry. Both states now consume
both event-message stall signals identically.

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

Four keyed-by-`worker_id` worker signals are **disjoint** and U distinguishes them
structurally (the `worker_event` family of system-architecture.md §1, U `E_in`).
The first three are *outcome* triggers (transition U out of the waiting state);
`worker_heartbeat` is a *liveness* pulse (keeps U in the state, resets the cap):

| trigger | meaning | U action |
|---------|---------|----------|
| `work_ready(w, branch, head_sha)` | agent declared a **stable diff** (success) | → `gating` (`request_gate`) [in `implementing`]; → `implementing` [in `oracle`] |
| `worker_exit(w, reason)` (semantic death-cert) | worker **exited without a work-product** (`:no_work_product` / `:error` / `{:exit_status,_}`) | **retry ladder** → re-enter originating state; gate NOT called (FR-8.2) |
| `worker_stalled(w)` | watchdog saw **heartbeat absence** (wedged, no `:DOWN`) | **retry ladder** → re-enter originating state; gate NOT called |
| `worker_heartbeat(w)` | live progress pulse (D-366 shim frame) | **reset** `:state_timeout`; stay in state (D-377) |

The same table governs **both** `oracle` and `implementing` (GOV4 re-shape). The
event-message stall/exit triggers collapse to **exactly one** combined metric
increment per worker (D-378): the first stall-class signal consumed clears
`data.worker_id`, so later signals for that superseded id are discarded; both route
to the retry ladder, which re-enters the originating state and (via `:on_enter`)
bumps `attempt_count` and snapshots the Ledger (D-315). There is **no deferred
re-spawn**. The Unit's own `:state_timeout` (total heartbeat silence) is the only
direct `E_WORKER_STALLED` escalation. See D-378 one-symmetric-rule model.

The legacy 2-tuple worker seam (`worker_id == nil`) has no in-band `work_ready` /
`worker_exit`; for it a monitored `:DOWN` is the infra-crash path →
`escalate(E_WORKER_DOWN)`. Under the D-326 3-tuple seam, `:DOWN` is not an
authoritative outcome (the death-cert arrives as `worker_exit`).

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

### 3.2.2 The `awaiting_merge` result lifecycle — subscribe-before-request (D-356)

The `awaiting_merge` state consumes M's async result over PubSub
`"factory:pr:#{id}"` (the §5 *U → M `merge_result`* edge). Because
`Phoenix.PubSub` is **at-most-once with no replay**, the order of *subscribe*
and *request* is load-bearing: if U requested the merge before subscribing, M's
result broadcast — fired minutes later in `:committing` — could still land in the
gap before U's subscription exists and be **lost**, leaving U to sit until its
`state_timeout` and escalate spuriously. U therefore **subscribes first, then
requests**:

```elixir
# awaiting_merge: subscribe to the per-PR result topic BEFORE submitting the
# merge, so the at-most-once broadcast can never precede the subscription.
def awaiting_merge(:internal, :on_enter, data) do
  case reconcile_merge_outcome(data) do          # D-355: durable outcome first
    {:merged, _sha}   -> terminal(data, :merged)  # already landed — no submit
    {:rejected, _r}   -> {:next_state, :gating, data, [request_gate(data)]}  # INV-2
    :none ->
      :ok = Phoenix.PubSub.subscribe(Tau.PubSub, "factory:pr:#{data.unit_id}")
      :queued = data.merge_fun.(data.unit_id, data.hash)   # → request_merge
      {:keep_state, data, [{:state_timeout, data.t_merge, :stall}]}
  end
end

# the result arrives async on the topic; U consumes it directly off its mailbox.
def awaiting_merge(:info, {:merge_result, :merged},   data), do: terminal(data, :merged)
def awaiting_merge(:info, {:merge_result, :rejected}, data),
  do: {:next_state, :gating, data, [request_gate(data)]}    # re-gate (INV-2)
```

`subscribe/2` is a synchronous local-registry write; it *happens-before* the
`request_merge` it precedes, and M's broadcast *happens-after* the build, so the
subscription provably exists at every possible publish instant — the race is
closed by construction (the single shared `Tau.PubSub` instance, never a second,
makes publisher and subscriber share one registry). U **unsubscribes on every
exit** from `awaiting_merge` (to `merged`, to `gating` on `:rejected`, or to
`escalated` on timeout); a late or duplicate broadcast after unsubscribe is
dropped harmlessly, so the re-gate → re-enter → re-subscribe cycle (INV-2) carries
no stale cross-excursion delivery. There is **no driver-side telemetry→Unit
bridge**: the `[:tau, :factory, :merge, …]` telemetry is an observer projection
(§5), and a bridge that re-derived `{:merge_result, _}` from it would re-introduce
the very lost-event hazard this ordering closes (D-356, SPEC-FACTORY-CORE /
SPEC-FACTORY-MERGE).

**U callbacks run off the mailbox — no blocking subprocess in a state callback.**
A `gen_statem` state callback that blocks (a synchronous `git`/build subprocess, a
multi-second `receive`, a `call` held across a long activity) freezes U's mailbox
for the whole duration: the mandatory `state_timeout` cannot fire, `worker_exit`
and `worker_stalled` triggers queue unprocessed, and the liveness guarantee of
§3.2 is silently defeated. This mirrors M's own deterministic-FSM /
nondeterministic-activity split (`merge-and-integration.md` — the minutes-long
build runs in a monitored `Task`, never in M's `handle_call`). For U the same
doctrine holds: every long or blocking effect is pushed into a **monitored peer**
(the worker, M, the gate `Task`) whose result returns as a *message* or `:DOWN`;
the state callback only decides and arms a timeout. In particular `merge_fun`
MUST return promptly (`request_merge` is non-blocking, returns `:queued`); it MUST
NOT perform worktree reclaim or any other blocking work inline — reclaim is the
`WorkspaceJanitor`'s, fired on the worker's `:DOWN` (`worker-fleet.md`, D-313/
D-314), never the driver's or the callback's.

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

---

## 7. The M10 dogfood harness (P5c-7) — recording on top of the control plane

This section **records** the dogfood capstone (`mix tau.factory.dogfood`,
SPEC-FACTORY-CORE §4 B11 / AC-12); it does **not** redesign the control plane.
The dogfood drives the **real** K → S → U → W → G (`gate-and-toolchain.md`) → M
(`merge-and-integration.md`) → health path; nothing is reimplemented. Only the
**agent's authorship** is simulated, and the **origin** is confined to a local
sandbox. The harness is a thin operator entry point above §1–§5.

### 7.1 What the harness is and is not

The harness is a `Mix.Task` (`mix tau.factory.dogfood --repo <work-repo> --issue <n>
[--db <ledger-path>]`) that (a) validates the sandbox, (b) seeds one trivial
issue, (c) enables and boots the §3-order factory subtree (`supervision-tree.md`;
the config-gated `Tau.Factory.Supervisor`, SPEC-FACTORY-CORE §4 B11) against the
sandbox, (d) lets the **Coordinator** drive exactly one unit to its terminal
`unit_terminal(:merged)` (§1.2 loop), and (e) reports the merged SHA + green
health, then halts. The optional `--db <path>` flag threads an isolated Ledger DB
path into `Supervisor.start_link/1` `:db_path` (default:
`Tau.Settings.data_dir()/factory_ledger.db`); the e2e test uses it to supply a
per-test DB and verify durable rows post-run. It introduces **no new control
process and no new transition** — it is the operator's `select_fun`/`drive_fun`
wiring plus a safety precondition.

### 7.2 The deterministic `agent_bin` (the only simulated part)

A live-LLM `agent_bin` is non-deterministic and slow, which would make the
end-to-end test flaky and would prove agent *intelligence*, not the *control
plane*. The dogfood instead uses a **deterministic scripted `agent_bin`**: a
small executable that, in the worker's private worktree (`worker-fleet.md`),
produces a **real** git branch + commit solving the seeded issue, then emits the
D-326 `work_ready` `{:packet,4}` frame (`{"type":"work_ready","branch":…,
"head_sha":…}`) over its `Port` — exactly the in-band success contract §3.2.1
requires. This keeps every machinery edge real: a **real** worker worktree, a
**real** `Gate.run` (including the engine-executed mutation half over the seeded
issue's **real gating test**, `gate-and-toolchain.md` §3), a **real**
MergeAuthority CAS push to the sandbox `main`, and a **real** post-integration
health check (`merge-and-integration.md` §5). The agent's *authorship* is the
sole simulated element; "one REAL PR end-to-end" holds because every other edge
is the production path.

**The seeded issue.** A trivial change with a real gating test so Gate 5.3
mutation genuinely fires — e.g. *add `Sandbox.answer/0` returning `42`* with a
gating test asserting `Sandbox.answer() == 42`. The scripted agent writes the
production function and commits; the test-author's gating test (frozen path)
fails on the reverted tree (no `answer/0`) and passes on the real tree, so the
mutation cross-check (`gate-and-toolchain.md` §3 step 7) is satisfied by a real
diff, not a vacuous one.

**Determinism and the head-SHA coordinate (RESOLVED — C1, PR #503).** U
**captures** `work_ready`'s `branch`/`head_sha` (§3.2.1) and keys
`gate_fun`/`merge_fun` on the agent-asserted `head_sha`, not the *declared*
`work_item.hash` (SPEC-FACTORY-CORE §4 B6/B7/B8, D-361/D-362/D-363; `[C121-B11]`
resolved). *Earlier this section stated U discards `head_sha` and keys on the
declared hash — that was the P5c-7 deferral, now superseded; §3.2.1 always showed
the capturing clause, and capture is the canonical contract.* For the **dogfood**
the change is a no-op: the deterministic scripted agent makes its asserted HEAD
exactly the declared `branch`/`hash`, so the captured and declared coordinates
coincide and the gate/merge coordinate **is** the agent's real HEAD either way.
The capture matters for a **non-deterministic** agent, whose real HEAD cannot be
pre-declared (V1) — its actual commit is then the coordinate gated and merged.

### 7.3 `gate_fun` construction (completing the §4 B11 deferral)

The Unit's `:gate_fun` seam is **arity-1** (`(coordinate :: String.t() -> :pass |
{:fail, findings})`); the real gate is `Gate.run/1` over a `%Gate.Request{}`. The
Unit supplies the coordinate (`data.head_sha || data.hash`) at the `gating` state
entry (D-361 symmetric with `awaiting_merge`). The harness/supervisor builds the
arity-1 closure that receives the coordinate, sets `Request.hash` to it, and folds
the `%Verdict{}`: `workspace` = a host-isolated checkout for the engine's revert
(distinct from the worker's writable worktree), `merge_base` = `git merge-base
origin/main HEAD` in that workspace, `frozen_paths` = the declared gating-test
path set (D-304), `unit`/`run`/`diff`/`policy_pin`/`ledger` from the work-item
and supervisor context; `hash` comes from the Unit at call time (D-361/D-363).
Detail and field provenance: SPEC-FACTORY-CORE §4 B11.

### 7.4 Sandbox + the local-origin safety guard (D-359, V1)

The dogfood `origin` is a **local bare repo** — a real git remote on the
filesystem (`file://` / path), never a network remote. MergeAuthority is the
sole writer of `origin/main` and advances it with `--force-with-lease` (§3,
`merge-and-integration.md` §2b); a force-push to a real GitHub remote is an
irreversible, gate-unassessable destructive action (INV-20 / E-DESTRUCTIVE
territory). The harness therefore **hard-refuses a non-local origin before
booting the factory**: it resolves the sandbox's `remote.origin.url` and rejects
any `https://` / `git@` / `ssh://` URL (non-zero exit, no subtree assembled),
proceeding only for a local bare-repo path/URL. This is a **precondition guard**,
not a runtime classification — the named mechanism (V1) that makes "the
autonomous force-pushing loop never targets a real remote in dogfood mode" true
by construction. It complements the off-by-default gate (D-357): even an
operator-enabled dogfood is blast-radius-confined to a throwaway local repo.

### 7.5 Widened Unit timeouts (D-358, OQ-2)

Real agent runs (`T_unit`) exceed the Unit's default 30 s per-state
`:state_timeout` (§3.2), so an unwidened dogfood would trip the stall path and
escalate `E-RETRY-EXHAUSTED` spuriously (a §1.4 non-progress *false positive*).
The harness threads a widened `:unit_timeouts` (`[state_timeout_ms: …]`, set well
above the scripted agent's worst-case run) through the supervisor onto every
driven Unit. This widens the liveness *bound*, not the *guarantee*: the timeout
still fires on a genuinely-wedged worker — just above `T_unit` (OQ-2 is the
binding `W_cap`/`B` sizing input; here it sets a single dogfood timeout, not the
fleet cap).

### 7.6 The one-unit-to-terminal autonomous flow (AC-12, no human)

The Coordinator's `running` loop (§1.2) is unchanged: `select_fun → drive_fun →
unit_terminal`. With a single seeded issue the first `select_fun` yields the
work-item and the second yields `nil` (milestone termination, D-342), so the loop
drives exactly one unit to `unit_terminal(:merged)` and then idles/reports — **no
per-step human checkpoint** (D-S1). The harness enables the factory, awaits the
single unit's terminal, and reports the merged SHA + green health. The AC-12
observables (merged commit on the sandbox `main`, green `Merge.Health.check`,
verdict + Unit snapshots durable in L, zero human input, no spurious escalation)
are the substance the §1 control plane already produces — the harness only points
it at a sandbox and reads the result. Full assertion list: SPEC-FACTORY-CORE §7
AC-12 / AC-13.
