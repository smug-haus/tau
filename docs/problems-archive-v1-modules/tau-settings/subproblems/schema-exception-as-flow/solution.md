---
template_version: 1
template_name: solution
parent_problem: problem.md
node_kind: leaf
synthesised_from: [proposals/proposal-1.md]
selection_method: single
revision: 0
---

# Solution: Compile-time string-to-module map replaces try/rescue in binary clause

## Recommendation

Replace the `try/rescue ArgumentError` binary clause of `to_known_module/1` with
a `case Map.fetch(@known_provider_names, str)` call, where `@known_provider_names`
is a compile-time module attribute built from `@known_providers` by stripping
the `"Elixir."` prefix from each atom's string form. The "unknown provider" result
becomes an ordinary `:error` branch; no atom is created at runtime; no exception
is raised. The atom clause and the rest of `Schema` are untouched.

## Selected from

- **Chosen:** `proposals/proposal-1.md`
- **Why chosen:** Proposal 1 satisfies the acceptance criterion with the minimum
  possible change: one new compile-time attribute (~5 lines), one simplified
  clause body (~4 lines), and zero test changes. It achieves deep decomplecting —
  the domain question "is this a known provider?" is answered entirely by the
  module's own `@known_provider_names` data, not the VM atom-intern mechanism —
  while incurring only a low migration cost (single callsite, no API surface
  change) and low risk (key-derivation is validated by existing tests, which
  exercise the "rejects unknown providers" path). It is fully reversible: the
  before/after diff is small and contained.

  Proposals 2 and 4 both satisfy the acceptance criterion but are inferior on the
  relevant axes. Proposal 2 (O(N) `Enum.find` + unification into three private
  functions) adds lines and complexity without a forcing function — the structural
  symmetry it exposes is real but not required by the problem. Proposal 4 (compile-
  time `for`-generated clauses) introduces a source-order dependency between the
  generated clauses and the catch-all; this is a latent ordering hazard that
  exceeds the problem's scope and brings no advantage over a map fetch for a
  6-element closed set. Proposal 3 (public `provider_from_string/1`) satisfies the
  criterion but extends the module's public API surface without evidence of external
  callers — speculative benefit at non-trivial maintenance cost. Proposal 1 is
  simpler, reversible, and decomplects as deeply as any other option.

## Scoring

| #  | Fit        | Decomplecting depth | Migration cost | Risk   | Reversibility |
|----|------------|---------------------|----------------|--------|---------------|
| 1  | Yes        | Deep                | Low            | Low    | Easy          |
| 2  | Yes        | Deep                | Low            | Low    | Easy          |
| 3  | Yes        | Deep                | Low            | Low    | Easy          |
| 4  | Yes        | Deep                | Low            | Medium | Easy          |

All four proposals achieve Deep decomplecting (the exception-as-flow complect is
fully removed in every case). Fit and migration cost are identical. The
differentiator is Risk + whether the change introduces additional surface area or
fragility beyond what the problem requires. Proposal 4's source-order dependency
raises its risk to Medium. Proposals 2 and 3 are equally safe as Proposal 1 but
do more work than the problem asks for (Proposal 2: unnecessary unification;
Proposal 3: speculative public API). Proposal 1 is the minimal, clean solution.

## What changes

- `lib/tau/settings/schema.ex`: add `@known_provider_names` module attribute
  computing `Map.new(@known_providers, fn mod -> {Atom.to_string(mod) |> String.replace_prefix("Elixir.", ""), mod} end)`.
- `lib/tau/settings/schema.ex`: replace the binary clause body of `to_known_module/1`
  (currently `try do … rescue ArgumentError`) with `case Map.fetch(@known_provider_names, str) do {:ok, mod} -> {:ok, mod}; :error -> {:error, {:unknown_provider, str}} end`.

## What does not change

- The atom clause of `to_known_module/1` (lines 282–288; already correct).
- The public API of `Tau.Settings.Schema` — no new public functions.
- `test/tau/settings/schema_test.exs` — existing tests cover the changed path without modification.
- `resolve_fallback_chains/1` and all call-sites.
- The `@known_providers` attribute definition — it is the unchanged source of truth.
- `@schema`, `json_schema/0`, `Loader.merge/2`, `Settings.Watcher` — all out of scope.

## Migration sketch

The change is a single-function edit at one callsite. Introduce the
`@known_provider_names` attribute immediately after `@known_providers` (so the
attribute-definition order is clear), then replace the binary-clause body. Run
`mix test test/tau/settings/schema_test.exs` to verify existing tests pass, then
`mix compile --warnings-as-errors` to confirm no new warnings. No phased rollout
is required.

## Open questions

- **Key-derivation convention:** the map strips `"Elixir."` to produce keys like
  `"Tau.Providers.Anthropic"`. This must match what users actually write in
  `.tau/settings.json`. The existing tests exercise known-good strings; if any
  user-facing documentation describes short-form provider names (e.g. `"Anthropic"`
  rather than `"Tau.Providers.Anthropic"`), those forms would silently fail with
  this implementation — exactly as they would with the current rescue-based
  implementation. Verify the documented provider name format before landing.
- **Future provider names:** a provider in a deeper namespace (e.g.
  `Tau.Providers.Foo.Bar`) produces the key `"Tau.Providers.Foo.Bar"`. The key-
  derivation comment in the attribute definition should state this convention
  explicitly so future contributors know what string to use when configuring a
  new provider.

## Linked sub-problems / proposals

- `proposals/proposal-1.md` — Direct string-match via compile-time `@known_provider_names` map; O(1) lookup; no atom creation, no rescue. **Selected.**
- `proposals/proposal-2.md` — Unify both clauses behind `resolve_input/1`; O(N) Enum.find; more code, no additional decomplecting. Not selected.
- `proposals/proposal-3.md` — Extract to public `provider_from_string/1`; identical implementation to P1 but adds public API surface without evidence of external callers. Not selected.
- `proposals/proposal-4.md` — Compile-time `for`-generated per-provider clauses + catch-all; introduces source-order dependency hazard. Not selected.

## Revision history

- (revision 0 — initial)
