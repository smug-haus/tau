defmodule Tau.Factory.UnitHeartbeatLivenessTest do
  @moduledoc """
  Gating tests for PR #513 (issue #491 — GOV4 unified oracle/implementing
  worker-outcome FSM, D-377/D-378/D-379 + D-315 durability).

  ## Invariants under test

  - **D-377** — the Unit re-arms its `:state_timeout` on every current-worker
    `{:worker_heartbeat, worker_id}` pulse **in both `oracle` and `implementing`**.
    A progressing worker never trips the fixed cap; absence of heartbeats
    escalates `E_WORKER_STALLED` at the deadline.

  - **D-378** — **ONE symmetric rule for BOTH waiting states.** `oracle` and
    `implementing` handle the worker-outcome signal set identically:
    - `{:worker_stalled, ^worker_id}` → retry ladder → **originating state**
      (oracle→oracle, implementing→implementing).
    - `{:worker_exit, ^worker_id, reason}` → retry ladder → **originating state**.
    - First stall-class signal clears `data.worker_id`; later signals for the
      same worker hit the stale-discard clause → EXACTLY ONE ladder advance per
      worker per state.
    The `advance_retry_ladder/2` function takes the originating state so
    re-spawn re-enters the correct role.
    **LIV-1 (D-378 boundedness):** repeated stall/exit cycles exhaust the bounded
    retry ladder (refine → pivot → exhausted) and the Unit escalates
    `E_RETRY_EXHAUSTED` — it does NOT re-spawn forever. The implementing path must
    use the SAME bounded ladder as the oracle path (no separate gate-ladder or
    unbounded deferred-spawn loop).

  - **D-379** — (a) `oracle` AND `implementing` both consume `{:worker_stalled,
    ^worker_id}` AND `{:worker_exit, ^worker_id, _}` → retry ladder; stale-worker
    variants are discarded. (b) `UnitDriver.drive/2` registers each spawned worker
    with the fleet `Watchdog` (via a `:watchdog` dep), delivering
    `{:worker_stalled, _}` to the owning Unit.
    **Run-#2 regression**: `oracle` previously had NO `{:worker_exit, _, _}` clause —
    an oracle worker exiting with `:no_work_product` would be silently discarded
    rather than routed to the retry ladder.

  - **D-315** — RPO=0 durability for stall re-spawn: the ladder's `:on_enter`
    bumps `attempt_count` **and** calls `snapshot_state/2` (writing a Ledger row)
    **before** spawning the next worker — in BOTH `oracle` and `implementing`.
    There is **no separate `:deferred_spawn` / `do_spawn_worker` path**; the
    ladder transition is the re-spawn.

  ## Fail-before validity (oracle-separation, factory-loop §4b)

  These tests fail against the current branch (6beddd1) because:
  - `implementing`'s `advance_retry_ladder/2` sends `:stall_respawn` (deferred
    path via `do_spawn_worker`) which never calls `Retry.next/3` and therefore
    never exhausts the bounded ladder → the LIV-1 boundedness test fails (no
    `:E_RETRY_EXHAUSTED` is ever sent).
  - The deferred path's `do_spawn_worker` uses `:keep_state` (not `:next_state`)
    → the `implementing` path uses a fundamentally different mechanism from the
    `oracle` path → the symmetric-worker_exit test fails (implementing worker_exit
    does not re-enter `:implementing` via the same `:next_state` ladder transition).
  - Fresh-id tests fail because the deferred path relies on same-worker_id reuse
    to drain stale signals from the mailbox; with fresh ids the deferred path's
    stale-discard assumption breaks.

  ## AC / D-NNN linkage (Gate 5.1)

  Every test name and @tag carries D-315, D-377, D-378, or D-379.
  """

  # async: false — exercises timing-sensitive OTP :state_timeout behaviour.
  # Under full-suite concurrency the BEAM scheduler can starve a heartbeat
  # sender, causing false :state_timeout trips. Serialising the module
  # eliminates scheduler starvation as a confound; individual tests still
  # start uniquely-named supervisors so there is no inter-test collision.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Tau.Factory.Fleet.Watchdog
  alias Tau.Factory.Ledger.Reader, as: LedgerReader
  alias Tau.Factory.Ledger.Writer, as: LedgerWriter
  alias Tau.Factory.Retry
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

  # Start a REAL Ledger.Writer against an isolated temp DB; return its name.
  # Mirrors the pattern in unit_snapshot_durability_test.exs.
  defp start_ledger do
    db_path = Briefly.create!(extname: ".db")
    writer_name = :"snap_ledger_hb_#{System.unique_integer([:positive])}"

    start_supervised!(
      {LedgerWriter, db_path: db_path, name: writer_name},
      id: writer_name
    )

    writer_name
  end

  # Base opts threaded through each test. `overrides` replaces defaults.
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

  # Poll until the Unit is in :oracle; return {:oracle, data} or
  # {:timeout, last_state} on deadline.
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
  # D-377 — heartbeat resets :state_timeout in BOTH waiting states
  # ---------------------------------------------------------------------------

  describe "D-377 — heartbeat resets :state_timeout; progressing worker never escalates" do
    @tag :d_377
    test "D-377: {worker_heartbeat, current_worker_id} at sub-timeout intervals keeps Unit in :implementing past old fixed cap" do
      test_pid = self()
      unit_id = "u-hb-reset-#{System.unique_integer([:positive])}"
      scheduler_name = :"sched_hb_reset_#{System.unique_integer([:positive])}"
      sup_name = :"sup_hb_reset_#{System.unique_integer([:positive])}"

      start_scheduler(scheduler_name)
      start_supervised!({@unit_supervisor, name: sup_name}, id: sup_name)

      # 1000ms gives the BEAM scheduler ample room under full suite load.
      state_timeout_ms = 1_000

      oracle_worker_id = "w-hb-oracle-#{System.unique_integer([:positive])}"
      call_count = :counters.new(1, [:atomics])

      worker_fun = fn _role ->
        n = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)
        pid = spawn_worker()

        if n == 0,
          do: {:ok, pid, oracle_worker_id},
          else: {:ok, pid, "impl-worker-#{n}-#{System.unique_integer([:positive])}"}
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

      {:implementing, data_impl} = result
      impl_worker_id = data_impl.worker_id

      # Drive heartbeats from the TEST PROCESS at 200ms intervals (well below the
      # 1000ms state_timeout_ms) for 3× the deadline (3000ms total).
      # Without D-377: the state_timeout fires at 1000ms → escalate.
      # With D-377: each pulse re-arms the timer → Unit stays in :implementing.
      hb_interval_ms = 200
      total_hb_duration_ms = 3 * state_timeout_ms

      hb_loop_from_test(unit_pid, impl_worker_id, hb_interval_ms, total_hb_duration_ms)

      {state_after, _data} = :sys.get_state(unit_pid)

      assert state_after == :implementing,
             "D-377: Unit fed {:worker_heartbeat, current_id} at #{hb_interval_ms}ms " <>
               "intervals (well below #{state_timeout_ms}ms state_timeout) MUST stay " <>
               "in :implementing past the old fixed cap (#{total_hb_duration_ms}ms total). " <>
               "Got state=#{inspect(state_after)}. " <>
               "FAIL-BEFORE: no {:worker_heartbeat, _} clause in oracle/3 or implementing/3."
    end

    @tag :d_377
    test "D-377: {worker_heartbeat, current_worker_id} at sub-timeout intervals keeps Unit in :oracle past old fixed cap" do
      test_pid = self()
      unit_id = "u-hb-oracle-reset-#{System.unique_integer([:positive])}"
      scheduler_name = :"sched_hb_oracle_reset_#{System.unique_integer([:positive])}"
      sup_name = :"sup_hb_oracle_reset_#{System.unique_integer([:positive])}"

      start_scheduler(scheduler_name)
      start_supervised!({@unit_supervisor, name: sup_name}, id: sup_name)

      state_timeout_ms = 1_000

      oracle_worker_id = "w-hb-oracle2-#{System.unique_integer([:positive])}"
      call_count = :counters.new(1, [:atomics])

      worker_fun = fn _role ->
        n = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)
        pid = spawn_worker()
        if n == 0, do: {:ok, pid, oracle_worker_id}, else: {:ok, pid, "re-spawned"}
      end

      opts =
        base_unit_opts(unit_id, scheduler_name, test_pid,
          worker_fun: worker_fun,
          timeouts: [state_timeout_ms: state_timeout_ms]
        )

      unit_pid = @unit_supervisor.start_unit(sup_name, opts)
      assert is_pid(unit_pid)

      # Wait in :oracle state — do NOT advance past oracle.
      result = wait_for_oracle(unit_pid)

      assert match?({:oracle, _}, result),
             "D-377 oracle: Unit must reach :oracle; got #{inspect(result)}"

      hb_interval_ms = 200
      total_hb_duration_ms = 3 * state_timeout_ms

      hb_loop_from_test(unit_pid, oracle_worker_id, hb_interval_ms, total_hb_duration_ms)

      {state_after, _data} = :sys.get_state(unit_pid)

      assert state_after == :oracle,
             "D-377: Unit fed {:worker_heartbeat, current_id} in :oracle at #{hb_interval_ms}ms " <>
               "intervals MUST stay in :oracle past the old fixed cap " <>
               "(#{total_hb_duration_ms}ms total). " <>
               "Got state=#{inspect(state_after)}. " <>
               "FAIL-BEFORE: no {:worker_heartbeat, _} clause in oracle/3."
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
      call_count = :counters.new(1, [:atomics])

      worker_fun = fn _role ->
        n = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)
        pid = spawn_worker()

        if n == 0,
          do: {:ok, pid, oracle_worker_id},
          else: {:ok, pid, "nostall-impl-#{n}-#{System.unique_integer([:positive])}"}
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

      # No heartbeats — state_timeout must fire at deadline.
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
  # D-378 — ONE symmetric rule: both :oracle and :implementing advance ladder
  # EXACTLY ONCE for a burst of stall signals
  # ---------------------------------------------------------------------------
  #
  # The UNIFIED contract: oracle and implementing handle worker_stalled and
  # worker_exit identically — advance_retry_ladder/2 takes the originating
  # state and re-enters IT, not hardcoded :implementing.
  #
  # D-378 disjointness: the first stall-class signal consumed clears
  # data.worker_id → later signals for the SAME worker hit the stale-worker
  # discard clause → EXACTLY ONE ladder advance per worker per state.
  # ---------------------------------------------------------------------------

  describe "D-378 — exactly one retry-ladder advance for close-succession stall signals in :implementing" do
    @tag :d_378
    test "D-378 implementing: burst stall signals for same worker advance ladder EXACTLY ONCE re-entering :implementing" do
      test_pid = self()
      unit_id = "u-d378-impl-once-#{System.unique_integer([:positive])}"
      scheduler_name = :"sched_d378_impl_#{System.unique_integer([:positive])}"
      sup_name = :"sup_d378_impl_#{System.unique_integer([:positive])}"

      start_scheduler(scheduler_name)
      start_supervised!({@unit_supervisor, name: sup_name}, id: sup_name)

      oracle_worker_id = "w-d378-impl-oracle-#{System.unique_integer([:positive])}"
      call_count = :counters.new(1, [:atomics])

      # D-326: each re-spawn returns a FRESH unique worker_id.
      # The deferred-spawn path relied on reusing the same id to drain stale
      # messages; the plain bounded ladder uses id-keyed discrimination instead.
      worker_fun = fn _role ->
        n = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)
        pid = spawn_worker()

        if n == 0,
          do: {:ok, pid, oracle_worker_id},
          else: {:ok, pid, "impl-worker-#{n}-#{System.unique_integer([:positive])}"}
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
             "D-378 implementing: Unit must reach :implementing; got #{inspect(result)}"

      {:implementing, data_before} = result
      refine_before = Map.get(data_before, :refine_count, 0)
      attempt_before = Map.get(data_before, :attempt_count, 0)
      # Read the CURRENT worker_id from state (fresh id, not a hardcoded string).
      current_impl_worker_id = data_before.worker_id

      # Burst of three stall signals for the SAME implementing worker.
      # D-378: first clears worker_id; second + third are stale-discarded.
      # Result: exactly ONE ladder advance, Unit re-enters :implementing
      # (the originating state, per the unified symmetric rule).
      # With fresh ids (D-326), the re-spawned worker gets a new id so the
      # stale signals for current_impl_worker_id are discarded by the
      # _other_id clause — exactly-once via id discrimination, not mailbox drain.
      send(unit_pid, {:worker_stalled, current_impl_worker_id})
      send(unit_pid, {:worker_exit, current_impl_worker_id, :no_work_product})
      send(unit_pid, {:worker_stalled, current_impl_worker_id})

      # Allow all three messages to be processed plus the on_enter to run.
      Process.sleep(400)

      {state_after, data_after} = :sys.get_state(unit_pid)

      refine_after = Map.get(data_after, :refine_count, 0)
      attempt_after = Map.get(data_after, :attempt_count, 0)

      total_advance_before = refine_before + attempt_before
      total_advance_after = refine_after + attempt_after

      assert state_after == :implementing,
             "D-378 implementing: after exactly one ladder advance Unit must be in " <>
               ":implementing (originating state); got #{inspect(state_after)}. " <>
               "FAIL-BEFORE: advance_retry_ladder/1 hardcodes :implementing so this " <>
               "may accidentally pass — but advance_retry_ladder/2 (originating state) " <>
               "must re-enter :implementing for the implementing case."

      assert total_advance_after - total_advance_before == 1,
             "D-378 implementing: three stall signals for one worker must advance " <>
               "ladder EXACTLY once. Advanced by " <>
               "#{total_advance_after - total_advance_before} (expected 1). " <>
               "refine #{refine_before}->#{refine_after}, " <>
               "attempt #{attempt_before}->#{attempt_after}. " <>
               "FAIL-BEFORE: deferred-spawn path or double-fire."
    end
  end

  describe "D-378 — exactly one retry-ladder advance for close-succession stall signals in :oracle" do
    @tag :d_378
    test "D-378 oracle: burst stall signals for same oracle worker advance ladder EXACTLY ONCE and re-enter :oracle (NOT :implementing)" do
      test_pid = self()
      unit_id = "u-d378-oracle-once-#{System.unique_integer([:positive])}"
      scheduler_name = :"sched_d378_oracle_#{System.unique_integer([:positive])}"
      sup_name = :"sup_d378_oracle_#{System.unique_integer([:positive])}"

      start_scheduler(scheduler_name)
      start_supervised!({@unit_supervisor, name: sup_name}, id: sup_name)

      oracle_worker_id = "w-d378-oracle-#{System.unique_integer([:positive])}"
      # Track all worker_fun invocations; the re-spawned oracle gets a new id
      # so we know the ladder fired.
      respawn_worker_id = "w-d378-oracle-respawn-#{System.unique_integer([:positive])}"
      call_count = :counters.new(1, [:atomics])

      worker_fun = fn _role ->
        n = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)
        pid = spawn_worker()

        case n do
          0 -> {:ok, pid, oracle_worker_id}
          _ -> {:ok, pid, respawn_worker_id}
        end
      end

      opts =
        base_unit_opts(unit_id, scheduler_name, test_pid,
          worker_fun: worker_fun,
          timeouts: [state_timeout_ms: 10_000]
        )

      unit_pid = @unit_supervisor.start_unit(sup_name, opts)
      assert is_pid(unit_pid)

      # Wait in :oracle — do NOT send work_ready.
      result = wait_for_oracle(unit_pid)

      assert match?({:oracle, _}, result),
             "D-378 oracle: Unit must reach :oracle; got #{inspect(result)}"

      {:oracle, data_before} = result
      refine_before = Map.get(data_before, :refine_count, 0)
      attempt_before = Map.get(data_before, :attempt_count, 0)

      # Burst of three stall signals for the SAME oracle worker.
      # D-378 unified symmetric rule: first clears worker_id → re-enters :oracle;
      # second + third are stale-discarded → exactly ONE ladder advance total.
      send(unit_pid, {:worker_stalled, oracle_worker_id})
      send(unit_pid, {:worker_exit, oracle_worker_id, :no_work_product})
      send(unit_pid, {:worker_stalled, oracle_worker_id})

      # Allow all three messages to process plus the oracle :on_enter.
      Process.sleep(400)

      {state_after, data_after} = :sys.get_state(unit_pid)

      refine_after = Map.get(data_after, :refine_count, 0)
      attempt_after = Map.get(data_after, :attempt_count, 0)

      total_advance_before = refine_before + attempt_before
      total_advance_after = refine_after + attempt_after

      assert state_after == :oracle,
             "D-378 oracle: after exactly one ladder advance Unit must be in " <>
               ":oracle (the ORIGINATING state, not :implementing). " <>
               "Got #{inspect(state_after)}. " <>
               "FAIL-BEFORE: advance_retry_ladder/1 hardcodes :implementing — " <>
               "the oracle stall re-enters :implementing, skipping oracle-separation."

      assert total_advance_after - total_advance_before == 1,
             "D-378 oracle: three stall signals for one oracle worker must advance " <>
               "ladder EXACTLY once. Advanced by " <>
               "#{total_advance_after - total_advance_before} (expected 1). " <>
               "refine #{refine_before}->#{refine_after}, " <>
               "attempt #{attempt_before}->#{attempt_after}."
    end
  end

  # ---------------------------------------------------------------------------
  # D-379(a) — Unit consumes {worker_stalled, ^worker_id} AND
  # {worker_exit, ^worker_id, _} in BOTH :oracle and :implementing;
  # stale variants are discarded in both states.
  # ---------------------------------------------------------------------------

  describe "D-379(a) implementing — stalled/exit route to retry ladder; stale discarded" do
    @tag :d_379
    test "D-379 implementing: {:worker_stalled, current_worker_id} advances retry ladder and re-enters :implementing" do
      test_pid = self()
      unit_id = "u-d379a-impl-stalled-#{System.unique_integer([:positive])}"
      scheduler_name = :"sched_d379a_impl_#{System.unique_integer([:positive])}"
      sup_name = :"sup_d379a_impl_#{System.unique_integer([:positive])}"

      start_scheduler(scheduler_name)
      start_supervised!({@unit_supervisor, name: sup_name}, id: sup_name)

      oracle_worker_id = "w-d379a-impl-oracle-#{System.unique_integer([:positive])}"
      call_count = :counters.new(1, [:atomics])

      worker_fun = fn _role ->
        n = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)
        pid = spawn_worker()

        if n == 0,
          do: {:ok, pid, oracle_worker_id},
          else: {:ok, pid, "d379a-impl-#{n}-#{System.unique_integer([:positive])}"}
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
             "D-379 implementing: Unit must reach :implementing; got #{inspect(result)}"

      {:implementing, data_before} = result
      refine_before = Map.get(data_before, :refine_count, 0)
      attempt_before = Map.get(data_before, :attempt_count, 0)
      current_impl_worker_id = data_before.worker_id

      send(unit_pid, {:worker_stalled, current_impl_worker_id})
      Process.sleep(250)

      {state_after, data_after} = :sys.get_state(unit_pid)

      assert state_after == :implementing,
             "D-379 implementing: {:worker_stalled, current_worker_id} must advance " <>
               "the retry ladder and re-enter :implementing; got #{inspect(state_after)}. " <>
               "FAIL-BEFORE: deferred_spawn path still in place; the message is processed " <>
               "via do_spawn_worker (keep_state, not next_state :implementing via ladder)."

      refine_after = Map.get(data_after, :refine_count, 0)
      attempt_after = Map.get(data_after, :attempt_count, 0)

      assert refine_after > refine_before or attempt_after > attempt_before,
             "D-379 implementing: {:worker_stalled, current_id} must advance the ladder; " <>
               "refine #{refine_before}→#{refine_after}, " <>
               "attempt #{attempt_before}→#{attempt_after}"

      refute_received {:unit_terminal, ^unit_id, _outcome, _prov},
                      "D-379 implementing: a single {:worker_stalled, current_id} must " <>
                        "route to retry, not terminate the Unit"
    end

    @tag :d_379
    test "D-379 implementing: {:worker_exit, current_worker_id, :no_work_product} advances retry ladder and re-enters :implementing" do
      test_pid = self()
      unit_id = "u-d379a-impl-exit-#{System.unique_integer([:positive])}"
      scheduler_name = :"sched_d379a_impl_exit_#{System.unique_integer([:positive])}"
      sup_name = :"sup_d379a_impl_exit_#{System.unique_integer([:positive])}"

      start_scheduler(scheduler_name)
      start_supervised!({@unit_supervisor, name: sup_name}, id: sup_name)

      oracle_worker_id = "w-d379a-impl-exit-oracle-#{System.unique_integer([:positive])}"
      call_count = :counters.new(1, [:atomics])

      worker_fun = fn _role ->
        n = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)
        pid = spawn_worker()

        if n == 0,
          do: {:ok, pid, oracle_worker_id},
          else: {:ok, pid, "d379a-impl-exit-#{n}-#{System.unique_integer([:positive])}"}
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
             "D-379 implementing worker_exit: Unit must reach :implementing; got #{inspect(result)}"

      {:implementing, data_before} = result
      refine_before = Map.get(data_before, :refine_count, 0)
      attempt_before = Map.get(data_before, :attempt_count, 0)
      current_impl_worker_id = data_before.worker_id

      send(unit_pid, {:worker_exit, current_impl_worker_id, :no_work_product})
      Process.sleep(250)

      {state_after, data_after} = :sys.get_state(unit_pid)

      assert state_after == :implementing,
             "D-379 implementing: {:worker_exit, current_worker_id, :no_work_product} must " <>
               "advance the retry ladder and re-enter :implementing; got #{inspect(state_after)}."

      refine_after = Map.get(data_after, :refine_count, 0)
      attempt_after = Map.get(data_after, :attempt_count, 0)

      assert refine_after > refine_before or attempt_after > attempt_before,
             "D-379 implementing: {:worker_exit, current_id, _} must advance the ladder; " <>
               "refine #{refine_before}→#{refine_after}, " <>
               "attempt #{attempt_before}→#{attempt_after}"

      refute_received {:unit_terminal, ^unit_id, _outcome, _prov},
                      "D-379 implementing: a single {:worker_exit, current_id, _} must " <>
                        "route to retry, not terminate the Unit"
    end

    @tag :d_379
    test "D-379 implementing: {:worker_stalled, stale_worker_id} is silently discarded — no ladder advance" do
      test_pid = self()
      unit_id = "u-d379a-impl-stale-#{System.unique_integer([:positive])}"
      scheduler_name = :"sched_d379a_impl_stale_#{System.unique_integer([:positive])}"
      sup_name = :"sup_d379a_impl_stale_#{System.unique_integer([:positive])}"

      start_scheduler(scheduler_name)
      start_supervised!({@unit_supervisor, name: sup_name}, id: sup_name)

      oracle_worker_id = "w-d379as-impl-oracle-#{System.unique_integer([:positive])}"
      call_count = :counters.new(1, [:atomics])

      worker_fun = fn _role ->
        n = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)
        pid = spawn_worker()

        if n == 0,
          do: {:ok, pid, oracle_worker_id},
          else: {:ok, pid, "d379as-impl-#{n}-#{System.unique_integer([:positive])}"}
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
             "D-379 implementing stale: Unit must reach :implementing; got #{inspect(result)}"

      {:implementing, data_before} = result
      refine_before = Map.get(data_before, :refine_count, 0)
      attempt_before = Map.get(data_before, :attempt_count, 0)

      stale_id = "w-d379-stale-#{System.unique_integer([:positive])}"
      send(unit_pid, {:worker_stalled, stale_id})
      Process.sleep(200)

      {state_after, data_after} = :sys.get_state(unit_pid)

      assert state_after == :implementing,
             "D-379 implementing stale: a {:worker_stalled, stale_id} must be discarded — " <>
               "Unit remains in :implementing; got #{inspect(state_after)}"

      refine_after = Map.get(data_after, :refine_count, 0)
      attempt_after = Map.get(data_after, :attempt_count, 0)

      assert refine_before == refine_after and attempt_before == attempt_after,
             "D-379 implementing stale: stale {:worker_stalled} must NOT advance the ladder; " <>
               "refine #{refine_before}→#{refine_after}, " <>
               "attempt #{attempt_before}→#{attempt_after}"

      refute_received {:unit_terminal, ^unit_id, _outcome, _prov},
                      "D-379 implementing stale: stale {:worker_stalled} must not terminate the Unit"
    end
  end

  describe "D-379(a) oracle — routes stalled/exit to retry ladder; stale discarded; re-enters :oracle" do
    @tag :d_379
    test "D-379 oracle: {:worker_stalled, current_oracle_worker_id} advances retry ladder re-enters :oracle not :implementing" do
      test_pid = self()
      unit_id = "u-d379a-oracle-stalled-#{System.unique_integer([:positive])}"
      scheduler_name = :"sched_d379a_oracle_#{System.unique_integer([:positive])}"
      sup_name = :"sup_d379a_oracle_#{System.unique_integer([:positive])}"

      start_scheduler(scheduler_name)
      start_supervised!({@unit_supervisor, name: sup_name}, id: sup_name)

      oracle_worker_id = "w-d379a-oracle-#{System.unique_integer([:positive])}"
      call_count = :counters.new(1, [:atomics])

      worker_fun = fn _role ->
        n = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)
        pid = spawn_worker()
        if n == 0, do: {:ok, pid, oracle_worker_id}, else: {:ok, pid, "re-oracle-#{n}"}
      end

      opts =
        base_unit_opts(unit_id, scheduler_name, test_pid,
          worker_fun: worker_fun,
          timeouts: [state_timeout_ms: 10_000]
        )

      unit_pid = @unit_supervisor.start_unit(sup_name, opts)
      assert is_pid(unit_pid)

      result = wait_for_oracle(unit_pid)

      assert match?({:oracle, _}, result),
             "D-379 oracle: Unit must reach :oracle; got #{inspect(result)}"

      {:oracle, data_before} = result
      refine_before = Map.get(data_before, :refine_count, 0)
      attempt_before = Map.get(data_before, :attempt_count, 0)

      send(unit_pid, {:worker_stalled, oracle_worker_id})
      Process.sleep(250)

      {state_after, data_after} = :sys.get_state(unit_pid)

      assert state_after == :oracle,
             "D-379 oracle: {:worker_stalled, current_oracle_worker_id} must advance " <>
               "the retry ladder and re-enter :oracle (the ORIGINATING state). " <>
               "Got #{inspect(state_after)}. " <>
               "FAIL-BEFORE: advance_retry_ladder/1 hardcodes :implementing — " <>
               "the oracle stall re-enters :implementing, violating oracle-separation."

      refine_after = Map.get(data_after, :refine_count, 0)
      attempt_after = Map.get(data_after, :attempt_count, 0)

      assert refine_after > refine_before or attempt_after > attempt_before,
             "D-379 oracle: {:worker_stalled, current_id} must advance the ladder; " <>
               "refine #{refine_before}→#{refine_after}, " <>
               "attempt #{attempt_before}→#{attempt_after}"

      refute_received {:unit_terminal, ^unit_id, _outcome, _prov},
                      "D-379 oracle: a single {:worker_stalled, current_oracle_id} must " <>
                        "route to retry, not terminate the Unit"
    end

    @tag :d_379
    test "D-379 oracle: {:worker_exit, current_oracle_worker_id, :no_work_product} advances retry ladder and re-enters :oracle (run-#2 regression)" do
      test_pid = self()
      unit_id = "u-d379a-oracle-exit-#{System.unique_integer([:positive])}"
      scheduler_name = :"sched_d379a_oracle_exit_#{System.unique_integer([:positive])}"
      sup_name = :"sup_d379a_oracle_exit_#{System.unique_integer([:positive])}"

      start_scheduler(scheduler_name)
      start_supervised!({@unit_supervisor, name: sup_name}, id: sup_name)

      oracle_worker_id = "w-d379a-oracle-exit-#{System.unique_integer([:positive])}"
      call_count = :counters.new(1, [:atomics])

      worker_fun = fn _role ->
        n = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)
        pid = spawn_worker()
        if n == 0, do: {:ok, pid, oracle_worker_id}, else: {:ok, pid, "re-oracle-exit-#{n}"}
      end

      opts =
        base_unit_opts(unit_id, scheduler_name, test_pid,
          worker_fun: worker_fun,
          timeouts: [state_timeout_ms: 10_000]
        )

      unit_pid = @unit_supervisor.start_unit(sup_name, opts)
      assert is_pid(unit_pid)

      result = wait_for_oracle(unit_pid)

      assert match?({:oracle, _}, result),
             "D-379 oracle worker_exit: Unit must reach :oracle; got #{inspect(result)}"

      {:oracle, data_before} = result
      refine_before = Map.get(data_before, :refine_count, 0)
      attempt_before = Map.get(data_before, :attempt_count, 0)

      # Run-#2 regression: oracle previously had NO {:worker_exit, _, _} clause.
      # This signal would fall through to handle_unexpected/4 and be silently
      # discarded — the oracle worker's no_work_product outcome was invisible to
      # the Unit, violating D-379 and the unified symmetric rule.
      send(unit_pid, {:worker_exit, oracle_worker_id, :no_work_product})
      Process.sleep(250)

      {state_after, data_after} = :sys.get_state(unit_pid)

      assert state_after == :oracle,
             "D-379 oracle (run-#2 regression): {:worker_exit, current_oracle_worker_id, " <>
               ":no_work_product} must advance the retry ladder and re-enter :oracle. " <>
               "Got #{inspect(state_after)}. " <>
               "FAIL-BEFORE: oracle/3 has NO {:worker_exit, _, _} clause — the message " <>
               "falls through to handle_unexpected/4 and is silently discarded."

      refine_after = Map.get(data_after, :refine_count, 0)
      attempt_after = Map.get(data_after, :attempt_count, 0)

      assert refine_after > refine_before or attempt_after > attempt_before,
             "D-379 oracle: {:worker_exit, current_oracle_id, :no_work_product} must " <>
               "advance the ladder; refine #{refine_before}→#{refine_after}, " <>
               "attempt #{attempt_before}→#{attempt_after}. " <>
               "FAIL-BEFORE: no oracle worker_exit clause; ladder stays flat."

      refute_received {:unit_terminal, ^unit_id, _outcome, _prov},
                      "D-379 oracle: a single {:worker_exit, current_oracle_id, _} must " <>
                        "route to retry, not terminate the Unit"
    end

    @tag :d_379
    test "D-379 oracle: {:worker_stalled, stale_oracle_id} is silently discarded — no ladder advance" do
      test_pid = self()
      unit_id = "u-d379a-oracle-stale-#{System.unique_integer([:positive])}"
      scheduler_name = :"sched_d379a_oracle_stale_#{System.unique_integer([:positive])}"
      sup_name = :"sup_d379a_oracle_stale_#{System.unique_integer([:positive])}"

      start_scheduler(scheduler_name)
      start_supervised!({@unit_supervisor, name: sup_name}, id: sup_name)

      oracle_worker_id = "w-d379as-oracle-#{System.unique_integer([:positive])}"
      call_count = :counters.new(1, [:atomics])

      worker_fun = fn _role ->
        n = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)
        pid = spawn_worker()
        if n == 0, do: {:ok, pid, oracle_worker_id}, else: {:ok, pid, "re-oracle-stale-#{n}"}
      end

      opts =
        base_unit_opts(unit_id, scheduler_name, test_pid,
          worker_fun: worker_fun,
          timeouts: [state_timeout_ms: 10_000]
        )

      unit_pid = @unit_supervisor.start_unit(sup_name, opts)
      assert is_pid(unit_pid)

      result = wait_for_oracle(unit_pid)

      assert match?({:oracle, _}, result),
             "D-379 oracle stale: Unit must reach :oracle; got #{inspect(result)}"

      {:oracle, data_before} = result
      refine_before = Map.get(data_before, :refine_count, 0)
      attempt_before = Map.get(data_before, :attempt_count, 0)

      stale_id = "w-d379-oracle-stale-#{System.unique_integer([:positive])}"
      send(unit_pid, {:worker_stalled, stale_id})
      Process.sleep(200)

      {state_after, data_after} = :sys.get_state(unit_pid)

      assert state_after == :oracle,
             "D-379 oracle stale: a {:worker_stalled, stale_oracle_id} must be discarded — " <>
               "Unit remains in :oracle; got #{inspect(state_after)}"

      refine_after = Map.get(data_after, :refine_count, 0)
      attempt_after = Map.get(data_after, :attempt_count, 0)

      assert refine_before == refine_after and attempt_before == attempt_after,
             "D-379 oracle stale: stale {:worker_stalled} must NOT advance the ladder; " <>
               "refine #{refine_before}→#{refine_after}, " <>
               "attempt #{attempt_before}→#{attempt_after}"

      refute_received {:unit_terminal, ^unit_id, _outcome, _prov},
                      "D-379 oracle stale: stale {:worker_stalled} must not terminate the Unit"
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
  # We test this via a Unit with a worker_fun that itself calls
  # Watchdog.register/5 (mirroring the closure UnitDriver.drive/2 will build).
  # The test confirms the stall signal arrives at the Unit and routes to the
  # retry ladder — demonstrating the full D-379 wiring path.
  #
  # FAIL-BEFORE: the Unit has no {:worker_stalled, _} clause via the proper
  # advance_retry_ladder/2 path (D-379 absent or using deferred path), so
  # when the Watchdog fires {:worker_stalled, worker_id} to the Unit the
  # ladder counter stays flat.
  # ---------------------------------------------------------------------------

  describe "D-379(b) — worker_fun that calls Watchdog.register/5 delivers {:worker_stalled, id} to Unit → ladder" do
    @tag :d_379
    test "D-379: worker registered via Watchdog.register/5 — absence triggers {:worker_stalled, id} routed to retry ladder in :implementing" do
      test_pid = self()
      unit_id = "u-d379b-wd-#{System.unique_integer([:positive])}"
      scheduler_name = :"sched_d379b_#{System.unique_integer([:positive])}"
      sup_name = :"sup_d379b_#{System.unique_integer([:positive])}"
      watchdog_name = :"watchdog_d379b_#{System.unique_integer([:positive])}"

      start_scheduler(scheduler_name)
      start_supervised!({@unit_supervisor, name: sup_name}, id: sup_name)

      check_interval = 20
      heartbeat_timeout = 60

      start_supervised!(
        {Watchdog, name: watchdog_name, check_interval: check_interval},
        id: watchdog_name
      )

      oracle_worker_id = "w-d379b-oracle-#{System.unique_integer([:positive])}"
      call_count = :counters.new(1, [:atomics])

      # This worker_fun mirrors the closure UnitDriver.drive/2 will build:
      # calls Watchdog.register/5 with report_to = self() (the Unit's pid)
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

        :ok =
          Watchdog.register(watchdog_name, worker_id, pid, self(),
            heartbeat_timeout: heartbeat_timeout
          )

        {:ok, pid, worker_id}
      end

      opts =
        base_unit_opts(unit_id, scheduler_name, test_pid,
          worker_fun: worker_fun,
          timeouts: [state_timeout_ms: 5_000]
        )

      unit_pid = @unit_supervisor.start_unit(sup_name, opts)
      assert is_pid(unit_pid)

      advance_past_oracle(unit_pid, oracle_worker_id)
      result = wait_for_implementing(unit_pid)

      assert match?({:implementing, _}, result),
             "D-379(b): Unit must reach :implementing; got #{inspect(result)}"

      {:implementing, data_before} = result
      refine_before = Map.get(data_before, :refine_count, 0)
      attempt_before = Map.get(data_before, :attempt_count, 0)

      # No heartbeats emitted — the Watchdog fires {:worker_stalled, impl_worker_id}
      # to the Unit within heartbeat_timeout + check_interval ms.
      Process.sleep(heartbeat_timeout + 4 * check_interval + 50)

      {state_after, data_after} = :sys.get_state(unit_pid)

      refine_after = Map.get(data_after, :refine_count, 0)
      attempt_after = Map.get(data_after, :attempt_count, 0)

      stall_advanced = refine_after > refine_before or attempt_after > attempt_before

      assert state_after == :implementing and stall_advanced,
             "D-379(b): a worker registered with Watchdog.register/5 (the closure " <>
               "UnitDriver.drive/2 will build) MUST trigger {:worker_stalled, worker_id} " <>
               "delivery to the Unit, which routes to the retry ladder via " <>
               "advance_retry_ladder(:implementing, data) (re-enters :implementing). " <>
               "Got state=#{inspect(state_after)}, " <>
               "refine #{refine_before}→#{refine_after}, " <>
               "attempt #{attempt_before}→#{attempt_after}. " <>
               "FAIL-BEFORE: deferred-spawn path or no worker_stalled clause routes " <>
               "via advance_retry_ladder/2."
    end
  end

  # ---------------------------------------------------------------------------
  # D-315 — stall re-spawn MUST write a Ledger snapshot via the ladder's
  # :on_enter (RPO=0 durability) — in BOTH :oracle and :implementing
  # ---------------------------------------------------------------------------
  #
  # The unified contract (GOV4 re-shape): when a stall-class signal fires,
  # advance_retry_ladder/2 emits {:next_state, <originating_state>, data,
  # [{:next_event, :internal, :on_enter}]}. The :on_enter callback already:
  #   (a) bumps attempt_count
  #   (b) calls snapshot_state/2 (writing a Ledger row)
  #   (c) calls worker_fun to spawn the next worker
  #
  # There is NO separate :deferred_spawn / do_spawn_worker path.
  #
  # FAIL-BEFORE (implementing): the deferred path (advance_retry_ladder_deferred/1
  # → :deferred_spawn → do_spawn_worker/1) uses keep_state, not next_state.
  # While do_spawn_worker/1 happens to call attempt_count++ and snapshot_state/2,
  # the advance_retry_ladder/1 call itself uses refine_count++ without calling
  # :on_enter — the attempt_count bump and snapshot happen in do_spawn_worker,
  # which is not the canonical on_enter path. The test asserts the ladder-driven
  # on_enter is the single correct path.
  #
  # FAIL-BEFORE (oracle): advance_retry_ladder/1 (arity-1) hardcodes :implementing
  # as the next state — the oracle :on_enter runs for :implementing, not :oracle,
  # so the oracle stall re-spawn violates oracle-separation AND D-315 (the
  # :implementing on_enter writes the row but with wrong-role semantics).
  # ---------------------------------------------------------------------------

  describe "D-315 — stall re-spawn writes Ledger snapshot via ladder :on_enter (RPO=0)" do
    @tag :d_315
    test "D-315 implementing: worker_stalled triggers ladder re-spawn writing Ledger snapshot with bumped attempt_count" do
      ledger = start_ledger()
      test_pid = self()
      unit_id = "u-d315-impl-stall-snap-#{System.unique_integer([:positive])}"
      scheduler_name = :"sched_d315_impl_#{System.unique_integer([:positive])}"
      sup_name = :"sup_d315_impl_#{System.unique_integer([:positive])}"

      start_scheduler(scheduler_name)
      start_supervised!({@unit_supervisor, name: sup_name}, id: sup_name)

      oracle_worker_id = "w-d315-impl-oracle-#{System.unique_integer([:positive])}"
      call_count = :counters.new(1, [:atomics])

      # D-326: each spawn returns a FRESH unique worker_id.
      worker_fun = fn _role ->
        n = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)
        pid = spawn_worker()

        if n == 0,
          do: {:ok, pid, oracle_worker_id},
          else: {:ok, pid, "d315-impl-#{n}-#{System.unique_integer([:positive])}"}
      end

      opts = [
        unit_id: unit_id,
        declared_scope: empty_scope(),
        hash: "hash-#{unit_id}",
        scheduler: scheduler_name,
        report_to: test_pid,
        ledger: ledger,
        worker_fun: worker_fun,
        gate_fun: fn _coord -> :pass end,
        merge_fun: fn _uid, _hash -> :queued end,
        timeouts: [state_timeout_ms: 10_000]
      ]

      unit_pid = @unit_supervisor.start_unit(sup_name, opts)
      assert is_pid(unit_pid)

      advance_past_oracle(unit_pid, oracle_worker_id)
      result = wait_for_implementing(unit_pid)

      assert match?({:implementing, _}, result),
             "D-315 implementing: Unit must reach :implementing; got #{inspect(result)}"

      {:implementing, data_before} = result
      attempt_before = Map.get(data_before, :attempt_count, 0)
      # Read the CURRENT worker_id from state (fresh id, D-326).
      current_impl_worker_id = data_before.worker_id

      # Sanity: normal :on_enter must write a Ledger snapshot at :implementing.
      Process.sleep(50)
      snapshots_before = LedgerReader.latest_unit_snapshots(ledger)

      assert Map.get(snapshots_before, unit_id) == :implementing,
             "D-315 implementing pre-condition: normal :on_enter must write a Ledger " <>
               "snapshot at :implementing. Got #{inspect(Map.get(snapshots_before, unit_id))} " <>
               "(map: #{inspect(snapshots_before)}). " <>
               "Indicates :ledger opt not wired or normal snapshotting path broken."

      # Trigger the ladder re-spawn by delivering a stall signal for the
      # CURRENT implementing worker. With the unified design:
      #   {:worker_stalled, current_impl_worker_id}
      #   → advance_retry_ladder(:implementing, data)
      #   → {:next_state, :implementing, bumped, [{:next_event, :internal, :on_enter}]}
      #   → implementing(:internal, :on_enter, bumped)
      #   → attempt_count++ + snapshot_state(:implementing, ...) + spawn next worker
      send(unit_pid, {:worker_stalled, current_impl_worker_id})

      # Allow the on_enter to complete: next_state fires, on_enter runs,
      # new worker is spawned.
      Process.sleep(300)

      {state_after, data_after} = :sys.get_state(unit_pid)
      attempt_after = Map.get(data_after, :attempt_count, 0)

      # Assert 1: the Unit is in :implementing after the ladder re-spawn.
      assert state_after == :implementing,
             "D-315 implementing: after stall ladder re-spawn, Unit must be back in " <>
               ":implementing; got #{inspect(state_after)}"

      # Assert 2: attempt_count was bumped by the :on_enter (the re-spawn IS a new attempt).
      assert attempt_after > attempt_before,
             "D-315 implementing: stall ladder re-spawn MUST increment attempt_count " <>
               "via :on_enter. attempt_count #{attempt_before} -> #{attempt_after} " <>
               "(expected strictly greater). " <>
               "FAIL-BEFORE: deferred path's do_spawn_worker bumps attempt_count but " <>
               "outside the canonical on_enter; with the unified ladder the on_enter " <>
               "is the single correct path."

      # Assert 3: the Ledger holds a FRESH :implementing snapshot.
      snapshots_after = LedgerReader.latest_unit_snapshots(ledger)

      assert Map.get(snapshots_after, unit_id) == :implementing,
             "D-315 implementing: after stall ladder re-spawn, Ledger must hold :implementing. " <>
               "Got #{inspect(Map.get(snapshots_after, unit_id))} " <>
               "(map: #{inspect(snapshots_after)})."

      # Assert 4: no terminal — the stall triggered retry, not escalation.
      refute_received {:unit_terminal, ^unit_id, _outcome, _prov},
                      "D-315 implementing: a single {:worker_stalled, current_id} must " <>
                        "route to retry, not terminate the Unit"
    end

    @tag :d_315
    test "D-315 oracle: worker_stalled triggers ladder re-spawn writing Ledger snapshot with bumped attempt_count re-entering :oracle" do
      ledger = start_ledger()
      test_pid = self()
      unit_id = "u-d315-oracle-stall-snap-#{System.unique_integer([:positive])}"
      scheduler_name = :"sched_d315_oracle_#{System.unique_integer([:positive])}"
      sup_name = :"sup_d315_oracle_#{System.unique_integer([:positive])}"

      start_scheduler(scheduler_name)
      start_supervised!({@unit_supervisor, name: sup_name}, id: sup_name)

      oracle_worker_id_1 = "w-d315-oracle-1-#{System.unique_integer([:positive])}"
      oracle_worker_id_2 = "w-d315-oracle-2-#{System.unique_integer([:positive])}"
      call_count = :counters.new(1, [:atomics])

      worker_fun = fn _role ->
        n = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)
        pid = spawn_worker()

        case n do
          0 -> {:ok, pid, oracle_worker_id_1}
          _ -> {:ok, pid, oracle_worker_id_2}
        end
      end

      opts = [
        unit_id: unit_id,
        declared_scope: empty_scope(),
        hash: "hash-#{unit_id}",
        scheduler: scheduler_name,
        report_to: test_pid,
        ledger: ledger,
        worker_fun: worker_fun,
        gate_fun: fn _coord -> :pass end,
        merge_fun: fn _uid, _hash -> :queued end,
        timeouts: [state_timeout_ms: 10_000]
      ]

      unit_pid = @unit_supervisor.start_unit(sup_name, opts)
      assert is_pid(unit_pid)

      # Wait in :oracle — do NOT advance past oracle.
      result = wait_for_oracle(unit_pid)

      assert match?({:oracle, _}, result),
             "D-315 oracle: Unit must reach :oracle; got #{inspect(result)}"

      {:oracle, data_before} = result
      attempt_before = Map.get(data_before, :attempt_count, 0)

      # Allow the oracle :on_enter to write its Ledger snapshot.
      Process.sleep(50)
      snapshots_before = LedgerReader.latest_unit_snapshots(ledger)

      assert Map.get(snapshots_before, unit_id) == :oracle,
             "D-315 oracle pre-condition: normal oracle :on_enter must write a Ledger " <>
               "snapshot at :oracle. Got #{inspect(Map.get(snapshots_before, unit_id))} " <>
               "(map: #{inspect(snapshots_before)}). " <>
               "Indicates :ledger opt not wired, or oracle :on_enter snapshot path broken."

      # Trigger the ladder re-spawn by delivering a stall signal for the
      # CURRENT oracle worker. With the unified design:
      #   {:worker_stalled, oracle_worker_id_1}
      #   → advance_retry_ladder(:oracle, data)
      #   → {:next_state, :oracle, bumped, [{:next_event, :internal, :on_enter}]}
      #   → oracle(:internal, :on_enter, bumped)
      #   → attempt_count++ + snapshot_state(:oracle, ...) + spawn oracle worker 2
      send(unit_pid, {:worker_stalled, oracle_worker_id_1})

      Process.sleep(300)

      {state_after, data_after} = :sys.get_state(unit_pid)
      attempt_after = Map.get(data_after, :attempt_count, 0)

      # Assert 1: Unit is in :oracle after the ladder re-spawn.
      assert state_after == :oracle,
             "D-315 oracle: after stall ladder re-spawn, Unit must be back in :oracle " <>
               "(the originating state). Got #{inspect(state_after)}. " <>
               "FAIL-BEFORE: advance_retry_ladder/1 hardcodes :implementing — oracle " <>
               "stall re-enters :implementing, violating oracle-separation."

      # Assert 2: attempt_count was bumped by oracle :on_enter.
      assert attempt_after > attempt_before,
             "D-315 oracle: stall ladder re-spawn MUST increment attempt_count via " <>
               "oracle :on_enter. attempt_count #{attempt_before} -> #{attempt_after} " <>
               "(expected strictly greater). " <>
               "FAIL-BEFORE: advance_retry_ladder/1 hardcodes :implementing; the " <>
               "wrong :on_enter runs (or no :on_enter if the state doesn't change)."

      # Assert 3: the Ledger holds a FRESH :oracle snapshot.
      snapshots_after = LedgerReader.latest_unit_snapshots(ledger)

      assert Map.get(snapshots_after, unit_id) == :oracle,
             "D-315 oracle: after stall ladder re-spawn, Ledger must hold :oracle snapshot. " <>
               "Got #{inspect(Map.get(snapshots_after, unit_id))} " <>
               "(map: #{inspect(snapshots_after)}). " <>
               "FAIL-BEFORE: advance_retry_ladder/1 hardcodes :implementing — the Ledger " <>
               "would hold :implementing (wrong role) or the wrong attempt_count row."

      # Assert 4: no terminal.
      refute_received {:unit_terminal, ^unit_id, _outcome, _prov},
                      "D-315 oracle: a single {:worker_stalled, current_oracle_id} must " <>
                        "route to retry, not terminate the Unit"
    end
  end

  # ---------------------------------------------------------------------------
  # D-378 LIV-1 — the retry ladder is BOUNDED; repeated stall/exit cycles
  # must eventually escalate E_RETRY_EXHAUSTED, NOT re-spawn forever.
  # ---------------------------------------------------------------------------
  #
  # The current 6beddd1 implementing path sends `:stall_respawn` to itself
  # via `do_spawn_worker` which calls `Retry.next/3`… wait, actually it does
  # NOT call Retry.next at all — it just bumps attempt_count and re-spawns
  # unconditionally. Only the gate-failure path (`advance_gate_ladder/1`)
  # calls `Retry.next`. Therefore the stall/exit loop in `:implementing` is
  # UNBOUNDED: no matter how many times the implementing worker stalls, the
  # Unit keeps re-spawning and never escalates E_RETRY_EXHAUSTED.
  #
  # The realigned impl must use the SAME bounded ladder for stall re-spawns:
  # advance_retry_ladder/2 calls Retry.next (or the :on_enter that calls it)
  # so that after N_REFINE + N_PIVOT stall cycles the Unit escalates.
  #
  # FAIL-BEFORE (6beddd1): the implementing deferred path (`do_spawn_worker`)
  # never consumes the Retry budget → the assert_receive for
  # {:unit_terminal, _, :escalated, _} times out (no escalation ever fires).
  # ---------------------------------------------------------------------------

  describe "D-378 LIV-1 — repeated stall cycles exhaust bounded ladder and escalate E_RETRY_EXHAUSTED" do
    @tag :d_378
    test "D-378 LIV-1 implementing: repeated worker_stalled cycles exhaust Retry ladder and escalate E_RETRY_EXHAUSTED not re-spawn forever" do
      test_pid = self()
      unit_id = "u-d378-liv1-impl-#{System.unique_integer([:positive])}"
      scheduler_name = :"sched_d378_liv1_impl_#{System.unique_integer([:positive])}"
      sup_name = :"sup_d378_liv1_impl_#{System.unique_integer([:positive])}"

      start_scheduler(scheduler_name)
      start_supervised!({@unit_supervisor, name: sup_name}, id: sup_name)

      oracle_worker_id = "w-liv1-oracle-#{System.unique_integer([:positive])}"
      call_count = :counters.new(1, [:atomics])

      worker_fun = fn _role ->
        n = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)
        pid = spawn_worker()

        if n == 0,
          do: {:ok, pid, oracle_worker_id},
          else: {:ok, pid, "liv1-impl-#{n}-#{System.unique_integer([:positive])}"}
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
             "D-378 LIV-1: Unit must reach :implementing; got #{inspect(result)}"

      # The total stall budget: N_REFINE + N_PIVOT stall cycles must exhaust the
      # unified bounded ladder and cause the Unit to escalate E_RETRY_EXHAUSTED.
      # This is the LIVENESS STALL path ({:worker_stalled, w}) — NOT the
      # semantic-failure path ({:worker_exit, w, _}) which already calls
      # advance_gate_ladder in the current impl.
      #
      # FAIL-BEFORE (6beddd1): implementing {:worker_stalled, _} calls
      # advance_retry_ladder(:implementing, data) which sends :stall_respawn
      # and returns {:keep_state, data}. do_spawn_worker then bumps attempt_count
      # and re-spawns — but it NEVER calls Retry.next/3, so the stall re-spawn
      # loop is UNBOUNDED. No E_RETRY_EXHAUSTED is ever sent.
      total_stall_cycles = Retry.n_refine() + Retry.n_pivot() + 1

      # Drive stall cycles: each cycle reads the current worker_id from state,
      # sends a {:worker_stalled, id} signal (the liveness path), and waits for
      # the Unit to re-enter :implementing (re-spawn via the ladder).
      # After exhausting the budget the Unit must escalate.
      for _cycle <- 1..total_stall_cycles do
        case :sys.get_state(unit_pid) do
          {:implementing, data} ->
            current_id = data.worker_id

            if is_binary(current_id) do
              send(unit_pid, {:worker_stalled, current_id})
            end

          _other ->
            :ok
        end

        # Allow the ladder transition (on_enter re-spawn) to complete.
        Process.sleep(150)
      end

      # After exhausting the retry budget the Unit MUST send a terminal escalation.
      assert_receive {:unit_terminal, ^unit_id, :escalated, provenance},
                     2_000,
                     "D-378 LIV-1 implementing: after #{total_stall_cycles} " <>
                       "{:worker_stalled, _} cycles the bounded ladder MUST escalate " <>
                       "E_RETRY_EXHAUSTED. No terminal received within 2000ms. " <>
                       "FAIL-BEFORE (6beddd1): the :stall_respawn deferred path in " <>
                       "advance_retry_ladder(:implementing, _) never calls Retry.next/3 " <>
                       "— the stall loop is UNBOUNDED and the Unit re-spawns forever."

      reason = Map.get(provenance, :reason)

      assert reason == :E_RETRY_EXHAUSTED,
             "D-378 LIV-1 implementing: terminal escalation must carry :E_RETRY_EXHAUSTED; " <>
               "got #{inspect(reason)}. Provenance: #{inspect(provenance)}"
    end

    @tag :d_378
    test "D-378 LIV-1 oracle: repeated worker_stalled cycles exhaust Retry ladder and escalate E_RETRY_EXHAUSTED" do
      test_pid = self()
      unit_id = "u-d378-liv1-oracle-#{System.unique_integer([:positive])}"
      scheduler_name = :"sched_d378_liv1_oracle_#{System.unique_integer([:positive])}"
      sup_name = :"sup_d378_liv1_oracle_#{System.unique_integer([:positive])}"

      start_scheduler(scheduler_name)
      start_supervised!({@unit_supervisor, name: sup_name}, id: sup_name)

      call_count = :counters.new(1, [:atomics])

      worker_fun = fn _role ->
        n = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)
        pid = spawn_worker()
        {:ok, pid, "liv1-oracle-worker-#{n}-#{System.unique_integer([:positive])}"}
      end

      opts =
        base_unit_opts(unit_id, scheduler_name, test_pid,
          worker_fun: worker_fun,
          timeouts: [state_timeout_ms: 10_000]
        )

      unit_pid = @unit_supervisor.start_unit(sup_name, opts)
      assert is_pid(unit_pid)

      # Stay in :oracle — do NOT advance past oracle.
      result = wait_for_oracle(unit_pid)

      assert match?({:oracle, _}, result),
             "D-378 LIV-1 oracle: Unit must reach :oracle; got #{inspect(result)}"

      # Drive stall cycles using the LIVENESS stall signal ({:worker_stalled, _})
      # to mirror the implementing LIV-1 test. Both paths (oracle and implementing)
      # must route stall signals through the SAME bounded ladder.
      total_stall_cycles = Retry.n_refine() + Retry.n_pivot() + 1

      for _cycle <- 1..total_stall_cycles do
        case :sys.get_state(unit_pid) do
          {:oracle, data} ->
            current_id = data.worker_id

            if is_binary(current_id) do
              send(unit_pid, {:worker_stalled, current_id})
            end

          _other ->
            :ok
        end

        Process.sleep(150)
      end

      assert_receive {:unit_terminal, ^unit_id, :escalated, provenance},
                     2_000,
                     "D-378 LIV-1 oracle: after #{total_stall_cycles} {:worker_stalled, _} " <>
                       "cycles the bounded ladder MUST escalate E_RETRY_EXHAUSTED. " <>
                       "No terminal received within 2000ms. " <>
                       "FAIL-BEFORE (6beddd1): advance_retry_ladder(:oracle, data) returns " <>
                       "{:next_state, :oracle, data} with no Retry.next/3 call — the oracle " <>
                       "stall loop is UNBOUNDED and the Unit re-spawns indefinitely."

      reason = Map.get(provenance, :reason)

      assert reason == :E_RETRY_EXHAUSTED,
             "D-378 LIV-1 oracle: terminal escalation must carry :E_RETRY_EXHAUSTED; " <>
               "got #{inspect(reason)}"
    end
  end

  # ---------------------------------------------------------------------------
  # D-378 symmetric worker_exit — implementing({:worker_exit,_}) uses
  # advance_retry_ladder/2, NOT advance_gate_ladder.
  #
  # The asymmetric routing bug (6beddd1): implementing {:worker_exit, _, _}
  # calls `advance_gate_ladder/1` which increments `refine_count` (consuming
  # the gate-retry budget, D-318). The SPEC mandates that worker-outcome events
  # (both worker_stalled AND worker_exit) use `advance_retry_ladder/2` so that
  # only gate failures consume the refine budget. Oracle already uses
  # advance_retry_ladder — refine_count is NOT bumped there.
  #
  # Observable: when implementing receives {:worker_exit, current_id, _},
  # `refine_count` must NOT be bumped. `advance_gate_ladder` bumps it;
  # `advance_retry_ladder/2` (realigned impl) must NOT.
  #
  # FAIL-BEFORE (6beddd1): implementing {:worker_exit, _, _} calls
  # advance_gate_ladder → refine_count increments from 0 to 1.
  # The assertion that refine_count is UNCHANGED fails for implementing.
  # ---------------------------------------------------------------------------

  describe "D-378 symmetric worker_exit — implementing uses advance_retry_ladder not advance_gate_ladder" do
    @tag :d_378
    test "D-378 symmetric: implementing {:worker_exit,current_id} does NOT consume refine_count (uses advance_retry_ladder not advance_gate_ladder)" do
      test_pid = self()
      unit_id = "u-d378-sym-exit-#{System.unique_integer([:positive])}"
      scheduler_name = :"sched_d378_sym_exit_#{System.unique_integer([:positive])}"
      sup_name = :"sup_d378_sym_exit_#{System.unique_integer([:positive])}"

      start_scheduler(scheduler_name)
      start_supervised!({@unit_supervisor, name: sup_name}, id: sup_name)

      oracle_worker_id = "w-sym-oracle-#{System.unique_integer([:positive])}"
      call_count = :counters.new(1, [:atomics])

      worker_fun = fn _role ->
        n = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)
        pid = spawn_worker()

        if n == 0,
          do: {:ok, pid, oracle_worker_id},
          else: {:ok, pid, "sym-impl-#{n}-#{System.unique_integer([:positive])}"}
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
             "D-378 symmetric: Unit must reach :implementing; got #{inspect(result)}"

      {:implementing, data_before} = result
      refine_before = data_before.refine_count
      attempt_before = data_before.attempt_count
      current_impl_id = data_before.worker_id

      # Send a single worker_exit for the current implementing worker.
      # The SPEC mandates advance_retry_ladder/2 (identical to oracle):
      # - re-enters :implementing via {:next_state, :implementing, …}
      # - bumps attempt_count via :on_enter
      # - does NOT bump refine_count (only gate failures do that)
      send(unit_pid, {:worker_exit, current_impl_id, :no_work_product})

      Process.sleep(300)

      {state_after, data_after} = :sys.get_state(unit_pid)

      assert state_after == :implementing,
             "D-378 symmetric: {:worker_exit, current_impl_id, _} must re-enter " <>
               ":implementing. Got #{inspect(state_after)}."

      assert data_after.refine_count == refine_before,
             "D-378 symmetric: {:worker_exit, current_impl_id, _} MUST NOT bump " <>
               "refine_count — worker-outcome events use advance_retry_ladder/2, " <>
               "not advance_gate_ladder. refine_count #{refine_before} -> " <>
               "#{data_after.refine_count}. " <>
               "FAIL-BEFORE (6beddd1): implementing {:worker_exit, _, _} calls " <>
               "advance_gate_ladder which increments refine_count, consuming the " <>
               "gate retry budget for a non-gate-failure event."

      assert data_after.attempt_count > attempt_before,
             "D-378 symmetric: {:worker_exit, current_impl_id, _} must bump " <>
               "attempt_count via the :on_enter. " <>
               "attempt_count #{attempt_before} -> #{data_after.attempt_count}."

      refute_received {:unit_terminal, ^unit_id, _outcome, _prov},
                      "D-378 symmetric: a single {:worker_exit, current_impl_id, _} " <>
                        "must route to retry, not terminate the Unit"
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Drive {:worker_heartbeat, worker_id} pulses from the TEST PROCESS at
  # interval_ms for up_to_ms total wall time. Driving from the test process
  # (rather than a spawned ticker) ensures the sends are not subject to
  # scheduler starvation of a separate process under full-suite load.
  defp hb_loop_from_test(_unit_pid, _worker_id, _interval_ms, remaining_ms)
       when remaining_ms <= 0,
       do: :ok

  defp hb_loop_from_test(unit_pid, worker_id, interval_ms, remaining_ms) do
    send(unit_pid, {:worker_heartbeat, worker_id})
    Process.sleep(interval_ms)
    hb_loop_from_test(unit_pid, worker_id, interval_ms, remaining_ms - interval_ms)
  end
end
