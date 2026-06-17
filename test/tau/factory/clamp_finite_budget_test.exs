defmodule Tau.Factory.ClampFiniteBudgetTest do
  @moduledoc """
  Gating test for INV-CLAMP-FINITE-BUDGET (issue #589).

  Invariant statement (from issue body):
  "Every admitted policy must have strictly positive integer values for all
  four budget dimensions (token, cost, wall_time, iteration). An
  infinite-budget sentinel (:infinity, nil, or <=0) must be REJECTED (not
  clamped). Falsified if a policy with a non-positive or non-integer budget
  dimension is admitted."

  ## The gap this closes

  `Tau.Factory.Policy.clamp/1` (policy.ex:109-122) implements
  `reject_infinite_budget/1` with three conformance gaps against the invariant:

  1. A `nil` budget dimension hits the `nil -> {:cont, :ok}` clause — silently
     admitted. The invariant requires REJECTION: nil is an infinite-budget
     sentinel.

  2. A non-integer (float) budget dimension — e.g. `1.5` — is neither
     `:infinity` nor `<= 0`, so it passes the guard. The invariant requires ALL
     FOUR dimensions to be **positive integers**; a float is not a positive
     integer.

  3. A policy that omits all four budget dimensions is admitted because the
     `Enum.reduce_while` over `@budget_dimensions` finds no keys to inspect. The
     invariant demands all four dimensions be **present** and strictly positive
     integers.

  ## Boundary exercised

  `Tau.Factory.Policy.clamp/1` — the real engine-clamp entry point defined in
  `lib/tau/factory/policy.ex`. NOT a hand-built struct that bypasses it.

  ## Failure expectation

  Tests assert rejection (`{:error, _}`) for nil, float, missing, zero, and
  negative budget dimensions. The current production code returns `{:ok, _}` for
  these cases — the nil, float, and missing-dimensions tests FAIL against current
  `lib/`.

  ## AC / D-NNN linkage

  - INV-CLAMP-FINITE-BUDGET (issue #589)
  - SPEC-FACTORY-GOV §4 B6 (`reject_infinite_budget`), D-320, D-321
  - docs/arch/04-software-architecture/governance.md:214-217
  """

  use ExUnit.Case, async: true

  @moduletag :inv_clamp_finite_budget

  @policy Tau.Factory.Policy

  # A minimal valid policy struct satisfying every guard EXCEPT budget.
  # Individual tests override budget dimensions.
  defp base_policy(budget_overrides \\ %{}) do
    base = %{
      gate_manifest: [:mutation, :critic, :reviewer],
      retry_bound_n: 3
    }

    Map.merge(base, budget_overrides)
  end

  # A fully-valid policy with all four budget dimensions set to positive integers.
  # MUST be accepted by clamp/1 — used as the positive-control baseline.
  defp valid_budget_policy do
    base_policy(%{
      token: 100_000,
      cost: 5_000_000,
      wall_time: 3_600,
      iteration: 10
    })
  end

  # ---------------------------------------------------------------------------
  # Positive control — fully valid policy is admitted
  # ---------------------------------------------------------------------------

  describe "INV-CLAMP-FINITE-BUDGET: positive control — valid policy is admitted" do
    @tag :inv_clamp_finite_budget
    test "INV-CLAMP-FINITE-BUDGET: a policy with all four budget dimensions as strictly positive integers is accepted by clamp/1" do
      result = @policy.clamp(valid_budget_policy())

      assert match?({:ok, _}, result),
             "INV-CLAMP-FINITE-BUDGET: clamp/1 MUST accept a policy with all four budget " <>
               "dimensions (token, cost, wall_time, iteration) set to strictly positive " <>
               "integers. Got: #{inspect(result)}"
    end
  end

  # ---------------------------------------------------------------------------
  # nil sentinel MUST be rejected
  # ---------------------------------------------------------------------------

  describe "INV-CLAMP-FINITE-BUDGET: nil sentinel in any budget dimension is REJECTED" do
    @tag :inv_clamp_finite_budget
    test "INV-CLAMP-FINITE-BUDGET: nil token dimension is rejected — nil is an infinite-budget sentinel" do
      policy = base_policy(%{token: nil, cost: 100, wall_time: 3_600, iteration: 10})

      result = @policy.clamp(policy)

      assert match?({:error, _}, result),
             "INV-CLAMP-FINITE-BUDGET: clamp/1 MUST reject a policy with token: nil. " <>
               "nil is an infinite-budget sentinel (SPEC-FACTORY-GOV §4 B6 / D-320). " <>
               "Current code admits it. Got: #{inspect(result)}"
    end

    @tag :inv_clamp_finite_budget
    test "INV-CLAMP-FINITE-BUDGET: nil cost dimension is rejected" do
      policy = base_policy(%{token: 100, cost: nil, wall_time: 3_600, iteration: 10})

      result = @policy.clamp(policy)

      assert match?({:error, _}, result),
             "INV-CLAMP-FINITE-BUDGET: clamp/1 MUST reject a policy with cost: nil. " <>
               "Got: #{inspect(result)}"
    end

    @tag :inv_clamp_finite_budget
    test "INV-CLAMP-FINITE-BUDGET: nil wall_time dimension is rejected" do
      policy = base_policy(%{token: 100, cost: 100, wall_time: nil, iteration: 10})

      result = @policy.clamp(policy)

      assert match?({:error, _}, result),
             "INV-CLAMP-FINITE-BUDGET: clamp/1 MUST reject a policy with wall_time: nil. " <>
               "Got: #{inspect(result)}"
    end

    @tag :inv_clamp_finite_budget
    test "INV-CLAMP-FINITE-BUDGET: nil iteration dimension is rejected" do
      policy = base_policy(%{token: 100, cost: 100, wall_time: 3_600, iteration: nil})

      result = @policy.clamp(policy)

      assert match?({:error, _}, result),
             "INV-CLAMP-FINITE-BUDGET: clamp/1 MUST reject a policy with iteration: nil. " <>
               "Got: #{inspect(result)}"
    end
  end

  # ---------------------------------------------------------------------------
  # :infinity sentinel MUST be rejected
  # ---------------------------------------------------------------------------

  describe "INV-CLAMP-FINITE-BUDGET: :infinity sentinel in any budget dimension is REJECTED" do
    @tag :inv_clamp_finite_budget
    test "INV-CLAMP-FINITE-BUDGET: :infinity token dimension is rejected" do
      policy = base_policy(%{token: :infinity, cost: 100, wall_time: 3_600, iteration: 10})

      result = @policy.clamp(policy)

      assert match?({:error, _}, result),
             "INV-CLAMP-FINITE-BUDGET: clamp/1 MUST reject token: :infinity. " <>
               "Got: #{inspect(result)}"
    end

    @tag :inv_clamp_finite_budget
    test "INV-CLAMP-FINITE-BUDGET: :infinity iteration dimension is rejected" do
      policy = base_policy(%{token: 100, cost: 100, wall_time: 3_600, iteration: :infinity})

      result = @policy.clamp(policy)

      assert match?({:error, _}, result),
             "INV-CLAMP-FINITE-BUDGET: clamp/1 MUST reject iteration: :infinity. " <>
               "Got: #{inspect(result)}"
    end
  end

  # ---------------------------------------------------------------------------
  # Zero and negative values MUST be rejected
  # ---------------------------------------------------------------------------

  describe "INV-CLAMP-FINITE-BUDGET: zero and negative values in any budget dimension are REJECTED" do
    @tag :inv_clamp_finite_budget
    test "INV-CLAMP-FINITE-BUDGET: zero token dimension is rejected (not a strictly positive integer)" do
      policy = base_policy(%{token: 0, cost: 100, wall_time: 3_600, iteration: 10})

      result = @policy.clamp(policy)

      assert match?({:error, _}, result),
             "INV-CLAMP-FINITE-BUDGET: clamp/1 MUST reject token: 0. " <>
               "Strictly positive integer means > 0. Got: #{inspect(result)}"
    end

    @tag :inv_clamp_finite_budget
    test "INV-CLAMP-FINITE-BUDGET: negative cost dimension is rejected" do
      policy = base_policy(%{token: 100, cost: -1, wall_time: 3_600, iteration: 10})

      result = @policy.clamp(policy)

      assert match?({:error, _}, result),
             "INV-CLAMP-FINITE-BUDGET: clamp/1 MUST reject cost: -1. Got: #{inspect(result)}"
    end
  end

  # ---------------------------------------------------------------------------
  # Non-integer (float) values MUST be rejected
  # ---------------------------------------------------------------------------

  describe "INV-CLAMP-FINITE-BUDGET: non-integer (float) values in any budget dimension are REJECTED" do
    @tag :inv_clamp_finite_budget
    test "INV-CLAMP-FINITE-BUDGET: float token dimension is rejected — 1.5 is not a positive integer" do
      policy = base_policy(%{token: 1.5, cost: 100, wall_time: 3_600, iteration: 10})

      result = @policy.clamp(policy)

      assert match?({:error, _}, result),
             "INV-CLAMP-FINITE-BUDGET: clamp/1 MUST reject token: 1.5. " <>
               "The invariant requires *integer* values; a float is not a positive integer. " <>
               "Current code admits floats. Got: #{inspect(result)}"
    end

    @tag :inv_clamp_finite_budget
    test "INV-CLAMP-FINITE-BUDGET: float wall_time dimension is rejected — 3600.0 is not a positive integer" do
      policy = base_policy(%{token: 100, cost: 100, wall_time: 3_600.0, iteration: 10})

      result = @policy.clamp(policy)

      assert match?({:error, _}, result),
             "INV-CLAMP-FINITE-BUDGET: clamp/1 MUST reject wall_time: 3600.0. " <>
               "A float is not a positive integer. Got: #{inspect(result)}"
    end
  end

  # ---------------------------------------------------------------------------
  # Missing budget dimensions MUST be rejected
  # ---------------------------------------------------------------------------

  describe "INV-CLAMP-FINITE-BUDGET: a policy missing ANY of the four required budget dimensions is REJECTED" do
    @tag :inv_clamp_finite_budget
    test "INV-CLAMP-FINITE-BUDGET: a policy with NO budget dimensions is rejected — all four are required" do
      # A policy with only gate_manifest and retry_bound_n — no budget dimension
      # keys at all. The invariant requires ALL FOUR present and strictly positive
      # integers; absence is not admissible.
      policy = base_policy()

      result = @policy.clamp(policy)

      assert match?({:error, _}, result),
             "INV-CLAMP-FINITE-BUDGET: clamp/1 MUST reject a policy that omits all four " <>
               "budget dimensions (token, cost, wall_time, iteration). " <>
               "All four must be strictly positive integers. " <>
               "Current code admits a policy with no budget dimensions. Got: #{inspect(result)}"
    end

    @tag :inv_clamp_finite_budget
    test "INV-CLAMP-FINITE-BUDGET: a policy missing the iteration dimension is rejected" do
      # Three dimensions present, one missing.
      policy = base_policy(%{token: 100, cost: 100, wall_time: 3_600})

      result = @policy.clamp(policy)

      assert match?({:error, _}, result),
             "INV-CLAMP-FINITE-BUDGET: clamp/1 MUST reject a policy missing the `iteration` " <>
               "dimension. All four (token, cost, wall_time, iteration) are required. " <>
               "Got: #{inspect(result)}"
    end

    @tag :inv_clamp_finite_budget
    test "INV-CLAMP-FINITE-BUDGET: a policy missing the token dimension is rejected" do
      policy = base_policy(%{cost: 100, wall_time: 3_600, iteration: 10})

      result = @policy.clamp(policy)

      assert match?({:error, _}, result),
             "INV-CLAMP-FINITE-BUDGET: clamp/1 MUST reject a policy missing the `token` " <>
               "dimension. Got: #{inspect(result)}"
    end
  end

  # ---------------------------------------------------------------------------
  # Error reason specificity — SPEC-FACTORY-GOV §4 B6 names {:error, {:infinite_budget, dim}}
  # ---------------------------------------------------------------------------

  describe "INV-CLAMP-FINITE-BUDGET: error reason identifies the offending dimension" do
    @tag :inv_clamp_finite_budget
    test "INV-CLAMP-FINITE-BUDGET: rejection of nil token includes the dimension in the error reason" do
      policy = base_policy(%{token: nil, cost: 100, wall_time: 3_600, iteration: 10})

      result = @policy.clamp(policy)

      # At minimum: clamp/1 must reject (not admit).
      refute match?({:ok, _}, result),
             "INV-CLAMP-FINITE-BUDGET: clamp/1 MUST NOT return {:ok, _} for a nil budget " <>
               "dimension. Got: #{inspect(result)}"

      # Preferred reason per SPEC-FACTORY-GOV §4 B6:
      assert match?({:error, {:infinite_budget, :token}}, result) or
               match?({:error, _}, result),
             "INV-CLAMP-FINITE-BUDGET: rejection of nil token SHOULD produce " <>
               "{:error, {:infinite_budget, :token}} per SPEC-FACTORY-GOV §4 B6. " <>
               "At minimum it must be {:error, _}. Got: #{inspect(result)}"
    end

    @tag :inv_clamp_finite_budget
    test "INV-CLAMP-FINITE-BUDGET: rejection of float cost includes the dimension in the error reason" do
      policy = base_policy(%{token: 100, cost: 999.99, wall_time: 3_600, iteration: 10})

      result = @policy.clamp(policy)

      refute match?({:ok, _}, result),
             "INV-CLAMP-FINITE-BUDGET: clamp/1 MUST NOT admit a float cost dimension. " <>
               "Got: #{inspect(result)}"

      assert match?({:error, {:infinite_budget, :cost}}, result) or
               match?({:error, _}, result),
             "INV-CLAMP-FINITE-BUDGET: rejection of float cost SHOULD produce " <>
               "{:error, {:infinite_budget, :cost}}. At minimum {:error, _}. Got: #{inspect(result)}"
    end
  end
end
