defmodule Tau.Memory.InjectionTest do
  @moduledoc """
  Verifies that `Tau.Session.init/1` loads the `TAU.md` cascade via
  `Tau.Memory.Loader.load/1` and prepends the bodies as system-role
  `Tau.Message.User` messages — so the Anthropic provider's
  `split_system/1` lifts them into the API's `system` field, and
  providers without that split see them at the top of the conversation.

  Also verifies the `[:tau, :memory, :loaded]` telemetry event fires
  when memory is loaded.
  """
  use ExUnit.Case, async: false

  alias Tau.Provider.Event

  setup do
    tmp_data = Path.join(System.tmp_dir!(), "tau-memory-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_data)
    Application.put_env(:tau, :data_dir, tmp_data)

    # Pin HOME to an empty dir so an actual ~/.tau/TAU.md on the developer's
    # machine doesn't perturb the cascade.
    fake_home =
      Path.join(System.tmp_dir!(), "tau-memory-home-#{System.unique_integer([:positive])}")

    File.mkdir_p!(fake_home)
    prior_home = System.get_env("HOME")
    System.put_env("HOME", fake_home)

    cwd = Path.join(System.tmp_dir!(), "tau-memory-cwd-#{System.unique_integer([:positive])}")
    File.mkdir_p!(cwd)
    File.mkdir_p!(Path.join(cwd, ".git"))
    File.write!(Path.join(cwd, "TAU.md"), "Always reply in haiku.\n")

    on_exit(fn ->
      File.rm_rf!(tmp_data)
      File.rm_rf!(cwd)
      File.rm_rf!(fake_home)
      Application.delete_env(:tau, :data_dir)
      Application.delete_env(:tau, Tau.Providers.Replay)
      if prior_home, do: System.put_env("HOME", prior_home), else: System.delete_env("HOME")
    end)

    %{cwd: cwd}
  end

  test "TAU.md is injected as a system-role user message at session start", %{cwd: cwd} do
    Application.put_env(:tau, Tau.Providers.Replay,
      fixture: [
        %Event.Start{request_id: "r", model: "replay-test"},
        %Event.TextStart{block_id: "b0"},
        %Event.TextDelta{block_id: "b0", text: "ok"},
        %Event.TextEnd{block_id: "b0"},
        %Event.Done{stop_reason: :stop, usage: %{output_tokens: 1}}
      ]
    )

    handler_id = "memory-injection-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach(
      handler_id,
      [:tau, :memory, :loaded],
      fn _event, measurements, metadata, _ ->
        send(parent, {:memory_loaded, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, sid} =
      Tau.start_session(provider: Tau.Providers.Replay, model: "replay-test", cwd: cwd)

    assert_receive {:memory_loaded, %{file_count: 1, bytes: bytes}, %{cwd: ^cwd}}, 1_000
    assert bytes > 0

    [{pid, _}] = Registry.lookup(Tau.Sessions.Registry, sid)
    {_state, data} = :sys.get_state(pid)

    assert [%Tau.Message.User{} = sys_msg | _] = data.messages
    assert sys_msg.metadata.role == :system
    assert sys_msg.metadata.source == :memory
    assert sys_msg.content =~ "Always reply in haiku."
  end

  test "missing TAU.md leaves the message list empty and emits no memory telemetry" do
    bare_cwd =
      Path.join(System.tmp_dir!(), "tau-memory-bare-#{System.unique_integer([:positive])}")

    File.mkdir_p!(bare_cwd)
    File.mkdir_p!(Path.join(bare_cwd, ".git"))
    on_exit(fn -> File.rm_rf!(bare_cwd) end)

    Application.put_env(:tau, Tau.Providers.Replay, fixture: [%Event.Done{stop_reason: :stop}])

    handler_id = "memory-empty-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach(
      handler_id,
      [:tau, :memory, :loaded],
      fn _e, _m, _meta, _ -> send(parent, :memory_loaded) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, sid} =
      Tau.start_session(provider: Tau.Providers.Replay, model: "replay-test", cwd: bare_cwd)

    [{pid, _}] = Registry.lookup(Tau.Sessions.Registry, sid)
    {_state, data} = :sys.get_state(pid)

    memory_msgs =
      Enum.filter(data.messages, fn
        %Tau.Message.User{metadata: %{source: :memory}} -> true
        _ -> false
      end)

    assert memory_msgs == []
    refute_receive :memory_loaded, 200
  end
end
