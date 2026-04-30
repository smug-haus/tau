defmodule Tau.Hooks.PayloadTest do
  @moduledoc """
  Verifies that every hook payload built by `Tau.Session` carries the
  canonical Claude-Code-shape fields: `session_id`, `cwd`,
  `permission_mode`, `hook_event_name`, and `transcript_path`. Issue #8.

  Programmatic hooks see the same shape as `Tau.Hooks.Shell` did, so
  filtering on `permission_mode` or grepping `transcript_path` works
  without each hook having to reach back into session state.
  """
  use ExUnit.Case, async: false

  import Tau.Test.SessionHelper, only: [start_session_for_test: 1]
  alias Tau.Provider.Event

  defmodule CapturingHook do
    @moduledoc false
    @behaviour Tau.Hook

    @impl true
    def events, do: [:user_prompt_submit]

    @impl true
    def handle(event, payload) do
      pid = Process.whereis(payload.metadata.test_capture_name)
      if pid, do: send(pid, {:hook_payload, event, payload})
      :cont
    end
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "tau-hook-payload-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:tau, :data_dir, tmp)

    {:ok, _} = Registry.register(Tau.Hooks.Registry, :user_prompt_submit, CapturingHook)

    capture_name = :"hook_payload_capture_#{System.unique_integer([:positive])}"
    Process.register(self(), capture_name)

    on_exit(fn ->
      File.rm_rf!(tmp)
      Application.delete_env(:tau, :data_dir)
    end)

    %{
      capture_name: capture_name,
      data_dir: tmp,
      replay_fixture: [%Event.Done{stop_reason: :stop}]
    }
  end

  test "user_prompt_submit payload includes the canonical fields", %{
    capture_name: capture_name,
    data_dir: data_dir,
    replay_fixture: replay_fixture
  } do
    cwd = Path.join(System.tmp_dir!(), "tau-hook-cwd-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(cwd, ".git"))
    on_exit(fn -> File.rm_rf!(cwd) end)

    {:ok, sid} =
      start_session_for_test(
        provider: Tau.Providers.Replay,
        model: "replay-test",
        cwd: cwd,
        provider_ctx: %{replay_fixture: replay_fixture},
        metadata: %{
          test_capture_name: capture_name,
          permissions_mode: :plan
        }
      )

    Tau.send(sid, "hello hook")

    assert_receive {:hook_payload, :user_prompt_submit, payload}, 1_000

    assert payload.session_id == sid
    assert payload.cwd == cwd
    assert payload.permission_mode == :plan
    assert payload.hook_event_name == "user_prompt_submit"
    assert is_binary(payload.transcript_path)
    assert String.starts_with?(payload.transcript_path, data_dir)
    assert String.ends_with?(payload.transcript_path, "#{sid}.jsonl")

    # Event-specific extras are still present.
    assert %Tau.Message.User{content: "hello hook"} = payload.message
  end

  test "permission_mode defaults to :default when not set in metadata", %{
    capture_name: capture_name,
    replay_fixture: replay_fixture
  } do
    cwd =
      Path.join(System.tmp_dir!(), "tau-hook-cwd-default-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(cwd, ".git"))
    on_exit(fn -> File.rm_rf!(cwd) end)

    {:ok, sid} =
      start_session_for_test(
        provider: Tau.Providers.Replay,
        model: "replay-test",
        cwd: cwd,
        provider_ctx: %{replay_fixture: replay_fixture},
        metadata: %{test_capture_name: capture_name}
      )

    Tau.send(sid, "no mode")

    assert_receive {:hook_payload, :user_prompt_submit, payload}, 1_000
    assert payload.permission_mode == :default
  end
end
