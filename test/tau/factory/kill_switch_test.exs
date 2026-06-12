defmodule Tau.Factory.KillSwitchTest do
  @moduledoc """
  Gating tests for PR #449 (P5a — Coordinator FSM + KillSwitch).

  Enforces D-321: a kill-switch event sets `halt_pending`; the Coordinator
  transitions `running → halting → halted` only at the next `unit_terminal`
  boundary, never by interrupting the in-flight unit mid-execution.

  Also covers:
    - AC-7: clean kill at a unit boundary (load-bearing D-321 contract).
    - Loop-drive invariant: Coordinator drives units in order until select_fun
      returns nil, then idles (no over-invocation of drive_fun).
    - Escalation routing: global escalation → halting; per-unit escalation →
      running (unit escalated, loop continues).

  Written BEFORE production code exists (oracle-separation phase, factory-loop
  §4b). Both `Tau.Factory.Coordinator` and `Tau.Factory.KillSwitch` are absent
  now; tests fail with `UndefinedFunctionError` at runtime.

  ## Pinned API contract (implementer MUST conform exactly)

  ### Tau.Factory.KillSwitch (supervised GenServer)

  `start_link(opts) :: GenServer.on_start()`
    Required opts:
      `:name`     — atom; registered name for the GenServer.
      `:pubsub`   — atom; name of a running Phoenix.PubSub (use `Tau.PubSub`).
    Optional opts:
      `:sentinel_path`  — Path.t(); if given, KillSwitch polls for this file's
                          existence and broadcasts `:halt_requested` when it
                          appears.
      `:poll_interval`  — integer() ms; default 500; used when `:sentinel_path`
                          is set.

  `request_halt(kill_switch) :: :ok`
    Broadcasts `:halt_requested` EXACTLY ONCE on Phoenix.PubSub topic
    `"factory:control"` using the pubsub name given at start_link.
    Returns `:ok` synchronously.

  ### Tau.Factory.Coordinator (gen_statem, :state_functions)

  States: `running` | `halting` | `halted`

  `start_link(opts) :: :gen_statem.start_ret()`
    Required opts:
      `:name`       — atom; registered name for the gen_statem.
      `:pubsub`     — atom; name of a running Phoenix.PubSub. Coordinator
                      MUST subscribe to topic `"factory:control"` and handle
                      the `:halt_requested` message.
      `:select_fun` — (-> work_item | nil); called each loop iteration to
                      select the next unit of work. Returns nil when idle.
      `:drive_fun`  — (work_item -> :ok); called with the selected work item
                      to start one unit. The unit eventually sends
                      `{:unit_terminal, unit_id, outcome}` back to the
                      Coordinator pid to signal completion. The drive_fun
                      itself MUST NOT block; it spawns/starts a unit process
                      that sends the terminal message asynchronously.
    Optional opts:
      `:scheduler`  — atom() | pid() | nil; if non-nil, the Coordinator calls
                      `Tau.Factory.Scheduler.admit/3` before driving. Pass nil
                      in tests to skip admission gating.
      `:on_halted`  — pid(); notified with `:coordinator_halted` when the
                      Coordinator reaches `halted` state.

  State observation:
    `:sys.get_state(coordinator)` returns `{state_name, _data}` where
    `state_name ∈ {:running, :halting, :halted}`.

  Message shapes (pinned):
    - `{:unit_terminal, unit_id :: String.t(), outcome}` — sent by a unit
      to the Coordinator to signal terminal completion. `outcome` may be
      `:merged`, `:escalated`, or `:rejected`.
    - `{:escalate, {e, :global}}` — sent to the Coordinator to trigger a
      global escalation; transitions the Coordinator to `halting`.
    - `{:escalate, {e, :unit}}` — sent to the Coordinator to signal a
      per-unit escalation; the Coordinator stays `running` (unit is
      treated as escalated, loop continues).
    - `:halt_requested` — received from PubSub `"factory:control"`; sets
      `halt_pending` in the Coordinator's data. Does NOT immediately halt;
      halting occurs only at the next `unit_terminal` (D-321).

  D-321 boundary semantics:
    On `:halt_requested` in `running` state:
      - set `halt_pending = true`
      - do NOT interrupt the in-flight unit
      - do NOT transition state immediately
    On `{:unit_terminal, _, _}` when `halt_pending = true`:
      - complete the terminal fold (schedule release etc.)
      - transition to `halting`
      - when in-flight count drops to 0 → transition to `halted`
    `halted` → notify `:on_halted` pid with `:coordinator_halted` (if set).

  AC/D-NNN linkage: AC-7, D-321.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log
  @moduletag :ac_7
  @moduletag :d_321

  # ---------------------------------------------------------------------------
  # Runtime module references.
  # File compiles while these modules are absent; tests fail at runtime.
  # Using @mod Module + @mod.fun(args) form — NOT apply/2,3 (Credo strict).
  # ---------------------------------------------------------------------------

  @coordinator Tau.Factory.Coordinator
  @kill_switch Tau.Factory.KillSwitch

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Generate a unique atom name for supervised processes per test, avoiding
  # name-collision across async tests.
  defp unique_name(base) do
    suffix = System.unique_integer([:positive])
    :"#{base}_#{suffix}"
  end

  # A controllable "unit" that blocks until the test sends it :finish.
  # On :finish, sends {:unit_terminal, unit_id, :merged} to the coordinator.
  # Returns {unit_pid, unit_id}.
  defp spawn_blocking_unit(coordinator_pid, unit_id) do
    test_pid = self()

    unit_pid =
      spawn(fn ->
        receive do
          :finish ->
            send(coordinator_pid, {:unit_terminal, unit_id, :merged})

          :finish_escalated ->
            send(coordinator_pid, {:unit_terminal, unit_id, :escalated})
        end

        send(test_pid, {:unit_finished, unit_id})
      end)

    {unit_pid, unit_id}
  end

  # ---------------------------------------------------------------------------
  # Test 1 — AC-7 / D-321: clean kill at a unit boundary (load-bearing)
  #
  # Timeline:
  #   1. Start Coordinator with select_fun returning one work item then nil.
  #   2. drive_fun spawns a blocking unit (holds in flight).
  #   3. Trigger :halt_requested via KillSwitch.request_halt/1.
  #   4. Assert: Coordinator is still `running` (not immediately halted);
  #      unit process is still alive.
  #   5. Release the unit → sends {:unit_terminal, ...} to Coordinator.
  #   6. Assert: unit completed (ran to terminal, was NOT killed mid-flight).
  #   7. Assert: Coordinator transitions running → halting → halted.
  # ---------------------------------------------------------------------------

  @tag :ac_7
  @tag :d_321
  test "AC-7 / D-321: kill mid-unit; halt occurs after unit completes, never mid-unit" do
    coord_name = unique_name(:coord_ac7)
    ks_name = unique_name(:ks_ac7)
    pubsub_name = Tau.PubSub
    on_halted = self()

    # Counter for select_fun: returns one work item then nil.
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    work_item = "unit-ac7-#{System.unique_integer([:positive])}"
    unit_id = work_item

    # Drive-fun spawns a blocking unit; the test controls when it finishes.
    # We capture the unit_pid so we can assert it is still alive post-halt-request.
    unit_pids = :ets.new(:unit_pids, [:public, :set])

    drive_fun = fn _work ->
      # Coordinator pid is looked up by registered name at drive time.
      coord_pid = Process.whereis(coord_name)
      {unit_pid, _} = spawn_blocking_unit(coord_pid, unit_id)
      :ets.insert(unit_pids, {unit_id, unit_pid})
      :ok
    end

    select_fun = fn ->
      n = Agent.get_and_update(counter, fn c -> {c, c + 1} end)

      if n == 0 do
        work_item
      else
        nil
      end
    end

    # Start KillSwitch.
    start_supervised!(
      {@kill_switch, name: ks_name, pubsub: pubsub_name},
      id: ks_name
    )

    # Start Coordinator.
    start_supervised!(
      {
        @coordinator,
        name: coord_name,
        pubsub: pubsub_name,
        select_fun: select_fun,
        drive_fun: drive_fun,
        scheduler: nil,
        on_halted: on_halted
      },
      id: coord_name
    )

    # Wait for drive_fun to have been called (unit is in flight).
    # Poll until unit_pid is registered in ETS.
    assert_unit_in_flight = fn ->
      Enum.reduce_while(1..100, :not_yet, fn _, _ ->
        case :ets.lookup(unit_pids, unit_id) do
          [{^unit_id, _pid}] ->
            {:halt, :ok}

          [] ->
            Process.sleep(10)
            {:cont, :not_yet}
        end
      end)
    end

    assert :ok == assert_unit_in_flight.()

    [{^unit_id, unit_pid}] = :ets.lookup(unit_pids, unit_id)

    # Assert unit process is alive before halt request.
    assert Process.alive?(unit_pid)

    # Trigger halt via KillSwitch.
    :ok = @kill_switch.request_halt(ks_name)

    # Give the Coordinator a moment to process the PubSub message.
    # Then assert it is still in running (or at most starting halting but the
    # unit pid MUST still be alive — it was not interrupted).
    Process.sleep(50)

    {coord_state, _} = :sys.get_state(coord_name)

    # The unit MUST still be alive — D-321 forbids mid-unit interruption.
    assert Process.alive?(unit_pid),
           "D-321 violation: unit was killed mid-flight by the halt request " <>
             "(state was #{inspect(coord_state)})"

    # Coordinator must NOT yet be halted (it should be running or halting-pending).
    refute coord_state == :halted,
           "D-321 violation: Coordinator reached :halted before unit_terminal fired"

    # Release the blocking unit (simulates the unit completing normally).
    send(unit_pid, :finish)

    # Wait for the unit's terminal notification to reach us.
    assert_receive {:unit_finished, ^unit_id}, 2000

    # Now the Coordinator should transition to halted and notify :on_halted.
    assert_receive :coordinator_halted,
                   2000,
                   "Coordinator did not reach :halted after unit_terminal"

    # Verify final state.
    {final_state, _} = :sys.get_state(coord_name)
    assert final_state == :halted

    :ets.delete(unit_pids)
  end

  # ---------------------------------------------------------------------------
  # Test 2 — Loop-drive invariant: drive_fun invoked in order, stops at nil
  #
  # select_fun returns [work1, work2, nil] (via Agent counter).
  # drive_fun records invocations.
  # Assert drive_fun was called exactly twice, in order, with correct items.
  # ---------------------------------------------------------------------------

  @tag :d_321
  test "loop: drive_fun invoked exactly twice in order when select_fun returns two items then nil" do
    coord_name = unique_name(:coord_loop)
    pubsub_name = Tau.PubSub
    on_halted = self()

    work1 = "unit-loop1-#{System.unique_integer([:positive])}"
    work2 = "unit-loop2-#{System.unique_integer([:positive])}"

    {:ok, counter} = Agent.start_link(fn -> 0 end)

    work_items = [work1, work2]

    select_fun = fn ->
      n = Agent.get_and_update(counter, fn c -> {c, c + 1} end)
      Enum.at(work_items, n)
    end

    # Record drive invocations in order.
    {:ok, drive_log} = Agent.start_link(fn -> [] end)

    test_pid = self()

    drive_fun = fn work ->
      Agent.update(drive_log, fn log -> log ++ [work] end)
      coord_pid = Process.whereis(coord_name)

      # Each "unit" completes immediately to allow the loop to advance.
      spawn(fn ->
        send(coord_pid, {:unit_terminal, work, :merged})
        send(test_pid, {:driven, work})
      end)

      :ok
    end

    start_supervised!(
      {
        @coordinator,
        name: coord_name,
        pubsub: pubsub_name,
        select_fun: select_fun,
        drive_fun: drive_fun,
        scheduler: nil,
        on_halted: on_halted
      },
      id: coord_name
    )

    # Wait for both units to be driven.
    assert_receive {:driven, ^work1}, 2000
    assert_receive {:driven, ^work2}, 2000

    # Give the coordinator time to attempt a third select (should return nil → idle).
    Process.sleep(100)

    invocations = Agent.get(drive_log, & &1)

    assert invocations == [work1, work2],
           "Expected drive_fun called exactly twice in order [work1, work2]; got #{inspect(invocations)}"

    # Coordinator should still be running (no kill switch triggered).
    {state, _} = :sys.get_state(coord_name)
    assert state == :running
  end

  # ---------------------------------------------------------------------------
  # Test 3 — Escalation routing: global vs per-unit
  #
  # Global escalation {e, :global} → Coordinator transitions to halting.
  # Per-unit escalation {e, :unit} → Coordinator stays running.
  # ---------------------------------------------------------------------------

  @tag :d_321
  test "escalation routing: global → halting, per-unit → running" do
    # --- Part A: global escalation → halting ---
    coord_a = unique_name(:coord_esc_global)

    # Idle coordinator with no work (select_fun always returns nil).
    start_supervised!(
      {
        @coordinator,
        name: coord_a,
        pubsub: Tau.PubSub,
        select_fun: fn -> nil end,
        drive_fun: fn _w -> :ok end,
        scheduler: nil,
        on_halted: self()
      },
      id: coord_a
    )

    send(coord_a, {:escalate, {:E_UNCLASSIFIED, :global}})
    Process.sleep(50)

    {state_a, _} = :sys.get_state(coord_a)

    assert state_a in [:halting, :halted],
           "Global escalation did not move Coordinator to halting/halted; state=#{inspect(state_a)}"

    # --- Part B: per-unit escalation → running ---
    coord_b = unique_name(:coord_esc_unit)

    start_supervised!(
      {
        @coordinator,
        name: coord_b,
        pubsub: Tau.PubSub,
        select_fun: fn -> nil end,
        drive_fun: fn _w -> :ok end,
        scheduler: nil,
        on_halted: self()
      },
      id: coord_b
    )

    send(coord_b, {:escalate, {:E_AMBIGUITY, :unit}})
    Process.sleep(50)

    {state_b, _} = :sys.get_state(coord_b)

    assert state_b == :running,
           "Per-unit escalation moved Coordinator out of running; state=#{inspect(state_b)}"
  end

  # ---------------------------------------------------------------------------
  # Test 4 — KillSwitch broadcasts :halt_requested exactly once
  #
  # Subscribes to "factory:control" before calling request_halt; asserts
  # exactly one :halt_requested message arrives, and no second one.
  # ---------------------------------------------------------------------------

  @tag :ac_7
  @tag :d_321
  test "KillSwitch.request_halt/1 broadcasts :halt_requested exactly once on factory:control" do
    ks_name = unique_name(:ks_broadcast)

    start_supervised!(
      {@kill_switch, name: ks_name, pubsub: Tau.PubSub},
      id: ks_name
    )

    # Subscribe to the control topic before triggering.
    :ok = Phoenix.PubSub.subscribe(Tau.PubSub, "factory:control")

    :ok = @kill_switch.request_halt(ks_name)

    assert_receive :halt_requested,
                   1000,
                   "KillSwitch did not broadcast :halt_requested on factory:control"

    # No second broadcast.
    refute_receive :halt_requested, 200
  end

  # ---------------------------------------------------------------------------
  # Test 5 — D-321: :halt_requested sets halt_pending; Coordinator does NOT
  # halt immediately (no in-flight unit present but idle: stays in running
  # with halt_pending, or immediately transitions to halting if no work pending)
  #
  # The load-bearing case is Test 1 (mid-unit). This confirms the PubSub
  # wiring and that the halt message is processed without crashing.
  # ---------------------------------------------------------------------------

  @tag :ac_7
  @tag :d_321
  test "D-321: :halt_requested via PubSub is handled without crashing the Coordinator" do
    coord_name = unique_name(:coord_halt_noop)
    ks_name = unique_name(:ks_halt_noop)
    on_halted = self()

    start_supervised!(
      {@kill_switch, name: ks_name, pubsub: Tau.PubSub},
      id: ks_name
    )

    start_supervised!(
      {
        @coordinator,
        name: coord_name,
        pubsub: Tau.PubSub,
        select_fun: fn -> nil end,
        drive_fun: fn _w -> :ok end,
        scheduler: nil,
        on_halted: on_halted
      },
      id: coord_name
    )

    # Coordinator is alive.
    assert Process.alive?(Process.whereis(coord_name))

    :ok = @kill_switch.request_halt(ks_name)

    # Coordinator must still be alive after halt_requested (it may or may not
    # have transitioned; it must not have crashed).
    Process.sleep(100)

    assert Process.alive?(Process.whereis(coord_name)),
           "Coordinator crashed after :halt_requested"
  end
end
