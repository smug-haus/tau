defmodule Tau.Factory.PolicyModelRoleTest do
  @moduledoc """
  Gating test for issue #552 — INV-MODEL-POLICY.

  INV-MODEL-POLICY statement:
  > No role's model assignment is hardcoded in engine code; model per role
  > is a field in Tau.Factory.Policy, pinned per unit at admission, and
  > cost is attributed per (model, role). Falsified if any role's model is
  > determined by a hardcoded constant in engine code rather than the
  > policy field.

  Boundary governed: SPEC-FACTORY-GOV §4 B6 (Policy.Owner ↔ Policy):
    - `%Policy{}` struct carries `model_per_role :: %{role => model}` (FR-7.4).
    - `clamp/1 :: (Policy.t()) -> {:ok, Policy.t()} | {:error, term()}` —
      pure, property-tested; runs at admission before the pin.
    - `resolve/2 :: (unit_id, field) -> value` — reads the pinned ETS
      snapshot; returns the policy-driven value, NOT a hardcoded constant.

  The admission path exercised here is:
    Tau.Factory.Policy.Owner.start_link/1
      → Policy.Owner.pin/2 (pins policy at admission)
      → Policy.Owner.resolve/2 (reads the pinned snapshot for a given field)

  The three assertions below constitute the full INV-MODEL-POLICY conformance
  check at the B6 boundary:

  1. `%Policy{}` struct exists and has a `model_per_role` field — the invariant
     cannot hold if there is no such field.

  2. `clamp/1` passes a fully-specified policy through unchanged, preserving
     the caller-supplied `model_per_role` — the engine must not override the
     map with a hardcoded value on the happy path.

  3. After `pin/2` at admission and `resolve/2` for `:model_per_role`, the
     returned value equals the caller-supplied map — the engine must not
     substitute a hardcoded model in place of the pinned policy value.

  Written BEFORE production code exists (oracle-separation phase, factory-loop §4b).
  All three tests MUST FAIL against the current branch because:
    - `Tau.Factory.Policy` does not exist (no `defmodule`, no `defstruct`).
    - `Tau.Factory.Policy.Owner` does not exist.
  A compile error or UndefinedFunctionError is the correct fail-before state.

  ## Gating-test paths

    - `test/tau/factory/policy_model_role_test.exs`

  ## AC / D-NNN linkage

    - INV-MODEL-POLICY (issue #552)
  """

  use ExUnit.Case, async: true

  alias Tau.Factory.Policy
  alias Tau.Factory.Policy.Owner, as: PolicyOwner

  # ---------------------------------------------------------------------------
  # Minimal valid policy for testing.
  # Every field uses the smallest admissible positive integer for numeric
  # dimensions; model_per_role uses two representative roles.
  # ---------------------------------------------------------------------------

  @model_per_role %{
    implementer: "claude-sonnet-4-5",
    critic: "claude-opus-4-5"
  }

  @valid_policy %Policy{
    version: 1,
    model_per_role: @model_per_role,
    retry_bound_n: 3,
    budget: %{token: 100_000, cost: 10, wall_time: 3_600, iteration: 5},
    priority_order: [],
    conflict_predicate: &(&1 == &1 and &2 == &2),
    gate_manifest: [:mutation, :critic, :reviewer],
    escalation_thresholds: %{upheld_challenges: 2}
  }

  # ---------------------------------------------------------------------------
  # INV-MODEL-POLICY assertion 1 — struct field presence
  # ---------------------------------------------------------------------------

  describe "INV-MODEL-POLICY struct field" do
    @tag :inv_model_policy
    test "INV-MODEL-POLICY: %Policy{} struct has a :model_per_role field" do
      # The invariant cannot hold if there is no model_per_role field in the
      # Policy struct — the engine cannot resolve the policy-driven model for a
      # role if the field does not exist.
      #
      # FAIL BEFORE: Tau.Factory.Policy does not exist → compile error.

      policy = @valid_policy

      assert Map.has_key?(policy, :model_per_role),
             "INV-MODEL-POLICY: %Policy{} must carry a :model_per_role field " <>
               "(FR-7.4); the engine resolves the model per role from policy, " <>
               "not from a hardcoded constant. " <>
               "struct keys=#{inspect(Map.keys(policy))}"

      assert is_map(policy.model_per_role),
             "INV-MODEL-POLICY: :model_per_role must be a map of role => model; " <>
               "got #{inspect(policy.model_per_role)}"

      # Each value in the map must be a non-empty string (a real model id).
      for {role, model} <- policy.model_per_role do
        assert is_binary(model) and model != "",
               "INV-MODEL-POLICY: model_per_role[#{inspect(role)}] must be a " <>
                 "non-empty model-id string; got #{inspect(model)}"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # INV-MODEL-POLICY assertion 2 — clamp/1 preserves model_per_role
  # ---------------------------------------------------------------------------

  describe "INV-MODEL-POLICY clamp/1 preserves model_per_role" do
    @tag :inv_model_policy
    test "INV-MODEL-POLICY: clamp/1 returns {:ok, policy} with model_per_role intact on a valid policy" do
      # clamp/1 is the engine-clamp (HR-8): it rejects or tightens unsafe
      # policy values, but MUST NOT override model_per_role with a hardcoded
      # model string.  If clamp/1 substituted a hardcoded model it would
      # falsify INV-MODEL-POLICY by making the engine code the model source.
      #
      # FAIL BEFORE: Tau.Factory.Policy.clamp/1 does not exist → UndefinedFunctionError.

      assert {:ok, clamped} = Policy.clamp(@valid_policy),
             "INV-MODEL-POLICY: Policy.clamp/1 must return {:ok, policy} for a " <>
               "valid policy; got error instead"

      assert clamped.model_per_role == @model_per_role,
             "INV-MODEL-POLICY: clamp/1 must NOT overwrite model_per_role with a " <>
               "hardcoded value.  The caller-supplied map must survive the clamp " <>
               "unchanged (FR-7.4). " <>
               "expected=#{inspect(@model_per_role)}, " <>
               "got=#{inspect(clamped.model_per_role)}"
    end
  end

  # ---------------------------------------------------------------------------
  # INV-MODEL-POLICY assertion 3 — pin/2 + resolve/2 round-trip at admission
  # ---------------------------------------------------------------------------

  describe "INV-MODEL-POLICY pin/resolve round-trip at admission" do
    @tag :inv_model_policy
    test "INV-MODEL-POLICY: Policy.Owner pin/2 then resolve/2 for :model_per_role returns the policy-driven map, not a hardcoded constant" do
      # This test exercises the full B6 boundary (SPEC-FACTORY-GOV §4):
      #   Policy.Owner.pin(unit_id, clamped_policy)  — called at admission
      #   Policy.Owner.resolve(unit_id, :model_per_role)  — called by engine/cost
      #
      # The resolved value MUST equal the caller-supplied model_per_role from
      # the clamped policy, not a hardcoded string such as "claude-sonnet-4-5"
      # baked into the engine.  If any engine module hard-codes the model,
      # resolve/2 is either absent or returns a constant regardless of the pin.
      #
      # FAIL BEFORE: Tau.Factory.Policy.Owner does not exist → compile error or
      # UndefinedFunctionError on start_link/pin/resolve.

      unit_id = "test-unit-#{System.unique_integer([:positive])}"
      owner_name = :"policy_owner_test_#{System.unique_integer([:positive])}"

      {:ok, _owner} = PolicyOwner.start_link(name: owner_name)

      {:ok, clamped} = Policy.clamp(@valid_policy)

      :ok = PolicyOwner.pin(owner_name, unit_id, clamped)

      resolved = PolicyOwner.resolve(owner_name, unit_id, :model_per_role)

      assert resolved == @model_per_role,
             "INV-MODEL-POLICY: Policy.Owner.resolve/3 for :model_per_role after " <>
               "pin/3 must return the policy-driven map; a hardcoded constant " <>
               "would make the engine the model source and falsify INV-MODEL-POLICY. " <>
               "expected=#{inspect(@model_per_role)}, " <>
               "got=#{inspect(resolved)}"

      # Extra: verify that a *different* policy value for a second unit produces
      # a different resolved model_per_role — ruling out a global hardcoded default.
      alt_model_per_role = %{implementer: "claude-haiku-3-5", critic: "claude-haiku-3-5"}

      alt_policy = %Policy{clamped | model_per_role: alt_model_per_role}
      {:ok, clamped_alt} = Policy.clamp(alt_policy)

      unit_id_2 = "test-unit-alt-#{System.unique_integer([:positive])}"
      :ok = PolicyOwner.pin(owner_name, unit_id_2, clamped_alt)

      resolved_alt = PolicyOwner.resolve(owner_name, unit_id_2, :model_per_role)

      assert resolved_alt == alt_model_per_role,
             "INV-MODEL-POLICY: two units with different model_per_role policies " <>
               "must resolve independently — a hardcoded global constant would " <>
               "make both resolve to the same value. " <>
               "unit_1 resolved=#{inspect(resolved)}, " <>
               "unit_2 expected=#{inspect(alt_model_per_role)}, " <>
               "unit_2 got=#{inspect(resolved_alt)}"
    end
  end
end
