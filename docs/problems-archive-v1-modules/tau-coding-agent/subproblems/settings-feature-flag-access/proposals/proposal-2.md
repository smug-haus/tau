---
template_version: 1
template_name: proposal
proposal_id: 2
parent_problem: ../problem.md
---

# Proposal 2: Eliminate the rescue entirely — let SettingsCache failure propagate to the Dispatcher supervisor

## Approach

Remove the `try/rescue/catch` block in `expose_tau_context?/0` entirely.
Call `SettingsCache.get/0` directly. If the cache is absent or crashes, the
exception propagates up the call stack through `maybe_start_tau_context/1` into
the Dispatcher GenServer's callback, which triggers the OTP supervisor restart
cycle. The Dispatcher already has a supervisor (`Tau.CodingAgent.Supervisor` or
equivalent); letting the crash propagate to it is the correct OTP behaviour when
a required dependency is unavailable at callback time.

## Rationale

The OTP non-negotiables (rule 7) state: "Let it crash; supervise; restart." The
rescue in `expose_tau_context?/0` is a manual crash-containment fence that
pre-empts the supervisor. The complecting is at the decision layer: the function
cannot distinguish crash from absence because it absorbs both. Removing the
rescue does not add a new mechanism — it removes the one that hides information.
If SettingsCache is unavailable, the Dispatcher's `handle_continue/2` or
`handle_call/3` crashes and is restarted; supervision handles the recovery.
Starting an MCP server with an unknown settings state is worse than crashing and
restarting before the MCP server is started at all.

## Sketch

```elixir
# lib/tau/coding_agent/dispatcher.ex
# Before: rescue/catch ladder returning %{} on failure.
# After: direct call, no rescue.

defp expose_tau_context? do
  SettingsCache.get()
  |> Map.get(:coding_agent, %{})
  |> case do
    %{} = ca -> Map.get(ca, :expose_tau_context, Map.get(ca, "expose_tau_context", true))
    _ -> true
  end
end
```

The call chain is:

```
Dispatcher.handle_continue(:start_tau_context, state)
  └── maybe_start_tau_context(state)
        └── expose_tau_context?()
              └── SettingsCache.get()   # may raise if process absent
                    [raise propagates to handle_continue]
                    [OTP supervisor restarts Dispatcher]
```

The supervisor restart strategy (`:one_for_one` or `:one_for_all` depending on
`Tau.CodingAgent.Supervisor`) determines recovery semantics. No code change to
the supervisor is required; the change is purely a deletion in `dispatcher.ex`.

## Tradeoffs

### Strengths

- The most direct expression of the OTP non-negotiables: no rescue at all is
  cleaner than a rescue that returns a structured error.
- No new code paths, no new types, no new modules — a net deletion of ~8 lines.
- Makes the Dispatcher's dependency on SettingsCache explicit: if the cache is
  not running, the Dispatcher crashes visibly rather than proceeding silently
  with an unknown default.
- The supervisor restart strategy already governs recovery; this change makes
  existing supervision infrastructure do real work.

### Weaknesses

- Crashes the entire Dispatcher process if SettingsCache is transiently absent
  (e.g. during supervised startup ordering). If the Dispatcher is restarted
  before SettingsCache is up, it will crash again, potentially hitting the max
  restart intensity and permanently stopping the Dispatcher for the session.
- `maybe_start_tau_context/1` is called in a GenServer callback; crashing there
  terminates the current in-flight coding-agent run, not just the TauContext
  startup. This may be a disproportionate failure for what could be a transient
  cache unavailability.
- If the supervisor's restart intensity is low, a sequence of cache-absent
  sessions will exhaust restarts and stop the subsystem permanently until
  the application restarts — a harder failure than silently skipping TauContext.
- Requires verifying the supervisor restart strategy and intensity for
  `Tau.CodingAgent.Dispatcher` before merging; a crash loop could affect
  unrelated concurrent runs sharing the supervisor.

### Costs

- Net ~8 line deletion in `dispatcher.ex`.
- Tests must be updated: any test that mocks SettingsCache absence and expects
  `expose_tau_context?` to return `true` will now see a crash instead; tests
  must be restructured to either mock SettingsCache as present or test the
  crash path.
- Requires understanding and verifying the supervisor restart policy — a
  non-local concern that adds review surface.

## Dependencies

- The Dispatcher must be under a supervisor that allows it to crash and restart
  without blocking other subsystems. Verify `Tau.CodingAgent.Supervisor` restart
  strategy before merging.
- SettingsCache must be started before the Dispatcher in the supervision tree;
  if the tree currently allows Dispatcher to start before SettingsCache, startup
  ordering must be confirmed or adjusted (in `application.ex`, not in
  `SettingsCache` itself).

## Confidence

Low. The approach is principled but the consequences depend on the supervisor
topology (restart strategy, intensity, whether Dispatcher is `:one_for_one`
with other concurrent agents) — which requires reading `application.ex` and
the Supervisor spec. Without that verification, the risk of a crash loop
degrading the system is real. Confidence would be medium after topology
verification; high only if startup ordering is proven to guarantee SettingsCache
precedes Dispatcher.

## Prior art / references

- OTP non-negotiables rule 7: "Let it crash; supervise; restart. MUST NOT
  try/rescue across process boundaries."
- Elixir/OTP GenServer crash-and-restart pattern is the canonical recovery
  mechanism for unavailable dependencies.
