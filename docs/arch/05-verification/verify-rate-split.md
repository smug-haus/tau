# Verification — candidate RATE-SPLIT (adversarial)

Verifier with fresh context, no stake. Job: attack the structural artifacts and
the arithmetic, not grade the prose. Target:
`docs/arch/03-system-architecture/candidate-rate-split.md`.

The headline ruling is on **§5: is `W* = T_unit/T_merge` a stable operating
point or an optimistic upper bound the re-gate feedback loop erodes?** Ruling
below: **it is an upper bound, not a fixed point — the feedback loop the shaper's
own §5.2 introduces invalidates the §5.1 cap.** This is a HOLE in the central
quantitative claim, and it propagates to the back-pressure sizing.

---

## V6 — Path arithmetic (the key attack) — **HOLE FOUND**

### What is arithmetically correct

- The table in §5.1 computes `W* = T_unit/8` correctly: `30/8 = 3.75 ≈ 3.8`,
  `120/8 = 15.0`. The numbers match.
- The Little's-law / utilization derivation of the *merge-throughput bound* is
  dimensionally sound **as a bound on final-green arrival rate**:
  `λ_merge = W/T_unit`, `μ_merge = 1/T_merge`, stability `λ_merge < μ_merge ⇒
  W < T_unit/T_merge`. The boundary case `W=1 ⇒ T_unit > T_merge` is trivially
  true. As a *ceiling on useful merge throughput*, `W*` is the right shape.

### Where it breaks — the feedback loop the formula omits

The derivation treats `T_unit` as an **exogenous constant** (the §5.1 table
sweeps it as an input: 30/60/90/120 min). But §5.2 then asserts that **every
merge restales the other `W−1` in-flight branches**, and each restaled branch
must re-run a gate (cost `T_g ≈ T_merge`) *before it can re-qualify to merge*.
That re-gate is part of the branch's time-in-system. Therefore:

```
   T_unit  is NOT independent of W.
   T_unit(W) = T_base + T_queue(W) + n_restale(W)·L_regate(W)
```

where a branch waiting for the serial funnel is restaled on each of the ~`W−1`
merges that land ahead of it, and `L_regate` is itself a queueing latency on the
gate stage. Re-derive the gate-stage utilization from §5.2's own demand
equation `D_regate = μ_merge·(W−1)·T_g`:

```
   ρ_g = (W−1)·T_g / (G·T_merge)   with T_g = T_merge  ⇒  ρ_g = (W−1)/G
```

The shaper's prescription is `G = W` ("G must scale linearly with W"). Substitute:

```
   G = W  ⇒  ρ_g = (W−1)/W   →   0.75 (W=4),  0.94 (W=16),  0.98 (W=64)
```

**`G = W` does not stabilize the gate stage — it parks it at the edge of
saturation.** `ρ_g = (W−1)/W → 1` as `W` grows. Mean re-gate wait under an
M/M/1 approximation is `ρ_g/(1−ρ_g)·T_g = (W−1)·T_g` — at `W=16`, that is
`15 × 8 = 120 min` of re-gate latency *per restale*. "G must scale linearly
with W" is therefore **not a stability condition; it is the instability
boundary.** Stability needs `G` over-provisioned past `W`, e.g.
`G ≈ W/(1−ρ_target)`, which the linear claim does not contain.

### The fixed-point check — does W* self-consist?

Iterating `T_unit(W)` with the queueing terms (T_base = 30 min, T_merge = T_g =
8 min, G = W):

| W | T_unit(W) actual | "W* = T_unit(W)/T_merge" | self-consistency of the cap |
|---|------------------|--------------------------|-----------------------------|
| 4 | 150 min | 18.8 | `W ≤ W*` trivially true |
| 16 | 2070 min | 258.8 | `W ≤ W*` trivially true |
| 64 | 32790 min | 4098.8 | `W ≤ W*` trivially true |

The cap **collapses into vacuity**: because `T_unit` is inflated by the very `W`
admitted, `W* = T_unit(W)/T_merge` grows *faster than W*, so the admission rule
"admit while `W ≤ W*`" is always satisfied and caps nothing. Meanwhile the
*effective* useful merge rate **falls** as W rises (the funnel starves waiting
for a fresh-green head-of-queue branch):

