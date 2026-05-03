# Spec-Before-Code Rule

Coordination-heavy components (PSDH triage score >= 2) MUST have a written
specification under `docs/spec/SPEC-*.md` before any implementation PR is opened
that modifies their behaviour.

## What counts as coordination-heavy

A component is coordination-heavy when it scores >= 2 on the PSDH triage
checklist (`.claude/skills/design-reasoning`). Concretely: shared mutable state,
temporal coupling, cross-process coordination, feedback loops, or state
accumulation. Single-process pure functions and CRUD endpoints do NOT need a
spec.

The current spec catalog:

- `docs/spec/SPEC-USER-TURN.md` — the binary launch → TUI → session FSM →
  provider stream → render loop. Mandatory for any PR touching `lib/tau/cli.ex`,
  `lib/tau/tui/`, `lib/tau/session.ex`, `lib/tau/application.ex`,
  `lib/tau/providers/*` (in their `stream/3` callback), or
  `lib/tau/settings/cache.ex`.

Future SPECs land here as new components reach triage threshold.

## What this rule requires

A PR is in scope of a SPEC if it touches any file the SPEC's source-map (Appendix B
in each spec) names, OR it changes a boundary contract (§4 in each spec), OR it
introduces new state at any boundary the spec lists.

For an in-scope PR, the description MUST state:

1. **Which acceptance criterion (AC-N) the PR advances**, or which D-xxx
   invariant it enforces, or both.
2. **Whether any new constraint surfaced** during implementation that should
   be added to §3 of the SPEC. Adding a constraint is a spec amendment, not a
   silent slip; the amendment lives in the same PR.

Out-of-scope PRs (typo fixes, dependency bumps, formatting) need not reference
the SPEC.

## What this rule forbids

- MUST NOT merge a PR that adds new state to a SPEC'd boundary without a
  corresponding §3 entry and §4 contract update in the same PR.
- MUST NOT implement an acceptance criterion without a property test or unit
  test that fails before the change and passes after. The "binary smoke" tests
  named in AC-5 (e.g. `test/tau/cli/binary_smoke_test.exs`) are a CI-level
  blocking gate; do not bypass.
- MUST NOT close an issue that is referenced as "closes a constraint" without
  the corresponding D-xxx invariant landing as enforcement.

## Critic / reviewer gate amendment

Both gates' review prompts are extended to ask:

- **Critic (pre-impl):** "Does the planned change touch any file in
  `docs/spec/SPEC-*.md` Appendix B? If yes, which AC-N or D-xxx does it
  advance? Does the plan amend the spec where new constraints surfaced?"
- **Reviewer (post-impl):** "Does the PR description name the AC-N / D-xxx?
  Are spec amendments (if any) in this PR or absent? Does the new test cover
  the listed criterion?"

A PR that fails either question receives a FAIL verdict regardless of code
quality.

## When to update this rule

When a new SPEC enters the catalog, list it under "the current spec catalog"
above. When a SPEC is retired (component dropped, refactored away), remove it
and amend the source-map references in any consuming PRs.

## Why this exists

Three days of activity (May 1-3 2026) produced 110 commits and a non-functional
TUI. The diagnosis on file (memory: `project_state_2026_05_03_evening.md`)
attributes this to an absence of plan-of-record and a review gate tuned for
local OTP correctness rather than product behaviour. This rule converts the
PSDH method into an enforced gate, applied to the components where the method
yields the most.
