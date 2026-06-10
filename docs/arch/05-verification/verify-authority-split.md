# Adversarial verification — candidate AUTHORITY-SPLIT

**Target:** `docs/arch/03-system-architecture/candidate-authority-split.md`
**Verifier stance:** attack, not grade. The shaper's prose is treated as an
unproven claim set; the structural artifacts (§0 assignment, §1 components, §2
edges, §3 R×C matrix, §5 path arithmetic) are the surface under attack.
**Crux under attack:** the claim (§3 "Why sole-writer-of-HEAD discharges
INV-1..4 directly") that A_MERGE, in "one atomic critical section," reads
`Green@hash`, compares `base` vs `head` with "no TOCTOU," reads `health`, and
thereby gets INV-1..4 **by construction**.

---

## Crux first — V1 on the "atomic cross-authority read" (FATAL)

Decompose A_MERGE's critical section (C8 `→`, steps 2–5) by *who owns each datum
read*:

| step | reads/writes | owner | kind |
|---|---|---|---|
| 2 | `A_GATE.Green(pr, hash)` | **A_GATE** (datum 7) | cross-authority request |
| 3 | own `head`, compare `base(diff)` | A_MERGE (datum 8) | local read |
| 4 | `health` | A_MERGE (datum 8) | local read |
| 5 | apply diff; `head := head'`; set `health` | A_MERGE | local write |

Steps 3–5 touch **only A_MERGE's own datum**. For those, "read and write are the
same owner's uninterrupted step ⇒ no TOCTOU" is **sound**. INV-3 (singularity)
and the *internal* freshness of `head` are genuinely discharged by construction.
The shaper is right about the half of the claim that concerns A_MERGE's own
state. **That is not where the proof fails.**

The proof fails at **step 2**, which is a read of a datum A_MERGE does **not**
own, across a boundary that D-S4 mandates be a *message*, not shared memory. Two
independent impossibilities sit here.

### Hole 1 — the verdict cell is MUTABLE; a snapshot of it is stale-able (the make-or-break)

`A_GATE(pr)` state is `verdict : (g, hash(diff)) → {PASS, FAIL, ⊥}` (C7). This
mapping is **not write-once**. The shape itself moves a verdict from PASS→FAIL
*after* it is first computed, on the **same `hash`**, in at least two flows:

- **Upheld challenge** (C7 `→`, "A challenge routes to an independent critic";
  FR-4.4): the critic can rule a previously-passing gating posture invalid.
- **Incomplete-fix detection** (C7 Inv, INV-9): "a finding falsifying a named
  AC ⇒ `Red`." Masking detection is explicitly **detection-only, surfaced to the
  critic asynchronously** (factory-loop gate 5.2). A late critic finding flips
  the verdict for an unchanged diff.

So `verdict(g, hash)` is a *mutable cell keyed by hash*, whose value can be
`PASS` at t₀ and `FAIL` at t₁ > t₀ **with `hash` unchanged**.

Now the interleaving (notation: `Vᴳ(hash)@t` = A_GATE's verdict value at time t):

```
t0 : A_GATE sets Vᴳ(hash) := PASS,  emits Green(pr, hash)
t0': A_MERGE (in crit. section) reads snapshot Green(pr, hash)        ← request/response
t1 : upheld challenge / late incomplete-fix finding lands;
     A_GATE sets Vᴳ(hash) := FAIL                                     (SAME hash)
t2 : A_MERGE, still in its critical section, checks base(diff)=head   ← TRUE (no merge happened between t0' and t2)
t3 : A_MERGE applies diff → head'                                     ← MERGE of a now-RED diff
```

At t3, `merge(d)` holds but `green(d)` is **false** (`Vᴳ(hash)=FAIL`). **INV-1
`□(merge(d) → green(d))` is violated.** CON-6 (`merged → fresh(verdict)`) is
violated with it.

The shaper's defence (§4 Cut B; §3 bullet "CON-6") only covers a *different-diff*
stale read: "a stale `Green(pr, hash_old)` simply fails to satisfy the
precondition for `hash_new`." That defence is keyed to **diff content changing**.
The interleaving above has **identical diff content** (same `hash`) and a
**flipped verdict value**. Hash-keying detects *content* staleness; it does
**nothing** for *value* staleness of a mutable cell. A_MERGE holds a snapshot of
a value that another authority revoked after the snapshot.

This is the textbook V1 impossibility: **an atomic read of another authority's
mutable state across an asynchronous boundary, acted upon without a version-CAS
or a lease, is a TOCTOU by construction.** The edge table's `Green idem on hash`
(§2) is idempotence on the *message* (re-delivering the same Green is harmless),
**not** a guarantee that the verdict's *current value* still equals the snapshot.
The "single atomic critical section" is a *local* critical section on A_MERGE
that contains a *non-atomic distributed read*; calling the whole thing atomic is
the error.

**Why the funnel does not save it.** A_MERGE being the sole writer of `head`
serializes *merges*; it does not serialize against *A_GATE's verdict writes*,
which are a different authority on a different timeline. Single-writer-of-HEAD
gives INV-2/3 over `head`; it gives **nothing** over a fact owned elsewhere.

**Fixable?** Yes, but not "by construction" — the claim that needs to die is the
"directly / by construction" framing. Closure needs an explicit mechanism the
shape lacks: either (a) **verdict immutability** — once `Green(pr, hash)` is
emitted it is monotone and a later finding must change the *hash* (force a new
diff/empty re-commit) so the snapshot self-invalidates, OR (b) a
**version/lease**: A_GATE issues `Green(pr, hash, epoch)`, A_MERGE's apply is a
conditional commit that A_GATE must confirm `epoch` is still current at apply
time (a two-phase handshake — i.e. exactly the atomic-commit-across-authorities
the shape claimed to avoid), OR (c) move the verdict cell *into* A_MERGE's
authority so the read is local (collapses A_GATE-verdict into A_MERGE — see V12).
The shape picks none; the prose asserts the result it has not built.

### Hole 2 — `head` ≠ `origin/main`; freshness is checked against a projection (V4/V1)

INV-2 requires `fresh(d) ⟺ base(d) = head(origin/main)` (invariants.md). A_MERGE
owns **datum 8 = "HEAD-of-`main`"**, but `origin/main` is an **external git
remote**, not an in-factory datum. A_MERGE's `head` is its *model* of the remote.
The shape never establishes that A_MERGE is the **sole pusher** to `origin/main`.
Counter-writers that the requirements actively admit:

- **E-DESTRUCTIVE / operator actions** (INV-20, FR-5.3): force-push, history
  rewrite, hotfix release are escalated *to a human who then executes them on the
  remote* — out-of-band of A_MERGE. After such an action, A_MERGE's `head` is
  stale and `base(diff)=head` certifies freshness against a phantom.
- **The bootstrap / self-hosting loop** (D-S2, FR-3.4) and any second factory
  instance: D-S4 is "distribution-ready"; nothing pins `origin/main` to one
  A_MERGE.

If any agent other than A_MERGE can advance `origin/main`, then step 3's
`base(diff)=head` is a comparison of `base` against a **stale local snapshot**,
and INV-2 is violated by exactly the cross-authority-stale-read pattern the crux
claims immunity from. This is the same disease as Hole 1, one datum over.

**Fixable?** Yes by *definition* — declare A_MERGE the sole writer of
`origin/main` and route every push (including post-escalation destructive ones)
back through it as the funnel. But the shape's §0 names the owned datum
"HEAD-of-`main`" ambiguously and never states the sole-pusher invariant, so as
written it is a HOLE, not a guarantee.

**V1 verdict: HOLE FOUND (FATAL on the crux).** The "no TOCTOU, single atomic
critical section ⇒ INV-1, INV-2 directly" claim is false as stated. INV-3 and the
internal-`head` half of INV-2 survive; INV-1 and external-`origin/main` INV-2 do
not, because both rest on an atomic read of another authority's mutable state.

---

## V2 — re-derive the problem from the shape

Reconstructing the problem from §0–§2 alone yields: "an autonomous pipeline that
turns tracker issues into gated, serialized merges with conserved budget/work and
total escalation." That matches the requirement intent. But fine-grained
authority splitting **smears the per-PR lifecycle across four authorities with no
single owner of the PR state machine**:

- attempt count / refine-pivot ladder → **A_POR(pr)** (datum 5)
- gating-test path set → **A_ORACLE(pr)** (datum 6)
- gate verdicts → **A_GATE(pr)** (datum 7)
- the decision log of all of the above → **A_TREE** (datum 2)

The "PR FSM" that FR-8.3 and INV-19 name as a **single authority** ("Authority:
the PR FSM") is, in this shape, a *distributed* FSM whose state lives in A_POR
(attempts/mode), A_GATE (verdict), A_ORACLE (paths), and A_TREE (the log). The
transition "FAIL ⇒ refine iff attempts<N" (C5) requires reading A_GATE's verdict
*and* A_POR's count *and* appending to A_TREE — a **three-authority transaction**
on every refine decision, each hop a stale-able snapshot (same disease as the
crux). The §1 co-location note ("datums 2,5,7,10 MAY share one host") is the
shape *quietly admitting this*: it proposes to physically recombine exactly the
authorities it logically split, because the PR lifecycle is one consistency
class. That is a tell that the split is along the wrong seam for these four.

**V2 verdict: HOLE FOUND (design-smell, not fatal).** The per-PR lifecycle has no
coherent single owner; it is reconstructed only by a multi-authority transaction
the shape pushes into an optional co-location footnote (Q-1) rather than the
component model. The problem *does* re-derive, but a cross-cutting behaviour (the
PR FSM, a stated single authority) was lost to over-splitting.

---

## V3 — orphan invariants & liveness starvation

**Coverage (rebuilt independently).** Every INV-1..24, CON-1..7, LIV-1..5 has at
least one `●` in §3. No literal orphan row. The shaper's "no empty row" claim is
**confirmed** at the level of *a mark existing*. But two rows have a `●` that
does not actually enforce, and several LIV rows hide a starvation hole:

- **INV-2 (freshness):** `●` is A_MERGE, but per Hole 2 the enforcer reads a
  projection of an external datum it may not solely own. The `●` is **nominal,
  not structural** — an orphan in disguise (V3's "both services check = zero
  enforcers" failure dressed as one enforcer).
- **INV-8 (user-path oracle):** `●(crit)` = A_ORACLE via *critic judgement*. The
  requirement text (INV-8) and nfrs.md (NFR-GAME-RESISTANCE) **explicitly say
  this is a residual NOT mechanically closed**. Marking it `●` overstates
  enforcement; it is at best `○ + human-judgement`, the weakest enforcer class
  under D-S1 (no human in loop). Acceptable only because the requirement itself
  concedes it — but the matrix should not show a solid `●`.

**Liveness starvation (the LIV attack the prompt flags).** Single-writer
authorities are safety-good but **availability-coupled**:

- **LIV-2 (merge progress)** depends on A_MERGE being *up*. §4 Cut A concedes
  "A_MERGE down ⇒ LIV-2 degrades (merge starvation) until restart." So LIV-2 is
  **conditional on A_MERGE availability**, an *unstated assumption* in the LIV-2
  row (matrix shows `●(fair q)` with no availability caveat). Worse:
  **availability of A_GATE is an unstated precondition of LIV-2 too** — A_MERGE's
  step 2 blocks on a request to A_GATE; if A_GATE(pr) is slow/down, the merge
  critical section *blocks*, and because A_MERGE is concurrency-1, **a single
  slow A_GATE response head-of-lines the entire merge funnel** (every other
  green+fresh PR starves behind it). This is a LIV-2 hole the matrix hides.
- **INV-21 / Cut A "A_BUDGET down ⇒ blocks all billable actions":** every agent
  action Debits A_BUDGET (§5). A_BUDGET unavailability ⇒ **total factory stall**,
  not graceful degradation. The shape calls this "fail-closed correct" (it
  preserves INV-21), but it is a **liveness catastrophe**: LIV-1 (unit
  termination) and LIV-3 (milestone termination) **cannot hold** while A_BUDGET
  is down, and nothing bounds A_BUDGET's downtime. A safety-preserving
  permanent-stall is still a LIV-1 violation. The matrix marks LIV-1 `●(bound)`
  at A_POR but A_POR cannot make progress without A_BUDGET admission — an
  **unstated cross-authority liveness dependency**.

**V3 verdict: HOLE FOUND.** No literal orphan, but INV-2's enforcer is nominal
(Hole 2), INV-8's `●` overstates a conceded residual, and LIV-1/2/3 carry
**unstated availability preconditions** on A_MERGE / A_GATE / A_BUDGET that a
single-writer-down turns into starvation. "Single-writer ⇒ safe" is bought with
"single-writer ⇒ availability SPOF for that datum's liveness," and the LIV rows
do not declare the price.

---

## V6 — path arithmetic

**Merge funnel μ ≈ 1/8min, ≤15 re-gates/merge @ peak-16.** The arithmetic is
*internally* consistent: at C_max=16, each merge advances `head` and forces ≤15
freshness re-checks; `work/merge ≈ T_merge·(1+15)` (§5). With `T_gate≈T_merge≈8
min`, that is ≈ **128 min of gating work per single merge** at peak. The shape's
own conclusion ("past ~32 A_MERGE saturates") *understates* the problem: even at
16, if re-gate cost is real and serialized through the A_MERGE→A_GATE request,
the **effective merge cadence is not μ=1/8min but μ/(1+15)≈1/128min** unless
re-gates run concurrently on independent A_GATE(pr) instances. The shape asserts
A_GATE is per-PR (`A_GATE(pr)`), so re-gates *can* parallelize — but then step 2
of A_MERGE blocks on up to 16 concurrent A_GATE responses, re-raising the
head-of-line hole from V3. **The arithmetic only closes if re-gating is
off-the-critical-path; the shape routes the Green read *onto* the critical path.
Internal contradiction.**

**A_BUDGET as hidden contention (confirmed).** Every billable action across ≤128
agent processes (NFR-AGENT-FLEET) Debits the single A_BUDGET writer. §5 claims
`μ_budget` is "enormous (in-memory CAS-style increment)." **But D-S4 forbids the
cheap mechanism:** "no shared-memory ETS across the coordination boundary," and
INV-16/RPO=0 requires each Debit be **write-ahead durable before the action's
effect is visible** (CON-3: "every billable action debits the ledger *before* it
is admitted"). A durable, serialized, single-writer counter at 128-process
fan-out is **not** an in-memory CAS — it is a synchronous durable write per
action. The §5 throughput claim ("trivially true at 10³–10⁵") **omits the
durability cost the shape's own INV-16 imposes**. This is a V6 UNCLEAR-becoming-
HOLE: the missing quantity is *Debit durable-write latency × action arrival
rate*; if Debits must be durable and serialized, A_BUDGET is a far tighter funnel
than §5 admits.

**SPOF / NFR-RTO story.** A_MERGE and A_BUDGET are each concurrency-1 single
writers. NFR-RTO (p95 ≤ 60s) governs *coordinator* restart; the shape does not
give a per-authority RTO. Cut A's "blocks until restart" means **availability of
the whole factory = min over authority availabilities**, i.e. a *series*
reliability composition (V6: availability = Π aᵢ), not the parallel resilience
the per-worker NFR-BLAST story implies. The merge/budget SPOFs are **series
elements**; NFR-CONTROL-AVAIL (single-node, durable reload within RTO) covers
*node* loss but not *per-authority* stall, and §5/§6 never compute the composite.

**V6 verdict: HOLE FOUND.** The ≤15-re-gate arithmetic contradicts the
on-critical-path Green read; A_BUDGET's throughput claim ignores the durability
cost its own INV-16 mandates; the merge/budget SPOFs compose in *series* and the
availability product is never stated.

---

## V12 — boundary count vs invariant count

~15 authorities vs 24 INV + 7 CON + 5 LIV. The prompt asks: which authorities buy
no **distinct safety invariant** and could collapse into a sibling? Run the
drop-a-component test:

| candidate merge | distinct invariant lost? | verdict |
|---|---|---|
| **A_COST → A_BUDGET** | CON-4 (∃! owner partition) vs CON-3 (ceiling). Different *balance equations*, BUT both are single-writer durable counters reconciled each cycle (`Σ A_COST = spent`). A_COST owns a *partition of the same quantity A_BUDGET totals*. | **Collapse candidate.** No distinct *safety* invariant — CON-4 is an accounting refinement of CON-3. §6 Q-2 keeps them split for *rate-class* reasons, but they share a rate class (per-action). Splitting buys only audit tidiness. |
| **A_POR → A_TREE** | INV-19 (bounded retry) is a *legality check on appended decisions* — exactly A_TREE's job (it already does terminal-state legality, C2). A_POR is a per-PR *projection* over A_TREE's log (the §1 note admits "logically hosted in A_TREE"). | **Collapse candidate.** A_POR enforces no datum A_TREE cannot; it is a view, not an authority (V4: projection, not co-writer). The shape *says so* in §0 ("logically hosted in A_TREE"). |
| **A_GATE-verdict → A_TREE** | CON-6/INV-1 verdict record. §0 note: "logically hosted in A_TREE." The verdict *value* is a decision; A_TREE is the decision log. | **Collapse candidate for the record;** but see Hole 1 — the verdict must be read *by A_MERGE atomically*, which argues the verdict cell wants to live in **A_MERGE**, not A_TREE and not its own authority. Either way A_GATE-as-separate-authority buys no distinct safety invariant; it buys a *role* (who runs the gate), which is an A_WORK-class concern, not a writer-of-record. |
| **A_CLASS** | INV-20. It is a **pure function over a versioned policy datum** (§0, C15). A pure function is *not an authority* (it writes nothing). | **Not an authority.** It is a predicate; listing it as a 15th writer-of-record inflates the count. The *policy datum* has a writer (quarterly); the classifier is stateless. V12: a boundary enforcing nothing it writes. |
| **A_ESC → A_TREE** | CON-7/INV-18. §0: "co-authored with A_TREE." Delivery (Notify) is an effect; the *record* is an A_TREE append. | **Partial collapse.** The record is A_TREE's; only the *operator-delivery side-effect* is distinct. That is an output adapter, not a writer-of-record. |

**Comparison to the 7-component minimal shape.** The distinct *writers-of-record*
that buy a distinct safety/conservation guarantee are roughly: **A_TREE**
(decisions: CON-1,2,6,7; INV-9,16,18,19,23 — absorbing A_POR, A_GATE-record,
A_ESC-record), **A_MERGE** (INV-1,2,3,4,22; and per Hole 1 it *should* own the
verdict cell it reads), **A_BUDGET** (CON-3,4; INV-21 — absorbing A_COST),
**A_WORK** (INV-10..17; CON-5), **A_SCHED** (INV-13; LIV-4), **A_TRACK** (CON-2
projection), **A_MEM** (FR-6.2). That is **7 authorities** — exactly the minimal
shape — with A_ORACLE/A_GATE/A_EGRESS/A_TOOL/A_CLASS recast as **roles, pure
functions, or governors that run *within* a writer's boundary** rather than as
writers-of-record.

**What the extra granularity BUYS:** independent *failure domains* (the only
honest justification — §1 says A_MERGE/A_WORK "MUST be independent ... different
availability profiles"). That justifies splitting **A_MERGE, A_WORK, A_BUDGET,
A_TRACK** out. It does **not** justify A_POR, A_COST, A_GATE-record, A_CLASS,
A_ESC-record as separate *writers* — those split by *role/noun*, not by a
distinct invariant or a stated rate/availability boundary. Each surplus writer
adds a failure cut (V8), an idempotence obligation, and — fatally for the crux —
**one more cross-authority snapshot read on the merge critical path.**

**V12 verdict: HOLE FOUND (over-granular).** ~5 of the 15 authorities
(A_POR, A_COST, A_GATE-as-record, A_CLASS, A_ESC-as-record) enforce no distinct
safety invariant and collapse into a sibling without losing a guarantee. The
defensible count is ~7 (the minimal shape), the surplus drawn by role/noun. The
granularity actively *worsens* the crux by multiplying cross-authority reads.

---

## Verdict

```
Pattern V1  (atomic cross-authority read — THE CRUX): HOLE FOUND (FATAL)
Pattern V2  (re-derive / lost PR-FSM owner):          HOLE FOUND
Pattern V3  (orphans + LIV starvation):               HOLE FOUND
Pattern V6  (merge/budget arithmetic & SPOF):         HOLE FOUND
Pattern V12 (over-granular authorities):              HOLE FOUND

OVERALL: FATAL
```

**Crux (the load-bearing claim) — FALSIFIED.** "A_MERGE in one atomic critical
section reads `Green@hash`, compares base/head with no TOCTOU, reads health ⇒
INV-1..4 by construction" is false. The single-writer funnel discharges INV-3 and
the *internal-`head`* half of INV-2 genuinely. It does **not** discharge INV-1:
the `Green` read is a snapshot of a **mutable** verdict cell owned by *another*
authority (A_GATE), and that verdict can flip PASS→FAIL on the *same hash* via an
upheld challenge or a late incomplete-fix finding (the shape's own INV-9/FR-4.4).
Hash-keying closes *content* staleness, not *value* staleness; acting on the
snapshot is a TOCTOU by construction. Nor does it discharge INV-2 against the
*external* `origin/main`, which A_MERGE does not provably solely write. Closing
either requires the very atomic-commit-across-authorities (lease / version-CAS /
verdict-immutability) the shape claimed to have avoided.

**Other holes:** (V2) the PR lifecycle is a distributed FSM with no single owner,
recombined only in an optional co-location footnote; (V3) INV-2's `●` is nominal,
INV-8's `●` overstates a conceded residual, and LIV-1/2/3 hide availability
preconditions on A_MERGE/A_GATE/A_BUDGET that a single-writer-down turns into
starvation; (V6) the ≤15-re-gate arithmetic contradicts routing the Green read
onto the merge critical path, and A_BUDGET's throughput claim ignores the durable
write per Debit its own INV-16 mandates.

**Over-granular authorities:** ~5 of 15 (A_POR, A_COST, A_GATE-as-record,
A_CLASS, A_ESC-as-record) buy no distinct safety invariant and collapse into a
sibling; the defensible writer-of-record count is ~7 (the minimal shape), the
surplus split by role/noun, which *worsens* the crux by adding cross-authority
reads on the merge path.

**Salvageability:** the *partition* is sound (single-writer-per-datum is the right
idea and genuinely discharges CON-1..5,7 and INV-3); the *crux proof* is not.
Salvage requires (1) making the gate verdict **monotone / immutable-per-hash** so
a revocation forces a new hash (snapshot self-invalidates), OR moving the verdict
cell *into* A_MERGE's authority; (2) declaring A_MERGE the **sole pusher** of
`origin/main` and funnelling post-escalation destructive pushes back through it;
(3) collapsing the ~5 role-authorities into their owning writers (→ ~7), removing
cross-authority reads from the merge critical path; (4) restating INV-1/2 as
"discharged by a named lease/immutability mechanism," not "by construction." With
those four, the shape is recoverable; as written, the central claim is FATAL.
```
```
