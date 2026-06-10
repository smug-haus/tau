---
template_version: 1
template_name: proposal
proposal_id: 3
parent_problem: ../problem.md
---

# Proposal 3: Shared SettingsGen generator module + property test file

## Approach

Introduce `test/support/settings_gen.ex` — a reusable StreamData generator
library for the settings subsystem — and a new
`test/tau/settings/loader_property_test.exs` that imports it. The generator
module provides `SettingsGen.settings_map/0`, `SettingsGen.permissions_layer/0`,
and `SettingsGen.permission_list/0`, exposing them for reuse by any other
test module in the `tau-permissions` problem set (matchers, evaluator) that
needs realistic settings shapes. The two acceptance-criterion properties
(concat and identity) plus the nil-vs-empty-list invariant are expressed
in the property test file using the shared generators.

## Rationale

The four sub-problems in `tau-permissions` all need settings-shaped inputs.
Without a shared generator, each property test file re-invents generators
independently — a secondary complecting where generator logic is scattered
across test modules, duplicated, and allowed to drift. Extracting generators
into `test/support/settings_gen.ex` makes the test data contract first-class:
the generator module is the single source of truth for "what does a valid
settings map look like in tests." This is the data-shape axis of decomplecting:
instead of coupling test assertions to inline generator logic, the generators
become a typed, composable interface. Future property test files for matchers
and the evaluator import the same generators, reducing drift across the whole
`tau-permissions` property-test sweep.

## Sketch

```
test/support/
  settings_gen.ex       # new — shared generator module
test/tau/settings/
  loader_test.exs       # unchanged
  loader_property_test.exs  # new — imports SettingsGen
```

```elixir
# test/support/settings_gen.ex

defmodule SettingsGen do
  @moduledoc """
  StreamData generators for settings maps and permissions blocks.
  Reused across Tau.Settings and Tau.Permissions property tests.
  """
  import StreamData

  @perm_keys [:allow, :deny, :ask]

  @doc "A list of permission rule strings (non-empty alphanumeric atoms)."
  def permission_list do
    list_of(string(:alphanumeric, min_length: 1))
  end

  @doc "A permissions sub-map with :allow, :deny, :ask list keys (all present)."
  def permissions_layer do
    fixed_map(%{
      allow: permission_list(),
      deny:  permission_list(),
      ask:   permission_list()
    })
  end

  @doc "A sparse permissions layer — keys may be absent (tests nil-vs-empty)."
  def sparse_permissions_layer do
    map_of(member_of(@perm_keys), permission_list())
  end

  @doc "A settings map that always includes a permissions block."
  def settings_map do
    fixed_map(%{permissions: permissions_layer()})
  end

  @doc "A settings map where the permissions block may be sparse."
  def sparse_settings_map do
    fixed_map(%{permissions: sparse_permissions_layer()})
  end
end
```

```elixir
# test/tau/settings/loader_property_test.exs

defmodule Tau.Settings.LoaderPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Tau.Settings.Loader

  property "merge/2: permissions arrays are prefix-then-suffix concat" do
    check all(
              a <- SettingsGen.settings_map(),
              b <- SettingsGen.settings_map()
            ) do
      merged = Loader.merge(a, b)

      for key <- [:allow, :deny, :ask] do
        assert merged[:permissions][key] ==
                 a[:permissions][key] ++ b[:permissions][key]
      end
    end
  end

  property "merge/2: identity under merge with empty map" do
    check all(x <- SettingsGen.settings_map()) do
      assert Loader.merge(x, %{}) == x
    end
  end

  property "merge/2: absent permissions key treated as empty list, not nil" do
    check all(
              a <- SettingsGen.settings_map(),
              b <- SettingsGen.sparse_settings_map(),
              key <- member_of([:allow, :deny, :ask])
            ) do
      merged = Loader.merge(a, b)
      # even if b doesn't have the key, a's list must survive
      assert is_list(merged[:permissions][key])
    end
  end
end
```

`test/support/` is on the `elixirc_paths` for `:test` in `mix.exs`
(standard in ExUnit projects), so `SettingsGen` is available to all test
modules without explicit import.

## Tradeoffs

### Strengths

- Generator logic is written once and reused across the full `tau-permissions`
  property sweep (matchers, evaluator) — eliminates generator drift across
  test files.
- `sparse_permissions_layer/0` covers the nil-vs-empty-list invariant with a
  generator that actually generates sparse maps, not just hand-crafted inputs.
- The generator API (`SettingsGen.settings_map/0`) documents the authoritative
  shape of a settings map as understood by tests — a living spec.
- Satisfies all three named invariants from the problem statement, not just
  the two mandated by the acceptance criterion.

### Weaknesses

- Introduces a new `test/support/` module, which has its own maintenance
  surface. If `Loader.merge/2`'s understanding of valid settings shapes evolves,
  `SettingsGen` must be updated in sync — a hidden coupling between production
  code and the generator module.
- The generator module is useful only if the other sub-problems (`matcher-unit-
  contracts`, `evaluator-mode-complecting`) actually import it. If those
  sub-problems are solved independently, the generator module becomes orphaned
  support infrastructure with a single user.
- `test/support/settings_gen.ex` is not a test file — it contains no assertions.
  Contributors may not know to look there for generator definitions; discoverability
  depends on documentation or convention.
- Slightly more scope than strictly required by the acceptance criterion
  (introduces a module when inline generators would suffice for two properties).

### Costs

- Two new files (~50 + ~45 lines); no production file changes.
- `test/support/settings_gen.ex` must be listed in `elixirc_paths` for `:test`
  — this is typically already true in ExUnit projects but should be verified
  in `mix.exs`.
- CI impact: same as Proposal 2 (~3 property runs), plus marginal compile
  overhead for the support module.

## Dependencies

- `{:stream_data, "~> 1.1"}` already present.
- `test/support/` must be on `elixirc_paths` for `:test` in `mix.exs` (verify,
  do not assume).
- The value of this proposal increases if `matcher-unit-contracts` and/or
  `evaluator-mode-complecting` sub-problems are worked next and import
  `SettingsGen` — standalone, it is over-engineered for the problem at hand.

## Confidence

medium — The structural approach is sound and mirrors patterns in Elixir
projects (e.g. ExMachina for Ecto, `DataCase` support modules). Confidence
is not `high` because the incremental value over Proposal 2 depends on
whether other sub-problems will reuse `SettingsGen` — a decision not yet
made. If they won't, this proposal's main differentiator (reuse) collapses
to overhead.

## Prior art / references

- ExMachina pattern: shared test factory module under `test/support/` for
  reusable data generation — https://github.com/thoughtbot/ex_machina
- `test/support/tui_pty_helper.ex` in this project — precedent for shared
  test support modules that are imported across multiple test files.
- `StreamData.fixed_map/1` + `StreamData.map_of/2` combined approach:
  https://hexdocs.pm/stream_data/StreamData.html
