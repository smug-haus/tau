defmodule Tau.Factory.CoordinatorLivenessUnclassifiedTest do
  @moduledoc """
  Gating test for issue #613 / invariant LIVE-liveness-1.

  Enforces **D-317(b)** — the second half of the total-escalation invariant:
  every reachable non-progress state MUST emit a trigger classified into E.
  `running` is the ONLY non-progress-capable state in the Coordinator
  (SPEC-FACTORY-CORE §5, line ~1211). An unrecognised `:info` message
  received in `:running` MUST be classified via `Escalation.classify/1` and
  result in a `{:escalation, %{reason: :"E-UNCLASSIFIED", ...}}` broadcast to
  the `"factory:escalation"` PubSub topic.

  ## What D-317(b) requires (SPEC-FACTORY-CORE §6)

      D-317 — Escalation is total over reachable states:
      (a) `Escalation.classify/1` is total over `term()` — its catch-all
          returns `{:"E-UNCLASSIFIED", :global}`; AND
      (b) every reachable non-progress state EMITS A TRIGGER within a
          bounded window.

  The existing `escalation_property_test.exs` covers only (a). This test
  covers (b) at the Coordinator boundary.

  ## Current defect (lines 341-344, coordinator.ex)

      def running(event_type, event, data) do
        Logger.debug("[Coordinator] running: unhandled ...")
        {:keep_state, data}          # <- silent absorption; no classify/1 call
      end                            # <- no {:escalate,...} emitted; D-317(b) false

  The test fails against this code because no escalation message arrives on
  `"factory:escalation"`. It passes only once the catch-all invokes
  `Escalation.classify/1` on the unrecognised event and broadcasts the result.

  ## Entry point

  The test exercises the REAL `Tau.Factory.Coordinator.start_link/1` path.
  The gen_statem is started via start_supervised!/1 (the production child_spec
  path), an unrecognised message is sent as a real :info event, and the
  observable outcome is the PubSub broadcast on "factory:escalation" — the
  user-facing control plane signal D-317 requires.

  AC/D-NNN linkage: LIVE-liveness-1, D-317.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log
  @moduletag :liveness_1
  @moduletag :d_317

  @coordinator Tau.Factory.Coordinator

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique_name(base) do
    suffix = System.unique_integer([:positive, :monotonic])
    :"#{base}_#{suffix}"
  end

  # Start a minimal Coordinator in :running state.
  # select_fun returns nil immediately (no work to select) so the coordinator
  # reaches idle :running after the :loop internal event. drive_fun is a no-op.
  defp start_coordinator do
    name = unique_name(:coord_liveness)

    # Subscribe to the escalation topic BEFORE the coordinator starts, so we
    # receive any broadcast it emits during startup as well as after the probe.
    :ok = Phoenix.PubSub.subscribe(Tau.PubSub, "factory:escalation")

    start_supervised!(
      {@coordinator,
       name: name,
       pubsub: Tau.PubSub,
       select_fun: fn -> nil end,
       drive_fun: fn _work -> :ok end,
       scheduler: nil,
       on_halted: nil,
       ledger: nil}
    )

    pid = wait_for_running(name)
    {name, pid}
  end

  # Poll until the coordinator is in :running state (not still processing
  # the initial :loop internal event). Bounded; never hangs.
  defp wait_for_running(name) do
    Enum.reduce_while(1..100, nil, fn _, _ ->
      case Process.whereis(name) do
        nil ->
          Process.sleep(5)
          {:cont, nil}

        pid ->
          # Verify the gen_statem is in :running by requesting its state; the
          # sys call ensures it has processed all prior events.
          case :sys.get_state(pid, 500) do
            {:running, _data} -> {:halt, pid}
            _ -> Process.sleep(5) && {:cont, nil}
          end
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # LIVE-liveness-1 / D-317(b) -- unrecognised :info in :running emits
  # E-UNCLASSIFIED on "factory:escalation".
  # ---------------------------------------------------------------------------

  @tag :liveness_1
  @tag :d_317
  test "LIVE-liveness-1 / D-317(b): unrecognised :info event in :running state broadcasts E-UNCLASSIFIED to factory:escalation" do
    {_name, pid} = start_coordinator()

    # Probe: send an unrecognised :info message -- one the Coordinator has no
    # explicit clause for. The shape {:unrecognised_probe, :liveness_1} is not
    # matched by any of the named running/3 heads.
    send(pid, {:unrecognised_probe, :liveness_1})

    # D-317(b): the coordinator MUST classify the event via Escalation.classify/1
    # (which maps any unrecognised term to {:"E-UNCLASSIFIED", :global}) and
    # broadcast {:escalation, %{reason: :"E-UNCLASSIFIED", scope: :global, ...}}
    # to "factory:escalation" within a bounded window.
    #
    # The current catch-all (coordinator.ex lines 341-344) does NOT do this --
    # it absorbs the message silently. This assertion therefore FAILS against
    # the current code and passes only once D-317(b) is enforced.
    assert_receive {:escalation, %{reason: :"E-UNCLASSIFIED", scope: :global}},
                   500,
                   "D-317(b) / LIVE-liveness-1 violation: the Coordinator :running " <>
                     "catch-all absorbed an unrecognised :info event without calling " <>
                     "Escalation.classify/1 or broadcasting to factory:escalation. " <>
                     "Every non-progress state MUST emit a trigger into E."
  end

  @tag :liveness_1
  @tag :d_317
  test "LIVE-liveness-1 / D-317(b): unrecognised :cast event in :running state broadcasts E-UNCLASSIFIED to factory:escalation" do
    {_name, pid} = start_coordinator()

    # gen_statem :cast messages also arrive via the running/3 catch-all when
    # unrecognised. D-317(b) applies to all event types in :running.
    :gen_statem.cast(pid, {:unrecognised_cast_probe, :liveness_1})

    assert_receive {:escalation, %{reason: :"E-UNCLASSIFIED", scope: :global}},
                   500,
                   "D-317(b) / LIVE-liveness-1 violation: the Coordinator :running " <>
                     "catch-all absorbed an unrecognised :cast event without emitting " <>
                     "E-UNCLASSIFIED on factory:escalation."
  end
end
