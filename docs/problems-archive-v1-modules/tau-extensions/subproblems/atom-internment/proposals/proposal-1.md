---
template_version: 1
template_name: proposal
proposal_id: 1
parent_problem: ../problem.md
---

# Proposal 1: Defer atom creation to post-compile — check by string, intern only on success

## Approach

Rewrite `peek_module_names/1` to return `{:ok, [String.t()]}` (bare strings, not atoms) and rewrite `compile_with_collision_guard/1` to perform the collision check using `String.to_existing_atom/1` with a guard: if the atom does not yet exist in the table, the module cannot be loaded, so the collision check returns false without interning anything. Only if `String.to_existing_atom/1` succeeds (meaning the atom is already in the table from a prior successful load) does the check proceed to `Code.ensure_loaded?/1`. Module names that have never been compiled therefore never have their atoms created during the peek phase; atoms are created only when `Code.compile_file/1` itself interns them as part of compilation.

## Rationale

The collision guard's job is to detect "is module X already loaded?" For a module that has never been compiled, the answer is trivially no — the BEAM cannot have it loaded — so there is nothing to intern. By switching to `String.to_existing_atom/1` and treating `ArgumentError` as "not loaded," the check becomes sound: it only succeeds on atoms that already exist (because a prior compilation created them), which is exactly the collision scenario. The permanent-intern side-effect is decomplected from the guard by moving it to the compiler, its only legitimate owner.

## Sketch

```elixir
# peek_module_names/1 returns strings, not atoms
defp peek_module_names(path) do
  case File.read(path) do
    {:ok, src} ->
      names =
        Regex.scan(~r/defmodule\s+([\w.]+)/, src, capture: :all_but_first)
        |> List.flatten()
        |> Enum.map(fn name -> "Elixir." <> name end)  # strings only

      {:ok, names}

    _error ->
      :error
  end
end

# collision_check/1 uses to_existing_atom — no intern on miss
defp module_already_loaded?(name_string) do
  atom = String.to_existing_atom(name_string)
  Code.ensure_loaded?(atom)
rescue
  ArgumentError -> false  # atom does not exist → module not loaded → no collision
end

defp compile_with_collision_guard(path) do
  case peek_module_names(path) do
    {:ok, name_strings} ->
      collisions = Enum.filter(name_strings, &module_already_loaded?/1)

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

No changes to `do_compile_file/1`, callers, or the `Tau.Extension` behaviour.

## Tradeoffs

### Strengths

- Zero new permanent atoms for modules that never compile successfully — the acceptance criterion is met exactly.
- Collision detection for already-loaded modules remains correct: `String.to_existing_atom/1` succeeds because the prior `Code.compile_file/1` interned the atom when that module was first loaded.
- Minimal blast radius: changes two private functions (`peek_module_names/1` and `compile_with_collision_guard/1`); the public API and all callers are untouched.
- The `rescue ArgumentError` pattern is idiomatic Elixir for this exact use case (see Elixir stdlib docs on `String.to_existing_atom/1`).
- Removes the existing Credo suppression comment (the `UnsafeToAtom` warning goes away legitimately).

### Weaknesses

- The `rescue ArgumentError` in `module_already_loaded?/1` is technically a control-flow-via-exception pattern. It is correct and idiomatic here, but violates the project's stated preference for explicit error handling over exceptions (global CLAUDE.md).
- If a future change causes `String.to_existing_atom/1` to raise something other than `ArgumentError` (unlikely in BEAM, but theoretically possible if module name is not a valid atom), the rescue clause would swallow an unexpected error as "not loaded."
- Does not guard against an adversary who first loads a legitimate extension (interning its atoms), then floods the directory with uniquely-named files to exhaust remaining atom-table capacity via the regex scan. The atom-safety guarantee only applies to names not already in the table.
- The comment at lines 270–275 ("adding atoms here is acceptable — D-123") must be updated; leaving it stale would mislead future readers.

### Costs

- Two private functions modified; no public API change.
- One existing Credo suppression comment removed.
- The comment block at lines 270–275 must be rewritten to document the new invariant.
- Test surface: the existing property test for `compile_with_collision_guard/1` that covers collision detection continues to pass; a new property test is needed to assert that `peek_module_names/1` returns strings and that processing N unique names interns zero atoms when none are pre-loaded.

## Dependencies

- No other modules to change.
- No library upgrades.
- The `String.to_existing_atom/1` + `rescue ArgumentError` pattern is available in all supported Elixir versions (1.x+).

## Confidence

Medium. The logic is sound and the pattern is idiomatic, but the `rescue`-as-control-flow concern warrants a quick prototype to confirm Credo does not flag the `rescue ArgumentError` clause as an OTP-non-negotiable violation. Would raise to high after one successful `mix credo --strict` run on the modified file.

## Prior art / references

- Elixir docs: `String.to_existing_atom/1` — explicitly documents `ArgumentError` on missing atom, treating the rescue pattern as its canonical usage.
- Erlang atom table semantics: `erlang:binary_to_existing_atom/2` — same guarantee in OTP; well-established pattern.
- SPEC-EXTENSIONS D-123 — the invariant this fix is designed to enforce.
