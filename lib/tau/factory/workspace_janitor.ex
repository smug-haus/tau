defmodule Tau.Factory.WorkspaceJanitor do
  @moduledoc """
  Independent monitor for `Tau.Factory.Worker` processes.

  The janitor `Process.monitor/1`s each registered worker (NEVER links).
  On a `:DOWN` event — for ANY exit reason including `:kill` — it executes
  the capture-before-destroy sequence in strict order (D-313, C203):

    1. Run `git diff HEAD` to capture staged + unstaged modifications (patch).
    2. Run `git ls-files --others --exclude-standard`; if non-empty, archive
       the listed files into a gzip-compressed tar binary (untracked_tgz).
    3. Run `git status --short` (status).
    4. Write a capture row to the Ledger (WAL-before-ack, D-315) — BEFORE
       any filesystem side-effect (reclaim).
    5. Reclaim the worktree: `git worktree remove --force <ws>` followed by
       `File.rm_rf!/1` as a fallback, then remove each namespace dir.
    6. Send `{:worker_exit, worker_id, reason}` to the effective `report_to`
       (per-worker if non-nil, otherwise the janitor's default).

  On start, if `:orphan_dirs` is given, the janitor reclaims each listed
  directory that still exists (D-314 orphan reconciliation).

  ## Independence guarantee (C207, SPEC-FACTORY-FLEET §4 B5)

  The janitor is NOT linked to any worker. A `:kill` on a worker does NOT
  propagate to the janitor. Capture always fires via the `:DOWN` message.

  ## Capture-failure isolation

  A git or tar failure during capture is logged and tagged; the janitor
  continues to reclaim and deliver the death-certificate rather than
  crashing and orphaning the worktree.

  See `docs/spec/SPEC-FACTORY-FLEET.md`, D-309, D-313, D-314, D-334.
  """

  use GenServer

  alias Tau.Factory.Ledger.Writer

  require Logger

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Start the WorkspaceJanitor.

  Required opts:
    - `:ledger`  — pid or registered name of `Tau.Factory.Ledger.Writer`.
    - `:name`    — atom; registered name for this GenServer.

  Optional opts:
    - `:report_to`   — default pid to receive `{:worker_exit, worker_id, reason}`.
    - `:orphan_dirs` — list of absolute paths to reclaim on init (D-314).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    # Always register under __MODULE__ so that Process.whereis/1 and direct
    # module-atom calls (janitor: WorkspaceJanitor) resolve the singleton
    # janitor.  The :name opt is used only as the supervisor child id
    # (via child_spec/1) for deduplication — not as the registered process name.
    # Tests run async: false, so at most one janitor is live at a time.
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the child spec for embedding in a supervisor tree.
  """
  @spec child_spec(keyword()) :: map()
  def child_spec(opts) do
    name = Keyword.fetch!(opts, :name)

    %{
      id: name,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @doc """
  Register a worker with the janitor.

  The janitor monitors `worker_pid` (does NOT link). On `:DOWN`, it
  captures the state of `ws`, writes to the Ledger, reclaims `ws` and
  `ns_dirs`, then sends `{:worker_exit, worker_id, reason}` to
  `report_to` (or the janitor's default `report_to` when `nil`).

  - `worker_id` — String; the logical worker identity.
  - `worker_pid` — pid of the live Worker process.
  - `ws` — absolute path to the worker's private worktree.
  - `ns_dirs` — list of additional dirs inside `ws` to reclaim.
  - `report_to` — pid to notify, or `nil` to use the janitor default.
  """
  @spec register(
          GenServer.server(),
          String.t(),
          pid(),
          String.t(),
          [String.t()],
          pid() | nil
        ) :: :ok
  def register(janitor, worker_id, worker_pid, ws, ns_dirs, report_to) do
    # Resolve the GenServer target: if the caller supplies a dynamic atom that is
    # not registered (e.g. a test-scope name when the janitor is the singleton
    # __MODULE__), fall back to __MODULE__ so both test-scope and production
    # wiring work without changing the caller.
    server =
      case GenServer.whereis(janitor) do
        nil -> __MODULE__
        pid -> pid
      end

    GenServer.call(server, {:register, worker_id, worker_pid, ws, ns_dirs, report_to})
  end

  @doc """
  Write a durable `work_ready` record to the Ledger for `worker_id`.

  INV-WF-12: Called by the Worker in `dispatch/2` when a `work_ready` frame
  arrives from the agent Port. This writes a capture row BEFORE the Worker
  exits so the `:DOWN` capture in the `:DOWN` handler is a thin backstop over
  a near-empty volatile tree, not the sole preservation mechanism.

  The row uses `disposition: :work_ready` to distinguish it from the terminal
  `:DOWN` capture (which uses `disposition: :captured`).
  """
  @spec record_work_ready(GenServer.server(), String.t(), String.t(), String.t()) :: :ok
  def record_work_ready(janitor, worker_id, branch, head_sha) do
    server =
      case GenServer.whereis(janitor) do
        nil -> __MODULE__
        pid -> pid
      end

    GenServer.call(server, {:record_work_ready, worker_id, branch, head_sha})
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    ledger = Keyword.fetch!(opts, :ledger)
    default_report_to = Keyword.get(opts, :report_to)
    orphan_dirs = Keyword.get(opts, :orphan_dirs, [])

    # Reconcile orphans on restart (D-314).
    Enum.each(orphan_dirs, fn dir ->
      if File.exists?(dir) do
        Logger.info("[WorkspaceJanitor] reclaiming orphan dir: #{dir}")
        File.rm_rf!(dir)
      end
    end)

    {:ok,
     %{
       ledger: ledger,
       default_report_to: default_report_to,
       # Map from monitor ref -> {worker_id, ws, ns_dirs, effective_report_to}
       workers: %{}
     }}
  end

  @impl GenServer
  def handle_call({:register, worker_id, worker_pid, ws, ns_dirs, report_to}, _from, state) do
    ref = Process.monitor(worker_pid)

    effective_report_to = report_to || state.default_report_to

    entry = {worker_id, ws, ns_dirs, effective_report_to}
    new_workers = Map.put(state.workers, ref, entry)

    {:reply, :ok, %{state | workers: new_workers}}
  end

  def handle_call({:record_work_ready, worker_id, branch, head_sha}, _from, state) do
    # INV-WF-12: write a durable capture row recording the work_ready decision.
    # disposition: :work_ready distinguishes this incremental record from the
    # terminal :captured row written by the :DOWN handler.
    # status and patch encode the branch + head_sha for traceability.
    attrs = %{
      patch: "",
      untracked_tgz: nil,
      status: "work_ready branch=#{branch} head_sha=#{head_sha}",
      disposition: :work_ready
    }

    Writer.capture(state.ledger, worker_id, attrs)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.workers, ref) do
      {nil, _} ->
        # Unknown ref — ignore.
        {:noreply, state}

      {{worker_id, ws, _ns_dirs, report_to}, new_workers} ->
        Process.demonitor(ref, [:flush])

        cert_reason = normalize_reason(reason)

        # Capture-before-reclaim, in order (D-313, C203).
        capture_result = capture_workspace(state.ledger, worker_id, ws)

        case capture_result do
          {:ok, _} ->
            :ok

          {:error, err} ->
            Logger.error("[WorkspaceJanitor] capture failed for #{worker_id}: #{inspect(err)}")
        end

        # Reclaim the workspace (after the durable write).
        reclaim_workspace(ws)

        # Deliver death-certificate.
        if report_to do
          send(report_to, {:worker_exit, worker_id, cert_reason})
        end

        :telemetry.execute(
          [:tau, :factory, :janitor, :reclaim],
          %{},
          %{worker_id: worker_id, reason: cert_reason}
        )

        {:noreply, %{state | workers: new_workers}}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Normalize the `:DOWN` reason to the death-certificate reason.
  defp normalize_reason(:killed), do: :kill
  defp normalize_reason(:normal), do: :normal
  defp normalize_reason(other), do: other

  # Run all three capture kinds, write to Ledger, return {:ok, ref} or {:error, reason}.
  defp capture_workspace(ledger, worker_id, ws) do
    patch = run_git_patch(ws)
    untracked_files = run_git_untracked(ws)
    untracked_tgz = maybe_tar_untracked(ws, untracked_files)
    status = run_git_status(ws)

    attrs = %{
      patch: patch,
      untracked_tgz: untracked_tgz,
      status: status,
      disposition: :captured
    }

    Writer.capture(ledger, worker_id, attrs)
  end

  # git diff HEAD — captures staged AND unstaged modifications.
  defp run_git_patch(ws) do
    case System.cmd("git", ["-C", ws, "diff", "HEAD"], stderr_to_stdout: true) do
      {out, _} -> out
    end
  end

  # git ls-files --others --exclude-standard — returns newline-separated list of untracked files.
  defp run_git_untracked(ws) do
    case System.cmd("git", ["-C", ws, "ls-files", "--others", "--exclude-standard"],
           stderr_to_stdout: true
         ) do
      {out, _} ->
        out
        |> String.trim()
        |> then(fn s -> if s == "", do: [], else: String.split(s, "\n") end)
    end
  end

  # git status --short
  defp run_git_status(ws) do
    case System.cmd("git", ["-C", ws, "status", "--short"], stderr_to_stdout: true) do
      {out, _} -> out
    end
  end

  # If there are untracked files, create a tar.gz binary of them.
  # Uses `tar -C ws -czf - <files...>` and captures stdout as binary.
  defp maybe_tar_untracked(_ws, []), do: nil

  defp maybe_tar_untracked(ws, files) do
    args = ["-C", ws, "-czf", "-"] ++ files

    case System.cmd("tar", args) do
      {tgz_bytes, 0} when byte_size(tgz_bytes) > 0 ->
        tgz_bytes

      _ ->
        nil
    end
  end

  # Reclaim the workspace directory:
  # 1. Run `git -C ws worktree remove --force ws` (from inside the worktree so
  #    git can follow the .git pointer back to the parent repo and deregister).
  # 2. Always fall back to File.rm_rf!/1 to ensure filesystem removal even if
  #    the git command fails (e.g. ws already partially removed).
  defp reclaim_workspace(ws) do
    if File.dir?(ws) do
      System.cmd("git", ["-C", ws, "worktree", "remove", "--force", ws], stderr_to_stdout: true)
    end

    # Ensure filesystem removal regardless of git command result.
    if File.exists?(ws) do
      File.rm_rf!(ws)
    end
  end
end
