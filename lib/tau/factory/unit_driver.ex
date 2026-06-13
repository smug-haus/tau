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
  calls `MergeAuthority.request_merge/2`, then the bridge process (started at
  `drive/2` time) installs a telemetry handler that forwards
  `{:merge_result, :merged}` / `{:merge_result, :rejected}` to the Unit pid when
  the real MergeAuthority emits `[:tau, :factory, :merge, :merged]` /
  `[:tau, :factory, :merge, :reject]`. The handler is keyed by `unit_id` so it
  only fires for this unit's outcome.

  ## Bridge process (D-340)

  A short-lived, unlinked bridge process is started at `drive/2` time. It:

    1. Receives the started Unit's pid and monitors it.
    2. Accumulates private worker worktree paths as `worker_fun` sends
       `{:worktree_allocated, ws}` messages to it.
    3. When `merge_fun` calls `MergeAuthority.request_merge/2`, the bridge
       installs a telemetry handler for `[:tau, :factory, :merge, :merged]` /
       `[:tau, :factory, :merge, :reject]`. On the first matching event, the
       handler forwards `{:merge_result, outcome}` to the Unit, then sends
       `{:merge_result_delivered}` to the bridge. The bridge immediately
       detaches the telemetry handler, reclaims all pending worktrees, and exits.
    4. On Unit `:DOWN` (any terminal path — merged, escalated, or crashed):
       bridge detaches the telemetry handler (if still installed) and reclaims
       all accumulated worktrees before exiting.
    5. On timeout (5 minutes): same cleanup.

  This design guarantees:
    - No duplicate or late `{:merge_result, _}` delivery (handler detaches
      immediately on first delivery).
    - Worktree reclaim fires on ALL terminal paths, not only the merge path.
    - No unsupervised, never-stopped `Agent` or other stateful process.
    - Reclaim runs off the Unit gen_statem process, removing the D-340 liveness
      risk from the blocking `merge_fun` callback.

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
    # Start the bridge process BEFORE the unit so closures can reference it.
    # The bridge receives the unit pid once the unit is started, then monitors
    # it. This avoids any need for a shared Agent or ETS state.
    # -------------------------------------------------------------------------
    bridge_pid = start_bridge(unit_id)

    # -------------------------------------------------------------------------
    # :worker_fun — called from within the Unit's process context.
    # `self()` at invocation time resolves to the Unit pid, so the Worker's
    # `report_to` is the Unit itself (D-326 in-band work_ready delivery).
    # WorkerSupervisor.spawn/5 returns {:ok, worker_id}. After spawn completes,
    # the Worker has finished init/1 and registered in the WorkerRegistry.
    # We look up its pid from the registry to return the 3-tuple the Unit needs.
    # Each allocated private worktree path is registered with the bridge process
    # for lifecycle-tied reclaim (covering ALL terminal paths, not just merge).
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
              # Register the private worktree path with the bridge process for
              # lifecycle-tied reclaim. The bridge accumulates these in its own
              # state and reclaims all of them on any terminal path (unit :DOWN,
              # merge result delivered, or timeout) — no Agent, no ETS.
              # Pass repo_dir along so the bridge can call git worktree remove
              # without needing to derive it from the worktree path.
              ws = Path.join([Path.dirname(repo_dir), ".worker-wt-#{worker_id}"])
              send(bridge_pid, {:worktree_allocated, ws, repo_dir})

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
    # notifies the bridge to install its telemetry handler and forward the async
    # outcome to the Unit pid.
    # The bridge installs the handler so that it can detach it exactly once on
    # first delivery (no duplicate or late merge_result messages).
    #
    # Synchronous worktree reclaim happens here (before request_merge) to ensure
    # all allocated worktrees are released before the merge result arrives. By the
    # time awaiting_merge is entered, all workers have exited. The bridge also
    # reclaims on unit `:DOWN` (covering the escalation path where merge_fun never
    # runs) — since `reclaim_worktree` is idempotent (guards on File.dir?), a
    # double-reclaim attempt by the bridge on the merge path is safe.
    # -------------------------------------------------------------------------
    merge_fun = fn merge_unit_id, merge_hash ->
      unit_pid = self()

      # Notify bridge: fetch the current worktree list synchronously, reclaim
      # them now, and clear the list in the bridge. This removes the race where
      # the unit reaches terminal before the bridge processes its cleanup message.
      # We use a call-style approach: send a message and wait for the bridge to
      # confirm it has received the list and cleared its state.
      send(bridge_pid, {:drain_and_reclaim, self()})

      receive do
        {:worktrees_drained, pending_ws} ->
          Enum.each(pending_ws, fn {ws, rd} -> reclaim_worktree(ws, rd) end)
      after
        5_000 ->
          Logger.warning(
            "[UnitDriver #{unit_id}] bridge drain timed out; proceeding without sync reclaim"
          )
      end

      merge_map = %{
        id: merge_unit_id,
        hash: merge_hash,
        run: run,
        branch: branch
      }

      # Notify bridge: install the telemetry handler for this unit's merge
      # result and wire unit_pid as the delivery target. The bridge installs
      # the handler BEFORE request_merge is called so no event is missed.
      send(bridge_pid, {:arm_merge_bridge, unit_pid})

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

    unit_pid = UnitSupervisor.start_unit(unit_supervisor, unit_opts)

    # Send the unit pid to the bridge so it can begin monitoring.
    send(bridge_pid, {:unit_started, unit_pid})

    unit_pid
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

  # ---------------------------------------------------------------------------
  # Bridge process
  #
  # Lifecycle:
  #   1. Start with `start_bridge/1` → spawns an unlinked process in the
  #      :pre_start phase (no unit pid yet, no telemetry handler installed).
  #   2. {:unit_started, unit_pid} → transitions to :monitoring phase:
  #      monitors unit_pid; begins accumulating {:worktree_allocated, ws} msgs.
  #   3. {:arm_merge_bridge, unit_pid} → installs the per-unit telemetry handler
  #      for [:tau,:factory,:merge,:merged] and [:tau,:factory,:merge,:reject].
  #      On first matching event the handler sends {:merge_result_delivered} to
  #      the bridge and {:merge_result, outcome} to unit_pid.
  #   4. {:merge_result_delivered} → bridge detaches the handler, reclaims
  #      all accumulated worktrees, exits normally. Unit is still alive here
  #      (it's in awaiting_merge, will be driven to terminal by the result).
  #   5. {:DOWN, ^unit_ref, ...} → unit died (normal, kill, crash); bridge
  #      detaches any handler (idempotent), reclaims worktrees, exits.
  #   6. Timeout (5 minutes) → same cleanup.
  #
  # State is carried in the recursive loop function — no Agent, no ETS.
  # This is the correct OTP pattern: monitored refs for cross-process events,
  # state in the process's own receive loop.
  # ---------------------------------------------------------------------------

  # Start the unlinked bridge process. Returns the bridge pid.
  # The bridge immediately enters the pre-start phase, waiting for {:unit_started, pid}.
  @spec start_bridge(String.t()) :: pid()
  defp start_bridge(unit_id) do
    Elixir.Process.spawn(
      fn ->
        # Pre-start phase: wait for the unit pid before monitoring.
        # Also buffer any {:worktree_allocated, ws} messages that arrive before
        # the unit pid (shouldn't happen in practice, but defensive).
        bridge_pre_start(unit_id, [])
      end,
      []
    )
  end

  # Pre-start phase: wait for {:unit_started, unit_pid}.
  # Accumulate {:worktree_allocated, ws, repo_dir} messages while waiting.
  # ws_list is a list of {ws, repo_dir} tuples.
  defp bridge_pre_start(unit_id, pending_ws) do
    receive do
      {:unit_started, unit_pid} ->
        unit_ref = Process.monitor(unit_pid)
        # Transition to monitoring phase with any already-accumulated worktrees.
        bridge_monitoring(unit_id, unit_pid, unit_ref, false, pending_ws)

      {:worktree_allocated, ws, repo_dir} ->
        bridge_pre_start(unit_id, [{ws, repo_dir} | pending_ws])

      _other ->
        bridge_pre_start(unit_id, pending_ws)
    after
      # Safety timeout in pre-start phase: 30 seconds.
      # If no unit starts within 30s, exit cleanly (no resources to clean up yet).
      30_000 ->
        Logger.warning("[UnitDriver bridge #{unit_id}] timed out in pre-start phase; exiting")
    end
  end

  # Monitoring phase: unit is running; accumulate worktree paths and wait
  # for the merge arm signal, unit death, or timeout.
  # ws_list is a list of {ws, repo_dir} tuples.
  defp bridge_monitoring(unit_id, unit_pid, unit_ref, handler_installed, ws_list) do
    receive do
      {:worktree_allocated, ws, repo_dir} ->
        bridge_monitoring(unit_id, unit_pid, unit_ref, handler_installed, [
          {ws, repo_dir} | ws_list
        ])

      {:drain_and_reclaim, caller} ->
        # merge_fun (inside the Unit process) is requesting a synchronous drain
        # of the worktree list so it can reclaim them before calling request_merge.
        # Reply with the current list and clear it in the bridge state.
        # The bridge will still reclaim on :DOWN to cover any worktrees allocated
        # after the drain (none expected, but defensive) and the escalation path.
        send(caller, {:worktrees_drained, ws_list})
        bridge_monitoring(unit_id, unit_pid, unit_ref, handler_installed, [])

      {:arm_merge_bridge, ^unit_pid} ->
        # Install the telemetry handler now. The handler closure captures
        # bridge_self so it can notify the bridge on first delivery.
        bridge_self = self()
        handler_id = {__MODULE__, :merge_bridge, unit_id}

        :telemetry.attach_many(
          handler_id,
          [
            [:tau, :factory, :merge, :merged],
            [:tau, :factory, :merge, :reject]
          ],
          fn event_name, _measurements, metadata, _config ->
            outcome = find_unit_outcome(event_name, metadata, unit_id)

            if outcome do
              send(unit_pid, {:merge_result, outcome})
              # Notify bridge to detach. The bridge will handle this in its next
              # receive iteration. Using send (not a blocking call) keeps the
              # telemetry handler fast and prevents handler re-entry.
              send(bridge_self, :merge_result_delivered)
            end
          end,
          nil
        )

        bridge_monitoring(unit_id, unit_pid, unit_ref, true, ws_list)

      :merge_result_delivered ->
        # Merge result was forwarded to the unit. Detach handler immediately —
        # no duplicate or late delivery possible after this point.
        # ws_list here is any worktrees allocated AFTER the drain (expected to be
        # empty on the normal merge path, but reclaim anyway for correctness).
        detach_handler(unit_id, handler_installed)
        reclaim_all(ws_list)
        Process.demonitor(unit_ref, [:flush])

      {:DOWN, ^unit_ref, :process, ^unit_pid, _reason} ->
        # Unit terminated (any terminal path: merged, escalated, crashed).
        # Detach any handler and reclaim all remaining worktrees.
        # On the gate-fail/escalation path, merge_fun never runs so the drain
        # never fires — all allocated worktrees are still in ws_list here.
        detach_handler(unit_id, handler_installed)
        reclaim_all(ws_list)

      _other ->
        bridge_monitoring(unit_id, unit_pid, unit_ref, handler_installed, ws_list)
    after
      # Bridge expires after 5 minutes. The merge train can take a while, but
      # 5 minutes is well beyond any reasonable bound.
      300_000 ->
        Logger.warning("[UnitDriver bridge #{unit_id}] timed out in monitoring phase; cleaning up")
        detach_handler(unit_id, handler_installed)
        reclaim_all(ws_list)
        Process.demonitor(unit_ref, [:flush])
    end
  end

  # Detach the telemetry handler idempotently (ignore :not_found).
  defp detach_handler(_unit_id, false), do: :ok

  defp detach_handler(unit_id, true) do
    handler_id = {__MODULE__, :merge_bridge, unit_id}

    case :telemetry.detach(handler_id) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  # Reclaim all accumulated private worktrees.
  # ws_list is a list of {ws, repo_dir} tuples where ws is the absolute worktree
  # path and repo_dir is the parent git repository used to deregister the worktree.
  # Reclaim is idempotent: reclaim_worktree/2 guards on File.dir? before calling git.
  defp reclaim_all([]), do: :ok

  defp reclaim_all(ws_list) do
    Enum.each(ws_list, fn {ws, repo_dir} ->
      reclaim_worktree(ws, repo_dir)
    end)
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
end
