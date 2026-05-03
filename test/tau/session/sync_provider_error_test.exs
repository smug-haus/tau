defmodule Tau.Session.SyncProviderErrorTest do
  @moduledoc """
  D-009 (SPEC-USER-TURN [C12]/[C19]): when a provider's `stream/3`
  returns `{:error, reason}` synchronously, the FSM emits a
  `MessageEnd` whose Assistant message has:

    * `stop_reason: :error`
    * `error_message: inspect(reason)`
    * `content: [%{type: :text, text: "Error: " <> inspect(reason)}]`

  The non-empty content block is the structural fix: render paths
  that iterate `msg.content` (the TUI's `on_message_end/2`, the
  CLI's `tau run` reducer) surface the error visibly. Without it,
  the user sees nothing.
  """
  use ExUnit.Case, async: false

  import Tau.Test.SessionHelper, only: [start_session_for_test: 1]
  alias Tau.Session.Events, as: SE

  defmodule SyncFailureProvider do
    @moduledoc false
    @behaviour Tau.Provider

    @impl true
    def stream(_messages, _opts, _ctx), do: {:error, :sync_fail}

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
    def default_model, do: "sync-fail"
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "tau-sync-err-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:tau, :data_dir, tmp)

    on_exit(fn ->
      File.rm_rf!(tmp)
      Application.delete_env(:tau, :data_dir)
    end)

    %{data_dir: tmp}
  end

  test "synchronous provider error produces a non-empty content text block" do
    sid = "sync-err-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    {:ok, ^sid} =
      start_session_for_test(
        session_id: sid,
        provider: SyncFailureProvider,
        model: "sync-fail"
      )

    Tau.send(sid, "trigger sync error")

    assert_receive %SE.MessageEnd{message: msg}, 2_000

    assert msg.stop_reason == :error,
           "Assistant.stop_reason should be :error, got #{inspect(msg.stop_reason)}"

    assert is_list(msg.content) and msg.content != [],
           "Assistant.content MUST be non-empty so render paths surface the error " <>
             "(D-009 / SPEC-USER-TURN [C12]/[C19]); got #{inspect(msg.content)}"

    text_blocks = Enum.filter(msg.content, &match?(%{type: :text}, &1))

    assert text_blocks != [], "Assistant.content MUST include at least one :text block"

    assert Enum.any?(text_blocks, fn %{text: t} -> String.contains?(t, "Error") end),
           "the :text block MUST surface the error keyword for human visibility"

    assert msg.error_message != nil and msg.error_message != "",
           "error_message remains populated for diagnostic consumers"
  end

  test "the FSM returns to :awaiting_user after a sync error (does not hang)" do
    sid = "sync-err-state-#{System.unique_integer([:positive])}"

    {:ok, ^sid} =
      start_session_for_test(
        session_id: sid,
        provider: SyncFailureProvider,
        model: "sync-fail"
      )

    Tau.send(sid, "trigger sync error")
    # Allow the cast to be processed.
    Process.sleep(200)

    {:ok, snap} = Tau.snapshot(sid)
    assert snap.state == :awaiting_user
  end
end
