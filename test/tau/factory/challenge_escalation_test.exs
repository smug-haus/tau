defmodule Tau.Factory.ChallengeEscalationTest do
  @moduledoc """
  Gating test for issue #653 — FR-4.4 / E-CHALLENGE:
  challenge protocol reachability and upheld-challenge escalation threshold.

  Invariant (FR-4.4):
    An implementer may challenge a gating test only when it contradicts a SPEC §4
    contract.  Every challenge MUST be adjudicated by an independent critic (never
    the coordinator's own judgement).  When upheld_challenge_count > 2 on a Unit,
    the Unit FSM MUST escalate E-CHALLENGE.

  Contract source:
    docs/arch/04-software-architecture/control-plane.md §3.5 (Challenge protocol):

      def implementing(:info, {:challenge, test, clause}, data) do
        ruling = Tau.Factory.Gate.adjudicate_challenge(test, clause)
        data   = log_challenge(data, test, clause, ruling)
        {:upheld, n} when n + 1 > 2 -> escalate(data, {:challenges_exceeded, data.unit_id})
      end

    SPEC-FACTORY-CORE §6 D-317 / escalation table (line 1266):
      E-CHALLENGE | > 2 upheld challenges on one PR | per-unit

    lib/tau/factory/escalation.ex line 41:
      classify({:challenge, _}) → {:"E-CHALLENGE", :unit}

  GAP confirmed by #653: `{:challenge, _, _}` has NO clause in unit.ex and no
  executable path produces `{:challenge, _}` anywhere in lib/.  The test drives
  the real Unit FSM entry point via three `{:challenge, test, clause}` messages
  delivered while the Unit is in `:implementing` state, and asserts the terminal
  report carries `reason: :E_CHALLENGE` (or the escalation atom the implementer
  chooses — any atom whose `Escalation.classify/1` image is `{:"E-CHALLENGE",
  :unit}` satisfies this contract).

  ## Fail-before

  The test fails because:
    1. `Tau.Factory.Unit.implementing/3` has no clause matching
       `{:challenge, _, _}` — the message is handled by the catch-all
       `handle_unexpected/4` and the unit neither escalates nor tracks count.
    2. There is no `upheld_challenge_count` field in Unit state data.
    3. No `adjudicate_challenge` entrypoint exists in `Tau.Factory.Gate`
       (the arch §3.5 callsite).

  That compile-or-assertion failure IS the correct fail-before state.
  The implementer MUST NOT edit this file.

  AC/D-NNN linkage: FR-4.4 / E-CHALLENGE (#653).
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log
  @moduletag :fr_4_4
  @moduletag :e_challenge

  @unit_supervisor Tau.Factory.UnitSupervisor
  @scheduler Tau.Factory.Scheduler

  # ---------------------------------------------------------------------------
  # Helpers (mirrors unit_termination_test.exs pattern)
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

  # Drive the oracle phase: deliver :worker_done to the current oracle worker.
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

  # Wait until the Unit FSM reaches the given state.
  defp wait_for_state(unit_pid, expected_state, deadline_ms \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms

    Stream.repeatedly(fn ->
      :timer.sleep(20)
      {state, _data} = :sys.get_state(unit_pid)
      state
    end)
    |> Enum.find_value(fn state ->
      if state == expected_state do
        true
      else
        if System.monotonic_time(:millisecond) > deadline,
          do: raise("Timed out waiting for state #{expected_state}; last=#{state}"),
          else: nil
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # FR-4.4 — Three upheld challenges trigger E-CHALLENGE escalation
  # ---------------------------------------------------------------------------

  describe "FR-4.4 / E-CHALLENGE — upheld challenge count > 2 escalates" do
    @tag :fr_4_4
    @tag :e_challenge
    test "FR-4.4: three {:challenge, test, clause} upheld messages while in :implementing escalate with E-CHALLENGE" do
      test_pid = self()
      unit_id = "u-challenge-#{System.unique_integer([:positive])}"
      scheduler_name = :"sched_challenge_#{System.unique_integer([:positive])}"
      sup_name = :"sup_challenge_#{System.unique_integer([:positive])}"

      start_scheduler(scheduler_name)
      start_supervised!({@unit_supervisor, name: sup_name}, id: sup_name)

      # The gate_fun never fires in this test path — the unit escalates on the
      # challenge threshold before it would ever reach :gating.  Gate set to
      # :pass for safety; merge_fun likewise.
      opts =
        base_unit_opts(unit_id, scheduler_name, test_pid,
          gate_fun: fn _coord -> :pass end,
          merge_fun: fn _uid, _hash -> :queued end,
          timeouts: [state_timeout_ms: 5_000]
        )

      unit_pid = @unit_supervisor.start_unit(sup_name, opts)
      assert is_pid(unit_pid), "start_unit must return a pid"

      # Drive oracle phase to completion.
      deliver_worker_done(unit_pid)

      # Wait for the FSM to land in :implementing.
      wait_for_state(unit_pid, :implementing)

      # Deliver 3 upheld challenge messages to the Unit while it is in
      # :implementing state.  The arch contract (control-plane.md §3.5) names
      # the message shape `{:challenge, test, spec_clause}`.  A correct
      # implementation MUST handle this message, adjudicate via an independent
      # critic (NOT coordinator), track upheld_challenge_count, and on the 3rd
      # upheld challenge escalate E-CHALLENGE.
      #
      # FR-4.4: "more than 2 upheld challenges on one PR MUST trigger escalation
      # E-CHALLENGE."  Three upheld challenges ⟹ count > 2 ⟹ must escalate.
      send(unit_pid, {:challenge, "test_some_contract_1", "SPEC §4.1"})
      :timer.sleep(50)
      send(unit_pid, {:challenge, "test_some_contract_2", "SPEC §4.2"})
      :timer.sleep(50)
      send(unit_pid, {:challenge, "test_some_contract_3", "SPEC §4.3"})

      # The Unit must escalate E-CHALLENGE within a generous window.
      # Outcome: {:unit_terminal, unit_id, :escalated, %{reason: escalation_reason}}
      # where Tau.Factory.Escalation.classify/1 maps escalation_reason →
      # {:"E-CHALLENGE", :unit}.
      assert_receive {:unit_terminal, ^unit_id, :escalated, provenance},
                     5_000,
                     "FR-4.4: expected :escalated terminal after 3 upheld challenges within 5s"

      reason = Map.get(provenance, :reason)

      assert reason != nil,
             "FR-4.4: provenance.reason must be set; got #{inspect(provenance)}"

      # Verify the reason classifies to E-CHALLENGE via the authoritative
      # Escalation classifier (escalation.ex line 41: classify({:challenge, _})
      # → {:"E-CHALLENGE", :unit}).  The implementer may encode the reason atom
      # directly or as the trigger term — both forms are acceptable as long as
      # the classifier maps it to E-CHALLENGE.
      {e_class, scope} = Tau.Factory.Escalation.classify(reason)

      assert e_class == :"E-CHALLENGE",
             "FR-4.4: escalation reason #{inspect(reason)} must classify to E-CHALLENGE; got #{inspect(e_class)}"

      assert scope == :unit,
             "FR-4.4: E-CHALLENGE is per-unit scope; got #{inspect(scope)}"

      # Assert the Scheduler released the unit on escalation.
      in_flight = @scheduler.in_flight(scheduler_name)

      refute Map.has_key?(in_flight, unit_id),
             "FR-4.4: after E-CHALLENGE escalation, unit must be released from Scheduler"
    end

    @tag :fr_4_4
    @tag :e_challenge
    test "FR-4.4: two upheld challenges do NOT escalate — threshold is strictly > 2" do
      test_pid = self()
      unit_id = "u-challenge-2-#{System.unique_integer([:positive])}"
      scheduler_name = :"sched_challenge2_#{System.unique_integer([:positive])}"
      sup_name = :"sup_challenge2_#{System.unique_integer([:positive])}"

      start_scheduler(scheduler_name)
      start_supervised!({@unit_supervisor, name: sup_name}, id: sup_name)

      # Implementing worker that stays alive indefinitely so we can observe
      # that two upheld challenges do NOT prematurely escalate.
      # Gate: :pass (so if it ever gates it merges cleanly).
      opts =
        base_unit_opts(unit_id, scheduler_name, test_pid,
          gate_fun: fn _coord -> :pass end,
          merge_fun: fn _uid, _hash -> :queued end,
          timeouts: [state_timeout_ms: 5_000]
        )

      unit_pid = @unit_supervisor.start_unit(sup_name, opts)
      assert is_pid(unit_pid), "start_unit must return a pid"

      # Drive oracle phase.
      deliver_worker_done(unit_pid)

      # Wait for :implementing.
      wait_for_state(unit_pid, :implementing)

      # Two upheld challenges — below the > 2 threshold.
      send(unit_pid, {:challenge, "test_contract_a", "SPEC §4.1"})
      :timer.sleep(50)
      send(unit_pid, {:challenge, "test_contract_b", "SPEC §4.2"})
      :timer.sleep(200)

      # The unit MUST NOT have escalated after only 2 upheld challenges.
      refute_receive {:unit_terminal, ^unit_id, :escalated, _},
                     100,
                     "FR-4.4: two upheld challenges must NOT escalate (threshold is > 2)"

      # Cleanup: allow the implementing worker to finish normally.
      deliver_worker_done(unit_pid)
    end
  end
end
