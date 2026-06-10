# Candidate shape — MINIMAL

The null hypothesis: the fewest components/boundaries that still enforce ALL of
`invariants.md` (INV-1..24), `conservation.md` (CON-1..7), `liveness.md`
(LIV-1..5, escalation set E), and the quantified NFRs. Bias: collapse every
boundary that does not enforce a *distinct* invariant. Runtime-agnostic
(no OTP/vendor terms); the imposed Elixir/OTP mapping is a later layer.

## Constraints (imposed)

- D-S1 escalation-only autonomy → every "must never happen" enforced
  structurally, escalation set total. (`scope-decisions.md`)
- D-S2 polyglot → toolchain is data (an adapter record), not a wired component.
- D-S3 greenfield. D-S4 single-node, location-transparent (events not shared
  memory across boundaries; node-local memory flagged where used).

## Notation

Components as `C = (S, E_in, E_out, →, Inv)`. `auth : datum → C` total.
`◁` single-writer-of-record. `⫫` isolation. `‖` parallel composition.
`merge(d)/green(d)/fresh(d)` per `invariants.md`. Edges: `{pre} e {post}` +
**FAIL:** failure clause.

---

## 1. Components

Seven components survive the drop-a-component test. Each is justified by the
invariant(s) it *alone* enforces; deleting it orphans those rows.

### C1 — LEDGER (durable system-of-record) ◁ all factory facts

The single transactional authority for every durable factory datum. This is the
one component the requirements forbid collapsing into any other: INV-16 demands
a system-of-record that is *not* a context window and survives restart at RPO=0.

- `S_L = SolutionTree × Backlog × VerdictStore × ChallengeLog × BudgetLedger ×
  EscalationLog × ScopeRecords × KnowledgeStore`
  where `SolutionTree : UnitId → {state, attempts, kill_reason, lineage}`,
  `Backlog : UnitId → {open, in_flight, merged, escalated, rejected}`,
  `BudgetLedger = (total, spent, remaining) with spent+remaining=total`,
  `VerdictStore : (UnitId, DiffHash, GateHalf) → {PASS, FAIL}`.
- `E_in`: `record_decision(x)`, `debit(owner, cost)`, `record_verdict(g,d̂,v)`,
  `record_challenge`, `record_escalation(e,snapshot)`, `set_scope(u,scope)`,
  `reconcile(tracker_state)`, `read(query)`.
- `E_out`: `committed(x)` (durable ack), `over_budget` (debit would breach
  ceiling), `drift(i)` (tracker/tree disagreement).
- `→`: every write is WAL-committed *before* its ack; commit is the linearization
  point. `debit` is compare-and-debit: admits iff `spent+cost ≤ total`, else
  emits `over_budget` and does not debit (CON-3, INV-21). All writes
  monotone-append where the datum is a log; CAS on `(UnitId, version)` where the
  datum is a state cell.
