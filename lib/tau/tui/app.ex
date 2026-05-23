if Code.ensure_loaded?(Ratatouille.Runtime) do
  defmodule Tau.TUI.App do
    @moduledoc """
    Ratatouille MVU app implementation. Only compiled when the optional
    `:ratatouille` dep is loaded; the parent `Tau.TUI.start/0` checks
    `Code.ensure_loaded?/1` before delegating here.

    This module holds only the four `@behaviour Ratatouille.App` callback
    stubs and the `run/0` entry point. All logic lives in the focused
    sub-modules under `Tau.TUI.App.*`.
    """

    @behaviour Ratatouille.App

    alias Ratatouille.Runtime.Subscription

    # Adaptive tick: 16 ms while a turn is streaming (last_assistant non-nil);
    # 250 ms while idle. Ratatouille re-reads subscribe/1 each cycle, so the
    # interval tracks model state without any process changes.
    @tick_interval_streaming 16
    @tick_interval_idle 250

    @impl true
    def init(context), do: Tau.TUI.App.Bootstrap.init(context)

    @impl true
    def update(model, msg), do: Tau.TUI.App.Events.update(model, msg)

    @impl true
    def render(model), do: Tau.TUI.App.View.render(model)

    @impl true
    def subscribe(%{last_assistant: la}) when is_binary(la) and la != "" do
      Subscription.interval(@tick_interval_streaming, :tick)
    end

    def subscribe(_model), do: Subscription.interval(@tick_interval_idle, :tick)

    @doc "Run the TUI loop (blocking until the user quits)."
    def run, do: Tau.TUI.App.Bootstrap.run()
  end
end
