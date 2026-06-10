# Candidate shape — AUTHORITY-SPLIT

**Lens.** Boundaries follow the *writer-of-record*. `auth : Datum → Component`
is a total function (notation.md §Data). Every datum has **exactly one** writer;
all others read or *request*. Conservation laws (CON-1..7) and single-writer
invariants (INV-1..4) then hold *by construction*: a quantity with one writer
cannot be lost or double-counted, and HEAD-of-`main` with a sole writer cannot
be merged twice, stale, or ungated. Cross-authority dependence is **monitored
request/response**, never shared mutable state (D-S4: location-transparent; no
`:global`, no cross-boundary memory). All concrete state is mathematical;
runtime mapping is deferred to `04-software-architecture/`.

## 0. The authority assignment (datum → sole writer)

| # | Datum (the conserved/owned quantity) | Sole writer-of-record | Source |
|---|---|---|---|
| 1 | Intent: issue set + open/closed state | **A_TRACK** (external tracker, projected) | FR-1.1 |
| 2 | Solution tree: steps, attempts, verdicts, challenges, kill reasons, escalations | **A_TREE** | CON-1,2,7; FR-6.1; INV-16 |
| 3 | Budget ledger: `(spent, remaining, total)` per budget axis | **A_BUDGET** | CON-3; FR-7.1; INV-21 |
| 4 | Cost attribution: `spend → ∃! owner` | **A_COST** | CON-4; FR-7.4 |
| 5 | Per-PR plan-of-record + frozen scope (issue set, plan, AC/D-NNN) | **A_POR**(pr) | FR-1.3; INV-19; FR-8.3 |
| 6 | Gating-test path set `paths_g(pr)` | **A_ORACLE**(pr) | INV-5,6; FR-4.2 |
| 7 | Gate verdicts `verdict(g, diff(pr))` | **A_GATE**(pr) | CON-6; INV-1; FR-4.1 |
| 8 | HEAD-of-`main`, merge serialization, main-health verdict | **A_MERGE** | INV-1,2,3,4; FR-5.1 |
| 9 | Per-worker workspace + dirty state (3 kinds) | **A_WORK**(w) | INV-10,14,15; CON-5; FR-3.1,8.1 |
| 10 | Escalation log + operator delivery | **A_ESC** (co-authored with A_TREE) | CON-7; INV-18; FR-9.2 |
| 11 | Knowledge / durable memory | **A_MEM** | FR-6.2 |
| 12 | Conflict admission / scheduling decisions | **A_SCHED** | INV-13; FR-2.3,7.3 |
| 13 | Toolchain adapter registry (read-mostly catalog) | **A_TOOL** | FR-3.3,3.4; D-S2 |
| 14 | Egress governance (rate→breaker counters) | **A_EGRESS** | FR-7.2; NFR-EGRESS |
| 15 | Action-class verdict (destructive?) | **A_CLASS** (pure fn over a versioned policy datum) | INV-20; FR-5.3 |

**Co-location note (anticipating Q-1, Q-2).** Datums 2,5,7,10 are all *factory
decisions* written write-ahead (INV-16, RPO=0). They MAY share a single durable
transactional **authority host** (one store, one serialized writer) without
violating single-writer, because each datum still has exactly one *logical*
writer; co-location only shares the durability substrate, not the write right.
Datum 3 (budget) and 4 (cost) are kept logically distinct (different balance
equations) but are natural co-tenants of the same host. Whether A_TREE and
A_BUDGET share a *physical* authority is Q-2. A_MERGE (8) and A_WORK (9) MUST be
independent of that host and of each other (different failure/availability
profiles — see §6).

---

## 1. Components — `C = (S, E_in, E_out, →, Inv)`

Notation: `H` = append-only history; `proj` = pure projection (fold) over a
history; `⊥` = absent; `⊑` monotone. Each component lists the datum it owns.

### C1 · A_TRACK — intent authority (projected external)
- **Owns:** datum 1. *Writer-of-record is the external tracker*; A_TRACK is its
  in-factory **projection** with a bounded-staleness contract.
- `S = { issues : Id → {open, closed}, milestone : Id → M, etag, age }`.
- `E_in = { Reconcile(milestone), CloseRequest(i, pr) }`.
- `E_out = { IssueSet(milestone, issues), ReconRESULT(Δ) }`.
- `→`: `Reconcile` pulls tracker truth, recomputes `issues`, sets `age:=0`.
  `CloseRequest` is *forwarded* to the tracker, then re-projected (never a local
  write of closed-state).
