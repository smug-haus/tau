# Adversarial verification — candidate-minimal

Verifier with fresh context, no stake in the design. Job: ATTACK. Target:
`docs/arch/03-system-architecture/candidate-minimal.md` (the 7-component MINIMAL
shape). Mandatory patterns: V1, V2, V3, V6; plus V5 (too-simple). Each reported
PASS/HOLE with the component/edge/invariant cited and the exact failure scenario.

---

## V1 — Does any component or edge assume an impossibility?

### V1.a — The merge "atomic read of green ∧ fresh ∧ health" — **HOLE (TOCTOU across three authorities)**

- **Location:** C7 §1, the merge critical section, steps 2–5; the prose claim
  "freshness re-check *inside* the same critical section as the merge."
- **Pattern:** V1 (atomic commit across authorities without blocking).
- **Why it breaks.** The critical section reads from **three independent
  authorities** and the lock only serializes C7 against *itself*:
  - step 2 reads `head(origin/main)` — authority = the **external VCS**;
  - step 3 reads `green(d̂)` from **C1's VerdictStore** — authority = C1;
  - step 5 applies the diff to **origin/main** — authority = the external VCS
    again.

  C7's `merge_lock` is C7-local mutual exclusion. It does **not** lock
  `origin/main`. The shape itself states C5's agent workers hold *private
  checkouts* and push, and that the only thing forbidden is a non-C7 *merge*. But
  nothing in the shape forbids a force-push or branch update to `origin/main` by
  an external actor (operator, CI, a side-effect of a destructive action that is
  *requested-then-denied* but whose upstream push already happened). More
  importantly, even with C7 as sole merger, the window between step 2 (read head)
  and step 5 (apply) is non-zero, and the apply is "the atomic VCS commit"
  against a remote whose head C7 only *sampled* at step 2. If `origin/main` is a
  real remote (D-S4 says state on disk/remote, not BEAM memory), the
  read-head→apply pair is a classic compare-and-swap that the shape never states
  is executed as a CAS. A plain "read head, later push" is TOCTOU: between the
  read and the push another writer advances head and the push either fast-forward
  -fails (caught — fine) **or** is a non-FF apply that silently rebases
  (INV-2 violated: `base(d̂) ≠ head` at the *apply* instant, not the *read*
  instant).
- **The hidden assumption:** that "merge authority is sole writer of `main`" ⇒
  "read-head and apply are atomic." They are atomic **only if** the apply is a
  conditional CAS (`git push --force-with-lease`-style expected-head guard, or a
  server-side ref-update precondition). The shape asserts atomicity in prose
  ("apply atomically … apply-or-not, no in-between") but the no-in-between
  property is about *partial* application, not about *concurrent head advance*.
  Those are different impossibilities; the shape conflates them.
- **Fixable?** Yes, cheaply, but it requires a stated mechanism the shape lacks:
  the apply MUST be a conditional ref-update keyed on the head read at step 2
  (`expected_old = head_step2`), and on CAS-fail loop back to step 2. Add that
  and INV-2/INV-3 hold. Until stated, the atomicity claim is prose over a TOCTOU.

### V1.b — "stateless-recoverable C2" + "RPO=0 durable C1" — **PASS**

- C2 holding no durable state and recovering by replay from C1's WAL is not an
  impossibility: it is the standard event-sourced/orchestrator-replay pattern.
  Write-ahead (durable-before-effect) makes the write durable *and then* the
  effect visible — not "durable and free simultaneously." No two-generals here
  because C1 is a single authority and C2 reads it; there is no second writer of
  the decision. **No hole.** (But see V1.c for the edge where the *effect* is an
  external VCS apply — the write-ahead ordering there is load-bearing and only
  partially specified.)

### V1.c — `merged(u,d̂)` idempotent-replay across the C2/C7/VCS boundary — **HOLE (lost-record window)**

- **Location:** Composition-graph edge **C2 → C7 `request_merge`**, the
  idempotence clause: "replay checks C1 for `merged(u,d̂)` first"; and failure cut
  #1.
