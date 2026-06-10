# Candidate shape — RATE-SPLIT

**Shaping bias.** Draw component boundaries along **flow rate** and
**burstiness**: separate the slow/serial parts from the fast/parallel parts and
place an explicit **back-pressure edge** wherever two responsibilities run at
mismatched rates. Optimise NFR-CONC / NFR-AGENT-FLEET / NFR-MERGE-RATE while
every INV-/CON-/LIV- is enforced inside exactly one component boundary.

Runtime-agnostic. Components are `(S, E_in, E_out, →, Inv)`. No OTP/vendor
vocabulary; "demand-driven stage", "bounded buffer", "serialized authority",
"back-pressure edge" only. The Elixir/OTP mapping is a later layer.

## Constraints (imposed)

| ID | Source | Bears on this shape |
|----|--------|---------------------|
| D-S1 | scope-decisions | escalation-only autonomy ⇒ invariants structural, not prose |
| D-S2 | scope-decisions | polyglot ⇒ toolchain is a behaviour; gate/health/mutation dispatch through it |
| D-S3 | scope-decisions | greenfield ⇒ boundaries from requirements |
| D-S4 | scope-decisions | single-node, dist-ready ⇒ message/PubSub addressing, no `:global`, no cross-node shared store |

---

## 0. The flow-rate spectrum (the organising axis)

The factory is a pipeline whose stages run at **orders-of-magnitude different
rates**. Name them, with arrival rate `λ`, burstiness `b = peak/mean`, and
concurrency class:

| Class | Stage | `λ` (per node) | `b` | Concurrency | Character |
|-------|-------|----------------|-----|-------------|-----------|
| **R0 — intake** | intent → admitted unit | human-paced, ~issues/day | high (batch milestone) | 1 reader | slow, serial, idempotent re-read of tracker |
| **R1 — plan** | unit → frozen scope + SPEC/AC | ~units/hour | medium | small (per-unit) | medium, mostly serial per unit, parallel across units |
| **R2 — oracle** | scope → frozen gating-test path set | ~units/hour | medium | per-unit | medium; **must precede** R3 (INV-5) |
| **R3 — implement** | scope → committed diff | **fast, fan-out** | **high** (`b≫5`) | **W parallel pipelines** | bursty, parallel, fallible; the fleet |
| **R4 — gate** | diff → {PASS,FAIL} verdict pair | medium, **parallel across PRs** | medium | `G` parallel gate runs | toolchain-bound; re-runnable |
| **R5 — merge+health** | green+fresh diff → `main` | **slow, strictly serial** | low | **= 1** (INV-3) | the funnel; concurrency=1 by invariant |
| **R6 — ledger/tree** | every decision → durable fact | every transition | smooth | single writer per datum | the accounting spine |

**Governing observation.** R3 (fast, parallel, bursty) feeds R5 (slow,
serial, concurrency 1). That **rate impedance mismatch at the merge boundary**
is the dominant force in the whole design. R4 sits between them and is subject
to **re-gate amplification** (INV-2 freshness, Q-L2): every R5 merge advances
`origin/main` and restales every in-flight R3/R4 branch. The shape below puts a
back-pressure edge precisely at R3→R4→R5, sized by arithmetic (§5).

**Boundary rule applied.** Each stage is also an invariant cluster, so the
rate split and the invariant-cluster split coincide — the strongest possible
boundary justification (a boundary is where invariants are enforced AND where
flow rate changes).

---

## 1. Components

Notation: `S` state space, `E_in`/`E_out` event alphabets, `→` transition
relation (salient rules only), `Inv` invariants enforced **locally**.

### C0 — Intake Reconciler (R0; slow, serial, idempotent)

```
S0 = { backlog : Issue → State_tracker,
       scope_milestone : MilestoneId,
       cursor : reconcile_watermark }
     State_tracker ∈ {open, in_flight, merged, escalated, rejected}
E_in0  = { tick_reconcile, tracker_snapshot(Issue→State), unit_terminated(u, term) }
E_out0 = { admit_candidate(issue_set), reconcile_report(drift),
           e_unclassified(state) }            -- drift that cannot be classified
→ : tracker_snapshot ⇒ fold into backlog; emit admit_candidate for the
     smallest shippable open unit whose deps clear (FR-2.1); re-read is a pure
     idempotent fold keyed on Issue (apply twice ≡ once).
Inv0 : CON-1 (accepted ⇒ exactly one terminal ∨ in_flight),
       CON-2 (state_tree(i) ≡ state_tracker(i); |steps_rec| = |steps_exec|),
       FR-1.1 (tracker authority for *what*, tree authority for *done*).
```
Rate justification: human-paced intake decoupled from the fast interior by the
**Scheduler buffer** (C1). One reader; no contention. Idempotent because the
tracker is re-read each cycle, not consumed.

