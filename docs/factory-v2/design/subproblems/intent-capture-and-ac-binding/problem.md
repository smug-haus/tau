---
template_version: 1
template_name: problem
node_kind: leaf
mode: leaf
depth: 1
parent: ../../problem.md
status: draft
---

# Problem: Intent capture and AC-to-user-path binding

## Statement

A user intent (issue, audit finding, directive) must enter the factory as a
PR-shaped unit whose acceptance criteria (`AC-N`) are bound, by mechanism,
to tests that exercise the *same user-visible code path the AC names*. The
v1 failure is that a PR may declare it advances `AC-N` while the tests
covering `AC-N` invoke a hand-built struct or a private helper, leaving
the user-facing entry point unexercised — the AC remains formally green
while substantively false (root §Hypothesis #6; AC-B6 falsification probe).
The problem is solved when the AC declaration is the test plan, not a prose
claim adjacent to one.

## Context

- Root problem.md §Hypothesis #6 (AC-B6 falsification): deleting the
  `Tau.Session.set_permissions_mode/2` call still left AC-B6 tests green.
- Root §Acceptance criterion A: every failure class must have a mechanism;
  this leaf owns failure class #6 in full.
- Root §Hypothesis #1 (partial): the AC declaration is where contracts
  *enter* the factory; structural drift between AC and code is detected
  here at the binding layer, before AST-level checks (which live in the
  pre-merge code gates sibling).
- v1 factory-loop rule (`.claude/rules/factory-loop.md`) §"The three
  mechanical gates" — Gate 5.1 (AC linkage) and Gate 5.3 (mutation check)
  exist but key on declared paths and a single mutation-revert, which a
  test exercising the wrong path silently passes.

## Failure classes addressed (from root §Hypothesis)

- **#6** (primary) — AC tests must invoke the user-facing path the AC
  names; an under-asserting or wrong-path test fails this leaf's gate.
- **#1** (partial, AC-side) — the AC text and the user-path entry point
  cited in the AC must reference symbols that exist in the codebase at
  the time of the PR; AC text that names a struct/function that does not
  exist fails this leaf's gate. (Module-internal contract drift remains
  with the pre-merge-code-gates sibling.)

## Complecting hypothesis

- The PR-body AC declaration is complected with the test-author's choice
  of entry point because the only link between them today is prose; a
  machine cannot detect "the test invokes the wrong layer" without an
  explicit, structured AC→user-path→test binding.
- The "mutation check" (revert non-test paths to merge-base, expect ≥1
  test fail) is complected with "does the suite exercise the user path"
  because a single global revert cannot distinguish a test that fails for
  the *right* reason from one that fails because compilation broke.

## Decomposition strategy

(leaf — no further decomposition; proceed to proposals)

## Acceptance criterion

The factory specification names a single, deterministic mechanism such
that: (a) every `AC-N` / `D-NNN` token in the PR body's `## Acceptance
criteria` section is paired with (i) a machine-resolvable user-facing
entry-point reference (module + function + arity, or CLI argv pattern)
and (ii) the gating-test file path(s) that invoke that entry point; (b)
the mechanism executes a per-AC mutation — disabling the *specific
user-path call site* the AC names — and the gating test(s) for that AC
MUST go red, else the gate fails the PR; (c) the gate cannot silent-skip
(an AC with no resolvable entry point, or an entry point with no
gating-test that goes red on per-AC mutation, fails the PR — it does not
pass-with-a-warning); (d) the design explicitly addresses whether an
existing Claude Code plugin / mix dependency (e.g. `muzak` mutation
testing, `excoveralls` coverage with per-AC tagging) is adopted vs a
bespoke build, with the reuse-vs-build decision recorded; (e) the
spec output identifies the concrete artifacts to build (e.g. a
`tau.gate.ac_binding` mix task, a CI workflow step in
`.github/workflows/ci.yml`, a PR-body schema, an optional plugin
`polya-audit`-style agent producing the binding manifest, and any
settings.json entries needed).

## Out of scope

- AST-level checks on production code (`try/rescue`, missing
  `@behaviour`, capability-flag fidelity, telemetry-consumer presence)
  — owned by **pre-merge-code-gates** sibling.
- Gate-infrastructure invariants (silent-skip impossibility, evidence
  source must be CI-not-local) — owned by
  **pre-merge-evidence-and-skip-integrity** sibling.
- Cross-document SPEC-vs-SPEC contradictions — owned by
  **post-merge-cross-artifact-coherence** sibling.
- Reading historical audit findings into the AC-binding schema — owned
  by **knowledge-memory-and-audit-ingestion** sibling (this leaf only
  enforces the binding contract; *what* invariants the binding must
  enforce per-surface is informed by audit ingestion).
- Worktree hygiene, dashboards, parent-on-main — owned by
  **operability-and-hygiene-enforcement** sibling.
- Documentation-only components; agent-discipline-only enforcement;
  workstream-2 corrective-actions catalogue.

## Amendment log

- (none yet)
