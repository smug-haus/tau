defmodule Tau.Factory.UnitInvLiveCp1GatingTimeoutTest do
  @moduledoc """
  Gating test for issue #631 — INV-LIVE-CP-1 (liveness — Unit-FSM, high severity).

  ## Invariant under test

  **INV-LIVE-CP-1** (liveness — Unit-FSM):

  > Every U state that awaits an external actor (oracle, implementing, gating,
  > awaiting_merge) arms a per-state timeout on entry. In worker-awaiting states
  > (oracle, implementing), the timeout is reset by each current-worker heartbeat.
  > Combined with the worker watchdog (D-379), every reachable non-progress state
  > eventually produces a trigger within a bounded window. Falsified if any
  > awaiting state has no state_timeout armed, or if a wedged worker can remain
  > undetected indefinitely.

  ## Violation

  The audit (confirmed by independent review) found that the `gating` state's
  `:on_enter` callback (unit.ex ~line 686) returns:

      {:keep_state, %{data | gate_task_ref: task.ref}}

  with **no** `{:state_timeout, timeout_ms, :gate_stalled}` action. The three
  other awaiting states — oracle, implementing, awaiting_merge — all arm a
  per-state timeout on entry. The gating state does not. If the gate Task never
  delivers a `{:gate_result, _}` (e.g. the CI runner crashes, the network hangs,
  or the gate binary deadlocks), the Unit remains stuck in `:gating` indefinitely
  and never escalates.

  The arch reference (docs/arch/04-software-architecture/control-plane.md, lines
  558-564) documents the conformant behaviour:

      # Non-worker waiting states keep the gate/merge-stall semantics unchanged.
      def gating(:state_timeout, :stall, data), do: stall_escalate(data, :gating)
      def awaiting_merge(:state_timeout, :stall, data), do: stall_escalate(data, :awaiting_merge)

      # Each waiting state arms the timeout on entry; progress heartbeats reset it.
      defp enter_waiting(state, ms, data),
        do: {:next_state, state, data, [{:state_timeout, ms, :stall}]}

  The conformant `gating(:internal, :on_enter, data)` MUST arm
  `{:state_timeout, timeout_ms, :gate_stalled}` (or the `:stall` form used in
  the arch doc) before returning, so that a permanently-wedged gate Task cannot
  strand the Unit forever.

  ## Test design

  The test injects a `gate_fun` that never returns — it blocks in
  `receive do :never -> :ok end` (a Task spawned by the real FSM's on_enter —
  so the Task also blocks forever). The `state_timeout_ms` is set to
  `@gating_timeout_ms` (a short wall-clock value that is still comfortably
  longer than scheduling jitter). After triggering the
  `:implementing -> :gating` transition the test waits for
  `@gating_timeout_ms + @buffer_ms` and asserts:

    1. The Unit emits `{:unit_terminal, unit_id, :escalated, _provenance}` within
       the deadline — confirming the state_timeout fired and was routed to
       escalation.

    2. The Unit is released from the Scheduler's in-flight map — confirming the
       terminal path completes end-to-end.

  Under the CURRENT production code (no state_timeout armed in gating on_enter),
  the gen_statem never receives a `:state_timeout` event in the gating state.
  The gate Task blocks forever, no `{:gate_result, _}` ever arrives, and the Unit
  stays in `:gating` without escalating. The `assert_receive` at assertion 1
  therefore TIMES OUT — that is the expected fail-before.

  Under the CONFORMANT code, `gating(:internal, :on_enter, data)` includes
  `{:state_timeout, timeout_ms, :gate_stalled}` in its actions (alongside the
  Task spawn), the timeout fires after `@gating_timeout_ms`, the handler escalates
  the Unit, and the `assert_receive` succeeds.

  ## Entry path

  Real entry path: `Tau.Factory.UnitSupervisor.start_unit/2` ->
  `Tau.Factory.Unit` (gen_statem). No hand-built struct; no injected seam that
  bypasses the real FSM.

  ## INV-LIVE-CP-1 linkage (Gate 5.1)

  Every test in this file carries `@tag :inv_live_cp_1` so the AC-linkage gate
  can verify coverage of `INV-LIVE-CP-1`.
  """

  # async: false — this test measures wall-clock escalation timing from a
  # per-state timeout. Under full-suite concurrency, BEAM scheduler pressure
  # could delay the state_timeout event beyond the assert_receive deadline,
  # producing false positives. Serialize to eliminate scheduler starvation
  # as a confound.
  use ExUnit.Case, async: false

  @moduletag :capture_log
  @moduletag :inv_live_cp_1

  alias Tau.Factory.Scheduler
  alias Tau.Factory.UnitSupervisor

  # How long the gating state_timeout is set to. Short enough that the test
  # does not take long; long enough that scheduling jitter does not fire it
  # spuriously during normal fast gate execution.
  @gating_timeout_ms 300

  # Extra buffer on top of @gating_timeout_ms for the assert_receive deadline.
  # Accounts for scheduling jitter and message delivery latency.
  @buffer_ms 1_500

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique(base), do: :"#{base}_#{System.unique_integer([:positive])}"

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
    start_supervised!({Scheduler, name: name, w_cap: 10}, id: name)
  end

  defp spawn_idle_worker do
    # A worker that stays alive until asked to stop, so the FSM
    # can monitor it without a premature :DOWN.
    spawn(fn ->
      receive do
        :stop -> :ok
      after
        30_000 -> :ok
      end
    end)
  end

  # Drive the Unit through the oracle state using the legacy 2-tuple seam:
  # worker_fun returns {:ok, pid}; we deliver {:worker_done, pid}.
  defp drive_oracle_done(unit_pid) do
    :timer.sleep(60)

    case :sys.get_state(unit_pid) do
      {:oracle, data} ->
        worker_pid = Map.get(data, :worker_pid)
        if is_pid(worker_pid), do: send(unit_pid, {:worker_done, worker_pid})

      _ ->
        :ok
    end

    :timer.sleep(60)
  end

  # Poll until unit reaches target_state (max_ms wall-clock deadline).
  defp wait_for_state(unit_pid, target_state, max_ms \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + max_ms

    Stream.repeatedly(fn ->
      case :sys.get_state(unit_pid) do
        {^target_state, _data} -> :reached
        _ -> :not_yet
      end
    end)
    |> Enum.find_value(fn
      :reached ->
        true

      :not_yet ->
        if System.monotonic_time(:millisecond) < deadline do
          :timer.sleep(20)
          nil
        else
          false
        end
    end)
  end

  # ---------------------------------------------------------------------------
  # INV-LIVE-CP-1 — gating state MUST arm a per-state timeout on entry
  # ---------------------------------------------------------------------------

  describe "INV-LIVE-CP-1 — Unit.gating state MUST arm a per-state timeout on entry" do
    @tag :inv_live_cp_1
    test "INV-LIVE-CP-1: unit escalates within state_timeout_ms when gate_fun never delivers a result" do
      test_pid = self()
      unit_id = "u-gating-timeout-#{System.unique_integer([:positive])}"
      sched = unique(:sched_inv_live_cp_1)
      sup = unique(:sup_inv_live_cp_1)
      start_scheduler(sched)
      start_supervised!({UnitSupervisor, name: sup}, id: sup)

      # Agent to capture the 3-tuple worker_id set by the implementing worker_fun.
      {:ok, worker_id_store} = Agent.start_link(fn -> nil end)
      on_exit(fn -> if Process.alive?(worker_id_store), do: Agent.stop(worker_id_store) end)

      # worker_fun:
      #   :test_author role (oracle state) — legacy 2-tuple seam so drive_oracle_done
      #     can advance through oracle via {:worker_done, pid}.
      #   :implementer role (implementing state) — 3-tuple seam so we can trigger
      #     the :implementing -> :gating transition via {:work_ready, worker_id, _, _}.
      worker_fun = fn role ->
        worker_pid = spawn_idle_worker()

        case role do
          :test_author ->
            {:ok, worker_pid}

          :implementer ->
            worker_id = "wid-live-cp-1-#{System.unique_integer([:positive])}"
            Agent.update(worker_id_store, fn _ -> worker_id end)
            {:ok, worker_pid, worker_id}
        end
      end

      # gate_fun: blocks forever — models a wedged CI runner / deadlocked gate binary.
      # The Task spawned by gating(:internal, :on_enter) will block in this receive,
      # so {:gate_result, _} is NEVER delivered to the FSM mailbox.
      # Only a per-state timeout armed in on_enter can rescue the Unit from this state.
      gate_fun = fn _coord ->
        # Signal the test process that the gate_fun has been entered (Task is running).
        send(test_pid, :gate_entered)
        # Block forever — Task never returns, {:gate_result, _} never fires.
        receive do
          :never_happens -> :ok
        after
          # Bounded to prevent process leak if test exits cleanly.
          60_000 -> {:fail, []}
        end
      end

      merge_fun = fn uid, _hash ->
        Phoenix.PubSub.broadcast(Tau.PubSub, "factory:pr:#{uid}", {:merge_result, :merged})
        :queued
      end

      opts = [
        unit_id: unit_id,
        declared_scope: empty_scope(),
        hash: "hash-live-cp-1-#{System.unique_integer([:positive])}",
        scheduler: sched,
        report_to: test_pid,
        pubsub: Tau.PubSub,
        worker_fun: worker_fun,
        gate_fun: gate_fun,
        merge_fun: merge_fun,
        timeouts: [state_timeout_ms: @gating_timeout_ms]
      ]

      unit_pid = UnitSupervisor.start_unit(sup, opts)

      assert is_pid(unit_pid),
             "INV-LIVE-CP-1: UnitSupervisor.start_unit/2 must return a pid"

      # Advance through oracle phase (legacy 2-tuple seam).
      drive_oracle_done(unit_pid)

      assert wait_for_state(unit_pid, :implementing),
             "INV-LIVE-CP-1: unit must reach :implementing after oracle completes"

      # Trigger :implementing -> :gating transition via {:work_ready, worker_id, _, _}.
      worker_id = Agent.get(worker_id_store, & &1)
      refute is_nil(worker_id), "INV-LIVE-CP-1: worker_id must be set by 3-tuple worker_fun"

      branch = "feat/inv-live-cp-1-branch"
      head_sha = "sha-live-cp-1-#{System.unique_integer([:positive])}"
      send(unit_pid, {:work_ready, worker_id, branch, head_sha})

      # Confirm the gate_fun was actually entered — the Unit reached :gating and
      # the Task started running. Without this confirmation the test would pass
      # vacuously if the transition never happened.
      assert_receive :gate_entered,
                     3_000,
                     "INV-LIVE-CP-1: gate_fun must be invoked after {:work_ready, ...} — " <>
                       "the Unit did not enter the :gating state within 3 s"

      # Core assertion: the Unit MUST escalate within state_timeout_ms + buffer.
      #
      # CONFORMANT behaviour: gating(:internal, :on_enter) arms
      # {:state_timeout, state_timeout_ms, :gate_stalled} alongside the Task spawn.
      # After @gating_timeout_ms ms the state_timeout fires, the handler escalates
      # the Unit, and {:unit_terminal, unit_id, :escalated, _} is broadcast to
      # report_to (test_pid).
      #
      # CURRENT PRODUCTION CODE (violated): gating(:internal, :on_enter) returns
      # {:keep_state, %{data | gate_task_ref: task.ref}} with NO state_timeout action.
      # The gen_statem never receives a :state_timeout event in the :gating state.
      # The Unit stays in :gating forever. This assert_receive TIMES OUT — that is
      # the expected fail-before confirming the test is red.
      assert_receive {:unit_terminal, ^unit_id, :escalated, provenance},
                     @gating_timeout_ms + @buffer_ms,
                     "INV-LIVE-CP-1: unit did NOT escalate within #{@gating_timeout_ms + @buffer_ms} ms " <>
                       "after entering :gating with a gate_fun that never delivers {:gate_result, _}. " <>
                       "Root cause: gating(:internal, :on_enter, data) does not arm " <>
                       "{:state_timeout, timeout_ms, :gate_stalled} — the gating state has NO " <>
                       "bounded liveness guarantee when the gate Task hangs. " <>
                       "Fix: add [{:state_timeout, data.state_timeout_ms, :gate_stalled}] to the " <>
                       "actions returned by gating(:internal, :on_enter, data), and add a handler " <>
                       "def gating(:state_timeout, :gate_stalled, data) that escalates the unit."

      assert is_map(provenance),
             "INV-LIVE-CP-1: escalated provenance must be a map; got #{inspect(provenance)}"

      reason = Map.get(provenance, :reason)

      assert reason != nil,
             "INV-LIVE-CP-1: escalated provenance must carry a :reason key; got nil — " <>
               "the FSM must name the escalation cause (e.g. :E_GATE_STALLED)"

      # Confirm the Unit was released from the Scheduler's in-flight map.
      in_flight = Scheduler.in_flight(sched)

      refute Map.has_key?(in_flight, unit_id),
             "INV-LIVE-CP-1: after escalation, unit_id must be released from " <>
               "Scheduler in_flight; still present: #{inspect(Map.get(in_flight, unit_id))}"
    end
  end
end
