defmodule Tau.Factory.UnitWorkerExitTest do
  @moduledoc """
  Gating tests for PR #507 (issue #490 — A3: route semantic worker_exit to the
  retry ladder).

  Advances D-326 (SPEC-FACTORY-CORE §4 B8 [C111b-B8] / [C105-B5]):

    * **Race oracle (NEW):** a synthetic BEAM `:DOWN` delivered to the Unit's
      mailbox *before* `{:worker_exit, worker_id, reason}` (simulating the
      one-hop `:DOWN` winning over the two-hop fleet signal) MUST NOT cause
      `E_WORKER_DOWN`. For the 3-tuple path the Unit must treat `:DOWN` as a
      non-outcome when `data.worker_id` is non-nil and route the eventual
      `worker_exit` to the retry ladder.  This test FAILS against the current
      impl (the `:DOWN` handler fires unconditionally and escalates
      `E_WORKER_DOWN`).

    * `worker_exit(w, :no_work_product)` — exit-0-without-work_ready — is routed
      to the retry ladder, NEVER gated.

    * `worker_exit(w, :error)` and `worker_exit(w, {:exit_status, n})` — semantic
      agent failures — are routed to the retry ladder, NOT escalated via the :DOWN
      infra path.

    * Repeated semantic exits exhaust the ladder →
      `escalated(:E_RETRY_EXHAUSTED)` (D-318).

    * A genuine infra :DOWN on a **2-tuple** (legacy `worker_id == nil`) worker
      still escalates `E_WORKER_DOWN` (preserved behaviour — the 2-tuple seam is
      unchanged by this PR).

    * **3-tuple vanish without `worker_exit` → `E_WORKER_STALLED`, NOT
      `E_WORKER_DOWN`:** when a 3-tuple worker process dies before sending
      `worker_exit`, the Unit must surface this via the stall detection path
      (`E_WORKER_STALLED`), never via `E_WORKER_DOWN`.  This FAILS against the
      current impl (the `:DOWN` handler fires unconditionally and escalates
      `E_WORKER_DOWN`).

    * A `{:worker_exit, other_worker_id, _}` not matching the current worker_id is
      discarded (stale-worker guard, B8).

  ## D-326 token linkage

  Every test in this file carries the D-326 token (in its name and/or @tag) as
  required by factory-loop §4b gate 5.1.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log
  @moduletag :d_326

  alias Tau.Factory.Retry

  @unit_supervisor Tau.Factory.UnitSupervisor
  @scheduler Tau.Factory.Scheduler

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
    start_supervised!(
      {@scheduler, name: name, w_cap: 10},
      id: name
    )
  end

  # Spawn a long-lived stub process; the test controls its lifetime.
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

  # Advance the Unit past the oracle state by sending work_ready for the
  # oracle worker.  Polls :sys.get_state/1 until oracle state is observed,
  # then delivers work_ready.
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
        # Already transitioned — oracle was advanced before we polled.
        :ok

      {other, _} ->
        {:unexpected, other}
    end
  end

  # ---------------------------------------------------------------------------
  # RACE TEST (NEW, key oracle) — D-326
  #
  # Delivers a synthetic BEAM :DOWN to the Unit's mailbox BEFORE the semantic
  # worker_exit, simulating the one-hop :DOWN arriving ahead of the two-hop
  # fleet signal.
  #
  # Fail-before: the current implementing/3 :DOWN clause matches on worker_pid
  # unconditionally (no worker_id guard), so the :DOWN fires first and
  # escalates E_WORKER_DOWN — directly contradicting [C111b-B8].
  #
  # Pass-after (no-self-monitor design): the :DOWN clause MUST be suppressed for
  # 3-tuple workers (worker_id non-nil). The Unit only acts on the subsequent
  # {:worker_exit, worker_id, reason} which routes to the retry ladder.
  # ---------------------------------------------------------------------------

  describe "D-326 [C111b-B8] race: 3-tuple :DOWN before worker_exit" do
    @tag :d_326
    test "D-326 race: :DOWN before worker_exit — Unit routes to retry, NEVER E_WORKER_DOWN" do
      test_pid = self()
      unit_id = "u-race-down-#{System.unique_integer([:positive])}"
      scheduler_name = :"sched_race_#{System.unique_integer([:positive])}"
      sup_name = :"sup_race_#{System.unique_integer([:positive])}"

      start_scheduler(scheduler_name)
      start_supervised!({@unit_supervisor, name: sup_name}, id: sup_name)

      gate_called_ref = :counters.new(1, [:atomics])

      gate_fun = fn _coord ->
        :counters.add(gate_called_ref, 1, 1)
        :pass
      end

      oracle_worker_id = "w-race-oracle-#{System.unique_integer([:positive])}"
      impl_worker_id = "w-race-impl-#{System.unique_integer([:positive])}"

      # The oracle call returns a 3-tuple so the oracle uses work_ready keying.
      # The implementing call also returns a 3-tuple with a DIFFERENT worker_id.
      call_count = :counters.new(1, [:atomics])

      worker_fun = fn _role ->
        n = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)
        pid = spawn_worker()

        if n == 0 do
          # First call: oracle phase worker.
          {:ok, pid, oracle_worker_id}
        else
          # Subsequent calls: implementing phase worker.
          {:ok, pid, impl_worker_id}
        end
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

      # Advance oracle → implementing.
      advance_past_oracle(unit_pid, oracle_worker_id)
      result = wait_for_implementing(unit_pid)

      assert match?({:implementing, _}, result),
             "D-326 race: Unit must reach :implementing; got #{inspect(result)}"

      {:implementing, impl_data} = result
      worker_pid = Map.get(impl_data, :worker_pid)

      assert is_pid(worker_pid),
             "D-326 race: Unit must expose :worker_pid in implementing state data; got #{inspect(impl_data)}"

      refine_before = Map.get(impl_data, :refine_count, 0)
      attempt_before = Map.get(impl_data, :attempt_count, 0)

      # STEP 1: Deliver a synthetic :DOWN FIRST — simulating the one-hop BEAM
      # monitor winning the race against the two-hop fleet worker_exit signal.
      # The no-self-monitor design requires this to be ignored for 3-tuple workers.
      send(unit_pid, {:DOWN, make_ref(), :process, worker_pid, {:shutdown, :no_work_product}})

      # STEP 2: Deliver the semantic worker_exit SECOND — this is the fleet's
      # authoritative outcome signal for the 3-tuple path.
      send(unit_pid, {:worker_exit, impl_worker_id, :no_work_product})

      # Allow the FSM to process both messages.
      Process.sleep(250)

      {state_after, data_after} = :sys.get_state(unit_pid)

      assert state_after == :implementing,
             "D-326 [C111b-B8] RACE: Unit must ignore the synthetic :DOWN and route " <>
               "{:worker_exit, worker_id, :no_work_product} to the retry ladder, " <>
               "re-entering :implementing. Got state=#{inspect(state_after)}. " <>
               "FAIL-BEFORE: the current impl's :DOWN handler matches worker_pid unconditionally " <>
               "(no worker_id guard), so the one-hop :DOWN fires FIRST and escalates " <>
               "E_WORKER_DOWN before worker_exit is ever processed. " <>
               "FIX REQUIRED: guard the :DOWN handler with `when is_nil(worker_id)` so it " <>
               "only fires for the legacy 2-tuple path."

      refine_after = Map.get(data_after, :refine_count, 0)
      attempt_after = Map.get(data_after, :attempt_count, 0)

      assert refine_after > refine_before or attempt_after > attempt_before,
             "D-326 race: after routing through the retry ladder, refine_count or " <>
               "attempt_count must have incremented; " <>
               "refine #{refine_before}→#{refine_after}, attempt #{attempt_before}→#{attempt_after}"

      gate_calls = :counters.get(gate_called_ref, 1)

      assert gate_calls == 0,
             "D-326 [C111b-B8] race: gate_fun must NOT be called for :no_work_product " <>
               "routed via the retry ladder; called #{gate_calls} times"

      refute_received {:unit_terminal, ^unit_id, _outcome, _prov},
                      "D-326 race: a single :no_work_product exit must route to retry, not terminate"
    end

    @tag :d_326
    test "D-326 race worker_exit-first: worker_exit before :DOWN also routes to retry" do
      test_pid = self()
      unit_id = "u-race-wef-#{System.unique_integer([:positive])}"
      scheduler_name = :"sched_race_wef_#{System.unique_integer([:positive])}"
      sup_name = :"sup_race_wef_#{System.unique_integer([:positive])}"

      start_scheduler(scheduler_name)
      start_supervised!({@unit_supervisor, name: sup_name}, id: sup_name)

      gate_called_ref = :counters.new(1, [:atomics])

      gate_fun = fn _coord ->
        :counters.add(gate_called_ref, 1, 1)
        :pass
      end

      oracle_worker_id = "w-wef-oracle-#{System.unique_integer([:positive])}"
      impl_worker_id = "w-wef-impl-#{System.unique_integer([:positive])}"
      call_count = :counters.new(1, [:atomics])

      worker_fun = fn _role ->
        n = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)
        pid = spawn_worker()

        if n == 0 do
          {:ok, pid, oracle_worker_id}
        else
          {:ok, pid, impl_worker_id}
        end
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

      advance_past_oracle(unit_pid, oracle_worker_id)
      result = wait_for_implementing(unit_pid)

      assert match?({:implementing, _}, result),
             "D-326 race/wef: Unit must reach :implementing; got #{inspect(result)}"

      {:implementing, impl_data} = result
      worker_pid = Map.get(impl_data, :worker_pid)
      refine_before = Map.get(impl_data, :refine_count, 0)
      attempt_before = Map.get(impl_data, :attempt_count, 0)

      # worker_exit FIRST, then the :DOWN that follows in the normal sequence.
      send(unit_pid, {:worker_exit, impl_worker_id, :no_work_product})
      send(unit_pid, {:DOWN, make_ref(), :process, worker_pid, {:shutdown, :no_work_product}})

      Process.sleep(250)

      {state_after, data_after} = :sys.get_state(unit_pid)

      assert state_after == :implementing,
             "D-326 [C111b-B8] race/wef: worker_exit-first must route to retry ladder; " <>
               "got state=#{inspect(state_after)}"

      refine_after = Map.get(data_after, :refine_count, 0)
      attempt_after = Map.get(data_after, :attempt_count, 0)

      assert refine_after > refine_before or attempt_after > attempt_before,
             "D-326 race/wef: ladder must have progressed; " <>
               "refine #{refine_before}→#{refine_after}, attempt #{attempt_before}→#{attempt_after}"

      gate_calls = :counters.get(gate_called_ref, 1)

      assert gate_calls == 0,
             "D-326 race/wef: gate_fun must NOT be called; called #{gate_calls} times"

      refute_received {:unit_terminal, ^unit_id, _outcome, _prov},
                      "D-326 race/wef: retry must not terminate the Unit"
    end
  end

  # ---------------------------------------------------------------------------
  # Semantic worker_exit → retry ladder (3-tuple path)
  # ---------------------------------------------------------------------------

  describe "D-326 [C111b-B8] — worker_exit :no_work_product routes to retry ladder" do
    @tag :d_326
    test "D-326: {:worker_exit, worker_id, :no_work_product} routes to retry ladder — NOT :gating, NOT :escalated" do
      test_pid = self()
      unit_id = "u-noprod-retry-#{System.unique_integer([:positive])}"
      scheduler_name = :"sched_noprod_#{System.unique_integer([:positive])}"
      sup_name = :"sup_noprod_#{System.unique_integer([:positive])}"

      start_scheduler(scheduler_name)
      start_supervised!({@unit_supervisor, name: sup_name}, id: sup_name)

      gate_called_ref = :counters.new(1, [:atomics])

      gate_fun = fn _coord ->
        :counters.add(gate_called_ref, 1, 1)
        :pass
      end

      oracle_worker_id = "w-noprod-oracle-#{System.unique_integer([:positive])}"
      impl_worker_id = "w-noprod-impl-#{System.unique_integer([:positive])}"
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
          gate_fun: gate_fun,
          merge_fun: fn _uid, _hash -> :queued end,
          timeouts: [state_timeout_ms: 5_000]
        )

      unit_pid = @unit_supervisor.start_unit(sup_name, opts)
      assert is_pid(unit_pid), "start_unit must return a pid"

      advance_past_oracle(unit_pid, oracle_worker_id)
      result = wait_for_implementing(unit_pid)

      assert match?({:implementing, _}, result),
             "D-326: Unit must reach :implementing; got #{inspect(result)}"

      {:implementing, data_before} = result
      attempt_before = Map.get(data_before, :attempt_count, 0)
      refine_before = Map.get(data_before, :refine_count, 0)

      send(unit_pid, {:worker_exit, impl_worker_id, :no_work_product})

      Process.sleep(200)

      {state_after, data_after} = :sys.get_state(unit_pid)

      assert state_after == :implementing,
             "D-326 [C111b-B8]: {:worker_exit, id, :no_work_product} must route to the retry " <>
               "ladder and re-enter :implementing; got state=#{inspect(state_after)}"

      refine_after = Map.get(data_after, :refine_count, 0)
      attempt_after = Map.get(data_after, :attempt_count, 0)

      assert refine_after > refine_before or attempt_after > attempt_before,
             "D-326: after routing through the retry ladder, refine_count or attempt_count " <>
               "must have incremented; refine #{refine_before}→#{refine_after}, " <>
               "attempt #{attempt_before}→#{attempt_after}"

      gate_calls = :counters.get(gate_called_ref, 1)

      assert gate_calls == 0,
             "D-326 [C111b-B8]: gate_fun must NOT be called for a semantic :no_work_product " <>
               "exit (retry ladder, never gated); called #{gate_calls} times"

      refute_received {:unit_terminal, ^unit_id, _outcome, _prov},
                      "D-326: a single :no_work_product exit must route to retry, not terminate"
    end
  end

  # ---------------------------------------------------------------------------
  # Semantic worker_exit :error and {:exit_status, n} → retry ladder
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

      oracle_worker_id = "w-err-oracle-#{System.unique_integer([:positive])}"
      impl_worker_id = "w-err-impl-#{System.unique_integer([:positive])}"
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
          gate_fun: gate_fun,
          merge_fun: fn _uid, _hash -> :queued end,
          timeouts: [state_timeout_ms: 5_000]
        )

      unit_pid = @unit_supervisor.start_unit(sup_name, opts)
      assert is_pid(unit_pid), "start_unit must return a pid"

      advance_past_oracle(unit_pid, oracle_worker_id)
      result = wait_for_implementing(unit_pid)

      assert match?({:implementing, _}, result),
             "D-326: Unit must reach :implementing; got #{inspect(result)}"

      {:implementing, data_before} = result
      refine_before = Map.get(data_before, :refine_count, 0)
      attempt_before = Map.get(data_before, :attempt_count, 0)

      send(unit_pid, {:worker_exit, impl_worker_id, :error})

      Process.sleep(200)

      {state_after, data_after} = :sys.get_state(unit_pid)

      assert state_after == :implementing,
             "D-326 [C105-B5]: {:worker_exit, id, :error} must route to the retry ladder and " <>
               "re-enter :implementing; got state=#{inspect(state_after)}"

      refine_after = Map.get(data_after, :refine_count, 0)
      attempt_after = Map.get(data_after, :attempt_count, 0)

      assert refine_after > refine_before or attempt_after > attempt_before,
             "D-326: ladder must have progressed; refine #{refine_before}→#{refine_after}, " <>
               "attempt #{attempt_before}→#{attempt_after}"

      gate_calls = :counters.get(gate_called_ref, 1)

      assert gate_calls == 0,
             "D-326 [C105-B5]: gate_fun must NOT be called on a semantic :error exit; " <>
               "called #{gate_calls} times"

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

      oracle_worker_id = "w-exst-oracle-#{System.unique_integer([:positive])}"
      impl_worker_id = "w-exst-impl-#{System.unique_integer([:positive])}"
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
          gate_fun: gate_fun,
          merge_fun: fn _uid, _hash -> :queued end,
          timeouts: [state_timeout_ms: 5_000]
        )

      unit_pid = @unit_supervisor.start_unit(sup_name, opts)
      assert is_pid(unit_pid), "start_unit must return a pid"

      advance_past_oracle(unit_pid, oracle_worker_id)
      result = wait_for_implementing(unit_pid)

      assert match?({:implementing, _}, result),
             "D-326: Unit must reach :implementing; got #{inspect(result)}"

      {:implementing, data_before} = result
      refine_before = Map.get(data_before, :refine_count, 0)
      attempt_before = Map.get(data_before, :attempt_count, 0)

      send(unit_pid, {:worker_exit, impl_worker_id, {:exit_status, 1}})

      Process.sleep(200)

      {state_after, data_after} = :sys.get_state(unit_pid)

      assert state_after == :implementing,
             "D-326 [C105-B5]: {:worker_exit, id, {:exit_status,1}} must route to the retry " <>
               "ladder and re-enter :implementing; got state=#{inspect(state_after)}"

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
  # D-326 / D-318: repeated semantic exits exhaust ladder → E_RETRY_EXHAUSTED
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
      total_exits = n_refine + n_pivot + 1

      gate_called_ref = :counters.new(1, [:atomics])

      gate_fun = fn _coord ->
        :counters.add(gate_called_ref, 1, 1)
        :pass
      end

      # Each implementing cycle gets a fresh 3-tuple worker_id.
      call_count_ref = :counters.new(1, [:atomics])

      worker_fun = fn _role ->
        idx = :counters.get(call_count_ref, 1)
        :counters.add(call_count_ref, 1, 1)
        pid = spawn_worker()
        {:ok, pid, "w-exhaust-#{unit_id}-#{idx}"}
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

      # Advance oracle: poll for :oracle state, get oracle worker_id from data,
      # deliver work_ready.
      oracle_worker_id =
        Enum.reduce_while(1..100, nil, fn _, _ ->
          Process.sleep(20)

          case :sys.get_state(unit_pid) do
            {:oracle, data} -> {:halt, Map.get(data, :worker_id)}
            _ -> {:cont, nil}
          end
        end)

      assert is_binary(oracle_worker_id),
             "D-326/D-318: oracle must expose :worker_id in state data; got #{inspect(oracle_worker_id)}"

      send(unit_pid, {:work_ready, oracle_worker_id, "feat/oracle", "aabb0011"})

      # Drive total_exits semantic worker_exit cycles.
      for _i <- 1..total_exits do
        result = wait_for_implementing(unit_pid, 3_000)

        case result do
          {:implementing, data} ->
            wid = Map.get(data, :worker_id)
            send(unit_pid, {:worker_exit, wid, :no_work_product})
            Process.sleep(150)

          {:escalated, _} ->
            :ok

          {state, _} ->
            flunk("D-326/D-318: unexpected state #{inspect(state)} mid-exhaustion loop")
        end
      end

      assert_receive {:unit_terminal, ^unit_id, :escalated, provenance},
                     10_000,
                     "D-326/D-318: after #{total_exits} semantic worker_exits " <>
                       "(#{n_refine} refines + #{n_pivot} pivot exhausted), " <>
                       "the Unit must reach :escalated"

      reason = Map.get(provenance, :reason)

      assert reason == :E_RETRY_EXHAUSTED,
             "D-318: exhausted escalation must carry :E_RETRY_EXHAUSTED; got #{inspect(reason)}"

      gate_calls = :counters.get(gate_called_ref, 1)

      assert gate_calls == 0,
             "D-326 [C111b-B8]: gate_fun must NEVER be called for semantic worker_exit " <>
               "exhaustion; called #{gate_calls} times"

      in_flight = @scheduler.in_flight(scheduler_name)

      refute Map.has_key?(in_flight, unit_id),
             "D-326/D-318: after :escalated, unit must be released from Scheduler in_flight"
    end
  end

  # ---------------------------------------------------------------------------
  # Legacy 2-tuple seam: :DOWN on worker_id == nil → E_WORKER_DOWN (preserved)
  # ---------------------------------------------------------------------------

  describe "D-326 [B8/C105] — 2-tuple legacy seam: genuine infra :DOWN (worker_id nil) escalates E_WORKER_DOWN" do
    @tag :d_326
    @tag :b8
    @tag :c105
    test "D-326/B8/C105 [2-tuple seam]: Process.exit(:kill) on 2-tuple worker (worker_id nil) escalates :E_WORKER_DOWN — legacy path preserved" do
      test_pid = self()
      unit_id = "u-2tuple-down-#{System.unique_integer([:positive])}"
      scheduler_name = :"sched_2tuple_#{System.unique_integer([:positive])}"
      sup_name = :"sup_2tuple_#{System.unique_integer([:positive])}"

      start_scheduler(scheduler_name)
      start_supervised!({@unit_supervisor, name: sup_name}, id: sup_name)

      gate_called_ref = :counters.new(1, [:atomics])

      gate_fun = fn _coord ->
        :counters.add(gate_called_ref, 1, 1)
        :pass
      end

      # 2-tuple seam: worker_fun returns {:ok, pid} with NO worker_id.
      # Unit stores worker_id = nil and uses :worker_done / :DOWN for completion.
      worker_pids_ref = :counters.new(1, [:atomics])
      ets = :ets.new(:wpid_2tuple, [:set, :public])

      worker_fun = fn role ->
        idx = :counters.get(worker_pids_ref, 1)
        :counters.add(worker_pids_ref, 1, 1)
        pid = spawn_worker()
        :ets.insert(ets, {idx, role, pid})
        # 2-tuple: no worker_id — legacy seam.
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

      # Advance oracle via :worker_done (2-tuple oracle path).
      # Poll until we are in :oracle state and get the worker_pid from data.
      oracle_pid =
        Enum.reduce_while(1..100, nil, fn _, _ ->
          Process.sleep(20)

          case :sys.get_state(unit_pid) do
            {:oracle, data} -> {:halt, Map.get(data, :worker_pid)}
            _ -> {:cont, nil}
          end
        end)

      assert is_pid(oracle_pid),
             "D-326/2-tuple: oracle must expose :worker_pid in state data"

      send(unit_pid, {:worker_done, oracle_pid})

      # Wait until :implementing.
      impl_result = wait_for_implementing(unit_pid, 2_000)

      assert match?({:implementing, _}, impl_result),
             "D-326/2-tuple: Unit must reach :implementing; got #{inspect(impl_result)}"

      {:implementing, impl_data} = impl_result
      implementing_pid = Map.get(impl_data, :worker_pid)

      assert is_nil(Map.get(impl_data, :worker_id)),
             "D-326/2-tuple: 2-tuple seam must have worker_id = nil in state data"

      assert is_pid(implementing_pid),
             "B8: Unit must expose :worker_pid in state data; got #{inspect(impl_data)}"

      # Kill the 2-tuple worker — pure infra crash, no prior semantic exit.
      # For the 2-tuple seam (worker_id nil) this must STILL escalate E_WORKER_DOWN.
      Process.exit(implementing_pid, :kill)

      assert_receive {:unit_terminal, ^unit_id, :escalated, provenance},
                     5_000,
                     "D-326/B8/C105 [2-tuple]: a pure infra :DOWN (kill) on a 2-tuple worker " <>
                       "(worker_id nil) must escalate E_WORKER_DOWN; not received within 5s"

      reason = Map.get(provenance, :reason)

      assert reason == :E_WORKER_DOWN,
             "B8/C105 [2-tuple]: infra :DOWN must escalate :E_WORKER_DOWN, not #{inspect(reason)}"

      gate_calls = :counters.get(gate_called_ref, 1)

      assert gate_calls == 0,
             "C105: gate_fun must NOT be called for a pure infra :DOWN; called #{gate_calls} times"

      :ets.delete(ets)
    end
  end

  # ---------------------------------------------------------------------------
  # 3-tuple vanish without worker_exit → E_WORKER_STALLED (NOT E_WORKER_DOWN)
  #
  # For the 3-tuple path, a worker that vanishes without sending worker_exit
  # MUST surface via the stall detection path (E_WORKER_STALLED), never via
  # E_WORKER_DOWN.
  #
  # Fail-before: the current :DOWN handler in implementing/3 does NOT check
  # worker_id; it fires for 3-tuple workers too, escalating E_WORKER_DOWN.
  # Pass-after: the :DOWN handler is guarded with `when is_nil(worker_id)` so
  # it only fires for the 2-tuple legacy path. 3-tuple vanish is detected by
  # the state_timeout watchdog → E_WORKER_STALLED.
  # ---------------------------------------------------------------------------

  describe "D-326 [B8] — 3-tuple vanish without worker_exit → E_WORKER_STALLED, never E_WORKER_DOWN" do
    @tag :d_326
    @tag :b8
    test "D-326/B8: 3-tuple worker process killed without worker_exit escalates :E_WORKER_STALLED, NOT :E_WORKER_DOWN" do
      test_pid = self()
      unit_id = "u-3tuple-vanish-#{System.unique_integer([:positive])}"
      scheduler_name = :"sched_3tv_#{System.unique_integer([:positive])}"
      sup_name = :"sup_3tv_#{System.unique_integer([:positive])}"

      start_scheduler(scheduler_name)
      start_supervised!({@unit_supervisor, name: sup_name}, id: sup_name)

      gate_called_ref = :counters.new(1, [:atomics])

      gate_fun = fn _coord ->
        :counters.add(gate_called_ref, 1, 1)
        :pass
      end

      oracle_worker_id = "w-3tv-oracle-#{System.unique_integer([:positive])}"
      impl_worker_id = "w-3tv-impl-#{System.unique_integer([:positive])}"
      call_count = :counters.new(1, [:atomics])

      worker_fun = fn _role ->
        n = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)
        pid = spawn_worker()
        if n == 0, do: {:ok, pid, oracle_worker_id}, else: {:ok, pid, impl_worker_id}
      end

      # Use a very short state_timeout so the stall watchdog fires quickly.
      opts =
        base_unit_opts(unit_id, scheduler_name, test_pid,
          worker_fun: worker_fun,
          gate_fun: gate_fun,
          merge_fun: fn _uid, _hash -> :queued end,
          timeouts: [state_timeout_ms: 200]
        )

      unit_pid = @unit_supervisor.start_unit(sup_name, opts)
      assert is_pid(unit_pid), "start_unit must return a pid"

      advance_past_oracle(unit_pid, oracle_worker_id)
      result = wait_for_implementing(unit_pid)

      assert match?({:implementing, _}, result),
             "D-326/3-tuple vanish: Unit must reach :implementing; got #{inspect(result)}"

      {:implementing, impl_data} = result
      worker_pid = Map.get(impl_data, :worker_pid)

      assert is_pid(worker_pid),
             "B8: Unit must expose :worker_pid in implementing state data"

      assert impl_worker_id == Map.get(impl_data, :worker_id),
             "D-326/3-tuple: worker_id must be set in state data for 3-tuple worker"

      # Kill the 3-tuple worker WITHOUT sending worker_exit.
      # In the no-self-monitor design the Unit must NOT see E_WORKER_DOWN —
      # the only detection path for vanish-without-exit is the stall watchdog
      # (state_timeout → E_WORKER_STALLED).
      Process.exit(worker_pid, :kill)

      # Wait for the terminal report — must be E_WORKER_STALLED, not E_WORKER_DOWN.
      assert_receive {:unit_terminal, ^unit_id, :escalated, provenance},
                     3_000,
                     "D-326 [B8]: 3-tuple worker killed without worker_exit must escalate " <>
                       "(via stall watchdog or :DOWN-converted-to-stall); not received within 3s. " <>
                       "FAIL-BEFORE: current impl's :DOWN handler fires unconditionally and " <>
                       "escalates E_WORKER_DOWN instead of E_WORKER_STALLED."

      reason = Map.get(provenance, :reason)

      assert reason == :E_WORKER_STALLED,
             "D-326 [B8]: 3-tuple vanish-without-exit must escalate :E_WORKER_STALLED, " <>
               "not #{inspect(reason)}. " <>
               "FAIL-BEFORE: current impl escalates :E_WORKER_DOWN because the :DOWN handler " <>
               "does not check worker_id."

      gate_calls = :counters.get(gate_called_ref, 1)

      assert gate_calls == 0,
             "D-326: gate_fun must NOT be called for a vanished 3-tuple worker; " <>
               "called #{gate_calls} times"
    end
  end

  # ---------------------------------------------------------------------------
  # Stale worker_exit (other worker_id) → discarded
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

      oracle_worker_id = "w-stale-oracle-#{System.unique_integer([:positive])}"
      current_worker_id = "w-stale-current-#{System.unique_integer([:positive])}"
      call_count = :counters.new(1, [:atomics])

      worker_fun = fn _role ->
        n = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)
        pid = spawn_worker()
        if n == 0, do: {:ok, pid, oracle_worker_id}, else: {:ok, pid, current_worker_id}
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

      advance_past_oracle(unit_pid, oracle_worker_id)
      result = wait_for_implementing(unit_pid)

      assert match?({:implementing, _}, result),
             "D-326: Unit must reach :implementing; got #{inspect(result)}"

      {:implementing, data_before} = result
      refine_before = Map.get(data_before, :refine_count, 0)
      attempt_before = Map.get(data_before, :attempt_count, 0)

      stale_worker_id = "w-stale-#{System.unique_integer([:positive])}"
      send(unit_pid, {:worker_exit, stale_worker_id, :no_work_product})

      Process.sleep(200)

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
