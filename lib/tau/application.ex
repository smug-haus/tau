defmodule Tau.Application do
  @moduledoc """
  Tau's top-level supervision tree.

  Boot order is significant — `:rest_for_one` means a child crash
  cascades to everything below it. The current order encodes:

    1. **Telemetry** first — every other process emits events.
    2. **PubSub** — needed by Settings.Cache (broadcasts reloads),
       Permissions.RuleSet (subscribes to settings), and the
       session FSMs. ADR-0004 nailed this in: PubSub is at the
       top so subsystems can publish/subscribe in their `init/1`
       without needing `Process.whereis` guards.
    3. **Registries** — name lookup for tools, hooks, commands,
       skills, sessions, MCP servers.
    4. **Settings.Cache + Watcher** — persistent_term-backed
       config.
    5. **Permissions.RuleSet** — subscribes to settings PubSub,
       compiles rules from Settings.Cache.
    6. **Finch** — HTTP client, used by providers.
    7. **Task supervisors** — for tool dispatch.
    8. **Extensions.Loader** — registers tools/hooks/commands
       defined by extensions.
    9. **MCP.Supervisor** — MCP server connections.
    10. **Sessions.Supervisor** — dynamic supervisor for session
        FSMs (must be last; it's the only consumer of all the
        above).

  `Tau.Memory.Cache` was removed (ADR-0006) — the ETS-backed
  memory cache it implied was never wired up. `Tau.Memory.Loader`
  reads from disk on each call until profiling shows that's a
  bottleneck.
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Tau.Telemetry.Supervisor,
      {Phoenix.PubSub, name: Tau.PubSub},
      Tau.Registries,
      Tau.Settings.Cache,
      Tau.Settings.Watcher,
      Tau.Permissions.RuleSet,
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
