defmodule Tau.TUI.EventBridge do
  @moduledoc """
  PubSub → Ratatouille bridge.

  Ratatouille 0.5.1's runtime dispatches its own internal events
  (keyboard, ticks declared via `App.subscribe/1`) to `App.update/2`.
  It does not forward arbitrary messages from the runtime process's
  mailbox. The TUI nonetheless needs to react to `Tau.Session.Events`
  broadcast on `"session:<id>"`. This bridge is the seam.

  One bridge per TUI session:

  - `start_link/1` — subscribes to `"session:<id>"` and holds a queue.
  - PubSub broadcasts arrive via `handle_info/2`, are appended.
  - `drain/1` returns and clears the queue atomically; `App.update/2`
    invokes it on each `:tick` and folds the events through the
    existing `on_message_*` / `on_tool_*` / `on_session_end` clauses.

  Registered under `Tau.Sessions.Registry` keyed by
  `{:tui_event_bridge, session_id}` so the App can address it without
  threading a pid through the model.
  """

  use GenServer

  @registry Tau.Sessions.Registry

  @spec start_link(String.t()) :: GenServer.on_start()
  def start_link(session_id) when is_binary(session_id) do
    GenServer.start_link(__MODULE__, session_id, name: via(session_id))
  end

  @doc """
  Drain pending events. Returns events in arrival order; queue is empty
  after the call. Returns `[]` if no bridge is running for this session.
  """
  @spec drain(String.t()) :: [term()]
  def drain(session_id) when is_binary(session_id) do
    case Registry.lookup(@registry, {:tui_event_bridge, session_id}) do
      [{pid, _}] -> GenServer.call(pid, :drain)
      [] -> []
    end
  end

  @doc "Stop the bridge for `session_id`. No-op if absent."
  @spec stop(String.t()) :: :ok
  def stop(session_id) when is_binary(session_id) do
    case Registry.lookup(@registry, {:tui_event_bridge, session_id}) do
      [{pid, _}] -> GenServer.stop(pid, :normal)
      [] -> :ok
    end

    :ok
  end

  defp via(session_id), do: {:via, Registry, {@registry, {:tui_event_bridge, session_id}}}

  @impl true
  def init(session_id) do
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{session_id}")
    {:ok, %{queue: :queue.new()}}
  end

  @impl true
  def handle_info(msg, %{queue: q} = state) do
    {:noreply, %{state | queue: :queue.in(msg, q)}}
  end

  @impl true
  def handle_call(:drain, _from, %{queue: q} = state) do
    {:reply, :queue.to_list(q), %{state | queue: :queue.new()}}
  end
end
