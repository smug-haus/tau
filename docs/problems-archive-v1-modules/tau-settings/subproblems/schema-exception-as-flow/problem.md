---
template_version: 1
template_name: problem
node_kind: leaf
depth: 1
parent: ../../problem.md
status: draft
---

# Problem: Schema.to_known_module/1 uses rescue ArgumentError as primary control flow

## Statement

`Tau.Settings.Schema.to_known_module/1` (the binary clause, lines
291-296) calls `String.to_existing_atom("Elixir." <> str)` and wraps
the call in `rescue ArgumentError` to detect an unknown atom. The
`ArgumentError` raised when the atom does not exist is not an exceptional
condition — it is the expected result for any provider string that isn't
pre-loaded. Using `rescue` as the normal-path dispatch conflates
exception handling with ordinary control flow, violating the principle
that `rescue` is for genuinely unexpected faults.

## Context

- `lib/tau/settings/schema.ex:290-296` — the binary clause of
  `to_known_module/1`:
  ```elixir
  defp to_known_module(str) when is_binary(str) do
    try do
      mod = String.to_existing_atom("Elixir." <> str)
      if mod in @known_providers, do: {:ok, mod}, else: {:error, {:unknown_provider, str}}
    rescue
      ArgumentError -> {:error, {:unknown_provider, str}}
    end
  end
  ```
- `String.to_existing_atom/1` raises `ArgumentError` when the atom is
  not interned — this is its documented, non-exceptional signal for
  "atom not found". An alternative is `:"Elixir.#{str}"` is not safe
  (creates atoms); the correct alternative is to check the `@known_providers`
  list directly (the set is compile-time-known) before attempting any
  atom coercion.
- `@known_providers` is a compile-time constant (6 modules). A direct
  `Enum.find/2` on the string-serialised form of each known provider
  covers the same cases without atom creation or exception use.
- `test/tau/settings/schema_test.exs:88-94` exercises the "rejects
  unknown providers" path; the test passes regardless of whether the
  implementation uses rescue or conditional logic.

## Complecting hypothesis

The domain-level "provider string is unknown" result is complected with
Elixir's atom-intern exception mechanism because the implementation
delegates the "is this atom known?" question to the VM's atom table
lookup rather than to the module's own `@known_providers` data.

## Decomposition strategy

(leaf — no further decomposition; proceed to proposals)

## Acceptance criterion

`to_known_module/1` for binary input no longer uses `rescue` or `try`;
the "unknown provider" result is produced by a conditional check against
`@known_providers` (or equivalent compile-time data); the existing
`schema_test.exs` tests for `resolve_fallback_chains/1` all continue to
pass; and `mix compile --warnings-as-errors` produces no new warnings.

## Out of scope

- `to_known_module/1` for atom input (the atom clause at lines 282-288;
  it uses `cond` correctly and has no exception-as-flow issue).
- `resolve_fallback_chains/1` reduce logic.
- The JSON Schema map itself (`@schema`) or `json_schema/0`.
- `Loader.merge/2` property tests (sibling problem).
- `Settings.Watcher` OTP compliance (sibling problem).

## Amendment log

- (none yet)
