defmodule Tau.Commands.Builtin.Ping do
  @moduledoc """
  Built-in `/ping` command.

  Responds with `"pong"` via a `{:notice, ...}` outcome. Primary
  purpose: seed entry for the built-in registry so dispatch is testable.
  """

  @behaviour Tau.Commands.Builtin

  @impl Tau.Commands.Builtin
  def name, do: "/ping"

  @impl Tau.Commands.Builtin
  def description, do: "Check session responsiveness (responds with pong)"

  @impl Tau.Commands.Builtin
  def run(_args, _data), do: {:notice, "pong"}
end
