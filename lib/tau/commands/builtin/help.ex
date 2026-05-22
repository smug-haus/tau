defmodule Tau.Commands.Builtin.Help do
  @moduledoc """
  Built-in `/help` command (AC-1 / D-100, SPEC-TUI-COMPLETION).

  Lists every resolvable slash command with its description and origin,
  one entry per line, via the `{:notice, lines}` outcome. No provider turn
  is started (D-042, D-100).

  The command catalog is derived from `Tau.Commands.Catalog.list/1` using
  the current session's FSM `data` map so skills and templates discovered
  for this session are included.
  """

  @behaviour Tau.Commands.Builtin

  alias Tau.Commands.Catalog

  @impl Tau.Commands.Builtin
  def name, do: "/help"

  @impl Tau.Commands.Builtin
  def description, do: "List available slash commands"

  @impl Tau.Commands.Builtin
  def run(_args, data) do
    header = "Available slash commands:"

    lines =
      data
      |> Catalog.list()
      |> Enum.map(fn %{name: name, description: desc, origin: origin} ->
        origin_tag = "[" <> to_string(origin) <> "]"

        if desc != "" do
          "  #{name}  — #{desc}  #{origin_tag}"
        else
          "  #{name}  #{origin_tag}"
        end
      end)

    {:notice, [header | lines]}
  end
end
