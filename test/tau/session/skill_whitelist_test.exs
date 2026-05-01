defmodule Tau.Session.SkillWhitelistTest do
  @moduledoc """
  End-to-end coverage for issue #16 / ADR-0013:

    * an `active_skill` set on `data` causes `dispatch_tools/2` to
      synthesise a `is_error: true` `ToolResult` for any tool not on
      the skill's `allowed_tools` whitelist;
    * `data.active_skill` is cleared on `:end_turn` (the model
      finished the skill task);
    * `data.active_skill` is cleared on `:cancel`.
  """
  use ExUnit.Case, async: false

  import Tau.Test.SessionHelper, only: [start_session_for_test: 1]
  alias Tau.Provider.Event
  alias Tau.Session.Events, as: SE

  defmodule WhitelistedTool do
    @moduledoc false
    @behaviour Tau.Tool
    @impl true
    def name, do: "skill_ok_tool"
    @impl true
    def description, do: "Always allowed."
    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}, "required" => []}
    @impl true
    def execute(_args, _ctx),
      do: {:ok, %Tau.Tool.Result{content: "ok", details: %{}, is_error: false}}

    @impl true
    def execution_mode, do: :parallel
    @impl true
    def streams_updates?, do: false
  end

  defmodule BlockedTool do
    @moduledoc false
    @behaviour Tau.Tool
    @impl true
    def name, do: "skill_blocked_tool"
    @impl true
    def description, do: "Should never run when whitelisted skill is active."
    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}, "required" => []}
    @impl true
    def execute(_args, _ctx),
      do: {:ok, %Tau.Tool.Result{content: "must-not-see-this", details: %{}, is_error: false}}

    @impl true
    def execution_mode, do: :parallel
    @impl true
    def streams_updates?, do: false
  end

  defmodule ProviderEmittingBlocked do
    @moduledoc false
    @behaviour Tau.Provider

    @impl true
    def stream(messages, _opts, _ctx) do
      has_tool_result? = Enum.any?(messages, &match?(%Tau.Message.ToolResult{}, &1))

      events =
        if has_tool_result? do
          [
            %Event.Start{request_id: "r2", model: "p16"},
            %Event.TextStart{block_id: "t1"},
            %Event.TextDelta{block_id: "t1", text: "ack"},
            %Event.TextEnd{block_id: "t1"},
            %Event.Done{stop_reason: :end_turn, usage: %{}}
          ]
        else
          [
            %Event.Start{request_id: "r1", model: "p16"},
            %Event.ToolCallStart{tool_call_id: "call-blocked", name: "skill_blocked_tool"},
            %Event.ToolCallEnd{tool_call_id: "call-blocked", params: %{}},
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
    def default_model, do: "p16"
  end

  defmodule EndTurnProvider do
    @moduledoc false
    @behaviour Tau.Provider

    @impl true
    def stream(_messages, _opts, _ctx) do
      {:ok,
       [
         %Event.Start{request_id: "r", model: "et"},
         %Event.TextStart{block_id: "t"},
         %Event.TextDelta{block_id: "t", text: "done"},
         %Event.TextEnd{block_id: "t"},
         %Event.Done{stop_reason: :end_turn, usage: %{}}
       ]}
    end

    @impl true
    def capabilities,
      do: %{
        thinking: false,
        tools: false,
        vision: false,
        prompt_caching: false,
        parallel_tools: false
      }

    @impl true
    def default_model, do: "et"
  end

  defmodule HangingProvider do
    @moduledoc false
    @behaviour Tau.Provider

    @impl true
    def stream(_messages, _opts, _ctx) do
      {:ok,
       Stream.resource(
         fn -> :ok end,
         fn :ok ->
           Process.sleep(:infinity)
           {:halt, :ok}
         end,
         fn _ -> :ok end
       )}
    end

    @impl true
    def capabilities,
      do: %{
        thinking: false,
        tools: false,
        vision: false,
        prompt_caching: false,
        parallel_tools: false
      }

    @impl true
    def default_model, do: "hang"
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "tau-skill-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:tau, :data_dir, tmp)

    prior_builtins = Application.get_env(:tau, :builtin_tools, [])

    Application.put_env(
      :tau,
      :builtin_tools,
      [WhitelistedTool, BlockedTool | prior_builtins]
    )

    on_exit(fn ->
      Application.put_env(:tau, :builtin_tools, prior_builtins)
      File.rm_rf!(tmp)
      Application.delete_env(:tau, :data_dir)
    end)

    :ok
  end

  defp set_active_skill(sid, skill) do
    [{pid, _}] = Registry.lookup(Tau.Sessions.Registry, sid)

    :sys.replace_state(pid, fn {state, data} ->
      {state, %{data | active_skill: skill}}
    end)
  end

  defp active_skill(sid) do
    [{pid, _}] = Registry.lookup(Tau.Sessions.Registry, sid)
    {_state, data} = :sys.get_state(pid)
    data.active_skill
  end

  test "tool not on active skill's whitelist is denied with attribution" do
    sid = "skill-deny-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    {:ok, ^sid} =
      start_session_for_test(
        provider: ProviderEmittingBlocked,
        model: "p16",
        session_id: sid
      )

    skill = %Tau.Skill{
      name: "narrow_skill",
      body: "",
      path: "test",
      allowed_tools: ["skill_ok_tool"]
    }

    set_active_skill(sid, skill)
    assert active_skill(sid) == skill

    Tau.send(sid, "go")

    assert_receive %SE.ToolEnd{
                     tool_call_id: "call-blocked",
                     result: %Tau.Message.ToolResult{is_error: true, content: content}
                   },
                   5_000

    assert content =~ "skill_blocked_tool"
    assert content =~ "narrow_skill"
    assert content =~ "allowed_tools"

    assert_receive %SE.MessageEnd{message: %{stop_reason: :end_turn}}, 5_000

    {:ok, snap} = Tau.snapshot(sid)
    assert snap.state == :awaiting_user

    [path] = Path.wildcard(Path.join(Tau.Settings.data_dir(), "sessions/*/#{sid}.jsonl"))

    rows =
      File.read!(path)
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    tr =
      Enum.find(rows, fn r ->
        r["kind"] == "tool_result" and r["data"]["tool_call_id"] == "call-blocked"
      end)

    assert tr
    assert tr["data"]["is_error"] == true
    assert tr["data"]["content"] =~ "narrow_skill"
  end

  test ":end_turn clears active_skill" do
    sid = "skill-endturn-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    {:ok, ^sid} =
      start_session_for_test(provider: EndTurnProvider, model: "et", session_id: sid)

    skill = %Tau.Skill{
      name: "transient_skill",
      body: "",
      path: "test",
      allowed_tools: ["Read"]
    }

    set_active_skill(sid, skill)
    Tau.send(sid, "hi")

    assert_receive %SE.MessageEnd{message: %{stop_reason: :end_turn}}, 5_000

    {:ok, snap} = Tau.snapshot(sid)
    assert snap.state == :awaiting_user
    assert active_skill(sid) == nil
  end

  test ":cancel clears active_skill" do
    sid = "skill-cancel-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    {:ok, ^sid} =
      start_session_for_test(provider: HangingProvider, model: "hang", session_id: sid)

    skill = %Tau.Skill{
      name: "cancelled_skill",
      body: "",
      path: "test",
      allowed_tools: ["Read"]
    }

    set_active_skill(sid, skill)
    Tau.send(sid, "go")

    assert_receive %SE.MessageStart{}, 5_000

    Tau.cancel(sid)

    assert_receive %SE.Cancelled{}, 5_000

    {:ok, snap} = Tau.snapshot(sid)
    assert snap.state == :awaiting_user
    assert active_skill(sid) == nil
  end
end
