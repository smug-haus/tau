# Gap 3 — Unit ↔ Merge result-signal drift (ledger-pattern + crash-window evaluation)

> Read-only architecture-integrity analysis. Refs #460. No production code
> changed. Sources: `lib/tau/factory/merge_authority.ex`,
> `lib/tau/factory/unit.ex`, `lib/tau/factory/ledger/{writer,reader,migrations}.ex`,
> `lib/tau/factory/coordinator.ex`, `docs/spec/SPEC-FACTORY-MERGE.md` §4 (B1/B8),
> `docs/spec/SPEC-FACTORY-CORE.md` §4 B3 / §5 (D-315, D-344), `docs/arch/04-…/
> merge-and-integration.md` §1, `docs/arch/04-…/control-plane.md` §5,
> `docs/arch/05-verification/final-validation.md` (H-1/H-1b).

## Executive summary

**Position: REVISE.** The merge outcome should become a durable, append-only
Ledger record — appended by M *before* it acks/projects the result, read by
U/Coordinator on resume — with PubSub/telemetry as a derived projection. This is
the same Ledger pattern the factory already applies to `verdicts`,
`unit_snapshots`, `budget_debits`, and `captures`; the merge outcome is the one
terminal-deciding fact that is currently *only* an ephemeral event and is
therefore the lone hole in the RPO=0 (D-315) discipline at the merge boundary.

**Single most important crash-window finding:** A Unit rehydrated at
`awaiting_merge` (the D-344 resume path) **re-enters `awaiting_merge(:internal,
:on_enter)` and re-calls `merge_fun` unconditionally** (`unit.ex:343-347`),
re-submitting a merge that may have **already landed on `origin/main`**. Nothing
durable tells U "this merge already happened," because the `:merged` outcome
lives only in a telemetry event (`merge_authority.ex:264`) that does not survive
a crash. This is a **double-merge / re-gate-of-merged-work** exposure at exactly
the terminal transition D-344 promises is exactly-once.

The git-state idempotency of `cas_push` (`--force-with-lease`) *mitigates but
does not close* the hole — see §3.

---

## 1. The drift, precisely

The architecture specifies (SPEC-FACTORY-MERGE §4 B1, B8; arch
merge-and-integration.md §1; control-plane.md §5):

- `request_merge/2 :: (unit_id, hash) -> :queued` — **non-blocking**; the result
  `:merged` / `{:rejected, reason}` arrives **async on the PubSub topic
  `"factory:pr:#{unit_id}"`** (B1), with `[:tau, :factory, :merge, …]` telemetry
  as an *observer* fan-out (B8). C217: "the **result plane is PubSub**."
- SPEC-FACTORY-CORE §5: U waits in `awaiting_merge`; `M :merged → merged`
  (terminal); `M reject → gating` (re-gate, INV-2).

The implementation drifted on **both** ends of the edge:

| Concern | Spec / arch | Implementation | File |
|---|---|---|---|
| Producer signal | PubSub `"factory:pr:#{unit_id}"` (B1/B8/C217) | bare telemetry `[:tau,:factory,:merge,:merged\|:reject]`, **not keyed to the unit, no PubSub** | `merge_authority.ex:178,192,250,264,…396` |
| Consumer clause | U consumes the async result | U *nominally* waits for `{:merge_result, :merged\|:rejected}` (`unit.ex:349,353`) but **nothing publishes that message** — telemetry events are not `send`s to U's mailbox | `unit.ex:343-356` |
| Wiring | U subscribes to `"factory:pr:#{id}"` and maps the event to `{:merge_result, _}` | **absent** — no subscription, no translator, no `report_to`-style bridge | — |

So the edge is *unbuilt*: M emits a telemetry event no one routes to U, and U
blocks in `awaiting_merge` until its `:state_timeout` (`:merge_stalled`,
`unit.ex:358`) fires → `escalate(:E_MERGE_STALLED)`. **In the current build the
happy path cannot complete** — every merge "succeeds" on `origin/main` yet every
U escalates on merge-stall. That is the surface bug. The deeper question is what
the *correct* repair is, and whether the spec's async-PubSub contract is itself
sufficient once wired.

