---
template_version: 1
template_name: proposal
proposal_id: 3
parent_problem: ../problem.md
---

# Proposal 3: `use Tau.Tool` DSL macro that wraps `execute/2` at compile time

## Approach

Extend `Tau.Tool` with a `__using__/1` macro that injects a public `execute/2`
wrapper around the module's `@impl Tau.Tool` `execute/2` implementation
(renamed to `do_execute/2`). The macro-injected `execute/2`:
(a) wraps `do_execute/2` in a `try/rescue` that converts raises to
`{:ok, Result.error(...)}`,
(b) asserts the returned `Result.details` has a `:kind` key and injects
`:unclassified` if absent (with a `Logger.warning/1` in dev/test),
(c) emits `[:tau, :tool, <name_atom>, :start]` / `[:tau, :tool, <name_atom>,
:stop]` / `[:tau, :tool, <name_atom>, :exception]` telemetry spans.
Each built-in tool keeps its current module shape but replaces `@impl Tau.Tool`
`def execute(...)` with `@impl Tau.Tool` `def do_execute(...)` and adds
`use Tau.Tool` at the top. `Bash.persist_full/3` is fixed separately using
non-raising `File` variants. The `Tau.Tool` behaviour gains `do_execute/2` as
its primary callback (replacing `execute/2`); `execute/2` becomes the macro-
injected public wrapper.

## Rationale

The complecting hypothesis is that the contract enforcement is woven into each
tool implementation because there is no dispatch layer between the FSM and
the tool. The `use` macro creates that layer inside each tool module itself,
so the tool module owns a conformant public interface without each author
having to remember the three properties. Unlike a central executor (Proposal 1),
enforcement is local to the module boundary: any caller of `Bash.execute/2`
directly (e.g. tests calling the tool in isolation) also benefits. Unlike typed
structs (Proposal 2), enforcement happens at runtime for all callers, not just
via static analysis. The behaviour callback rename from `execute` to
`do_execute` makes it impossible for a tool to accidentally bypass the wrapper
by implementing the old callback name — the compiler will warn about an
unimplemented `do_execute/2`.

## Sketch

```elixir
# lib/tau/tool.ex — add __using__/1 and rename primary callback
defmodule Tau.Tool do
  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback parameters() :: map()

  # Renamed from execute/2; macro injects a conformant execute/2
  @callback do_execute(params :: map(), ctx :: Context.t()) ::
              {:ok, Result.t()} | {:error, term()}

  @callback execution_mode() :: :sequential | :parallel
  @callback streams_updates?() :: boolean()

  @optional_callbacks [execution_mode: 0, streams_updates?: 0]

  defmacro __using__(_opts) do
    quote do
      @behaviour Tau.Tool
      alias Tau.Tool.Result

      # The macro-generated wrapper; modules implement do_execute/2 instead.
      def execute(params, ctx) do
        tool_name = __MODULE__.name()
        # Safe: module names are compile-time atoms
        telem_name = Module.concat([Tau.Tool, __MODULE__]) |> then(fn _ ->
          # Use a per-module atom derived from the module name
          __MODULE__
          |> Module.split()
          |> List.last()
          |> String.downcase()
          |> String.to_atom()
        end)

        started = System.monotonic_time(:millisecond)

        :telemetry.execute(
          [:tau, :tool, telem_name, :start],
          %{system_time: System.system_time()},
          %{tool: tool_name, tool_call_id: ctx.tool_call_id, session_id: ctx.session_id}
        )

        {event, outcome} =
          try do
            case __MODULE__.do_execute(params, ctx) do
              {:ok, %Result{} = r} ->
                r = maybe_inject_kind(r, tool_name)
                {:stop, {:ok, r}}

              {:error, _} = err ->
                {:stop, err}
            end
          rescue
            e ->
              {:exception,
               {:ok, Result.error("Tool raised: #{Exception.message(e)}",
                 details: %{kind: :raised_exception, exception: Exception.message(e)})}}
          end

        :telemetry.execute(
          [:tau, :tool, telem_name, event],
          %{duration: System.monotonic_time(:millisecond) - started},
          %{tool: tool_name, tool_call_id: ctx.tool_call_id,
            is_error: match?({:ok, %Result{is_error: true}}, outcome)}
        )

        outcome
      end

      defoverridable execute: 2

      defp maybe_inject_kind(%Result{details: %{kind: _}} = r, _name), do: r
      defp maybe_inject_kind(%Result{details: d} = r, name) do
        require Logger
        if Mix.env() in [:dev, :test] do
          Logger.warning("Tool #{name} returned details without :kind; injecting :unclassified")
        end
        %{r | details: Map.put(d, :kind, :unclassified)}
      end
    end
  end

  # ... rest of Tau.Tool unchanged
end
```