| W | effective merges/hr, G=W | effective merges/hr, G=2W | ideal `1/T_merge` |
|---|--------------------------|---------------------------|-------------------|
| 2 | 3.75 | 5.62 | 7.5 |
| 4 | 1.88 | 4.69 | 7.5 |
| 16 | 0.47 | 3.98 | 7.5 |
| 32 | 0.23 | 3.87 | 7.5 |

Raising concurrency *reduces* throughput — the signature of a positive feedback
loop, not a stable governor. The thing that actually saturates first is the
**gate stage** (`ρ_g → 1`), which the merge-funnel formula does not model at all.

**Ruling:** `W* = T_unit/T_merge` is an **optimistic upper bound on merge
throughput, never a stable operating point.** The merge→restale→re-gate→inflated
`T_unit`→deeper queue loop is a fixed-point condition the §5.1 linear model omits;
under the design's own §5.2 amplification it does not converge at `W*`. The
"single number that decides the back-pressure machinery" is mis-stated: the
binding constraint is gate-stage stability (`ρ_g < 1` with margin), and the cap
that matters is set by `G` provisioning and re-gate latency, not by
`T_unit/T_merge`.

**Fixable?** Yes, without changing the boundary: (a) re-derive the cap from
gate-stage utilization `ρ_g = (W−1)·T_g/(G·T_merge) < 1−ε`, giving
`W < 1 + (1−ε)·G·T_merge/T_g`; (b) state `T_unit(W)` as endogenous and admit on
the *measured time-in-system*, not a base constant; (c) add **merge-batching**
or a **rebase-train** at C6 so one re-gate covers many branches (amortizes the
`(W−1)` restale fan-out to `O(log W)` or `O(1)`), which is the only structural
move that breaks the feedback loop rather than throttling against it. The
shape's §5.3 gestures at "merge-batch / demand-credit discipline" but does not
size it; that hand-wave is exactly where the binding arithmetic lives.

---

## V1 — Does it assume an impossibility? (back-pressure overflow) — **HOLE FOUND**

The four back-pressure edges (C0→C1, C5→C1, C6→C1, C7→C1) all terminate at
C1's `W_cap`. The claim (FC-1) is that this prevents merge-buffer overflow. Two
gaps:

1. **Delayed-signal / bufferbloat.** `merge_funnel_depth(q)` is sampled at C6
   and must traverse C6→C1, after which C1 lowers `W_cap`, after which fewer
   units are *admitted*. But units already in `running` (up to `W`) keep
   producing green branches into `wait_queue` regardless — admission throttling
   acts on *future* arrivals, not the W already in flight. With `T_unit` in the
   tens-to-hundreds of minutes, the control loop's dead time is `~T_unit`, far
   longer than the `T_merge`-paced arrival of green branches. A back-pressure
   loop whose dead time greatly exceeds its actuation period is the textbook
   bufferbloat / under-damped controller; `wait_queue` overshoots before
   `W_cap` bites. FC-1's "no branch is lost" is true (CON-1/CON-5 hold —
   branches sit in worktrees), but the *liveness* claim "degrades to
   bounded-throughput, not deadlock" is unproven: nothing bounds `wait_queue`
   depth or the per-branch wait during the dead-time window, and §5 gives no
   `θ` (the depth threshold) nor a settling-time argument.

2. **"Admission is the single throttle" assumes global instantaneous knowledge.**
   `W_cap` is shared mutable control state read at admission and written from
   four sources (C0, C5, C6, C7). Under D-S4 (distribution-ready, no `:global`,
   no cross-node ETS) the four demand signals are *messages* with their own
   latency; C1's view of funnel depth is stale by the in-flight time of the
   `merge_funnel_depth`/`credit_demand` messages. The shape asserts
   `W_cap = min(peak, W*)` "estimated online" but never states the staleness
   bound `Δ` on that estimate. Per notation.md, eventual consistency without a
   stated `Δ` is unverifiable — and here the estimate drives the one throttle
   the whole overflow argument rests on.

