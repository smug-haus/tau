defmodule Tau.CodingAgent.LifecyclePropertyTest do
  @moduledoc """
  Property test skeleton for SPEC-CODING-AGENT.md AC-5 — kill-the-BEAM
  invariant.

  Invariant: regardless of when `cancel/1` is invoked relative to a
  running dispatcher, the `Tau.CodingAgent.Supervisor` ends up with
  zero active children once each run terminates.

  This phase exercises the invariant against the Replay adapter, which
  has no subprocess. Full validation (zero zombie OS subprocesses) lands
  in Phase 1B alongside the ClaudeCode adapter.
  """

  use ExUnit.Case, async: false
  use ExUnitProperties

  @moduletag :property

  alias Tau.CodingAgent.Dispatcher
  alias Tau.CodingAgent.Event
  alias Tau.CodingAgent.Supervisor, as: CASup

  @fixture [
    %Event.Start{agent: :replay},
    %Event.AssistantText{text: "a"},
    %Event.AssistantText{text: "b"},
    %Event.AssistantText{text: "c"},
    %Event.AssistantText{text: "d"},
    %Event.Done{exit_status: 0}
  ]

  property "50 random cancel timings against Replay leave zero zombie children" do
    # Sanity: the application's coding-agent supervisor must be running
    # before we sample. If something cascaded it down between iterations,
    # the failure surface is clearer here than inside `eventually`.
    assert Process.whereis(CASup) != nil

    check all(
            cancel_after_ms <- StreamData.integer(0..200),
            delay_ms <- StreamData.member_of([5, 10, 25]),
            max_runs: 50
          ) do
      task = %{
        prompt: "p",
        workspace: System.tmp_dir!(),
        replay_fixture: @fixture
      }

      args = [
        adapter: Tau.CodingAgents.Replay,
        task: task,
        ctx: %{replay_delay_ms: delay_ms},
        subscriber: self()
      ]

      {:ok, pid} = CASup.start_dispatcher(args)
      ref = Process.monitor(pid)

      :timer.sleep(cancel_after_ms)
      Dispatcher.cancel(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, reason} ->
          assert reason == :normal or match?({:shutdown, _}, reason)
      after
        2_000 ->
          flunk("dispatcher did not exit after cancel within 2s")
      end

      # Drain any lingering mailbox messages from the run so the next
      # iteration starts clean.
      flush_mailbox()

      assert Process.whereis(CASup) != nil,
             "Tau.CodingAgent.Supervisor died mid-property — cascade"

      # Allow the DynamicSupervisor a moment to reap the dead child.
      :timer.sleep(20)

      assert CASup.count() == 0,
             "expected zero supervisor children, got #{CASup.count()}"
    end
  end

  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      0 -> :ok
    end
  end
end
