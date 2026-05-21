defmodule Tau.Session.ToolsWhitelistTest do
  @moduledoc """
  End-to-end coverage for issue #91: a session-spawn-time
  `:tools_whitelist` option restricts which tools a session may call.

  Verifies:

    * `:all` (the default) is a no-op — model-emitted tool calls execute
      normally;
    * a list-valued whitelist filters out non-whitelisted calls before
      `Tau.Permissions.Evaluator`, synthesising an `is_error: true`
      `ToolResult` with the whitelist-attribution message;
    * a tool *on* the whitelist falls through to the permissions
      evaluator and executes normally;
    * `Tau.snapshot/1` exposes the whitelist value.

  The pure-function property at the bottom pins the
  filtered-iff-not-in-list invariant.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  import Tau.Test.SessionHelper, only: [start_session_for_test: 1]
  alias Tau.Provider.Event
  alias Tau.Session.Events, as: SE

  defmodule WhitelistTool do
    @moduledoc false
    @behaviour Tau.Tool
    @impl true
    def name, do: "wl_ok_tool"
    @impl true
    def description, do: "Always allowed."
    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}, "required" => []}
    @impl true
    def execute(_args, _ctx),
      do: {:ok, %Tau.Tool.Result{content: "ran", details: %{}, is_error: false}}

    @impl true
    def execution_mode, do: :parallel
    @impl true
    def streams_updates?, do: false
  end

  defmodule WhitelistBlockedTool do
    @moduledoc false
    @behaviour Tau.Tool
    @impl true
    def name, do: "wl_blocked_tool"
    @impl true
    def description, do: "Should never run when filtered out."
    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}, "required" => []}
    @impl true
    def execute(_args, _ctx),
      do: {:ok, %Tau.Tool.Result{content: "should-not-run", details: %{}, is_error: false}}

    @impl true
    def execution_mode, do: :parallel
    @impl true
    def streams_updates?, do: false
  end

  # Provider that emits ONE tool_call to a configured tool name on the
  # first turn, then a clean :end_turn after the FSM hands back a
  # tool_result. Keeps the test deterministic for any name the test wants
  # the model to "emit".
  defmodule SingleToolCallProvider do
    @moduledoc false
    @behaviour Tau.Provider

    @impl true
    def stream(messages, _opts, ctx) do
      has_tool_result? = Enum.any?(messages, &match?(%Tau.Message.ToolResult{}, &1))
      tool_name = Map.fetch!(ctx, :tool_name)
      call_id = Map.get(ctx, :call_id, "call-91")

      events =
        if has_tool_result? do
          [
            %Event.Start{request_id: "r2", model: "p91"},
            %Event.TextStart{block_id: "t1"},
            %Event.TextDelta{block_id: "t1", text: "ok"},
            %Event.TextEnd{block_id: "t1"},
            %Event.Done{stop_reason: :end_turn, usage: %{}}
          ]
        else
          [
            %Event.Start{request_id: "r1", model: "p91"},
            %Event.ToolCallStart{tool_call_id: call_id, name: tool_name},
            %Event.ToolCallEnd{tool_call_id: call_id, params: %{}},
            %Event.Done{stop_reason: :tool_use, usage: %{}}
          ]
        end

      {:ok, events}
    end

    @impl true
    def capabilities,
      do: %{
        thinking: false,
        tools: true,
        vision: false,
        prompt_caching: false,
        parallel_tools: true
      }

    @impl true
    def default_model, do: "p91"
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "tau-tools-whitelist-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:tau, :data_dir, tmp)

    prior_builtins = Application.get_env(:tau, :builtin_tools, [])

    Application.put_env(
      :tau,
      :builtin_tools,
      [WhitelistTool, WhitelistBlockedTool | prior_builtins]
    )

    on_exit(fn ->
      Application.put_env(:tau, :builtin_tools, prior_builtins)
      File.rm_rf!(tmp)
      Application.delete_env(:tau, :data_dir)
    end)

    :ok
  end

  test ":all (the default) is a no-op — non-whitelisted tools execute normally" do
    sid = "wl-default-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    {:ok, ^sid} =
      start_session_for_test(
        provider: SingleToolCallProvider,
        model: "p91",
        session_id: sid,
        # SPEC-PERMISSION-PROMPTS: bypass permissions so the whitelist
        # filter is the only gate being tested.
        metadata: %{permissions_mode: :bypass},
        provider_ctx: %{tool_name: "wl_blocked_tool", call_id: "call-default"}
      )

    {:ok, snap0} = Tau.snapshot(sid)
    assert snap0.tools_whitelist == :all

    Tau.send(sid, "go")

    assert_receive %SE.ToolEnd{
                     tool_call_id: "call-default",
                     result: %Tau.Message.ToolResult{is_error: false, content: "should-not-run"}
                   },
                   5_000

    assert_receive %SE.MessageEnd{message: %{stop_reason: :end_turn}}, 5_000
  end

  test "list whitelist filters non-listed tool — synthesised is_error ToolResult and clean :end_turn" do
    sid = "wl-filter-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    handler_id = "wl-filter-handler-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:tau, :session, :tool_whitelisted],
      fn _e, _m, meta, _c -> Process.send(test_pid, {:wl_telemetry, meta}, []) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, ^sid} =
      start_session_for_test(
        provider: SingleToolCallProvider,
        model: "p91",
        session_id: sid,
        tools_whitelist: ["wl_ok_tool"],
        provider_ctx: %{tool_name: "wl_blocked_tool", call_id: "call-filter"}
      )

    Tau.send(sid, "go")

    assert_receive %SE.ToolEnd{
                     tool_call_id: "call-filter",
                     result: %Tau.Message.ToolResult{is_error: true, content: content}
                   },
                   5_000

    assert content =~ "wl_blocked_tool"
    assert content =~ "whitelist"

    assert_receive {:wl_telemetry,
                    %{session_id: ^sid, tool_name: "wl_blocked_tool", whitelist_size: 1}},
                   5_000

    assert_receive %SE.MessageEnd{message: %{stop_reason: :end_turn}}, 5_000

    {:ok, snap} = Tau.snapshot(sid)
    assert snap.state == :awaiting_user
    assert snap.tools_whitelist == ["wl_ok_tool"]
  end

  test "tool on whitelist falls through to permissions evaluator and executes" do
    sid = "wl-passthrough-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    {:ok, ^sid} =
      start_session_for_test(
        provider: SingleToolCallProvider,
        model: "p91",
        session_id: sid,
        tools_whitelist: ["wl_ok_tool"],
        provider_ctx: %{tool_name: "wl_ok_tool", call_id: "call-pass"}
      )

    Tau.send(sid, "go")

    assert_receive %SE.ToolEnd{
                     tool_call_id: "call-pass",
                     result: %Tau.Message.ToolResult{is_error: false, content: "ran"}
                   },
                   5_000

    assert_receive %SE.MessageEnd{message: %{stop_reason: :end_turn}}, 5_000
  end

  test "snapshot/1 exposes the whitelist value verbatim" do
    sid = "wl-snap-#{System.unique_integer([:positive])}"

    {:ok, ^sid} =
      start_session_for_test(
        provider: SingleToolCallProvider,
        model: "p91",
        session_id: sid,
        tools_whitelist: ["Read", "Grep"],
        provider_ctx: %{tool_name: "noop", call_id: "noop"}
      )

    {:ok, snap} = Tau.snapshot(sid)
    assert snap.tools_whitelist == ["Read", "Grep"]
  end

  # Pure-function invariant: a tool is filtered iff its name is not on the
  # whitelist (when the whitelist is a list); a `:all` whitelist never
  # filters. Mirrors the `split_tools_whitelist/2` clause inside
  # `Tau.Session`.
  @tag :property
  property "filtered-iff-not-in-list (list whitelist) and never-filtered (:all)" do
    check all(
            tools <-
              StreamData.list_of(
                StreamData.string(:alphanumeric, min_length: 1, max_length: 8),
                max_length: 6
              ),
            whitelist <-
              StreamData.list_of(
                StreamData.string(:alphanumeric, min_length: 1, max_length: 8),
                max_length: 4
              )
          ) do
      calls = Enum.with_index(tools, fn name, i -> %{id: "c#{i}", name: name} end)

      # `:all` => nothing filtered.
      {filtered_all, kept_all} = split_test(calls, :all)
      assert filtered_all == []
      assert kept_all == calls

      # List => filtered iff name not in list.
      {filtered, kept} = split_test(calls, whitelist)
      assert Enum.all?(filtered, fn %{name: n} -> n not in whitelist end)
      assert Enum.all?(kept, fn %{name: n} -> n in whitelist end)
      assert length(filtered) + length(kept) == length(calls)
    end
  end

  # Mirrors the production `split_tools_whitelist/2` exactly. Kept here so
  # the property exercises the same shape without reaching into private
  # functions (same approach as `skill_activation_property_test.exs`).
  defp split_test(calls, :all), do: {[], calls}

  defp split_test(calls, list) when is_list(list) do
    Enum.split_with(calls, fn %{name: n} -> n not in list end)
  end
end
