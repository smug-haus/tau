defmodule Tau.Factory.UnitWorkerExitTest do
  @moduledoc """
  Gating tests for PR #507 (issue #490 — A3: route semantic worker_exit to the
  retry ladder).

  Advances D-326 (SPEC-FACTORY-CORE §4 B8 [C111b-B8]):

    * `worker_exit(w, :no_work_product)` — exit-0-without-work_ready — is routed
      to the retry ladder, NEVER gated.
    * `worker_exit(w, :error)` and `worker_exit(w, {:exit_status, n})` — semantic
      agent failures — are routed to the retry ladder, NOT escalated via the :DOWN
      infra path.
    * Repeated semantic exits exhaust the ladder →
      `escalated(:E_RETRY_EXHAUSTED)` (D-318).
    * A genuine infra :DOWN (no preceding semantic worker_exit) still escalates
      `E_WORKER_DOWN` (preserved behaviour — guards against the fix over-broadening).
    * After a semantic exit routes to retry, the consequent monitor :DOWN for the
      same worker does NOT fire a second outcome (one exit → one outcome, B8
      disjointness).
    * A `{:worker_exit, other_worker_id, _}` not matching the current worker_id is
      discarded (stale-worker guard, B8).

  ## Fail-before validity

  The current `Tau.Factory.Unit` `implementing/3` has NO `{:worker_exit, ...}`
  clause. On receiving `{:worker_exit, worker_id, reason}` the message falls
  through to `handle_unexpected/4` which calls `{:keep_state, data}` or is dropped
  to the info-catch-all (logging). When the process then exits via the monitor :DOWN,
  it lands on `E_WORKER_DOWN`, NOT the retry ladder. Tests 1, 2, 3, 5, and 6 are
  therefore RED against current code for the right reason.

  Test 4 (infra :DOWN → E_WORKER_DOWN) may already be GREEN — it guards the
  existing behaviour and must remain GREEN after the fix.

  ## D-326 token linkage

  Every test in this file carries the D-326 token (in its name and/or @tag) as
  required by factory-loop §4b gate 5.1.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log
  @moduletag :d_326

  # Runtime module references — @mod.fun form (Credo strict), never apply/2,3.
  alias Tau.Factory.Retry

  @unit_supervisor Tau.Factory.UnitSupervisor
  @scheduler Tau.Factory.Scheduler

  # ---------------------------------------------------------------------------
  # Shared helpers — mirror the idiom from unit_termination_test.exs
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
    start_supervised!(
      {@scheduler, name: name, w_cap: 10},
      id: name
    )
  end

  # Spawn a long-lived worker the Unit will monitor. Normal completion is via
  # an in-band work_ready message; the test can also kill it for :DOWN tests.
  defp spawn_worker do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

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

  # Advance through the oracle state by delivering work_ready keyed by the Unit's
  # current worker_id. The Unit exposes data.worker_id via :sys.get_state/1.
  defp drive_oracle_to_implementing(unit_pid, worker_id) do
    :timer.sleep(50)

    case :sys.get_state(unit_pid) do
      {:oracle, data} ->
        wid = Map.get(data, :worker_id, worker_id)
        send(unit_pid, {:work_ready, wid, "feat/x", "deadbeef"})

      _ ->
        :ok
    end
  end

  # Wait until the Unit is in :implementing; return the current {state, data}.
  defp wait_for_implementing(unit_pid, deadline_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_wait_implementing(unit_pid, deadline)
  end

  defp do_wait_implementing(unit_pid, deadline) do
    case :sys.get_state(unit_pid) do
      {:implementing, data} ->
        {:implementing, data}

      {state, _data} when state in [:planned, :oracle] ->
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

  # ---------------------------------------------------------------------------
  # Test 1 — D-326: :no_work_product → retry ladder, not :gating, not E_WORKER_DOWN
  # ---------------------------------------------------------------------------

  describe "D-326 [C111b-B8] — worker_exit :no_work_product routes to retry ladder" do
    @tag :d_326
    test "D-326: {:worker_exit, worker_id, :no_work_product} routes to retry ladder — Unit re-enters :implementing, NOT :gating and NOT :escalated" do
      test_pid = self()
      unit_id = "u-noprod-retry-#{System.unique_integer([:positive])}"
      scheduler_name = :"sched_noprod_#{System.unique_integer([:positive])}"
      sup_name = :"sup_noprod_#{System.unique_integer([:positive])}"

      start_scheduler(scheduler_name)
      start_supervised!({@unit_supervisor, name: sup_name}, id: sup_name)

      # gate_fun sentinel: if called, the Unit incorrectly gated a :no_work_product exit.
      gate_called_ref = :counters.new(1, [:atomics])

      gate_fun = fn _coord ->
        :counters.add(gate_called_ref, 1, 1)
        :pass
      end

      # worker_id surfaces as the 3-tuple seam so the Unit keys events by it.
      worker_id = "w-noprod-#{System.unique_integer([:positive])}"

      opts =
        base_unit_opts(unit_id, scheduler_name, test_pid,
          worker_fun: fn _role -> {:ok, spawn_worker(), worker_id} end,
          gate_fun: gate_fun,
          merge_fun: fn _uid, _hash -> :queued end,
          timeouts: [state_timeout_ms: 5_000]
        )

      unit_pid = @unit_supervisor.start_unit(sup_name, opts)
      assert is_pid(unit_pid), "start_unit must return a pid"

      # Advance oracle → implementing.
      drive_oracle_to_implementing(unit_pid, worker_id)

      result = wait_for_implementing(unit_pid)

      assert match?({:implementing, _}, result),
             "D-326: Unit must reach :implementing; got #{inspect(result)}"

      {:implementing, data_before} = result
      attempt_before = Map.get(data_before, :attempt_count, 0)
      refine_before = Map.get(data_before, :refine_count, 0)

      # Send the semantic non-completion — exit-0-without-work_ready.
      send(unit_pid, {:worker_exit, worker_id, :no_work_product})

      # Allow FSM to process and re-enter :implementing via the retry ladder.
      :timer.sleep(200)

      {state_after, data_after} = :sys.get_state(unit_pid)

      assert state_after == :implementing,
             "D-326 [C111b-B8]: {:worker_exit, id, :no_work_product} must route to the retry " <>
               "ladder and re-enter :implementing; got state=#{inspect(state_after)}. " <>
               "On current code (no worker_exit handler) the message is ignored and the Unit " <>
               "stays stuck — or the subsequent :DOWN escalates to E_WORKER_DOWN."

      refine_after = Map.get(data_after, :refine_count, 0)
      attempt_after = Map.get(data_after, :attempt_count, 0)

      assert refine_after > refine_before or attempt_after > attempt_before,
             "D-326: after routing through the retry ladder, refine_count or attempt_count " <>
               "must have incremented (ladder progressed); refine_before=#{refine_before} " <>
               "refine_after=#{refine_after}, attempt_before=#{attempt_before} " <>
               "attempt_after=#{attempt_after}"

      # Gate must NOT have been called — :no_work_product is retry, never gated.
      gate_calls = :counters.get(gate_called_ref, 1)

      assert gate_calls == 0,
             "D-326 [C111b-B8]: gate_fun must NOT be called for a semantic :no_work_product " <>
               "exit (retry ladder, never gated); called #{gate_calls} times"

      # No terminal report should have arrived yet.
      refute_received {:unit_terminal, ^unit_id, _outcome, _prov},
                      "D-326: a single :no_work_product exit must route to retry, not terminate"
    end
  end

  # ---------------------------------------------------------------------------
  # Test 2 — D-326: :error and {:exit_status, n} → retry ladder, not escalate
  # ---------------------------------------------------------------------------

  describe "D-326 [C105-B5] — worker_exit :error and {:exit_status,n} route to retry ladder" do
    @tag :d_326
    test "D-326 :error: {:worker_exit, worker_id, :error} routes to retry ladder, NOT E_WORKER_DOWN" do
      test_pid = self()
      unit_id = "u-err-retry-#{System.unique_integer([:positive])}"
      scheduler_name = :"sched_err_#{System.unique_integer([:positive])}"
      sup_name = :"sup_err_#{System.unique_integer([:positive])}"

      start_scheduler(scheduler_name)
      start_supervised!({@unit_supervisor, name: sup_name}, id: sup_name)

      gate_called_ref = :counters.new(1, [:atomics])

      gate_fun = fn _coord ->
        :counters.add(gate_called_ref, 1, 1)
        :pass
      end

      worker_id = "w-err-#{System.unique_integer([:positive])}"

      opts =
        base_unit_opts(unit_id, scheduler_name, test_pid,
          worker_fun: fn _role -> {:ok, spawn_worker(), worker_id} end,
          gate_fun: gate_fun,
          merge_fun: fn _uid, _hash -> :queued end,
          timeouts: [state_timeout_ms: 5_000]
        )

      unit_pid = @unit_supervisor.start_unit(sup_name, opts)
      assert is_pid(unit_pid), "start_unit must return a pid"

      drive_oracle_to_implementing(unit_pid, worker_id)
      result = wait_for_implementing(unit_pid)

      assert match?({:implementing, _}, result),
             "D-326: Unit must reach :implementing; got #{inspect(result)}"

      {:implementing, data_before} = result
      refine_before = Map.get(data_before, :refine_count, 0)
      attempt_before = Map.get(data_before, :attempt_count, 0)

      # Semantic agent failure: the agent itself reported an error (not an infra crash).
      send(unit_pid, {:worker_exit, worker_id, :error})

      :timer.sleep(200)

      {state_after, data_after} = :sys.get_state(unit_pid)

      assert state_after == :implementing,
             "D-326 [C105-B5]: {:worker_exit, id, :error} must route to the retry ladder and " <>
               "re-enter :implementing; got state=#{inspect(state_after)}. " <>
               "On current code (no worker_exit clause) this is ignored; the :DOWN that follows " <>
               "escalates to E_WORKER_DOWN instead of entering the retry ladder."

      refine_after = Map.get(data_after, :refine_count, 0)
      attempt_after = Map.get(data_after, :attempt_count, 0)

      assert refine_after > refine_before or attempt_after > attempt_before,
             "D-326: ladder must have progressed; refine #{refine_before}→#{refine_after}, " <>
               "attempt #{attempt_before}→#{attempt_after}"

      gate_calls = :counters.get(gate_called_ref, 1)

      assert gate_calls == 0,
             "D-326 [C105-B5]: gate_fun must NOT be called on a semantic :error exit " <>
               "(retry ladder, not a gate outcome); called #{gate_calls} times"

      refute_received {:unit_terminal, ^unit_id, _outcome, _prov},
                      "D-326: a single :error worker_exit must route to retry, not terminate"
    end

    @tag :d_326
    test "D-326 exit_status: {:worker_exit, worker_id, {:exit_status,1}} routes to retry ladder, NOT E_WORKER_DOWN" do
      test_pid = self()
      unit_id = "u-exitstatus-retry-#{System.unique_integer([:positive])}"
      scheduler_name = :"sched_exst_#{System.unique_integer([:positive])}"
      sup_name = :"sup_exst_#{System.unique_integer([:positive])}"

      start_scheduler(scheduler_name)
      start_supervised!({@unit_supervisor, name: sup_name}, id: sup_name)

      gate_called_ref = :counters.new(1, [:atomics])

      gate_fun = fn _coord ->
        :counters.add(gate_called_ref, 1, 1)
        :pass
      end

      worker_id = "w-exst-#{System.unique_integer([:positive])}"

      opts =
        base_unit_opts(unit_id, scheduler_name, test_pid,
          worker_fun: fn _role -> {:ok, spawn_worker(), worker_id} end,
          gate_fun: gate_fun,
          merge_fun: fn _uid, _hash -> :queued end,
          timeouts: [state_timeout_ms: 5_000]
        )

      unit_pid = @unit_supervisor.start_unit(sup_name, opts)
      assert is_pid(unit_pid), "start_unit must return a pid"

      drive_oracle_to_implementing(unit_pid, worker_id)
      result = wait_for_implementing(unit_pid)

      assert match?({:implementing, _}, result),
             "D-326: Unit must reach :implementing; got #{inspect(result)}"

      {:implementing, data_before} = result
      refine_before = Map.get(data_before, :refine_count, 0)
      attempt_before = Map.get(data_before, :attempt_count, 0)

      # Non-zero exit code surfaces as {:exit_status, 1} — a semantic failure.
      send(unit_pid, {:worker_exit, worker_id, {:exit_status, 1}})

      :timer.sleep(200)

      {state_after, data_after} = :sys.get_state(unit_pid)

      assert state_after == :implementing,
             "D-326 [C105-B5]: {:worker_exit, id, {:exit_status,1}} must route to the retry " <>
               "ladder and re-enter :implementing; got state=#{inspect(state_after)}."

      refine_after = Map.get(data_after, :refine_count, 0)
      attempt_after = Map.get(data_after, :attempt_count, 0)

      assert refine_after > refine_before or attempt_after > attempt_before,
             "D-326: ladder must have progressed; refine #{refine_before}→#{refine_after}, " <>
               "attempt #{attempt_before}→#{attempt_after}"

      gate_calls = :counters.get(gate_called_ref, 1)

      assert gate_calls == 0,
             "D-326 [C105-B5]: gate_fun must NOT be called on a {:exit_status,1} worker_exit; " <>
               "called #{gate_calls} times"

      refute_received {:unit_terminal, ^unit_id, _outcome, _prov},
                      "D-326: a single {:exit_status,1} worker_exit must route to retry, not terminate"
    end
  end

  # ---------------------------------------------------------------------------
  # Test 3 — D-326 / D-318: repeated semantic exits exhaust ladder → E_RETRY_EXHAUSTED
  # ---------------------------------------------------------------------------

  describe "D-326 / D-318 — repeated semantic worker_exits exhaust the retry ladder" do
    @tag :d_326
    @tag :d_318
    test "D-326/D-318: enough semantic :no_work_product exits exhaust the retry ladder → :escalated :E_RETRY_EXHAUSTED" do
      test_pid = self()
      unit_id = "u-exhaust-#{System.unique_integer([:positive])}"
      scheduler_name = :"sched_exhaust_#{System.unique_integer([:positive])}"
      sup_name = :"sup_exhaust_#{System.unique_integer([:positive])}"

      start_scheduler(scheduler_name)
      start_supervised!({@unit_supervisor, name: sup_name}, id: sup_name)

      n_refine = Retry.n_refine()
      n_pivot = Retry.n_pivot()

      # We need to exhaust the full retry ladder via semantic exits only.
      # Ladder (D-318): N_REFINE refines + N_PIVOT pivot = N_REFINE + N_PIVOT total
      # non-terminal outcomes before :exhausted. Each semantic worker_exit consumes
      # one ladder step without a gate call. After N_REFINE + N_PIVOT steps the next
      # worker_exit (or gate-fail if gating is ever reached) yields :exhausted.
      # We deliver N_REFINE + N_PIVOT + 1 semantic exits total.
      total_exits = n_refine + n_pivot + 1

      gate_called_ref = :counters.new(1, [:atomics])

      gate_fun = fn _coord ->
        :counters.add(gate_called_ref, 1, 1)
        :pass
      end

      # We need fresh worker pids per implementing cycle. Use a counter to hand out
      # sequential worker_ids so the Unit correctly keys each cycle.
      exit_count_ref = :counters.new(1, [:atomics])
      # Store pid→worker_id so we can drive work_ready in oracle correctly.
      ets = :ets.new(:wpid_exhaust, [:set, :public])

      worker_fun = fn _role ->
        idx =
          :counters.add(exit_count_ref, 1, 1) |> then(fn _ -> :counters.get(exit_count_ref, 1) end)

        wid = "w-exhaust-#{unit_id}-#{idx}"
        pid = spawn_worker()
        :ets.insert(ets, {idx, pid, wid})
        {:ok, pid, wid}
      end

      opts =
        base_unit_opts(unit_id, scheduler_name, test_pid,
          worker_fun: worker_fun,
          gate_fun: gate_fun,
          merge_fun: fn _uid, _hash -> :queued end,
          timeouts: [state_timeout_ms: 5_000]
        )

      unit_pid = @unit_supervisor.start_unit(sup_name, opts)
      assert is_pid(unit_pid), "start_unit must return a pid"

      # Advance oracle (drives worker_fun call #1 which is for :test_author role).
      # Find the worker_id for the oracle worker and deliver work_ready.
      :timer.sleep(50)

      case :sys.get_state(unit_pid) do
        {:oracle, data} ->
          oracle_wid = Map.get(data, :worker_id)
          send(unit_pid, {:work_ready, oracle_wid, "feat/oracle", "aabb0011"})

        {state, _} ->
          flunk("D-326: expected :oracle after start; got #{inspect(state)}")
      end

      # Drive total_exits semantic worker_exit cycles through :implementing.
      for _i <- 1..total_exits do
        # Wait until we are in :implementing.
        result = wait_for_implementing(unit_pid, 3_000)

        case result do
          {:implementing, data} ->
            wid = Map.get(data, :worker_id)
            send(unit_pid, {:worker_exit, wid, :no_work_product})
            # Allow FSM to process the exit and re-enter the next state.
            :timer.sleep(150)

          {state, _} when state in [:escalated] ->
            # Already exhausted — stop driving.
            :ok

          {state, _} ->
            flunk("D-326/D-318: unexpected state #{inspect(state)} mid-exhaustion loop")
        end
      end

      # All ladder steps consumed. The Unit must now be terminal :escalated.
      assert_receive {:unit_terminal, ^unit_id, :escalated, provenance},
                     10_000,
                     "D-326/D-318: after #{total_exits} semantic worker_exits (#{n_refine} refines + " <>
                       "#{n_pivot} pivot exhausted), the Unit must reach :escalated. " <>
                       "On current code the message is ignored → the Unit is stuck, never exhausted."

      reason = Map.get(provenance, :reason)

      assert reason == :E_RETRY_EXHAUSTED,
             "D-318: exhausted escalation must carry :E_RETRY_EXHAUSTED; got #{inspect(reason)}"

      # gate_fun must NEVER have been called — semantic exits skip the gate.
      gate_calls = :counters.get(gate_called_ref, 1)

      assert gate_calls == 0,
             "D-326 [C111b-B8]: gate_fun must NEVER be called for semantic worker_exit " <>
               "exhaustion (retry ladder, never gated); called #{gate_calls} times"

      in_flight = @scheduler.in_flight(scheduler_name)

      refute Map.has_key?(in_flight, unit_id),
             "D-326/D-318: after :escalated, unit must be released from Scheduler in_flight"

      :ets.delete(ets)
    end
  end

  # ---------------------------------------------------------------------------
  # Test 4 — D-326: genuine infra :DOWN (no prior semantic exit) → E_WORKER_DOWN
  # ---------------------------------------------------------------------------

  describe "D-326 [B8/C105] — genuine infra :DOWN (no prior semantic exit) escalates E_WORKER_DOWN" do
    @tag :d_326
    @tag :b8
    @tag :c105
    test "D-326/B8/C105: a :DOWN with NO preceding semantic worker_exit escalates :E_WORKER_DOWN (preserved behaviour)" do
      test_pid = self()
      unit_id = "u-infradown-#{System.unique_integer([:positive])}"
      scheduler_name = :"sched_infradown_#{System.unique_integer([:positive])}"
      sup_name = :"sup_infradown_#{System.unique_integer([:positive])}"

      start_scheduler(scheduler_name)
      start_supervised!({@unit_supervisor, name: sup_name}, id: sup_name)

      gate_called_ref = :counters.new(1, [:atomics])

      gate_fun = fn _coord ->
        :counters.add(gate_called_ref, 1, 1)
        :pass
      end

      # Capture worker pids so we can kill the implementing-phase worker directly.
      ets = :ets.new(:wpid_infradown, [:set, :public])

      worker_fun = fn role ->
        pid = spawn_worker()
        :ets.insert(ets, {role, pid})
        {:ok, pid}
      end

      opts =
        base_unit_opts(unit_id, scheduler_name, test_pid,
          worker_fun: worker_fun,
          gate_fun: gate_fun,
          merge_fun: fn _uid, _hash -> :queued end,
          timeouts: [state_timeout_ms: 5_000]
        )

      unit_pid = @unit_supervisor.start_unit(sup_name, opts)
      assert is_pid(unit_pid), "start_unit must return a pid"

      # Advance oracle (2-tuple seam: {:worker_done, pid}).
      :timer.sleep(50)

      oracle_pid =
        case :ets.lookup(ets, :test_author) do
          [{_, p}] -> p
          _ -> nil
        end

      if is_pid(oracle_pid), do: send(unit_pid, {:worker_done, oracle_pid})
      :timer.sleep(80)

      # Confirm we are in :implementing.
      {impl_state, impl_data} = :sys.get_state(unit_pid)

      assert impl_state == :implementing,
             "D-326: Unit must be in :implementing; got #{inspect(impl_state)}"

      implementing_pid = Map.get(impl_data, :worker_pid)

      assert is_pid(implementing_pid),
             "B8: Unit must expose :worker_pid in state data (real pid); " <>
               "got #{inspect(impl_data)}"

      # Kill the worker abnormally — pure infra crash, NO preceding semantic exit.
      # The Unit's Process.monitor/1 delivers {:DOWN, _, :process, pid, :killed}.
      Process.exit(implementing_pid, :kill)

      assert_receive {:unit_terminal, ^unit_id, :escalated, provenance},
                     5_000,
                     "D-326/B8/C105: a pure infra :DOWN (kill, no semantic exit) must escalate " <>
                       "E_WORKER_DOWN; not received within 5s."

      reason = Map.get(provenance, :reason)

      assert reason == :E_WORKER_DOWN,
             "B8/C105: infra :DOWN must escalate :E_WORKER_DOWN, not #{inspect(reason)}"

      gate_calls = :counters.get(gate_called_ref, 1)

      assert gate_calls == 0,
             "C105: gate_fun must NOT be called for a pure infra :DOWN; called #{gate_calls} times"

      :ets.delete(ets)
    end
  end

  # ---------------------------------------------------------------------------
  # Test 5 — D-326: consequent monitor :DOWN after semantic exit does NOT re-fire
  # ---------------------------------------------------------------------------

  describe "D-326 [B8 disjointness] — monitor :DOWN after semantic worker_exit does not fire a second outcome" do
    @tag :d_326
    @tag :b8
    test "D-326/B8: after semantic worker_exit routes to retry, the subsequent monitor :DOWN is suppressed — one exit, one outcome" do
      test_pid = self()
      unit_id = "u-nodup-#{System.unique_integer([:positive])}"
      scheduler_name = :"sched_nodup_#{System.unique_integer([:positive])}"
      sup_name = :"sup_nodup_#{System.unique_integer([:positive])}"

      start_scheduler(scheduler_name)
      start_supervised!({@unit_supervisor, name: sup_name}, id: sup_name)

      # gate_fun always fails so we do not proceed past gating (keeps state stable).
      gate_called_ref = :counters.new(1, [:atomics])

      gate_fun = fn _coord ->
        :counters.add(gate_called_ref, 1, 1)
        {:fail, [:stop_here]}
      end

      worker_id = "w-nodup-#{System.unique_integer([:positive])}"

      # The Unit must demonitor the previous worker before spawning the next one
      # so that the prior worker's :DOWN does not fire a second escalation.
      # Use a real, killable process.
      worker_pid_ref = make_ref()
      # We need to capture the implementing-phase worker pid BEFORE sending exit.
      ets = :ets.new(:wpid_nodup, [:set, :public])

      worker_fun = fn _role ->
        pid = spawn_worker()
        :ets.insert(ets, {worker_pid_ref, pid})
        {:ok, pid, worker_id}
      end

      opts =
        base_unit_opts(unit_id, scheduler_name, test_pid,
          worker_fun: worker_fun,
          gate_fun: gate_fun,
          merge_fun: fn _uid, _hash -> :queued end,
          timeouts: [state_timeout_ms: 5_000]
        )

      unit_pid = @unit_supervisor.start_unit(sup_name, opts)
      assert is_pid(unit_pid), "start_unit must return a pid"

      # Advance oracle → implementing via work_ready.
      drive_oracle_to_implementing(unit_pid, worker_id)

      result = wait_for_implementing(unit_pid)

      assert match?({:implementing, _}, result),
             "D-326: Unit must reach :implementing; got #{inspect(result)}"

      {:implementing, impl_data} = result
      current_impl_pid = Map.get(impl_data, :worker_pid)

      assert is_pid(current_impl_pid),
             "B8: Unit must expose :worker_pid in state data; got #{inspect(impl_data)}"

      # Send the semantic exit — the Unit should demonitor and route to retry.
      send(unit_pid, {:worker_exit, worker_id, :no_work_product})

      # Allow FSM to process the exit, demonitor the old worker, enter retry.
      :timer.sleep(200)

      # Now kill the old worker — if the Unit did NOT demonitor it, the :DOWN fires
      # and (before this PR's fix) would escalate E_WORKER_DOWN as a SECOND outcome.
      Process.exit(current_impl_pid, :kill)

      # Allow time for any spurious :DOWN to reach the Unit mailbox.
      :timer.sleep(200)

      # The Unit must be back in :implementing (retry ladder re-entry), NOT escalated.
      {state_now, _} = :sys.get_state(unit_pid)

      assert state_now == :implementing,
             "D-326 [B8 disjointness]: after semantic worker_exit routed to retry, the " <>
               "subsequent :DOWN for the same worker must NOT fire a second escalation. " <>
               "Unit must be in :implementing; got #{inspect(state_now)}. " <>
               "On current code: no semantic exit handler → :DOWN hits the implementing " <>
               ":DOWN clause → E_WORKER_DOWN (the very scenario this fix prevents)."

      # No terminal report should have arrived (single retry step, not exhausted).
      refute_received {:unit_terminal, ^unit_id, :escalated, _},
                      "D-326 [B8 disjointness]: the :DOWN for the prior worker must not " <>
                        "generate a second :escalated outcome after the semantic exit already routed to retry"

      :ets.delete(ets)
    end
  end

  # ---------------------------------------------------------------------------
  # Test 6 — D-326: stale worker_id → discarded, no retry, no escalate
  # ---------------------------------------------------------------------------

  describe "D-326 [B8 stale-worker] — worker_exit from a stale worker_id is discarded" do
    @tag :d_326
    @tag :b8
    test "D-326/B8: {:worker_exit, other_worker_id, :no_work_product} does NOT trigger retry or escalate" do
      test_pid = self()
      unit_id = "u-stale-exit-#{System.unique_integer([:positive])}"
      scheduler_name = :"sched_stale_exit_#{System.unique_integer([:positive])}"
      sup_name = :"sup_stale_exit_#{System.unique_integer([:positive])}"

      start_scheduler(scheduler_name)
      start_supervised!({@unit_supervisor, name: sup_name}, id: sup_name)

      gate_called_ref = :counters.new(1, [:atomics])

      gate_fun = fn _coord ->
        :counters.add(gate_called_ref, 1, 1)
        :pass
      end

      current_worker_id = "w-current-#{System.unique_integer([:positive])}"

      opts =
        base_unit_opts(unit_id, scheduler_name, test_pid,
          worker_fun: fn _role -> {:ok, spawn_worker(), current_worker_id} end,
          gate_fun: gate_fun,
          merge_fun: fn _uid, _hash -> :queued end,
          timeouts: [state_timeout_ms: 5_000]
        )

      unit_pid = @unit_supervisor.start_unit(sup_name, opts)
      assert is_pid(unit_pid), "start_unit must return a pid"

      # Advance oracle → implementing.
      drive_oracle_to_implementing(unit_pid, current_worker_id)

      result = wait_for_implementing(unit_pid)

      assert match?({:implementing, _}, result),
             "D-326: Unit must reach :implementing; got #{inspect(result)}"

      {:implementing, data_before} = result
      refine_before = Map.get(data_before, :refine_count, 0)
      attempt_before = Map.get(data_before, :attempt_count, 0)

      # Send worker_exit keyed by a STALE / DIFFERENT worker_id — must be discarded.
      stale_worker_id = "w-stale-#{System.unique_integer([:positive])}"
      send(unit_pid, {:worker_exit, stale_worker_id, :no_work_product})

      :timer.sleep(200)

      {state_after, data_after} = :sys.get_state(unit_pid)

      assert state_after == :implementing,
             "D-326 [B8 stale-worker]: worker_exit from a stale worker_id must be discarded — " <>
               "Unit remains in :implementing, not #{inspect(state_after)}"

      refine_after = Map.get(data_after, :refine_count, 0)
      attempt_after = Map.get(data_after, :attempt_count, 0)

      assert refine_before == refine_after and attempt_before == attempt_after,
             "D-326 [B8 stale-worker]: stale worker_exit must not advance the ladder; " <>
               "refine #{refine_before}→#{refine_after}, attempt #{attempt_before}→#{attempt_after}"

      gate_calls = :counters.get(gate_called_ref, 1)

      assert gate_calls == 0,
             "D-326: stale worker_exit must not call gate_fun; called #{gate_calls} times"

      refute_received {:unit_terminal, ^unit_id, _outcome, _prov},
                      "D-326 [B8 stale-worker]: stale worker_exit must not produce any terminal report"
    end
  end
end
