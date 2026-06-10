---
template_version: 1
template_name: proposal
proposal_id: 2
parent_problem: ../problem.md
---

# Proposal 2: Eliminate peek entirely — use post-compile collision detection

## Approach

Remove `peek_module_names/1` and the pre-compile collision check from `compile_with_collision_guard/1` entirely. Replace the guard with a post-compile check: call `Code.compile_file/1`, then compare the returned module list against the existing registry to detect collisions. On collision, log the warning and purge the newly-loaded modules via `:code.purge/1` and `:code.delete/1`. This eliminates the atom-internment problem at its root by eliminating the pre-compile scan that caused it — no regex scan, no `String.to_atom/1`, no atom creation prior to compilation.

## Rationale

The pre-compile peek exists to avoid clobbering already-loaded modules. But the BEAM's `:code` server already tracks loaded modules; a post-compile registry comparison is a strictly more accurate collision signal than a regex-derived prediction. The complected side-effect (atom internment) disappears because the peek function disappears. Module names are only ever interned by `Code.compile_file/1` itself, which is unavoidable and correct — the BEAM must intern a module's name to define it. Post-compile purge is safe because the module has not yet been inserted into the extension registry.

## Sketch

```elixir
# compile_with_collision_guard/1 — post-compile collision detection; no peek
defp compile_with_collision_guard(path) do
  compiled = do_compile_file(path)

  collisions =
    Enum.filter(compiled, fn mod ->
      # Check the registry state BEFORE this load cycle started.
      # @already_loaded is passed in from the call site (see below),
      # or we query the registry directly:
      Registry.lookup(Tau.Extensions.Registry, mod) != []
    end)

  if collisions != [] do
    Logger.warning(
      "Tau.Extensions.Loader: purging #{path} — module name collision: " <>
        inspect(collisions) <>
        ". A prior extension already defined these modules. " <>
        "Rename the conflicting module(s) to avoid a silent BEAM clobber."
    )

    Enum.each(compiled, fn mod ->
      :code.purge(mod)
      :code.delete(mod)
    end)

    []
  else
    compiled
  end
end

# peek_module_names/1 — DELETED
# String.to_atom("Elixir." <> name) call — DELETED
```

The `do_compile_file/1` helper is unchanged. The `compile_with_collision_guard/1`
call site in `load_entry/1` is unchanged — it still receives the path and returns
a list of atoms.

For the registry check, the simplest implementation queries `Code.ensure_loaded?/1`
on each compiled module against a snapshot of what was loaded *before* this load
cycle:

```elixir
# Alternative: snapshot-based collision check
defp compile_with_collision_guard(path, pre_loaded_mods) do
  compiled = do_compile_file(path)
  collisions = Enum.filter(compiled, &MapSet.member?(pre_loaded_mods, &1))

  if collisions != [] do
    # ... log + purge as above
    []
  else
    compiled
  end
end

# Caller snapshots before the load cycle:
pre_loaded = :code.all_loaded() |> Enum.map(&elem(&1, 0)) |> MapSet.new()
Enum.flat_map(paths, &compile_with_collision_guard(&1, pre_loaded))
```

## Tradeoffs

### Strengths

- Eliminates the atom-internment problem at its source: no pre-compile scan, no `String.to_atom/1` call, no atom leak.
- More accurate collision detection: uses what is actually loaded rather than a regex prediction. The current approach can miss a collision if the `defmodule` line is inside a quote block or a macro; the post-compile approach is exact.
- Removes `peek_module_names/1` entirely — less code, fewer moving parts.
- No `rescue`-as-control-flow; purge path uses explicit `{:ok, _} | :error` style if wrapped.

### Weaknesses

- Compilation is not free: the file is compiled (JIT'd and loaded into the BEAM) before the collision is detected. The existing approach skipped compilation on collision; this approach always pays the compile cost.
- Post-compile purge via `:code.purge/1` / `:code.delete/1` is correct but not atomic. A concurrent process that somehow obtains a reference to the module between compile and purge could receive a stale code reference. In practice, the extension loader is single-process, but the guarantee is weaker than never loading the module at all.
- `:code.purge/1` returns `false` if there are lingering processes running old code; this case must be handled explicitly or the module is not cleanly removed.
- The snapshot approach (`pre_loaded_mods`) requires a small API change at the call site in `load_entry/1` — the `compile_with_collision_guard/1` signature changes arity.
- Does not prevent atom exhaustion from the extension's own compilation creating atoms for its module names — but this is unavoidable: any approach that compiles the file will intern those atoms.

### Costs

- `peek_module_names/1` deleted (~15 lines).
- `compile_with_collision_guard/1` rewritten (~25 lines net).
- If snapshot approach is chosen: `load_entry/1` updated to pass `pre_loaded_mods`.
- `:code.purge/1` / `:code.delete/1` are Erlang BIFs — no new dependencies.
- Test surface: collision-detection property tests must be updated; the "peek returns string" test from proposal 1 is not needed but a "post-compile purge cleans modules" test is.
- The behaviour change (compilation-then-purge instead of skip-before-compile) must be documented in SPEC-EXTENSIONS D-123.

## Dependencies

- No library changes.
- Requires confirming that `:code.purge/1` behaviour in Erlang/OTP 27.2 is as expected (it is; the API is stable).
- The `Tau.Extensions.Registry` module (or equivalent lookup mechanism) must be queryable before the load cycle begins; if the registry is only queryable after `crash_safe_register/2`, the snapshot approach is preferred.

## Confidence

Medium. The purge-based approach is well-established in hot-code-loading contexts, but using it in an extension loader is a less-common pattern. The `:code.purge/1` `false` return on lingering processes is a known rough edge. Would raise to high after a prototype that exercises the purge path under concurrent load.

## Prior art / references

- OTP `:code` module documentation — `:code.purge/1`, `:code.delete/1` semantics and return values.
- Elixir `Code.compile_file/2` documentation — documents return value `[{module, binary}]`.
- Erlang hot code loading discipline — load, check, purge pattern is established in release handler.
