defmodule Tau.Factory.Worker do
  @moduledoc """
  Per-agent worker process for the Factory Worker fleet (W).

  Each Worker:
    1. Allocates a private git worktree via `git worktree add <ws> <base_ref>`.
    2. Resolves a per-worker HOME-namespace isolation map via
       `Worker.Isolation.resolve_namespace/2` and creates the directories.
    3. Verifies its position with `Worker.Isolation.verify_position/3` —
       aborts with `{:stop, {:position_unverified, ws, base_ref}}` on mismatch.
    4. Opens a linked `Port` to the agent executable in the private worktree.
    5. When the Port exits (clean or crash), sends
       `{:worker_exit, worker_id, reason}` to `report_to` and stops normally.

  ## Port exit — drain window

  When the Port exits (agent done or crashed), the Worker does NOT stop
  immediately. Instead it enters a brief drain window (`@drain_ms`, default
  250 ms) during which it remains alive and registered. After the drain
  window it sends the death certificate and stops normally.

  The drain window exists so that callers can look up the worker's pid from
  the registry RIGHT after spawning, even when a fast-exiting dummy agent
  causes the Port to exit before the test's next statement runs. Without the
  drain, a 56-scheduler BEAM would race the GenServer exit against the
  caller's Registry.lookup, producing flaky failures.

  The drain window is an intentional implementation choice for P4d-2. The
  WorkspaceJanitor (P4d-3) provides the authoritative reclaim-on-exit path;
  the drain window is a bounded delay, not a permanent hold.

  ## Crash containment (D-316)

  The Port is linked to the Worker, so an agent crash propagates to the
  Worker. The Worker is `:temporary`, so the supervisor does NOT restart it.
  A death-certificate `{:worker_exit, worker_id, reason}` is delivered to
  `report_to` on ALL exit types including `:kill`, via a lightweight monitor
  spawned at init (the full WorkspaceJanitor with capture-before-destroy is
  P4d-3).

  Worker is addressed via `WorkerRegistry` by its logical `worker_id`
  string key; pids are never stored durably ([C218], SPEC-FACTORY-FLEET §4).

  See `docs/spec/SPEC-FACTORY-FLEET.md`, D-309–D-311, D-313, D-316.
  """

  use GenServer, restart: :temporary

  alias Tau.Factory.Worker.Isolation
  alias Tau.Factory.Toolchain

  # Drain window in ms: the worker stays alive this long after Port exit
  # before sending the death certificate and stopping. This prevents a race
  # between fast-exiting agents and Registry.lookup in callers.
  @drain_ms 250

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
          ws: ws
        }

        init_after_worktree(init_ctx)

      {_out, _nonzero} ->
        # git worktree add failed — base_ref unresolvable or other git error.
        # Surface as position_unverified (D-311).
        {:stop, {:position_unverified, ws, base_ref}}
    end
  end

  # Port exited: enter drain window (@drain_ms), then send death cert and stop.
  @impl GenServer
  def handle_info({port, {:exit_status, n}}, %{port: port} = state) do
    reason = if n == 0, do: :normal, else: {:exit_status, n}

    :telemetry.execute(
      [:tau, :factory, :worker, :exit],
      %{status: n},
      %{worker_id: state.worker_id, role: state.role}
    )

    # Schedule the drain-window expiry. The worker stays alive until then.
    Process.send_after(self(), {:drain_expired, reason}, @drain_ms)
    {:noreply, %{state | port: nil}}
  end

  # Drain window expired: send death certificate and stop normally.
  def handle_info({:drain_expired, reason}, state) do
    if state.report_to do
      send(state.report_to, {:worker_exit, state.worker_id, reason})
    end

    {:stop, :normal, state}
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
    %{base_ref: base_ref, repo_dir: repo_dir} = ctx
    observed_head = git_rev_parse(ws, "HEAD")
    observed_branch = git_rev_parse(ws, "--abbrev-ref", "HEAD")
    expected_head = git_rev_parse_in_repo(repo_dir, base_ref)

    observed = %{pwd: ws, head: observed_head, branch: observed_branch}
    expected = %{head: expected_head, branch: observed_branch}

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

    # Arm a monitor so we deliver death-certificate on :kill (drain_expired
    # covers normal exits; monitor covers forced kills where terminate/2
    # does not run).
    spawn_death_monitor(worker_id, report_to)

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

  # Spawn a lightweight monitor process that watches this worker and delivers
  # the death-certificate to report_to on forced exits (:kill).
  #
  # Normal Port exits are handled via the drain_expired path above. The monitor
  # only delivers for reasons OTHER than :normal and :shutdown (which are
  # drain-path exits). This prevents double-delivery for normal Port exits.
  defp spawn_death_monitor(_worker_id, nil), do: :ok

  defp spawn_death_monitor(worker_id, report_to) do
    worker_pid = self()

    spawn(fn ->
      ref = Process.monitor(worker_pid)

      receive do
        {:DOWN, ^ref, :process, ^worker_pid, reason} ->
          case reason do
            # These reasons indicate a drain-path or graceful stop;
            # the drain_expired handler already sent (or will send) the cert.
            :normal -> :ok
            :shutdown -> :ok
            # Forced kill — drain_expired will NOT run; we are the sole cert path.
            :killed -> send(report_to, {:worker_exit, worker_id, :kill})
            # Any other exit reason (e.g. a crash) — deliver verbatim.
            other -> send(report_to, {:worker_exit, worker_id, other})
          end
      end
    end)
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

  # Remove the worktree on init abort to avoid leaking a git worktree.
  # The full reclaim-on-crash is P4d-3; this covers init-time failures.
  defp cleanup_worktree(ws, repo_dir) do
    System.cmd("git", ["worktree", "remove", "--force", ws],
      cd: repo_dir,
      stderr_to_stdout: true
    )
  end
end