### C1 — Scheduler / Admission Controller (R0→R3 back-pressure boundary)

```
S1 = { ready   : Set<Unit>,            -- admitted-but-not-running
       running : Set<Unit>,            -- in-flight (|running| = W)
       blocked : Unit → BlockReason,
       W_cap   : ℕ }                   -- dynamic admission ceiling (§5)
E_in1  = { admit_candidate(issues), unit_terminated(u), credit_demand(stage),
           budget_state(spent,total), merge_funnel_depth(q) }
E_out1 = { start_unit(u, frozen_scope), serialize(u, blocker), e_budget }
→ : admit(u) PERMITTED iff
      (a) conflict_check(u, w) = clear  ∀ w ∈ running           (INV-13, 5 clauses)
      (b) |running| < W_cap                                     (NFR-CONC / §5)
      (c) budget.remaining ≥ reserve(u)                          (INV-21)
    else u → blocked (monotone: re-evaluated only when a blocker terminates → LIV-4).
Inv1 : INV-13 (conflict-gated concurrency), FR-2.3, FR-7.3 (admission-controlled,
       not fixed fan-out), bounded-buffer discipline (ready/running are bounded).
```
**This is the principal back-pressure edge.** `W_cap` is **demand-driven**:
it shrinks when `merge_funnel_depth` rises (R5 cannot absorb) or
`credit_demand` from R4 signals re-gate saturation. Admission, not spawning, is
the throttle (FR-7.3). Conflict check makes admitted units **disjoint** ⇒ their
R3 work commutes and needs no inter-worker coordination.

### C2 — Plan/Scope Authority (R1)

```
S2 = { plan : Unit → {issue_set, ordered_steps, spec_refs, AC_set, D_set, status} }
E_in2  = { start_unit(u), spec_gap(u, clause) }
E_out2 = { frozen_scope(u, plan), need_spec(u), need_test_author(u),
           e_ambiguity(u) }                  -- irreducible spec/product ambiguity
→ : produce SPEC for coordination-heavy unit (INV-23) BEFORE freeze; freeze plan;
    emit frozen_scope. Scope is immutable post-freeze (re-plan = explicit event).
Inv2 : FR-1.3 (frozen scope), FR-1.2/INV-23 (spec-before-code), FR-1.4 (AC against
       user entry point with observable signal), FR-2.2 (gateability ceiling).
```

### C3 — Oracle (Test-Author) Authority (R2; precedes R3 — INV-5)

```
S3 = { paths_g : Unit → frozen Set<TestPath>,
       authored : Unit → Bool }
E_in3  = { frozen_scope(u) }
E_out3 = { gating_paths_frozen(u, paths_g), spec_gap(u, clause),
           ready_for_impl(u) }
→ : author 1 failing test per AC/D exercising the user entry point (INV-8);
    commit; freeze paths_g; emit ready_for_impl. MUST complete before any C4 spawn.
Inv3 : INV-5 (author(test_g) ≠ author(impl)), INV-8 (user-path oracle),
       FR-4.2. paths_g is the frozen boundary all mechanical gates key on
       (path-based, not commit attribution — FR-4.3).
```
Rate/ordering justification: R2 is a **hard predecessor** of R3 by INV-5. The
boundary exists to make oracle separation a structural precondition (a spawn of
C4 is impossible until `gating_paths_frozen` exists), not a convention.

### C4 — Implementer Fleet (R3; fast, parallel, bursty, fallible)

```
S4(w) = { workspace : IsolationBoundary,    -- git checkout + ALL declared caches
          position  : Ref (verified),
          status    : {spawning, working, committed, crashed},
          dirty     : {staged, unstaged, untracked} }
E_in4  = { ready_for_impl(u), challenge_ruling(test, verdict) }
E_out4 = { diff_committed(u, content_hash), challenge(u, test, spec_clause),
           worker_crashed(w, captured_dirty) }
→ : verify own position (INV-12) → work → commit. MUST NOT write paths_g
    (INV-6); a contradiction with SPEC §4 emits challenge (never edits the test).
Inv4 : INV-10 (resource isolation, total over toolchain-declared resources),
       INV-11 (no shared mutable tree), INV-12 (verified position),
       INV-6 (gating-test immutability), INV-17 (crash blast radius = {w}).
```
**The fleet is the fast/bursty stage.** Each `w` is an independent crash
domain; `b≫5` is absorbed by the bounded buffer in C1, not by C4 itself. Up to
`A_max=128` agent processes (NFR-AGENT-FLEET) across all `W` pipelines.
Isolation is a property of the spawn mechanism (C8), not an opt-in flag.