- **Inv:** `□ ( state_local(i) = proj(tracker_history(i)) ∨ age ≤ Δ_track )`
  (bounded staleness; CON-2 reconciliation). The tracker, not A_TRACK, is the
  writer; A_TRACK cannot fabricate closed-state ⇒ no phantom progress.

### C2 · A_TREE — solution-tree authority (system of record)
- **Owns:** datum 2 (and hosts 5,7,10 — see co-location).
- `S = H_dec`, an append-only log of decision events
  `Dec = Step ⊎ Attempt ⊎ Verdict ⊎ Challenge ⊎ Kill ⊎ Escalation`, plus
  `view = proj(H_dec)` (the queryable tree; a rebuildable cache).
- `E_in = { Append(d), Query(q) }`. `E_out = { Committed(d), Result(view, q) }`.
- `→`: `Append(d)` ⇒ `H_dec := H_dec ⌢ d` *write-ahead* then `Committed`. No
  in-place mutation; corrections are compensating events.
- **Inv (CON-1,2; INV-16):**
  `□ ( decided(x) → x ∈ H_dec )` (no decision off-log);
  `□ ( |steps_recorded| = |steps_executed| )` via idempotent `Append`
  (dedup on `step_id`); `□ ( terminal(u) ∈ {merged,escalated,rejected} )`
  enforced as a legality check on Step-terminal events.
  RPO=0: `Committed` precedes any externally-visible effect of `d`.

### C3 · A_BUDGET — budget ledger
- **Owns:** datum 3.
- `S = { axis → (spent ∈ ℕ, total ∈ ℕ) }`, `remaining = total − spent`.
- `E_in = { Debit(axis, cost, action_id), TopUp(axis, Δ), Read(axis) }`.
- `E_out = { Admitted(action_id), Denied(action_id, E-BUDGET), Balance }`.
- `→`: `Debit` admits iff `spent + cost ≤ total`, then `spent += cost` *as one
  atomic step on the sole writer*; else `Denied` + raise E-BUDGET.
- **Inv (CON-3, INV-21, NFR-BUDGET-PRECISION):**
  `□ ( spent + remaining = total )` — single writer ⇒ no lost debit;
  `□ ( spent ≤ total )` — admission is pre-action;
  overrun `≤ 1` in-flight action's cost (check precedes effect). Idempotent on
  `action_id` (retry-safe at the egress boundary).

### C4 · A_COST — cost attribution
- **Owns:** datum 4.
- `S = H_spend`, events `spend = (amount, owner ∈ {step,agent,gate,model})`.
- `E_in = { Record(spend) }`. `E_out = { Attributed(spend) }`.
- `→`: append-only; `owner` mandatory and unique per `spend`.
- **Inv (CON-4):** `□ ( ∀ s. ∃! owner(s) )` and
  `□ ( Σ_owner attributed(o) = Σ amount )`. Distinct from A_BUDGET: A_BUDGET
  owns the *ceiling balance*; A_COST owns the *partition by owner*. Reconciled:
  `Σ_owner A_COST = spent(A_BUDGET)` (cross-authority audit each cycle).

### C5 · A_POR(pr) — per-PR plan-of-record + frozen scope
- **Owns:** datum 5 (one instance per PR; logically hosted in A_TREE).
- `S = { issues_decl, plan, AC, D-NNN, paths_g (filled at oracle phase),
  attempts ∈ ℕ, mode ∈ {refine,pivot}, frozen ∈ 𝔹 }`.
- `E_in = { Declare(scope), FreezePaths(paths_g), Refine, Pivot }`.
- `E_out = { Scope(pr), AttemptBound(reached?) }`.
- `→`: `Declare` once ⇒ `frozen := true`. `FreezePaths` once. `Refine` iff
  `attempts < N_refine`; else `Pivot` (new A_POR, attempts:=0); else escalate.
- **Inv (FR-1.3, INV-19, FR-8.3):**
  `□ ( frozen → issues = issues_decl )` (no silent scope growth);
  `□ ( attempts ≤ N_refine + N_pivot )`; `paths_g` write-once.

### C6 · A_ORACLE(pr) — gating-test authority
- **Owns:** datum 6. The **test-author role**, run *before* any implementer.
- `S = { paths_g ⊆ Path, committed ∈ 𝔹 }`.
- `E_in = { AuthorTests(AC, D-NNN, SPEC§4) }`.
- `E_out = { PathsFrozen(paths_g), SpecGap(detail) }`.
- `→`: writes one failing test per AC/D-NNN on the user path; commits; emits
  `paths_g`. On a §4 gap, emits `SpecGap` (blocks until SPEC amended).
