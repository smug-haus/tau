defmodule Tau.Session.SwapModelTest do
  @moduledoc """
  D-041 / [C54-B4]: `Tau.swap_model/2` — the synchronous, state-gated
  mid-session model swap API. Covers:

    - Swap succeeds in :awaiting_user + telemetry fires + snapshot reflects it.
    - Swap rejected {:error, :busy} when state != :awaiting_user (mid-stream).
    - model_swap event persisted to JSONL.
    - {:error, :not_found} for unknown session id.
    - Idempotent same-model swap (succeeds, from == to).
    - {:error, :invalid_model} for empty / whitespace-only strings.
  """
  use ExUnit.Case, async: false

  import Tau.Test.SessionHelper, only: [start_session_for_test: 1]
  alias Tau.Provider.Event
  alias Tau.Session.Events, as: SE

  setup do
    tmp = Path.join(System.tmp_dir!(), "tau-swap-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:tau, :data_dir, tmp)

    on_exit(fn ->
      File.rm_rf!(tmp)
      Application.delete_env(:tau, :data_dir)
    end)

    %{data_dir: tmp}
  end

  defp base_fixture do
    [
      %Event.Start{request_id: "r", model: "replay"},
      %Event.TextStart{block_id: "b"},
      %Event.TextDelta{block_id: "b", text: "hello"},
      %Event.TextEnd{block_id: "b"},
      %Event.Done{stop_reason: :stop, usage: %{}}
    ]
  end

  # A slow replay fixture that pauses between events so we can catch the FSM
  # mid-stream.
  defp slow_fixture do
    [
      %Event.Start{request_id: "r", model: "replay"},
      %Event.TextStart{block_id: "b"},
      %Event.TextDelta{block_id: "b", text: "part1"},
      %Event.TextDelta{block_id: "b", text: "part2"},
      %Event.TextDelta{block_id: "b", text: "part3"},
      %Event.TextEnd{block_id: "b"},
      %Event.Done{stop_reason: :stop, usage: %{}}
    ]
  end

  test "swap in :awaiting_user succeeds, telemetry fires, snapshot reflects new model" do
    handler_id = "tau-swap-ok-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:tau, :session, :model_swapped],
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    sid = "swap-ok-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    {:ok, ^sid} =
      start_session_for_test(
        provider: Tau.Providers.Replay,
        model: "old-model",
        session_id: sid,
        provider_ctx: %{replay_fixture: base_fixture()}
      )

    assert {:ok, %{from: "old-model", to: "new-model"}} = Tau.swap_model(sid, "new-model")

    {:ok, snap} = Tau.snapshot(sid)
    assert snap.model == "new-model"

    assert_receive {:telemetry, _measurements,
                    %{from: "old-model", to: "new-model", session_id: ^sid}},
                   1_000

    # AC-6 / D-160: ModelSwapped broadcast fires on a mid-session /model switch.
    assert_receive %SE.ModelSwapped{session_id: ^sid, from: "old-model", to: "new-model"}, 1_000
  end

  test "swap rejected {:error, :busy} mid-stream" do
    sid = "swap-busy-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    {:ok, ^sid} =
      start_session_for_test(
        provider: Tau.Providers.Replay,
        model: "slow",
        session_id: sid,
        # A long delay keeps the stream in :provider_streaming long enough for
        # the call to land while the FSM is still busy.
        provider_ctx: %{replay_fixture: slow_fixture(), replay_delay_ms: 100}
      )

    Tau.send(sid, "go")
    assert_receive %SE.MessageStart{}, 2_000

    # FSM is in :provider_streaming — swap MUST be rejected
    assert {:error, :busy} = Tau.swap_model(sid, "other")

    assert_receive %SE.MessageEnd{}, 5_000
  end

  test "model_swap event persisted to JSONL" do
    sid = "swap-jsonl-#{System.unique_integer([:positive])}"

    {:ok, ^sid} =
      start_session_for_test(
        provider: Tau.Providers.Replay,
        model: "orig",
        session_id: sid,
        provider_ctx: %{replay_fixture: base_fixture()}
      )

    {:ok, _} = Tau.swap_model(sid, "swapped")

    Process.sleep(50)

    [path] = Path.wildcard(Path.join(Tau.Settings.data_dir(), "sessions/*/#{sid}.jsonl"))

    events =
      File.read!(path)
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    kinds = Enum.map(events, & &1["kind"])
    assert "model_swap" in kinds

    swap_event = Enum.find(events, &(&1["kind"] == "model_swap"))
    assert swap_event["data"]["from"] == "orig"
    assert swap_event["data"]["to"] == "swapped"
  end

  test "{:error, :not_found} for unknown session id" do
    assert {:error, :not_found} = Tau.swap_model("no-such-session-id", "any-model")
  end

  test "idempotent same-model swap succeeds" do
    sid = "swap-idem-#{System.unique_integer([:positive])}"

    {:ok, ^sid} =
      start_session_for_test(
        provider: Tau.Providers.Replay,
        model: "same",
        session_id: sid,
        provider_ctx: %{replay_fixture: base_fixture()}
      )

    assert {:ok, %{from: "same", to: "same"}} = Tau.swap_model(sid, "same")

    {:ok, snap} = Tau.snapshot(sid)
    assert snap.model == "same"
  end

  test "{:error, :invalid_model} for empty string" do
    sid = "swap-blank-#{System.unique_integer([:positive])}"

    {:ok, ^sid} =
      start_session_for_test(
        provider: Tau.Providers.Replay,
        model: "orig",
        session_id: sid,
        provider_ctx: %{replay_fixture: base_fixture()}
      )

    assert {:error, :invalid_model} = Tau.swap_model(sid, "")
  end

  test "{:error, :invalid_model} for whitespace-only string" do
    sid = "swap-ws-#{System.unique_integer([:positive])}"

    {:ok, ^sid} =
      start_session_for_test(
        provider: Tau.Providers.Replay,
        model: "orig",
        session_id: sid,
        provider_ctx: %{replay_fixture: base_fixture()}
      )

    assert {:error, :invalid_model} = Tau.swap_model(sid, "   ")
  end
end
