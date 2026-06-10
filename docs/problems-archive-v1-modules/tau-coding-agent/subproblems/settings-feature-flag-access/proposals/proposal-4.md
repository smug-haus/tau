---
template_version: 1
template_name: proposal
proposal_id: 4
parent_problem: ../problem.md
---

# Proposal 4: Interface change — push flag resolution into SettingsCache via a dedicated with-default API

## Approach

Add a `SettingsCache.get_in/2` (or `SettingsCache.get_flag/2`) function to
`SettingsCache` that accepts a key path and a default, and returns
`{:ok, value} | {:error, :unavailable}` — removing the burden of crash
containment from every caller. Then rewrite `expose_tau_context?/0` as a
thin delegating wrapper: call `SettingsCache.get_flag([:coding_agent,
:expose_tau_context], true)` and pattern-match on the result. The rescue
ladder in `dispatcher.ex` is deleted. All crash containment lives in
`SettingsCache` where it is co-located with the process that owns the
ETS table and can make authoritative availability decisions.

Note: the problem statement says "changes to SettingsCache itself" are out
of scope. This proposal is therefore a **boundary-push** option and is
presented so the selector can explicitly reject it on scope grounds — not
presented as a recommended approach.

## Rationale

The complecting hypothesis is that crash containment is woven into feature-flag
retrieval in `dispatcher.ex`. The root cause is that `SettingsCache.get/0` has a
*failable* interface (it crashes on unavailability) but a *non-failable* calling
convention (callers expect a map). Moving the availability contract to
`SettingsCache` itself decomplects at the right abstraction level: the cache
process knows whether it is available; the Dispatcher does not. A
`{:ok, v} | {:error, :unavailable}` return from `SettingsCache` removes the
need for any rescue in callers — they pattern-match on the result instead.
This eliminates the rescue-fallback problem not only for `expose_tau_context?/0`
but for all future callers of `SettingsCache`.

## Sketch

```elixir
# lib/tau/settings/cache.ex  (out of scope per problem statement — shown for completeness)

@spec get_flag([atom() | binary()], term()) ::
  {:ok, term()} | {:error, :unavailable}
def get_flag(key_path, default) do
  case get() do
    settings when is_map(settings) ->
      value = get_in(settings, key_path) || default
      {:ok, value}
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end
end
```

```elixir
# lib/tau/coding_agent/dispatcher.ex  (modified — the only in-scope change)

defp expose_tau_context? do
  # key_path uses string key as SettingsCache may return string-keyed maps
  SettingsCache.get_flag([:coding_agent, :expose_tau_context], true)
end

defp maybe_start_tau_context(state) do
  case expose_tau_context?() do
    {:ok, true}              -> do_start_tau_context(state)
    {:ok, false}             -> state
    {:error, :unavailable}   ->
      :telemetry.execute(
        [:tau, :coding_agent, :tau_context, :settings_unavailable],
        %{system_time: System.system_time()},
        %{adapter: state.adapter}
      )
      state
  end
end
```

The `dispatcher.ex` change is a net deletion of the rescue ladder and a
pattern-match update — ~10 lines net. The `SettingsCache` change is out of
scope but required for viability.

## Tradeoffs

### Strengths

- Decomplects at the correct abstraction level: the cache owns availability
  semantics; callers own business logic.
- The in-scope change to `dispatcher.ex` is the smallest of any proposal —
  pure delegation with no rescue.
- Eliminates the rescue problem for all future callers of SettingsCache
  (not just `expose_tau_context?/0`), so it has the highest leverage.
- `SettingsCache.get_flag/2` is a general, reusable API that callers in
  `tools.ex` (sibling sub-problem) could also adopt.

### Weaknesses

- **Out of scope per problem statement.** Requires modifying `SettingsCache`,
  which the problem statement explicitly excludes. This proposal cannot be
  selected without relaxing the scope constraint.
- If `SettingsCache.get/0` already returns `{:ok, _} | {:error, _}` (rather
  than crashing), the `get_flag` wrapper is unnecessary and the rescue in the
  wrapper is dead code. Viability depends on SettingsCache's actual failure mode.
- The `get_in/2` path with atom keys may not match the string-keyed map
  SettingsCache returns; the exact key type must be verified.
- Moves the rescue from `dispatcher.ex` into `SettingsCache`, not eliminates it.
  Still violates OTP non-negotiables spirit (rule 7) at the cache layer.
- Adds a new API surface to a module declared out of scope, increasing review
  burden and risk of unintended side-effects on other callers.

### Costs

- One new function in `SettingsCache` (~12 lines) — out of scope.
- ~10 line net deletion in `dispatcher.ex`.
- Tests for `SettingsCache.get_flag/2` (new module surface).
- Tests for the three branches of `maybe_start_tau_context/1`.

## Dependencies

- `SettingsCache` must be modified — currently out of scope. Either the problem
  scope must be relaxed, or this proposal is not viable as-is.
- `SettingsCache.get/0`'s actual failure mode (crash vs `{:error, _}` return)
  must be verified before writing the `get_flag` wrapper.

## Confidence

Low (due to out-of-scope dependency). The design is sound and has the highest
leverage of the four proposals. Confidence would be medium if the scope
constraint were relaxed and the SettingsCache failure mode were confirmed.
High requires a prototype verifying the key-type issue.

## Prior art / references

- `Application.fetch_env/2` — the standard Elixir idiom for failable config
  reads returning `{:ok, v} | :error`.
- `Map.fetch/2` — same pattern at the data level.
- Phoenix `conn.assigns` patterns: callers receive `{:ok, v} | :error` from
  `Plug.Conn.fetch_*` rather than catching from raw map access.