```elixir
# Example: Updated lib/tau/tools/builtin/write.ex
defmodule Tau.Tools.Builtin.Write do
  use Tau.Tool   # <-- replaces `@behaviour Tau.Tool`

  @impl Tau.Tool
  def name, do: "Write"
  # ... description, parameters, execution_mode unchanged ...

  # Renamed from execute/2
  @impl Tau.Tool
  def do_execute(%{"path" => path, "content" => content}, ctx) do
    full = ctx.operations.resolve(path, ctx.cwd)
    bytes = byte_size(content)

    case ctx.operations.write(full, content) do
      :ok ->
        {:ok, Result.text("Wrote #{bytes} bytes to #{full}",
          details: %{kind: :file_write, path: full, bytes: bytes})}  # kind added
      {:error, e} ->
        {:ok, Result.error("Write failed: #{inspect(e)}")}
    end
  end
end
```

```elixir
# The session dispatcher: no change needed.
# run_tool_validated/6 still calls mod.execute(args, ctx),
# which now resolves to the macro-injected wrapper.
```

The `String.to_atom/1` call inside the macro is safe at compile time because
it runs against the module's own compile-time name literal; it is not called
at runtime with user-supplied strings.

## Tradeoffs

### Strengths

- Enforcement is local to the tool module boundary; every caller of a tool
  module's `execute/2` (tests, inspectors, extensions) benefits — not just the
  session dispatcher path.
- No change required to `run_tool_validated/6` or any session FSM code.
- The callback rename from `execute/2` to `do_execute/2` makes it a compile-
  time error for any tool module using `use Tau.Tool` to forget the rename,
  because the `@behaviour` check fires on `do_execute`.
- Telemetry is per-tool and idiomatic (per-module atom, safe at compile time).
- Tool authors who opt into `use Tau.Tool` get the three properties for free;
  the pattern is well-understood in the Elixir ecosystem (`use GenServer`,
  `use Phoenix.LiveView`).

### Weaknesses

- The callback rename (`execute` → `do_execute`) is a breaking change for any
  external tool that implements `@behaviour Tau.Tool` directly without
  `use Tau.Tool`. The old `execute/2` callback must be deprecated rather than
  removed, creating a two-callback period.
- `defoverridable execute: 2` means a tool can still override the wrapper;
  discipline at code review is required to prevent bypasses.
- Modules that do NOT use `use Tau.Tool` (e.g., external or legacy tools)
  continue to call `execute/2` directly and receive no wrapper benefits; the
  property is not universally enforced without requiring all tools to migrate.
- The macro-injected `maybe_inject_kind/2` private function may conflict with
  a tool module that defines its own private function of the same name.
- Testing the macro-injected behaviour requires either a purpose-built stub
  module or importing the macro in test scope.

### Costs

- Modification to `lib/tau/tool.ex` to add `__using__/1` and rename primary
  callback (~60 LOC added; ~5 LOC changed).
- Six built-in tools: rename `execute` → `do_execute` and add `use Tau.Tool`
  (~12 LOC delta total across all six, plus `:kind` additions).
- `Bash.persist_full/3`: fix raising File calls (~10 LOC).
- Tests: rename `execute` to `do_execute` in any unit tests that call the
  callback directly rather than through `execute/2`; update assertion shapes.
- Deprecation shim for `execute/2` callback to avoid breaking external tools.

## Dependencies

- No library additions.
- All six built-in tools must be updated atomically to use `use Tau.Tool` (or
  individually; the macro is opt-in so incremental migration is possible).
- Any extension tools or MCP adapters that implement `Tau.Tool` directly will
  continue to work unchanged but will not gain the wrapper properties until
  they opt in.

## Confidence

Medium. The `use` macro pattern is idiomatic and well-tested in Elixir. The
main uncertainty is the `String.to_atom/1` compile-time safety for dynamically
named tools registered at runtime (MCP adapters). A prototype would clarify
whether the atom table concern is real for the current tool surface.

## Prior art / references

- `use GenServer` / `use Phoenix.LiveView` — established Elixir pattern for
  injecting behaviour-conformant wrappers via macro.
- `Tau.Tools.Builtin.Delegate` — already has its telemetry pattern inline;
  `use Tau.Tool` would supersede Delegate's manual emit calls.
- `Plug.Builder` — wraps the `call/2` callback in a pipeline via `use Plug.Builder`.
- Elixir `defoverridable` — enables hook-and-override for injected default implementations.
