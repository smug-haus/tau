---
template_version: 1
template_name: proposal
proposal_id: 2
parent_problem: ../problem.md
---

# Proposal 2: Extract Tau.Cost.HandlerGuard — shared rescue wrapper for all cost handlers

## Approach

Extract a new module `Tau.Cost.HandlerGuard` that provides a single
`guarded/3` wrapper function (handler id, measurement map, a zero-arity
fun) with the D-035-compliant `rescue` and telemetry emission inside.
Rewrite both `handle_event/4` and `handle_coding_agent_cost/4` in
`Tau.Cost.Tracker` to delegate their bodies through `HandlerGuard.guarded/3`.
Change `Tau.Telemetry.Supervisor` to `:rest_for_one` as in Proposal 1.

## Rationale

The two handler functions already share the same rescue pattern and the
same failure-telemetry event; the only difference is which event they
listen to and which metadata keys they read. Extracting the guard into
`HandlerGuard` makes it impossible for a future third handler (e.g. a
streaming-token cost event) to be added without the rescue — the guard
is the only public entry point. The complecting hypothesis states that
crash-safety is woven into handler identity; `HandlerGuard` decomplects
by making crash-safety a structural wrapper rather than a per-handler
convention. The supervisor change is the same as Proposal 1 for the same
reason.

## Sketch

**New file `lib/tau/cost/handler_guard.ex`:**

```elixir
defmodule Tau.Cost.HandlerGuard do
  @moduledoc """
  Wraps a telemetry handler body with the D-035-mandated rescue boundary.

  Any exception raised inside `fun` is caught; a
  `[:tau, :cost, :tracker, :handler_failed]` event is emitted with the
  exception message, and the handler returns `:ok` so the emitter is
  never crashed.
  """

  @failure_event [:tau, :cost, :tracker, :handler_failed]

  @doc """
  Invoke `fun.()` inside a D-035-compliant rescue boundary.

  `handler_id` is included in the failure-event metadata for
  observability (distinguishes which handler raised).
  """
  @spec guarded(String.t(), (-> :ok)) :: :ok
  def guarded(handler_id, fun) when is_function(fun, 0) do
    fun.()
  rescue
    e ->
      :telemetry.execute(
        @failure_event,
        %{system_time: System.system_time()},
        %{handler_id: handler_id, reason: Exception.message(e)}
      )
      :ok
  end
end
```

**`lib/tau/cost/tracker.ex` — rewrite both handler bodies:**

```elixir
@doc false
def handle_event(_event, measurements, metadata, _config) do
  HandlerGuard.guarded(@handler_id, fn ->
    with provider when is_atom(provider) and not is_nil(provider) <- metadata[:provider],
         session_id when is_binary(session_id) <- metadata[:session_id],
         usage when is_map(usage) <- measurements[:usage] do
      key = {today_iso(), provider, metadata[:model], session_id}
      :ets.update_counter(@table, key,
        [{2, nz(usage[:input_tokens])}, {3, nz(usage[:output_tokens])},
         {4, nz(usage[:cache_read])},   {5, nz(usage[:cache_write])}],
        {key, 0, 0, 0, 0})
    else
      _ -> :ok
    end
  end)
end

@doc false
def handle_coding_agent_cost(_event, measurements, metadata, _config) do
  HandlerGuard.guarded(@coding_agent_handler_id, fn ->
    with agent when is_atom(agent) and not is_nil(agent) <- metadata[:agent],
         session_id when is_binary(session_id) <- metadata[:session_id] do
      key = {today_iso(), agent, metadata[:model], session_id}
      :ets.update_counter(@table, key,
        [{2, nz(measurements[:input_tokens])}, {3, nz(measurements[:output_tokens])},
         {4, nz(measurements[:cache_read])},   {5, nz(measurements[:cache_write])}],
        {key, 0, 0, 0, 0})
    else
      _ -> :ok
    end
  end)
end
```

**`lib/tau/telemetry/supervisor.ex`** — identical `:rest_for_one` change as
Proposal 1.

**File move summary:** `lib/tau/cost/handler_guard.ex` added (new).

## Tradeoffs

### Strengths

- Makes D-035 structurally enforceable: future handlers cannot bypass the
  rescue without deliberately not calling `HandlerGuard.guarded/3`.
- Adds `handler_id` to the failure-event metadata, improving observability
  (distinguishes which handler raised — useful if more handlers are added).
- Eliminates the current code duplication between the two handler rescues.
- The guard is independently testable without standing up a supervisor tree.

### Weaknesses

- Introduces a new module for what is currently a ~5-line pattern; may be
  over-engineering given there are only two handlers today.
- The wrapper function call (`HandlerGuard.guarded/3`) obscures the handler
  body one level deeper, making stack traces slightly harder to read.
- Does not address the structural question of why `handle_event/4` was
  written without the rescue in the first place — a process/review issue,
  not a code issue.
- `rescue` inside the anonymous function propagates up to `guarded/3`'s
  rescue: this is correct but may be non-obvious to reviewers unfamiliar
  with how Elixir `rescue` scopes in nested functions.

### Costs

- 1 new file (`handler_guard.ex`), 2 files modified, ~25 lines net.
- Test surface: `HandlerGuard` itself needs a unit test (guarded fn raises
  → returns `:ok` + emits telemetry). Existing handler tests exercise the
  delegating bodies; a separate `HandlerGuard` test is clean.
- No dependency changes; no migration.

## Dependencies

- None beyond the same `:rest_for_one` supervisor change.

## Confidence

medium — the pattern is clean; the only risk is reviewer resistance to
adding a module for a small rescue wrapper. Would be high if a third
cost-telemetry handler were already planned (making DRY clearly worthwhile).

## Prior art / references

- `Tau.OtelReporter.Handler.handle_event/4` — a different module that also
  wraps its handler body in a rescue, independently confirming the OTP
  telemetry handler-must-not-crash-emitter contract.
- D-035 ("cost-folding errors MUST degrade gracefully") — the spec driving
  this proposal.
- Elixir docs: anonymous function rescue scope — confirmed that `rescue`
  inside an anonymous function is local to that function's frame, not the
  enclosing `def`'s.
