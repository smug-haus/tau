# ADR-0006: Defer `Tau.Memory.Cache` until measurements justify it

- **Status:** Accepted
- **Date:** 2026-04-30
- **Deciders:** @smug-haus
- **Related:**
  - Issue: #53
  - Code (removed): `lib/tau/memory/cache.ex`
  - Refs: #30 (added a tuning option to a never-written ETS table)

## Context

`Tau.Memory.Cache` was wired into the supervision tree as part of
the M0 push: a `GenServer` that creates a named ETS table in
`init/1` (`:tau_memory_cache`, `:set`,
`read_concurrency: true`, more recently
`decentralized_counters: true`) and exits to its idle loop.

`Tau.Memory.Loader.load/1` re-reads files from disk on every call
and **never touches the table**. The cache is dead code — neither
written to nor read from. #30 added an ETS tuning option to a
table no one uses. Pure cargo-cult.

Two costs:

1. Violates non-negotiable #3 ("No GenServer that wraps stateless
   logic just to 'own' it").
2. Misleads readers — the supervision tree implies state owners
   that don't exist.

The Phase-11 plan calls for an mtime-keyed `{path, mtime, size}`
ETS cache so repeated session starts don't re-read identical
`TAU.md` cascades from disk. We will land that when we have
measurements that show per-session cascade reads are a
bottleneck. Today, the load is a handful of small files; for
typical use it's well under a millisecond.

## Decision

**Delete `Tau.Memory.Cache`** (and its supervision-tree entry)
until either:

- profiling on a real workload (hot iteration, agentic loops with
  hundreds of session starts per minute) shows the read amplifies
  meaningfully, or
- a non-perf reason emerges (e.g., wanting a centralised
  invalidation channel for memory-file edits).

Until then, `Tau.Memory.Loader.load/1` reads from disk on each
call. Caching is added back as part of the work that proves it
matters, with the Phase-11 design documented in a new ADR.

## Consequences

- Supervision tree shrinks by one process and one ETS table.
- Reading the tree no longer suggests the existence of a memory
  cache that isn't wired up.
- Re-adding the cache later means another small refactor
  (introducing a `Tau.Memory.Loader.load_cached/1` or similar);
  cost is bounded.
- We accept slightly higher per-session-start file-read cost in
  exchange for not lying about what's running.

## Alternatives considered

- **Wire `Tau.Memory.Loader.load/1` to the existing ETS table**
  per the original plan. Possible, but doing it without a real
  workload to validate against would just shift the same
  cargo-cult earlier in the lifecycle. Better to wait until
  there's something to measure.
- **Keep the GenServer and rename it
  `Tau.Memory.Cache.Placeholder` with a clear "M11 stub"
  moduledoc.** Lying with extra steps. Just delete the file.
- **Move the ETS table creation into a `Tau.Memory` umbrella
  module that initialises at app boot but doesn't run a process.**
  More machinery for the same outcome.

## Notes

#30 was filed and (mistakenly) closed by adding
`decentralized_counters: true` to the unused table. That commit
was technically correct ("apply the right ETS tuning when this
becomes a real cache") and technically useless ("the table has no
writers"). Re-add the option when the cache exists.
