defmodule Tau.TUI do
  @moduledoc """
  Interactive terminal UI built on Ratatouille.

  Layout (resizable):

      ┌─────────────────────────────────────────────────────────┐
      │ session: <id>  model: <m>  cwd: <cwd>  ●<state>         │ status
      ├─────────────────────────────────────────────────────────┤
      │  transcript pane (streaming)                            │
      ├─────────────────────────────────────────────────────────┤
      │ tool I/O pane (collapsible)                             │
      ├─────────────────────────────────────────────────────────┤
      │ > input prompt                                          │
      └─────────────────────────────────────────────────────────┘

  Subscribes to `"session:<id>"` PubSub topic; each event becomes a
  message in Ratatouille's update loop.

  Keybindings:

    * `Enter`  — submit input
    * `ESC`    — cancel in-flight work (`Tau.cancel/1`)
    * `Ctrl-C` — quit (with confirmation)
    * `Ctrl-R` — open session picker (TODO)
    * `/`      — slash-command completion (TODO)

  Ratatouille is an optional dep. When it isn't loaded (prod / minimal
  builds), `Tau.TUI.start/0` returns `{:error, :ratatouille_not_loaded}`
  instead of trying to render. The CLI's `tui` subcommand handles this
  case explicitly.
  """

  @doc "Start the TUI loop (blocking). Requires the optional :ratatouille dep."
  @spec start() :: :ok | {:error, :ratatouille_not_loaded}
  def start do
    if Code.ensure_loaded?(Ratatouille.Runtime) do
      apply(Tau.TUI.App, :run, [])
    else
      {:error, :ratatouille_not_loaded}
    end
  end
end
