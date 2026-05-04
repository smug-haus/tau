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
    7. **Providers.RateLimiter.Supervisor** — per-provider token-bucket
       limiters (ADR-0011). Boots after Finch (limiters wrap Finch
       sends) and before the task supervisors.
    8. **Task supervisors** — for tool dispatch.
    9. **Extensions.Loader** — registers tools/hooks/commands
       defined by extensions.
    10. **MCP.Supervisor** — MCP server connections.
    11. **TUI.Supervisor** — empty DynamicSupervisor; hosts the
        Ratatouille runtime subtree when the TUI is invoked (ADR-0018).
    12. **Sessions.Supervisor** — dynamic supervisor for session
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
      Tau.Providers.RateLimiter.Supervisor,
      {Task.Supervisor, name: Tau.Tools.TaskSupervisor},
      Tau.Extensions.Loader,
      Tau.MCP.Supervisor,
      Tau.TUI.Supervisor,
      Tau.Sessions.Supervisor
    ]

    opts = [strategy: :rest_for_one, name: Tau.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        :telemetry.execute([:tau, :app, :ready], %{system_time: System.system_time()}, %{
          version: Application.spec(:tau, :vsn) |> to_string()
        })

        maybe_dispatch_cli()

        {:ok, pid}

      other ->
        other
    end
  end

  defp maybe_dispatch_cli do
    case Burrito.Util.Args.get_bin_path() do
      :not_in_burrito ->
        :ok

      _bin_path ->
        args = Burrito.Util.Args.get_arguments() || []

        Task.start(fn ->
          exit_code =
            case Tau.CLI.main(args) do
              n when is_integer(n) -> n
              _ -> 0
            end

          System.halt(exit_code)
        end)
    end
  end
end
