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

    # Bring the RecordingStore Agent up if it isn't already. It's
    # registered globally and survives across tests; each test
    # filters by session_id so there's no cross-test interference.
    __MODULE__.RecordingStore.ensure!()

    on_exit(fn ->
      File.rm_rf!(tmp)
      Application.delete_env(:tau, :data_dir)
    end)

    %{data_dir: tmp}
  end

  # Long-lived Agent that owns the recording state. We can't use a
  # named ETS table because the drainer process (which is where the
  # adapter's start/2 runs) dies as soon as the stream completes,
  # taking any tables it created with it.
  defmodule RecordingStore do
    @name __MODULE__

    def ensure! do
      case Agent.start_link(fn -> %{} end, name: @name) do
        {:ok, _pid} ->
          :ok

        {:error, {:already_started, _pid}} ->
          :ok

        {:error, reason} ->
          raise "RecordingStore failed to start: #{inspect(reason)}"
      end
    end

    def record(session_id, task) do
      ensure!()
      Agent.update(@name, fn st -> Map.update(st, session_id, [task], &(&1 ++ [task])) end)
    end

    def tasks(session_id) do
      ensure!()
      Agent.get(@name, fn st -> Map.get(st, session_id, []) end)
    end
  end

  # An adapter that records every `task` it was started with into
  # the RecordingStore (above) so the test can assert resume_id on
  # the second launch. Otherwise behaves like Replay.
  defmodule RecordingReplay do
    @behaviour Tau.CodingAgent

    alias Tau.CodingAgent.Event

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
      sid = Map.get(ctx, :session_id) || Map.get(task, :session_id) || "unknown"
      RecordingStore.record(sid, task)

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

    @doc """
    Tasks recorded for the given tau session_id, oldest-first.
    """
    defdelegate tasks(session_id), to: RecordingStore

    @doc false
    def start_event(session_id), do: %Event.Start{agent: :recording_replay, session_id: session_id}

    @doc false
    def done_event, do: %Event.Done{exit_status: 0, final_message: nil}
  end

  # Wait until `Tau.Sessions.Registry` no longer answers for `sid`.
  # Used by the resume-roundtrip test to ensure `Tau.resume/1`
  # doesn't short-circuit on a still-live `whereis/1`.
  defp wait_for_unregister(sid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn -> :ok end)
    |> Enum.reduce_while(:ok, fn _, _ ->
      case Registry.lookup(Tau.Sessions.Registry, sid) do
        [] ->
          {:halt, :ok}

        _ ->
          if System.monotonic_time(:millisecond) > deadline do
            flunk("session #{sid} did not unregister within #{timeout_ms}ms")
          else
            Process.sleep(10)
            {:cont, :ok}
          end
      end
    end)
  end

  describe "captures Start.session_id into coding_agent_state" do
    test "second dispatcher launch in same session receives resume_id" do
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
      # No sleep needed: RecordingStore.record/2 uses Agent.update (a
      # synchronous GenServer.call), so the task is persisted before
      # RecordingReplay.start/2 returns — well before MessageEnd fires.

      :ok =
        Tau.update_provider(sid,
          coding_agent_ctx: %{replay_fixture: [RecordingReplay.done_event()]}
        )

      Tau.send(sid, "turn 2")
      assert_receive %SE.MessageEnd{}, 2_000

      # RecordingStore.record/2 calls Agent.update (synchronous GenServer.call),
      # which completes inside RecordingReplay.start/2 before the stream is
      # consumed. MessageEnd fires only after the full stream is drained, so
      # both tasks are guaranteed to be recorded by the time we read here.

      tasks = RecordingReplay.tasks(sid)
      assert length(tasks) == 2, "expected exactly 2 task recordings, got: #{inspect(tasks)}"

      [task1, task2] = tasks
      assert task1.resume_id == nil
      assert task2.resume_id == "claude-sess-aaa"
    end
  end

  describe "[:tau, :coding_agent, :resume] telemetry fires on second launch" do
    test "exactly when task.resume_id is non-nil" do
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

  describe "Tau.resume/1 — disk roundtrip rehydrates coding_agent_state" do
    test "resumed FSM carries the persisted adapter session_id; next turn threads it as task.resume_id" do
      # Verifies the BLOCKER fix: `Tau.resume/1` must thread the
      # post-header event log into `:preload_events` so the
      # `coding_agent_state_from_preload/1` helper can rehydrate
      # `data.coding_agent_state.session_id` from the persisted
      # `coding_agent_session` JSONL record. Confirms parity with
      # `Tau.fork/2`'s preload pattern (#196 review).
      sid = "ca-resume-roundtrip-#{System.unique_integer([:positive])}"

      # Turn 1: drive the session live, let it persist a
      # `coding_agent_session` event, then stop it so resume must
      # rebuild from disk (a live `whereis` short-circuits resume).
      first_fixture = [
        RecordingReplay.start_event("claude-sess-roundtrip"),
        %CAE.Cost{
          tokens: %{"input_tokens" => 7, "output_tokens" => 11},
          usd: 0.0123,
          duration_ms: 42
        },
        %CAE.AssistantText{text: "first turn", turn: 0},
        RecordingReplay.done_event()
      ]

      Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

      {:ok, ^sid} =
        start_session_for_test(
          session_id: sid,
          coding_agent: RecordingReplay,
          coding_agent_workspace_backend: Tau.CodingAgent.Workspace.Cwd,
          coding_agent_ctx: %{replay_fixture: first_fixture}
        )

      Tau.send(sid, "turn 1")
      assert_receive %SE.MessageEnd{}, 2_000

      # Persistence.Jsonl.append/2 is synchronous (IO.binwrite + :file.datasync
      # both block), so MessageEnd arriving means all JSONL writes are on disk.
      Tau.stop(sid)

      # Wait for the registry entry to clear so Tau.resume/1 doesn't
      # short-circuit on `whereis`.
      wait_for_unregister(sid, 1_000)

      # Verify the persisted ledger contains exactly what resume must
      # reconstruct (sanity check on the precondition).
      persisted = Tau.Persistence.impl().stream(sid) |> Enum.to_list()

      assert Enum.any?(
               persisted,
               &match?(
                 %{
                   "kind" => "coding_agent_session",
                   "data" => %{"session_id" => "claude-sess-roundtrip"}
                 },
                 &1
               )
             )

      assert Enum.any?(persisted, &match?(%{"kind" => "coding_agent_cost"}, &1))

      # Seed settings so the resumed session picks up RecordingReplay
      # as its coding-agent (the JSONL header doesn't yet carry the
      # adapter module — that's a follow-up #196 noted but didn't
      # require). Restore on_exit so concurrent tests aren't affected.
      original_settings = :persistent_term.get({Tau, :settings}, %{})

      :persistent_term.put({Tau, :settings}, %{
        coding_agent: %{default_agent: RecordingReplay}
      })

      on_exit(fn -> :persistent_term.put({Tau, :settings}, original_settings) end)

      # Resume from disk.
      {:ok, ^sid} = Tau.resume(sid)
      on_exit(fn -> Tau.stop(sid) end)

      # BLOCKER assertion: the rehydrated FSM data carries the
      # persisted adapter-side session_id.
      [{pid, _}] = Registry.lookup(Tau.Sessions.Registry, sid)
      {_state, data} = :sys.get_state(pid)

      assert data.coding_agent == RecordingReplay,
             "settings-derived coding_agent didn't reach the resumed session: #{inspect(data.coding_agent)}"

      # `data.coding_agent_state.agent` is stored as the module atom
      # (because `maybe_capture_coding_agent_session/2` records
      # `data.coding_agent`, not the symbolic event-side `:recording_replay`).
      # `agent_to_string/1` and `agent_to_atom/1` round-trip the module
      # via "Elixir.<Mod>"; resume reconstructs the same module atom.
      assert data.coding_agent_state == %{
               session_id: "claude-sess-roundtrip",
               agent: RecordingReplay
             }

      # Cost rehydration: the per-session list should carry the
      # persisted record so the cost panel doesn't lose history.
      assert length(data.coding_agent_costs) == 1
      [cost] = data.coding_agent_costs
      assert cost.usd == 0.0123
      assert cost.input_tokens == 7
      assert cost.output_tokens == 11
      assert cost.duration_ms == 42

      # BLOCKER follow-through: the next coding-agent turn's task
      # MUST carry `resume_id: "claude-sess-roundtrip"`. Drive turn 2
      # against the resumed session (the rehydration is only useful
      # if it actually threads to the next dispatcher launch).
      :ok =
        Tau.update_provider(sid,
          coding_agent_ctx: %{
            replay_fixture: [
              RecordingReplay.start_event("claude-sess-roundtrip"),
              RecordingReplay.done_event()
            ]
          }
        )

      Tau.send(sid, "turn 2 after resume")
      assert_receive %SE.MessageEnd{}, 2_000

      # No sleep needed: see comment above — Agent.update is synchronous.

      # The RecordingStore agent is module-global and persists
      # across the stop/resume boundary, so it retains BOTH the
      # pre-stop turn-1 task (resume_id: nil) and the post-resume
      # turn-2 task (resume_id: "claude-sess-roundtrip"). The
      # latter is the assertion that matters for the BLOCKER fix.
      tasks = RecordingReplay.tasks(sid)
      assert length(tasks) == 2

      [task_before_stop, task_after_resume] = tasks
      assert task_before_stop.resume_id == nil
      assert task_before_stop.prompt == "turn 1"

      assert task_after_resume.resume_id == "claude-sess-roundtrip",
             "next dispatcher launch after Tau.resume/1 didn't thread the persisted session_id"

      assert task_after_resume.prompt == "turn 2 after resume"
    end

    # Regression: a provider-only session (no coding-agent kinds in
    # its JSONL) MUST resume byte-identically — `coding_agent_state`
    # falls back to the nil sentinel, `coding_agent_costs` to [].
    test "provider-only resume is unaffected by preload_events threading" do
      sid = "ca-resume-provider-only-#{System.unique_integer([:positive])}"

      # Build a minimal provider-only JSONL by hand.
      cwd = File.cwd!()
      path = Tau.Persistence.Jsonl.path_for(sid, cwd)
      File.mkdir_p!(Path.dirname(path))

      header = %{
        "id" => "hdr_" <> sid,
        "parent_id" => nil,
        "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "kind" => "session_header",
        "data" => %{
          "session_id" => sid,
          "cwd" => cwd,
          "provider" => inspect(Tau.Providers.Replay),
          "model" => "replay-test",
          "metadata" => %{}
        }
      }

      user = %{
        "id" => "evt_user_" <> sid,
        "parent_id" => nil,
        "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "kind" => "user_message",
        "data" => %{"role" => "user", "content" => "hello"}
      }

      File.write!(path, Enum.map_join([header, user], "\n", &Jason.encode!/1) <> "\n")

      {:ok, ^sid} = Tau.resume(sid)
      on_exit(fn -> Tau.stop(sid) end)

      [{pid, _}] = Registry.lookup(Tau.Sessions.Registry, sid)
      {_state, data} = :sys.get_state(pid)

      assert data.coding_agent_state == %{session_id: nil, agent: nil}
      assert data.coding_agent_costs == []
      # The provider-only user message should still appear in
      # rebuilt messages (events_to_messages is unaffected).
      assert Enum.any?(data.messages, fn
               %Tau.Message.User{content: "hello"} -> true
               _ -> false
             end)
    end
  end

  describe "JSONL persistence on the live session-mode path" do
    test "a `coding_agent_session` event is written when Start.session_id is non-nil" do
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

      # No sleep: Persistence.Jsonl.append/2 is synchronous (IO.binwrite +
      # :file.datasync both block). MessageEnd fires after persist_event, so
      # the JSONL is fully written by the time we reach here.

      events = Tau.Persistence.impl().stream(sid) |> Enum.to_list()

      session_events =
        Enum.filter(events, &match?(%{"kind" => "coding_agent_session"}, &1))

      assert length(session_events) == 1
      [se] = session_events
      assert se["data"]["session_id"] == "claude-sess-ccc"
    end

    test "no session event when Start.session_id is nil (e.g. Replay default)" do
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

      # No sleep: same reasoning as the test above.

      events = Tau.Persistence.impl().stream(sid) |> Enum.to_list()
      assert Enum.filter(events, &match?(%{"kind" => "coding_agent_session"}, &1)) == []
    end
  end
end
