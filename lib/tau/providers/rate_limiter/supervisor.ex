defmodule Tau.Providers.RateLimiter.Supervisor do
  @moduledoc """
  Dynamic supervisor for `Tau.Providers.RateLimiter` GenServers
  (one per configured provider) — ADR-0011.

  On boot, reads the current settings from `Tau.Settings.Cache` and
  starts a limiter for every provider listed under
  `:rate_limits`. Subscribes to the `"settings"` PubSub topic; on
  reload, *reconciles* the running set against the new config:

    * **Add** — new provider key → start a new limiter under this
      DynamicSupervisor.
    * **Remove** — provider key dropped from settings → terminate
      the corresponding child.
    * **Same** — provider already running → leave it alone. The
      limiter has its own `"settings"` subscription and resizes its
      buckets in place.

  This keeps the supervisor's job small (lifecycle reconciliation
  only) while letting the limiters preserve their wait queues
  across config changes.
  """

  use Supervisor

  alias Tau.Providers.RateLimiter

  @doc false
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {DynamicSupervisor, strategy: :one_for_one, name: __MODULE__.Dynamic},
      {__MODULE__.Reconciler, []}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  @doc """
  Start (or no-op if already running) a limiter for `provider`.
  """
  @spec ensure_started(module(), keyword()) ::
          {:ok, pid()} | {:ok, pid(), term()} | {:error, term()}
  def ensure_started(provider, opts \\ []) when is_atom(provider) do
    case Registry.lookup(Tau.Providers.RateLimiter.Registry, provider) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        DynamicSupervisor.start_child(
          __MODULE__.Dynamic,
          {RateLimiter, {provider, opts}}
        )
    end
  end

  @doc """
  Stop the limiter for `provider`, if running.
  """
  @spec stop(module()) :: :ok
  def stop(provider) when is_atom(provider) do
    case Registry.lookup(Tau.Providers.RateLimiter.Registry, provider) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(__MODULE__.Dynamic, pid)
      [] -> :ok
    end

    :ok
  end

  @doc """
  Currently-running provider modules.
  """
  @spec running() :: [module()]
  def running do
    Registry.select(Tau.Providers.RateLimiter.Registry, [
      {{:"$1", :_, :_}, [], [:"$1"]}
    ])
  end

  defmodule Reconciler do
    @moduledoc false
    use GenServer

    def start_link(_), do: GenServer.start_link(__MODULE__, [])

    @impl true
    def init(_) do
      Phoenix.PubSub.subscribe(Tau.PubSub, "settings")
      reconcile(Tau.Settings.Cache.get())
      {:ok, %{}}
    end

    @impl true
    def handle_info({:settings_reloaded, settings}, state) do
      reconcile(settings)
      {:noreply, state}
    end

    def handle_info(_, state), do: {:noreply, state}

    @doc false
    def reconcile_now do
      reconcile(Tau.Settings.Cache.get())
    end

    defp reconcile(settings) do
      configured = configured_providers(settings)
      running = MapSet.new(Tau.Providers.RateLimiter.Supervisor.running())

      Enum.each(MapSet.difference(configured, running), &start_one/1)

      Enum.each(
        MapSet.difference(running, configured),
        &Tau.Providers.RateLimiter.Supervisor.stop/1
      )
    end

    defp start_one(provider) do
      _ = Tau.Providers.RateLimiter.Supervisor.ensure_started(provider, [])
    end

    defp configured_providers(settings) do
      providers =
        Map.get(settings, :rate_limits) ||
          Map.get(settings, "rate_limits") ||
          %{}

      providers
      |> Map.keys()
      |> Enum.map(&to_module/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()
    end

    defp to_module(m) when is_atom(m), do: m

    defp to_module(s) when is_binary(s) do
      try do
        String.to_existing_atom("Elixir." <> s)
      rescue
        ArgumentError -> nil
      end
    end

    defp to_module(_), do: nil
  end
end