- **Pattern:** V1 (exactly-once across a lossy boundary) / V8 (failure cut).
- **Why it breaks.** The sequence is: (i) C7 applies to VCS (external, durable),
  (ii) C7 records `merged(u,d̂)` to C1. These are **two authorities, one logical
  fact**. If C7 crashes *between* (i) and (ii) — VCS shows the merge, C1 does
  not — then on replay the idempotence check ("is `merged(u,d̂)` in C1?") returns
  **false**, and C7 re-reads head. Now `head = base(d̂)` is **already advanced by
  the very merge that landed**, so step 2 gives `base(d̂) ≠ head` → `reject_stale`
  → the unit is sent to re-gate a diff that **is already on main**. That is not a
  double-merge (good) but it *is* a CON-6/CON-1 accounting fault: a unit that is
  factually `merged` is recorded as `in_flight/refining`, and its issue may be
  re-worked — `|steps_recorded| ≠ |steps_executed|` (CON-2 falsified) until a
  reconcile pass catches it. The shape's reconcile (`reconcile(tracker_state)`)
  is the only backstop and it is described as a per-cycle *audit*, not a
  synchronous guard — so there is a window where CON-2 is violated and the
  shape's claim "no double-merge, holds" understates the actual residual (silent
  re-work, not silent double-merge).
- **Fixable?** Yes: the apply step must carry the C1 `merged` record into the
  *same* transaction boundary, e.g. by writing an intent-to-merge token to C1
  *before* the VCS apply (so replay finds the token and **probes VCS** rather
  than re-gating), or by making "is this diff already on main?" — not "is
  `merged` recorded in C1?" — the idempotence predicate. The shape uses the C1
  record as the idempotence key, which is exactly the side that can be lost.

### V1.d — Oracle separation as "cannot observe each other" — **PASS with a caveat**

- INV-5 only requires `author(test) ≠ author(impl)` and path-freeze-before-spawn.
  The shape enforces this by **spawn ordering** (a guard `∃ frozen paths_g(u)`),
  which is a real structural wall, not an observation-impossibility claim. The
  implementer *reads* `paths_g` (it must, to run the tests) but does not *author*
  them — INV-5 is about authorship, satisfied. **No impossibility assumed.**
  *Caveat (folded into V3 below):* the guard enforces *ordering*, not
  *distinct-identity*. See V3/INV-5.

---

## V2 — Re-derive the problem from the shape alone

Reconstructing from components + graph (ignoring the prose rationale):

- C1 durable system-of-record; C2 a control loop FSM that ticks, spawns, decides,
  escalates; C3 admits units under a 5-clause conflict check; C5 spawns/​isolates
  agent workers (test-author, implementer, critic, reviewer) and captures dirty
  state; C4 aggregates two oracle verdicts + three mechanical checks into
  `green`; C6 a per-unit retry FSM; C7 a serialized merger with freshness/health.

This **does** reconstruct "an autonomous, bounded-retry, gate-before-merge
software factory with isolated concurrent workers and durable decision state."
The autonomous-factory problem is recoverable from the shape. **No capability
silently lost at the gross level** — V2 PASS on reconstruction.

**But V2 surfaces one collapse-induced ambiguity (→ HOLE, escalated under V5):**
the **conflict check (INV-13)** lives in C3, but the **declared scope** it checks
against (files, codepoints, SPEC/D-blocks, gating-test paths) is produced partly
by C2 (`set_scope`) and partly by C5 (`oracle_frozen(paths_g)` — the gating-test
paths). So C3's 5-clause check at *admission time* (S1) cannot include the
gating-test-path clause, because `paths_g` is not frozen until S2 (test-author
runs **after** admission). The shape's own ladder is
`admitted → tested(paths_g frozen) → implemented`. **Admission precedes
gating-test-path freezing.** Therefore C3's clause "disjoint files **incl.
gating-test paths**" (INV-13, clause 2) is **structurally unenforceable at the
only point C3 acts** — it admits before the paths exist. This is a real
re-derivation failure: the minimal collapse put the conflict check in a component
that runs before one of its five inputs exists. See V3/INV-13 for the orphan
consequence.

---

## V3 — Orphan invariants (every INV/CON/LIV needs a real enforcer)

Rebuilt independently from the shape, not trusted from its matrix. Findings:

### Confirmed real enforcers (spot-checked, PASS)

