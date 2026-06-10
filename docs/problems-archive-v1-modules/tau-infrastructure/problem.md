---
template_version: 1
template_name: problem
node_kind: internal
depth: 0
parent: —
status: decomposed
---

# Problem: tau-infrastructure cross-cutting correctness

## Statement

`Tau.Application` and its cross-cutting subsystems (supervision tree, telemetry,
cost tracker, circuit breaker, OTel reporter) contain at least four independent
classes of correctness defect: asymmetric crash-safety in telemetry handlers,
a supervision strategy mismatch that allows stale handler re-attachment,
circuit-breaker invariants split across a stateless façade and an ETS-owner store
in a way that bakes the store's internal counter protocol into the pure-state
module's callers, and global process names that make single-node deployment a
hard requirement. Resolving any one class does not resolve the others; each can
be proposed and validated independently.

## Context

- `lib/tau/application.ex` — 17-child `:rest_for_one` supervision tree;
  `maybe_dispatch_cli/0` spawns an unmonitored `Task` (line 185) that calls
  `System.halt/1`; `otel_reporter_spec/0` (line 113) duplicates the
  enable/disable policy already expressed in `Tau.OtelReporter.init/1`.
- `lib/tau/cost/tracker.ex:118-138` — `handle_event/4` (provider-request-stop
  handler) has no rescue; the coding-agent twin at line 144 is guarded per D-035.
  Flat audit classifies this as Critical.
- `lib/tau/telemetry/supervisor.ex:17-22` — `:one_for_one` strategy; if
  `Tau.Telemetry.Handlers` crashes and restarts, `Cost.Tracker` is not
  restarted so its handlers remain attached; on `Handlers` restart the events
  list is re-attached — duplicate handler risk (flat audit: minor).
- `lib/tau/circuit_breaker.ex:124-145` — `record_outcome/5` performs a
  `new_count - 1` adjustment to work around `Store.bump_*/1` returning the
  post-increment value, encoding the Store's internal counter protocol in the
  façade's private logic (flat audit: minor).
- `lib/tau/circuit_breaker/state.ex:64` — `@default_cooldown_ms 30_000` is
  consumed inside `check/2` but not exposed as a keyword opt, while
  `failure_threshold` and `success_threshold` are threadable.
- `lib/tau/application.ex:68` — `Tau.PubSub` hard-coded global name; same
  pattern for `Tau.Providers.Finch`, `Tau.CircuitBreaker.Store` (`__MODULE__`),
  `Tau.Sessions.Supervisor`, etc. Two simultaneous Tau BEAM applications collide.
- SPEC-CIRCUIT-BREAKER D-029/D-030/D-043/D-044; OTP-NN §1, §7.

## Complecting hypothesis

1. **Crash-safety policy is complected with handler identity**: whether a
   telemetry handler survives a sibling's restart is determined by the
   supervisor strategy choice, not by any explicit lifecycle declaration in the
   handler itself — making crash-safety invisible until it fails.
2. **Store's counter protocol is complected with the façade's transition logic**:
   `Tau.CircuitBreaker.record_outcome/5`'s `new_count - 1` adjustment exists
   only because `Store.bump_*/1` returns post-increment; the pure `State`
   functions' `count + 1` semantics leak into the caller.
3. **Process-name scope is complected with deployment topology**: hard-coded
   atom names for PubSub, Finch, ETS tables, and supervisors embed a
   single-instance-per-node assumption into every subsystem simultaneously.

## Decomposition strategy

The audit lens names four independent concern classes:
(a) handler asymmetry and supervisor strategy mismatch (steady-state event handling);
(b) supervision tree startup ordering and the unmonitored CLI task (lifecycle);
(c) circuit-breaker invariant split between store and state (data-shape vs
    control-flow across a layer boundary);
(d) global name collision risk (deployment topology concern).

These four classes are MECE along the **concern (Hickey)** axis: each names a
distinct woven pair of concerns, no concern lives in two classes, and their union
covers every finding in the flat audit for this module. They are solvable
independently — a proposer at any leaf needs no conclusions from sibling leaves.

## Sub-problems (filled by decomposer)

1. **supervision-tree-startup** — Supervision tree lifecycle defects: the
   unmonitored CLI task, the dual OTel enable/disable policy, and `max_restarts`
   defaults for a binary expected to recover from transient init failures.
2. **telemetry-handler-coupling** — Telemetry handler crash-safety and the
   `Telemetry.Supervisor` `:one_for_one` strategy mismatch that allows stale or
   duplicate handler attachment after a sibling restart.
3. **circuit-breaker-invariant-split** — The circuit breaker's counter-protocol
   leakage between `Store.bump_*/1` (post-increment return) and `State`'s pure
   functions (`count + 1` semantics), plus the asymmetric cooldown configurability.
4. **global-name-collision** — Hard-coded global atom names for PubSub, Finch,
   ETS tables, and supervisors that embed a single-instance-per-node assumption.

## Acceptance criterion

All four sub-problems are resolved: each has a validated proposal that names the
change, the affected file(s) and line(s), and the invariant it restores, without
introducing new correctness defects at sibling boundaries.

## Out of scope

- `lib/tau/cost/tracker.ex` `handle_event/4` missing rescue is the specific
  subject of **telemetry-handler-coupling**; root does not propose fixes.
- `lib/tau/factory/gate.ex` placement (CI build tool under `lib/tau/`) — covered
  by the tau-cli audit module, not this one.
- Memory store (`lib/tau/memory/`) — covered by tau-memory audit module.
- Coding-agent defensive rescue ladders — covered by tau-coding-agent audit.
- Provider adapter drift — covered by tau-providers audit.
- `lib/tau/persistence/jsonl.ex` raises — covered by tau-cli audit.

## Amendment log

- (none yet)
