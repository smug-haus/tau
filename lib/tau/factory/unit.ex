defmodule Tau.Factory.Unit do
  @moduledoc """
  Per-PR Unit FSM — the lifecycle driver for a single PR unit.

  Implements the Unit (U) state machine from SPEC-FACTORY-CORE §5:

      planned → oracle → implementing → gating → awaiting_merge → merged
      gating {:fail,_} → retry ladder → implementing | escalated
      worker_exit (semantic) → retry ladder → implementing | escalated (D-326)
      awaiting_merge :rejected → gating (re-gate, INV-2)
      any non-terminal + :state_timeout → escalated (C107)
      worker :DOWN (infra, no prior semantic exit) → escalated (B8/C105)

  D-318: total gate invocations == 1 + N_refine + N_pivot (exactly, bounded
  retry via `Tau.Factory.Retry.next/3`). The `gating` state ALWAYS calls
  `gate_fun` on entry — for refine attempts AND the pivot attempt alike.
  The only difference is which `Retry.next` decision fires on gate-fail:
    - `{:refine, k}` → bump `refine_count` → back to `:implementing`
    - `:pivot`        → bump `pivot_count`  → back to `:implementing` (the pivot
                        attempt; this attempt's gate call is counted and gated)
    - `:exhausted`   → `escalate(:E_RETRY_EXHAUSTED)` (reached after the
                        pivot attempt's gate fails: `Retry.next(_, 3, 1)`)

  All-fail trace (N_REFINE=3, N_PIVOT=1):
    gate#1 fail → Retry.next(_,0,0) = {:refine,0} → refine_count=1 → implementing
    gate#2 fail → Retry.next(_,1,0) = {:refine,1} → refine_count=2 → implementing
    gate#3 fail → Retry.next(_,2,0) = {:refine,2} → refine_count=3 → implementing
    gate#4 fail → Retry.next(_,3,0) = :pivot      → pivot_count=1  → implementing
    gate#5 fail → Retry.next(_,3,1) = :exhausted  → escalated
  Total gate calls = 1 + N_REFINE + N_PIVOT = 5.

  A gate#5 :pass → awaiting_merge → merged (the successful-pivot path).

  D-340: every terminal state sends `{:unit_terminal, unit_id, outcome, provenance}`
  to `report_to` and releases from the Scheduler before stopping.

  B8: the Unit holds a `Process.monitor/1` ref on the worker for liveness.
  Worker pid is stored under `:worker_pid` in state data (test-observable via
  `:sys.get_state/1`).

  C105: semantic gate failures (retry ladder) and infra failures (:state_timeout,
  :DOWN) are distinct code paths. Gate is NEVER called on the infra path.

  UnitRegistry: the Unit registers itself under its `unit_id` in the registry
  named by `:registry_name` (if provided) on start, so live units are
  discoverable via `Tau.Factory.UnitRegistry.lookup/2`.

  See `docs/spec/SPEC-FACTORY-CORE.md` §5, D-318, D-340.
  """

  @behaviour :gen_statem

  alias Tau.Factory.Ledger.Reader, as: LedgerReader
  alias Tau.Factory.Ledger.Writer, as: LedgerWriter
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
    - `:worker_fun`     — `(role :: atom() -> {:ok, worker_pid :: pid()} | {:ok, worker_pid :: pid(), worker_id :: String.t()} | {:error, reason})`.
                         Returns a real process pid; the Unit monitors it via
                         `Process.monitor/1` for liveness (B8).
                         When the 3-tuple form is returned, the Unit stores `worker_id`
                         under `data.worker_id` and gates `implementing → gating` ONLY
                         on `{:work_ready, ^worker_id, _, _}` (D-326/SPEC-FACTORY-CORE §4 B8).
                         When the 2-tuple form is returned (legacy), the Unit matches
                         `{:worker_done, ^worker_pid}` for normal completion.
    - `:gate_fun`       — `(coordinate :: String.t() -> :pass | {:fail, findings :: [term()]})`.
                         Called with `data.head_sha || data.hash` as the coordinate
                         (D-361 symmetric with merge; nil-fallback per D-363).
    - `:merge_fun`      — `(unit_id, hash -> :queued | {:error, reason})`.

  Optional options:
    - `:ledger`         — `GenServer.server()` | `nil`; when present and non-nil,
                          the Unit calls `Ledger.Writer.snapshot_unit/2` on each
                          state entry (WAL-before-ack, D-318). The idempotency key
                          is per-entry-unique (`"<unit_id>:snapshot:<entry_seq>"`),
                          so backward-edge re-entries each write a new row and
                          `latest_unit_snapshots/1` returns the current state.
                          When `nil` or absent, snapshotting is a no-op — existing
                          callers unaffected.
    - `:pubsub`         — `atom()`; the `Phoenix.PubSub` instance to subscribe to
                          for D-356 merge-result delivery (default `Tau.PubSub`).
                          In `awaiting_merge`, the Unit subscribes to
                          `"factory:pr:\#{unit_id}"` BEFORE calling `merge_fun`
                          (subscribe-before-request ordering — race-freedom guarantee)
                          and unsubscribes on every exit from `awaiting_merge`.
    - `:registry_name`  — atom; if given, the Unit registers itself under its
                          `unit_id` in that Registry on start (f-6).
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
    ledger = Keyword.get(opts, :ledger, nil)
    pubsub = Keyword.get(opts, :pubsub, Tau.PubSub)
    registry_name = Keyword.get(opts, :registry_name, nil)
    timeouts = Keyword.get(opts, :timeouts, [])
    state_timeout_ms = Keyword.get(timeouts, :state_timeout_ms, @default_state_timeout_ms)

    # f-6: register in UnitRegistry when a registry_name was provided.
    if registry_name do
      Registry.register(registry_name, unit_id, self())
    end

    # D-318 counter-durability: restore retry counters from the Ledger when a
    # snapshot exists for this unit_id (D-344 resume pattern). On fresh start
    # (no prior snapshot), all counters default to 0.
    {refine_count, pivot_count, stall_count} =
      case ledger do
        nil ->
          {0, 0, 0}

        _ ->
          case LedgerReader.unit_counters_for(ledger, unit_id) do
            {:ok, %{refine_count: rc, pivot_count: pc, stall_count: sc}} -> {rc, pc, sc}
            :none -> {0, 0, 0}
          end
      end

    data = %{
      unit_id: unit_id,
      declared_scope: declared_scope,
      hash: hash,
      scheduler: scheduler,
      report_to: report_to,
      ledger: ledger,
      pubsub: pubsub,
      worker_fun: worker_fun,
      gate_fun: gate_fun,
      merge_fun: merge_fun,
      state_timeout_ms: state_timeout_ms,
      # Current worker pid (B8 — real process, monitorable).
      worker_pid: nil,
      # D-326: logical worker_id keying work_ready events (nil when worker_fun
      # returns 2-tuple legacy form). Stored under :worker_id so tests can
      # observe it via :sys.get_state/1.
      worker_id: nil,
      # Monitor ref for the current worker.
      worker_mref: nil,
      # Retry counters (D-318 counter-durability: restored from Ledger on restart).
      refine_count: refine_count,
      pivot_count: pivot_count,
      # Total times oracle/implementing state was entered (non-terminal attempts).
      # Also used as an observability metric; see stall_count for the ladder counter.
      attempt_count: 0,
      # D-378 bounded stall ladder counter (D-318 counter-durability: restored from
      # Ledger on restart). Incremented exclusively by advance_retry_ladder/2
      # (worker-outcome events). Distinct from attempt_count which includes initial
      # spawns. Used as the position counter for Retry.next/3 on the worker-outcome
      # path so the budget of N_REFINE + N_PIVOT stall advances is not pre-consumed
      # by the initial oracle/implementing spawns.
      stall_count: stall_count,
      # Last gate findings (nil until a gate failure occurs).
      last_findings: nil,
      # Monotonic per-entry counter for idempotency-key uniqueness (D-318 / §4 B3).
      # Incremented on every snapshot_state call so backward-edge re-entries each
      # produce a distinct key, making MAX(id) in latest_unit_snapshots/1 track
      # the genuinely-latest FSM state rather than the forward-stale state.
      entry_seq: 0,
      # D-362: captured from {:work_ready, worker_id, branch, head_sha} (3-tuple seam).
      # Initialised to nil; stays nil when the legacy 2-tuple seam is used (D-363).
      head_sha: nil,
      branch: nil,
      # INV-WF-13: gating_test_paths captured from the 5-tuple work_ready form.
      # Nil until the :test_author worker reports its path set; the oracle →
      # implementing transition REQUIRES a non-empty list (Clause 2 guard).
      gating_test_paths: nil,
      # INV-SAFE-CP-5: ref of the in-flight gate Task (set on :gating entry,
      # cleared when the {:gate_result, _} arrives). Nil when not in :gating state.
      gate_task_ref: nil
    }

    # Transition immediately to planned state, which triggers admission.
    {:ok, :planned, data, [{:next_event, :internal, :on_enter}]}
  end

  # ---------------------------------------------------------------------------
  # State: :planned
  # Calls Scheduler.admit; on :admit → oracle; on {:defer, _} → escalated.
  # ---------------------------------------------------------------------------

  def planned(:internal, :on_enter, data) do
    data = snapshot_state(:planned, data)

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
    new_data = %{data | attempt_count: data.attempt_count + 1}
    new_data = snapshot_state(:oracle, new_data)

    case new_data.worker_fun.(:test_author) do
      {:ok, worker_pid, worker_id} ->
        mref = Process.monitor(worker_pid)
        updated_data = %{new_data | worker_pid: worker_pid, worker_id: worker_id, worker_mref: mref}
        timeout_ms = updated_data.state_timeout_ms
        {:keep_state, updated_data, [{:state_timeout, timeout_ms, :worker_stalled}]}

      {:ok, worker_pid} ->
        mref = Process.monitor(worker_pid)
        updated_data = %{new_data | worker_pid: worker_pid, worker_id: nil, worker_mref: mref}
        timeout_ms = updated_data.state_timeout_ms
        {:keep_state, updated_data, [{:state_timeout, timeout_ms, :worker_stalled}]}

      {:error, reason} ->
        Logger.warning(
          "[Unit #{new_data.unit_id}] worker_fun(:test_author) error: #{inspect(reason)}"
        )

        escalate(new_data, :E_WORKER_ERROR)
    end
  end

  # INV-WF-13 Clause 1: 5-tuple work_ready WITH gating_test_paths — capture paths and advance.
  # The conformant oracle-separation contract requires the :test_author worker to carry
  # a non-empty gating_test_paths list. This clause matches the extended form and captures
  # the path set into data.gating_test_paths before transitioning to :implementing.
  def oracle(
        :info,
        {:work_ready, worker_id, branch, head_sha, paths},
        %{worker_id: worker_id} = data
      )
      when not is_nil(worker_id) and is_list(paths) and paths != [] do
    Process.demonitor(data.worker_mref, [:flush])

    new_data = %{
      data
      | worker_pid: nil,
        worker_id: nil,
        worker_mref: nil,
        branch: branch,
        head_sha: head_sha,
        gating_test_paths: paths
    }

    {:next_state, :implementing, new_data, [{:next_event, :internal, :on_enter}]}
  end

  # INV-WF-13 Clause 2 guard: 5-tuple work_ready with an empty or missing path set —
  # REFUSE the transition. Log a warning; the Unit stays in :oracle.
  def oracle(
        :info,
        {:work_ready, worker_id, _branch, _head_sha, paths},
        %{worker_id: worker_id} = data
      )
      when not is_nil(worker_id) do
    Logger.warning(
      "[Unit #{data.unit_id}] oracle work_ready from worker #{worker_id} carries " <>
        "empty or invalid gating_test_paths #{inspect(paths)} — " <>
        "refusing oracle→implementing transition (INV-WF-13 Clause 2)"
    )

    {:keep_state, data}
  end

  # INV-WF-13 Clause 2 guard: 4-tuple work_ready (no gating_test_paths) from the
  # CURRENT oracle worker (3-tuple seam, worker_id set) — REFUSE the transition.
  # A conformant :test_author worker MUST send the 5-tuple form with a non-empty
  # gating_test_paths list. Receiving the legacy 4-tuple from an oracle-phase worker
  # means no path set was reported; the oracle→implementing transition is withheld.
  def oracle(:info, {:work_ready, worker_id, _branch, _head_sha}, %{worker_id: worker_id} = data)
      when not is_nil(worker_id) do
    Logger.warning(
      "[Unit \#{data.unit_id}] oracle work_ready from worker \#{worker_id} carries " <>
        "no gating_test_paths (4-tuple form) — " <>
        "refusing oracle→implementing transition (INV-WF-13 Clause 2)"
    )

    {:keep_state, data}
  end

  # Discard work_ready from a superseded worker_id (stale-worker discard, B8).
  def oracle(:info, {:work_ready, _other_id, _branch, _head_sha}, data) do
    {:keep_state, data}
  end

  # Discard 5-tuple work_ready from a superseded worker_id.
  def oracle(:info, {:work_ready, _other_id, _branch, _head_sha, _paths}, data) do
    {:keep_state, data}
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

  # D-377: re-arm :state_timeout when a heartbeat arrives for the CURRENT worker.
  # A progressing worker never trips the fixed cap. Stale-worker heartbeats → discard.
  def oracle(:info, {:worker_heartbeat, worker_id}, %{worker_id: worker_id} = data)
      when not is_nil(worker_id) do
    timeout_ms = data.state_timeout_ms
    {:keep_state, data, [{:state_timeout, timeout_ms, :worker_stalled}]}
  end

  # Stale-worker heartbeat — discard.
  def oracle(:info, {:worker_heartbeat, _stale_id}, data) do
    {:keep_state, data}
  end

  # D-379(a): route {:worker_stalled, ^worker_id} to the retry ladder (current worker).
  # D-378: clears data.worker_id so later stall signals for this worker are discarded.
  # D-378 unified symmetric rule: re-enters :oracle (the originating state).
  def oracle(:info, {:worker_stalled, worker_id}, %{worker_id: worker_id} = data)
      when not is_nil(worker_id) do
    Logger.warning(
      "[Unit #{data.unit_id}] oracle {:worker_stalled, #{worker_id}} — routing to retry ladder"
    )

    demonitor_worker(data)
    new_data = %{data | worker_pid: nil, worker_id: nil, worker_mref: nil}
    advance_retry_ladder(:oracle, new_data)
  end

  # D-379(a): stale {:worker_stalled, _} — discard (D-378 disjointness).
  def oracle(:info, {:worker_stalled, _stale_id}, data) do
    {:keep_state, data}
  end

  # D-379(a): route {:worker_exit, ^worker_id, _} to the retry ladder (run-#2 regression fix).
  # D-378 unified symmetric rule: re-enters :oracle (the originating state).
  def oracle(:info, {:worker_exit, worker_id, _reason}, %{worker_id: worker_id} = data)
      when not is_nil(worker_id) do
    Logger.warning(
      "[Unit #{data.unit_id}] oracle {:worker_exit, #{worker_id}} — routing to retry ladder"
    )

    Process.demonitor(data.worker_mref, [:flush])
    new_data = %{data | worker_pid: nil, worker_id: nil, worker_mref: nil}
    advance_retry_ladder(:oracle, new_data)
  end

  # D-379(a): stale {:worker_exit, _, _} — discard (D-378 disjointness).
  def oracle(:info, {:worker_exit, _other_id, _reason}, data) do
    {:keep_state, data}
  end

  def oracle(:state_timeout, :worker_stalled, data) do
    Logger.warning("[Unit #{data.unit_id}] oracle :state_timeout — worker stalled")
    demonitor_worker(data)
    escalate(data, :E_WORKER_STALLED)
  end

  # Handle monitored worker :DOWN (infra crash path, B8/C105).
  # D-326: guard with `is_nil(data.worker_id)` — only the legacy 2-tuple seam
  # (worker_id == nil) escalates E_WORKER_DOWN via :DOWN. For the 3-tuple path,
  # :DOWN is not an authoritative outcome; the fleet sends worker_exit (or the
  # state_timeout fires for vanish-without-exit → E_WORKER_STALLED).
  def oracle(:info, {:DOWN, _mref, :process, worker_pid, reason}, %{worker_pid: worker_pid} = data)
      when not is_nil(worker_pid) and is_nil(data.worker_id) do
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
    new_data = snapshot_state(:implementing, new_data)

    case new_data.worker_fun.(:implementer) do
      {:ok, worker_pid, worker_id} ->
        mref = Process.monitor(worker_pid)
        updated_data = %{new_data | worker_pid: worker_pid, worker_id: worker_id, worker_mref: mref}
        timeout_ms = updated_data.state_timeout_ms
        {:keep_state, updated_data, [{:state_timeout, timeout_ms, :worker_stalled}]}

      {:ok, worker_pid} ->
        mref = Process.monitor(worker_pid)
        updated_data = %{new_data | worker_pid: worker_pid, worker_id: nil, worker_mref: mref}
        timeout_ms = updated_data.state_timeout_ms
        {:keep_state, updated_data, [{:state_timeout, timeout_ms, :worker_stalled}]}

      {:error, reason} ->
        Logger.warning(
          "[Unit #{new_data.unit_id}] worker_fun(:implementer) error: #{inspect(reason)}"
        )

        escalate(new_data, :E_WORKER_ERROR)
    end
  end

  # D-326 §4 B8: gate implementing → gating ONLY on work_ready keyed by the
  # CURRENT worker_id (the sole completion trigger — never bare exit / :worker_done).
  # D-362: capture branch and head_sha into data on transition.
  def implementing(
        :info,
        {:work_ready, worker_id, branch, head_sha},
        %{worker_id: worker_id} = data
      )
      when not is_nil(worker_id) do
    Process.demonitor(data.worker_mref, [:flush])

    new_data = %{
      data
      | worker_pid: nil,
        worker_id: nil,
        worker_mref: nil,
        branch: branch,
        head_sha: head_sha
    }

    {:next_state, :gating, new_data, [{:next_event, :internal, :on_enter}]}
  end

  # Stale-worker discard (B8): work_ready from a superseded worker_id is ignored.
  def implementing(:info, {:work_ready, _other_id, _branch, _head_sha}, data) do
    {:keep_state, data}
  end

  # Legacy 2-tuple worker_fun seam: {:worker_done, worker_pid} (back-compat).
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

  # D-326 [C111b-B8 / C105-B5] / D-378 symmetric: semantic worker exit — route to
  # the worker-outcome retry ladder (advance_retry_ladder/2), NEVER gate and NEVER
  # advance_gate_ladder. Covers :no_work_product (exit-0-without-work_ready),
  # :error (agent-reported failure), {:exit_status, n} (non-zero exit code),
  # and any other non-completion semantic reason.
  #
  # D-378 clarification: worker_exit is a worker-outcome event (no work product
  # exists to gate-review); it MUST advance attempt_count via the worker-outcome
  # ladder, NOT refine_count via advance_gate_ladder. Only gate failures (in
  # gating/3) consume refine_count/pivot_count via advance_gate_ladder.
  #
  # Race handling: Process.demonitor(mref, [:flush]) flushes any queued :DOWN
  # from the BEAM mailbox synchronously, so a :DOWN that was already delivered
  # before we processed this worker_exit message is discarded. A :DOWN that
  # arrives after the demonitor+flush is suppressed by the demonitor. This
  # provides one-exit-one-outcome disjointness (B8) regardless of ordering.
  #
  # The guard `not is_nil(worker_id)` ensures this clause is only active when
  # the 3-tuple seam is in use. 2-tuple workers (nil worker_id) still rely on
  # the legacy :DOWN handler for infra crash detection (test 4 preserved).
  def implementing(:info, {:worker_exit, worker_id, _reason}, %{worker_id: worker_id} = data)
      when not is_nil(worker_id) do
    Process.demonitor(data.worker_mref, [:flush])
    new_data = %{data | worker_pid: nil, worker_id: nil, worker_mref: nil}
    # D-378 symmetric: worker-outcome events use advance_retry_ladder/2 (not
    # advance_gate_ladder). This preserves refine_count for genuine gate failures only.
    advance_retry_ladder(:implementing, new_data)
  end

  # D-326 [B8 stale-worker]: worker_exit keyed by a different worker_id — discard.
  def implementing(:info, {:worker_exit, _other_id, _reason}, data) do
    {:keep_state, data}
  end

  # D-377: re-arm :state_timeout when a heartbeat arrives for the CURRENT worker.
  # A progressing worker never trips the fixed cap. Stale-worker heartbeats → discard.
  def implementing(:info, {:worker_heartbeat, worker_id}, %{worker_id: worker_id} = data)
      when not is_nil(worker_id) do
    timeout_ms = data.state_timeout_ms
    {:keep_state, data, [{:state_timeout, timeout_ms, :worker_stalled}]}
  end

  # Stale-worker heartbeat — discard.
  def implementing(:info, {:worker_heartbeat, _stale_id}, data) do
    {:keep_state, data}
  end

  # D-379(a): route {:worker_stalled, ^worker_id} to the retry ladder (current worker).
  # D-378: clears data.worker_id so later stall signals for this worker are discarded.
  # D-378 unified symmetric rule: re-enters :implementing (the originating state).
  # D-378 exactly-once: with fresh unique worker_ids per spawn (D-326), the internal
  # :on_enter fires before any stale external messages and sets worker_id to the NEW
  # unique id. Stale messages for the OLD worker_id are then discarded by the
  # _stale_id clause, providing exactly-once via id discrimination.
  def implementing(:info, {:worker_stalled, worker_id}, %{worker_id: worker_id} = data)
      when not is_nil(worker_id) do
    Logger.warning(
      "[Unit #{data.unit_id}] implementing {:worker_stalled, #{worker_id}} — routing to retry ladder (D-379/D-378)"
    )

    demonitor_worker(data)
    new_data = %{data | worker_pid: nil, worker_id: nil, worker_mref: nil}
    advance_retry_ladder(:implementing, new_data)
  end

  # D-379(a): stale {:worker_stalled, _} — discard (D-378 disjointness).
  def implementing(:info, {:worker_stalled, _stale_id}, data) do
    {:keep_state, data}
  end

  def implementing(:state_timeout, :worker_stalled, data) do
    Logger.warning("[Unit #{data.unit_id}] implementing :state_timeout — worker stalled")
    demonitor_worker(data)
    new_data = %{data | worker_pid: nil, worker_id: nil, worker_mref: nil}
    escalate(new_data, :E_WORKER_STALLED)
  end

  # Handle monitored worker :DOWN (infra crash path, B8/C105).
  # D-326: guard with `is_nil(data.worker_id)` — only the legacy 2-tuple seam
  # (worker_id == nil) escalates E_WORKER_DOWN via :DOWN. For the 3-tuple path,
  # :DOWN is not an authoritative outcome; the fleet sends worker_exit (or the
  # state_timeout fires for vanish-without-exit → E_WORKER_STALLED).
  def implementing(
        :info,
        {:DOWN, _mref, :process, worker_pid, reason},
        %{worker_pid: worker_pid} = data
      )
      when not is_nil(worker_pid) and is_nil(data.worker_id) do
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
  # Spawns gate_fun(coordinate) in a Task on entry (INV-SAFE-CP-5 — non-blocking).
  # ALWAYS calls gate_fun — for refine attempts AND the pivot attempt alike.
  #
  # INV-SAFE-CP-5: the :on_enter callback MUST NOT block. gate_fun is spawned in
  # a Task.async/1 so the gen_statem callback returns immediately and the FSM
  # remains responsive to state_timeout, worker_exit, and worker_stalled messages
  # while the gate runs. The result arrives as {:gate_result, :pass} or
  # {:gate_result, {:fail, findings}} via an info message from the Task.
  #
  # D-361: coordinate = data.head_sha || data.hash (symmetric with awaiting_merge).
  # When head_sha was captured from work_ready (3-tuple seam), it is used as the
  # coordinate. When not captured (legacy 2-tuple seam), falls back to the declared
  # work_item.hash (D-363 back-compat, nil-fallback symmetric with merge).
  #
  # :pass → awaiting_merge (this is how a successful pivot reaches merge).
  # {:fail, findings} → Retry.next(:gate_fail, refine_count, pivot_count):
  #   {:refine, k} → bump refine_count → back to :implementing
  #   :pivot       → bump pivot_count  → back to :implementing (the pivot attempt)
  #   :exhausted   → escalate :E_RETRY_EXHAUSTED (reached after pivot's gate fails:
  #                  Retry.next(_, N_REFINE, N_PIVOT) = :exhausted)
  #
  # D-318 all-fail trace (N_REFINE=3, N_PIVOT=1, total=5 gate calls):
  #   gate#1 → {:refine,0} → refine_count=1 → implementing
  #   gate#2 → {:refine,1} → refine_count=2 → implementing
  #   gate#3 → {:refine,2} → refine_count=3 → implementing
  #   gate#4 → :pivot       → pivot_count=1  → implementing (pivot attempt)
  #   gate#5 → :exhausted   → escalated
  # ---------------------------------------------------------------------------

  def gating(:internal, :on_enter, data) do
    data = snapshot_state(:gating, data)

    # D-361: use the captured head_sha as the gate coordinate when present;
    # fall back to the declared work_item.hash for the legacy 2-tuple seam
    # (D-363 back-compat — head_sha is nil when no work_ready was received).
    # Symmetric with the merge coordinate in awaiting_merge.
    coordinate = data.head_sha || data.hash

    # INV-SAFE-CP-5: spawn gate_fun in a Task so the callback returns immediately.
    # Task.async/1 links and monitors the task; the result arrives as
    # {task.ref, result} in the gen_statem's mailbox (info message). We wrap it in
    # {:gate_result, result} via the Task reply — handled below.
    unit_pid = self()
    gate_fun = data.gate_fun

    task =
      Task.async(fn ->
        result = gate_fun.(coordinate)
        send(unit_pid, {:gate_result, result})
        result
      end)

    {:keep_state, %{data | gate_task_ref: task.ref}}
  end

  # INV-SAFE-CP-5: handle the gate result delivered asynchronously from the Task.
  # The gate_fun sends {:gate_result, result} to this process; we consume it here.
  def gating(:info, {:gate_result, :pass}, data) do
    new_data = %{data | gate_task_ref: nil}
    {:next_state, :awaiting_merge, new_data, [{:next_event, :internal, :on_enter}]}
  end

  def gating(:info, {:gate_result, {:fail, findings}}, data) do
    new_data = %{data | last_findings: findings, gate_task_ref: nil}
    # D-318: gate failure — advance the refine→pivot→exhausted ladder.
    advance_gate_ladder(new_data)
  end

  # INV-SAFE-CP-5: discard the raw Task reply tuple {ref, result} that Task.async
  # also delivers to the caller's mailbox (in addition to the {:gate_result, _} we
  # send explicitly). Matching on gate_task_ref ensures we only swallow our own
  # Task's reply, not unrelated task results.
  def gating(:info, {ref, _result}, %{gate_task_ref: ref} = data) when not is_nil(ref) do
    {:keep_state, data}
  end

  # INV-SAFE-CP-5: discard the :DOWN from the completed Task (Task.async monitors
  # the spawned task; a normal exit sends :DOWN with reason :normal after the reply).
  def gating(:info, {:DOWN, ref, :process, _pid, _reason}, %{gate_task_ref: ref} = data)
      when not is_nil(ref) do
    {:keep_state, data}
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
    data = snapshot_state(:awaiting_merge, data)

    # D-355 / D-344 — Reconcile-on-entry: before calling merge_fun, check the
    # durable Ledger for an already-decided outcome. This prevents re-doing
    # terminal work after a crash-resume (D-344 "re-does no terminal work"):
    #   :merged   → already landed; transition to terminal :merged immediately.
    #   :rejected → was rejected (INV-2); re-gate without re-calling merge_fun.
    #   :none     → no prior outcome; proceed with the normal merge_fun call.
    case reconcile_merge_outcome(data) do
      {:merged, _commit_sha} ->
        # Reconcile found a prior merge — no PubSub subscription needed since
        # we are not calling merge_fun (no broadcast will arrive).
        terminal(data, :merged, nil, nil)

      {:rejected, _reason} ->
        # INV-2: re-gate on rejection (same as receiving {:merge_result, :rejected}).
        # No PubSub subscription needed — not calling merge_fun.
        {:next_state, :gating, data, [{:next_event, :internal, :on_enter}]}

      :none ->
        # D-356 subscribe-before-request: subscribe to the per-PR PubSub topic
        # BEFORE calling merge_fun. The subscription MUST be in place before the
        # request is issued so that a broadcast that fires at any point during or
        # after request_merge — even concurrently within merge_fun itself — is
        # guaranteed to reach this process. Phoenix.PubSub is at-most-once with
        # no replay; ordering here is the race-freedom guarantee.
        :ok = Phoenix.PubSub.subscribe(data.pubsub, "factory:pr:#{data.unit_id}")

        # D-361: use the captured head_sha as the merge coordinate when present;
        # fall back to the declared work_item.hash for the legacy 2-tuple seam
        # (D-363 back-compat — head_sha is nil when no work_ready was received).
        coordinate = data.head_sha || data.hash
        _result = data.merge_fun.(data.unit_id, coordinate)
        timeout_ms = data.state_timeout_ms
        {:keep_state, data, [{:state_timeout, timeout_ms, :merge_stalled}]}
    end
  end

  def awaiting_merge(:info, {:merge_result, :merged}, data) do
    # D-356: unsubscribe on exit from awaiting_merge (terminal :merged path).
    Phoenix.PubSub.unsubscribe(data.pubsub, "factory:pr:#{data.unit_id}")
    terminal(data, :merged, nil, nil)
  end

  def awaiting_merge(:info, {:merge_result, :rejected}, data) do
    # D-356: unsubscribe on exit from awaiting_merge (re-gate path, INV-2).
    Phoenix.PubSub.unsubscribe(data.pubsub, "factory:pr:#{data.unit_id}")
    # INV-2: merge reject → re-gate.
    {:next_state, :gating, data, [{:next_event, :internal, :on_enter}]}
  end

  def awaiting_merge(:state_timeout, :merge_stalled, data) do
    Logger.warning("[Unit #{data.unit_id}] awaiting_merge :state_timeout — merge stalled")
    # D-356: unsubscribe on exit from awaiting_merge (escalation path).
    Phoenix.PubSub.unsubscribe(data.pubsub, "factory:pr:#{data.unit_id}")
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

  # D-326 / D-378 / D-379: unified bounded worker-outcome retry ladder for oracle
  # and implementing. Called when a stall-class signal ({:worker_stalled} or
  # {:worker_exit}) arrives for the CURRENT worker in either waiting state.
  #
  # The caller has already cleared worker_pid/worker_id/worker_mref to nil.
  #
  # D-378 symmetric: BOTH oracle and implementing use {:next_state, state, data,
  # [{:next_event, :internal, :on_enter}]} — the originating state re-enters
  # itself and :on_enter owns the attempt_count increment, Ledger snapshot, and
  # worker spawn. No deferred :stall_respawn path exists.
  #
  # D-378 boundedness (LIV-1): calls Retry.next/3 using attempt_count as the
  # ladder position (distinct from refine_count, which is EXCLUSIVELY the
  # gate-failure counter). pivot_count is shared. The ladder exhausts after
  # N_REFINE + N_PIVOT advances and escalates E_RETRY_EXHAUSTED.
  #
  # D-378 clarification: the worker-outcome ladder counter is attempt_count;
  # refine_count MUST NOT be touched here. Gate failures (in gating/3) use
  # advance_gate_ladder/1 for Retry.next progression against refine_count.
  #
  # D-378 exactly-once: with fresh unique worker_ids per spawn (D-326), the
  # internal :on_enter fires before any stale external messages are processed
  # (gen_statem guarantees internal events precede external ones). By the time
  # stale burst messages for the OLD worker_id are consumed, :on_enter has
  # already set worker_id to the NEW unique id — so the stale-discard clauses
  # correctly discard them via id discrimination. No deferred path needed.
  #
  # D-315 RPO=0: :on_enter bumps attempt_count and writes Ledger snapshot
  # before spawning the next worker — in BOTH oracle and implementing.
  @spec advance_retry_ladder(:oracle | :implementing, map()) ::
          {:next_state, :oracle | :implementing, map(), list()}
          | {:next_state, :escalated, map()}
  defp advance_retry_ladder(state, data) do
    # D-378 stall budget: use stall_count (not attempt_count) as the ladder
    # position. attempt_count includes the initial oracle/implementing spawns
    # (which are legitimate work initiations, not re-spawns). stall_count starts
    # at 0 and is incremented only here, ensuring the full N_REFINE + N_PIVOT
    # budget is available for genuine stall/exit events. Both attempt_count and
    # stall_count are observable; tests assert attempt_count increases (via
    # :on_enter), but the exhaustion is keyed on stall_count.
    case Retry.next(:stall, data.stall_count, data.pivot_count) do
      {:refine, _k} ->
        # Increment stall_count; :on_enter will increment attempt_count.
        bumped = %{data | stall_count: data.stall_count + 1}
        {:next_state, state, bumped, [{:next_event, :internal, :on_enter}]}

      :pivot ->
        # Increment stall_count and pivot_count; :on_enter will increment attempt_count.
        bumped = %{data | stall_count: data.stall_count + 1, pivot_count: data.pivot_count + 1}
        {:next_state, state, bumped, [{:next_event, :internal, :on_enter}]}

      :exhausted ->
        escalate(data, :E_RETRY_EXHAUSTED)
    end
  end

  # D-318: gate-failure retry-ladder progression. Called only from gating/3 on
  # {:fail, findings}. Applies Retry.next to advance the refine→pivot→exhausted
  # ladder and re-enters :implementing (always — gate failures always target the
  # implementing role for the next attempt).
  @spec advance_gate_ladder(map()) ::
          {:next_state, :implementing, map()} | {:next_state, :escalated, map()}
  defp advance_gate_ladder(data) do
    case Retry.next(:gate_fail, data.refine_count, data.pivot_count) do
      {:refine, _k} ->
        bumped = %{data | refine_count: data.refine_count + 1}
        {:next_state, :implementing, bumped, [{:next_event, :internal, :on_enter}]}

      :pivot ->
        bumped = %{data | pivot_count: data.pivot_count + 1}
        {:next_state, :implementing, bumped, [{:next_event, :internal, :on_enter}]}

      :exhausted ->
        escalate(data, :E_RETRY_EXHAUSTED)
    end
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

    # D-318: snapshot BEFORE external effects (WAL-before-ack, D-315).
    data = snapshot_state(outcome, data)

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

  # Durably snapshot the Unit's current state to the Ledger (D-318 / WAL-before-ack).
  #
  # Idempotency key: "<unit_id>:snapshot:<entry_seq>" — per-entry-unique because
  # `entry_seq` is a monotonic counter incremented on every call. This means EVERY
  # state entry (including backward-edge re-entries of :implementing or :gating)
  # writes a distinct row; MAX(id) in latest_unit_snapshots/1 therefore always
  # returns the genuinely-latest FSM state. A genuine replay of the same entry
  # (same `entry_seq`) remains a no-op via INSERT OR IGNORE (D-315).
  #
  # Returns updated data with incremented entry_seq so the counter is threaded
  # through all state functions correctly.
  #
  # No-op (data unchanged) when ledger is nil (back-compat, D-318 §4 B3).
  @spec snapshot_state(atom(), map()) :: map()
  defp snapshot_state(_state, %{ledger: nil} = data), do: data

  defp snapshot_state(state, data) do
    seq = data.entry_seq
    idempotency_key = "#{data.unit_id}:snapshot:#{seq}"

    LedgerWriter.snapshot_unit(data.ledger, %{
      unit_id: data.unit_id,
      state: state,
      idempotency_key: idempotency_key,
      refine_count: data.refine_count,
      pivot_count: data.pivot_count,
      stall_count: data.stall_count
    })

    %{data | entry_seq: seq + 1}
  end

  # D-355 / D-344 — read the durable merge outcome from the Ledger.
  # Returns {:merged, sha} | {:rejected, reason} | :none.
  # When ledger is nil (snapshot disabled), always returns :none so the
  # existing merge_fun path is taken unchanged (back-compat).
  @spec reconcile_merge_outcome(map()) ::
          {:merged, String.t()} | {:rejected, term()} | :none
  defp reconcile_merge_outcome(%{ledger: nil}), do: :none

  defp reconcile_merge_outcome(%{ledger: ledger, unit_id: unit_id}) do
    LedgerReader.merge_outcome_for(ledger, unit_id)
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