INV-1 (C7 precond), INV-3 (C7 lock), INV-4 (C7 health FSM), INV-7 (C4 mutation),
INV-9 (C4 incomplete-fix), INV-11 (C2 holds no tree + C5 forks), INV-14/15/17
(C5 lifecycle/capture/crash-domain), INV-16 (C1 WAL), INV-18 (C2 catch-all),
INV-19 (C6 guard), INV-20 (C7 classifier), INV-21 (C1 compare-and-debit),
INV-22 (C2 boundary check), CON-1/3/4/5/7 (C1 single-writer balances), LIV-2
(C7 fair queue) — each has a single named component whose transition relation
makes the violating state unreachable. **PASS.**

### INV-13 conflict-gated concurrency — **HOLE (enforcer runs before its input exists)**

- Already derived under V2. C3 admits at S1; the gating-test-path clause of the
  5-clause check needs `paths_g`, frozen at S2 (post-admission). So at admission
  C3 enforces **four** of the five clauses; clause 2's gating-test-path component
  is checked **never**, or is re-checked nowhere after S2. Two units admitted as
  file-disjoint can have their *test-authors* (S2) independently choose
  overlapping gating-test paths in shared `test/support`, and nothing re-runs the
  conflict check after `oracle_frozen`. INV-13 is therefore **partially orphaned**
  for exactly the surface (`test/support` collisions) the requirements call out
  as "a new shared-`test/support` collision surface." The matrix cell "C3 · P
  5-clause" overstates: C3 cannot evaluate clause 2 in full at the only time it
  acts.
- **Fixable?** Yes but it moves a boundary: either (a) C3 must be re-consulted
  after S2 with the frozen `paths_g` and may *retroactively serialize* an
  already-admitted unit (which contradicts the "admission is monotone, decided
  once" claim that the shape uses to discharge LIV-4), or (b) `paths_g` must be
  declared at admission (pull test-path declaration before the test-author writes
  bodies). The minimal shape picked an ordering that makes (a) and the LIV-4
  monotonicity claim mutually inconsistent — see LIV-4 below.

### INV-5 oracle separation — **HOLE (guard checks ordering, not distinct identity)**

- The enforcer is a spawn-ordering guard: `spawn(impl)` iff `∃ frozen paths_g(u)`.
  This guarantees *the test-author phase happened before the implementer phase*.
  It does **not** guarantee `author(test) ≠ author(impl)` — the literal predicate
  of INV-5. Nothing in C5's transition relation binds the *identity* of the
  test-author agent to be distinct from the later implementer agent; a buggy or
  adversarial C2 (or a model-routing config, FR-7.4) could route the same agent
  identity to both roles, and the `∃ frozen paths_g` guard would still pass.
  Oracle separation's whole point (Cluster B: treat the implementer as
  adversarial) is *identity* distinctness, not merely *temporal* ordering. The
  shape enforces the weaker property and labels it INV-5.
- **Fixable?** Yes: C5 must record the test-author's agent identity into the
  frozen `paths_g` record and refuse to spawn an implementer with that identity
  (or assert role-exclusivity). Cheap, but currently absent — so as written,
  INV-5's falsification test ("a gating test whose authoring agent is the
  implementing agent") is **not** made unreachable. Orphan on the literal
  predicate.

### INV-8 user-path oracle — **partial orphan (acknowledged, PASS-as-flagged)**

- The shape flags this honestly (GAP-7, critic judgement + partial mechanical).
  Not a concealment. Accept as a *known residual*, not a shape defect — consistent
  with NFR-GAME-RESISTANCE explicitly declining to claim a number. **No new hole.**

### INV-2 freshness — **see V1.a (TOCTOU) — HOLE**, counted there, not double-counted.

### INV-23 / INV-24 (spec-before-code, OTP non-negotiables) — **HOLE (enforcer is "gate question", i.e. prose-by-proxy)**

- Matrix: INV-23 → "C4 M (gate Q)" + "C7 P"; INV-24 → "C4 M (gate Q)". A "gate
  question" routed to the critic/reviewer is **judgement**, not a mechanical wall.
  The requirements' own framing (invariants.md preamble) is that under D-S1 every
  invariant must be enforced *structurally*, "not by an agent choosing to obey
  prose." INV-23's structural part (does a touched file appear in a SPEC source
  map ⇒ require a named D-NNN) **is** mechanizable (path-set membership, exactly
  like gate 5.1) but the shape leaves it as a critic checklist item. INV-24's OTP
  checks have a partly-mechanical enforcer (`compile --warnings-as-errors`,
  credo, dialyzer) that the shape mentions in the *requirement* text but does
  **not** wire into C4's transition relation — C4's `→` lists only g5.1/g5.2/g5.3
  + incomplete-fix; the lint/compile gate is absent from C4's enumerated mechanical
  checks. So INV-24's mechanizable half is unenforced by any named transition,
  and INV-23's mechanizable half is demoted to judgement. **Partial orphans.**
