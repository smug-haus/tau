---
template_version: 1
template_name: proposal
proposal_id: 1
parent_problem: ../problem.md
---

# Proposal 1: Tagged-result return — expose_tau_context?/0 becomes fetch_expose_tau_context/0 returning {:ok, bool} | {:error, :cache_unavailable}

## Approach

Replace `expose_tau_context?/0`'s `try/rescue/catch` fallback with a function
that returns a tagged tuple: `{:ok, true}`, `{:ok, false}`, or
`{:error, :cache_unavailable}`. Rename to `fetch_expose_tau_context/0` to make
the fallibility explicit. Update `maybe_start_tau_context/1` to pattern-match on
the three cases: start context on `{:ok, true}`, skip on `{:ok, false}`, and on
`{:error, :cache_unavailable}` emit a telemetry event and skip (fail-closed,
not fail-open).

## Rationale

The complecting hypothesis is that crash containment is woven into feature-flag
retrieval; both produce the same `true` return, making the two indistinguishable.
A tagged tuple structurally separates the two concerns: the retrieval result
encodes what happened (configured vs unavailable), and the caller decides what
to do for each case. The boolean predicate form (`?`) is idiomatic for a pure
query with no failure modes; replacing it with a tagged-result form (`fetch_*`)
signals at the type level that the call is failable. Fail-closed on
`:cache_unavailable` fixes the silent-enable-on-failure defect: a system that
cannot read its settings does not start the MCP server.

## Sketch

```elixir
# lib/tau/coding_agent/dispatcher.ex

@spec fetch_expose_tau_context() ::
  {:ok, boolean()} | {:error, :cache_unavailable}
defp fetch_expose_tau_context do
  case SettingsCache.get() do
    settings when is_map(settings) ->
      value =
        settings
        |> Map.get(:coding_agent, %{})
        |> case do
          %{} = ca -> Map.get(ca, :expose_tau_context, Map.get(ca, "expose_tau_context", true))
          _ -> true
        end
      {:ok, value}
  rescue
    _ -> {:error, :cache_unavailable}
  catch
    _, _ -> {:error, :cache_unavailable}
  end
end

defp maybe_start_tau_context(state) do
  case fetch_expose_tau_context() do
    {:ok, true} ->
      do_start_tau_context(state)

    {:ok, false} ->
      state

    {:error, :cache_unavailable} ->
      :telemetry.execute(
        [:tau, :coding_agent, :tau_context, :settings_unavailable],
        %{system_time: System.system_time()},
        %{adapter: state.adapter}
      )
      state
  end
end

# private helper used by {:ok, true} branch above
defp do_start_tau_context(state) do
  args = [
    owner: self(),
    session_id: Map.get(state.ctx, :session_id),
    cwd: Map.get(state.task, :workspace),
    max_depth: Map.get(state.ctx, :tau_context_max_depth, 2)
  ]

  case TauContext.start_link(args) do
    {:ok, pid} ->
      entry = TauContext.mcp_servers_entry(pid)
      existing = state.task |> Map.get(:mcp_servers, []) |> List.wrap()
      task = Map.put(state.task, :mcp_servers, [entry | existing])
      %{state | task: task, tau_context_pid: pid}

    {:error, reason} ->
      :telemetry.execute(
        [:tau, :coding_agent, :tau_context, :start_failed],
        %{system_time: System.system_time()},
        %{reason: reason, adapter: state.adapter}
      )
      state
  end
end
```

## Tradeoffs

### Strengths

- Directly addresses the acceptance criterion: caller can distinguish all three
  cases (`true`, `false`, `unavailable`) without interpreting a bare boolean.
- Minimal scope: changes are confined to `dispatcher.ex`; no new modules, no
  interface changes visible outside the file.
- Behaviour-correcting at the right boundary: fail-closed on cache failure
  without requiring supervision restructure.
- Telemetry added for the `:cache_unavailable` branch gives observability
  without exposing the error to callers.
- The `rescue`/`catch` ladder is preserved but now returns a distinguishable
  value rather than silently mapping to the same default.

### Weaknesses

- Still uses `rescue`/`catch` — does not fully satisfy the spirit of the OTP
  non-negotiables (rule 7: "Let it crash"). Structurally the error is still
  swallowed at this level rather than propagated to a supervisor.
- Callers of `maybe_start_tau_context/1` remain unchanged; the error is never
  visible beyond the private call chain, so no upstream caller can react to or
  log a persistent cache failure.
- If SettingsCache is genuinely down for an extended period, every coding-agent
  run silently skips TauContext with only a telemetry event — no alerting
  mechanism beyond what the telemetry consumer does.
- Does not eliminate the rescue itself; a future refactor of SettingsCache
  to return `{:ok, _} | {:error, _}` would make the rescue dead code and
  require a follow-up cleanup.

### Costs

- ~30 lines changed in `dispatcher.ex`; no new files.
- Tests for `maybe_start_tau_context/1` need a new case: "returns state
  unchanged + fires telemetry when SettingsCache raises".
- No migration cost for external callers; both functions are private.

## Dependencies

- None. `SettingsCache` is not modified; its current crash-on-absence behaviour
  is the trigger for the `{:error, :cache_unavailable}` branch.

## Confidence

Medium. The sketch is complete and the types are clear. Confidence would be
high if a test confirmed that SettingsCache.get/0 actually raises (rather than
returning an error tuple) when the process is absent — the current rescue
arms may be correct or may be dead code depending on SettingsCache's actual
failure mode.

## Prior art / references

- Elixir convention: `fetch_*` prefix for failable reads returning `{:ok, v} |
  {:error, reason}` (see `Map.fetch/2`, `Keyword.fetch/2`).
- `Tau.CircuitBreaker` façade uses tagged tuples at every public boundary
  (`SPEC-CIRCUIT-BREAKER §4`).
