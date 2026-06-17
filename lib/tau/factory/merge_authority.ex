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

  alias Tau.Factory.Gate
  alias Tau.Factory.Ledger.Writer, as: LedgerWriter
  alias Tau.Factory.Merge.Cas
  alias Tau.Factory.Merge.Health

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
    - `:required_halves` — list of verdict halves required (default `Gate.gate_floor/0` = `[:mutation, :critic, :reviewer]`; D-335).
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
    required_halves = Keyword.get(opts, :required_halves, Gate.gate_floor())
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

    data = %{
      ledger: ledger,
      repo_dir: repo_dir,
      tasks_name: tasks_name,
      required_halves: required_halves,
      cas: cas,
      pubsub: pubsub,
      build_fun: build_fun,
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
      backoff_pending: false
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
        # Eject the train; do NOT requeue — health failure is terminal for this tip.
        # D-355 (symmetric) / WAL-before-ack: write the durable :rejected outcome
        # row for each ejected member BEFORE the ephemeral telemetry projection
        # fires. Mirrors the :merged WAL-before-ack path in :committing (D-315,
        # RPO=0). Only TERMINAL rejections are durable; requeues write nothing.
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

        # D-356: broadcast :rejected to each ejected member (terminal rejection).
        Enum.each(train, fn unit ->
          Phoenix.PubSub.broadcast(
            data.pubsub,
            "factory:pr:#{unit.id}",
            {:merge_result, :rejected}
          )
        end)

        next_data = eject_train(data)
        transition_from_idle(next_data)

      _other ->
        # D-394: non-health retryable failure — bounded retry or terminal eject.
        bounded_retry_or_eject(data, :build_failed)
    end
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

            transition_from_idle(%{data | build_attempts: next_attempts})

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

  # D-394: head guard — if a backoff timer is armed, do NOT launch a build.
  # This is the single chokepoint: every code path that might launch funnels
  # through start_build/1, so the guard covers all of them.
  defp start_build(%{backoff_pending: true} = data), do: {:idle, data}

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
  defp do_build_in_worktree(repo_dir, merge_wt, [unit | _] = units, base) do
    git_wt = fn args ->
      System.cmd("git", args, cd: merge_wt, stderr_to_stdout: true)
    end

    with {_, 0} <- System.cmd("git", ["fetch", "origin"], cd: repo_dir, stderr_to_stdout: true),
         {_, 0} <- git_wt.(["rebase", base]),
         {tip_raw, 0} <- git_wt.(["rev-parse", "HEAD"]),
         {_, 0} <-
           System.cmd(
             "git",
             ["push", "--force-with-lease", "origin", "HEAD:#{unit.branch}"],
             cd: merge_wt,
             stderr_to_stdout: true
           ) do
      tip = String.trim(tip_raw)

      case Health.check(merge_wt, :elixir, %{}) do
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
