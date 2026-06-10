---
template_version: 1
template_name: proposal
proposal_id: 3
parent_problem: ../problem.md
---

# Proposal 3: Single generic dispatcher module per subsystem — replace N generated modules with one parameterised module and an ETS config table

## Approach

For shell hooks, define a single compile-time module `Tau.Hooks.Shell.Dispatcher`
that implements `Tau.Hook` and at runtime reads its configuration from an ETS
table keyed by `{event, registration_key}`. Registration of a new hook entry
writes a row to the ETS table; no `Module.create/3` is called. `Tau.Hooks.Registry`
stores the atom `Tau.Hooks.Shell.Dispatcher` (not a unique generated module) as
the registry value for every shell-hook entry, plus a unique opaque `key` term
that the dispatcher uses to look up its config in ETS.

For MCP tool adapters, define a single compile-time module
`Tau.MCP.ToolAdapter.Dispatcher` that implements `Tau.Tool`. `name/0`,
`description/0`, and `parameters/0` are replaced by a `config/1` function that
accepts a key and returns the relevant field from ETS. The session FSM dispatch
path is extended with one clause that, when the tool registry value is the
`Dispatcher` module, calls `Dispatcher.execute(params, ctx, key)` instead of
`mod.execute(params, ctx)`.

## Rationale

The complecting hypothesis states that each hook/tool must be a distinct module
because the registry stores module atoms. This proposal decomplects by making
the registry value a `{module, key}` pair instead of a bare module atom.
A single shared dispatcher module is loaded once, consumes O(1) atoms and O(1)
code space, and all configuration lives in ETS (owned by a supervised process),
which supports insert/delete without atom-table effects. Reloading settings
writes new ETS rows and deletes old ones; no modules are created or destroyed.

## Sketch

```elixir
# lib/tau/hooks/shell/config_table.ex — new file (~30 lines)
defmodule Tau.Hooks.Shell.ConfigTable do
  @table :tau_shell_hook_configs

  def init, do: :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

  def put(key, cmd, matcher, timeout_ms),
    do: :ets.insert(@table, {key, cmd, matcher, timeout_ms})

  def get(key) do
    case :ets.lookup(@table, key) do
      [{^key, cmd, matcher, timeout_ms}] -> {:ok, cmd, matcher, timeout_ms}
      [] -> :error
    end
  end

  def delete(key), do: :ets.delete(@table, key)
end

# lib/tau/hooks/shell.ex — build/2 becomes a config-table write:
def build(%{"command" => cmd} = config, events) do
  matcher = config["matcher"]
  timeout_ms = (config["timeout"] || 60) * 1000
  key = make_ref()  # opaque; unique per registration; NOT an atom
  Tau.Hooks.Shell.ConfigTable.put(key, cmd, matcher, timeout_ms)
  {Tau.Hooks.Shell.Dispatcher, key, events}
  # caller registers the {Dispatcher, key} tuple in the Hook registry
end

# lib/tau/hooks/shell/dispatcher.ex — new file (~20 lines)
defmodule Tau.Hooks.Shell.Dispatcher do
  @behaviour Tau.Hook
  # events/0 not meaningful for the shared dispatcher; see registry registration note
  def events, do: []

  def handle(event, %{__hook_key__: key} = payload) do
    case Tau.Hooks.Shell.ConfigTable.get(key) do
      {:ok, cmd, matcher, timeout_ms} ->
        Tau.Hooks.Shell.run_command(cmd, matcher, timeout_ms, event, payload)
      :error ->
        :cont
    end
  end
end

# lib/tau/hooks/dispatcher.ex — inject key into payload before dispatch:
defp run_one({Tau.Hooks.Shell.Dispatcher, key}, event, payload) do
  run_one_result(
    Tau.Hooks.Shell.Dispatcher.handle(event, Map.put(payload, :__hook_key__, key)),
    payload
  )
end
defp run_one(mod, event, payload) when is_atom(mod) do
  # existing path unchanged
  run_one_result(mod.handle(event, payload), payload)
end

# lib/tau/mcp/tool_adapter/config_table.ex — analogous ETS table for MCP tools
defmodule Tau.MCP.ToolAdapter.ConfigTable do
  @table :tau_mcp_tool_configs

  def init, do: :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

  def put(key, server_name, local_name, description, parameters),
    do: :ets.insert(@table, {key, server_name, local_name, description, parameters})

  def get(key) do
    case :ets.lookup(@table, key) do
      [{^key, s, l, d, p}] -> {:ok, s, l, d, p}
      [] -> :error
    end
  end

  def delete(key), do: :ets.delete(@table, key)
end

# lib/tau/mcp/tool_adapter/dispatcher.ex — single Tau.Tool module
defmodule Tau.MCP.ToolAdapter.Dispatcher do
  @behaviour Tau.Tool
  # name/0 and description/0 are placeholders; real values fetched by key
  def name, do: "__mcp_dispatcher__"
  def description, do: ""
  def parameters, do: %{}
  def execution_mode, do: :parallel

  def execute(params, %Tau.Tool.Context{mcp_key: key}) do
    case Tau.MCP.ToolAdapter.ConfigTable.get(key) do
      {:ok, server, local, _d, _p} ->
        Tau.MCP.ToolAdapter.invoke_remote(server, local, params)
      :error ->
        {:ok, %Tau.Tool.Result{content: "MCP tool not found", is_error: true}}
    end
  end
end

# Context struct gains :mcp_key field; session FSM sets it from the registry
# value before calling execute/2.
```

