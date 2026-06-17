defmodule Tau.Factory.ClampGateFloorTest do
  @moduledoc """
  Gating test for INV-CLAMP-GATE-FLOOR (issue #590).

  ## Invariant

  The gate manifest must always contain at minimum `{:mutation, :critic,
  :reviewer}`. The clamp rejects any policy whose gate manifest does not
  include all three floor halves. Falsified if a unit is admitted with a
  gate manifest that does not include mutation, critic, and reviewer.

  Source: SPEC-FACTORY-GOV §4 B6, C5, C206-B6, HR-8, D-319.

  ## Admission boundary

  `SPEC-FACTORY-GOV C206-B6 (★ load-bearing)` states:

      The engine-clamp/1 runs AT ADMISSION, BEFORE THE PIN — the pinned
      version is the *clamped* one. A policy value that could falsify a
      protected invariant is rejected/clamped *before* it ever governs a
      unit; an un-clamped value never reaches the engine.

  The admission boundary for INV-CLAMP-GATE-FLOOR is
  `Tau.Factory.Policy.Owner.pin/3`. It calls `Policy.clamp/1` before
  writing to ETS, so a floor-deficient policy must be rejected there.

  ## Gap being closed

  `Policy.clamp/1`'s `enforce_gate_floor/1` function has two clauses:

      defp enforce_gate_floor(%{gate_manifest: manifest}) when is_list(manifest) do
        missing = Enum.reject(@gate_floor, &(&1 in manifest))
        case missing do
          [] -> :ok
          missing -> {:error, {:gate_floor_violation, missing}}
        end
      end

      defp enforce_gate_floor(_candidate), do: :ok

  The catch-all clause `enforce_gate_floor(_candidate), do: :ok` silently
  passes a policy map that has no `gate_manifest` key at all. A policy
  with no `gate_manifest` contains none of the required floor members, so
  it must be rejected — not silently admitted. The invariant's "must always
  contain at minimum {mutation, critic, reviewer}" requires rejection when
  the manifest is absent.

  This test exercises the FULL admission path: `Policy.Owner.pin/3`
  calling `Policy.clamp/1` which calls `enforce_gate_floor/1`.

  ## Failure expectation (fail-before)

  `Policy.clamp/1`'s catch-all `enforce_gate_floor(_candidate), do: :ok`
  causes `Policy.Owner.pin/3` to ACCEPT a policy with no `gate_manifest`
  key — the assertion that it should be rejected will fail. This is the
  correct red state before the implementer fixes `enforce_gate_floor/1`.
  """

  use ExUnit.Case, async: true

  alias Tau.Factory.Policy

  @moduletag :inv_clamp_gate_floor

  @owner Tau.Factory.Policy.Owner

  # A minimal valid policy — all budget dimensions present, full floor manifest.
  defp valid_policy do
    %{
      gate_manifest: [:mutation, :critic, :reviewer],
      retry_bound_n: 3,
      token: 100_000,
      cost: 500,
      wall_time: 3_600,
      iteration: 10
    }
  end

  # ---------------------------------------------------------------------------
  # Setup: start a fresh Policy.Owner per test
  # ---------------------------------------------------------------------------

  setup do
    owner_name = :"clamp_gate_floor_owner_#{System.unique_integer([:positive])}"
    owner_pid = start_supervised!({@owner, name: owner_name})
    %{owner: owner_pid}
  end

  # ---------------------------------------------------------------------------
  # INV-CLAMP-GATE-FLOOR: absent gate_manifest must be rejected at admission
  # ---------------------------------------------------------------------------

  describe "INV-CLAMP-GATE-FLOOR: Policy.Owner.pin/3 enforces the gate-floor at admission" do
    @tag :inv_clamp_gate_floor
    test "INV-CLAMP-GATE-FLOOR: pin/3 REJECTS a policy with no gate_manifest key (absent manifest contains no floor members)",
         %{owner: owner} do
      unit_id = "test-unit-no-manifest-#{System.unique_integer([:positive])}"

      # A policy with no gate_manifest key at all — it contains none of
      # {:mutation, :critic, :reviewer}, so the invariant is violated.
      policy_no_manifest = %{
        retry_bound_n: 3,
        token: 100_000,
        cost: 500,
        wall_time: 3_600,
        iteration: 10
      }

      result = @owner.pin(owner, unit_id, policy_no_manifest)

      assert match?({:error, _}, result),
             "INV-CLAMP-GATE-FLOOR: Policy.Owner.pin/3 MUST reject a policy with no " <>
               "gate_manifest key. A missing gate_manifest contains none of " <>
               "{:mutation, :critic, :reviewer}; the clamp must return " <>
               "{:error, {:gate_floor_violation, _}} (SPEC-FACTORY-GOV C206-B6, HR-8). " <>
               "Got: #{inspect(result)}"

      {:error, reason} = result

      assert match?({:gate_floor_violation, _}, reason),
             "INV-CLAMP-GATE-FLOOR: the rejection reason MUST be " <>
               "{:gate_floor_violation, missing_members}. " <>
               "Got reason: #{inspect(reason)}"

      {_, missing} = reason

      assert :mutation in missing or :critic in missing or :reviewer in missing,
             "INV-CLAMP-GATE-FLOOR: the missing list must include at least one of " <>
               "{:mutation, :critic, :reviewer} when gate_manifest is absent. " <>
               "Got missing: #{inspect(missing)}"
    end

    @tag :inv_clamp_gate_floor
    test "INV-CLAMP-GATE-FLOOR: after rejection of no-manifest policy, resolve/3 confirms unit NOT admitted",
         %{owner: owner} do
      unit_id = "test-unit-no-manifest-resolve-#{System.unique_integer([:positive])}"

      policy_no_manifest = %{
        retry_bound_n: 3,
        token: 100_000,
        cost: 500,
        wall_time: 3_600,
        iteration: 10
      }

      # This will currently return :ok (bug) — force the test to destructure
      # as {:error, _} to demonstrate the failure.
      case @owner.pin(owner, unit_id, policy_no_manifest) do
        {:error, _} ->
          resolve_result = @owner.resolve(owner, unit_id, :gate_manifest)

          assert match?({:error, :not_pinned}, resolve_result),
                 "INV-CLAMP-GATE-FLOOR: after pin/3 rejects a no-manifest policy, " <>
                   "resolve/3 MUST return {:error, :not_pinned}. " <>
                   "Got: #{inspect(resolve_result)}"

        :ok ->
          flunk(
            "INV-CLAMP-GATE-FLOOR: pin/3 accepted a policy with no gate_manifest key " <>
              "(returned :ok). It MUST reject it with {:error, {:gate_floor_violation, _}} " <>
              "(SPEC-FACTORY-GOV C206-B6, HR-8). The catch-all clause in " <>
              "enforce_gate_floor/1 is causing silent admission of floor-deficient policies."
          )
      end
    end

    @tag :inv_clamp_gate_floor
    test "INV-CLAMP-GATE-FLOOR: pin/3 REJECTS a policy with gate_manifest missing :reviewer",
         %{owner: owner} do
      unit_id = "test-unit-missing-reviewer-#{System.unique_integer([:positive])}"

      policy_partial_manifest = %{
        gate_manifest: [:mutation, :critic],
        retry_bound_n: 3,
        token: 100_000,
        cost: 500,
        wall_time: 3_600,
        iteration: 10
      }

      result = @owner.pin(owner, unit_id, policy_partial_manifest)

      assert match?({:error, {:gate_floor_violation, _}}, result),
             "INV-CLAMP-GATE-FLOOR: Policy.Owner.pin/3 MUST reject a policy with " <>
               "gate_manifest missing :reviewer. " <>
               "Got: #{inspect(result)}"

      {:error, {:gate_floor_violation, missing}} = result

      assert :reviewer in missing,
             "INV-CLAMP-GATE-FLOOR: :reviewer must appear in missing list. " <>
               "Got: #{inspect(missing)}"
    end

    @tag :inv_clamp_gate_floor
    test "INV-CLAMP-GATE-FLOOR: pin/3 REJECTS a policy with gate_manifest missing :mutation",
         %{owner: owner} do
      unit_id = "test-unit-missing-mutation-#{System.unique_integer([:positive])}"

      policy_partial_manifest = %{
        gate_manifest: [:critic, :reviewer],
        retry_bound_n: 3,
        token: 100_000,
        cost: 500,
        wall_time: 3_600,
        iteration: 10
      }

      result = @owner.pin(owner, unit_id, policy_partial_manifest)

      assert match?({:error, {:gate_floor_violation, _}}, result),
             "INV-CLAMP-GATE-FLOOR: Policy.Owner.pin/3 MUST reject a policy with " <>
               "gate_manifest missing :mutation. " <>
               "Got: #{inspect(result)}"

      {:error, {:gate_floor_violation, missing}} = result

      assert :mutation in missing,
             "INV-CLAMP-GATE-FLOOR: :mutation must appear in missing list. " <>
               "Got: #{inspect(missing)}"
    end

    @tag :inv_clamp_gate_floor
    test "INV-CLAMP-GATE-FLOOR: pin/3 REJECTS a policy with gate_manifest missing :critic",
         %{owner: owner} do
      unit_id = "test-unit-missing-critic-#{System.unique_integer([:positive])}"

      policy_partial_manifest = %{
        gate_manifest: [:mutation, :reviewer],
        retry_bound_n: 3,
        token: 100_000,
        cost: 500,
        wall_time: 3_600,
        iteration: 10
      }

      result = @owner.pin(owner, unit_id, policy_partial_manifest)

      assert match?({:error, {:gate_floor_violation, _}}, result),
             "INV-CLAMP-GATE-FLOOR: Policy.Owner.pin/3 MUST reject a policy with " <>
               "gate_manifest missing :critic. " <>
               "Got: #{inspect(result)}"

      {:error, {:gate_floor_violation, missing}} = result

      assert :critic in missing,
             "INV-CLAMP-GATE-FLOOR: :critic must appear in missing list. " <>
               "Got: #{inspect(missing)}"
    end

    @tag :inv_clamp_gate_floor
    test "INV-CLAMP-GATE-FLOOR: pin/3 ACCEPTS a policy whose gate_manifest contains the full floor",
         %{owner: owner} do
      unit_id = "test-unit-full-floor-#{System.unique_integer([:positive])}"

      result = @owner.pin(owner, unit_id, valid_policy())

      assert result == :ok,
             "INV-CLAMP-GATE-FLOOR: Policy.Owner.pin/3 MUST accept a policy with " <>
               "the full floor manifest [:mutation, :critic, :reviewer]. " <>
               "Got: #{inspect(result)}"

      resolve_result = @owner.resolve(owner, unit_id, :gate_manifest)

      assert match?({:ok, _}, resolve_result),
             "INV-CLAMP-GATE-FLOOR: after a valid pin/3, resolve/3 MUST return {:ok, value}. " <>
               "Got: #{inspect(resolve_result)}"
    end

    @tag :inv_clamp_gate_floor
    test "INV-CLAMP-GATE-FLOOR: pin/3 ACCEPTS a policy with a superset manifest (extra halves beyond floor)",
         %{owner: owner} do
      unit_id = "test-unit-superset-#{System.unique_integer([:positive])}"

      # A superset manifest — has all floor members plus additional ones
      policy_superset =
        Map.put(valid_policy(), :gate_manifest, [:mutation, :critic, :reviewer, :extra_check])

      result = @owner.pin(owner, unit_id, policy_superset)

      assert result == :ok,
             "INV-CLAMP-GATE-FLOOR: Policy.Owner.pin/3 MUST accept a gate_manifest " <>
               "that is a SUPERSET of the floor (extra halves beyond the floor are fine). " <>
               "Got: #{inspect(result)}"
    end
  end

  # ---------------------------------------------------------------------------
  # INV-CLAMP-GATE-FLOOR: pure clamp/1 boundary (property-testable entry)
  # ---------------------------------------------------------------------------

  describe "INV-CLAMP-GATE-FLOOR: Policy.clamp/1 direct boundary (HR-8 pure function)" do
    @tag :inv_clamp_gate_floor
    test "INV-CLAMP-GATE-FLOOR: clamp/1 REJECTS a policy with no gate_manifest key" do
      policy_no_manifest = %{
        retry_bound_n: 3,
        token: 100_000,
        cost: 500,
        wall_time: 3_600,
        iteration: 10
      }

      result = Policy.clamp(policy_no_manifest)

      assert match?({:error, {:gate_floor_violation, _}}, result),
             "INV-CLAMP-GATE-FLOOR: Policy.clamp/1 MUST return " <>
               "{:error, {:gate_floor_violation, _}} for a policy with no " <>
               "gate_manifest key. A missing manifest contains no floor members. " <>
               "Got: #{inspect(result)}"
    end

    @tag :inv_clamp_gate_floor
    test "INV-CLAMP-GATE-FLOOR: clamp/1 REJECTS a policy with gate_manifest: [] (empty list)" do
      policy_empty_manifest = %{
        gate_manifest: [],
        retry_bound_n: 3,
        token: 100_000,
        cost: 500,
        wall_time: 3_600,
        iteration: 10
      }

      result = Policy.clamp(policy_empty_manifest)

      assert match?({:error, {:gate_floor_violation, _}}, result),
             "INV-CLAMP-GATE-FLOOR: Policy.clamp/1 MUST return " <>
               "{:error, {:gate_floor_violation, _}} for gate_manifest: []. " <>
               "An empty manifest contains none of {:mutation, :critic, :reviewer}. " <>
               "Got: #{inspect(result)}"
    end
  end
end
