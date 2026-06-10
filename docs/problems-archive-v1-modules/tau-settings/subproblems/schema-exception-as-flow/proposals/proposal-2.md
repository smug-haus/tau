---
template_version: 1
template_name: proposal
proposal_id: 2
parent_problem: ../problem.md
---

# Proposal 2: Unify binary and atom clauses into a single normalise-then-check function

## Approach

Collapse the two `to_known_module/1` clauses into one by adding a private
`normalise_provider_input/1` that converts a binary to an atom (using
`String.to_existing_atom/1` — but only as an intern lookup embedded in a guard
rather than as primary control flow) OR returns `nil` for an unknown atom. The
single clause then checks `result in @known_providers` (for atoms) or `result
implements_provider?` — removing the `rescue` by making atom-absence produce
`nil` via an explicit `try` helper whose contract is clearly "returns nil on
miss". However, this still uses a `try` internally — so instead, unify around
the `@known_providers` membership test applied to both atoms and strings: a
single `Enum.find/2` that compares `Atom.to_string(mod)` against `"Elixir." <>
str` for the string case, with no atom creation at all.

Concretely: replace both clauses with one clause `to_known_module(input)` that
calls a `resolve_input/1` helper returning `{:module, mod} | :not_found`, where
`resolve_input` for atoms checks `@known_providers` membership directly, and for
strings uses `Enum.find(@known_providers, fn m -> Atom.to_string(m) == "Elixir." <> input end)`.

## Rationale

The two `to_known_module/1` clauses share an outcome type (`{:ok, mod} |
{:error, {:unknown_provider, _}}`) and a core question ("is this input a known
provider?"). Currently the binary clause reaches the answer via exception and the
atom clause via `cond`. Unifying them behind a single `resolve_input/1` helper
exposes the shared structure, makes the control flow uniform, and removes the
exception path entirely. The string comparison `Atom.to_string(m) == "Elixir." <>
str` is semantically equivalent to the current rescue-based approach but expressed
as a predicate rather than a side effect.

## Sketch

```elixir
# Single public-facing clause (or keep two guards, shared body):
defp to_known_module(input) when is_atom(input) or is_binary(input) do
  case resolve_input(input) do
    {:ok, mod} -> {:ok, mod}
    :not_found ->
      label = if is_atom(input), do: inspect(input), else: input
      {:error, {:unknown_provider, label}}
  end
end

defp resolve_input(mod) when is_atom(mod) do
  cond do
    mod in @known_providers    -> {:ok, mod}
    implements_provider?(mod)  -> {:ok, mod}
    true                       -> :not_found
  end
end

defp resolve_input(str) when is_binary(str) do
  case Enum.find(@known_providers, fn m ->
         Atom.to_string(m) == "Elixir." <> str
       end) do
    nil -> :not_found
    mod -> {:ok, mod}
  end
end
```

`Atom.to_string/1` on known provider atoms is called at most 6 times (the list
length) per lookup — acceptable for this validation path, which runs once per
settings load. No new atom is created; no exception is raised.

## Tradeoffs

### Strengths

- Removes `try`/`rescue` entirely from the binary path.
- Unifies both clauses under a shared outcome type through `resolve_input/1`,
  exposing the structural symmetry that was previously hidden.
- The string comparison `Atom.to_string(m) == "Elixir." <> str` is explicit and
  readable — the lookup mechanism is visible to any reader, unlike the atom-intern
  side-effect approach.
- `resolve_input/1` is separately testable and has a clear contract.
- Satisfies the acceptance criterion: no `rescue` or `try` in either clause.

### Weaknesses

- `Enum.find/2` + `Atom.to_string/1` per call is O(N) in the provider list
  length. Currently N=6, so this is negligible, but unlike proposal 1's O(1)
  compile-time map it scales linearly if `@known_providers` grows.
- Splitting the two-clause function into three private functions
  (`to_known_module`, `resolve_input` x 2) increases the module's private API
  surface. The change may feel like over-engineering for a 6-element list.
- The `"Elixir." <>` string concatenation appears in two places (the compile-time
  map in proposal 1 also has it, but only once). Here it appears in the
  `resolve_input/1` binary clause — a subtle coupling to Elixir's atom
  serialisation convention that must be documented.
- The `implements_provider?/1` branch (for atoms) is no longer relevant for the
  binary path, creating asymmetry: strings are strict (`@known_providers` only),
  atoms are permissive (`@known_providers` or `implements_provider?`). This
  asymmetry already exists; unification makes it more obvious, which may prompt
  further questions about whether it is intentional.

### Costs

- ~15 lines replaced by ~25 lines (3 private functions vs 2 private clauses).
  Net increase of ~10 lines.
- No test changes required — the contract exposed at `to_known_module/1` is
  identical.
- No API change, no consumer impact.

## Dependencies

- `implements_provider?/1` already defined in the same module; no external
  dependency.

## Confidence

Medium. The change is straightforward but introduces more code than necessary to
solve the acceptance criterion (proposal 1 is simpler). Confidence in correctness
is high; confidence that this is the *best* shape is medium because the unification
adds lines without a compelling forcing function beyond symmetry.

## Prior art / references

- Erlang/Elixir convention: use `Enum.find/2` over exception-based dispatch for
  closed sets. Ecto's `Type.match?/2` uses this pattern for the type registry.
- Unified input normalisation before guard dispatch: pattern in Phoenix params
  parsing (`Phoenix.Param` protocol implementation).
- The `Atom.to_string/1` round-trip for provider name comparison appears in
  `Tau.Settings.Schema.known_providers/0` callsites elsewhere in the codebase.