**Ruling:** the back-pressure structure *prevents loss* (conservation holds) but
does **not** demonstrably *prevent overflow of `wait_queue`* nor bound its
liveness degradation, because the controller's dead time (`~T_unit`) dominates
its actuation period (`~T_merge`) and the throttle reads a signal of unstated
staleness. **Fixable?** Yes: add a hard cap on `|wait_queue|` that pauses
*commit* (not just admission) — i.e. back-pressure must reach the *running*
fleet C4, not only future admission at C1 — plus a stated `Δ` on the funnel-depth
estimate. This is a real structural gap: every back-pressure edge terminating at
C1 is the bug, not the feature — C1 governs *arrivals*, and overflow is a
*departure-side* (merge) problem.

---

## V2 — Re-derive the problem from the shape — **PASS (with one fracture, see V3)**

Reconstructing the business problem from the 13 components alone: intake
reconciler + admission + plan + oracle + fleet + gate + serial-merge + ledger +
isolation + toolchain + escalation + egress + telemetry → "an autonomous,
polyglot, single-node software factory that takes tracker issues to gated merges
with no human in the per-step loop." That reconstructs FR-1..FR-9, D-S1..S4
faithfully; no component answers a question nobody asked, and no requirement
lacks a path. The R×C matrix rebuilt independently shows **every INV/CON/LIV has
exactly one `★` primary** (36/36) and **no empty rows**. The reconstruction
matches the brief. The one structural fracture this exposes is INV-2's
enforcement spanning C5↔C6 — handled under V3.

---

## V3 — Orphan invariants — **PASS (the flagged one is genuinely funnelled)**

The shape itself flags the cross-boundary case: **INV-2 (freshness) + INV-9
(incomplete-fix) span C5↔C6.** Per V3 the test is: is there a single component
whose transition relation makes the violating state unreachable, or is it "both
check" (= zero enforcers)?

- **INV-2:** C5 issues `gate_verdict(u, hash, green)`; C6's critical section
  (§1 C6 step 2) re-reads `head(origin/main)` and rejects if `base(u) ≠ head`.
  The merge *cannot* proceed without C6's own fresh re-read — this is a **funnel**
  (all merge writes pass through the single serialized C6), not a "both check".
  The verdict's `diff_hash` keying (CON-6) is the escrow that makes C6's local
  check sufficient. **Genuinely enforced.** PASS.
- **INV-9:** primary `★` at C5, `✓` at C6. The incomplete-fix test is a property
  of the *gate verdict computation* (does a finding falsify a named AC?), which
  is wholly inside C5; C6 only consumes the boolean. Single owner. PASS.

No orphan among the 36. The matrix's "exactly one ★ per req" property (verified
independently) is the structural guarantee against the shared-invariant-owned-by-
nobody failure V3 hunts for. **PASS.**

---

## V12 — Boundary count vs invariant count — **HOLE FOUND (one collapsible component)**

13 components vs 24 safety invariants — *more invariants than components*, so the
gross V12 test (components ≫ invariants) does **not** fire. But the per-component
drop test surfaces three components that are primary `★` owner of **zero**
INV/CON/LIV:

- **C11 (egress)** — primary of NFR-EGRESS (a quantified NFR with its own
  compose-order contract FR-7.2) and a distinct *external* rate boundary. Keep:
  it owns a real requirement the merge interior does not.
- **C12 (telemetry)** — primary of NFR-OBS/NFR-AUDIT. Keep: a cross-cutting
  observability requirement, off the critical path by design.
- **C9 (toolchain registry)** — primary of **no INV/CON/LIV at all**; its matrix
  row is all `✓` (INV-7, INV-10, INV-24 — it merely *dispatches* checks others
  own). Its only ownership is FR-3.3/3.4 plus a **volatility split** (quarterly
  adapters behind a stable engine).

