defmodule Tau.Session.CodingAgentResumeTest do
  @moduledoc """
  SPEC-CODING-AGENT §7 Q5: when a coding-agent run emits an
  `%Event.Start{session_id: id}`, the session FSM MUST capture
  `id`, persist it via the JSONL `coding_agent_session` event,
  and pass it as `task.resume_id` on the next dispatcher launch
  in the same session (Claude Code's `--resume <session-id>`).

  The session-mode surface is the only path that does this; the
  Delegate tool surface (Phase 2) does not — see SPEC §7 Q5
  resolution and #191.
  """
  use ExUnit.Case, async: false

  import Tau.Test.SessionHelper, only: [start_session_for_test: 1]

  alias Tau.CodingAgent.Event, as: CAE
  alias Tau.Session.Events, as: SE

  setup do
    tmp = Path.join(System.tmp_dir!(), "tau-ca-resume-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:tau, :data_dir, tmp)

    on_exit(fn ->
      File.rm_rf!(tmp)
      Application.delete_env(:tau, :data_dir)
    end)

    %{data_dir: tmp}
  end

  # An adapter that records every `task` it was started with into
  # an ETS table so the test can assert resume_id on the second
  # launch. Otherwise behaves like Replay.
  defmodule RecordingReplay do
    @behaviour Tau.CodingAgent

    alias Tau.CodingAgent.Event

    @table :tau_recording_replay_tasks

    @impl true
    def capabilities,
      do: %{
        streaming: true,
        tool_restriction: false,
        mcp_client: false,
        session_resume: true,
        cost_reporting: true,
        workspace_isolation: :either
      }

    @impl true
    def configure(opts) when is_map(opts), do: {:ok, opts}

    @impl true
    def cancel(_handle), do: :ok

    @impl true
    def start(task, ctx) do
      ensure_table!()
      :ets.insert(@table, {System.unique_integer([:monotonic]), task})

      events = Map.get(ctx, :replay_fixture, [])

      stream =
        Stream.resource(
          fn -> events end,
          fn
            [] -> {:halt, []}
            [h | t] -> {[h], t}
          end,
          fn _ -> :ok end
        )

      {:ok, stream}
    end

    def tasks do
      ensure_table!()
      :ets.tab2list(@table) |> Enum.sort_by(fn {k, _} -> k end) |> Enum.map(&elem(&1, 1))
    end

    def reset do
      ensure_table!()
      :ets.delete_all_objects(@table)
    end

    defp ensure_table! do
      if :ets.whereis(@table) == :undefined do
        :ets.new(@table, [:named_table, :public, :ordered_set])
      end

      :ok
    end

    @doc false
    def start_event(session_id), do: %Event.Start{agent: :recording_replay, session_id: session_id}

    @doc false
    def done_event, do: %Event.Done{exit_status: 0, final_message: nil}
  end

  describe "captures Start.session_id into coding_agent_state" do
    test "second dispatcher launch in same session receives resume_id" do
      RecordingReplay.reset()
      sid = "ca-resume-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

      # Turn 1: adapter emits a Start with an adapter-side session_id.
      first_fixture = [
        RecordingReplay.start_event("claude-sess-aaa"),
        %CAE.AssistantText{text: "first turn", turn: 0},
        RecordingReplay.done_event()
      ]

      {:ok, ^sid} =
        start_session_for_test(
          session_id: sid,
          coding_agent: RecordingReplay,
          coding_agent_workspace_backend: Tau.CodingAgent.Workspace.Cwd,
          coding_agent_ctx: %{replay_fixture: first_fixture}
        )

      Tau.send(sid, "turn 1")
      assert_receive %SE.MessageEnd{}, 2_000

      # Reconfigure the ctx so the second turn ships a different
      # fixture (without the Start we'd otherwise emit twice).
      # The session reuses its captured coding_agent_state regardless.
      Process.sleep(50)

      :ok =
        Tau.update_provider(sid,
          coding_agent_ctx: %{replay_fixture: [RecordingReplay.done_event()]}
        )

      Tau.send(sid, "turn 2")
      assert_receive %SE.MessageEnd{}, 2_000

      # The recording adapter logged both `task` maps; verify the
      # second carries resume_id and the first does not.
      [task1, task2] = RecordingReplay.tasks()
      assert task1.resume_id == nil
      assert task2.resume_id == "claude-sess-aaa"
    end
  end

  describe "[:tau, :coding_agent, :resume] telemetry fires on second launch" do
    test "exactly when task.resume_id is non-nil" do
      RecordingReplay.reset()
      parent = self()
      handler_id = "tau-ca-resume-tel-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:tau, :coding_agent, :resume],
        fn _e, _m, meta, _ -> send(parent, {:tel_resume, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      sid = "ca-resume-tel-#{System.unique_integer([:positive])}"

      fixture = [
        RecordingReplay.start_event("claude-sess-bbb"),
        RecordingReplay.done_event()
      ]

      {:ok, ^sid} =
        start_session_for_test(
          session_id: sid,
          coding_agent: RecordingReplay,
          coding_agent_workspace_backend: Tau.CodingAgent.Workspace.Cwd,
          coding_agent_ctx: %{replay_fixture: fixture}
        )

      Tau.send(sid, "turn 1")

      # First turn — no resume yet, so no telemetry.
      refute_receive {:tel_resume, _}, 250

      :ok =
        Tau.update_provider(sid,
          coding_agent_ctx: %{replay_fixture: [RecordingReplay.done_event()]}
        )

      Tau.send(sid, "turn 2")

      assert_receive {:tel_resume,
                      %{adapter_session_id: "claude-sess-bbb", agent: RecordingReplay}},
                     2_000
    end
  end

  describe "JSONL persistence + /resume path" do
    test "a `coding_agent_session` event is written when Start.session_id is non-nil" do
      RecordingReplay.reset()
      sid = "ca-resume-jsonl-#{System.unique_integer([:positive])}"

      fixture = [
        RecordingReplay.start_event("claude-sess-ccc"),
        RecordingReplay.done_event()
      ]

      {:ok, ^sid} =
        start_session_for_test(
          session_id: sid,
          coding_agent: RecordingReplay,
          coding_agent_workspace_backend: Tau.CodingAgent.Workspace.Cwd,
          coding_agent_ctx: %{replay_fixture: fixture}
        )

      Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")
      Tau.send(sid, "turn 1")
      assert_receive %SE.MessageEnd{}, 2_000
      Process.sleep(50)

      events = Tau.Persistence.impl().stream(sid) |> Enum.to_list()

      session_events =
        Enum.filter(events, &match?(%{"kind" => "coding_agent_session"}, &1))

      assert length(session_events) == 1
      [se] = session_events
      assert se["data"]["session_id"] == "claude-sess-ccc"
    end

    test "no session event when Start.session_id is nil (e.g. Replay default)" do
      RecordingReplay.reset()
      sid = "ca-resume-nosid-#{System.unique_integer([:positive])}"

      fixture = [
        %CAE.Start{agent: :recording_replay, session_id: nil},
        RecordingReplay.done_event()
      ]

      {:ok, ^sid} =
        start_session_for_test(
          session_id: sid,
          coding_agent: RecordingReplay,
          coding_agent_workspace_backend: Tau.CodingAgent.Workspace.Cwd,
          coding_agent_ctx: %{replay_fixture: fixture}
        )

      Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")
      Tau.send(sid, "turn 1")
      assert_receive %SE.MessageEnd{}, 2_000
      Process.sleep(50)

      events = Tau.Persistence.impl().stream(sid) |> Enum.to_list()
      assert Enum.filter(events, &match?(%{"kind" => "coding_agent_session"}, &1)) == []
    end
  end
end
