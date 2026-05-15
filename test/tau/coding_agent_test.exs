defmodule Tau.CodingAgentTest do
  @moduledoc """
  Contract tests for the `Tau.CodingAgent` behaviour using the
  `Tau.CodingAgents.Replay` adapter. Phase 1B adapters (ClaudeCode,
  etc.) should re-run the same shape of assertions.

  Covers SPEC-CODING-AGENT.md AC-1 (partial — Replay only),
  D-031 (normalized event stream), D-033 (explicit workspace),
  D-035 (no raise across boundary).
  """

  use ExUnit.Case, async: true

  alias Tau.CodingAgent
  alias Tau.CodingAgent.Event
  alias Tau.CodingAgents.Replay

  describe "capabilities/0" do
    test "returns a fully-populated map" do
      caps = Replay.capabilities()

      assert is_map(caps)

      for key <- [
            :streaming,
            :tool_restriction,
            :mcp_client,
            :session_resume,
            :cost_reporting,
            :workspace_isolation
          ] do
        assert Map.has_key?(caps, key), "missing capability key: #{inspect(key)}"
      end

      assert caps.workspace_isolation in [:cwd, :worktree, :either]
    end
  end

  describe "configure/1" do
    test "echoes the input map" do
      assert {:ok, %{foo: 1}} = Replay.configure(%{foo: 1})
    end
  end

  describe "start/2" do
    test "returns {:ok, stream} for a valid task" do
      task = %{prompt: "hi", workspace: System.tmp_dir!()}
      assert {:ok, stream} = Replay.start(task, %{})
      assert Enumerable.impl_for(stream) != nil
    end

    test "returns {:error, _} when workspace is absent — D-033" do
      assert {:error, :workspace_missing} = Replay.start(%{prompt: "hi"}, %{})
    end

    test "does NOT raise on bad fixture path; falls through to default" do
      task = %{
        prompt: "hi",
        workspace: System.tmp_dir!(),
        replay_fixture: "/nonexistent/path/that/does/not/exist.jsonl"
      }

      # D-035: must not raise.
      assert {:ok, stream} = Replay.start(task, %{})
      events = Enum.to_list(stream)
      assert match?(%Event.Start{}, hd(events))
    end

    test "in-memory event list passes through unmodified" do
      events = [
        %Event.Start{agent: :replay},
        %Event.AssistantText{text: "hi"},
        %Event.Done{exit_status: 0}
      ]

      task = %{prompt: "p", workspace: System.tmp_dir!(), replay_fixture: events}
      {:ok, stream} = Replay.start(task, %{})
      assert ^events = Enum.to_list(stream)
    end
  end

  describe "event order (D-031)" do
    test "default fixture emits Start → … → Done with no extra events after Done" do
      task = %{prompt: "p", workspace: System.tmp_dir!()}
      {:ok, stream} = Replay.start(task, %{})
      events = Enum.to_list(stream)

      assert match?(%Event.Start{}, List.first(events))
      assert match?(%Event.Done{}, List.last(events))

      # No event after Done.
      done_index = Enum.find_index(events, &match?(%Event.Done{}, &1))
      assert done_index == length(events) - 1
    end
  end

  describe "cancel via cancel_flag" do
    test "halts emission and surfaces a cancelled Error event" do
      flag = :counters.new(1, [])
      :counters.add(flag, 1, 1)

      events = [
        %Event.Start{agent: :replay},
        %Event.AssistantText{text: "hi"},
        %Event.Done{exit_status: 0}
      ]

      task = %{prompt: "p", workspace: System.tmp_dir!(), replay_fixture: events}
      {:ok, stream} = Replay.start(task, %{cancel_flag: flag})
      out = Enum.to_list(stream)

      assert [%Event.Error{reason: :cancelled, recoverable: false}] = out
    end
  end

  describe "CodingAgent.run/4 convenience" do
    test "drains the stream to a {:ok, %{events, done}}" do
      task = %{prompt: "p", workspace: System.tmp_dir!()}
      {:ok, %{events: events, done: done}} = CodingAgent.run(Replay, task, %{})

      assert match?(%Event.Done{}, done)
      assert Enum.any?(events, &match?(%Event.Start{}, &1))
    end

    test "surfaces synchronous {:error, _} from start/2 unchanged" do
      assert {:error, :workspace_missing} = CodingAgent.run(Replay, %{prompt: "p"}, %{})
    end

    test "in-stream non-recoverable error returns {:error, reason}" do
      events = [
        %Event.Start{agent: :replay},
        %Event.Error{reason: :boom, recoverable: false}
      ]

      task = %{prompt: "p", workspace: System.tmp_dir!(), replay_fixture: events}
      assert {:error, :boom} = CodingAgent.run(Replay, task, %{})
    end
  end
end
