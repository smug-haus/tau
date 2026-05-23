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
    * `/`      — slash-command completion

  Ratatouille is an optional dep. When it isn't loaded (prod / minimal
  builds), `Tau.TUI.start/0` returns `{:error, :ratatouille_not_loaded}`
  instead of trying to render. The CLI's `tui` subcommand handles this
  case explicitly.
  """

  alias Tau.TUI.App

  @doc """
  Start the TUI loop (blocking). Requires the optional :ratatouille dep.

  `opts` are stashed in `Tau.TUI.RuntimeOpts` for `Tau.TUI.App.init/1`
  to read when it calls `Tau.start_session/1`. Recognised keys:
  `:provider`, `:model`, `:provider_ctx`. Anything not set falls back
  to the merged settings cascade via `Tau.Provider.default/0`.
  """
  @spec start(keyword() | map()) :: :ok | {:error, :ratatouille_not_loaded}
  def start(opts \\ []) do
    if Code.ensure_loaded?(Ratatouille.Runtime) do
      Tau.TUI.RuntimeOpts.set(opts)
      App.run()
    else
      {:error, :ratatouille_not_loaded}
    end
  end
end
