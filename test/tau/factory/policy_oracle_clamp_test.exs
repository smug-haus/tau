defmodule Tau.Factory.PolicyOracleClampTest do
  @moduledoc """
  Gating test for INV-POLICY-DATA (issue #553).

  Invariant statement: "Policy is versioned data interpreted by a stable
  engine; no safety invariant's enforcement lives in policy, only its
  parameters. Falsified if any safety enforcement logic is placed inside a
  policy value (e.g., a policy-supplied function that bypasses a gate)."

  ## The gap this closes

  `Tau.Factory.Gate.Oracle.select/1` (gate/oracle.ex:52–58) accepts any map
  as `policy_pin.oracle` and routes to the `Stub` implementation. `Stub.judge/2`
  (gate/oracle.ex:77–85) returns `:pass` whenever `oracle_map[half] == :pass`.
  A policy value (`%{critic: :pass, reviewer: :pass}`) thereby substitutes for
  the real critic/reviewer gate with **no envelope guard** — a direct violation
  of INV-POLICY-DATA and SPEC-FACTORY-GOV HR-8.

  ## What is asserted (SPEC-FACTORY-GOV §4 B6 / HR-8)

  `Tau.Factory.Policy.clamp/1` is the engine-clamp boundary that enforces the
  safe envelope on every policy value before it governs a unit.  HR-8 states:
  "No safety invariant's enforcement lives in policy — only its parameters,
  and only where the invariant holds for all admissible parameter values."

  An `oracle` key in a `%Policy{}` is NOT a "parameter within a safe envelope";
  it is a gate-result substitution — enforcement living in policy data.
  `clamp/1` MUST reject a policy struct that carries an `oracle` key (i.e. a
  map-valued oracle field that would allow a policy pin to substitute for real
  LLM critic/reviewer judgement).

  This test exercises the boundary at `Tau.Factory.Policy.clamp/1` — the real
  engine-clamp entry point — not a hand-built struct that bypasses it.

  ## Failure expectation

  `Tau.Factory.Policy` does not exist in lib/ on this branch (grep confirms zero
  results).  The test will raise `UndefinedFunctionError` (or fail to compile).
  That is the correct fail-before state for the oracle-separation phase.

  ## AC / D-NNN linkage

  - INV-POLICY-DATA (issue #553)
  - SPEC-FACTORY-GOV §4 B6, HR-8
  """

  use ExUnit.Case, async: true

  @moduletag :inv_policy_data

  # Runtime module reference — compiles even before the module exists.
  @policy Tau.Factory.Policy

  # ---------------------------------------------------------------------------
  # INV-POLICY-DATA: Policy.clamp/1 MUST reject an oracle key in the policy
  # ---------------------------------------------------------------------------

  describe "INV-POLICY-DATA: Policy.clamp/1 rejects an oracle-substitution key" do
    @tag :inv_policy_data
    test "INV-POLICY-DATA: a policy struct carrying an oracle map key is REJECTED by clamp/1 (not admitted into the safe envelope)" do
      # A policy pin that carries `oracle: %{critic: :pass, reviewer: :pass}`.
      # This is the direct falsification example from INV-POLICY-DATA: a
      # policy-supplied value that substitutes for real critic/reviewer gate
      # enforcement.  clamp/1 MUST reject it — an oracle key is NOT a
      # "parameter within a safe envelope" (SPEC-FACTORY-GOV HR-8).
      policy_with_oracle = %{
        gate_manifest: [:mutation, :critic, :reviewer],
        retry_bound_n: 3,
        gate_concurrency: 4,
        gate_timeout: 60_000,
        # The oracle key: a policy value that would substitute for real gate
        # enforcement if admitted.
        oracle: %{critic: :pass, reviewer: :pass}
      }

      result = @policy.clamp(policy_with_oracle)

      refute match?({:ok, %{oracle: _}}, result),
             "INV-POLICY-DATA: clamp/1 MUST NOT return {:ok, policy} with an oracle key " <>
               "present. An oracle map in policy is a gate-result substitution — enforcement " <>
               "living in policy data — and violates SPEC-FACTORY-GOV HR-8. " <>
               "Got: #{inspect(result)}"

      assert match?({:error, _}, result) or
               match?({:ok, policy} when not is_map_key(policy, :oracle), result),
             "INV-POLICY-DATA: clamp/1 MUST either reject the policy " <>
               "({:error, _}) or strip the oracle key from the clamped result. " <>
               "Enforcement must not live in policy data. Got: #{inspect(result)}"
    end

    @tag :inv_policy_data
    test "INV-POLICY-DATA: a policy struct with NO oracle key is accepted by clamp/1 (the safe envelope)" do
      # Baseline: a valid policy without any oracle key MUST be accepted.
      # This verifies the guard is selective (rejects oracle, allows safe params),
      # not a blanket reject-all.
      policy_without_oracle = %{
        gate_manifest: [:mutation, :critic, :reviewer],
        retry_bound_n: 3,
        gate_concurrency: 4,
        gate_timeout: 60_000
      }

      result = @policy.clamp(policy_without_oracle)

      assert match?({:ok, _}, result),
             "INV-POLICY-DATA: clamp/1 MUST accept a policy struct that carries no oracle " <>
               "key — that is a valid parameter set within the safe envelope. " <>
               "Got: #{inspect(result)}"
    end
  end
end
