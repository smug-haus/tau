# M10 parallelism — conflict-check batches (refs #458)

Read-only analyst pass. Applies the factory-loop **conflict check**
(`.claude/rules/factory-loop.md`, "The conflict check") to the remaining M10 /
#458 P5c tasks, to find which can run **concurrently in implementation** while
**merges stay serialized**. Merge ordering and the cycle-8a freshness re-check
(rebase + re-gate per merge) are unaffected by anything here.

The five clauses (ALL must hold to parallelise a pair):
1. **No dependency** — neither blocked by the other.
2. **Disjoint files** — expected changed-file sets (incl. gating-test paths) do not overlap.
3. **Disjoint codepoints** — do not modify the same function clause.
4. **No shared SPEC / D-NNN block** — do not both author/amend the same SPEC or D-NNN.
5. **Shared-resource isolation possible** — any non-worktree resource is isolatable.

> Note on clause 2 vs 3: two tasks touching the **same file at clearly separate,
> stable regions** MAY parallelise, but "the burden of proof is on the check;
> when in doubt, serialize." This analysis applies that burden explicitly for
> the `unit.ex` collision.

---

## 1. Candidate changed-file / changed-codepoint sets

Derived from the issue bodies, the SPEC-FACTORY-* Appendix-B source-maps, and a
direct read of the cited modules (function-clause line numbers below are from
`HEAD` at analysis time, indicative not load-bearing).