**C9 is the V12 target.** It enforces no safety invariant of its own; it is a
dispatch seam. Per V12, merge it into C5 (gate) + C8 (isolation), the two
components that actually *invoke* the toolchain — unless the volatility split is
accepted as independent justification. The split *is* a legitimate boundary
rationale (a behaviour seam isolating quarterly-volatile data from the stable
engine, per the shaper's stated bias and D-S2). **Ruling:** C9 survives **only**
on the volatility argument, not on any invariant it enforces — which is exactly
the "exists to mark a property, enforces nothing" pattern V12 warns about. The
shape should either (a) state the volatility-split justification explicitly in
the drop-a-component test (it currently omits C9 from that test entirely — the
§1 drop test covers only C1/C3/C6/C7/C8), or (b) collapse C9 into C5/C8.
**Fixable?** Yes — add the C9 volatility justification to the drop test, or merge.
This is a documentation/justification HOLE, not a boundary error.

---

## Secondary findings (not in the mandated set, surfaced in passing)

- **V9 / freshness clock (minor).** INV-2 compares `base(u)` against
  `head(origin/main)` read inside C6's section — both are VCS refs read by one
  authority, not cross-component timestamps. No wall-clock coordination hole.
  PASS. But LIV-2 fairness ("FIFO+aging") under the re-gate feedback (V6) is
  *more* fragile than stated: as `W` rises the perpetually-restaled-branch risk
  (Q-L1, FC-6) grows with the same `(W−1)` factor that drives the V6
  instability. Aging is not optional at any `W > W*`; the shape lists it as a
  Q-L1 open question when V6 shows it is mandatory.

- **V8 / FC-2 self-rebuts.** FC-2 says re-gate amplification "is bounded by
  admission, not by adding gate workers indefinitely," then concedes "If demand
  still exceeds capacity at `W_cap = 1` … the toolchain is simply too slow."
  That concession is the V6 result in disguise: at `G = W` the gate stage is
  already saturated for any `W > 1`, so the system is forced toward `W_cap = 1`
  (serial) far earlier than the `W* ≈ 4–16` headroom advertises. The advertised
  operating range `4 ≤ W ≤ 16` is largely unreachable without `G ≫ W` or
  merge-batching.

---

## Verdict

```
**Verdict**: HOLE FOUND  (central quantitative claim + back-pressure model)

Per-pattern:
  V1  (impossibility / overflow)      : HOLE  — back-pressure throttles arrivals,
                                          not departures; controller dead-time
                                          (~T_unit) ≫ actuation period (~T_merge);
                                          no |wait_queue| bound, no staleness Δ.
  V2  (re-derive)                      : PASS  — shape reconstructs the brief.
  V3  (orphan invariants)             : PASS  — 36/36 single-★; INV-2 genuinely
                                          funnelled through C6's critical section.
  V6  (path arithmetic) [HEADLINE]    : HOLE  — W* = T_unit/T_merge is an upper
                                          bound, NOT a fixed point. T_unit is
                                          endogenous in W via re-gate; G=W parks
                                          the gate stage at ρ_g=(W−1)/W→1 (edge of
                                          instability, not stability); effective
                                          merge rate FALLS as W rises. Cap is
                                          vacuous; binding constraint is gate-stage
                                          ρ_g<1 with margin, which the formula omits.
  V12 (boundary vs invariant count)   : HOLE  — C9 enforces zero INV/CON/LIV;
                                          survives only on a volatility split the
                                          §1 drop test never states. Collapse or
                                          justify.

**Overall**: HOLE-FOUND (not FATAL — the boundaries are right; the SIZING
arithmetic and the back-pressure actuation point are wrong and fixable).
```

**Salvageability — HIGH.** The 13-boundary decomposition is sound: invariant
ownership is clean (V2/V3 pass), and the rate-split coincides with the
invariant-cluster split as claimed. The defects are all in §5 (the arithmetic)
and in *where* back-pressure acts, not in the component set:

1. Replace the `W* = T_unit/T_merge` admission cap with a gate-stage stability
   cap `W < 1 + (1−ε)·G·T_merge/T_g`, and model `T_unit(W)` as endogenous.
2. Add **merge-batching / rebase-train** at C6 to amortize the `(W−1)` restale
   fan-out — the only structural fix that breaks the feedback loop instead of
   throttling against it. §5.3 names this but does not size it; that is where
   the real arithmetic belongs.
3. Route back-pressure to the *running fleet* (C4 commit-pause), not only to C1
   admission, and add a hard `|wait_queue|` ceiling plus a stated staleness `Δ`
   on the funnel-depth estimate.
4. Either fold C9 into C5/C8 or add its volatility justification to the
   drop-a-component test.

None of these moves a boundary; all are corrections to the quantitative layer
and the actuation point. The shape is a viable base once §5 is re-derived.
