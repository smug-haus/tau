defmodule Tau.Session.Queue do
  @moduledoc """
  Steering and follow-up queue operations for `Tau.Session`.

  Manages the two-tier message queue (D-077 / D-078 / SPEC-USER-TURN §6):

  - `steering_queue` — messages that drain at the tool-round boundary, placed
    AFTER all tool results and BEFORE the next provider call (D-079).
  - `followup_queue` — messages that drain on transition into `:awaiting_user`
    (D-080).

  ## Invariants

  - FIFO order is preserved across enqueue and dequeue (one message at a time).
  - Hard cap: 32 entries per tier (D-083). Messages past the cap are dropped
    with a `%SystemNotice{}` broadcast.
  - `:cancel` empties `steering_queue` and enqueues a `%QueueRestored{}`
    notification (SPEC-USER-TURN §6).
  - Steering drain bypasses slash-command classification; follow-up drain
    re-routes through the full user_message dispatch path.
  """

  alias Tau.Session.Events

  @queue_cap 32

  @doc """
  Enqueue `msg` into `data.steering_queue` or `data.followup_queue` based on
  `tier`, with telemetry. Drops with a `%SystemNotice{}` broadcast when the
  queue is at the hard cap (D-083).

  Returns updated `data` wrapped in `{:keep_state, data}`.
  """
  @spec enqueue(Tau.Session.Data.t(), Tau.Message.t(), :steering | :followup, atom()) ::
          :gen_statem.event_handler_result()
  def enqueue(data, msg, tier, from_state) do
    {queue_field, tier_atom} =
      case tier do
        :steering -> {:steering_queue, :steering}
        _ -> {:followup_queue, :followup}
      end

    queue = Map.get(data, queue_field)
    queue_size = :queue.len(queue)

    if queue_size >= @queue_cap do
      # D-083: hard cap — drop with a %SystemNotice{}, no unbounded growth.
      notice =
        "Message queue full (#{@queue_cap} #{tier_atom} messages queued); " <>
          "message dropped. Wait for the current turn to complete."

      Tau.Session.broadcast(data.id, %Events.SystemNotice{session_id: data.id, text: notice})

      :telemetry.execute(
        [:tau, :session, tier_atom, :dropped],
        %{system_time: System.system_time()},
        %{session_id: data.id, from_state: from_state, queue_size: queue_size}
      )

      {:keep_state_and_data, []}
    else
      new_queue = :queue.in(msg, queue)
      new_data = Map.put(data, queue_field, new_queue)

      :telemetry.execute(
        [:tau, :session, tier_atom, :enqueued],
        %{system_time: System.system_time()},
        %{session_id: data.id, from_state: from_state, queue_size: queue_size + 1}
      )

      {:keep_state, new_data}
    end
  end

  @doc """
  Drain one message from `data.steering_queue` and append it to `data.messages`.

  D-079: called after all tool results are in, before the next provider call,
  so no tool_call is orphaned. Bypasses slash-command classification — a
  steering message has already passed the user-intent gate at enqueue time.

  Returns updated data (or data unchanged if the queue is empty).
  """
  @spec drain_steering_queue_one(Tau.Session.Data.t()) :: Tau.Session.Data.t()
  def drain_steering_queue_one(data) do
    case :queue.out(data.steering_queue) do
      {:empty, _} ->
        data

      {{:value, msg}, rest} ->
        :telemetry.execute(
          [:tau, :session, :steering, :delivered],
          %{system_time: System.system_time()},
          %{session_id: data.id, from_state: :tool_executing}
        )

        Tau.Session.emit_user_message_telemetry(:delivered, data, :tool_executing)

        data
        |> Tau.Session.append_message(msg)
        |> Tau.Session.Journal.persist("user_message", Tau.Session.Journal.message_to_data(msg))
        |> Map.put(:steering_queue, rest)
    end
  end

  # --- FSM clause handlers ---------------------------------------------------

  @doc """
  Handle a user message arriving while a command task is in flight.

  ADR-0008: postpone so the message is re-delivered on the next FSM transition,
  preserving order.
  """
  @spec handle_postpone(Tau.Session.Data.t(), atom()) :: :gen_statem.event_handler_result()
  def handle_postpone(data, state) do
    Tau.Session.emit_user_message_telemetry(:enqueued, data, state)
    {:keep_state_and_data, [{:postpone, true}]}
  end

  @doc """
  Handle a user message when the FSM is not in `:awaiting_user`.

  D-077 / D-078: route to the appropriate tier queue.
  """
  @spec handle_enqueue(Tau.Message.t(), :steering | atom(), atom(), Tau.Session.Data.t()) ::
          :gen_statem.event_handler_result()
  def handle_enqueue(msg, tier, state, data) do
    Tau.Session.emit_user_message_telemetry(:enqueued, data, state)
    enqueue(data, msg, tier, state)
  end

  @doc """
  Handle `:drain_followups` internal event in `:awaiting_user` with no command task.

  Dequeues one follow-up message and re-routes it through the full user_message
  dispatch path so slash commands are classified.
  """
  @spec handle_drain_followups_idle(Tau.Session.Data.t()) :: :gen_statem.event_handler_result()
  def handle_drain_followups_idle(data) do
    case :queue.out(data.followup_queue) do
      {:empty, _} ->
        {:keep_state, data}

      {{:value, msg}, rest} ->
        :telemetry.execute(
          [:tau, :session, :followup, :delivered],
          %{system_time: System.system_time()},
          %{session_id: data.id, from_state: :awaiting_user}
        )

        # Re-route through the full user_message dispatch path so slash commands
        # are classified. The :followup tier tag is preserved but irrelevant in
        # :awaiting_user — the handler delivers immediately.
        Tau.Session.handle_event(:cast, {:user_message, msg, :followup}, :awaiting_user, %{
          data
          | followup_queue: rest
        })
    end
  end

  @doc """
  Handle `:drain_followups` in a non-idle state or with a command task in flight.
  Drop — the followup will re-drain on the next `:awaiting_user` transition.
  """
  @spec handle_drain_followups_busy(Tau.Session.Data.t()) :: :gen_statem.event_handler_result()
  def handle_drain_followups_busy(data) do
    {:keep_state, data}
  end

  @doc """
  Handle `{:provider_dispatch, _id}` info messages.

  These are fire-and-forget confirmations from the parallel tool dispatcher;
  the FSM ignores them (no state change).
  """
  @spec handle_provider_dispatch(Tau.Session.Data.t()) :: :gen_statem.event_handler_result()
  def handle_provider_dispatch(data) do
    {:keep_state, data}
  end
end
