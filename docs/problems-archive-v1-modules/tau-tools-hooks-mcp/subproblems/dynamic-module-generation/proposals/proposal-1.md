---
template_version: 1
template_name: proposal
proposal_id: 1
parent_problem: ../problem.md
---

# Proposal 1: Data-driven dispatch — eliminate Module.create/3 entirely; store hook and tool config as tagged structs in registry values

## Approach

Replace every `Module.create/3` callsite with a plain-data registration. Define
`%Tau.Hooks.Shell.Entry{cmd, matcher, timeout_ms, events}` and
`%Tau.MCP.ToolEntry{server_name, namespaced_name, description, parameters}` as
plain structs. Store these structs directly as the registry value (instead of a
module atom). Rewrite `Tau.Hooks.Dispatcher.run_one/3` and `Tau.Tool.lookup/1`
(and the session FSM's tool dispatch path) to pattern-match on the struct tag
and delegate to the appropriate dispatch function
(`Tau.Hooks.Shell.run_command/5` or `Tau.MCP.ToolAdapter.invoke_remote/3`).
No compiled module is produced at settings-load time. Atoms created are only
the field-name atoms already in the struct definition, which are compile-time
constants, not per-config-entry runtime atoms.

## Rationale

The complecting hypothesis is that dispatch identity is forced to be a module
because `Hooks.Registry` and `Tools.Registry` store modules. Eliminating the
module-per-entry constraint decomplects the hook's _identity_ from its
_dispatch mechanism_. Once identity is a struct (data), reload is a data swap:
unregister the old struct values, register the new ones. No atom accumulation
is possible because no new atoms are created after boot. The dispatch logic
already exists as `run_command/5` and `invoke_remote/3` — both are public,
behaviour-preserving, and called from within the generated modules today.

## Sketch

```elixir
# lib/tau/hooks/shell.ex
defmodule Tau.Hooks.Shell.Entry do
  @enforce_keys [:cmd, :events]
  defstruct [:cmd, :matcher, :timeout_ms, :events]
end

# build/2 becomes:
@spec build(map(), [Tau.Hook.event()]) :: Tau.Hooks.Shell.Entry.t()
def build(%{"command" => cmd} = config, events) do
  %Tau.Hooks.Shell.Entry{
    cmd: cmd,
    matcher: config["matcher"],
    timeout_ms: (config["timeout"] || 60) * 1000,
    events: events
  }
end
# No Module.create/3. No atom generated.

# lib/tau/hooks/dispatcher.ex — run_one becomes:
defp run_one(%Tau.Hooks.Shell.Entry{} = entry, event, payload) do
  run_one_result(
    Tau.Hooks.Shell.run_command(entry.cmd, entry.matcher, entry.timeout_ms, event, payload),
    payload
  )
end

defp run_one(mod, event, payload) when is_atom(mod) do
  # existing behaviour-module path unchanged
  run_one_result(mod.handle(event, payload), payload)
end

# lib/tau/mcp/tool_adapter.ex — build/5 becomes:
defmodule Tau.MCP.ToolEntry do
  @enforce_keys [:server_name, :namespaced_name, :description, :parameters]
  defstruct [:server_name, :namespaced_name, :description, :parameters]
end

@spec build(module(), String.t(), String.t(), String.t(), map()) :: Tau.MCP.ToolEntry.t()
def build(_mod_name, server_name, namespaced_name, description, parameters) do
  %Tau.MCP.ToolEntry{
    server_name: server_name,
    namespaced_name: namespaced_name,
    description: description,
    parameters: parameters
  }
end
# mod_name arg retained for arity compat; ignored. Or drop it with a coord
# rename of the call in server.ex.

# lib/tau/tool.ex — lookup stores the struct; callers pattern-match:
@spec lookup(String.t()) :: {:ok, module() | Tau.MCP.ToolEntry.t()} | :error
def lookup(name) do
  case Registry.lookup(Tau.Tools.Registry, name) do
    [{_pid, val} | _] -> {:ok, val}
    [] -> :error
  end
end

# Session FSM tool dispatch (lib/tau/session.ex) gains one new clause:
defp dispatch_tool(%Tau.MCP.ToolEntry{} = entry, params, ctx) do
  local = String.replace_prefix(entry.namespaced_name, "mcp__#{entry.server_name}__", "")
  Tau.MCP.ToolAdapter.invoke_remote(entry.server_name, local, params)
end

defp dispatch_tool(mod, params, ctx) when is_atom(mod) do
  mod.execute(params, ctx)
end
```

File moves: none. Modules deleted: `Tau.MCP.ToolAdapter` module-creation body
(retains `invoke_remote/3` and `render_blocks/1`). `Tau.Hooks.Shell` loses
`generate_name/0` entirely.

## Tradeoffs

### Strengths

- Zero atoms created per reload: strictly satisfies acceptance criterion (a).
- No orphaned code generations: no `Module.create/3` means criterion (b) is
  vacuously satisfied — there is nothing to purge.
- All existing dispatch logic (`run_command/5`, `invoke_remote/3`) is already
  tested; the refactor is behaviour-preserving.
- Registry.unregister on settings-reload naturally garbage-collects the old
  data; no explicit cleanup needed.
- Reduces BEAM memory footprint: no compiled bytecode or module metadata tables
  for ephemeral tools.

### Weaknesses

- Breaks the uniform `Tau.Tool` behaviour contract: `dispatch_tool/3` in the
  session FSM now handles two shapes (module and struct), adding a branching
  concern to the FSM.
- MCP tools and built-in tools are no longer uniformly addressable via
  `mod.name/0`, `mod.description/0`, `mod.parameters/0` — any code that calls
  those callbacks on a looked-up value (e.g. introspection, help generation,
  schema export) must now branch on the type.
- The `Tau.Tool` behaviour's `name/0`, `description/0`, `parameters/0`
  callbacks become semantically meaningful only for compile-time tools; the
  behaviour loses its role as the universal interface for runtime-discovered
  tools.
- Requires touching the session FSM (`lib/tau/session.ex`), which is in
  SPEC-USER-TURN scope — a spec-gating concern.

### Costs

- `lib/tau/session.ex` must be updated to pattern-match on `ToolEntry` structs
  in the dispatch path. SPEC-USER-TURN gating is required.
- Any introspection path that iterates registered tools and calls `mod.name/0`
  etc. must be updated to handle the struct case — requires a full grep of
  callsites.
- Approximately 3–4 files modified; no new files needed.
- Backward compatibility: existing behaviour-module hooks and built-in tools
  are unaffected; only the shell-hook and MCP-adapter paths change.

## Dependencies

- `lib/tau/session.ex` dispatch clause must be updated atomically with the
  `build/2` change — these cannot land in separate PRs without a broken
  intermediate state.
- No library upgrades needed.

## Confidence

medium — The approach is mechanically straightforward and the dispatch functions
already exist. Confidence would rise to high after verifying the full set of
callsites that call `mod.name/0`, `mod.description/0`, `mod.parameters/0` on a
looked-up tool value (to confirm the branching cost is bounded).

## Prior art / references

- Elixir Registry stores arbitrary values; using a struct rather than a module
  atom as the registry value is idiomatic for dynamic systems (e.g., Phoenix
  Router's `{plug, opts}` tuples).
- Rich Hickey, "Simple Made Easy": replacing a compile-time artefact (module)
  with data reduces incidental complexity when the artefact's only purpose is
  to carry static values.
- `Tau.Hook` behaviour itself: `Tau.Hooks.Dispatcher` already branches on
  result shapes; extending it to branch on entry shape is consistent.