### C5 — Gate Stage (R4; medium, parallel across PRs, re-runnable)

```
S5 = { runs : Unit → { critic, reviewer ∈ {⊥,PASS,FAIL},
                       ac_linkage, masking, mutation ∈ {⊥,PASS,FAIL,N/A},
                       diff_hash : Hash } }                 -- verdict keyed to diff
E_in5  = { diff_committed(u, hash), regate(u, new_hash) }
E_out5 = { gate_verdict(u, hash, green?), masking_flag(u, deletion),
           challenge_route(u, test, clause) }
→ : run BOTH oracles + 3 mechanical gates on EXACTLY diff=hash, dispatching
    build/test/mutation through the toolchain behaviour (D-S2). A verdict is
    valid ONLY for its diff_hash (INV-1). Stage is horizontally parallel: G
    concurrent gate runs across distinct PRs.
Inv5 : INV-1 (gate-before-merge, keyed to content hash), INV-5/6/7 mechanical
       checks (masking, mutation, ac-linkage), INV-9 (incomplete-fix test),
       CON-6 (verdict per required half), FR-4.1/4.3.
```
Rate justification: R4 is **parallelisable across PRs** (each gate run is
independent, disjoint by INV-13) but each run is toolchain-bound (~T_g). This
is the stage that suffers **re-gate amplification** (§5): G must scale with W.

### C6 — Merge Authority (R5; the funnel — serialized, concurrency = 1)

```
S6 = { merging   : Option<Unit>,         -- |{merging}| ≤ 1 BY CONSTRUCTION
       main_head : Ref,
       main_health : {green, red},
       wait_queue : OrderedSet<Unit> }   -- green branches awaiting merge slot
E_in6  = { gate_verdict(u, hash, green=true), kill_signal, e_red_main }
E_out6 = { merged(u, commit), restale(in_flight_branches), regate(u),
           e_red_main, health_result(green?) }
→ : single critical section per merge:
      1. assert main_health = green                            (INV-4)
      2. read head(origin/main); if base(u) ≠ head ⇒ reject, emit regate(u) (INV-2)
      3. assert verdict.diff_hash = current diff ∧ green        (INV-1, CON-6)
      4. apply merge; advance main_head                         (INV-3: |merging|≤1)
      5. run post-merge health via toolchain; red ⇒ e_red_main, gate closed (INV-4)
      6. emit restale(all other in-flight)                      (forces Q-L2 re-gate)
    Serve wait_queue under fair policy (FIFO+aging) → LIV-2 (no merge starvation).
    kill_signal honoured only BETWEEN merges, never mid-step → INV-22.
Inv6 : INV-1, INV-2, INV-3, INV-4, INV-22, LIV-2, CON-6.
```
**The funnel.** Concurrency = 1 is structural (single serialized authority),
not a lock convention. This is the throughput governor (NFR-MERGE-RATE) and the
source of the rate impedance mismatch. `restale` is the amplification generator.

### C7 — Durable Decision Spine + Ledger (R6; the accounting authority)

```
S7 = { tree    : append-only log of {step, attempt, verdict, challenge, kill,
                                      escalation, terminal},   -- RPO=0
       ledger  : { spent, remaining, total },                 -- single writer
       attrib  : Spend → Owner }                              -- exactly-one owner
E_in7  = { record(fact), debit(action, cost), reserve(unit), reconcile_request }
E_out7 = { persisted_ack(fact), budget_state(spent,total), e_budget,
           resume_state(in_flight) }
→ : write-ahead — a fact is persisted BEFORE its effect is externally visible
    (INV-16). debit checked pre-admission; remaining<cost ⇒ deny + e_budget.
    spent+remaining=total maintained as a balance (CON-3); every spend has ∃! owner.
Inv7 : INV-16 (RPO=0 durable state), INV-21 (budget ceiling), CON-3 (budget
       conservation), CON-4 (cost attribution), CON-7 (escalation conservation),
       FR-6.1/6.3 (decisions not LLM-reasoning; replayable), LIV-5 (resume).
```
Single writer per datum (tree, ledger). Off-heap, survives node loss (D-S4,
NFR-CONTROL-AVAIL). The system of record — never a context window (FR-6.1).

### C8 — Isolation/Spawn Lifecycle Authority (cross-cutting; owns INV-10/14/15)

