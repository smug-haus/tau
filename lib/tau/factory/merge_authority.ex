defmodule Tau.Factory.MergeAuthority do
  @moduledoc """
  Serialized Merge Authority (M) — the sole writer of `origin/main`.

  A single `gen_statem` with three states:

    - `:idle` — accepts submissions; assembles and launches the next train.
    - `:integrating` — monitored `Task` runs the build off the mailbox;
      M still accepts submissions for the *next* train (INV-3: no second build).
    - `:committing` — short critical section: re-read latest verdicts (HR-2)
      then `cas_push` (`--force-with-lease`, HR-1). Milliseconds only.

  The build task runs via `Task.Supervisor.async_nolink/2` so M's mailbox stays
  free during `T_int` (minutes). `request_merge/2` is non-blocking (D-302).

  See `docs/spec/SPEC-FACTORY-MERGE.md` §4–§5, D-300, D-301, D-302.
  """

  @behaviour :gen_statem

  alias Tau.Factory.Ledger.Writer, as: LedgerWriter
  alias Tau.Factory.Merge.Cas
  alias Tau.Factory.Merge.Health
  alias Tau.Factory.Merge.RepoDirRegistry
  alias Tau.Factory.Merge.Train

  require Logger

  # How long to wait for a build task before treating it as wedged (C207).
  @build_timeout_ms :timer.minutes(30)

  # D-394: maximum consecutive retryable failures per member before terminal eject.
  @build_retry_max 3

  # D-394: dwell between retry launches (non-blocking backoff timer).
  @build_backoff_ms 2_000

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Start and register the MergeAuthority.

  Options (all required unless noted):
    - `:name` — registered name for this process.
    - `:ledger` — pid/name of the `Tau.Factory.Ledger.Writer`.
    - `:repo_dir` — filesystem path of the git working directory.
    - `:tasks_name` — registered name of the `Task.Supervisor` for builds.
    - `:required_halves` — list of verdict halves required (default `[:critic, :reviewer]`).
    - `:build_fun` — `(units, base) -> {:built, units, base, tip} | {:build_failed, reason}`
      (default: the real rebase+push implementation; injectable for tests).
    - `:cas` — the CAS module to use (default `Tau.Factory.Merge.Cas`; injectable for tests).
    - `:pubsub` — the `Phoenix.PubSub` instance to broadcast D-356 merge results on
      (default `Tau.PubSub`; injectable for tests).
    - `:build_retry_max` — maximum consecutive retryable failures before terminal eject
      (default #{@build_retry_max}; injectable for tests, D-394).
    - `:build_backoff_ms` — dwell in ms between retry launches
      (default #{@build_backoff_ms}; injectable for tests, D-394).
    - `:build_timeout_ms` — ms before a running build task is killed as wedged
      (default #{@build_timeout_ms}; injectable for tests, D-394).
    - `:post_merge_health_fun` — `(repo_dir, lang, ctx) -> :green | {:red, report}`
      post-merge origin/main health check (default: `Health.check/3`; injectable
      for tests, D-303).
    - `:node_list_fun` — `(-> [node()])` returns the list of connected BEAM nodes
      (default: `&Node.list/0`; injectable for tests). If non-empty on startup,
      `start_link/1` returns `{:error, {:multi_node_detected, nodes}}` and the
      process is NOT started (INV-ST-11: control plane MUST stay single-node).
    - `:repo_dir_registry` — module that provides `ensure_started/0` and
      `register/1` (default `Tau.Factory.Merge.RepoDirRegistry`; injectable
      for tests). Used to enforce INV-DIST-R5: at most one MA per repo_dir on
      this node. A second `start_link/1` for the same `repo_dir` returns
      `{:error, {:already_registered, repo_dir}}`.
  """
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

  @spec start_link(keyword()) :: :gen_statem.start_ret()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)

    # INV-ST-11: Perform the single-node guard BEFORE start_link to avoid
    # propagating the EXIT signal to the caller. gen_statem.start_link links
    # the caller, and a {:stop, reason} from init/1 exits the child process
    # AFTER init_ack — the linked EXIT then arrives at the caller's mailbox.
    # Guard here (pre-spawn) eliminates the race entirely. init/1 still checks
    # (defence-in-depth) but the early guard makes start_link safe to call
    # from un-supervised callers (including tests).
    node_list_fun = Keyword.get(opts, :node_list_fun, &Node.list/0)

    # INV-DIST-R5: Ensure the per-repo_dir registry is running before spawning.
    # The registry is started lazily so no external supervisor is required —
    # in production it is pre-started by Tau.Factory.Supervisor; in tests it
    # starts on demand. The actual registration (with self() as the MA pid)
    # happens inside init/1 to avoid a race between reserve and spawn.
    repo_dir_registry = Keyword.get(opts, :repo_dir_registry, RepoDirRegistry)
    {:ok, _registry_pid} = repo_dir_registry.ensure_started()

    # Pre-spawn early-return guard (non-atomic; init/1 is the authoritative gate).
    # Avoids spawning a process that would immediately stop — which would
    # propagate an EXIT signal to the caller even though gen_statem.start_link
    # internally handles it. The pre-spawn check is safe for the sequential
    # production use-case; the init/1 gate handles concurrent races.
    repo_dir = Keyword.fetch!(opts, :repo_dir)

    if repo_dir_registry.registered?(repo_dir) do
      {:error, {:already_registered, repo_dir}}
    else
      case node_list_fun.() do
        [] ->
          :gen_statem.start_link({:local, name}, __MODULE__, opts, [])

        nodes ->
          {:error, {:multi_node_detected, nodes}}
      end
    end
  end

  @doc """
  Submit a unit for merging. Non-blocking: returns `:queued` immediately.

  The merge outcome is broadcast via telemetry when the commit lands or is
  rejected.

  `unit` must have keys: `:id`, `:hash`, `:run`, `:branch`.
  """
  @spec request_merge(:gen_statem.server_ref(), map()) :: :queued
  def request_merge(server, unit) do
    :gen_statem.call(server, {:request_merge, unit})
  end

  @doc """
  Clear the red-main gate. Called by an operator (or coordinator) after
  the red `origin/main` has been fixed (revert-or-fix-forward). Allows
  the next queued unit to be built.

  Returns `:ok`.
  """
  @spec clear_red_main(:gen_statem.server_ref()) :: :ok
  def clear_red_main(server) do
    :gen_statem.call(server, :clear_red_main)
  end

  @doc """
  Classify an `origin/main` write attempt by the given actor.

  Returns `:ok` when `actor` is `:merge_authority` — the sole authorised
  writer of `origin/main` per [C200-B4] / SPEC-FACTORY-MERGE §3.

  Returns `{:escalate, :"E-DESTRUCTIVE"}` for every other actor.  A non-M
  push is a destructive action that MUST be escalated to K and MUST NOT be
  auto-executed (INV-20, SPEC-FACTORY-GOV D-319, [C212-B7]).

  This function is a pure classifier — it has no side-effects and does not
  execute any write regardless of the return value.
  """
  @spec classify_main_write(atom()) :: :ok | {:escalate, :"E-DESTRUCTIVE"}
  def classify_main_write(:merge_authority), do: :ok
  def classify_main_write(_actor), do: {:escalate, :"E-DESTRUCTIVE"}

  # ---------------------------------------------------------------------------
  # gen_statem callbacks
  # ---------------------------------------------------------------------------

  @impl :gen_statem
  def callback_mode, do: :state_functions

  @impl :gen_statem
  def init(opts) do
    # INV-ST-11: single-node guard. The control plane MUST NOT start when
    # connected BEAM nodes are visible — distributing M imports split-brain risk.
    # node_list_fun is injectable for test isolation (default: &Node.list/0).
    node_list_fun = Keyword.get(opts, :node_list_fun, &Node.list/0)

    case node_list_fun.() do
      nodes when nodes != [] ->
        # Defence-in-depth: if start_link's pre-spawn guard was bypassed
        # (e.g. direct :gen_statem.start_link call), stop the process here.
        {:stop, {:multi_node_detected, nodes}}

      [] ->
        # INV-DIST-R5: per-repo_dir single-instance guard. Register this process
        # (self()) with the RepoDirRegistry. The registration is atomic: if
        # another live MergeAuthority is already registered for this repo_dir,
        # init/1 stops with {:already_registered, repo_dir} and start_link
        # returns {:error, {:already_registered, repo_dir}} to the caller.
        # The registry monitors self() and cleans up the entry on process exit.
        repo_dir = Keyword.fetch!(opts, :repo_dir)
        repo_dir_registry = Keyword.get(opts, :repo_dir_registry, RepoDirRegistry)

        # Ensure the registry is running (idempotent — no-op if already started
        # by start_link/1 or Tau.Factory.Supervisor).
        {:ok, _} = repo_dir_registry.ensure_started()

        case repo_dir_registry.register(repo_dir) do
          :ok ->
            init_state(opts)

          {:error, {:already_registered, ^repo_dir}} ->
            {:stop, {:already_registered, repo_dir}}
        end
    end
  end

  defp init_state(opts) do
    ledger = Keyword.fetch!(opts, :ledger)
    repo_dir = Keyword.fetch!(opts, :repo_dir)
    tasks_name = Keyword.fetch!(opts, :tasks_name)
    required_halves = Keyword.get(opts, :required_halves, [:critic, :reviewer])
    cas = Keyword.get(opts, :cas, Cas)
    pubsub = Keyword.get(opts, :pubsub, Tau.PubSub)

    # D-394: resolve retry/backoff/timeout params from opts, falling back to module attrs.
    build_retry_max = Keyword.get(opts, :build_retry_max, @build_retry_max)
    build_backoff_ms = Keyword.get(opts, :build_backoff_ms, @build_backoff_ms)
    build_timeout_ms = Keyword.get(opts, :build_timeout_ms, @build_timeout_ms)

    # Start the Task.Supervisor for builds if it is not already running.
    # Linking it to this process ensures it is cleaned up when MA stops.
    case Process.whereis(tasks_name) do
      nil ->
        {:ok, _} = Task.Supervisor.start_link(name: tasks_name)

      _pid ->
        :already_running
    end

    build_fun =
      Keyword.get(opts, :build_fun, fn units, base ->
        default_build(repo_dir, units, base)
      end)

    post_merge_health_fun =
      Keyword.get(opts, :post_merge_health_fun, fn dir, lang, ctx ->
        Health.check(dir, lang, ctx)
      end)

    data = %{
      ledger: ledger,
      repo_dir: repo_dir,
      tasks_name: tasks_name,
      required_halves: required_halves,
      cas: cas,
      pubsub: pubsub,
      build_fun: build_fun,
      post_merge_health_fun: post_merge_health_fun,
      # D-394: resolved retry parameters
      build_retry_max: build_retry_max,
      build_backoff_ms: build_backoff_ms,
      build_timeout_ms: build_timeout_ms,
      # wait queue: list of units waiting to be built
      queue: [],
      # task ref for current build (nil when :idle)
      task_ref: nil,
      # task pid for forwarding barrier messages (nil when :idle)
      task_pid: nil,
      # units currently in the integrating train
      train: [],
      # D-394: per-member consecutive failure counter (unit_id => non_neg_integer)
      build_attempts: %{},
      # D-394: true while the T_backoff timer is armed; blocks start_build
      backoff_pending: false,
      # D-303 (B6): true after a post-merge red origin/main is detected;
      # gates start_build closed until an operator calls clear_red_main/1.
      main_red: false
    }

    {:ok, :idle, data}
  end

  # ---------------------------------------------------------------------------
  # State: :idle
  # ---------------------------------------------------------------------------

  def idle({:call, from}, {:request_merge, unit}, data) do
    data = enqueue(data, unit)

    case start_build(data) do
      {:integrating, next_data, actions} ->
        {:next_state, :integrating, next_data, [{:reply, from, :queued} | actions]}

      {:idle, next_data} ->
        {:keep_state, next_data, [{:reply, from, :queued}]}
    end
  end

  # D-394: backoff timer expired — clear pending flag and attempt next build.
  # In :state_functions callback mode, a generic timeout {:timeout, T, Name}
  # arrives as idle(:timeout, Name, data) — event type is :timeout, content is Name.
  def idle(:timeout, :build_backoff, data) do
    next_data = %{data | backoff_pending: false}
    transition_from_idle(next_data)
  end

  # D-303 (B6): operator clears the red-main gate after fixing origin/main.
  def idle({:call, from}, :clear_red_main, data) do
    next_data = %{data | main_red: false}

    case start_build(next_data) do
      {:integrating, new_data, actions} ->
        {:next_state, :integrating, new_data, [{:reply, from, :ok} | actions]}

      {:idle, new_data} ->
        {:keep_state, new_data, [{:reply, from, :ok}]}
    end
  end

  # Ignore stray barrier messages in idle state.
  def idle(:info, {:proceed, _ref}, data) do
    {:keep_state, data}
  end

  def idle(:info, msg, data) do
    Logger.debug("[MergeAuthority] idle received unexpected message: #{inspect(msg)}")
    {:keep_state, data}
  end

  # ---------------------------------------------------------------------------
  # State: :integrating
  # ---------------------------------------------------------------------------

  def integrating({:call, from}, {:request_merge, unit}, data) do
    # Enqueue for the NEXT train; do NOT start a second build (INV-3 / D-302).
    data = enqueue(data, unit)
    {:keep_state, data, [{:reply, from, :queued}]}
  end

  # Forward :proceed messages from the test barrier to the blocked task process.
  def integrating(:info, {:proceed, _ref} = msg, %{task_pid: task_pid} = data)
      when is_pid(task_pid) do
    send(task_pid, msg)
    {:keep_state, data}
  end

  def integrating(:info, {:proceed, _ref}, data) do
    {:keep_state, data}
  end

  # Task result: build succeeded.
  def integrating(:info, {ref, {:built, units, base, tip}}, %{task_ref: ref} = data) do
    # Demonitor; flush the :DOWN that async_nolink sends when the task exits.
    Process.demonitor(ref, [:flush])

    telemetry(:committing, %{hash: hd_hash(units)}, %{units: units, tip: tip})

    # D-394: reset build_attempts for all successfully-built members.
    next_attempts =
      Enum.reduce(units, data.build_attempts, fn unit, acc ->
        Map.delete(acc, unit.id)
      end)

    next_data = %{data | task_ref: nil, task_pid: nil, train: [], build_attempts: next_attempts}
    commit_action = {:next_event, :internal, {:commit, units, base, tip}}
    {:next_state, :committing, next_data, [commit_action]}
  end

  # Task result: build failed — health_red means eject (D-303, B=1); other
  # failures enter D-394 bounded backed-off retry or terminal eject.
  def integrating(:info, {ref, {:build_failed, reason}}, %{task_ref: ref} = data) do
    Process.demonitor(ref, [:flush])
    Logger.warning("[MergeAuthority] build failed: #{inspect(reason)}")

    train = data.train

    case reason do
      {:health_red, _report} ->
        # INV-MAI-8 / D-303: when the batch tip is red and the train has a
        # single member, it is trivially the culprit — eject immediately (same
        # semantics as before). When B > 1, we cannot know which member broke
        # the combined tip, so we spawn a bisect Task (Train.bisect/3) that
        # calls build_fun on sub-trains to identify the culprit in O(log B)
        # steps. The bisect result arrives as {:bisect_result, culprit,
        # survivors}; a dedicated integrating/3 clause handles it.
        case train do
          [_single] ->
            # B = 1: the lone member is the culprit — terminal eject.
            # D-355 (symmetric) / WAL-before-ack: write the durable :rejected
            # outcome row for the ejected member BEFORE the ephemeral telemetry
            # projection fires.
            Enum.each(train, fn unit ->
              LedgerWriter.record_merge_outcome(data.ledger, %{
                unit_id: unit.id,
                outcome: :rejected,
                commit_sha: nil,
                reason: :build_failed,
                run: unit.run
              })
            end)

            telemetry(:reject, %{hash: hd_hash(train)}, %{reason: :build_failed, units: train})

            # D-356: broadcast :rejected to the ejected member (terminal rejection).
            Enum.each(train, fn unit ->
              Phoenix.PubSub.broadcast(
                data.pubsub,
                "factory:pr:#{unit.id}",
                {:merge_result, :rejected}
              )
            end)

            next_data = eject_train(data)
            transition_from_idle(next_data)

          _multiple ->
            # B > 1: spawn a bisect Task to identify the culprit in O(log B)
            # steps. The Task calls build_fun on sub-trains; when it completes
            # the gen_statem receives {:bisect_result, culprit, survivors} and
            # handles it in a dedicated clause below. We reuse task_ref/task_pid
            # (the original build task has already returned at this point).
            build_fun = data.build_fun
            repo_dir = data.repo_dir
            tasks_name = data.tasks_name

            bisect_task =
              Task.Supervisor.async_nolink(tasks_name, fn ->
                base = fetch_main_oid(repo_dir)
                {:culprit, culprit, survivors} = Train.bisect(train, build_fun, base)
                {:bisect_result, culprit, survivors}
              end)

            telemetry(:bisect, %{}, %{units: train})

            next_data = %{
              data
              | task_ref: bisect_task.ref,
                task_pid: bisect_task.pid
            }

            {:keep_state, next_data}
        end

      _other ->
        # D-394: non-health retryable failure — bounded retry or terminal eject.
        bounded_retry_or_eject(data, :build_failed)
    end
  end

  # Bisect task result: culprit identified; eject the culprit and re-queue
  # the innocent survivors for re-integration (INV-MAI-8, D-303).
  def integrating(:info, {ref, {:bisect_result, culprit, survivors}}, %{task_ref: ref} = data) do
    Process.demonitor(ref, [:flush])

    Logger.info(
      "[MergeAuthority] bisect identified culprit: #{inspect(culprit.id)}; " <>
        "survivors: #{inspect(Enum.map(survivors, & &1.id))}"
    )

    # Terminal eject for the culprit only (D-355 WAL-before-ack + D-356 broadcast).
    LedgerWriter.record_merge_outcome(data.ledger, %{
      unit_id: culprit.id,
      outcome: :rejected,
      commit_sha: nil,
      reason: :build_failed,
      run: culprit.run
    })

    telemetry(:reject, %{hash: hd_hash([culprit])}, %{reason: :build_failed, units: [culprit]})

    Phoenix.PubSub.broadcast(
      data.pubsub,
      "factory:pr:#{culprit.id}",
      {:merge_result, :rejected}
    )

    # Re-queue the innocent survivors; clear train / task handles.
    # requeue_units prepends them to the queue head so they are picked up next.
    data_after_eject = %{
      data
      | train: [],
        task_ref: nil,
        task_pid: nil
    }

    next_data = requeue_units(data_after_eject, survivors)
    transition_from_idle(next_data)
  end

  # Task crashed (:DOWN without a prior result message).
  # D-394: task crash joins the bounded backed-off retry climb.
  def integrating(:info, {:DOWN, ref, :process, _pid, reason}, %{task_ref: ref} = data) do
    Logger.warning("[MergeAuthority] build task crashed: #{inspect(reason)}")
    bounded_retry_or_eject(data, :task_down)
  end

  # Wedged build guard: state_timeout fires if the build takes too long.
  # D-394: wedge is terminal at B=1 — kill task, eject, never requeue.
  def integrating(:state_timeout, :build_timeout, data) do
    Logger.warning("[MergeAuthority] build task wedged; ejecting train (terminal at B=1)")

    if data.task_pid, do: Process.exit(data.task_pid, :kill)
    if data.task_ref, do: Process.demonitor(data.task_ref, [:flush])

    # D-394: wedge is terminal at B=1 — does NOT count toward build_attempts.
    # Write durable row + broadcast then transition.
    next_data = terminal_eject_members(data, data.train, :build_wedged)
    transition_from_idle(next_data)
  end

  # D-303 (B6): accept clear_red_main while integrating (state recorded;
  # start_build guard will re-evaluate when this train completes).
  def integrating({:call, from}, :clear_red_main, data) do
    {:keep_state, %{data | main_red: false}, [{:reply, from, :ok}]}
  end

  def integrating(:info, msg, data) do
    Logger.debug("[MergeAuthority] integrating received unexpected message: #{inspect(msg)}")
    {:keep_state, data}
  end

  # ---------------------------------------------------------------------------
  # State: :committing
  # ---------------------------------------------------------------------------

  def committing(:internal, {:commit, units, base, tip}, data) do
    %{
      ledger: ledger,
      required_halves: required_halves,
      cas: cas,
      repo_dir: repo_dir,
      pubsub: pubsub
    } = data

    case cas.assert_all_verdicts_live(ledger, units, required_halves) do
      {:revoked, revoked_unit} ->
        Logger.info(
          "[MergeAuthority] verdict revoked for unit #{inspect(revoked_unit.id)}; no push"
        )

        # D-355 (symmetric) / WAL-before-ack: write the durable :rejected outcome
        # row for the revoked member BEFORE the ephemeral telemetry projection fires.
        # Mirrors the :merged WAL-before-ack path (D-315, RPO=0). Terminal rejection.
        LedgerWriter.record_merge_outcome(ledger, %{
          unit_id: revoked_unit.id,
          outcome: :rejected,
          commit_sha: nil,
          reason: :verdict_revoked,
          run: revoked_unit.run
        })

        telemetry(:reject, %{hash: revoked_unit.hash}, %{
          reason: :verdict_revoked,
          unit: revoked_unit
        })

        # D-356 TERMINAL REJECT: verdict-revoked eject is a terminal rejection for
        # this member. Broadcast :rejected AFTER telemetry (derived projection first,
        # then control-path delivery). A single-member train with a revoked verdict
        # gets no push and no requeue — this is the terminal signal the Unit awaits.
        Phoenix.PubSub.broadcast(
          pubsub,
          "factory:pr:#{revoked_unit.id}",
          {:merge_result, :rejected}
        )

        # Eject the revoked unit; requeue the rest (no push).
        rest = Enum.reject(units, &(&1.id == revoked_unit.id))
        next_data = requeue_units(data, rest)
        transition_from_idle(next_data)

      :all_pass ->
        case cas.cas_push(repo_dir, tip, base) do
          :ok ->
            Logger.info("[MergeAuthority] merged tip #{tip}")

            # D-355 / WAL-before-ack: write the durable merge-outcome row BEFORE
            # the ephemeral telemetry projection fires. Telemetry/PubSub becomes a
            # derived projection of the durable row. reply arrives only after the
            # WAL commit is durable (D-315, RPO=0).
            Enum.each(units, fn unit ->
              LedgerWriter.record_merge_outcome(ledger, %{
                unit_id: unit.id,
                outcome: :merged,
                commit_sha: tip,
                reason: nil,
                run: unit.run
              })
            end)

            telemetry(:merged, %{hash: hd_hash(units)}, %{tip: tip, units: units})

            # D-356: broadcast :merged to each train member's per-PR topic AFTER the
            # D-355 durable record and AFTER telemetry (WAL-before-ack ordering).
            Enum.each(units, fn unit ->
              Phoenix.PubSub.broadcast(
                pubsub,
                "factory:pr:#{unit.id}",
                {:merge_result, :merged}
              )
            end)

            # D-394: reset build_attempts for successfully merged members.
            next_attempts =
              Enum.reduce(units, data.build_attempts, fn unit, acc ->
                Map.delete(acc, unit.id)
              end)

            data_after_merge = %{data | build_attempts: next_attempts}

            # D-303 (B6) / [C209-B6]: post-merge origin/main re-check.
            # After a successful CAS push, re-check origin/main health.
            # A red result gates the merge precondition closed (□ red(main) → ¬∃ d.
            # merge(d)) and raises E-RED-MAIN to K via "factory:control".
            case data.post_merge_health_fun.(repo_dir, :elixir, %{}) do
              :green ->
                transition_from_idle(data_after_merge)

              {:red, report} ->
                Logger.warning(
                  "[MergeAuthority] post-merge origin/main is red; raising E-RED-MAIN: #{inspect(report)}"
                )

                telemetry(:health, %{}, %{result: :red, phase: :post_merge_check})

                Phoenix.PubSub.broadcast(
                  pubsub,
                  "factory:control",
                  {:escalate, {:"E-RED-MAIN", :global}}
                )

                # Gate the merge precondition closed: set main_red = true so
                # start_build refuses to admit any further build until cleared.
                {:next_state, :idle, %{data_after_merge | main_red: true}}
            end

          {:error, :stale_ref} ->
            Logger.info("[MergeAuthority] stale ref; requeuing train for rebase + re-gate")
            telemetry(:reject, %{hash: hd_hash(units)}, %{reason: :stale_ref, units: units})
            # :stale_ref is NOT a terminal reject — the train is requeued for retry.
            # D-356: do NOT broadcast :rejected here.
            next_data = requeue_units(data, units)
            transition_from_idle(next_data)

          {:error, reason} ->
            Logger.warning("[MergeAuthority] cas_push failed: #{inspect(reason)}")
            telemetry(:reject, %{hash: hd_hash(units)}, %{reason: reason, units: units})
            # Other cas_push errors are also requeued for retry.
            # D-356: do NOT broadcast :rejected here.
            next_data = requeue_units(data, units)
            transition_from_idle(next_data)
        end
    end
  end

  def committing({:call, from}, {:request_merge, unit}, data) do
    data = enqueue(data, unit)
    {:keep_state, data, [{:reply, from, :queued}]}
  end

  # D-303 (B6): accept clear_red_main while committing.
  def committing({:call, from}, :clear_red_main, data) do
    {:keep_state, %{data | main_red: false}, [{:reply, from, :ok}]}
  end

  def committing(:info, msg, data) do
    Logger.debug("[MergeAuthority] committing received unexpected message: #{inspect(msg)}")
    {:keep_state, data}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp enqueue(%{queue: queue} = data, unit) do
    # D-341: stamp enqueued_at on first entry; preserved across requeues so
    # max_wait_ms in start_build/1 reflects total wait, not just the latest
    # enqueue cycle.
    stamped = Map.put_new(unit, :enqueued_at, System.monotonic_time(:millisecond))
    %{data | queue: queue ++ [stamped]}
  end

  # D-394: head guard — if a backoff timer is armed, do NOT launch a build.
  # D-303 (B6): if origin/main is red, do NOT launch a build until cleared.
  # This is the single chokepoint: every code path that might launch funnels
  # through start_build/1, so the guards cover all of them.
  defp start_build(%{backoff_pending: true} = data), do: {:idle, data}

  defp start_build(%{main_red: true} = data), do: {:idle, data}

  defp start_build(%{queue: []} = data), do: {:idle, data}

  defp start_build(%{queue: [unit | rest]} = data) do
    # [C213-B4] / HR-5: assemble a batch (B ≥ 1; when ≥ 2 units are already
    # waiting at transition time, consume the whole queue so B ≥ 2).
    # The serial regime (B = 1) is stable only when the queue is empty at the
    # moment of assembly; if ≥ 2 units wait, taking them all avoids ρ_g → 1.
    train = [unit | rest]

    # D-341 / B8: emit the :queue span with LIV-2 starvation falsification
    # measurements BEFORE launching the build Task. max_restale_count and
    # max_wait_ms are the live runtime watches for the fair FIFO+aging queue.
    now_ms = System.monotonic_time(:millisecond)

    max_restale =
      Enum.reduce(train, 0, fn u, acc ->
        max(acc, Map.get(u, :restale_count, 0))
      end)

    max_wait =
      Enum.reduce(train, 0, fn u, acc ->
        enqueued = Map.get(u, :enqueued_at, now_ms)
        max(acc, now_ms - enqueued)
      end)

    telemetry(:queue, %{max_restale_count: max_restale, max_wait_ms: max_wait}, %{
      units: train
    })

    build_fun = data.build_fun
    repo_dir = data.repo_dir
    tasks_name = data.tasks_name

    # INV-MAI-1 / D-302 / [C206-B1]: fetch_main_oid runs INSIDE the async Task
    # (off the gen_statem mailbox) so that request_merge returns :queued
    # immediately without blocking on network I/O. A stalled git fetch must not
    # hold up the gen_statem callback — M's mailbox must stay free for T_int.
    task =
      Task.Supervisor.async_nolink(tasks_name, fn ->
        base = fetch_main_oid(repo_dir)
        build_fun.(train, base)
      end)

    telemetry(:integrating, %{hash: hd_hash(train)}, %{units: train, base: nil})

    next_data = %{
      data
      | queue: [],
        train: train,
        task_ref: task.ref,
        task_pid: task.pid
    }

    # D-394: use the resolved build_timeout_ms from data (not the module attribute).
    timeout_action = {:state_timeout, data.build_timeout_ms, :build_timeout}
    {:integrating, next_data, [timeout_action]}
  end

  # Transition back from a terminal state (after a commit/reject completes).
  # Either returns to :idle or kicks off the next build.
  defp transition_from_idle(data) do
    case start_build(data) do
      {:integrating, next_data, actions} ->
        {:next_state, :integrating, next_data, actions}

      {:idle, next_data} ->
        {:next_state, :idle, next_data}
    end
  end

  # D-394: bounded retry or terminal eject for retryable build failures.
  #
  # Increments build_attempts for each train member, then:
  #   - Members at N_build exhaustion → terminal_eject_members (durable row + broadcast).
  #   - Remaining retryable members → requeue with a T_backoff timer.
  #   - If ALL exhausted → no timer, transition_from_idle immediately.
  #   - If ANY retryable → arm {:timeout, T_backoff, :build_backoff}, set backoff_pending.
  #
  # Returns a gen_statem action tuple.
  defp bounded_retry_or_eject(data, failure_reason) do
    train = data.train
    retry_max = data.build_retry_max
    backoff_ms = data.build_backoff_ms

    # Increment attempt counter for each current train member.
    new_attempts =
      Enum.reduce(train, data.build_attempts, fn unit, acc ->
        Map.update(acc, unit.id, 1, &(&1 + 1))
      end)

    # Partition by exhaustion.
    {exhausted, retryable} =
      Enum.split_with(train, fn unit ->
        Map.get(new_attempts, unit.id, 0) >= retry_max
      end)

    # Emit a non-terminal telemetry span for ALL train members first.
    # (Terminal path emits its own telemetry inside terminal_eject_members.)
    unless retryable == [] do
      telemetry(:reject, %{hash: hd_hash(train)}, %{reason: failure_reason, units: train})
    end

    # Terminal eject exhausted members (writes durable rows + broadcasts).
    data_after_eject =
      if exhausted == [] do
        data
      else
        terminal_eject_members(
          %{data | build_attempts: new_attempts},
          exhausted,
          :build_retry_exhausted
        )
      end

    if retryable == [] do
      # All members exhausted — eject was already terminal; transition immediately.
      # (terminal_eject_members already cleared train/task_ref/task_pid and dropped
      # the ejected units from build_attempts — do NOT overwrite with new_attempts.)
      transition_from_idle(data_after_eject)
    else
      # At least one retryable member: requeue, set backoff_pending, arm timer.
      # Emit per-retryable-member :build_retry point telemetry (D-394).
      Enum.each(retryable, fn unit ->
        attempt_n = Map.get(new_attempts, unit.id, 0)

        :telemetry.execute(
          [:tau, :factory, :merge, :build_retry],
          %{},
          %{unit_id: unit.id, attempt_n: attempt_n, backoff_ms: backoff_ms}
        )
      end)

      next_data =
        data_after_eject
        |> requeue_units(retryable)
        |> Map.put(:build_attempts, new_attempts)
        |> Map.put(:backoff_pending, true)

      {:next_state, :idle, next_data, [{:timeout, backoff_ms, :build_backoff}]}
    end
  end

  # D-394: terminal eject for a list of units with a given reason.
  #
  # For each unit IN ORDER (D-355/D-356):
  #   (a) Write durable :rejected row via LedgerWriter (WAL-before-ack).
  #   (b) Emit :reject telemetry.
  #   (c) Broadcast {:merge_result, :rejected} on the per-PR PubSub topic.
  #
  # Returns updated data with those units removed from train, task_ref/task_pid
  # cleared, and their build_attempts entries dropped.
  defp terminal_eject_members(data, units, reason) do
    # (a) WAL-before-ack: write all durable rows BEFORE any telemetry or broadcast.
    Enum.each(units, fn unit ->
      LedgerWriter.record_merge_outcome(data.ledger, %{
        unit_id: unit.id,
        outcome: :rejected,
        commit_sha: nil,
        reason: reason,
        run: unit.run
      })
    end)

    # (b) Telemetry after WAL writes.
    telemetry(:reject, %{hash: hd_hash(units)}, %{reason: reason, units: units})

    # (c) D-356: broadcast :rejected per unit after telemetry.
    Enum.each(units, fn unit ->
      Phoenix.PubSub.broadcast(
        data.pubsub,
        "factory:pr:#{unit.id}",
        {:merge_result, :rejected}
      )
    end)

    # Drop ejected units from train and build_attempts; clear task handles.
    ejected_ids = MapSet.new(units, & &1.id)

    remaining_train =
      Enum.reject(data.train, fn unit -> MapSet.member?(ejected_ids, unit.id) end)

    next_attempts =
      Enum.reduce(units, data.build_attempts, fn unit, acc ->
        Map.delete(acc, unit.id)
      end)

    %{data | train: remaining_train, task_ref: nil, task_pid: nil, build_attempts: next_attempts}
  end

  # Eject the current train without requeuing its units. Used for D-303 health
  # failures — a red tip is discarded; the caller decides on future action.
  defp eject_train(data) do
    %{data | train: [], task_ref: nil, task_pid: nil}
  end

  defp requeue_units(%{queue: queue} = data, units) do
    # D-341: increment restale_count on each unit being requeued. This tracks
    # how many times a unit has been re-staled (fresh-merge-race or build-retry),
    # driving the aging priority in the fair FIFO+aging queue (LIV-2).
    restaled = Enum.map(units, fn u -> Map.update(u, :restale_count, 1, &(&1 + 1)) end)
    %{data | queue: restaled ++ queue, task_ref: nil, task_pid: nil, train: []}
  end

  # Fetch current origin/main oid after a fetch; returns a string or raises.
  defp fetch_main_oid(repo_dir) do
    case System.cmd("git", ["fetch", "origin"], cd: repo_dir, stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {output, code} ->
        Logger.warning("[MergeAuthority] git fetch failed (#{code}): #{output}")
    end

    {oid, 0} = System.cmd("git", ["rev-parse", "origin/main"], cd: repo_dir)
    String.trim(oid)
  end

  # Default build_fun: acquire a private ephemeral worktree, fetch + rebase
  # the unit branch onto base, run health check, then return the tip or a
  # build_failed result.  The shared repo_dir is the ref anchor only — its HEAD
  # and index are NEVER touched (D-385, INV-11).
  defp default_build(repo_dir, [unit | _] = units, base) do
    nonce = :erlang.unique_integer([:positive])
    merge_wt = Path.join(Path.dirname(repo_dir), ".merge-wt-#{nonce}")

    case System.cmd(
           "git",
           ["worktree", "add", "--detach", merge_wt, unit.branch],
           cd: repo_dir,
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        try do
          do_build_in_worktree(repo_dir, merge_wt, units, base)
        after
          System.cmd(
            "git",
            ["worktree", "remove", "--force", merge_wt],
            cd: repo_dir,
            stderr_to_stdout: true
          )
        end

      {output, code} ->
        {:build_failed, {:git_error, code, output}}
    end
  end

  # Run the actual fetch/rebase/health steps inside merge_wt (never repo_dir).
  # repo_dir is used only for ref-ops (fetch writes refs, not the tree).
  # After a successful rebase we force-push the rebased tip to origin/<branch>
  # so the tip SHA is addressable on the remote for CAS (cas_push creates the
  # fast-forward from origin/<branch>'s tip onto origin/main).
  # D-303 / INV-MAI-5: health check runs PRE-PUSH — no push to origin (including
  # origin/<branch>) may precede a green health result. Fetch and rebase first,
  # run health on the rebased tip, and only push if health returns :green.
  defp do_build_in_worktree(repo_dir, merge_wt, [unit | _] = units, base) do
    git_wt = fn args ->
      System.cmd("git", args, cd: merge_wt, stderr_to_stdout: true)
    end

    with {_, 0} <- System.cmd("git", ["fetch", "origin"], cd: repo_dir, stderr_to_stdout: true),
         {_, 0} <- git_wt.(["rebase", base]),
         {tip_raw, 0} <- git_wt.(["rev-parse", "HEAD"]) do
      tip = String.trim(tip_raw)

      case Health.check(merge_wt, :elixir, %{}) do
        :green ->
          case System.cmd(
                 "git",
                 ["push", "--force-with-lease", "origin", "HEAD:#{unit.branch}"],
                 cd: merge_wt,
                 stderr_to_stdout: true
               ) do
            {_, 0} ->
              {:built, units, base, tip}

            {output, code} ->
              {:build_failed, {:git_error, code, output}}
          end

        {:red, report} ->
          {:build_failed, {:health_red, report}}
      end
    else
      {output, code} ->
        {:build_failed, {:git_error, code, output}}
    end
  end

  defp hd_hash([%{hash: hash} | _]), do: hash
  defp hd_hash([]), do: nil

  defp telemetry(event, measurements, metadata) do
    :telemetry.execute([:tau, :factory, :merge, event], measurements, metadata)
  end
end
