defmodule Tau.Factory.SchedulerPolicyPinReadmitTest do
  @moduledoc """
  Gating test for issue #554 — INV-POLICY-PIN: re-admit must NOT overwrite
  the policy pin frozen at the original admission.

  ## Invariant statement (issue #554)

  A unit's policy version is pinned at admission and MUST NOT change for the
  life of the unit.  A mid-flight policy change (version bump) MUST only affect
  units admitted after the change.  Falsified if an in-flight unit's effective
  policy changes after its admission.

  ## Contract under test

  This test exercises the re-admit path: when a unit already in F calls
  `Scheduler.admit/4` again with a *different* policy (e.g., a scope
  amendment — the D-380 idempotent-upsert path), the Scheduler MUST NOT
  overwrite the policy pin frozen at the original admission.

  The re-admit scenario (arch `control-plane.md §2.2`):
    - First admit via `admit/4` with policy v1 → pin[unit-a] = v1.
    - Re-admit (scope amendment) via `admit/4` with policy v2 while unit-a
      is still in F.  Self-exclusion (D-380) removes unit-a from F before
      evaluating the predicate, so the re-admit resolves to `:admit`.
    - INV-POLICY-PIN requires that pin[unit-a] remains v1 after the
      re-admit.  A "mid-flight policy change" must only affect NEW units.

  ## Why this test FAILS against current code

  `Scheduler.handle_call({:admit, unit_id, declared_scope, policy}, ...)` at
  `scheduler.ex:171-175` unconditionally executes:

      new_pins =
        if is_nil(policy) do
          state.pins
        else
          Map.put(state.pins, unit_id, policy)   # ← OVERWRITES pin on re-admit
        end

  Because `policy` is non-nil (v2), `Map.put` replaces the v1 pin with v2.
  After the re-admit, `pinned_policy_for(sched, "unit-a")` returns v2 — not
  v1 as INV-POLICY-PIN requires.

  The fix (production code, not this test) must guard the pin write: only write
  the pin when the unit is NOT already in `pins` (first admission), never on a
  re-admit.  Concretely:

      new_pins =
        if is_nil(policy) or Map.has_key?(state.pins, unit_id) do
          state.pins
        else
          Map.put(state.pins, unit_id, policy)
        end

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

  defp scope_with_file(filename) do
    %{
      deps: [],
      files: MapSet.new([filename]),
      codepoints: MapSet.new(),
      specs: MapSet.new(),
      resources: MapSet.new()
    }
  end

  defp start_scheduler(w_cap \\ 5) do
    uid = System.unique_integer([:positive])
    name = :"test_sched_pin_readmit_#{uid}"
    start_supervised!({@scheduler, name: name, w_cap: w_cap}, id: :"sched_pin_readmit_#{uid}")
    name
  end

  # ---------------------------------------------------------------------------
  # INV-POLICY-PIN — pin is immutable across re-admit (scope amendment)
  # ---------------------------------------------------------------------------

  @tag :inv_policy_pin
  test "INV-POLICY-PIN: re-admit via admit/4 with a different policy must NOT overwrite the admission-time pin" do
    sched = start_scheduler()

    policy_v1 = make_policy(1)
    policy_v2 = make_policy(2)

    # First admission: pin policy v1 for unit-a.
    assert :admit = @scheduler.admit(sched, "unit-a", scope_with_file("lib/foo.ex"), policy_v1)

    pin_at_admission = @scheduler.pinned_policy_for(sched, "unit-a")

    assert pin_at_admission.version == 1,
           "Precondition: pin must be v1 at first admission; got #{inspect(pin_at_admission)}"

    # Re-admit unit-a with an amended scope and a different policy (policy_v2).
    # D-380 self-exclusion removes unit-a from F before the conflict check, so
    # this re-admit resolves to :admit (idempotent upsert, scope amendment).
    assert :admit =
             @scheduler.admit(sched, "unit-a", scope_with_file("lib/foo_amended.ex"), policy_v2)

    # INV-POLICY-PIN: the pin established at first admission MUST remain v1.
    # The re-admit is a scope amendment — the in-flight unit's effective policy
    # must not change mid-flight.
    pin_after_readmit = @scheduler.pinned_policy_for(sched, "unit-a")

    assert pin_after_readmit.version == 1,
           "INV-POLICY-PIN VIOLATED: re-admit via admit/4 with policy v2 overwrote " <>
             "the admission-time pin (v1). pin_after_readmit=#{inspect(pin_after_readmit)}. " <>
             "A mid-flight scope amendment MUST NOT change the unit's pinned policy version."
  end
end
