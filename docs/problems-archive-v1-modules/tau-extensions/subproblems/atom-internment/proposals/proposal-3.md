---
template_version: 1
template_name: proposal
proposal_id: 3
parent_problem: ../problem.md
---

# Proposal 3: Change peek's return type — strings throughout, atom created once at guard site with arity guard

## Approach

Keep `peek_module_names/1` as a pure string-extraction function (returns `{:ok, [String.t()]}`) and introduce a new private function `name_collision?/1` that accepts a string, calls `:erlang.binary_to_existing_atom(name_string, :utf8)` (the OTP primitive, not the Elixir wrapper) directly, and returns `true` only when the atom exists AND `Code.ensure_loaded?/1` returns true. Wrap the `:erlang` call in a `case` on the atom-table result rather than a `rescue` block, by using the `:erlang.binary_to_existing_atom/2` variant that returns `{:ok, atom} | error` — except that primitive does not exist. Instead, introduce a narrow NIF-free guard using `:erlang.is_atom/1` and the atom-table check via the documented `:erlang.system_info(:atom_count)` delta to enforce a hard ceiling: if the atom count is within a configurable `@atom_headroom` of the limit, the loader refuses to process any further files and logs a clear error. This is an independent safety net distinct from the core fix.

The core fix: `peek_module_names/1` returns strings; `compile_with_collision_guard/1` calls `name_collision?(string)` which wraps `String.to_existing_atom/1` (Elixir) in a structured helper that returns `{:collision, atom} | :no_collision`; the atom is only created if it already exists. This is similar to proposal 1 but extracted into a named, testable helper with an explicit return type and an additional atom-budget guard.

## Rationale

Proposal 1 solves the core problem but leaves the `rescue ArgumentError` inline in the calling function. Extracting the guard into `name_collision?/1` gives it an explicit type contract (`{:collision, atom} | :no_collision`) that the selector and future readers can reason about without parsing rescue logic. The atom-budget guard (check `:erlang.system_info(:atom_count)` vs `:erlang.system_info(:atom_limit)`) adds a defence-in-depth layer that fires even if some future code path reintroduces atom creation — it is a runtime enforcement of D-123's spirit, not just a local fix.

## Sketch

```elixir
# Configurable headroom: refuse to process files when fewer than this many
# atom slots remain. Default: 10_000.
@atom_headroom Application.compile_env(:tau, [:extensions, :atom_headroom], 10_000)

# peek_module_names/1 — returns strings only; no atom creation
defp peek_module_names(path) do
  case File.read(path) do
    {:ok, src} ->
      names =
        Regex.scan(~r/defmodule\s+([\w.]+)/, src, capture: :all_but_first)
        |> List.flatten()
        |> Enum.map(fn name -> "Elixir." <> name end)

      {:ok, names}

    _error ->
      :error
  end
end

# name_collision?/1 — explicit return type; no intern on miss
@spec name_collision?(String.t()) :: {:collision, atom()} | :no_collision
defp name_collision?(name_string) do
  case String.to_existing_atom(name_string) do
    atom when is_atom(atom) ->
      if Code.ensure_loaded?(atom), do: {:collision, atom}, else: :no_collision
  end
rescue
  ArgumentError -> :no_collision
end

# atom_budget_ok?/0 — defence-in-depth guard
defp atom_budget_ok? do
  limit = :erlang.system_info(:atom_limit)
  count = :erlang.system_info(:atom_count)
  limit - count >= @atom_headroom
end

# compile_with_collision_guard/1 — uses name_collision?/1 and atom_budget_ok?/0
defp compile_with_collision_guard(path) do
  unless atom_budget_ok?() do
    Logger.error(
      "Tau.Extensions.Loader: atom table near capacity " <>
        "(#{:erlang.system_info(:atom_count)}/#{:erlang.system_info(:atom_limit)}); " <>
        "refusing to load #{path}"
    )

    :telemetry.execute([:tau, :extensions, :atom_budget_exceeded], %{count: :erlang.system_info(:atom_count)}, %{path: path})
    return []
  end

  case peek_module_names(path) do
    {:ok, name_strings} ->
      collisions =
        name_strings
        |> Enum.map(&name_collision?/1)
        |> Enum.filter(&match?({:collision, _}, &1))
        |> Enum.map(fn {:collision, atom} -> atom end)

      if collisions != [] do
        Logger.warning(
          "Tau.Extensions.Loader: skipping #{path} — module name collision: " <>
            inspect(collisions) <>
            ". A prior extension already defined these modules. " <>
            "Rename the conflicting module(s) to avoid a silent BEAM clobber."
        )
        []
      else
        do_compile_file(path)
      end

    :error ->
      do_compile_file(path)
  end
end
```

