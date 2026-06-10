---
template_version: 1
template_name: proposal
proposal_id: 4
parent_problem: ../problem.md
---

# Proposal 4: Reify the Hook and Tool registries as GenServer-owned maps — replace Registry + Module.create/3 with a supervised config-map server per subsystem

## Approach

Replace the use of `Tau.Hooks.Registry` (a `:duplicate` `Registry`) and
`Tau.Tools.Registry` for the dynamic (shell hook and MCP adapter) entries with
two new supervised GenServers: `Tau.Hooks.Shell.Store` and
`Tau.MCP.ToolAdapter.Store`. Each store holds a `%{event => [shell_hook_entry]}`
and `%{namespaced_name => mcp_tool_entry}` map respectively, where entries are
plain maps (not modules). `Tau.Hooks.Dispatcher` calls
`Tau.Hooks.Shell.Store.list(event)` instead of `Registry.lookup/2` for the
dynamic-hook portion. The session FSM tool dispatch calls
`Tau.MCP.ToolAdapter.Store.get(name)` when `Tau.Tool.lookup/1` returns `:error`
(no compile-time tool registered). No `Module.create/3` is called anywhere in
the dynamic path. The compile-time `Tau.Hook` behaviour module requirement is
dropped for shell hooks; `Tau.Tool` behaviour module requirement is dropped for
MCP adapters. Reload is a GenServer `cast` that atomically replaces the internal
map; no atom accumulation is possible.

## Rationale

Both the `Tau.Hooks.Registry` and `Tau.Tools.Registry` are process-lifetime
registries — their entries disappear when the owning process exits. This makes
them a natural fit for long-lived compile-time hooks and tools but an awkward
fit for dynamically-loaded config entries that must survive independent of the
process that loaded them. A GenServer-owned map makes the config lifetime and
ownership explicit: the store process owns the config, and the store is under
the application supervisor. Settings reload becomes a functional state swap
(`GenServer.cast(store, {:reload, new_entries})`), atomic from the caller's
perspective. This fully decomplects _dispatch_ (the GenServer holds the config)
from _hook identity_ (the config key is the hook's logical identity, not a
module atom).

## Sketch

```elixir
# lib/tau/hooks/shell/store.ex — new file (~60 lines)
defmodule Tau.Hooks.Shell.Store do
  use GenServer

  @type entry :: %{
    cmd: String.t(),
    matcher: String.t() | nil,
    timeout_ms: non_neg_integer(),
    events: [Tau.Hook.event()]
  }

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @spec reload([entry()]) :: :ok
  def reload(entries), do: GenServer.call(__MODULE__, {:reload, entries})

  @spec list(Tau.Hook.event()) :: [entry()]
  def list(event), do: GenServer.call(__MODULE__, {:list, event})

  @impl true
  def init(_), do: {:ok, %{}}  # %{event => [entry]}

  @impl true
  def handle_call({:reload, entries}, _from, _state) do
    new_state =
      Enum.reduce(entries, %{}, fn %{events: evts} = e, acc ->
        Enum.reduce(evts, acc, fn ev, a -> Map.update(a, ev, [e], &[e | &1]) end)
      end)
    {:reply, :ok, new_state}
  end

  def handle_call({:list, event}, _from, state) do
    {:reply, Map.get(state, event, []), state}
  end
end

# lib/tau/hooks/shell.ex — build/2 returns a plain map:
@spec build(map(), [Tau.Hook.event()]) :: Tau.Hooks.Shell.Store.entry()
def build(%{"command" => cmd} = config, events) do
  %{
    cmd: cmd,
    matcher: config["matcher"],
    timeout_ms: (config["timeout"] || 60) * 1000,
    events: events
  }
end
# No Module.create/3. No atom generated. No Registry call.

# lib/tau/hooks/dispatcher.ex — lookup includes store:
defp lookup(event) do
  registry_mods = case Registry.lookup(Tau.Hooks.Registry, event) do
    [] -> []
    list -> Enum.map(list, fn {_pid, mod} -> mod end)
  end

  shell_entries = Tau.Hooks.Shell.Store.list(event)

  # shell entries run first (user-configured); compile-time mods run after
  shell_entries ++ registry_mods
end

defp run_one(%{cmd: cmd, matcher: matcher, timeout_ms: t}, event, payload) do
  run_one_result(Tau.Hooks.Shell.run_command(cmd, matcher, t, event, payload), payload)
end
defp run_one(mod, event, payload) when is_atom(mod) do
  run_one_result(mod.handle(event, payload), payload)
end

# lib/tau/mcp/tool_adapter/store.ex — new file (~50 lines)
defmodule Tau.MCP.ToolAdapter.Store do
  use GenServer

  @type entry :: %{
    server_name: String.t(),
    namespaced_name: String.t(),
    description: String.t(),
    parameters: map()
  }

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @spec put(String.t(), entry()) :: :ok
  def put(key, entry), do: GenServer.call(__MODULE__, {:put, key, entry})

  @spec delete(String.t()) :: :ok
  def delete(key), do: GenServer.call(__MODULE__, {:delete, key})

  @spec get(String.t()) :: {:ok, entry()} | :error
  def get(key), do: GenServer.call(__MODULE__, {:get, key})

  @spec list() :: [{String.t(), entry()}]
  def list, do: GenServer.call(__MODULE__, :list)

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call({:put, k, v}, _from, s), do: {:reply, :ok, Map.put(s, k, v)}
  def handle_call({:delete, k}, _from, s), do: {:reply, :ok, Map.delete(s, k)}
  def handle_call({:get, k}, _from, s), do: {:reply, Map.fetch(s, k), s}
  def handle_call(:list, _from, s), do: {:reply, Map.to_list(s), s}
end

# lib/tau/mcp/server.ex — register_tool/2:
defp register_tool(server_name, %{"name" => name} = tool_def) do
  key = "mcp__#{server_name}__#{name}"
  Tau.MCP.ToolAdapter.Store.put(key, %{
    server_name: server_name,
    namespaced_name: key,
    description: tool_def["description"] || "MCP tool from #{server_name}",
    parameters: tool_def["inputSchema"] || %{"type" => "object"}
  })
  key
end

# terminate/2 uses Store.delete/1 instead of Registry.unregister + code.delete:
def terminate(_reason, state) do
  Enum.each(state.registered_keys, &Tau.MCP.ToolAdapter.Store.delete/1)
  if state.transport_state, do: state.transport.close(state.transport_state)
  :ok
end

# lib/tau/tool.ex — lookup falls back to MCP store:
@spec lookup(String.t()) :: {:ok, {:mcp, Tau.MCP.ToolAdapter.Store.entry()} | module()} | :error
def lookup(name) do
  case Registry.lookup(Tau.Tools.Registry, name) do
    [{_pid, mod} | _] -> {:ok, mod}
    [] ->
      case Tau.MCP.ToolAdapter.Store.get(name) do
        {:ok, entry} -> {:ok, {:mcp, entry}}
        :error -> :error
      end
  end
end

# Session FSM dispatch adds one clause for the {:mcp, entry} shape:
defp dispatch_tool({:mcp, %{server_name: s, namespaced_name: n}}, params, _ctx) do
  local = String.replace_prefix(n, "mcp__#{s}__", "")
  Tau.MCP.ToolAdapter.invoke_remote(s, local, params)
end
defp dispatch_tool(mod, params, ctx) when is_atom(mod) do
  mod.execute(params, ctx)
end
```

