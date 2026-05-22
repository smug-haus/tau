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
  alias Tau.Test.BlockingTool

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
  # Module-level provider and tool definitions
  # ---------------------------------------------------------------------------

  # Provider for the AC-10 :awaiting_permission cancel test.
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

  # Provider for the AC-8 / D-079 tests: emits one blocking_test_tool call per
  # round, then plain text once all tool rounds are done.
  #
  # Round detection: counts the number of tool_result messages in the history
  # to determine which round we are in.
  defmodule BlockingToolProvider do
    @moduledoc false
    @behaviour Tau.Provider
    alias Tau.Provider.Event

    @impl true
    def default_model, do: "blocking-tool-model"

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
      # Count how many tool_result messages exist to know which round we're on.
      tool_result_count =
        Enum.count(messages, &match?(%Tau.Message.ToolResult{}, &1))

      # This provider is configured per-test with :max_rounds.
      # We read the round cap from process dictionary set by the test.
      max_rounds = Process.get(:blocking_provider_max_rounds, 1)

      events =
        if tool_result_count < max_rounds do
          call_id = "blocking-tc-#{tool_result_count + 1}"

          [
            %Event.Start{request_id: "br-#{tool_result_count + 1}", model: "blocking-tool-model"},
            %Event.ToolCallStart{tool_call_id: call_id, name: "blocking_test_tool"},
            %Event.ToolCallEnd{tool_call_id: call_id, params: %{}},
            %Event.Done{stop_reason: :tool_use, usage: %{}}
          ]
        else
          [
            %Event.Start{request_id: "br-final", model: "blocking-tool-model"},
            %Event.TextStart{block_id: "bt-final"},
            %Event.TextDelta{block_id: "bt-final", text: "all-rounds-done"},
            %Event.TextEnd{block_id: "bt-final"},
            %Event.Done{stop_reason: :stop, usage: %{}}
          ]
        end

      {:ok, events}
    end
  end

  # Two-round provider for multi-round deterministic example tests.
  # Uses BlockingTool (2 calls) — rounds 1 and 2 — then emits final text.
  # Same logic as BlockingToolProvider with max_rounds hard-coded to 2.
  defmodule TwoRoundBlockingProvider do
    @moduledoc false
    @behaviour Tau.Provider
    alias Tau.Provider.Event

    @impl true
    def default_model, do: "two-round-model"

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
      tool_result_count = Enum.count(messages, &match?(%Tau.Message.ToolResult{}, &1))

      events =
        if tool_result_count < 2 do
          call_id = "two-tc-#{tool_result_count + 1}"

          [
            %Event.Start{
              request_id: "two-br-#{tool_result_count + 1}",
              model: "two-round-model"
            },
            %Event.ToolCallStart{tool_call_id: call_id, name: "blocking_test_tool"},
            %Event.ToolCallEnd{tool_call_id: call_id, params: %{}},
            %Event.Done{stop_reason: :tool_use, usage: %{}}
          ]
        else
          [
            %Event.Start{request_id: "two-final", model: "two-round-model"},
            %Event.TextStart{block_id: "two-final-t"},
            %Event.TextDelta{block_id: "two-final-t", text: "two-rounds-done"},
            %Event.TextEnd{block_id: "two-final-t"},
            %Event.Done{stop_reason: :stop, usage: %{}}
          ]
        end

      {:ok, events}
    end
  end

  # ---------------------------------------------------------------------------
  # Shared helpers
  # ---------------------------------------------------------------------------

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

  # Register BlockingTool as a builtin and self() under the notify name.
  # Returns {prior_builtins} so the on_exit can restore.
  defp setup_blocking_tool do
    prior_builtins = Application.get_env(:tau, :builtin_tools, [])
    Application.put_env(:tau, :builtin_tools, [BlockingTool | prior_builtins])

    # Unregister any stale registration from a previous (crashed) test.
    try do
      Process.unregister(BlockingTool.notify_name())
    rescue
      ArgumentError -> :ok
    end

    Process.register(self(), BlockingTool.notify_name())

    prior_builtins
  end

  defp teardown_blocking_tool(prior_builtins) do
    Application.put_env(:tau, :builtin_tools, prior_builtins)

    try do
      Process.unregister(BlockingTool.notify_name())
    rescue
      ArgumentError -> :ok
    end
  end

  # Read user_message records from the session's JSONL file.
  defp jsonl_user_messages(sid) do
    [path] = Path.wildcard(Path.join(Tau.Settings.data_dir(), "sessions/*/#{sid}.jsonl"))

    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
    |> Enum.filter(&(&1["kind"] == "user_message"))
    |> Enum.map(&get_in(&1, ["data", "content"]))
  end

  # Read all JSONL records and return their kinds in order.
  defp jsonl_record_sequence(sid) do
    [path] = Path.wildcard(Path.join(Tau.Settings.data_dir(), "sessions/*/#{sid}.jsonl"))

    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
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
    assert "steer-must-run" in jsonl_user_messages(sid),
           "steer message must appear in JSONL as user_message; got #{inspect(jsonl_user_messages(sid))}"
  end

  # ---------------------------------------------------------------------------
  # D-079/AC-8: race-free steering-at-tool-round-boundary tests
  #
  # These tests use BlockingTool to guarantee the steering message is in the
  # queue BEFORE the tool round completes. Mechanism:
  #
  #   1. BlockingTool.execute/2 sends {:blocking_tool_executing, executor_pid}
  #      to the test process (registered as BlockingTool.notify_name/0).
  #   2. Test receives that message — tool is blocked, tool_done NOT yet sent.
  #   3. Test calls Tau.steer/2 and confirms via Tau.snapshot/1 the steer is
  #      in the queue.
  #   4. Test calls BlockingTool.release(executor_pid) — tool proceeds.
  #   5. Tool sends {:tool_done, ...} to FSM; FSM drains steering queue (D-079).
  #
  # This eliminates the race: the steer is provably queued before the FSM
  # processes tool_done. The test FAILS if:
  #   - the steer user_message appears BEFORE the tool_result in the JSONL
  #     (orphaned tool_call)
  #   - the steer user_message appears AFTER the final assistant_message
  #     (drain missed the boundary)
  #   - any tool_call lacks a paired tool_result
  # ---------------------------------------------------------------------------

  test "D-079/AC-8: steering at tool-round boundary — strictly ordered in JSONL (1 round)" do
    # Single tool round, steer enqueued during round 1.
    # Verifies D-079: steer appears in JSONL AFTER tool_result and BEFORE the
    # final assistant text. Fails if ordering is wrong in either direction.
    sid = "queue-steer-1round-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    prior_builtins = setup_blocking_tool()

    on_exit(fn -> teardown_blocking_tool(prior_builtins) end)

    {:ok, ^sid} =
      start_session_for_test(
        provider: Tau.Session.MessageQueueTiersTest.BlockingToolProvider,
        session_id: sid,
        metadata: %{permissions_mode: :bypass}
      )

    # Set the round count for BlockingToolProvider (1 tool round).
    Process.put(:blocking_provider_max_rounds, 1)

    Tau.send(sid, "go")

    # Wait for tool to start and block.
    assert_receive {:blocking_tool_executing, executor_pid}, 3_000

    # Tool is blocked: steer is provably enqueued BEFORE tool_done.
    Tau.steer(sid, "steer-at-boundary")

    {:ok, snap} = Tau.snapshot(sid)

    assert snap.state == :tool_executing,
           "FSM must be in :tool_executing while tool is blocked"

    steer_contents = Enum.map(snap.queues.steering, & &1.content)

    assert "steer-at-boundary" in steer_contents,
           "steer MUST be in steering_queue before tool release; got #{inspect(snap.queues)}"

    # Unblock the tool — tool_done fires, D-079 drain runs.
    BlockingTool.release(executor_pid)

    assert_receive %SE.ToolEnd{session_id: ^sid}, 3_000

    # Two MessageEnd events total for a 1-round tool turn:
    #   1. tool-round assistant (broadcast by finalize_assistant before dispatch_tools —
    #      already in mailbox when ToolEnd arrives)
    #   2. final text turn (after D-079 steer drain + :start_provider → stop)
    assert_receive %SE.MessageEnd{session_id: ^sid}, 5_000
    assert_receive %SE.MessageEnd{session_id: ^sid}, 5_000

    {:ok, snap2} = Tau.snapshot(sid)
    assert snap2.state == :awaiting_user
    assert snap2.queues.steering == []

    # Verify strict JSONL ordering invariant (AC-8 / D-079):
    #   user_message("go")
    #   assistant_message (tool_call for blocking-tc-1)
    #   tool_result (blocking-tc-1)
    #   user_message ("steer-at-boundary")   ← MUST be here
    #   assistant_message ("all-rounds-done")
    records = jsonl_record_sequence(sid)
    kinds = Enum.map(records, & &1["kind"])

    tool_result_idx = Enum.find_index(kinds, &(&1 == "tool_result"))

    assert tool_result_idx != nil,
           "AC-8: JSONL must contain a tool_result; got kinds: #{inspect(kinds)}"

    steer_idx =
      kinds
      |> Enum.with_index()
      |> Enum.find(fn {kind, idx} ->
        kind == "user_message" and idx > tool_result_idx
      end)
      |> then(fn
        nil -> nil
        {_, idx} -> idx
      end)

    assert steer_idx != nil,
           "AC-8: steer user_message must appear in JSONL after tool_result; " <>
             "got kinds: #{inspect(kinds)}"

    final_assistant_idx =
      kinds
      |> Enum.with_index()
      |> Enum.find(fn {kind, idx} ->
        kind == "assistant_message" and idx > steer_idx
      end)
      |> then(fn
        nil -> nil
        {_, idx} -> idx
      end)

    assert final_assistant_idx != nil,
           "AC-8: final assistant_message must appear after steer user_message; " <>
             "got kinds: #{inspect(kinds)}"

    steer_record = Enum.at(records, steer_idx)

    assert get_in(steer_record, ["data", "content"]) == "steer-at-boundary",
           "AC-8: steer record content must be 'steer-at-boundary'"

    # Verify no orphaned tool_calls: every assistant tool_call must have a tool_result.
    tool_call_ids =
      records
      |> Enum.filter(&(&1["kind"] == "assistant_message"))
      |> Enum.flat_map(&(get_in(&1, ["data", "content"]) || []))
      |> Enum.filter(&(&1["type"] == "tool_call"))
      |> Enum.map(& &1["id"])

    tool_result_ids =
      records
      |> Enum.filter(&(&1["kind"] == "tool_result"))
      |> Enum.map(&get_in(&1, ["data", "tool_call_id"]))

    assert MapSet.new(tool_call_ids) == MapSet.new(tool_result_ids),
           "AC-8: every tool_call must be paired with a tool_result; " <>
             "calls: #{inspect(tool_call_ids)}, results: #{inspect(tool_result_ids)}"
  end

  test "D-079/AC-8: steering at round-1 of 2-round turn — steer between rounds 1 and 2" do
    # Two-round turn; steer enqueued during round 1 (before round 1 completes).
    # The steer must drain at the round-1 boundary, so the JSONL is:
    #   user ("go"), assistant (tool_call round-1), tool_result (round-1),
    #   user ("steer-round-1"), assistant (tool_call round-2), tool_result (round-2),
    #   assistant ("two-rounds-done")
    sid = "queue-steer-round1of2-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    prior_builtins = setup_blocking_tool()
    on_exit(fn -> teardown_blocking_tool(prior_builtins) end)

    {:ok, ^sid} =
      start_session_for_test(
        provider: Tau.Session.MessageQueueTiersTest.TwoRoundBlockingProvider,
        session_id: sid,
        metadata: %{permissions_mode: :bypass}
      )

    Tau.send(sid, "go")

    # Round 1: block and steer.
    assert_receive {:blocking_tool_executing, exec1_pid}, 3_000
    Tau.steer(sid, "steer-round-1")

    {:ok, snap} = Tau.snapshot(sid)
    assert "steer-round-1" in Enum.map(snap.queues.steering, & &1.content)

    BlockingTool.release(exec1_pid)
    assert_receive %SE.ToolEnd{session_id: ^sid}, 3_000

    # D-079 drains steer at round-1 boundary. Provider sees steer+tool_result,
    # emits round-2 tool_call. Block on round 2.
    assert_receive {:blocking_tool_executing, exec2_pid}, 3_000

    # No steer for round 2 — release immediately.
    BlockingTool.release(exec2_pid)
    assert_receive %SE.ToolEnd{session_id: ^sid}, 3_000

    # Drain 3 MessageEnd events total:
    #   1. round-1 assistant (broadcast by finalize_assistant before dispatching tools)
    #   2. round-2 assistant (same — fires before exec2 unblocks)
    #   3. final text turn
    # MessageEnds #1 and #2 are already in the mailbox when we reach this point.
    assert_receive %SE.MessageEnd{session_id: ^sid}, 5_000
    assert_receive %SE.MessageEnd{session_id: ^sid}, 5_000
    assert_receive %SE.MessageEnd{session_id: ^sid}, 5_000

    {:ok, snap2} = Tau.snapshot(sid)
    assert snap2.state == :awaiting_user
    assert snap2.queues.steering == []

    # Strict JSONL ordering: steer appears after round-1 tool_result and before
    # round-2 assistant_message.
    records = jsonl_record_sequence(sid)
    kinds = Enum.map(records, & &1["kind"])

    # Find round-1 tool_result index.
    tr1_idx = Enum.find_index(kinds, &(&1 == "tool_result"))
    assert tr1_idx != nil, "JSONL must have a tool_result for round 1"

    # Find steer user_message AFTER round-1 tool_result.
    steer_idx =
      kinds
      |> Enum.with_index()
      |> Enum.find(fn {kind, idx} ->
        kind == "user_message" and idx > tr1_idx
      end)
      |> then(fn
        nil -> nil
        {_, idx} -> idx
      end)

    assert steer_idx != nil,
           "AC-8: steer user_message must appear after round-1 tool_result; " <>
             "kinds: #{inspect(kinds)}"

    steer_record = Enum.at(records, steer_idx)

    assert get_in(steer_record, ["data", "content"]) == "steer-round-1",
           "steer record must contain 'steer-round-1'"

    # Round-2 assistant_message must come AFTER the steer user_message.
    round2_assistant_idx =
      kinds
      |> Enum.with_index()
      |> Enum.find(fn {kind, idx} ->
        kind == "assistant_message" and idx > steer_idx
      end)
      |> then(fn
        nil -> nil
        {_, idx} -> idx
      end)

    assert round2_assistant_idx != nil,
           "AC-8: round-2 assistant_message must appear after steer; kinds: #{inspect(kinds)}"

    # No orphaned tool_calls.
    tool_call_ids =
      records
      |> Enum.filter(&(&1["kind"] == "assistant_message"))
      |> Enum.flat_map(&(get_in(&1, ["data", "content"]) || []))
      |> Enum.filter(&(&1["type"] == "tool_call"))
      |> Enum.map(& &1["id"])

    tool_result_ids =
      records
      |> Enum.filter(&(&1["kind"] == "tool_result"))
      |> Enum.map(&get_in(&1, ["data", "tool_call_id"]))

    assert MapSet.new(tool_call_ids) == MapSet.new(tool_result_ids),
           "every tool_call must be paired with a tool_result"
  end

  test "D-079/AC-8: steering at round-2 of 2-round turn — steer enqueued after round 1 completes" do
    # Two-round turn; steer enqueued during round 2 (while round-2 tool executes).
    # No steer during round 1. The steer drains at the round-2 boundary.
    sid = "queue-steer-round2of2-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    prior_builtins = setup_blocking_tool()
    on_exit(fn -> teardown_blocking_tool(prior_builtins) end)

    {:ok, ^sid} =
      start_session_for_test(
        provider: Tau.Session.MessageQueueTiersTest.TwoRoundBlockingProvider,
        session_id: sid,
        metadata: %{permissions_mode: :bypass}
      )

    Tau.send(sid, "go")

    # Round 1: release immediately (no steer for this round).
    assert_receive {:blocking_tool_executing, exec1_pid}, 3_000
    BlockingTool.release(exec1_pid)
    assert_receive %SE.ToolEnd{session_id: ^sid}, 3_000

    # Round 2: block and steer.
    assert_receive {:blocking_tool_executing, exec2_pid}, 3_000
    Tau.steer(sid, "steer-round-2")

    {:ok, snap} = Tau.snapshot(sid)
    assert "steer-round-2" in Enum.map(snap.queues.steering, & &1.content)

    BlockingTool.release(exec2_pid)
    assert_receive %SE.ToolEnd{session_id: ^sid}, 3_000

    # Drain 3 MessageEnd events total:
    #   1. round-1 assistant (already in mailbox — fires before exec1 blocks)
    #   2. round-2 assistant (already in mailbox — fires before exec2 blocks)
    #   3. final text turn
    assert_receive %SE.MessageEnd{session_id: ^sid}, 5_000
    assert_receive %SE.MessageEnd{session_id: ^sid}, 5_000
    assert_receive %SE.MessageEnd{session_id: ^sid}, 5_000

    {:ok, snap2} = Tau.snapshot(sid)
    assert snap2.state == :awaiting_user
    assert snap2.queues.steering == []

    # Strict JSONL ordering: steer appears after round-2 tool_result.
    records = jsonl_record_sequence(sid)
    kinds = Enum.map(records, & &1["kind"])

    # Two tool_result entries. Find the SECOND one (round 2).
    tool_result_indices =
      kinds
      |> Enum.with_index()
      |> Enum.filter(fn {k, _} -> k == "tool_result" end)
      |> Enum.map(fn {_, i} -> i end)

    assert length(tool_result_indices) == 2,
           "two-round turn must have exactly 2 tool_results; kinds: #{inspect(kinds)}"

    tr2_idx = List.last(tool_result_indices)

    steer_idx =
      kinds
      |> Enum.with_index()
      |> Enum.find(fn {kind, idx} ->
        kind == "user_message" and idx > tr2_idx
      end)
      |> then(fn
        nil -> nil
        {_, idx} -> idx
      end)

    assert steer_idx != nil,
           "AC-8: steer user_message must appear after round-2 tool_result; " <>
             "kinds: #{inspect(kinds)}"

    steer_record = Enum.at(records, steer_idx)

    assert get_in(steer_record, ["data", "content"]) == "steer-round-2",
           "steer record must contain 'steer-round-2'"
  end

  # ---------------------------------------------------------------------------
  # AC-8 property: tool_call/tool_result pairing + strict ordering invariant
  #
  # Property: for any steer_text, the JSONL transcript from a 1-round tool turn
  # with a steer enqueued during tool execution (blocking, race-free) MUST have:
  #   1. Every tool_call paired with a tool_result.
  #   2. The steer user_message at a position strictly between the tool_result
  #      and the next assistant_message.
  #
  # This property FAILS if:
  #   - The steer drains before the tool_result (orphaned tool_call).
  #   - The steer is absent or after the final assistant_message (drain missed).
  #   - Tool pairing is broken in any way.
  #
  # The race is eliminated by BlockingTool: the steer is provably in the queue
  # before {:tool_done} fires.
  # ---------------------------------------------------------------------------

  property "AC-8: tool_call/tool_result pairing preserved; steer strictly after tool_result" do
    check all(
            steer_text <- StreamData.string(:alphanumeric, min_length: 1, max_length: 32),
            max_runs: 8
          ) do
      sid = "queue-ac8-prop-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

      prior_builtins = setup_blocking_tool()

      # on_exit is not available inside check all — clean up synchronously at
      # the end of each iteration (see teardown below the assertions).
      {:ok, ^sid} =
        start_session_for_test(
          provider: Tau.Session.MessageQueueTiersTest.BlockingToolProvider,
          session_id: sid,
          metadata: %{permissions_mode: :bypass}
        )

      Process.put(:blocking_provider_max_rounds, 1)

      Tau.send(sid, "go")

      # Wait for tool to block.
      assert_receive {:blocking_tool_executing, executor_pid}, 3_000

      # Steer is provably enqueued before tool_done.
      Tau.steer(sid, steer_text)

      # Confirm steer is in steering_queue BEFORE releasing the tool.
      {:ok, snap} = Tau.snapshot(sid)

      assert Enum.any?(snap.queues.steering, &(&1.content == steer_text)),
             "steer MUST be in queue before release; snap.queues: #{inspect(snap.queues)}"

      # Unblock the tool — tool_done fires, D-079 drain runs.
      BlockingTool.release(executor_pid)

      assert_receive %SE.ToolEnd{session_id: ^sid}, 3_000
      # Two MessageEnds for 1-round tool turn:
      #   1. tool-round assistant (already in mailbox — fires before dispatcher blocks)
      #   2. final text (after D-079 drain + :start_provider → stop)
      assert_receive %SE.MessageEnd{session_id: ^sid}, 5_000
      assert_receive %SE.MessageEnd{session_id: ^sid}, 5_000

      Phoenix.PubSub.unsubscribe(Tau.PubSub, "session:#{sid}")

      records = jsonl_record_sequence(sid)
      kinds = Enum.map(records, & &1["kind"])

      # Invariant 1: every tool_call has a paired tool_result.
      tool_call_ids =
        records
        |> Enum.filter(&(&1["kind"] == "assistant_message"))
        |> Enum.flat_map(&(get_in(&1, ["data", "content"]) || []))
        |> Enum.filter(&(&1["type"] == "tool_call"))
        |> Enum.map(& &1["id"])

      tool_result_ids =
        records
        |> Enum.filter(&(&1["kind"] == "tool_result"))
        |> Enum.map(&get_in(&1, ["data", "tool_call_id"]))

      assert MapSet.new(tool_call_ids) == MapSet.new(tool_result_ids),
             "AC-8 VIOLATED: tool_call IDs must equal tool_result IDs.\n" <>
               "  calls:   #{inspect(tool_call_ids)}\n" <>
               "  results: #{inspect(tool_result_ids)}"

      # Invariant 2: steer user_message appears strictly AFTER tool_result.
      tool_result_idx = Enum.find_index(kinds, &(&1 == "tool_result"))

      assert tool_result_idx != nil,
             "AC-8: JSONL must contain a tool_result; kinds: #{inspect(kinds)}"

      steer_idx =
        kinds
        |> Enum.with_index()
        |> Enum.find(fn {kind, idx} ->
          kind == "user_message" and idx > tool_result_idx
        end)
        |> then(fn
          nil -> nil
          {_, i} -> i
        end)

      assert steer_idx != nil,
             "AC-8: steer user_message must appear after tool_result in JSONL; " <>
               "kinds: #{inspect(kinds)}"

      # Invariant 3: final assistant_message appears strictly AFTER steer.
      final_assistant_idx =
        kinds
        |> Enum.with_index()
        |> Enum.find(fn {kind, idx} ->
          kind == "assistant_message" and idx > steer_idx
        end)
        |> then(fn
          nil -> nil
          {_, i} -> i
        end)

      assert final_assistant_idx != nil,
             "AC-8: final assistant_message must appear after steer in JSONL; " <>
               "kinds: #{inspect(kinds)}"

      # Invariant 4: steer content matches.
      steer_record = Enum.at(records, steer_idx)

      assert get_in(steer_record, ["data", "content"]) == steer_text,
             "AC-8: steer content must be #{inspect(steer_text)}; " <>
               "got #{inspect(get_in(steer_record, ["data", "content"]))}"

      # Cleanup: restore builtins for next iteration.
      teardown_blocking_tool(prior_builtins)
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
    assert_receive %SE.ToolEnd{
                     session_id: ^sid,
                     tool_call_id: "perm-tc1",
                     result: denied_result
                   },
                   2_000

    # FIX-2: assert the ToolEnd result is an is_error denial, not just that
    # a ToolEnd fired. This is the specific contract from #341.
    assert denied_result.is_error == true,
           "AC-10: cancelled :awaiting_permission must produce an is_error ToolResult; " <>
             "got is_error=#{inspect(denied_result.is_error)}"

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
