---
template_version: 1
template_name: proposal
proposal_id: 2
parent_problem: ../problem.md
---

# Proposal 2: Stable deterministic module names + explicit purge on reload — keep Module.create/3 but eliminate the atom-growth path

## Approach

Keep `Module.create/3` for both hooks and MCP tool adapters, but replace the
random-suffix name generation with a deterministic naming scheme whose output is
stable across reloads for the same logical entry, and add an explicit
`:code.purge/1` + `:code.delete/1` sequence before re-creating a module with
the same name. For shell hooks, derive the name from a content-hash of the
`{cmd, matcher, events}` triple. For MCP tool adapters, the name is already
deterministic (`Module.concat([Tau.MCP.ToolAdapter, server_name, name])`) — the
fix is to add the purge step before `Module.create/3` when the name already
exists. A settings reload that produces the same config produces the same module
names and therefore zero new atoms; a reload that changes a hook's command
produces exactly one new atom (the new hash-derived name) and purges the old
module.

## Rationale

The root cause in `Hooks.Shell` is the random suffix, not `Module.create/3`
itself. The root cause in `MCP.ToolAdapter` is the missing purge, not the
naming. Fixing the two independent causes separately is a minimal, targeted
change that leaves the dispatch model (`Dispatcher` calls `mod.handle/2`, the
session FSM calls `mod.execute/2`) entirely intact. No behaviour changes; no
FSM touch; no callsite migration. The atom-table grows only by the number of
_distinct logical hooks/tools that have ever existed_, which is bounded by
real-world configuration, not by the number of reloads.

## Sketch

```elixir
# lib/tau/hooks/shell.ex — replace generate_name/0:
defp stable_name(cmd, matcher, events) do
  key = :erlang.phash2({cmd, matcher, Enum.sort(events)})
  Module.concat([Tau.Hooks.Shell, "Entry_#{key}"])
end

# build/2 becomes:
def build(%{"command" => cmd} = config, events) do
  matcher = config["matcher"]
  timeout_ms = (config["timeout"] || 60) * 1000
  name = stable_name(cmd, matcher, events)

  unless Code.ensure_loaded?(name) do
    body = quote do
      @behaviour Tau.Hook
      @impl true
      def events, do: unquote(events)
      @impl true
      def handle(event, payload) do
        Tau.Hooks.Shell.run_command(
          unquote(cmd), unquote(matcher), unquote(timeout_ms), event, payload
        )
      end
    end
    Module.create(name, body, Macro.Env.location(__ENV__))
  end

  name
end
# If config hasn't changed, Module.create/3 is skipped entirely.
# No new atom; no new code generation.

# lib/tau/mcp/server.ex — register_tool/2 purge before create:
defp register_tool(server_name, %{"name" => name} = tool_def) do
  key = "mcp__#{server_name}__#{name}"
  description = tool_def["description"] || "MCP tool from #{server_name}"
  parameters = tool_def["inputSchema"] || %{"type" => "object"}

  mod_name = Module.concat([Tau.MCP.ToolAdapter, server_name, name])

  if :erlang.module_loaded(mod_name) do
    :code.purge(mod_name)
    :code.delete(mod_name)
  end

  Tau.MCP.ToolAdapter.build(mod_name, server_name, key, description, parameters)
  Registry.register(Tau.Tools.Registry, key, mod_name)
  key
end
# Old code generation is purged before the new one lands.
# terminate/2 should also purge registered adapter modules on server shutdown.
```

Additionally, `terminate/2` in `Tau.MCP.Server` is extended to purge adapter
modules:

```elixir
def terminate(_reason, state) do
  Enum.each(state.registered_keys, fn key ->
    Registry.unregister(Tau.Tools.Registry, key)
  end)
  Enum.each(state.tools, fn %{"name" => name} ->
    mod = Module.concat([Tau.MCP.ToolAdapter, state.name, name])
    if :erlang.module_loaded(mod) do
      :code.purge(mod)
      :code.delete(mod)
    end
  end)
  if state.transport_state, do: state.transport.close(state.transport_state)
  :ok
end
```

## Tradeoffs

### Strengths

- Minimal diff: 2 files, targeted changes. No FSM touch, no behaviour changes,
  no callsite migration.
- Zero atoms per reload for unchanged config (hook module names are idempotent).
- Satisfies criterion (b): `:code.all_loaded/0` no longer grows on MCP restart
  because the old generation is explicitly purged.
- The `Tau.Tool` and `Tau.Hook` behaviour contracts are completely unchanged;
  tests require no modification.
- `Code.ensure_loaded?/1` guard means the hook compilation path is O(changed
  entries), not O(all entries), on every reload.

### Weaknesses

- Atom table still grows proportionally to _distinct hook configurations ever
  seen_ across the node's lifetime. If users frequently change hook commands
  (e.g., templated CI environments), new atoms accumulate. The growth is slow
  but not zero.
- `Module.create/3` is BEAM-version-sensitive: it generates a real code
  generation in the code server, consuming memory proportional to the number of
  distinct configurations, not just active ones.
- The content-hash scheme (`erlang.phash2`) is not collision-free. Two distinct
  configs that hash identically would share a module. Probability is negligible
  but not zero; a SHA-based scheme avoids it at the cost of a longer atom name.
- Purging a module that is currently being invoked (e.g., a long-running shell
  hook) will cause the invocation to complete normally (old code is soft-purged)
  but adds a code generation to the "old code" slot — if a second reload fires
  before the first invocation completes, the second purge will kill the running
  process. This is a standard BEAM hot-code-loading hazard, not new, but it
  wasn't present in the random-suffix approach.

### Costs

- 2 files modified (`hooks/shell.ex`, `mcp/server.ex`); ~20 lines changed.
- No new dependencies, no test suite changes.
- Operational: nodes that have been running long-duration processes holding
  references to old hook modules require testing of the soft-purge path.

## Dependencies

- No prerequisite changes.
- The `terminate/2` purge in `Tau.MCP.Server` must land in the same PR as the
  `register_tool/2` purge to avoid a partial state where new modules are purged
  on create but not on server shutdown.

## Confidence

high — Both `:code.purge/1` + `:code.delete/1` and `Code.ensure_loaded?/1` are
well-documented OTP mechanisms with clear semantics. The approach directly
addresses both named root causes.

## Prior art / references

- OTP documentation: `code` module, `purge/1` and `delete/1` — standard
  hot-code-loading sequence.
- Elixir `Code.ensure_loaded?/1` — idiomatic guard before conditional module
  operations.
- BEAM hot-code upgrade semantics: old code slot holds the prior generation
  until `:code.purge/1` removes processes referencing it, then `:code.delete/1`
  removes the slot.
- Phoenix LiveReloader uses a structurally similar pattern: recompile a module
  only when its source has changed; no unnecessary code generations.