- **Inv (INV-5,6,8):** `□ ( author(test_g) ≠ author(impl) )` — structural:
  A_ORACLE runs and *closes* before A_WORK(impl) is admitted;
  `□ ( ∀ t. exercises_user_entrypoint(t) )` (critic-checked residual, INV-8).

### C7 · A_GATE(pr) — gate-verdict authority
- **Owns:** datum 7 (logically hosted in A_TREE; one instance per PR-diff).
- `S = { verdict : (g, hash(diff)) → {PASS, FAIL, ⊥},
  g ∈ {critic, reviewer, ac_linkage, masking, mutation} }`.
- `E_in = { RunGate(pr, diff), ChallengeRuling(req) }`.
- `E_out = { Verdict(g, hash(diff), r), Green(pr, hash) | Red(pr, finding) }`.
- `→`: runs ALL five `g` against *one* `hash(diff)`; verdict keyed to that hash.
  `Green` iff `∀ g. verdict(g, hash) = PASS`. A challenge routes to an
  *independent* critic (never A_TREE/coordinator self-judgement).
- **Inv (INV-1, CON-6, INV-9, FR-4.1,4.4):**
  `□ ( green(d) → ∀ g. verdict(g, hash(d)) = PASS )`;
  verdict immutably keyed to `hash(diff)` ⇒ a stale verdict is *detectably*
  for a different hash (this is what makes INV-2 enforceable at A_MERGE);
  incomplete-fix: a finding falsifying a named AC ⇒ `Red` (no follow-up
  deflection). `> 2` upheld challenges ⇒ E-CHALLENGE.

### C8 · A_MERGE — merge / HEAD-of-`main` authority (THE funnel)
- **Owns:** datum 8. **Single-concurrency owner** (sole writer of `main`).
- `S = { head ∈ Commit, merging ∈ 𝔹, health ∈ {green, red, ⊥},
  waitq : ordered set of pr (fair: FIFO+aging) }`.
- `E_in = { RequestMerge(pr, diff, hash), HealthResult(r) }`.
- `E_out = { Merged(pr, head'), Rejected(pr, reason), ReGate(pr),
  E-RED-MAIN, E-CONFLICT }`.
