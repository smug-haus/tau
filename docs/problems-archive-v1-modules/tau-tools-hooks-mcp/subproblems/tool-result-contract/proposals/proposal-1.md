---
template_version: 1
template_name: proposal
proposal_id: 1
parent_problem: ../problem.md
---

# Proposal 1: Central dispatch wrapper in `run_tool_validated/6`

## Approach

Replace the bare `mod.execute(args, ctx)` call in
`Tau.Session.ToolDispatch.run_tool_validated/6` with a shared wrapper function
`Tau.Tool.Executor.call/4` that: (a) wraps `execute/2` in a `try/rescue` that
converts any raise into `{:ok, Result.error(...)}` before the existing outer
`try/rescue` sees it, (b) checks that the returned `Result.details` map
contains a `:kind` key and injects `kind: :unclassified` if absent, and (c)
emits `[:tau, :tool, <name_atom>, :start]` / `[:tau, :tool, <name_atom>,
:stop]` / `[:tau, :tool, <name_atom>, :exception]` telemetry around each call.
The existing `[:tau, :tool, :execute, :start/:stop/:exception]` events emitted
in `run_tool_validated` are retained as the session-level boundary events;
the new per-tool events are additive. `Bash.persist_full/3`'s `File.mkdir_p!/1`
and `File.write!/1` calls are wrapped in `File.mkdir_p/1` + `File.write/1`
(non-raising variants) as a simultaneous targeted fix so the raise guard is not
the sole protection.

## Rationale

The complecting hypothesis is that the three contract properties (no-raise,
details schema, telemetry) are each tool implementation's responsibility because
there is no central dispatch site between the FSM and `execute/2`. This proposal
adds exactly that site without altering the `Tau.Tool` behaviour contract,
`Tau.Tool.Result`'s struct shape, or any tool's public interface. The wrapper is
the single place where all three properties are enforced regardless of which
tool is called. Callers (`run_tool_validated`, `finish_permission_round`,
`spawn_parallel_dispatcher`) route through the same path without modification
because `run_tool_validated` is already their common convergence point. The
`Bash.persist_full/3` fix removes the live raise path so the wrapper is defence-
in-depth rather than the first line.

## Sketch

```elixir
# New file: lib/tau/tool/executor.ex
defmodule Tau.Tool.Executor do
  @moduledoc """
  Central execution wrapper that enforces the three Tau.Tool contract properties:
  (1) no uncaught raise, (2) details.kind present, (3) per-tool telemetry.
  Called exclusively from Tau.Session.ToolDispatch.run_tool_validated/6.
  """

  alias Tau.Tool.Result

  @spec call(module(), map(), Tau.Tool.Context.t(), integer()) ::
          {:ok, Result.t()} | {:error, term()}
  def call(mod, args, ctx, started_mono) do
    name = mod.name()
    name_atom = String.to_existing_atom(String.downcase(name))

    :telemetry.execute(
      [:tau, :tool, name_atom, :start],
      %{system_time: System.system_time()},
      %{tool: name, tool_call_id: ctx.tool_call_id, session_id: ctx.session_id}
    )

    outcome =
      try do
        mod.execute(args, ctx)
      rescue
        e ->
          {:ok, Result.error("Tool raised: #{Exception.message(e)}",
            details: %{kind: :raised_exception, exception: Exception.message(e)})}
      end

    {telemetry_event, result} =
      case outcome do
        {:ok, %Result{} = r} ->
          r = ensure_kind(r)
          {:stop, {:ok, r}}

        {:error, reason} ->
          {:stop, {:error, reason}}
      end

    :telemetry.execute(
      [:tau, :tool, name_atom, telemetry_event],
      %{duration: System.monotonic_time(:millisecond) - started_mono},
      %{tool: name, tool_call_id: ctx.tool_call_id,
        is_error: match?({:ok, %Result{is_error: true}}, result)}
    )

    result
  end

  defp ensure_kind(%Result{details: %{kind: _}} = r), do: r
  defp ensure_kind(%Result{details: d} = r), do: %{r | details: Map.put(d, :kind, :unclassified)}
end
```

