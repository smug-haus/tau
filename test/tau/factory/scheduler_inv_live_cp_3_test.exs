defmodule Tau.Factory.SchedulerInvLiveCp3Test do
  @moduledoc """
  Gating test for issue #632 — INV-LIVE-CP-3: re-admission notification on release.

  ## Invariant statement (issue #632)

  S serves deferred units in arrival order with aging once their blocker clears
  (fairness: a deferred unit's queue position never regresses). Monotone admission
  (P-CC-3) guarantees that a smaller F never forbids what a larger F allowed, so a
  unit deferred only by a blocker will eventually be admitted when the blocker
  terminates. Falsified if a deferred unit's queue position regresses, or if a unit
  remains permanently deferred after all its blockers have terminated.

  ## What this test checks

  The invariant requires that `Scheduler.release/2` emits a re-admission
  notification so that units that were deferred can learn the blocker has cleared
  and retry admission.  Without this notification, a unit that received
  `{:defer, :at_capacity}` or `{:defer, {:conflict, _}}` has no way to know
  a slot has opened — it remains permanently deferred.

  The test exercises two sub-conditions:

  1. **Re-admission notification on release (capacity blocker).**  When
     `release/2` frees a capacity slot, the Scheduler MUST broadcast
     `{:admission_slots_available, scheduler_name}` on the
     `"factory:scheduler"` PubSub topic so deferred units can retry.
     Currently: `release/2` only calls `Map.delete/2` — no broadcast fires,
     the `assert_receive` assertion fails with a timeout.

  2. **Re-admission notification on release (conflict blocker).**  When the
     blocking unit is released from F (clearing a file-conflict), the same
     notification MUST fire so the waiting unit can retry.  Same mechanism;
     same failure mode.

  ## Why this test FAILS against current code

  `Scheduler.handle_call({:release, unit_id}, ...)` at `scheduler.ex:217-221`:

      def handle_call({:release, unit_id}, _from, state) do
        new_f = Map.delete(state.f, unit_id)
        new_pins = Map.delete(state.pins, unit_id)
        {:reply, :ok, %{state | f: new_f, pins: new_pins}}
      end

  No PubSub broadcast is issued.  The `start_link/1` option `:pubsub` is not
  recognised.  A subscriber on `"factory:scheduler"` receives nothing.
  Both `assert_receive` assertions below fail with a timeout.

  ## AC / D-NNN linkage

  @tag :inv_live_cp_3 — INV-LIVE-CP-3 (issue #632)
  Cross-refs: D-343 (no livelock / monotone admission), SPEC-FACTORY-CORE §4 B1.
  """

  use ExUnit.Case, async: true

  @moduletag :inv_live_cp_3
  @moduletag :capture_log

  @scheduler Tau.Factory.Scheduler

  # ---------------------------------------------------------------------------
  # Setup — start a per-test PubSub so the Scheduler has a live registry to
  # broadcast on without depending on the full application.
  # ---------------------------------------------------------------------------

  setup do
    uid = System.unique_integer([:positive])
    pubsub_name = :"test_pubsub_live_cp3_#{uid}"

    start_supervised!({Phoenix.PubSub, name: pubsub_name}, id: :"pubsub_live_cp3_#{uid}")

    {:ok, pubsub: pubsub_name}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp empty_scope do
    %{
      deps: [],
      files: MapSet.new(),
      codepoints: MapSet.new(),
      specs: MapSet.new(),
      resources: MapSet.new()
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

  # Start a Scheduler that will broadcast re-admission notifications on
  # "factory:scheduler" via the supplied PubSub.  The :pubsub option is
  # required for INV-LIVE-CP-3 conformance; the current implementation ignores
  # it, which is exactly the defect this test guards.
  defp start_scheduler(w_cap, pubsub) do
    uid = System.unique_integer([:positive])
    name = :"test_sched_live_cp3_#{uid}"

    start_supervised!(
      {@scheduler, name: name, w_cap: w_cap, pubsub: pubsub},
      id: :"sched_live_cp3_#{uid}"
    )

    name
  end

  # ---------------------------------------------------------------------------
  # INV-LIVE-CP-3 sub-condition 1: release of capacity blocker notifies waiters
  # ---------------------------------------------------------------------------

  @tag :inv_live_cp_3
  test "INV-LIVE-CP-3: release/2 broadcasts {:admission_slots_available, name} on \"factory:scheduler\" when capacity blocker clears",
       %{pubsub: pubsub} do
    sched = start_scheduler(1, pubsub)

    # Subscribe to the re-admission topic BEFORE filling capacity, so we cannot
    # miss a broadcast that fires during release/2.
    :ok = Phoenix.PubSub.subscribe(pubsub, "factory:scheduler")

    # Fill to capacity so the next unit is deferred.
    assert :admit = @scheduler.admit(sched, "unit-blocker", empty_scope())

    # A second non-conflicting unit is deferred because |F| == W_cap.
    assert {:defer, :at_capacity} = @scheduler.admit(sched, "unit-waiter", empty_scope())

    # Release the blocker.  INV-LIVE-CP-3 requires a re-admission notification
    # to be broadcast so "unit-waiter" can retry.
    :ok = @scheduler.release(sched, "unit-blocker")

    # The Scheduler MUST broadcast on "factory:scheduler" after release so that
    # deferred units can learn a slot has opened.  Failure here means the
    # current release/2 implementation never emits the notification, which
    # leaves deferred units permanently waiting — the invariant is violated.
    assert_receive {:admission_slots_available, ^sched},
                   200,
                   "INV-LIVE-CP-3 VIOLATED: Scheduler.release/2 did not broadcast " <>
                     "{:admission_slots_available, #{inspect(sched)}} on \"factory:scheduler\" " <>
                     "after freeing a capacity slot.  Deferred units have no mechanism to learn " <>
                     "the blocker has cleared and will remain permanently deferred."
  end

  # ---------------------------------------------------------------------------
  # INV-LIVE-CP-3 sub-condition 2: release of conflict blocker notifies waiters
  # ---------------------------------------------------------------------------

  @tag :inv_live_cp_3
  test "INV-LIVE-CP-3: release/2 broadcasts {:admission_slots_available, name} on \"factory:scheduler\" when conflict blocker clears",
       %{pubsub: pubsub} do
    # Use a larger W_cap so the only blocker is the file conflict (not capacity).
    sched = start_scheduler(5, pubsub)

    :ok = Phoenix.PubSub.subscribe(pubsub, "factory:scheduler")

    shared_file = "lib/tau/factory/coordinator.ex"

    # Admit the blocker unit with the shared file.
    assert :admit = @scheduler.admit(sched, "unit-conflict-blocker", scope_with_file(shared_file))

    # The waiting unit conflicts on the same file — it is deferred.
    assert {:defer, {:conflict, :disjoint_files}} =
             @scheduler.admit(sched, "unit-conflict-waiter", scope_with_file(shared_file))

    # Release the blocker.  The conflict is now gone.  INV-LIVE-CP-3 requires
    # the Scheduler to broadcast so "unit-conflict-waiter" can retry.
    :ok = @scheduler.release(sched, "unit-conflict-blocker")

    assert_receive {:admission_slots_available, ^sched},
                   200,
                   "INV-LIVE-CP-3 VIOLATED: Scheduler.release/2 did not broadcast " <>
                     "{:admission_slots_available, #{inspect(sched)}} on \"factory:scheduler\" " <>
                     "after releasing a conflict-holding unit.  Deferred units have no " <>
                     "mechanism to learn the blocker has cleared."
  end
end
