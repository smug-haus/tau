---
template_version: 1
template_name: problem
node_kind: leaf
depth: 1
parent: ../../problem.md
status: draft
---

# Problem: telemetry handler crash-safety and supervisor strategy mismatch

## Statement

`Tau.Cost.Tracker.handle_event/4` (the `[:tau, :provider, :request, :stop]`
handler) has no rescue guard, contrary to D-035 and contrary to the
coding-agent twin `handle_coding_agent_cost/4` in the same module; a
malformed `:usage` measurement from any provider crashes the calling FSM
process. Independently, `Tau.Telemetry.Supervisor` uses `:one_for_one`
strategy, so a `Tau.Telemetry.Handlers` crash restarts only `Handlers`
without restarting `Tau.Cost.Tracker` — on `Handlers` restart the event
list is re-attached, but `Cost.Tracker`'s own handlers remain attached from
its prior `init/1`, creating a window for duplicate handler attachment.

## Context

- `lib/tau/cost/tracker.ex:118-138` — `handle_event/4` uses a `with` chain
  that falls through to `else _ -> :ok` for structural mismatches, but has
  no `rescue` around the `:ets.update_counter/3` call at line 129; a
  provider emitting a non-integer in `:usage` that passes the `is_map`
  guard causes an `ArgumentError` in the emitter's process. Flat audit:
  Critical, classified as OTP-NN §7 violation.
- `lib/tau/cost/tracker.ex:140-158` — `handle_coding_agent_cost/4` documents
  D-035 explicitly: "cost-folding errors MUST degrade gracefully"; the
  provider handler does not.
- `lib/tau/telemetry/supervisor.ex:16-23` — `strategy: :one_for_one`;
  `Tau.Telemetry.Handlers` and `Tau.Cost.Tracker` are siblings. A crash in
  `Handlers` restarts only `Handlers`. `Handlers.init/1` calls
  `:telemetry.attach_many/4`; `Cost.Tracker.init/1` also calls
  `:telemetry.attach/4` — independently. After a `Handlers`-only restart,
  the `Handlers` event list is re-registered while `Cost.Tracker`'s
  handlers (still alive) remain registered. Flat audit: minor, suggests
  `:rest_for_one` so a `Handlers` crash cascades to `Cost.Tracker` forcing
  re-`init/1`.
- SPEC-CIRCUIT-BREAKER not directly in scope; OTP-NN §7.

## Complecting hypothesis

1. **Handler crash-safety is complected with the event's structural
   completeness**: `handle_event/4` trusts that any measurement passing the
   `is_map` guard has integer-valued token fields, embedding a provider-side
   correctness assumption into the crash boundary.
2. **Handler attachment lifecycle is complected with supervisor restart
   scope**: which handlers are alive after a partial subtree restart is
   determined by the supervisor strategy, not by any explicit
   attach/detach pairing on the handlers themselves.

## Decomposition strategy

(leaf — no further decomposition; proceed to proposals)

## Acceptance criterion

A proposal names: (a) the rescue boundary to add to
`Cost.Tracker.handle_event/4` that makes it D-035-compliant and symmetric
with its coding-agent twin, including what telemetry event to emit on
failure; (b) the supervisor strategy change (`:one_for_one` → `:rest_for_one`)
in `Tau.Telemetry.Supervisor` and the justification that this change does
not over-restart `Cost.Tracker` in the common path.

## Out of scope

- Supervision tree startup ordering or CLI task — exclusive scope of
  **supervision-tree-startup**.
- Global process name collision — exclusive scope of **global-name-collision**.
- Circuit-breaker counter protocol — exclusive scope of
  **circuit-breaker-invariant-split**.
- `Tau.OtelReporter.Handler.handle_event/4`'s existing rescue (justified by
  the handler-must-not-crash-emitter contract; not a defect).
- `Tau.Telemetry.Handlers.handle_event/4` log-format pessimisation (info
  severity; not a correctness defect).

## Amendment log

- (none yet)
