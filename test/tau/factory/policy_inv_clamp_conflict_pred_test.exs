defmodule Tau.Factory.PolicyInvClampConflictPredTest do
  @moduledoc """
  Gating test for issue #588 — INV-CLAMP-CONFLICT-PRED.

  INV-CLAMP-CONFLICT-PRED statement:
  > The effective conflict predicate for a unit is always (engine_floor AND
  > policy_pred), meaning policy predicates may only TIGHTEN (narrow) the set
  > of admissible concurrent work, never loosen it. Falsified if a policy
  > conflict predicate admits work that the engine's floor predicate would deny.

  The invariant is owned by SPEC-FACTORY-GOV B6 / HR-8; the architecture
  pseudocode is at docs/arch/04-software-architecture/governance.md lines 219-222:

      defp floor_conflict_predicate(policy_pred),
        do: {:ok, &(ConflictCheck.engine_floor(&1, &2) and policy_pred.(&1, &2))}

  Real entry point exercised:
    Tau.Factory.Policy.clamp/1  ->  the clamped %Policy{}.conflict_predicate field
    Tau.Factory.Scheduler.admit/4  ->  integration boundary (enforces clamped predicate)

  ## Gating-test paths

    - test/tau/factory/policy_inv_clamp_conflict_pred_test.exs

  ## AC / D-NNN linkage

    - INV-CLAMP-CONFLICT-PRED (issue #588)
  """

  use ExUnit.Case, async: true

  alias Tau.Factory.ConflictCheck
  alias Tau.Factory.Policy
  alias Tau.Factory.Scheduler

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp scope_with_files(files, codepoints \\ MapSet.new()) do
    %{
      deps: [],
      files: MapSet.new(files),
      codepoints: codepoints,
      specs: MapSet.new(),
      resources: MapSet.new()
    }
  end

  # MFA references required — module attributes must be escapable literals;
  # anonymous function literals are not.
  def always_admit(_a, _b), do: true
  def always_deny(_a, _b), do: false

  @permissive_pred &__MODULE__.always_admit/2
  @restrictive_pred &__MODULE__.always_deny/2

  @valid_gate_manifest [:mutation, :critic, :reviewer]

  @base_policy %Policy{
    version: 1,
    model_per_role: %{implementer: "claude-sonnet-4-5", critic: "claude-opus-4-5"},
    retry_bound_n: 3,
    budget: %{token: 100_000, cost: 10, wall_time: 3_600, iteration: 5},
    priority_order: [],
    conflict_predicate: @permissive_pred,
    gate_manifest: @valid_gate_manifest,
    escalation_thresholds: %{upheld_challenges: 2}
  }

  # ---------------------------------------------------------------------------
  # INV-CLAMP-CONFLICT-PRED: Policy.clamp/1 unit-level composition tests
  # ---------------------------------------------------------------------------

  describe "INV-CLAMP-CONFLICT-PRED Policy.clamp/1 composes floor with policy_pred" do
    @tag :inv_clamp_conflict_pred
    test "INV-CLAMP-CONFLICT-PRED: clamped predicate denies overlapping files even when policy_pred admits" do
      # engine_floor(scope_a, scope_b) is FALSE when files overlap.
      # A permissive policy_pred returns TRUE.
      # The composition (engine_floor AND policy_pred) MUST be FALSE — the floor wins.
      #
      # FAIL BEFORE: Policy.clamp/1 exists and correctly composes the predicate.
      # The unit-level clamp test PASSES. However, the INTEGRATION test below
      # (Scheduler.admit/4) FAILS because the Scheduler ignores the pinned policy's
      # conflict_predicate (scheduler.ex line 151 calls ConflictCheck.clear? directly
      # with no composition layer — evidence from issue #588).

      scope_a = scope_with_files(["lib/tau/factory/coordinator.ex"])
      scope_b = scope_with_files(["lib/tau/factory/coordinator.ex"])

      refute ConflictCheck.engine_floor(scope_a, scope_b),
             "pre-condition: engine_floor must deny overlapping-file scopes"

      permissive = @permissive_pred
      assert permissive.(scope_a, scope_b),
             "pre-condition: permissive policy_pred must return true"

      policy = %Policy{@base_policy | conflict_predicate: permissive}

      assert {:ok, clamped} = Policy.clamp(policy),
             "INV-CLAMP-CONFLICT-PRED: Policy.clamp/1 must return {:ok, _} for a " <>
               "valid policy; got #{inspect(Policy.clamp(policy))}"

      clamped_pred = clamped.conflict_predicate

      refute clamped_pred.(scope_a, scope_b),
             "INV-CLAMP-CONFLICT-PRED: the clamped conflict_predicate MUST return " <>
               "false for overlapping-file scopes — the engine floor (file+codepoint " <>
               "disjointness) cannot be relaxed by a permissive policy_pred. " <>
               "A true result means the floor was bypassed, falsifying the invariant " <>
               "(governance.md lines 219-222)."
    end

    @tag :inv_clamp_conflict_pred
    test "INV-CLAMP-CONFLICT-PRED: clamped predicate denies overlapping codepoints even when policy_pred admits" do
      shared_cp = MapSet.new([{"lib/tau/factory/scheduler.ex", :admit}])
      scope_a = scope_with_files(["lib/tau/factory/other_a.ex"], shared_cp)
      scope_b = scope_with_files(["lib/tau/factory/other_b.ex"], shared_cp)

      refute ConflictCheck.engine_floor(scope_a, scope_b),
             "pre-condition: engine_floor must deny overlapping-codepoint scopes"

      policy = %Policy{@base_policy | conflict_predicate: @permissive_pred}

      assert {:ok, clamped} = Policy.clamp(policy),
             "INV-CLAMP-CONFLICT-PRED: Policy.clamp/1 must return {:ok, _}"

      clamped_pred = clamped.conflict_predicate

      refute clamped_pred.(scope_a, scope_b),
             "INV-CLAMP-CONFLICT-PRED: clamped predicate MUST deny overlapping " <>
               "codepoint scopes regardless of permissive policy_pred (INV-13 / HR-8)."
    end

    @tag :inv_clamp_conflict_pred
    test "INV-CLAMP-CONFLICT-PRED: clamped predicate admits disjoint scopes when policy_pred admits (T AND T = T)" do
      scope_a = scope_with_files(["lib/tau/factory/coordinator.ex"])
      scope_b = scope_with_files(["lib/tau/factory/scheduler.ex"])

      assert ConflictCheck.engine_floor(scope_a, scope_b),
             "pre-condition: engine_floor must admit disjoint-file scopes"

      policy = %Policy{@base_policy | conflict_predicate: @permissive_pred}

      assert {:ok, clamped} = Policy.clamp(policy),
             "INV-CLAMP-CONFLICT-PRED: Policy.clamp/1 must return {:ok, _}"

      clamped_pred = clamped.conflict_predicate

      assert clamped_pred.(scope_a, scope_b),
             "INV-CLAMP-CONFLICT-PRED: clamped predicate MUST admit when both " <>
               "engine_floor and policy_pred admit (T AND T = T). " <>
               "An over-restrictive clamp would falsify the invariant."
    end

    @tag :inv_clamp_conflict_pred
    test "INV-CLAMP-CONFLICT-PRED: restrictive policy_pred blocks even when engine_floor admits (T AND F = F)" do
      scope_a = scope_with_files(["lib/tau/factory/coordinator.ex"])
      scope_b = scope_with_files(["lib/tau/factory/scheduler.ex"])

      assert ConflictCheck.engine_floor(scope_a, scope_b),
             "pre-condition: engine_floor must admit disjoint-file scopes"

      policy = %Policy{@base_policy | conflict_predicate: @restrictive_pred}

      assert {:ok, clamped} = Policy.clamp(policy),
             "INV-CLAMP-CONFLICT-PRED: Policy.clamp/1 must return {:ok, _}"

      clamped_pred = clamped.conflict_predicate

      refute clamped_pred.(scope_a, scope_b),
             "INV-CLAMP-CONFLICT-PRED: a restrictive policy_pred MUST still block " <>
               "when engine_floor admits — tightening must be respected (T AND F = F). " <>
               "If this returns true, the AND composition is broken."
    end
  end

  # ---------------------------------------------------------------------------
  # INV-CLAMP-CONFLICT-PRED: Scheduler.admit/4 enforces the clamped predicate
  #
  # This is the integration boundary where the invariant is actually enforced.
  # The issue evidence (scheduler.ex:151) shows the Scheduler calls
  # ConflictCheck.clear?/2 directly with no policy-predicate composition layer,
  # so even a correctly-composed clamped predicate is never consulted at admission.
  #
  # Test: when a policy_pred would block a scope pair that engine_floor admits,
  # Scheduler.admit/4 with a pinned clamped policy MUST honour it and return
  # {:defer, {:conflict, _}}.
  # ---------------------------------------------------------------------------

  describe "INV-CLAMP-CONFLICT-PRED Scheduler.admit/4 enforces clamped conflict_predicate at admission boundary" do
    setup do
      name = :"test_sched_inv_ccp_#{:erlang.unique_integer([:positive])}"

      {:ok, _pid} =
        Scheduler.start_link(
          name: name,
          w_cap: 10
        )

      %{scheduler: name}
    end

    @tag :inv_clamp_conflict_pred
    test "INV-CLAMP-CONFLICT-PRED: Scheduler.admit/4 defers when clamped policy_pred conflicts but engine_floor admits",
         %{scheduler: scheduler} do
      # Two scopes with DISJOINT files — engine_floor ADMITS them.
      # Policy conflict_predicate is always_deny — the clamped effective predicate is:
      #   (engine_floor AND always_deny) = (true AND false) = false
      # So the Scheduler MUST defer the second unit with {:defer, {:conflict, _}}.
      #
      # FAIL BEFORE: Scheduler.admit/4 calls ConflictCheck.clear?/2 directly,
      # ignoring the pinned policy's conflict_predicate. Because engine_floor
      # admits disjoint scopes, it returns :admit instead of {:defer, {:conflict, _}},
      # falsifying INV-CLAMP-CONFLICT-PRED.

      scope_a = scope_with_files(["lib/tau/factory/coordinator.ex"])
      scope_b = scope_with_files(["lib/tau/factory/scheduler.ex"])

      assert ConflictCheck.engine_floor(scope_a, scope_b),
             "pre-condition: engine_floor must admit disjoint-file scopes"

      restrictive_policy = %Policy{@base_policy | conflict_predicate: @restrictive_pred}

      assert {:ok, clamped_policy} = Policy.clamp(restrictive_policy),
             "INV-CLAMP-CONFLICT-PRED: Policy.clamp/1 must return {:ok, _}; " <>
               "got #{inspect(Policy.clamp(restrictive_policy))}"

      # Verify the clamped predicate itself correctly denies (T AND F = F).
      clamped_pred = clamped_policy.conflict_predicate

      refute clamped_pred.(scope_a, scope_b),
             "pre-condition: clamped predicate must deny disjoint scopes under always_deny policy"

      # Admit unit A — must succeed (empty in-flight set).
      assert :admit = Scheduler.admit(scheduler, "unit-a", scope_a, clamped_policy),
             "INV-CLAMP-CONFLICT-PRED: first admit must succeed (empty in-flight set)"

      # Attempt to admit unit B — the clamped policy's conflict_predicate denies this pair.
      # Scheduler MUST consult it and return {:defer, {:conflict, _}}.
      result = Scheduler.admit(scheduler, "unit-b", scope_b, clamped_policy)

      assert match?({:defer, {:conflict, _}}, result),
             "INV-CLAMP-CONFLICT-PRED: Scheduler.admit/4 MUST defer unit-b when the " <>
               "clamped policy's conflict_predicate denies the pair, even though " <>
               "engine_floor alone would admit them (disjoint files). " <>
               "Got: #{inspect(result)}. " <>
               "Evidence: scheduler.ex line 151 calls ConflictCheck.clear? directly " <>
               "with no (engine_floor AND policy_pred) composition layer (issue #588)."
    end

    @tag :inv_clamp_conflict_pred
    test "INV-CLAMP-CONFLICT-PRED: Scheduler.admit/4 admits when both engine_floor and policy_pred admit",
         %{scheduler: scheduler} do
      # Positive case: both floor and policy_pred admit => Scheduler MUST admit.
      scope_a = scope_with_files(["lib/tau/factory/coordinator.ex"])
      scope_b = scope_with_files(["lib/tau/factory/scheduler.ex"])

      permissive_policy = %Policy{@base_policy | conflict_predicate: @permissive_pred}

      assert {:ok, clamped_policy} = Policy.clamp(permissive_policy),
             "INV-CLAMP-CONFLICT-PRED: Policy.clamp/1 must return {:ok, _}; " <>
               "got #{inspect(Policy.clamp(permissive_policy))}"

      assert :admit = Scheduler.admit(scheduler, "unit-a", scope_a, clamped_policy),
             "INV-CLAMP-CONFLICT-PRED: first admit must succeed"

      assert :admit = Scheduler.admit(scheduler, "unit-b", scope_b, clamped_policy),
             "INV-CLAMP-CONFLICT-PRED: second admit must succeed when both " <>
               "engine_floor and policy_pred admit disjoint scopes (T AND T = T)."
    end
  end
end
