defmodule Tau.CodingAgent.DispatcherTest do
  @moduledoc """
  Exercises the dispatcher against the Replay adapter.

  Touches D-031 (normalized stream reaches subscriber), D-032
  (cancel emits a synthetic terminal Done), D-035 (adapter
  configuration error becomes an in-stream Error then Done),
  plus the inactivity-timeout path.
  """

  use ExUnit.Case, async: true

  alias Tau.CodingAgent.Dispatcher
  alias Tau.CodingAgent.Event

  defp start_dispatcher!(task, ctx \\ %{}) do
    args = [
      adapter: Tau.CodingAgents.Replay,
      task: task,
      ctx: ctx,
      subscriber: self()
    ]

    {:ok, pid} = Dispatcher.start_link(args)
    pid
  end

  describe "happy path" do
    test "emits the Replay default events and terminates with Done" do
      task = %{prompt: "p", workspace: System.tmp_dir!()}
      pid = start_dispatcher!(task)
      ref = Process.monitor(pid)

      {:ok, events} = Dispatcher.await(pid)

      assert match?(%Event.Start{}, List.first(events))
      assert match?(%Event.Done{exit_status: 0}, List.last(events))

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    end

    test "in-memory fixture round-trips through the dispatcher" do
      events = [
        %Event.Start{agent: :replay},
        %Event.AssistantText{text: "hi"},
        %Event.Cost{tokens: %{}, usd: 0.0, duration_ms: 1},
        %Event.Done{exit_status: 0}
      ]

      task = %{prompt: "p", workspace: System.tmp_dir!(), replay_fixture: events}
      pid = start_dispatcher!(task)

      {:ok, out} = Dispatcher.await(pid)
      assert ^events = out
    end
  end

  describe "cancel — D-032" do
    test "emits a synthetic Done with exit_status: -2 and stops normally" do
      events = [
        %Event.Start{agent: :replay},
        %Event.AssistantText{text: "slow"},
        %Event.AssistantText{text: "stream"},
        %Event.Done{exit_status: 0}
      ]

      task = %{prompt: "p", workspace: System.tmp_dir!(), replay_fixture: events}
      # Slow the emission so cancel has time to land.
      pid = start_dispatcher!(task, %{replay_delay_ms: 50})
      ref = Process.monitor(pid)

      # Wait for at least the first event so we know we're streaming.
      assert_receive {:coding_agent_event, ^pid, %Event.Start{}}, 5_000

      Dispatcher.cancel(pid)

      # Drain remaining messages and assert we see exactly one Done
      # with the cancel sentinel.
      done = drain_for_done(pid, 5_000)
      assert %Event.Done{exit_status: -2} = done

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    end

    test "duplicate cancel is idempotent" do
      events = [
        %Event.Start{agent: :replay},
        %Event.AssistantText{text: "x"},
        %Event.Done{exit_status: 0}
      ]

      task = %{prompt: "p", workspace: System.tmp_dir!(), replay_fixture: events}
      pid = start_dispatcher!(task, %{replay_delay_ms: 30})
      ref = Process.monitor(pid)

      Dispatcher.cancel(pid)
      Dispatcher.cancel(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    end
  end

  describe "synchronous start error — D-035" do
    test "missing workspace becomes an Error event + Done" do
      args = [
        adapter: Tau.CodingAgents.Replay,
        # No workspace field — Replay.start/2 returns {:error, :workspace_missing}.
        task: %{prompt: "p"},
        ctx: %{},
        subscriber: self()
      ]

      {:ok, pid} = Dispatcher.start_link(args)
      ref = Process.monitor(pid)

      assert_receive {:coding_agent_event, ^pid,
                      %Event.Error{reason: :workspace_missing, recoverable: false}},
                     5_000

      assert_receive {:coding_agent_event, ^pid, %Event.Done{exit_status: -1}}, 5_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    end
  end

  describe "inactivity timeout" do
    test "fires after ctx.inactivity_timeout_ms with a stalled adapter" do
      # A fixture with one event then a long sleep before Done; we
      # set the inactivity timeout below the sleep delay so it must
      # fire before the next emission.
      events = [
        %Event.Start{agent: :replay},
        %Event.AssistantText{text: "tick"},
        %Event.Done{exit_status: 0}
      ]

      task = %{prompt: "p", workspace: System.tmp_dir!(), replay_fixture: events}
      pid = start_dispatcher!(task, %{replay_delay_ms: 500, inactivity_timeout_ms: 100})
      ref = Process.monitor(pid)

      assert_receive {:coding_agent_event, ^pid,
                      %Event.Error{reason: :inactivity_timeout, recoverable: false}},
                     2_000

      assert_receive {:coding_agent_event, ^pid, %Event.Done{exit_status: -1}}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
    end
  end

  describe "supervised under CodingAgent.Supervisor" do
    test "child registers, runs to completion, exits cleanly (zero zombies)" do
      task = %{prompt: "p", workspace: System.tmp_dir!()}

      args = [
        adapter: Tau.CodingAgents.Replay,
        task: task,
        ctx: %{},
        subscriber: self()
      ]

      {:ok, pid} = Tau.CodingAgent.Supervisor.start_dispatcher(args)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000

      # Allow DynamicSupervisor a moment to reap.
      :timer.sleep(20)
      assert Tau.CodingAgent.Supervisor.count() == 0
    end
  end

  # ── helpers ───────────────────────────────────────────────────

  defp drain_for_done(pid, timeout) do
    receive do
      {:coding_agent_event, ^pid, %Event.Done{} = d} -> d
      {:coding_agent_event, ^pid, _} -> drain_for_done(pid, timeout)
    after
      timeout -> flunk("did not receive Done within #{timeout}ms")
    end
  end
end