- **Fixable?** Yes, cheaply: add the SPEC-source-map-membership check and the
  toolchain `lint/compile` invocation to C4's mechanical-check set (the toolchain
  behaviour FR-3.3 already exists to host them). The boundary is right; the
  transition relation is under-specified.

### CON-2 issue reconciliation — **HOLE (no synchronous enforcer; audit-only)**

- Matrix: "C1 SW fold" + "C2 triggers". But the *fold* is `reconcile(tracker_state)`
  described as a per-cycle audit, and the C2/C7/VCS lost-record window (V1.c)
  produces states where `state_tree(i) ≢ state_tracker(i)` between reconciles.
  CON-2 is a balance that must hold in **every reachable state** (conservation.md:
  "must hold in every reachable state"); an audit that *detects drift each cycle*
  does not make the drifted state unreachable — it makes it *eventually detected*.
  That is a liveness property (drift ↝ detected), not the safety conservation law
  CON-2 states. **Orphan as a safety invariant; only a liveness backstop exists.**
- **Fixable?** Only by closing V1.c (make merge-record and VCS-apply one atomic
  fact). Same root cause; same fix.

### NFR-AUDIT / NFR-OBS-COVERAGE — flagged by the shaper as "no dedicated component,
query/emission over C1." For NFR-AUDIT: acceptable *iff* the lineage is truly a
C1 invariant — but V1.c shows the `d̂ → merged` link can be lost on a crash window,
so the "100% traceable" claim inherits the V1.c gap (a merge on `main` with no C1
`merged` record is, transiently, a `main` commit with a broken lineage link →
NFR-AUDIT < 100%). **Counted under V1.c.** Telemetry emission as a per-component
obligation with no enforcer is a genuine but low-severity orphan (no *safety*
invariant rests on it); accept as flagged.

### Orphan summary

