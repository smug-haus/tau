defmodule Tau.Factory.SchedulerInvSaPolicyClampTest do
  @moduledoc """
  Gating test for issue #608 -- INV-SA-POLICY-CLAMP, Scheduler admission boundary.

  INV-SA-POLICY-CLAMP statement:
  > Safety-relevant policy values are engine-clamped: the gate floor is
  > non-shrinkable, retry bound N = min(policy, ceiling), infinite retry bound
  > (infinity) is rejected, and the conflict predicate floor is only tightened
  > (never relaxed). Falsified if any policy value causes a safety invariant's
  > enforcement to be weaker than its engine-defined floor.

  ## Why this test is needed (the gap)

  `policy_sa_clamp_test.exs` verifies that `Policy.clamp/1` itself rejects
  infinity and clamps over-ceiling N. That is correct and necessary but
  INSUFFICIENT: it does not verify that the Scheduler enforces clamping at the
  admission boundary (the real enforcement point per C206-B6).

  SPEC-FACTORY-GOV section 4 C206-B6 states:
  > "The engine-clamp/1 runs at admission, before the pin -- the pinned version
  > is the clamped one."

  The current `Scheduler.admit/4` implementation accepts any policy and pins it
  directly WITHOUT calling `Policy.clamp/1`. If a caller passes an unclamped
  policy with `retry_bound_n: :infinity`, the Scheduler stores `:infinity` in
  its `pins` map, and the Unit FSM later reads this unclamped value from
  `Scheduler.pinned_policy_for/2` -- bypassing every safety guard.

  ## What this test asserts

  `Scheduler.admit/4` called with an unsafe (unclamped) policy MUST either:
  - Return `{:error, _}` or `{:defer, _}` (reject at admission boundary), OR
  - Return `:admit` but store the CLAMPED policy in `pins` (clamp before pin).

  In both cases `Scheduler.pinned_policy_for/2` MUST NOT return a policy
  whose `retry_bound_n` is `:infinity` or any non-positive/non-integer value.

  ## Real entry point exercised

    Tau.Factory.Scheduler.admit/4 -> Tau.Factory.Scheduler.pinned_policy_for/2

  ## Fail-before mode

  At the current HEAD, `Scheduler.admit/4` stores the unclamped `:infinity`
  value directly. `pinned_policy_for/2` returns a policy with
  `retry_bound_n: :infinity`. The `refute` assertion fails -- the test is red.

  ## AC / D-NNN linkage

    - INV-SA-POLICY-CLAMP (issue #608)

  ## Gating-test paths

    - test/tau/factory/scheduler_inv_sa_policy_clamp_test.exs
  """

  use ExUnit.Case, async: true

  alias Tau.Factory.ConflictCheck
  alias Tau.Factory.Policy
  alias Tau.Factory.Scheduler

  # ---------------------------------------------------------------------------
  # Named predicate helper -- MFA reference avoids anon-fn module-attr issues.
  # ---------------------------------------------------------------------------

  def engine_floor_pred(a, b), do: ConflictCheck.engine_floor(a, b)

  # ---------------------------------------------------------------------------
  # Helpers -- built at runtime so the file compiles at merge-base cleanly.
  # ---------------------------------------------------------------------------

  defp scope_for(files) do
    %{
      deps: [],
      files: MapSet.new(files),
      codepoints: MapSet.new(),
      specs: MapSet.new(),
      resources: MapSet.new()
    }
  end

  defp unsafe_policy(retry_bound_n) do
    %Policy{
      version: 1,
      model_per_role: %{implementer: "claude-sonnet-4-5"},
      retry_bound_n: retry_bound_n,
      budget: %{token: 100_000, cost: 10, wall_time: 3_600, iteration: 5},
      priority_order: [],
      conflict_predicate: &__MODULE__.engine_floor_pred/2,
      gate_manifest: [:mutation, :critic, :reviewer],
      escalation_thresholds: %{upheld_challenges: 2}
    }
  end

  # ---------------------------------------------------------------------------
  # Test setup -- unique scheduler per test so tests run async.
  # ---------------------------------------------------------------------------

  setup do
    name = :"sched_inv_sa_cpc_#{:erlang.unique_integer([:positive])}"
    {:ok, _pid} = Scheduler.start_link(name: name, w_cap: 10)
    %{scheduler: name}
  end

  # ---------------------------------------------------------------------------
  # INV-SA-POLICY-CLAMP: Scheduler.admit/4 must enforce clamp at admission
  # ---------------------------------------------------------------------------

  describe "INV-SA-POLICY-CLAMP Scheduler.admit/4 admission boundary" do
    @tag :inv_sa_policy_clamp
    test "INV-SA-POLICY-CLAMP: Scheduler does not pin :infinity retry_bound_n (C206-B6 clamp-before-pin)",
         %{scheduler: scheduler} do
      # SPEC-FACTORY-GOV C206-B6: "The engine-clamp/1 runs at admission, before
      # the pin -- the pinned version is the clamped one."
      #
      # If Scheduler.admit/4 pins the unclamped policy directly, the Unit FSM
      # calls pinned_policy_for/2 and receives retry_bound_n: :infinity,
      # falsifying INV-SA-POLICY-CLAMP and D-318 (bounded-retry invariant).
      #
      # FAIL BEFORE: Scheduler.admit/4 stores the raw :infinity value; the
      # refute below fails because pinned retry_bound_n is :infinity.
      # PASS AFTER: Scheduler calls Policy.clamp/1 before pinning and either
      # rejects the admission or stores the clamped value (<=3).

      policy_inf = unsafe_policy(:infinity)

      _result = Scheduler.admit(scheduler, "unit-inf", scope_for(["lib/a.ex"]), policy_inf)

      pinned = Scheduler.pinned_policy_for(scheduler, "unit-inf")

      infinity_pinned? =
        case pinned do
          %Policy{retry_bound_n: n} when n == :infinity -> true
          %Policy{retry_bound_n: n} when not is_integer(n) -> true
          %Policy{retry_bound_n: n} when is_integer(n) and n <= 0 -> true
          _ -> false
        end

      refute infinity_pinned?,
             "INV-SA-POLICY-CLAMP: Scheduler.admit/4 MUST NOT pin a policy with " <>
               "retry_bound_n=:infinity. C206-B6 mandates clamp/1 runs at admission " <>
               "BEFORE the pin. pinned.retry_bound_n = " <>
               "#{inspect(pinned && pinned.retry_bound_n)}"
    end

    @tag :inv_sa_policy_clamp
    test "INV-SA-POLICY-CLAMP: Scheduler does not pin over-ceiling retry_bound_n (N = min(policy, ceiling))",
         %{scheduler: scheduler} do
      # Engine hard ceiling is @hard_ceiling_n = 3 (governance.md section 3).
      # A policy with retry_bound_n = 10 (above ceiling) passed to admit/4 MUST
      # result in the pinned policy having retry_bound_n <= 3. If Scheduler pins
      # 10 unclamped, the Unit FSM takes 10 refine steps, falsifying D-318.
      #
      # FAIL BEFORE: Scheduler pins raw value 10; assert n <= 3 fails.
      # PASS AFTER: Scheduler calls Policy.clamp/1; pinned value is min(10,3)=3.

      hard_ceiling_n = 3
      over_ceiling = hard_ceiling_n + 7

      policy_over = unsafe_policy(over_ceiling)

      _result = Scheduler.admit(scheduler, "unit-over", scope_for(["lib/b.ex"]), policy_over)

      pinned = Scheduler.pinned_policy_for(scheduler, "unit-over")

      case pinned do
        nil ->
          # Admission rejected the policy outright -- acceptable, pin is absent.
          :ok

        %Policy{retry_bound_n: n} ->
          assert n <= hard_ceiling_n,
                 "INV-SA-POLICY-CLAMP: Scheduler.admit/4 MUST NOT pin " <>
                   "retry_bound_n=#{over_ceiling} (above engine ceiling=#{hard_ceiling_n}). " <>
                   "C206-B6: clamp must run at admission before the pin. " <>
                   "Pinned retry_bound_n=#{n}; expected <= #{hard_ceiling_n}."
      end
    end
  end
end