| Task | Status | Production files | Key codepoints | Gating-test path(s) | SPEC / D-NNN |
|---|---|---|---|---|---|
| **P5c-3a** (#467/#468) | **IN FLIGHT** | `worker.ex`, `unit.ex` | `worker.ex` `handle_info({port,{:data,_}},…)` (~L158, parse in-band `work_ready`) + death-monitor exit path (`:no_work_product`); `unit.ex` `implementing/3` `{:worker_done,…}`→`gating` trigger (~L271) + `oracle/3` analog | `test/tau/factory/worker_completion_event_test.exs` | FLEET D-326/AC-13; CORE §4 B8 |
| **P5c-3b** UnitDriver | not filed | **new** `unit_driver.ex` | starts Unit under `UnitSupervisor`; adapter closures: worker `work_ready`→Unit trigger, `Gate.run/1`→`:pass\|{:fail,_}`, MergeAuthority telemetry→`{:merge_result,_}` | new `unit_driver_test.exs` | CORE §4 (consumes B8 shape) |
| **P5c-4** IssueSelector | not filed | **new** `issue_selector.ex` | `gh`-backed `select_fun`: open milestone issues − L-terminal units → one frozen `work_item`\|`nil` | new `issue_selector_test.exs` | CORE D-331/D-342 |
| **P5c-5** escalation drain + dead-clause (#453 + #452) | filed (#452/#453) | `coordinator.ex` | #453: `running(:info,{:escalate,{_e,:global}},…)` (~L227)→route to `:halting` (drain); #452: delete `halted(:info,{:unit_finished,…})` clause (~L284) | `test/tau/factory/kill_switch_test.exs` (test-author refactor) + a new escalation-drain test | CORE §5, D-320, D-321/AC-7 |
| **P5c-6** production supervision | not filed | `supervisor.ex`, `application.ex` | factory subtree config-gate; start Coordinator with real `select_fun`/`drive_fun`/`:ledger` | supervision test | CORE (wiring) |
| **P5c-7** dogfood AC-12 | not filed | **new** `mix tau.factory.dogfood` task + e2e | end-to-end sandbox drive; planted "refuse real remote" guard | new dogfood e2e test | CORE AC-12 |
| **#466** symmetric reject durability | filed | `merge_authority.ex`, `ledger/writer.ex`, `unit.ex` | `merge_authority.ex` `integrating/3` `:build_failed`→`:health_red` eject arm (~L188-208) + write `:rejected` row (mirror `committing/3` `record_merge_outcome` ~L271); `writer.ex` `record_merge_outcome`/`parse_reason` (~L749); `unit.ex` `awaiting_merge/3` `{:merge_result,:rejected}` (~L395) + `reconcile_merge_outcome/1` (~L511) populated | `test/tau/factory/merge_outcome_durability_test.exs` (extend) | MERGE §6 / D-355 |
| **#457** SlashCommand flake | filed | `lib/tau/session/slash_command.ex` (+ session dispatch) | `handle_builtin_command/4` async `Task` reply race | `test/tau/session/*_builtin_dispatch_test.exs` | **non-factory** (no SPEC) |

**Dependency edges (validated):**
- **P5c-3b → P5c-3a (hard).** UnitDriver's worker-adapter closure bridges to the
  Unit's `implementing → gating` trigger, which P5c-3a is *redefining*
  (`{:worker_done}` placeholder → real `work_ready(worker_id,…)`). Building the
  adapter against the soon-to-be-deleted placeholder shape is rework. **Serialize.**
- **P5c-3b also needs P5c-2 (Gate orchestrator).** `gate.ex` `run/1` already
  exists at `HEAD` (P5c-2 landed: `gate.ex:110`, `gate_run_test.exs`), so this
  edge is **satisfied** — only the P5c-3a edge gates P5c-3b.
- **P5c-4 ↔ P5c-3b (co-design, soft).** #458 says IssueSelector's `work_item`
  shape is "co-designed with P5c-3's work_item shape." This is a *contract*
  coupling on a struct shape, not a file/codepoint overlap (disjoint new files).
  Manageable: pin the `work_item` shape in P5c-3a/3b's SPEC §4 first, or freeze
  it in the P5c-4 draft-PR body. Not a hard file conflict.
- **P5c-5 → P5c-3a (soft, "makes clause dead").** #452 schedules the dead-clause
  removal for "P5c, where real units wire into the drive seam and the clause
  becomes visibly dead." But the *mechanical* deletion + the #453 drain fix are
  **coordinator.ex-only** and need no change to `unit.ex`/`worker.ex`: the Unit
  already emits `{:unit_terminal,…}` and `halting/3` already consumes it. The
  "P5c" scheduling note is a *narrative* justification ("the clause is now
  visibly dead"), not a code dependency. **No hard edge to P5c-3a.** (See §3 note.)
- **P5c-6 → P5c-3, P5c-4 (hard).** Production supervision starts the Coordinator
  with the *real* `select_fun`/`drive_fun`, which are the deliverables of P5c-4 /
  P5c-3b. **Serialize after them.**
- **P5c-7 → all (hard).** Dogfood drives the whole assembled core end-to-end.
  **Last.**
- **#466 → P5c-3a: NO dependency.** Different Unit state (`awaiting_merge` vs
  `implementing`), different producer (`merge_authority.ex` vs `worker.ex`). The
  edge to assess is the **`unit.ex` file collision** (clause 2/3), not a
  dependency. See §2.
- **#457: independent of all factory work** (disjoint subsystem).

---

## 2. Pairwise conflict-check matrix

PASS = may parallelise; FAIL = must serialize, with the failing clause.

### 2a. Each candidate × the IN-FLIGHT P5c-3a (changed set = `{worker.ex, unit.ex[implementing/3,oracle/3], worker_completion_event_test.exs}`)

| Candidate vs P5c-3a | C1 dep | C2 files | C3 codepoints | C4 SPEC/D | C5 resource | Verdict |
|---|---|---|---|---|---|---|
| **#466** | ok (no dep) | **`unit.ex` SHARED** | distinct clauses (`awaiting_merge/3`+`reconcile_merge_outcome/1` vs `implementing/3`+`oracle/3`) | distinct (MERGE D-355 vs FLEET D-326) | ok | **FAIL (C2)** — same file `unit.ex`. See §2a-note. |
| **P5c-5** (#452+#453) | ok (no hard dep) | disjoint (`coordinator.ex`, `kill_switch_test.exs` vs `worker.ex`/`unit.ex`/`…event_test.exs`) | disjoint | distinct (CORE §5/D-320/D-321 vs FLEET D-326) | ok | **PASS** |
| **P5c-3b** | **blocked-by P5c-3a** | new file ok | bridges P5c-3a's redefined trigger | CORE consumes B8 (being authored) | ok | **FAIL (C1)** |
| **P5c-4** | ok (no dep on 3a) | disjoint (new `issue_selector.ex` + test) | disjoint | distinct (CORE D-331/342) | ok | **PASS** |
| **#457** | ok | disjoint (`session/*`) | disjoint | none (non-factory) | ok | **PASS** |
| **P5c-6** | **blocked-by P5c-3/4** | `supervisor.ex`/`application.ex` (disjoint from 3a) | disjoint from 3a, but dep-blocked | — | ok | **FAIL (C1, transitive)** |
| **P5c-7** | **blocked-by all** | new task | — | — | ok | **FAIL (C1)** |

**§2a-note — the `unit.ex` collision (#466 vs P5c-3a).** Clauses 1, 3, 4, 5 all
PASS: no dependency, **disjoint function clauses** (`implementing/3`+`oracle/3`
for 3a; `awaiting_merge/3`+`reconcile_merge_outcome/1` for #466), and distinct
SPEC/D-NNN blocks. Only **clause 2 (disjoint files) FAILS** — both edit
`unit.ex`. Per the conflict-check's stated burden ("the same file touched at
clearly separate, stable regions MAY still parallelise … when in doubt,
serialize"), the regions here ARE clearly separate and stable. But P5c-3a is
**in flight** (an implementer is mid-write in `unit.ex`); a second concurrent
writer to the same file risks a textual merge conflict and a mid-write gate
collision against an unstable branch. **Recommendation: serialize #466 behind
P5c-3a** — it costs one cycle and removes all ambiguity. (If maximal throughput
were required and P5c-3a were *committed and stable*, the disjoint-region case
could justify parallelising; it is not, so serialize.)

### 2b. Candidate × candidate (the set spawnable alongside P5c-3a: P5c-5, P5c-4, #457)

| Pair | C1 | C2 | C3 | C4 | C5 | Verdict |
|---|---|---|---|---|---|---|
| **P5c-5 × P5c-4** | ok | disjoint (`coordinator.ex`/`kill_switch_test.exs` vs new `issue_selector.ex`) | disjoint | distinct D-NNN | ok | **PASS** |
| **P5c-5 × #457** | ok | disjoint | disjoint | distinct | ok | **PASS** |
| **P5c-4 × #457** | ok | disjoint (factory vs session) | disjoint | distinct | ok | **PASS** |

The three non-3a parallel candidates are mutually disjoint → a valid **parallel
batch** with each other AND with P5c-3a.

### 2c. Next-wave candidates × each other (#466, P5c-3b — after P5c-3a merges)

| Pair | C1 | C2 | C3 | C4 | C5 | Verdict |
|---|---|---|---|---|---|---|
| **#466 × P5c-3b** | ok (both only need 3a) | **`unit.ex` SHARED** (#466 edits `awaiting_merge`/`reconcile`; P5c-3b is a new file but its adapter targets `unit.ex`'s `implementing` trigger via injection — verify at spawn) | likely disjoint clauses | distinct (MERGE D-355 vs CORE §4) | ok | **PASS (conditional)** — disjoint clauses; confirm P5c-3b needs no `unit.ex` edit (pure new-file driver). If P5c-3b must edit `unit.ex`, **serialize**. |
| **#466 × P5c-4** | ok | disjoint | disjoint | distinct | ok | **PASS** |
| **P5c-3b × P5c-4** | co-design (soft) | disjoint new files | disjoint | distinct | ok | **PASS** (freeze `work_item` shape first) |

---

## 3. Recommended parallel batches

Merges are serialized throughout; each merge triggers the cycle-8a freshness
re-check (rebase onto fresh `origin/main` + full re-gate) for every other
in-flight branch.

### Batch A — spawn NOW, alongside the in-flight P5c-3a
Implementers that clear the 5-clause check against P5c-3a **and** each other:

- **P5c-5** — escalation drain (#453) + dead-clause removal (#452).
  `coordinator.ex` + `kill_switch_test.exs`. (File a single P5c-5 PR closing
  #452 + #453; the dead-clause is mechanically dead today, not gated on 3a.)
- **P5c-4** — IssueSelector (new `issue_selector.ex`). File the issue first.
  Freeze the `work_item` struct shape in its draft-PR body so P5c-3b co-designs
  against a fixed contract.
- **#457** — SlashCommand flake (non-factory; `lib/tau/session/*`). Independent;
  improves post-merge health-check stability (loop safety cond. 6).

→ **Spawn together: { P5c-3a [running], P5c-5, P5c-4, #457 }** — a 4-wide
implementation batch.

### Batch B — after P5c-3a merges (its `unit.ex`/`worker.ex` now stable on `main`)
- **#466** — symmetric reject-side durability. Was FAIL-on-C2 only because of the
  live `unit.ex` write in 3a; once 3a is merged, #466's `awaiting_merge` /
  `reconcile_merge_outcome` edits sit on stable code. Touches `merge_authority.ex`
  + `writer.ex` + `unit.ex`.
- **P5c-3b** — UnitDriver. Unblocked by P5c-3a's final `work_ready` trigger shape
  (and P5c-2's already-landed `Gate.run/1`).

→ #466 × P5c-3b is **PASS (conditional)**: parallelise *iff* P5c-3b is a pure
new-file driver with no `unit.ex` edit. Confirm at spawn; if P5c-3b must edit
`unit.ex`, run #466 → P5c-3b serially (or vice-versa). P5c-4 (if still in flight)
remains disjoint from both.

### Batch C — after P5c-3b + P5c-4 merge
- **P5c-6** — production supervision (`supervisor.ex`/`application.ex`); starts the
  Coordinator with the now-real `select_fun`/`drive_fun`.

### Batch D — last, after everything
- **P5c-7** — dogfood AC-12 (`mix tau.factory.dogfood` + sandbox e2e). Depends on
  the whole assembled core.

---

## 4. Hard serialization edges (the load-bearing constraints)

1. **P5c-3b → P5c-3a** (blocking file: `unit.ex` — the `implementing → gating`
   trigger contract). UnitDriver's worker adapter targets the trigger P5c-3a
   redefines; building it first is rework. **The one true hard edge in the 3-series.**
2. **#466 ⊣ P5c-3a** (blocking file: `unit.ex`). NOT a dependency — a clause-2
   file collision against an *in-flight* writer. Serialize #466 to Batch B; it is
   free to parallelise with everything else once 3a is stable.
3. **P5c-6 → {P5c-3b, P5c-4}** and **P5c-7 → all** (blocking files:
   `application.ex`/`supervisor.ex` need real fns; dogfood needs the assembled
   loop). Standard end-of-chain integration ordering.

## 5. Forbidden moves (explicit)

- MUST NOT spawn a second concurrent writer to `unit.ex` while P5c-3a is mid-write
  (#466, and any P5c-3b variant that edits `unit.ex`). Wait for 3a to merge.
- MUST NOT spawn P5c-3b before P5c-3a merges — its adapter would target the dead
  `{:worker_done}` placeholder.
- MUST NOT merge two PRs concurrently — implementation parallelism only; the gate
  + merge stay serialized, freshness re-check (8a) fires per merge.
- MUST NOT skip filing issues for the not-yet-filed tasks (P5c-3b, P5c-4, P5c-6,
  P5c-7) before opening their draft PRs.