```
S8 = { boundary : Worker → {checkout, cache_namespaces, sandbox_fs},
       lease    : Worker → leased | reclaimed }
E_in8  = { start_unit(u)/spawn(w), worker_crashed(w), unit_terminated(u) }
E_out8 = { workspace_ready(w, position), captured(w, {staged,unstaged,untracked}),
           reclaimed(w) }
→ : on spawn — allocate complete isolation (checkout from verified ref + every
    mutable resource the toolchain adapter declares), set position. On exit
    (incl. crash) — CAPTURE all three dirty kinds BEFORE reclaim (INV-14, CON-5),
    then reclaim (INV-15). Capture is a lifecycle responsibility, not opt-in.
Inv8 : INV-10, INV-12 (sets position; worker verifies), INV-14, INV-15,
       CON-5, FR-3.1, FR-8.1, NFR-SPAWN.
```

### C9 — Toolchain Behaviour Registry (D-S2; volatile data behind a stable seam)

```
S9 = { adapters : Lang → {install, build, test, lint, mutation_run, package} }
E_in9  = { resolve(lang) }
E_out9 = { adapter(lang, ops) }
Inv9 : FR-3.3 (all gating/health/isolation dispatch through behaviour, never a
       hardcoded runner), FR-3.4 (self-hosting adapter is bootstrap), volatile
       (quarterly): adapters are DATA behind a stable engine (split-by-volatility).
```

### C10 — Action Classifier + Escalation/Kill Control (Cluster E safety)

```
S10 = { kill : armed | disarmed,                  -- operator state, separate from project
        E_set : closed,total escalation alphabet } -- INV-18
E_in10 = { proposed_action(a), non_progress(state), kill_signal,
           e_* (any escalation from any component) }
E_out10 = { deny(a, e_destructive), escalate(scope, e), notify_operator(e, snapshot),
            halt(scope) }
→ : classify(a) ∈ {safe, destructive}; destructive ⇒ deny + E-DESTRUCTIVE (INV-20).
    map every non-progress state to ∃! e∈E (INV-18); unmatched ⇒ E-UNCLASSIFIED.
    kill honoured at unit/merge boundaries only (INV-22, with C6).
Inv10 : INV-18 (total escalation), INV-19 (bounded retry, via PR-FSM state in C7),
        INV-20 (no unilateral destruction), INV-22 (clean kill), CON-7,
        LIV-1 (retry-ladder exhaustion ⇒ escalated terminal).
```

### C11 — Egress Governor (NFR-EGRESS; rate-limit boundary at the provider edge)

```
S11 = { bucket : Provider → tokens, breaker : Provider → {closed,open,half_open} }
E_in11 = { provider_call(p, req) }
E_out11 = { admit(req) | throttle(req) | break(p) }
→ : composed chain rate_limiter → circuit_breaker → budget_ledger(C7), in that
    load-bearing order (FR-7.2). 0 sustained 429-driven failures (NFR-EGRESS).
Inv11 : NFR-EGRESS, FR-7.2. (A back-pressure edge at the *external* rate boundary,
        complementing the internal merge back-pressure.)
```

### C12 — Telemetry/Reporter (observability; not on any critical path)

```
Inv12 : NFR-OBS-COVERAGE (100% paired spans), NFR-AUDIT (100% traceable merges),
        FR-9.1/9.2 (milestone+escalation reporting only, sourced numbers).
```

**Drop-a-component test.** Remove C1 ⇒ FR-7.3/INV-13 unenforced (unbounded
fan-out, no back-pressure). Remove C3 ⇒ INV-5 falls (no oracle separation).
Remove C6 ⇒ INV-1/2/3/4 fall. Remove C7 ⇒ INV-16/21, all CON-* lose their
authority. Remove C8 ⇒ INV-10/14/15. Each survives — minimal.

---

## 2. Composition graph

Edges: `{pre} event {post}` + **failure clause**; **[rate-class]**;
**⟂BP** = carries back-pressure (demand signal flows opposite to data).

```
 tracker ──tracker_snapshot──▶ C0 ──admit_candidate──▶ C1 ──start_unit──▶ C2
   [R0, idempotent re-read]        [R0]      ⟂BP            [R1]
                                    ▲                         │ frozen_scope
                    merge_funnel_depth, credit_demand         ▼
                                    │                        C3 ──ready_for_impl──▶ C4
                                    │ (back-pressure)         [R2, predecessor of R3]   [R3 fleet]
                                    │                                                     │ diff_committed(hash)
                                    │                                                     ▼
                                    └──────credit_demand◀── C5 ◀──regate───────────────  C5
                                              [R4 ⟂BP]      [R4, ×G parallel]              │ gate_verdict(green,hash)
                                                                                          ▼
                                                            restale ◀──────────────────  C6   [R5 funnel, conc=1]
                                                            (amplification)               │ merged(commit)
                                                                                          ▼
                                                                                        main / tracker
 All components ──record/debit──▶ C7 [R6 spine, RPO=0] ──budget_state/e_budget──▶ C1,C10
 C8 ⟂ C4 (spawn/capture/reclaim lifecycle)   C9 ⟂ C5,C8 (toolchain dispatch)
 C10 collects e_* from every component;  C11 wraps every provider_call.
```

