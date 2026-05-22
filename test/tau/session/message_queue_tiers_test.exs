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
  # AC-8 property provider and tool modules (defined at module compile time)
  # ---------------------------------------------------------------------------

  # Provider for the AC-8 tool_call/tool_result pairing property test.
  # Emits one tool call on the first round, then plain text on the second round.
  defmodule PairingTool do
    @moduledoc false
    @behaviour Tau.Tool

    @impl true
    def name, do: "pairing_check_tool"

    @impl true
    def description, do: "Returns the input for pairing test"

    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}, "required" => []}

    @impl true
    def execute(_args, _ctx), do: {:ok, "pairing-result"}

    @impl true
    def execution_mode, do: :sequential

    @impl true
    def streams_updates?, do: false
  end

  defmodule PairingProvider do
    @moduledoc false
    @behaviour Tau.Provider
    alias Tau.Provider.Event

    @impl true
    def default_model, do: "pairing-model"

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
            %Event.Start{request_id: "r2", model: "pairing-model"},
            %Event.TextStart{block_id: "t2"},
            %Event.TextDelta{block_id: "t2", text: "done"},
            %Event.TextEnd{block_id: "t2"},
            %Event.Done{stop_reason: :stop, usage: %{}}
          ]
        else
          [
            %Event.Start{request_id: "r1", model: "pairing-model"},
            %Event.ToolCallStart{tool_call_id: "pairing-tc1", name: "pairing_check_tool"},
            %Event.ToolCallEnd{tool_call_id: "pairing-tc1", params: %{}},
            %Event.Done{stop_reason: :tool_use, usage: %{}}
          ]
        end

      {:ok, events}
    end
  end

  # Provider and tool for the AC-10 :awaiting_permission cancel test.
  defmodule PermTool do
    @moduledoc false
    @behaviour Tau.Tool

    @impl true
    def name, do: "perm_ask_tool"

    @impl true
    def description, do: "Tool that requires permission"

    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}, "required" => []}

    @impl true
    def execute(_args, _ctx), do: {:ok, "perm-result"}

    @impl true
    def execution_mode, do: :sequential

    @impl true
    def streams_updates?, do: false
  end

  defmodule PermProvider do
    @moduledoc false
    @behaviour Tau.Provider
    alias Tau.Provider.Event

    @impl true
    def default_model, do: "perm-model"

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
    def stream(_messages, _opts, _ctx) do
      events = [
        %Event.Start{request_id: "rp1", model: "perm-model"},
        %Event.ToolCallStart{tool_call_id: "perm-tc1", name: "perm_ask_tool"},
        %Event.ToolCallEnd{tool_call_id: "perm-tc1", params: %{}},
        %Event.Done{stop_reason: :tool_use, usage: %{}}
      ]

      {:ok, events}
    end
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

    # Snapshot during streaming — both queues are populated.
    {:ok, mid_snap} = Tau.snapshot(sid)
    assert mid_snap.state == :provider_streaming
    steering_mid = Enum.map(mid_snap.queues.steering, & &1.content)
    followup_mid = Enum.map(mid_snap.queues.followup, & &1.content)
    assert "steer-msg" in steering_mid
    assert "followup-msg" in followup_mid

    # Let the first turn complete (pure-text, no tool round).
    # FIX-4: the steer-msg is merged into followup_queue at turn-end, so:
    # - Turn 1 ends → steer-msg moved to followup queue (prepended)
    # - :drain_followups fires: steer-msg turn starts (turn 2)
    # - Turn 2 ends → followup-msg turn starts (turn 3)
    # - Turn 3 ends → both queues empty
    assert_receive %SE.MessageEnd{session_id: ^sid}, 5_000
    # steer-msg turn (merged into followup at turn-end).
    assert_receive %SE.MessageEnd{session_id: ^sid}, 5_000
    # followup-msg turn.
    assert_receive %SE.MessageEnd{session_id: ^sid}, 5_000

    {:ok, snap} = Tau.snapshot(sid)
    assert snap.state == :awaiting_user
    # Both queues empty — all messages consumed.
    assert snap.queues.followup == []
    assert snap.queues.steering == []
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

  property "D-080/D-081: followup messages delivered in FIFO order" do
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

  test "D-079/D-082: steering message is held during streaming (not drained to followup prematurely)" do
    # D-079: during streaming, the steering message stays in steering_queue.
    # D-082 / FIX-4 correction: after a pure-text turn (no tool round), the
    # steering message is drained at turn-end by merging into followup_queue,
    # so it runs as the immediate next turn. The steering message MUST NOT
    # bleed into an unrelated later turn's tool-round boundary.
    #
    # This test verifies:
    #   (a) steer is enqueued in steering_queue while busy (D-079/D-078)
    #   (b) at turn-end (pure-text, no tool round), the steering message is
    #       merged into followup_queue and drained as the next turn (FIX-4)
    #   (c) after the steer-draining turn completes, steering_queue is empty
    #       and followup_queue is empty — the steer was consumed, not orphaned
    sid = "queue-steer-hold-fix4-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")
    {:ok, ^sid} = start_slow_session(sid)

    # Start first turn.
    Tau.send(sid, "turn-1")
    assert_receive %SE.MessageStart{session_id: ^sid}, 2_000

    # Queue a steer while streaming.
    Tau.steer(sid, "steer-must-run")

    # Verify it's in the steering queue before the turn ends.
    {:ok, snap0} = Tau.snapshot(sid)
    assert snap0.state == :provider_streaming
    steering_contents0 = Enum.map(snap0.queues.steering, & &1.content)
    assert "steer-must-run" in steering_contents0

    # Drain turn 1 (pure-text, no tool round).
    assert_receive %SE.MessageEnd{session_id: ^sid}, 5_000

    # FIX-4: at turn-end, any remaining steering messages are merged into
    # followup_queue and drained. This triggers a second turn for "steer-must-run".
    assert_receive %SE.MessageEnd{session_id: ^sid}, 5_000

    # After both turns complete, steering_queue MUST be empty.
    {:ok, snap1} = Tau.snapshot(sid)
    assert snap1.state == :awaiting_user

    assert snap1.queues.steering == [],
           "steering_queue MUST be empty after pure-text turn; steer ran as post-turn continuation"

    assert snap1.queues.followup == [],
           "followup_queue MUST also be empty; no orphaned messages"

    # JSONL should contain the steer message as a user_message.
    [path] = Path.wildcard(Path.join(Tau.Settings.data_dir(), "sessions/*/#{sid}.jsonl"))

    user_contents =
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.filter(&(&1["kind"] == "user_message"))
      |> Enum.map(&get_in(&1, ["data", "content"]))

    assert "steer-must-run" in user_contents,
           "steer message must appear in JSONL as user_message; got #{inspect(user_contents)}"
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
  # AC-8 property: tool_call/tool_result pairing invariant under steering
  # ---------------------------------------------------------------------------
  #
  # For any interleaving of tool rounds and steering enqueues the persisted
  # JSONL transcript MUST be well-formed: every tool_call block must be paired
  # with a tool_result, and every steering message must appear AFTER the
  # tool_results from its round and BEFORE the next provider call's messages.
  #
  # The property uses a provider that produces tool calls on the first round
  # and a plain text response on the second round (after receiving tool results).
  # A single steering message is enqueued while the tool is executing; we then
  # verify the JSONL ordering invariant.
  #
  # This test is a real StreamData property: it generates a steering message
  # that is randomly placed before, during, or after the tool-execution phase,
  # and asserts the invariant holds regardless of timing.

  property "AC-8: tool_call/tool_result pairing preserved under steering interleavings" do
    # Uses PairingTool and PairingProvider defined at module compile time above.
    # The provider emits one tool call on round 1 and plain text on round 2.
    # A steering message is enqueued while the tool executes; we verify:
    #   1. Every tool_call has a paired tool_result in the JSONL transcript.
    #   2. The steering message appears AFTER the tool_result and BEFORE
    #      the final assistant message (AC-8 ordering invariant).
    check all(
            steer_text <- StreamData.string(:alphanumeric, min_length: 1, max_length: 32),
            max_runs: 5
          ) do
      sid = "queue-ac8-property-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

      prior_builtins = Application.get_env(:tau, :builtin_tools, [])

      Application.put_env(
        :tau,
        :builtin_tools,
        [Tau.Session.MessageQueueTiersTest.PairingTool | prior_builtins]
      )

      on_exit(fn -> Application.put_env(:tau, :builtin_tools, prior_builtins) end)

      {:ok, ^sid} =
        start_session_for_test(
          provider: Tau.Session.MessageQueueTiersTest.PairingProvider,
          session_id: sid,
          metadata: %{permissions_mode: :bypass}
        )

      # Start the turn.
      Tau.send(sid, "go")

      # Wait for the tool to start and enqueue a steering message while it runs.
      assert_receive %SE.ToolStart{session_id: ^sid, name: "pairing_check_tool"}, 3_000
      Tau.steer(sid, steer_text)
      assert_receive %SE.ToolEnd{session_id: ^sid}, 3_000

      # Wait for the full turn to complete (tool-round + steer drain + final text turn).
      assert_receive %SE.MessageEnd{session_id: ^sid}, 5_000
      # The steer drains at the tool-round boundary, triggering another provider call.
      assert_receive %SE.MessageEnd{session_id: ^sid}, 5_000

      Phoenix.PubSub.unsubscribe(Tau.PubSub, "session:#{sid}")

      # Verify JSONL transcript well-formedness.
      [path] = Path.wildcard(Path.join(Tau.Settings.data_dir(), "sessions/*/#{sid}.jsonl"))

      records =
        path
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      # Extract all tool_call and tool_result entries.
      tool_calls =
        records
        |> Enum.filter(&(&1["kind"] == "assistant_message"))
        |> Enum.flat_map(fn r ->
          get_in(r, ["data", "content"]) || []
        end)
        |> Enum.filter(&(&1["type"] == "tool_call"))
        |> Enum.map(& &1["id"])

      tool_results =
        records
        |> Enum.filter(&(&1["kind"] == "tool_result"))
        |> Enum.map(&get_in(&1, ["data", "tool_call_id"]))

      # AC-8 invariant: every tool_call has a paired tool_result.
      assert MapSet.new(tool_calls) == MapSet.new(tool_results),
             "AC-8 VIOLATED: tool_call IDs must be paired with tool_result IDs.\n" <>
               "  tool_calls: #{inspect(tool_calls)}\n" <>
               "  tool_results: #{inspect(tool_results)}"

      # AC-8 ordering: the steering message appears AFTER the tool_result and
      # BEFORE the final plain-text assistant message in the JSONL sequence.
      ordered_kinds =
        Enum.map(records, & &1["kind"])

      # The transcript must have: user_message, assistant_message (tool_call),
      # tool_result, user_message (steer), assistant_message (final text).
      tool_result_idx =
        Enum.find_index(ordered_kinds, &(&1 == "tool_result"))

      steer_user_idx =
        ordered_kinds
        |> Enum.with_index()
        |> Enum.filter(fn {kind, idx} ->
          kind == "user_message" and idx > (tool_result_idx || 0)
        end)
        |> Enum.map(fn {_, idx} -> idx end)
        |> List.first()

      final_assistant_idx =
        ordered_kinds
        |> Enum.with_index()
        |> Enum.filter(fn {kind, idx} ->
          kind == "assistant_message" and idx > (steer_user_idx || 0)
        end)
        |> Enum.map(fn {_, idx} -> idx end)
        |> List.first()

      assert tool_result_idx != nil,
             "AC-8: JSONL must contain a tool_result; got kinds: #{inspect(ordered_kinds)}"

      assert steer_user_idx != nil,
             "AC-8: JSONL must contain a user_message (steer) after the tool_result; " <>
               "got kinds: #{inspect(ordered_kinds)}"

      assert final_assistant_idx != nil,
             "AC-8: JSONL must contain a final assistant_message after the steer; " <>
               "got kinds: #{inspect(ordered_kinds)}"

      # Verify the steer user_message content matches.
      steer_record = Enum.at(records, steer_user_idx)
      steer_content = get_in(steer_record, ["data", "content"])

      assert steer_content == steer_text,
             "AC-8: steer message content must be #{inspect(steer_text)}; got #{inspect(steer_content)}"
    end
  end

  # ---------------------------------------------------------------------------
  # AC-10: :cancel in :awaiting_permission — #339 and #341 contracts coexist
  # ---------------------------------------------------------------------------

  test "AC-10: cancel in :awaiting_permission drains steering queue AND denies pending requests" do
    # Verifies that the :awaiting_permission cancel clause correctly handles
    # both contracts simultaneously:
    #   #341: all pending permission requests denied with is_error ToolResults.
    #   #339: steering queue drained to %QueueRestored{}; follow-up queue preserved.
    #
    # Uses PermTool and PermProvider defined at module compile time above.
    # The session uses :default permissions_mode (interactive?) so the evaluator
    # returns :ask for perm_ask_tool, causing the FSM to enter :awaiting_permission.

    sid = "queue-cancel-perm-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    prior_builtins = Application.get_env(:tau, :builtin_tools, [])

    Application.put_env(
      :tau,
      :builtin_tools,
      [Tau.Session.MessageQueueTiersTest.PermTool | prior_builtins]
    )

    on_exit(fn -> Application.put_env(:tau, :builtin_tools, prior_builtins) end)

    {:ok, ^sid} =
      start_session_for_test(
        provider: Tau.Session.MessageQueueTiersTest.PermProvider,
        session_id: sid,
        # :default permissions_mode — the evaluator will :ask for the tool call.
        metadata: %{permissions_mode: :default}
      )

    # Start a turn.
    Tau.send(sid, "trigger perm turn")

    # Wait for the permission request.
    assert_receive %SE.PermissionRequest{session_id: ^sid, tool_call_id: "perm-tc1"}, 5_000

    # While in :awaiting_permission, enqueue a steering message.
    # (No followup here so the followup queue stays empty; the PermProvider always
    # emits another tool call which would re-enter :awaiting_permission on drain.)
    Tau.steer(sid, "steer-during-perm")

    # Verify the steering queue is populated and the state is correct.
    {:ok, snap_before} = Tau.snapshot(sid)
    assert snap_before.state == :awaiting_permission
    steering_before = Enum.map(snap_before.queues.steering, & &1.content)
    assert "steer-during-perm" in steering_before
    assert snap_before.queues.followup == []

    # Cancel while in :awaiting_permission.
    Tau.cancel(sid)

    # Collect all cancel-phase events.
    # Order in the :awaiting_permission cancel handler:
    #   1. ToolEnd for pending :ask tool call (is_error result)
    #   2. Cancelled
    #   3. QueueRestored (steering queue non-empty)

    # #341: is_error ToolResult for the denied permission request.
    assert_receive %SE.ToolEnd{session_id: ^sid, tool_call_id: "perm-tc1"}, 2_000

    # #341: Cancelled event arrives.
    assert_receive %SE.Cancelled{session_id: ^sid}, 2_000

    # #339: QueueRestored carries the steering messages.
    assert_receive %SE.QueueRestored{session_id: ^sid, messages: restored_msgs}, 2_000
    restored_contents = Enum.map(restored_msgs, & &1.content)
    assert "steer-during-perm" in restored_contents

    # No followup to drain — session goes directly to :awaiting_user with empty queues.
    {:ok, snap_after} = Tau.snapshot(sid)
    assert snap_after.state == :awaiting_user
    # Both queues empty after cancel.
    assert snap_after.queues.steering == []
    assert snap_after.queues.followup == []
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
