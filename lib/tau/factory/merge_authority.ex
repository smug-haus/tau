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

  require Logger

  # How long to wait for a build task before treating it as wedged (C207).
  @build_timeout_ms :timer.minutes(30)

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
    :gen_statem.start_link({:local, name}, __MODULE__, opts, [])
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

  # ---------------------------------------------------------------------------
  # gen_statem callbacks
  # ---------------------------------------------------------------------------

  @impl :gen_statem
  def callback_mode, do: :state_functions

  @impl :gen_statem
  def init(opts) do
    ledger = Keyword.fetch!(opts, :ledger)
    repo_dir = Keyword.fetch!(opts, :repo_dir)
    tasks_name = Keyword.fetch!(opts, :tasks_name)
    required_halves = Keyword.get(opts, :required_halves, [:critic, :reviewer])
    cas = Keyword.get(opts, :cas, Cas)
    pubsub = Keyword.get(opts, :pubsub, Tau.PubSub)

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

    data = %{
      ledger: ledger,
      repo_dir: repo_dir,
      tasks_name: tasks_name,
      required_halves: required_halves,
      cas: cas,
      pubsub: pubsub,
      build_fun: build_fun,
      # wait queue: list of units waiting to be built
      queue: [],
      # task ref for current build (nil when :idle)
      task_ref: nil,
      # task pid for forwarding barrier messages (nil when :idle)
      task_pid: nil,
      # units currently in the integrating train
      train: []
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

    next_data = %{data | task_ref: nil, task_pid: nil, train: []}
    commit_action = {:next_event, :internal, {:commit, units, base, tip}}
    {:next_state, :committing, next_data, [commit_action]}
  end

  # Task result: build failed — health_red means eject (D-303, B=1); other
  # failures requeue for the next train attempt.
  def integrating(:info, {ref, {:build_failed, reason}}, %{task_ref: ref} = data) do
    Process.demonitor(ref, [:flush])
    Logger.warning("[MergeAuthority] build failed: #{inspect(reason)}")

    train = data.train
    telemetry(:reject, %{hash: hd_hash(train)}, %{reason: :build_failed, units: train})

    next_data =
      case reason do
        {:health_red, _report} ->
          # Eject the train; do NOT requeue — health failure is terminal for this tip.
          # D-356: broadcast :rejected to each ejected member (terminal rejection).
          Enum.each(train, fn unit ->
            Phoenix.PubSub.broadcast(
              data.pubsub,
              "factory:pr:#{unit.id}",
              {:merge_result, :rejected}
            )
          end)

          eject_train(data)

        _other ->
          requeue_train(data)
      end

    transition_from_idle(next_data)
  end

  # Task crashed (:DOWN without a prior result message).
  def integrating(:info, {:DOWN, ref, :process, _pid, reason}, %{task_ref: ref} = data) do
    Logger.warning("[MergeAuthority] build task crashed: #{inspect(reason)}")

    train = data.train
    telemetry(:reject, %{hash: hd_hash(train)}, %{reason: :task_down, units: train})

    next_data = requeue_train(data)
    transition_from_idle(next_data)
  end

  # Wedged build guard: state_timeout fires if the build takes too long.
  def integrating(:state_timeout, :build_timeout, data) do
    Logger.warning("[MergeAuthority] build task wedged; requeuing train")

    if data.task_pid, do: Process.exit(data.task_pid, :kill)
    if data.task_ref, do: Process.demonitor(data.task_ref, [:flush])

    train = data.train
    telemetry(:reject, %{hash: hd_hash(train)}, %{reason: :build_timeout, units: train})

    next_data = requeue_train(data)
    transition_from_idle(next_data)
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

            transition_from_idle(data)

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

  def committing(:info, msg, data) do
    Logger.debug("[MergeAuthority] committing received unexpected message: #{inspect(msg)}")
    {:keep_state, data}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp enqueue(%{queue: queue} = data, unit) do
    %{data | queue: queue ++ [unit]}
  end

  # Attempt to start a new build from the queue. Returns a gen_statem reply tuple.
  # Used from `:idle` to avoid duplicating the transition logic.
  defp start_build(%{queue: []} = data), do: {:idle, data}

  defp start_build(%{queue: [unit | rest]} = data) do
    train = [unit]
    base = fetch_main_oid(data.repo_dir)

    build_fun = data.build_fun
    tasks_name = data.tasks_name

    task = Task.Supervisor.async_nolink(tasks_name, fn -> build_fun.(train, base) end)

    telemetry(:integrating, %{hash: hd_hash(train)}, %{units: train, base: base})

    next_data = %{
      data
      | queue: rest,
        train: train,
        task_ref: task.ref,
        task_pid: task.pid
    }

    timeout_action = {:state_timeout, @build_timeout_ms, :build_timeout}
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

  defp requeue_train(%{train: train} = data) do
    requeue_units(%{data | train: []}, train)
  end

  # Eject the current train without requeuing its units. Used for D-303 health
  # failures — a red tip is discarded; the caller decides on future action.
  defp eject_train(data) do
    %{data | train: [], task_ref: nil, task_pid: nil}
  end

  defp requeue_units(%{queue: queue} = data, units) do
    %{data | queue: units ++ queue, task_ref: nil, task_pid: nil, train: []}
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

  # Default build_fun: fetch + rebase unit branch onto base, run health check,
  # then return the tip or a build_failed result.
  defp default_build(repo_dir, [unit | _] = units, base) do
    git = fn args ->
      System.cmd("git", args, cd: repo_dir, stderr_to_stdout: true)
    end

    with {_, 0} <- git.(["fetch", "origin"]),
         {_, 0} <- git.(["checkout", unit.branch]),
         {_, 0} <- git.(["rebase", base]),
         {tip_raw, 0} <- git.(["rev-parse", "HEAD"]) do
      tip = String.trim(tip_raw)

      case Health.check(repo_dir, :elixir, %{}) do
        :green ->
          {:built, units, base, tip}

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
