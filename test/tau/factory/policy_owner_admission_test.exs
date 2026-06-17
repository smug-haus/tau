defmodule Tau.Factory.PolicyOwnerAdmissionTest do
  @moduledoc """
  Gating test for INV-POLICY-DATA (issue #553) — the ADMISSION BOUNDARY.

  The existing `policy_oracle_clamp_test.exs` verifies that the pure function
  `Tau.Factory.Policy.clamp/1` correctly rejects an oracle-carrying policy map.
  That test now PASSES (the function was implemented in commit 7a856ea).

  This test closes the remaining gap: the enforcement must also be wired into
  the real ADMISSION PATH — `Tau.Factory.Policy.Owner.pin/2` — so that an
  oracle-bearing policy value is rejected BEFORE it is pinned to govern a unit.

  ## The gap (SPEC-FACTORY-GOV C206-B6 / INV-POLICY-DATA / issue #553)

  `SPEC-FACTORY-GOV §4 B6` specifies:

      clamp/1 at admission (pure); pin/2 freezes a version per unit;
      resolve/2 reads the pinned snapshot.

  `SPEC-FACTORY-GOV C206-B6` (★ = load-bearing) states:

      The engine-clamp/1 runs AT ADMISSION, BEFORE THE PIN — the pinned
      version is the *clamped* one. A policy value that could falsify a
      protected invariant is rejected/clamped *before* it ever governs a
      unit; an un-clamped value never reaches the engine.

  Without this wiring, `Gate.Oracle.select/1` (gate/oracle.ex:52–58) still
  accepts any `policy_pin.oracle` map from a unit's policy_pin and routes to
  the `Stub` — a policy VALUE substituting for real critic/reviewer gate
  enforcement. `Policy.clamp/1` existing but not called at admission is no
  better than it not existing at all.

  ## What is asserted

  1. `Tau.Factory.Policy.Owner.pin/2` is the real admission boundary (B6).
  2. When called with a candidate policy carrying `oracle: %{...}`, `pin/2`
     returns `{:error, {:oracle_substitution, :gate_result_enforcement_in_policy}}`
     and does NOT pin the policy to the unit's ETS snapshot.
  3. After a rejection, `Tau.Factory.Policy.Owner.resolve/2` for the same unit
     returns `{:error, :not_pinned}` confirming the unsafe policy was NOT admitted.
  4. A valid policy without an oracle key IS admitted — the guard is selective.

  ## Failure expectation

  `Tau.Factory.Policy.Owner` does not exist in lib/ on this branch. The test
  will fail with `UndefinedFunctionError` — the correct fail-before state for
  the oracle-separation phase. Do NOT resolve this by adding production code.

  ## AC / D-NNN linkage

  - INV-POLICY-DATA (issue #553)
  - SPEC-FACTORY-GOV §4 B6, C206-B6, HR-8
  """

  use ExUnit.Case, async: true

  @moduletag :inv_policy_data

  # Runtime module reference — compile-time safe even before the module exists.
  @owner Tau.Factory.Policy.Owner

  # ---------------------------------------------------------------------------
  # INV-POLICY-DATA: Policy.Owner.pin/2 MUST call clamp/1 at admission and
  # reject an oracle-substitution key before it governs any unit.
  # ---------------------------------------------------------------------------

  describe "INV-POLICY-DATA: Policy.Owner.pin/2 enforces clamp/1 at the admission boundary" do
    setup do
      owner_name = :"test_policy_owner_#{System.unique_integer([:positive])}"
      owner_pid = start_supervised!({@owner, name: owner_name})
      %{owner: owner_pid}
    end

    @tag :inv_policy_data
    test "INV-POLICY-DATA: pin/2 REJECTS a policy carrying an oracle map (gate-result enforcement in policy)",
         %{owner: owner} do
      unit_id = "test-unit-#{System.unique_integer([:positive])}"

      # A candidate policy carrying the oracle key — the direct falsification
      # example from INV-POLICY-DATA: a policy VALUE that would substitute for
      # real critic/reviewer gate enforcement if admitted.
      policy_with_oracle = %{
        gate_manifest: [:mutation, :critic, :reviewer],
        retry_bound_n: 3,
        gate_concurrency: 4,
        gate_timeout: 60_000,
        oracle: %{critic: :pass, reviewer: :pass}
      }

      result = @owner.pin(owner, unit_id, policy_with_oracle)

      assert match?({:error, _}, result),
             "INV-POLICY-DATA: Policy.Owner.pin/2 MUST reject a policy carrying an oracle " <>
               "key. pin/2 must call Policy.clamp/1 at admission (SPEC-FACTORY-GOV C206-B6) " <>
               "and return {:error, reason} when clamp/1 rejects the candidate. " <>
               "The oracle key is gate-result enforcement in policy data (HR-8). " <>
               "Got: #{inspect(result)}"

      {:error, reason} = result

      assert reason == {:oracle_substitution, :gate_result_enforcement_in_policy},
             "INV-POLICY-DATA: pin/2 rejection MUST carry the reason " <>
               "{:oracle_substitution, :gate_result_enforcement_in_policy} — the same " <>
               "reason Policy.clamp/1 produces. Got reason: #{inspect(reason)}"
    end

    @tag :inv_policy_data
    test "INV-POLICY-DATA: after pin/2 rejection, resolve/2 returns error (unsafe policy NOT admitted)",
         %{owner: owner} do
      unit_id = "test-unit-#{System.unique_integer([:positive])}"

      policy_with_oracle = %{
        gate_manifest: [:mutation, :critic, :reviewer],
        retry_bound_n: 3,
        gate_concurrency: 4,
        gate_timeout: 60_000,
        oracle: %{critic: :pass, reviewer: :pass}
      }

      # pin/2 should reject
      {:error, _} = @owner.pin(owner, unit_id, policy_with_oracle)

      # resolve/2 for the same unit_id must NOT return any oracle-carrying snapshot.
      resolve_result = @owner.resolve(owner, unit_id, :gate_manifest)

      assert match?({:error, _}, resolve_result),
             "INV-POLICY-DATA: after pin/2 rejects an oracle-carrying policy, " <>
               "resolve/2 for the same unit MUST return {:error, _} — confirming the " <>
               "unsafe policy was NOT admitted into the unit's ETS snapshot. " <>
               "Got: #{inspect(resolve_result)}"
    end

    @tag :inv_policy_data
    test "INV-POLICY-DATA: pin/2 ACCEPTS a policy with no oracle key (safe envelope admitted)",
         %{owner: owner} do
      unit_id = "test-unit-#{System.unique_integer([:positive])}"

      policy_without_oracle = %{
        gate_manifest: [:mutation, :critic, :reviewer],
        retry_bound_n: 3,
        gate_concurrency: 4,
        gate_timeout: 60_000
      }

      result = @owner.pin(owner, unit_id, policy_without_oracle)

      assert match?(:ok, result) or match?({:ok, _}, result),
             "INV-POLICY-DATA: Policy.Owner.pin/2 MUST accept a policy with no oracle key. " <>
               "The oracle guard is selective — rejects oracle-substitution values while " <>
               "admitting valid parameter sets. Got: #{inspect(result)}"

      resolve_result = @owner.resolve(owner, unit_id, :gate_manifest)

      assert match?({:ok, _}, resolve_result),
             "INV-POLICY-DATA: after a successful pin/2, resolve/2 MUST return {:ok, value} " <>
               "confirming the safe policy was admitted into the ETS snapshot. " <>
               "Got: #{inspect(resolve_result)}"
    end
  end
end
