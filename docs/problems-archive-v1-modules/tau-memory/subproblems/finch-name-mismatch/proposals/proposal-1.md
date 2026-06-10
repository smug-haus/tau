---
template_version: 1
template_name: proposal
proposal_id: 1
parent_problem: ../problem.md
---

# Proposal 1: Fix the default atom at the call-site

## Approach

Change the single default value in `EmbeddingWorker.call_embedding_api/3` from
`Tau.Finch` to `Tau.Providers.Finch`. No new modules, no shared constant, no
behaviour changes. The `Application.get_env/3` call remains; only its third
argument changes.

```diff
-    finch_name = Application.get_env(:tau, :finch_name, Tau.Finch)
+    finch_name = Application.get_env(:tau, :finch_name, Tau.Providers.Finch)
```

## Rationale

The complecting hypothesis identifies two sites that can drift independently.
This proposal collapses the drift at its cheapest point — the wrong default atom
— without introducing new structure. The supervision tree already registers the
name; the call-site simply needs to match it. The `Application.get_env/3`
override hook is preserved, so operators who need a different pool name can still
set `:tau, :finch_name` in `config/runtime.exs`. The fix is atomic, reviewable
in one line, and directly satisfies the acceptance criterion.

## Sketch

File: `lib/tau/memory/embedding_worker.ex`, line 106:

```elixir
# Before
finch_name = Application.get_env(:tau, :finch_name, Tau.Finch)

# After
finch_name = Application.get_env(:tau, :finch_name, Tau.Providers.Finch)
```

No other files touched. The diff is one token.

## Tradeoffs

### Strengths

- Minimal blast radius: one line changed, zero new dependencies.
- Immediately satisfies the acceptance criterion with no migration.
- Preserves the runtime-override escape hatch (`Application.get_env/3`).
- Reviewable and revertable in seconds.

### Weaknesses

- Does NOT prevent future drift: the two atoms (`Tau.Providers.Finch` in
  `application.ex` and the default in `embedding_worker.ex`) remain unbound
  by any compile-time constraint. The next person who renames the pool in
  `application.ex` will reproduce this bug.
- No compile-time guarantee that the name exists when the call runs.
- The escape hatch (`Application.get_env/3`) is now the only coupling
  mechanism — if someone adds a second Finch pool and wants
  `EmbeddingWorker` to use a different one, they must remember the config key.

### Costs

- One-line change; review cost is effectively zero.
- No test surface change; the existing integration tests (if any) that mock
  Finch will continue to work.
- No operator migration required.

## Dependencies

- None. The fix is self-contained.

## Confidence

**High.** The root cause is a wrong atom literal; the fix is replacing it with
the correct atom. No design uncertainty.

What would raise it further: a test that asserts `Finch.request/3` is called
with `Tau.Providers.Finch` (currently absent per the problem statement).

## Prior art / references

- `lib/tau/application.ex:78` — the authoritative registration: `{Finch, name: Tau.Providers.Finch}`.
- The pattern of fixing a wrong default without adding structure is described in
  Rich Hickey's "Simple Made Easy" as preferring direct composition over indirect
  coordination.
