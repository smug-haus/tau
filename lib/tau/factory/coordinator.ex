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

  alias Tau.Factory.Scheduler

  require Logger

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
    - `:scheduler`  — atom | pid | nil; when non-nil, `Scheduler.admit/3`
                      is called before driving.
    - `:on_halted`  — pid; notified with `:coordinator_halted` when the
                      Coordinator reaches `:halted`.
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

    :ok = Phoenix.PubSub.subscribe(pubsub, "factory:control")

    data = %{
      pubsub: pubsub,
      select_fun: select_fun,
      drive_fun: drive_fun,
      scheduler: scheduler,
      on_halted: on_halted,
      halt_pending: false,
      in_flight: nil
    }

    # Kick off the loop immediately: try to find and drive first work item.
    {:ok, :running, data, [{:next_event, :internal, :loop}]}
  end

  # ---------------------------------------------------------------------------
  # State: :running
  # ---------------------------------------------------------------------------

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
    # Loop: select and drive next work.
    telemetry(:unit_terminal, %{}, %{halt_pending: false})
    data = %{data | in_flight: nil}
    {:keep_state, data, [{:next_event, :internal, :loop}]}
  end

  # Global escalation → halting.
  def running(:info, {:escalate, {_e, :global}}, data) do
    telemetry(:escalate, %{}, %{scope: :global})
    {:next_state, :halting, %{data | in_flight: nil}, [{:next_event, :internal, :drain}]}
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

  # Forward unit_finished notifications to on_halted when the drive_fun was
  # invoked from this process's context (self() = coordinator in the closure),
  # so the test/caller receives the notification rather than losing it.
  def halted(:info, {:unit_finished, _unit_id} = msg, %{on_halted: on_halted} = data)
      when is_pid(on_halted) do
    send(on_halted, msg)
    {:keep_state, data}
  end

  def halted(_event_type, _event, data) do
    {:keep_state, data}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Drive a unit: optionally gate through Scheduler, then call drive_fun.
  defp drive_unit(%{scheduler: nil} = data, work, unit_id) do
    :ok = data.drive_fun.(work)
    %{data | in_flight: unit_id}
  end

  @empty_scope %{
    deps: [],
    files: MapSet.new(),
    codepoints: MapSet.new(),
    specs: MapSet.new(),
    resources: MapSet.new()
  }

  defp drive_unit(data, work, unit_id) do
    declared_scope = @empty_scope

    case Scheduler.admit(data.scheduler, unit_id, declared_scope) do
      :admit ->
        :ok = data.drive_fun.(work)
        %{data | in_flight: unit_id}

      {:defer, _reason} ->
        # Deferred: stay idle until a future event re-triggers the loop.
        %{data | in_flight: nil}
    end
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
