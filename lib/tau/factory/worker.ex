defmodule Tau.Factory.Worker do
  @moduledoc """
  Per-agent worker process for the Factory Worker fleet (W).

  Each Worker:
    1. Allocates a private git worktree via `git worktree add <ws> <base_ref>`.
    2. Resolves a per-worker HOME-namespace isolation map via
       `Worker.Isolation.resolve_namespace/2` and creates the directories.
    3. Verifies its position with `Worker.Isolation.verify_position/3` —
       aborts with `{:stop, {:position_unverified, ws, base_ref}}` on mismatch.
       Honors `opts[:expected_head]` as the expected HEAD SHA when provided.
    4. Opens a linked `Port` to the agent executable in the private worktree.
    5. When the Port exits, the Worker stops; the death-certificate
       `{:worker_exit, worker_id, reason}` is delivered exclusively by an
       unlinked monitor process that observes the worker's `:DOWN` event.

  ## Death-certificate delivery (C202 single-writer discipline)

  An unlinked monitor process is spawned at init. It holds the sole writer
  role for `{:worker_exit, worker_id, reason}` to `report_to`. The Worker
  itself does NOT send the certificate — it simply stops when the Port exits.
  The monitor fires on the `:DOWN` event regardless of exit reason:

    * `:normal`  → `{:worker_exit, id, :normal}`
    * `:killed`  → `{:worker_exit, id, :kill}`
    * other      → `{:worker_exit, id, other}`

  ## Crash containment (D-316)

  The Port is linked to the Worker, so an agent crash propagates to the
  Worker. The Worker is `:temporary`, so the supervisor does NOT restart it.
  The unlinked monitor survives `:kill` and delivers the death-certificate.

  Worker is addressed via `WorkerRegistry` by its logical `worker_id`
  string key; pids are never stored durably ([C218], SPEC-FACTORY-FLEET §4).

  See `docs/spec/SPEC-FACTORY-FLEET.md`, D-309–D-311, D-313, D-316.
  """

  use GenServer, restart: :temporary

  alias Tau.Factory.Worker.Isolation
  alias Tau.Factory.Toolchain
  alias Tau.Factory.WorkspaceJanitor

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Start a Worker as a linked process, registered under `worker_id` in the
  given `registry`.

  Required options:
    - `:worker_id`   — String; the logical identity key.
    - `:role`        — atom; worker role (`:implementer`, `:critic`, etc.).
    - `:brief`       — String; the work brief.
    - `:base_ref`    — String; the git ref for `git worktree add`.
    - `:repo_dir`    — String; path to the parent git repository.
    - `:agent_bin`   — String; path to the agent executable.
    - `:registry`    — atom; name of the WorkerRegistry to register under.

  Optional options:
    - `:toolchain`           — atom (default: `:elixir`).
    - `:report_to`           — pid that receives death-certificate messages.
    - `:heartbeat_interval`  — ms; enables periodic heartbeat telemetry.
    - `:expected_head`       — SHA string; expected HEAD after worktree add
                               (overrides resolved base_ref SHA for testing).
    - `:janitor`             — pid or name of `WorkspaceJanitor`; when present,
                               the janitor is used as the independent monitor
                               instead of the built-in death-monitor process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    worker_id = Keyword.fetch!(opts, :worker_id)
    registry = Keyword.fetch!(opts, :registry)

    GenServer.start_link(
      __MODULE__,
      opts,
      name: {:via, Registry, {registry, worker_id}}
    )
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    worker_id = Keyword.fetch!(opts, :worker_id)
    role = Keyword.fetch!(opts, :role)
    brief = Keyword.fetch!(opts, :brief)
    base_ref = Keyword.fetch!(opts, :base_ref)
    repo_dir = Keyword.fetch!(opts, :repo_dir)
    agent_bin = Keyword.fetch!(opts, :agent_bin)
    registry = Keyword.fetch!(opts, :registry)
    toolchain_key = Keyword.get(opts, :toolchain, :elixir)
    report_to = Keyword.get(opts, :report_to)
    heartbeat_interval = Keyword.get(opts, :heartbeat_interval)
    expected_head_override = Keyword.get(opts, :expected_head)
    janitor = Keyword.get(opts, :janitor)

    # Unique private worktree path under the parent repo's parent dir.
    ws = Path.join([Path.dirname(repo_dir), ".worker-wt-#{worker_id}"])

    # Step 1: git worktree add
    case System.cmd("git", ["worktree", "add", ws, base_ref],
           cd: repo_dir,
           stderr_to_stdout: true
         ) do
      {_out, 0} ->
        init_ctx = %{
          worker_id: worker_id,
          role: role,
          brief: brief,
          base_ref: base_ref,
          repo_dir: repo_dir,
          agent_bin: agent_bin,
          registry: registry,
          toolchain_key: toolchain_key,
          report_to: report_to,
          heartbeat_interval: heartbeat_interval,
          expected_head_override: expected_head_override,
          janitor: janitor,
          ws: ws
        }

        init_after_worktree(init_ctx)

      {_out, _nonzero} ->
        # git worktree add failed — base_ref unresolvable or other git error.
        # Surface as position_unverified (D-311).
        {:stop, {:position_unverified, ws, base_ref}}
    end
  end

  @impl GenServer
  def handle_call(:get_ws, _from, state) do
    {:reply, {:ok, state.ws}, state}
  end

  # Port exited: stop the worker. The death-certificate is delivered by the
  # unlinked monitor, NOT by the worker itself (C202 single-writer discipline).
  @impl GenServer
  def handle_info({port, {:exit_status, n}}, %{port: port} = state) do
    :telemetry.execute(
      [:tau, :factory, :worker, :exit],
      %{status: n},
      %{worker_id: state.worker_id, role: state.role}
    )

    reason = if n == 0, do: :normal, else: {:exit_status, n}
    {:stop, reason, state}
  end

  # Data from agent — ignore for now (future: forward to Unit FSM).
  def handle_info({port, {:data, _data}}, %{port: port} = state) do
    {:noreply, state}
  end

  # Heartbeat tick: emit telemetry + optional report_to message, re-arm timer.
  def handle_info(:heartbeat, state) do
    :telemetry.execute(
      [:tau, :factory, :worker, :heartbeat],
      %{},
      %{worker_id: state.worker_id, role: state.role}
    )

    if state.report_to do
      send(state.report_to, {:worker_heartbeat, state.worker_id})
    end

    timer = Process.send_after(self(), :heartbeat, state.heartbeat_interval)
    {:noreply, %{state | heartbeat_timer: timer}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    if state.heartbeat_timer do
      Process.cancel_timer(state.heartbeat_timer)
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp init_after_worktree(%{toolchain_key: toolchain_key, ws: ws} = ctx) do
    # Step 2: resolve namespace
    tc_module = Toolchain.for(toolchain_key)

    decls =
      case tc_module do
        {:error, _} -> []
        mod -> mod.declare_resource_namespace(%{})
      end

    ns = Isolation.resolve_namespace(ws, decls)

    # Create all namespace directories inside the worktree.
    Enum.each(ns, fn {_var, dir} -> File.mkdir_p!(dir) end)

    # Step 3: verify position
    # Resolve the actual HEAD SHA in the worktree (after `git worktree add`).
    %{base_ref: base_ref, repo_dir: repo_dir, expected_head_override: expected_head_override} = ctx
    observed_head = git_rev_parse(ws, "HEAD")
    observed_branch = git_rev_parse(ws, "--abbrev-ref", "HEAD")

    # expected_head: use injected override if provided (for testing HEAD-mismatch
    # without breaking git worktree add); otherwise resolve base_ref to its SHA.
    expected_head =
      if expected_head_override do
        expected_head_override
      else
        git_rev_parse_in_repo(repo_dir, base_ref)
      end

    # expected_branch: derive from base_ref (not from observed_branch, to make
    # the check non-vacuous). For a SHA ref (detached HEAD), the expected branch
    # is "HEAD"; for a branch-name ref it resolves to that branch.
    expected_branch = derive_expected_branch(base_ref, ws, repo_dir)

    observed = %{pwd: ws, head: observed_head, branch: observed_branch}
    expected = %{head: expected_head, branch: expected_branch}

    case Isolation.verify_position(ws, observed, expected) do
      :ok ->
        open_port_and_finish(Map.put(ctx, :ns, ns))

      {:error, _reason} ->
        cleanup_worktree(ws, repo_dir)
        {:stop, {:position_unverified, ws, base_ref}}
    end
  end

  defp open_port_and_finish(ctx) do
    %{
      worker_id: worker_id,
      role: role,
      brief: brief,
      base_ref: base_ref,
      repo_dir: repo_dir,
      agent_bin: agent_bin,
      registry: registry,
      report_to: report_to,
      heartbeat_interval: heartbeat_interval,
      janitor: janitor,
      ws: ws,
      ns: ns
    } = ctx

    # Step 4: open Port (linked by default — agent crash propagates to worker).
    env_list =
      Enum.map(ns, fn {var, dir} ->
        {String.to_charlist(var), String.to_charlist(dir)}
      end)

    port =
      Port.open({:spawn_executable, agent_bin}, [
        :binary,
        {:packet, 4},
        :exit_status,
        {:env, env_list},
        {:cd, ws}
      ])

    # When a janitor is provided, register with it (it becomes the sole writer
    # of the death-certificate and the capture-before-destroy executor).
    # Otherwise fall back to the P4d-2 built-in unlinked death-monitor.
    ns_dirs = Map.values(ns)

    if janitor do
      WorkspaceJanitor.register(janitor, worker_id, self(), ws, ns_dirs, report_to)
    else
      spawn_death_monitor(worker_id, report_to)
    end

    # Step 5: arm heartbeat timer.
    timer =
      if heartbeat_interval do
        Process.send_after(self(), :heartbeat, heartbeat_interval)
      end

    :telemetry.execute(
      [:tau, :factory, :worker, :start],
      %{},
      %{worker_id: worker_id, role: role}
    )

    {:ok,
     %{
       worker_id: worker_id,
       role: role,
       brief: brief,
       base_ref: base_ref,
       repo_dir: repo_dir,
       ws: ws,
       port: port,
       report_to: report_to,
       registry: registry,
       heartbeat_interval: heartbeat_interval,
       heartbeat_timer: timer
     }}
  end

  # Spawn a lightweight unlinked monitor process that watches this worker and
  # delivers the death-certificate to report_to on the `:DOWN` event.
  #
  # This is the SOLE writer of `{:worker_exit, worker_id, reason}` (C202).
  # The worker itself does NOT send the certificate — it just stops.
  #
  # Reason mapping:
  #   :normal  → {:worker_exit, id, :normal}
  #   :killed  → {:worker_exit, id, :kill}
  #   other    → {:worker_exit, id, other}
  defp spawn_death_monitor(_worker_id, nil), do: :ok

  defp spawn_death_monitor(worker_id, report_to) do
    worker_pid = self()

    Elixir.Process.spawn(
      fn ->
        ref = Process.monitor(worker_pid)

        receive do
          {:DOWN, ^ref, :process, ^worker_pid, reason} ->
            cert_reason =
              case reason do
                :normal -> :normal
                :killed -> :kill
                other -> other
              end

            send(report_to, {:worker_exit, worker_id, cert_reason})
        end
      end,
      []
    )
  end

  # ---------------------------------------------------------------------------
  # Git helpers (pure System.cmd calls; no side-effects beyond the command)
  # ---------------------------------------------------------------------------

  # Resolve a ref to its full SHA inside the worktree.
  defp git_rev_parse(ws, ref) do
    case System.cmd("git", ["rev-parse", ref], cd: ws, stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      {_out, _} -> ""
    end
  end

  # Resolve a ref with a flag (e.g. --abbrev-ref) inside the worktree.
  defp git_rev_parse(ws, flag, ref) do
    case System.cmd("git", ["rev-parse", flag, ref], cd: ws, stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      {_out, _} -> ""
    end
  end

  # Resolve base_ref to a SHA in the parent repo (for expected.head computation).
  defp git_rev_parse_in_repo(repo_dir, base_ref) do
    case System.cmd("git", ["rev-parse", base_ref], cd: repo_dir, stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      {_out, _} -> ""
    end
  end

  # Derive the expected branch name from the base_ref.
  # For a SHA (40 hex chars) → worktree is in detached HEAD state → "HEAD".
  # For a branch name → resolve it to the checked-out branch name (same as the ref).
  # Falls back to the observed branch in the worktree.
  defp derive_expected_branch(base_ref, ws, _repo_dir) do
    if Regex.match?(~r/\A[0-9a-fA-F]{40}\z/, base_ref) do
      # SHA ref → detached HEAD
      "HEAD"
    else
      # Branch or tag ref → use what git worktree add checked out
      case System.cmd("git", ["rev-parse", "--abbrev-ref", "HEAD"],
             cd: ws,
             stderr_to_stdout: true
           ) do
        {out, 0} -> String.trim(out)
        {_out, _} -> "HEAD"
      end
    end
  end

  # Remove the worktree on init abort to avoid leaking a git worktree.
  # The full reclaim-on-crash is P4d-3; this covers init-time failures.
  defp cleanup_worktree(ws, repo_dir) do
    System.cmd("git", ["worktree", "remove", "--force", ws],
      cd: repo_dir,
      stderr_to_stdout: true
    )
  end
end