### Per-edge contracts

| Edge | `{pre} event {post}` | Failure clause | Rate | ⟂BP |
|------|----------------------|----------------|------|-----|
| tracker→C0 | `{snapshot consistent} tracker_snapshot {backlog folded}` | snapshot stale ⇒ retry next tick (idempotent) | R0 | – |
| C0→C1 | `{open unit, deps clear} admit_candidate {candidate queued}` | C1 ready full ⇒ candidate held (back-pressure to intake) | R0 | **yes** |
| C1→C2 | `{conflict_check clear ∧ W<W_cap ∧ budget ok} start_unit {running++}` | any clause fails ⇒ serialize(u) (no spawn) | R1 | – |
| C2→C3 | `{spec exists for coord-heavy} frozen_scope {scope immutable}` | spec gap ⇒ need_spec, amend in-unit | R1→R2 | – |
| C3→C4 | `{paths_g frozen ∧ tests fail pre-impl} ready_for_impl {oracle separated}` | author fails ⇒ unit blocked, not spawned | R2→R3 | – |
| C4→C5 | `{diff committed, paths_g untouched} diff_committed(hash) {gateable}` | impl touched paths_g ⇒ masking_flag → critic; challenge ⇒ route to critic | R3→R4 | – |
| C5→C6 | `{both oracles PASS ∧ 3 mechanical PASS ∧ hash matches} gate_verdict(green) {mergeable}` | any FAIL ⇒ refine (same PR, N≤3) → pivot → escalate (INV-19) | R4→R5 | – |
| **C6→C5** | `{merge applied} restale(in_flight) {bases invalidated}` | re-gate storm ⇒ C5 emits credit_demand → C1 lowers W_cap | R5→R4 | **yes** |
| **C5→C1** | `{gate saturated} credit_demand {admission throttle}` | unbounded demand ⇒ W_cap→W* (§5) | R4→R0 | **yes** |
| **C6→C1** | `{wait_queue deep} merge_funnel_depth(q) {admission throttle}` | q>θ ⇒ W_cap shrinks (merge cannot absorb) | R5→R0 | **yes** |
| C6→main | `{green ∧ fresh ∧ health green} merged {main advanced}` | health red ⇒ E-RED-MAIN, merge gate closed (INV-4) | R5 | – |
| *→C7 | `{decision made} record/debit {persisted before visible}` | persist fails ⇒ block effect (write-ahead; no externalisation) | R6 | – |
| C7→C1 | `{remaining<reserve} budget_state {admission denied}` | exhaustion ⇒ e_budget → C10 halt (INV-21) | R6 | **yes** |
| C8⟂C4 | `{spawn} workspace_ready(position) ; {exit} captured then reclaimed` | crash ⇒ capture all 3 dirty kinds BEFORE reclaim (CON-5) | – | – |
| C11 wrap | `{within rate ∧ breaker closed ∧ budget} admit {call made}` | over limit ⇒ throttle; 5xx storm ⇒ break; no budget ⇒ deny | ext | **yes** |

The **four back-pressure edges** (C0→C1, C6→C5→C1, C6→C1, C7→C1) all terminate
at **C1's `W_cap`** — admission is the single throttle point. Data flows
forward R0→R5; demand/credit flows backward to C1. This is the defining
structure of the rate-split shape.

---

## 3. Enforcement matrix (R × C)

Every INV-/CON-/LIV- with its enforcing component(s). `★` = primary authority.

