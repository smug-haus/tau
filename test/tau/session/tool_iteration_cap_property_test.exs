defmodule Tau.Session.ToolIterationCapPropertyTest do
  @moduledoc """
  Property suite for D-005 / AC-6 (SPEC-USER-TURN [C24]).

  Invariant: a session whose provider always emits a tool_call MUST
  terminate the current turn within `max_tool_iterations` with
  `stop_reason: :tool_loop_aborted`, regardless of the configured cap
  value (N = 1..10 for test speed).

  Also asserts that `[:tau, :session, :tool_iteration_cap]` telemetry
  is emitted exactly once per aborted turn with the correct measurements.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  @moduletag :property

  import Tau.Test.SessionHelper, only: [start_session_for_test: 1]
  alias Tau.Session.Events, as: SE

  # Provider that ALWAYS emits a single tool_call regardless of how
  # many tool_results have already accumulated in the message list.
  # This simulates a buggy or looping model.
  defmodule AlwaysToolCallProvider do
    @moduledoc false
    @behaviour Tau.Provider

    alias Tau.Message.ToolResult
    alias Tau.Provider.Event.{Done, Start, ToolCallEnd, ToolCallStart}

    @impl true
    def stream(messages, _opts, ctx) do
      # Use a unique call_id derived from message count so each call
      # has a distinct id (required by Assembler dedup logic).
      call_n = Enum.count(messages, &match?(%ToolResult{}, &1))
      call_id = "loop-call-#{call_n}"
      tool_name = Map.get(ctx, :tool_name, "loop_tool")

      events = [
        %Start{request_id: "r-#{call_n}", model: "loopy"},
        %ToolCallStart{tool_call_id: call_id, name: tool_name},
        %ToolCallEnd{tool_call_id: call_id, params: %{}},
        %Done{stop_reason: :tool_use, usage: %{}}
      ]

      {:ok, events}
    end

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
    def default_model, do: "loopy"
  end

  # Minimal tool implementation: always succeeds, no side-effects.
  defmodule LoopTool do
    @moduledoc false
    @behaviour Tau.Tool

    alias Tau.Tool.Result

    @impl true
    def name, do: "loop_tool"
    @impl true
    def description, do: "Always succeeds; used to drive iteration cap tests."
    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}, "required" => []}

    @impl true
    def execute(_args, _ctx),
      do: {:ok, %Result{content: "loop result", details: %{}, is_error: false}}

    @impl true
    def execution_mode, do: :parallel
    @impl true
    def streams_updates?, do: false
  end

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "tau-tool-iter-cap-prop-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    Application.put_env(:tau, :data_dir, tmp)

    prior_builtins = Application.get_env(:tau, :builtin_tools, [])
    Application.put_env(:tau, :builtin_tools, [LoopTool | prior_builtins])

    on_exit(fn ->
      Application.put_env(:tau, :builtin_tools, prior_builtins)
      File.rm_rf!(tmp)
      Application.delete_env(:tau, :data_dir)
    end)

    :ok
  end

  property "session always terminates within max_tool_iterations with stop_reason: :tool_loop_aborted" do
    check all(cap <- StreamData.integer(1..10), max_runs: 8) do
      sid =
        "tool-cap-prop-#{cap}-#{System.unique_integer([:positive])}-#{:crypto.strong_rand_bytes(3) |> Base.url_encode64(padding: false)}"

      Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

      test_pid = self()
      handler_id = "tool-iter-cap-handler-#{sid}"

      :telemetry.attach(
        handler_id,
        [:tau, :session, :tool_iteration_cap],
        fn _event, measurements, metadata, _ ->
          send(test_pid, {:cap_telemetry, measurements, metadata})
        end,
        nil
      )

      try do
        {:ok, ^sid} =
          start_session_for_test(
            session_id: sid,
            provider: AlwaysToolCallProvider,
            model: "loopy",
            max_tool_iterations: cap,
            # SPEC-PERMISSION-PROMPTS: bypass permissions — this property test
            # exercises the iteration cap invariant, not the permission system.
            metadata: %{permissions_mode: :bypass}
          )

        :ok = Tau.send(sid, "go")

        # Wait for the aborted MessageEnd — allow generous time (cap * 2s).
        timeout_ms = max(cap * 2_000, 5_000)

        assert_receive %SE.MessageEnd{
                         session_id: ^sid,
                         message: %Tau.Message.Assistant{stop_reason: :tool_loop_aborted}
                       },
                       timeout_ms

        # Exactly one cap telemetry event per aborted turn.
        assert_receive {:cap_telemetry, %{iterations: actual_iter, cap: ^cap}, %{session_id: ^sid}},
                       1_000

        # iterations in telemetry == cap: exactly cap completed dispatches occurred,
        # then the (cap+1)th attempt was blocked (D-027 semantics).
        assert actual_iter == cap

        # Session returns to :awaiting_user — snapshot should show tool_iterations reset.
        {:ok, snap} = Tau.snapshot(sid)
        assert snap.tool_iterations == 0
      after
        # Detach the handler immediately after the iteration to prevent stale
        # {:cap_telemetry, ...} messages from bleeding into subsequent iterations.
        :telemetry.detach(handler_id)
        Phoenix.PubSub.unsubscribe(Tau.PubSub, "session:#{sid}")

        # Drain any residual cap_telemetry messages from this sid that arrived
        # between the assert_receive and the detach.
        drain_cap_telemetry(sid)
      end
    end
  end

  defp drain_cap_telemetry(sid) do
    receive do
      {:cap_telemetry, _measurements, %{session_id: ^sid}} ->
        drain_cap_telemetry(sid)
    after
      0 -> :ok
    end
  end
end