| Req | Claimed enforcer | Verdict |
|---|---|---|
| INV-2 | C7 freshness in-section | HOLE (V1.a TOCTOU) |
| INV-5 | C5 spawn-ordering guard | HOLE (ordering ≠ identity) |
| INV-13 | C3 5-clause at admission | HOLE (clause 2 input absent at admission) |
| INV-23 | C4 "gate question" | HOLE (mechanizable half left as judgement) |
| INV-24 | C4 "gate question" | HOLE (lint/compile not in C4's `→`) |
| INV-8 | critic + partial mech | partial orphan — **accepted as flagged** |
| CON-2 | C1 per-cycle audit | HOLE (audit ≠ safety enforcer; V1.c) |
| NFR-AUDIT | C1 lineage query | degraded by V1.c |
| NFR-OBS | per-component emission | low-sev orphan — accepted as flagged |

---

## V6 — Path arithmetic

### Stage count — **PASS**

intent → merged path: S1 admit → S2 freeze tests → S3 implement → S4 gate →
S5 merge+health = 5 serialized-per-unit stages, of which only S5 is
globally serialized. The count is correct and the "only S5 serialized" claim is
right for the *happy* path.

### Bottleneck identification — **PASS on identity, HOLE on the stability argument**

- The shape names S5 (merge) as the throughput bottleneck: μ_merge = 1/8min =
  7.5 merges/hr. Correct identity.
- **The stability argument is circular / under-justified.** The shape argues
  `λ_merge < μ_merge` because "upstream (S2+S3+S4) ≫ S5, so the *production* of
  merge-ready diffs is throttled by upstream latency." This conflates **per-unit
  latency** with **system throughput**. With C=16 units in flight *in parallel*,
  upstream produces merge-ready diffs at rate ≈ C / T_upstream, not 1 /
  T_upstream. If T_upstream ≈ 40 min and C = 16, the **production** rate of
  merge-ready diffs is 16/40min = 24/hr — which **exceeds** μ_merge = 7.5/hr.
  So `λ_merge (24/hr) > μ_merge (7.5/hr)`: the merge queue is **not**
  unconditionally stable at peak; it is stable only if upstream *latency* is high
  enough relative to *both* T_merge *and* C that 16/T_upstream < 7.5/hr, i.e.
  T_upstream > 16/7.5 hr ≈ 128 min ≈ 2.1 hr per unit. The shape asserts
  stability without stating this required `T_upstream > 2.1 hr` floor. At the
  proposed peak=16 with a plausible sub-2-hr per-unit cycle, **the merge queue is
  unstable** and grows without bound — exactly the condition the shape claims is
  avoided "structurally."
- **Pattern:** V6 (λ<μ at peak must be shown, not asserted).

### Freshness re-gate amplification — **HOLE (the amplifier is under-counted)**

- The shape's own "amplifier" clause: each S5 merge forces ≤ C−1 in-flight units
  to re-gate (re-run S4). At C=16 that is ≤15 re-gates **per merge**. Re-gates
  are not free upstream production — they are **forced rework** injected at merge
  rate μ_merge. The re-gate load on the S4 gate capacity is
  `λ_regate ≈ μ_merge × (C−1) = 7.5/hr × 15 = 112 re-gates/hr`. Each re-gate
  consumes a gate slot for ~T_gate. For the gate stage not to saturate,
  S4 capacity must absorb 112 re-gates/hr **on top of** first-pass gates. The
  shape claims "peak=16 is chosen *precisely so* this stays sub-super-linear"
  and that admission control suffices — but it never shows S4's service capacity
  exceeds 112/hr at T_gate. If T_gate ≈ T_merge ≈ 8 min and gates run with
  concurrency ≤ C = 16, S4 throughput ceiling ≈ 16/(8min) = 120/hr — i.e. the
  re-gate load (112/hr) consumes **~93% of all gate capacity**, leaving ~8/hr for
  first-pass gates. That is a near-saturated gate stage at the *recommended*
  peak, not a comfortable margin, and it makes forward progress (first-pass
  gates) a thin residual of capacity consumed by re-gate churn. The "no 8th
  component needed below ~32" claim rests on an unstated and, on these numbers,
  **false** capacity margin at 16.
- **Fixable?** The fix is precisely the 8th component the shape defers (a buffered
  /batched merge-integrator that coalesces freshness re-gates, or a merge-train
  that rebases-and-gates a batch once). So this is not a cheap parameter tweak —
  it is the boundary the shape bet it could omit, and the arithmetic at the
  *recommended* peak=16 (not the claimed ~32 threshold) already pushes the gate
  stage to saturation. The threshold is mis-estimated by ~2×.

---

## V5 — Too-simple check: did any collapsed boundary silently drop an invariant?

The shape claims three non-collapsible boundaries (oracle author/implementer,
merge serialization, durable state). Per the brief, verify that boundaries it
**did** collapse don't drop an invariant.

### Collapse: conflict-check input split across C2/C3/C5 — **OVER-COLLAPSE (drops INV-13 clause 2)**

- Covered under V2/V3. The conflict check was kept in C3 but its gating-test-path
  input was left in C5's later phase. The boundary that *should* exist — a
  re-admission / scope-finalization check after `oracle_frozen` — was collapsed
  away. Result: INV-13 clause 2 + the LIV-4 monotonicity claim are mutually
  inconsistent. **Named over-collapse.**

### Collapse: CON-2 reconciliation folded into a per-cycle audit on C1 — **OVER-COLLAPSE (drops CON-2 as safety)**

- Covered under V3. Folding reconciliation into an audit downgrades a *safety*
  conservation law to a *liveness* "eventually detected." The minimal shape
  collapsed the synchronous tracker-tree consistency boundary into an
  after-the-fact fold. **Named over-collapse**, root-caused to V1.c.

### Collapse: budget admission as "a pure guard, not a process" — **PASS**

- C1's compare-and-debit + C3's precheck genuinely discharge INV-21/CON-3 with no
  dropped invariant; budget needs no separate component at single-node scale.
  The drop test is correct here. **No over-collapse.**

### Collapse: LIV-4 monotonicity claim — **HOLE (contradicted by the INV-13 fix path)**

- The shape discharges LIV-4 ("no livelock") by asserting C3's serialization
  decisions are *monotone* — "a blocked unit becomes admissible once its blocker
  is released … not re-litigated." But the only available fix for the INV-13
  clause-2 gap (V3) is to **re-litigate** admission after `oracle_frozen`
  (retroactively serialize an already-admitted unit when its frozen `paths_g`
  collide). That re-litigation is exactly the admit→conflict→withdraw cycle LIV-4
  forbids. So the shape is impaled on a dilemma: either INV-13 clause 2 is
  unenforced (V3 orphan) **or** LIV-4's monotonicity discharge is false. It
  cannot have both as written. **Structural, not cosmetic.**

### Merge-serialization and durable-state boundaries — **PASS as non-collapsible**

- Both are genuinely load-bearing and correctly kept. (The TOCTOU/lost-record
  *mechanism* inside C7/C1 is wrong — V1 — but the *boundary placement* is right.)

---

## Verdict

**Overall: HOLE-FOUND** (not FATAL — the boundary skeleton is sound; the holes
are mechanism gaps and one arithmetic mis-estimate, fixable without redrawing the
7-component frame, except the INV-13/LIV-4 dilemma which requires adding or
moving one boundary).

### Per-pattern

| Pattern | Verdict |
|---|---|
| **V1** impossibility | **HOLE** — V1.a merge-section TOCTOU (read-head→apply not stated as CAS); V1.c `merged` idempotence key is the losable side of a 2-authority fact. V1.b, V1.d PASS. |
| **V2** re-derive | **HOLE** — reconstructs the factory, but exposes the conflict-check-before-its-input ordering defect. |
| **V3** orphans | **HOLE** — INV-2, INV-5, INV-13, INV-23, INV-24, CON-2 lack a true structural enforcer (judgement-by-proxy, ordering≠identity, input-absent, or audit≠safety). INV-8/NFR-OBS accepted as flagged. |
| **V6** path arithmetic | **HOLE** — stage count PASS; bottleneck identity PASS; but the λ<μ stability argument is circular (ignores C-fold parallel production) and the re-gate amplifier saturates the gate stage at the *recommended* peak=16, not the claimed ~32. |
| **V5** too-simple | **HOLE** — two over-collapses (conflict-check input split; CON-2 audit) and the INV-13⊥LIV-4 dilemma. Budget-as-guard PASS. |

---

## 8-line summary

1. Overall: **HOLE-FOUND** — skeleton sound, mechanisms and one number wrong.
2. Highest-severity holes (2): **V1.a** merge read-head→apply is a TOCTOU, not the
   atomic CAS the prose claims (INV-2/INV-3 at risk); **V6** the re-gate amplifier
   saturates the gate stage (~93% capacity) at the *recommended* peak=16 — the
   claimed safe-to-~32 threshold is mis-estimated ~2×, and merge-queue stability
   is asserted, not shown (λ_merge ≈ C/T_upstream can exceed μ_merge).
3. Structural-dilemma hole (1): **INV-13 clause-2 ⊥ LIV-4** — the gating-test-path
   conflict clause needs an input that exists only after admission; the only fix
   re-litigates admission, which falsifies the monotonicity that discharges LIV-4.
4. Correctness/accounting holes (2): **V1.c** `merged(u,d̂)` idempotence keyed on
   the losable C1 record ⇒ transient mis-classification + **CON-2** drift.
5. Judgement-by-proxy orphans (2): **INV-23/INV-24** mechanizable halves left as
   "gate questions"/absent from C4's transition relation, violating the
   "structural not prose" mandate.
6. Identity-vs-ordering orphan (1): **INV-5** enforced as *ordering*, not
   *distinct author identity* — the literal falsification test stays reachable.
7. Accepted-as-flagged (not new holes): INV-8 (GAP-7), NFR-OBS emission.
8. **Salvageable by revision** (no full redraw) **except** the INV-13/LIV-4
   dilemma, which requires **one boundary moved/added**: a scope-finalization
   re-check after `oracle_frozen`, OR declaring `paths_g` at admission time. Both
   V1 holes are cheap mechanism fixes (CAS apply; intent-token before VCS apply);
   the V6 hole likely forces the deferred 8th component (buffered merge-integrator)
   at peak=16 rather than at ~32.