---

## 2. Is "merge outcome tracked on both producer and consumer" a Ledger pattern?

**Yes — by direct analogy to the four append-only tables already in L.**

The factory's durability discipline (D-315, RPO=0; `writer.ex` moduledoc
"WAL-before-ack") is: *any decision whose loss on crash would corrupt the
control loop is written WAL-before-ack to an append-only L table, and the
in-memory/PubSub/ETS copy is a derived projection rebuilt on resume.* The
existing tables instantiate exactly this:

- `verdicts` — the gate decision (read back inside the merge CAS, HR-2).
- `unit_snapshots` — the U FSM *state* per transition (read back by
  `Coordinator.init/1` for D-344 resume).
- `budget_debits` — egress cost decisions (rebuilt into the `Budget.Owner` ETS
  snapshot in `init/1`; the snapshot "is never the writer of record",
  SPEC-FACTORY-CORE §3).
- `captures` — killed-worker WIP (D-334).

Each follows the shape: **append-only row, WAL-before-ack, projection derived,
re-read on resume.** The merge *outcome* (`{unit_id, hash, :merged | :rejected,
reason, tip_oid}`) has the same two properties that put the others in L:

1. **It is a control-loop decision.** `:merged` is the *terminal* fact for the
   Unit (U → `merged` sink) and the signal K uses to release scheduling and
   advance the milestone. `:rejected` drives the INV-2 re-gate loop. Losing it
   mis-drives the loop (see §3).
2. **Its only authoritative producer (M) is a single serialized writer** whose
   recoverable state is already "**derived from L on `init/1`**" (C218). M
   currently derives its *train/queue* from L but records *nothing* of its own
   *outputs* there — it only **reads** verdicts. The outcome is the one M-side
   fact with no durable home.

