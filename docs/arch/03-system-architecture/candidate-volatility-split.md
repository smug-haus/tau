# Candidate shape — VOLATILITY-SPLIT

**Lens.** Draw the primary boundary between an *invariant-bearing stable core*
(the engine) and a *policy/data plane* (rules-as-data). Things that change
weekly/quarterly become **data** `r ∈ Rules` interpreted by a stable mechanism
`decide : Rules × Input → Outcome`; things invariant (merge-serialization,
oracle-separation, durable-state contract, capture-before-destroy) become the
fixed engine. Key strength claim to be defended: **for every plugin behaviour
(including malicious/buggy), the stable core's safety invariants hold** — a bad
toolchain adapter, a swapped model, a rewritten gate-policy datum cannot bypass
INV-1..INV-3, INV-5..INV-7, INV-10..INV-22.

Notation per `references/notation.md`: component `C = (S, E_in, E_out, →, Inv)`;
`□P` safety; `↝` leads-to; `⫫` isolation; `auth : Datum → C` total. Runtime-
agnostic — no OTP/language/product terms; OTP is a later layer.

---

## 0. The volatility tagging (per requirement)

Volatility drives the cut. Tag = {**S** stable / stationary-invariant,
**Q** quarterly, **W** weekly, **U** per-unit}. Source: R-list volatility column
+ scope-decisions.

| Datum / rule | Vol | Disposition |
|---|---|---|
| merge-serialization, freshness, gate-before-merge (INV-1..3) | S | **engine wall** |
| oracle-separation, gating-test immutability (INV-5,6) | S | **engine wall** |
| durable-decision contract, RPO=0 (INV-16) | S | **engine wall** |
| capture-before-destroy, reclaim (INV-14,15, CON-5) | S | **engine wall** |
| crash containment, verified position (INV-12,17) | S | **engine wall** |
| total-escalation totality (INV-18) | S | **engine wall** (set membership is data; *totality* is engine) |
| no-unilateral-destruction *boundary* (INV-20) | S | **engine wall** (the *list* of destructive classes is data) |
| budget-ceiling *enforcement* (INV-21) | S | **engine wall** (the *number* is data) |
| conflict-check *clauses count=5* + admit-only-when-clear (INV-13) | S | engine enforces "clear ⇒ admit"; clause *predicates* are data |
| which model per role (FR-7.4) | W | **policy datum** `model_of : Role → ModelId` |
| toolchain adapter per language (FR-3.3, D-S2) | Q | **plugin** `Toolchain` behaviour |
| gate composition (which halves) (FR-4.1) | S/Q | **plugin set** `Gate[]`; *cardinality+all-must-pass* is engine |
| escalation thresholds N_refine, N_pivot (INV-19) | Q | **policy datum** |
| budget policy numbers (INV-21, FR-7.1) | W | **policy datum** |
| conflict-check clause predicates (FR-2.3) | Q | **policy datum** (engine still requires all-clear) |
| priority / work-selection order (FR-2.1) | W | **policy datum** `priority : Issue → ℕ` |
| destructive-action class list (FR-5.3) | Q | **policy datum** (deny-by-default engine) |
| rate-limit / circuit-breaker thresholds (FR-7.2) | W | **policy datum** |
| memory heuristics / failure taxonomy (FR-6.2) | W | **knowledge datum** |

**Cut rule (the discriminator).** A safety invariant's *enforcement* is engine;
its *parameters* may be data — **iff the engine's invariant holds for all values
of that datum**. Counterexample test applied to every "policy" row above: does
the worst-case value of the datum break a `□`-invariant? If yes ⇒ it is not
policy, promote to engine (§6 flags two such borderline cases).

---

## 1. Components

### 1.A — STABLE CORE (the engine; invariant-bearing, plugin-agnostic)

**C1 — MergeAuthority** (the conservation funnel; INV-1,2,3,4; CON-6)
- `S₁ = { phase ∈ {idle, gating, fresh_check, applying, health}, cur ∈ Diff⊥,
  head ∈ CommitHash, red ∈ 𝔹, queue : seq⟨Branch⟩ }`. Single-concurrency owner.
- `E_in = { request_merge(d), gate_verdicts(d, V), head_advanced(h) }`
- `E_out = { merged(d), reject_stale(d), escalate(E-RED-MAIN), health(d,r) }`
- `→`: `idle ─request_merge(d)→ gating`; require `V = all PASS keyed to hash(d)`
  (else reject); `─→ fresh_check`: `base(d)=head ? applying : reject_stale`;
  `applying ─→ health`; `health(red) ─→ escalate(E-RED-MAIN) ∧ red:=⊤`.