## Tradeoffs

### Strengths

- Zero atom growth per reload: no `Module.create/3`, no random suffix, no
  atom-per-tool. Criteria (a) and (b) are fully and permanently satisfied.
- The GenServer state swap (`:reload`) is atomic from the dispatcher's
  perspective: the old entries are replaced in a single call, eliminating the
  window where a partially-updated registry could be observed during reload.
- Cleanup on MCP server shutdown is a simple map deletion — no BEAM hot-code-
  loading mechanics involved.
- Separation of lifecycle is explicit: the store process owns the config; the
  MCP server processes own the transport. Their lifetimes are independent.
- Introspection is straightforward: `Tau.MCP.ToolAdapter.Store.list/0` returns
  all registered MCP tools as plain data, useful for diagnostics and help
  generation.

### Weaknesses

- Two new supervised GenServers in `Tau.Application` add supervision tree depth
  and two new crash/restart scenarios to reason about. If the store crashes
  between a `put` and the caller registering the key in `registered_keys`, the
  restart produces a ghost entry.
- Every dispatch path now makes a GenServer call. Under high hook-dispatch
  frequency (e.g., a session that fires `:pre_tool_use` on every tool call), the
  store GenServer becomes a serialisation point. The MCP store is call-based, not
  ETS-based, so concurrent `get` calls queue behind each other.
- The `Tau.Tool.lookup/1` return type changes from `{:ok, module()}` to
  `{:ok, module() | {:mcp, entry()}}`, requiring the session FSM and any other
  lookup caller to handle the new shape. This is a public API change.
- `Tau.Tools.Registry` is retained for compile-time tools; MCP tools bypass it.
  This creates two separate lookup paths in `Tau.Tool.lookup/1`, which could
  cause confusion.

### Costs

- 2 new GenServer modules; 4–5 existing files modified.
- `lib/tau/session.ex` (SPEC-USER-TURN scope) must be updated to handle the
  `{:mcp, entry}` dispatch shape.
- Dialyzer will catch `Tau.Tool.lookup/1` callers that do not handle the new
  `{:mcp, entry}` variant — a good forcing function for a complete callsite audit,
  but adds migration effort proportional to the number of callers.
- GenServer call latency is measurable under load; benchmarking is advisable
  before landing.

## Dependencies

- `Tau.Application` supervision tree must start `Tau.Hooks.Shell.Store` and
  `Tau.MCP.ToolAdapter.Store` before the hook and MCP subsystems register
  entries.
- Session FSM (`lib/tau/session.ex`) change must land in the same PR under
  SPEC-USER-TURN gating.
- All callers of `Tau.Tool.lookup/1` must handle the `{:mcp, entry}` variant —
  a grep-and-update required before the PR is mergeable.

## Confidence

medium — The GenServer-owned-map pattern is standard OTP. Confidence drops
because the `Tau.Tool.lookup/1` API change is wide-ranging and the GenServer
serialisation under load has not been benchmarked. Would rise to high after
a concurrent dispatch benchmark and a Dialyzer-clean callsite audit.

## Prior art / references

- Elixir `Registry` is itself a supervised GenServer cluster; using a plain
  GenServer for a domain-specific subset of its function is a well-understood
  narrowing.
- `Phoenix.Router` stores route dispatch tables in a module-level compile-time
  structure; this proposal is the inverse — a runtime-loaded, process-owned
  table — which is the idiomatic OTP alternative when the data is dynamic.
- OTP Design Principles, "Supervisor Behaviour": using a supervised GenServer
  as the owner of shared mutable state is the canonical pattern for avoiding
  `:global` and `Application.put_env/3`.
- Tau OTP non-negotiables §1: "Stateful subsystems MUST run as supervised
  processes" — this proposal instantiates that rule for the dynamic hook and
  MCP-tool config.
