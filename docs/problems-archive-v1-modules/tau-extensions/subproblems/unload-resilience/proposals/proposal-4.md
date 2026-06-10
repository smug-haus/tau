---
template_version: 1
template_name: proposal
proposal_id: 4
parent_problem: ../problem.md
---

# Proposal 4: Isolated unload sub-process — delegate unload callback queries to a monitored Task

## Approach

Replace the four `try/rescue _ -> []` blocks in `unload_module/1` with a single
`Task.await/2` call to a short-lived monitored process. The Task calls all four behaviour
callbacks (`mod.tools/0`, `mod.hooks/0`, `mod.commands/0`, `mod.skills/0`) under normal
OTP supervision. If any callback raises or the task times out (e.g. 200 ms), the Task
exits abnormally; the Loader receives the exit reason, emits warning log and
`[:tau, :extensions, :unload, :exception]` telemetry, and falls back to the load-time
snapshot from `state.loaded` (enriched with callback results from load time — see below)
to drive the unregister loop. On success, the task returns the four lists and the Loader
uses them normally. The fallback to the load-time snapshot satisfies requirement (c).

## Rationale

The current design runs callback queries in the Loader process, so a callback that hangs
indefinitely (not just raises) can stall the Loader GenServer — a risk the `try/rescue`
approach does not address. Delegating callback queries to a Task process decomplects the
Loader's liveness from the extension module's correctness: whether the module raises,
panics, or spins, the Loader is unblocked after the timeout. The fallback to the load-time
snapshot (which must exist for any successfully-registered module) satisfies requirement (c)
without requiring the module to cooperate. This approach combines process isolation (OTP
"let it crash" for the sub-process) with the data-shape enrichment of Proposal 1's snapshot
— but applies the snapshot only as a fallback rather than as the primary path.

## Sketch

```elixir
# load-time: enrich info with callback results (mirrors Proposal 1)
defp register_module(mod) do
  if is_extension?(mod) do
    # ... (registration unchanged) ...
    info = %{
      module: mod,
      tools: mod.tools(),
      hooks: mod.hooks(),
      commands: mod.commands(),
      skills: mod.skills()
    }
    {:ok, mod, info}
  else
    :error
  end
end

# Unload: try Task-isolated callback queries; fall back to snapshot

defp unload_module(mod, info) do
  task = Task.async(fn ->
    {mod.tools(), mod.hooks(), mod.commands(), mod.skills()}
  end)

  {tools, hooks, commands, skills} =
    case Task.yield(task, 200) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      nil ->
        # Task timed out or the module raised — use load-time snapshot
        Logger.warning(
          "Tau.Extensions.Loader: #{inspect(mod)} callbacks did not return during unload " <>
            "(timed out or raised); using load-time snapshot"
        )
        :telemetry.execute(
          [:tau, :extensions, :unload, :exception],
          %{system_time: System.system_time()},
          %{module: mod, reason: :timeout_or_raise}
        )
        {
          Map.get(info, :tools, []),
          Map.get(info, :hooks, []),
          Map.get(info, :commands, []),
          Map.get(info, :skills, [])
        }
    end

  Enum.each(tools, fn t ->
    name = try_tool_name(t)
    if name, do: Registry.unregister_match(Tau.Tools.Registry, name, t)
  end)
  Enum.each(hooks,    fn {ev, _}   -> Registry.unregister(Tau.Hooks.Registry, ev) end)
  Enum.each(commands, fn {name, _} -> Registry.unregister(Tau.Commands.Registry, name) end)
  Enum.each(skills,   fn {name, _} -> Registry.unregister(Tau.Skills.Registry, name) end)
end
```

`do_unload/1` threads `info` through to `unload_module/2`. `unload_entry/2` already has
`info` and passes it. The `info` map must be enriched at load time (as shown above); path-based
entries store per-module callback snapshots inside `%{path: path, modules: [...], snapshots: %{mod => info}}`.

## Tradeoffs

### Strengths

- Satisfies all three acceptance-criterion requirements: (a) and (b) on Task failure/timeout,
  (c) via snapshot fallback regardless of callback success.
- Adds timeout-resilience that no other proposal addresses: a callback that hangs does not
  stall the Loader GenServer (a GenServer stall under heavy reload is a real OTP failure mode).
- Respects the OTP "let it crash" discipline for the sub-process while keeping the Loader
  alive.
- On the happy path (module still healthy), callback queries remain live and the unregister
  logic uses fresh data — correct for the common case where module is intact but a reload
  races with unload.

### Weaknesses

- Introduces `Task.async/Task.yield/Task.shutdown` in a GenServer `handle_cast`, which
  adds a process-lifecycle complexity that is unusual in the codebase.
- The `200 ms` timeout is arbitrary; too short means false negatives on a loaded system,
  too long stalls the Loader under slow-module conditions.
- Still requires enriching the `info` map (same load-path change as Proposal 1) — the
  snapshot fallback only works if load-time callback results are stored. If they're not,
  (c) cannot be satisfied on timeout.
- `Task.async` in a GenServer callback creates an unhandled `{ref, result}` message if
  `Task.yield` returns before the Task finishes — must use `Task.yield/Task.shutdown` pair
  correctly; subtle to get right.
- Most `try/rescue _ -> []` fixes in the Elixir ecosystem do not involve a spawned process;
  a reviewer unfamiliar with this pattern may push back.

### Costs

- Adds `Task.yield/Task.shutdown` mechanics — ~10 lines more complex than Proposal 1.
- `info` map enrichment is the same scope as Proposal 1.
- One additional supervisor-level concern: if the Loader crashes mid-Task, the Task is
  orphaned (though bounded by the 200 ms timeout).
- Test surface: tests must simulate Task timeout to exercise the fallback path; this requires
  a test harness that can make callback invocations hang.

## Dependencies

- Load-time `info` enrichment (same as Proposal 1) — `register_module/1` must store
  callback results in `info`.
- `Task.yield/2` + `Task.shutdown/2` requires no additional libraries; both are in the
  Elixir stdlib.
- Path-based entries (`%{modules: [mod1, mod2, ...]}`) must store per-module snapshots;
  the `info` shape for path entries needs to be updated.

## Confidence

medium — process isolation is the correct OTP tool for a potentially-blocking call.
Confidence would be raised by verifying that `Task.async` inside a GenServer `handle_cast`
doesn't create a stray message problem (the `Task.yield/Task.shutdown` pair should drain
the mailbox, but a concrete test would confirm).

## Prior art / references

- Elixir `Task.yield/2` + `Task.shutdown/2` docs: the canonical "run with timeout, kill
  on timeout" pattern.
- OTP `gen_server` + `proc_lib:spawn_link` timeout isolation: the conceptual ancestor of
  spawning a bounded sub-process for a potentially-blocking call.
- The Loader's own `crash_safe_register/2` uses `try/rescue` rather than a process — this
  proposal diverges from that precedent, which may be seen as inconsistent.
