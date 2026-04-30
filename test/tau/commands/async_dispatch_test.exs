defmodule Tau.Commands.AsyncDispatchTest do
  @moduledoc """
  Regression test for ADR-0008 / #59: a slash-command body that
  blocks for longer than the session's responsiveness budget must
  NOT block the FSM. Cancellation arrives promptly even while the
  command is still "running" inside its supervised task.
  """
  use ExUnit.Case, async: false

  import Tau.Test.SessionHelper, only: [start_session_for_test: 1]
  alias Tau.Provider.Event

  defmodule SlowCmd do
    @moduledoc false
    @behaviour Tau.Command

    @impl true
    def name, do: "/slow-cmd"

    @impl true
    def description, do: "sleeps forever to prove the FSM stays responsive"

    @impl true
    def execute(_args, _ctx) do
      # Block "forever" — Process.exit(:brutal_kill) from the FSM's
      # cancel handler must terminate this task.
      Process.sleep(60_000)
      :ignore
    end
  end

  defmodule CrashCmd do
    @moduledoc false
    @behaviour Tau.Command

    @impl true
    def name, do: "/crash-cmd"

    @impl true
    def description, do: "raises immediately"

    @impl true
    def execute(_args, _ctx), do: raise("boom")
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "tau-async-cmd-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:tau, :data_dir, tmp)

    {:ok, _} = Registry.register(Tau.Commands.Registry, "/slow-cmd", SlowCmd)
    {:ok, _} = Registry.register(Tau.Commands.Registry, "/crash-cmd", CrashCmd)

    on_exit(fn ->
      File.rm_rf!(tmp)
      Application.delete_env(:tau, :data_dir)
    end)

    :ok
  end

  test "Tau.cancel/1 returns promptly while a slow slash command is running" do
    cwd = Path.join(System.tmp_dir!(), "tau-async-cmd-cwd-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(cwd, ".git"))
    on_exit(fn -> File.rm_rf!(cwd) end)

    {:ok, sid} =
      start_session_for_test(
        provider: Tau.Providers.Replay,
        model: "replay-test",
        cwd: cwd,
        provider_ctx: %{replay_fixture: [%Event.Done{stop_reason: :stop}]}
      )

    # Subscribe so we can observe the Cancelled event.
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    Tau.send(sid, "/slow-cmd whatever")

    # The session's command_task is now running SlowCmd.execute
    # (which Process.sleeps for 60s). If the FSM were blocked, the
    # cancel cast would sit in the mailbox and not be handled —
    # we'd time out below. With ADR-0008, the FSM is free to
    # process :cancel immediately.
    started_at = System.monotonic_time(:millisecond)
    Tau.cancel(sid)
    assert_receive %Tau.Session.Events.Cancelled{session_id: ^sid, reason: :user}, 2_000
    elapsed = System.monotonic_time(:millisecond) - started_at

    assert elapsed < 1_500,
           "cancel took #{elapsed}ms; FSM was blocked by the slash command (ADR-0008 regression)"
  end

  test "a slash command that crashes surfaces as a synthetic message, not an FSM crash" do
    cwd = Path.join(System.tmp_dir!(), "tau-async-cmd-crash-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(cwd, ".git"))
    on_exit(fn -> File.rm_rf!(cwd) end)

    {:ok, sid} =
      start_session_for_test(
        provider: Tau.Providers.Replay,
        model: "replay-test",
        cwd: cwd,
        provider_ctx: %{replay_fixture: [%Event.Done{stop_reason: :stop}]}
      )

    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    Tau.send(sid, "/crash-cmd argy")

    # The crash should be wrapped into a synthetic user message that
    # gets prepended to the original. Wait for the resulting
    # MessageEnd (the Replay provider yields a Done event after
    # the user_prompt is appended).
    assert_receive %Tau.Session.Events.MessageEnd{session_id: ^sid}, 2_000

    # The session is still alive — Tau.snapshot/1 succeeds.
    assert {:ok, snap} = Tau.snapshot(sid)
    assert snap.id == sid

    # The user-typed message (NOT the system-role skill/memory injections)
    # starts with the crash marker.
    user_msg =
      Enum.find(snap.messages, fn
        %Tau.Message.User{content: c, metadata: meta} when is_binary(c) ->
          Map.get(meta || %{}, :role) != :system

        _ ->
          false
      end)

    assert user_msg, "expected to find a non-system user message"
    assert user_msg.content =~ "(slash command crashed:"
    assert user_msg.content =~ "boom"
  end
end
