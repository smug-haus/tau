defmodule Tau.Session.CancelCooperativeTest do
  @moduledoc """
  ADR-0017: cooperative cancellation of in-flight provider streams.

  Pins three behaviours of `Tau.cancel/1` against the Replay provider:

    1. `:replay_delay_ms` keeps the stream open long enough for the
       cancel cast to land. The stream observes the `:cancel_flag`
       counter at the next chunk boundary, halts, and emits
       `%Event.Error{reason: :cancelled, retryable?: false}` to the
       assembler. JSONL records a `cancellation` event with
       `reason: "cooperative"`. Telemetry `[:tau, :provider, :request,
       :cancelled]` fires; `:brutal_kill` does not.

    2. A provider whose stream actively *ignores* the flag
       (`:replay_ignore_cancel`) trips the brutal-kill fallback —
       `[:tau, :provider, :request, :brutal_kill]` fires and the
       persisted `cancellation` reason is `"brutal_kill"`.

    3. A cancel against an idle session (no provider task in flight)
       is a no-op for the cancellation telemetry — neither
       `:cancelled` nor `:brutal_kill` fires.
  """
  use ExUnit.Case, async: false

  import Tau.Test.SessionHelper, only: [start_session_for_test: 1]
  alias Tau.Provider.Event
  alias Tau.Session.Events, as: SE

  setup do
    tmp = Path.join(System.tmp_dir!(), "tau-cancel-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:tau, :data_dir, tmp)

    on_exit(fn ->
      File.rm_rf!(tmp)
      Application.delete_env(:tau, :data_dir)
    end)

    :ok
  end

  defp slow_fixture do
    [
      %Event.Start{request_id: "r0", model: "replay"},
      %Event.TextStart{block_id: "b0"},
      %Event.TextDelta{block_id: "b0", text: "partial-"},
      %Event.TextDelta{block_id: "b0", text: "more-"},
      %Event.TextDelta{block_id: "b0", text: "even-more-"},
      %Event.TextEnd{block_id: "b0"},
      %Event.Done{stop_reason: :stop, usage: %{}}
    ]
  end

  test "cancel mid-stream takes the cooperative path" do
    sid = "cancel-coop-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    test_pid = self()
    handler_id = "tau-cancel-coop-#{sid}"

    :telemetry.attach_many(
      handler_id,
      [
        [:tau, :provider, :request, :cancelled],
        [:tau, :provider, :request, :brutal_kill]
      ],
      fn event, _measurements, metadata, _ ->
        Kernel.send(test_pid, {:telemetry, event, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, ^sid} =
      start_session_for_test(
        provider: Tau.Providers.Replay,
        session_id: sid,
        provider_ctx: %{
          replay_fixture: slow_fixture(),
          # 50ms between events — we have a comfortable race window
          # to land the cancel before Done.
          replay_delay_ms: 50
        }
      )

    Tau.send(sid, "kick off the stream")

    # Wait for at least one streaming event so we know the provider
    # task is in-flight.
    assert_receive %SE.MessageStart{}, 1_000
    assert_receive %SE.MessageUpdate{}, 1_000

    # Cancel mid-stream.
    Tau.cancel(sid)

    # The cooperative-path telemetry fires; the brutal-kill telemetry
    # does NOT (assert that more carefully via refute_receive below).
    assert_receive {:telemetry, [:tau, :provider, :request, :cancelled], meta}, 1_000
    assert meta.session_id == sid
    assert meta.provider == Tau.Providers.Replay

    # The Cancelled broadcast lands on PubSub.
    assert_receive %SE.Cancelled{session_id: ^sid, reason: :user}, 1_000

    # No brutal-kill telemetry should arrive — the cooperative path
    # got us out within 250ms.
    refute_receive {:telemetry, [:tau, :provider, :request, :brutal_kill], _}, 100

    # JSONL has a `cancellation` event whose reason marks the
    # cooperative path.
    [path] = Path.wildcard(Path.join(Tau.Settings.data_dir(), "sessions/*/#{sid}.jsonl"))

    cancellation =
      File.read!(path)
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.find(&(&1["kind"] == "cancellation"))

    assert cancellation
    assert cancellation["data"]["reason"] == "cooperative"
    assert cancellation["data"]["cause"] == "user"

    # Snapshot is back at :awaiting_user with the cancel flag dropped.
    {:ok, snap} = Tau.snapshot(sid)
    assert snap.state == :awaiting_user
  end

  test "ignored cancel flag falls back to brutal-kill" do
    sid = "cancel-brutal-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    test_pid = self()
    handler_id = "tau-cancel-brutal-#{sid}"

    :telemetry.attach_many(
      handler_id,
      [
        [:tau, :provider, :request, :cancelled],
        [:tau, :provider, :request, :brutal_kill]
      ],
      fn event, _measurements, metadata, _ ->
        Kernel.send(test_pid, {:telemetry, event, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, ^sid} =
      start_session_for_test(
        provider: Tau.Providers.Replay,
        session_id: sid,
        provider_ctx: %{
          replay_fixture: slow_fixture(),
          # Long delay AND ignore_cancel so the stream stays in a
          # `Process.sleep/1` past the 250ms grace window — the FSM
          # has to brutal-kill the provider task to escape.
          replay_delay_ms: 1_000,
          replay_ignore_cancel: true
        }
      )

    Tau.send(sid, "kick off the stream")

    # Wait for the stream to start before cancelling.
    assert_receive %SE.MessageStart{}, 1_000

    Tau.cancel(sid)

    # The brutal-kill telemetry fires (after the 250ms grace).
    assert_receive {:telemetry, [:tau, :provider, :request, :brutal_kill], meta}, 2_000
    assert meta.session_id == sid

    # The cooperative-path telemetry should NOT fire for this run.
    refute_receive {:telemetry, [:tau, :provider, :request, :cancelled], _}, 100

    # JSONL records the brutal-kill mechanism.
    [path] = Path.wildcard(Path.join(Tau.Settings.data_dir(), "sessions/*/#{sid}.jsonl"))

    cancellation =
      File.read!(path)
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.find(&(&1["kind"] == "cancellation"))

    assert cancellation
    assert cancellation["data"]["reason"] == "brutal_kill"
  end

  test "cancel on an idle session emits no provider-cancel telemetry" do
    sid = "cancel-idle-#{System.unique_integer([:positive])}"

    test_pid = self()
    handler_id = "tau-cancel-idle-#{sid}"

    :telemetry.attach_many(
      handler_id,
      [
        [:tau, :provider, :request, :cancelled],
        [:tau, :provider, :request, :brutal_kill]
      ],
      fn event, _measurements, metadata, _ ->
        Kernel.send(test_pid, {:telemetry, event, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, ^sid} =
      start_session_for_test(
        provider: Tau.Providers.Replay,
        session_id: sid,
        provider_ctx: %{replay_fixture: slow_fixture()}
      )

    # Idle session — no Tau.send/2, no provider in flight.
    Tau.cancel(sid)

    refute_receive {:telemetry, [:tau, :provider, :request, :cancelled], _}, 200
    refute_receive {:telemetry, [:tau, :provider, :request, :brutal_kill], _}, 50
  end
end
