---
template_version: 1
template_name: proposal
proposal_id: 1
parent_problem: ../problem.md
---

# Proposal 1: Snapshot-driven unload — enrich `info` with registered keys at load time

## Approach

Enrich the `info` map stored in `state.loaded` at load time to include the exact registry
keys that were registered for each callback category: `tools`, `hooks`, `commands`, and
`skills`. During `unload_module/1`, use the snapshot from `info` to drive all four
`Registry.unregister*` calls without invoking any behaviour callbacks. Remove the four
`try/rescue _ -> []` blocks entirely. Wrap the unregister loop in a `crash_safe_unload/2`
helper that mirrors `crash_safe_register/2`: emit a warning log and
`[:tau, :extensions, :unload, :exception]` telemetry if a Registry call itself raises.

## Rationale

The complecting hypothesis is that `unload_module/1` calls behaviour callbacks to discover
what to unregister, which fuses registry-key discovery with module-state assumptions. By
storing registry keys at registration time (when the module is known-good), the unload path
operates solely on load-time data. A module that has since become broken contributes no
information at unload time — the snapshot is sufficient and independent of the module's
current state. This decomplects "what was registered" (a historical fact in `info`) from
"what the module says now" (a runtime query to a potentially-broken module).

## Sketch

```elixir
# In register_module/1 — replace {:ok, mod, %{module: mod}} return

defp register_module(mod) do
  if is_extension?(mod) do
    tool_keys =
      Enum.flat_map(mod.tools(), fn t ->
        case Tau.Tool.register(t) do
          :ok -> [{:tool, try_tool_name(t), t}]
          _ -> []
        end
      end)

    hook_keys =
      Enum.map(mod.hooks(), fn {ev, h} ->
        Registry.register(Tau.Hooks.Registry, ev, h)
        {:hook, ev}
      end)

    command_keys =
      Enum.map(mod.commands(), fn {name, c} ->
        Registry.register(Tau.Commands.Registry, name, c)
        {:command, name}
      end)

    skill_keys =
      Enum.flat_map(mod.skills(), fn {name, path} ->
        case Tau.Skills.Loader.parse(path) do
          {:ok, skill} ->
            Registry.register(Tau.Skills.Registry, name, %{skill | name: name})
            [{:skill, name}]
          {:error, reason} ->
            Logger.warning("Tau.Extensions.Loader: skipping skill ...")
            []
        end
      end)

    info = %{
      module: mod,
      registered_keys: tool_keys ++ hook_keys ++ command_keys ++ skill_keys
    }

    {:ok, mod, info}
  else
    :error
  end
end

# In unload_module/1 — replace all four try/rescue blocks with snapshot-driven unregister

defp unload_module(mod, %{registered_keys: keys}) do
  Enum.each(keys, fn
    {:tool, nil, _t} -> :ok
    {:tool, name, t}  -> Registry.unregister_match(Tau.Tools.Registry, name, t)
    {:hook, ev}       -> Registry.unregister(Tau.Hooks.Registry, ev)
    {:command, name}  -> Registry.unregister(Tau.Commands.Registry, name)
    {:skill, name}    -> Registry.unregister(Tau.Skills.Registry, name)
  end)
end

defp unload_module(mod, _no_keys), do: unload_module_fallback(mod)

# crash_safe_unload/2 — mirrors crash_safe_register/2
defp crash_safe_unload(mod, info) do
  try do
    unload_module(mod, info)
  rescue
    e ->
      Logger.warning(
        "Tau.Extensions.Loader: unload of #{inspect(mod)} raised: #{Exception.message(e)}"
      )
      :telemetry.execute(
        [:tau, :extensions, :unload, :exception],
        %{system_time: System.system_time()},
        %{module: mod, kind: :error, reason: e, stacktrace: __STACKTRACE__}
      )
  end
end
```

`do_unload/1` is updated to thread `info` through to `crash_safe_unload/2`. `unload_entry/2`
already has `info` available; no public API changes required.

## Tradeoffs

### Strengths

- Fully satisfies the acceptance criterion: broken callbacks are never called at unload time;
  the snapshot drives complete, clean registry removal.
- Mirrors the existing `crash_safe_register/2` discipline exactly — consistency is high,
  maintenance cost is low.
- Snapshot fidelity: the keys recorded at `Registry.register` time are precisely the keys
  that need to be unregistered, with no inference step.
- No new public API surface; the change is entirely internal to the GenServer.
- `try_tool_name/1` becomes unused and can be deleted.

### Weaknesses

- Requires enriching the `info` map stored per-entry in `state.loaded`. Any code that
  pattern-matches on `%{module: mod}` must be updated to accept the enriched shape.
- The `do_unload/1` / `unload_module/1` call chain must be refactored to thread `info`
  through; currently `do_unload/1` receives `info` but `unload_module/1` does not.
- If `Tau.Tool.register/1` doesn't currently return `:ok | error`, the tool-key capture
  logic needs to be adjusted to match the actual return contract.
- Path-based entries (`%{path: path, modules: registered}`) register multiple modules; the
  enrichment must be per-module, requiring a per-module key list inside the entry info.

### Costs

- Moderate refactor: `register_module/1`, `do_unload/1`, `unload_module/1`,
  `unload_entry/2`, and `crash_safe_unload/2` (new). Estimate 4–6 functions touched.
- Test updates: tests that inspect `state.loaded` entry shapes or call `list/0` need to
  handle the enriched `info` map.
- The `registered_keys` field adds a small per-entry memory overhead (bounded by the count
  of registered items per extension).

## Dependencies

- `Tau.Tool.register/1` return value must be inspectable to determine whether a tool key
  was actually registered; if it currently returns `:ok` unconditionally, a `:ok | :error`
  shape or exception-on-failure is needed.
- No external dependency changes.

## Confidence

medium — the data-shape change is well-scoped and the Registry API supports keyed
unregister. Confidence would be raised to high by verifying `Tau.Tool.register/1`'s
return contract and confirming no external code pattern-matches on the bare `%{module: mod}`
info shape.

## Prior art / references

- `crash_safe_register/2` in the same file (lines 296–349) — the load-path mirror this
  proposal models the unload path on.
- Erlang/OTP `ets:insert_new` + tombstone pattern: store facts at write time, use them at
  delete time, never re-derive.
- `unload_entry/2` (lines 397–408): already receives `info` — the threading path exists.
