# Problem statement

## A / O / B restatement

> **Actor A** (an operator / product owner) **cannot achieve outcome O**
> (working, verified software delivered from high-level intent to merged code)
> **because of obstacle B** (delivery currently requires a human to perform and
> supervise every coordination step — decomposing intent into work, spawning
> and isolating agents, gating quality, integrating changes, and recovering
> from partial failure — and no autonomous control plane exists that can do
> this while preserving correctness invariants under concurrency and bounded
> resource use).

## Interpretation readings

Three readings of "autonomous agentic coding factory"; they imply different
architectures.

**R-i — Pipeline / job-queue reading.** The factory is a worker pool consuming
tasks: issue → agent → CI → merge. Under this reading the hard part is
throughput and the design is a queue + CI. *Rejected as primary:* it models
agents as stateless workers and ignores that the shared artifact (a git repo +
running BEAM) is **mutable state under concurrent writers**, that quality gates
are **decisions under uncertainty**, and that failure is **partial and
mid-transaction**, not a clean retry.

**R-ii — Distributed control-system reading (PRIMARY).** The factory is a
control plane that drives many concurrent, fallible agents against shared
mutable state (repository, build, running system), with feedback loops
(gate → refine/pivot), conservation constraints (no committed work or spent
budget silently lost), and autonomous decision-making (select work, judge
gates, escalate). The hard parts are: enforcing safety invariants under
concurrency, bounding resource use, and surviving partial failure without human
intervention. This is where the BEAM earns its place — supervision, isolation,
backpressure, let-it-crash.

**R-iii — Learning-system reading (SECONDARY).** The factory accumulates
knowledge (heuristics, failure taxonomies, solution trees) and improves over
time. Real, but an overlay on R-ii rather than the primary axis; treated as a
memory/feedback subsystem.

**Decision:** solve **R-ii**, with R-iii as a subordinate concern. R-i's
throughput goals survive only as quantified NFRs, never as the organizing
boundary.

## Whose problem

The requester is the *operator/owner* of the factory, not an agent inside it.
The factory is the **system under design**; the autonomous coordinator is its
control plane; the human appears only at escalation boundaries. Requirements
are written from the operator's vantage: what must the factory guarantee such
that the operator can leave it running.

## What "fully autonomous" must mean (to be falsifiable)

Autonomy is not "no human ever" — it is "**no human in the per-step loop**; the
human is consulted only at well-defined escalation boundaries that the system
itself names and reaches deterministically." The exact boundary is a
discriminating decision recorded in `scope-decisions.md`.

## Decomposition axes (sub-problem map)

The problem space is decomposed along these axes; each becomes a requirement
cluster and one or more candidate components:

1. **Intake & specification** — intent → falsifiable acceptance criteria.
2. **Planning & decomposition** — work → ordered, dependency-aware units.
3. **Execution & isolation** — spawning/supervising fallible agents on isolated
   workspaces.
4. **Verification & gating** — tests, critics, reviewers, mechanical gates.
5. **Integration & delivery** — merge, branch hygiene, release, freshness.
6. **State, memory & knowledge** — solution tree, durable memory, feedback.
7. **Resource governance** — token/cost/rate/concurrency budgets, model choice.
8. **Fault tolerance & recovery** — crash, capture-before-destroy, restart.
9. **Observability & control** — telemetry, kill switch, escalation, reporting.
10. **Safety & invariants** — the cross-cutting "must never happen" set.

These axes are the seed for `02-requirements/`. The current repo's
`factory-loop.md`, `worktree-discipline.md`, and `otp-non-negotiables.md`
encode hard-won constraints for several of these axes and are mined in
`01-research/tau-current-analysis.md`.
