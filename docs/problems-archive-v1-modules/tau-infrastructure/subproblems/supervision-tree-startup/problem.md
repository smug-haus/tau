---
template_version: 1
template_name: problem
node_kind: leaf
depth: 1
parent: ../../problem.md
status: draft
---

# Problem: supervision tree startup lifecycle defects

## Statement

`Tau.Application.maybe_dispatch_cli/0` spawns the CLI entry-point inside an
unmonitored `Task.start/1`; a failure inside `Tau.CLI.main/1` produces an
unobserved crash and `System.halt/1` is never called, leaving the binary
hung. Additionally, `otel_reporter_spec/0` reads `Application.get_env` at
startup and conditionally splices children, duplicating the enable/disable
policy already expressed in `Tau.OtelReporter.init/1`'s `:ignore` path —
two independent code sites must agree on what "OTel disabled" means, and
the default `max_restarts: 3 / max_seconds: 5` for a binary expected to
recover from transient SQLite or Finch init failures is tight.

## Context

- `lib/tau/application.ex:185-199` — `Task.start/1` spawns the CLI; no
  monitor, no link, no `Task.Supervisor.start_child`. If `Tau.CLI.main/1`
  raises, the exit is unobserved and `System.halt/1` never fires.
- `lib/tau/application.ex:113-119` — `otel_reporter_spec/0` reads
  `Application.get_env(:tau, :otel)` and returns `[]` when disabled.
  `Tau.OtelReporter.init/1` also returns `:ignore` when disabled.
  Both guard the same gate; a future change to either creates a split-brain.
- `lib/tau/application.ex:93` — `opts = [strategy: :rest_for_one, name:
  Tau.Supervisor]` with no `max_restarts:` / `max_seconds:` override;
  three restarts in five seconds halts the binary on transient failure at
  init (e.g., SQLite locked briefly on cold start).
- Flat audit: major finding `application.ex:185-199`; minor finding on
  `otel_reporter_spec/0` dual-policy.

## Complecting hypothesis

1. **CLI exit policy is complected with the OTP task primitive choice**:
   `Task.start/1` is chosen for its fire-and-forget semantics, but the
   caller needs crash-visibility to guarantee `System.halt/1` fires — these
   two requirements are incompatible with the same primitive.
2. **OTel enable/disable policy is complected across two independent code
   sites**: the supervisor child-list and the GenServer `init/1` both
   represent "is OTel enabled?", and they must be kept in sync manually.

## Decomposition strategy

(leaf — no further decomposition; proceed to proposals)

## Acceptance criterion

A proposal names: (a) the replacement primitive for the CLI task that
guarantees `System.halt/1` fires on both normal and crash exits; (b) a
single authoritative OTel-enabled gate with the other site removed or made
unconditionally passthrough; (c) explicit `max_restarts` / `max_seconds`
values justified against the binary's recovery expectations — without
regressing supervision tree startup ordering.

## Out of scope

- Global process name collision risk — exclusive scope of
  **global-name-collision**.
- Telemetry handler crash-safety and supervisor strategy — exclusive scope of
  **telemetry-handler-coupling**.
- Circuit-breaker counter protocol — exclusive scope of
  **circuit-breaker-invariant-split**.
- Any change to `Tau.CLI.main/1` internals or `lib/tau/factory/gate.ex`.

## Amendment log

- (none yet)
