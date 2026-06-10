# Conservation laws — "nothing is silently lost or created"

Conservation laws are invariants of *accounting*: a quantity is neither created
from nothing nor destroyed silently. They are the requirements most often missed
because nothing visibly breaks when they are violated — work just quietly
vanishes. Each is a balance equation that must hold in every reachable state.

## Notation

`Σ` over a population; terminal state ∈ {merged, escalated, rejected};
`⊎` disjoint union. Each law: **balance equation** · **falsification test** ·
**authority** (who is the writer-of-record for the quantity).

---

**CON-1 Work conservation.**
Every accepted unit of intent reaches exactly one terminal state; none is
silently dropped.
`∀ u ∈ accepted_intent. terminal(u) ∈ { merged, escalated, rejected }` and
`accepted = merged ⊎ escalated ⊎ rejected ⊎ in_flight`.
*Falsify:* an accepted unit that is neither in-flight nor in any terminal set
(it "disappeared"). *Authority:* the factory backlog / solution tree.

**CON-2 Issue reconciliation.**
The solution tree and the external issue tracker agree on the state of every
issue in scope; no factory step is lost or double-counted.
`∀ i ∈ scope. state_tree(i) ≡ state_tracker(i)` and
`|steps_recorded| = |steps_executed|`.
*Falsify:* an issue closed in the tracker with no recorded merging step, or a
step recorded twice. *Authority:* the durable solution tree, reconciled against
the tracker each cycle (research GAP-5: removes the "reconcile JSON against
GitHub" burden by making the tree the system of record).

**CON-3 Budget conservation.**
`spent + remaining = total` at all times; every billable action debits the
ledger before it is admitted, and no debit is lost.
`Σ_actions cost(a) = total − remaining`.
*Falsify:* a sum of recorded action costs ≠ `total − remaining` (a spend with no
ledger entry, or a ledger entry with no spend). *Authority:* the budget ledger
(single owner; INV-21 reads it).

**CON-4 Cost attribution.**
Every token / unit of cost spent is attributed to exactly one owner (factory
step, agent, gate run).
`∀ spend s. ∃! owner(s)` and `Σ_owners attributed(o) = total_spent`.
*Falsify:* spend recorded with no owner, or whose owners sum ≠ total spent.
*Authority:* the cost tracker (reuse candidate: current `cost/tracker.ex`).

**CON-5 Artifact conservation (no lost work).**
The dirty state of any worker that terminates is conserved: it is either
committed, captured to a durable log, or explicitly discarded by a recorded
decision — never lost by omission.
`dirty(w) = committed(w) ⊎ captured(w) ⊎ discarded_by_decision(w)`.
*Falsify:* a terminated worker whose uncommitted change (esp. an **untracked**
file) is gone with no capture and no discard decision. *Authority:* the worker's
supervisor (couples to INV-14). This is the accounting form of capture-before-
destroy.

**CON-6 Verdict conservation.**
Every gate run produces a recorded verdict for every required gate half; a PR
cannot be in a "merged" state with a missing or stale verdict.
`merged(pr) → ∀ g ∈ required_gates. ∃ verdict(g, diff(pr)) ∧ fresh(verdict)`.
*Falsify:* a merged PR with a gate half whose verdict is absent or was computed
against a superseded diff. *Authority:* the gate-verdict record on the PR
process (couples to INV-1, INV-2).

**CON-7 Escalation conservation.**
Every escalation raised reaches the operator and is recorded with its reason and
the state snapshot; none is raised-and-swallowed.
`∀ e ∈ raised. delivered(e) ∧ recorded(reason(e), state(e))`.
*Falsify:* a halt condition that fired with no operator-visible report and no
record. *Authority:* the solution tree + the operator notification channel.

---

## Why conservation laws are separate from invariants

An invariant (`invariants.md`) says a bad *state* is unreachable. A conservation
law says a *quantity* balances across a transition. The distinction matters for
enforcement: invariants are enforced by guarding transitions; conservation laws
are enforced by **double-entry accounting** — every quantity has a single
writer-of-record and a balance check. The factory's durable store (INV-16) is
where all seven balances are maintained; a reconciliation pass each cycle is the
audit that detects any drift early (cheap) rather than at milestone end (costly).