The ETS tables are owned by a new supervised worker
`Tau.Hooks.Shell.ConfigTable` and `Tau.MCP.ToolAdapter.ConfigTable`, started in
`Tau.Application`'s supervision tree. `Tau.MCP.Server.terminate/2` calls
`ConfigTable.delete/1` for each registered key instead of `:code.delete/1`.

## Tradeoffs

### Strengths

- Zero atom growth on reload: `make_ref()` is used as keys; refs are not atoms.
  Acceptance criterion (a) is fully satisfied.
- Zero code-server growth on reload: only two compile-time modules ever exist
  (one dispatcher per subsystem), regardless of the number of hooks or tools
  ever loaded. Criterion (b) is fully satisfied.
- ETS reads are O(1) and concurrent; no lock contention compared to Registry
  lookups.
- ETS rows are garbage-collected by `delete/1` on unregister; no accumulation.

### Weaknesses

- The `Tau.Hook` behaviour's `events/0` callback does not fit the shared
  dispatcher model: the dispatcher module returns `[]` and the dispatcher event
  routing is handled externally by the registration layer — a subtle deviation
  from the behaviour contract.
- `Tau.Tool.Context` must be extended with `mcp_key` (or an equivalent side-
  channel), coupling the context struct to a specific dispatch variant. This is
  an API-breaking change to `Tau.Tool.Context`.
- Injecting `:__hook_key__` into the payload map is a leaky abstraction:
  hook implementations that inspect the payload will see an unexpected key.
  A more principled fix would thread the key through the dispatcher call
  signature, but that breaks the `handle(event, payload)` callback shape.
- Two new supervised workers and two new ETS tables increase the supervision
  tree depth and the number of things that can crash on startup.
- The ETS tables must be created before any hook or MCP registration fires;
  startup ordering in `Tau.Application` must be verified.

### Costs

- 4–5 new files; 3–4 modified files (`hooks/shell.ex`, `mcp/tool_adapter.ex`,
  `mcp/server.ex`, `lib/tau/application.ex`).
- `Tau.Tool.Context` struct modification may require updates across all
  `execute/2` implementations if they pattern-match on the context.
- Requires adding the config-table workers to the supervision tree and testing
  crash/restart behaviour for the ETS owner.

## Dependencies

- `Tau.Tool.Context` struct change must land before or atomically with the
  dispatcher implementation.
- The `Tau.Application` supervision tree must be updated to start the config-
  table workers before the hook/MCP subsystems.
- `Tau.Hooks.Registry` registration call sites must be updated to store
  `{module, key}` tuples rather than bare module atoms.

## Confidence

medium — The ETS + single-dispatcher pattern is proven in OTP (Phoenix PubSub
uses a similar strategy). Confidence drops because the `Tau.Tool.Context` API
break is wide-ranging and the `events/0` deviation from the behaviour contract
requires careful documentation.

## Prior art / references

- Phoenix PubSub dispatches to a single module (`Phoenix.PubSub.PG2`) with a
  config term, not per-subscription compiled modules.
- Elixir `Registry` supports arbitrary value types; the `{module, key}` pair
  pattern is documented in the Registry module's "Using the Registry" guide.
- OTP ETS `named_table` + supervised owner pattern — standard approach for
  read-heavy shared config in OTP applications.
