defmodule Tau.Factory.Gate.SpecMembershipPropertyTest do
  @moduledoc """
  Gating tests for D-322 — `Tau.Factory.Gate.SpecMembership.check/3`.

  Written BEFORE production code exists (oracle-separation phase, D-304).
  These tests fail with a compile error / UndefinedFunctionError until the
  implementer creates `lib/tau/factory/gate/spec_membership.ex`.

  D-322 — Spec-before-code mechanized (INV-23):
    `Gate.SpecMembership.check/3` loads the SPEC source-maps and FAILs a diff
    that touches any source-map boundary path WITHOUT a `SPEC-*`/`D-NNN` token
    in the PR body, naming that boundary. A diff touching only non-SPEC'd paths
    PASSES regardless of body.

  Boundary: SPEC-FACTORY-GATE §4 B2 —
    `SpecMembership.check/3 :: (diff, pr_body, source_maps) ->
      {:pass, []} | {:fail, [boundary]}`

  Properties:
    P-SP1: SPEC'd-boundary-without-reference ⇒ fail naming it.
    P-SP2: non-SPEC'd-only paths ⇒ pass regardless of PR body.

  All property tests are tagged `:property` (OTP non-negotiable #6:
  properties before examples for invariant-bearing modules).

  AC linkage: D-322 (the `@tag :d_322` / description token satisfies Gate 5.1).
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :property
  @moduletag :d_322

  alias Tau.Factory.Gate.SpecMembership

  # ---------------------------------------------------------------------------
  # Generators
  # ---------------------------------------------------------------------------

  # A plausible SPEC'd source-map boundary entry: a spec name + a file path.
  defp spec_boundary_gen do
    StreamData.bind(
      StreamData.integer(1..30),
      fn n ->
        spec_name = "SPEC-FAKE-#{n}"
        path = "lib/tau/fake_module_#{n}.ex"
        StreamData.constant(%{spec: spec_name, path: path})
      end
    )
  end

  # A file path that is NOT in any source map.
  defp non_spec_path_gen do
    StreamData.bind(
      StreamData.integer(100..200),
      fn n -> StreamData.constant("lib/tau/non_spec_file_#{n}.ex") end
    )
  end

  # A minimal unified diff that touches the given path.
  defp diff_touching(path) do
    """
    diff --git a/#{path} b/#{path}
    index abc1234..def5678 100644
    --- a/#{path}
    +++ b/#{path}
    @@ -1,3 +1,4 @@
     defmodule Foo do
    +  def bar, do: :ok
     end
    """
  end

  # A PR body that contains no SPEC or D-NNN token in the acceptance-criteria section.
  defp pr_body_without_spec_token do
    """
    ## Background

    Some prose without any SPEC-* or D-NNN tokens here.

    ## Acceptance criteria

    - **AC-1** some criterion with no spec reference.

    ## Gating-test paths

    test/some_test.exs
    """
  end

  # A PR body that contains a `D-NNN` reference (satisfies spec-membership check).
  defp pr_body_with_d_nnn_token(token) do
    """
    ## Background

    Some background.

    ## Acceptance criteria

    - **#{token}** enforces the spec membership contract.

    ## Gating-test paths

    test/some_test.exs
    """
  end

  # A PR body that contains a `SPEC-*` reference (satisfies spec-membership check).
  defp pr_body_with_spec_ref(spec_name) do
    """
    ## Background

    Conforms to #{spec_name}.

    ## Acceptance criteria

    - **AC-1** references #{spec_name} implicitly.

    ## Gating-test paths

    test/some_test.exs
    """
  end

  # ---------------------------------------------------------------------------
  # P-SP1 — SPEC'd boundary without D-NNN/SPEC reference ⇒ fail naming boundary
  #
  # check/3 MUST return {:fail, boundaries} (non-empty) when the diff touches a
  # path in `source_maps` but the pr_body contains no SPEC-*/D-NNN token
  # referencing that boundary.
  # ---------------------------------------------------------------------------

  property "P-SP1: D-322 — diff touching a SPEC'd boundary without SPEC/D-NNN token ⇒ {:fail, [boundary]}" do
    check all(boundary <- spec_boundary_gen()) do
      diff = diff_touching(boundary.path)
      pr_body = pr_body_without_spec_token()
      # source_maps: a list of %{spec: spec_name, path: path} entries.
      source_maps = [boundary]

      result = SpecMembership.check(diff, pr_body, source_maps)

      assert {:fail, failed_boundaries} = result,
             "Expected {:fail, _} but got #{inspect(result)} for diff touching #{boundary.path} without D-NNN"

      assert is_list(failed_boundaries) and failed_boundaries != [],
             "Expected non-empty boundary list, got #{inspect(failed_boundaries)}"

      # The returned boundary list MUST name the boundary that was triggered.
      # The boundary is identified by spec name or path — either form is acceptable.
      triggered =
        Enum.any?(failed_boundaries, fn b ->
          (is_binary(b) and
             (String.contains?(b, boundary.spec) or String.contains?(b, boundary.path))) or
            (is_map(b) and
               (Map.get(b, :spec) == boundary.spec or Map.get(b, :path) == boundary.path))
        end)

      assert triggered,
             "Expected boundary #{inspect(boundary)} to appear in #{inspect(failed_boundaries)}"
    end
  end

  property "P-SP1: D-322 — diff touching multiple SPEC'd boundaries without token ⇒ {:fail, all boundaries}" do
    check all(
            b1 <- spec_boundary_gen(),
            b2 <- spec_boundary_gen(),
            b1.path != b2.path
          ) do
      diff = diff_touching(b1.path) <> diff_touching(b2.path)
      pr_body = pr_body_without_spec_token()
      source_maps = [b1, b2]

      result = SpecMembership.check(diff, pr_body, source_maps)

      assert {:fail, failed_boundaries} = result,
             "Expected {:fail, _} for multi-boundary diff without token, got #{inspect(result)}"

      assert failed_boundaries != [],
             "Expected at least one boundary named in #{inspect(failed_boundaries)}"
    end
  end

  # ---------------------------------------------------------------------------
  # P-SP1b — SPEC'd boundary WITH a matching D-NNN token ⇒ pass
  #
  # Once a D-NNN token appears in the PR body the membership check is satisfied.
  # ---------------------------------------------------------------------------

  property "P-SP1b: D-322 — diff touching SPEC'd boundary WITH a D-NNN token ⇒ {:pass, []}" do
    check all(
            boundary <- spec_boundary_gen(),
            d_num <- StreamData.integer(100..400)
          ) do
      diff = diff_touching(boundary.path)
      d_token = "D-#{d_num}"
      pr_body = pr_body_with_d_nnn_token(d_token)
      source_maps = [boundary]

      result = SpecMembership.check(diff, pr_body, source_maps)

      assert {:pass, []} = result,
             "Expected {:pass, []} when diff has D-NNN token #{d_token} but got #{inspect(result)}"
    end
  end

  property "P-SP1b: D-322 — diff touching SPEC'd boundary WITH a SPEC-* reference ⇒ {:pass, []}" do
    check all(boundary <- spec_boundary_gen()) do
      diff = diff_touching(boundary.path)
      pr_body = pr_body_with_spec_ref(boundary.spec)
      source_maps = [boundary]

      result = SpecMembership.check(diff, pr_body, source_maps)

      assert {:pass, []} = result,
             "Expected {:pass, []} when PR body references #{boundary.spec} but got #{inspect(result)}"
    end
  end

  # ---------------------------------------------------------------------------
  # P-SP2 — non-SPEC'd-only paths ⇒ pass regardless of PR body
  #
  # check/3 MUST return {:pass, []} when the diff touches ONLY paths not in
  # any source-map boundary, regardless of what the pr_body says.
  # ---------------------------------------------------------------------------

  property "P-SP2: D-322 — diff touching only non-SPEC'd paths ⇒ {:pass, []} regardless of PR body" do
    check all(
            non_spec_path <- non_spec_path_gen(),
            spec_boundary <- spec_boundary_gen(),
            # ensure they are different
            non_spec_path != spec_boundary.path
          ) do
      # The diff only touches the non-spec path.
      diff = diff_touching(non_spec_path)
      # PR body has no SPEC/D-NNN token — irrelevant for a non-SPEC'd diff.
      pr_body = pr_body_without_spec_token()
      # source_maps lists the SPEC'd path, but the diff does NOT touch it.
      source_maps = [spec_boundary]

      result = SpecMembership.check(diff, pr_body, source_maps)

      assert {:pass, []} = result,
             "Expected {:pass, []} for non-SPEC'd diff but got #{inspect(result)}"
    end
  end

  property "P-SP2: D-322 — empty diff ⇒ {:pass, []} (no boundary touched)" do
    check all(spec_boundary <- spec_boundary_gen()) do
      diff = ""
      pr_body = pr_body_without_spec_token()
      source_maps = [spec_boundary]

      result = SpecMembership.check(diff, pr_body, source_maps)

      assert {:pass, []} = result,
             "Expected {:pass, []} for empty diff but got #{inspect(result)}"
    end
  end

  # ---------------------------------------------------------------------------
  # P-SP2b — empty source_maps ⇒ pass unconditionally
  #
  # When there are no SPEC'd boundaries in scope, check/3 MUST pass.
  # ---------------------------------------------------------------------------

  property "P-SP2b: D-322 — empty source_maps ⇒ {:pass, []} regardless of diff or body" do
    check all(non_spec_path <- non_spec_path_gen()) do
      diff = diff_touching(non_spec_path)
      pr_body = pr_body_without_spec_token()
      source_maps = []

      result = SpecMembership.check(diff, pr_body, source_maps)

      assert {:pass, []} = result,
             "Expected {:pass, []} for empty source_maps but got #{inspect(result)}"
    end
  end

  # ---------------------------------------------------------------------------
  # Example test — exercises the real public entry point, confirms the module
  # exists and the function is callable. This fires if the module doesn't exist.
  # ---------------------------------------------------------------------------

  @tag :d_322
  test "D-322: SpecMembership.check/3 public entry point callable — module must exist" do
    diff = diff_touching("lib/tau/factory/gate/spec_membership.ex")
    pr_body = pr_body_with_d_nnn_token("D-322")
    # The file itself is a SPEC-FACTORY-GATE boundary.
    source_maps = [%{spec: "SPEC-FACTORY-GATE", path: "lib/tau/factory/gate/spec_membership.ex"}]

    assert {:pass, []} = SpecMembership.check(diff, pr_body, source_maps)
  end

  @tag :d_322
  test "D-322: diff touching SPEC-FACTORY-GATE boundary without D-NNN ⇒ {:fail, [boundary]}" do
    # A diff touching lib/tau/factory/gate/spec_membership.ex (a known SPEC-FACTORY-GATE
    # boundary per Appendix B) with a PR body containing no SPEC/D-NNN token MUST fail.
    diff = diff_touching("lib/tau/factory/gate/spec_membership.ex")
    pr_body = pr_body_without_spec_token()
    source_maps = [%{spec: "SPEC-FACTORY-GATE", path: "lib/tau/factory/gate/spec_membership.ex"}]

    result = SpecMembership.check(diff, pr_body, source_maps)
    assert {:fail, boundaries} = result
    assert boundaries != [], "Expected non-empty boundary list, got #{inspect(boundaries)}"
  end

  @tag :d_322
  test "D-322: diff touching SPEC'd boundary WITH D-322 token ⇒ {:pass, []}" do
    diff = diff_touching("lib/tau/factory/gate.ex")
    pr_body = pr_body_with_d_nnn_token("D-322")
    source_maps = [%{spec: "SPEC-FACTORY-GATE", path: "lib/tau/factory/gate.ex"}]

    assert {:pass, []} = SpecMembership.check(diff, pr_body, source_maps)
  end
end
