defmodule Tau.Providers.Shared.FinchStreamCancelTest do
  @moduledoc """
  ADR-0017: cooperative cancellation. Drives the `Replay`-style cancel
  path that mirrors the chunk-loop behaviour `FinchStream` exposes for
  real provider streams. We can't drive `FinchStream.run/4` directly
  in unit tests (it would open a real Finch HTTP request); instead we
  exercise the same `:counters`-flag protocol against the Replay
  provider, whose chunk loop checks the flag at every event boundary.

  The contract being pinned: flipping the cancel flag aborts the stream
  within one chunk boundary, emits a final
  `%Event.Error{reason: :cancelled, retryable?: false}`, and stops
  drawing from the fixture.
  """
  use ExUnit.Case, async: true

  alias Tau.Provider.Event
  alias Tau.Providers.Replay

  test "Replay provider honours :cancel_flag — aborts within one boundary" do
    flag = :counters.new(1, [])

    fixture =
      [
        %Event.Start{request_id: "r0", model: "replay"},
        %Event.TextStart{block_id: "b0"},
        %Event.TextDelta{block_id: "b0", text: "chunk-1"},
        %Event.TextDelta{block_id: "b0", text: "chunk-2"},
        %Event.TextDelta{block_id: "b0", text: "chunk-3"},
        %Event.TextEnd{block_id: "b0"},
        %Event.Done{stop_reason: :stop, usage: %{}}
      ]

    {:ok, stream} =
      Replay.stream([], %{}, %{
        replay_fixture: fixture,
        replay_delay_ms: 30,
        cancel_flag: flag
      })

    test_pid = self()

    # Run the consumer in its own process so we can race a cancel
    # against an in-progress stream.
    consumer =
      Task.async(fn ->
        events = Enum.to_list(stream)
        send(test_pid, {:done, events})
      end)

    # Let a couple of chunks land before flipping the flag.
    Process.sleep(40)
    :counters.add(flag, 1, 1)

    assert_receive {:done, events}, 2_000
    Task.await(consumer)

    # The cancellation marker is the last event.
    assert List.last(events) == %Event.Error{reason: :cancelled, retryable?: false}

    # The stream halted strictly before draining the fixture (the test
    # otherwise sees `Done` at the tail).
    refute Enum.any?(events, &match?(%Event.Done{}, &1))
  end

  test ":cancel_flag is optional — streams without one drain normally" do
    fixture =
      [
        %Event.Start{request_id: "r0", model: "replay"},
        %Event.TextDelta{block_id: "b0", text: "hi"},
        %Event.Done{stop_reason: :stop, usage: %{}}
      ]

    # No :cancel_flag, no :replay_delay_ms — streaming is synchronous.
    {:ok, stream} = Replay.stream([], %{}, %{replay_fixture: fixture})
    events = Enum.to_list(stream)

    assert events == fixture
    refute Enum.any?(events, &match?(%Event.Error{}, &1))
  end

  test ":replay_ignore_cancel forces the brutal-kill fallback path" do
    flag = :counters.new(1, [])

    fixture =
      [
        %Event.Start{request_id: "r0", model: "replay"},
        %Event.TextDelta{block_id: "b0", text: "hi"},
        %Event.Done{stop_reason: :stop, usage: %{}}
      ]

    {:ok, stream} =
      Replay.stream([], %{}, %{
        replay_fixture: fixture,
        cancel_flag: flag,
        replay_ignore_cancel: true
      })

    # Even with the flag flipped, the stream ignores it and drains
    # the entire fixture — the FSM-level brutal-kill is then the
    # only escape hatch.
    :counters.add(flag, 1, 1)
    events = Enum.to_list(stream)

    assert events == fixture
    refute Enum.any?(events, &match?(%Event.Error{reason: :cancelled}, &1))
  end
end
