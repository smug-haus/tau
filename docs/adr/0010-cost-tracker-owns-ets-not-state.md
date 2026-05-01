# ADR-0010: Cost tracker owns an ETS table, not GenServer state

- **Status:** Accepted
- **Date:** 2026-05-01
- **Deciders:** the agent loop, with no objection from @smug-haus
- **Related:**
  - Issue: #40 (sub-issue of #19)
  - Code: `lib/tau/cost.ex`, `lib/tau/cost/tracker.ex`
  - Prior: ADR-0006 (defer caches without measurements — applies in
    spirit: "don't add a process where ETS suffices"), CLAUDE.md
    non-negotiable #1 (process-per-subsystem) and the explicit
    "no Manager GenServer for shared state" carve-out.

## Context

`Tau.Cost` aggregates `%Tau.Message.Assistant.usage{}` across all
sessions in the BEAM into spend metrics: tokens-by-provider,
tokens-by-session, etc. (#40). The shape of the data is a counter
table keyed by `{date, provider, model, session_id}`.

Two natural choices:

1. A `Tau.Providers.CostTracker` GenServer that holds the counters
   in its `state` and serves reads/writes via `handle_call` /
   `handle_cast`. The issue body sketches this.
2. A bare ETS table whose lifecycle is tied to a tiny owner process,
   with writers calling `:ets.update_counter/3` directly and readers
   doing table scans.

CLAUDE.md non-negotiable #1 explicitly forbids "a 'Manager' or
'Service' GenServer to 'own' shared state for convenience" —
shared state should live in `:persistent_term` / ETS, or split into
per-entity processes. A per-session counter doesn't fit (we need
cross-session aggregates), so ETS is the prescribed shape.

The hidden cost of the GenServer-state shape is mailbox
serialisation: every provider request stop becomes a cast, every
read becomes a call. With dozens of concurrent sessions emitting
provider-request-stop events at the end of every turn, the tracker
becomes a sequencing bottleneck. ETS `:ets.update_counter/3` is
atomic and lock-free; reads with `read_concurrency: true` scale
across schedulers without coordination.

## Decision

`Tau.Cost.Tracker` is a `GenServer` whose **only** job is to own
the ETS table named `:tau_cost_counters` and to attach a telemetry
handler that updates the table on
`[:tau, :provider, :request, :stop]`. It exposes no public
`handle_call` / `handle_cast` clauses for state mutation; readers
and writers go directly to ETS.

Specifically:

- Table options: `:named_table, :public, :set,
  read_concurrency: true, write_concurrency: true`.
- Key shape: `{date_iso8601 :: String.t(), provider :: module(),
  model :: String.t(), session_id :: String.t()}`.
- Value shape: a 4-tuple of counters
  `{input_tokens, output_tokens, cache_read, cache_write}`. Stored
  as positions 2–5 of the row tuple so `:ets.update_counter/3` can
  bump them with a single atomic call.
- Writer (`Tau.Cost.Tracker.handle_event/4`, the telemetry
  callback): `:ets.update_counter(:tau_cost_counters, key,
  [{2, in}, {3, out}, {4, cr}, {5, cw}], default_row)`.
- Reader: `Tau.Cost.summary/1` does `:ets.match_object/2` filtered
  by date and folds the rows.
- Lifecycle: the GenServer creates the table in `init/1` and
  detaches the telemetry handler in `terminate/2`. A crash
  restarts the whole tracker (and the table is recreated empty —
  acceptable; counters are observability data, not a source of
  truth).

## Consequences

- Provider-request-stop events do not serialise through a
  GenServer mailbox — `:ets.update_counter/3` is faster than
  `GenServer.cast` and pre-emptively concurrent.
- Readers can call `Tau.Cost.summary/0` from any process without
  fan-in to the tracker.
- The tracker process is a *lifecycle anchor*, not a state holder.
  Crashing it loses counters but does not block session work.
- `:tau_cost_counters` is `:public`; any test that wants to seed
  data can write to it directly. The table is named so tests can
  reset it via `:ets.delete_all_objects/1`.
- We do **not** track dollar spend yet. That requires a pricing
  table per `{provider, model}` and a way to update it as
  providers change prices. Filed as a follow-up; this PR ships the
  token-counting half.

## Alternatives considered

- **Manager-style GenServer with state map.** Forbidden by
  CLAUDE.md non-negotiable #1, and slower under load. The issue
  body sketches this shape, but the rationale (ergonomics) doesn't
  outweigh the cost.
- **`:persistent_term`.** Optimised for write-once /
  read-many; each `:persistent_term.put/2` triggers a global
  garbage scan. Counters that update on every turn would thrash
  this.
- **`:counters` module (BIF-backed atomics).** Faster than ETS for
  raw bumps but offers no key-based aggregation — we'd still need
  a separate index from `{date, provider, model, session_id}` →
  `:counters_ref`, which is more code than ETS for a marginal win.
- **Telemetry.Metrics with the official reporter.** Useful for
  external metrics back-ends (Prometheus, StatsD), but doesn't
  give us in-process readback for the `tau cost` CLI subcommand.
  Compatible — a future PR can attach a `Telemetry.Metrics`
  reporter alongside this tracker without conflict.

## Notes

The choice mirrors `Tau.Settings.Cache` (which uses
`:persistent_term` for the same one-writer-many-readers shape) and
the deferred `Tau.Memory.Cache` from ADR-0006 (which would have
used ETS if the measurements justified it). Both honour the
non-negotiable: state lives in BEAM term storage, processes own
lifecycles only.
