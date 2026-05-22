defmodule Tau.QA.ToolLoopBrakeTest do
  @moduledoc """
  Hard brake on identical-args tool-call retries (D-060 / #293).
  """

  use ExUnit.Case, async: false

  import Tau.Test.SessionHelper, only: [start_session_for_test: 1]

  alias Tau.Session.Events, as: SE
  alias Tau.Tool.Result

  defmodule RequiresDescriptionTool do
    @moduledoc false
    @behaviour Tau.Tool

    @impl true
    def name, do: "loop_brake_tool"
    @impl true
    def description, do: "Test tool with a required `description` property."

    @impl true
    def parameters,
      do: %{
        "type" => "object",
        "properties" => %{
          "description" => %{"type" => "string"},
          "n" => %{"type" => "integer"}
        },
        "required" => ["description"]
      }

    @impl true
    def execute(args, _ctx),
      do: {:ok, %Result{content: "ok #{inspect(args)}", details: %{}, is_error: false}}

    @impl true
    def execution_mode, do: :parallel
    @impl true
    def streams_updates?, do: false
  end

  defmodule LoopProvider do
    @moduledoc false
    @behaviour Tau.Provider

    alias Tau.Message.ToolResult
    alias Tau.Provider.Event.{Done, Start, ToolCallEnd, ToolCallStart}

    @impl true
    def stream(messages, _opts, ctx) do
      n = Enum.count(messages, &match?(%ToolResult{}, &1))
      call_id = "lp-#{n}-#{System.unique_integer([:positive])}"
      variant = Map.get(ctx, :variant, :identical)

      params =
        case variant do
          :identical -> %{}
          :varied -> %{"n" => n}
        end

      events = [
        %Start{request_id: "lp-#{n}", model: "loopy"},
        %ToolCallStart{tool_call_id: call_id, name: "loop_brake_tool"},
        %ToolCallEnd{tool_call_id: call_id, params: params},
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

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "tau-qa-tool-loop-brake-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    Application.put_env(:tau, :data_dir, tmp)

    prior = Application.get_env(:tau, :builtin_tools, [])
    Application.put_env(:tau, :builtin_tools, [RequiresDescriptionTool | prior])

    on_exit(fn ->
      Application.put_env(:tau, :builtin_tools, prior)
      File.rm_rf!(tmp)
      Application.delete_env(:tau, :data_dir)
    end)

    :ok
  end

  test "brake fires after N identical (tool, args, error) repetitions" do
    sid = "brake-pos-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    test_pid = self()
    handler_id = "brake-pos-tel-#{sid}"

    :telemetry.attach(
      handler_id,
      [:tau, :session, :tool_loop_brake],
      fn _ev, m, meta, _ -> send(test_pid, {:brake_telemetry, m, meta}) end,
      nil
    )

    try do
      {:ok, ^sid} =
        start_session_for_test(
          session_id: sid,
          provider: LoopProvider,
          model: "loopy",
          max_tool_iterations: 50,
          tool_loop_brake_threshold: 3,
          # SPEC-PERMISSION-PROMPTS: bypass permissions — this test exercises
          # tool loop brake detection, not the permission system.
          metadata: %{permissions_mode: :bypass},
          provider_ctx: %{variant: :identical}
        )

      :ok = Tau.send(sid, "go")

      assert_receive %SE.SystemNotice{session_id: ^sid, text: notice_text}, 5_000

      assert notice_text =~ "loop_brake_tool"
      assert notice_text =~ "identical arguments"
      assert notice_text =~ "3x in a row"
      assert notice_text =~ "description"
      assert notice_text =~ "Halting this turn"

      assert_receive %SE.MessageEnd{
                       session_id: ^sid,
                       message: %Tau.Message.Assistant{stop_reason: :tool_loop_aborted}
                     },
                     5_000

      assert_receive {:brake_telemetry, %{count: 3},
                      %{session_id: ^sid, tool_name: "loop_brake_tool"}},
                     1_000

      {:ok, snap} = Tau.snapshot(sid)
      assert snap.state == :awaiting_user
      assert snap.tool_loop_state == %{}
    after
      :telemetry.detach(handler_id)
      Phoenix.PubSub.unsubscribe(Tau.PubSub, "session:#{sid}")
    end
  end

  test "brake does NOT fire when args vary between failures" do
    sid = "brake-neg-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    test_pid = self()
    handler_id = "brake-neg-tel-#{sid}"

    :telemetry.attach(
      handler_id,
      [:tau, :session, :tool_loop_brake],
      fn _ev, m, meta, _ -> send(test_pid, {:brake_telemetry, m, meta}) end,
      nil
    )

    try do
      {:ok, ^sid} =
        start_session_for_test(
          session_id: sid,
          provider: LoopProvider,
          model: "loopy",
          max_tool_iterations: 3,
          tool_loop_brake_threshold: 3,
          # SPEC-PERMISSION-PROMPTS: bypass permissions — this test exercises
          # tool loop brake with varied args, not the permission system.
          metadata: %{permissions_mode: :bypass},
          provider_ctx: %{variant: :varied}
        )

      :ok = Tau.send(sid, "go")

      assert_receive %SE.MessageEnd{
                       session_id: ^sid,
                       message: %Tau.Message.Assistant{
                         stop_reason: :tool_loop_aborted,
                         content: content
                       }
                     },
                     5_000

      text =
        content
        |> Enum.map(fn
          %{type: :text, text: t} -> t
          _ -> ""
        end)
        |> Enum.join("\n")

      assert text =~ "iteration cap"
      refute text =~ "identical arguments"

      refute_received {:brake_telemetry, _, _}

      {:ok, snap} = Tau.snapshot(sid)
      assert snap.state == :awaiting_user
    after
      :telemetry.detach(handler_id)
      Phoenix.PubSub.unsubscribe(Tau.PubSub, "session:#{sid}")
    end
  end
end
