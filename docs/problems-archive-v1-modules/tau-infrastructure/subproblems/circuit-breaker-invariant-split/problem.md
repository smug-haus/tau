---
template_version: 1
template_name: problem
node_kind: leaf
depth: 1
parent: ../../problem.md
status: draft
---

# Problem: circuit-breaker invariant split between Store and State

## Statement

`Tau.CircuitBreaker.record_outcome/5` adjusts `new_count - 1` before
passing it to `State.record_failure/2` and `State.record_success/2` in
order to cancel out the `count + 1` increment that those pure functions
perform internally — meaning the façade encodes knowledge of the Store's
post-increment return convention AND knowledge of the State module's internal
arithmetic in the same private helper. A change to either side breaks the
protocol silently. Separately, `State.check/2` consumes `@default_cooldown_ms`
as a private module attribute while `failure_threshold` and `success_threshold`
are caller-threadable keyword opts, leaving cooldown as the only
threshold not configurable per provider call.

## Context

- `lib/tau/circuit_breaker.ex:124-145` — `record_outcome/5`; the comment at
  line 116-123 explains the `new_count - 1` dance explicitly: "To keep
  State's pure functions unmodified … we pass `new_count - 1` as the
  pre-bump value so the pure function computes the same `new_count`."
  Flat audit: minor, "bakes the State function's internal `count + 1`
  increment into the public protocol of `Store.bump_*`".
- `lib/tau/circuit_breaker/store.ex:116-133` — `bump_failure_count/1` and
  `bump_success_count/1` return the post-increment value via
  `:ets.update_counter/3`. There is no pre-increment variant.
- `lib/tau/circuit_breaker/state.ex:86-103` — `record_failure/2` in `:closed`
  state computes `new_count = s.failure_count + 1` from the struct field
  value passed in; the caller is expected to pass the pre-increment count.
- `lib/tau/circuit_breaker/state.ex:64` — `@default_cooldown_ms 30_000` is
  a private module attribute consumed in `check/2`; `record_failure/2` and
  `record_success/2` accept `:failure_threshold` and `:success_threshold`
  opts respectively. Flat audit: minor, "mismatched configurability".
- SPEC-CIRCUIT-BREAKER D-029/D-030/D-044.

## Complecting hypothesis

1. **The Store's counter-return convention is complected with the State
   module's pure-function semantics**: the façade's `record_outcome/5`
   is the only place where the post-increment/pre-increment impedance is
   resolved; changing either the Store primitive or the State arithmetic
   requires updating the façade's private adjustment, with no type-level
   or test-level enforcement.
2. **Cooldown configurability is complected with the default-threshold
   pattern**: `failure_threshold` and `success_threshold` are exposed as
   caller opts, establishing a pattern that `cooldown_ms` violates without
   documentation of why it is treated differently.

## Decomposition strategy

(leaf — no further decomposition; proceed to proposals)

## Acceptance criterion

A proposal names: (a) the interface change (either to `Store.bump_*/1`'s
return convention, or to `State`'s function signatures) that eliminates the
`new_count - 1` adjustment in `record_outcome/5`, with the D-044 row-layout
impact assessed; (b) whether `cooldown_ms` should be promoted to a
caller-threadable keyword opt in `State.check/2` (or documented as
intentionally non-threadable), with justification.

## Out of scope

- Supervision tree startup or CLI task — exclusive scope of
  **supervision-tree-startup**.
- Telemetry handler crash-safety — exclusive scope of
  **telemetry-handler-coupling**.
- Global process name collision — exclusive scope of
  **global-name-collision**.
- `Store`'s ETS schema version or row-layout fields other than the counter
  columns; probe-slot admission logic (`do_probe_admission`).
- Any change to the public `Tau.CircuitBreaker.call/3` API contract.

## Amendment log

- (none yet)
