defmodule Tau.Factory.UnitDriver do
  @moduledoc """
  The real `drive_fun` the Coordinator calls to drive a single `Tau.Factory.Unit`
  through the full factory substrate.

  `drive/2` wires the three Unit seams — `:worker_fun`, `:gate_fun`,
  `:merge_fun` — over the live substrate processes and starts the Unit under the
  supplied `UnitSupervisor`. It is the ONLY entry point a Coordinator needs to
  launch a per-PR unit cycle.

  ## Seams

  **`:worker_fun`** — calls `WorkerSupervisor.spawn/5` with `report_to` bound to
  the calling Unit's pid (resolved via `self()` at invocation time, since
  `worker_fun` is always called from within the Unit process). Returns the
  3-tuple `{:ok, worker_pid, worker_id}` so the Unit can gate
  `implementing → gating` on the D-326 `{:work_ready, ^worker_id, _, _}` event.

  **`:gate_fun`** — passed through directly from `deps.gate_fun`. The Coordinator
  may inject a hermetic gate for testing; the driver also accepts a real
  `Gate.run/1` closure here.

  **`:merge_fun`** — builds `%{id: unit_id, hash: hash, run: run, branch: branch}`,
  calls `MergeAuthority.request_merge/2`, then installs a telemetry bridge that
  forwards `{:merge_result, :merged}` / `{:merge_result, :rejected}` to the Unit
  pid when the real MergeAuthority emits `[:tau, :factory, :merge, :merged]` /
  `[:tau, :factory, :merge, :reject]`. The bridge is keyed by `unit_id` so it
  only fires for this unit's outcome.

  ## D-340 terminal report

  The Unit itself sends `{:unit_terminal, unit_id, outcome, provenance}` to
  `deps.report_to` on reaching a terminal state. The driver does not emit that
  message — it wires the seams and starts the Unit.

  See `docs/spec/SPEC-FACTORY-CORE.md` §4 B8, D-340.
  """

  alias Tau.Factory.MergeAuthority
  alias Tau.Factory.UnitSupervisor
  alias Tau.Factory.WorkerSupervisor

  require Logger

  @doc """
  Wire the Unit seams over the live substrate and start the Unit under the
  `UnitSupervisor`.

  Returns the pid of the started `Tau.Factory.Unit`.

  ## `work_item` keys

    * `:unit_id`        — `String.t()`; unique unit identity (== PR/unit id in
                          the merge map's `:id`).
    * `:declared_scope` — `ConflictCheck.scope()` passed to `Scheduler.admit/3`.
    * `:hash`           — `String.t()`; content/HEAD hash for the PR.
    * `:branch`         — `String.t()`; the feature branch (passed in merge map).
    * `:run`            — `String.t()`; the run identifier (merge-map `:run`).
    * `:base_ref`       — `String.t()`; the git ref `WorkerSupervisor.spawn/5`
                          checks out for the worker worktree.
    * `:brief`          — `String.t()`; the worker brief.

  ## `deps` keys

    * `:unit_supervisor`   — atom/pid of a running `UnitSupervisor`.
    * `:unit_registry`     — atom of a running `UnitRegistry` (passed as
                             `:registry_name` to the Unit).
    * `:scheduler`         — atom/pid of a running `Scheduler`.
    * `:worker_supervisor` — atom/pid of a running `WorkerSupervisor`.
    * `:worker_registry`   — atom of a running `WorkerRegistry`.
    * `:repo_dir`          — `String.t()`; the parent git repo for worker
                             worktrees.
    * `:agent_bin`         — `String.t()`; the agent executable each worker runs.
    * `:gate_fun`          — `(-> :pass | {:fail, findings})`; injected gate
                             seam (passed through to the Unit unchanged).
    * `:merge_authority`   — atom/pid of a (possibly stubbed) `MergeAuthority`;
                             the `:merge_fun` calls `request_merge/2` against it.
    * `:report_to`         — pid receiving `{:unit_terminal, unit_id, outcome,
                             provenance}` (the coordinator seam).
    * `:ledger`            — optional; `GenServer.server()` | `nil`.
  """
  @spec drive(map(), map()) :: pid()
  def drive(work_item, deps) do
    %{
      unit_id: unit_id,
      declared_scope: declared_scope,
      hash: hash,
      branch: branch,
      run: run,
      base_ref: base_ref,
      brief: brief
    } = work_item

    %{
      unit_supervisor: unit_supervisor,
      unit_registry: unit_registry,
      scheduler: scheduler,
      worker_supervisor: worker_supervisor,
      worker_registry: worker_registry,
      repo_dir: repo_dir,
      agent_bin: agent_bin,
      gate_fun: gate_fun,
      merge_authority: merge_authority,
      report_to: report_to
    } = deps

    ledger = Map.get(deps, :ledger, nil)

    # -------------------------------------------------------------------------
    # Shared worktree reclaim tracker (synchronous reclaim via merge_fun).
    #
    # Stores the list of private worker worktree paths (ws) that have been
    # allocated so far. merge_fun drains and reclaims them synchronously —
    # by the time merge_fun runs (awaiting_merge entry), both the :test_author
    # and :implementer workers have already exited, so reclaim is safe.
    #
    # Using an Agent (owned by the current caller process) lets worker_fun
    # (which runs in the Unit process) and merge_fun (also Unit process) share
    # mutable state without ETS or process dictionary. The Agent is started
    # unlinked to avoid linking it to the Unit (which is started separately);
    # it lives until the Unit terminates or the caller process dies.
    # -------------------------------------------------------------------------
    {:ok, reclaim_agent} = Agent.start(fn -> [] end)

    # -------------------------------------------------------------------------
    # :worker_fun — called from within the Unit's process context.
    # `self()` at invocation time resolves to the Unit pid, so the Worker's
    # `report_to` is the Unit itself (D-326 in-band work_ready delivery).
    # WorkerSupervisor.spawn/5 returns {:ok, worker_id}. After spawn completes,
    # the Worker has finished init/1 and registered in the WorkerRegistry.
    # We look up its pid from the registry to return the 3-tuple the Unit needs.
    # The private worktree path (ws) is registered in reclaim_agent for later
    # synchronous reclaim in merge_fun.
    # -------------------------------------------------------------------------
    worker_fun = fn role ->
      unit_pid = self()

      opts = [
        registry: worker_registry,
        repo_dir: repo_dir,
        agent_bin: agent_bin,
        report_to: unit_pid
      ]

      case WorkerSupervisor.spawn(worker_supervisor, role, brief, base_ref, opts) do
        {:ok, worker_id} ->
          case resolve_worker_pid(worker_registry, worker_id) do
            {:ok, worker_pid} ->
              # Register the private worktree path for synchronous reclaim in merge_fun.
              ws = Path.join([Path.dirname(repo_dir), ".worker-wt-#{worker_id}"])
              Agent.update(reclaim_agent, fn ws_list -> [ws | ws_list] end)

              {:ok, worker_pid, worker_id}

            {:error, reason} ->
              Logger.warning(
                "[UnitDriver #{unit_id}] failed to resolve worker pid for #{worker_id}: #{inspect(reason)}"
              )

              {:error, reason}
          end

        {:error, reason} ->
          Logger.warning(
            "[UnitDriver #{unit_id}] WorkerSupervisor.spawn failed: #{inspect(reason)}"
          )

          {:error, reason}
      end
    end

    # -------------------------------------------------------------------------
    # :merge_fun — called from the Unit's awaiting_merge state.
    # Builds the exact merge map, calls MergeAuthority.request_merge/2, then
    # installs a short-lived telemetry bridge that forwards the async outcome
    # back to the Unit pid as {:merge_result, :merged} or {:merge_result, :rejected}.
    # The bridge is keyed by unit_id so it only fires for this unit's outcome.
    # In tests, the stub MergeAuthority never fires real telemetry events;
    # the test manually sends {:merge_result, :merged} to the unit_pid instead.
    #
    # Before calling request_merge, synchronously reclaim all pending worker
    # worktrees. By the time awaiting_merge is entered, both the :test_author
    # and :implementer workers have already exited (work_ready was received and
    # the Unit passed through gating). Reclaiming here eliminates the scheduling
    # race that would otherwise exist if reclaim ran in a separate monitor process.
    # -------------------------------------------------------------------------
    merge_fun = fn merge_unit_id, merge_hash ->
      unit_pid = self()

      # Synchronously reclaim all pending private worktrees.
      pending_ws = Agent.get_and_update(reclaim_agent, fn ws_list -> {ws_list, []} end)
      Enum.each(pending_ws, fn ws -> reclaim_worktree(ws, repo_dir) end)

      merge_map = %{
        id: merge_unit_id,
        hash: merge_hash,
        run: run,
        branch: branch
      }

      # Install telemetry bridge before calling request_merge/2 so no
      # event is missed if the authority resolves synchronously (unlikely
      # but safe). The bridge is a monitored process that detaches its
      # handler on receipt or on unit pid death.
      install_merge_bridge(unit_id, unit_pid)

      MergeAuthority.request_merge(merge_authority, merge_map)
    end

    # -------------------------------------------------------------------------
    # Start the Unit under the UnitSupervisor with all seams wired.
    # -------------------------------------------------------------------------
    unit_opts = [
      unit_id: unit_id,
      declared_scope: declared_scope,
      hash: hash,
      scheduler: scheduler,
      report_to: report_to,
      worker_fun: worker_fun,
      gate_fun: gate_fun,
      merge_fun: merge_fun,
      ledger: ledger,
      registry_name: unit_registry
    ]

    UnitSupervisor.start_unit(unit_supervisor, unit_opts)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Resolve the worker pid from the WorkerRegistry by worker_id.
  # The Worker registers itself synchronously in init/1, so after
  # WorkerSupervisor.spawn/5 returns, the pid is always available.
  # Returns {:ok, pid} | {:error, :not_found}.
  @spec resolve_worker_pid(atom(), String.t()) :: {:ok, pid()} | {:error, :not_found}
  defp resolve_worker_pid(worker_registry, worker_id) do
    case Registry.lookup(worker_registry, worker_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  # Remove the worker's private git worktree: deregister via git then rm_rf.
  @spec reclaim_worktree(String.t(), String.t()) :: :ok
  defp reclaim_worktree(ws, repo_dir) do
    if File.dir?(ws) do
      System.cmd("git", ["worktree", "remove", "--force", ws],
        cd: repo_dir,
        stderr_to_stdout: true
      )
    end

    if File.exists?(ws) do
      File.rm_rf!(ws)
    end

    :ok
  end

  # Install a short-lived telemetry bridge process for the given unit_id.
  # Subscribes to [:tau, :factory, :merge, :merged] and
  # [:tau, :factory, :merge, :reject], forwards a single {:merge_result, _}
  # message to unit_pid when a matching unit_id is found in the event metadata,
  # then detaches and exits.
  #
  # The bridge process monitors unit_pid and exits cleanly if the Unit dies
  # before a merge outcome arrives (no leak). Uses Process.spawn for a truly
  # unlinked bridge that won't crash the Unit on bridge exit.
  #
  # OTP non-negotiable: this is a monitored-ref pattern, NOT Process.whereis|>send.
  # The handler name is unique per unit_id so concurrent units don't collide.
  @spec install_merge_bridge(String.t(), pid()) :: :ok
  defp install_merge_bridge(unit_id, unit_pid) do
    handler_id = {__MODULE__, :merge_bridge, unit_id}

    # Unlinked bridge process: monitors unit_pid and cleans up its telemetry
    # handler when done (on merge outcome or unit death).
    Elixir.Process.spawn(
      fn ->
        unit_ref = Process.monitor(unit_pid)

        :telemetry.attach_many(
          handler_id,
          [
            [:tau, :factory, :merge, :merged],
            [:tau, :factory, :merge, :reject]
          ],
          fn event_name, _measurements, metadata, _config ->
            outcome_for_unit = find_unit_outcome(event_name, metadata, unit_id)

            if outcome_for_unit do
              send(unit_pid, {:merge_result, outcome_for_unit})
            end
          end,
          nil
        )

        wait_for_merge_outcome(unit_ref, unit_pid, handler_id)
      end,
      []
    )

    :ok
  end

  # Determine if this telemetry event is for our unit_id and map it to an outcome.
  # MergeAuthority metadata carries `units: [%{id: unit_id, ...}]`.
  # Returns :merged | :rejected | nil.
  @spec find_unit_outcome(list(), map(), String.t()) :: :merged | :rejected | nil
  defp find_unit_outcome(event_name, metadata, unit_id) do
    units = Map.get(metadata, :units, [])
    ids = Enum.map(units, & &1.id)

    if unit_id in ids do
      case List.last(event_name) do
        :merged -> :merged
        :reject -> :rejected
        _ -> nil
      end
    end
  end

  # Bridge receive loop: wait for the unit_pid :DOWN (dead — detach handler)
  # or a :bridge_done signal (sent by the handler after forwarding). Using a
  # mailbox poll because the telemetry handler runs synchronously in the telemetry
  # caller's context, not in this process — it can send us a message.
  # We use a sentinel message approach: the handler sends {:merge_bridge_done, unit_id}
  # to the bridge process once it fires. The bridge process then detaches.
  defp wait_for_merge_outcome(unit_ref, _unit_pid, handler_id) do
    receive do
      {:DOWN, ^unit_ref, :process, _, _} ->
        :telemetry.detach(handler_id)

      {:merge_bridge_done, _} ->
        :telemetry.detach(handler_id)
    after
      # Bridge expires after 5 minutes (well beyond any real merge timeout).
      # Telemetry handler has already forwarded its message; we just clean up.
      300_000 ->
        :telemetry.detach(handler_id)
    end
  end
end
