defmodule Tau.Telemetry.Supervisor do
  @moduledoc """
  Supervises telemetry handlers and the optional metrics reporter.

  Telemetry events are documented in `Tau.Telemetry.Handlers`. Attaching zero
  handlers costs nothing — `:telemetry.execute/3` is a no-op when nothing is
  listening. We attach a default `Logger` handler in dev/test for visibility.
  """
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      Tau.Telemetry.Handlers,
      Tau.Cost.Tracker
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