| Req | C0 | C1 | C2 | C3 | C4 | C5 | C6 | C7 | C8 | C9 | C10 | C11 | C12 |
|-----|----|----|----|----|----|----|----|----|----|----|----|----|----|
| INV-1 gate-before-merge | | | | | | ✓ | ★ | | | | | | |
| INV-2 freshness | | | | | | | ★ | | | | | | |
| INV-3 serial merge | | | | | | | ★ | | | | | | |
| INV-4 main health | | ✓ | | | | | ★ | | | | ✓ | | |
| INV-5 oracle separation | | ✓ | | ★ | | ✓ | | | | | | | |
| INV-6 gating-test immut. | | | | ✓ | ★ | ✓ | | | | | | | |
| INV-7 non-vacuous | | | | ✓ | | ★ | | | | ✓ | | | |
| INV-8 user-path oracle | | | ✓ | ★ | | ✓ | | | | | | | |
| INV-9 incomplete-fix | | | | | | ★ | ✓ | | | | | | |
| INV-10 resource isolation | | | | | ✓ | | | | ★ | ✓ | | | |
| INV-11 no shared tree | | | | | ✓ | | | | ★ | | | | |
| INV-12 verified position | | | | | ✓ | | | | ★ | | | | |
| INV-13 conflict-gated conc | | ★ | | | | | | | | | | | |
| INV-14 no lost work | | | | | ✓ | | | ✓ | ★ | | | | |
| INV-15 reclaimed isolation | | | | | | | | | ★ | | | | |
| INV-16 durable state | | | | | | | | ★ | | | | | |
| INV-17 crash containment | | | | | ★ | | | | ✓ | | | | |
| INV-18 total escalation | ✓ | | ✓ | ✓ | | | | ✓ | | | ★ | | |
| INV-19 bounded retry | | | | | | ✓ | | ✓ | | | ★ | | |
| INV-20 no destruction | | | | | | | ✓ | | | | ★ | | |
| INV-21 budget ceiling | | ✓ | | | | | | ★ | | | ✓ | ✓ | |
| INV-22 clean kill | | | | | | | ✓ | | | | ★ | | |
| INV-23 spec-before-code | | | ★ | | | ✓ | | | | | | | |
| INV-24 OTP non-negot. | | | | | | ★ | | | ✓ | | | | |
| CON-1 work conservation | ★ | ✓ | | | | | | ✓ | | | | | |
| CON-2 issue reconcile | ★ | | | | | | ✓ | ✓ | | | | | |
| CON-3 budget conservation | | | | | | | | ★ | | | | | |
| CON-4 cost attribution | | | | | | | | ★ | | | | ✓ | |
| CON-5 artifact (no lost) | | | | | ✓ | | | ✓ | ★ | | | | |
| CON-6 verdict conservation | | | | | | ★ | ✓ | ✓ | | | | | |
| CON-7 escalation conserv. | | | | | | | | ✓ | | | ★ | | |
| LIV-1 unit termination | | ✓ | | | | ✓ | | | | | ★ | | |
| LIV-2 merge progress | | ✓ | | | | | ★ | | | | | | |
| LIV-3 milestone term. | ✓ | | | | | | | ✓ | | | ★ | | |
| LIV-4 no livelock | | ★ | | | | | | | | | ✓ | | |
| LIV-5 recovery progress | | | | | | | | ★ | | | | | |
| NFR-EGRESS | | | | | | | | ✓ | | | | ★ | |
| NFR-OBS / NFR-AUDIT | | | | | | | ✓ | ✓ | | | | | ★ |

**No empty rows** (every requirement has ≥1 enforcer). **No empty columns**
(every component enforces ≥1 — drop-a-component passes).

**Cross-boundary invariant flagged (V3).** INV-2 freshness + INV-9
incomplete-fix span the C5↔C6 boundary: the verdict (C5) is keyed to a
`diff_hash`, and C6 re-validates `hash = current ∧ fresh` **inside its own
critical section** before merging. Mechanism = single-writer funnel (C6) that
re-reads, never a "the stages coordinate" hand-wave. CON-6 fresh-verdict is the
explicit cross-boundary contract.

---

## 4. Failure cuts

Each cut: severed edge / crashed component → behaviour in requirement terms.

**FC-1 — Buffer overflow at the merge boundary (R3 ≫ R5).**
Cut: C4 produces green branches faster than C6 can merge (`λ_merge > μ_merge`,
§5). Behaviour: `wait_queue` (C6) grows. C6 emits `merge_funnel_depth(q)`;
at `q > θ`, C1 lowers `W_cap` (back-pressure edge C6→C1) until `λ_merge ≤
μ_merge`. **No branch is lost** (CON-1/CON-5; all in C7 + worktrees). Liveness
degrades to bounded-throughput, not deadlock; LIV-2 fairness (FIFO+aging) keeps
any one branch from starving. **This is the designed-for cut.**

**FC-2 — A slow gate stage backing up fast implementers (R4 < R3 under
re-gate storm).** Cut: C6 `restale` invalidates W−1 branches per merge; C5
re-gate demand `(W−1)·μ_merge·T_g` exceeds G gate workers. Behaviour: gate
backlog grows; C5 emits `credit_demand` → C1 lowers `W_cap` to `W*` (§5). The
amplification is **bounded by admission**, not by adding gate workers
indefinitely. If demand still exceeds capacity at `W_cap = 1` (single-pipeline
serial), the toolchain is simply too slow — surfaced as a throughput report,
not a failure. INV-1/INV-2 never violated (no merge without fresh PASS).

