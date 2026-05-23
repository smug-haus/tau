defmodule Tau.CodingAgent.Workspace.Git do
  @moduledoc """
  Per-session **git worktree** workspace (SPEC-CODING-AGENT §4 B3, Q3).

  Each session gets a fresh worktree at
  `~/.tau/worktrees/<session_id>/` (overridable via `:state_dir`), on a
  branch named `tau/coding-agent/<session_id>`. The worktree is removed
  on `cleanup/1` via `git worktree remove --force`.

  ## Why a worktree

  The dominant destructive interaction surface flagged in
  SPEC-CODING-AGENT §3 is a concurrent editor
  session writing the same files the coding agent edits. A worktree
  isolates the agent's writes onto a parallel branch without copying
  the repo or interfering with the user's index. The user can review
  the agent's changes via `git diff <ws-path>` or merge the branch
  back when satisfied.

  ## Failure modes

    * The user invoked tau from a directory that is **not** inside a
      git repo: this backend will never be selected by
      `Workspace.resolve_default_backend/1` — the FSM falls back to
      `Workspace.Cwd`. Calling `prepare/1` here directly in that
      situation returns `{:error, :not_a_git_repo}`.
    * `git` is not on PATH: `prepare/1` returns
      `{:error, {:git_missing, _}}`. Adapters that require a worktree
      should surface this as an `%Event.Error{}` rather than crash.
    * The state directory cannot be created: `{:error, {:state_dir,
      reason}}`.

  All failure modes are tagged-tuple returns; no exceptions cross the
  boundary.
  """

  @behaviour Tau.CodingAgent.Workspace

  alias Tau.CodingAgent.Workspace

  @branch_prefix "tau/coding-agent/"

  @impl Tau.CodingAgent.Workspace
  def prepare(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    cwd = Keyword.fetch!(opts, :cwd)
    state_dir = Keyword.get(opts, :state_dir, default_state_dir())

    with {:ok, git_bin} <- find_git(),
         {:ok, repo_root} <- locate_repo(cwd),
         :ok <- ensure_state_dir(state_dir),
         {:ok, path} <- compute_worktree_path(state_dir, session_id),
         branch <- @branch_prefix <> session_id,
         :ok <- create_worktree(git_bin, repo_root, path, branch) do
      ws = %Workspace{
        backend: __MODULE__,
        path: path,
        repo_root: repo_root,
        branch: branch,
        handle: %{git_bin: git_bin}
      }

      :telemetry.execute(
        [:tau, :coding_agent, :workspace, :prepared],
        %{system_time: System.system_time()},
        %{backend: __MODULE__, path: path, repo_root: repo_root, branch: branch}
      )

      {:ok, ws}
    end
  end

  @impl Tau.CodingAgent.Workspace
  def cleanup(%Workspace{backend: __MODULE__, path: path, repo_root: repo_root, handle: handle}) do
    git_bin = Map.get(handle || %{}, :git_bin) || System.find_executable("git")

    if git_bin && File.dir?(path) do
      # `--force` because the agent's branch is almost certainly dirty
      # at end-of-session — that's the whole point.
      System.cmd(git_bin, ["worktree", "remove", "--force", path],
        cd: repo_root,
        stderr_to_stdout: true
      )
    end

    # Best-effort directory removal in case `git worktree remove` left
    # an orphan (it shouldn't, but worktrees can drift on a crashed
    # session).
    if File.dir?(path), do: File.rm_rf(path)

    :telemetry.execute(
      [:tau, :coding_agent, :workspace, :cleaned],
      %{system_time: System.system_time()},
      %{backend: __MODULE__, path: path, repo_root: repo_root}
    )

    :ok
  end

  @doc """
  Locate the git repository root for a starting directory by walking
  up the path tree looking for a `.git` entry. Returns the absolute
  path of the repository root, or `nil` if `cwd` is not under a git
  repo.

  Public so the workspace dispatcher can pre-check before selecting
  this backend; also exercised directly by the workspace unit tests.
  """
  @spec find_repo_root(Path.t()) :: Path.t() | nil
  def find_repo_root(cwd) when is_binary(cwd) do
    cwd = Path.expand(cwd)
    do_find_repo_root(cwd)
  end

  defp do_find_repo_root(path) do
    git_entry = Path.join(path, ".git")

    cond do
      File.exists?(git_entry) ->
        path

      path == "/" or Path.dirname(path) == path ->
        nil

      true ->
        do_find_repo_root(Path.dirname(path))
    end
  end

  # ── helpers ───────────────────────────────────────────────────

  defp find_git do
    case System.find_executable("git") do
      nil -> {:error, {:git_missing, "git binary not on PATH"}}
      bin -> {:ok, bin}
    end
  end

  defp locate_repo(cwd) do
    case find_repo_root(cwd) do
      nil -> {:error, :not_a_git_repo}
      root -> {:ok, root}
    end
  end

  defp ensure_state_dir(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, {:state_dir, reason}}
    end
  end

  defp compute_worktree_path(state_dir, session_id) do
    # Sanitise session_id: only word chars and dashes survive. UUIDv7
    # ids are already safe; this is paranoia for tests that hand in
    # arbitrary strings.
    safe = String.replace(session_id, ~r/[^\w\-]/, "_")
    path = Path.join(state_dir, safe)

    cond do
      File.dir?(path) ->
        # A stale worktree from a previous crashed session. Best-effort
        # nuke it so we get a clean slate. `git worktree remove --force`
        # against the *repo* would be cleaner but we don't have the repo
        # root yet at the right level — File.rm_rf works fine because
        # the worktree's metadata under the repo's .git/worktrees/ will
        # be GC'd by `git worktree prune` on the next `add` call below.
        File.rm_rf(path)
        {:ok, path}

      File.exists?(path) ->
        {:error, {:state_dir, {:path_exists_as_file, path}}}

      true ->
        {:ok, path}
    end
  end

  defp create_worktree(git_bin, repo_root, path, branch) do
    # `git worktree prune` first — removes references to stale worktree
    # paths that may match our target. Without this, a crashed previous
    # session leaves an entry in `.git/worktrees/` and `git worktree add`
    # refuses with "fatal: '...' already exists".
    System.cmd(git_bin, ["worktree", "prune"], cd: repo_root, stderr_to_stdout: true)

    # `-b <branch>` creates a fresh branch off HEAD. If the branch
    # already exists (resumed session id collision) we retry without
    # `-b` so an existing branch is reattached.
    case System.cmd(git_bin, ["worktree", "add", "-b", branch, path],
           cd: repo_root,
           stderr_to_stdout: true
         ) do
      {_out, 0} ->
        :ok

      {out, _nonzero} ->
        # Heuristic: branch already exists. Retry without -b.
        if out =~ "already exists" do
          case System.cmd(git_bin, ["worktree", "add", path, branch],
                 cd: repo_root,
                 stderr_to_stdout: true
               ) do
            {_out, 0} -> :ok
            {out2, _} -> {:error, {:git_worktree_add_failed, String.trim(out2)}}
          end
        else
          {:error, {:git_worktree_add_failed, String.trim(out)}}
        end
    end
  end

  defp default_state_dir do
    Path.join(System.user_home!(), ".tau/worktrees")
  end
end
