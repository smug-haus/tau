defmodule Tau.Session.UserMessageQueueTest do
  @moduledoc """
  Verifies #64 / ADR-0009: `{:user_message, _}` casts that arrive
  while the FSM is not in `:awaiting_user` are postponed and
  re-delivered in cast order on the next return to idle.

  The property exercises the FIFO guarantee end-to-end through the
  Replay provider; the unit test pins the telemetry contract
  (`:enqueued` / `:delivered`).
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  import Tau.Test.SessionHelper, only: [start_session_for_test: 1]
  alias Tau.Provider.Event
  alias Tau.Session.Events, as: SE

  @moduletag :property

  setup do
    tmp = Path.join(System.tmp_dir!(), "tau-uqueue-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:tau, :data_dir, tmp)

    on_exit(fn ->
      File.rm_rf!(tmp)
      Application.delete_env(:tau, :data_dir)
    end)

    :ok
  end

  property "user_messages cast during a turn persist in cast order" do
    # Each run starts a real session under Tau.Sessions.Supervisor
    # and writes JSONL, so max_runs is intentionally small.
    check all(n <- StreamData.integer(2..5), max_runs: 8) do
      fixture = [
        %Event.Start{request_id: "r", model: "replay"},
        %Event.TextStart{block_id: "b"},
        %Event.TextDelta{block_id: "b", text: "ack"},
        %Event.TextEnd{block_id: "b"},
        %Event.Done{stop_reason: :stop, usage: %{}}
      ]

      sid = "uqueue-prop-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

      {:ok, ^sid} =
        start_session_for_test(
          provider: Tau.Providers.Replay,
          model: "replay",
          session_id: sid,
          provider_ctx: %{replay_fixture: fixture}
        )

      msgs = for i <- 1..n, do: "msg-#{i}"
      Enum.each(msgs, &Tau.send(sid, &1))

      # Drain N MessageEnd events — one per turn the FSM completes.
      for _ <- 1..n do
        receive do
          %SE.MessageEnd{} -> :ok
        after
          5_000 -> flunk("timed out waiting for turn to complete")
        end
      end

      Phoenix.PubSub.unsubscribe(Tau.PubSub, "session:#{sid}")

      user_contents =
        sid
        |> jsonl_path()
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&(&1["kind"] == "user_message"))
        |> Enum.map(&get_in(&1, ["data", "content"]))

      assert user_contents == msgs,
             "user_message JSONL order should match cast order; got #{inspect(user_contents)}"
    end
  end

  test "casts during :provider_streaming emit :enqueued; idle casts emit :delivered" do
    fixture = [
      %Event.Start{request_id: "r", model: "replay"},
      %Event.TextStart{block_id: "b"},
      %Event.TextDelta{block_id: "b", text: "ack"},
      %Event.TextEnd{block_id: "b"},
      %Event.Done{stop_reason: :stop, usage: %{}}
    ]

    sid = "uqueue-tel-#{System.unique_integer([:positive])}"
    parent = self()
    handler_id = "uqueue-h-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      [
        [:tau, :session, :user_message, :enqueued],
        [:tau, :session, :user_message, :delivered]
      ],
      fn evt, _m, meta, _ -> send(parent, {:tel, List.last(evt), meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    {:ok, ^sid} =
      start_session_for_test(
        provider: Tau.Providers.Replay,
        model: "replay",
        session_id: sid,
        provider_ctx: %{replay_fixture: fixture}
      )

    # Cast both messages in tight succession. The first cast is the
    # head of the mailbox, so the FSM processes it from :awaiting_user
    # and transitions to :provider_streaming before pulling the second
    # cast — which therefore lands during streaming and is postponed.
    Tau.send(sid, "first")
    Tau.send(sid, "second")

    assert_receive {:tel, :delivered, %{from_state: :awaiting_user, session_id: ^sid}}, 1_000
    assert_receive {:tel, :enqueued, %{from_state: :provider_streaming, session_id: ^sid}}, 1_000

    # Drain the two turns.
    for _ <- 1..2 do
      assert_receive %SE.MessageEnd{}, 5_000
    end

    # The postponed "second" was re-delivered on entry into
    # :awaiting_user; that fired a second :delivered event.
    assert_receive {:tel, :delivered, %{from_state: :awaiting_user, session_id: ^sid}}, 1_000
  end

  defp jsonl_path(sid) do
    [path] = Path.wildcard(Path.join(Tau.Settings.data_dir(), "sessions/*/#{sid}.jsonl"))
    path
  end
end