Note: `return []` above is pseudocode for an early return; in Elixir this would be a nested `if/case` — the actual implementation uses idiomatic early-branch returns.

## Tradeoffs

### Strengths

- Zero new permanent atoms for never-compiled modules — acceptance criterion met.
- `name_collision?/1` has an explicit, typed return (`{:collision, atom} | :no_collision`) — easier to unit-test and reason about than an inline rescue.
- The atom-budget guard provides a defence-in-depth backstop that fires even if a future code path reintroduces atom creation. It also adds observability via telemetry.
- Removes the Credo `UnsafeToAtom` suppression legitimately.
- The `@atom_headroom` compile-env parameter lets operators tune the threshold without a code change.

### Weaknesses

- More code than proposal 1: adds `name_collision?/1`, `atom_budget_ok?/0`, and a telemetry event — roughly 20 extra lines for a local fix.
- The atom-budget guard fires on total atom count, not extension-load-specific atom count; a burst of non-extension activity (e.g. dynamic module generation elsewhere) could trigger the guard spuriously.
- `:erlang.system_info(:atom_count)` includes atoms created by the VM itself and all libraries; the `@atom_headroom` value is empirical, not derivable from first principles. The default of 10_000 may be too conservative or too permissive depending on workload.
- Still uses `rescue ArgumentError` internally in `name_collision?/1` (the same control-flow-via-exception concern as proposal 1, but one level removed).
- The atom-budget guard's `return []` silently drops extensions rather than returning a tagged error to the caller; callers cannot distinguish "skipped for budget" from "skipped for collision" from the return value alone — only the log message differentiates them.

### Costs

- Three private functions modified/added.
- One `Application.compile_env/3` call at module level (compile-time config).
- One new telemetry event: `[:tau, :extensions, :atom_budget_exceeded]` — must be added to SPEC-EXTENSIONS if the spec governs telemetry namespace.
- Test surface: `name_collision?/1` is independently testable; the atom-budget guard needs a test that mocks `:erlang.system_info` or temporarily exhausts the table (difficult; property test recommended).
- The comment at lines 270–275 must be updated.

## Dependencies

- No library changes.
- `Application.compile_env/3` requires that the application is configured at compile time if a non-default headroom is desired; runtime config would require a different pattern.
- SPEC-EXTENSIONS §3 / §4 should record the `@atom_headroom` parameter and the telemetry event.

## Confidence

Medium. The core fix (strings + `name_collision?/1`) is sound. The atom-budget guard adds value but introduces a new configuration surface that needs operational validation. Would raise to high after a prototype with configurable headroom tested under a synthetic atom-pressure workload.

## Prior art / references

- OTP `:erlang.system_info(:atom_count)` / `:atom_limit` — documented in OTP `erlang` module; used in production systems to monitor atom table pressure.
- Elixir `Application.compile_env/3` — compile-time config idiom; well-established.
- SPEC-EXTENSIONS D-123 — the invariant this fix enforces.
- Erlang `:telemetry` — the telemetry pattern for atom-budget events follows `[:tau, ...]` namespace convention per OTP non-negotiables §5.
