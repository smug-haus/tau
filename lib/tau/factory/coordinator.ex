defmodule Tau.Factory.Coordinator do
  @moduledoc """
  Factory Coordinator loop (K) — the `gen_statem` driver.

  States: `:running` → `:halting` → `:halted`.

  Drives units in order: call `select_fun.()` to pick work; call
  `drive_fun.(work)` to start it; wait for `{:unit_terminal, id, outcome}`;
  loop. Halts cleanly at a unit boundary when `:halt_requested` is received
  (D-321): the flag `halt_pending` is set, and the transition to `:halting`
  occurs only at the next `unit_terminal`, never mid-unit.

  Escalation routing (D-320):
    - `{:escalate, {e, :global}}` → `:halting` (total escalation).
    - `{:escalate, {e, :unit}}`   → stays `:running` (per-unit; loop continues).

  D-321 main-sync clause: when `:main_synced_fun` is configured, the
  `halting → halted` transition calls `main_synced_fun.()` before notifying
  `:on_halted`. If it returns `false`, the Coordinator stays in `:halting`
  and retries the sync check on the next drain attempt.

  NFR-KILL-LATENCY: when `:unit_max_ms` is configured, entering `:halting`
  with a unit in flight arms an absolute-ceiling timer. If the unit does not
  complete within `unit_max_ms`, the Coordinator forcibly ejects it and halts.

  See `docs/spec/SPEC-FACTORY-CORE.md`, D-321, D-320.
  """

  @behaviour :gen_statem

  alias Tau.Factory.Ledger.Reader, as: LedgerReader

  require Logger

  @terminal_states [:merged, :escalated]

  # Default retry interval (ms) for re-probing main_synced_fun when it returns false.
  @default_main_sync_retry_ms 250

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Start and register the Coordinator.

  Required options:
    - `:name`       — atom; registered name.
    - `:pubsub`     — atom; name of a running `Phoenix.PubSub`. The
                      Coordinator subscribes to `"factory:control"` and
                      handles `:halt_requested` from that topic.
    - `:select_fun` — `(-> work_item | nil)`; returns the next unit of
                      work or `nil` when idle.
    - `:drive_fun`  — `(work_item -> :ok)`; starts a unit. The unit sends
                      `{:unit_terminal, unit_id, outcome}` asynchronously
                      to the Coordinator to signal completion.

  Optional options:
    - `:scheduler`       — atom | pid | nil; passed through to `data.scheduler`
                           (D-380: admission is performed by the Unit FSM, not here).
    - `:on_halted`       — pid; notified with `:coordinator_halted` when the
                           Coordinator reaches `:halted`.
    - `:main_synced_fun` — `(-> boolean())`; called before transitioning to
                           `:halted` (D-321 main-sync clause). Must return `true`
                           to proceed. When `false`, the Coordinator stays in
                           `:halting` and does not notify `:on_halted`.
    - `:unit_max_ms`     — non_neg_integer(); absolute ceiling on unit runtime
                           (NFR-KILL-LATENCY). When set and a unit is in flight
                           during `:halting`, an accumulating timer fires after
                           this many ms and forces the unit to be ejected, then
                           halts the factory.
    - `:ledger`          — `GenServer.server()` reference to a running
                           `Ledger.Writer`. When present, `init/1` reads
                           `Ledger.Reader.latest_unit_snapshots/1` and rehydrates
                           each NON-terminal unit at its snapshotted state (driving
                           it forward). Units already at a terminal sink
                           (`:merged`/`:escalated`) are skipped — exactly-once on
                           resume (D-344 / §5 Coordinator `running` entry =
                           "start (resume from L)").
  """
  @spec start_link(keyword()) :: :gen_statem.start_ret()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    :gen_statem.start_link({:local, name}, __MODULE__, opts, [])
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
  # gen_statem callbacks
  # ---------------------------------------------------------------------------

  @impl :gen_statem
  def callback_mode, do: :state_functions

  @impl :gen_statem
  def init(opts) do
    pubsub = Keyword.fetch!(opts, :pubsub)
    select_fun = Keyword.fetch!(opts, :select_fun)
    drive_fun = Keyword.fetch!(opts, :drive_fun)
    scheduler = Keyword.get(opts, :scheduler)
    on_halted = Keyword.get(opts, :on_halted)
    main_synced_fun = Keyword.get(opts, :main_synced_fun)
    unit_max_ms = Keyword.get(opts, :unit_max_ms)
    ledger = Keyword.get(opts, :ledger)

    :ok = Phoenix.PubSub.subscribe(pubsub, "factory:control")

    # Resume from L when a ledger is provided (D-344, §5 "start (resume from L)").
    # Read latest_unit_snapshots/1 to discover which units were in flight at crash
    # time. Non-terminal units are rehydrated (driven). Terminal sinks are skipped.
    {rehydrated, init_events} =
      if ledger do
        snapshots = LedgerReader.latest_unit_snapshots(ledger)

        non_terminal =
          snapshots
          |> Enum.reject(fn {_uid, state} -> state in @terminal_states end)
          |> Map.new()

        if map_size(non_terminal) > 0 do
          # Schedule rehydration of all non-terminal units.
          {non_terminal, [{:next_event, :internal, {:rehydrate, non_terminal}}]}
        else
          {%{}, [{:next_event, :internal, :loop}]}
        end
      else
        {%{}, [{:next_event, :internal, :loop}]}
      end

    data = %{
      pubsub: pubsub,
      select_fun: select_fun,
      drive_fun: drive_fun,
      scheduler: scheduler,
      on_halted: on_halted,
      main_synced_fun: main_synced_fun,
      unit_max_ms: unit_max_ms,
      halt_pending: false,
      in_flight: nil,
      # Track rehydrated units so :sys.get_state reveals them (Oracle c).
      rehydrated: rehydrated
    }

    {:ok, :running, data, init_events}
  end

  # ---------------------------------------------------------------------------
  # State: :running
  # ---------------------------------------------------------------------------

  # Resume rehydration: drive each non-terminal unit that was in flight at crash
  # time. Each drive is sequential (one at a time), using the existing loop
  # mechanism. We drive the first one immediately; the loop handles subsequent
  # ones via {:unit_terminal, ...} → :loop after each completes.
  def running(:internal, {:rehydrate, non_terminal}, data) when map_size(non_terminal) == 0 do
    # All rehydrated — fall through to the normal select loop.
    {:keep_state, data, [{:next_event, :internal, :loop}]}
  end

  def running(:internal, {:rehydrate, non_terminal}, data) do
    # Pop one unit_id and drive it; store the remainder for post-terminal replay.
    [{unit_id, _state} | rest] = Map.to_list(non_terminal)
    remaining = Map.new(rest)
    data = drive_unit(data, unit_id, unit_id)
    data = Map.put(data, :rehydrate_queue, remaining)
    {:keep_state, data}
  end

  # Internal loop event: select next work and drive it (or idle).
  def running(:internal, :loop, data) do
    case data.select_fun.() do
      nil ->
        {:keep_state, %{data | in_flight: nil}}

      work ->
        unit_id = work
        data = drive_unit(data, work, unit_id)
        {:keep_state, data}
    end
  end

  # PubSub delivers messages via :info.
  def running(:info, :halt_requested, %{in_flight: nil} = data) do
    # No unit in flight: go straight to halting → halted.
    telemetry(:halt_requested, %{}, %{in_flight: nil})
    {:next_state, :halting, %{data | halt_pending: true}, [{:next_event, :internal, :drain}]}
  end

  def running(:info, :halt_requested, data) do
    # Unit in flight: transition to :halting immediately so the absolute-ceiling
    # timer (unit_max_ms / NFR-KILL-LATENCY) can be armed in :halting/:drain.
    # The unit terminal will still be handled in :halting if it arrives in time.
    telemetry(:halt_requested, %{}, %{in_flight: data.in_flight})

    {:next_state, :halting, %{data | halt_pending: true}, [{:next_event, :internal, :drain}]}
  end

  # Unit completed.
  def running(:info, {:unit_terminal, _unit_id, _outcome}, %{halt_pending: true} = data) do
    telemetry(:unit_terminal, %{}, %{halt_pending: true})
    {:next_state, :halting, %{data | in_flight: nil}, [{:next_event, :internal, :drain}]}
  end

  def running(:info, {:unit_terminal, _unit_id, _outcome}, data) do
    telemetry(:unit_terminal, %{}, %{halt_pending: false})
    data = %{data | in_flight: nil}

    # If rehydration of recovered units is still in progress, drive the next one.
    case Map.get(data, :rehydrate_queue, %{}) do
      queue when map_size(queue) > 0 ->
        {:keep_state, data, [{:next_event, :internal, {:rehydrate, queue}}]}

      _ ->
        # Loop: select and drive next work.
        {:keep_state, data, [{:next_event, :internal, :loop}]}
    end
  end

  # Also handle the 4-arg variant sent by the real Unit FSM (D-340).
  def running(
        :info,
        {:unit_terminal, _unit_id, _outcome, _provenance},
        %{halt_pending: true} = data
      ) do
    telemetry(:unit_terminal, %{}, %{halt_pending: true})
    {:next_state, :halting, %{data | in_flight: nil}, [{:next_event, :internal, :drain}]}
  end

  def running(:info, {:unit_terminal, _unit_id, _outcome, _provenance}, data) do
    telemetry(:unit_terminal, %{}, %{halt_pending: false})
    data = %{data | in_flight: nil}

    case Map.get(data, :rehydrate_queue, %{}) do
      queue when map_size(queue) > 0 ->
        {:keep_state, data, [{:next_event, :internal, {:rehydrate, queue}}]}

      _ ->
        {:keep_state, data, [{:next_event, :internal, :loop}]}
    end
  end

  # Global escalation → halting (D-320).
  # If a unit is in flight, route through :halting and AWAIT {:unit_terminal}
  # so the in-flight unit is drained before reaching :halted (drain-first).
  # If no unit is in flight, the existing halting(:internal, :drain) nil-branch
  # transitions immediately to :halted.
  def running(:info, {:escalate, {_e, :global}}, data) do
    telemetry(:escalate, %{}, %{scope: :global})
    {:next_state, :halting, data, [{:next_event, :internal, :drain}]}
  end

  # Per-unit escalation → stay running; treat as a terminal for loop progress.
  def running(:info, {:escalate, {_e, :unit}}, data) do
    telemetry(:escalate, %{}, %{scope: :unit})
    data = %{data | in_flight: nil}
    {:keep_state, data, [{:next_event, :internal, :loop}]}
  end

  def running(event_type, event, data) do
    Logger.debug("[Coordinator] running: unhandled #{inspect(event_type)} #{inspect(event)}")
    {:keep_state, data}
  end

  # ---------------------------------------------------------------------------
  # State: :halting
  # ---------------------------------------------------------------------------

  # Drain: if no in-flight unit, check main-sync then transition to halted.
  # D-321 main-sync clause: call main_synced_fun before notifying :on_halted.
  # If it returns false, stay in :halting and schedule a retry drain (D-321 retry path).
  def halting(:internal, :drain, %{in_flight: nil} = data) do
    if main_synced?(data) do
      do_halt(data)
    else
      Logger.debug("[Coordinator] halting: main not synced, scheduling retry drain")
      retry_ms = Map.get(data, :main_sync_retry_ms, @default_main_sync_retry_ms)
      {:keep_state, data, [{{:timeout, :main_sync_retry}, retry_ms, :drain}]}
    end
  end

  # D-321 retry path: re-probe main_synced_fun after the retry interval.
  def halting({:timeout, :main_sync_retry}, :drain, data) do
    {:keep_state, data, [{:next_event, :internal, :drain}]}
  end

  # In-flight unit exists: arm the absolute-ceiling timer if configured
  # (NFR-KILL-LATENCY), then wait for the terminal.
  def halting(:internal, :drain, data) do
    actions = arm_unit_max_timer(data)
    {:keep_state, data, actions}
  end

  # Unit completed while halting: clear in_flight, check main-sync, halt.
  def halting(:info, {:unit_terminal, _unit_id, _outcome}, data) do
    telemetry(:unit_terminal, %{}, %{state: :halting})
    data = %{data | in_flight: nil}

    if main_synced?(data) do
      do_halt(data)
    else
      Logger.debug("[Coordinator] halting: unit terminal, but main not synced; scheduling retry")
      retry_ms = Map.get(data, :main_sync_retry_ms, @default_main_sync_retry_ms)
      {:keep_state, data, [{{:timeout, :main_sync_retry}, retry_ms, :drain}]}
    end
  end

  # Also handle the 4-arg variant sent by the real Unit FSM (D-340).
  def halting(:info, {:unit_terminal, _unit_id, _outcome, _provenance}, data) do
    telemetry(:unit_terminal, %{}, %{state: :halting})
    data = %{data | in_flight: nil}

    if main_synced?(data) do
      do_halt(data)
    else
      Logger.debug(
        "[Coordinator] halting: unit terminal (4-arg), but main not synced; scheduling retry"
      )

      retry_ms = Map.get(data, :main_sync_retry_ms, @default_main_sync_retry_ms)
      {:keep_state, data, [{{:timeout, :main_sync_retry}, retry_ms, :drain}]}
    end
  end

  # NFR-KILL-LATENCY: absolute-ceiling named timeout fired. The in-flight unit
  # is forcibly ejected (treated as escalated). Proceed to halt regardless of
  # main-sync (the ceiling is an absolute bound, not a soft drain).
  def halting({:timeout, :unit_max_ceiling}, :unit_max_timeout, data) do
    Logger.warning(
      "[Coordinator] halting: unit_max_ms elapsed; forcibly ejecting in_flight unit " <>
        inspect(data.in_flight)
    )

    data = %{data | in_flight: nil}
    do_halt(data)
  end

  # Absorb stray halt_requested (already halting).
  def halting(:info, :halt_requested, data) do
    {:keep_state, %{data | halt_pending: true}}
  end

  def halting(event_type, event, data) do
    Logger.debug("[Coordinator] halting: unhandled #{inspect(event_type)} #{inspect(event)}")
    {:keep_state, data}
  end

  # ---------------------------------------------------------------------------
  # State: :halted
  # ---------------------------------------------------------------------------

  def halted(_event_type, _event, data) do
    {:keep_state, data}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Drive a unit: call drive_fun and mark unit in-flight.
  # D-380 single-authority: the Coordinator MUST NOT call Scheduler.admit.
  # The Unit FSM planned state is the sole admitter (with the real declared_scope).
  defp drive_unit(data, work, unit_id) do
    :ok = data.drive_fun.(work)
    %{data | in_flight: unit_id}
  end

  # D-321 main-sync check: call main_synced_fun if configured; default true.
  defp main_synced?(%{main_synced_fun: nil}), do: true
  defp main_synced?(%{main_synced_fun: fun}) when is_function(fun, 0), do: fun.()

  # Notify :on_halted and transition to :halted.
  defp do_halt(data) do
    notify_halted(data)
    {:next_state, :halted, data}
  end

  # NFR-KILL-LATENCY: arm the absolute-ceiling timer when entering :halting
  # with a unit in flight. The timer fires :unit_max_timeout as an :info message.
  defp arm_unit_max_timer(%{unit_max_ms: nil}), do: []

  defp arm_unit_max_timer(%{unit_max_ms: ms}) when is_integer(ms) and ms > 0 do
    # gen_statem state_timeout fires when the state hasn't changed for ms.
    # Since we stay in :halting, a Process.send_after to self is cleaner
    # and avoids interaction with the state-timeout mechanism used in Unit FSM.
    [{{:timeout, :unit_max_ceiling}, ms, :unit_max_timeout}]
  end

  defp arm_unit_max_timer(_), do: []

  defp notify_halted(%{on_halted: nil}), do: :ok

  defp notify_halted(%{on_halted: pid}) when is_pid(pid) do
    send(pid, :coordinator_halted)
    :ok
  end

  defp telemetry(event, measurements, metadata) do
    :telemetry.execute([:tau, :factory, :coordinator, event], measurements, metadata)
  end
end
