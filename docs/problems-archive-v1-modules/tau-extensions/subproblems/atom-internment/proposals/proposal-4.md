---
template_version: 1
template_name: proposal
proposal_id: 4
parent_problem: ../problem.md
---

# Proposal 4: API-breaking — replace peek with a module-count quota enforced at the directory level

## Approach

Remove `peek_module_names/1` and its `String.to_atom/1` call entirely. Replace the per-file pre-compile collision check with a **directory-level module quota** enforced before any compilation begins: scan the extension directory for `.ex` files, count the `defmodule` occurrences using the same regex but without converting them to atoms (a raw integer count), and reject the entire directory load if the count exceeds a configurable `@max_extension_modules` limit. For collision detection, replace the pre-compile atom-based check with a post-compile registry comparison: after `Code.compile_file/1` returns, compare the returned module atoms against a snapshot of the known extension registry taken before the load cycle. This is an API-breaking change because `compile_with_collision_guard/1`'s internal contract changes and the public-facing load-cycle behavior changes (directory rejected as a unit rather than individual files skipped).

## Rationale

Both the pre-compile atom-intern problem and the collision-check mechanism share a common root: the attempt to answer "what will this file define?" before compiling it, using an approximation (regex + atom). This proposal rejects the approximation entirely. Atom exhaustion via `defmodule` counts is a volume attack; volume attacks are best stopped at the entry point with a hard cap rather than with per-name checks. Collision detection is more accurately done post-compile against real registry state than pre-compile against a speculative atom list. The result is simpler: no pre-compile scan, no atom creation, two independent concerns handled by two independent mechanisms.

## Sketch

```elixir
# Module-count cap: refuse to load a directory whose files declare more than
# this many defmodule forms in total. Configurable via application env.
@max_extension_modules Application.compile_env(:tau, [:extensions, :max_modules], 100)

# count_declared_modules/1 — pure integer count; no atom creation
@spec count_declared_modules([Path.t()]) :: non_neg_integer()
defp count_declared_modules(paths) do
  Enum.reduce(paths, 0, fn path, acc ->
    case File.read(path) do
      {:ok, src} ->
        acc + length(Regex.scan(~r/defmodule\s+[\w.]+/, src))
      _error ->
        acc
    end
  end)
end

# quota_ok?/1 — enforce the directory-level cap before any compilation
@spec quota_ok?([Path.t()]) :: :ok | {:error, :quota_exceeded, non_neg_integer()}
defp quota_ok?(paths) do
  count = count_declared_modules(paths)

  if count <= @max_extension_modules do
    :ok
  else
    {:error, :quota_exceeded, count}
  end
end

# load_entry/1 (modified excerpt) — quota check before compilation loop
defp load_entry({:ok, dir, paths}) do
  case quota_ok?(paths) do
    :ok ->
      pre_loaded_mods = MapSet.new(Map.keys(existing_registry_snapshot()))

      registered =
        Enum.flat_map(paths, fn path ->
          compiled = do_compile_file(path)
          {collisions, new_mods} = Enum.split_with(compiled, &MapSet.member?(pre_loaded_mods, &1))

          if collisions != [] do
            Logger.warning(
              "Tau.Extensions.Loader: purging #{path} — module name collision: " <>
                inspect(collisions)
            )
            Enum.each(compiled, fn m -> :code.purge(m); :code.delete(m) end)
            []
          else
            Enum.flat_map(new_mods, fn mod ->
              crash_safe_register(mod, dir_key(dir))
            end)
          end
        end)

      {:ok, dir, %{path: dir, modules: registered}}

    {:error, :quota_exceeded, count} ->
      Logger.error(
        "Tau.Extensions.Loader: refusing to load #{dir} — " <>
          "#{count} defmodule declarations exceed the limit of #{@max_extension_modules}. " <>
          "Split the extension or raise :max_modules in config."
      )
      :telemetry.execute([:tau, :extensions, :quota_exceeded], %{count: count}, %{dir: dir})
      :error
  end
end

# peek_module_names/1 — DELETED
# String.to_atom("Elixir." <> name) call — DELETED
# compile_with_collision_guard/1 — DELETED (replaced inline in load_entry)
```

