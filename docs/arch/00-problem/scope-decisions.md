# Scope decisions (discriminating questions)

These four decisions were underdetermined by the brief and each materially
shapes the architecture. Answered by the requester on 2026-06-09. Each is
recorded with its consequence and the cost asymmetry of having guessed wrong.

## D-S1 — Autonomy boundary: **Escalation-only (fully autonomous)**

The factory runs intent → plan → execute → gate → merge with **no human in the
per-step loop**. A human is consulted only when the system *itself* reaches a
named, deterministic escalation boundary:

- irreducible spec/product ambiguity,
- N gate-refine attempts exhausted without a green pivot,
- a destructive/irreversible action the gate cannot competently assess,
- resource budget exhausted,
- post-merge `main` health check fails (red main),
- (others surface during requirements; the set must be **closed and total**).

**Consequence.** "No human in the loop" makes the *safety invariants* the load-
bearing wall: with no human backstop, every "must never happen" must be enforced
structurally (by process boundaries, gates, supervisors) not by prose. The
escalation set must be **total** — every non-progress state maps to exactly one
escalation reason or the system livelocks silently.

**Cost asymmetry.** Guessing "human approves merge" when the user wanted full
autonomy ⇒ the whole control-plane design is over-built with checkpoints that
must later be ripped out. Guessing full autonomy when they wanted checkpoints ⇒
add a gate, cheap. We chose the answer; the asymmetry favored asking.

## D-S2 — Build target: **Polyglot (any repo, any language)**

The factory must build arbitrary software, not only Elixir/BEAM projects.

**Consequence — first-class boundary.** The **toolchain** (how to install deps,
build, test, lint, run mutation analysis, produce a release) becomes a
**pluggable behaviour** with per-language adapters, NOT hardcoded `mix`. This is
a major boundary the Elixir-only reading would have omitted. The factory's
*control plane* is BEAM/OTP; the *target build environment* is language-agnostic
and runs in isolated workspaces (process + filesystem +, where needed,
container/sandbox isolation). Test-oracle separation, gating, and mutation
checks must be expressed against the toolchain behaviour, not a specific runner.

Note: this diverges from the current repo's self-hosting-first memory.
**Self-hosting (tau builds tau, an Elixir project) is retained as the bootstrap
/ proving case** — the first toolchain adapter and the dogfood loop — but the
*architecture's target set* is polyglot. See migration note (D-S3).

**Cost asymmetry.** Designing Elixir-only and discovering polyglot later ⇒
the toolchain assumption is threaded through gating, isolation, and CI; costly
retrofit. Designing the toolchain seam now ⇒ one behaviour + adapters; cheap.

## D-S3 — Basis: **Greenfield + migration note**

Design the ideal clean-slate architecture from the requirements. The current
repo is **inspiration and failure-mode evidence only** (mined in
`01-research/tau-current-analysis.md`); it does not constrain boundaries. A
closing migration appendix will map today's subsystems (session, provider,
coding_agent, circuit_breaker, memory, cost, telemetry, the factory-loop/
worktree-discipline rules) onto the new component boundaries as reusable seams.

**Consequence.** Requirements are derived from the problem, not reverse-
engineered from existing modules. The prose rules in `.claude/rules/` are
treated as *evidence of required invariants* to be re-enforced structurally,
not as the design.

## D-S4 — Scale: **Single-node, distribution-ready**

v1 targets one BEAM node running many processes (10³–10⁵). Boundaries are drawn
to be **location-transparent** — addressing via `Registry`/`Phoenix.PubSub`,
no assumption of shared-memory ETS across the coordination boundary that
distribution would break — so a later multi-node move is configuration and
supervisor placement, not a rearchitecture.

**Consequence.** A standing constraint on every component: *would this still be
correct if the process lived on another node?* Components that must share memory
(read-mostly catalogs, budget counters) are explicitly marked node-local and
justified; cross-component coordination uses messages/PubSub, never `:global`,
never raw `:ets` reached across the boundary.

**Cost asymmetry.** Designing single-node-only and needing a cluster later ⇒
rework addressing and state-sharing throughout. Paying the location-transparency
discipline now ⇒ near-zero extra cost on the BEAM, which already favors it.

## Summary table

| ID | Decision | Primary architectural consequence |
|----|----------|-----------------------------------|
| D-S1 | Escalation-only autonomy | Safety invariants enforced structurally; escalation set must be total |
| D-S2 | Polyglot target | Toolchain = pluggable behaviour + per-language adapters; sandboxed workspaces |
| D-S3 | Greenfield + migration note | Requirements from problem; current repo = evidence + migration seams |
| D-S4 | Single-node, dist-ready | Location-transparent boundaries; no `:global`, no cross-node ETS reliance |
