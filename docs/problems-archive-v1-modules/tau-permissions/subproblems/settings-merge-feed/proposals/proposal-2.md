---
template_version: 1
template_name: proposal
proposal_id: 2
parent_problem: ../problem.md
---

# Proposal 2: Separate property test file loader_property_test.exs

## Approach

Create a new file `test/tau/settings/loader_property_test.exs` containing
only `ExUnitProperties`-tagged tests for `Loader.merge/2`. Leave the existing
`loader_test.exs` untouched. The new file owns three properties: the
prefix-then-suffix concatenation invariant, the identity invariant, and a
third property asserting that absent permissions keys in one layer are treated
as empty lists (not nil) — the third invariant named in the problem statement
that the acceptance criterion encodes implicitly.

## Rationale

Separating property tests from example tests follows the established pattern
in `test/tau/permissions/` where modules with rich property coverage tend to
have dedicated property files. The separation makes the OTP NN #6 check
mechanical: `grep -r "use ExUnitProperties" test/tau/settings/` yields
`loader_property_test.exs` and unambiguously confirms coverage. It also
protects the example test file from accretion: `loader_test.exs` remains
a readable, compact exemplar of expected behaviors; the property file
contains the full combinatorial coverage. A reviewer can look at either file
with a clear mental model of what it does.

## Sketch

```
test/tau/settings/
  loader_test.exs           # unchanged
  loader_property_test.exs  # new
```

```elixir
# test/tau/settings/loader_property_test.exs  — full new file

defmodule Tau.Settings.LoaderPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Tau.Settings.Loader

  @perm_keys [:allow, :deny, :ask]

  # ── generators ──────────────────────────────────────────────────────────

  defp permission_list, do: list_of(string(:alphanumeric, min_length: 1))

  defp permissions_layer do
    fixed_map(%{
      allow: permission_list(),
      deny:  permission_list(),
      ask:   permission_list()
    })
  end

  defp settings_with_permissions do
    fixed_map(%{permissions: permissions_layer()})
  end

  # ── properties ──────────────────────────────────────────────────────────

  property "merge/2: permissions arrays are prefix-then-suffix concat for each key" do
    check all(
              a <- settings_with_permissions(),
              b <- settings_with_permissions()
            ) do
      merged = Loader.merge(a, b)

      for key <- @perm_keys do
        assert merged[:permissions][key] ==
                 a[:permissions][key] ++ b[:permissions][key],
               "key #{key}: expected a-prefix then b-suffix"
      end
    end
  end

  property "merge/2: merge(x, %{}) == x for any settings map with permissions" do
    check all(x <- settings_with_permissions()) do
      assert Loader.merge(x, %{}) == x
    end
  end

  property "merge/2: absent permissions key in layer b treated as empty list, not nil" do
    check all(
              a_list <- permission_list(),
              key    <- member_of(@perm_keys)
            ) do
      a = %{permissions: %{key => a_list}}
      # layer b omits this key entirely
      b = %{permissions: %{}}
      merged = Loader.merge(a, b)
      # must equal a's list, not nil
      assert merged[:permissions][key] == a_list
      refute is_nil(merged[:permissions][key])
    end
  end
end
```

The `fixed_map/1` generator produces maps with all keys always present,
removing key-presence variation from the concat property and isolating the
nil-vs-empty-list invariant to its own property.

## Tradeoffs

### Strengths

- OTP NN #6 compliance is unambiguous: the module name `LoaderPropertyTest`
  and the file suffix `_property_test.exs` signal pure property coverage.
- Three properties vs two: the nil-vs-empty-list invariant (the third invariant
  from the problem statement) is explicitly covered, not left to inference.
- `loader_test.exs` is not touched, so no risk of breaking existing passing
  tests during the PR.
- `fixed_map/1`-based generators are more readable than inline `map_of`
  generators and more representative of real settings shapes.
- File is naturally mixable with `mix test --only property` if a `:property`
  tag is added.

### Weaknesses

- A new file means two places to look for `merge/2` coverage; a new
  contributor might not know to check `loader_property_test.exs`.
- The `settings_with_permissions/0` generator produces maps with all three
  permission keys always present; it doesn't cover sparse maps where only
  some keys exist. This is partially compensated by the nil-vs-empty-list
  property but doesn't cover the three-key-subset combinations.
- Introduces a naming convention (`_property_test.exs`) that may or may not
  be followed elsewhere in the project — a convention inconsistency if other
  modules don't follow it.
- `fixed_map/1` is a `StreamData` function that some contributors may be
  less familiar with than the more common `map_of/2`.

### Costs

- One new file (~60 lines).
- No production code changes; no dependency changes.
- CI: adds ~3 `check all` runs at 100 iterations each; estimated < 2 s.

## Dependencies

- `{:stream_data, "~> 1.1"}` already present.
- No production code changes required.
- Existing `loader_test.exs` left untouched.

## Confidence

high — `fixed_map/1`, `list_of/1`, `member_of/1` are standard StreamData
primitives well-established in this codebase. The three properties map
directly to the problem statement's three named invariants. The generator
shapes match real settings maps (atom-keyed, nested permissions map).

## Prior art / references

- `test/tau/permissions/mode_test.exs` — existing property test file in the
  permissions subsystem; pattern precedent for a dedicated property file.
- `StreamData.fixed_map/1` docs:
  https://hexdocs.pm/stream_data/StreamData.html#fixed_map/1
- Problem statement §Context: "No `StreamData` import; no `property` blocks"
  — the nil-vs-empty-list invariant is named but untested.
