defmodule Tau.Factory.WorkerStalledTest do
  @moduledoc """
  Gating tests for PR #447 (P4d-4 — Fleet.Watchdog heartbeat→worker_stalled).

  Written BEFORE production code exists (oracle-separation phase, factory-loop §4b).
  Tests fail at runtime (UndefinedFunctionError on Tau.Factory.Fleet.Watchdog) until
  the implementer creates `lib/tau/factory/fleet/watchdog.ex`.

  ## Pinned interface (oracle-declared; implementer MUST conform)

  ### Tau.Factory.Fleet.Watchdog (supervised GenServer)

      start_link(opts) :: GenServer.on_start()
        Required options:
          :name             — atom; registered name for the GenServer.
          :check_interval   — ms; how often the watchdog scans for stalled workers.

      register(watchdog, worker_id, worker_pid, report_to, heartbeat_timeout: ms) :: :ok
        Registers the worker. The watchdog calls Process.monitor(worker_pid).
        When the worker is alive but has not emitted a
        [:tau, :factory, :worker, :heartbeat] telemetry event (keyed by
        %{worker_id: worker_id} in metadata) for longer than heartbeat_timeout ms,
        the watchdog sends {:worker_stalled, worker_id} to report_to EXACTLY ONCE
        per stall window (C213). On receiving :DOWN for the worker_pid the watchdog
        deregisters — no {:worker_stalled, _} message is sent for a crash.

  ## Heartbeat driving (deterministic harness)

  These tests do NOT use a real Worker process. Heartbeats are driven by emitting
  the real telemetry event directly:

      :telemetry.execute([:tau, :factory, :worker, :heartbeat], %{}, %{worker_id: id})

  A wedged worker is a spawned process that blocks on receive — alive but emitting
  no heartbeat.

  ## AC / D-NNN linkage (Gate 5.1)

  - AC-10 (SPEC-FACTORY-FLEET §7): wedged worker → exactly one worker_stalled
  - D-317 (SPEC-FACTORY-CORE): heartbeat absence synthesizes the worker_stalled trigger
  - C213 (SPEC-FACTORY-FLEET §3 Q5): exactly one stall message per stall window
  - C206 (SPEC-FACTORY-FLEET §3 Q3): watchdog, not supervisor, handles liveness
  """

  use ExUnit.Case, async: false

  # Avoid compile-time alias of the absent module.
  # Module.concat/1 is evaluated at compile time to produce an atom, but the
  # function calls @watchdog.fun(args) are dispatched at runtime only, so no
  # UndefinedFunctionError at compile time.
  @watchdog Module.concat(["Tau", "Factory", "Fleet", "Watchdog"])

  # Timing constants — generous relative to the short intervals to avoid flakiness.
  # check_interval: 30ms, heartbeat_timeout: 60ms (2 scan cycles).
  # assert_receive window: 300ms (5× timeout, accounts for scheduler jitter).
  # refute_receive window: 500ms (8× timeout, spans several scan cycles).
  @check_interval 30
  @heartbeat_timeout 60
  # how often the "alive" worker drives heartbeats in the no-stall test
  @heartbeat_drive_interval 20

  setup do
    name = :"watchdog_#{:erlang.unique_integer([:positive])}"

    {:ok, pid} =
      @watchdog.start_link(
        name: name,
        check_interval: @check_interval
      )

    on_exit(fn ->
      if Process.alive?(pid) do
        GenServer.stop(pid, :normal, 1_000)
      end
    end)

    {:ok, watchdog: name, watchdog_pid: pid}
  end

  describe "AC-10 / D-317 — wedged worker (alive, no heartbeat) → worker_stalled" do
    @tag :ac_10
    @tag :d_317
    test "registers a wedged worker and receives exactly one {:worker_stalled, worker_id}",
         %{watchdog: watchdog} do
      worker_id = "wedged-w1-#{:erlang.unique_integer([:positive])}"
      # A dummy process that stays alive but never emits a heartbeat.
      wedged = spawn(fn -> receive do: (:stop -> :ok) end)
      assert Process.alive?(wedged)

      :ok =
        @watchdog.register(watchdog, worker_id, wedged, self(),
          heartbeat_timeout: @heartbeat_timeout
        )

      # Wait long enough for the watchdog to detect the stall (timeout + 2 scans).
      assert_receive {:worker_stalled, ^worker_id}, 300

      # Clean up
      send(wedged, :stop)
    end
  end

  describe "C206 — no false stall when heartbeats arrive on time" do
    @tag :c_206
    @tag :ac_10
    test "no {:worker_stalled, _} when heartbeats are driven faster than timeout",
         %{watchdog: watchdog} do
      worker_id = "alive-w2-#{:erlang.unique_integer([:positive])}"
      # A dummy process that stays alive.
      dummy = spawn(fn -> receive do: (:stop -> :ok) end)
      assert Process.alive?(dummy)

      :ok =
        @watchdog.register(watchdog, worker_id, dummy, self(),
          heartbeat_timeout: @heartbeat_timeout
        )

      # Drive heartbeats from the test process, faster than the timeout.
      # 500ms window spans 500/@heartbeat_drive_interval ≈ 25 heartbeats — well
      # above what the watchdog needs to stay satisfied.
      driver =
        spawn(fn ->
          heartbeat_loop(worker_id, @heartbeat_drive_interval, 500)
        end)

      refute_receive {:worker_stalled, _}, 500

      send(driver, :stop)
      send(dummy, :stop)
    end
  end

  describe "C213 — exactly one worker_stalled per stall window, no retry" do
    @tag :c_213
    @tag :ac_10
    test "wedged worker yields EXACTLY ONE worker_stalled across multiple scan intervals",
         %{watchdog: watchdog} do
      worker_id = "wedged-once-w3-#{:erlang.unique_integer([:positive])}"
      wedged = spawn(fn -> receive do: (:stop -> :ok) end)
      assert Process.alive?(wedged)

      :ok =
        @watchdog.register(watchdog, worker_id, wedged, self(),
          heartbeat_timeout: @heartbeat_timeout
        )

      # Receive the first (and only expected) stall message.
      assert_receive {:worker_stalled, ^worker_id}, 300

      # Wait long enough for at least 2-3 additional scan cycles to fire.
      # The watchdog MUST NOT send a second message (C213: one per stall window).
      refute_receive {:worker_stalled, _}, 150

      send(wedged, :stop)
    end
  end

  describe "D-309 / C217 — :DOWN is not a stall (crash is janitor's concern)" do
    @tag :c_217
    @tag :ac_10
    test "killing a registered worker emits no {:worker_stalled, _}",
         %{watchdog: watchdog} do
      worker_id = "killed-w4-#{:erlang.unique_integer([:positive])}"
      dummy = spawn(fn -> receive do: (:stop -> :ok) end)
      assert Process.alive?(dummy)

      :ok =
        @watchdog.register(watchdog, worker_id, dummy, self(),
          heartbeat_timeout: @heartbeat_timeout
        )

      # Kill the process before it can stall — the watchdog should deregister on :DOWN.
      Process.exit(dummy, :kill)
      refute Process.alive?(dummy)

      # Give the watchdog enough time to process the :DOWN and multiple scan cycles.
      # If it were going to send a stall message it would have done so by 300ms.
      refute_receive {:worker_stalled, _}, 300
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Emits the real heartbeat telemetry event at interval_ms for up_to_ms total.
  # The process exits when it receives :stop or when up_to_ms has elapsed.
  defp heartbeat_loop(worker_id, interval_ms, up_to_ms) when up_to_ms > 0 do
    :telemetry.execute(
      [:tau, :factory, :worker, :heartbeat],
      %{},
      %{worker_id: worker_id}
    )

    receive do
      :stop -> :ok
    after
      interval_ms ->
        heartbeat_loop(worker_id, interval_ms, up_to_ms - interval_ms)
    end
  end

  defp heartbeat_loop(_worker_id, _interval_ms, _up_to_ms), do: :ok
end
