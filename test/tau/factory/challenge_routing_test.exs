defmodule Tau.Factory.ChallengeRoutingTest do
  @moduledoc """
  Gating test for issue #543 (INV-CHALLENGE-ROUTING).

  Invariant statement (factory-loop.md §Challenge protocol, SPEC-FACTORY-GATE
  §C214-B6):

    An implementer challenge against a gating test MUST be adjudicated by the
    critic (an independent read-only oracle), never by the coordinator's own
    judgement. The Unit FSM MUST capture a `{:challenge, payload}` message
    received while in `:implementing` state and invoke the injected
    `challenge_fun` (the critic-routing seam), NOT drop or self-adjudicate it.

  ## What is tested

  The invariant governs the `Tau.Factory.Unit` gen_statem. When an implementer
  worker sends `{:challenge, payload}` while the Unit is in `:implementing`
  state, the Unit MUST:

    1. Capture the challenge (not silently drop it via the catch-all
       `handle_unexpected`).
    2. Route it to the critic by invoking a `challenge_fun` seam with the
       challenge payload — NOT adjudicate the challenge itself.
    3. After the critic ruling, record the outcome (upheld or rejected) and
       resume normally (rejected → continue; upheld → corrected test path;
       > 2 upheld → escalate E-CHALLENGE).

  ## Evidence of NOT-YET-BUILT

  - `lib/tau/factory/unit.ex` `:implementing/3` has no `{:challenge, _}` clause.
    The catch-all `handle_unexpected` silently discards it (debug-log only).
  - `Tau.Factory.Unit.start_link/1` accepts no `:challenge_fun` option.
  - No unit-facing challenge routing exists anywhere in `lib/tau/factory/`.

  ## Fail-before expectation

  These tests will fail — the Unit does not call challenge_fun (it doesn't exist
  as a seam), so the `assert_receive` for `{:challenge_routed, _}` times out.
  Test 2 likewise never escalates E-CHALLENGE because no challenge accumulation
  logic exists.

  ## INV-CHALLENGE-ROUTING token linkage

  Every test carries the `INV-CHALLENGE-ROUTING` token in its name and/or
  `@tag`, satisfying factory-loop §4b Gate 5.1.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log
  @moduletag :inv_challenge_routing

  @unit_supervisor Tau.Factory.UnitSupervisor
  @scheduler Tau.Factory.Scheduler

  # ---------------------------------------------------------------------------
  # Helpers
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
      after
        30_000 -> :ok
      end
    end)
  end

  # Advance the Unit past oracle so it reaches :implementing.
  defp advance_past_oracle(unit_pid, oracle_worker_id, deadline_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_advance_oracle(unit_pid, oracle_worker_id, deadline)
  end

  defp do_advance_oracle(unit_pid, oracle_worker_id, deadline) do
    case :sys.get_state(unit_pid) do
      {:oracle, _data} ->
        send(unit_pid, {:work_ready, oracle_worker_id, "feat/challenge-test", "abc123"})
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
  # Test 1 — INV-CHALLENGE-ROUTING: challenge_fun seam invoked for each challenge
  #
  # When the implementer worker sends {:challenge, payload} to the Unit FSM in
  # :implementing state, the Unit MUST invoke the injected challenge_fun with
  # the payload. It MUST NOT silently drop the message or adjudicate itself.
  # ---------------------------------------------------------------------------

  describe "INV-CHALLENGE-ROUTING: challenge routed to critic via challenge_fun" do
    @tag :inv_challenge_routing
    test "INV-CHALLENGE-ROUTING — Unit invokes challenge_fun when implementer sends {:challenge, _}" do
      test_pid = self()
      unit_id = "u-challenge-routing-#{System.unique_integer([:positive])}"
      scheduler_name = :"sched_challenge_#{System.unique_integer([:positive])}"
      sup_name = :"sup_challenge_#{System.unique_integer([:positive])}"

      start_scheduler(scheduler_name)
      start_supervised!({@unit_supervisor, name: sup_name}, id: sup_name)

      oracle_worker_id = "w-oracle-#{System.unique_integer([:positive])}"
      impl_worker_id = "w-impl-#{System.unique_integer([:positive])}"

      challenge_payload = %{
        test_name: "some_gating_test",
        spec_clause: "§4 B1 — frozen_paths non-empty"
      }

      challenge_calls = :counters.new(1, [:atomics])

      # challenge_fun is the critic-routing seam: records the call and returns
      # {:rejected, :test_conforms} (the critic rules implementer must comply).
      challenge_fun = fn payload ->
        send(test_pid, {:challenge_routed, payload})
        :counters.add(challenge_calls, 1, 1)
        {:rejected, :test_conforms}
      end

      worker_fun = fn
        :test_author -> {:ok, spawn_worker(), oracle_worker_id}
        :implementer -> {:ok, spawn_worker(), impl_worker_id}
      end

      opts = [
        unit_id: unit_id,
        declared_scope: empty_scope(),
        hash: "hash-#{unit_id}",
        scheduler: scheduler_name,
        report_to: test_pid,
        worker_fun: worker_fun,
        gate_fun: fn _coord -> :pass end,
        merge_fun: fn _uid, _hash -> :queued end,
        # THE SEAM UNDER TEST: challenge_fun must be accepted and invoked.
        challenge_fun: challenge_fun,
        timeouts: [state_timeout_ms: 5_000]
      ]

      unit_pid = @unit_supervisor.start_unit(sup_name, opts)

      :ok = advance_past_oracle(unit_pid, oracle_worker_id)
      assert {:implementing, _data} = wait_for_implementing(unit_pid)

      # Implementer worker delivers a challenge to the Unit FSM.
      send(unit_pid, {:challenge, challenge_payload})

      # FAILS until: Unit.implementing/3 has a {:challenge, payload} clause
      # that calls data.challenge_fun.(payload) and the :challenge_fun opt is
      # stored in data.
      assert_receive {:challenge_routed, ^challenge_payload},
                     1_000,
                     "INV-CHALLENGE-ROUTING: Unit FSM did not invoke challenge_fun — " <>
                       "challenge was silently dropped (handle_unexpected) instead of " <>
                       "being routed to the critic oracle"

      assert :counters.get(challenge_calls, 1) == 1,
             "INV-CHALLENGE-ROUTING: challenge_fun call count was " <>
               "#{:counters.get(challenge_calls, 1)}, expected 1"
    end
  end

  # ---------------------------------------------------------------------------
  # Test 2 — INV-CHALLENGE-ROUTING: > 2 upheld challenges escalates E-CHALLENGE
  #
  # When challenge_fun returns {:upheld, :contradicts_spec} on more than 2
  # challenges for the same unit, the Unit MUST escalate with the E-CHALLENGE
  # class (factory-loop §Safety circuit condition 7; SPEC-FACTORY-GATE §C214-B6;
  # SPEC-FACTORY-CORE §5 E-CHALLENGE table).
  # ---------------------------------------------------------------------------

  describe "INV-CHALLENGE-ROUTING: > 2 upheld challenges escalates E-CHALLENGE" do
    @tag :inv_challenge_routing
    test "INV-CHALLENGE-ROUTING — 3 upheld challenges → unit_terminal escalated E-CHALLENGE" do
      test_pid = self()
      unit_id = "u-challenge-escalate-#{System.unique_integer([:positive])}"
      scheduler_name = :"sched_challenge_esc_#{System.unique_integer([:positive])}"
      sup_name = :"sup_challenge_esc_#{System.unique_integer([:positive])}"

      start_scheduler(scheduler_name)
      start_supervised!({@unit_supervisor, name: sup_name}, id: sup_name)

      oracle_worker_id = "w-oracle-esc-#{System.unique_integer([:positive])}"

      upheld_count = :counters.new(1, [:atomics])

      # challenge_fun always upholds — simulates repeated contradictory challenges.
      challenge_fun = fn _payload ->
        :counters.add(upheld_count, 1, 1)
        {:upheld, :contradicts_spec}
      end

      worker_fun = fn
        :test_author ->
          {:ok, spawn_worker(), oracle_worker_id}

        :implementer ->
          wid = "w-impl-esc-#{System.unique_integer([:positive])}"
          {:ok, spawn_worker(), wid}
      end

      opts = [
        unit_id: unit_id,
        declared_scope: empty_scope(),
        hash: "hash-#{unit_id}",
        scheduler: scheduler_name,
        report_to: test_pid,
        worker_fun: worker_fun,
        gate_fun: fn _coord -> :pass end,
        merge_fun: fn _uid, _hash -> :queued end,
        challenge_fun: challenge_fun,
        timeouts: [state_timeout_ms: 5_000]
      ]

      unit_pid = @unit_supervisor.start_unit(sup_name, opts)

      :ok = advance_past_oracle(unit_pid, oracle_worker_id)
      assert {:implementing, _data} = wait_for_implementing(unit_pid)

      # Deliver 3 upheld challenges — exceeds the > 2 threshold.
      send(unit_pid, {:challenge, %{test_name: "test_1", spec_clause: "§4 B1"}})
      Process.sleep(50)
      send(unit_pid, {:challenge, %{test_name: "test_2", spec_clause: "§4 B2"}})
      Process.sleep(50)
      send(unit_pid, {:challenge, %{test_name: "test_3", spec_clause: "§4 B3"}})

      # FAILS until: challenge routing + escalation-on-upheld-count exist.
      assert_receive {:unit_terminal, ^unit_id, outcome, _provenance},
                     2_000,
                     "INV-CHALLENGE-ROUTING: Unit did not send {:unit_terminal, ...} after 3 upheld challenges"

      # Extract escalation class from whatever shape the outcome takes.
      escalation_class =
        case outcome do
          {:escalated, class} when is_atom(class) ->
            class

          {:escalated, meta} when is_map(meta) ->
            Map.get(meta, :class) || Map.get(meta, :reason)

          _ ->
            nil
        end

      assert escalation_class in [:"E-CHALLENGE", :E_CHALLENGE, "E-CHALLENGE"],
             "INV-CHALLENGE-ROUTING: expected E-CHALLENGE escalation class after 3 upheld " <>
               "challenges, got outcome=#{inspect(outcome)}"
    end
  end
end
