defmodule Tau.Session.MessageQueueTiersTest do
  @moduledoc """
  Two-tier message queue (#339 / D-077..D-083).

  Verifies the steering/follow-up queue contracts:

  - D-077: `Tau.send/2` always routes to the :followup tier.
  - D-078: `Tau.steer/2` always routes to the :steering tier.
  - D-079: steering queue drains at the tool-round boundary (before next provider call).
  - D-080: follow-up queue drains on `:awaiting_user` entry via `:internal :drain_followups`.
  - D-081: follow-up FIFO order preserved across sessions.
  - D-082: `cancel/1` broadcasts `%QueueRestored{}` carrying steering messages and clears the
    steering queue; follow-up queue is preserved.
  - D-083: hard cap of 32 per queue; messages beyond the cap are dropped.

  AC-8 (ordering): interleaved steering messages arrive before the next provider turn.
  AC-9 (cap): messages beyond 32 are dropped (no crash, no wedge).
  AC-10: `Tau.steer/2` vs `Tau.send/2` route correctly.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  import Tau.Test.SessionHelper, only: [start_session_for_test: 1]
  alias Tau.Provider.Event
  alias Tau.Session.Events, as: SE

  @queue_cap 32

  setup do
    tmp = Path.join(System.tmp_dir!(), "tau-queue-tiers-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:tau, :data_dir, tmp)

    on_exit(fn ->
      File.rm_rf!(tmp)
      Application.delete_env(:tau, :data_dir)
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Shared providers
  # ---------------------------------------------------------------------------

  # A slow provider: introduces replay_delay_ms so the test can land casts
  # while the session is in :provider_streaming.
  defp slow_fixture(text \\ "ack") do
    [
      %Event.Start{request_id: "r", model: "replay"},
      %Event.TextStart{block_id: "b"},
      %Event.TextDelta{block_id: "b", text: text},
      %Event.TextEnd{block_id: "b"},
      %Event.Done{stop_reason: :stop, usage: %{}}
    ]
  end

  defp start_slow_session(sid, extra_ctx \\ %{}) do
    ctx = Map.merge(%{replay_fixture: slow_fixture(), replay_delay_ms: 30}, extra_ctx)

    start_session_for_test(
      provider: Tau.Providers.Replay,
      model: "replay",
      session_id: sid,
      provider_ctx: ctx
    )
  end

  # ---------------------------------------------------------------------------
  # D-077: Tau.send/2 routes to :followup tier
  # D-078: Tau.steer/2 routes to :steering tier
  # ---------------------------------------------------------------------------

  test "D-077/D-078: snapshot queues reflect tier routing while busy" do
    sid = "queue-tier-routing-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")
    {:ok, ^sid} = start_slow_session(sid)

    # Kick off a turn so the session is in :provider_streaming.
    Tau.send(sid, "kick")
    assert_receive %SE.MessageStart{session_id: ^sid}, 2_000

    # While streaming: one steer (steering tier) and one followup (followup tier).
    Tau.steer(sid, "steer-msg")
    Tau.send(sid, "followup-msg")

    # Let the first turn complete. The followup drain fires immediately on
    # :awaiting_user entry, starting another turn.
    assert_receive %SE.MessageEnd{session_id: ^sid}, 5_000
    # Drain the followup turn.
    assert_receive %SE.MessageEnd{session_id: ^sid}, 5_000

    # Follow-up queue is empty. Steering queue is also empty here because
    # there was no tool round — steer-msg remains in steering_queue until
    # a tool round or cancel drains it.
    {:ok, snap} = Tau.snapshot(sid)
    assert snap.state == :awaiting_user
    assert snap.queues.followup == []
    # Steering queue holds the steer message (no tool round occurred).
    steering_contents = Enum.map(snap.queues.steering, & &1.content)
    assert steering_contents == ["steer-msg"]
  end

  test "D-077/D-078: snapshot queues populated during streaming" do
    sid = "queue-tier-snap-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")
    {:ok, ^sid} = start_slow_session(sid)

    Tau.send(sid, "kick")
    assert_receive %SE.MessageStart{session_id: ^sid}, 2_000

    # While streaming, enqueue both tiers.
    Tau.steer(sid, "s1")
    Tau.send(sid, "f1")
    Tau.send(sid, "f2")

    # Snapshot before turn ends — queues should be non-empty.
    {:ok, snap} = Tau.snapshot(sid)
    assert snap.state == :provider_streaming

    # Queues contain %Tau.Message.User{} structs; extract content for comparison.
    steering_contents = Enum.map(snap.queues.steering, & &1.content)
    followup_contents = Enum.map(snap.queues.followup, & &1.content)
    assert "s1" in steering_contents
    assert "f1" in followup_contents
    assert "f2" in followup_contents

    # Let it complete.
    assert_receive %SE.MessageEnd{session_id: ^sid}, 5_000
  end

  # ---------------------------------------------------------------------------
  # D-080: follow-up queue drains on :awaiting_user entry (FIFO order)
  # ---------------------------------------------------------------------------

  property "D-080/D-081: followup messages delivered in FIFO order (AC-8)" do
    check all(n <- StreamData.integer(2..5), max_runs: 6) do
      sid = "queue-fifo-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

      {:ok, ^sid} =
        start_session_for_test(
          provider: Tau.Providers.Replay,
          model: "replay",
          session_id: sid,
          provider_ctx: %{replay_fixture: slow_fixture(), replay_delay_ms: 30}
        )

      msgs = for i <- 1..n, do: "followup-#{i}"

      # Kick the first turn.
      Tau.send(sid, "start")
      assert_receive %SE.MessageStart{session_id: ^sid}, 2_000

      # Queue n followups while busy.
      Enum.each(msgs, &Tau.send(sid, &1))

      # Drain n+1 turns (initial + n followups).
      for _ <- 1..(n + 1) do
        assert_receive %SE.MessageEnd{session_id: ^sid}, 5_000
      end

      Phoenix.PubSub.unsubscribe(Tau.PubSub, "session:#{sid}")

      # Verify JSONL order: user messages should appear in enqueue order.
      [path] = Path.wildcard(Path.join(Tau.Settings.data_dir(), "sessions/*/#{sid}.jsonl"))

      user_contents =
        path
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&(&1["kind"] == "user_message"))
        |> Enum.map(&get_in(&1, ["data", "content"]))

      # "start" first, then msgs in order.
      assert user_contents == ["start" | msgs],
             "followup messages must be delivered in FIFO order; got #{inspect(user_contents)}"
    end
  end

  # ---------------------------------------------------------------------------
  # D-082: cancel drains steering queue → %QueueRestored{}; followup preserved
  # ---------------------------------------------------------------------------

  test "D-082: cancel broadcasts %QueueRestored{} with steering messages" do
    sid = "queue-cancel-steer-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")
    {:ok, ^sid} = start_slow_session(sid)

    Tau.send(sid, "kick")
    assert_receive %SE.MessageStart{session_id: ^sid}, 2_000

    # Queue a steering message and a followup while streaming.
    Tau.steer(sid, "steer-1")
    Tau.steer(sid, "steer-2")
    Tau.send(sid, "followup-1")

    # Cancel while streaming.
    Tau.cancel(sid)
    assert_receive %SE.Cancelled{session_id: ^sid}, 2_000

    # QueueRestored carries the steering messages (not the followup).
    # Messages are %Tau.Message.User{} structs.
    assert_receive %SE.QueueRestored{session_id: ^sid, messages: msgs}, 2_000
    msg_contents = Enum.map(msgs, & &1.content)
    assert "steer-1" in msg_contents
    assert "steer-2" in msg_contents
    assert "followup-1" not in msg_contents

    # The followup queue is non-empty after cancel, so :drain_followups fires
    # immediately on :awaiting_user entry and starts a new turn.
    # Drain that turn before checking the snapshot.
    assert_receive %SE.MessageEnd{session_id: ^sid}, 5_000

    # Steering queue cleared; followup was drained by the post-cancel turn.
    {:ok, snap} = Tau.snapshot(sid)
    assert snap.state == :awaiting_user
    assert snap.queues.steering == []
    assert snap.queues.followup == []
  end

  test "D-082: cancel with empty steering queue does NOT broadcast %QueueRestored{}" do
    sid = "queue-cancel-nosteer-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")
    {:ok, ^sid} = start_slow_session(sid)

    Tau.send(sid, "kick")
    assert_receive %SE.MessageStart{session_id: ^sid}, 2_000

    # Only a followup queued — no steering.
    Tau.send(sid, "followup-1")

    Tau.cancel(sid)
    assert_receive %SE.Cancelled{session_id: ^sid}, 2_000

    # No QueueRestored event (steering was empty).
    refute_receive %SE.QueueRestored{session_id: ^sid}, 200
  end

  # ---------------------------------------------------------------------------
  # D-083 / AC-9: hard cap of 32; messages beyond cap dropped (no crash)
  # ---------------------------------------------------------------------------

  test "D-083/AC-9: followup queue capped at #{@queue_cap}; excess dropped, no crash" do
    sid = "queue-cap-followup-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")
    {:ok, ^sid} = start_slow_session(sid)

    Tau.send(sid, "kick")
    assert_receive %SE.MessageStart{session_id: ^sid}, 2_000

    # Queue 35 followups — 3 beyond the cap.
    overflow = @queue_cap + 3

    for i <- 1..overflow do
      Tau.send(sid, "f-#{i}")
    end

    # Snapshot should show the cap was not exceeded.
    {:ok, snap} = Tau.snapshot(sid)
    assert length(snap.queues.followup) <= @queue_cap

    # Allow the session to drain (receive multiple MessageEnd events).
    # We don't need all of them — just verify the FSM is still alive.
    assert_receive %SE.MessageEnd{session_id: ^sid}, 5_000

    {:ok, snap2} = Tau.snapshot(sid)
    assert snap2.state in [:awaiting_user, :provider_streaming]
  end

  test "D-083/AC-9: steering queue capped at #{@queue_cap}; excess dropped, no crash" do
    sid = "queue-cap-steering-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")
    {:ok, ^sid} = start_slow_session(sid)

    Tau.send(sid, "kick")
    assert_receive %SE.MessageStart{session_id: ^sid}, 2_000

    overflow = @queue_cap + 3

    for i <- 1..overflow do
      Tau.steer(sid, "s-#{i}")
    end

    {:ok, snap} = Tau.snapshot(sid)
    assert length(snap.queues.steering) <= @queue_cap

    # Cancel to restore steering and verify no crash.
    Tau.cancel(sid)
    assert_receive %SE.Cancelled{session_id: ^sid}, 2_000

    {:ok, snap2} = Tau.snapshot(sid)
    assert snap2.state == :awaiting_user
  end

  # ---------------------------------------------------------------------------
  # D-079: steering drain at tool-round boundary (AC-8 ordering invariant)
  # ---------------------------------------------------------------------------

  test "D-079/AC-8: steering message is held in queue during streaming; cancel returns it" do
    # D-079: steering drains only at the tool-round boundary. A pure-text
    # provider (no tool calls) will NOT drain the steering queue between turns —
    # the message stays in the steering queue until a tool round or cancel.
    # This test verifies: (a) steer is enqueued while busy, (b) it is NOT
    # consumed by the follow-up drain path, and (c) cancel returns it via
    # %QueueRestored{}, demonstrating the queue is held correctly (D-082).
    sid = "queue-steer-hold-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")
    {:ok, ^sid} = start_slow_session(sid)

    # Start first turn.
    Tau.send(sid, "turn-1")
    assert_receive %SE.MessageStart{session_id: ^sid}, 2_000

    # Queue a steer while streaming.
    Tau.steer(sid, "steer-held")

    # Verify it's in the steering queue before the turn ends.
    {:ok, snap0} = Tau.snapshot(sid)
    assert snap0.state == :provider_streaming
    steering_contents0 = Enum.map(snap0.queues.steering, & &1.content)
    assert "steer-held" in steering_contents0

    # Drain turn 1.
    assert_receive %SE.MessageEnd{session_id: ^sid}, 5_000

    # After turn ends (no tool round): the follow-up drain runs, but the
    # steering queue should still hold "steer-held" (D-079: only drains at
    # tool-round boundary).
    {:ok, snap1} = Tau.snapshot(sid)
    assert snap1.state == :awaiting_user
    # The steering queue may be empty here because:
    # - Replay provider has no tools, so drain_steering_queue_one doesn't fire.
    # - But the FSM returns to :awaiting_user. The steering queue persists.
    steering_after = Enum.map(snap1.queues.steering, & &1.content)

    assert "steer-held" in steering_after,
           "steering message should remain in queue after non-tool turn; got #{inspect(steering_after)}"
  end

  test "D-079/AC-8: steering at tool-round boundary — message prepended before next provider call" do
    # Full D-079 test with a real tool round. Uses a module-level provider
    # that signals the tool round to the test process.
    sid = "queue-steer-tool-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    defmodule EchoTool do
      @moduledoc false
      @behaviour Tau.Tool

      @impl true
      def name, do: "echo_for_steer_test"

      @impl true
      def description, do: "Returns the input"

      @impl true
      def parameters,
        do: %{"type" => "object", "properties" => %{}, "required" => []}

      @impl true
      def execute(_args, _ctx), do: {:ok, "echo-result"}

      @impl true
      def execution_mode, do: :sequential

      @impl true
      def streams_updates?, do: false
    end

    defmodule EchoToolProvider do
      @moduledoc false
      @behaviour Tau.Provider

      @impl true
      def default_model, do: "echo-tool-model"

      @impl true
      def capabilities,
        do: %{
          thinking: false,
          tools: true,
          vision: false,
          prompt_caching: false,
          parallel_tools: false
        }

      @impl true
      def configure(opts), do: {:ok, opts}

      @impl true
      def stream(messages, _opts, _ctx) do
        has_tool_result? = Enum.any?(messages, &match?(%Tau.Message.ToolResult{}, &1))

        events =
          if has_tool_result? do
            [
              %Event.Start{request_id: "r2", model: "echo-tool-model"},
              %Event.TextStart{block_id: "t1"},
              %Event.TextDelta{block_id: "t1", text: "done"},
              %Event.TextEnd{block_id: "t1"},
              %Event.Done{stop_reason: :stop, usage: %{}}
            ]
          else
            [
              %Event.Start{request_id: "r1", model: "echo-tool-model"},
              %Event.ToolCallStart{tool_call_id: "steer-tc1", name: "echo_for_steer_test"},
              %Event.ToolCallEnd{tool_call_id: "steer-tc1", params: %{}},
              %Event.Done{stop_reason: :tool_use, usage: %{}}
            ]
          end

        {:ok, events}
      end
    end

    # Register EchoTool as a builtin so the session picks it up.
    prior_builtins = Application.get_env(:tau, :builtin_tools, [])
    Application.put_env(:tau, :builtin_tools, [EchoTool | prior_builtins])

    on_exit(fn -> Application.put_env(:tau, :builtin_tools, prior_builtins) end)

    {:ok, ^sid} =
      start_session_for_test(
        provider: EchoToolProvider,
        session_id: sid,
        metadata: %{permissions_mode: :bypass}
      )

    Tau.send(sid, "go")

    # Wait for the tool to execute.
    assert_receive %SE.ToolStart{session_id: ^sid, name: "echo_for_steer_test"}, 3_000

    # Steer while the tool is executing.
    Tau.steer(sid, "post-tool-steer")

    assert_receive %SE.ToolEnd{session_id: ^sid}, 3_000

    # The turn should complete (the steer was drained at the tool-round boundary).
    assert_receive %SE.MessageEnd{session_id: ^sid}, 5_000

    # The steer message was drained into data.messages at the tool-round boundary.
    # After the tool round, drain_steering_queue_one prepends the steer message
    # and calls :start_provider again, producing another turn.
    assert_receive %SE.MessageEnd{session_id: ^sid}, 5_000

    {:ok, snap} = Tau.snapshot(sid)
    assert snap.state == :awaiting_user
    assert snap.queues.steering == []

    # JSONL: verify the steer message was delivered (appears as user_message).
    [path] = Path.wildcard(Path.join(Tau.Settings.data_dir(), "sessions/*/#{sid}.jsonl"))

    user_contents =
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.filter(&(&1["kind"] == "user_message"))
      |> Enum.map(&get_in(&1, ["data", "content"]))

    assert "post-tool-steer" in user_contents,
           "steer message should appear in JSONL; got #{inspect(user_contents)}"
  end

  # ---------------------------------------------------------------------------
  # AC-10: Tau.steer/2 vs Tau.send/2 API contract
  # ---------------------------------------------------------------------------

  test "AC-10: idle session — Tau.steer/2 delivers immediately like Tau.send/2" do
    sid = "queue-steer-idle-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    {:ok, ^sid} =
      start_session_for_test(
        provider: Tau.Providers.Replay,
        model: "replay",
        session_id: sid,
        provider_ctx: %{replay_fixture: slow_fixture()}
      )

    # Session is idle — Tau.steer/2 should deliver immediately (no queuing).
    :ok = Tau.steer(sid, "hello from steer")

    assert_receive %SE.MessageStart{session_id: ^sid}, 2_000
    assert_receive %SE.MessageEnd{session_id: ^sid}, 5_000

    {:ok, snap} = Tau.snapshot(sid)
    assert snap.state == :awaiting_user
    assert snap.queues.steering == []
  end
end
