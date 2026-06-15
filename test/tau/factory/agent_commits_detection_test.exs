defmodule Tau.Factory.AgentCommitsDetectionTest do
  @moduledoc """
  Gating tests for PR #527 (issue #525 — D-386: agent-commits-aware work-product
  detection).

  Written BEFORE production code exists (oracle-separation, factory-loop §4b).

  ## D-386 invariant

  Work-product detection is `HEAD-advance ∨ dirty-tree`, NOT dirty-tree only.

  The shim captures `base = git rev-parse HEAD` before draining the agent stream.
  After `%Done{exit_status: 0}`:

    * `HEAD ≠ base` (agent committed, CLEAN tree) → emit `work_ready{head_sha =
      agent's HEAD}`; do NOT make a redundant second commit.
    * `HEAD == base ∧ dirty` (uncommitted edits) → shim commits; emit shim's SHA
      (back-compat, D-364).
    * `HEAD == base ∧ clean` (nothing) → no `work_ready`; `:no_work_product`
      (preserved, D-364).

  ## Why case (a) fails before the fix

  The current shim's detection path:

      git status --porcelain → "" → :empty → System.halt(0) (no work_ready)

  A real agent that commits its own work leaves `git status --porcelain` EMPTY
  even though HEAD has advanced. The shim cannot see the advance because it
  never captures the pre-drain base SHA. The `assert_receive {:work_ready, ...}`
  in case (a) times out with the current implementation.

  Cases (b) and (c) are back-compat / preserved D-364 paths that should already
  pass.

  ## AC linkage
    - D-386 — all tests below.
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log
  @moduletag :d_386

  alias Tau.CodingAgent.Event
  alias Tau.Factory.CodingAgentShim
  alias Tau.Factory.TestAdapters.CommittingAgent

  @worker_registry Tau.Factory.WorkerRegistry
  @worker_supervisor Tau.Factory.WorkerSupervisor

  # ---------------------------------------------------------------------------
  # Hermetic git repo helpers (mirrors coding_agent_shim_bridge_test.exs idiom)
  # ---------------------------------------------------------------------------

  defp setup_git_repo(tmp_dir) do
    repo_dir = Path.join(tmp_dir, "repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo_dir)

    git = fn args ->
      System.cmd("git", args, cd: repo_dir, stderr_to_stdout: true)
    end

    {_, 0} = git.(["init", "-b", "main"])
    {_, 0} = git.(["config", "user.email", "test@tau.test"])
    {_, 0} = git.(["config", "user.name", "Tau Test"])
    # CommittingAgent also needs these set inside the worktree; they are set
    # by the shim runner, but also set here for the hermetic repo's initial
    # commit to succeed cleanly.
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
    registry_name = :"d386_reg_#{tag}_#{n}"
    sup_name = :"d386_sup_#{tag}_#{n}"

    {:ok, _reg} =
      start_supervised({@worker_registry, name: registry_name}, id: :"reg_#{n}")

    {:ok, sup} =
      start_supervised(
        {@worker_supervisor, name: sup_name, registry: registry_name},
        id: :"sup_#{n}"
      )

    {sup, registry_name}
  end

  # A Replay fixture that edits a file (non-empty diff when committed by shim).
  defp uncommitted_edits_fixture(ws) do
    [
      %Event.Start{agent: :replay, version: "0.0.0", pid: nil},
      %Event.AssistantText{text: "I will create a file (uncommitted)", turn: 0},
      %Event.FileEdit{path: Path.join(ws, "output.txt"), kind: :create},
      %Event.Cost{tokens: %{}, usd: 0.0, duration_ms: 0},
      %Event.Done{exit_status: 0, final_message: "done"}
    ]
  end

  # A Replay fixture that produces no file edits (empty diff).
  defp empty_diff_fixture do
    [
      %Event.Start{agent: :replay, version: "0.0.0", pid: nil},
      %Event.AssistantText{text: "I did nothing", turn: 0},
      %Event.Cost{tokens: %{}, usd: 0.0, duration_ms: 0},
      %Event.Done{exit_status: 0, final_message: "no changes"}
    ]
  end

  # ---------------------------------------------------------------------------
  # D-386 case (a): agent commits its own work; tree is CLEAN; HEAD advanced.
  #
  # The CommittingAgent test adapter writes + git-commits a file INSIDE the
  # worktree before emitting %Done{0}, leaving `git status --porcelain` EMPTY
  # while HEAD ≠ base.
  #
  # Pre-impl failure: the current shim sees `git status --porcelain` → "" →
  # :empty → exits 0 without emitting work_ready. The assert_receive times out.
  #
  # V6 strength:
  #   (i)  head_sha == the AGENT's commit (not a shim-authored SHA).
  #   (ii) exactly ONE new commit beyond base (no double-commit).
  # ---------------------------------------------------------------------------

  describe "D-386 agent-commits-aware detection" do
    @tag :d_386
    test "D-386 case (a): agent commits own work on clean tree — work_ready carries agent HEAD, no redundant shim commit" do
      tmp_dir = mk_tmp("d386_commits")
      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)

      branch = "feat/d386-agent-commits"
      n = System.unique_integer([:positive])
      shim_bin = Path.join(tmp_dir, "shim_d386_commits_#{n}")

      # Write the shim configured with the CommittingAgent adapter.
      # CommittingAgent.start/2 writes + commits inside the workspace, then
      # emits %Done{exit_status: 0}. The shim receives a CLEAN tree with HEAD
      # advanced by one commit.
      shim_bin =
        CodingAgentShim.write(shim_bin,
          adapter: CommittingAgent,
          branch: branch
        )

      assert File.exists?(shim_bin),
             "D-386: CodingAgentShim.write/2 must produce an executable shim"

      {sup, registry_name} = start_fleet(:d386_commits)
      report_to = self()

      {:ok, worker_id} =
        @worker_supervisor.spawn(sup, :implementer, "D-386 committing agent brief", base_ref,
          repo_dir: repo_dir,
          agent_bin: shim_bin,
          report_to: report_to,
          registry: registry_name
        )

      # D-386 case (a): the shim MUST detect HEAD-advance (HEAD ≠ base) even
      # when `git status --porcelain` is empty, and emit work_ready.
      # PRE-IMPL FAILURE: assert_receive times out because the current shim
      # routes clean-tree → :no_work_product without checking HEAD advance.
      assert_receive {:work_ready, ^worker_id, ^branch, head_sha},
                     15_000,
                     "D-386 case (a): agent committed its own work (HEAD advanced, clean tree). " <>
                       "The shim MUST detect HEAD != base and emit work_ready. " <>
                       "Fails pre-impl: shim's git-status-only detection sees clean tree → no work_ready."

      # V6 strength (i): head_sha must be a real 40-char hex SHA.
      assert Regex.match?(~r/\A[0-9a-fA-F]{40}\z/, head_sha),
             "D-386: head_sha must be a 40-char commit SHA; got #{inspect(head_sha)}"

      # V6 strength (ii): branch must have EXACTLY ONE new commit beyond base.
      # Capture the current branch tip in the hermetic repo.
      {log_out, 0} =
        System.cmd(
          "git",
          ["log", "--oneline", "#{base_ref}..#{branch}"],
          cd: repo_dir,
          stderr_to_stdout: true
        )

      new_commits = log_out |> String.trim() |> String.split("\n") |> Enum.reject(&(&1 == ""))

      assert length(new_commits) == 1,
             "D-386: exactly 1 new commit expected beyond base (the agent's commit). " <>
               "Got #{length(new_commits)}: #{inspect(new_commits)}. " <>
               "A value of 2 means the shim made a redundant second commit."

      # V6 strength (iii): head_sha must equal the branch tip (the agent's commit).
      {tip_sha, 0} =
        System.cmd("git", ["rev-parse", branch], cd: repo_dir, stderr_to_stdout: true)

      assert head_sha == String.trim(tip_sha),
             "D-386: head_sha reported in work_ready must equal the branch tip. " <>
               "work_ready.head_sha=#{head_sha}, branch tip=#{String.trim(tip_sha)}"

      # D-386: no :no_work_product when HEAD advanced.
      refute_received {:worker_exit, ^worker_id, :no_work_product},
                      "D-386: must NOT surface :no_work_product when HEAD advanced (agent committed)"

      # D-386: single work_ready (no duplicate).
      refute_received {:work_ready, ^worker_id, _, _},
                      "D-386: only one work_ready must be emitted per worker"
    end

    # D-386 case (b): agent leaves uncommitted edits (HEAD == base, dirty tree).
    # Back-compat: the shim commits and emits work_ready with the SHIM's SHA.
    # This is the existing D-364 non-empty Replay path — preserved by D-386.
    @tag :d_386
    test "D-386 case (b): uncommitted edits (HEAD == base, dirty) — shim commits and emits work_ready (back-compat)" do
      tmp_dir = mk_tmp("d386_uncommitted")
      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)

      branch = "feat/d386-uncommitted"
      n = System.unique_integer([:positive])
      shim_bin = Path.join(tmp_dir, "shim_d386_uncommitted_#{n}")

      # Use the Replay adapter: Replay emits FileEdit events that the shim
      # materializes as real files in the worktree (dirty tree, HEAD unchanged).
      shim_bin =
        CodingAgentShim.write(shim_bin,
          adapter: Tau.CodingAgents.Replay,
          replay_fixture: uncommitted_edits_fixture(""),
          branch: branch
        )

      {sup, registry_name} = start_fleet(:d386_uncommitted)
      report_to = self()

      {:ok, worker_id} =
        @worker_supervisor.spawn(sup, :implementer, "D-386 uncommitted edits brief", base_ref,
          repo_dir: repo_dir,
          agent_bin: shim_bin,
          report_to: report_to,
          registry: registry_name
        )

      # D-386 case (b): dirty tree, HEAD == base → shim commits and emits work_ready.
      assert_receive {:work_ready, ^worker_id, ^branch, head_sha},
                     10_000,
                     "D-386 case (b): shim must commit uncommitted edits and emit work_ready (back-compat D-364)"

      # head_sha must be a real 40-char SHA (the shim's commit).
      assert Regex.match?(~r/\A[0-9a-fA-F]{40}\z/, head_sha),
             "D-386 case (b): head_sha must be a 40-char commit SHA; got #{inspect(head_sha)}"

      # Exactly one new commit beyond base.
      {log_out, 0} =
        System.cmd(
          "git",
          ["log", "--oneline", "#{base_ref}..#{branch}"],
          cd: repo_dir,
          stderr_to_stdout: true
        )

      new_commits = log_out |> String.trim() |> String.split("\n") |> Enum.reject(&(&1 == ""))

      assert length(new_commits) == 1,
             "D-386 case (b): exactly 1 new commit expected (the shim's commit). Got #{length(new_commits)}"

      refute_received {:worker_exit, ^worker_id, :no_work_product},
                      "D-386 case (b): must NOT surface :no_work_product when edits were committed"
    end

    # D-386 case (c): agent does nothing (HEAD == base, clean tree).
    # Preserved D-364 / D-326 path: no work_ready, :no_work_product surfaces.
    @tag :d_386
    test "D-386 case (c): agent does nothing (HEAD == base, clean tree) — no work_ready, :no_work_product preserved" do
      tmp_dir = mk_tmp("d386_nothing")
      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)

      branch = "feat/d386-nothing"
      n = System.unique_integer([:positive])
      shim_bin = Path.join(tmp_dir, "shim_d386_nothing_#{n}")

      # Empty Replay fixture: no FileEdit events, HEAD stays at base, tree clean.
      shim_bin =
        CodingAgentShim.write(shim_bin,
          adapter: Tau.CodingAgents.Replay,
          replay_fixture: empty_diff_fixture(),
          branch: branch
        )

      {sup, registry_name} = start_fleet(:d386_nothing)
      report_to = self()

      {:ok, worker_id} =
        @worker_supervisor.spawn(sup, :implementer, "D-386 nothing brief", base_ref,
          repo_dir: repo_dir,
          agent_bin: shim_bin,
          report_to: report_to,
          registry: registry_name
        )

      # D-386 case (c): no advance, no edits → no work_ready; :no_work_product.
      assert_receive {:worker_exit, ^worker_id, :no_work_product},
                     10_000,
                     "D-386 case (c): empty run must surface :no_work_product (D-326, D-364 preserved)"

      refute_received {:work_ready, ^worker_id, _, _},
                      "D-386 case (c): empty run must NOT emit work_ready"
    end
  end
end
