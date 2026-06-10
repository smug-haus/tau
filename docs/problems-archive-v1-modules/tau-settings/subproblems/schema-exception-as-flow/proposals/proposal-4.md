---
template_version: 1
template_name: proposal
proposal_id: 4
parent_problem: ../problem.md
---

# Proposal 4: Replace the binary clause with a guard-matched multi-head function over `@known_providers`

## Approach

Use Elixir's compile-time macro machinery to generate one function clause per
known provider via `for/1` or `defmacro`, eliminating both atom creation and
data-structure lookup. Each known provider module atom contributes a head of the
form `defp to_known_module(str) when str == ^name, do: {:ok, mod}` where `name`
is the string expansion of the module name. A catch-all clause returns the error.
This is a **behaviour-preserving, incremental** change that replaces the binary
clause body only; it keeps both clauses' signatures intact and adds no new
module-level data structures.

## Rationale

Elixir's pattern matching is the idiomatic control-flow mechanism for closed
dispatch. Generating a function clause per known provider makes the dispatch
visible as code — a reader sees exactly what strings are accepted — rather than
as a runtime data lookup. No atom is created, no exception is raised, and the
`@known_providers` list remains the single source of truth via the `for/1`
comprehension. The catch-all clause makes the "not found" path as explicit as the
"found" paths.

## Sketch

```elixir
# At module body level, after the @known_providers attribute is defined:
for mod <- @known_providers do
  str_name = mod |> Atom.to_string() |> String.replace_prefix("Elixir.", "")

  defp to_known_module(unquote(str_name)), do: {:ok, unquote(mod)}
end

# Catch-all (replaces the old binary clause):
defp to_known_module(str) when is_binary(str),
  do: {:error, {:unknown_provider, str}}
```

At compile time this expands to six pattern-matched clauses (one per provider)
plus the catch-all. No map, no `Enum.find`, no `String.to_existing_atom`, no
`rescue`. The generated clauses are visible in the compiled beam (via `iex> :beam_lib`
or `mix compile --verbose`) so debugging is transparent.

Note: the original single binary clause with `rescue` is replaced entirely by the
`for`-generated clauses + catch-all. The atom clause (`is_atom(mod)`) is
unchanged.

## Tradeoffs

### Strengths

- Removes `try`/`rescue` completely — acceptance criterion satisfied.
- Uses Elixir's native pattern matching rather than a data structure; dispatch is
  by the compiler, not by a runtime `Map.fetch` or `Enum.find`.
- The generated clauses are fully visible in compiled artefacts and in `iex`
  (`__info__(:functions)` shows them).
- No new module-level data structures (`@known_provider_names` map) needed.
- Catch-all clause makes the "unknown" path syntactically parallel to the "known"
  paths — a reader can see the complete dispatch surface at a glance.

### Weaknesses

- Compile-time clause generation (`for` + `defp` inside a module body) is
  Elixir-idiomatic but uncommon in this codebase. A reader unfamiliar with the
  pattern may be surprised to find `for/1` generating function clauses in module
  scope.
- The `for/1` block and the `is_binary` catch-all must appear in the correct
  order relative to each other in the source file. If a future editor reorders
  them (e.g. puts the catch-all before the generated clauses), behaviour changes
  silently — this ordering dependency is not enforced by the compiler.
- Six generated clauses for six providers is manageable, but the pattern scales
  poorly if `@known_providers` ever becomes large (100+ providers would generate
  100+ clauses, each with a compile-time string constant, potentially impacting
  compile time).
- The `Atom.to_string/1` + `String.replace_prefix/3` expansion logic runs at
  compile time, not runtime — correct, but the same key-derivation convention
  fragility noted in proposal 1 applies here.
- Dialyzer cannot easily express the multi-head generated spec without a `@spec`
  annotation; the spec for the binary-clause group would need to be written
  manually to get full type coverage.

### Costs

- The binary clause body is replaced by a `for/1` loop (~4 lines) + a catch-all
  (~2 lines). Net: roughly the same line count.
- No test changes required.
- No API change, no consumer impact.
- Compile time: negligible for 6 providers; the macro expansion is trivial.

## Dependencies

- None. Uses only Elixir compile-time constructs already available; no new
  attributes or helpers.

## Confidence

Medium. The pattern is correct and idiomatic in Elixir (used in e.g. Plug's
router and Ecto's type adapter dispatch), but it introduces a source-order
dependency and a `for`-in-module-body construct that is uncommon in this
codebase's style. Confidence in correctness is high; confidence in style fit is
medium pending a codebase-wide search for existing `for`-in-module patterns.

## Prior art / references

- Plug Router's compile-time route clause generation (`Plug.Router` macro
  generates one `match/2` clause per route at compile time).
- Elixir `String` module's Unicode function generation: large sets of clauses
  generated from compile-time data (though at a scale that warrants the approach
  more than a 6-element list does).
- Ecto `Type` adapter multi-head dispatch: each known type generates matching
  clauses, with a catch-all for custom types.
- Elixir guide "Compile-time code generation" (official docs, §Modules and
  functions) describes the `for/1`-generates-`defp` pattern explicitly.
