defmodule Tau.Factory.KillSwitch do
  @moduledoc """
  Kill switch for the factory Coordinator.

  A supervised `GenServer` that broadcasts `:halt_requested` on the
  `"factory:control"` PubSub topic. Callers use `request_halt/1` to
  trigger a clean halt; the Coordinator honours the halt at the next
  unit boundary (D-321).

  Optional sentinel polling: when `:sentinel_path` and `:poll_interval`
  are given, the KillSwitch polls for the file's existence and broadcasts
  `:halt_requested` once on first detection (no repeated broadcasts).

  See `docs/spec/SPEC-FACTORY-CORE.md`, D-321.
  """

  use GenServer

  require Logger

  @default_poll_interval_ms 500

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Start and register the KillSwitch.

  Required options:
    - `:name`   — atom; registered name for the GenServer.
    - `:pubsub` — atom; name of a running `Phoenix.PubSub`.

  Optional options:
    - `:sentinel_path`  — `Path.t()`; if given, KillSwitch polls for the
                          file's existence and broadcasts `:halt_requested`
                          once on first detection.
    - `:poll_interval`  — integer ms; default #{@default_poll_interval_ms};
                          used only when `:sentinel_path` is set.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Broadcast `:halt_requested` exactly once on the `"factory:control"` PubSub
  topic. Returns `:ok` synchronously.
  """
  @spec request_halt(GenServer.server()) :: :ok
  def request_halt(server) do
    GenServer.call(server, :request_halt)
  end

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5000
    }
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    pubsub = Keyword.fetch!(opts, :pubsub)
    sentinel_path = Keyword.get(opts, :sentinel_path)
    poll_interval = Keyword.get(opts, :poll_interval, @default_poll_interval_ms)

    state = %{
      pubsub: pubsub,
      sentinel_path: sentinel_path,
      poll_interval: poll_interval,
      sentinel_triggered: false
    }

    if sentinel_path do
      schedule_poll(poll_interval)
    end

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:request_halt, _from, state) do
    :ok = Phoenix.PubSub.broadcast(state.pubsub, "factory:control", :halt_requested)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info(:poll_sentinel, %{sentinel_triggered: true} = state) do
    schedule_poll(state.poll_interval)
    {:noreply, state}
  end

  def handle_info(:poll_sentinel, state) do
    next_state =
      if state.sentinel_path && File.exists?(state.sentinel_path) do
        Logger.info("[KillSwitch] sentinel detected at #{state.sentinel_path}; broadcasting halt")
        :ok = Phoenix.PubSub.broadcast(state.pubsub, "factory:control", :halt_requested)
        %{state | sentinel_triggered: true}
      else
        state
      end

    schedule_poll(next_state.poll_interval)
    {:noreply, next_state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp schedule_poll(interval) do
    Process.send_after(self(), :poll_sentinel, interval)
  end
end
