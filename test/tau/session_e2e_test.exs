defmodule Tau.SessionE2ETest do
  use ExUnit.Case, async: false

  import Tau.Test.SessionHelper, only: [start_session_for_test: 1]
  alias Tau.Provider.Event

  setup do
    # Per-test data dir so JSONL files don't collide.
    tmp = Path.join(System.tmp_dir!(), "tau-session-e2e-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:tau, :data_dir, tmp)

    on_exit(fn ->
      File.rm_rf!(tmp)
      Application.delete_env(:tau, :data_dir)
    end)

    %{data_dir: tmp}
  end

  test "drives a full session through the FSM and persists JSONL" do
    fixture = [
      %Event.Start{request_id: "r", model: "replay-test"},
      %Event.TextStart{block_id: "b0"},
      %Event.TextDelta{block_id: "b0", text: "hi from replay"},
      %Event.TextEnd{block_id: "b0"},
      %Event.Done{stop_reason: :stop, usage: %{output_tokens: 4}}
    ]

    # Subscribe BEFORE start_session so we don't miss the SessionStart event
    # broadcast synchronously from Session.init/1. Pre-generate the id so
    # subscription can happen before init runs.
    sid = "test-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    {:ok, ^sid} =
      start_session_for_test(
        provider: Tau.Providers.Replay,
        model: "replay-test",
        session_id: sid,
        provider_ctx: %{replay_fixture: fixture}
      )

    Tau.send(sid, "hello?")

    # Collect events for up to 5s.
    events = collect_events([], System.monotonic_time(:millisecond) + 5000)

    # Assert key lifecycle events were broadcast.
    kinds = Enum.map(events, & &1.__struct__)
    assert Tau.Session.Events.SessionStart in kinds
    assert Tau.Session.Events.MessageStart in kinds
    assert Tau.Session.Events.MessageEnd in kinds

    # Assert the assembled message is what the replay produced.
    %Tau.Session.Events.MessageEnd{message: msg} =
      Enum.find(events, &match?(%Tau.Session.Events.MessageEnd{}, &1))

    assert msg.stop_reason == :stop
    assert msg.model == "replay-test"
    assert [%{type: :text, text: "hi from replay"}] = msg.content

    # Assert JSONL session file was written and contains the user + assistant messages.
    [path] = Path.wildcard(Path.join(Tau.Settings.data_dir(), "sessions/*/#{sid}.jsonl"))

    lines =
      File.read!(path)
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    kinds = Enum.map(lines, & &1["kind"])
    assert "session_header" in kinds
    assert "user_message" in kinds
    assert "assistant_message" in kinds
  end

  defp collect_events(acc, deadline) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      %Tau.Session.Events.SessionEnd{} = e ->
        Enum.reverse([e | acc])

      %Tau.Session.Events.MessageEnd{} = e ->
        # Allow a brief tail for any post-message events (none expected for this fixture).
        collect_events([e | acc], min(deadline, System.monotonic_time(:millisecond) + 250))

      ev when is_struct(ev) ->
        collect_events([ev | acc], deadline)
    after
      timeout -> Enum.reverse(acc)
    end
  end
end
