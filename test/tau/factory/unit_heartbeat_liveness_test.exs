defmodule Tau.Factory.UnitHeartbeatLivenessTest do
  @moduledoc """
  Gating tests for PR #513 (issue #491 — GOV4 heartbeat-driven Unit liveness).

  Advances D-377, D-378, D-379 (SPEC-FACTORY-CORE §3/§4/§6):

  - **D-377** — the Unit re-arms its `:state_timeout` on every current-worker
    `{:worker_heartbeat, worker_id}` pulse. A progressing worker never trips the
    fixed cap; absence of heartbeats escalates `E_WORKER_STALLED` at the deadline.

  - **D-378** — exactly ONE advance of the retry ladder per worker per state when
    stall signals arrive in close succession (`:state_timeout`, `{:worker_stalled,
    w}`, `{:worker_exit, w, _}` for the same worker). The first consumed signal
    clears `data.worker_id`; later ones hit the stale-worker discard clause.

  - **D-379** — (a) the Unit routes `{:worker_stalled, ^worker_id}` → retry ladder
    (same path as `:state_timeout`); stale-worker `{:worker_stalled, _}` is
    discarded. (b) `UnitDriver.drive/2` registers each spawned worker with the
    fleet `Watchdog` (via a `:watchdog` dep), delivering `{:worker_stalled, _}`
    to the owning Unit.

  ## Fail-before validity (oracle-separation, factory-loop §4b)

  These tests fail against the current branch because:
  - `oracle`/`implementing` have no `{:worker_heartbeat, _}` clause — D-377 absent.
  - `oracle`/`implementing` have no `{:worker_stalled, _}` clause — D-379 absent.
  - `UnitDriver.drive/2` has no `:watchdog` dep and does not call
    `Watchdog.register/5` — D-379 producer absent.

  ## AC / D-NNN linkage (Gate 5.1)

  Every test name and @tag carries D-377, D-378, or D-379.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Tau.Factory.Fleet.Watchdog
  alias Tau.Factory.Scheduler
  alias Tau.Factory.UnitSupervisor

  @scheduler Scheduler
  @unit_supervisor UnitSupervisor

  # ---------------------------------------------------------------------------
  # Shared helpers
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

  defp start_scheduler(name) do
    start_supervised!({@scheduler, name: name, w_cap: 10}, id: name)
  end

  defp spawn_worker do
    spawn(fn ->
      receive do
        :stop -> :ok
      after
        30_000 -> :ok
      end
    end)
  end

  # Base opts threaded through each test.  `overrides` replaces defaults.
  defp base_unit_opts(unit_id, scheduler_name, report_to, overrides) do
    defaults = [
      unit_id: unit_id,
      declared_scope: empty_scope(),
      hash: "hash-#{unit_id}",
      scheduler: scheduler_name,
      report_to: report_to,
      worker_fun: fn _role -> {:ok, spawn_worker()} end,
      gate_fun: fn _coord -> :pass end,
      merge_fun: fn _uid, _hash -> :queued end,
      timeouts: [state_timeout_ms: 5_000]
    ]

    Keyword.merge(defaults, overrides)
  end

  # Poll until the Unit is in :implementing; return {:implementing, data} or
  # {:timeout, last_state} on deadline.
  defp wait_for_implementing(unit_pid, deadline_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_wait_implementing(unit_pid, deadline)
  end

  defp do_wait_implementing(unit_pid, deadline) do
    case :sys.get_state(unit_pid) do
      {:implementing, data} ->
        {:implementing, data}

      {state, _} when state in [:planned, :oracle] ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:timeout, state}
        else
          Process.sleep(20)
          do_wait_implementing(unit_pid, deadline)
        end

      {state, data} ->
        {state, data}
    end
  end

  # Advance past oracle by sending work_ready to the oracle worker.
  defp advance_past_oracle(unit_pid, oracle_worker_id, deadline_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_advance_oracle(unit_pid, oracle_worker_id, deadline)
  end

  defp do_advance_oracle(unit_pid, oracle_worker_id, deadline) do
    case :sys.get_state(unit_pid) do
      {:oracle, _data} ->
        send(unit_pid, {:work_ready, oracle_worker_id, "feat/x", "deadbeef"})
        :ok

      {:planned, _} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:timeout, :planned}
        else
          Process.sleep(20)
          do_advance_oracle(unit_pid, oracle_worker_id, deadline)
        end

      {:implementing, _} ->
        :ok

      {other, _} ->
        {:unexpected, other}
    end
  end

  # ---------------------------------------------------------------------------
  # D-377 — heartbeat resets state_timeout; absence trips stall at deadline
  # ---------------------------------------------------------------------------

  describe "D-377 — heartbeat resets :state_timeout, progressing worker never escalates" do
    @tag :d_377
    test "D-377: {worker_heartbeat, current_worker_id} at sub-timeout intervals keeps Unit in :implementing past old fixed cap" do
      test_pid = self()
      unit_id = "u-hb-reset-#{System.unique_integer([:positive])}"
      scheduler_name = :"sched_hb_reset_#{System.unique_integer([:positive])}"
      sup_name = :"sup_hb_reset_#{System.unique_integer([:positive])}"

      start_scheduler(scheduler_name)
      start_supervised!({@unit_supervisor, name: sup_name}, id: sup_name)

      # Very short timeout so the test is fast.  Without heartbeat-reset the Unit
      # would trip at state_timeout_ms.  With D-377 each heartbeat re-arms the
      # timer, so the Unit stays in :implementing as long as pulses arrive.
      state_timeout_ms = 80

      oracle_worker_id = "w-hb-oracle-#{System.unique_integer([:positive])}"
      impl_worker_id = "w-hb-impl-#{System.unique_integer([:positive])}"
      call_count = :counters.new(1, [:atomics])

      worker_fun = fn _role ->
        n = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)
        pid = spawn_worker()
        if n == 0, do: {:ok, pid, oracle_worker_id}, else: {:ok, pid, impl_worker_id}
      end

      opts =
        base_unit_opts(unit_id, scheduler_name, test_pid,
          worker_fun: worker_fun,
          timeouts: [state_timeout_ms: state_timeout_ms]
        )

      unit_pid = @unit_supervisor.start_unit(sup_name, opts)
      assert is_pid(unit_pid)

      advance_past_oracle(unit_pid, oracle_worker_id)
      result = wait_for_implementing(unit_pid)

      assert match?({:implementing, _}, result),
             "D-377: Unit must reach :implementing; got #{inspect(result)}"

      # Drive heartbeats every 40ms (< timeout 80ms) for 3× the old fixed cap.
      # Without D-377 the Unit would escalate E_WORKER_STALLED at 80ms.
      # With D-377 each pulse re-arms the timer so the Unit stays in :implementing.
      driver =
        spawn(fn ->
          hb_loop(unit_pid, impl_worker_id, 35, 3 * state_timeout_ms)
        end)

      # Wait 3× the old cap — the Unit must NOT have escalated.
      Process.sleep(3 * state_timeout_ms + 50)

      {state_after, _data} = :sys.get_state(unit_pid)

      send(driver, :stop)

      assert state_after == :implementing,
             "D-377: Unit fed {:worker_heartbeat, current_id} at sub-timeout intervals " <>
               "MUST stay in :implementing past the old fixed cap (#{3 * state_timeout_ms}ms). " <>
               "Got state=#{inspect(state_after)}. " <>
               "FAIL-BEFORE: no {:worker_heartbeat, _} clause exists — the Unit trips " <>
               ":state_timeout at #{state_timeout_ms}ms and escalates E_WORKER_STALLED."
    end

    @tag :d_377
    test "D-377: without heartbeats, Unit trips :state_timeout and escalates E_WORKER_STALLED at deadline" do
      test_pid = self()
      unit_id = "u-hb-nostall-#{System.unique_integer([:positive])}"
      scheduler_name = :"sched_hb_nostall_#{System.unique_integer([:positive])}"
      sup_name = :"sup_hb_nostall_#{System.unique_integer([:positive])}"

      start_scheduler(scheduler_name)
      start_supervised!({@unit_supervisor, name: sup_name}, id: sup_name)

      state_timeout_ms = 80

      oracle_worker_id = "w-nostall-oracle-#{System.unique_integer([:positive])}"
      impl_worker_id = "w-nostall-impl-#{System.unique_integer([:positive])}"
      call_count = :counters.new(1, [:atomics])

      worker_fun = fn _role ->
        n = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)
        pid = spawn_worker()
        if n == 0, do: {:ok, pid, oracle_worker_id}, else: {:ok, pid, impl_worker_id}
      end

      opts =
        base_unit_opts(unit_id, scheduler_name, test_pid,
          worker_fun: worker_fun,
          timeouts: [state_timeout_ms: state_timeout_ms]
        )

      unit_pid = @unit_supervisor.start_unit(sup_name, opts)
      assert is_pid(unit_pid)

      advance_past_oracle(unit_pid, oracle_worker_id)
      result = wait_for_implementing(unit_pid)

      assert match?({:implementing, _}, result),
             "D-377: Unit must reach :implementing; got #{inspect(result)}"

      # No heartbeats sent — state_timeout must fire at deadline.
      assert_receive {:unit_terminal, ^unit_id, :escalated, provenance},
                     500,
                     "D-377: without heartbeats, Unit MUST escalate via :state_timeout " <>
                       "within #{state_timeout_ms}ms; not received within 500ms"

      reason = Map.get(provenance, :reason)

      assert reason == :E_WORKER_STALLED,
             "D-377: stall escalation must carry :E_WORKER_STALLED; got #{inspect(reason)}"
    end
  end

  # ---------------------------------------------------------------------------
  # D-378 — exactly one ladder advance when stall signals arrive in succession
  # ---------------------------------------------------------------------------

  describe "D-378 — exactly one retry-ladder advance for close-succession stall signals" do
    @tag :d_378
    test "D-378: state_timeout then {worker_stalled, w} then {worker_exit, w, _} advances ladder EXACTLY ONCE — later signals are stale-worker discarded" do
      test_pid = self()
      unit_id = "u-d378-once-#{System.unique_integer([:positive])}"
      scheduler_name = :"sched_d378_#{System.unique_integer([:positive])}"
      sup_name = :"sup_d378_#{System.unique_integer([:positive])}"

      start_scheduler(scheduler_name)
      start_supervised!({@unit_supervisor, name: sup_name}, id: sup_name)

      # Disable the real state_timeout with a long timer so we can deliver signals
      # manually and control the ordering precisely.
      oracle_worker_id = "w-d378-oracle-#{System.unique_integer([:positive])}"
      impl_worker_id = "w-d378-impl-#{System.unique_integer([:positive])}"
      call_count = :counters.new(1, [:atomics])

      worker_fun = fn _role ->
        n = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)
        pid = spawn_worker()
        if n == 0, do: {:ok, pid, oracle_worker_id}, else: {:ok, pid, impl_worker_id}
      end

      opts =
        base_unit_opts(unit_id, scheduler_name, test_pid,
          worker_fun: worker_fun,
          # Long timeout so the real :state_timeout does not fire during the test.
          timeouts: [state_timeout_ms: 10_000]
        )

      unit_pid = @unit_supervisor.start_unit(sup_name, opts)
      assert is_pid(unit_pid)

      advance_past_oracle(unit_pid, oracle_worker_id)
      result = wait_for_implementing(unit_pid)

      assert match?({:implementing, _}, result),
             "D-378: Unit must reach :implementing; got #{inspect(result)}"

      {:implementing, data_before} = result
      refine_before = Map.get(data_before, :refine_count, 0)
      attempt_before = Map.get(data_before, :attempt_count, 0)

      # Deliver three successive stall signals for the SAME worker in one burst.
      # D-378: the first one must clear data.worker_id; the second and third must
      # hit the stale-worker discard clause and be ignored.
      send(unit_pid, {:state_timeout, :worker_stalled})
      send(unit_pid, {:worker_stalled, impl_worker_id})
      send(unit_pid, {:worker_exit, impl_worker_id, :no_work_product})

      # Allow all three messages to be processed.
      Process.sleep(350)

      {state_after, data_after} = :sys.get_state(unit_pid)

      # The Unit must have entered :implementing EXACTLY ONCE MORE (ladder +1,
      # not +2 or +3).  We assert counters are exactly +1 or exactly the state is
      # :implementing without having escalated.
      refine_after = Map.get(data_after, :refine_count, 0)
      attempt_after = Map.get(data_after, :attempt_count, 0)

      total_advance_before = refine_before + attempt_before
      total_advance_after = refine_after + attempt_after

      assert state_after == :implementing,
             "D-378: after exactly one ladder advance, Unit must be in :implementing; " <>
               "got #{inspect(state_after)}"

      assert total_advance_after - total_advance_before == 1,
             "D-378: three close-succession stall signals for one worker MUST advance " <>
               "the retry ladder EXACTLY once (first signal consumed, later signals " <>
               "stale-worker discarded). Counter advanced by " <>
               "#{total_advance_after - total_advance_before} (expected 1). " <>
               "refine #{refine_before}→#{refine_after}, attempt #{attempt_before}→#{attempt_after}. " <>
               "FAIL-BEFORE: no {:worker_stalled, _} clause and no worker_id-clear on " <>
               "state_timeout means each signal may advance independently, or the " <>
               "Unit may escalate instead of refining."
    end
  end

  # ---------------------------------------------------------------------------
  # D-379(a) — Unit consumes {worker_stalled, ^worker_id} → ladder; stale → discard
  # ---------------------------------------------------------------------------

  describe "D-379(a) — Unit routes {worker_stalled, current_id} to retry ladder; stale is discarded" do
    @tag :d_379
    test "D-379: {:worker_stalled, current_worker_id} in :implementing advances retry ladder (same as :state_timeout)" do
      test_pid = self()
      unit_id = "u-d379a-stalled-#{System.unique_integer([:positive])}"
      scheduler_name = :"sched_d379a_#{System.unique_integer([:positive])}"
      sup_name = :"sup_d379a_#{System.unique_integer([:positive])}"

      start_scheduler(scheduler_name)
      start_supervised!({@unit_supervisor, name: sup_name}, id: sup_name)

      oracle_worker_id = "w-d379a-oracle-#{System.unique_integer([:positive])}"
      impl_worker_id = "w-d379a-impl-#{System.unique_integer([:positive])}"
      call_count = :counters.new(1, [:atomics])

      worker_fun = fn _role ->
        n = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)
        pid = spawn_worker()
        if n == 0, do: {:ok, pid, oracle_worker_id}, else: {:ok, pid, impl_worker_id}
      end

      opts =
        base_unit_opts(unit_id, scheduler_name, test_pid,
          worker_fun: worker_fun,
          timeouts: [state_timeout_ms: 10_000]
        )

      unit_pid = @unit_supervisor.start_unit(sup_name, opts)
      assert is_pid(unit_pid)

      advance_past_oracle(unit_pid, oracle_worker_id)
      result = wait_for_implementing(unit_pid)

      assert match?({:implementing, _}, result),
             "D-379: Unit must reach :implementing; got #{inspect(result)}"

      {:implementing, data_before} = result
      refine_before = Map.get(data_before, :refine_count, 0)
      attempt_before = Map.get(data_before, :attempt_count, 0)

      # Deliver the Watchdog's stall signal for the CURRENT worker.
      send(unit_pid, {:worker_stalled, impl_worker_id})

      Process.sleep(250)

      {state_after, data_after} = :sys.get_state(unit_pid)

      assert state_after == :implementing,
             "D-379: {:worker_stalled, current_worker_id} must advance the retry ladder " <>
               "and re-enter :implementing; got #{inspect(state_after)}. " <>
               "FAIL-BEFORE: no {:worker_stalled, _} clause in implementing/3 — " <>
               "the message is routed to handle_unexpected/4 and silently ignored."

      refine_after = Map.get(data_after, :refine_count, 0)
      attempt_after = Map.get(data_after, :attempt_count, 0)

      assert refine_after > refine_before or attempt_after > attempt_before,
             "D-379: {:worker_stalled, current_id} must advance the ladder; " <>
               "refine #{refine_before}→#{refine_after}, " <>
               "attempt #{attempt_before}→#{attempt_after}"

      refute_received {:unit_terminal, ^unit_id, _outcome, _prov},
                      "D-379: a single {:worker_stalled, current_id} must route to retry, " <>
                        "not terminate the Unit"
    end

    @tag :d_379
    test "D-379: {:worker_stalled, stale_worker_id} in :implementing is silently discarded — no ladder advance" do
      test_pid = self()
      unit_id = "u-d379a-stale-#{System.unique_integer([:positive])}"
      scheduler_name = :"sched_d379a_stale_#{System.unique_integer([:positive])}"
      sup_name = :"sup_d379a_stale_#{System.unique_integer([:positive])}"

      start_scheduler(scheduler_name)
      start_supervised!({@unit_supervisor, name: sup_name}, id: sup_name)

      oracle_worker_id = "w-d379as-oracle-#{System.unique_integer([:positive])}"
      impl_worker_id = "w-d379as-impl-#{System.unique_integer([:positive])}"
      call_count = :counters.new(1, [:atomics])

      worker_fun = fn _role ->
        n = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)
        pid = spawn_worker()
        if n == 0, do: {:ok, pid, oracle_worker_id}, else: {:ok, pid, impl_worker_id}
      end

      opts =
        base_unit_opts(unit_id, scheduler_name, test_pid,
          worker_fun: worker_fun,
          timeouts: [state_timeout_ms: 10_000]
        )

      unit_pid = @unit_supervisor.start_unit(sup_name, opts)
      assert is_pid(unit_pid)

      advance_past_oracle(unit_pid, oracle_worker_id)
      result = wait_for_implementing(unit_pid)

      assert match?({:implementing, _}, result),
             "D-379 stale: Unit must reach :implementing; got #{inspect(result)}"

      {:implementing, data_before} = result
      refine_before = Map.get(data_before, :refine_count, 0)
      attempt_before = Map.get(data_before, :attempt_count, 0)

      stale_id = "w-d379-stale-#{System.unique_integer([:positive])}"
      send(unit_pid, {:worker_stalled, stale_id})

      Process.sleep(200)

      {state_after, data_after} = :sys.get_state(unit_pid)

      assert state_after == :implementing,
             "D-379 stale: a {:worker_stalled, stale_id} must be discarded — " <>
               "Unit remains in :implementing; got #{inspect(state_after)}"

      refine_after = Map.get(data_after, :refine_count, 0)
      attempt_after = Map.get(data_after, :attempt_count, 0)

      assert refine_before == refine_after and attempt_before == attempt_after,
             "D-379 stale: stale {:worker_stalled} must NOT advance the ladder; " <>
               "refine #{refine_before}→#{refine_after}, " <>
               "attempt #{attempt_before}→#{attempt_after}"

      refute_received {:unit_terminal, ^unit_id, _outcome, _prov},
                      "D-379 stale: stale {:worker_stalled} must not terminate the Unit"
    end
  end

  # ---------------------------------------------------------------------------
  # D-379(b) — UnitDriver.drive/2 registers each spawned worker with the Watchdog
  # ---------------------------------------------------------------------------
  #
  # The SPEC says: "the `UnitDriver.drive/2` `worker_fun` seam … registers each
  # spawned worker with the fleet `Watchdog` (`Watchdog.register(watchdog,
  # worker_id, worker_pid, unit_pid, heartbeat_timeout: …)`)".
  #
  # The observable contract is: when UnitDriver wires a :watchdog dep into its
  # worker_fun closure, a spawned worker with no heartbeats triggers
  # {:worker_stalled, worker_id} → Unit, which routes to escalation.
  #
  # We test this via a Unit with a worker_fun that itself calls
  # Watchdog.register/5 (mirroring the closure UnitDriver.drive/2 will build).
  # The test then confirms the stall signal arrives at the Unit and is routed
  # to the retry ladder — demonstrating the full D-379 wiring path.
  #
  # FAIL-BEFORE: the Unit has no {:worker_stalled, _} clause (D-379 absent), so
  # when the Watchdog fires {:worker_stalled, worker_id} to the Unit it is
  # silently ignored via handle_unexpected/4.  The Unit never escalates via
  # this path, and the stall_advance_count assertion fails.
  # ---------------------------------------------------------------------------

  describe "D-379(b) — worker_fun that calls Watchdog.register/5 delivers {:worker_stalled, id} to Unit → ladder" do
    @tag :d_379
    test "D-379: worker registered via Watchdog.register/5 — absence triggers {:worker_stalled, id} routed to retry ladder" do
      test_pid = self()
      unit_id = "u-d379b-wd-#{System.unique_integer([:positive])}"
      scheduler_name = :"sched_d379b_#{System.unique_integer([:positive])}"
      sup_name = :"sup_d379b_#{System.unique_integer([:positive])}"
      watchdog_name = :"watchdog_d379b_#{System.unique_integer([:positive])}"

      start_scheduler(scheduler_name)
      start_supervised!({@unit_supervisor, name: sup_name}, id: sup_name)

      # Very short Watchdog timeout so the test is fast.
      check_interval = 20
      heartbeat_timeout = 60

      start_supervised!(
        {Watchdog, name: watchdog_name, check_interval: check_interval},
        id: watchdog_name
      )

      oracle_worker_id = "w-d379b-oracle-#{System.unique_integer([:positive])}"
      call_count = :counters.new(1, [:atomics])

      # This worker_fun mirrors the closure UnitDriver.drive/2 will build:
      # it calls Watchdog.register/5 with report_to = self() (the Unit's pid)
      # so the Watchdog sends {:worker_stalled, worker_id} to the Unit when no
      # heartbeats arrive within heartbeat_timeout ms.
      worker_fun = fn _role ->
        n = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        pid = spawn_worker()

        worker_id =
          if n == 0,
            do: oracle_worker_id,
            else: "w-d379b-impl-#{n}-#{System.unique_integer([:positive])}"

        # D-379: the driver's worker_fun closure calls Watchdog.register/5 with
        # report_to = self() (the owning Unit's pid at invocation time).
        :ok =
          Watchdog.register(watchdog_name, worker_id, pid, self(),
            heartbeat_timeout: heartbeat_timeout
          )

        {:ok, pid, worker_id}
      end

      opts =
        base_unit_opts(unit_id, scheduler_name, test_pid,
          worker_fun: worker_fun,
          # Long Unit state_timeout so the Unit does not trip its own timer —
          # only the Watchdog should fire.
          timeouts: [state_timeout_ms: 5_000]
        )

      unit_pid = @unit_supervisor.start_unit(sup_name, opts)
      assert is_pid(unit_pid)

      # Advance past oracle so the implementing worker is registered too.
      advance_past_oracle(unit_pid, oracle_worker_id)
      result = wait_for_implementing(unit_pid)

      assert match?({:implementing, _}, result),
             "D-379(b): Unit must reach :implementing; got #{inspect(result)}"

      {:implementing, data_before} = result
      refine_before = Map.get(data_before, :refine_count, 0)
      attempt_before = Map.get(data_before, :attempt_count, 0)

      # No heartbeats emitted — the Watchdog fires {:worker_stalled, impl_worker_id}
      # to the Unit within heartbeat_timeout + check_interval ms.
      # D-379(a) must route this to advance_retry_ladder/1.
      Process.sleep(heartbeat_timeout + 4 * check_interval + 50)

      {state_after, data_after} = :sys.get_state(unit_pid)

      refine_after = Map.get(data_after, :refine_count, 0)
      attempt_after = Map.get(data_after, :attempt_count, 0)

      stall_advanced = refine_after > refine_before or attempt_after > attempt_before

      assert state_after == :implementing and stall_advanced,
             "D-379(b): a worker registered with Watchdog.register/5 (the closure " <>
               "UnitDriver.drive/2 will build) MUST trigger {:worker_stalled, worker_id} " <>
               "delivery to the Unit, which routes to the retry ladder. " <>
               "Got state=#{inspect(state_after)}, refine #{refine_before}→#{refine_after}, " <>
               "attempt #{attempt_before}→#{attempt_after}. " <>
               "FAIL-BEFORE: the Unit has no {:worker_stalled, _} clause (D-379 absent) — " <>
               "the Watchdog fires the signal but the Unit silently discards it via " <>
               "handle_unexpected/4; the ladder counter stays flat."
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Drive {:worker_heartbeat, worker_id} pulses at interval_ms for up_to_ms.
  defp hb_loop(unit_pid, worker_id, interval_ms, up_to_ms) when up_to_ms > 0 do
    send(unit_pid, {:worker_heartbeat, worker_id})

    receive do
      :stop -> :ok
    after
      interval_ms ->
        hb_loop(unit_pid, worker_id, interval_ms, up_to_ms - interval_ms)
    end
  end

  defp hb_loop(_unit_pid, _worker_id, _interval_ms, _up_to_ms), do: :ok
end
