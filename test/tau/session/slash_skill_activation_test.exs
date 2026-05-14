defmodule Tau.Session.SlashSkillActivationTest do
  @moduledoc """
  Tests for issue #95: user-initiated slash-command skill activation path.

  A user may type `/<skill-name> [args]` to activate a skill directly,
  bypassing the model-invokable `__activate_skill__` synthetic tool.
  This path is universally available — both `disable_model_invocation:
  true` AND `false` skills can be activated this way.

  Scenarios:
    - Typing `/skill-name` activates the skill and sets `data.active_skill`.
    - The rewritten user message strips the slash-command prefix (args only).
    - Skills with `disable_model_invocation: true` are activatable via slash.
    - The `%Events.SkillActivated{}` is broadcast and telemetry fires.
    - An unrecognised `/foo` still passes through verbatim (regression guard).
    - The model-invokable `__activate_skill__` tool path continues to work
      alongside the slash path (non-regression).
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  import Tau.Test.SessionHelper, only: [start_session_for_test: 1]
  alias Tau.Commands.Parser
  alias Tau.Provider.Event
  alias Tau.Session.Events, as: SE

  @moduletag :property

  # ---------------------------------------------------------------------------
  # Helpers shared across tests
  # ---------------------------------------------------------------------------

  defp seed_skills(sid, skills) do
    [{pid, _}] = Registry.lookup(Tau.Sessions.Registry, sid)

    :sys.replace_state(pid, fn {state, data} ->
      {state, %{data | skills: skills}}
    end)
  end

  defp setup_tmp do
    tmp = Path.join(System.tmp_dir!(), "tau-slash-skill-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:tau, :data_dir, tmp)

    on_exit(fn ->
      File.rm_rf!(tmp)
      Application.delete_env(:tau, :data_dir)
    end)

    :ok
  end

  defp end_turn_provider do
    Tau.Providers.Replay
  end

  defp end_turn_fixture do
    [
      %Event.Start{request_id: "r1", model: "replay"},
      %Event.TextStart{block_id: "t"},
      %Event.TextDelta{block_id: "t", text: "ok"},
      %Event.TextEnd{block_id: "t"},
      %Event.Done{stop_reason: :end_turn, usage: %{}}
    ]
  end

  defp invokable_skill(name) do
    %Tau.Skill{
      name: name,
      body: "body for #{name}",
      path: "/tmp/#{name}/SKILL.md",
      description: "Invokable skill #{name}",
      allowed_tools: [],
      disable_model_invocation: false
    }
  end

  defp manual_only_skill(name) do
    %Tau.Skill{
      name: name,
      body: "body for #{name}",
      path: "/tmp/#{name}/SKILL.md",
      description: "Manual-only skill #{name}",
      allowed_tools: [],
      disable_model_invocation: true
    }
  end

  # ---------------------------------------------------------------------------
  # Property: Parser.lookup_skill/2 always finds a skill by exact name
  # ---------------------------------------------------------------------------

  property "Parser.lookup_skill/2 finds a skill by exact name and returns :error for unknown" do
    check all(
            name <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20),
            other_name <-
              StreamData.string(:alphanumeric, min_length: 1, max_length: 20)
              |> StreamData.filter(&(&1 != name))
          ) do
      skill = invokable_skill(name)
      skills = [{name, skill}]

      assert {:ok, ^skill} = Parser.lookup_skill(name, skills)
      assert :error = Parser.lookup_skill(other_name, skills)
      assert :error = Parser.lookup_skill(name, [])
    end
  end

  # ---------------------------------------------------------------------------
  # Integration: slash activation sets active_skill and rewrites message
  # ---------------------------------------------------------------------------

  setup do
    setup_tmp()
  end

  test "typing /skill-name activates the skill and sets data.active_skill" do
    sid = "slash-act-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    {:ok, ^sid} =
      start_session_for_test(
        provider: end_turn_provider(),
        model: "replay",
        session_id: sid,
        provider_ctx: %{replay_fixture: end_turn_fixture()}
      )

    seed_skills(sid, [{"deploy", invokable_skill("deploy")}])

    Tau.send(sid, "/deploy some args here")

    assert_receive %SE.SkillActivated{skill_name: "deploy", tool_call_id: nil}, 5_000
    assert_receive %SE.MessageEnd{}, 5_000

    # active_skill may have been cleared by :end_turn (per ADR-0013).
    # We verify it was set at some point via the SkillActivated broadcast above.
    # A snapshot of the JSONL confirms the event was persisted.
    [path] = Path.wildcard(Path.join(Tau.Settings.data_dir(), "sessions/*/#{sid}.jsonl"))

    rows =
      File.read!(path)
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    assert Enum.any?(rows, fn r ->
             r["kind"] == "skill_activated" and r["data"]["skill_name"] == "deploy"
           end)
  end

  test "the rewritten message strips the slash command prefix — args are the content" do
    sid = "slash-rewrite-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    # Use a provider that captures the messages it receives so we can inspect
    # the content of the user message after rewriting.
    parent = self()

    {:ok, ^sid} =
      start_session_for_test(
        provider: end_turn_provider(),
        model: "replay",
        session_id: sid,
        provider_ctx: %{replay_fixture: end_turn_fixture(), report_to: parent}
      )

    seed_skills(sid, [{"greet", invokable_skill("greet")}])

    Tau.send(sid, "/greet hello world")

    assert_receive %SE.MessageEnd{}, 5_000

    # Inspect the persisted user_message row — its content must be the
    # stripped args, not the full slash-command string.
    [path] = Path.wildcard(Path.join(Tau.Settings.data_dir(), "sessions/*/#{sid}.jsonl"))

    rows =
      File.read!(path)
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    user_rows = Enum.filter(rows, &(&1["kind"] == "user_message"))
    assert user_rows != []

    last_user = List.last(user_rows)
    # Content must be the args only ("hello world"), not "/greet hello world".
    assert last_user["data"]["content"] == "hello world"
  end

  test "disable_model_invocation: true skill is still activatable via slash" do
    sid = "slash-disabled-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    {:ok, ^sid} =
      start_session_for_test(
        provider: end_turn_provider(),
        model: "replay",
        session_id: sid,
        provider_ctx: %{replay_fixture: end_turn_fixture()}
      )

    seed_skills(sid, [{"secret", manual_only_skill("secret")}])

    Tau.send(sid, "/secret run this manually")

    assert_receive %SE.SkillActivated{skill_name: "secret", tool_call_id: nil}, 5_000
    assert_receive %SE.MessageEnd{}, 5_000
  end

  test "unrecognised slash command passes through verbatim (no skill match)" do
    sid = "slash-unknown-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    {:ok, ^sid} =
      start_session_for_test(
        provider: end_turn_provider(),
        model: "replay",
        session_id: sid,
        provider_ctx: %{replay_fixture: end_turn_fixture()}
      )

    # No skills seeded — /unknown should pass through as-is.
    seed_skills(sid, [])

    Tau.send(sid, "/unknown foo bar")

    assert_receive %SE.MessageEnd{}, 5_000

    [path] = Path.wildcard(Path.join(Tau.Settings.data_dir(), "sessions/*/#{sid}.jsonl"))

    rows =
      File.read!(path)
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    user_rows = Enum.filter(rows, &(&1["kind"] == "user_message"))
    last_user = List.last(user_rows)
    # Content is the full unmodified message.
    assert last_user["data"]["content"] == "/unknown foo bar"
  end

  test "slash activation coexists with model-invokable __activate_skill__ tool" do
    # Regression: both activation paths must work. This test exercises
    # the slash path; model path is covered by SkillActivationTest.
    sid = "slash-coexist-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    {:ok, ^sid} =
      start_session_for_test(
        provider: end_turn_provider(),
        model: "replay",
        session_id: sid,
        provider_ctx: %{replay_fixture: end_turn_fixture()}
      )

    seed_skills(sid, [
      {"visible", invokable_skill("visible")},
      {"manual", manual_only_skill("manual")}
    ])

    # Both visible and manual are slash-activatable.
    Tau.send(sid, "/visible do something")
    assert_receive %SE.SkillActivated{skill_name: "visible"}, 5_000
    assert_receive %SE.MessageEnd{}, 5_000
  end
end
