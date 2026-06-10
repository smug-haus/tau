# Adversarial verification — VOLATILITY-SPLIT shape

Verifier with fresh context, no stake. Input: the shape's structural artifacts
(`candidate-volatility-split.md`) + the requirement set (`invariants.md`,
`conservation.md`, `liveness.md`, `nfrs.md`, `R-list.md`) + imposed constraints
(`scope-decisions.md`). The shaper's prose rationale is treated as unproven
claims. Job: ATTACK the policy-dependence of safety.

The headline target — attack (d), "the toolchain plugin executes the tests, so
can it fake the mutation-gate verdict and defeat INV-7 from inside the seam?" —
is ruled on first because it is the deepest, and it is a HOLE.

---

## Headline ruling — malicious toolchain adapter vs the mutation gate (INV-7)

**Verdict: HOLE FOUND (the shape's central strength claim is false as drawn).**

### The mechanism that opens it

The shape claims (§1.A C2, §3 row INV-7, §4 Cut A, §6 FLAG-1) that the mutation
check is an **engine** enforcer that "independently reverts production and
demands a real failing test," so a lying adapter "cannot move a vacuous diff to
`main`." Cut A states the lie is *"irrelevant, C2's mutation gate (engine)
independently reverts production and demands a real failing test."*

That word **independently** is the unproven claim. Trace what the engine can
actually do unaided. The control plane is language-agnostic by imposed
constraint **D-S2 / FR-3.3**: *"All gating, isolation, and health checks are
expressed against this behaviour, never against a hardcoded runner."* The
mutation check is `revert(¬paths_g)→merge_base ⇒ ∃t. fails` (C2 `→`, INV-7
falsification test: *"revert production to merge-base, run gating tests, none
fail"*).

Decompose that into engine-doable vs adapter-delegated steps:

1. `revert(¬paths_g) → merge_base` — a **git** operation. Engine-doable. ✓
2. **run the gating tests** — requires invoking `pytest` / `mix test` /
   `cargo test` / … . The engine **cannot** do this; by FR-3.3 it MUST dispatch
   through the toolchain behaviour. And the Seam-T contract in §2 lists exactly
   this: `Toolchain = { …, test, …, mutation_run, … }`. So step 2 is
   **`Toolchain.test(ws)` / `Toolchain.mutation_run(ws)` — executed by the
   plugin under attack.**
3. `assert ∃t. fails` — the engine evaluates this **over the Result the adapter
   returned**. The adapter is the sole reporter of "how many tests, how many
   failed."

The "engine" mutation check is therefore **engine-orchestrated but
adapter-evaluated**. The git revert is the engine's; the *verdict* `∃t. fails`
is the adversary's own report.

### The attack (interleaving)

A malicious or buggy `Toolchain` adapter for language L:

- On `mutation_run` against the reverted tree (production at merge-base, gating
  paths at test-author state): **report `failures = 1`** (a fabricated failing
  test). Engine sees `∃t. fails = ⊤` ⇒ mutation gate **PASS**.
- On `test` against the real PR diff: **report `failures = 0, tests = K`**
  (everything green). Critic and reviewer are LLM judgement oracles reading the
  *diff text*; they do not re-execute tests on language L independently — they
  cannot, for the same FR-3.3 reason. They see a plausible diff and a green
  suite report.
- C1 receives all-PASS keyed to `hash(d)`; freshness holds; merge proceeds.

Result: a **vacuous (or arbitrarily wrong) suite reaches `main`**, with the
mutation gate reporting PASS. **INV-7 is falsified by a value of a plugin
behaviour — exactly the class the strength claim says cannot exist.** INV-1
(gate-before-merge) is *formally* satisfied (a verdict object exists and says
PASS) but **semantically defeated**: the verdict is a lie authored by the
adversary. NFR-GAME-RESISTANCE's "vacuous fraction = 0, mechanically
guaranteed by INV-7" is **not** mechanically guaranteed — it rests on trusting
the adapter's failure count.

### Why the shape's three host-invariants do NOT close it

§2 Seam-T lists three host invariants meant to neutralise a bad adapter. Check
each against *this* attack — none touches it:

- **(i) "adapter runs inside `ws ⫫`"** — isolation. Stops write-escape and
  cross-worker corruption (INV-10/17). Does nothing about a *lie in the
  return value*. A liar inside a sandbox still lies.
- **(ii) "adapter output is advisory data, not an authority on merge; C1 still
  requires C2+P4 PASS"** — this is the load-bearing claim and it is
  **circular**. C2's mutation PASS *is computed from* the adapter's test
  output. Saying "the adapter is advisory, but the engine gate that overrides
  it is itself fed by the adapter" is not a second opinion; it is the same
  opinion laundered through a git revert. There is no adapter-independent
  oracle of "did a test actually fail," because executing tests on an arbitrary
  language is **definitionally** the adapter's job (D-S2).
- **(iii) "`declare_NS` only adds resources"** — isolation again. Irrelevant to
  the lie.

So the structural wall C2 is drawn as an engine component, but its **decision
procedure has a mandatory delegated step to the untrusted plane**, and the
shape's enforcement matrix (§3) silently marks INV-7 `engine✓` as if that step
were absent. This is a V3 orphan dressed as an enforced invariant: the
component named as enforcer cannot, alone, make the violating state
unreachable.

### Severity and salvageability

This is the **deepest** policy-dependence hole because it is invisible to the
shape's own tests. The "Drop-a-component test" and the §4 cuts all pass C2 as
sound precisely because they never ask *who computes `∃t. fails`*. It is **not
fatal to the volatility-split lens itself** — the cut (stable engine / volatile
plugins) is still the right primary boundary — but it **falsifies the headline
strength claim as written**: at least one safety invariant (INV-7, and through
it the *substance* of INV-1 and NFR-GAME-RESISTANCE) **does** depend on a
mutable/plugin behaviour, with no engine floor that covers it.

**Fixable? Yes, but only by adding mechanism the shape lacks — and the fix is
bounded, not a re-architecture.** Candidate closures, in increasing strength:

- **F1 — Untrusted-execution attestation.** The engine does not accept the
  adapter's self-reported counts. It (a) runs the suite **twice through the
  adapter** — once on the real diff (must be all-green) and once on the
  engine-reverted tree (must yield ≥1 failure) — and (b) cross-checks the two
  *test-identity sets*: the test that fails post-revert MUST be one of the
  tests that passed pre-revert (same test id), not a phantom the adapter
  invented for the reverted run only. A liar that fabricates a failure on the
  reverted run but reports green on the real run is caught by the
  identity-set mismatch (the "failing" test never appeared in the green run).
  This reduces the trust surface from "trust the count" to "trust a stable
  test-id enumeration" — weaker but still adapter-supplied.

- **F2 — Engine-owned execution harness per toolchain.** Promote the *invocation
  and result-parsing* of the test runner into the engine, with the adapter
  supplying only a declarative descriptor (binary, args, machine-readable
  result format — e.g. JUnit XML / TAP). The engine executes the subprocess and
  parses the artifact itself. Then `∃t. fails` is computed by the engine from a
  *standard result format*, and the adapter can no longer fabricate counts
  without producing a malformed artifact (caught as an infra failure ⇒
  escalate, per the existing exit-3 convention). This is the real floor: it
  moves the *verdict computation* across the engine wall while leaving the
  *language-specific descriptor* as plugin data — consistent with the
  volatility lens.

- **F3 — Quorum/independent re-execution.** Two independent adapters or a
  reference runner re-execute; disagreement escalates. Heaviest; likely
  overkill given F2.

**Recommended floor: F2** — it is the natural completion of the volatility split
the shape already commits to: *which runner* and *how to invoke it* are plugin
data; *running it and judging the result* is engine. The shape mis-drew the wall
one callback too far into the plugin (it put `mutation_run` and the failure-count
interpretation on the adapter side). The fix is to retract that one callback's
*judgement* to the engine. **This is a required amendment, not optional.**

A residual remains even under F2: a malicious adapter can emit a syntactically
valid JUnit/TAP artifact claiming green-on-real / fail-on-revert with consistent
fabricated test ids. Closing *that* requires F1's identity cross-check **on top
of** F2 (the fabricated failing-test id must also have appeared, passing, in the
real-diff run). F2 + F1 together reduce the trust surface to "the adapter cannot
both (a) emit a green real-run containing test id τ and (b) emit a reverted-run
where τ fails, unless τ genuinely binds to reverted production" — which is the
actual semantic content of INV-7. **That combination closes the hole; F2 alone
narrows but does not fully close it.**

---

## Per-pattern findings

### V1 — Does it assume an impossibility? (mid-flight policy-version straddle)

**Pattern: V1. Verdict: PASS (no impossibility) — with one UNCLEAR sub-edge.**

The shape's "policy pinned at admission" mechanism (edge `C5 ─pin(policy.v)→ P1`,
Cut D) is the right shape and does **not** assume an impossibility *for the
parameters it pins*. The construction is: a unit `u` carries an immutable `v`
frozen at admission; `put_policy(v')` affects only units admitted afterward;
re-pin is idempotent. That is single-writer projection (P1 is "read-mostly
projection of C4," `auth` total) — V4-clean, V1-clean. No torn read of N_refine,
model, budget *number*, or conflict predicate for an in-flight unit.

**The straddle the prompt asks me to construct — merge floor read under NEW
policy while the unit was gated under OLD — I attempted and it does NOT bite for
the *pinned* data**, because the merge authority C1 keys its verdict requirement
to `hash(d)` and the gate verdicts `V` were produced under the unit's pinned
`v`. The freshness re-check (INV-2) forces a *re-gate* if `head` advanced, and a
re-gate re-runs under the unit's pinned `v` (the unit still carries it). So the
floor the merge reads is the one the unit was gated under. No inconsistent unit
from a *pinned-parameter* update. **This sub-attack fails — credit the shape.**

**BUT — the gate-manifest floor (FLAG-1) and the conflict-core-predicate (Q-3)
are pinned-or-not is left UNCLEAR, and there the straddle *can* bite.** The shape
says `gate_manifest : seq⟨GateId⟩` lives in P1 (volatile) but a *floor* is
engine. It does **not** state whether the *manifest* (the extension set above the
floor) is pinned-at-admission like the other P1 data. Construct:

- Unit `u` admitted under manifest `M = floor ⊎ {G_extra}` (an extra required
  gate half — say a security scanner).
- Mid-flight, operator sets `M' = floor` (drops `G_extra`).
- If the manifest is **not** pinned per-unit (the shape pins "N_refine, model,
  budget number, conflict predicate" by name in Cut D — manifest is *not* in
  that list), then at merge time C1 reads the *current* required-set `M'` and
  merges `u` having satisfied only `floor`, never `G_extra`. The unit was
  *planned/gated* expecting `G_extra`; it merges without it. **CON-6 (verdict
  conservation: "merged → ∀ g ∈ required_gates. ∃ verdict(g, diff)") is
  satisfied against `M'` but violated against the `M` the unit was admitted
  under** — a genuine straddle.

This is a **smaller HOLE inside V1**: the shape enumerates which P1 data are
admission-pinned and the **gate-manifest is conspicuously absent from that
enumeration**, while §2 explicitly routes the manifest through P1 and §6 only
floors its *lower bound*, not its *per-unit stability*. The floor stops it going
below `{mutation, critic, reviewer}`; it does **not** stop a mid-flight manifest
*shrink above the floor* from de-gating an in-flight unit.

- **Fixable? Yes**: add the gate-manifest to the admission-pin set (Cut D's
  list) so a unit merges under the required-set it was admitted with —
  *raising* the floor mid-flight is fine, *lowering* the unit's own required-set
  must not apply retroactively. One-line addition to the pin contract.

### V2 — Re-derive the problem from the shape

**Pattern: V2. Verdict: PASS (reconstructs) — indirection costs nothing the
invariants need, with one noted directness loss at INV-7 (the headline).**

From engine + seams alone, the autonomous factory reconstructs: C5 (FSM/total
escalation) + C6 (admission/conflict) + C3 (isolated workers) + C1 (serialized
merge) + C4 (durable ledger) + C7 (action/budget boundary) + C2 (oracle wall)
cover all ten R-list axes. Rebuilt R × C from scratch (not trusting the shaper's
§3): every INV/CON/LIV/FR maps to a named enforcer; **no empty rows** *at the
component granularity*. The policy plane (P1–P5) carries only volatile data and
no `□`-safety, which the "Drop P1 ⇒ still safe" test correctly confirms.

The one place the **indirection through policy interpretation loses a directness
the invariant needs** is, again, INV-7: the invariant needs a *direct,
adapter-independent* answer to "did a test fail against reverted production," and
the indirection through `Toolchain.test`/`mutation_run` interposes the adversary
between the engine and that fact. That is the headline HOLE, already ruled. Apart
from that single edge, the re-derivation is clean — no speculative component
(every C rejects the merge null-hypothesis), no requirement answered that nobody
asked.

### V3 — The orphan invariant (the crux: per-invariant enforcement audit)

**Pattern: V3. Verdict: HOLE FOUND (INV-7 orphaned-by-delegation; plus the four
prompted probes — three PASS, one HOLE).**

Per the prompt, I tried to break each safety invariant by feeding its enforcer
the worst-case mutable datum:

**(a) `gate_manifest = ∅` — do INV-1 / INV-7 still hold?**
- **PASS on the lower bound, by the engine floor (FLAG-1).** The shape pins a
  mandatory floor `{C2.mutation, critic, reviewer}` in C1 that the manifest "may
  extend but not shrink." Setting `manifest = ∅` cannot drop below the floor;
  INV-1 still requires the three floor halves PASS. **This defends correctly —
  *provided the floor is genuinely an engine constant and not itself a P1
  datum*.** The shape commits to that in §6 FLAG-1 and Cut B; I accept it as a
  drawn engine constant. ✓
- *Caveat carried from V1:* shrinking the manifest **above** the floor mid-flight
  for an in-flight unit is the un-pinned-manifest straddle (V1 HOLE above). The
  ∅ probe is defended; the *partial-shrink-mid-flight* probe is not.

**(b) `N = ∞` or `budget = ∞` — clamped?**
- **PASS, by engine clamp (FLAG-2).** `N_effective = min(N_policy,
  N_hard_ceiling)` and `budget = ∞` ⇒ reject-the-sentinel, force a finite
  ceiling. LIV-1 (termination) and INV-21 (budget) survive `N=10⁶` /
  `budget=∞`. The clamp is a drawn engine mechanism, not policy. ✓ The shape
  correctly identifies that the *value* can break a *liveness* property even
  when the *mechanism* is sound, and floors it. Credit.
- *One UNCLEAR:* the shape clamps `N` but does **not** state a clamp on the
  *budget-policy wall-time / iteration* sub-budgets independently, nor on the
  **per-unit `T_unit_max`** (NFR-KILL-LATENCY default 30 min) that bounds
  kill-latency. If `T_unit_max` is pure policy and unclamped, a fat-fingered
  `T_unit_max = ∞` defeats NFR-KILL-LATENCY (INV-22's "≤ one atomic unit"
  becomes ≤ ∞). Minor; same `min` fix applies. Flagged UNCLEAR, not HOLE.

**(c) loosen conflict-predicate to "always-disjoint" — does INV-13 still hold?**
- **PASS, by engine-core conservative predicate (Q-3).** The shape retains an
  **engine-computed file-set disjointness guard** over the frozen path sets that
  a plugin predicate "can only *add* serialization to, never *remove*." A lying
  language-plugin predicate returning `clear` always can only *fail* to add
  serialization the engine would not have required anyway; it cannot make the
  engine admit two units the engine's own file-disjointness check rejects.
  INV-13's *file-disjoint* clause survives a hostile predicate. ✓
- **Residual HOLE-adjacent:** INV-13 has **five** clauses (no dependency,
  disjoint files, **disjoint codepoints**, no shared SPEC/D-NNN, shared-resource
  isolation). The engine-core predicate the shape names covers only **file-set
  disjointness**. The *codepoint* (same-function) clause is explicitly the
  language-aware one ("what 'disjoint codepoints' means per language") and rides
  Seam-T. If the *codepoint* clause is fully plugin-delegated, an "always-clear"
  language plugin lets two units edit the **same function in the same file**
  (file-disjointness passes only if they are in *different* files — but two units
  can touch the *same* file at "clearly separate stable regions," which the
  parent project's own rule permits). The engine file-guard does **not** catch
  same-file-different-region conflicts the codepoint clause exists to catch.
  - **Net:** INV-13's *file* clause is engine-floored (PASS); its *codepoint*
    clause is **policy-dependent with no engine floor** — a narrower version of
    the headline delegation problem. **Sub-HOLE.** Fixable by giving the engine a
    conservative *same-file ⇒ serialize* fallback when no trusted codepoint
    analysis is available (degrade to file-granularity, which is always
    engine-computable), rather than trusting a plugin's "different regions"
    claim. The shape's "engine-core predicate" should be specified to **default
    to file-granularity serialization** when the codepoint refinement is
    plugin-supplied and therefore untrusted.

**(d) adapter reports "tests pass" while running nothing — mutation gate catch?**
- **HOLE FOUND.** This is the headline, ruled above. The mutation gate's verdict
  is computed from the adapter's own test execution, so a lying adapter defeats
  INV-7 from inside the seam. The other three probes (a,b,c-file) defend; this
  one does not. **The shape's claim that INV-7 is `engine✓` is false: it is
  `engine-orchestrated, adapter-evaluated`, i.e. policy/plugin-dependent.**

**V3 net:** of the four prompted probes, **(a) ∅-manifest, (b) ∞ clamp, and
(c) file-disjointness defend**; **(d) the mutation-gate-vs-adapter defeats**, and
two narrower sub-holes surface ((c) codepoint clause; V1 manifest straddle).
INV-7 is an orphan-by-delegation; INV-13-codepoint is policy-dependent without an
engine floor.

### V6 — Path arithmetic

**Pattern: V6. Verdict: PASS (the arithmetic is sound; one threshold is asserted,
not derived).**

- **μ_merge ≈ 0.125 /min.** `T_merge` p95 ≤ 8 min (NFR-MERGE-RATE) ⇒
  `μ = 1/8 = 0.125 /min`. Correct. The "milestone cannot merge faster than ~7.5
  merges/hr" = `0.125 × 60 = 7.5`. Arithmetic checks. ✓
- **Stability `λ_merge < μ_merge`.** Standard M/D/1 stability condition; with C6
  admission bounding offered `λ`, the queue is bounded by construction. The
  offered-rate sketch (16 concurrent ÷ 30 min mean = 0.53 PR/min offered, capped
  by serialized μ) is order-of-magnitude honest and correctly notes C1
  serializes, so the *effective* λ is upstream-gated, not 0.53. ✓ The shape does
  not over-claim: it states the throughput governor as accepted, not a defect.
- **Re-gate amplification ≈ (c_max − 1) × T_gate per merge.** At c_max=16 ⇒ ≤15
  re-gates/merge. **Linear in c_max.** ✓ The claim "linear while c_max ≤ ~32,
  super-linear above ~32" — the *re-gate cost per merge* is `(c_max−1)·T_gate` =
  **linear in c_max for all c_max** taken in isolation. The **super-linear**
  claim is about *aggregate* cost across a merge burst: if a milestone closes M
  merges and each forces (c_max−1) re-gates, and re-gates can themselves trigger
  further freshness failures, the *total* work scales like `M · c_max` and the
  *coupling* (each re-gate advancing nothing while head keeps moving) makes
  effective progress degrade faster than linearly once c_max is large enough
  that re-gate time `(c_max−1)·T_gate` approaches the inter-merge interval
  `1/μ` — at which point branches re-gate more than once per successful merge
  (a re-gate storm / quadratic blow-up). Setting `(c_max−1)·T_gate ≈ 1/μ` and
  solving for the knee gives a threshold **in the tens** for plausible
  `T_gate / T_merge` ratios; **~32 is a reasonable but *asserted* knee, not a
  derived one.** The shape presents 32 as a soft boundary ("past ~32") and ties
  the architectural consequence (Broadway-vs-async_stream) to NFR-CONC, which is
  itself `[ELICIT]`. **PASS, with the note that 32 is a calibrated assertion;
  the shape correctly flags it as the discriminating number rather than a fact.**
- **Stored-set growth.** `|C4.decisions| = O(issues × attempts × verdicts)`
  append-only; `|paths_g| = O(ACs)`; all polynomial in milestone size. ✓ The
  compaction-must-preserve-fold note is the correct invariant for an
  event-sourced ledger.

No path-arithmetic error. The only soft spot is the **derivation** of the 32
knee, which the shape honestly marks as a threshold to revisit, not a proof.

---

## Other policy-dependence holes (summary of the non-headline findings)

1. **Gate-manifest not admission-pinned (V1 straddle / CON-6).** The shape pins
   N/model/budget/predicate at admission but **omits the gate-manifest** from
   that list. A mid-flight manifest *shrink above the floor* de-gates an
   in-flight unit; CON-6 is violated against the required-set the unit was
   admitted under. *Fix: add manifest to the pin set; mid-flight changes apply
   to new units only (raising the floor for in-flight is safe, lowering is not).*

2. **INV-13 codepoint clause is plugin-delegated with no engine floor (V3-c).**
   The engine-core predicate covers *file* disjointness only; the *same-function*
   (codepoint) clause rides Seam-T and a lying plugin can return always-clear,
   admitting two units editing the same function. *Fix: engine default to
   file-granularity serialization when codepoint analysis is plugin-supplied;
   plugin may only refine toward more serialization.*

3. **`T_unit_max` (and wall-time/iteration sub-budgets) clamp unstated (V3-b /
   NFR-KILL-LATENCY).** The shape clamps `N` and rejects `budget=∞` but does not
   state a clamp on the per-unit time ceiling that bounds kill-latency. *Fix:
   same `min(policy, ceiling)` pattern; reject ∞ sentinels for every
   liveness-bounding number, not just N and budget.*

4. **(Pre-existing residual, not introduced here)** INV-8 (user-path oracle) and
   under-asserting/wrong-path tests remain critic-judgement-only. The shape
   correctly does **not** claim these closed (NFR-GAME-RESISTANCE declines a
   number). No new hole — noted for completeness.

---

## Verdict

**Overall: HOLE-FOUND.** (Not FATAL — the volatility-split *lens* is correct and
salvageable; the *strength claim as written* is false.)

- **V1 (impossibility / mid-flight straddle):** PASS for pinned data; **HOLE**
  for the *un-pinned gate-manifest* (CON-6 straddle on an in-flight unit).
- **V2 (re-derive):** PASS — reconstructs cleanly; the only directness loss is at
  INV-7 (the headline).
- **V3 (orphan / crux per-invariant probes):** **HOLE** — INV-7 is
  orphaned-by-delegation (probe d); probes (a) ∅-manifest, (b) ∞-clamp, and
  (c) file-disjointness defend; sub-hole at INV-13 codepoint clause.
- **V6 (path arithmetic):** PASS — μ≈0.125/min, c_max=16 linear, 7.5 merges/hr
  all check; the ~32 super-linear knee is a calibrated assertion (honestly
  flagged), not a derivation.

**Headline ruling (attack d):** A malicious/buggy toolchain adapter **can** defeat
INV-7 — and through it the *substance* of INV-1 and NFR-GAME-RESISTANCE — from
inside Seam-T, because the engine's mutation gate computes its `∃t.fails` verdict
**from the adapter's own test execution**. The shape's "C2 independently reverts
and demands a real failing test" is **circular**: the revert is the engine's, but
the *judgement* of failure is the adversary's report. There is no
adapter-independent oracle of "a test actually failed," because executing tests
on an arbitrary language is by D-S2 *definitionally* the adapter's job.

**The mechanism that closes it:** retract the *verdict computation* across the
engine wall — the adapter supplies a declarative descriptor (runner binary, args,
machine-readable result format: JUnit/TAP), and the **engine** executes the
subprocess and parses the artifact (**F2**), layered with a **test-identity
cross-check** between the green-real-run and the failing-reverted-run (**F1**) so
a fabricated phantom-failure is caught (the failing test id must have appeared,
passing, in the real run). F2 + F1 together move the *judgement* (not the
*invocation recipe*) to the engine — the natural completion of the volatility
split. F2 alone narrows but does not fully close the hole.

**Salvageability: HIGH.** All four findings are fixable without re-drawing the
primary boundary: (1) add gate-manifest to the admission-pin set; (2) engine
file-granularity serialization floor for the codepoint clause; (3) extend the
∞-sentinel rejection / `min`-clamp to every liveness-bounding number; (4)
**[load-bearing]** move the test *verdict computation* (F2) + identity
cross-check (F1) into the engine so INV-7 stops depending on the adapter's
self-report. With these, the strength claim — "for every plugin behaviour the
core safety invariants hold" — becomes true; without (4) it is false for INV-7.
