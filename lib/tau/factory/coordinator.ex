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

  See `docs/spec/SPEC-FACTORY-CORE.md`, D-321, D-320.
  """

  @behaviour :gen_statem

  alias Tau.Factory.Ledger.Reader, as: LedgerReader

  require Logger

  @terminal_states [:merged, :escalated]

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
    - `:scheduler`  — atom | pid | nil; passed through to `data.scheduler`
                      (D-380: admission is performed by the Unit FSM, not here).
    - `:on_halted`  — pid; notified with `:coordinator_halted` when the
                      Coordinator reaches `:halted`.
    - `:ledger`     — `GenServer.server()` reference to a running
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
    # Unit in flight: set flag, honour at next terminal.
    telemetry(:halt_requested, %{}, %{in_flight: data.in_flight})
    {:keep_state, %{data | halt_pending: true}}
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

  # Drain: if no in-flight unit, transition to halted.
  def halting(:internal, :drain, %{in_flight: nil} = data) do
    notify_halted(data)
    {:next_state, :halted, data}
  end

  def halting(:internal, :drain, data) do
    # In-flight unit exists: wait for its terminal.
    {:keep_state, data}
  end

  # Unit completed while halting: drain now.
  def halting(:info, {:unit_terminal, _unit_id, _outcome}, data) do
    telemetry(:unit_terminal, %{}, %{state: :halting})
    data = %{data | in_flight: nil}
    notify_halted(data)
    {:next_state, :halted, data}
  end

  # Also handle the 4-arg variant sent by the real Unit FSM (D-340).
  def halting(:info, {:unit_terminal, _unit_id, _outcome, _provenance}, data) do
    telemetry(:unit_terminal, %{}, %{state: :halting})
    data = %{data | in_flight: nil}
    notify_halted(data)
    {:next_state, :halted, data}
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

  defp notify_halted(%{on_halted: nil}), do: :ok

  defp notify_halted(%{on_halted: pid}) when is_pid(pid) do
    send(pid, :coordinator_halted)
    :ok
  end

  defp telemetry(event, measurements, metadata) do
    :telemetry.execute([:tau, :factory, :coordinator, event], measurements, metadata)
  end
end