**FC-3 — Budget exhaustion mid-fan-out.** Cut: `remaining < reserve(u)` while
W pipelines run. Behaviour: C7 denies new admission (C1), emits `e_budget`.
In-flight units run to their next clean checkpoint (commit or capture), then
halt; C10 raises **E-BUDGET** (global), notifies operator, records snapshot
(CON-7). No partial spend lost (CON-3: `spent+remaining=total` holds through
the halt). No mid-merge interruption (INV-22 honoured by C6). Overrun ≤ one
in-flight action's cost (NFR-BUDGET-PRECISION).

**FC-4 — Implementer crash mid-write.** Cut: C4 worker `w` dies with dirty
state. Behaviour: C8 captures all three dirty kinds (staged/unstaged/untracked)
**before** reclaim (INV-14, CON-5). Blast radius = {w} (INV-17); no peer or
coordinator affected (NFR-BLAST = 0). C1 re-admits or escalates per retry
ladder (INV-19). Semantic vs infra distinction (FR-8.2): a crash is supervised
restart; a gate FAIL is an FSM outcome, never a crash.

**FC-5 — Coordinator crash (C1/C7 process loss).** Cut: control plane dies
mid-cycle. Behaviour: durable spine (C7, RPO=0) is the system of record; on
restart the loop resumes from `resume_state` within NFR-RTO (≤60 s); no
decision re-done or lost (LIV-5, INV-16). In-flight worktrees survive (off-heap
C8 state + tree reconciliation CON-2). Idempotent resume: re-reading the tree
applies each fact once.

**FC-6 — Stale-base merge race (INV-2 boundary).** Cut: C5 issues a green
verdict for `hash`, then `origin/main` advances before C6 reaches the unit.
Behaviour: C6's critical section re-reads `head(origin/main)`; `base(u) ≠ head`
⇒ reject + `regate(u)` (no stale merge — INV-2 holds structurally). Worst case
under heavy churn: a branch is perpetually restaled (Q-L1) → mitigated by
FIFO+aging fairness (LIV-2) and by `W_cap` capping churn (§5).

---

## 5. Path arithmetic + queue stability

Anchors: `T_merge = 8 min` (NFR-MERGE-RATE p95) ⇒ `μ_merge = 0.125 /min =
7.5 merges/hr`. Gate wall `T_g ≈ T_merge` (both polyglot build+test bound).
NFR-CONC: `p50=4, peak=16`; stress at `64`.

### 5.1 The merge funnel is the binding governor

R5 is concurrency-1. Useful completed-unit throughput cannot exceed `μ_merge`.
With `W` parallel pipelines each producing a unit every `T_unit`, arrival at
the funnel is `λ_merge = W / T_unit`. Stability `λ_merge < μ_merge` ⇒

```
   W  <  μ_merge · T_unit  =  T_unit / T_merge   ≜  W*      (useful-concurrency ceiling)
```

| `T_unit` | `W* = T_unit / 8` | interpretation |
|----------|-------------------|----------------|
| 30 min | **3.8** | fast units ⇒ merge funnel saturates at W≈4 |
| 60 min | **7.5** | |
| 90 min | **11.2** | |
| 120 min | **15.0** | slow units ⇒ W≈15, right at NFR-CONC peak |

**Finding:** the deciding number is **not raw concurrency** but **merge-funnel
headroom `W* = T_unit / T_merge`**. Admitting `W > W*` yields **negative
return**: surplus pipelines only deepen `wait_queue` and (via `restale`)
amplify re-gate cost. C1 must cap `W_cap = min(NFR-CONC peak, W*)`, with `W*`
estimated online from measured `T_unit` and `T_merge`.

### 5.2 Re-gate amplification (Q-L2)

Every merge advances `origin/main` ⇒ restales the other `W−1` in-flight
branches (INV-2). Re-gate demand on the gate stage:

```
   D_regate(W) = μ_merge · (W−1) · T_g   [gate-service-units]
   first-pass demand at saturation = μ_merge · T_g = 1
   total gate demand = W ;  amplification ratio = (W−1):1
```

| W | re-gate demand | amplification |
|----|----------------|---------------|
| 4 | 3 | 3:1 |
| 16 | 15 | **15:1** |
| 32 | 31 | 31:1 |
| 64 | 63 | **63:1** |

Gate-stage stability requires `G ≥ W` parallel gate workers — gate parallelism
**must scale linearly with admitted concurrency**. At W=16, 15 of every 16
gate runs are re-gates, not first-pass. At W=64, 63:1 — the gate stage does
~63× wasted work per useful merge unless W is capped.