- `Inv_L`: **INV-16** (decided ↝ persisted, survives restart, RPO=0, single
  source of truth — single-writer + WAL); **CON-1** work conservation (Backlog
  partition is a disjoint union maintained by C1 as the only writer);
  **CON-2** issue reconciliation (`reconcile` is C1's audit fold; `|steps_recorded|`
  is C1 state); **CON-3** budget conservation (`spent+remaining=total` is a C1
  balance invariant on every `debit`); **CON-4** cost attribution (`debit`
  carries `owner`, `∃! owner(s)` by the event schema); **CON-6** verdict
  conservation (VerdictStore keyed by `DiffHash`; a verdict is *fresh* iff its
  `DiffHash` = current diff hash); **CON-7** escalation conservation
  (EscalationLog append is the record-leg of every escalation); **INV-19**
  attempts(pr) ≤ N (attempt count is durable C1 state read by C6's guard).
  Also the writer-of-record substrate for **FR-6.1..6.3** and **FR-6.2**
  knowledge (KnowledgeStore, node-local read cache permitted, D-S4).

*Why not split LEDGER per datum?* Splitting (e.g. budget ledger ≠ solution tree)
buys nothing minimal: all are RPO=0 transactional facts with the same authority
discipline and no rate/consistency divergence large enough (shaping_heuristics
"split by rate/consistency") to force separate sequencers at single-node scale
(NFR-CONC peak 16). One transactional authority, many tables. The drop test for
a *separate* budget component fails: its invariants (CON-3, INV-21) are already
discharged here. Kept as one component; budget *admission* logic is a pure
guard, not a process.

### C2 — COORDINATOR (the control-loop authority / escalation FSM)

The deterministic orchestrator (FR-6.3: persist decisions, not LLM reasoning).
Owns the loop FSM and the totality of escalation. It holds **no mutable working
tree** (INV-11) and **no durable state of its own** — it reads/writes through C1,
so a crash loses nothing (LIV-5 via INV-16).

- `S_C = LoopMode × {per-unit FSM handles} × KillFlag`,
  `LoopMode ∈ {running, halted(e)}`. All authoritative per-unit state lives in
  C1; `S_C` is rebuildable cache (smallest-sufficient-state: on restart,
  reconstruct from C1).
- `E_in`: `tick` (driver re-invocation), `verdict(u, half, v)` (from C4),
  `worker_terminal(u, outcome)` (from C5), `over_budget`/`drift` (from C1),
  `kill` (out-of-band), `destructive_request(a)` (from C5/C7),
  `challenge(u, test, clause)` (from C5).
- `E_out`: `set_scope(u)`, `record_decision`, `record_escalation(e)` → C1;
  `admit(unit, plan)` → C3; `spawn_test_author(u)` / `spawn_impl(u)` /
  `spawn_gate(u)` → C5; `request_merge(u, d̂)` → C7; `notify(operator, report)`.
- `→`: an FSM with **no terminal-without-classification state** — the catch-all
  transition emits `E-UNCLASSIFIED` (INV-18 totality by construction). Per-unit
  ladder: `admitted → tested → implemented → gated → {merge | refine | pivot |
  escalate}`, refine bound N=3 then pivot then `E-RETRY-EXHAUSTED` (INV-19).
  `kill` is read **only at unit boundaries**; an in-flight unit runs to its clean
  checkpoint, then `halted` (INV-22, NFR-KILL-LATENCY ≤ 1 unit). Reporting only
  at milestone-boundary and on escalation (FR-9.2).
- `Inv_C`: **INV-18** total escalation (FSM construction); **LIV-1..5**
  (termination: the ladder is well-founded — every state either progresses or
  steps toward an escalation in ≤ N transitions; LIV-5 resume-from-C1);
  **INV-22** clean kill (boundary check); **INV-20** routing
  (destructive class → `E-DESTRUCTIVE`, never auto-execute — the *classification*
  is C7's, the *halt* is C2's); **CON-7** delivery-leg of escalation (notify).
  Drives **FR-9.2, FR-9.3, FR-8.3**.

*Distinct from C1?* Yes: C1 is a passive store with a balance discipline; C2 is
the active FSM that decides. Collapsing them would put loop control inside the
transactional writer — but the loop must survive the writer (read-then-decide-
then-write), and a crash of the decider must not corrupt the store. Boundary
kept. C2 is *stateless-recoverable*; C1 is *durable*.

### C3 — SCHEDULER (admission / conflict-gated concurrency authority)

The single authority that decides *which* units may run concurrently. It exists
solely to enforce INV-13 (and FR-2.3, FR-7.3): admission is serialized so the
conflict check is evaluated against a stable in-flight set.

- `S_S = InFlight : ℘(UnitScope)` where `UnitScope = (files, codepoints,
  spec/D-blocks, declared resources, deps)`. (Read-through projection of C1
  scope records; `InFlight` is the live admitted subset.)
- `E_in`: `admit(unit, scope)` (from C2), `released(unit)` (from C5 on terminal),
  `budget_ok?` (queried from C1's `debit`-precheck).
- `E_out`: `admitted(unit)` | `serialized(unit, blocker)` → C2; `spawn_worker`
  trigger to C5.
- `→`: `admit(u)` succeeds iff the **five-clause check** clears against every
  `v ∈ InFlight` (no dependency ∧ disjoint files incl. gating-test paths ∧
  disjoint codepoints ∧ no shared SPEC/D-block ∧ resource-isolation possible)
  **and** budget admits (INV-21 precheck). Admission is mutually exclusive
  (single-writer to `InFlight`). Serialized units are monotone: a blocked unit
  becomes admissible once its blocker is `released` (LIV-4 no livelock — the
  decision is monotone, not re-litigated).
- `Inv_S`: **INV-13** conflict-gated concurrency (the only enforcer);
  **INV-21** admission-side budget ceiling (co-enforced with C1); **FR-2.3,
  FR-7.3** back-pressure (admission bounds in-flight ≤ what budget+check allow →
  NFR-CONC); contributes **LIV-4** monotone serialization.

### C4 — GATE (mechanical-check authority; the green/fresh oracle aggregator)

Computes `green(d)` for a diff `d`: aggregates the two judgement-oracle verdicts
(critic, reviewer — produced by C5 agents) and runs the three **mechanical**
gates (AC-linkage, masking-detection, mutation) as pure path-based checks. It is
the structural home of the anti-gaming mechanical invariants.

- `S_G`: stateless per-run; `S_G = ∅` between runs (a pure function of
  `(diff, frozen_scope, gating_test_paths, merge_base)`). Verdicts persisted in
  C1 (CON-6), not held here.
- `E_in`: `gate(u, d̂, scope, paths_g)` (from C2 after C5's oracle agents report).
- `E_out`: `verdict(u, half, v, d̂)` per half → C1 (record) and C2 (decide).
- `→`, the three mechanical gates as total functions:
  - **AC-linkage** g5.1: `∀ ac ∈ AC(scope). ∃ name ∈ paths_g. ac ∈ name`
    (meta-AC exempt) — **INV-?** supports INV-1's completeness.
  - **masking** g5.2: scan `d` for deleted/weakened assertions ∨
    `d ∩ paths_g ≠ ∅` → flag to critic (detection-only) — **INV-6**.
  - **mutation** g5.3: revert all but `paths_g` to `merge_base`, run gating
    tests, assert ≥1 fails — **INV-7**.
  Plus the **incomplete-fix** check g (does a finding falsify a named AC/D-NNN?
  → not mergeable) — **INV-9**. Aggregate `green(d) = critic=PASS ∧
  reviewer=PASS ∧ g5.1 ∧ g5.3 ∧ ¬incomplete`.
- `Inv_G`: **INV-1** gate-before-merge completeness (green keyed to `DiffHash`);
  **INV-6** masking (path-based); **INV-7** non-vacuous (mutation); **INV-9**
  incomplete-fix; partial **INV-8** (mechanizable entry-point assertion where
  possible; residual is critic judgement — flagged, not claimed). **INV-23/24**
  spec/OTP gate questions ride here as critic/reviewer checklist items.
  Enforces **NFR-GAME-RESISTANCE** vacuous=0 (g5.3).

*Why not fold C4 into C7 (merge authority)?* They enforce different invariants:
C4 computes the *predicate* `green(d)`; C7 enforces *serialization+freshness+
atomic apply*. Folding makes the merge authority also the gate runner, widening
its critical section to include long toolchain runs (NFR-MERGE-RATE 8min) — which
would serialize *gating* behind merging and break NFR-CONC's parallel gates. Kept
separate: gates run in parallel per-PR; merges serialize.

### C5 — WORKER SUPERVISOR (isolation + agent lifecycle + capture authority)

One component owning the *complete* isolation boundary and the supervised
lifecycle of every agent process (test-author, implementer, critic, reviewer).
This is the structural home of work-isolation (INV-10..13 spawn side),
durability-of-dirty-state (INV-14, CON-5), reclaim (INV-15), crash containment
(INV-17). The oracle-separation boundary INV-5 is enforced here as a
**spawn-ordering precondition**: it freezes `paths_g` (writes to C1) *before* any
implementer for the unit is permitted to spawn.

- `S_W : WorkerId → (workspace, agent_role, lease)`,
  `workspace = (private_checkout_from_ref, resource_namespace)` where
  `resource_namespace` is total over the resources the unit's **toolchain adapter**
  declares (D-S2: per-language caches, XDG, sandbox FS). `lease` couples the
  workspace to the worker's life.
- `E_in`: `spawn(role, unit, ref, toolchain)` (from C2/C3),
  `agent_done(role, output)`, `agent_crash(WorkerId)` (monitored),
  `challenge(test, clause)` (from an implementer agent).
- `E_out`: `position_set(w, ref)`, `oracle_frozen(u, paths_g)` → C1,
  `agent_output(role, structured)` → C2/C4 (structured, never screen-scraped),
  `captured(w, dirty)` → C1 (durable log), `released(unit)` → C3,
  `destructive_request(a)` → C7, `worker_terminal` → C2.
- `→`: spawn allocates a fresh isolation boundary forked from a **verified ref**
  (INV-12: spawn sets position, agent's first act verifies-or-aborts; spawn brief
  is not trusted, INV-12/spawn-brief-integrity). **Ordering precondition for
  INV-5:** `spawn(implementer, u)` is *guarded* by `∃ frozen paths_g(u)` in C1 —
  i.e. test-author runs and freezes paths before any implementer of `u` exists.
  On `agent_crash` or `kill`: **capture-before-destroy** runs in the supervised
  termination path — capture staged ⊎ unstaged ⊎ **untracked** (all three) to
  C1's durable log, *then* reclaim the workspace+namespace (INV-14, INV-15,
  CON-5). Each agent is its own crash domain (INV-17): a crash captures+reclaims
  that worker only, blast radius `{w}`. **Challenge protocol:** an implementer
  agent that hits a gating test it believes contradicts a SPEC §4 clause emits
  `challenge` (it MUST NOT edit `paths_g` — INV-6); C5 forwards to C2 which routes
  to an *independent* critic (FR-4.4), never the coordinator's own judgement.
- `Inv_W`: **INV-5** oracle separation (spawn-ordering precondition + frozen
  paths); **INV-10** resource isolation (allocation is a property of spawn, total
  over declared resources); **INV-11** no shared mutable tree (workers fork
  private checkouts; C2 holds none); **INV-12** verified position; **INV-14**
  no lost work (capture in terminate path, all three kinds); **INV-15** reclaimed
  isolation (lease coupled to worker life, reclaim on crash); **INV-17** crash
  containment (per-worker crash domain); **CON-5** artifact conservation
  (dirty = committed ⊎ captured ⊎ discarded-by-decision). Distinguishes
  **FR-8.2** infrastructure-crash (supervise/restart) from semantic failure
  (an *outcome* → C2's FSM, never a crash-loop). Egress governor (FR-7.2,
  NFR-EGRESS: rate-limiter → breaker → ledger) sits on the agents' outbound
  provider calls inside this boundary.

### C6 — UNIT-PROCESS / PR FSM (per-work-unit lifecycle authority)

One supervised process per in-flight work unit, owning that unit's atomic
lifecycle and the *bounded-retry* state machine. It is the atomicity scope for
"this PR" — frozen scope (FR-1.3), attempt ladder (INV-19), challenge tally
(E-CHALLENGE). Lightweight (NFR-AGENT-FLEET: ≤128 such + agents, well within
10³–10⁵).

- `S_U = (unit_id, frozen_scope, fsm_state, attempt_count, challenge_count,
  diff_hash, gate_verdicts↪C1)`. Authoritative copies WAL'd to C1 (RPO=0); `S_U`
  is the hot working cache, rebuildable from C1 on restart.
- `E_in`: `set_scope`, `oracle_frozen`, `agent_output`, `verdict`,
  `merge_result`, `freshness_stale`.
- `E_out`: `request_gate`, `request_merge(d̂)`, `refine|pivot|escalate(e)` → C2.
- `→`: `admitted → scope_frozen → tested(paths_g frozen) → implemented →
  gated → green? {request_merge | refine(≤3) | pivot(fresh PR, reset count) |
  escalate}`. `challenge_count > 2 → E-CHALLENGE`. A **pivot** closes this unit's
  PR and opens a fresh one (new `S_U`, count reset). Each transition is recorded
  to C1 *before* externally visible effect (write-ahead).
- `Inv_U`: **INV-19** bounded retry (guard on the refine edge, count durable);
  **FR-1.3** frozen scope (set once, immutable for unit life; growth → re-plan
  event, not silent); **E-CHALLENGE** (count guard); contributes **CON-6**
  (per-PR verdict freshness vs `diff_hash`). Localizes **LIV-1** unit
  termination.

*Why a per-unit component, not just rows in C1?* The FSM needs a **live
crash-domain** per unit so one unit's wedge does not stall others (INV-17 at the
unit granularity) and so concurrency (NFR-CONC) is real parallel processes, not
serialized table-walking. The durable copy is in C1; the live FSM is C6. This is
the deterministic-orchestrator-per-workflow shape (FR-6.3). Could it fold into
C2? No — C2 is one loop authority; folding N unit-FSMs into it makes C2 a
single-process bottleneck and a single crash domain for all units, violating
INV-17 at unit scope and capping NFR-CONC at 1.

### C7 — MERGE AUTHORITY (single serialized integrator)

The single-concurrency owner of the act of landing a diff on `main`. Exists to
enforce the integration-safety cluster (INV-1..4) and the destructive-action
classifier (INV-20). Mutual exclusion by construction — *the* merge boundary.

- `S_M = (merge_lock ∈ {free, held}, head_ref, main_health ∈ {green, red},
  fair_queue)`. `head_ref` re-read from origin inside the critical section.
- `E_in`: `request_merge(u, d̂)` (from C6 via C2), `classify(action a)`.
- `E_out`: `merged(u)` | `reject_stale(u)` (→ re-gate) | `reject_red` |
  `escalate(E-DESTRUCTIVE|E-CONFLICT|E-RED-MAIN)` → C2; `head_advanced` → C6s.
- `→`, the merge critical section (mutually exclusive, `|merging| ≤ 1`):
  1. acquire lock (INV-3 serialized);
  2. re-read `head(origin/main)`; if `base(d̂) ≠ head` → `reject_stale` (INV-2
     freshness — re-check *inside* the section);
  3. precondition `green(d̂)` against C1's verdict keyed to `DiffHash(d̂)`; absent/
     stale → reject (INV-1, CON-6);
  4. if `main_health = red` → refuse, hold ceiling closed, `E-RED-MAIN` (INV-4);
  5. apply atomically; run post-merge health (toolchain build+test); on red set
     `main_health=red` + `E-RED-MAIN` (INV-4, halts further merges);
  6. release lock.
  Fair service of `fair_queue` (FIFO + aging) so no green+fresh branch starves
  (LIV-2). **Action classification:** `classify(a)` — destructive class
  {force-push, history-rewrite, data-migration, release, external-publish} →
  deny + `E-DESTRUCTIVE`, never auto-execute (INV-20).
- `Inv_M`: **INV-1** gate-before-merge (precondition step 3);
  **INV-2** freshness (step 2 inside the section); **INV-3** serialized
  (lock); **INV-4** main health (steps 4–5); **INV-20** no unilateral
  destruction (classifier); **LIV-2** merge progress (fair queue); **FR-5.1,
  FR-5.2** (atomic traceable land); **CON-6** (reads fresh verdict).

---

## 2. Composition graph

Edges labelled `{pre} e {post}` + **FAIL** clause.

```
operator ─intent→ TRACKER(ext) ─issues→ C1.Backlog
                                            │ read
driver ─tick→ C2 ───────────────────────────┤
   C2 ─admit(u,scope)→ C3 ─admitted→ C2 ─spawn(test_author)→ C5
   C5 ─oracle_frozen(paths_g)→ C1   (PRECONDITION for next)
   C2 ─spawn(impl) [guarded ∃paths_g]→ C5 ─agent_output→ C2/C6
   C2 ─request_gate→ C4 ─verdict(half,d̂)→ C1 + C2
   C6 ─request_merge(d̂)→ C2 ─request_merge→ C7
   C7 ─merged|reject→ C2 ; C7 ─head_advanced→ {C6 in-flight} (freshness)
   C5 ─captured(dirty)→ C1  (on crash/kill, before reclaim)
   any ─record_decision/debit/record_verdict→ C1 ◁
   C2 ─notify→ operator (milestone | escalation only)
```

Edge contracts (the load-bearing ones):

- **C5 → C1 `oracle_frozen` ⇒ C2 `spawn(impl)`**: `{paths_g committed in C1}
  spawn(impl) {impl runs}`. **FAIL** (test-author crashes before freeze): no
  `paths_g` ⇒ the implementer-spawn guard is false ⇒ implementer never spawns;
  INV-5 holds vacuously; C2 re-spawns test-author (bounded). Ordering is the
  enforcement.
- **C4 → C1 `verdict` keyed to `DiffHash`**: `{d̂ = hash(final diff)}
  record_verdict {VerdictStore[d̂] set}`. **FAIL** (C4 crashes mid-gate): no
  verdict recorded; C7 precondition (`green(d̂)`) is false ⇒ no merge (INV-1
  fail-closed); C2 re-runs gate.
- **C2 → C7 `request_merge`**: `{green(d̂) ∧ C6 ready} request_merge
  {merged ∨ reject}`. **FAIL** (C7 unavailable/crashes mid-section): merge_lock
  released on crash (lease); partial apply impossible — the apply is the atomic
  VCS commit (apply-or-not, no in-between); on restart C7 re-reads head, finds
  either landed (idempotent: `merged(u)` already recorded in C1 → skip) or not
  (retry). **Idempotence:** `request_merge` carries `d̂`; replay checks C1 for
  `merged(u,d̂)` first.
- **C7 → C6 `head_advanced`**: every successful merge fans out a freshness
  signal; each in-flight C6 marks itself stale → re-gate before its own merge
  (INV-2). **FAIL** (signal lost): C7's step-2 re-read is the backstop — freshness
  is enforced *inside* the merge section regardless of the fan-out, so the signal
  is an optimization, not a correctness dependency.
- **C5 → C1 `captured`**: `{worker dirty} capture {staged⊎unstaged⊎untracked in
  C1 log} ; then reclaim`. **FAIL** (C5 itself crashes mid-capture): C5's own
  supervisor restarts it; the worker lease is still held (not yet reclaimed) so
  the dirty tree persists and capture is retried — reclaim only after capture acks
  (INV-14 ordering: capture ◁ reclaim).
- **any → C1 `debit`**: `{cost} debit {spent+=cost ∨ over_budget}`. **FAIL**
  (C1 briefly unavailable): debit blocks the billable action's admission
  (fail-closed: no debit ⇒ no admit) — never admit-then-lose-the-debit. INV-21
  holds; liveness degrades to "stall until C1 returns," which is correct (budget
  safety > throughput).

---

## 3. Enforcement matrix (R × C)

Cell = enforcing component · mechanism (P=precondition, SW=single-writer,
L=lifecycle, M=mechanical-check, FSM=state-machine guard). Every row has ≥1
enforcer.

| Req | C1 Ledger | C2 Coord | C3 Sched | C4 Gate | C5 Worker | C6 Unit | C7 Merge |
|---|---|---|---|---|---|---|---|
| INV-1 gate-before-merge | SW verdict | | | M aggregate | | | **P** |
| INV-2 freshness | | | | | | (signal) | **P/SW** |
| INV-3 serialized merge | | | | | | | **SW** |
| INV-4 main health | | escalate | | | | | **FSM** |
| INV-5 oracle separation | freeze store | | | | **P/L** (order) | | |
| INV-6 gating-test immut. | | | | **M** mask | P (no-edit) | | |
| INV-7 non-vacuous | | | | **M** mutation | | | |
| INV-8 user-path oracle | | | | M (partial)+critic | | | ⚠ residual |
| INV-9 incomplete-fix | | | | **M** | | | |
| INV-10 resource isolation | | | | | **L** allocate | | |
| INV-11 no shared tree | | (holds none) | | | **L** fork | | |
| INV-12 verified position | | | | | **P** | | |
| INV-13 conflict concurrency | | | **P** 5-clause | | | | |
| INV-14 no lost work | log sink | | | | **L** capture | | |
| INV-15 reclaimed isolation | | | | | **L** lease | | |
| INV-16 durable state RPO=0 | **SW/WAL** | (recovers) | | | | (WAL'd) | |
| INV-17 crash containment | | | | | **L** domain | FSM per-unit | |
| INV-18 total escalation | log | **FSM** | | | | | |
| INV-19 bounded retry | attempt ◁ | | | | | **FSM** guard | |
| INV-20 no destruction | | route+halt | | | | | **FSM** classify |
| INV-21 budget ceiling | **SW** debit | | P precheck | | | | |
| INV-22 clean kill | | **FSM** boundary | | | | | |
| INV-23 spec-before-code | | | | M (gate Q) | | | P |
| INV-24 OTP non-negot. | | | | M (gate Q) | | | |
| CON-1 work conservation | **SW** partition | | | | | | |
| CON-2 issue reconcile | **SW** fold | (triggers) | | | | | |
| CON-3 budget conservation | **SW** balance | | | | | | |
| CON-4 cost attribution | **SW** owner | | | | | | |
| CON-5 artifact conserve | log sink | | | | **L** capture | | |
| CON-6 verdict conserve | **SW** keyed | | | M produce | | freshness | P read |
| CON-7 escalation conserve | **SW** record | deliver | | | | | |
| LIV-1 unit termination | | FSM ladder | | | | **FSM** | |
| LIV-2 merge progress | | | | | | | **fair queue** |
| LIV-3 milestone term. | | FSM + reconcile | | | | | |
| LIV-4 no livelock | | | **monotone** | | | | |
| LIV-5 recovery progress | **WAL** | **resume** | | | | rebuild | |

**Orphans / residuals (called out per brief):**

- **INV-8 (user-path oracle)** — *partial orphan.* Mechanically checkable only in
  part (an entry-point assertion where the language permits); the general
  "exercises the real user entrypoint, not a hand-built struct" property rests on
  **critic judgement** (C4's oracle half), not a structural wall. Flagged as
  residual GAP-7 in the requirements; the minimal shape does **not** claim it
  closed. No new component fixes this — it is a judgement boundary by nature.
- **NFR-AUDIT (100% traceable)** — enforced by *construction* across C1+C7 (every
  merge carries `d̂ → verdicts → paths_g → AC/D → SPEC → issue` lineage in C1), but
  there is no dedicated *auditor* component; it is a query over C1. Acceptable
  minimally (the lineage is a C1 invariant), flagged so a richer shape may add a
  standing reconciliation/audit component.
- **NFR-OBS-COVERAGE / FR-9.1 (telemetry)** — in the minimal shape telemetry is a
  *cross-cutting emission* every component performs, not its own component. No
  invariant is orphaned (each component emits its own spans), but there is **no
  separate observability authority**; a non-minimal candidate would add a
  supervised reporter. Minimal: emission is a per-component obligation, the export
  sink is out-of-band.

Every INV/CON/LIV row has ≥1 structural enforcer. No INV is fully orphaned;
INV-8's residual is intrinsic, not a shape defect.

---

## 4. Failure cuts

1. **Coordinator (C2) dies mid-merge.** C2 holds no durable state and is *not*
   in the merge critical section (C7 is). The merge in C7 is atomic (VCS
   apply-or-not) and its result is recorded to C1 before C2 is notified. On C2
   restart it reads C1: if `merged(u,d̂)` present → unit is `merged`, skip;
   else → re-`request_merge` (idempotent via `d̂` check). **Holds:** INV-16 (RPO=0),
   INV-3 (C7's lock independent of C2), LIV-5 (resume from C1). No double-merge.

2. **A worker (agent, C5 child) crashes mid-write.** Per-worker crash domain
   (INV-17): blast radius `{w}`. The supervised terminate path runs
   capture-before-destroy — staged ⊎ unstaged ⊎ **untracked** to C1's durable log
   — *then* reclaims workspace+namespace (INV-14, INV-15, CON-5). Other workers
   and C2 are unaffected (NFR-BLAST=0). C6 sees `agent_crash` as a *semantic
   outcome* (FR-8.2), not a crash-loop: it refines or re-spawns within the N=3
   bound.

3. **Budget exhausts mid-PR.** Next billable action's `debit` to C1 returns
   `over_budget` (compare-and-debit, INV-21, CON-3 — no admit-past-ceiling).
   C3 admission denies new units; C2 raises **E-BUDGET** (global), halts the loop,
   records reason+snapshot to C1 (CON-7), notifies operator. In-flight units run
   to their clean checkpoint then stop (no mid-merge). **Holds:** INV-21,
   NFR-BUDGET-PRECISION (overrun ≤ one in-flight action).

4. **origin/main advances during a gate.** C4 produced `green(d̂)` for base `b`.
   Before merge, another unit merged → `head ≠ b`. C7 step-2 re-reads head
   *inside the lock* → `base(d̂) ≠ head` → `reject_stale` → C6 marks stale →
   re-gate the rebased diff (new `d̂′`) → re-merge. **Holds:** INV-2 (freshness in
   the critical section, independent of the `head_advanced` fan-out signal),
   CON-6 (the stale verdict is never used — keyed to the old `d̂`).

5. **The durable store (C1) is briefly unavailable.** Every write blocks
   fail-closed: no `debit` ⇒ no billable action admitted; no `record_verdict` ⇒
   C7's `green(d̂)` precondition false ⇒ no merge; no `record_decision` ⇒ C2 stalls
   rather than acting on un-persisted state. **Holds:** INV-16 (nothing acts on
   state that isn't durable), INV-1/INV-21 (fail-closed). Liveness degrades to a
   stall (correct: safety > progress); on C1 return the loop resumes (LIV-5).
   *This is the load-bearing single point* — its availability is C1's own
   supervision concern (NFR-CONTROL-AVAIL: durable store survives node loss; on
   disk, not in volatile memory).

6. **A destructive action is requested.** An agent's output / a delivery step
   requests force-push | history-rewrite | data-migration | release |
   external-publish. C7's `classify` (or C5 at the action boundary) denies it,
   emits **E-DESTRUCTIVE**, never auto-executes (INV-20). C2 halts the affected
   scope, records + notifies (CON-7). **Holds:** INV-20; the action whitelist is
   the structural wall, not agent restraint.

---

## 5. Path arithmetic (hot path: intent → merged)

Serialized stages on the critical path for one unit:

```
S1 select+scope (C2/C3 admission)        ── parallel across units
S2 freeze gating tests (C5 test-author)  ── parallel across units
S3 implement (C5 implementer)            ── parallel across units
S4 gate (C4: 2 oracles ‖ 3 mech checks)  ── parallel across units (key: NOT serialized)
S5 merge+health (C7)                     ── SERIALIZED across ALL units
```

Only **S5** is globally serialized (INV-3). S1–S4 run with concurrency
`C ≤ peak` (NFR-CONC peak=16), bounded by C3 admission + budget.

**Throughput bottleneck = S5 (the merge authority).** Its service time is
`T_merge` (p95 ≤ 8 min, NFR-MERGE-RATE), dominated by the polyglot toolchain
build+test, *not* the control plane. Merge throughput `μ_merge = 1 / T_merge ≈
1/8min = 7.5 merges/hr`.

**Queue stability at peak.** Let arrival of merge-ready units be `λ_merge`.
Stability requires `λ_merge < μ_merge`. With peak C=16 in-flight and a per-unit
end-to-end time dominated by S2+S3+S4 ≫ S5 (LLM implement + gate ≫ 8 min merge),
the *production* rate of merge-ready diffs is throttled by upstream agent latency
and by C3 admission, so `λ_merge` is structurally ≤ `μ_merge` at C=16: the
merge queue is stable, expected length O(1). **The freshness re-check is the
amplifier (Q-L2):** each S5 merge advances head, forcing ≤ C−1 in-flight units to
re-gate (re-run S4). Re-gate cost grows ~linearly in C while C ≤ ~32; the
requirements (NFR-CONC) set peak=16 *precisely so* this stays sub-super-linear
and no back-pressure-batch boundary (a separate buffered integrator) is needed —
admission control (C3) suffices. **If peak rose past ~32**, S5's re-gate
amplification would make `λ_re-gate → μ_gate` and a merge-batch / buffered
boundary becomes warranted: that is the single number that would add an 8th
component. Minimally, it is absent.

Merge fairness (LIV-2): C7's `fair_queue` is FIFO+aging so a large branch
(repeatedly re-gated as small ones merge ahead) eventually wins (Q-L1) — aging
is cheap insurance against the starvation the freshness loop can induce.

---

## 6. Open discriminating questions

1. **Q-CONC — peak concurrency C_max (NFR-CONC).** *The single number that
   decides component count.* At C ≤ ~32, C3 admission control + C7 fair-queue
   suffice and the minimal 7-component shape holds. Past ~32 the freshness
   re-gate amplification (S5 → ≤C−1 re-gates) goes super-linear and warrants an
   8th component (a buffered merge-integrator / back-pressure boundary).
   *Cost asymmetry:* building the buffer for a 4–16 PR workload is wasted
   complexity (the minimal shape is correct and cheaper); omitting it for a 64-PR
   workload causes re-gate storms and merge starvation. **Default peak=16 ⇒ stay
   minimal.** Guessing high is expensive-and-unnecessary; guessing low is a
   cheap-to-add boundary later. Asymmetry favors minimal-now.

2. **Q-MERGE-FAIRNESS (Q-L1) — FIFO vs aging in C7.** Each merge re-stales every
   in-flight branch; a large/slow branch can be perpetually overtaken. Is FIFO
   sufficient or is aging required? *Cost asymmetry:* FIFO is trivial but admits
   starvation of an unlucky large branch (LIV-2 violation under a stream of small
   merges); aging adds a priority term to C7's queue, cheap. **Recommend aging by
   default** — the cost is one comparator, the failure it prevents (a branch that
   never merges) is a silent liveness break. Guessing FIFO-is-enough risks a
   starvation the operator only sees as "that PR never lands."

(Secondary, noted not load-bearing: Q-RPO-mechanism is already decided RPO=0 —
only C1's concrete mechanism is open, deferred to the software-architecture
layer; Q-node-loss-HA (NFR-CONTROL-AVAIL) affects only C1's durability substrate,
not the boundary count.)
