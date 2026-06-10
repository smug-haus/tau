defmodule Tau.Factory.Gate.AcLinkagePropertyTest do
  @moduledoc """
  Gating tests for AC-1 (D-305-adjacent) — `Tau.Factory.Gate.AcLinkage.check/2`.

  Written BEFORE production code exists (oracle-separation phase, D-304).
  These tests fail with a compile error / UndefinedFunctionError until the
  implementer creates `lib/tau/factory/gate/ac_linkage.ex`.

  Properties pin SPEC-FACTORY-GATE §4 B2 + gate-and-toolchain.md §2.1:
    P-AC1 soundness
    P-AC2 scope-tightness (tokens outside acceptance section ignored)
    P-AC3 meta-exemption
    P-AC4 monotone in tests

  All property tests are tagged `:property` (OTP non-negotiable #6:
  properties before examples for invariant-bearing modules).

  AC linkage: AC-1, D-305-adjacent.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :property
  @moduletag :ac_1

  alias Tau.Factory.Gate.AcLinkage

  # ---------------------------------------------------------------------------
  # Generators
  # ---------------------------------------------------------------------------

  defp ac_token_gen do
    StreamData.bind(StreamData.integer(1..50), fn n -> StreamData.constant("AC-#{n}") end)
  end

  defp d_token_gen do
    StreamData.bind(StreamData.integer(100..400), fn n -> StreamData.constant("D-#{n}") end)
  end

  defp any_token_gen do
    StreamData.one_of([ac_token_gen(), d_token_gen()])
  end

  # A gating-test meta that "covers" the given token via @tag form.
  defp covering_meta(token) do
    tag_form = token |> String.downcase() |> String.replace("-", "_")
    %{name: "#{token}: some test description", tags: [String.to_atom(tag_form)]}
  end

  defp uncovering_meta(token) do
    # A meta that covers a DIFFERENT token to guarantee the given one is uncovered.
    other = if String.starts_with?(token, "AC-"), do: "D-999", else: "AC-999"
    tag_form = other |> String.downcase() |> String.replace("-", "_")
    %{name: "#{other}: unrelated", tags: [String.to_atom(tag_form)]}
  end

  defp pr_body_with_ac_section(tokens) when is_list(tokens) do
    bullets = Enum.map_join(tokens, "\n", fn t -> "- **#{t}** some criterion" end)

    """
    ## Background

    Context prose mentioning D-999 and AC-999 as background — should be ignored.

    ## Acceptance criteria

    #{bullets}

    ## Test plan

    See gating tests.
    """
  end

  # ---------------------------------------------------------------------------
  # P-AC1 — soundness
  # check/2 = {:pass, []} iff every non-meta token in the AC section is covered.
  # ---------------------------------------------------------------------------

  property "P-AC1: AC-1 — check/2 returns {:pass, []} iff every non-meta token is covered" do
    check all(tokens <- StreamData.list_of(any_token_gen(), min_length: 1, max_length: 6)) do
      tokens = Enum.uniq(tokens)
      pr_body = pr_body_with_ac_section(tokens)
      gating_tests = Enum.map(tokens, &covering_meta/1)

      assert {:pass, []} = AcLinkage.check(pr_body, gating_tests)
    end
  end

  property "P-AC1: AC-1 — check/2 returns {:fail, missing} listing uncovered tokens" do
    check all(
            covered_tokens <- StreamData.list_of(any_token_gen(), min_length: 1, max_length: 4),
            missing_token <- any_token_gen()
          ) do
      # Ensure missing_token is not also in covered_tokens.
      covered_tokens = Enum.reject(covered_tokens, &(&1 == missing_token)) |> Enum.uniq()
      all_tokens = [missing_token | covered_tokens]
      pr_body = pr_body_with_ac_section(all_tokens)
      gating_tests = Enum.map(covered_tokens, &covering_meta/1)

      result = AcLinkage.check(pr_body, gating_tests)
      assert {:fail, missing} = result
      assert missing_token in missing
    end
  end

  # ---------------------------------------------------------------------------
  # P-AC2 — scope-tightness: tokens outside the AC section are never claims.
  # ---------------------------------------------------------------------------

  property "P-AC2: AC-1 — tokens appearing only in prose outside the AC section are ignored" do
    check all(
            claimed_token <- any_token_gen(),
            background_token <- any_token_gen(),
            claimed_token != background_token
          ) do
      pr_body = """
      ## Background

      This PR relates to #{background_token} — cited for context only.

      ## Acceptance criteria

      - **#{claimed_token}** the actual claim.

      ## Test plan

      See gating test.
      """

      # Cover the claimed token but NOT background_token.
      gating_tests = [covering_meta(claimed_token)]

      # background_token should be ignored; result should be pass.
      assert {:pass, []} = AcLinkage.check(pr_body, gating_tests)
    end
  end

  # ---------------------------------------------------------------------------
  # P-AC3 — meta-exemption: (meta) token is never reported missing.
  # ---------------------------------------------------------------------------

  property "P-AC3: AC-1 — a (meta)-marked AC is never reported missing" do
    check all(meta_token <- ac_token_gen(), other_token <- any_token_gen()) do
      # Only AC- tokens support the (meta) marker in this PR's convention.
      # meta_token is present with (meta) — should be exempt.
      # other_token is a normal claimed token — we cover it.
      other_token = if other_token == meta_token, do: "D-999", else: other_token

      pr_body = """
      ## Acceptance criteria

      - **#{meta_token} (meta)** verified by CI, not a unit test.
      - **#{other_token}** a normal claimed criterion.

      ## Test plan

      See gating test.
      """

      gating_tests = [covering_meta(other_token)]

      result = AcLinkage.check(pr_body, gating_tests)
      # meta_token must NOT be in the missing list under any outcome.
      case result do
        {:pass, []} ->
          :ok

        {:fail, missing} ->
          refute meta_token in missing,
                 "Meta AC #{meta_token} must never appear in missing list; got #{inspect(missing)}"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # P-AC4 — monotone in tests: adding a gating test never turns :pass into :fail.
  # ---------------------------------------------------------------------------

  property "P-AC4: AC-1 — adding a gating test never turns {:pass, []} into {:fail, _}" do
    check all(tokens <- StreamData.list_of(any_token_gen(), min_length: 1, max_length: 5)) do
      tokens = Enum.uniq(tokens)
      pr_body = pr_body_with_ac_section(tokens)
      gating_tests = Enum.map(tokens, &covering_meta/1)

      assert {:pass, []} = AcLinkage.check(pr_body, gating_tests)

      # Add an extra unrelated test — must still pass.
      extra = %{name: "unrelated extra test", tags: [:unrelated_xyz]}
      extended_tests = [extra | gating_tests]

      assert {:pass, []} = AcLinkage.check(pr_body, extended_tests)
    end
  end

  # ---------------------------------------------------------------------------
  # AC-1 example test — exercises the real public entry point, not a hand-built
  # struct. This fires if the module doesn't exist at all.
  # ---------------------------------------------------------------------------

  @tag :ac_1
  test "AC-1: check/2 public entry point callable — module must exist" do
    pr_body = """
    ## Acceptance criteria

    - **AC-1** the module is present and callable.

    """

    gating_tests = [%{name: "AC-1: present", tags: [:ac_1]}]
    assert {:pass, []} = AcLinkage.check(pr_body, gating_tests)
  end
end
