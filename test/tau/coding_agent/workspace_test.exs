defmodule Tau.CodingAgent.WorkspaceTest do
  @moduledoc """
  SPEC-CODING-AGENT §4 B3 / D-033: workspace preparation/cleanup.

  Covers both backends:

    * `Tau.CodingAgent.Workspace.Git` — repo detection, worktree
      creation under a per-session state dir, branch naming, cleanup
      via `git worktree remove --force`.
    * `Tau.CodingAgent.Workspace.Cwd` — passthrough; no state
      created; cleanup is a no-op.

  And the dispatcher:

    * `Workspace.resolve_default_backend/1` picks Git when invoked
      inside a repo, Cwd when not.
    * `Workspace.prepare/1` validates the returned path is absolute
      and exists (D-033).
  """
  use ExUnit.Case, async: true

  alias Tau.CodingAgent.Workspace
  alias Tau.CodingAgent.Workspace.{Cwd, Git}

  defp unique_tmpdir(prefix) do
    base =
      Path.join(
        System.tmp_dir!(),
        "#{prefix}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)
    base
  end

  defp init_repo(dir) do
    git = System.find_executable("git") || flunk("git not on PATH")

    {_, 0} =
      System.cmd(git, ["init", "--initial-branch=main", "--quiet"],
        cd: dir,
        stderr_to_stdout: true
      )

    {_, 0} =
      System.cmd(git, ["-c", "user.email=t@t", "-c", "user.name=t", "config", "user.email", "t@t"],
        cd: dir,
        stderr_to_stdout: true
      )

    {_, 0} =
      System.cmd(git, ["config", "user.name", "t"], cd: dir, stderr_to_stdout: true)

    File.write!(Path.join(dir, "README.md"), "seed\n")

    {_, 0} =
      System.cmd(git, ["add", "README.md"], cd: dir, stderr_to_stdout: true)

    {_, 0} =
      System.cmd(git, ["commit", "-q", "-m", "seed"], cd: dir, stderr_to_stdout: true)

    :ok
  end

  describe "resolve_default_backend/1" do
    test "returns Git when cwd is inside a repo" do
      dir = unique_tmpdir("tau-ws-resolve-repo")
      init_repo(dir)

      assert Workspace.resolve_default_backend(dir) == Tau.CodingAgent.Workspace.Git
    end

    test "returns Cwd when cwd is not inside a repo" do
      dir = unique_tmpdir("tau-ws-resolve-norepo")

      assert Workspace.resolve_default_backend(dir) == Tau.CodingAgent.Workspace.Cwd
    end

    test "walks up parent dirs to find .git" do
      root = unique_tmpdir("tau-ws-resolve-nested")
      init_repo(root)

      nested = Path.join([root, "a", "b", "c"])
      File.mkdir_p!(nested)

      assert Workspace.resolve_default_backend(nested) == Tau.CodingAgent.Workspace.Git
    end
  end

  describe "Workspace.Git.find_repo_root/1" do
    test "returns the repo root when called from a subdir" do
      root = unique_tmpdir("tau-ws-find")
      init_repo(root)

      nested = Path.join(root, "subdir")
      File.mkdir_p!(nested)

      assert Git.find_repo_root(nested) == root
    end

    test "returns nil outside a repo" do
      dir = unique_tmpdir("tau-ws-find-none")
      assert is_nil(Git.find_repo_root(dir))
    end
  end

  describe "Workspace.Git — prepare + cleanup" do
    test "creates a worktree under the configured state_dir and cleans up" do
      repo = unique_tmpdir("tau-ws-git-repo")
      state_dir = unique_tmpdir("tau-ws-git-state")
      init_repo(repo)

      sid = "sess-#{System.unique_integer([:positive])}"

      {:ok, ws} =
        Workspace.prepare(
          backend: Git,
          session_id: sid,
          cwd: repo,
          state_dir: state_dir
        )

      # D-033: absolute path that exists as a directory.
      assert is_binary(ws.path)
      assert Path.absname(ws.path) == ws.path
      assert File.dir?(ws.path)

      # The worktree must be a real git worktree of the source repo.
      assert ws.repo_root == repo
      assert ws.branch == "tau/coding-agent/" <> sid
      assert ws.backend == Git

      # `git worktree list` should mention the new path.
      git = System.find_executable("git")
      {out, 0} = System.cmd(git, ["worktree", "list"], cd: repo, stderr_to_stdout: true)
      assert out =~ ws.path

      # Cleanup removes the directory.
      assert :ok = Workspace.cleanup(ws)
      refute File.dir?(ws.path)
    end

    test "prepare fails closed when invoked outside a repo" do
      dir = unique_tmpdir("tau-ws-git-norepo")

      assert {:error, :not_a_git_repo} =
               Git.prepare(session_id: "sess-x", cwd: dir, state_dir: dir)
    end

    test "stale worktree path is cleaned and rebuilt" do
      repo = unique_tmpdir("tau-ws-git-stale")
      state_dir = unique_tmpdir("tau-ws-git-stale-state")
      init_repo(repo)

      sid = "sess-stale-#{System.unique_integer([:positive])}"

      # First prepare succeeds.
      {:ok, ws1} =
        Workspace.prepare(
          backend: Git,
          session_id: sid,
          cwd: repo,
          state_dir: state_dir
        )

      # Pretend the process crashed: do NOT clean up. A subsequent
      # prepare under the same session_id (e.g. a restarted session)
      # must succeed by reclaiming the path.
      {:ok, ws2} =
        Workspace.prepare(
          backend: Git,
          session_id: sid,
          cwd: repo,
          state_dir: state_dir
        )

      assert ws2.path == ws1.path
      assert File.dir?(ws2.path)

      assert :ok = Workspace.cleanup(ws2)
    end
  end

  describe "Workspace.Cwd — passthrough" do
    test "prepare returns the cwd unchanged; cleanup is a no-op" do
      dir = unique_tmpdir("tau-ws-cwd")

      {:ok, ws} =
        Workspace.prepare(
          backend: Cwd,
          session_id: "sess-cwd",
          cwd: dir
        )

      assert ws.backend == Cwd
      assert ws.path == Path.expand(dir)
      assert File.dir?(ws.path)

      assert :ok = Workspace.cleanup(ws)
      # cwd preserved: the user's working tree is sacred.
      assert File.dir?(ws.path)
    end

    test "prepare rejects a non-directory cwd" do
      file =
        Path.join(System.tmp_dir!(), "tau-ws-cwd-not-dir-#{System.unique_integer([:positive])}")

      File.write!(file, "x")
      on_exit(fn -> File.rm(file) end)

      assert {:error, {:workspace_invalid, {:cwd_not_a_directory, ^file}}} =
               Cwd.prepare(session_id: "sess-x", cwd: file)
    end
  end

  describe "Workspace.cleanup/1 — nil and error tolerance" do
    test "nil is a clean no-op (covers prepare-failed-before-struct path)" do
      assert :ok = Workspace.cleanup(nil)
    end
  end
end
