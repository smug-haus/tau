defmodule Tau.Factory.UnitD340LivenessTest do
  @moduledoc """
  Gating test for issue #624 — D-340 / LIV-1 merge-reject cycle liveness.

  Invariant (D-340 / LIV-1): every accepted unit MUST eventually reach a
  terminal state (◇ terminal). Falsified by an infinite
  gating → awaiting_merge → gating cycle when merge_fun always delivers
  :rejected faster than the awaiting_merge :state_timeout fires.

  The conformant FSM MUST track the number of consecutive merge rejections and
  escalate (E_MERGE_REJECT_EXCEEDED or equivalent) after a bounded count,
  regardless of how quickly :rejected arrives relative to the :state_timeout.
  Without a rejection counter the SPEC-FACTORY-CORE D-340 liveness guarantee
  is vacuous on this path.

  This test exercises the invariant at the real entry point
  (Tau.Factory.UnitSupervisor.start_unit/2 → Tau.Factory.Unit gen_statem) with
  a merge_fun that delivers :rejected synchronously on every awaiting_merge
  entry — before any :state_timeout can fire — and a generous state_timeout_ms
  so the state_timeout cannot rescue us.  The conformant FSM MUST eventually
  reach :escalated; the current production code loops without bound.

  AC/D-NNN linkage: D-340, LIV-1.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log
  @moduletag :d_340
  @moduletag :liveness

  @unit_supervisor Tau.Factory.UnitSupervisor
  @scheduler Tau.Factory.Scheduler

  # ---------------------------------------------------------------------------
  # Helpers (minimal, self-contained)
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
  # D-340e / LIV-1 — perpetual merge rejection must escalate (bounded cycle)
  # ---------------------------------------------------------------------------

  describe "D-340e / LIV-1 — perpetual merge rejection escalates (bounded re-gate cycle)" do
    @tag :d_340
    @tag :liveness
    test "D-340e / LIV-1: merge_fun always rejects -> unit escalates within bounded re-gates, not a cycle" do
      test_pid = self()
      unit_id = "u-inf-rejet-#{System.unique_integer([:positive])}"
      scheduler_name = :"sched_inf_rejet_#{System.unique_integer([:positive])}"
      sup_name = :"sup_inf_rejet_#{System.unique_integer([:positive])}"
      start_scheduler(scheduler_name)
      start_supervised!({@unit_supervisor, name: sup_name}, id: sup_name)

      # gate_fun always passes — the only progress-stopper is perpetual merge rejection.
      gate_fun = fn _coord -> :pass end

      # merge_fun notifies the test process so we can deliver :rejected synchronously,
      # before any :state_timeout fires.  This is the adversarial scenario:
      # D-340 liveness is discharged by "state_timeout will eventually fire" only if
      # :rejected does NOT arrive first.  With a 5 s state_timeout and a sub-1 ms
      # :rejected delivery the state_timeout NEVER fires — the FSM exits
      # awaiting_merge on every cycle before the timeout can.
      # The conformant fix: track merge_reject_count and escalate after N_MERGE_REJECT.
      merge_fun = fn _uid, _hash ->
        send(test_pid, :merge_fun_called)
        :queued
      end

      # Generous state_timeout — ensures the state_timeout alone cannot rescue us;
      # only a rejection counter constitutes a real fix.
      opts =
        base_unit_opts(unit_id, scheduler_name, test_pid,
          gate_fun: gate_fun,
          merge_fun: merge_fun,
          timeouts: [state_timeout_ms: 5_000]
        )

      unit_pid = @unit_supervisor.start_unit(sup_name, opts)
      assert is_pid(unit_pid)

      # Advance through oracle and implementing phases.
      deliver_worker_done(unit_pid)
      :timer.sleep(50)
      deliver_worker_done(unit_pid)

      # Pump :rejected into awaiting_merge on every merge_fun call.
      # Each :merge_fun_called notification means the FSM entered awaiting_merge
      # and called merge_fun; we immediately deliver :rejected.
      # Cap at 10 iterations — far more than any sane N_MERGE_REJECT bound —
      # to prevent hanging the test suite when the FSM loops indefinitely
      # (the assert_receive below is the definitive failure detector).
      Enum.each(1..10, fn _i ->
        receive do
          :merge_fun_called ->
            send(unit_pid, {:merge_result, :rejected})
        after
          # If merge_fun is not called within 500 ms the FSM has already
          # reached a terminal state (the assert_receive below catches it)
          # or is stuck waiting for something else.
          500 -> :ok
        end
      end)

      # CONFORMANT behaviour (D-340 / LIV-1): repeated :rejected responses MUST
      # cause escalation.  The unit MUST reach :escalated, not loop indefinitely.
      #
      # Against the current production code this assert_receive WILL TIMEOUT:
      # the FSM has no merge_reject_count and cycles gating -> awaiting_merge
      # without bound, never emitting {:unit_terminal, _, :escalated, _}.
      # That timeout IS the expected failure mode for this gating test.
      assert_receive {:unit_terminal, ^unit_id, :escalated, provenance},
                     3_000,
                     "D-340e / LIV-1: unit must escalate after repeated merge rejections " <>
                       "(liveness #624); infinite gating->awaiting_merge cycle detected -- " <>
                       "no {:unit_terminal, _, :escalated, _} received within 3 s. " <>
                       "Fix: add merge_reject_count to unit data; escalate E_MERGE_REJECT_EXCEEDED " <>
                       "after N_MERGE_REJECT consecutive rejections."

      assert is_map(provenance),
             "D-340e: provenance must be a map; got #{inspect(provenance)}"

      reason = Map.get(provenance, :reason)

      assert reason != nil,
             "D-340e: escalated provenance must carry a :reason; " <>
               "got nil -- the FSM must name why it escalated " <>
               "(e.g. :E_MERGE_REJECT_EXCEEDED)"

      in_flight = @scheduler.in_flight(scheduler_name)

      refute Map.has_key?(in_flight, unit_id),
             "D-340e: after escalation from repeated rejections, " <>
               "unit must be released from Scheduler in_flight"
    end
  end
end
