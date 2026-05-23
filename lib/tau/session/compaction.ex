defmodule Tau.Session.Compaction do
  @moduledoc """
  Compaction logic and `:compacting` FSM clause handlers for `Tau.Session`.

  Encapsulates the two-path compaction contract: a synchronous post-turn path
  (`maybe_compact/2` → `compact/2`) and an asynchronous background-task path
  (three terminal FSM clauses for `:compacting`).

  ## Invariants

  - D-016: `compaction_failures` is a session-level counter shared across the
    sync and async paths. It increments on every `{:error, _}` result and
    resets to 0 only on `{:ok, _, _}`. It is NOT reset by `:cancel`.
  - After three consecutive failures, the sync path returns `{:abort, data}`
    and the session turn is aborted with `stop_reason: :compaction_failed`.
  - D-164: `%Events.CompactionFinished{}` fires on every exit from `:compacting`,
    including error and timeout paths, so the TUI status bar never sticks.
  """

  alias Tau.Session.Events

  @doc """
  Decide whether to compact and, if so, run compaction synchronously.

  Returns:
  - `data` — no compaction needed, or compaction succeeded.
  - `{:soft_error, data}` — compaction failed but `compaction_failures < 3`; caller broadcasts a notice and continues.
  - `{:abort, data}` — `compaction_failures >= 3` (D-016); caller aborts the turn.
  """
  @spec maybe_compact(Tau.Session.Data.t(), map()) ::
          Tau.Session.Data.t()
          | {:soft_error, Tau.Session.Data.t()}
          | {:abort, Tau.Session.Data.t()}
  def maybe_compact(data, usage) do
    compactor = Tau.Compactor.impl()

    if compactor.should_compact?(data.messages, usage) do
      compact(data, %{provider: data.provider, model: data.model})
    else
      data
    end
  end

  @doc """
  Run compaction synchronously.

  Shared core invoked by both the sync post-turn path and the async worker
  result handler. Returns `data`, `{:soft_error, data}`, or `{:abort, data}`.
  """
  @spec compact(Tau.Session.Data.t(), map()) ::
          Tau.Session.Data.t()
          | {:soft_error, Tau.Session.Data.t()}
          | {:abort, Tau.Session.Data.t()}
  def compact(data, ctx) do
    compactor = Tau.Compactor.impl()

    :telemetry.execute([:tau, :compaction, :start], %{system_time: System.system_time()}, %{
      session_id: data.id,
      message_count: length(data.messages)
    })

    case compactor.compact(data.messages, ctx) do
      {:ok, new_messages, summary_text} ->
        data =
          Tau.Session.Journal.persist(data, "compaction", %{
            before_count: length(data.messages),
            after_count: length(new_messages),
            summary: Tau.Session.Journal.format_summary_for_persist(summary_text)
          })

        :telemetry.execute([:tau, :compaction, :stop], %{system_time: System.system_time()}, %{
          session_id: data.id,
          after_count: length(new_messages)
        })

        %{data | messages: new_messages, compaction_failures: 0}

      {:error, reason} ->
        :telemetry.execute(
          [:tau, :compaction, :exception],
          %{system_time: System.system_time()},
          %{session_id: data.id, reason: reason, kind: :compactor_error}
        )

        failures = data.compaction_failures + 1

        if failures >= 3 do
          {:abort, %{data | compaction_failures: failures}}
        else
          {:soft_error, %{data | compaction_failures: failures}}
        end
    end
  end

  @doc """
  Emit per-turn prompt-cache hit/write telemetry.

  SPEC-PROMPT-CACHING AC-4: surfaces the per-turn prompt-cache signal so a
  silent cache miss (a cost regression) is observable. Reads canonical B3
  usage-map keys (`:cache_read` / `:cache_write` / `:cache_breakdown`).
  """
  @spec emit_cache_usage(Tau.Session.Data.t(), map()) :: :ok
  def emit_cache_usage(data, usage) do
    read = nonneg_token(usage[:cache_read])
    write = nonneg_token(usage[:cache_write])
    breakdown = if is_map(usage[:cache_breakdown]), do: usage[:cache_breakdown], else: %{}

    :telemetry.execute(
      [:tau, :session, :cache_usage],
      %{write_tokens: write, read_tokens: read, storage_tokens: 0},
      %{session_id: data.id, provider: data.provider, breakdown: breakdown}
    )
  end

  # --- FSM clause handlers ---------------------------------------------------

  @doc """
  Handle async compaction worker result: `{ref, result}` in `:compacting`.

  Clause 1 of the five `:compacting` terminal clauses. Guards on
  `compaction_monitor == ref` to reject stale results from superseded workers.
  Demonitors before clearing worker fields so pending `:DOWN` messages are
  flushed from the mailbox.
  """
  @spec handle_worker_result(reference(), term(), Tau.Session.Data.t()) ::
          Tau.Session.Data.fsm_result()
  def handle_worker_result(ref, result, data) do
    # Demonitor first to flush any pending {:DOWN} that is already enqueued.
    Process.demonitor(ref, [:flush])

    data = %{data | compaction_task: nil, compaction_monitor: nil}

    {notice, data} =
      case result do
        {:ok, new_messages, summary_text} ->
          data =
            Tau.Session.Journal.persist(data, "compaction", %{
              before_count: length(data.messages),
              after_count: length(new_messages),
              summary: Tau.Session.Journal.format_summary_for_persist(summary_text)
            })

          :telemetry.execute(
            [:tau, :compaction, :stop],
            %{system_time: System.system_time()},
            %{session_id: data.id, after_count: length(new_messages), async: true}
          )

          data = %{data | messages: new_messages, compaction_failures: 0}
          {"Compaction complete.", data}

        {:error, reason} ->
          :telemetry.execute(
            [:tau, :compaction, :exception],
            %{system_time: System.system_time()},
            %{session_id: data.id, reason: reason, kind: :compactor_error, async: true}
          )

          failures = data.compaction_failures + 1
          data = %{data | compaction_failures: failures}
          {"Compaction failed (#{failures} consecutive failure(s)).", data}
      end

    Tau.Session.broadcast(data.id, %Events.SystemNotice{session_id: data.id, text: notice})

    # D-164: CompactionFinished MUST fire on every exit from :compacting.
    outcome =
      case result do
        {:ok, _, _} -> {:ok, :compacted}
        {:error, reason} -> {:error, reason}
      end

    Tau.Session.broadcast(data.id, %Events.CompactionFinished{session_id: data.id, outcome: outcome})

    # D-080: drain follow-up queue on :awaiting_user transition.
    actions =
      if :queue.is_empty(data.followup_queue),
        do: [],
        else: [{:next_event, :internal, :drain_followups}]

    {:next_state, :awaiting_user, data, actions}
  end

  @doc """
  Handle a `:normal` `:DOWN` for the compaction worker in `:compacting`.

  Clause 2a: `async_nolink` emits both `{ref, result}` AND `{:DOWN, :normal}`
  on clean task exit. The result may arrive after `:DOWN`; keep waiting.
  """
  @spec handle_worker_down_normal(Tau.Session.Data.t()) :: Tau.Session.Data.fsm_result()
  def handle_worker_down_normal(data) do
    {:keep_state, data}
  end

  @doc """
  Handle an abnormal worker crash (`:DOWN` with non-`:normal` reason) in `:compacting`.

  Clause 2b: the task process died without delivering a result. Increment
  `compaction_failures`, clear worker fields, return to `:awaiting_user`.
  """
  @spec handle_worker_crash(reference(), term(), Tau.Session.Data.t()) ::
          Tau.Session.Data.fsm_result()
  def handle_worker_crash(_ref, reason, data) do
    :telemetry.execute(
      [:tau, :compaction, :exception],
      %{system_time: System.system_time()},
      %{session_id: data.id, reason: reason, kind: :worker_down, async: true}
    )

    failures = data.compaction_failures + 1
    notice = "Compaction worker crashed (#{failures} consecutive failure(s))."

    next_data = %{
      data
      | compaction_task: nil,
        compaction_monitor: nil,
        compaction_failures: failures
    }

    Tau.Session.broadcast(data.id, %Events.SystemNotice{session_id: data.id, text: notice})
    # D-164: fire on every :compacting exit, including worker crash.
    Tau.Session.broadcast(
      data.id,
      %Events.CompactionFinished{session_id: data.id, outcome: {:error, reason}}
    )

    # D-080: drain follow-up queue on :awaiting_user transition.
    actions =
      if :queue.is_empty(next_data.followup_queue),
        do: [],
        else: [{:next_event, :internal, :drain_followups}]

    {:next_state, :awaiting_user, next_data, actions}
  end

  @doc """
  Handle a live compaction timeout in `:compacting`.

  Clause 3: the worker is still running — kill it, increment the failure
  counter, and return to `:awaiting_user`. Guards on `compaction_task == pid`
  to ensure this is for the current worker.
  """
  @spec handle_timeout(pid(), Tau.Session.Data.t()) :: Tau.Session.Data.fsm_result()
  def handle_timeout(pid, data) do
    if data.compaction_monitor, do: Process.demonitor(data.compaction_monitor, [:flush])
    if pid && Process.alive?(pid), do: Process.exit(pid, :brutal_kill)

    :telemetry.execute(
      [:tau, :compaction, :exception],
      %{system_time: System.system_time()},
      %{session_id: data.id, kind: :timeout, async: true}
    )

    failures = data.compaction_failures + 1
    notice = "Compaction timed out (#{failures} consecutive failure(s))."

    next_data = %{
      data
      | compaction_task: nil,
        compaction_monitor: nil,
        compaction_failures: failures
    }

    Tau.Session.broadcast(data.id, %Events.SystemNotice{session_id: data.id, text: notice})
    # D-164: fire on every :compacting exit, including timeout.
    Tau.Session.broadcast(
      data.id,
      %Events.CompactionFinished{session_id: data.id, outcome: {:error, :timeout}}
    )

    # D-080: drain follow-up queue on :awaiting_user transition.
    actions =
      if :queue.is_empty(next_data.followup_queue),
        do: [],
        else: [{:next_event, :internal, :drain_followups}]

    {:next_state, :awaiting_user, next_data, actions}
  end

  # --- Private helpers -------------------------------------------------------

  defp nonneg_token(n) when is_integer(n) and n >= 0, do: n
  defp nonneg_token(_), do: 0
end
