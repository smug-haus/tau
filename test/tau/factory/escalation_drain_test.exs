defmodule Tau.Factory.EscalationDrainTest do
  @moduledoc """
  Gating test for PR #471 (P5c-5 — #453 / D-320 global-escalation drain).

  Enforces the SPEC-FACTORY-CORE §5 `:halting` contract: the `halting` state
  exists to **drain in-flight units to a clean checkpoint** when entered by a
  global escalation. A global escalation delivered while a unit is in flight
  MUST drain that unit (let it run to its `{:unit_terminal, …}`) BEFORE the
  Coordinator reaches `:halted` — the in-flight unit is NOT abandoned.

  This mirrors the D-321 clean-kill contract (`kill_switch_test.exs`), which
  already drains the in-flight unit at a unit boundary. The global-escalation
  path must observe the same drain-first discipline.

  ## Fail-before (on current `main`)

  The `running(:info, {:escalate, {_e, :global}}, data)` clause currently
  zeroes `in_flight` and drains straight to `:halted` (`{:next_event,
  :internal, :drain}` with `in_flight: nil`), ABANDONING the in-flight unit.
  The unit's `{:unit_terminal, …}` is never awaited, so the
  "unit reached terminal BEFORE :halted" assertion below FAILS until the drain
  is implemented (route through `:halting` and await the in-flight unit's
  terminal).

  Drives a real `Tau.Factory.Coordinator` via the same injected seams
  (`select_fun` / `drive_fun`) the kill-switch test uses, so the test exercises
  the genuine gen_statem path — NOT a hand-built struct.

  AC/D-NNN linkage: D-320 (#453).
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log
  @moduletag :d_320

  @coordinator Tau.Factory.Coordinator

  defp unique_name(base) do
    suffix = System.unique_integer([:positive])
    :"#{base}_#{suffix}"
  end

  # ---------------------------------------------------------------------------
  # D-320 / #453 — global escalation drains the in-flight unit before :halted.
  #
  # Timeline:
  #   1. Start Coordinator; select_fun returns one work item then nil.
  #   2. drive_fun spawns a blocking unit (holds in flight) and records when
  #      it reaches terminal into an external order-log Agent.
  #   3. Deliver a GLOBAL escalation {:escalate, {e, :global}} while the unit
  #      is in flight.
  #   4. Release the unit → it sends {:unit_terminal, …} to the Coordinator and
  #      records :unit_terminal into the order-log; the Coordinator then reaches
  #      :halted and the order-log records :halted (via on_halted).
  #   5. Assert: the in-flight unit reached terminal (NOT abandoned), AND the
  #      :unit_terminal event was recorded BEFORE :halted.
  # ---------------------------------------------------------------------------

  @tag :d_320
  test "D-320 / #453: global escalation drains the in-flight unit (reaches terminal) before :halted" do
    coord_name = unique_name(:coord_drain)
    pubsub_name = Tau.PubSub
    test_pid = self()

    # External order-log: appends event atoms in the order they occur, so we can
    # assert :unit_terminal precedes :halted (drain-first, not abandon).
    {:ok, order_log} = Agent.start_link(fn -> [] end)

    work_item = "unit-drain-#{System.unique_integer([:positive])}"
    unit_id = work_item

    # One work item, then nil.
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    select_fun = fn ->
      n = Agent.get_and_update(counter, fn c -> {c, c + 1} end)
      if n == 0, do: work_item, else: nil
    end

    # Register the unit pid so the test can release it once it is in flight.
    unit_pids = :ets.new(:drain_unit_pids, [:public, :set])

    drive_fun = fn _work ->
      coord_pid = Process.whereis(coord_name)

      unit_pid =
        spawn(fn ->
          receive do
            :finish ->
              # Record that the in-flight unit reached terminal, THEN tell the
              # Coordinator. Drain-first means this MUST be observed before
              # :halted.
              Agent.update(order_log, fn log -> log ++ [:unit_terminal] end)
              send(coord_pid, {:unit_terminal, unit_id, :merged})
              send(test_pid, {:unit_finished, unit_id})
          end
        end)

      :ets.insert(unit_pids, {unit_id, unit_pid})
      :ok
    end

    # on_halted: record :halted into the order-log AND notify the test.
    on_halted_pid =
      spawn_link(fn ->
        receive do
          :coordinator_halted ->
            Agent.update(order_log, fn log -> log ++ [:halted] end)
            send(test_pid, :coordinator_halted)
        end
      end)

    start_supervised!(
      {
        @coordinator,
        name: coord_name,
        pubsub: pubsub_name,
        select_fun: select_fun,
        drive_fun: drive_fun,
        scheduler: nil,
        on_halted: on_halted_pid
      },
      id: coord_name
    )

    # Wait for the unit to be in flight.
    assert_unit_in_flight = fn ->
      Enum.reduce_while(1..100, :not_yet, fn _, _ ->
        case :ets.lookup(unit_pids, unit_id) do
          [{^unit_id, _pid}] -> {:halt, :ok}
          [] -> Process.sleep(10) && {:cont, :not_yet}
        end
      end)
    end

    assert :ok == assert_unit_in_flight.()
    [{^unit_id, unit_pid}] = :ets.lookup(unit_pids, unit_id)
    assert Process.alive?(unit_pid)

    # Deliver a GLOBAL escalation while the unit is in flight.
    send(coord_name, {:escalate, {:E_UNCLASSIFIED, :global}})

    # The drain contract: the Coordinator MUST NOT reach :halted while the unit
    # is still in flight. Give it a moment, then assert the unit is still alive
    # and the Coordinator has not yet halted.
    Process.sleep(50)

    refute_received :coordinator_halted

    {state_after_esc, _} = :sys.get_state(coord_name)

    assert state_after_esc in [:halting, :running],
           "global escalation with an in-flight unit must drain (await terminal), " <>
             "not jump to :halted; state=#{inspect(state_after_esc)}"

    assert Process.alive?(unit_pid),
           "D-320 drain violation: in-flight unit was abandoned by the global escalation"

    # Release the unit so it can reach terminal.
    send(unit_pid, :finish)

    # The in-flight unit MUST run to terminal (not abandoned).
    assert_receive {:unit_finished, ^unit_id}, 2000

    # The Coordinator then reaches :halted.
    assert_receive :coordinator_halted, 2000

    {final_state, _} = :sys.get_state(coord_name)
    assert final_state == :halted

    # The crux: the in-flight unit's terminal was DRAINED (observed) BEFORE the
    # Coordinator reached :halted. On current `main` the global-escalation
    # clause zeroes in_flight and halts straight away, so :halted is recorded
    # without :unit_terminal ever preceding it → this assertion fails.
    order = Agent.get(order_log, & &1)

    assert order == [:unit_terminal, :halted],
           "global escalation must drain the in-flight unit to terminal BEFORE " <>
             ":halted; observed order=#{inspect(order)}"

    :ets.delete(unit_pids)
  end
end
