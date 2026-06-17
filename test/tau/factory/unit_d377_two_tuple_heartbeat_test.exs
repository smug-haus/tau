defmodule Tau.Factory.UnitD377TwoTupleHeartbeatTest do
  @moduledoc """
  Gating test for issue #628 — D-377 2-tuple seam gap.

  ## Invariant under test

  **D-377** — each current-worker progress heartbeat (`{:worker_heartbeat, w}`)
  re-arms the per-state `:state_timeout` in BOTH `oracle` and `implementing`.
  A genuinely-progressing agent that pulses at least once per `state_timeout_ms`
  window MUST never trip the cap.

  ## GAP (issue #628)

  When `worker_fun` returns `{:ok, worker_pid}` (the legacy 2-tuple form), the
  Unit stores `worker_id: nil`.  The heartbeat clause carries the guard
  `when not is_nil(worker_id)` — so `{:worker_heartbeat, nil}` (the only
  heartbeat message a 2-tuple worker can send, keyed by its nil `worker_id`)
  NEVER matches the re-arm clause.  It falls through to the stale-worker discard
  clause (`{:keep_state, data}` with no actions list) and the `:state_timeout` is
  NOT re-armed.

  Evidence (unit.ex):
  - Line ~273: `updated_data = %{new_data | worker_pid: pid, worker_id: nil, …}` (oracle)
  - Line ~458: same for implementing
  - Line ~368: `def oracle(:info, {:worker_heartbeat, worker_id}, %{worker_id: worker_id} = data) when not is_nil(worker_id)` — guard fails for nil
  - Line ~548: same guard for implementing
  - Lines ~375, ~555: stale-discard clauses — `{:keep_state, data}` with NO actions
    — the `:state_timeout` fires at the fixed wall.

  A 2-tuple worker that sends `{:worker_heartbeat, nil}` continuously will still
  trip the fixed-wall `:state_timeout` — identical to silence.

  ## Fail-before validity

  Both tests fail against the current production code:
  - oracle test: Unit escalates `:E_WORKER_STALLED` during the heartbeat stream
    because `{:worker_heartbeat, nil}` falls to stale-discard (no re-arm).
  - implementing test: same — Unit escalates `:E_WORKER_STALLED` during the
    heartbeat stream for the implementing state.

  ## AC / D-NNN linkage (Gate 5.1)

  Both tests carry `@tag :d_377` and reference `D-377` in their names.
  """

  # async: false — exercises timing-sensitive OTP :state_timeout behaviour.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Tau.Factory.Scheduler
  alias Tau.Factory.UnitSupervisor

  @scheduler Scheduler
  @unit_supervisor UnitSupervisor

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

  defp wait_for_oracle(unit_pid, deadline_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_wait_oracle(unit_pid, deadline)
  end

  defp do_wait_oracle(unit_pid, deadline) do
    case :sys.get_state(unit_pid) do
      {:oracle, data} ->
        {:oracle, data}

      {:planned, _} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:timeout, :planned}
        else
          Process.sleep(20)
          do_wait_oracle(unit_pid, deadline)
        end

      {state, data} ->
        {state, data}
    end
  end

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

  # Advance past oracle using the 5-tuple work_ready form (INV-WF-13).
  # The oracle refuses a 4-tuple form (no gating_test_paths), so we must send
  # the 5-tuple form with a non-empty paths list.
  defp advance_past_oracle_5tuple(unit_pid, oracle_worker_id, deadline_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_advance_oracle_5tuple(unit_pid, oracle_worker_id, deadline)
  end

  defp do_advance_oracle_5tuple(unit_pid, oracle_worker_id, deadline) do
    case :sys.get_state(unit_pid) do
      {:oracle, _data} ->
        send(unit_pid, {:work_ready, oracle_worker_id, "feat/x", "deadbeef", ["test/gating.exs"]})
        :ok

      {:planned, _} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:timeout, :planned}
        else
          Process.sleep(20)
          do_advance_oracle_5tuple(unit_pid, oracle_worker_id, deadline)
        end

      {:implementing, _} ->
        :ok

      {other, _} ->
        {:unexpected, other}
    end
  end

  defp hb_loop_from_test(_unit_pid, _worker_id, _interval_ms, remaining_ms)
       when remaining_ms <= 0,
       do: :ok

  defp hb_loop_from_test(unit_pid, worker_id, interval_ms, remaining_ms) do
    send(unit_pid, {:worker_heartbeat, worker_id})
    Process.sleep(interval_ms)
    hb_loop_from_test(unit_pid, worker_id, interval_ms, remaining_ms - interval_ms)
  end

  # ---------------------------------------------------------------------------
  # D-377 (2-tuple seam) — {:worker_heartbeat, nil} MUST re-arm :state_timeout
  # in :implementing when worker_fun returns the 2-tuple legacy form.
  # ---------------------------------------------------------------------------

  describe "D-377 2-tuple seam: {:worker_heartbeat, nil} re-arms :state_timeout in :implementing" do
    @tag :d_377
    test "D-377 2-tuple seam implementing: heartbeats with nil worker_id keep Unit in :implementing past old fixed cap" do
      test_pid = self()
      unit_id = "u-d377-2tuple-impl-#{System.unique_integer([:positive])}"
      scheduler_name = :"sched_d377_2tuple_impl_#{System.unique_integer([:positive])}"
      sup_name = :"sup_d377_2tuple_impl_#{System.unique_integer([:positive])}"

      start_scheduler(scheduler_name)
      start_supervised!({@unit_supervisor, name: sup_name}, id: sup_name)

      state_timeout_ms = 1_000

      # Oracle call: 3-tuple so we can advance via work_ready with a known id.
      # Implementing calls: 2-tuple legacy form -> worker_id stored as nil.
      oracle_worker_id = "w-d377-2tuple-oracle-#{System.unique_integer([:positive])}"
      call_count = :counters.new(1, [:atomics])

      worker_fun = fn _role ->
        n = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)
        pid = spawn_worker()

        if n == 0,
          # oracle call: 3-tuple with known id (so advance_past_oracle_5tuple can send it)
          do: {:ok, pid, oracle_worker_id},
          # implementing calls: 2-tuple legacy form -> worker_id stored as nil
          else: {:ok, pid}
      end

      opts =
        base_unit_opts(unit_id, scheduler_name, test_pid,
          worker_fun: worker_fun,
          timeouts: [state_timeout_ms: state_timeout_ms]
        )

      unit_pid = @unit_supervisor.start_unit(sup_name, opts)
      assert is_pid(unit_pid)

      # Use 5-tuple work_ready (INV-WF-13 requires gating_test_paths).
      advance_past_oracle_5tuple(unit_pid, oracle_worker_id)
      result = wait_for_implementing(unit_pid)

      assert match?({:implementing, _}, result),
             "D-377 2-tuple seam: Unit must reach :implementing; got #{inspect(result)}"

      {:implementing, data_impl} = result

      # Confirm the 2-tuple seam is active: worker_id must be nil.
      assert is_nil(data_impl.worker_id),
             "D-377 2-tuple seam precondition: worker_id must be nil for a 2-tuple " <>
               "worker_fun; got #{inspect(data_impl.worker_id)}. " <>
               "worker_fun did not return the 2-tuple form on the implementing call."

      # Drive {:worker_heartbeat, nil} at 200ms intervals for 3x the state_timeout.
      #
      # D-377 requires the :state_timeout to be re-armed on every pulse, even when
      # worker_id is nil (2-tuple seam). Without the re-arm the Unit escalates
      # at 1000ms; with the re-arm it must remain in :implementing for 3000ms.
      #
      # FAIL-BEFORE (issue #628): the heartbeat clause guards
      # `when not is_nil(worker_id)` -- {:worker_heartbeat, nil} falls through to
      # the stale-discard clause without re-arming :state_timeout.
      hb_interval_ms = 200
      total_hb_duration_ms = 3 * state_timeout_ms

      hb_loop_from_test(unit_pid, nil, hb_interval_ms, total_hb_duration_ms)

      {state_after, _data} = :sys.get_state(unit_pid)

      assert state_after == :implementing,
             "D-377 2-tuple seam: Unit fed {:worker_heartbeat, nil} (2-tuple worker, " <>
               "worker_id == nil) at #{hb_interval_ms}ms intervals MUST stay in " <>
               ":implementing past the old fixed cap (#{total_hb_duration_ms}ms total). " <>
               "Got state=#{inspect(state_after)}. " <>
               "FAIL-BEFORE (issue #628): implementing/3 heartbeat clause guards " <>
               "`when not is_nil(worker_id)` -- {:worker_heartbeat, nil} falls through " <>
               "to the stale-discard clause ({:keep_state, data} with no actions) " <>
               "and the :state_timeout is NOT re-armed. The 2-tuple seam provides " <>
               "zero inactivity-deadline reset."
    end
  end

  # ---------------------------------------------------------------------------
  # D-377 (2-tuple seam) -- {:worker_heartbeat, nil} MUST re-arm :state_timeout
  # in :oracle when worker_fun returns the 2-tuple legacy form.
  # ---------------------------------------------------------------------------

  describe "D-377 2-tuple seam: {:worker_heartbeat, nil} re-arms :state_timeout in :oracle" do
    @tag :d_377
    test "D-377 2-tuple seam oracle: heartbeats with nil worker_id keep Unit in :oracle past old fixed cap" do
      test_pid = self()
      unit_id = "u-d377-2tuple-oracle-#{System.unique_integer([:positive])}"
      scheduler_name = :"sched_d377_2tuple_oracle_#{System.unique_integer([:positive])}"
      sup_name = :"sup_d377_2tuple_oracle_#{System.unique_integer([:positive])}"

      start_scheduler(scheduler_name)
      start_supervised!({@unit_supervisor, name: sup_name}, id: sup_name)

      state_timeout_ms = 1_000

      # All worker_fun calls return 2-tuple -> oracle also gets worker_id: nil.
      worker_fun = fn _role ->
        pid = spawn_worker()
        {:ok, pid}
      end

      opts =
        base_unit_opts(unit_id, scheduler_name, test_pid,
          worker_fun: worker_fun,
          timeouts: [state_timeout_ms: state_timeout_ms]
        )

      unit_pid = @unit_supervisor.start_unit(sup_name, opts)
      assert is_pid(unit_pid)

      # Wait in :oracle -- do NOT advance past oracle.
      result = wait_for_oracle(unit_pid)

      assert match?({:oracle, _}, result),
             "D-377 2-tuple seam oracle: Unit must reach :oracle; got #{inspect(result)}"

      {:oracle, data_oracle} = result

      # Confirm the 2-tuple seam is active: worker_id must be nil.
      assert is_nil(data_oracle.worker_id),
             "D-377 2-tuple seam oracle precondition: worker_id must be nil for a " <>
               "2-tuple worker_fun; got #{inspect(data_oracle.worker_id)}. " <>
               "worker_fun did not return the 2-tuple form."

      hb_interval_ms = 200
      total_hb_duration_ms = 3 * state_timeout_ms

      hb_loop_from_test(unit_pid, nil, hb_interval_ms, total_hb_duration_ms)

      {state_after, _data} = :sys.get_state(unit_pid)

      assert state_after == :oracle,
             "D-377 2-tuple seam oracle: Unit fed {:worker_heartbeat, nil} (2-tuple " <>
               "worker, worker_id == nil) at #{hb_interval_ms}ms intervals MUST stay " <>
               "in :oracle past the old fixed cap (#{total_hb_duration_ms}ms total). " <>
               "Got state=#{inspect(state_after)}. " <>
               "FAIL-BEFORE (issue #628): oracle/3 heartbeat clause guards " <>
               "`when not is_nil(worker_id)` -- {:worker_heartbeat, nil} falls through " <>
               "to the stale-discard clause without re-arming :state_timeout."
    end
  end
end
