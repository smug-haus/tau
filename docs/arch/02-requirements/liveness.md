# Liveness — progress guarantees & the escalation set

Safety (`invariants.md`) says nothing bad happens; liveness says something good
*eventually* happens. For an autonomous factory the central liveness property is
**termination**: every unit of work eventually reaches a terminal state — it
must never spin forever, and "give up and ask a human" is a *valid* terminal
state, not a failure (INV-18 makes the escalation set total).

## Notation

`◇P` — P eventually holds. `↝` — leads-to. Fairness assumed: an admitted work
unit eventually receives scheduler attention (bounded concurrency, no
starvation).

---

## Liveness requirements

**LIV-1 Unit termination.**
`∀ u ∈ accepted. ◇ terminal(u)` where `terminal ∈ {merged, escalated,
rejected}`. Every accepted unit eventually reaches a terminal state. *Falsify:*
a unit that is admitted and, under fair scheduling, never reaches a terminal
state (infinite refine, wedged forever). *Guaranteed by:* INV-19 (bounded
retry) + INV-18 (total escalation) — exhausting the retry ladder is itself a
transition to `escalated`.

**LIV-2 Merge progress (no merge starvation).**
`green(d) ∧ fresh(d) ↝ ◇ merge(d)` — a gate-green, fresh diff eventually merges.
Serialized merges (INV-3) must not starve any particular branch. *Falsify:* a
green+fresh branch that, under a stream of other merges, never merges. *Requires:*
the merge authority serves waiting branches under a fair policy (e.g.
FIFO/aging), and the freshness re-check on each does not livelock (see
discriminating question Q-L1).

**LIV-3 Milestone termination.**
`◇ ( open_issues(milestone) = 0 ∨ escalated(milestone) )` — the assigned
milestone eventually reaches zero open issues or escalates. *Falsify:* a
milestone that neither completes nor escalates under fair scheduling. *Guaranteed
by:* LIV-1 applied to each issue + CON-2 (reconciliation ensures the count is
honest).

**LIV-4 No livelock under contention.**
`□◇ progress` — when multiple units contend (conflict check serializes some),
the system makes progress on *some* unit infinitely often; it does not thrash
between re-planning and admission forever. *Falsify:* a reachable cycle of
admit→conflict→withdraw with no net progress. *Requires:* the scheduler's
serialization decisions are monotone (a serialized unit eventually runs once its
blocker terminates).

**LIV-5 Recovery progress.**
`crash(coordinator) ↝ ◇ resume(from_durable_state)` — after a coordinator crash
or restart, the loop resumes from durable state and continues; it does not stall
awaiting reconstruction. *Falsify:* a restart that hangs or restarts work already
terminal. *Guaranteed by:* INV-16 (durable state, RPO=0) + idempotent resume.

---

## The escalation set E (must be total — INV-18)

Every non-progress state maps to **exactly one** `e ∈ E`. `E` is closed: a state
that matches none raises **E-UNCLASSIFIED** (which is itself an escalation, so
totality holds even for unforeseen states — fail loud, never spin).

| ID | Trigger | Terminal? |
|----|---------|-----------|
| **E-AMBIGUITY** | Irreducible spec/product ambiguity needing human judgement | per-unit |
| **E-RETRY-EXHAUSTED** | N=3 refines + a failed pivot, still red (INV-19) | per-unit |
| **E-CONFLICT** | Unresolvable merge conflict the system cannot mechanically reconcile | per-unit |
| **E-DESTRUCTIVE** | A destructive/irreversible action requested (INV-20) | per-action |
| **E-BUDGET** | Budget (token/cost/time/iteration) exhausted (INV-21) | global |
| **E-RED-MAIN** | Post-merge health check failed; `main` red (INV-4) | global |
| **E-CHALLENGE** | > 2 upheld implementer challenges on one PR (weak oracle/spec) | per-unit |
| **E-UNCLASSIFIED** | Catch-all: a non-progress state matching none of the above | any |

**Totality proof obligation.** The coordinator FSM must be shown to have no
reachable state that is simultaneously (a) not making progress and (b) not
matched by some `e ∈ E`. The catch-all E-UNCLASSIFIED discharges this by
construction, but its firing is itself a defect signal (an unforeseen
non-progress state) and must be logged as such.

**On every escalation:** halt the affected scope (per-unit halts the unit;
global halts the loop), write reason + state snapshot to the durable store
(CON-7), and notify the operator. Halting on a safety condition is *correct*
behaviour, not a fault (research: `factory-loop.md` safety circuit).

---

## Open discriminating questions (liveness)

- **Q-L1 — merge fairness policy.** Under heavy concurrency, is FIFO sufficient,
  or is aging needed to prevent a perpetually-rebased "unlucky" branch from
  starving (each merge advances `origin/main`, forcing it to re-gate)? Cost
  asymmetry: FIFO is simpler but a large branch may starve behind a stream of
  small ones; aging adds complexity. → resolve in system-architecture with the
  merge-authority contract.
- **Q-L2 — re-gate cost vs freshness.** Each serialized merge forces every
  in-flight branch's freshness re-check (INV-2). At high concurrency this can
  dominate cost (re-gate storms). Is there a bound on in-flight concurrency that
  keeps re-gate cost sub-linear? → a quantified NFR (`nfrs.md`, NFR-CONC).
