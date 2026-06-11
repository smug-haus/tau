defmodule Tau.Factory.Unit do
  @moduledoc """
  Per-PR Unit FSM — the lifecycle driver for a single PR unit.

  Implements the Unit (U) state machine from SPEC-FACTORY-CORE §5:

      planned → oracle → implementing → gating → awaiting_merge → merged
      gating {:fail,_} → retry ladder → implementing | escalated
      awaiting_merge :rejected → gating (re-gate, INV-2)
      any non-terminal + :state_timeout → escalated (C107)
      worker :DOWN → escalated (B8/C105 infra path, gate never called)

  D-318: total gate invocations == N_refine + N_pivot (exactly, bounded retry via
  `Tau.Factory.Retry.next/3`). The pivot IS a real implementing attempt that goes
  back through gating; only after pivot's gate-fail does `Retry.next` return
  `:exhausted` and escalation occurs.

  D-340: every terminal state sends `{:unit_terminal, unit_id, outcome, provenance}`
  to `report_to` and releases from the Scheduler before stopping.

  B8: the Unit holds a `Process.monitor/1` ref on the worker for liveness.
  Worker pid is stored under `:worker_pid` in state data (test-observable via
  `:sys.get_state/1`).

  C105: semantic gate failures (retry ladder) and infra failures (:state_timeout,
  :DOWN) are distinct code paths. Gate is NEVER called on the infra path.

  See `docs/spec/SPEC-FACTORY-CORE.md` §5, D-318, D-340.
  """

  @behaviour :gen_statem

  alias Tau.Factory.Retry
  alias Tau.Factory.Scheduler

  require Logger

  @default_state_timeout_ms 30_000

  # ---------------------------------------------------------------------------
  # Types
  # ---------------------------------------------------------------------------

  @type unit_id :: String.t()

  @type provenance :: %{
          attempt_count: non_neg_integer(),
          last_findings: [term()] | nil,
          reason: atom() | nil
        }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Start and link the Unit FSM.

  Required options:
    - `:unit_id`        — `String.t()`; unique identity; registered in UnitRegistry.
    - `:declared_scope` — scope map passed to `Scheduler.admit/3`.
    - `:hash`           — `String.t()`; content hash for the PR.
    - `:scheduler`      — atom or pid of a running `Tau.Factory.Scheduler`.
    - `:report_to`      — pid receiving `{:unit_terminal, unit_id, outcome, provenance}`.
    - `:worker_fun`     — `(role :: atom() -> {:ok, worker_pid :: pid()} | {:error, reason})`.
                         Returns a real process pid; the Unit monitors it via
                         `Process.monitor/1` for liveness (B8).
    - `:gate_fun`       — `(-> :pass | {:fail, findings :: [term()]})`.
    - `:merge_fun`      — `(unit_id, hash -> :queued | {:error, reason})`.

  Optional options:
    - `:timeouts`       — keyword with `:state_timeout_ms` (default 30_000).
  """
  @spec start_link(keyword()) :: :ignore | {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    :gen_statem.start_link(__MODULE__, opts, [])
  end

  # ---------------------------------------------------------------------------
  # gen_statem callbacks
  # ---------------------------------------------------------------------------

  @impl :gen_statem
  def callback_mode, do: :state_functions

  @impl :gen_statem
  def init(opts) do
    unit_id = Keyword.fetch!(opts, :unit_id)
    declared_scope = Keyword.fetch!(opts, :declared_scope)
    hash = Keyword.fetch!(opts, :hash)
    scheduler = Keyword.fetch!(opts, :scheduler)
    report_to = Keyword.fetch!(opts, :report_to)
    worker_fun = Keyword.fetch!(opts, :worker_fun)
    gate_fun = Keyword.fetch!(opts, :gate_fun)
    merge_fun = Keyword.fetch!(opts, :merge_fun)
    timeouts = Keyword.get(opts, :timeouts, [])
    state_timeout_ms = Keyword.get(timeouts, :state_timeout_ms, @default_state_timeout_ms)

    data = %{
      unit_id: unit_id,
      declared_scope: declared_scope,
      hash: hash,
      scheduler: scheduler,
      report_to: report_to,
      worker_fun: worker_fun,
      gate_fun: gate_fun,
      merge_fun: merge_fun,
      state_timeout_ms: state_timeout_ms,
      # Current worker pid (B8 — real process, monitorable).
      worker_pid: nil,
      # Monitor ref for the current worker.
      worker_mref: nil,
      # Retry counters.
      refine_count: 0,
      pivot_count: 0,
      # True when the next gating entry is the pivot's gate call. After the
      # pivot's gate_fun runs (and fails), we escalate directly without
      # consulting Retry.next again. This ensures gate_fun is called exactly
      # N_REFINE + N_PIVOT times (D-318).
      in_pivot: false,
      # Total times implementing state was entered (non-terminal attempts).
      attempt_count: 0,
      # Last gate findings (nil until a gate failure occurs).
      last_findings: nil
    }

    # Transition immediately to planned state, which triggers admission.
    {:ok, :planned, data, [{:next_event, :internal, :on_enter}]}
  end

  # ---------------------------------------------------------------------------
  # State: :planned
  # Calls Scheduler.admit; on :admit → oracle; on {:defer, _} → escalated.
  # ---------------------------------------------------------------------------

  def planned(:internal, :on_enter, data) do
    case Scheduler.admit(data.scheduler, data.unit_id, data.declared_scope) do
      :admit ->
        {:next_state, :oracle, data, [{:next_event, :internal, :on_enter}]}

      {:defer, reason} ->
        Logger.info("[Unit #{data.unit_id}] deferred from Scheduler: #{inspect(reason)}")
        escalate(data, :E_SCHEDULER_DEFER)
    end
  end

  def planned(event_type, event, data) do
    handle_unexpected(:planned, event_type, event, data)
  end

  # ---------------------------------------------------------------------------
  # State: :oracle
  # Calls worker_fun(:test_author); waits for {:worker_done, worker_pid}.
  # Monitors worker_pid for crash (B8). Arms :state_timeout (C107).
  # ---------------------------------------------------------------------------

  def oracle(:internal, :on_enter, data) do
    case data.worker_fun.(:test_author) do
      {:ok, worker_pid} ->
        mref = Process.monitor(worker_pid)
        new_data = %{data | worker_pid: worker_pid, worker_mref: mref}
        timeout_ms = data.state_timeout_ms
        {:keep_state, new_data, [{:state_timeout, timeout_ms, :worker_stalled}]}

      {:error, reason} ->
        Logger.warning("[Unit #{data.unit_id}] worker_fun(:test_author) error: #{inspect(reason)}")
        escalate(data, :E_WORKER_ERROR)
    end
  end

  def oracle(:info, {:worker_done, worker_pid}, %{worker_pid: worker_pid} = data)
      when not is_nil(worker_pid) do
    Process.demonitor(data.worker_mref, [:flush])
    new_data = %{data | worker_pid: nil, worker_mref: nil}
    {:next_state, :implementing, new_data, [{:next_event, :internal, :on_enter}]}
  end

  # Ignore :worker_done for unknown pids (stale or spurious).
  def oracle(:info, {:worker_done, _other_pid}, data) do
    {:keep_state, data}
  end

  def oracle(:state_timeout, :worker_stalled, data) do
    Logger.warning("[Unit #{data.unit_id}] oracle :state_timeout — worker stalled")
    demonitor_worker(data)
    escalate(data, :E_WORKER_STALLED)
  end

  # Handle monitored worker :DOWN (infra crash path, B8/C105).
  def oracle(:info, {:DOWN, _mref, :process, worker_pid, reason}, %{worker_pid: worker_pid} = data)
      when not is_nil(worker_pid) do
    Logger.warning("[Unit #{data.unit_id}] oracle worker :DOWN: #{inspect(reason)}")
    new_data = %{data | worker_pid: nil, worker_mref: nil}
    escalate(new_data, :E_WORKER_DOWN)
  end

  def oracle(event_type, event, data) do
    handle_unexpected(:oracle, event_type, event, data)
  end

  # ---------------------------------------------------------------------------
  # State: :implementing
  # Calls worker_fun(:implementer); waits for {:worker_done, worker_pid}.
  # Monitors worker_pid for crash (B8). Arms :state_timeout (C107).
  # Increments attempt_count.
  # ---------------------------------------------------------------------------

  def implementing(:internal, :on_enter, data) do
    new_data = %{data | attempt_count: data.attempt_count + 1}

    case new_data.worker_fun.(:implementer) do
      {:ok, worker_pid} ->
        mref = Process.monitor(worker_pid)
        updated_data = %{new_data | worker_pid: worker_pid, worker_mref: mref}
        timeout_ms = updated_data.state_timeout_ms
        {:keep_state, updated_data, [{:state_timeout, timeout_ms, :worker_stalled}]}

      {:error, reason} ->
        Logger.warning(
          "[Unit #{new_data.unit_id}] worker_fun(:implementer) error: #{inspect(reason)}"
        )

        escalate(new_data, :E_WORKER_ERROR)
    end
  end

  def implementing(:info, {:worker_done, worker_pid}, %{worker_pid: worker_pid} = data)
      when not is_nil(worker_pid) do
    Process.demonitor(data.worker_mref, [:flush])
    new_data = %{data | worker_pid: nil, worker_mref: nil}
    {:next_state, :gating, new_data, [{:next_event, :internal, :on_enter}]}
  end

  # Ignore :worker_done for unknown pids.
  def implementing(:info, {:worker_done, _other_pid}, data) do
    {:keep_state, data}
  end

  def implementing(:state_timeout, :worker_stalled, data) do
    Logger.warning("[Unit #{data.unit_id}] implementing :state_timeout — worker stalled")
    demonitor_worker(data)
    escalate(data, :E_WORKER_STALLED)
  end

  # Handle monitored worker :DOWN (infra crash path, B8/C105).
  def implementing(
        :info,
        {:DOWN, _mref, :process, worker_pid, reason},
        %{worker_pid: worker_pid} = data
      )
      when not is_nil(worker_pid) do
    Logger.warning("[Unit #{data.unit_id}] implementing worker :DOWN: #{inspect(reason)}")
    new_data = %{data | worker_pid: nil, worker_mref: nil}
    # C105: infra crash — do NOT call gate_fun. Route straight to escalated.
    escalate(new_data, :E_WORKER_DOWN)
  end

  def implementing(event_type, event, data) do
    handle_unexpected(:implementing, event_type, event, data)
  end

  # ---------------------------------------------------------------------------
  # State: :gating
  # Calls gate_fun() synchronously on entry via an internal event.
  # :pass → awaiting_merge.
  # {:fail, findings} → retry ladder → implementing (refine/pivot) | escalated.
  #
  # D-318 retry ladder:
  #   {:refine, k}  → bump refine_count → back to :implementing
  #   :pivot        → bump pivot_count  → back to :implementing (real attempt!)
  #   :exhausted    → escalate :E_RETRY_EXHAUSTED
  # ---------------------------------------------------------------------------

  def gating(:internal, :on_enter, data) do
    # D-318 exact-count gate discipline (fix f-1):
    #
    # The retry ladder gate call count is N_REFINE + N_PIVOT (exactly).
    # Semantics:
    #   - N_REFINE gate calls each return {:refine, k} → go back to implementing.
    #   - 1 gate call (the N_REFINE+1-th... wait, Retry returns :pivot at N_REFINE)
    #     returns :pivot → go to implementing ONE MORE TIME (the "pivot attempt").
    #     After the pivot implementing completes, escalate WITHOUT a gate call.
    #     This makes the gate-call count N_REFINE + N_PIVOT where N_PIVOT counts the
    #     gate calls that DECIDE pivot (1 call returning :pivot), not a gate call
    #     following the pivot implementing.
    #
    # in_pivot: true ↔ the implementing that just completed was the pivot attempt.
    # In this case, escalate WITHOUT calling gate_fun (budget exhausted, D-318).
    if data.in_pivot do
      escalate(data, :E_RETRY_EXHAUSTED)
    else
      case data.gate_fun.() do
        :pass ->
          {:next_state, :awaiting_merge, data, [{:next_event, :internal, :on_enter}]}

        {:fail, findings} ->
          new_data = %{data | last_findings: findings}

          case Retry.next(:gate_fail, new_data.refine_count, new_data.pivot_count) do
            {:refine, _k} ->
              # Bump refine_count; go back to implementing for another attempt.
              bumped = %{new_data | refine_count: new_data.refine_count + 1}
              {:next_state, :implementing, bumped, [{:next_event, :internal, :on_enter}]}

            :pivot ->
              # D-318: this gate call counted as the "pivot decision" gate call.
              # Do one more implementing attempt (the pivot attempt) and then
              # escalate — in_pivot: true ensures the subsequent gating entry
              # escalates WITHOUT calling gate_fun. Gate call count = N_REFINE + 1
              # (for :pivot) = N_REFINE + N_PIVOT (since N_PIVOT = 1 counts this call).
              bumped = %{new_data | pivot_count: new_data.pivot_count + 1, in_pivot: true}
              {:next_state, :implementing, bumped, [{:next_event, :internal, :on_enter}]}

            :exhausted ->
              # Both N_REFINE refines and N_PIVOT decisions have been consumed.
              escalate(new_data, :E_RETRY_EXHAUSTED)
          end
      end
    end
  end

  def gating(event_type, event, data) do
    handle_unexpected(:gating, event_type, event, data)
  end

  # ---------------------------------------------------------------------------
  # State: :awaiting_merge
  # Calls merge_fun(unit_id, hash) on entry; result arrives as {:merge_result, _}.
  # :merged → terminal. :rejected → gating (re-gate, INV-2).
  # Arms :state_timeout (C107).
  # ---------------------------------------------------------------------------

  def awaiting_merge(:internal, :on_enter, data) do
    _result = data.merge_fun.(data.unit_id, data.hash)
    timeout_ms = data.state_timeout_ms
    {:keep_state, data, [{:state_timeout, timeout_ms, :merge_stalled}]}
  end

  def awaiting_merge(:info, {:merge_result, :merged}, data) do
    terminal(data, :merged, nil, nil)
  end

  def awaiting_merge(:info, {:merge_result, :rejected}, data) do
    # INV-2: merge reject → re-gate.
    {:next_state, :gating, data, [{:next_event, :internal, :on_enter}]}
  end

  def awaiting_merge(:state_timeout, :merge_stalled, data) do
    Logger.warning("[Unit #{data.unit_id}] awaiting_merge :state_timeout — merge stalled")
    escalate(data, :E_MERGE_STALLED)
  end

  def awaiting_merge(event_type, event, data) do
    handle_unexpected(:awaiting_merge, event_type, event, data)
  end

  # ---------------------------------------------------------------------------
  # Terminal states: :merged, :escalated
  # Both are quiescent sinks — no further transitions.
  # ---------------------------------------------------------------------------

  def merged(event_type, event, data) do
    handle_unexpected(:merged, event_type, event, data)
  end

  def escalated(event_type, event, data) do
    handle_unexpected(:escalated, event_type, event, data)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Escalate the Unit: send the terminal report with :escalated outcome and
  # enter the :escalated quiescent-sink state.
  @spec escalate(map(), atom()) :: {:next_state, :escalated, map()}
  defp escalate(data, reason) do
    terminal(data, :escalated, data.last_findings, reason)
  end

  # Demonitor the current worker if a monitor ref is present.
  @spec demonitor_worker(map()) :: :ok
  defp demonitor_worker(%{worker_mref: nil}), do: :ok

  defp demonitor_worker(%{worker_mref: mref}) do
    Process.demonitor(mref, [:flush])
    :ok
  end

  # Build the provenance map, release from Scheduler, notify report_to, then
  # enter the terminal state (quiescent sink). We do NOT stop the process so
  # that callers may still inspect state via :sys.get_state/1.
  @spec terminal(map(), atom(), [term()] | nil, atom() | nil) ::
          {:next_state, atom(), map()}
  defp terminal(data, outcome, last_findings, reason) do
    provenance = %{
      attempt_count: data.attempt_count,
      last_findings: last_findings,
      reason: reason
    }

    Scheduler.release(data.scheduler, data.unit_id)
    send(data.report_to, {:unit_terminal, data.unit_id, outcome, provenance})

    emit_telemetry(outcome, data, provenance)

    # Store provenance in data so :sys.get_state can read it if needed.
    new_data = Map.put(data, :terminal_provenance, provenance)

    {:next_state, outcome, new_data}
  end

  defp emit_telemetry(outcome, data, provenance) do
    :telemetry.execute(
      [:tau, :factory, :unit, outcome],
      %{attempt_count: provenance.attempt_count},
      %{unit_id: data.unit_id, reason: provenance.reason}
    )
  end

  # Drop a spurious internal on_enter if it arrives in a terminal state,
  # or log unexpected messages for debugging.
  defp handle_unexpected(state, :info, msg, data) do
    Logger.debug("[Unit #{data.unit_id}] #{state} ignoring message: #{inspect(msg)}")
    {:keep_state, data}
  end

  defp handle_unexpected(state, :internal, :on_enter, data) do
    Logger.debug("[Unit #{data.unit_id}] #{state} ignoring stray :on_enter")
    {:keep_state, data}
  end

  defp handle_unexpected(state, event_type, event, data) do
    Logger.debug(
      "[Unit #{data.unit_id}] #{state} ignoring #{inspect(event_type)}: #{inspect(event)}"
    )

    {:keep_state, data}
  end
end
