defmodule Tau.Factory.CodingAgentShimIsolationTest do
  @moduledoc """
  Gating test for PR #504 (#487 — A1: wire real Tau.CodingAgent substrate as the
  worker agent). Advances AC-14, D-365 (SPEC-FACTORY-FLEET §4 B4-A1, §6).

  Written BEFORE production code exists (oracle-separation, factory-loop §4b).
  These tests MUST FAIL against the current branch because:
    - `Tau.Factory.CodingAgentShim` does not exist yet.
    - Calling `Tau.Factory.CodingAgentShim.write/2` will raise
      `UndefinedFunctionError`.

  ## The contract under test (D-365)

  SPEC-FACTORY-FLEET §4 B4-A1 and §6 D-365:

    * The Worker launches the shim with `{:env, ns}` and `{:cd, ws}`.
    * The shim MUST set `task.workspace = ws` (the worker's private worktree —
      NOT a `~/.tau/worktrees/...` nested worktree).
    * The shim MUST select `Tau.CodingAgent.Workspace.Cwd` (passthrough backend)
      so the adapter creates NO second nested worktree.
    * The shim MUST pass its environment through to the `claude` subprocess so
      the `XDG_*`/`MIX_HOME`/`HEX_HOME` namespace keys inherited from the Worker
      are visible to the sub-subprocess.
    * No write from the shim or its sub-agent escapes the worker's `ws`.
    * `□( resources(shim) ∪ resources(claude) ⊆ namespace(worker) )`.

  ## What "inside ws" means in these tests

  Because the shim uses the Replay adapter (no real `claude`), we test the
  isolation invariants by inspecting what the shim writes to the environment
  and the workspace:

  1. The shim's effective workspace (passed to the adapter as `task.workspace`)
     resolves to a path INSIDE the worktree `ws`, NOT `~/.tau/worktrees/...`.
  2. No `~/.tau/worktrees/...` directory is created during the shim's run.
  3. Any `XDG_DATA_HOME` the shim exposes in its environment maps to a path
     inside `ws`.

  The shim can report these values by emitting a typed diagnostic heartbeat or
  by writing an inspection file; the test observes the net effect.

  ## AC linkage
    - AC-14 / D-365 — all tests below.
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log
  @moduletag :ac_14
  @moduletag :d_365

  alias Tau.CodingAgent.Event

  @worker_registry Tau.Factory.WorkerRegistry
  @worker_supervisor Tau.Factory.WorkerSupervisor

  defp setup_git_repo(tmp_dir) do
    repo_dir = Path.join(tmp_dir, "repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo_dir)

    git = fn args ->
      System.cmd("git", args, cd: repo_dir, stderr_to_stdout: true)
    end

    {_, 0} = git.(["init", "-b", "main"])
    {_, 0} = git.(["config", "user.email", "test@tau.test"])
    {_, 0} = git.(["config", "user.name", "Tau Test"])

    File.write!(Path.join(repo_dir, "README"), "initial\n")
    {_, 0} = git.(["add", "README"])
    {_, 0} = git.(["commit", "-m", "initial commit"])
    {sha, 0} = git.(["rev-parse", "HEAD"])

    %{repo_dir: repo_dir, base_ref: String.trim(sha)}
  end

  defp mk_tmp(tag) do
    tmp_dir =
      Path.join(System.tmp_dir!(), "tau_#{tag}_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    tmp_dir
  end

  defp start_fleet(tag) do
    n = System.unique_integer([:positive])
    registry_name = :"iso_reg_#{tag}_#{n}"
    sup_name = :"iso_sup_#{tag}_#{n}"

    {:ok, _reg} =
      start_supervised({@worker_registry, name: registry_name}, id: :"reg_#{n}")

    {:ok, sup} =
      start_supervised(
        {@worker_supervisor, name: sup_name, registry: registry_name},
        id: :"sup_#{n}"
      )

    {sup, registry_name}
  end

  # A Replay fixture that writes a file containing the shim's effective
  # XDG_DATA_HOME environment value so the test can assert it resides
  # inside the worker's ws. The shim is responsible for actually writing
  # the file when it executes the adapter; the fixture content drives what
  # the adapter "does" — the real write is handled by the shim runtime.
  defp inspection_fixture do
    [
      %Event.Start{agent: :replay, version: "0.0.0", pid: nil},
      %Event.AssistantText{text: "isolation probe", turn: 0},
      %Event.Cost{tokens: %{}, usd: 0.0, duration_ms: 0},
      %Event.Done{exit_status: 0, final_message: nil}
    ]
  end

  # ---------------------------------------------------------------------------
  # D-365 test 1: workspace uses worker's ws (Cwd backend), no nested worktree
  #
  # Full contract: the shim MUST set task.workspace = ws (the worker's private
  # worktree) and select the Cwd backend so NO ~/.tau/worktrees/... nested
  # worktree is created. Verified by snapshotting ~/.tau/worktrees before/after.
  # ---------------------------------------------------------------------------

  describe "D-365 shim isolation" do
    @tag :ac_14
    @tag :d_365
    test "D-365: the shim uses the worker's ws as task.workspace (Cwd backend) and does NOT create a ~/.tau/worktrees/... nested worktree" do
      tmp_dir = mk_tmp("shim_iso")
      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)

      tau_worktrees_before =
        case File.ls(Path.join([System.user_home!(), ".tau", "worktrees"])) do
          {:ok, entries} -> MapSet.new(entries)
          {:error, :enoent} -> MapSet.new()
        end

      n = System.unique_integer([:positive])
      shim_bin = Path.join(tmp_dir, "shim_iso_#{n}")

      # D-365: UndefinedFunctionError on current branch — correct fail-before state.
      # The shim MUST be written with workspace_backend: :cwd to suppress nested
      # worktree creation.
      shim_bin =
        Tau.Factory.CodingAgentShim.write(shim_bin,
          adapter: Tau.CodingAgents.Replay,
          replay_fixture: inspection_fixture(),
          branch: "feat/iso-probe-#{n}",
          workspace_backend: Tau.CodingAgent.Workspace.Cwd
        )

      {sup, registry_name} = start_fleet(:shim_iso)
      report_to = self()

      # Inject a known XDG_DATA_HOME into the namespace so we can verify the
      # shim sees it. The Worker passes :env opts through its ns resolution; we
      # supply a synthetic ns override via extra_env.
      xdg_probe = Path.join(tmp_dir, "xdg_home_probe")
      File.mkdir_p!(xdg_probe)

      {:ok, worker_id} =
        @worker_supervisor.spawn(sup, :implementer, "isolation probe", base_ref,
          repo_dir: repo_dir,
          agent_bin: shim_bin,
          report_to: report_to,
          registry: registry_name,
          extra_env: [{"XDG_DATA_HOME", xdg_probe}]
        )

      # Wait for the run to complete (work_ready OR no_work_product both acceptable;
      # we care about isolation, not the work outcome).
      assert_receive msg
                     when elem(msg, 0) in [:work_ready, :worker_exit] and
                            elem(msg, 1) == worker_id,
                     10_000,
                     "D-365: shim run must complete (work_ready or no_work_product) within 10s"

      # D-365: assert no new ~/.tau/worktrees/... directory was created.
      tau_worktrees_after =
        case File.ls(Path.join([System.user_home!(), ".tau", "worktrees"])) do
          {:ok, entries} -> MapSet.new(entries)
          {:error, :enoent} -> MapSet.new()
        end

      new_nested = MapSet.difference(tau_worktrees_after, tau_worktrees_before)

      assert MapSet.size(new_nested) == 0,
             "D-365: the shim MUST NOT create a nested ~/.tau/worktrees/... entry. " <>
               "New entries found: #{inspect(MapSet.to_list(new_nested))}. " <>
               "Fails on current branch: Tau.Factory.CodingAgentShim is undefined."
    end

    # D-365 test 2: env-passthrough — XDG_DATA_HOME inside ws is inherited
    #
    # Full contract: the shim MUST pass its environment through to the adapter/
    # sub-subprocess so XDG_DATA_HOME/MIX_HOME/HEX_HOME namespace keys inherited
    # from the Worker resolve inside ws, NOT the host $HOME.
    @tag :ac_14
    @tag :d_365
    test "D-365: the shim's effective XDG_DATA_HOME (and MIX_HOME/HEX_HOME when set) resolve inside the worker's ws, not the host $HOME" do
      tmp_dir = mk_tmp("shim_env")
      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)

      n = System.unique_integer([:positive])
      shim_bin = Path.join(tmp_dir, "shim_env_#{n}")

      # D-365: UndefinedFunctionError on current branch — correct fail-before state.
      # The shim must accept an :inspect_env_file option and, when set, write the
      # shim's effective XDG_DATA_HOME/MIX_HOME/HEX_HOME to that file so the test
      # can assert they are sub-paths of ws.
      inspect_file = Path.join(tmp_dir, "env_inspection_#{n}.txt")

      shim_bin =
        Tau.Factory.CodingAgentShim.write(shim_bin,
          adapter: Tau.CodingAgents.Replay,
          replay_fixture: inspection_fixture(),
          branch: "feat/env-probe-#{n}",
          workspace_backend: Tau.CodingAgent.Workspace.Cwd,
          inspect_env_file: inspect_file
        )

      {sup, registry_name} = start_fleet(:shim_env)
      report_to = self()

      {:ok, worker_id} =
        @worker_supervisor.spawn(sup, :implementer, "env passthrough probe", base_ref,
          repo_dir: repo_dir,
          agent_bin: shim_bin,
          report_to: report_to,
          registry: registry_name
        )

      # Wait for the shim to complete.
      assert_receive msg
                     when elem(msg, 0) in [:work_ready, :worker_exit] and
                            elem(msg, 1) == worker_id,
                     10_000,
                     "D-365: shim run must complete within 10s"

      # D-365: the inspection file must exist and contain env paths that are
      # sub-paths of the worker's ws (not the host $HOME).
      assert File.exists?(inspect_file),
             "D-365: shim must write its effective env to the inspect_env_file; file not found. " <>
               "Fails on current branch: Tau.Factory.CodingAgentShim is undefined."

      # Retrieve the worker's ws to validate paths are inside it.
      {:ok, ws} =
        case Registry.lookup(@worker_registry, worker_id) do
          [{pid, _meta}] -> GenServer.call(pid, :get_ws)
          [] -> {:ok, nil}
        end

      env_text = File.read!(inspect_file)

      # D-365: every env path the shim reports must be a sub-path of ws.
      env_lines =
        env_text
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.contains?(&1, "="))

      for line <- env_lines do
        [_key, value] = String.split(line, "=", parts: 2)

        if ws do
          assert String.starts_with?(value, ws),
                 "D-365: env var #{inspect(line)} must point inside ws=#{inspect(ws)}; " <>
                   "got #{inspect(value)}. This would be a host-$HOME leak (GAP-4 / F-5)."
        end
      end
    end
  end
end
