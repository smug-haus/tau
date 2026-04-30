defmodule Tau.Commands.ContextThreadingTest do
  @moduledoc """
  Verifies that `Tau.Session` builds a populated `Tau.Command.Context` and
  hands it to slash-command modules — the user-flagged "commands receive
  empty context" gap (#2).

  Uses a stub command registered from the test process. The stub forwards
  the ctx it receives back to the test process so we can assert on every
  field.
  """
  use ExUnit.Case, async: false

  alias Tau.Provider.Event

  defmodule StubCmd do
    @moduledoc false
    @behaviour Tau.Command

    @impl true
    def name, do: "/stub-cmd"

    @impl true
    def description, do: "echoes its ctx back to the test"

    @impl true
    def execute(args, ctx) do
      # Metadata is Jason-encoded into the persistence header, so we can't
      # stash a raw pid there. Resolve a registered name to a pid instead.
      pid = Process.whereis(ctx.metadata.test_parent_name)
      if pid, do: send(pid, {:stub_executed, args, ctx})
      :ignore
    end
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "tau-cmd-ctx-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:tau, :data_dir, tmp)

    {:ok, _} = Registry.register(Tau.Commands.Registry, "/stub-cmd", StubCmd)

    Application.put_env(:tau, Tau.Providers.Replay, fixture: [%Event.Done{stop_reason: :stop}])

    capture_name = :"ctx_threading_capture_#{System.unique_integer([:positive])}"
    Process.register(self(), capture_name)

    on_exit(fn ->
      File.rm_rf!(tmp)
      Application.delete_env(:tau, :data_dir)
      Application.delete_env(:tau, Tau.Providers.Replay)
    end)

    %{capture_name: capture_name}
  end

  test "slash command receives a populated Tau.Command.Context", %{capture_name: capture_name} do
    cwd = Path.join(System.tmp_dir!(), "tau-cmd-ctx-cwd-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(cwd, ".git"))
    on_exit(fn -> File.rm_rf!(cwd) end)

    {:ok, sid} =
      Tau.start_session(
        provider: Tau.Providers.Replay,
        model: "replay-test",
        cwd: cwd,
        metadata: %{
          test_parent_name: capture_name,
          permissions_mode: :plan,
          custom: "hello"
        }
      )

    Tau.send(sid, "/stub-cmd production")

    assert_receive {:stub_executed, "production", %Tau.Command.Context{} = ctx}, 1_000

    assert ctx.session_id == sid
    assert ctx.cwd == cwd
    assert ctx.permissions_mode == :plan
    assert ctx.metadata.test_parent_name == capture_name
    assert ctx.metadata.custom == "hello"
    assert is_function(ctx.emit, 1)

    # ctx.emit should publish on the session's PubSub topic.
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")
    :ok = ctx.emit.({:test_event, 42})
    assert_receive {:test_event, 42}, 500
  end
end
