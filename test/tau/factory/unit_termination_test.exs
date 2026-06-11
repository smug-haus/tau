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
    `:worker_fun`     — (role :: atom() -> {:ok, ref :: reference()} | {:error, reason})
                        Called when the FSM needs to spawn a worker for a role.
                        The test controls worker completion: send `{:worker_done, ref}`
                        to the Unit pid to advance oracle→implementing or
                        implementing→gating. The Unit arms a monitor on the returned
                        ref so a `:DOWN` is also handled.
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

  AC/D-NNN linkage: D-340, D-318.
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

  @unit Tau.Factory.Unit
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

  # Build base Unit opts with seam funs injected by the caller.
  # `merge_deliver_pid` is the pid that will receive merge result delivery
  # requests from merge_fun; tests send `{:merge_result, outcome}` to the
  # Unit pid themselves (or via a spawned sender).
  defp base_unit_opts(unit_id, scheduler_name, report_to, overrides) do
    defaults = [
      unit_id: unit_id,
      declared_scope: empty_scope(),
      hash: "hash-#{unit_id}",
      scheduler: scheduler_name,
      report_to: report_to,
      # Default seams (overridden per test):
      worker_fun: fn _role -> {:ok, make_ref()} end,
      gate_fun: fn -> :pass end,
      merge_fun: fn _uid, _hash -> :queued end,
      timeouts: [state_timeout_ms: 5_000]
    ]

    Keyword.merge(defaults, overrides)
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

      # worker_fun: capture the Unit pid so we can deliver worker_done and merge_result.
      # The Unit process registers in UnitRegistry; we hold the pid from start_unit.
      worker_fun = fn _role ->
        ref = make_ref()
        # Spawn a process to deliver :worker_done after a brief yield.
        # The sender needs the Unit pid; we delay slightly to let start_unit return.
        Process.send_after(self(), {:_worker_ref_capture, ref}, 1)
        {:ok, ref}
      end

      merge_fun = fn _uid, _hash -> :queued end

      gate_fun = fn -> :pass end

      opts =
        base_unit_opts(unit_id, scheduler_name, test_pid,
          worker_fun: worker_fun,
          gate_fun: gate_fun,
          merge_fun: merge_fun,
          timeouts: [state_timeout_ms: 5_000]
        )

      # Unit start triggers: planned → (Scheduler.admit) → oracle → worker_fun call.
      unit_pid = @unit_supervisor.start_unit(sup_name, opts)
      assert is_pid(unit_pid), "start_unit must return a pid"

      # Drive oracle phase: deliver worker_done for the oracle worker.
      # The Unit should be waiting in oracle state with a ref from worker_fun.
      # We ask the Unit for its current worker ref via sys.get_state, then send done.
      # Allow up to 500 ms for the FSM to reach oracle and call worker_fun.
      :timer.sleep(50)
      {state_name, state_data} = :sys.get_state(unit_pid)

      assert state_name in [:oracle, :implementing],
             "After start, Unit must be in oracle or implementing; got #{inspect(state_name)}"

      # Deliver worker_done for oracle (or implementing, same message shape).
      # We extract the ref from state_data — implementer exposes :worker_ref key.
      worker_ref = Map.get(state_data, :worker_ref) || Map.get(state_data, :current_worker_ref)

      if worker_ref do
        send(unit_pid, {:worker_done, worker_ref})
      else
        # Fallback: send a synthetic done — the FSM handles unknown refs gracefully.
        send(unit_pid, {:worker_done, make_ref()})
      end

      # Allow FSM to advance to implementing if it was in oracle.
      :timer.sleep(50)

      {state_name2, state_data2} = :sys.get_state(unit_pid)

      if state_name2 == :implementing do
        impl_ref = Map.get(state_data2, :worker_ref) || Map.get(state_data2, :current_worker_ref)

        if impl_ref do
          send(unit_pid, {:worker_done, impl_ref})
        end
      end

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
  # D-340b / D-318 — Gate-fail ladder → escalated, bounded attempt count
  # ---------------------------------------------------------------------------

  describe "D-340b / D-318 — gate-fail ladder exhausts to :escalated within attempt bound" do
    @tag :d_340
    @tag :d_318
    test "D-340b / D-318: gate always fails → :escalated with E-RETRY-EXHAUSTED, attempts ≤ N_refine + N_pivot" do
      test_pid = self()
      unit_id = "u-ladder-#{System.unique_integer([:positive])}"
      scheduler_name = :"sched_ladder_#{System.unique_integer([:positive])}"
      sup_name = :"sup_ladder_#{System.unique_integer([:positive])}"
      start_scheduler(scheduler_name)
      start_supervised!({@unit_supervisor, name: sup_name}, id: sup_name)

      # Count gate invocations so we can bound them.
      gate_count_ref = :counters.new(1, [:atomics])

      worker_fun = fn _role -> {:ok, make_ref()} end

      # Always-fail gate: records each invocation.
      gate_fun = fn ->
        :counters.add(gate_count_ref, 1, 1)
        {:fail, ["finding-#{:counters.get(gate_count_ref, 1)}"]}
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

      # Drive each implementing phase by delivering worker_done whenever the
      # FSM reaches implementing. The FSM will enter gating, fail, re-enter
      # implementing, etc. We poll and deliver up to max_attempts+2 times.
      n_refine = Retry.n_refine()
      n_pivot = Retry.n_pivot()
      max_attempts = n_refine + n_pivot

      # Deliver worker_done up to max_attempts + 2 times to cover each cycle.
      # Each delivery either finishes oracle, implementing, or a refine re-attempt.
      for _i <- 1..(max_attempts + 4) do
        :timer.sleep(60)

        case :sys.get_state(unit_pid) do
          {state, data} when state in [:oracle, :implementing] ->
            ref = Map.get(data, :worker_ref) || Map.get(data, :current_worker_ref)
            if ref, do: send(unit_pid, {:worker_done, ref})

          _ ->
            :ok
        end
      end

      assert_receive {:unit_terminal, ^unit_id, :escalated, provenance},
                     10_000,
                     "D-340b / D-318: expected {:unit_terminal, _, :escalated, _} within 10s"

      # Provenance must carry the escalation reason.
      reason = Map.get(provenance, :reason)

      assert reason == :E_RETRY_EXHAUSTED,
             "D-318: escalated provenance must carry :E_RETRY_EXHAUSTED; got #{inspect(reason)}"

      # Gate must not have been called more than N_refine + N_pivot times (D-318).
      gate_calls = :counters.get(gate_count_ref, 1)

      assert gate_calls <= max_attempts,
             "D-318: gate called #{gate_calls} times; must be ≤ #{max_attempts} (N_refine=#{n_refine} + N_pivot=#{n_pivot})"

      # Scheduler must have released the unit.
      in_flight = @scheduler.in_flight(scheduler_name)

      refute Map.has_key?(in_flight, unit_id),
             "D-340b: after :escalated, unit must be released from Scheduler in_flight"
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

      # gate_fun is a sentinel: if called, the FSM confused semantic failure with
      # infra stall. We record any call so the test can assert it was NOT called
      # as the stall termination path.
      gate_called_ref = :counters.new(1, [:atomics])

      # worker_fun returns a ref but the corresponding :worker_done is NEVER sent.
      # The Unit must arm a :state_timeout and escalate on timeout.
      worker_fun = fn _role -> {:ok, make_ref()} end

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
          # Very short timeout so the stall path is fast.
          timeouts: [state_timeout_ms: 80]
        )

      unit_pid = @unit_supervisor.start_unit(sup_name, opts)
      assert is_pid(unit_pid)

      # Do NOT send any :worker_done. The FSM must timeout on its own.
      assert_receive {:unit_terminal, ^unit_id, :escalated, provenance},
                     5_000,
                     "D-340c / C107: expected :escalated from :state_timeout within 5s"

      # The provenance reason must be infrastructure-stall-derived, not the
      # gate-fail derived :E_RETRY_EXHAUSTED.
      reason = Map.get(provenance, :reason)

      refute reason == nil,
             "D-340c: provenance must carry a reason; got nil"

      # C105 / C107: stall path is NOT the same as semantic gate fail.
      # Gate should not have been called on a stall-only path.
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

      # gate_fun always passes so we can focus on the re-gate edge.
      gate_fun = fn -> :pass end

      # merge_fun: the test drives outcomes by sending {:merge_result, _} to
      # the unit pid after the merge_fun is called. merge_fun itself just returns :queued.
      merge_fun = fn _uid, _hash -> :queued end

      worker_fun = fn _role -> {:ok, make_ref()} end

      opts =
        base_unit_opts(unit_id, scheduler_name, test_pid,
          worker_fun: worker_fun,
          gate_fun: gate_fun,
          merge_fun: merge_fun,
          timeouts: [state_timeout_ms: 5_000]
        )

      unit_pid = @unit_supervisor.start_unit(sup_name, opts)
      assert is_pid(unit_pid)

      # Helper: deliver worker_done for whichever worker the FSM is waiting on.
      deliver_worker_done = fn ->
        :timer.sleep(50)

        case :sys.get_state(unit_pid) do
          {state, data} when state in [:oracle, :implementing] ->
            ref = Map.get(data, :worker_ref) || Map.get(data, :current_worker_ref)
            if ref, do: send(unit_pid, {:worker_done, ref})

          _ ->
            :ok
        end
      end

      # Advance through oracle and implementing.
      deliver_worker_done.()
      :timer.sleep(50)
      deliver_worker_done.()

      # Allow FSM to reach awaiting_merge (gate :pass → awaiting_merge).
      :timer.sleep(100)

      # First merge result: :rejected → FSM must re-enter gating (INV-2).
      send(unit_pid, {:merge_result, :rejected})

      # Allow FSM to re-gate and re-enter awaiting_merge.
      # gate_fun returns :pass again, so FSM should reach awaiting_merge a second time.
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

      worker_fun = fn _role -> {:ok, make_ref()} end

      opts =
        base_unit_opts(unit_id, scheduler_name, test_pid,
          worker_fun: worker_fun,
          gate_fun: gate_fun,
          merge_fun: fn _uid, _hash -> :queued end,
          timeouts: [state_timeout_ms: 5_000]
        )

      unit_pid = @unit_supervisor.start_unit(sup_name, opts)
      assert is_pid(unit_pid)

      n_refine = Retry.n_refine()
      n_pivot = Retry.n_pivot()

      for _i <- 1..(n_refine + n_pivot + 4) do
        :timer.sleep(60)

        case :sys.get_state(unit_pid) do
          {state, data} when state in [:oracle, :implementing] ->
            ref = Map.get(data, :worker_ref) || Map.get(data, :current_worker_ref)
            if ref, do: send(unit_pid, {:worker_done, ref})

          _ ->
            :ok
        end
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
end