```elixir
# Modification to lib/tau/session/tool_dispatch.ex
# In run_tool_validated/6, replace:
#   case mod.execute(args || %{}, ctx) do
# with:
#   case Tau.Tool.Executor.call(mod, args || %{}, ctx, started) do
```

```elixir
# Modification to lib/tau/tools/builtin/bash.ex
# persist_full/3: replace File.mkdir_p!/dir and File.write!/path with:
  defp persist_full(output, session_id, call_id) do
    dir = Tau.Settings.data_dir() |> Path.join("sessions") |> Path.join(session_id || "default")
    with :ok <- File.mkdir_p(dir),
         path = Path.join(dir, "bash-#{call_id}.log"),
         :ok <- File.write(path, output) do
      path
    else
      {:error, reason} -> nil  # truncation log unwritable; degrade gracefully
    end
  end
```

The `String.to_existing_atom/1` call is safe because all built-in tool names
(`"Bash"`, `"Read"`, `"Write"`, `"Edit"`, `"Delegate"`, `"Agent"`) are atoms
already in the atom table from module compilation. For dynamically-registered
tools (MCP adapters, extensions), the wrapper falls back to
`[:tau, :tool, :dynamic, :start/:stop]` with the name in metadata.

## Tradeoffs

### Strengths

- Decomplects the contract enforcement from every tool implementation in one
  change: the wrapper is the single enforcement site.
- Behaviour-preserving: the `Tau.Tool` callback contract, `Result` struct, and
  all tool module APIs are unchanged.
- Minimal blast radius: one new module, one call-site change in
  `run_tool_validated`, one targeted fix in `bash.ex`.
- Existing `[:tau, :tool, :execute, :start/:stop/:exception]` events are
  preserved for consumers already subscribed to them.
- The `ensure_kind/1` guard makes the acceptance criterion for (b) fully
  verifiable by a test that calls `Executor.call/3` with a module that omits
  `:kind` from details.

### Weaknesses

- `String.to_existing_atom/1` is unsafe for arbitrary dynamic tool names; the
  fallback to `[:tau, :tool, :dynamic, ...]` loses per-tool observability for
  runtime-registered tools.
- `ensure_kind/1` injects `:unclassified` rather than raising; this masks
  authoring errors silently in production (though CI can catch it with a test).
- Tools that already emit their own `[:tau, :tool, :bash, :stderr]` sub-events
  now fire both their own sub-event and the new wrapper-level event; operators
  must understand the two-level namespace.
- The `persist_full/3` fix degrades silently (returns `nil` on write failure)
  rather than surfacing the error in the tool result; a caller relying on
  `details.full_output_path` gets `nil` instead of an error.

### Costs

- One new file (`lib/tau/tool/executor.ex`, ~50 LOC).
- One-line change in `run_tool_validated`.
- `bash.ex` `persist_full/3` refactor (~10 LOC delta).
- Tests: one new unit test for `Executor.call/4`; one property test for
  `ensure_kind/1`; update `bash.ex` tests that test truncation path.
- Zero API surface change for tool authors.

## Dependencies

- No library additions required.
- The `String.to_existing_atom/1` fallback for dynamic tools requires the
  dynamic-module-generation sub-problem to be at least aware of this naming
  contract (no hard dependency, but coordination is cleaner if both land
  together).

## Confidence

Medium. The approach is straightforward and the call-site is clearly identified.
Confidence would be high if a prototype confirmed that `String.to_existing_atom`
covers all currently-registered tool names (easily verified with
`Tau.Tool.list()` at runtime).

## Prior art / references

- `Tau.Session.ToolDispatch.run_tool_validated/6` lines 671–737 — existing
  outer `try/rescue` and session-level telemetry; the new wrapper nests inside.
- `Tau.Tools.Builtin.Delegate` — already emits `[:tau, :tool, :delegate,
  :start/:stop/:exception]` directly; this proposal centralises the same
  pattern without removing Delegate's own emissions.
- Elixir `File.mkdir_p/1` / `File.write/1` — non-raising equivalents in stdlib.
