defmodule Tau.Factory.Fleet.Watchdog do
  @moduledoc """
  Heartbeat-absence watchdog for the Factory Worker fleet (W).

  The Watchdog monitors registered workers by observing
  `[:tau, :factory, :worker, :heartbeat]` telemetry events keyed by
  `%{worker_id: worker_id}` in the event metadata. When a registered worker
  has not emitted a heartbeat for longer than its configured
  `heartbeat_timeout`, the Watchdog sends `{:worker_stalled, worker_id}` to
  the registered `report_to` pid **exactly once per stall window** (C213).

  A stall window begins when the worker's heartbeat goes silent and ends when
  a fresh heartbeat arrives. On the leading edge of each new window the
  Watchdog fires the notification exactly once; subsequent scan cycles in the
  same window are suppressed by the `stalled?` flag.

  A `:DOWN` event (crash/exit) deregisters the worker without sending a
  `{:worker_stalled, _}` message — crash handling is the WorkspaceJanitor's
  responsibility (D-309, C217).

  ## Telemetry-handler discipline

  The telemetry handler is attached at `init/1` and detached in `terminate/2`.
  It runs in the **emitting process** (the Worker), so the handler does ONLY
  a `GenServer.cast` — no blocking operations (OTP non-negotiable: telemetry
  handlers must be non-blocking).

  ## Monotonic clock

  All timeout arithmetic uses `System.monotonic_time(:millisecond)` (not the
  wall clock) to avoid skew from NTP adjustments or DST.

  See `docs/spec/SPEC-FACTORY-FLEET.md`, D-309, D-317, C206, C213, C217.
  """

  use GenServer

  require Logger

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Start the Watchdog as a supervised GenServer.

  Required opts:
    - `:name`            — atom; registered name for this GenServer.
    - `:check_interval`  — ms; how often the Watchdog scans for stalled workers.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Register a worker with the Watchdog.

  The Watchdog calls `Process.monitor(worker_pid)`. If the worker has not
  emitted a `[:tau, :factory, :worker, :heartbeat]` telemetry event with
  `%{worker_id: worker_id}` in metadata for longer than `heartbeat_timeout`
  ms, the Watchdog sends `{:worker_stalled, worker_id}` to `report_to`
  **exactly once per stall window** (C213).

  On receiving a `:DOWN` for `worker_pid` the Watchdog deregisters the worker
  without sending a stall message (C217).

  Required keyword opts:
    - `:heartbeat_timeout` — ms; maximum acceptable silence window.
  """
  @spec register(
          GenServer.server(),
          String.t(),
          pid(),
          pid(),
          keyword()
        ) :: :ok
  def register(watchdog, worker_id, worker_pid, report_to, opts) do
    timeout = Keyword.fetch!(opts, :heartbeat_timeout)
    GenServer.call(watchdog, {:register, worker_id, worker_pid, report_to, timeout})
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    check_interval = Keyword.fetch!(opts, :check_interval)

    # Unique handler id prevents attach conflicts when multiple Watchdog
    # instances coexist (e.g. in async: false tests each with a unique :name).
    handler_id = {__MODULE__, self()}

    :telemetry.attach(
      handler_id,
      [:tau, :factory, :worker, :heartbeat],
      &__MODULE__.handle_heartbeat_event/4,
      self()
    )

    Process.send_after(self(), :scan, check_interval)

    {:ok,
     %{
       check_interval: check_interval,
       handler_id: handler_id,
       # worker_id => %{report_to, timeout, last_seen, stalled?, ref}
       workers: %{},
       # ref => worker_id (reverse index for :DOWN lookup)
       refs: %{}
     }}
  end

  @impl GenServer
  def handle_call({:register, worker_id, worker_pid, report_to, timeout}, _from, state) do
    ref = Process.monitor(worker_pid)
    now = System.monotonic_time(:millisecond)

    entry = %{
      report_to: report_to,
      timeout: timeout,
      last_seen: now,
      stalled?: false,
      ref: ref
    }

    new_workers = Map.put(state.workers, worker_id, entry)
    new_refs = Map.put(state.refs, ref, worker_id)

    {:reply, :ok, %{state | workers: new_workers, refs: new_refs}}
  end

  @impl GenServer
  def handle_cast({:heartbeat, worker_id}, state) do
    case Map.get(state.workers, worker_id) do
      nil ->
        # Heartbeat from an unknown worker — ignore.
        {:noreply, state}

      entry ->
        now = System.monotonic_time(:millisecond)
        updated_entry = %{entry | last_seen: now, stalled?: false}
        new_workers = Map.put(state.workers, worker_id, updated_entry)
        {:noreply, %{state | workers: new_workers}}
    end
  end

  @impl GenServer
  def handle_info(:scan, state) do
    now = System.monotonic_time(:millisecond)

    new_workers =
      Map.new(state.workers, fn {worker_id, entry} ->
        elapsed = now - entry.last_seen

        updated_entry =
          if elapsed > entry.timeout and not entry.stalled? do
            # Leading edge of a stall window: notify exactly once (C213).
            send(entry.report_to, {:worker_stalled, worker_id})
            %{entry | stalled?: true}
          else
            entry
          end

        {worker_id, updated_entry}
      end)

    Process.send_after(self(), :scan, state.check_interval)

    {:noreply, %{state | workers: new_workers}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.get(state.refs, ref) do
      nil ->
        # Unknown ref — ignore.
        {:noreply, state}

      worker_id ->
        Process.demonitor(ref, [:flush])
        new_workers = Map.delete(state.workers, worker_id)
        new_refs = Map.delete(state.refs, ref)
        {:noreply, %{state | workers: new_workers, refs: new_refs}}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    :telemetry.detach(state.handler_id)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Telemetry handler (runs in the EMITTING process — only cast, no blocking)
  # ---------------------------------------------------------------------------

  @doc false
  @spec handle_heartbeat_event(
          [atom()],
          map(),
          %{worker_id: String.t()},
          pid()
        ) :: :ok
  def handle_heartbeat_event(_event, _measurements, %{worker_id: worker_id}, watchdog_pid) do
    GenServer.cast(watchdog_pid, {:heartbeat, worker_id})
  end

  # Guard: ignore malformed metadata rather than crashing the emitting process.
  def handle_heartbeat_event(_event, _measurements, _metadata, _watchdog_pid), do: :ok
end
