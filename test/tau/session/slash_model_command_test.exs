defmodule Tau.Session.SlashModelCommandTest do
  @moduledoc """
  D-041: `/model` slash-command behaviour.

    - `/model` with no arg broadcasts a SystemNotice showing the current
      model; no provider turn is started.
    - `/model <id>` swaps the model and the next turn uses it.
  """
  use ExUnit.Case, async: false

  import Tau.Test.SessionHelper, only: [start_session_for_test: 1]
  alias Tau.Provider.Event
  alias Tau.Session.Events, as: SE

  setup do
    tmp = Path.join(System.tmp_dir!(), "tau-slash-model-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:tau, :data_dir, tmp)

    on_exit(fn ->
      File.rm_rf!(tmp)
      Application.delete_env(:tau, :data_dir)
    end)

    :ok
  end

  defp replay_fixture do
    [
      %Event.Start{request_id: "r", model: "replay"},
      %Event.TextStart{block_id: "b"},
      %Event.TextDelta{block_id: "b", text: "response"},
      %Event.TextEnd{block_id: "b"},
      %Event.Done{stop_reason: :stop, usage: %{}}
    ]
  end

  test "/model with no args shows current model via SystemNotice, no turn starts" do
    sid = "slash-model-noarg-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    {:ok, ^sid} =
      start_session_for_test(
        provider: Tau.Providers.Replay,
        model: "my-model",
        session_id: sid,
        provider_ctx: %{replay_fixture: replay_fixture()}
      )

    Tau.send(sid, "/model")

    # Expect a SystemNotice containing the model name
    assert_receive %SE.SystemNotice{session_id: ^sid, text: text}, 2_000
    assert String.contains?(text, "my-model")

    # No MessageStart should arrive (no provider turn)
    refute_receive %SE.MessageStart{}, 200
  end

  test "/model <id> swaps model and the next turn uses it" do
    sid = "slash-model-swap-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    {:ok, ^sid} =
      start_session_for_test(
        provider: Tau.Providers.Replay,
        model: "original-model",
        session_id: sid,
        provider_ctx: %{replay_fixture: replay_fixture()}
      )

    # Swap the model via /model slash command
    Tau.send(sid, "/model new-model")

    # Expect a SystemNotice about the swap
    assert_receive %SE.SystemNotice{session_id: ^sid, text: text}, 2_000
    assert String.contains?(text, "new-model")

    # No provider turn should start from the slash command itself
    refute_receive %SE.MessageStart{}, 200

    # Snapshot should reflect the new model
    {:ok, snap} = Tau.snapshot(sid)
    assert snap.model == "new-model"

    # Send a real message — should use the new model
    Tau.send(sid, "hello")
    assert_receive %SE.MessageEnd{}, 5_000

    {:ok, snap2} = Tau.snapshot(sid)
    assert snap2.model == "new-model"
  end
end
