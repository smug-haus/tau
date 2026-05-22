defmodule Tau.Commands.Builtin.Clone do
  @moduledoc """
  Built-in `/clone` command.

  Duplicates the entire current session as a new session id by forking
  at the session's latest persisted event via `Tau.fork/2`.

  The current session is NOT mutated — it persists unchanged.  The new
  session is started under `Tau.Sessions.Supervisor` and is immediately
  live (in `:awaiting_user`) with the full conversation history of the
  current session.

  Returns `{:notice, "Cloned to session <new-id>"}` on success, or
  `{:error, <reason>}` on failure.  No provider turn is started (D-042).

  ## Difference from `/fork`

  `/clone` always forks at the latest event (a full duplicate); `/fork`
  accepts an optional event-id to branch from an earlier point in history.

  ## Known product limitation

  The single-session TUI cannot switch focus to the new session; this
  command only creates it.  The user must restart Tau with `--session
  <new-id>` to interact with the clone.
  """

  @behaviour Tau.Commands.Builtin

  @impl Tau.Commands.Builtin
  def name, do: "/clone"

  @impl Tau.Commands.Builtin
  def description, do: "Duplicate the current session (clone at latest event)"

  @impl Tau.Commands.Builtin
  def run(_args, data) do
    case resolve_last_event_id(data.id, data.persistence) do
      {:ok, event_id} ->
        case Tau.fork(data.id, event_id) do
          {:ok, new_id} ->
            {:notice, "Cloned to session #{new_id}"}

          {:error, :parent_event_not_found} ->
            {:error, "Could not find latest event to clone from."}

          {:error, :parent_not_found} ->
            {:error, "Parent session not found."}

          {:error, reason} ->
            {:error, "Clone failed: #{inspect(reason)}"}
        end

      {:error, :no_events} ->
        {:error, "No events to clone from — send a message first."}

      {:error, reason} ->
        {:error, "Clone failed: #{inspect(reason)}"}
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
