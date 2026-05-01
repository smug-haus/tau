defmodule Tau.Telemetry.Handlers do
  @moduledoc """
  Attaches default `:telemetry` handlers.

  All Tau-emitted events live under the `[:tau, ...]` namespace:

      [:tau, :app, :ready]
      [:tau, :session, :start | :stop]
      [:tau, :session, :transition]
      [:tau, :session, :tool_whitelisted]
      [:tau, :session, :child_registered | :child_unregistered]
      [:tau, :session, :subagent, :start | :stop | :exception]
      [:tau, :provider, :request, :start | :stop | :exception]
      [:tau, :provider, :event]
      [:tau, :provider, :rate_limit, :acquired | :throttled | :rejected | :halved]
      [:tau, :provider, :fallback]
      [:tau, :tool, :execute, :start | :stop | :exception]
      [:tau, :tool, :bash, :stderr]
      [:tau, :hook, :run, :start | :stop | :exception]
      [:tau, :mcp, :rpc, :start | :stop | :exception]
      [:tau, :mcp, :stderr]
      [:tau, :permissions, :decision]
      [:tau, :permissions, :ceiling_clamped]
      [:tau, :compaction, :start | :stop]
      [:tau, :settings, :reloaded]
      [:tau, :extensions, :reloaded]

  This module is a one-shot worker: it attaches handlers in `init/1` and
  exits `:ignore`. The attachments live until detached (or the VM exits).
  """
  use GenServer
  require Logger

  @handler_id "tau-default-logger"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :telemetry.attach_many(
      @handler_id,
      events(),
      &__MODULE__.handle_event/4,
      %{}
    )

    {:ok, %{}}
  end

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach(@handler_id)
    :ok
  end

  @doc false
  def handle_event(event, measurements, metadata, _config) do
    Logger.debug(fn ->
      "telemetry #{inspect(event)} #{inspect(measurements)} #{inspect(metadata)}"
    end)
  end

  defp events do
    [
      [:tau, :app, :ready],
      [:tau, :session, :start],
      [:tau, :session, :stop],
      [:tau, :session, :transition],
      [:tau, :session, :tool_whitelisted],
      [:tau, :session, :child_registered],
      [:tau, :session, :child_unregistered],
      [:tau, :session, :subagent, :start],
      [:tau, :session, :subagent, :stop],
      [:tau, :session, :subagent, :exception],
      [:tau, :provider, :request, :start],
      [:tau, :provider, :request, :stop],
      [:tau, :provider, :request, :exception],
      [:tau, :provider, :event],
      [:tau, :provider, :rate_limit, :acquired],
      [:tau, :provider, :rate_limit, :throttled],
      [:tau, :provider, :rate_limit, :rejected],
      [:tau, :provider, :rate_limit, :halved],
      [:tau, :provider, :fallback],
      [:tau, :tool, :execute, :start],
      [:tau, :tool, :execute, :stop],
      [:tau, :tool, :execute, :exception],
      [:tau, :tool, :bash, :stderr],
      [:tau, :hook, :run, :start],
      [:tau, :hook, :run, :stop],
      [:tau, :hook, :run, :exception],
      [:tau, :mcp, :rpc, :start],
      [:tau, :mcp, :rpc, :stop],
      [:tau, :mcp, :rpc, :exception],
      [:tau, :mcp, :stderr],
      [:tau, :permissions, :decision],
      [:tau, :permissions, :ceiling_clamped],
      [:tau, :compaction, :start],
      [:tau, :compaction, :stop],
      [:tau, :settings, :reloaded],
      [:tau, :extensions, :reloaded]
    ]
  end
end
