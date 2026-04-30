defmodule Tau.Skills.InjectionTest do
  @moduledoc """
  Verifies that `Tau.Session.init/1` calls `Tau.Skills.Loader.load_all/1`
  and prepends each non-`disable-model-invocation` skill into the session
  message list as a system-role `Tau.Message.User`. Skills marked
  `disable-model-invocation: true` are tracked on session data but NOT
  injected into messages — they're reachable via slash commands, not the
  model. See issues #16, #17 for full enforcement of `allowed-tools` and
  invocation gating.

  Also verifies the `[:tau, :skills, :loaded]` telemetry event fires.
  """
  use ExUnit.Case, async: false

  import Tau.Test.SessionHelper, only: [start_session_for_test: 1]
  alias Tau.Provider.Event

  setup do
    tmp_data = Path.join(System.tmp_dir!(), "tau-skills-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_data)
    Application.put_env(:tau, :data_dir, tmp_data)

    fake_home =
      Path.join(System.tmp_dir!(), "tau-skills-home-#{System.unique_integer([:positive])}")

    File.mkdir_p!(fake_home)
    prior_home = System.get_env("HOME")
    System.put_env("HOME", fake_home)

    cwd = Path.join(System.tmp_dir!(), "tau-skills-cwd-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(cwd, ".git"))
    File.mkdir_p!(Path.join(cwd, ".tau/skills/haiku-bot"))
    File.mkdir_p!(Path.join(cwd, ".tau/skills/quiet-cmd"))

    File.write!(Path.join(cwd, ".tau/skills/haiku-bot/SKILL.md"), """
    ---
    name: haiku-bot
    description: Reply only in haikus.
    ---

    When invoked, respond in 5/7/5 syllables.
    """)

    File.write!(Path.join(cwd, ".tau/skills/quiet-cmd/SKILL.md"), """
    ---
    name: quiet-cmd
    description: A slash-only utility skill.
    disable-model-invocation: true
    ---

    Body for the quiet skill.
    """)

    on_exit(fn ->
      File.rm_rf!(tmp_data)
      File.rm_rf!(cwd)
      File.rm_rf!(fake_home)
      Application.delete_env(:tau, :data_dir)
      if prior_home, do: System.put_env("HOME", prior_home), else: System.delete_env("HOME")
    end)

    %{cwd: cwd, replay_fixture: [%Event.Done{stop_reason: :stop}]}
  end

  test "active skills are injected as system-role user messages",
       %{cwd: cwd, replay_fixture: replay_fixture} do
    handler_id = "skills-loaded-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach(
      handler_id,
      [:tau, :skills, :loaded],
      fn _e, m, meta, _ -> send(parent, {:skills_loaded, m, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, sid} =
      start_session_for_test(
        provider: Tau.Providers.Replay,
        model: "replay-test",
        cwd: cwd,
        provider_ctx: %{replay_fixture: replay_fixture}
      )

    assert_receive {:skills_loaded, measurements, %{cwd: ^cwd}}, 1_000
    assert measurements.count >= 2
    assert measurements.active >= 1
    assert measurements.skipped >= 1

    [{pid, _}] = Registry.lookup(Tau.Sessions.Registry, sid)
    {_state, data} = :sys.get_state(pid)

    skill_msgs =
      Enum.filter(data.messages, fn
        %Tau.Message.User{metadata: %{source: :skill}} -> true
        _ -> false
      end)

    haiku_msg =
      Enum.find(skill_msgs, fn %{metadata: %{name: name}} -> name == "haiku-bot" end)

    assert haiku_msg, "haiku-bot skill should be injected as a system message"
    assert haiku_msg.metadata.role == :system
    assert haiku_msg.content =~ "5/7/5 syllables"
    assert haiku_msg.content =~ "Reply only in haikus."

    refute Enum.any?(skill_msgs, fn %{metadata: %{name: n}} -> n == "quiet-cmd" end),
           "disable-model-invocation skill should NOT appear in messages"
  end

  test "disable-model-invocation skills are tracked on session data but not injected",
       %{cwd: cwd, replay_fixture: replay_fixture} do
    {:ok, sid} =
      start_session_for_test(
        provider: Tau.Providers.Replay,
        model: "replay-test",
        cwd: cwd,
        provider_ctx: %{replay_fixture: replay_fixture}
      )

    [{pid, _}] = Registry.lookup(Tau.Sessions.Registry, sid)
    {_state, data} = :sys.get_state(pid)

    skill_names = Enum.map(data.skills, fn {name, _} -> name end)
    assert "haiku-bot" in skill_names
    assert "quiet-cmd" in skill_names

    quiet = Enum.find_value(data.skills, fn {n, s} -> if n == "quiet-cmd", do: s end)
    assert quiet.disable_model_invocation == true
  end
end
