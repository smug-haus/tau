defmodule Tau.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Tau.Telemetry.Supervisor,
      Tau.Settings.Cache,
      Tau.Settings.Watcher,
      Tau.Memory.Cache,
      Tau.Permissions.RuleSet,
      Tau.Registries,
      {Phoenix.PubSub, name: Tau.PubSub},
      {Finch, name: Tau.Providers.Finch},
      {Task.Supervisor, name: Tau.Tools.TaskSupervisor},
      Tau.Extensions.Loader,
      Tau.MCP.Supervisor,
      Tau.Sessions.Supervisor
    ]

    opts = [strategy: :rest_for_one, name: Tau.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        :telemetry.execute([:tau, :app, :ready], %{system_time: System.system_time()}, %{
          version: Application.spec(:tau, :vsn) |> to_string()
        })

        {:ok, pid}

      other ->
        other
    end
  end
end
