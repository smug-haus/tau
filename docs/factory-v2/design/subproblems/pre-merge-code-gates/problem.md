---
template_version: 1
template_name: problem
node_kind: leaf
mode: leaf
depth: 1
parent: ../../problem.md
status: draft
---

# Problem: Pre-merge code gates — AST, contract, capability, telemetry

## Statement

A PR's *production code diff* must not be mergeable if it (a) declares a
behaviour / `@behaviour` it does not implement, (b) introduces `try/rescue`
or `catch :exit` against unreachable conditions in violation of OTP
non-negotiable #7, (c) sets a capability flag (e.g. `prompt_caching: true`)
without exporting the required callback (e.g. `cache_regions/2`), or (d)
emits a `:telemetry.execute/3` event under `[:tau, ...]` with no
production consumer registered. v1 tolerates all four: SPEC §4 names
non-existent structs (root #1), seven flagged `rescue` sites moved zero
between audits (root #2/#10), `prompt_caching: true` lies on adapters
without `cache_regions/2` (root #3), and 64.9% of telemetry sites have
no non-debug consumer (root #4). The problem is solved when each is a
deterministic per-PR check whose verdict is independent of agent
self-report.

## Context

- Root §Hypothesis #1, #2, #3, #4 — the four code-shape failure classes.
- Root §Acceptance criterion B — "Mix task that exits non-zero when a
  `prompt_caching: true` adapter does not export `cache_regions/2`" is
  cited as the model mechanism.
- `.claude/rules/otp-non-negotiables.md` #7 — "Let it crash; supervise;
  restart. MUST NOT `try/rescue` across process boundaries. MUST NOT
  catch `:exit`." This is the source-of-truth rule; today no mechanical
  enforcement exists.
- `docs/problems/` and `docs/problems-archive-v1-modules/` contain the
  evidence (struct names, rescue sites, capability liars, telemetry
  sites) but consume zero gate machinery.
- Existing Elixir static-analysis ecosystem: `mix dialyzer`,
  `mix credo --strict`, `mix xref`, `Sourceror` AST library, and
  Dialyzer's `@spec` / behaviour-callback checks. Reuse vs build must
  be evaluated per check.

## Failure classes addressed (from root §Hypothesis)

- **#1** (primary, code-side) — contracts drift between code and the
  symbols they name (struct existence, `@behaviour` implementation
  completeness). The AC-side of contract drift is owned by
  intent-capture-and-ac-binding.
- **#2** (primary) — `try/rescue` / `catch :exit` proliferation against
  unreachable conditions, NN #7 conformance.
- **#3** (primary) — capability-flag fidelity (flag implies callback).
- **#4** (primary) — telemetry events emitted without registered
  production consumer.

## Complecting hypothesis

- The four checks are complected with "the agent's word" because today
  the only enforcement is the critic/reviewer pair reading the diff;
  the checks become independent only when each is a per-commit Mix task
  whose output the gate consumes verbatim.
- "Behaviour-callback completeness" is complected with "capability-flag
  fidelity" in the codebase because adapters declare both via macros and
  module attributes that look stylistic; mechanically the two are one
  AST traversal per adapter module.
- "Telemetry-consumer presence" is complected with `Logger` debug noise
  because v1 treats any `:telemetry.attach` as a consumer; the gate must
  distinguish production handlers from in-test handlers and from
  unused handlers.

## Decomposition strategy

(leaf — no further decomposition; proceed to proposals)

## Acceptance criterion

The factory specification names exactly one mechanism per failure class
above (#1 code-side, #2, #3, #4) such that: (a) each mechanism is a
deterministic Mix task (or equivalent scripted check) that exits non-zero
on violation and is wired into `.github/workflows/ci.yml` as a required
status check on `main`; (b) the mechanisms enumerate their inputs (e.g.
"every file under `lib/tau/providers/`", "every module exporting
`__using__/1` from a behaviour") so that an empty input set is
distinguishable from "no findings" — silent skip on a missing target
list fails the PR (per root §Acceptance C); (c) the spec records, per
check, whether an existing tool (`mix dialyzer`'s `@behaviour` callback
warnings, `mix credo` custom checks, `Sourceror`-based traversal,
`muzak` mutation, OpenTelemetry SDK's registered-handler introspection)
is adopted or wrapped vs built bespoke, with the rationale recorded per
root §Acceptance D; (d) the spec output identifies the concrete
artifacts: mix task module names (e.g. `Mix.Tasks.Tau.Gate.Contracts`,
`Mix.Tasks.Tau.Gate.NoRescue`, `Mix.Tasks.Tau.Gate.CapabilityFidelity`,
`Mix.Tasks.Tau.Gate.TelemetryConsumers`), the CI workflow steps that
invoke them, any Sourceror or Credo plugin module names, and a
plugin-shaped wrapper if multiple Tau projects will consume them.

## Out of scope

- AC-test linkage and per-AC mutation — owned by
  **intent-capture-and-ac-binding** sibling (the AC binding determines
  *which* tests are gating; this leaf's checks run on the production
  diff regardless of AC).
- The CI infrastructure layer (silent-skip impossibility, evidence
  trust, "merge despite red CI") — owned by
  **pre-merge-evidence-and-skip-integrity** sibling.
- SPEC-vs-SPEC contradictions and other cross-document drift on main —
  owned by **post-merge-cross-artifact-coherence** sibling.
- Ingestion of historical audit findings as new check inputs — owned by
  **knowledge-memory-and-audit-ingestion** sibling.
- Worktree hygiene / dashboards — owned by
  **operability-and-hygiene-enforcement** sibling.
- Documentation-only components; agent-discipline-only enforcement;
  workstream-2 corrective-actions catalogue.

## Amendment log

- (none yet)