### 5.3 Where the design changes character

```
  W ≤ W*  (≈ 4–15 for plausible T_unit):  merge-funnel-bound.
          wait_queue short; D_regate modest; BOUNDED FAN-OUT suffices
          (admission cap at C1; no continuous-flow machinery needed).

  W > W*  (and especially W ≳ 32):  amplification-dominated.
          completed branches accumulate; (W−1):1 re-gate storm;
          merge starvation risk (LIV-2) without aging.
          REQUIRES a continuous back-pressure boundary that holds W_cap≈W*
          and a merge-batch / demand-credit discipline at C5↔C6 — NOT merely
          a fixed bounded fan-out.
```

**Threshold verdict.** The design's character changes at **`W ≈ W* = T_unit /
T_merge`**, which for the requirement envelope lands at **≈ 4–16**. NFR-CONC
peak=16 sits *at the knee* only when units are slow (`T_unit ≈ 120 min`); for
faster units the knee is at ~4. **The continuous back-pressure boundary is
warranted iff the operator wants `peak > W*`** — i.e. iff intended concurrency
exceeds merge-funnel headroom. Below `W*`, bounded fan-out with admission
control (C1) is sufficient and the heavier continuous-flow machinery is wasted
complexity. **This is the single number that decides the back-pressure
machinery** — and it is `W* = T_unit / T_merge`, not raw `C_max`.

### 5.4 Synchronous-path arithmetic (one unit, happy path)

```
  T_path = T_spawn + T_plan + T_oracle + T_impl + T_gate + T_merge
  p95:    ≤30s   +  ~      +   ~       + T_impl + T_g    + 8min     (NFR-SPAWN)
```
Tail amplification across the R4 mechanical gates (3 independent checks):
`P(all 3 ≤ t) = Π P(checkᵢ ≤ t)` — gate p95 is set by the **slowest** of
critic/reviewer/mutation, and mutation re-runs the suite (~`T_g`). Merge p95 is
`T_merge` and dominates the *committed-to-merged* sub-path.

### 5.5 Growth of stored sets

```
  |tree|   = O(units × attempts × verdicts)  — append-only, monotone (retention reqd)
  |ledger| = O(billable_actions)             — append-only debits
  |worktrees alive| = W ≤ W_cap ≤ 16         — bounded by admission (INV-15 reclaim)
  |agents alive|    ≤ A_max = 128            — NFR-AGENT-FLEET, within BEAM envelope
```

---

## 6. Open discriminating questions (with cost asymmetry)

**Q-1 — The real `W*`: what is `T_unit / T_merge`?** *(dominates everything.)*
The back-pressure machinery's necessity hinges on whether intended peak
concurrency exceeds `W* = T_unit / T_merge`. We have `T_merge ≈ 8 min`
`[ELICIT]` but **no measured `T_unit`** (full spawn→commit pipeline wall).
*Cost asymmetry:* if `T_unit ≈ 30 min`, `W* ≈ 4` and admitting NFR-CONC's
peak=16 is **4× over the funnel** — pure wasted fan-out + 15:1 re-gate storms;
the continuous back-pressure boundary is mandatory. If `T_unit ≈ 120 min`,
`W* ≈ 15` and bounded fan-out at peak=16 is fine — the heavy machinery is
wasted complexity. **Measure `T_unit` on the self-hosting adapter (FR-3.4)
before sizing `W_cap`.** Guessing high ⇒ re-gate storms + starvation; guessing
low ⇒ under-utilised node. → resolve by measurement, not choice.

**Q-2 — Merge cadence `T_merge` and the merge-fairness policy (Q-L1).** Is
`T_merge = 8 min` real, and is FIFO sufficient or is aging required? Under
heavy churn (`W` near peak) each merge restales the rest, so a large/slow
branch can be perpetually re-gated behind a stream of small ones (LIV-2
starvation). *Cost asymmetry:* FIFO is trivial but starves the unlucky branch
(unbounded latency for one unit — violates LIV-2); aging adds a priority term
to C6's `wait_queue` (modest). Since `T_merge` also *sets* `W*` (Q-1), the two
numbers are coupled: **a faster `T_merge` raises `W*` and reduces re-gate
pressure simultaneously** — investing in toolchain build/test speed is the
highest-leverage lever in the whole factory. → resolve in the C6 merge-authority
contract.

---

*Lens: RATE-SPLIT. Boundaries justified by flow rate AND invariant cluster
(they coincide). The merge funnel (C6, concurrency=1) is the rate-impedance
crux; the four back-pressure edges all terminate at C1's `W_cap`; the design's
character changes at `W* = T_unit / T_merge ≈ 4–16`.*
