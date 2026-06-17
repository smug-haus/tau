defmodule Tau.Factory.KillSwitchConformanceTest do
  @moduledoc """
  Gating tests for kill-switch conformance cluster PR #692.

  Closes: #549 (INV-KILLSWITCH-OPERATOR-STATE), #580 (D-321 main-synced),
          #599 (INV-DS-KILL-SWITCH), #673 (NFR-KILL-LATENCY).

  Each test asserts the FULL conformant behaviour the invariant documents:

  - INV-KILLSWITCH-OPERATOR-STATE: kill signal lives in an ETS table owned by a
    supervised control owner (`Tau.Factory.KillSwitch.Store`), never in process
    heap or raw filesystem.

  - D-321 (main-synced clause): the `halting → halted` transition MUST confirm
    `main == origin/main` (via a `main_synced_fun` injectable on the Coordinator)
    before notifying `:on_halted`. Currently absent from the Coordinator — tests
    will fail with `UndefinedFunctionError` or assertion failure.

  - INV-DS-KILL-SWITCH: `StepJob` (an Oban Worker) must exist and
    check the kill-switch sentinel at the start of `perform/1`. Oban dep is not
    declared → compile error is the legitimate fail-before.

  - NFR-KILL-LATENCY: after a kill signal, a running unit MUST NOT continue
    beyond T_unit_max. A configurable total-unit-duration timer must exist on
    the Coordinator/Unit and fire, causing the unit to be ejected and the factory
    to halt within the absolute ceiling. Currently only per-state timeouts exist
    (no accumulating total-unit-duration timer) → assertion fails.

  Tests are written before the production fix exists (oracle-separation §4b).
  Failing modes: `UndefinedFunctionError`, compile error, or assertion failure.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Tau.Factory.KillSwitch.Store
  alias Tau.Factory.StepJob

  @kill_switch Tau.Factory.KillSwitch
  @coordinator Tau.Factory.Coordinator

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique_name(base) do
    suffix = System.unique_integer([:positive])
    :"#{base}_#{suffix}"
  end

  # ---------------------------------------------------------------------------
  # INV-KILLSWITCH-OPERATOR-STATE (#549)
  #
  # The kill signal must live in operator state — an ETS flag under a control
  # owner (`Tau.Factory.KillSwitch.Store`) — never in GenServer process heap or
  # on the filesystem.
  #
  # Conformant behaviour:
  #   1. `KillSwitch.Store.start_link/1` creates and owns an ETS table.
  #   2. After `KillSwitch.request_halt/1`, `KillSwitch.Store.armed?/1` returns
  #      `true` — readable directly from ETS, NOT via GenServer state.
  #   3. The armed flag survives a crash-and-restart of the KillSwitch GenServer
  #      (the Store process holds the ETS table independently).
  #
  # Current failure mode: `Tau.Factory.KillSwitch.Store` does not exist →
  # `UndefinedFunctionError` on `Store.start_link/1`.
  # ---------------------------------------------------------------------------

  @tag :inv_killswitch_operator_state
  test "INV-KILLSWITCH-OPERATOR-STATE: halt flag lives in ETS (KillSwitch.Store), not process heap" do
    store_name = unique_name(:ks_store)
    ks_name = unique_name(:ks)

    # KillSwitch.Store must exist and be startable independently.
    # It owns the ETS table; the KillSwitch GenServer writes to it.
    start_supervised!(
      {Store, name: store_name},
      id: store_name
    )

    # Armed? should be false before any halt request.
    refute Store.armed?(store_name),
           "INV-KILLSWITCH-OPERATOR-STATE: Store.armed? should be false before request_halt"

    # Start the KillSwitch, wired to the same Store.
    start_supervised!(
      {@kill_switch, name: ks_name, pubsub: Tau.PubSub, store: store_name},
      id: ks_name
    )

    # Trigger halt.
    :ok = @kill_switch.request_halt(ks_name)

    # The flag must now be readable directly from the ETS owner (the Store),
    # not from the KillSwitch GenServer's process state.
    assert Store.armed?(store_name),
           "INV-KILLSWITCH-OPERATOR-STATE: halt flag not in ETS after request_halt — " <>
             "flag lives in process heap, not operator state (Store)"
  end

  @tag :inv_killswitch_operator_state
  test "INV-KILLSWITCH-OPERATOR-STATE: armed flag persists in ETS after KillSwitch process crash" do
    store_name = unique_name(:ks_store_persist)
    ks_name = unique_name(:ks_persist)

    # Start the Store (independent ETS owner).
    start_supervised!(
      {Store, name: store_name},
      id: store_name
    )

    # Start KillSwitch, wired to the Store.
    {:ok, ks_pid} =
      start_supervised(
        {@kill_switch, name: ks_name, pubsub: Tau.PubSub, store: store_name},
        id: ks_name
      )

    # Arm the switch.
    :ok = @kill_switch.request_halt(ks_name)

    assert Store.armed?(store_name),
           "INV-KILLSWITCH-OPERATOR-STATE: armed flag not set in Store after request_halt"

    # Kill the KillSwitch process (simulates a crash).
    Process.exit(ks_pid, :kill)
    Process.sleep(50)

    # The Store is a separate process; ETS table must still show armed = true.
    # If the flag was in process heap, it would be lost here.
    assert Store.armed?(store_name),
           "INV-KILLSWITCH-OPERATOR-STATE: armed flag lost after KillSwitch process crash — " <>
             "flag was in process heap (not ETS), violating operator-state invariant"
  end

  # ---------------------------------------------------------------------------
  # D-321 — main-synced clause (#580)
  #
  # The `halting → halted` transition MUST confirm `main == origin/main` before
  # notifying :on_halted. Current coordinator.ex calls `notify_halted/1` in
  # `halting(:internal, :drain, ...)` without any main-sync check.
  #
  # Conformant behaviour: the Coordinator accepts a `:main_synced_fun` option
  # (injectable for tests). Before transitioning to :halted, it calls
  # `main_synced_fun.()` and asserts it returns `true`. If it returns `false`
  # (main not synced), the Coordinator must NOT transition to :halted; it must
  # stay in :halting and retry or raise an escalation.
  #
  # Current failure mode: Coordinator does not accept `:main_synced_fun` and
  # does not perform any sync check → the test's sync tracker is never called →
  # assertion failure (sync_called? == false).
  # ---------------------------------------------------------------------------

  @tag :d_321
  test "D-321 (main-synced): Coordinator checks main==origin/main before transitioning to :halted" do
    coord_name = unique_name(:coord_d321_synced)
    on_halted = self()

    # Track whether the main-sync check was performed.
    {:ok, sync_tracker} = Agent.start_link(fn -> false end)

    main_synced_fun = fn ->
      Agent.update(sync_tracker, fn _ -> true end)
      # Returning true: main is synced (allows halt to proceed).
      true
    end

    # Coordinator MUST accept a :main_synced_fun option and call it before
    # transitioning to :halted. Currently this option is not implemented.
    start_supervised!(
      {
        @coordinator,
        name: coord_name,
        pubsub: Tau.PubSub,
        select_fun: fn -> nil end,
        drive_fun: fn _w -> :ok end,
        scheduler: nil,
        on_halted: on_halted,
        main_synced_fun: main_synced_fun
      },
      id: coord_name
    )

    # Trigger a halt on an idle coordinator (no in-flight unit → goes straight
    # to halting → drain → should call main_synced_fun → halted).
    ks_name = unique_name(:ks_d321)

    start_supervised!(
      {@kill_switch, name: ks_name, pubsub: Tau.PubSub},
      id: ks_name
    )

    :ok = @kill_switch.request_halt(ks_name)

    # Wait for the coordinator to reach :halted.
    assert_receive :coordinator_halted, 2000, "Coordinator did not reach :halted"

    sync_called = Agent.get(sync_tracker, & &1)

    assert sync_called,
           "D-321 (main-synced): Coordinator transitioned to :halted WITHOUT calling " <>
             "main_synced_fun — the 'main MUST be synced before halting' clause has no " <>
             "executable enforcement (coordinator.ex halting/3 :drain, lines 252-254)"
  end

  @tag :d_321
  test "D-321 (main-synced): Coordinator does NOT halt when main_synced_fun returns false" do
    coord_name = unique_name(:coord_d321_not_synced)
    on_halted = self()

    # Simulate main NOT being synced.
    main_synced_fun = fn -> false end

    start_supervised!(
      {
        @coordinator,
        name: coord_name,
        pubsub: Tau.PubSub,
        select_fun: fn -> nil end,
        drive_fun: fn _w -> :ok end,
        scheduler: nil,
        on_halted: on_halted,
        main_synced_fun: main_synced_fun
      },
      id: coord_name
    )

    ks_name = unique_name(:ks_d321_ns)

    start_supervised!(
      {@kill_switch, name: ks_name, pubsub: Tau.PubSub},
      id: ks_name
    )

    :ok = @kill_switch.request_halt(ks_name)

    # Give the Coordinator time to process. It must NOT reach :halted when
    # main_synced_fun returns false.
    Process.sleep(200)

    # Must NOT have received :coordinator_halted yet.
    refute_received :coordinator_halted,
                    "D-321 (main-synced): Coordinator halted even though main_synced_fun " <>
                      "returned false — main-sync check is not enforced before halting"

    # State must NOT be :halted.
    {state, _} = :sys.get_state(coord_name)

    refute state == :halted,
           "D-321 (main-synced): Coordinator reached :halted state without a synced main"
  end

  # ---------------------------------------------------------------------------
  # INV-DS-KILL-SWITCH (#599)
  #
  # The Oban cron/recurring driver MUST check for the kill-switch sentinel at
  # the start of every factory step job. This requires:
  #   - `Tau.Factory.StepJob` implementing `Oban.Worker`
  #   - `perform/1` calls `KillSwitch.Store.armed?/1` (or equivalent) at the
  #     start of execution and returns `{:cancel, :kill_switch_armed}` when armed.
  #
  # Current failure mode: `Tau.Factory.StepJob` does not exist (Oban not even a
  # dependency) → `UndefinedFunctionError` on `Tau.Factory.StepJob.new/1`.
  # ---------------------------------------------------------------------------

  @tag :inv_ds_kill_switch
  test "INV-DS-KILL-SWITCH: StepJob.perform/1 cancels when kill-switch sentinel is armed" do
    # The StepJob is an Oban Worker. When the kill-switch sentinel is armed,
    # perform/1 must return {:cancel, :kill_switch_armed} without executing
    # any factory-step work.
    #
    # This test calls perform/1 directly (not via Oban scheduler) to verify
    # the sentinel check at the user-facing entry point.

    store_name = unique_name(:ks_store_stepjob)

    start_supervised!(
      {Store, name: store_name},
      id: store_name
    )

    # Arm the kill switch in the Store.
    :ok = Store.set_armed(store_name)

    # Build a StepJob args map pointing at our test Store.
    args = %{"store" => store_name, "milestone" => "test-milestone"}

    # Calling perform/1 via the Oban.Worker contract.
    # Must return {:cancel, :kill_switch_armed} when the sentinel is armed.
    job = StepJob.new(args)

    result = StepJob.perform(job)

    assert result == {:cancel, :kill_switch_armed},
           "INV-DS-KILL-SWITCH: StepJob.perform/1 did not cancel when kill-switch was armed; " <>
             "got: #{inspect(result)}"
  end

  @tag :inv_ds_kill_switch
  test "INV-DS-KILL-SWITCH: StepJob exists and implements Oban.Worker behaviour" do
    # This test will fail to compile / raise UndefinedFunctionError if
    # Tau.Factory.StepJob does not exist.

    assert function_exported?(StepJob, :perform, 1),
           "INV-DS-KILL-SWITCH: StepJob does not export perform/1 — " <>
             "the Oban cron/recurring driver that checks the sentinel does not exist"

    assert StepJob.__info__(:attributes)
           |> Keyword.get(:behaviour, [])
           |> Enum.member?(Oban.Worker),
           "INV-DS-KILL-SWITCH: StepJob does not implement the Oban.Worker behaviour"
  end

  # ---------------------------------------------------------------------------
  # NFR-KILL-LATENCY (#673)
  #
  # After a kill signal, the factory MUST halt within at most 1 atomic unit,
  # bounded above by T_unit_max (configurable; default 30 min). A unit that
  # runs longer than T_unit_max must be forcibly terminated and treated as
  # escalated; the factory must then halt.
  #
  # Conformant behaviour: the Coordinator or Unit accepts a `:unit_max_ms`
  # option. A per-unit accumulating timer (not a per-state timer) fires after
  # T_unit_max from unit start. On fire, the unit is ejected (escalated) and
  # the factory halts if halt_pending.
  #
  # Current failure mode: only a per-state `:state_timeout` exists in Unit FSM
  # (unit.ex:60); no accumulating total-unit-duration timer exists → a
  # continuously heartbeating worker can prevent the bound from ever firing →
  # assertion failure (halt does not arrive within the configured ceiling).
  # ---------------------------------------------------------------------------

  @tag :nfr_kill_latency
  test "NFR-KILL-LATENCY: factory halts within T_unit_max after kill, even if unit never finishes" do
    coord_name = unique_name(:coord_nfr_latency)
    on_halted = self()

    # Use a very short T_unit_max for test speed.
    unit_max_ms = 300

    # A unit that NEVER sends {:unit_terminal,...} — simulates a stalled unit.
    # The factory must forcibly terminate it within T_unit_max and then halt.
    unit_never_finishes = fn _work ->
      # Spawn a process that blocks forever (no terminal message).
      spawn(fn -> Process.sleep(:infinity) end)
      :ok
    end

    {:ok, counter} = Agent.start_link(fn -> 0 end)

    select_fun = fn ->
      n = Agent.get_and_update(counter, fn c -> {c, c + 1} end)

      if n == 0 do
        "unit-latency-stalled-#{System.unique_integer([:positive])}"
      else
        nil
      end
    end

    # The Coordinator MUST accept :unit_max_ms and enforce the absolute ceiling.
    # This option does not exist in the current implementation.
    start_supervised!(
      {
        @coordinator,
        name: coord_name,
        pubsub: Tau.PubSub,
        select_fun: select_fun,
        drive_fun: unit_never_finishes,
        scheduler: nil,
        on_halted: on_halted,
        unit_max_ms: unit_max_ms
      },
      id: coord_name
    )

    # Wait for the unit to start (it will never finish on its own).
    Process.sleep(50)

    # Trigger halt. With halt_pending = true, the factory should eject the
    # stalled unit once T_unit_max elapses, then halt.
    ks_name = unique_name(:ks_nfr)

    start_supervised!(
      {@kill_switch, name: ks_name, pubsub: Tau.PubSub},
      id: ks_name
    )

    :ok = @kill_switch.request_halt(ks_name)

    # Allow up to unit_max_ms + generous margin for the forced ejection and halt.
    margin_ms = unit_max_ms + 500

    assert_receive :coordinator_halted,
                   margin_ms,
                   "NFR-KILL-LATENCY: factory did not halt within T_unit_max (#{unit_max_ms}ms) " <>
                     "after kill signal with a stalled unit — no accumulating total-unit-duration " <>
                     "timer exists (only per-state timeouts, which heartbeats can reset indefinitely)"
  end

  @tag :nfr_kill_latency
  test "NFR-KILL-LATENCY: Coordinator stores :unit_max_ms in state for accumulating-timer enforcement" do
    coord_name = unique_name(:coord_nfr_state)

    unit_max_ms = 30_000

    start_supervised!(
      {
        @coordinator,
        name: coord_name,
        pubsub: Tau.PubSub,
        select_fun: fn -> nil end,
        drive_fun: fn _w -> :ok end,
        scheduler: nil,
        unit_max_ms: unit_max_ms
      },
      id: coord_name
    )

    {_state, data} = :sys.get_state(coord_name)

    # The Coordinator must store :unit_max_ms in its state data so the
    # accumulating-timer arm code can read it. Silently ignoring the option
    # means no timer is ever armed — the absolute ceiling cannot fire.
    assert Map.get(data, :unit_max_ms) == unit_max_ms,
           "NFR-KILL-LATENCY: Coordinator did not store :unit_max_ms in state data — " <>
             "the absolute ceiling option is silently ignored; no accumulating timer " <>
             "can be armed without this value"
  end
end
