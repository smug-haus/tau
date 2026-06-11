defmodule Tau.Factory.UnitTerminationTest do
  @moduledoc """
  Gating tests for PR #441 (P4c — Unit FSM lifecycle driver).

  Exercises D-340 (unit termination liveness) and D-318 (bounded retry).

  Each test drives the Unit FSM to a terminal sink by scripting the injected
  boundary seams (worker_fun, gate_fun, merge_fun) and asserting that the
  `{:unit_terminal, unit_id, outcome, provenance}` report arrives and that
  `Scheduler.in_flight/1` no longer contains the unit after terminal.

  Written BEFORE production code exists (oracle-separation phase, factory-loop §4b).
  These tests fail with `UndefinedFunctionError` until the implementer creates:
    - `lib/tau/factory/unit.ex`         (Tau.Factory.Unit)
    - `lib/tau/factory/unit_supervisor.ex` (Tau.Factory.UnitSupervisor)
    - (Tau.Factory.UnitRegistry — a Registry started by UnitSupervisor or
      the test harness; name injected via opts)

  ## Pinned API contract (implementer MUST conform exactly)

  ### Tau.Factory.Unit (gen_statem, :state_functions)

  States (SPEC-FACTORY-CORE §5):
    planned → oracle → implementing → gating → awaiting_merge → merged (terminal)
    gating {:fail,_} → retry ladder → implementing | escalated (terminal)
    awaiting_merge :rejected → gating (re-gate)
    any non-terminal + :state_timeout or worker_stalled → ladder → escalated (terminal)
    any non-terminal + escalation/2 → escalated (terminal)

  `start_link(opts) :: {:ok, pid} | {:error, term}`

  Required opts:
    `:unit_id`        — String.t(); unique identity; keyed in UnitRegistry.
    `:declared_scope` — ConflictCheck.scope() (passed to Scheduler.admit/3).
    `:hash`           — String.t(); content hash for the PR.
    `:scheduler`      — atom() | pid(); name/pid of a running Scheduler.
    `:report_to`      — pid(); receives `{:unit_terminal, unit_id, outcome, provenance}`.
    `:worker_fun`     — (role :: atom() -> {:ok, worker_pid :: pid()} | {:error, reason})
                        Called when the FSM needs to spawn a worker for a role.
                        Returns a REAL process pid that the Unit MUST monitor via
                        `Process.monitor(worker_pid)`. The Unit MUST store the worker
                        pid in state data under the key `:worker_pid` (test-observable
                        via `:sys.get_state/1`). The test controls worker completion
                        by sending `{:worker_done, worker_pid}` to the Unit pid.
                        A worker crash is signalled by killing the worker pid; the
                        Unit's monitor delivers `{:DOWN, monitor_ref, :process,
                        worker_pid, reason}` and the Unit routes to the infra-failure
                        path (B8/C105 — NOT a gate call).
    `:gate_fun`       — (-> :pass | {:fail, findings :: [term()]})
                        Called when the FSM enters gating state. The seam's return
                        determines the gate outcome synchronously (i.e. the Unit
                        may call this in-state or via an internal event; the implementer
                        chooses, but the test observes the terminal output only).
    `:merge_fun`      — (unit_id :: String.t(), hash :: String.t() ->
                          :queued | {:error, reason})
                        Called when the FSM requests a merge (awaiting_merge entry).
                        The result `:merged | :rejected` is delivered to the Unit
                        process as `{:merge_result, :merged | :rejected}` sent
                        by the test harness (or the merge_fun itself may spawn a
                        process that does so). The Unit's awaiting_merge state must
                        handle this message.
    `:timeouts`       — keyword(); optional overrides:
                          `:state_timeout_ms` — integer(); `:state_timeout` value
                          for each waiting state (oracle, implementing, gating,
                          awaiting_merge). Default: 30_000. Set to ~50 for the
                          stall test so the test is fast.

  ### Tau.Factory.UnitSupervisor (DynamicSupervisor, restart :temporary)

  `start_link(opts) :: {:ok, pid}`
    Required opts: `:name` (atom).

  `start_unit(supervisor, unit_opts) :: {:ok, pid} | {:error, term}`
    Starts a Unit under the DynamicSupervisor. `unit_opts` is the same
    opts map accepted by `Unit.start_link/1`.

  ### Tau.Factory.UnitRegistry (Registry)

  A Registry started with `:keys: :unique`. Name is passed to tests via
  the registry_name opt; the Unit registers itself under its `unit_id`.

  `lookup(registry, unit_id) :: [{pid, value}]`
    Standard Registry.lookup/2.

  ### Terminal report shape

  `{:unit_terminal, unit_id :: String.t(), outcome, provenance}`

  where:
    outcome    :: :merged | :escalated | :rejected
    provenance :: %{
      attempt_count: non_neg_integer(),    # total non-terminal attempts
      last_findings: [term()] | nil,       # last gate findings (nil if not a gate failure)
      reason: atom() | nil                 # escalation reason (e.g. :E_RETRY_EXHAUSTED) or nil
    }

  ### Worker seam shape (PINNED — implementer MUST conform exactly, B8)

  `worker_fun.(role) -> {:ok, worker_pid :: pid()}`

  The Unit MUST:
    1. Call `Process.monitor(worker_pid)` to obtain a monitor ref (B8 liveness).
    2. Store `worker_pid` in state data under the key `:worker_pid` (test-observable
       via `:sys.get_state/1` so the test can deliver :worker_done or kill the pid).
    3. Match `{:worker_done, ^worker_pid}` for normal worker completion.
    4. Match `{:DOWN, _monitor_ref, :process, ^worker_pid, _reason}` for crash.
       On crash: route to infra-failure → `escalated`; do NOT call `gate_fun` (C105).

  AC/D-NNN linkage: D-340, D-318, B8, C105.
  """

  use ExUnit.Case, async: true

  # Retry exists on main; alias it to satisfy Credo nested-module warnings.
  alias Tau.Factory.Retry

  @moduletag :capture_log
  @moduletag :d_340
  @moduletag :d_318

  # ---------------------------------------------------------------------------
  # Runtime module references — file compiles while Unit/UnitSupervisor absent.
  # @mod.fun(args) form; NOT apply/2,3 (Credo strict).
  # ---------------------------------------------------------------------------

  @unit_supervisor Tau.Factory.UnitSupervisor
  @scheduler Tau.Factory.Scheduler

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Build a minimal non-conflicting scope that clears all five ConflictCheck
  # clauses against any other empty-scope unit.
  defp empty_scope do
    %{
      deps: [],
      files: MapSet.new(),
      codepoints: MapSet.new(),
      specs: MapSet.new(),
      resources: MapSet.new()
    }
  end

  # Start an isolated Scheduler with generous capacity and no budget gate.
  defp start_scheduler(name) do
    start_supervised!(
      {@scheduler, name: name, w_cap: 10},
      id: name
    )
  end

  # Spawn a long-lived worker process the Unit will monitor via Process.monitor/1.
  # The test kills it (abnormal) or delivers {:worker_done, pid} (normal).
  defp spawn_worker do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  # Build base Unit opts with seam funs injected by the caller.
  # worker_fun now returns {:ok, pid} where pid is a REAL monitorable process (B8).
  defp base_unit_opts(unit_id, scheduler_name, report_to, overrides) do
    defaults = [
      unit_id: unit_id,
      declared_scope: empty_scope(),
      hash: "hash-#{unit_id}",
      scheduler: scheduler_name,
      report_to: report_to,
      # Default seams (overridden per test).
      # worker_fun returns a real monitorable pid (B8 contract).
      worker_fun: fn _role -> {:ok, spawn_worker()} end,
      gate_fun: fn -> :pass end,
      merge_fun: fn _uid, _hash -> :queued end,
      timeouts: [state_timeout_ms: 5_000]
    ]

    Keyword.merge(defaults, overrides)
  end

  # Deliver :worker_done for the worker pid the FSM is currently waiting on.
  # The Unit MUST expose :worker_pid in state data (pinned seam contract, B8).
  # The Unit matches {:worker_done, ^worker_pid} for normal completion.
  defp deliver_worker_done(unit_pid) do
    :timer.sleep(50)

    case :sys.get_state(unit_pid) do
      {state, data} when state in [:oracle, :implementing] ->
        worker_pid = Map.get(data, :worker_pid)

        if is_pid(worker_pid) do
          send(unit_pid, {:worker_done, worker_pid})
        end

      _ ->
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # D-340a — Happy path → merged
  # ---------------------------------------------------------------------------

  describe "D-340a — happy path reaches :merged and releases from Scheduler" do
    @tag :d_340
    @tag :d_318
    test "D-340a: worker completes, gate passes, merge succeeds → :merged report + released" do
      test_pid = self()
      unit_id = "u-happy-#{System.unique_integer([:positive])}"
      scheduler_name = :"sched_happy_#{System.unique_integer([:positive])}"
      sup_name = :"sup_happy_#{System.unique_integer([:positive])}"
      start_scheduler(scheduler_name)
      start_supervised!({@unit_supervisor, name: sup_name}, id: sup_name)

      gate_fun = fn -> :pass end
      merge_fun = fn _uid, _hash -> :queued end

      opts =
        base_unit_opts(unit_id, scheduler_name, test_pid,
          gate_fun: gate_fun,
          merge_fun: merge_fun,
          timeouts: [state_timeout_ms: 5_000]
        )

      unit_pid = @unit_supervisor.start_unit(sup_name, opts)
      assert is_pid(unit_pid), "start_unit must return a pid"

      # Drive oracle phase.
      deliver_worker_done(unit_pid)

      # Allow FSM to advance; drive implementing phase.
      :timer.sleep(50)
      deliver_worker_done(unit_pid)

      # Allow transition through gating (gate_fun → :pass) to awaiting_merge.
      :timer.sleep(100)

      # Deliver merge result :merged to the Unit.
      send(unit_pid, {:merge_result, :merged})

      # Assert terminal report arrives.
      assert_receive {:unit_terminal, ^unit_id, :merged, provenance},
                     5_000,
                     "D-340a: expected {:unit_terminal, _, :merged, _} within 5s"

      assert is_map(provenance),
             "D-340a: provenance must be a map; got #{inspect(provenance)}"

      # Assert Scheduler released the unit.
      in_flight = @scheduler.in_flight(scheduler_name)

      refute Map.has_key?(in_flight, unit_id),
             "D-340a: after :merged, unit must be released from Scheduler in_flight"
    end
  end

  # ---------------------------------------------------------------------------
  # D-340b / D-318 — Gate-fail ladder → escalated at EXACT attempt count (fix f-4)
  #
  # The SPEC §5 ladder (line 315):
  #   k < N_REFINE  → refine → back to implementing
  #   k = N_REFINE  → pivot  → back to implementing (REAL extra attempt, GATED)
  #   pivot gate red → escalated [E-RETRY-EXHAUSTED]
  #
  # Gated-pivot gate-call trace (N_REFINE=3, N_PIVOT=1):
  #   attempt 1 (initial)  → gate #1 fail → Retry.next(_,0,0) = {:refine,0}
  #   attempt 2            → gate #2 fail → Retry.next(_,1,0) = {:refine,1}
  #   attempt 3            → gate #3 fail → Retry.next(_,2,0) = {:refine,2}
  #   attempt 4            → gate #4 fail → Retry.next(_,3,0) = :pivot  → re-implement
  #   attempt 5 (pivot)    → gate #5 fail → Retry.next(_,3,1) = :exhausted → escalated
  #
  # Total gate calls = 1 + N_REFINE + N_PIVOT = 5.
  # A buggy FSM that escalates the pivot UNGATED makes only 4 gate calls.
  # == 5 is the discriminating assertion (fix f-4, supersedes f-2's == 4).
  # ---------------------------------------------------------------------------

  describe "D-340b / D-318 — gate-fail ladder escalates at EXACT attempt count" do
    @tag :d_340
    @tag :d_318
    test "D-340b / D-318: gate always fails → :escalated with E-RETRY-EXHAUSTED, gate_calls == 1 + N_refine + N_pivot (exact)" do
      test_pid = self()
      unit_id = "u-ladder-#{System.unique_integer([:positive])}"
      scheduler_name = :"sched_ladder_#{System.unique_integer([:positive])}"
      sup_name = :"sup_ladder_#{System.unique_integer([:positive])}"
      start_scheduler(scheduler_name)
      start_supervised!({@unit_supervisor, name: sup_name}, id: sup_name)

      gate_count_ref = :counters.new(1, [:atomics])

      gate_fun = fn ->
        :counters.add(gate_count_ref, 1, 1)
        {:fail, ["finding-#{:counters.get(gate_count_ref, 1)}"]}
      end

      merge_fun = fn _uid, _hash -> :queued end

      n_refine = Retry.n_refine()
      n_pivot = Retry.n_pivot()
      # 1 initial attempt + N_REFINE refine attempts + N_PIVOT pivot attempt, all gated.
      # With N_REFINE=3, N_PIVOT=1: exactly 5 gate calls expected.
      expected_gate_calls = 1 + n_refine + n_pivot

      opts =
        base_unit_opts(unit_id, scheduler_name, test_pid,
          gate_fun: gate_fun,
          merge_fun: merge_fun,
          timeouts: [state_timeout_ms: 5_000]
        )

      unit_pid = @unit_supervisor.start_unit(sup_name, opts)
      assert is_pid(unit_pid)

      # Drive oracle (1 delivery) then each implementing cycle (expected_gate_calls
      # deliveries — one per gated attempt including the pivot attempt).
      # Add slack iterations to avoid races with FSM scheduling.
      for _i <- 1..(expected_gate_calls + 3) do
        deliver_worker_done(unit_pid)
        :timer.sleep(60)
      end

      assert_receive {:unit_terminal, ^unit_id, :escalated, provenance},
                     10_000,
                     "D-340b / D-318: expected {:unit_terminal, _, :escalated, _} within 10s"

      reason = Map.get(provenance, :reason)

      assert reason == :E_RETRY_EXHAUSTED,
             "D-318: escalated provenance must carry :E_RETRY_EXHAUSTED; got #{inspect(reason)}"

      gate_calls = :counters.get(gate_count_ref, 1)

      # EXACT assertion (fix f-4: gated-pivot semantics).
      # gate_calls == 4 means the pivot was escalated UNGATED (buggy FSM from f-2).
      # gate_calls == 3 means the pivot attempt was skipped entirely (f-2's original bug).
      # gate_calls == 5 means all 5 attempts were gated, including the pivot: correct FSM.
      assert gate_calls == expected_gate_calls,
             "D-318 (f-4): gate must be called EXACTLY #{expected_gate_calls} times " <>
               "(1 initial + #{n_refine} refine attempts + #{n_pivot} pivot attempt, all gated); " <>
               "got #{gate_calls} — " <>
               "count 4 means pivot was escalated ungated (f-4 bug); " <>
               "count 3 means pivot attempt was skipped entirely (f-2 bug)"

      in_flight = @scheduler.in_flight(scheduler_name)

      refute Map.has_key?(in_flight, unit_id),
             "D-340b: after :escalated, unit must be released from Scheduler in_flight"
    end
  end

  # ---------------------------------------------------------------------------
  # D-318 / f-5 — Successful pivot: pivot attempt's gate PASSES → :merged
  #
  # This is the discriminating case for gated-pivot semantics (f-4).
  # gate_fun script: [{:fail,_}, {:fail,_}, {:fail,_}, {:fail,_}, :pass]
  #   attempt 1 (initial)  → gate #1 {:fail,_} → refine
  #   attempt 2            → gate #2 {:fail,_} → refine
  #   attempt 3            → gate #3 {:fail,_} → refine
  #   attempt 4            → gate #4 {:fail,_} → pivot → re-implement
  #   attempt 5 (pivot)    → gate #5 :pass      → awaiting_merge → :merged
  #
  # Against an ungated-pivot FSM: the pivot attempt is escalated without gating,
  # so gate #5 is never called and the unit terminates :escalated — test FAILS.
  # Against the correct gated FSM: gate #5 fires, unit proceeds to :merged — test PASSES.
  # ---------------------------------------------------------------------------

  describe "D-318 / f-5 — successful pivot: pivot attempt's gate passes → :merged" do
    @tag :d_340
    @tag :d_318
    test "D-318 (f-5): gate fails 4 times then passes on pivot attempt → :merged, gate_calls == 5" do
      test_pid = self()
      unit_id = "u-pivot-pass-#{System.unique_integer([:positive])}"
      scheduler_name = :"sched_pivot_pass_#{System.unique_integer([:positive])}"
      sup_name = :"sup_pivot_pass_#{System.unique_integer([:positive])}"
      start_scheduler(scheduler_name)
      start_supervised!({@unit_supervisor, name: sup_name}, id: sup_name)

      n_refine = Retry.n_refine()
      n_pivot = Retry.n_pivot()
      # Total attempts before pivot pass: 1 initial + N_REFINE refines = 4 fails,
      # then the pivot attempt (call #5) returns :pass.
      total_gate_calls = 1 + n_refine + n_pivot

      gate_count_ref = :counters.new(1, [:atomics])

      # Script: first (1 + n_refine) calls → {:fail,_}; the pivot call → :pass.
      gate_fun = fn ->
        call_n =
          :counters.add(gate_count_ref, 1, 1) |> then(fn _ -> :counters.get(gate_count_ref, 1) end)

        if call_n <= 1 + n_refine do
          {:fail, ["scripted-fail-#{call_n}"]}
        else
          :pass
        end
      end

      merge_fun = fn _uid, _hash -> :queued end

      opts =
        base_unit_opts(unit_id, scheduler_name, test_pid,
          gate_fun: gate_fun,
          merge_fun: merge_fun,
          timeouts: [state_timeout_ms: 5_000]
        )

      unit_pid = @unit_supervisor.start_unit(sup_name, opts)
      assert is_pid(unit_pid)

      # Drive oracle + all implementing attempts (initial + refines + pivot).
      # Add slack iterations; the pivot attempt reaching gating requires one extra
      # worker-done delivery.
      for _i <- 1..(total_gate_calls + 3) do
        deliver_worker_done(unit_pid)
        :timer.sleep(60)
      end

      # Allow FSM to reach awaiting_merge after the pivot gate passes.
      :timer.sleep(150)

      # Deliver :merged to complete the terminal path.
      send(unit_pid, {:merge_result, :merged})

      # The pivot attempt's gate passed → unit must reach :merged, NOT :escalated.
      assert_receive {:unit_terminal, ^unit_id, :merged, provenance},
                     10_000,
                     "D-318 (f-5): pivot gate passed — expected {:unit_terminal, _, :merged, _}; " <>
                       "if :escalated arrived, the FSM escalated the pivot UNGATED (f-4 bug)"

      assert is_map(provenance),
             "D-318 (f-5): provenance must be a map; got #{inspect(provenance)}"

      gate_calls = :counters.get(gate_count_ref, 1)

      assert gate_calls == total_gate_calls,
             "D-318 (f-5): gate must be called exactly #{total_gate_calls} times " <>
               "(#{1 + n_refine} fails + 1 pivot pass); got #{gate_calls}"

      in_flight = @scheduler.in_flight(scheduler_name)

      refute Map.has_key?(in_flight, unit_id),
             "D-318 (f-5): after :merged, unit must be released from Scheduler in_flight"
    end
  end

  # ---------------------------------------------------------------------------
  # D-340c / C107 — Infra stall → escalated via :state_timeout (not gate fail)
  # ---------------------------------------------------------------------------

  describe "D-340c / C107 — wedged worker triggers :state_timeout → :escalated" do
    @tag :d_340
    @tag :d_318
    test "D-340c / C107: worker never delivers done → :state_timeout fires → :escalated" do
      test_pid = self()
      unit_id = "u-stall-#{System.unique_integer([:positive])}"
      scheduler_name = :"sched_stall_#{System.unique_integer([:positive])}"
      sup_name = :"sup_stall_#{System.unique_integer([:positive])}"
      start_scheduler(scheduler_name)
      start_supervised!({@unit_supervisor, name: sup_name}, id: sup_name)

      # gate_fun sentinel: if called, FSM confused infra stall with semantic failure.
      gate_called_ref = :counters.new(1, [:atomics])

      # worker_fun returns real monitorable pid but :worker_done is never sent.
      # Unit must arm :state_timeout and escalate on expiry.
      worker_fun = fn _role -> {:ok, spawn_worker()} end

      gate_fun = fn ->
        :counters.add(gate_called_ref, 1, 1)
        :pass
      end

      merge_fun = fn _uid, _hash -> :queued end

      opts =
        base_unit_opts(unit_id, scheduler_name, test_pid,
          worker_fun: worker_fun,
          gate_fun: gate_fun,
          merge_fun: merge_fun,
          # Very short timeout so the stall path completes quickly in CI.
          timeouts: [state_timeout_ms: 80]
        )

      unit_pid = @unit_supervisor.start_unit(sup_name, opts)
      assert is_pid(unit_pid)

      # Do NOT send any :worker_done. The FSM must timeout on its own.
      assert_receive {:unit_terminal, ^unit_id, :escalated, provenance},
                     5_000,
                     "D-340c / C107: expected :escalated from :state_timeout within 5s"

      reason = Map.get(provenance, :reason)

      refute reason == nil,
             "D-340c: provenance must carry a reason; got nil"

      # C105 / C107: stall path is NOT the gate-fail path. Gate must not be called.
      gate_calls = :counters.get(gate_called_ref, 1)

      assert gate_calls == 0,
             "C105 / C107: gate_fun must not be called on a :state_timeout stall path; called #{gate_calls} times"

      assert is_pid(unit_pid)

      in_flight = @scheduler.in_flight(scheduler_name)

      refute Map.has_key?(in_flight, unit_id),
             "D-340c: after :escalated, unit must be released from Scheduler in_flight"
    end
  end

  # ---------------------------------------------------------------------------
  # D-340d — Merge reject → re-gate (INV-2) → eventually :merged
  # ---------------------------------------------------------------------------

  describe "D-340d — merge reject causes re-gate; second pass succeeds → :merged" do
    @tag :d_340
    @tag :d_318
    test "D-340d: first merge :rejected → unit re-gates → second pass :merged" do
      test_pid = self()
      unit_id = "u-rejet-#{System.unique_integer([:positive])}"
      scheduler_name = :"sched_rejet_#{System.unique_integer([:positive])}"
      sup_name = :"sup_rejet_#{System.unique_integer([:positive])}"
      start_scheduler(scheduler_name)
      start_supervised!({@unit_supervisor, name: sup_name}, id: sup_name)

      gate_fun = fn -> :pass end
      merge_fun = fn _uid, _hash -> :queued end

      opts =
        base_unit_opts(unit_id, scheduler_name, test_pid,
          gate_fun: gate_fun,
          merge_fun: merge_fun,
          timeouts: [state_timeout_ms: 5_000]
        )

      unit_pid = @unit_supervisor.start_unit(sup_name, opts)
      assert is_pid(unit_pid)

      # Advance through oracle and implementing.
      deliver_worker_done(unit_pid)
      :timer.sleep(50)
      deliver_worker_done(unit_pid)

      # Allow FSM to reach awaiting_merge (gate :pass → awaiting_merge).
      :timer.sleep(100)

      # First merge result: :rejected → FSM must re-enter gating (INV-2).
      send(unit_pid, {:merge_result, :rejected})

      # Allow FSM to re-gate and re-enter awaiting_merge.
      :timer.sleep(150)

      # Second merge result: :merged → terminal.
      send(unit_pid, {:merge_result, :merged})

      assert_receive {:unit_terminal, ^unit_id, :merged, provenance},
                     5_000,
                     "D-340d: expected {:unit_terminal, _, :merged, _} after reject+re-gate within 5s"

      assert is_map(provenance),
             "D-340d: provenance must be a map"

      in_flight = @scheduler.in_flight(scheduler_name)

      refute Map.has_key?(in_flight, unit_id),
             "D-340d: after :merged, unit must be released from Scheduler in_flight"
    end
  end

  # ---------------------------------------------------------------------------
  # C111 — Provenance carries attempt count + last findings for escalated case
  # ---------------------------------------------------------------------------

  describe "C111 — provenance carries attempt_count and last_findings on escalated" do
    @tag :d_340
    @tag :d_318
    test "C111: escalated provenance has attempt_count > 0 and last_findings set" do
      test_pid = self()
      unit_id = "u-prov-#{System.unique_integer([:positive])}"
      scheduler_name = :"sched_prov_#{System.unique_integer([:positive])}"
      sup_name = :"sup_prov_#{System.unique_integer([:positive])}"
      start_scheduler(scheduler_name)
      start_supervised!({@unit_supervisor, name: sup_name}, id: sup_name)

      last_findings = ["finding-alpha", "finding-beta"]

      gate_fun = fn -> {:fail, last_findings} end

      n_refine = Retry.n_refine()
      n_pivot = Retry.n_pivot()

      opts =
        base_unit_opts(unit_id, scheduler_name, test_pid,
          gate_fun: gate_fun,
          merge_fun: fn _uid, _hash -> :queued end,
          timeouts: [state_timeout_ms: 5_000]
        )

      unit_pid = @unit_supervisor.start_unit(sup_name, opts)
      assert is_pid(unit_pid)

      for _i <- 1..(n_refine + n_pivot + 3) do
        deliver_worker_done(unit_pid)
        :timer.sleep(60)
      end

      assert_receive {:unit_terminal, ^unit_id, :escalated, provenance},
                     10_000,
                     "C111: expected :escalated terminal within 10s"

      attempt_count = Map.get(provenance, :attempt_count)

      assert is_integer(attempt_count) and attempt_count > 0,
             "C111: provenance.attempt_count must be a positive integer; got #{inspect(attempt_count)}"

      reported_findings = Map.get(provenance, :last_findings)

      assert reported_findings == last_findings,
             "C111: provenance.last_findings must be #{inspect(last_findings)}; got #{inspect(reported_findings)}"
    end
  end

  # ---------------------------------------------------------------------------
  # D-318 / B8 / C105 — Worker CRASH → infra-failure path → :escalated (fix f-3)
  #
  # SPEC-FACTORY-CORE §4 B8 (line 279): the Unit holds a Process.monitor/1 ref on
  # the worker for liveness. A worker CRASH (abnormal :DOWN) is an infra failure
  # distinct from a stall (:state_timeout) and from a gate {:fail} (C105).
  #
  # The monitorable seam: worker_fun.(role) -> {:ok, pid} where pid is a REAL
  # process (not make_ref()). The Unit monitors it. Killing the pid delivers
  # {:DOWN, monitor_ref, :process, pid, :killed} to the Unit's mailbox.
  # The Unit MUST route to infra-failure → escalated WITHOUT calling gate_fun.
  # ---------------------------------------------------------------------------

  describe "D-318 / B8 / C105 — worker process crash → infra-failure path, gate not called" do
    @tag :d_340
    @tag :d_318
    @tag :b8
    @tag :c105
    test "B8/C105: worker process killed in implementing state → :escalated, gate_fun NOT called" do
      test_pid = self()
      unit_id = "u-crash-#{System.unique_integer([:positive])}"
      scheduler_name = :"sched_crash_#{System.unique_integer([:positive])}"
      sup_name = :"sup_crash_#{System.unique_integer([:positive])}"
      start_scheduler(scheduler_name)
      start_supervised!({@unit_supervisor, name: sup_name}, id: sup_name)

      # The test captures the implementing worker pid so it can kill it.
      # We use a named ETS table owned by this test process.
      ets_name = :"wpid_#{System.unique_integer([:positive])}"
      worker_pid_ets = :ets.new(ets_name, [:set, :public])

      worker_fun = fn role ->
        pid = spawn_worker()
        :ets.insert(worker_pid_ets, {role, pid})
        {:ok, pid}
      end

      # Sentinel: if gate_fun is called, the FSM routed a :DOWN through the
      # semantic gate-fail path — a C105 violation.
      gate_called_ref = :counters.new(1, [:atomics])

      gate_fun = fn ->
        :counters.add(gate_called_ref, 1, 1)
        :pass
      end

      merge_fun = fn _uid, _hash -> :queued end

      opts =
        base_unit_opts(unit_id, scheduler_name, test_pid,
          worker_fun: worker_fun,
          gate_fun: gate_fun,
          merge_fun: merge_fun,
          timeouts: [state_timeout_ms: 5_000]
        )

      unit_pid = @unit_supervisor.start_unit(sup_name, opts)
      assert is_pid(unit_pid)

      # Drive oracle phase to completion; let FSM enter :implementing.
      deliver_worker_done(unit_pid)
      :timer.sleep(80)

      # Verify the FSM is in :implementing with worker_pid exposed in state data.
      # This is the discriminating check for the monitorable seam (B8 / fix f-3):
      # the old seam returned make_ref() (unmonitorable); the new seam returns a pid.
      {fsm_state, state_data} = :sys.get_state(unit_pid)

      assert fsm_state == :implementing,
             "B8: expected FSM in :implementing after oracle delivery; got :#{fsm_state}. " <>
               "Check worker_fun seam and oracle→implementing transition timing."

      worker_pid = Map.get(state_data, :worker_pid)

      assert is_pid(worker_pid),
             "B8 (f-3): Unit FSM in :implementing MUST expose :worker_pid in state data " <>
               "(real pid, not a ref — enables Process.monitor/1); " <>
               "got #{inspect(state_data)}"

      # Kill the worker abnormally. The Unit's Process.monitor/1 ref delivers
      # {:DOWN, monitor_ref, :process, worker_pid, :killed} to the Unit mailbox.
      # The Unit must route this to the infra-failure path, not the gate-fail path.
      Process.exit(worker_pid, :kill)

      assert_receive {:unit_terminal, ^unit_id, :escalated, provenance},
                     5_000,
                     "B8/C105: expected :escalated from worker crash (:DOWN) within 5s"

      reason = Map.get(provenance, :reason)

      refute reason == nil,
             "B8: provenance must carry an escalation reason after worker crash; got nil"

      # C105 (fix f-3): a worker crash is an infra event — gate_fun MUST NOT be called.
      # If gate_fun was called, the FSM treated the :DOWN as a semantic gate failure.
      gate_calls = :counters.get(gate_called_ref, 1)

      assert gate_calls == 0,
             "C105 (f-3): gate_fun must NOT be called for a worker crash (infra-failure path); " <>
               "called #{gate_calls} times — FSM incorrectly treated :DOWN as a gate outcome"

      # Scheduler must release the unit after crash escalation.
      in_flight = @scheduler.in_flight(scheduler_name)

      refute Map.has_key?(in_flight, unit_id),
             "B8: after worker-crash escalation, unit must be released from Scheduler in_flight"

      :ets.delete(worker_pid_ets)
    end
  end
end
