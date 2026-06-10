---
template_version: 1
template_name: proposal
proposal_id: 2
parent_problem: ../problem.md
---

# Proposal 2: Per-callback safe-call wrapper with per-exception telemetry and log

## Approach

Keep the four `try/rescue` blocks in `unload_module/1` but transform their contract: instead
of returning `[]` silently, each rescued exception emits a `Logger.warning/1` naming the
broken module and the specific callback (`tools/0`, `hooks/0`, `commands/0`, `skills/0`),
then emits a `[:tau, :extensions, :unload, :exception]` telemetry event, and finally
substitutes an empty list. Introduce a shared private helper
`safe_call_callback(mod, callback_name, default)` that encapsulates this pattern. The
`try_tool_name/1` rescue is given the same treatment. No change to the info map, no change
to how registry keys are discovered at unload time.

## Rationale

The acceptance criterion requires (a) a warning log naming module and callback, (b)
`[:tau, :extensions, :unload, :exception]` telemetry, and (c) no residual registry
entries for load-time registrations. This proposal satisfies (a) and (b) directly.
For (c), it relies on the observation that a broken module returning `[]` from callbacks
will cause zero unregister calls — which is a residual-entry failure only if callbacks
actually return different results than what was registered. The bet is: if a module's
`tools/0` raises, it is very unlikely that `tools/0` had returned a non-empty list at
load time (compile errors clobber the entire module). This proposal decomplects the
*visibility* of failures (silent vs. logged) without touching the registry-key-discovery
mechanism.

## Sketch

```elixir
# New helper — replace the four distinct try/rescue blocks

@spec safe_call_callback(module(), atom(), term()) :: term()
defp safe_call_callback(mod, callback, default) do
  apply(mod, callback, [])
rescue
  e ->
    Logger.warning(
      "Tau.Extensions.Loader: #{inspect(mod)}.#{callback}/0 raised during unload: " <>
        Exception.message(e)
    )
    :telemetry.execute(
      [:tau, :extensions, :unload, :exception],
      %{system_time: System.system_time()},
      %{module: mod, callback: callback, kind: :error, reason: e, stacktrace: __STACKTRACE__}
    )
    default
end

# Updated unload_module/1

defp unload_module(mod) do
  if is_extension?(mod) do
    tools = safe_call_callback(mod, :tools, [])
    Enum.each(tools, fn t ->
      tool_name = try_tool_name(t)
      if tool_name, do: Registry.unregister_match(Tau.Tools.Registry, tool_name, t)
    end)

    hooks = safe_call_callback(mod, :hooks, [])
    Enum.each(hooks, fn {ev, _h} ->
      Registry.unregister(Tau.Hooks.Registry, ev)
    end)

    commands = safe_call_callback(mod, :commands, [])
    Enum.each(commands, fn {name, _c} ->
      Registry.unregister(Tau.Commands.Registry, name)
    end)

    skills = safe_call_callback(mod, :skills, [])
    Enum.each(skills, fn {name, _path} ->
      Registry.unregister(Tau.Skills.Registry, name)
    end)
  end
end
```

`try_tool_name/1` is updated analogously (or called via `safe_call_callback` with `:name`).
No changes to `info` map, `load_entry/1`, `register_module/1`, `do_unload/1`, or
`unload_entry/2`.

## Tradeoffs

### Strengths

- Minimal diff: only `unload_module/1` and a new private helper change; four functions
  deleted (the four `try/rescue` blocks), one added.
- No refactoring of the `info` map or the load path — zero risk of perturbing load
  behaviour.
- Directly and explicitly satisfies acceptance-criterion requirements (a) and (b) with
  named module and callback in every log/telemetry event.
- Reusable helper reduces duplication immediately; the pattern is obviously applicable to
  `try_tool_name/1` as well.
- Incremental: can be merged independently of any other loader change.

### Weaknesses

- Does NOT satisfy acceptance criterion (c) in the case of a module that was successfully
  loaded (callbacks returned non-empty lists) and subsequently became broken via a partial
  hot-reload or dependency unload. In that failure mode, `safe_call_callback` returns `[]`
  and the prior registry entries remain.
- Relies on the implicit assumption that a broken module's broken callbacks returned empty
  lists at load time — an assumption that does not hold for hot-reload scenarios (D-124),
  which are the primary use case of `unload_module/1`.
- The accepted criterion explicitly requires "no residual registry entries for the
  registrations that were recorded at load time" — this proposal fails that bar for the
  hot-reload case even though it passes for fresh-compile-error cases.

### Costs

- Smallest possible diff: ~20 lines changed, ~4 lines added.
- No test-surface impact on `state.loaded` shape.
- Risk of false confidence: logs and telemetry fire, but residual entries may still exist
  after unload of a broken-but-previously-registered module.

## Dependencies

- None. No external or inter-module dependencies added.

## Confidence

low — the proposal satisfies (a) and (b) of the acceptance criterion but is structurally
unable to satisfy (c) for the hot-reload scenario that is the stated motivation of the
problem. Confidence in this being the right fix is low; confidence in the implementation
itself is high. This proposal is most useful if the problem statement's acceptance
criterion (c) is relaxed to "best-effort" for hot-reload.

## Prior art / references

- `crash_safe_register/2` telemetry and logging pattern (lines 296–349) — directly modelled.
- OTP `:logger` conventions: log at the severity of the originating event, include module
  and function in the message body.
