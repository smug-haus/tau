defmodule Tau.CodingAgent.Workspace do
  @moduledoc """
  Workspace preparation and cleanup for coding-agent runs.

  Phase 1B Team B (#191) introduces a **per-session git worktree** as the
  default workspace for coding-agent runs (SPEC-CODING-AGENT §4 B3, Q3).
  The worktree isolates the agent's edits from the user's working tree
  and survives until the session ends.

  This module is a thin **behaviour** with pluggable backends:

    * `Tau.CodingAgent.Workspace.Git` — repo-detection + `git worktree add`
      + `git worktree remove` on cleanup. The default.
    * `Tau.CodingAgent.Workspace.Cwd` — passthrough; uses the session's
      cwd directly. Used when there is no surrounding git repository or
      when the caller explicitly opted out. Replay tests select this
      backend so they don't depend on a real repo.

  D-033 (SPEC-CODING-AGENT §6): the workspace path returned here is
  **always** an explicit absolute path; the dispatcher MUST NOT inherit
  tau's cwd silently. `prepare/2` validates the result before returning.

  ## Lifecycle

      {:ok, ws} = Workspace.prepare(opts)
      # ws.path is the absolute path the dispatcher's `task.workspace`
      # field MUST carry.
      # ... run dispatcher against ws.path ...
      :ok = Workspace.cleanup(ws)

  The session FSM owns the lifecycle: prepares at the first
  `:coding_agent_streaming` transition for a session, cleans up on
  `terminate/3` (whether the session exits cleanly or crashes). The
  cleanup is best-effort — a partially-prepared workspace (failed mid-add)
  is also a no-op so resume / crash-recovery never wedges on a stale
  worktree.

  ## Behaviour contract

  Implementations declare two callbacks:

      @callback prepare(opts :: keyword()) :: {:ok, t()} | {:error, term()}
      @callback cleanup(t()) :: :ok

  `opts` is implementation-defined; the canonical keys are:

    * `:session_id` — string, used to name the worktree directory.
    * `:cwd`        — absolute path the user invoked tau from.
    * `:state_dir`  — root under which worktrees are created
      (default `Path.join(System.user_home!(), ".tau/worktrees")`).
  """

  @type backend :: module()

  @type t :: %__MODULE__{
          backend: backend(),
          path: Path.t(),
          repo_root: Path.t() | nil,
          branch: String.t() | nil,
          # backend-specific opaque
          handle: term()
        }

  @enforce_keys [:backend, :path]
  defstruct [:backend, :path, :repo_root, :branch, :handle]

  @callback prepare(opts :: keyword()) :: {:ok, t()} | {:error, term()}
  @callback cleanup(t()) :: :ok

  @doc """
  Prepare a workspace. Dispatches to the requested backend (default
  `Tau.CodingAgent.Workspace.Git`) and validates that the returned
  `:path` is an absolute path to an existing directory before handing
  it back to the caller (D-033).
  """
  @spec prepare(keyword()) :: {:ok, t()} | {:error, term()}
  def prepare(opts) do
    backend = Keyword.get(opts, :backend, Tau.CodingAgent.Workspace.Git)

    case backend.prepare(opts) do
      {:ok, %__MODULE__{path: path} = ws} ->
        cond do
          not is_binary(path) -> {:error, {:workspace_invalid, :path_not_binary}}
          Path.absname(path) != path -> {:error, {:workspace_invalid, :path_not_absolute}}
          not File.dir?(path) -> {:error, {:workspace_invalid, {:not_a_directory, path}}}
          true -> {:ok, ws}
        end

      {:ok, other} ->
        {:error, {:workspace_invalid, {:not_a_workspace_struct, other}}}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Tear down a workspace. Idempotent and best-effort: a `nil` workspace
  (preparation failed before this struct existed) is a no-op; a
  backend-level failure is logged via telemetry but does not raise.
  """
  @spec cleanup(t() | nil) :: :ok
  def cleanup(nil), do: :ok

  def cleanup(%__MODULE__{backend: backend} = ws) do
    backend.cleanup(ws)
  rescue
    e ->
      :telemetry.execute(
        [:tau, :coding_agent, :workspace, :cleanup_failed],
        %{system_time: System.system_time()},
        %{backend: backend, path: ws.path, reason: Exception.message(e)}
      )

      :ok
  catch
    kind, reason ->
      :telemetry.execute(
        [:tau, :coding_agent, :workspace, :cleanup_failed],
        %{system_time: System.system_time()},
        %{backend: backend, path: ws.path, reason: {kind, reason}}
      )

      :ok
  end

  @doc """
  Resolve the appropriate backend for a given cwd. Returns
  `Tau.CodingAgent.Workspace.Git` when `cwd` (or any ancestor) contains
  a `.git` entry; falls back to `Tau.CodingAgent.Workspace.Cwd`
  otherwise.

  Used by the session FSM so the user is not forced to think about
  worktree vs cwd — the default Just Works in a git repo and degrades
  gracefully when invoked elsewhere. A telemetry event records the
  fallback so the user can see the reason in `tau doctor` later.
  """
  @spec resolve_default_backend(Path.t()) :: backend()
  def resolve_default_backend(cwd) when is_binary(cwd) do
    if Tau.CodingAgent.Workspace.Git.find_repo_root(cwd) do
      Tau.CodingAgent.Workspace.Git
    else
      :telemetry.execute(
        [:tau, :coding_agent, :workspace, :git_repo_absent],
        %{system_time: System.system_time()},
        %{cwd: cwd}
      )

      Tau.CodingAgent.Workspace.Cwd
    end
  end
end
