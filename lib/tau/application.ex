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
    11. **CodingAgent.Supervisor** — DynamicSupervisor for
        `Tau.CodingAgent.Dispatcher` runs (SPEC-CODING-AGENT).
        Sits between MCP (which the future `tau-context` server
        depends on) and Sessions (which may reference dispatchers
        by id).
    12. **TUI.Supervisor** — empty DynamicSupervisor; hosts the
        Ratatouille runtime subtree when the TUI is invoked (ADR-0018).
    13. **Sessions.Supervisor** — dynamic supervisor for session
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
    install_file_system_log_filter()

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
      Tau.CodingAgent.Supervisor,
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

  # Suppress noisy [error]/[warning] messages from the :file_system library
  # (FSInotify.bootstrap and FileSystem.Worker.init) that fire before the
  # Tau.Settings.Watcher GenServer has a chance to degrade gracefully.  These
  # messages are emitted at the OTP logger level by Erlang code inside the
  # dependency and therefore cannot be suppressed via Elixir Logger config
  # alone — they arrive before any runtime filter registered by the Watcher
  # could be in place.  Installing a primary filter here, before the
  # supervision tree starts, ensures they are never written to stderr.
  #
  # The filter is intentionally narrow: it only drops :error and :warning
  # entries whose OTP logger :application metadata is :file_system.  All
  # other log entries are passed through unaffected.
  defp install_file_system_log_filter do
    case :logger.add_primary_filter(
           :tau_suppress_file_system_noise,
           {&__MODULE__.filter_file_system_log/2, :drop}
         ) do
      :ok -> :ok
      # Idempotent: filter already installed (hot-upgrade, test restart, etc.)
      {:error, {:already_exist, _}} -> :ok
    end
  end

  # Public because OTP :logger requires an MFA-capturable function for filter
  # callbacks ({&Mod.fun/arity, extra}). Do not call directly.
  @doc false
  @spec filter_file_system_log(:logger.log_event(), term()) :: :stop | :logger.log_event()
  def filter_file_system_log(%{level: level, meta: %{application: :file_system}} = _event, :drop)
      when level in [:error, :warning] do
    :stop
  end

  def filter_file_system_log(event, _), do: event

  @cli_argv_env "TAU_CLI_ARGV"
  @cli_argv_sep "\x1f"

  @doc false
  def cli_argv do
    case Burrito.Util.Args.get_bin_path() do
      :not_in_burrito ->
        case System.get_env(@cli_argv_env) do
          nil ->
            :no_cli

          "" ->
            :no_cli

          raw ->
            decoded = decode_cli_argv(raw)
            System.delete_env(@cli_argv_env)
            {:dispatch, decoded}
        end

      _bin_path ->
        {:dispatch, Burrito.Util.Args.get_arguments() || []}
    end
  end

  @doc false
  def encode_cli_argv(args) when is_list(args), do: Enum.join(args, @cli_argv_sep)

  defp decode_cli_argv(raw), do: String.split(raw, @cli_argv_sep)

  defp maybe_dispatch_cli do
    case cli_argv() do
      :no_cli ->
        :ok

      {:dispatch, argv} ->
        Task.start(fn ->
          exit_code =
            case Tau.CLI.main(argv) do
              n when is_integer(n) -> n
              _ -> 0
            end

          System.halt(exit_code)
        end)
    end
  end
end
