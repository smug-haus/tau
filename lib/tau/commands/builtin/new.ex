defmodule Tau.Commands.Builtin.New do
  @moduledoc """
  Built-in `/new` command.

  Starts a fresh session via `Tau.start_session/1`, inheriting `:cwd`,
  `:provider`, and `:model` from the current session's `data`.  The new
  session has an empty conversation history.

  Returns `{:notice, "Started new session <new-id>"}` on success, or
  `{:error, <reason>}` on failure.  No provider turn is started (D-042).

  ## Known product limitation

  The single-session TUI cannot switch focus to the new session; this
  command only creates it.  The user must restart Tau with `--session
  <new-id>` to interact with the new session.
  """

  @behaviour Tau.Commands.Builtin

  @impl Tau.Commands.Builtin
  def name, do: "/new"

  @impl Tau.Commands.Builtin
  def description, do: "Start a fresh session in the current directory"

  @impl Tau.Commands.Builtin
  def run(_args, data) do
    opts =
      [
        cwd: data.cwd,
        provider: data.provider,
        model: data.model
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    case Tau.start_session(opts) do
      {:ok, new_id} -> {:notice, "Started new session #{new_id}"}
      {:error, reason} -> {:error, "Failed to start new session: #{inspect(reason)}"}
    end
  end
end
