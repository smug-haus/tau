---
template_version: 1
template_name: proposal
proposal_id: 3
parent_problem: ../problem.md
---

# Proposal 3: Registry ownership unregister — use `Registry.unregister_all/2` keyed on the loader PID

## Approach

Change the registration strategy so that all registry keys registered by the loader for a
given module are tagged with that module's atom as the registry `value`'s owner-key (or use
a distinct `{:extension, mod}` tuple as the Registry key). At unload time, call
`Registry.unregister_match/3` (or a per-registry `Registry.select/2` + `Registry.unregister/2`
loop) scoped to `{:extension, mod}` without invoking any behaviour callbacks. Remove all
four `try/rescue` blocks. Emit warning log and `[:tau, :extensions, :unload, :exception]`
telemetry if the Registry interaction itself raises. This approach changes the registry
value shape at registration time; existing callers that look up by name and expect a bare
`Tool.t()` or command map must be updated.

## Rationale

The current design uses Registry keys that are semantic names (tool names, event atoms,
command names, skill names). Unloading requires knowing those names again, so `unload_module/1`
must re-query the module. This proposal moves ownership metadata into the registry itself:
the loader registers entries tagged with `{:extension, mod}` as a match-value prefix or
secondary key, enabling `Registry.unregister_match/3` to remove all entries for a given
module without asking the module for anything. The query axis (what did this module register?)
is resolved by the registry rather than by the module.

## Sketch

```elixir
# Changed registration in register_module/1:
# Each registry entry value is wrapped: {:extension_entry, mod, original_value}

Enum.each(mod.tools(), fn t ->
  name = t.name()  # still called at load time, when mod is known-good
  Registry.register(Tau.Tools.Registry, name, {:extension_entry, mod, t})
end)

Enum.each(mod.hooks(), fn {ev, h} ->
  Registry.register(Tau.Hooks.Registry, ev, {:extension_entry, mod, h})
end)

Enum.each(mod.commands(), fn {name, c} ->
  Registry.register(Tau.Commands.Registry, name, {:extension_entry, mod, c})
end)

Enum.each(mod.skills(), fn {name, path} ->
  case Tau.Skills.Loader.parse(path) do
    {:ok, skill} ->
      Registry.register(Tau.Skills.Registry, name, {:extension_entry, mod, %{skill | name: name}})
    {:error, reason} ->
      Logger.warning("...")
  end
end)

# Unload — no callback invocation at all

defp unload_module(mod) do
  # Each registry: unregister all keys where the value matches {:extension_entry, mod, _}
  [
    {Tau.Tools.Registry, :tools},
    {Tau.Hooks.Registry, :hooks},
    {Tau.Commands.Registry, :commands},
    {Tau.Skills.Registry, :skills}
  ]
  |> Enum.each(fn {registry, label} ->
    try do
      # Registry.select returns [{key, pid, value}]; match on {:extension_entry, mod, _}
      entries = Registry.select(registry, [
        {{:"$1", :"$2", {:extension_entry, ^mod, :"$3"}}, [], [{{:"$1", :"$2", :"$3"}}]}
      ])
      Enum.each(entries, fn {key, _pid, _val} ->
        Registry.unregister(registry, key)
      end)
    rescue
      e ->
        Logger.warning(
          "Tau.Extensions.Loader: #{inspect(registry)} unregister of #{inspect(mod)} raised: " <>
            Exception.message(e)
        )
        :telemetry.execute(
          [:tau, :extensions, :unload, :exception],
          %{system_time: System.system_time()},
          %{module: mod, registry: registry, label: label, kind: :error, reason: e,
            stacktrace: __STACKTRACE__}
        )
    end
  end)
end
```

Callers of the registries (e.g. `Tau.Tool.lookup/1`) must unwrap `{:extension_entry, _mod, value}`
to get the original value. `try_tool_name/1` becomes unused and is deleted.

## Tradeoffs

### Strengths

- Fully satisfies acceptance criterion (c): unload is driven by registry contents, not by
  module callbacks. A module that has become broken is cleanly unregistered without any
  callback invocation.
- The registry becomes the single source of truth for "what is registered" — no parallel
  `info` snapshot required in `state.loaded`.
- `try_tool_name/1` is eliminated entirely (no more `mod.name/0` call at unload time).
- Registry-ownership semantics are explicit and introspectable at runtime via
  `Registry.select/2`.

### Weaknesses

- API-breaking change to registry value shapes: every registry consumer (tool lookup, hook
  dispatch, command dispatch, skill dispatch) must unwrap `{:extension_entry, mod, val}`.
  This is a wide blast radius.
- `Registry.select/2` with match-spec syntax is non-obvious and hard to read; it inverts
  the simplicity gained elsewhere.
- If a registry uses `keys: :unique`, `Registry.select/2` still works, but the
  `unregister` must be called on the **same PID** that registered; since the Loader PID
  registered all entries, this works — but the constraint is non-obvious.
- Mixing structural metadata (`{:extension_entry, mod, _}`) into registry values creates a
  new convention that future extension code must follow; it is not enforced by the type
  system.
- Does not address the case where an extension registers a tool via a path-based entry that
  covers multiple modules — the `{:extension_entry, mod, _}` tagging must be per-module,
  not per-path-entry.

### Costs

- Large blast radius: `Tau.Tool` lookup, hook dispatch, command dispatch, skill dispatch
  must all be updated to unwrap the new value shape.
- Likely 6–10 callsites outside `loader.ex`.
- Tests for registry consumers (tool dispatch, hook event tests, command invocation tests)
  must be updated.
- Risk: if any Registry consumer is missed in the unwrapping update, it silently receives
  `{:extension_entry, mod, value}` where it expects a bare value — a runtime type error
  rather than a compile error.

## Dependencies

- All Registry consumers (`Tau.Tool.lookup/1`, hook dispatch in session, command dispatch
  in session, skill dispatch) must be updated atomically with this change or the system
  breaks. Cannot be deployed incrementally.
- Requires verifying that `Registry.select/2` with the `^mod` pin in the match spec works
  for all four registries (unique and duplicate key modes).

## Confidence

low — the registry-ownership approach is architecturally clean but the blast radius
(unwrapping in all consumers) is large and must land atomically. Confidence would be raised
by checking the Registry consumer count and verifying `Registry.select/2` pin semantics
against the Elixir Registry docs.

## Prior art / references

- Elixir `Registry.select/2` documentation: match-spec-based bulk lookup.
- Erlang `pg` / `gproc` ownership patterns: process-keyed group membership for clean
  process-exit cleanup.
- Phoenix PubSub topic ownership: all subscriptions for a PID are cleared on PID exit —
  same ownership-in-registry concept but driven by process death rather than explicit
  unload call.
