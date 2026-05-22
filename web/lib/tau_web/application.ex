defmodule TauWeb.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      TauWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:tau_web, :dns_cluster_query) || :ignore},
      # NOTE: :tau_web reuses the running Tau.PubSub from the core :tau application.
      # It MUST NOT start its own Phoenix.PubSub — see SPEC-WEB-DASHBOARD §4 B4
      # and the pubsub_server: Tau.PubSub endpoint configuration.
      # Start a worker by calling: TauWeb.Worker.start_link(arg)
      # {TauWeb.Worker, arg},
      # Start to serve requests, typically the last entry
      TauWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: TauWeb.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    TauWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
