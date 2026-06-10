---
template_version: 1
template_name: proposal
proposal_id: 4
parent_problem: ../problem.md
---

# Proposal 4: Credential-key verification via compile-time assertion + fix both bugs

## Approach

Fix both bugs directly in their owning files (same one-line corrections as
Proposal 1), and add a compile-time cross-module consistency assertion in a
dedicated test that runs at `mix compile` time or as part of `mix test`.
The assertion verifies that every `env` value in `Init.@providers` that
corresponds to a provider appearing in `Logout.@credential_map` has the
same value. Neither `@providers` nor `@credential_map` is moved or merged;
the duplication is accepted as a design fact, but divergence becomes a
compile/test error rather than a silent runtime mismatch. The `List.first`
truncation is fixed by extending the settings schema to support a
`"providers"` array and persisting all selected provider strings; the
`"provider"` key retains the first-selected provider for backwards
compatibility.

## Rationale

The complecting hypothesis calls out divergence between two independent
copies. One approach to decomplecting is elimination of one copy (Proposal
2); another is enforced agreement. This proposal takes the latter: instead
of removing duplication, it makes divergence structurally impossible to
ship by adding a property-based or unit assertion that fires before any PR
with a divergent copy can pass CI. The structural fix is at the test/CI
layer rather than the production code layer. This is appropriate when both
copies are in hot-path modules whose change history, ownership, and
coupling to surrounding code make a merge undesirable. The `List.first` and
schema fixes are independent of the assertion approach and are included to
satisfy the full acceptance criterion.

## Sketch

### 1. Fix both root bugs

```elixir
# lib/tau/cli/init.ex — fix Bedrock env key
%{key: :bedrock, label: "Bedrock", env: "AWS_SECRET_ACCESS_KEY"}

# lib/tau/cli/init.ex — fix List.first truncation; extend new_settings
new_settings =
  base_settings
  |> Map.put("permissions", merge_permissions(base_settings, perms_mode))
  |> Map.put("provider", providers |> List.first() |> provider_string())
  |> Map.put("providers", Enum.map(providers, &provider_string/1))
```

### 2. Schema amendment

```elixir
# lib/tau/settings/schema.ex
"providers" => %{
  "type" => "array",
  "items" => %{"type" => "string"}
}
```

### 3. Compile-time consistency assertion: new test module

```elixir
# test/tau/cli/init_logout_credential_parity_test.exs

defmodule Tau.CLI.InitLogoutCredentialParityTest do
  @moduledoc """
  Compile-time guard: asserts that every provider appearing in both
  `Tau.CLI.Init.@providers` and `Tau.Commands.Builtin.Logout.@credential_map`
  uses the same vault credential name.

  This test catches the class of bug documented in
  docs/problems/tau-cli/subproblems/wizard-data-fidelity/problem.md,
  where Init and Logout diverged on the Bedrock credential key.
  """
  use ExUnit.Case, async: true

  # Access module attributes via compiled functions (module attributes are
  # not accessible cross-module; expose via a function in each module, or
  # compare via the functions those modules export). Since @providers and
  # @credential_map are private, this test uses Application.spec or
  # a narrow accessor function added to each module.

  # Preferred: add accessor functions to each module (one line each):
  #   In Init:   def providers, do: @providers
  #   In Logout: def credential_map, do: @credential_map

  test "Init and Logout agree on vault credential names for all shared providers" do
    init_cred_map =
      Tau.CLI.Init.providers()
      |> Map.new(&{Atom.to_string(&1.key), &1.env})

    logout_cred_map = Tau.Commands.Builtin.Logout.credential_map()

    shared_providers = MapSet.intersection(
      MapSet.new(Map.keys(init_cred_map)),
      MapSet.new(Map.keys(logout_cred_map))
    )

    for provider <- shared_providers do
      assert init_cred_map[provider] == logout_cred_map[provider],
        "Credential key mismatch for provider #{inspect(provider)}: " <>
        "Init stores #{inspect(init_cred_map[provider])}, " <>
        "Logout deletes #{inspect(logout_cred_map[provider])}"
    end
  end
end
```

### Accessor functions added to owning modules (minimal surface)

```elixir
# lib/tau/cli/init.ex — add one public function
@doc false
def providers, do: @providers

# lib/tau/commands/builtin/logout.ex — add one public function
@doc false
def credential_map, do: @credential_map
```

### File moves

```
(mod)  lib/tau/cli/init.ex                        — bedrock key fix; providers accessor; schema key addition
(mod)  lib/tau/commands/builtin/logout.ex         — credential_map accessor
(mod)  lib/tau/settings/schema.ex                 — add "providers" array key
(new)  test/tau/cli/init_logout_credential_parity_test.exs
```

## Tradeoffs

### Strengths

- Preserves the independent ownership of `@providers` and
  `@credential_map`; neither module is structurally coupled to the other.
- The parity test is self-documenting: it names the defect class and will
  fail loudly (with a descriptive message naming the offending provider)
  on any future divergence.
- No new production module required; the enforcement lives in the test
  layer where CI already runs it.
- Satisfies both parts of the acceptance criterion: (a) all N providers
  persisted via the `"providers"` key; (b) credential key parity enforced
  at test-time, not just at code-review time.
- Incremental: the accessor functions and parity test can land before the
  bug fixes and will immediately catch the existing Bedrock divergence,
  providing independent verification that the bug exists as described.

### Weaknesses

- The duplication is accepted as a permanent design fact — this is an
  explicit tradeoff. The parity test reduces the risk but does not
  eliminate it: a provider absent from `Logout.@credential_map` but
  present in `Init.@providers` (or vice versa) would not trigger the
  parity check (only shared providers are checked).
- Requires exposing two `@doc false` accessor functions on private module
  attributes, which is a mild abstraction leak in both modules.
- The parity test does not catch a future provider that Init adds but
  Logout does not — asymmetric additions are invisible to the intersection
  check unless the assertion is strengthened to require all Init providers
  to appear in Logout's map.
- Schema amendment is a dependency that must be co-located with the
  `"providers"` write; the schema and init fixes cannot land independently.

### Costs

- 2 files modified (init.ex, logout.ex): ~5 lines each (accessor + key fix).
- 1 file modified (schema.ex): ~3 lines.
- 1 new test file: ~40 lines.
- Test updates: existing init tests for multi-provider selection may need
  to add assertions for the `"providers"` key in the written settings.

## Dependencies

- `"providers"` array key added to `Tau.Settings.Schema` in the same PR.
- Both `Tau.CLI.Init.providers/0` and
  `Tau.Commands.Builtin.Logout.credential_map/0` accessor functions must
  be present for the parity test to compile.

## Confidence

medium — the parity-test approach is unconventional (testing consistency
between module attributes is unusual); confidence would rise if a
prototype test runs green against the corrected code and red against the
pre-fix code.

## Prior art / references

- Elixir cross-module consistency tests: pattern used in Phoenix and Ecto
  to assert that behaviour callbacks are implemented or that configuration
  tables are consistent (e.g. `for {k, _v} <- defaults, do: assert schema[k]`).
- `lib/tau/settings/schema.ex:47–54` — `@known_providers` vs runtime
  registry: a precedent for the risk of divergent lists in this codebase.
- Property-based testing of data invariants: `StreamData` could
  parameterise the parity check over generated provider keys for stronger
  coverage, but a simple unit assertion is sufficient here.
