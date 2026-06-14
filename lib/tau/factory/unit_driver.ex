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
  `worker_fun` is always called from within the Unit process). Threads the
  `:janitor` dep into the spawn opts so the `WorkspaceJanitor` monitors each
  Worker and reclaims its private worktree on every `:DOWN` (D-313/D-314). The
  driver performs ZERO worktree reclaim of its own. Returns the 3-tuple
  `{:ok, worker_pid, worker_id}` so the Unit can gate `implementing → gating`
  on the D-326 `{:work_ready, ^worker_id, _, _}` event.

  **`:gate_fun`** — passed through directly from `deps.gate_fun`. The Coordinator
  may inject a hermetic gate for testing; the driver also accepts a real
  `Gate.run/1` closure here.

  **`:merge_fun`** — builds `%{id: unit_id, hash: hash, run: run, branch: branch}`
  and calls `MergeAuthority.request_merge/2`. Returns `:queued | {:error, reason}`.
  The async merge result is delivered the real way: a `Phoenix.PubSub.broadcast/3`
  of `{:merge_result, :merged | :rejected}` to `"factory:pr:\#{unit_id}"` on the
  shared `Tau.PubSub` (D-356), emitted by `MergeAuthority` on every terminal
  outcome. The Unit subscribes to that topic on `awaiting_merge` entry (before
  calling `merge_fun`) and unsubscribes on every exit. There is NO driver-side
  telemetry→Unit bridge — that design is FORBIDDEN by D-356.

  ## D-356 delivery contract

  The Unit handles the async merge result through its own PubSub subscription.
  The driver does NOT bridge, re-derive, or forward the result. Reclaim of private
  worker worktrees is the `WorkspaceJanitor`'s exclusive responsibility (D-313/14),
  triggered by the janitor's `:DOWN` monitor on every worker exit — not a
  driver-side reclaim and not tied to the merge path.

  ## D-340 terminal report

  The Unit itself sends `{:unit_terminal, unit_id, outcome, provenance}` to
  `deps.report_to` on reaching a terminal state. The driver does not emit that
  message — it wires the seams and starts the Unit.

  See `docs/spec/SPEC-FACTORY-CORE.md` §4 B6, B8, D-340, D-356;
  `docs/spec/SPEC-FACTORY-MERGE.md` §6 D-356.
  """

  alias Tau.Factory.MergeAuthority
  alias Tau.Factory.UnitSupervisor
  alias Tau.Factory.WorkerSupervisor
  alias Tau.Factory.WorkspaceJanitor

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
    * `:janitor`           — atom/pid of a running `WorkspaceJanitor`; threaded
                             into the worker spawn opts so the janitor monitors
                             each Worker and reclaims its worktree on `:DOWN`
                             (D-313/D-314). The driver performs ZERO reclaim.
    * `:pubsub`            — the shared `Phoenix.PubSub` instance (`Tau.PubSub`);
                             threaded into the Unit opts so the Unit subscribes to
                             `"factory:pr:\#{unit_id}"` on `awaiting_merge` entry
                             (D-356 subscribe-before-request).
    * `:repo_dir`          — `String.t()`; the parent git repo for worker
                             worktrees.
    * `:agent_bin`         — `String.t()`; the agent executable each worker runs.
    * `:gate_fun`          — `(coordinate :: String.t() -> :pass | {:fail, findings})`; injected
                             gate seam (passed through to the Unit unchanged). The Unit
                             supplies the coordinate (`data.head_sha || data.hash`) at
                             call time (D-361 symmetric with merge).
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
      pubsub: pubsub,
      repo_dir: repo_dir,
      agent_bin: agent_bin,
      gate_fun: gate_fun,
      merge_authority: merge_authority,
      report_to: report_to
    } = deps

    ledger = Map.get(deps, :ledger, nil)
    # unit_timeouts: optional keyword list of per-state Unit timeout overrides
    # (D-358 / SPEC-FACTORY-CORE §4 B11). Threaded into Unit's :timeouts opt
    # so the dogfood can widen state_timeout_ms above the scripted agent's
    # worst-case run time without modifying unit.ex.
    unit_timeouts = Map.get(deps, :unit_timeouts, [])
    # agent_mode / creds_check_fun: threaded from AgentBin.resolve/1 spawn_opts
    # (via supervisor_opts / UnitDriver deps) into the worker_fun closure so the
    # Worker's D-374 preflight fires for :claude_code mode (D-376 refine fix).
    # Non-:claude_code paths: agent_mode is nil/absent → preflight skipped (unchanged).
    agent_mode = Map.get(deps, :agent_mode)
    creds_check_fun = Map.get(deps, :creds_check_fun)

    # -------------------------------------------------------------------------
    # :worker_fun — called from within the Unit's process context.
    # `self()` at invocation time resolves to the Unit pid, so the Worker's
    # `report_to` is the Unit itself (D-326 in-band work_ready delivery).
    # WorkerSupervisor.spawn/5 returns {:ok, worker_id}. After spawn completes,
    # the Worker has finished init/1 and registered in the WorkerRegistry.
    # We look up its pid from the registry to return the 3-tuple the Unit needs.
    #
    # `:janitor` is threaded into the spawn opts so the WorkspaceJanitor monitors
    # the spawned Worker and reclaims its private worktree on every :DOWN
    # (D-313/D-314, SPEC-FACTORY-FLEET). The driver performs ZERO reclaim.
    #
    # WorkspaceJanitor always registers itself under its module name
    # (Tau.Factory.WorkspaceJanitor) regardless of the :name supervision opt.
    # Resolve the pid now so the Worker's GenServer.call targets a live pid
    # rather than the supervision-id atom which may differ.
    # -------------------------------------------------------------------------
    # Resolve the janitor: prefer the explicit deps[:janitor] injection (the
    # test-injection seam per B8/#479); fall back to the singleton
    # WorkspaceJanitor (always registered under __MODULE__). Driver-side reclaim
    # is ZERO — the janitor exclusively owns capture-before-destroy (D-313/D-314).
    janitor_pid = deps[:janitor] || WorkspaceJanitor

    # oracle_base_ref: optional per-work_item override for the oracle
    # (test_author) worker's checkout ref. When provided, the oracle Worker
    # checks out `oracle_base_ref` instead of `base_ref`. This lets harnesses
    # (e.g. the dogfood) put the oracle Worker in detached HEAD mode (via
    # `origin/<branch>`) so it does not lock the named branch, allowing the
    # implementing Worker to checkout the named branch without conflict.
    # Defaults to `base_ref` (existing single-ref behaviour).
    oracle_base_ref = Map.get(work_item, :oracle_base_ref, base_ref)

    worker_fun = fn role ->
      unit_pid = self()

      wr_base_ref = if role == :test_author, do: oracle_base_ref, else: base_ref

      base_opts = [
        registry: worker_registry,
        repo_dir: repo_dir,
        agent_bin: agent_bin,
        report_to: unit_pid,
        janitor: janitor_pid
      ]

      # Thread agent_mode and creds_check_fun (D-376 refine: closes the
      # orphaned-fence gap so :claude_code fires D-374 preflight in Worker).
      # agent_mode nil/absent → no key added → Worker preflight skipped (unchanged).
      opts =
        base_opts
        |> then(fn o -> if agent_mode, do: Keyword.put(o, :agent_mode, agent_mode), else: o end)
        |> then(fn o ->
          if creds_check_fun, do: Keyword.put(o, :creds_check_fun, creds_check_fun), else: o
        end)

      case WorkerSupervisor.spawn(worker_supervisor, role, brief, wr_base_ref, opts) do
        {:ok, worker_id} ->
          case resolve_worker_pid(worker_registry, worker_id) do
            {:ok, worker_pid} ->
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
    # :merge_fun — called from the Unit's awaiting_merge state (after the Unit
    # has already subscribed to "factory:pr:#{unit_id}" on Tau.PubSub — the
    # subscribe-before-request ordering is enforced by Unit.awaiting_merge/3).
    # Builds the exact merge map and calls MergeAuthority.request_merge/2.
    # Returns :queued | {:error, reason}. The async result arrives later as a
    # Phoenix.PubSub broadcast of {:merge_result, :merged | :rejected} to the
    # per-PR topic — emitted by MergeAuthority on every terminal outcome (D-356).
    # There is NO bridge, NO telemetry handler, NO direct send to the unit pid.
    # -------------------------------------------------------------------------
    merge_fun = fn merge_unit_id, merge_hash ->
      merge_map = %{
        id: merge_unit_id,
        hash: merge_hash,
        run: run,
        branch: branch
      }

      MergeAuthority.request_merge(merge_authority, merge_map)
    end

    # -------------------------------------------------------------------------
    # Start the Unit under the UnitSupervisor with all seams wired.
    # `:pubsub` is threaded in so the Unit subscribes to "factory:pr:#{unit_id}"
    # before calling merge_fun (D-356 subscribe-before-request ordering).
    # -------------------------------------------------------------------------
    unit_opts = [
      unit_id: unit_id,
      declared_scope: declared_scope,
      hash: hash,
      scheduler: scheduler,
      report_to: report_to,
      pubsub: pubsub,
      worker_fun: worker_fun,
      gate_fun: gate_fun,
      merge_fun: merge_fun,
      ledger: ledger,
      registry_name: unit_registry,
      timeouts: unit_timeouts
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
end
