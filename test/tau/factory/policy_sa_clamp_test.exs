defmodule Tau.Factory.PolicySaClampTest do
  @moduledoc """
  Gating test for issue #608 — INV-SA-POLICY-CLAMP (PARTIAL verdict).

  INV-SA-POLICY-CLAMP statement:
  > Safety-relevant policy values are engine-clamped: the gate floor is
  > non-shrinkable, retry bound N = min(policy, ceiling), infinite retry bound
  > (∞) is rejected, and the conflict predicate floor is only tightened (never
  > relaxed). Falsified if any policy value causes a safety invariant's
  > enforcement to be weaker than its engine-defined floor.

  Verdict: PARTIAL. The gate-floor and conflict-predicate halves are
  enforced (lib/tau/factory/gate.ex:79-95, lib/tau/factory/conflict_check.ex).
  The TWO UNENFORCED halves — exercised here — are:

    (a) retry_bound_n = min(policy, ceiling) — a policy value exceeding the
        engine ceiling (@hard_ceiling_n = 3) is NOT clamped; the clamp
        function Tau.Factory.Policy.clamp/1 does not exist.

    (b) infinite retry bound (∞) is rejected — Policy.clamp/1 must return
        {:error, _} when retry_bound_n is :infinity (or equivalent sentinel);
        this enforcement is absent.

  Boundary governed: SPEC-FACTORY-CORE §4, D-318; docs/arch/04-software-
  architecture/governance.md §3 "Engine-clamp (HR-8)".

  Real entry point exercised:
    Tau.Factory.Policy.clamp/1

  This function is specified as:
    @spec clamp(Policy.t()) :: {:ok, Policy.t()} | {:error, term()}

  with the engine-fixed constant:
    @hard_ceiling_n 3  (min of policy and ceiling; ∞ is rejected, not clamped)

  Written BEFORE production code exists (oracle-separation phase, factory-loop §4b).
  All tests MUST FAIL against the current branch because:
    - Tau.Factory.Policy does not exist (no defmodule, no defstruct).
    - Tau.Factory.Policy.clamp/1 does not exist.
  A compile error or UndefinedFunctionError is the correct fail-before state.

  ## Implementation note on conflict_predicate
  Elixir module attributes are injected into function/macro call sites at
  compile time and must be escapable AST literals. Anonymous functions (closures
  created with `&(&1 == ...)`) are NOT escapable and cause a compile-time
  `ArgumentError: cannot inject attribute @…`. The `conflict_predicate` field is
  a function type (governance.md §3), so a valid value must be supplied — but it
  MUST be an MFA reference (`&Mod.fun/arity`), not an anonymous function literal.
  This test uses `&__MODULE__.trivial_predicate/2` to satisfy the type constraint
  without triggering the module-attribute escaping restriction. This choice does
  not weaken any invariant: INV-SA-POLICY-CLAMP is about retry_bound_n clamping,
  not about the conflict predicate.

  ## Gating-test paths

    - test/tau/factory/policy_sa_clamp_test.exs

  ## AC / D-NNN linkage

    - INV-SA-POLICY-CLAMP (issue #608)
  """

  use ExUnit.Case, async: true

  alias Tau.Factory.Policy

  # Engine-fixed ceiling from governance.md §3 (@hard_ceiling_n = 3).
  # A policy value exceeding this MUST be clamped down; :infinity MUST be rejected.
  @hard_ceiling_n 3

  # ---------------------------------------------------------------------------
  # MFA reference for conflict_predicate.
  # Elixir module attributes must hold escapable values; anonymous function
  # literals are not escapable (ArgumentError at compile time). An MFA
  # reference is escapable and satisfies the function-typed field requirement.
  # ---------------------------------------------------------------------------

  # Trivial conflict predicate — always returns true, i.e., no admission is blocked.
  # Used only to satisfy the struct type; the tests here concern retry_bound_n.
  def trivial_predicate(_a, _b), do: true

  @conflict_predicate_mfa &__MODULE__.trivial_predicate/2

  @valid_gate_manifest [:mutation, :critic, :reviewer]

  @base_policy %Policy{
    version: 1,
    model_per_role: %{implementer: "claude-sonnet-4-5", critic: "claude-opus-4-5"},
    retry_bound_n: @hard_ceiling_n,
    budget: %{token: 100_000, cost: 10, wall_time: 3_600, iteration: 5},
    priority_order: [],
    conflict_predicate: @conflict_predicate_mfa,
    gate_manifest: @valid_gate_manifest,
    escalation_thresholds: %{upheld_challenges: 2}
  }

  # ---------------------------------------------------------------------------
  # INV-SA-POLICY-CLAMP (a) — retry_bound_n = min(policy, ceiling)
  # ---------------------------------------------------------------------------

  describe "INV-SA-POLICY-CLAMP retry_bound_n clamping" do
    @tag :inv_sa_policy_clamp
    test "INV-SA-POLICY-CLAMP: clamp/1 caps retry_bound_n at @hard_ceiling_n when policy exceeds it" do
      # A caller supplies retry_bound_n = 10 (above the hard ceiling of 3).
      # clamp/1 MUST return {:ok, clamped_policy} with clamped_policy.retry_bound_n == 3.
      # If the clamp is absent, a unit would be allowed 10 refine steps, defeating
      # LIV-1 (termination) and falsifying D-318 / INV-SA-POLICY-CLAMP.
      #
      # FAIL BEFORE: Tau.Factory.Policy.clamp/1 does not exist → UndefinedFunctionError.

      over_ceiling = @hard_ceiling_n + 7

      policy_over = %Policy{@base_policy | retry_bound_n: over_ceiling}

      result = Policy.clamp(policy_over)

      assert match?({:ok, _}, result),
             "INV-SA-POLICY-CLAMP: Policy.clamp/1 must return {:ok, _} for an " <>
               "otherwise-valid policy with retry_bound_n=#{over_ceiling} > ceiling=#{@hard_ceiling_n}; " <>
               "got #{inspect(result)}"

      {:ok, clamped} = result

      assert clamped.retry_bound_n == @hard_ceiling_n,
             "INV-SA-POLICY-CLAMP: retry_bound_n MUST be clamped to the engine " <>
               "ceiling #{@hard_ceiling_n} (N = min(policy, ceiling), D-318); " <>
               "policy supplied #{over_ceiling}, clamp returned #{clamped.retry_bound_n}"
    end

    @tag :inv_sa_policy_clamp
    test "INV-SA-POLICY-CLAMP: clamp/1 leaves retry_bound_n unchanged when it is at or below the ceiling" do
      # A policy value at or below the ceiling must pass through unchanged —
      # the clamp must not reduce a legitimate value below the floor.
      #
      # FAIL BEFORE: Tau.Factory.Policy.clamp/1 does not exist → UndefinedFunctionError.

      for n <- 1..@hard_ceiling_n do
        policy_at = %Policy{@base_policy | retry_bound_n: n}

        result = Policy.clamp(policy_at)

        assert match?({:ok, _}, result),
               "INV-SA-POLICY-CLAMP: clamp/1 must return {:ok, _} for retry_bound_n=#{n} " <>
                 "(≤ ceiling=#{@hard_ceiling_n}); got #{inspect(result)}"

        {:ok, clamped} = result

        assert clamped.retry_bound_n == n,
               "INV-SA-POLICY-CLAMP: clamp/1 MUST NOT reduce retry_bound_n below the " <>
                 "caller-supplied value when it is already within the ceiling. " <>
                 "Expected #{n}, got #{clamped.retry_bound_n}"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # INV-SA-POLICY-CLAMP (b) — infinite retry bound (:infinity) is REJECTED
  # ---------------------------------------------------------------------------

  describe "INV-SA-POLICY-CLAMP infinite retry_bound_n rejection" do
    @tag :inv_sa_policy_clamp
    test "INV-SA-POLICY-CLAMP: clamp/1 rejects retry_bound_n = :infinity with {:error, _}" do
      # An infinite retry bound defeats LIV-1 (termination): a unit could refine
      # forever. The arch specifies that ∞ is REJECTED, not clamped
      # (governance.md §3: "∞ rejected"). clamp/1 MUST return {:error, _} —
      # a non-integer or :infinity sentinel MUST NOT silently become 3.
      #
      # FAIL BEFORE: Tau.Factory.Policy.clamp/1 does not exist → UndefinedFunctionError.

      policy_inf = %Policy{@base_policy | retry_bound_n: :infinity}

      result = Policy.clamp(policy_inf)

      assert match?({:error, _}, result),
             "INV-SA-POLICY-CLAMP: Policy.clamp/1 MUST return {:error, _} when " <>
               "retry_bound_n = :infinity; silently clamping to 3 is insufficient — " <>
               "the arch mandates rejection, not clamping, for the ∞ sentinel (D-318). " <>
               "got #{inspect(result)}"
    end

    @tag :inv_sa_policy_clamp
    test "INV-SA-POLICY-CLAMP: clamp/1 rejects non-positive retry_bound_n with {:error, _}" do
      # Non-positive or zero refine bounds are semantically equivalent to an
      # invalid/infinite specification (they would make the retry ladder
      # immediately exhausted or nonsensical, defeating the bounded-retry guarantee).
      # The engine must reject these, not silently clamp them.
      #
      # FAIL BEFORE: Tau.Factory.Policy.clamp/1 does not exist → UndefinedFunctionError.

      for n <- [0, -1, -10] do
        policy_invalid = %Policy{@base_policy | retry_bound_n: n}

        result = Policy.clamp(policy_invalid)

        assert match?({:error, _}, result),
               "INV-SA-POLICY-CLAMP: Policy.clamp/1 MUST return {:error, _} for " <>
                 "retry_bound_n=#{n} (non-positive bound is invalid, like ∞); " <>
                 "got #{inspect(result)}"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # INV-SA-POLICY-CLAMP — property: clamping is idempotent
  # ---------------------------------------------------------------------------

  describe "INV-SA-POLICY-CLAMP clamp idempotence" do
    @tag :inv_sa_policy_clamp
    test "INV-SA-POLICY-CLAMP: clamp/1 applied twice yields the same result as once (idempotent on retry_bound_n)" do
      # If clamp(p) = {:ok, p'}, then clamp(p') = {:ok, p'} — the clamped policy
      # is already within the safe envelope and a second clamp is a no-op.
      # This is a structural property of a correct engine-clamp implementation.
      #
      # FAIL BEFORE: Tau.Factory.Policy.clamp/1 does not exist → UndefinedFunctionError.

      policy_over = %Policy{@base_policy | retry_bound_n: @hard_ceiling_n + 5}

      assert {:ok, clamped_once} = Policy.clamp(policy_over),
             "INV-SA-POLICY-CLAMP: first clamp/1 must return {:ok, _}; " <>
               "got #{inspect(Policy.clamp(policy_over))}"

      assert {:ok, clamped_twice} = Policy.clamp(clamped_once),
             "INV-SA-POLICY-CLAMP: second clamp/1 on already-clamped policy must " <>
               "return {:ok, _}; got #{inspect(Policy.clamp(clamped_once))}"

      assert clamped_once.retry_bound_n == clamped_twice.retry_bound_n,
             "INV-SA-POLICY-CLAMP: clamp/1 MUST be idempotent on retry_bound_n. " <>
               "First clamp: #{clamped_once.retry_bound_n}, " <>
               "second clamp: #{clamped_twice.retry_bound_n}"
    end
  end
end
