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
  alias Tau.Provider.Event.Heartbeat
  alias Tau.Provider.Event.WorkReady
  alias Tau.Providers.Anthropic.Auth

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
    - `:extra_env`           — list of `{key, value}` string pairs merged into
                               the Port's env AFTER the namespace map (D-365).
    - `:agent_mode`          — atom (default: `nil`); when `:claude_code`, the
                               D-374 preflight fires before `Port.open`: runs
                               `creds_check_fun.()` and appends
                               `{~c"ANTHROPIC_API_KEY", false}`,
                               `{~c"ANTHROPIC_AUTH_TOKEN", false}`, and
                               `{~c"ANTHROPIC_BASE_URL", false}` to the Port env
                               so the child never inherits any metered Anthropic
                               credential. Any other value (including absent)
                               disables the preflight (non-`:claude_code` modes
                               unchanged).
    - `:creds_check_fun`     — zero-arity function
                               `(-> :ok | {:error, :subscription_creds_absent})`.
                               Default checks `~/.claude/.credentials.json` via
                               `Tau.Providers.Anthropic.Auth`. Tests inject a
                               stub. (D-374)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    worker_id = Keyword.fetch!(opts, :worker_id)
    registry = Keyword.fetch!(opts, :registry)
    role = Keyword.fetch!(opts, :role)
    author_id = Keyword.get(opts, :author_id)

    # Register with metadata so the Gate and WorkerSupervisor can query
    # author identity per HR-7 (D-304 oracle-separation sub-mechanism (b)).
    metadata = %{role: role, author_id: author_id}

    GenServer.start_link(
      __MODULE__,
      opts,
      name: {:via, Registry, {registry, worker_id, metadata}}
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
    extra_env = Keyword.get(opts, :extra_env, [])
    agent_mode = Keyword.get(opts, :agent_mode)
    creds_check_fun = Keyword.get(opts, :creds_check_fun, &default_creds_check/0)

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
          extra_env: extra_env,
          agent_mode: agent_mode,
          creds_check_fun: creds_check_fun,
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
  #
  # D-326 fail-closed: exit-0 WITHOUT a prior work_ready is a semantic
  # non-completion. We stop with {:shutdown, :no_work_product} so the
  # independent monitor maps that to {:worker_exit, worker_id, :no_work_product}.
  # A normal exit AFTER work_ready is unchanged (just :normal).
  @impl GenServer
  def handle_info({port, {:exit_status, n}}, %{port: port} = state) do
    :telemetry.execute(
      [:tau, :factory, :worker, :exit],
      %{status: n},
      %{worker_id: state.worker_id, role: state.role}
    )

    reason =
      cond do
        n == 0 and not state.work_ready_seen? -> {:shutdown, :no_work_product}
        n == 0 -> :normal
        true -> {:exit_status, n}
      end

    {:stop, reason, state}
  end

  # Data from the agent: decode the {packet,4}-framed JSON into a typed event
  # and dispatch. D-326: a work_ready frame is forwarded to report_to exactly
  # ONCE and sets work_ready_seen? true (single-writer discipline, mirrors
  # independent monitor's sole ownership of worker_exit).
  def handle_info({port, {:data, frame}}, %{port: port} = state) do
    new_state = dispatch(decode_event(frame), state)
    {:noreply, new_state}
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
    %{
      base_ref: base_ref,
      repo_dir: repo_dir,
      expected_head_override: expected_head_override
    } = ctx

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
      repo_dir: repo_dir,
      report_to: report_to,
      janitor: janitor,
      ws: ws,
      ns: ns
    } = ctx

    extra_env = Map.get(ctx, :extra_env, [])
    agent_mode = Map.get(ctx, :agent_mode)
    creds_check_fun = Map.get(ctx, :creds_check_fun, &default_creds_check/0)

    # Step 4: register with the janitor BEFORE opening the Port, so that any
    # raise during Port.open is caught by the janitor's :DOWN handler — no
    # unmonitored worktree leak (D-314, SPEC B5). The monitor is also set up
    # before the D-374 preflight so that a :metered_path_refused stop delivers
    # a death-cert to report_to (D-374).
    #
    # D-313 (fail-closed): the janitor is mandatory infrastructure for
    # capture-before-destroy (INV-14). A nil janitor bypasses the capture path
    # entirely (spawn_death_monitor sends only {:worker_exit, ...} with zero git
    # capture). Per the D-374 precedent (infra prerequisites rejected at init),
    # Worker MUST stop with :no_janitor when no janitor is provided so the
    # WorkerSupervisor propagates {:error, :no_janitor} to the caller.
    if is_nil(janitor) do
      cleanup_worktree(ws, repo_dir)
      {:stop, :no_janitor}
    else
      ns_dirs = Map.values(ns)
      WorkspaceJanitor.register(janitor, worker_id, self(), ws, ns_dirs, report_to)

      # D-374: metered-API spend preflight — runs only for agent_mode: :claude_code.
      # If creds_check_fun returns {:error, _} the worker refuses to open the Port
      # and stops with :metered_path_refused (fail-closed; NO fallback).
      # The death-cert monitor (spawned above) delivers
      # {:worker_exit, worker_id, :metered_path_refused} to report_to.
      case preflight_metered(agent_mode, creds_check_fun) do
        :ok ->
          open_port_final(ctx, ns, extra_env, agent_mode, ws, repo_dir)

        {:stop, :metered_path_refused} ->
          cleanup_worktree(ws, repo_dir)
          {:stop, :metered_path_refused}
      end
    end
  end

  defp open_port_final(ctx, ns, extra_env, agent_mode, _ws, _repo_dir) do
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
      ws: ws
    } = ctx

    # Step 5: open Port (linked by default — agent crash propagates to worker).
    # Build env_list from namespace map, then merge any extra_env overrides
    # (D-365: extra_env allows per-worker isolation keys to be injected by
    # the caller, e.g. a test-supplied XDG_DATA_HOME probe path).
    ns_env =
      Enum.map(ns, fn {var, dir} ->
        {String.to_charlist(var), String.to_charlist(dir)}
      end)

    extra_env_charlist =
      Enum.map(extra_env, fn {k, v} ->
        {String.to_charlist(k), String.to_charlist(v)}
      end)

    # D-374 env scrub: when agent_mode is :claude_code, append all three
    # metered-spend variables with {key, false} so the child process never
    # inherits any metered Anthropic credential from the calling env.
    # Erlang Port {:env, list} is additive; appending {key, false} removes
    # an inherited var (POSIX: unsetenv semantics via Erlang's child_setup).
    #
    # Scrubbed variables (all three are metered-spend vectors):
    #   ANTHROPIC_API_KEY    — primary API key
    #   ANTHROPIC_AUTH_TOKEN — metered bearer token honoured by the claude CLI
    #   ANTHROPIC_BASE_URL   — proxy endpoint redirect (paid spend vector)
    metered_scrub =
      if agent_mode == :claude_code do
        [
          {~c"ANTHROPIC_API_KEY", false},
          {~c"ANTHROPIC_AUTH_TOKEN", false},
          {~c"ANTHROPIC_BASE_URL", false}
        ]
      else
        []
      end

    # D-381: inject TAU_AGENT_PROMPT so the subprocess (shim) reads the brief.
    # Applied for all agent_modes (benign for Replay; task data, not a secret).
    # TAU_AGENT_PROMPT is task data — it is NOT added to the D-374 metered scrub.
    #
    # Omit-on-empty: when brief == "", TAU_AGENT_PROMPT is NOT injected into the
    # Port env at all. The shim Runner reads System.get_env("TAU_AGENT_PROMPT") || ""
    # so an absent var yields "" — identical observable behaviour with no global
    # OS-env mutation (:os.putenv/:os.unsetenv are process-wide and unsafe under
    # concurrent Worker.init calls).
    prompt_env =
      if brief == "" do
        []
      else
        [{~c"TAU_AGENT_PROMPT", String.to_charlist(brief)}]
      end

    env_list = ns_env ++ extra_env_charlist ++ metered_scrub ++ prompt_env

    port =
      Port.open({:spawn_executable, agent_bin}, [
        :binary,
        {:packet, 4},
        :exit_status,
        {:env, env_list},
        {:cd, ws}
      ])

    # Step 6: heartbeat timer.
    # D-366: heartbeats are now event-driven (port heartbeat frames from the shim)
    # rather than self-clocked. The self-clock timer is NOT armed here.
    # The :heartbeat_interval opt is preserved in state as metadata (the shim
    # reads it at write time for rate-limiting). heartbeat_timer starts nil and
    # is kept nil throughout — the dispatch(%Heartbeat{}) handler checks it.
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
       heartbeat_timer: nil,
       # D-326: set to true when the agent emits work_ready before exiting.
       # Exit-0 without work_ready is fail-closed → :no_work_product.
       work_ready_seen?: false
     }}
  end

  # ---------------------------------------------------------------------------
  # D-326 — decode and dispatch typed agent events from Port data frames
  # ---------------------------------------------------------------------------

  # Decode a {packet,4}-framed JSON payload into a typed event struct.
  # The BEAM strips the 4-byte BE length prefix, so `frame` is raw JSON bytes.
  # Extend Tau.Provider.Event; never use ad-hoc formats (OTP non-negotiable).
  @spec decode_event(binary()) :: WorkReady.t() | Heartbeat.t() | {:unknown, binary()}
  defp decode_event(frame) do
    case Jason.decode(frame) do
      {:ok, %{"type" => "work_ready", "branch" => branch, "head_sha" => head_sha}} ->
        %WorkReady{branch: branch, head_sha: head_sha}

      {:ok, %{"type" => "heartbeat"}} ->
        %Heartbeat{}

      _ ->
        {:unknown, frame}
    end
  end

  # Dispatch a decoded typed event, updating state accordingly.
  # D-326: the Worker is the SOLE forwarder of work_ready to report_to
  # (single-writer discipline — mirrors the independent monitor's sole
  # ownership of worker_exit). Forward ONCE and set work_ready_seen? true.
  #
  # D-366: heartbeat frames from the shim drive the Worker's liveness signal.
  # On receipt, the self-clock timer is cancelled (switching from self-clock
  # mode to event-driven mode) and {:worker_heartbeat, worker_id} is sent to
  # report_to. Telemetry fires so the Watchdog's worker_stalled inference
  # (B7/C206) tracks real agent progress. A self-clock that fires regardless
  # of stream events cannot detect a wedged agent — heartbeat frames can.
  @spec dispatch(WorkReady.t() | Heartbeat.t() | {:unknown, binary()}, map()) :: map()
  defp dispatch(%WorkReady{branch: branch, head_sha: head_sha}, state) do
    if not is_nil(state.report_to) and not state.work_ready_seen? do
      send(state.report_to, {:work_ready, state.worker_id, branch, head_sha})
    end

    %{state | work_ready_seen?: true}
  end

  defp dispatch(%Heartbeat{}, state) do
    # Cancel the self-clock timer (if any) — switch to event-driven heartbeat mode.
    # Once event-driven, we no longer re-arm the timer; heartbeats come only from
    # port frames so a stalled agent stops pulsing (D-366).
    if state.heartbeat_timer do
      Process.cancel_timer(state.heartbeat_timer)
    end

    :telemetry.execute(
      [:tau, :factory, :worker, :heartbeat],
      %{},
      %{worker_id: state.worker_id, role: state.role}
    )

    if state.report_to do
      send(state.report_to, {:worker_heartbeat, state.worker_id})
    end

    %{state | heartbeat_timer: nil}
  end

  defp dispatch({:unknown, _frame}, state) do
    state
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

  # ---------------------------------------------------------------------------
  # D-374 — metered-API spend preflight helpers
  # ---------------------------------------------------------------------------

  # Run the metered-path preflight. Only active when agent_mode == :claude_code.
  # Returns :ok to proceed or {:stop, :metered_path_refused} to block Port.open.
  # Non-:claude_code modes pass through unconditionally (unchanged behaviour).
  @spec preflight_metered(atom() | nil, (-> :ok | {:error, term()})) ::
          :ok | {:stop, :metered_path_refused}
  defp preflight_metered(:claude_code, creds_check_fun) do
    case creds_check_fun.() do
      :ok -> :ok
      {:error, _reason} -> {:stop, :metered_path_refused}
    end
  end

  defp preflight_metered(_other_mode, _creds_check_fun), do: :ok

  # Default subscription-creds check (D-374): reads ~/.claude/.credentials.json
  # via Tau.Providers.Anthropic.Auth. Returns :ok if the file is present and
  # parseable (OAuth creds exist); {:error, :subscription_creds_absent}
  # otherwise (covers :no_auth, :oauth_expired, :oauth_malformed,
  # :oauth_missing_scope — all indicate absent/unusable subscription creds).
  @spec default_creds_check() :: :ok | {:error, :subscription_creds_absent}
  defp default_creds_check do
    case Auth.resolve(%{}) do
      {:ok, {:oauth, _}} -> :ok
      _other -> {:error, :subscription_creds_absent}
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
