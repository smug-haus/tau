defmodule Tau.Factory.HaltingTerminalArityTest do
  @moduledoc """
  Gating test for PR #476 (#472 — Coordinator `halting/3` 4-arg
  `{:unit_terminal}` handler; SPEC-FACTORY-CORE §5 `:halting`-row drain, D-340).

  The global-escalation drain (#471 / D-320) is the only path that AWAITS a
  `{:unit_terminal, …}` INSIDE the `:halting` state. The real Unit FSM
  (`Tau.Factory.Unit`, `unit.ex:511`, D-340) emits the **4-arg** terminal
  `{:unit_terminal, unit_id, outcome, provenance}` — every terminal state does.
  The `:running` state handles BOTH the 3-arg and 4-arg arities; `:halting`
  handles only the 3-arg form.

  Contract: a 4-arg terminal delivered while the Coordinator is draining
  (`:halting`) MUST drain the in-flight unit to `:halted` — identically to the
  3-arg form — and MUST NOT park.

  ## Fail-before (on current `main`)

  `halting(:info, {:unit_terminal, _unit_id, _outcome}, data)` matches only the
  3-tuple-payload form. A 4-arg `{:unit_terminal, id, outcome, provenance}`
  (a 4-tuple) falls through to the `halting/3` catch-all, which returns
  `{:keep_state, data}` — the drain PARKS FOREVER and `:halted` is never
  reached. The `assert_receive :coordinator_halted` below therefore TIMES OUT
  until `halting` handles the 4-arg arity. This is a genuine fail-before, not a
  compile error: the module under test already exists; the clause does not.

  Drives a real `Tau.Factory.Coordinator` via the same injected seams
  (`select_fun` / `drive_fun`) the #471 drain test and the kill-switch test use,
  so the test exercises the genuine `gen_statem` path — NOT a hand-built struct.

  AC/D-NNN linkage: D-340 (#472).
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log
  @moduletag :d_340

  @coordinator Tau.Factory.Coordinator

  defp unique_name(base) do
    suffix = System.unique_integer([:positive])
    :"#{base}_#{suffix}"
  end

  # Mirrors escalation_drain_test.exs, except the in-flight unit emits the real
  # Unit FSM's 4-ARG terminal (D-340, unit.ex:511), parameterised by the
  # terminal-payload builder. Used for both the 4-arg (gating) and 3-arg
  # (regression) cases below.
  defp drive_global_escalation_to_halted(terminal_msg_fun) do
    coord_name = unique_name(:coord_halt_arity)
    pubsub_name = Tau.PubSub
    test_pid = self()

    work_item = "unit-halt-arity-#{System.unique_integer([:positive])}"
    unit_id = work_item

    {:ok, counter} = Agent.start_link(fn -> 0 end)

    select_fun = fn ->
      n = Agent.get_and_update(counter, fn c -> {c, c + 1} end)
      if n == 0, do: work_item, else: nil
    end

    unit_pids = :ets.new(:halt_arity_unit_pids, [:public, :set])

    drive_fun = fn _work ->
      coord_pid = Process.whereis(coord_name)

      unit_pid =
        spawn(fn ->
          receive do
            :finish ->
              send(coord_pid, terminal_msg_fun.(unit_id))
              send(test_pid, {:unit_finished, unit_id})
          end
        end)

      :ets.insert(unit_pids, {unit_id, unit_pid})
      :ok
    end

    on_halted_pid =
      spawn_link(fn ->
        receive do
          :coordinator_halted -> send(test_pid, :coordinator_halted)
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
    wait_in_flight = fn ->
      Enum.reduce_while(1..200, :not_yet, fn _, _ ->
        case :ets.lookup(unit_pids, unit_id) do
          [{^unit_id, _pid}] -> {:halt, :ok}
          [] -> Process.sleep(10) && {:cont, :not_yet}
        end
      end)
    end

    assert :ok == wait_in_flight.()
    [{^unit_id, unit_pid}] = :ets.lookup(unit_pids, unit_id)
    assert Process.alive?(unit_pid)

    # Deliver a GLOBAL escalation while the unit is in flight → :halting (drain).
    send(coord_name, {:escalate, {:E_UNCLASSIFIED, :global}})

    # Confirm the Coordinator routed to drain and is NOT yet halted (the unit is
    # still in flight). This establishes the drain is genuinely awaiting the
    # in-flight unit's terminal inside :halting.
    Process.sleep(50)
    refute_received :coordinator_halted
    {state_after_esc, _} = :sys.get_state(coord_name)

    assert state_after_esc == :halting,
           "global escalation with an in-flight unit must route to :halting and " <>
             "await the unit terminal; state=#{inspect(state_after_esc)}"

    # Release the unit → it sends its terminal to the Coordinator IN :halting.
    send(unit_pid, :finish)
    assert_receive {:unit_finished, ^unit_id}, 2000

    # THE CRUX: the Coordinator must drain to :halted on receiving the terminal
    # while in :halting. On current `main`, the 4-arg terminal hits the
    # halting/3 catch-all ({:keep_state}) → this NEVER fires → timeout.
    assert_receive :coordinator_halted, 2000

    {final_state, _} = :sys.get_state(coord_name)
    assert final_state == :halted

    :ets.delete(unit_pids)
  end

  # ---------------------------------------------------------------------------
  # D-340 / #472 — the 4-arg terminal (real Unit FSM shape) drains in :halting.
  # This is the FAIL-BEFORE case: halting/3 lacks the 4-arg clause on `main`.
  # ---------------------------------------------------------------------------
  @tag :d_340
  test "D-340 / #472: a 4-arg {:unit_terminal, id, outcome, provenance} drains to :halted in :halting (does not park)" do
    # The exact D-340 shape from unit.ex:511 — a 4-tuple with a provenance map.
    four_arg = fn unit_id ->
      provenance = %{attempt_count: 1, last_findings: nil, reason: nil}
      {:unit_terminal, unit_id, :merged, provenance}
    end

    drive_global_escalation_to_halted(four_arg)
  end

  # ---------------------------------------------------------------------------
  # D-340 / #472 — regression guard: the 3-arg (injected-seam) terminal still
  # drains in :halting. The fix must KEEP the existing 3-arg handler.
  # ---------------------------------------------------------------------------
  @tag :d_340
  test "D-340 / #472: the 3-arg {:unit_terminal, id, outcome} still drains to :halted in :halting" do
    three_arg = fn unit_id -> {:unit_terminal, unit_id, :merged} end

    drive_global_escalation_to_halted(three_arg)
  end
end