- `Inv₁`: `□(|{d: phase∈{applying}}| ≤ 1)` (INV-3, by single owner).
  `□(merged(d) → gate(hash(d))=PASS_all)` (INV-1). `□(merged(d) → base(d)=head)`
  (INV-2). `□(red → ¬applying)` (INV-4). **No datum, no plugin, can widen this.**

**C2 — OracleBoundary** (anti-gaming structural wall; INV-5,6,7,8; FR-4.2,4.3)
- `S₂ = { paths_g ⊆ Path (frozen), author_g, author_impl, frozen ∈ 𝔹 }`
- `E_in = { declare_gating_paths(P), impl_diff(δ), merge_base(b) }`
- `E_out = { violation(masking), mutation_verdict(±), freeze_ack(P) }`
- `→`: `declare_gating_paths(P)` only while `¬frozen` and only by `author_g`;
  sets `frozen:=⊤`. Any `impl_diff(δ)` with `δ ∩ paths_g ≠ ∅ ⇒ violation`.
- `Inv₂`: `□(author(test_g) ≠ author(impl))` (INV-5);
  `□(∀p∈paths_g. ¬impl_writes(p))` (INV-6, path-based not commit-based);
  mutation: revert(¬paths_g)→merge_base ⇒ `∃t. fails` (INV-7).
  **The implementer is a plugin-ish agent; this wall does not trust it.**

**C3 — WorkerSupervisor** (isolation + durability; INV-10,11,12,14,15,17; CON-5)
- `S₃ = { workers : Id ⇀ (ws : Workspace, ns : ResourceNS, status) }` where
  `Workspace ⫫ Workspace` by construction.
- `E_in = { spawn(unit, toolchain_id), worker_exit(id, reason),
  resource_decl(id, R) }`
- `E_out = { ready(id, ws), captured(id, dirty), reclaimed(id),
  escalate(...) }`
- `→`: `spawn` allocates `ws` (private fork from verified ref) + `ns` totalising
  over `R` the toolchain adapter *declares*; on `worker_exit(_,reason)` for ALL
  reasons: `capture(staged ⊎ unstaged ⊎ untracked) → reclaimed`.
- `Inv₃`: `□(w₁≠w₂ → ws(w₁) ⫫ ws(w₂))` (INV-10);
  `□(¬∃w. mutates(w, HEAD(core)))` — core holds no mutable tree (INV-11);
  `□(starts(w) → position set-by-system ∧ verified-by-w)` (INV-12);
  `□(dies(w) → recoverable(committed ⊎ dirty₃ₖᵢₙ𝒹ₛ))` (INV-14,CON-5);
  `□(terminates(w) ↝ reclaimed(ws))` (INV-15);
  `□(crash(w) → blast=∅\{w})` (INV-17). **Capture runs in the supervisor's
  terminate path, before reclaim — not in the worker, which may be dead.**

**C4 — DurableLedger** (system of record; INV-16; CON-1..7; RPO=0)
- `S₄ = fold(apply, s₀, decisions)` — append-only decision log + balances.
  `auth : Decision → C4` total. Every C-law's writer-of-record.
- `E_in = { record(decision), debit(action,cost), reconcile(tracker) }`
- `E_out = { persisted(d), balance(b), drift_alarm }`
- `→`: write-ahead — `record(d)` commits *before* d's effect is externally
  visible (INV-16 ordering). `debit` is double-entry (`spent+remaining=total`).
- `Inv₄`: `□(decided(x) ↝ persisted(x) ∧ survives_restart(x))` RPO=0 (INV-16);
  `□(spent ≤ budget)` read-side for C7; CON-1..7 balances. **Replayable:
  decisions+outcomes only, not LLM reasoning (FR-6.3).**

**C5 — Coordinator FSM** (the total-escalation engine; INV-18,19,22; LIV-*)
- `S₅` = per-unit FSM `{selected, planned, oracle_set, implementing, gating,
  refine(k≤N), pivot, terminal ∈ {merged, escalated(e), rejected}}` ×
  global `{running, killing, halted}`.
