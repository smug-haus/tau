---
template_version: 1
template_name: problem
node_kind: leaf
depth: 1
parent: ../../problem.md
status: draft
---

# Problem: hard-coded global process names embed single-instance-per-node assumption

## Statement

`Tau.Application` registers `Tau.PubSub`, `Tau.Providers.Finch`,
`Tau.CircuitBreaker.Store` (via `__MODULE__`), `Tau.Sessions.Supervisor`,
`Tau.Registries`, and every `Registry` child under invariant atom names; a
second Tau OTP application started in the same BEAM node (test fixture host
running alongside an escript under test, a future hyperagent worker, or an
embedded-mode caller) collides at startup and the second instance fails to
start. The failure mode is silent — the first `start_link` wins, the second
returns `{:error, {:already_started, pid}}`, and callers silently share the
first instance's state.

## Context

- `lib/tau/application.ex:68` — `{Phoenix.PubSub, name: Tau.PubSub}`;
  flat audit: major, OTP-NN §4. "Two simultaneous Tau instances in one
  BEAM … collide at startup."
- `lib/tau/application.ex:78` — `{Finch, name: Tau.Providers.Finch}`.
- `lib/tau/circuit_breaker/store.ex:65` — `GenServer.start_link(__MODULE__,
  opts, name: __MODULE__)` — hard-coded to `Tau.CircuitBreaker.Store`.
- `lib/tau/cost/tracker.ex:73` — same pattern; hard-coded to `__MODULE__`.
- `lib/tau/registries.ex:56-63` — all seven `Registry` children use literal
  module atoms as names.
- `lib/tau/application.ex:93` — supervisor itself registered as `Tau.Supervisor`.
- The `:tau_circuit_breakers` and `:tau_cost_counters` ETS table names are
  hard-coded atoms in `Store` and `Tracker`; two concurrent instances share
  the same table.
- Flat audit: major finding on `application.ex:68`; pattern noted across
  every named child.
- `.claude/rules/otp-non-negotiables.md` §4: "Never `:global`" — `:global`
  is avoided here, but the pattern's fragility is the same class of concern.

## Complecting hypothesis

1. **Deployment topology is complected with process identity**: every
   subsystem that calls `Tau.PubSub`, `Tau.Providers.Finch`, or `Registry`
   by module atom embeds the assumption that exactly one instance of that
   subsystem exists in the node, preventing test isolation and multi-tenant
   embedding without restructuring call sites.
2. **ETS table ownership is complected with the module namespace**: the
   table names `:tau_circuit_breakers` and `:tau_cost_counters` are atoms
   derived from a convention rather than from the owning process's registered
   name, so they cannot be parameterised independently.

## Decomposition strategy

(leaf — no further decomposition; proceed to proposals)

## Acceptance criterion

A proposal names: (a) which global names are practical to parameterise
now (i.e. which subsystems have a natural `name:` opt path already exposed
by their `start_link/1`) vs which require broader caller-site changes; (b)
the minimum change that eliminates the test-fixture collision (the highest-
priority scenario) without requiring every call site to pass a name; and
(c) whether the ETS table names should follow the owning process's
registered name or be derived independently, with the D-044 schema-version
impact assessed for the circuit-breaker table.

## Out of scope

- Supervision tree startup ordering or CLI task — exclusive scope of
  **supervision-tree-startup**.
- Telemetry handler crash-safety — exclusive scope of
  **telemetry-handler-coupling**.
- Circuit-breaker counter-protocol leakage — exclusive scope of
  **circuit-breaker-invariant-split**.
- `lib/tau/factory/gate.ex` placement (CI tool under `lib/tau/`).
- `lib/tau/memory/embedding_worker.ex:106` Finch name mismatch — covered by
  the tau-memory audit module.

## Amendment log

- (none yet)