`existing_registry_snapshot/0` queries whatever ETS table backs the extension
registry before the load cycle; its implementation depends on the registry
internals (not changed by this proposal).

## Tradeoffs

### Strengths

- Eliminates `String.to_atom/1` entirely — zero atom internment from the peek path under any scenario.
- The directory-level quota is a volume-attack defence that scales with the attack surface (number of `defmodule` declarations) rather than trying to check each one.
- No `rescue`-as-control-flow anywhere in the modified path.
- Post-compile collision detection is exact rather than approximate (same strength as proposal 2).
- The quota failure mode is explicit and tagged (`{:error, :quota_exceeded, count}`), not silently absorbed.
- Telemetry event on quota breach provides observability.

### Weaknesses

- **API-breaking**: `compile_with_collision_guard/1` is deleted and its logic is merged into `load_entry/1`; any tests that call `compile_with_collision_guard/1` directly must be updated.
- The quota cap is a blunt instrument: a legitimate extension with 101 modules (unlikely but possible) would be rejected regardless of atom-table state. The cap is a policy choice, not a technical necessity.
- Post-compile purge via `:code.purge/1` has the same atomicity and lingering-process caveats as proposal 2.
- `count_declared_modules/1` reads all `.ex` files a second time (already read during compilation), doubling file I/O. For large extension directories, this is measurable.
- `existing_registry_snapshot/0` must be called before the load cycle and its implementation is not detailed here — the actual registry lookup mechanism needs to be confirmed to be snapshotable.
- Removes a tested unit (`compile_with_collision_guard/1`) and merges its logic into `load_entry/1`, which reduces test isolation.

### Costs

- `peek_module_names/1` deleted.
- `compile_with_collision_guard/1` deleted.
- `count_declared_modules/1` added (~12 lines).
- `quota_ok?/1` added (~10 lines).
- `load_entry/1` significantly modified — the most disruptive change of the four proposals.
- Two new telemetry events: `[:tau, :extensions, :quota_exceeded]`.
- Test surface: existing `compile_with_collision_guard/1` tests need porting to test the new inline logic in `load_entry/1`; new tests needed for `count_declared_modules/1` and `quota_ok?/1`.
- SPEC-EXTENSIONS D-123 must record the quota parameter and the changed load-cycle contract.
- The `@max_extension_modules` default of 100 is an arbitrary policy decision — it should be documented as such and reviewed with the product owner.

## Dependencies

- The ETS registry backing `Tau.Extensions.Loader` must expose a snapshotable view before the load cycle begins. If it does not, the pre-loaded snapshot approach from proposal 2's alternative sketch applies instead.
- `:code.purge/1` / `:code.delete/1` — Erlang/OTP 27.2 BIFs, no new deps.
- `Application.compile_env/3` for the `@max_extension_modules` cap.
- The quota default (100) should be validated against real-world extension directories.

## Confidence

Low-medium. The core approach (delete peek, add quota, post-compile collision) is sound, but the blast radius — deleting `compile_with_collision_guard/1`, modifying `load_entry/1`, adding a registry snapshot — is larger than the other proposals, and the `existing_registry_snapshot/0` dependency introduces uncertainty. Would raise to medium after confirming the registry is snapshotable and after a prototype that exercises the purge path under concurrent load.

## Prior art / references

- Rate-limiting / quota patterns in extension systems (VS Code extension validation, Ruby gem security scans) — domain-level quota on declaration count is an established entry-point defence.
- OTP `:code.purge/1` / `:code.delete/1` documentation.
- Erlang `:telemetry` — `[:tau, :extensions, ...]` namespace per OTP non-negotiables §5.
- SPEC-EXTENSIONS D-123 — the invariant this fix enforces.