By the project's own rule (`writer.ex`: append-only; D-315), a fact with these
properties belongs in L, with PubSub/telemetry as the derived projection — which
is precisely what B8 already calls the PubSub/telemetry plane ("never the control
path"). The async contract and a durable record are **not** alternatives: the
async event should be the *projection of* the durable append, exactly as the
`Budget.Owner` ETS snapshot is the projection of `budget_debits`.

`unit_snapshots` does **not** already cover this. It records the U *state name*
(`awaiting_merge`), not the *merge result*. Two units both crash-snapshotted at
`awaiting_merge` are indistinguishable in L regardless of whether M has since
landed one of them. The state-snapshot says "U was waiting"; it cannot say "the
thing U was waiting for has happened."

---

## 3. What is compromised or lost by the drift — crash-window trace

Let `B_merged` = M completed `cas_push :ok` and advanced `origin/main`;
`E_merged` = the ephemeral `:merged` telemetry event (the only current carrier of
the outcome). The drift makes `E_merged` **non-durable and unrouted**.

### Window W1 — `:merged` lost across a U/Coordinator crash (the headline)

```
t0  U in awaiting_merge; snapshot_unit(awaiting_merge) durable in L   [intended]
t1  M: cas_push :ok → origin/main advanced to tip            (B_merged, durable in git)
t2  M: telemetry [:tau,:factory,:merge,:merged]              (E_merged, ephemeral)
t3  CRASH (U / Coordinator) BEFORE E_merged is observed/routed
t4  Coordinator.init/1: latest_unit_snapshots ⇒ unit at :awaiting_merge (non-terminal)
t5  D-344 rehydrate: drive_unit(unit_id) → fresh U → awaiting_merge(:on_enter)
t6  awaiting_merge(:on_enter): merge_fun(unit_id, hash) called AGAIN   (unit.ex:344)
```

At t4 the durable record says `awaiting_merge` (non-terminal), so D-344
**rehydrates** the unit (SPEC-FACTORY-CORE §5 step 2: rehydrate non-terminal;
step 3 *skips* only `:merged`/`:escalated`). But the merge **already landed**.
The outcome is lost because it was only `E_merged`. Two failure modes follow,
depending on what `merge_fun`/M then do:

- **Double-merge / re-gate of merged work.** U re-submits `request_merge`. M
  re-assembles a train for a branch whose content is already on `origin/main`.
  The `default_build` rebases the branch onto the (advanced) base and re-runs the
  health build; if the branch still has commits not equal to the new base it
  re-gates and re-pushes already-merged work; if the rebase yields an empty diff
  the train tip equals base and the second `cas_push` is a no-op or
  `:stale_ref`. Either way the system **re-does terminal work** — the exact thing
  D-344 step 3 exists to forbid. The CAS idempotency (next bullet) bounds the
  damage but does not prevent the wasted re-gate cycle and the spurious
  `awaiting_merge` re-entry.
- **Stall forever.** If on re-submit M rejects with `:stale_ref` and the wiring
  (once built) maps that to `{:merge_result, :rejected}` → U re-gates (INV-2);
  but the branch is already merged, so the re-gate is meaningless churn and may
  loop until `:state_timeout` → `E_MERGE_STALLED`. The unit escalates for a merge
  that *succeeded*. A merged PR surfaced to the operator as an escalation is a
  false E-signal.

**git-state idempotency — the genuine mitigation, weighed.** The architecture
leans on `--force-with-lease` so the *push itself* is idempotent: a re-submitted
already-landed branch cannot double-write `origin/main` (C218: "an in-flight push
that the WAL shows as un-acked is re-attempted — idempotent: the CAS rejects if
it already landed"). This is real and it prevents the **worst** outcome (a
corrupt second write to main). **But it does not make the outcome recoverable at
the level the control loop needs:**

1. **Idempotency ≠ observability.** git state tells you the *tip*, not *which
   unit's submission produced it*. From `origin/main` alone, U/K cannot answer
   "was *this* unit's merge the one that landed, or a different train member's,
   or a human's?" The merge outcome is a `(unit_id ↦ merged|rejected)` mapping;
   git carries only the aggregate ref. C218's idempotency reasoning is M-side
   ("re-attempt my own un-acked push"); it says nothing about U learning its own
   terminal outcome after U's crash.
2. **It reopens the cost D-344 is meant to remove.** D-344's promise is "resume
   re-does **no** terminal work." git-idempotency downgrades that to "resume
   re-does terminal work but the *push* is harmless." That is a strictly weaker
   invariant than the spec states, and it spends a full rebase+health-build cycle
   per crashed `awaiting_merge` unit on resume.
3. **Train membership erases the 1:1.** Under HR-5 a train batches B≥2 units into
   one tip. After a crash, git shows one advanced ref for the *whole batch*;
   deriving per-unit `:merged` from the ref requires knowing the train roster M
   held in memory — which is itself ephemeral unless recorded. So even
   "reconstruct from git" needs a durable per-unit roster, i.e. the very record
   this analysis recommends.

**Net:** git-state idempotency makes the loss *safe-at-the-ref* but **not
recoverable-at-the-unit**. The control-loop fact (this unit's terminal outcome)
is genuinely lost.

### Window W2 — `:rejected` lost across a crash

```
t1  M: cas_push {:error,:stale_ref} → telemetry [:…:reject] (E_reject, ephemeral)
t3  CRASH before E_reject routed
t4  resume: snapshot says awaiting_merge → rehydrate → merge_fun called again
```

Symmetric but **more benign**: re-submitting a *rejected* (un-merged) branch is
the correct action anyway (the branch did not land; it should re-enter a train or
re-gate). git state confirms the branch is *not* on main, so re-submit is sound.
W2 wastes a cycle but corrupts nothing. The asymmetry matters: **the durable
record is needed primarily for the `:merged` case**, where the safe action after
crash (skip — already done) is the *opposite* of what an un-recorded resume does
(re-submit).

### Does M record the merge OUTCOME durably anywhere today? — No.

Confirmed by inspection: `merge_authority.ex` writes **zero** L rows. Its only L
interaction is `cas.assert_all_verdicts_live(ledger, …)` — a **read**
(`merge_authority.ex:244`). There is no `merges` table in
`migrations.ex` (tables: `verdicts`, `budget_debits`, `captures`,
`unit_snapshots`). The landed-commit fact is recoverable from `origin/main`
*as a ref value* but not as a per-unit outcome (§3, W1).

### Is the `awaiting_merge → merged` terminal transition durable end-to-end? — No.

There is a **non-durable gap at exactly the merge boundary**:

- U's `:awaiting_merge` *entry* is (intended to be) durable via
  `snapshot_unit` (D-315). **Caveat:** in the current build U holds **no ledger
  reference at all** — `unit.ex init/1` takes no `:ledger` opt and never calls
  `snapshot_unit`, so even the state-snapshot is, today, unbuilt on the U side
  (a separate P5b wiring gap; the snapshot machinery exists in `writer.ex` but
  is not invoked from `unit.ex`). Assume that wiring lands.
- U's `awaiting_merge → merged` *transition* is driven by an event
  (`{:merge_result, :merged}`) whose **producer fact is not durable**. So the
  decision to enter the terminal sink rests on an ephemeral signal. Per D-315
  ("visibility(effect) ⊐ commit(decision)"), the *decision* here (this unit is
  merged) is never committed before its effect (telemetry) is visible — the
  ordering is inverted relative to every other L-backed decision. **The terminal
  transition is the one transition in the U FSM whose triggering fact violates
  RPO=0.**

---

## 4. Recommendation — REVISE (the minimal durable contract)

Make the merge outcome a durable, append-only Ledger record; PubSub/telemetry
becomes its projection. Minimal shape:

### 4a. New append-only L table (`migrations.ex`)

```sql
CREATE TABLE IF NOT EXISTS merge_outcomes (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  unit_id         TEXT    NOT NULL,
  hash            TEXT    NOT NULL,
  outcome         TEXT    NOT NULL CHECK (outcome IN ('merged','rejected')),
  reason          TEXT,                       -- nil for :merged; e.g. 'stale_ref'
  tip_oid         TEXT,                       -- the landed tip for :merged
  idempotency_key TEXT    NOT NULL UNIQUE,    -- deterministic per {unit_id, hash, train_attempt}
  inserted_at     TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
```

Append-only, `INSERT OR IGNORE` on `idempotency_key` (mirrors `unit_snapshots`).
Per-unit row even for a batched train (M iterates the roster on commit), so the
1:1 `unit_id ↦ outcome` mapping git cannot carry is preserved.

### 4b. Where M writes it — WAL-before-ack, *before* the projection

In `merge_authority.ex` `committing(:internal, {:commit, …})`, on `cas_push :ok`
(and on each terminal reject branch), **before** emitting the telemetry/PubSub
projection:

```
cas_push :ok
  → for each unit in train:
       Ledger.Writer.record_merge_outcome(ledger,
         %{unit_id: u.id, hash: u.hash, outcome: :merged,
           tip_oid: tip, idempotency_key: key(u, tip)})     # WAL-before-ack
  → Phoenix.PubSub.broadcast("factory:pr:#{u.id}", {:merge_result, :merged})  # projection
  → telemetry(:merged, …)                                                     # projection
```

The append must precede the projection so a crash after the append but before the
broadcast still leaves the outcome recoverable (RPO=0). The broadcast is then the
*derived* notification, not the source of truth — exactly the
`budget_debits`→ETS relationship.

### 4c. How U / Coordinator reads it on resume

Two integration points, both already have a home:

1. **Wire the live edge (also fixes the surface bug):** U subscribes to
   `"factory:pr:#{unit_id}"` on `awaiting_merge` entry and maps
   `{:merge_result, _}` into its existing clauses (`unit.ex:349,353` already
   exist — they just need a real producer).
2. **Resume reconciliation (the durable fix):** in `awaiting_merge(:on_enter)`,
   **before** re-calling `merge_fun`, consult L:
   `Ledger.Reader.merge_outcome_for(unit_id, hash)`:
   - `{:ok, :merged, tip}` → transition straight to `merged` terminal **without
     re-submitting** (D-344 exactly-once restored for this transition).
   - `{:ok, :rejected, reason}` → re-gate (INV-2) without a redundant merge round
     trip.
   - `:none` → the merge genuinely never completed → call `merge_fun` as today.

   Equivalently, `Coordinator.init/1` could read `merge_outcomes` alongside
   `latest_unit_snapshots` and rehydrate a unit whose snapshot says
   `awaiting_merge` but whose outcome row says `:merged` **directly into the
   skip/terminal set** — turning the D-344 step-3 "skip terminal" test from
   "state == :merged" into "state == :merged OR an outcome row exists." Either
   placement closes W1.

### 4d. Spec amendments this implies (spec-before-code)

- **SPEC-FACTORY-MERGE §3/§4:** add a constraint and a B-contract that the merge
  outcome is appended to L (WAL-before-ack) *before* the PubSub projection;
  amend C218 so "M's recoverable state derived from L" includes outcomes, not
  only the train/queue. (Owns a new D-NNN, e.g. *durable merge outcome*.)
- **SPEC-FACTORY-CORE §5:** amend the `awaiting_merge` resume rule so rehydration
  reconciles against the durable outcome before re-submitting (D-344 wording:
  "skip terminal" → "skip terminal **or outcome-recorded**").

This is genuinely **new state at a SPEC'd boundary**, so per
`spec-before-code.md` it cannot land silently — the §3/§4 amendment ships in the
same PR.

---

## 5. Why not "adequate-as-specified (P5c-3)"

The "adequate" position is: the async-PubSub contract + git-state idempotency
suffices; the drift is merely unbuilt wiring — build the PubSub edge and stop.
That position is **insufficient** for one reason the crash-window analysis makes
mechanical, not aesthetic:

> Even with the PubSub edge fully wired, the outcome event remains **ephemeral**.
> A crash in W1's window (t1–t3) destroys it, D-344 rehydrates the
> `awaiting_merge` unit, and U re-submits an already-landed merge. git-state
> idempotency keeps the *ref* safe but cannot tell U *its own* terminal outcome
> (no per-unit mapping in the ref; train batching erases the 1:1). So the
> "adequate" build still re-does terminal work on resume — violating D-344's
> stated guarantee — and can surface a merged PR as an `E_MERGE_STALLED`
> escalation.

The merge outcome is the **only** terminal-deciding control-loop fact in the
factory carried solely by an ephemeral event. Every comparable fact (verdict,
unit state, budget debit, capture) is already in L precisely so resume is
exactly-once. Leaving the merge outcome out is the lone inconsistency in the
RPO=0 design, and it sits at the highest-consequence transition (terminal,
side-effecting on shared `origin/main`). Build the PubSub wiring **and** back it
with the durable append; the PubSub event becomes the projection, not the record.

---

## Appendix — evidence index

| Claim | Source |
|---|---|
| M broadcasts bare telemetry, not unit-keyed PubSub | `merge_authority.ex:264,396` |
| M writes no L row; only reads verdicts | `merge_authority.ex:244` (sole L call) |
| U re-calls `merge_fun` unconditionally on `awaiting_merge` entry | `unit.ex:343-347` |
| U's `{:merge_result, _}` clauses have no producer | `unit.ex:349,353` |
| U holds no ledger ref / never snapshots | `unit.ex init/1` (no `:ledger` opt) |
| No `merges`/`merge_outcomes` table | `migrations.ex:23-82` |
| Spec contract: async `:merged`/`:rejected` via `"factory:pr:#{unit_id}"` | SPEC-FACTORY-MERGE §4 B1, B8; C217 |
| D-315 RPO=0: visibility(effect) ⊐ commit(decision) | SPEC-FACTORY-CORE §4 B3; `writer.ex` moduledoc |
| D-344: resume rehydrates non-terminal, skips terminal | SPEC-FACTORY-CORE §5; `coordinator.ex:98-153` |
| "Every transition snapshots before its external effect" | SPEC-FACTORY-CORE §5 (line ~391) |
| H-1/H-1b: U→M result async, not held call | final-validation.md H-1b; control-plane.md §5 (the U→M `call` row) |
