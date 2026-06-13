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
    5. **Memory.Supervisor** — `Tau.Memory.Store.SQLite` owner process;
       runs schema migrations in `init/1` before reporting `:ok`.
       Must follow Watcher (needs `data_dir/0`) and precede Finch
       (embedding pipeline in PR3 uses Finch). D-045/D-046/D-047.
    5b. **Factory.Supervisor** — `Tau.Factory.Ledger.Writer` owner process;
        WAL-committed verdict ledger (D-315 RPO=0). Must follow Watcher
        (needs `data_dir/0`). D-312/D-315/D-335 / SPEC-FACTORY-CORE.
    6. **Permissions.RuleSet** — subscribes to settings PubSub,
       compiles rules from Settings.Cache.
    7. **Finch** — HTTP client, used by providers.
    8. **Providers.RateLimiter.Supervisor** — per-provider token-bucket
       limiters (ADR-0011). Boots after Finch (limiters wrap Finch
       sends) and before the circuit breaker.
    9. **CircuitBreaker.Store** — ETS-owner lifecycle anchor for
       `:tau_circuit_breakers` (SPEC-CIRCUIT-BREAKER §4 B2, ADR-0019).
       Placed after rate limiters (circuit breakers wrap provider calls
       at a higher level than rate limiting) and before task supervisors
       so the table exists when any session-turn task first calls a
       provider.
    10. **Task supervisors** — for tool dispatch.
    11. **Extensions.Loader** — registers tools/hooks/commands
        defined by extensions.
    12. **MCP.Supervisor** — MCP server connections.
    13. **CodingAgent.Supervisor** — DynamicSupervisor for
        `Tau.CodingAgent.Dispatcher` runs (SPEC-CODING-AGENT).
        Sits between MCP (which the future `tau-context` server
        depends on) and Sessions (which may reference dispatchers
        by id).
    14. **TUI.Supervisor** — empty DynamicSupervisor; hosts the
        Ratatouille runtime subtree when the TUI is invoked (ADR-0018).
    15. **Sessions.Supervisor** — dynamic supervisor for session
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

    children =
      List.flatten([
        Tau.Telemetry.Supervisor,
        # OTel reporter — conditional on otel.enabled. Placed after
        # Telemetry.Supervisor so the reporter is up before any session-turn
        # telemetry fires, but still under :rest_for_one so a reporter crash
        # cascades correctly.
        otel_reporter_spec(),
        {Phoenix.PubSub, name: Tau.PubSub},
        Tau.Registries,
        Tau.Settings.Cache,
        Tau.Settings.Watcher,
        # Memory store. Must follow Settings.Watcher (data_dir/0 depends on
        # it) and precede Finch (the embedding pipeline uses Finch). Under
        # :rest_for_one a crash cascades forward — intentional; a broken
        # memory store should not allow new sessions to start.
        Tau.Memory.Supervisor,
        # Factory ledger / control subtree. Must follow Memory.Supervisor
        # (data_dir/0 depends on Settings.Watcher, same requirement). Gated on
        # config :tau, :factory, enabled (default false — D-357, [C120-B11]).
        # Mirrors the OtelReporter :enabled precedent. Under :rest_for_one a crash
        # cascades forward — intentional; a broken ledger should not allow the
        # factory to continue operating. D-315 / SPEC-FACTORY-CORE.
        factory_supervisor_spec(),
        Tau.Permissions.RuleSet,
        {Finch, name: Tau.Providers.Finch},
        Tau.Providers.RateLimiter.Supervisor,
        Tau.CircuitBreaker.Store,
        # Copilot token store — supervised home for the short-lived API
        # token. Placed after Finch so the store can be refreshed via Finch
        # without a forward-dependency on an unstarted HTTP client.
        Tau.Providers.Copilot.TokenStore,
        {Task.Supervisor, name: Tau.Tools.TaskSupervisor},
        Tau.Extensions.Loader,
        Tau.MCP.Supervisor,
        Tau.CodingAgent.Supervisor,
        Tau.TUI.Supervisor,
        Tau.Sessions.Supervisor
      ])

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

  # Returns a child spec for the OTel reporter when otel.enabled is true,
  # otherwise returns an empty list so Supervisor.start_link/2 skips it
  # (flat-list children).
  defp otel_reporter_spec do
    if Application.get_env(:tau, :otel, []) |> Keyword.get(:enabled, false) do
      [Tau.OtelReporter]
    else
      []
    end
  end

  # Returns a child spec for the Factory supervisor.
  # When the factory is enabled (config :tau, :factory, enabled: true), the
  # full Coordinator-bearing subtree is assembled. When disabled (the default),
  # the supervisor starts without a Coordinator — no uncontrolled work is driven
  # on a normal boot (D-357, [C120-B11]).
  # Mirrors the otel_reporter_spec/0 pattern.
  defp factory_supervisor_spec do
    enabled = Application.get_env(:tau, :factory, []) |> Keyword.get(:enabled, false)
    [Tau.Factory.Supervisor.child_spec(enabled: enabled)]
  end

  # Suppress noisy `[error]`/`[warning]` messages from the `:file_system`
  # library that fire before `Tau.Settings.Watcher` can degrade gracefully.
  # These come from Erlang code at the OTP logger level so a runtime
  # Elixir Logger filter can't catch them. Installed as a primary filter
  # before the supervision tree starts; narrowly drops only `:error` and
  # `:warning` with `:application == :file_system`.
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
