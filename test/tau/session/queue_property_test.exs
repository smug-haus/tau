defmodule Tau.Session.QueuePropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :property

  alias Tau.Session.Queue

  defp make_data(steering_queue, followup_queue) do
    %{
      id: "test-session",
      steering_queue: steering_queue,
      followup_queue: followup_queue,
      messages: [],
      persistence: nil,
      persist_handle: nil
    }
  end

  defp msg_generator do
    gen all(text <- string(:alphanumeric, min_length: 1)) do
      %Tau.Message.User{content: text, metadata: %{}, timestamp: DateTime.utc_now()}
    end
  end

  property "steering_queue FIFO order is preserved across enqueue/dequeue" do
    check all(msgs <- list_of(msg_generator(), min_length: 1)) do
      q =
        Enum.reduce(msgs, :queue.new(), fn msg, acc ->
          :queue.in(msg, acc)
        end)

      dequeued =
        Enum.reduce(msgs, {[], q}, fn _msg, {acc, queue} ->
          {{:value, v}, rest} = :queue.out(queue)
          {acc ++ [v], rest}
        end)
        |> elem(0)

      assert dequeued == msgs
    end
  end

  property "enqueue respects the 32-entry hard cap" do
    check all(msgs <- list_of(msg_generator(), length: 35)) do
      data = make_data(:queue.new(), :queue.new())

      final_data =
        Enum.reduce(msgs, data, fn msg, acc ->
          case Queue.enqueue(acc, msg, :steering, :awaiting_user) do
            {:keep_state, updated} -> updated
            {:keep_state_and_data, _} -> acc
          end
        end)

      assert :queue.len(final_data.steering_queue) <= 32
    end
  end

  property "enqueue followup respects the 32-entry hard cap" do
    check all(msgs <- list_of(msg_generator(), length: 35)) do
      data = make_data(:queue.new(), :queue.new())

      final_data =
        Enum.reduce(msgs, data, fn msg, acc ->
          case Queue.enqueue(acc, msg, :followup, :provider_streaming) do
            {:keep_state, updated} -> updated
            {:keep_state_and_data, _} -> acc
          end
        end)

      assert :queue.len(final_data.followup_queue) <= 32
    end
  end

  property "enqueue preserves FIFO order up to cap" do
    check all(msgs <- list_of(msg_generator(), min_length: 1, max_length: 30)) do
      data = make_data(:queue.new(), :queue.new())

      final_data =
        Enum.reduce(msgs, data, fn msg, acc ->
          case Queue.enqueue(acc, msg, :steering, :awaiting_user) do
            {:keep_state, updated} -> updated
            {:keep_state_and_data, _} -> acc
          end
        end)

      queued = :queue.to_list(final_data.steering_queue)
      assert queued == Enum.take(msgs, 32)
    end
  end
end
