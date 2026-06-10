---
template_version: 1
template_name: problem
node_id: factory-v2-root
parent: null
depth: 0
mode: non-leaf
status: decomposed
---

# Root problem — design a software factory that survives v1's collapse modes

## Hypothesis to operationalise

The trustworthiness audit (`docs/problems/`) established that the v1
factory loop tolerated — and accumulated — the following classes of
failure, eventually collapsing entirely in the four most recent merges
(#411-#414, all bypassing the gate with red CI):

1. Contracts drift from code (SPEC §4 names structs that don't exist;
   `@doc` claims adapters implement callbacks they don't).
2. `try/rescue` and `catch :exit` proliferate against unreachable
   conditions, violating OTP non-negotiable #7; the rule is not
   mechanically enforced.
3. Capability flags lie (`prompt_caching: true` on adapters without
   `cache_regions/2`).
4. Telemetry events emit without production consumers (64.9% of 121
   `:telemetry.execute` sites have zero non-debug consumer).
5. CI gates silent-skip when the PR omits a declaration field, and one
   of three gates is `|| true`.
6. PRs declare `AC-N` advances whose tests never invoke the user path
   that the AC names (AC-B6 falsification probe: deleting the
   `Tau.Session.set_permissions_mode/2` call leaves AC-B6 tests green).
7. The factory merges PRs against red CI; PR-body fields cite
   local-machine `mix` output as evidence.
8. Worktree branches leak (63-571 orphans depending on the grep);
   `parent-on-main` invariant ignored.
9. SPEC self-contradiction persists (SPEC-PERMISSION-PROMPTS §4 B5
   says 6 modes, §6 D-171 says 3) because no SPEC-vs-SPEC consistency
   check runs.
10. The prior module audit's recommendations have not been ingested —
    zero of seven flagged `rescue` sites moved; new `rescue` sites
    accumulated since the audit was written.

## What the v2 factory must do

Build a software factory for Tau such that **the failure classes above
are structurally impossible, or surface as merge-blocking gates that
cannot be silent-skipped**.

The factory's components run as Claude Code plugins, agents, skills,
hooks, and CI gates. The factory's authority over a PR rests on
machine-checkable evidence (CI output, file diffs, AST checks,
Dialyzer warnings, behaviour-callback presence, telemetry-consumer
registration), not on agent self-report or PR-body assertion.

## Acceptance criteria

- **A — Failure-class coverage.** For each of the ten failure classes
  above, the v2 factory specification names exactly one mechanism that
  detects or prevents that class. Mechanisms may overlap (one gate
  may cover multiple classes); but no class may be uncovered, and no
  class may be covered only by "agent discipline" or "human review."

- **B — Mechanical enforceability.** Every gate the spec names MUST be
  expressible as a deterministic, scriptable check. "Critic reviews
  the diff" is not a mechanism. "Mix task that exits non-zero when a
  `prompt_caching: true` adapter does not export `cache_regions/2`"
  is a mechanism. The critic and reviewer agents continue to exist
  as quality checks but may not be load-bearing for any class above.

- **C — Silent-skip impossibility.** No gate may silent-skip. A gate
  that has nothing to check on a particular PR returns "checked, no
  applicable findings" — not "skipped." A gate that cannot run for
  infrastructural reasons fails the PR rather than passing it. The
  v1 CI early-exits at `ci.yml:88-100` and `:213-223` and the
  `|| true` at `:115` are the anti-patterns to make impossible.

- **D — Ecosystem reuse over reinvention.** Where a well-regarded
  open-source plugin / skill / agent exists in the Claude Code
  ecosystem that addresses a failure class, the v2 factory adopts it
  rather than building a bespoke equivalent. Bespoke components are
  justified explicitly per component.

- **E — Operability.** The factory's state — what gates are wired,
  what gates have run on what PRs, what gates passed / failed, what
  orphan worktrees exist, what stale-`main` collisions are pending
  — is observable from a single dashboard or query, not reconstructed
  by reading git logs.

- **F — Backward integration.** The factory ingests the audit
  findings (`docs/problems/` + `docs/problems-archive-v1-modules/`)
  as input, not as advice. The corrective-actions catalogue
  (`docs/factory-v2/corrective-actions.md`) is the factory's initial
  backlog, processed by the same mechanisms it gates new work with.

- **G — No prose-only commitments.** The spec MUST NOT include
  components whose only output is documentation. Every component
  produces a machine-checkable artifact (a gate verdict, a diff, a
  telemetry stream, a registry entry).

## Decomposition guidance

The next step MUST produce MECE sub-problems that are **dimensions of
factory capability**, not modules and not individual components.

Suggested starting points (the decomposer challenges and refines):

1. **Intent capture & decomposition** — how does a user intent (an
   issue, a directive, an audit finding) become a PR-shaped unit of
   work? What guards the decomposition against over-scoping,
   under-scoping, scope creep, or "follow-up issue" deferrals that
   defeat the AC?
2. **Pre-merge gating** — what mechanically stops a bad PR from
   merging? Specifically: AC-test linkage, mutation check, masking
   check, contract drift, capability-flag fidelity, NN #7 conformance,
   telemetry-consumer presence, behaviour-callback completeness, SPEC
   consistency, gate silent-skip detection.
3. **Post-merge enforcement** — what runs on `main` and catches what
   slipped through? Cross-PR coherence checks, codebase-level
   trustworthiness re-audits on cadence, drift telemetry.
4. **Knowledge / memory** — how does the factory persist and consult
   prior audits, ADRs, SPECs, decision history, failure post-mortems?
   How does authoring an audit finding *guarantee* the factory will
   consider it on the next PR that touches the relevant surface?
5. **Operability & observability** — what dashboard / query surface
   shows factory state, gate health, orphan branches, stale `main`,
   in-flight PRs, failed gate counts per dimension, prior-audit
   compliance percentage?
6. **Recovery & escalation** — what happens when discipline IS
   slipping? When are the gates themselves wrong (false-positive
   blocking)? When does the factory halt and escalate to the user
   rather than retry?

The decomposer MAY add, split, merge, or reframe these — the
constraint is MECE-across-failure-classes, dimensions-of-capability
(not implementation choices), each leaf addressing at least one
failure class from the list at the top.

## Sub-problems (filled by decomposer)

Decomposition axis: **dimensions of factory capability**, partitioned
by lifecycle phase (intent → pre-merge → post-merge) and persistent
concern (knowledge ingestion, operability). Each leaf addresses ≥1
failure class from §Hypothesis; together they cover all ten.

1. **intent-capture-and-ac-binding** (`subproblems/intent-capture-and-ac-binding/`)
   — how an issue/intent becomes a PR with AC declarations bound, by
   mechanism, to tests that exercise the user-facing path the AC names.
   Failure classes: #6 (primary), #1 (AC-side).
2. **pre-merge-code-gates** (`subproblems/pre-merge-code-gates/`) —
   per-PR AST / contract / capability-flag / telemetry-consumer checks
   that fail-loud on the production diff. Failure classes: #1 (code-
   side), #2, #3, #4.
3. **pre-merge-evidence-and-skip-integrity** (`subproblems/pre-merge-evidence-and-skip-integrity/`)
   — the gate-execution substrate: no silent-skip, no local-mix
   evidence, no merging against red CI. Failure classes: #5, #7.
4. **post-merge-cross-artifact-coherence** (`subproblems/post-merge-cross-artifact-coherence/`)
   — `main`-side checks for SPEC↔SPEC contradictions, SPEC↔code
   drift, ADR supersession, D-NNN uniqueness; runs on every push to
   `main` and on cadence. Failure classes: #9 (primary), #1 / #4
   (cumulative tails).
5. **knowledge-memory-and-audit-ingestion** (`subproblems/knowledge-memory-and-audit-ingestion/`)
   — structured audit findings whose authoring mechanically registers
   them as inputs to the pre-merge code gates; remediated or expiring-
   waivered only. Failure class: #10 (primary).
6. **operability-and-hygiene-enforcement** (`subproblems/operability-and-hygiene-enforcement/`)
   — single-query factory-state dashboard plus hook-enforced worktree
   discipline and `parent-on-main` invariants. Failure class: #8
   (primary); plus operability surface for all classes.

MECE check (per `decompose.md`):
- **No overlap.** AC-binding owns AC↔test linkage; pre-merge code
  gates own production-diff AST/contract checks (regardless of AC);
  evidence-and-skip-integrity owns *whether* gates run and what
  evidence counts; post-merge coherence owns cross-artifact drift on
  `main`; audit ingestion owns the registry that feeds inputs to
  pre-merge code gates; operability owns state observability and
  worktree hygiene. Each concern lives in exactly one leaf.
- **No gap.** Every failure class #1–#10 is named in at least one
  leaf's "Failure classes addressed" section.
- **Same altitude.** Each leaf is a *dimension of factory capability*,
  not an implementation component (no leaf could be a sub-problem of
  another).

## Out of scope

- Fix recommendations for Tau itself — workstream 2 catalogues those.
- Re-litigating whether the audit's findings are correct — they are
  the input.
- "We could also do X" framings without mapping X to a failure class.

## Background — why first-principles, why now

The user expressed (a) that the codebase has rotted to where
recommendations from Claude cannot be trusted; (b) that the
process Claude was given (Polya / Toulmin with falsification) was
not followed in earnest in v1; (c) that ANY further drift means
the project is abandoned. The v2 factory must therefore not rely on
Claude (or any single agent) telling the truth about its own work
— it must rely on independent mechanisms that produce verdicts
Claude cannot influence. Where Claude is in the loop, Claude's claims
must be cross-checked by mechanism, not by another Claude.