- `→` (one critical section, mutual-exclusion by construction):
  1. `merging?` ⇒ enqueue (LIV-2 fairness). 2. read `A_GATE.Green(pr, hash)`;
  `⊥/FAIL` ⇒ `Rejected`. 3. **freshness:** read own `head`; if `base(diff) ≠
  head` ⇒ `ReGate` (don't merge stale). 4. `health = red` ⇒ refuse +
  E-RED-MAIN. 5. apply diff ⇒ `head := head'`; run post-merge health ⇒ set
  `health`. 6. dequeue next.
- **Inv (INV-1,2,3,4 — discharged DIRECTLY by sole-writer):**
  `□ ( |{d: merging(d)}| ≤ 1 )` — single owner ⇒ INV-3 by construction;
  `□ ( merge(d) → green(d) )` — step 2 is an unskippable precondition ⇒ INV-1;
  `□ ( merge(d) → fresh(d) )` — step 3 reads `head` *inside* the same critical
  section ⇒ INV-2 (no TOCTOU: read-and-merge are one atomic step on the sole
  writer); `□ ( red(main) → ¬∃ merge )` — step 4 ⇒ INV-4.

### C9 · A_WORK(w) — per-worker workspace + dirty state
- **Owns:** datum 9 (one instance per work unit; supervised crash domain).
- `S = { checkout ∈ Ref, caches : Resource → Namespace,
  dirty = (staged, unstaged, untracked), alive ∈ 𝔹 }`.
- `E_in = { Spawn(ref, toolchain), Run(agent_io), Kill, Crash }`.
- `E_out = { Position(verified ref), Dirty(captured 3-tuple),
  Reclaimed(namespaces) }`.
- `→`: `Spawn` ⇒ system sets `checkout`; worker *verifies* (INV-12) or aborts.
  `Kill/Crash` ⇒ **capture-before-destroy**: emit `Dirty=(staged ∪ unstaged ∪
  untracked)` to a durable log, *then* `Reclaimed`.
- **Inv (INV-10,11,12,14,15,17; CON-5):**
  `□ ( w₁≠w₂ → workspace(w₁) ⫫ workspace(w₂) )` (isolation is a spawn property,
  total over toolchain-declared resources, D-S2);
  `□ ( ¬∃ w. mutates(w, HEAD(parent)) )` (no parent tree exists to mutate —
  coordinator holds no mutable checkout); `□ ( dies(w) → recoverable(committed ∪
  dirty₃) )`; `□ ( terminates(w) ↝ reclaimed )`; `blast_radius(w)={w}`.

### C10 · A_ESC — escalation authority (co-authored with A_TREE)
- **Owns:** datum 10 (the *delivery + record* of escalations).
- `S = { raised : Id → (e ∈ E, snapshot, delivered ∈ 𝔹) }`, `E` = the total
  escalation set (liveness.md).
- `E_in = { Raise(e, scope, snapshot) }`. `E_out = { Notify(operator), HaltScope }`.
- `→`: `Raise` ⇒ append to A_TREE (record) ∧ `Notify` (deliver) ∧ halt scope
  (per-unit | global). Catch-all unmatched non-progress ⇒ `E-UNCLASSIFIED`.
- **Inv (CON-7, INV-18):** `□ ( raised(e) → delivered(e) ∧ recorded(e) )`
  (no raise-and-swallow); `□ ( ¬progress(s) → ∃! e. escalates(s,e) )` (total;
  catch-all closes it).

### C11 · A_MEM — knowledge / durable memory
- **Owns:** datum 11.
- `S = { entries : Key → (heuristic | taxonomy | trajectory), index }`.
- `E_in = { Write(entry), Search(query) }`. `E_out = { Hits(query) }`.
- `→`: append + index; read-mostly. Single writer of an entry's canonical form.
- **Inv (FR-6.2):** `□ ( recurring_failure ↝ ∃ heuristic )` (liveness, not
  safety); search returns a function of the entry history (bounded staleness OK).

### C12 · A_SCHED — admission / conflict authority
- **Owns:** datum 12 (which units are admitted concurrent).
- `S = { running : set of unit, conflict : (u₁,u₂) → {clear, block} }`.
- `E_in = { Propose(unit), Terminated(unit) }`.
- `E_out = { Admit(unit), Serialize(unit, blocker) }`.
- `→`: `Propose(u)` admits iff the **five-clause check** clears against *every*
  `u' ∈ running` (no-dep ∧ disjoint-files incl. `paths_g` ∧ disjoint-codepoints
  ∧ no-shared-SPEC/D ∧ isolatable-resources); else `Serialize`. Admission also
  gated by A_BUDGET.Admitted.
- **Inv (INV-13, FR-2.3,7.3; LIV-4):**
  `□ ( concurrent(u₁,u₂) → conflict_check = clear )`; monotone serialization
  (a blocked unit runs once its blocker terminates) ⇒ no livelock.

### C13 · A_TOOL — toolchain registry (read-mostly catalog)
- **Owns:** datum 13. Node-local read-mostly (D-S4-justified).
- `S = { lang → adapter }`, `adapter` = behaviour
  `{ install, build, test, lint, mutation_run, package }`.
- `E_in = { Register(lang, adapter), Lookup(lang) }`. `E_out = { Adapter }`.
- **Inv (FR-3.3,3.4):** all gating/health/isolation dispatch through `adapter`,
  never a hardcoded runner; Elixir/BEAM adapter is the bootstrap proving case.

### C14 · A_EGRESS — egress governor
- **Owns:** datum 14. Compose order **rate-limiter → breaker → budget**.
- `S = { tokens : provider → ℕ, breaker : provider → {closed,open,half} }`.
- `E_in = { ProviderCall(p, action_id) }`. `E_out = { Pass | Throttle | Trip }`.
- `→`: token-bucket admit → breaker state → forward to A_BUDGET.Debit.
- **Inv (NFR-EGRESS):** `□ ( 0 sustained 429/5xx-failures )` under documented
  limits; order is load-bearing (breaker before budget).

### C15 · A_CLASS — action classifier (pure)
- **Owns:** datum 15 — a *versioned policy datum* (the destructive whitelist).
- Pure fn `classify : Action × Policy → {ordinary, destructive}`.
- **Inv (INV-20, FR-5.3):** `□ ( destructive(a) → escalate ∧ ¬auto_execute )`.
  Stateless over a single-writer policy datum (volatility: quarterly).

---

## 2. Composition graph — per-edge `{pre} e {post}` + failure clause

Every edge is a **read or request across an authority boundary**. No edge shares
state. Ordering and idempotency stated per edge.

```
A_TRACK ──IssueSet──▶ A_SCHED ──Admit──▶ A_POR ──Scope──▶ A_ORACLE ──PathsFrozen──▶ A_WORK(impl)
   ▲                     │                  │                                          │
 CloseRequest            │ Propose          │ FreezePaths                              │ RunGate(diff)
   │                     ▼                  ▼                                          ▼
A_MERGE ◀──Green/ReGate── A_GATE ◀──────────┴──────────── (diff, hash) ───────────────┘
   │  │                     ▲
 Merged│                    │ ChallengeRuling (independent critic)
   │  └──RequestMerge───────┘
   ▼
A_TREE ◀──Append(all decisions)──▶ A_ESC ──Notify──▶ operator
   ▲                                  ▲
 Debit/Read                           │ Raise(e, snapshot)
   │                                  │
A_BUDGET ◀──Record/recon──▶ A_COST    A_WORK ──Dirty(3-tuple)──▶ (durable capture log ⊆ A_TREE host)
   ▲
A_EGRESS ──Debit──┘     A_TOOL (looked up by A_WORK, A_GATE)    A_CLASS (pure, queried by A_MERGE/A_WORK)
```

| Edge | `{pre} event {post}` | Ordering | Idempotency | Failure clause |
|---|---|---|---|---|
| A_TRACK→A_SCHED | `{recon fresh} IssueSet {scheduler sees honest open set}` | reconcile ≺ propose | `Reconcile` idem on `etag` | stale (age>Δ) ⇒ A_SCHED blocks admission, raises recon |
| A_SCHED→A_POR | `{conflict clear ∧ budget admit} Admit {scope can be declared}` | admit ≺ declare | dedup on `unit_id` | denied ⇒ Serialize(unit, blocker); budget-deny ⇒ E-BUDGET |
| A_POR→A_ORACLE | `{frozen scope} AuthorTests {paths_g exist}` | declare ≺ author ≺ impl | path-set write-once | SpecGap ⇒ block, amend SPEC §3 in-PR |
| A_ORACLE→A_WORK(impl) | `{paths_g frozen} Spawn {impl cannot write paths_g}` | oracle ≺ impl (**INV-5 structural**) | spawn idem on `unit_id` | oracle absent ⇒ impl MUST NOT spawn (gate-bypass) |
| A_WORK→A_GATE | `{diff committed, stable} RunGate(hash) {verdict keyed to hash}` | impl-commit ≺ gate | gate idem on `(g, hash)` | runner crash ⇒ Verdict=⊥ (exit-3 infra, not a decision) |
| A_GATE→A_MERGE | `{∀g PASS @hash} Green(hash) {merge precondition true}` | gate ≺ merge | Green idem on `hash` | FAIL ⇒ Red→refine; ⊥ ⇒ A_MERGE refuses |
| A_MERGE self/loop | `{green ∧ base=head ∧ ¬red} apply {head'}` | **serialized critical section** | merge idem on `hash` (re-request ⇒ already-merged) | base≠head ⇒ ReGate; red ⇒ E-RED-MAIN; conflict ⇒ E-CONFLICT |
| any→A_BUDGET | `{action_id} Debit(cost) {spent+=cost ∨ denied}` | debit ≺ action effect | **idem on action_id** (critical: retried egress) | at ceiling ⇒ Denied + E-BUDGET |
| A_EGRESS→A_BUDGET | `{tokens∧breaker ok} Debit {provider call admitted}` | rate≺breaker≺budget | idem on action_id | trip ⇒ Throttle; no Debit |
| any→A_COST | `{owner present} Record(spend) {attributed}` | record ≺ report | append-only, idem on spend_id | missing owner ⇒ reject (CON-4 guard) |
| any→A_TREE | `{decision made} Append(d) {Committed, then effect visible}` | **append ≺ external effect (RPO=0)** | idem on decision_id | host down ⇒ block the deciding action (fail-closed, see §4-cut-A) |
| *→A_ESC | `{non-progress ∨ halt cond} Raise(e, snapshot) {delivered∧recorded}` | record ∧ deliver (both) | idem on escalation_id | delivery fails ⇒ retry+persist; never drop (CON-7) |
| A_WORK→capture log | `{dies(w)} Dirty(staged,unstaged,untracked) {recoverable}` | capture ≺ reclaim | idem on (w, snapshot_hash) | capture fails ⇒ do NOT reclaim (hold workspace) |
| A_WORK/A_GATE→A_TOOL | `{lang} Lookup {adapter}` | — (read-mostly) | pure read | unknown lang ⇒ E-UNCLASSIFIED (no adapter) |

---

## 3. Enforcement matrix — R × C (every INV / CON / LIV)

`●` = primary enforcer (owns the invariant inside its boundary); `○` = reads/participates.

| Req | A_TRACK | A_TREE | A_BUDGET | A_COST | A_POR | A_ORACLE | A_GATE | A_MERGE | A_WORK | A_ESC | A_SCHED | A_EGRESS | A_CLASS |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| INV-1 gate-before-merge | | ○ | | | | | ● | ● | | | | | |
| INV-2 freshness | | | | | | | ○ | ● | | | | | |
| INV-3 serialized merge | | | | | | | | ● | | | | | |
| INV-4 main health | | ○ | | | | | | ● | | ○ | | | |
| INV-5 oracle separation | | | | | ○ | ● | | | ○ | | ○ | | |
| INV-6 gating-test immut. | | | | | | ● | ●(masking) | ○ | ○ | | | | |
| INV-7 non-vacuous | | | | | | ○ | ●(mutation) | ○ | | | | | |
| INV-8 user-path oracle | | | | | | ●(crit) | ○ | | | | | | |
| INV-9 incomplete-fix | | ○ | | | ○ | | ● | ○ | | | | | |
| INV-10 resource isolation | | | | | | | | | ● | | ○ | | |
| INV-11 no shared tree | | | | | | | | ○ | ● | | | | |
| INV-12 verified position | | | | | | | | | ● | | | | |
| INV-13 conflict concurrency | | | | | | | | | | | ● | | |
| INV-14 no lost work | | ○ | | | | | | | ● | | | | |
| INV-15 reclaimed isolation | | | | | | | | | ● | | | | |
| INV-16 durable state | | ● | ○ | ○ | ○ | | ○ | ○ | | ○ | | | |
| INV-17 crash containment | | | | | | | | | ● | | | | |
| INV-18 total escalation | | ○ | | | | | | | | ● | ○ | | |
| INV-19 bounded retry | | ○ | | | ● | | | | | | | | |
| INV-20 no destruction | | | | | | | | ○ | ○ | ○ | | | ● |
| INV-21 budget ceiling | | | ● | | | | | | | | ○ | ○ | |
| INV-22 clean kill | | ○ | | | | | | ●(boundary) | | | ○ | | |
| INV-23 spec-before-code | | ○ | | | ● | ○ | ○(gate Q) | | | | | | |
| INV-24 OTP non-neg | | | | | | | ●(critic) | | | | | | |
| CON-1 work conservation | ○ | ● | | | | | | | | | ○ | | |
| CON-2 issue reconcil. | ● | ● | | | | | | | | | | | |
| CON-3 budget conserv. | | | ● | | | | | | | | | ○ | |
| CON-4 cost attribution | | | ○ | ● | | | | | | | | | |
| CON-5 artifact conserv. | | ○ | | | | | | | ● | | | | |
| CON-6 verdict conserv. | | ○ | | | | | ● | ○ | | | | | |
| CON-7 escalation conserv. | | ● | | | | | | | | ● | | | |
| LIV-1 unit termination | | ○ | | | ●(bound) | | | | | ○ | | | |
| LIV-2 merge progress | | | | | | | | ●(fair q) | | | | | |
| LIV-3 milestone term. | ○ | ○ | | | | | | | | | ○ | | |
| LIV-4 no livelock | | | | | | | | | | | ●(monotone) | | |
| LIV-5 recovery progress | | ●(RPO=0) | | | | | | | | | | | |

**No empty row** (every INV/CON/LIV has a `●`). **No empty column.** The
conservation laws CON-1..7 each have a single `●` writer-of-record — that is the
double-entry guarantee: one writer ⇒ the balance equation cannot be raced.

### Why single-writer discharges CON-1..7 by construction
- **CON-3, CON-4 (budget, cost):** A_BUDGET is the sole `spent`-writer ⇒
  `spent+remaining=total` is a *local* invariant of one process, never a
  distributed sum. No two requesters can both debit; debit-then-admit is one
  atomic step. A_COST sole-writes the owner partition ⇒ `∃! owner`. The two
  reconcile (`Σ A_COST = spent`) as an audit, not a coordination.
- **CON-1, CON-2, CON-7 (work, issue, escalation):** A_TREE is the sole
  decision-writer; terminal-state legality is checked at append ⇒ no unit can
  be in two terminal sets or none. A_TRACK projects the *external* writer ⇒
  reconciliation is a staleness check, not a second writer.
- **CON-5 (artifact):** A_WORK(w) sole-owns its dirty state; capture-before-
  reclaim is a precondition of the *same* owner's termination ⇒ no third party
  can reclaim before capture.
- **CON-6 (verdict):** A_GATE sole-writes verdicts, each keyed to `hash(diff)`
  ⇒ a "merged with stale verdict" state is unreachable because A_MERGE's
  precondition reads `Green(pr, hash)` for the *exact* hash it is about to apply.

### Why sole-writer-of-HEAD discharges INV-1..4 directly
A_MERGE is the *only* writer of `head(main)` and runs at concurrency 1. In one
atomic critical section it (a) reads `Green@hash` (INV-1), (b) reads its own
`head` and compares `base(diff)` (INV-2 — no TOCTOU because read and write are
the same owner's uninterrupted step), (c) is structurally singular (INV-3), (d)
reads `health` (INV-4). No lock discipline, no distributed consensus: the funnel
*is* the proof.

---

## 4. Failure cuts (requirement-level behavior)

**Cut A — an authority becomes unavailable (block vs proceed).**
- **A_MERGE down:** the loop **proceeds** on implementation/gating (workers,
  oracles, gates are independent) but **blocks at merge** — no INV-1..4 can be
  violated because the sole writer is simply absent (fail-closed). LIV-2 degrades
  (merge starvation) until A_MERGE restarts from durable `head`/`waitq`.
- **A_TREE down:** the loop **blocks all decisions** (fail-closed: `Append ≺
  external effect`, so no effect proceeds without a commit). This is correct —
  RPO=0 forbids effect-before-record. Recovery: reload from durable log (LIV-5).
- **A_BUDGET down:** **blocks all billable actions** (no Debit ⇒ no admission).
  Fail-closed preserves INV-21 (cannot overspend if you cannot admit).
- General rule: an unavailable *authority* blocks only the datum it owns; sibling
  authorities proceed (D-S4 independence). The system never proceeds *past* an
  authority by guessing its datum.

**Cut B — stale read across a boundary (A_MERGE reads a superseded gate verdict).**
A_GATE verdicts are keyed to `hash(diff)`. If `origin/main` advanced,
`base(diff) ≠ head` at step 3 ⇒ A_MERGE emits `ReGate` *before* applying ⇒ the
superseded verdict is never used to merge. **INV-2 holds** even though the read
was stale, because freshness is checked against `head` *inside the merge critical
section*, and the verdict's hash would not match the rebased diff. A stale
`Green(pr, hash_old)` simply fails to satisfy the precondition for `hash_new`.

**Cut C — two requesters race for the same authority.**
- *Two PRs RequestMerge:* A_MERGE serializes via `waitq` (FIFO+aging, LIV-2);
  exactly one is in the critical section; INV-3 holds by construction. The loser
  waits, then hits the freshness re-check (likely ReGate, expected under
  concurrency).
- *Two actions Debit budget:* A_BUDGET is single-writer; debits are totally
  ordered on the owner; the second sees the first's `spent`. No lost update
  (CON-3). Idempotent on `action_id` ⇒ a retried debit is absorbed.
- *Two workers Propose to A_SCHED:* admission is evaluated against the live
  `running` set one Propose at a time; the conflict check is the arbiter
  (INV-13). A late-arriving conflicting unit is serialized, not admitted.

**Cut D — worker crash mid-run (INV-14/17, CON-5).**
A_WORK(w)'s supervisor runs capture-before-destroy: emits `Dirty=(staged,
unstaged, untracked)` to the durable log *then* reclaims namespaces.
`blast_radius={w}` (no cross-worker shared state ⇒ peers unaffected, NFR-BLAST).
The unit's attempt is recorded in A_TREE; the FSM (A_POR) decides refine/pivot —
a *semantic* outcome, not a supervisor restart (FR-8.2).

**Cut E — coordinator/host restart (LIV-5, INV-16).**
A_TREE is the system of record; on restart, `view = proj(H_dec)` rebuilds, and
in-flight PRs resume from their last committed decision (RPO=0, RTO p95 ≤ 60 s).
No terminal unit is re-done (idempotent Append on decision_id). A_MERGE reloads
`head`/`health`/`waitq`; if it was mid-critical-section, the merge either
committed (head advanced, durable) or did not (re-request, idempotent on hash).

**Cut F — A_BUDGET exhausted (E-BUDGET, global).**
A_BUDGET denies the next admission; A_EGRESS stops forwarding; A_ESC raises
E-BUDGET (global halt). In-flight units run to their clean checkpoint (INV-22),
`main` synced, then the loop halts. CON-3 still balances at the ceiling.

---

## 5. Path arithmetic & queue stability — contention at NFR-CONC peak

**Two single-writer funnels are the contention points: A_MERGE and A_BUDGET.**

**A_MERGE (the dominant funnel).** Service = merge + post-merge health,
`μ_merge = 1 / T_merge`, `T_merge` p95 ≤ 8 min (NFR-MERGE-RATE, toolchain-bound).
Arrival = green+fresh PRs. Stability `λ_merge < μ_merge`:
- At peak `C_max = 16` (NFR-CONC), each merge advances `head` ⇒ forces ≤ 15
  freshness re-checks (Q-L2). Re-gate cost per merge `≈ 15 · T_gate`. If
  `T_gate ≈ T_merge`, total work per merge ≈ `T_merge·(1 + 15)` — *super-linear
  in concurrency*. This is the re-gate storm.
- **Consequence (matches nfrs.md):** at peak ≤ 16, bounded fan-out
  (`λ < μ` holds with re-gate amortized) suffices. **Past ~32, A_MERGE
  saturates** and a back-pressure / merge-batch boundary is warranted. The
  single number C_max decides whether that machinery exists (Q-L2 / Q-4).
- **Mitigation in-shape:** A_SCHED admission-controls in-flight count so
  `λ_merge` stays below `μ_merge`; A_MERGE's fair queue (FIFO+aging) prevents a
  large branch starving behind small ones (LIV-2, Q-L1).

**A_BUDGET (high-rate funnel, low service cost).** Every billable action Debits.
`λ_budget` ≫ `λ_merge` (one Debit per agent action across ≤128 agent processes,
NFR-AGENT-FLEET), but `μ_budget` is enormous (in-memory CAS-style increment on
one owner). Stable as long as the *single writer* can serialize increments
faster than actions arrive — trivially true at 10³–10⁵ process scale (D-S4).
The risk is not throughput but **the single writer as availability SPOF** — Cut
A blocks all spend if it is down; mitigated by durable reload (RPO=0) and a fast
RTO. *Open:* whether to shard A_BUDGET per budget-axis (notation §Conservation:
"shard by x when one sequencer won't do") — likely unnecessary at v1 scale.

**Path latency (intent → merged), synchronous spine:**
`L = L_recon + L_admit + L_oracle + L_impl + L_gate + L_merge`. Tail amplifies:
`P(all hops ≤ t) = Π P(hop_i ≤ t)` (independence). The toolchain-bound hops
(`L_gate`, `L_merge`) dominate (D-S2); control-plane hops are sub-second. The
loop throughput governor is `μ_merge`, not the control plane (by design,
NFR-MERGE-RATE).

**Growth of stored sets:** `|H_dec| = O(steps × attempts)` (append-only,
retention-bounded); `|H_spend| = O(actions)`; `|waitq| ≤ C_max`. A_TREE/A_COST
need a compaction-preserves-fold retention policy (invariant_catalog
§Monotonicity).

---

## 6. Open discriminating questions (with cost asymmetry)

**Q-1 — Do A_TREE, A_GATE-verdicts, A_POR, A_ESC share one physical authority
host?** They are all write-ahead factory-decision data with RPO=0 (INV-16).
Co-locating gives one transactional substrate and one reconciliation surface;
keeping them separate gives independent failure domains. *Asymmetry:* co-locating
when they should be split ⇒ one store's outage blocks all decision-making (Cut A
A_TREE — but that is *already* fail-closed-correct); splitting when they could
co-locate ⇒ N-way distributed-transaction across decision writers to keep the
tree, verdicts, and escalations mutually consistent (expensive, and risks a
verdict recorded without its tree step). **Lean: co-locate (single decision
host, one writer per logical datum); cheap to split a datum out later if a
hot-spot appears.** This is the single biggest structural choice in the shape.

**Q-2 — Does the budget ledger (A_BUDGET) share the decision host (A_TREE)?**
Budget is also durable, also RPO=0, but has a *radically different access
profile*: `λ_budget ≫ λ_decision` (per-action vs per-step). *Asymmetry:*
co-locating ⇒ high-rate debits contend with low-rate decision appends on one
serializer, and a budget hot-spot can stall the decision log (couples
NFR-BUDGET to NFR-RPO latency); keeping independent ⇒ a second durable store and
a cross-store reconciliation (`Σ A_COST = spent`, already required anyway).
**Lean: independent authority for A_BUDGET/A_COST** — different rate class
(shaping_heuristics §Split by rate), and the reconciliation edge already exists.
The conservation laws stay intact either way (single writer per datum); this is
purely a co-location/performance call, not a correctness one.

**(Secondary) Q-3 — A_MERGE/A_SCHED co-location?** Both gate concurrency, both
must be independent of the decision host (different availability profile). Likely
distinct processes, same node (D-S4). **Q-4 — C_max ceiling (NFR-CONC):** the
number that decides whether A_MERGE needs a back-pressure/merge-batch boundary
(re-gate storm past ~32); recommend peak=16, revisit on large backlogs.
