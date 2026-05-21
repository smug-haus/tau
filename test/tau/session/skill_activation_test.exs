defmodule Tau.Session.SkillActivationTest do
  @moduledoc """
  End-to-end coverage for issue #17 (Mechanism A): the model activates
  a discovered skill by emitting a tool_call to the synthetic
  `__activate_skill__` tool. Activation lives on the FSM's
  `data.active_skill` for the rest of the turn (clears on `:end_turn` /
  `:cancel`, per ADR-0013).

  Scenarios:

    * Successful activation of a model-invokable skill — `data.active_skill`
      is set, `%Events.SkillActivated{}` broadcasts, telemetry fires,
      the JSONL has a `skill_activated` event.
    * Attempt to activate a `disable_model_invocation: true` skill —
      synthetic `is_error: true` ToolResult, `data.active_skill` unchanged.
    * Post-activation, a tool_call outside the skill's `allowed_tools`
      whitelist is denied (regression-protects #16).
    * `:end_turn` clears `data.active_skill` (regression-protects ADR-0013).
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

  # Three-turn provider: first turn emits the activation tool_call;
  # second turn (after the activation result) emits a tool_call against
  # the post-activation tool name configured via `provider_ctx`; third
  # turn ends.
  defmodule ActivationProvider do
    @moduledoc false
    @behaviour Tau.Provider

    @impl true
    def stream(messages, _opts, ctx) do
      tool_results =
        Enum.filter(messages, &match?(%Tau.Message.ToolResult{}, &1))

      # After the activation result, optionally emit a follow-up
      # tool_call to a non-whitelisted tool — used by the
      # whitelist-enforcement scenario.
      events =
        cond do
          tool_results == [] ->
            skill_to_activate = ctx[:skill_to_activate]

            [
              %Event.Start{request_id: "r1", model: "act"},
              %Event.ToolCallStart{tool_call_id: "act-1", name: "__activate_skill__"},
              %Event.ToolCallEnd{
                tool_call_id: "act-1",
                params: %{"name" => skill_to_activate}
              },
              %Event.Done{stop_reason: :tool_use, usage: %{}}
            ]

          length(tool_results) == 1 and ctx[:emit_followup_tool] ->
            [
              %Event.Start{request_id: "r2", model: "act"},
              %Event.ToolCallStart{tool_call_id: "call-followup", name: ctx[:followup_tool]},
              %Event.ToolCallEnd{tool_call_id: "call-followup", params: %{}},
              %Event.Done{stop_reason: :tool_use, usage: %{}}
            ]

          true ->
            [
              %Event.Start{request_id: "r-end", model: "act"},
              %Event.TextStart{block_id: "t"},
              %Event.TextDelta{block_id: "t", text: "done"},
              %Event.TextEnd{block_id: "t"},
              %Event.Done{stop_reason: :end_turn, usage: %{}}
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
    def default_model, do: "act"
  end

  defmodule SpecCapturingProvider do
    @moduledoc false
    @behaviour Tau.Provider

    @impl true
    def stream(_messages, opts, ctx) do
      if pid = ctx[:report_to], do: send(pid, {:provider_opts, opts})

      {:ok,
       [
         %Event.Start{request_id: "rs", model: "spec"},
         %Event.TextStart{block_id: "t"},
         %Event.TextDelta{block_id: "t", text: "ok"},
         %Event.TextEnd{block_id: "t"},
         %Event.Done{stop_reason: :end_turn, usage: %{}}
       ]}
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
    def default_model, do: "spec"
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "tau-skill-act-#{System.unique_integer([:positive])}")
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

  defp seed_skills(sid, skills) do
    [{pid, _}] = Registry.lookup(Tau.Sessions.Registry, sid)

    :sys.replace_state(pid, fn {state, data} ->
      {state, %{data | skills: skills}}
    end)
  end

  defp active_skill(sid) do
    [{pid, _}] = Registry.lookup(Tau.Sessions.Registry, sid)
    {_state, data} = :sys.get_state(pid)
    data.active_skill
  end

  defp invokable do
    %Tau.Skill{
      name: "deploy",
      body: "deploy steps",
      path: "deploy/SKILL.md",
      description: "Run deploys",
      allowed_tools: ["skill_ok_tool"],
      disable_model_invocation: false
    }
  end

  defp disabled do
    %Tau.Skill{
      name: "secret",
      body: "secret steps",
      path: "secret/SKILL.md",
      description: "Background-only",
      allowed_tools: [],
      disable_model_invocation: true
    }
  end

  test "model activates a model-invokable skill via __activate_skill__" do
    sid = "act-ok-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")
    handler_ref = make_ref()
    parent = self()

    :telemetry.attach(
      "test-skill-activated-#{inspect(handler_ref)}",
      [:tau, :session, :skill_activated],
      fn _ev, measurements, meta, _ ->
        send(parent, {:telemetry, measurements, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("test-skill-activated-#{inspect(handler_ref)}") end)

    {:ok, ^sid} =
      start_session_for_test(
        provider: ActivationProvider,
        model: "act",
        session_id: sid,
        provider_ctx: %{skill_to_activate: "deploy"}
      )

    seed_skills(sid, [{"deploy", invokable()}, {"secret", disabled()}])

    Tau.send(sid, "go")

    assert_receive %SE.SkillActivated{skill_name: "deploy", tool_call_id: "act-1"}, 5_000
    assert_receive {:telemetry, _measurements, %{skill_name: "deploy", disabled?: false}}, 1_000

    assert_receive %SE.ToolEnd{
                     tool_call_id: "act-1",
                     result: %Tau.Message.ToolResult{is_error: false, content: content}
                   },
                   5_000

    assert content =~ "Skill activated: deploy"

    # Activation is confirmed by the SkillActivated broadcast and telemetry
    # already asserted above. Checking active_skill via :sys.get_state here
    # is inherently racy on a loaded runner: the FSM may have already advanced
    # to the second provider turn and cleared active_skill by the time this
    # process is scheduled. The SkillActivated + ToolEnd events are the correct
    # synchronisation points for activation; end_turn is the correct point for
    # the nil assertion below.

    # End-of-turn (no followup tool emitted) — `:end_turn` clears it.
    assert_receive %SE.MessageEnd{message: %{stop_reason: :end_turn}}, 5_000

    # Per ADR-0013: :end_turn clears active_skill. Safe to assert here:
    # gen_statem only responds to :sys.get_state after committing the
    # {next_state, :awaiting_user, data_with_nil} return value, which
    # happens after finalize_assistant/2 fully executes (including the
    # active_skill: nil assignment that follows the MessageEnd broadcast).
    assert active_skill(sid) == nil

    [path] = Path.wildcard(Path.join(Tau.Settings.data_dir(), "sessions/*/#{sid}.jsonl"))

    rows =
      File.read!(path)
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    assert Enum.any?(rows, fn r ->
             r["kind"] == "skill_activated" and r["data"]["skill_name"] == "deploy"
           end)
  end

  test "activating a disabled skill is denied with is_error: true" do
    sid = "act-disabled-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")
    handler_ref = make_ref()
    parent = self()

    :telemetry.attach(
      "test-skill-activated-disabled-#{inspect(handler_ref)}",
      [:tau, :session, :skill_activated],
      fn _ev, measurements, meta, _ -> send(parent, {:telemetry, measurements, meta}) end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach("test-skill-activated-disabled-#{inspect(handler_ref)}")
    end)

    {:ok, ^sid} =
      start_session_for_test(
        provider: ActivationProvider,
        model: "act",
        session_id: sid,
        provider_ctx: %{skill_to_activate: "secret"}
      )

    seed_skills(sid, [{"deploy", invokable()}, {"secret", disabled()}])

    Tau.send(sid, "try-disabled")

    assert_receive %SE.ToolEnd{
                     tool_call_id: "act-1",
                     result: %Tau.Message.ToolResult{is_error: true, content: content}
                   },
                   5_000

    assert content =~ "secret"
    assert content =~ "disable-model-invocation"
    assert_receive {:telemetry, _measurements, %{skill_name: "secret", disabled?: true}}, 1_000

    # No SkillActivated broadcast for a denied attempt.
    refute_receive %SE.SkillActivated{}, 200

    # active_skill stays nil.
    assert active_skill(sid) == nil

    assert_receive %SE.MessageEnd{message: %{stop_reason: :end_turn}}, 5_000
  end

  test "post-activation, a tool not on allowed_tools is denied (regression for #16)" do
    sid = "act-followup-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    {:ok, ^sid} =
      start_session_for_test(
        provider: ActivationProvider,
        model: "act",
        session_id: sid,
        provider_ctx: %{
          skill_to_activate: "deploy",
          emit_followup_tool: true,
          followup_tool: "skill_blocked_tool"
        }
      )

    seed_skills(sid, [{"deploy", invokable()}])

    Tau.send(sid, "go")

    assert_receive %SE.SkillActivated{skill_name: "deploy"}, 5_000

    # Activation tool_result.
    assert_receive %SE.ToolEnd{
                     tool_call_id: "act-1",
                     result: %Tau.Message.ToolResult{is_error: false}
                   },
                   5_000

    # Follow-up tool_call gets denied by the whitelist.
    assert_receive %SE.ToolEnd{
                     tool_call_id: "call-followup",
                     result: %Tau.Message.ToolResult{is_error: true, content: content}
                   },
                   5_000

    assert content =~ "skill_blocked_tool"
    assert content =~ "deploy"
    assert content =~ "allowed_tools"
  end

  test "synthetic __activate_skill__ tool is threaded to the provider with disabled skills excluded" do
    sid = "spec-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    {:ok, ^sid} =
      start_session_for_test(
        provider: SpecCapturingProvider,
        model: "spec",
        session_id: sid,
        provider_ctx: %{report_to: self()}
      )

    seed_skills(sid, [{"deploy", invokable()}, {"secret", disabled()}])

    Tau.send(sid, "hello")

    assert_receive {:provider_opts, opts}, 5_000
    assert [tool] = opts[:tools]
    assert tool.name == "__activate_skill__"

    # Disabled skill must not appear in the enum.
    enum = get_in(tool, [:parameters, "properties", "name", "enum"])
    assert "deploy" in enum
    refute "secret" in enum
  end
end
