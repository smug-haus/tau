defmodule Tau.Factory.SpecMembershipPropertyTest do
  @moduledoc """
  Property tests for D-322 (INV-23 — spec-before-code mechanized) — PR-GATE-3.

  AC-7 (SPEC-FACTORY-GATE §7):

    `mix test --only property` passes including `spec_membership_property_test.exs`
    (P-SP1/P-SP2) — a diff touching a SPEC source-map boundary with no
    `SPEC-*`/`D-NNN` token in the PR body fails naming that boundary. Signal:
    the property asserts fail-with-named-boundary.

  D-322 (SPEC-FACTORY-GATE §4):

    `Gate.SpecMembership.check/3` FAILs a diff that touches any source-map
    boundary path without a `SPEC-*`/`D-NNN` token in the PR body, naming
    that boundary. A diff touching only non-SPEC'd paths ⇒ PASS regardless
    of body.

  ## Properties

  - **P-SP1** (SPEC'd-boundary-without-reference ⇒ FAIL): when the diff touches
    a path that matches a source-map boundary and the PR body contains no
    `SPEC-*`/`D-NNN` token, `check/3` returns `{:fail, [boundary]}`.

  - **P-SP2** (non-SPEC'd-only ⇒ PASS): when every path touched by the diff is
    absent from all source-map boundaries, `check/3` returns `{:pass, []}`.

  ## Fail-before contract

  At the merge-base of wave/gate-conformance (before b66ce82), the module
  `Tau.Factory.Gate.SpecMembership` does NOT exist. This file therefore fails
  at COMPILE TIME before implementation, producing an `UndefinedFunctionError`
  when the test runner loads it. After the implementer lands
  `lib/tau/factory/gate/spec_membership.ex`, the compile error resolves and
  both property tests pass.

  AC linkage: AC-7, D-322 (the `@tag :ac_7` / `@tag :d_322` / `@tag :property`
  tokens satisfy Gate 5.1).
  """

  use ExUnit.Case, async: true

  use ExUnitProperties

  @moduletag :ac_7
  @moduletag :d_322
  @moduletag :property

  # Runtime reference — compile succeeds even before the module is defined,
  # but any call to check/3 before the module exists will raise at test
  # execution time (the intended fail-before mode).
  @spec_membership Tau.Factory.Gate.SpecMembership

  # ---------------------------------------------------------------------------
  # Generators
  # ---------------------------------------------------------------------------

  # Generate a simple file path string.
  defp gen_path do
    StreamData.bind(
      StreamData.string(:alphanumeric, min_length: 3, max_length: 12),
      fn name ->
        StreamData.bind(
          StreamData.string(:alphanumeric, min_length: 2, max_length: 8),
          fn dir ->
            StreamData.constant("lib/#{dir}/#{name}.ex")
          end
        )
      end
    )
  end

  # Generate a unified-diff snippet that touches the given path.
  # Uses the `--- a/` / `+++ b/` header format that extract_touched_paths parses.
  defp gen_diff_touching(path) do
    StreamData.constant("""
    --- a/#{path}
    +++ b/#{path}
    @@ -1,1 +1,2 @@
     existing line
    +new line
    """)
  end

  # Generate a PR body string that does NOT contain any SPEC-* or D-NNN token.
  defp gen_body_no_spec_ref do
    StreamData.bind(
      StreamData.string(:printable, min_length: 0, max_length: 80),
      fn s ->
        # Replace any accidental SPEC- or D-NNN substrings so the generator
        # is pure with respect to the check.
        cleaned =
          s
          |> String.replace(~r/SPEC-[A-Z]/, "NOPE-")
          |> String.replace(~r/\bD-\d+\b/, "N-0")

        StreamData.constant(cleaned)
      end
    )
  end

  # Generate a PR body string that DOES contain at least one SPEC-* token.
  defp gen_body_with_spec_ref do
    StreamData.bind(
      StreamData.string(:alphanumeric, min_length: 3, max_length: 10),
      fn suffix ->
        StreamData.constant("This PR advances SPEC-FACTORY-#{String.upcase(suffix)} D-999.")
      end
    )
  end

  # Generate a path that is NOT in the given boundary set.
  defp gen_path_not_in(boundaries) do
    StreamData.filter(gen_path(), fn p ->
      not Enum.any?(boundaries, fn b ->
        p == b or String.starts_with?(p, b <> "/")
      end)
    end)
  end

  # ---------------------------------------------------------------------------
  # P-SP1: SPEC'd-boundary-without-reference ⇒ {:fail, [boundary]}
  #
  # For any path that matches a source-map boundary, and for any PR body that
  # contains no SPEC-* or D-NNN token, check/3 MUST return {:fail, _} and the
  # violated boundary path MUST appear in the returned list.
  # ---------------------------------------------------------------------------

  property "P-SP1: a diff touching a SPEC'd boundary with no SPEC ref returns {:fail, [boundary]}" do
    check all(
            boundary_path <- gen_path(),
            spec_ref <- StreamData.string(:alphanumeric, min_length: 3, max_length: 10),
            diff <- gen_diff_touching(boundary_path),
            pr_body <- gen_body_no_spec_ref(),
            max_runs: 50
          ) do
      source_maps = [{boundary_path, "SPEC-#{String.upcase(spec_ref)}"}]
      result = @spec_membership.check(diff, pr_body, source_maps)

      assert match?({:fail, _}, result),
             "P-SP1 (D-322): a diff touching boundary #{inspect(boundary_path)} " <>
               "with no SPEC-*/D-NNN token in the PR body MUST return {:fail, _}. " <>
               "Got: #{inspect(result)}"

      {:fail, violated} = result

      assert boundary_path in violated,
             "P-SP1 (D-322): the violated boundary #{inspect(boundary_path)} " <>
               "MUST be named in the {:fail, boundaries} list. " <>
               "Got: #{inspect(violated)}"
    end
  end

  # ---------------------------------------------------------------------------
  # P-SP2: non-SPEC'd-only diff ⇒ {:pass, []}
  #
  # When every path touched by the diff is absent from all source-map
  # boundaries, check/3 MUST return {:pass, []} regardless of the PR body
  # content.
  # ---------------------------------------------------------------------------

  property "P-SP2: a diff touching only non-SPEC'd paths returns {:pass, []}" do
    check all(
            boundary_path <- gen_path(),
            spec_ref <- StreamData.string(:alphanumeric, min_length: 3, max_length: 10),
            non_spec_path <- gen_path_not_in([boundary_path]),
            diff <- gen_diff_touching(non_spec_path),
            pr_body <- StreamData.string(:printable, min_length: 0, max_length: 80),
            max_runs: 50
          ) do
      source_maps = [{boundary_path, "SPEC-#{String.upcase(spec_ref)}"}]
      result = @spec_membership.check(diff, pr_body, source_maps)

      assert result == {:pass, []},
             "P-SP2 (D-322): a diff touching only non-SPEC'd paths " <>
               "(#{inspect(non_spec_path)}, not in boundary #{inspect(boundary_path)}) " <>
               "MUST return {:pass, []} regardless of the PR body content. " <>
               "Got: #{inspect(result)}"
    end
  end

  # ---------------------------------------------------------------------------
  # P-SP1 corollary: a PR body WITH a SPEC-* token MUST produce {:pass, []}
  # even when the diff touches a SPEC'd boundary.
  #
  # This verifies the complementary direction of P-SP1: when the PR body DOES
  # reference a SPEC, the boundary is "covered" and check/3 must not fail it.
  # ---------------------------------------------------------------------------

  property "P-SP1 corollary: a diff touching a SPEC'd boundary WITH a SPEC ref returns {:pass, []}" do
    check all(
            boundary_path <- gen_path(),
            spec_ref <- StreamData.string(:alphanumeric, min_length: 3, max_length: 10),
            diff <- gen_diff_touching(boundary_path),
            pr_body <- gen_body_with_spec_ref(),
            max_runs: 50
          ) do
      source_maps = [{boundary_path, "SPEC-#{String.upcase(spec_ref)}"}]
      result = @spec_membership.check(diff, pr_body, source_maps)

      assert result == {:pass, []},
             "P-SP1 corollary (D-322): a diff touching SPEC'd boundary " <>
               "#{inspect(boundary_path)} whose PR body DOES contain a SPEC-* token " <>
               "MUST return {:pass, []} (the boundary is covered). " <>
               "Got: #{inspect(result)}"
    end
  end
end