- `E_in = { unit_event, gate_result, kill_signal, budget_exhausted, restart }`
- `E_out = { spawn-requests, escalate(e∈E), report, resume }`
- `→`: catch-all transition `¬classified(s) ⇒ escalate(E-UNCLASSIFIED)` — no
  terminal-without-classification state. Retry guarded by bound `k≤N`.
- `Inv₅`: `□(¬progress(s) → ∃! e∈E. escalates(s,e))` totality (INV-18);
  `□(attempts ≤ N_ref+N_piv)` (INV-19, count is durable in C4);
  `□(kill ↝ halt_between_units ∧ main_synced ∧ ¬mid_merge)` (INV-22).
  **`E` *membership* is enumerated data; totality (the `∃!` and catch-all) is
  engine. A policy that shrinks `E` cannot delete the catch-all.**

**C6 — Scheduler** (admission control; INV-13; FR-2.3,7.3; LIV-2,4)
- `S₆ = { inflight : set⟨Unit⟩, waiting : seq⟨Unit⟩, c_max }`
- `E_in = { candidate(u), unit_terminal(u), conflict_eval(u, inflight) }`
- `E_out = { admit(u), serialize(u), backpressure }`
- `→`: `admit(u)` **iff** `conflict_check(u, ∀v∈inflight)=clear` **and**
  `|inflight|<c_max` **and** budget-admits. Else `serialize`. Merge fairness
  (FIFO+aging — Q-L1) is policy; *serialize-until-clear* is engine.
- `Inv₆`: `□(concurrent(u₁,u₂) → conflict_check=clear)` (INV-13);
  `□(|inflight| ≤ c_max)`; `□◇progress` monotone serialization (LIV-4).

**C7 — ActionGate / BudgetGate** (the deny-by-default boundary; INV-20,21; CON-3)
- `S₇ = { class_table : Action ⇀ {safe, destructive}, budget, spent }`
- `E_in = { admit_action(a, cost), classify_update(table) }`
- `E_out = { allow(a), deny(a)→escalate(E-DESTRUCTIVE), deny(a)→E-BUDGET }`
- `→`: `admit_action(a,cost)`: if `class(a)=destructive ⇒ deny+escalate` (no
  auto-execute); if `spent+cost>budget ⇒ deny+escalate`; else `debit→allow`.
  **Default for unknown `a` is `destructive`** (deny-by-default — the safety bit).
- `Inv₇`: `□(destructive(a) → ¬auto_execute ∧ escalate)` (INV-20);
  `□(spent ≤ budget)` (INV-21, ≤1-action overrun NFR-BUDGET-PRECISION).

### 1.B — POLICY / DATA PLANE (volatile; interpreted, never structural)

**P1 — PolicyStore** (versioned rules-as-data; read-mostly projection of C4)
- `S = { model_of : Role→ModelId, N_ref, N_piv, budget_policy, priority,
  conflict_predicates[5], destructive_classes, ratelimit_thresholds,
  gate_manifest : seq⟨GateId⟩, version : ℕ }`
- `E_in = { put_policy(v), get_policy() }`; `E_out = { policy(v) }`.
- `Inv`: monotone `version`; each rule typed; **engine reads a pinned version per
  unit** (see edge contract §2). No `□`-safety invariant lives here.

**P2 — ToolchainRegistry** (the per-language plugin seam; Q)
- `S = lang ⇀ Toolchain` (behaviour-as-contract, §2 seam-T).
- Adapters: `install_deps, build, test, lint, mutation_run, package, declare_NS`.

**P3 — ProviderRegistry / ModelAdapters** (per-model plugin seam; W)
- `S = ModelId ⇀ Provider`; egress chain (rate→breaker→budget) thresholds from P1.

**P4 — GateRegistry** (gate-half plugins; the manifest from P1 selects active set)
- `S = GateId ⇀ Gate` where `Gate : Diff × Frozen → Verdict∈{PASS,FAIL,findings}`.

**P5 — Knowledge / Memory** (FR-6.2; W) — searchable heuristics; advisory only,
never a safety enforcer. Pure projection over C4 + external corpus.

**Drop-a-component test.** Delete C1 ⇒ INV-1..4 unenforced. Delete C2 ⇒
INV-5..7 (anti-gaming) gone. Delete C4 ⇒ RPO=0/all CON-laws gone. Delete P1 ⇒
engine still safe but rules hardcoded (loses volatility goal, not safety) —
confirms P1 is *correctly* in the policy plane, not the core.

---

## 2. Composition graph + per-edge contract + seam contracts

