defmodule Tau.Factory.SchedulerPolicyPinTest do
  @moduledoc """
  Gating test for issue #554 — INV-POLICY-PIN.

  Invariant statement (issue #554):
    A unit's policy version is pinned at admission and MUST NOT change for the
    life of the unit.  A mid-flight policy change (version bump) MUST only affect
    units admitted AFTER the change.  Falsified if an in-flight unit's effective
    policy changes after its admission.

  ## Contract being asserted

  This test exercises the Scheduler (C4, SPEC-FACTORY-CORE §4 B1) at its real
  entry point — `Tau.Factory.Scheduler.admit/4` — the arity-4 variant that
  accepts a clamped `%Policy{}` at admission and pins its version to the unit for
  the unit's lifetime (arch `control-plane.md §2.2`, durable-spine.md `units.policy_version`).

  The Scheduler is the sole serialization point for admission (D-312); it is also
  the sole writer of the per-unit policy pin (`pins: %{unit_id => policy_version}`
  in its GenServer state — arch §2.2).  `pinned_policy_for/2` is the read path
  that returns the `%Policy{}` frozen at admission.

  ## Why this test fails before the fix

  Two absent behaviours, both exercised via the real Scheduler entry point:

  1. `Tau.Factory.Scheduler.admit/4` — the current implementation exposes
     `admit/3 :: (server, unit_id, declared_scope)` with no policy argument;
     calling `admit/4` raises `UndefinedFunctionError` (or `FunctionClauseError`).

  2. `Tau.Factory.Scheduler.pinned_policy_for/2` — absent entirely; raises
     `UndefinedFunctionError`.

  Together these mean the Scheduler cannot satisfy INV-POLICY-PIN: it has no
  mechanism to capture the policy at admission, and no way to expose the frozen
  value for inspection or downstream use (e.g., by the Unit FSM when composing a
  `Gate.Request`, `control-plane.md §2.2`).

  ## AC / D-NNN linkage

  @tag :inv_policy_pin  — INV-POLICY-PIN (issue #554)
  """

  use ExUnit.Case, async: true

  @moduletag :inv_policy_pin
  @moduletag :capture_log

  @scheduler Tau.Factory.Scheduler
  @policy Tau.Factory.Policy

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Minimal valid %Policy{} for a given version integer.
  # gate_manifest includes the engine floor; retry_bound_n is within ceiling.
  defp make_policy(version) do
    %@policy{
      version: version,
      model_per_role: %{implementer: "claude-sonnet-4-6"},
      retry_bound_n: 3,
      budget: %{token: 1_000_000, cost: 100, wall_time: 3600, iteration: 100},
      priority_order: [],
      conflict_predicate: fn _scope, _f -> true end,
      gate_manifest: [:mutation, :critic, :reviewer],
      escalation_thresholds: %{upheld_challenges: 2}
    }
  end

  # Minimal non-conflicting declared scope (passes all five ConflictCheck clauses
  # against any other empty-MapSet scope).
  defp empty_scope do
    %{
      deps: [],
      files: MapSet.new(),
      codepoints: MapSet.new(),
      specs: MapSet.new(),
      resources: MapSet.new()
    }
  end

  # Start an isolated Scheduler (no budget gate needed for this test).
  defp start_scheduler(w_cap) do
    uid = System.unique_integer([:positive])
    name = :"test_sched_pin_#{uid}"

    start_supervised!(
      {@scheduler, name: name, w_cap: w_cap},
      id: :"scheduler_pin_#{uid}"
    )

    name
  end

  # ---------------------------------------------------------------------------
  # INV-POLICY-PIN — policy version is frozen at admission; a mid-flight
  # policy bump must not change the in-flight unit's effective policy.
  # ---------------------------------------------------------------------------

  @tag :inv_policy_pin
  test "INV-POLICY-PIN: admit/4 pins the supplied policy version; a subsequent policy bump does not affect the in-flight unit" do
    sched = start_scheduler(5)

    policy_v1 = make_policy(1)
    policy_v2 = make_policy(2)

    # Admit unit-A with policy v1 via the real Scheduler entry point (admit/4).
    # This is the admission-time pin: the Scheduler must capture policy_v1 and
    # associate it permanently with "unit-a".
    assert :admit = @scheduler.admit(sched, "unit-a", empty_scope(), policy_v1)

    # Retrieve the pinned policy while unit-a is in flight.
    # Must return the policy pinned at admission — version 1.
    pinned_before_bump = @scheduler.pinned_policy_for(sched, "unit-a")

    assert pinned_before_bump.version == 1,
           "Expected pinned policy version 1 at admission; got #{inspect(pinned_before_bump.version)}"

    # Simulate a mid-flight policy version bump: admit a new unit with policy v2.
    # This models the Coordinator starting a new unit under the updated policy.
    assert :admit = @scheduler.admit(sched, "unit-b", empty_scope(), policy_v2)

    # The in-flight unit-a's pinned policy MUST NOT have changed.
    # INV-POLICY-PIN: a mid-flight policy change only affects units admitted
    # after the change — never in-flight units.
    pinned_after_bump = @scheduler.pinned_policy_for(sched, "unit-a")

    assert pinned_after_bump.version == 1,
           "INV-POLICY-PIN VIOLATED: unit-a's pinned policy changed from v1 after unit-b was admitted with v2; " <>
             "got version #{inspect(pinned_after_bump.version)}"

    # unit-b must carry its own pin — version 2.
    pinned_b = @scheduler.pinned_policy_for(sched, "unit-b")

    assert pinned_b.version == 2,
           "Expected unit-b to carry policy version 2; got #{inspect(pinned_b.version)}"

    # Releasing a unit must not affect the other unit's pin.
    :ok = @scheduler.release(sched, "unit-b")
    pinned_a_after_release = @scheduler.pinned_policy_for(sched, "unit-a")

    assert pinned_a_after_release.version == 1,
           "unit-a's pin must survive unit-b's release; got version #{inspect(pinned_a_after_release.version)}"
  end
end
