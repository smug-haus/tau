defmodule Tau.Commands.Builtin.Fork do
  @moduledoc """
  Built-in `/fork [event-id]` command.

  Creates a new session forked from the current one via `Tau.fork/2`.

  - With an `event-id` arg: fork at that specific event.
  - With no arg: fork at the current session's most-recent persisted event id.

  The current session is NOT mutated — it persists unchanged.  The new
  session is started under `Tau.Sessions.Supervisor` and is immediately
  live (in `:awaiting_user`).

  Returns `{:notice, "Forked to session <new-id>"}` on success, or
  `{:error, <reason>}` on failure.  No provider turn is started (D-042).

  ## Known product limitation

  The single-session TUI cannot switch focus to the new session; this
  command only creates it.  The user must restart Tau with `--session
  <new-id>` to interact with the fork.
  """

  @behaviour Tau.Commands.Builtin

  @impl Tau.Commands.Builtin
  def name, do: "/fork"

  @impl Tau.Commands.Builtin
  def run(args, data) do
    event_id =
      case String.trim(args) do
        "" -> resolve_last_event_id(data.id, data.persistence)
        explicit -> {:ok, explicit}
      end

    case event_id do
      {:ok, eid} ->
        case Tau.fork(data.id, eid) do
          {:ok, new_id} -> {:notice, "Forked to session #{new_id}"}
          {:error, :parent_event_not_found} -> {:error, "Event not found: #{eid}"}
          {:error, :parent_not_found} -> {:error, "Parent session not found."}
          {:error, reason} -> {:error, "Fork failed: #{inspect(reason)}"}
        end

      {:error, :no_events} ->
        {:error, "No events to fork from — send a message first."}

      {:error, reason} ->
        {:error, "Fork failed: #{inspect(reason)}"}
    end
  end

  # Walk the persisted event stream and return the id of the last non-header event.
  # Returns `{:ok, event_id}` or `{:error, :no_events}`.
  defp resolve_last_event_id(session_id, persistence) do
    last =
      persistence.stream(session_id)
      |> Enum.reduce(nil, fn
        %{"kind" => "session_header"}, acc -> acc
        %{"id" => id}, _acc -> id
      end)

    case last do
      nil -> {:error, :no_events}
      id -> {:ok, id}
    end
  end
end