Edges are events; `{pre} e {post}` + **failure clause**. Seams marked **⊕**.

```
 Tracker ──issues──▶ C5 ──candidate──▶ C6 ──admit/serialize──▶ C3
   ▲                  │ pin(policy.v)      │                    │ spawn(unit,tc)
   │                  ▼ ◀──policy(v)── P1   │                    ▼ ready
 C5 ◀─reconcile─ C4   C5 ──declare_paths──▶ C2 ◀─impl_diff── Agents(P3)
   │ record            │                     │ mutation/masking   │ uses⊕T
   ▼ persisted         ▼ gate_request        ▼ verdict            ▼
  C4 ◀──debit── C7 ◀──admit_action── (all billable / destructive)
   │                                          │
 C5 ──request_merge──▶ C1 ◀──gate_verdicts── P4(GateRegistry, manifest⊂P1)
   │                    │ merged/health        ▲ run⊕G each half
   ▼                    ▼                       │
 report/escalate ──▶ Operator            C1 uses C2.mutation as one required half
```

**Edge contracts (load-bearing ones):**

- `C5 ─pin(policy.v)→ P1`: `{unit u admitted} pin {u carries immutable v}`.
  **Failure (policy update mid-flight):** a unit's `v` is *frozen at admission*;
  P1.put_policy(v') affects only units admitted after. No in-flight unit sees a
  changed rule. *Idempotent* (re-pin returns same v). This is the structural
  answer to "policy update mid-flight" (§4 cut D).
- `C3 ─spawn(unit, tc)→ Toolchain⊕T`: **Seam-T contract** —
  `Toolchain = { install_deps, build, test, lint, mutation_run, package,
  declare_NS }`, each `: Workspace → Result⊥`. **Host invariants enforced
  regardless of adapter:** (i) adapter runs *inside* `ws ⫫`; it receives only its
  private workspace+ns; (ii) adapter output is *advisory data* (a `Result`), it
  is **not** an authority on merge — C1 still requires C2+P4 PASS;
  (iii) `declare_NS` only *adds* resources to isolate; it cannot *remove* the
  git-checkout isolation. **Failure (buggy/malicious adapter):** any adapter
  result (crash, lie "tests pass", infinite loop, attempt to write outside ws)
  is contained: crash ⇒ C3 blast=∅\{w}; "lie" ⇒ irrelevant, C2's mutation gate
  (engine) independently reverts production and demands a real failing test;
  write-escape ⇒ ns isolation is a host property, not adapter-granted.
- `Agents ─impl_diff→ C2⊕(impl agent)`: **Seam-Impl** — implementer is treated
  adversarial. `{δ produced} impl_diff {δ ∩ paths_g checked}`. **Failure:**
  implementer edits a gating path ⇒ `violation(masking)` (engine), challenge
  protocol (FR-4.4) routes to *independent* critic, never C5's own judgement.
- `P4 ─run⊕G→ Gate`: **Seam-G** — `Gate : (Diff, Frozen) → Verdict`. Host
  invariant: C1 merges iff **all** manifest halves PASS; cardinality &
  all-must-pass are engine, *which* halves are P1 data. **Failure (malicious
  gate-policy datum sets manifest=∅):** see §6 FLAG-1 — engine pins a *minimum
  mandatory floor* {C2.mutation, critic, reviewer} not removable by manifest.
- `C7 ─admit_action→ everything billable/destructive`: every spend and every
  destructive class passes here. **Failure:** unknown action class defaults
  `destructive` ⇒ deny+escalate (fail-closed).
- `C1 ─request_merge→ apply`: single critical section; `head` re-read inside it
  (INV-2). **Failure (head advanced):** reject_stale ⇒ C5 rebases ⇒ re-gate
  (LIV-2 fairness via FIFO+aging policy).
- `* ─record→ C4`: write-ahead. **Failure (C4 unavailable):** the effect is
  **not** externalised (no merge, no spawn) — RPO=0 means "no effect before its
  decision is durable", so unavailability blocks progress (safe) rather than
  losing it.

---

## 3. Enforcement matrix R × C

`engine`✓ = enforced in stable core (good). `policy?` = depends on mutable
policy datum (**flag** unless engine floors it).

| Req | Enforcer | Core/Policy |
|---|---|---|
| INV-1 gate-before-merge | C1 (+C2,P4 verdicts) | engine✓ |
| INV-2 freshness | C1 critical section | engine✓ |
| INV-3 serialized merge | C1 single owner | engine✓ |
| INV-4 main-health gate | C1 `red` state | engine✓ |
| INV-5 oracle separation | C2 author check | engine✓ |
| INV-6 gating-test immutability | C2 path scan | engine✓ |
| INV-7 non-vacuous (mutation) | C2 revert+run | engine✓ |
| INV-8 user-path oracle | C2 + critic (P4) | **policy?** (residual GAP-7; critic judgement) |
| INV-9 incomplete-fix | C5+P4 mechanical test | engine✓ (test) / policy (critic findings) |
| INV-10 resource isolation | C3 ns allocation | engine✓ (over adapter-declared R) |
| INV-11 no shared tree | C3 (core holds no tree) | engine✓ |
| INV-12 verified position | C3 + worker self-check | engine✓ |
| INV-13 conflict-gated conc. | C6 admit guard | engine✓ (predicates are policy; *all-clear* is engine) |
| INV-14 no lost work | C3 terminate-capture | engine✓ |
| INV-15 reclaimed isolation | C3 supervised reclaim | engine✓ |
| INV-16 durable state RPO=0 | C4 write-ahead | engine✓ |
| INV-17 crash containment | C3 per-worker domain | engine✓ |
| INV-18 total escalation | C5 catch-all | engine✓ (E *membership* data; totality engine) |
| INV-19 bounded retry | C5 guard, N from P1 | engine✓ (bound *exists*); **policy?** N value (FLAG-2) |
| INV-20 no unilateral destruct | C7 deny-by-default | engine✓ (class *list* policy; default destructive=engine) |
| INV-21 budget ceiling | C7 + C4 ledger | engine✓ (number is policy; ceiling-check engine) |
| INV-22 clean kill | C5 unit-boundary check | engine✓ |
| INV-23 spec-before-code | C5 gate question (P4) | policy/process (not safety-critical to runtime) |
| INV-24 OTP non-negotiables | C5 gate + toolchain-T (self-host) | engine✓ for factory |
| CON-1 work conservation | C4 backlog | engine✓ |
| CON-2 issue reconciliation | C4 reconcile pass | engine✓ |
| CON-3 budget conservation | C4 double-entry | engine✓ |
| CON-4 cost attribution | C4 `auth(spend)` total | engine✓ |
| CON-5 artifact conservation | C3 capture | engine✓ |
| CON-6 verdict conservation | C1+C4 | engine✓ |
| CON-7 escalation conservation | C5+C4+reporter | engine✓ |
| LIV-1 unit termination | C5 (INV-18+19) | engine✓ |
| LIV-2 merge progress | C1 fair queue | engine✓ (policy: FIFO vs aging — Q-L1) |
| LIV-3 milestone termination | C5+C4 (CON-2) | engine✓ |
| LIV-4 no livelock | C6 monotone serialize | engine✓ |
| LIV-5 recovery progress | C4 replay + C5 resume | engine✓ |

**No empty rows.** Two `policy?` flags carry to §6 (FLAG-1 gate-floor implicit in
INV-1 row; FLAG-2 the N value; INV-8 is a pre-existing residual, not new).

---

## 4. Failure cuts

**Cut A — buggy/malicious Toolchain adapter (Seam-T).** Adapter lies "build+test
PASS" / crashes / loops / tries to write outside `ws`.
*Behaviour:* **all safety invariants hold.** (1) Its result is advisory; C1 still
demands C2.mutation (engine reverts production, requires a real failing gating
test) + critic + reviewer ⇒ a lying adapter cannot move a vacuous diff to `main`
(INV-1,7 hold). (2) Crash/loop ⇒ C3 blast=∅\{w}, capture-before-destroy runs,
reclaim frees ns (INV-14,15,17). (3) Write-escape impossible: ns isolation is a
host property C3 allocates, not something the adapter grants itself (INV-10).
*Liveness degrades:* that unit fails its gate ⇒ refine→pivot→`E-RETRY-EXHAUSTED`.
**Strength claim discharged for Seam-T.**

**Cut B — malicious gate-policy datum (Seam-G / P1).** Operator-or-bug sets
`gate_manifest = ∅` or drops the mutation half. *Behaviour:* C1 enforces a
**mandatory floor** {C2.mutation, critic, reviewer} that the manifest may *extend
but not shrink* (engine constant, not policy). So INV-1/INV-7 survive a hostile
manifest. (See §6 FLAG-1: this floor MUST be engine; if it were policy the
strength claim fails — the verifier's sharpest attack.)

**Cut C — implementer-agent gaming (Seam-Impl).** Implementer edits/weakens a
gating test, or writes a test that passes vacuously. *Behaviour:* path-scan
masking gate (C2, engine) flags any write to `paths_g` (INV-6); mutation gate
(C2) catches vacuity (INV-7); challenge routes to *independent* critic, never C5
(FR-4.4); >2 upheld ⇒ `E-CHALLENGE`. Under-asserting/wrong-path tests remain the
known residual (INV-8/GAP-7) — *not claimed closed*.

**Cut D — policy update mid-flight (P1).** P1.put_policy(v') while unit u is in
`implementing`. *Behaviour:* u carries `v` pinned at admission (edge
`pin(policy.v)`); v' applies only to units admitted after. **No in-flight
invariant re-evaluation, no torn read.** A change to N_refine, model, budget
number, or conflict predicate cannot retroactively alter an in-flight unit's
already-granted decisions. Re-verification surface on a rule change = *new units
only*; the engine itself is unchanged ⇒ **minimal re-verification** (the central
volatility-split payoff).

**Cut E — unknown-language target, no adapter (Seam-T absent).** A unit targets a
language with no `Toolchain` in P2. *Behaviour:* `lookup(lang)=⊥` ⇒ C6 cannot
satisfy `spawn(unit, tc)` precondition ⇒ unit is **not admitted**, classified
`E-AMBIGUITY` (irreducible: "no toolchain"), escalated to operator (CON-7), unit
parked `escalated`. **It does NOT fall through to a default runner** (which would
violate INV-1's premise that the gate can actually test the artifact). Fail-
closed. Adding the adapter later is a P2 plugin insert — engine untouched.

**Cut F — C4 (DurableLedger) unavailable.** *Behaviour:* write-ahead contract ⇒
no externally-visible effect (merge/spawn/debit) proceeds without its decision
durable. So C4-down *blocks* progress (safe halt) rather than losing it; on
recovery C5 replays from C4 (LIV-5, RPO=0). Liveness pauses; no safety/CON
violation.

**Cut G — coordinator (C5) crash.** Supervised restart; resume from C4
(INV-16). In-flight workers (C3) are independent crash domains — unaffected
(NFR-BLAST=0). Idempotent resume: a decision already in C4 is not re-executed
(LIV-5, RTO p95≤60s).

---

## 5. Path arithmetic + queue stability at NFR-CONC peak

**Merge path (synchronous, serialized).** Per-merge cost
`T_merge = T_freshcheck + T_apply + T_health`, dominated by toolchain
`build+test` (NFR-MERGE-RATE p95 ≤ 8 min, toolchain-bound by design).
Serialization: merges form an M/D/1-ish funnel at C1, service rate
`μ_merge ≈ 1/8min = 0.125 /min`.

**Arrival.** At NFR-CONC peak `c_max = 16` in-flight PRs, completion (gate-green)
arrival to C1 `λ_merge`. Milestone ~50 issues; if mean PR wall-time
`≈ 30 min` and 16 concurrent, throughput-bound at `≈ 16/30 = 0.53 PR/min`
*offered*, but C1 serializes ⇒ effective `λ_merge` is capped by upstream gate
completion, not 0.53. **Stability requires `λ_merge < μ_merge`.** With
`μ_merge=0.125/min`, sustained `λ_merge` must be < 0.125/min ⇒ **a milestone
cannot merge faster than ~7.5 merges/hr**; this is the loop's throughput
governor (NFR-MERGE-RATE), accepted, not a defect — correctness over throughput.

**Re-gate amplification (Q-L2).** Each merge advances `head` ⇒ each of the other
≤15 in-flight branches fails freshness ⇒ rebase+re-gate. Re-gate cost per merge
`≈ (c_max−1) × T_gate`. At `c_max=16`: ≤15 re-gates/merge. **Linear in c_max
while c_max ≤ ~32** ⇒ `Task.async_stream`-class bounded fan-out suffices; **above
~32 it goes super-linear** ⇒ back-pressure/merge-batch boundary warranted
(NFR-CONC architectural consequence). **This shape sits at 16 ⇒ no Broadway-class
machinery required**; the Scheduler's `c_max` admission bound (C6) keeps re-gate
cost sub-quadratic by capping in-flight.

**Queue stability statement.** C1 queue stable iff `λ_merge < μ_merge`; expected
queue length `→ ∞` as `λ_merge → μ_merge`. Admission control (C6, `|inflight| ≤
c_max`) bounds `λ_merge` offered ⇒ **bounded queue by construction**, no
unbounded growth. Agent fleet: `A_max ≤ 128` (NFR-AGENT-FLEET) within node
envelope; each a supervised crash domain (C3).

**Growth of stored sets.** `|C4.decisions| = O(issues × attempts × verdicts)` —
append-only, paired with retention (monotonicity invariant; compaction must
preserve fold). `|C4.ledger| = O(billable_actions)`. `|paths_g|` per unit =
O(ACs). All polynomial in milestone size.

---

## 6. Open discriminating questions (with cost asymmetry)

**FLAG-1 (the verifier's sharpest attack) — Is the gate composition genuinely
policy, or is a *floor* an invariant?** Gate *extension* is policy (Q); but the
mutation-gate + critic + reviewer **floor** MUST be engine — if `gate_manifest`
(policy data) could set the set to ∅ or drop mutation, a single policy edit
silently defeats INV-1/INV-7 with no code change and no re-verification. **This
is a rule that *looks like* policy but is actually invariant.** *Decision in this
shape:* engine pins the mandatory floor; manifest may only add halves. *Cost
asymmetry:* treating the floor as policy (cheap-looking) ⇒ catastrophic
silent-bypass surface, the exact failure the volatility split must prevent;
flooring it in engine ⇒ trivial constant. **Recommend: floor in engine.**
*Discriminating Q to operator:* "Is there ANY operational scenario requiring the
mutation/critic/reviewer floor to be removable at runtime?" If no (expected), it
is invariant.

**FLAG-2 — Are the retry bound N and the budget number policy, or invariant?**
The *existence* of a bound (INV-19) and the *ceiling-check* (INV-21) are engine
(proven above). The *values* N=3, budget=X are W/Q policy. *Risk:* a policy datum
`N=∞` defeats LIV-1 (termination) — i.e. the *value* can break a *liveness*
property even though the *mechanism* is sound. **So N is policy only if the
engine clamps it: `N_effective = min(N_policy, N_hard_ceiling)` with a hard
engine ceiling.** *Cost asymmetry:* unclamped N as pure policy ⇒ a fat-fingered
`N=10⁶` livelocks a unit for days burning budget; clamped ⇒ one `min`.
**Recommend: policy value, engine-clamped.** Same pattern for budget: policy sets
the number, engine guarantees `spent ≤ that-number` and refuses a "no-limit"
sentinel (budget=∞ ⇒ reject, force an explicit finite ceiling).

**Q-3 — Conflict-check clause predicates: policy or invariant?** The *count=5*
and *admit-only-when-all-clear* are engine (INV-13). The *predicate bodies*
(what "disjoint codepoints" means per language) are arguably Q-policy *and* per-
language (they ride Seam-T). *Risk:* a weakened predicate (always-returns-clear)
defeats isolation safety. *Decision:* predicate may be *stricter* than the engine
default but the engine retains a *conservative core predicate* (file-set
disjointness computed by the engine from the frozen path sets, not delegable to a
plugin) so a lying language-plugin predicate can only *add* serialization, never
*remove* the engine's file-disjointness guard. *Cost asymmetry:* fully-delegated
predicate ⇒ a buggy adapter merges two units editing the same file; engine-core
predicate ⇒ adapter can refine but not loosen. **Recommend: engine-core
conservative predicate + optional plugin tightening.**

**Q-L1 (merge fairness) / Q-L2 (re-gate storms)** — inherited; resolved here as
*policy on an engine-fair queue*: FIFO+aging is P1 data; the *no-starvation*
property is C1 engine. Cost asymmetry per liveness.md.

---

### Summary of the strength claim (defended)

For all plugin behaviours `b ∈ {Toolchain, Provider, Gate, Impl-agent, Policy
datum}`: the stable-core invariants INV-1..7, INV-10..22 + CON-1..7 hold,
**provided** the two flagged borderline data (gate-floor FLAG-1, retry/budget
value FLAG-2) and the conflict-core-predicate (Q-3) are kept in the engine, not
the policy plane. Those three are the precise loci where "looks like policy" is
actually invariant; mis-cutting any one of them is the single way the volatility
split would fail, and the shape pins all three on the engine side.
