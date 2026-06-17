defmodule Tau.Factory.CoordinatorLivenessAmbiguityTest do
  @moduledoc """
  Gating test for issue #615 / invariant LIVE-liveness-3.

  Enforces: **E-AMBIGUITY escalation fires for any irreducible spec/product
  ambiguity requiring human judgement.**

  ## What LIVE-liveness-3 states (liveness.md §E-AMBIGUITY)

      E-AMBIGUITY: Irreducible spec/product ambiguity needing human judgement.
      On every escalation: halt the affected scope (per-unit for E-AMBIGUITY),
      write reason + state snapshot to the durable store (CON-7), and notify
      the operator.

  The documented mechanism (control-plane.md §1.3) shows that `select_fun`
  signals ambiguity by returning `{:ambiguity, reason}` instead of a real
  work item or `nil`. The Coordinator's `running(:internal, :loop, data)` is
  the boundary where this must be detected and routed to E-AMBIGUITY escalation,
  not silently treated as a work item and driven.

  ## Current defect (fail-before state)

  `running(:internal, :loop, data)` (coordinator.ex ~line 191) only matches:

      nil  -> milestone/idle (correct)
      work -> drive_unit(data, work, ...) (WRONG for {:ambiguity, _})

  There is no clause that matches `{:ambiguity, _}` to emit
  `{:escalate, {:"E-AMBIGUITY", :unit}}`. The `{:ambiguity, reason}` value
  falls into the `work` branch and `drive_fun` is called with it as if it were
  a real work item -- the ambiguity is silently absorbed.

  Additionally, `Escalation.classify/1` has no production caller that detects
  or originates an ambiguity trigger from `select_fun` output -- the classifier
  is dead routing code for this path.

  ## What conformance requires

  When `select_fun.()` returns `{:ambiguity, reason}`:

    1. The Coordinator MUST broadcast `{:escalation, %{reason: :"E-AMBIGUITY",
       scope: :unit, ...}}` to `"factory:escalation"` -- operator notification.
    2. `drive_fun` MUST NOT be called with the ambiguity tuple as a work item.
    3. E-AMBIGUITY is per-unit scope: the Coordinator MUST remain in `:running`
       state (loop continues -- not a global halt).

  ## Entry point

  Tests exercise the REAL `Tau.Factory.Coordinator.start_link/1` (gen_statem)
  started via `start_supervised!/1`. `select_fun` is configured to return
  `{:ambiguity, reason}` -- the documented ambiguity signal -- and the
  observable outcome is the PubSub broadcast on `"factory:escalation"` and the
  non-invocation of `drive_fun`.

  AC/D-NNN linkage: LIVE-liveness-3, #615.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log
  @moduletag :liveness_3

  @coordinator Tau.Factory.Coordinator

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique_name(base) do
    suffix = System.unique_integer([:positive, :monotonic])
    :"#{base}_#{suffix}"
  end

  # Start a Coordinator whose select_fun returns {:ambiguity, reason}, then nil.
  # drive_fun records any calls so we can assert it was NOT called with the
  # ambiguity tuple.
  defp start_coordinator_with_ambiguity(reason) do
    name = unique_name(:coord_liveness_3)
    test_pid = self()

    :ok = Phoenix.PubSub.subscribe(Tau.PubSub, "factory:escalation")

    # Track drive_fun calls; drive_fun MUST NOT be called with the ambiguity tuple.
    {:ok, drive_calls} = Agent.start_link(fn -> [] end)

    # select_fun: first call returns {:ambiguity, reason}, subsequent calls return nil.
    {:ok, call_counter} = Agent.start_link(fn -> 0 end)

    select_fun = fn ->
      n = Agent.get_and_update(call_counter, fn c -> {c, c + 1} end)
      if n == 0, do: {:ambiguity, reason}, else: nil
    end

    drive_fun = fn work_item ->
      Agent.update(drive_calls, fn calls -> [work_item | calls] end)
      send(test_pid, {:drive_fun_called, work_item})
      :ok
    end

    _pid =
      start_supervised!(
        {@coordinator,
         name: name,
         pubsub: Tau.PubSub,
         select_fun: select_fun,
         drive_fun: drive_fun,
         scheduler: nil,
         on_halted: nil,
         ledger: nil}
      )

    {name, drive_calls}
  end

  # Poll until the Coordinator is in :running state.
  defp wait_for_running(name) do
    Enum.reduce_while(1..200, nil, fn _, _ ->
      case Process.whereis(name) do
        nil ->
          Process.sleep(5)
          {:cont, nil}

        pid ->
          case :sys.get_state(pid, 500) do
            {:running, _data} ->
              {:halt, pid}

            _ ->
              Process.sleep(5)
              {:cont, nil}
          end
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # LIVE-liveness-3 -- select_fun returning {:ambiguity, _} must fire E-AMBIGUITY
  # on "factory:escalation" and MUST NOT call drive_fun.
  # ---------------------------------------------------------------------------

  @tag :liveness_3
  test "LIVE-liveness-3: select_fun returning {:ambiguity, reason} broadcasts E-AMBIGUITY to factory:escalation" do
    reason = "irreducible spec gap: SPEC-FACTORY-CORE §4 B2 ambiguous precondition"
    {name, _drive_calls} = start_coordinator_with_ambiguity(reason)

    _pid = wait_for_running(name)

    # LIVE-liveness-3 requires: {:escalation, %{reason: :"E-AMBIGUITY", ...}} on
    # "factory:escalation". The Coordinator's running(:internal, :loop) MUST
    # detect the {:ambiguity, _} return from select_fun and emit this escalation.
    #
    # Against current code this fails because {:ambiguity, reason} falls into
    # the `work` branch and drive_fun is called instead of escalating.
    assert_receive {:escalation, %{reason: :"E-AMBIGUITY"}},
                   1_000,
                   "LIVE-liveness-3 violation: Coordinator did not broadcast E-AMBIGUITY " <>
                     "when select_fun returned {:ambiguity, reason}. " <>
                     "The {:ambiguity, _} signal from select_fun MUST be detected and " <>
                     "routed to E-AMBIGUITY escalation, not silently driven as a work item."
  end

  @tag :liveness_3
  test "LIVE-liveness-3: E-AMBIGUITY escalation carries :unit scope (per-unit, loop continues)" do
    reason = "product ambiguity: milestone objective undefined"
    {name, _drive_calls} = start_coordinator_with_ambiguity(reason)

    _pid = wait_for_running(name)

    # E-AMBIGUITY is per-unit scope (liveness.md §E-AMBIGUITY table). The
    # broadcast MUST carry scope: :unit -- not :global -- because the loop
    # must continue rather than globally halting.
    assert_receive {:escalation, %{reason: :"E-AMBIGUITY", scope: :unit}},
                   1_000,
                   "LIVE-liveness-3 scope violation: E-AMBIGUITY escalation MUST carry " <>
                     "scope: :unit (per-unit; loop continues). " <>
                     "A global scope (:global) would incorrectly halt the entire factory."
  end

  @tag :liveness_3
  test "LIVE-liveness-3: drive_fun is NOT called with the ambiguity tuple as a work item" do
    reason = "spec gap: no AC covers this code path"
    {_name, drive_calls} = start_coordinator_with_ambiguity(reason)

    # Give the Coordinator time to process the :loop event and either escalate
    # or (incorrectly) call drive_fun.
    Process.sleep(300)

    # Ensure no {:drive_fun_called, {:ambiguity, _}} arrived.
    refute_receive {:drive_fun_called, {:ambiguity, _}},
                   200,
                   "LIVE-liveness-3 boundary violation: drive_fun was called with " <>
                     "the ambiguity tuple {:ambiguity, reason} as if it were a real work item. " <>
                     "The Coordinator MUST detect {:ambiguity, _} in select_fun output " <>
                     "and escalate E-AMBIGUITY rather than driving it."

    # Also verify via the Agent record (belt and suspenders).
    recorded = Agent.get(drive_calls, & &1)

    refute Enum.any?(recorded, fn
             {:ambiguity, _} -> true
             _ -> false
           end),
           "LIVE-liveness-3: drive_calls agent recorded {:ambiguity, _} -- " <>
             "drive_fun MUST NOT be called with the ambiguity signal. " <>
             "Recorded calls: #{inspect(recorded)}"
  end

  @tag :liveness_3
  test "LIVE-liveness-3: Coordinator remains in :running after E-AMBIGUITY (per-unit; not globally halted)" do
    reason = "ambiguity: no issues in milestone"
    {name, _drive_calls} = start_coordinator_with_ambiguity(reason)

    # Allow the coordinator to process :loop and emit any escalation.
    Process.sleep(300)

    pid = Process.whereis(name)
    refute is_nil(pid), "Coordinator process unexpectedly absent after E-AMBIGUITY"

    # E-AMBIGUITY is per-unit: the Coordinator MUST stay in :running.
    # A global halt (:halting/:halted) would be a conformance violation.
    state = :sys.get_state(pid, 500)

    assert match?({:running, _}, state),
           "LIVE-liveness-3: Coordinator must remain in :running after per-unit " <>
             "E-AMBIGUITY escalation, but reached state: #{inspect(elem(state, 0))}. " <>
             "E-AMBIGUITY is per-unit scope -- the loop must continue."
  end
end
