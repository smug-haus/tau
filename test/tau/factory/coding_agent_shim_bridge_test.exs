defmodule Tau.Factory.CodingAgentShimBridgeTest do
  @moduledoc """
  Gating test for PR #504 (#487 — A1: wire real Tau.CodingAgent substrate as the
  worker agent). Advances AC-14, D-364 (SPEC-FACTORY-FLEET §4 B4-A1, §6).

  Written BEFORE production code exists (oracle-separation, factory-loop §4b).
  These tests MUST FAIL against the current branch because:
    - `Tau.Factory.CodingAgentShim` does not exist yet.
    - Calling `Tau.Factory.CodingAgentShim.write/2` will raise
      `UndefinedFunctionError`.

  ## The contract under test (D-364)

  SPEC-FACTORY-FLEET §4 B4-A1 and §6 D-364:

    * A `Tau.Factory.CodingAgentShim` module exposes an API to write the shim
      executable to a path (analogous to `Tau.Factory.Dogfood.Agent.write/1`).
    * The shim, when launched by the Worker as `agent_bin`, drives
      `Tau.CodingAgents.Replay` (or `Tau.CodingAgents.ClaudeCode`) over a
      deterministic stream, commits the agent's edits, and emits a
      `{"type":"work_ready","branch":"<b>","head_sha":"<real_sha>"}` `{:packet,4}`
      frame before exiting 0.
    * On a `%Done{exit_status: 0}` with a NON-EMPTY diff, the shim commits
      and emits `work_ready`; the Worker forwards
      `{:work_ready, worker_id, branch, head_sha}` to `report_to`.
    * On a `%Done{exit_status: 0}` with an EMPTY diff (agent ran, changed
      nothing), the shim emits NO `work_ready` and exits 0; the Worker's
      D-326 fail-closed maps this to `{:worker_exit, worker_id, :no_work_product}`.
    * On a `%Done{exit_status: -1}` (death / timeout / cancel) the shim emits
      NO `work_ready` and exits non-zero; the Worker maps to
      `{:worker_exit, worker_id, {:exit_status, n}}`.

  ## Pinned interface (oracle-declared)

  The shim module MUST expose at minimum:

      Tau.Factory.CodingAgentShim.write(dest_path :: String.t(), opts :: keyword()) ::
        String.t()

  where `opts` carries at minimum:
    - `:adapter`        — coding-agent adapter module (default `Tau.CodingAgents.Replay`)
    - `:replay_fixture` — list of `%Tau.CodingAgent.Event{}` for the Replay adapter
    - `:branch`         — branch name to commit to (the unit branch)

  The written executable, when invoked by the Worker Port with `{:cd, ws}`,
  must perform the branch+commit step and emit the `work_ready` frame over stdout
  using `{:packet,4}` framing.

  ## AC linkage
    - AC-14 / D-364 — all tests below.
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log
  @moduletag :ac_14
  @moduletag :d_364

  alias Tau.CodingAgent.Event
  alias Tau.Factory.CodingAgentShim

  @worker_registry Tau.Factory.WorkerRegistry
  @worker_supervisor Tau.Factory.WorkerSupervisor

  # ---------------------------------------------------------------------------
  # Hermetic git repo (mirrors worker_test.exs idiom)
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
    registry_name = :"bridge_reg_#{tag}_#{n}"
    sup_name = :"bridge_sup_#{tag}_#{n}"

    {:ok, _reg} =
      start_supervised({@worker_registry, name: registry_name}, id: :"reg_#{n}")

    {:ok, sup} =
      start_supervised(
        {@worker_supervisor, name: sup_name, registry: registry_name},
        id: :"sup_#{n}"
      )

    {sup, registry_name}
  end

  # A Replay fixture that edits a file (non-empty diff when committed).
  defp non_empty_fixture(ws) do
    [
      %Event.Start{agent: :replay, version: "0.0.0", pid: nil},
      %Event.AssistantText{text: "I will create a file", turn: 0},
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

  # A Replay fixture that ends with Done{exit_status: -1} (simulated death).
  defp failed_fixture do
    [
      %Event.Start{agent: :replay, version: "0.0.0", pid: nil},
      %Event.Error{reason: :dispatcher_crash, recoverable: false},
      %Event.Done{exit_status: -1, final_message: nil}
    ]
  end

  # ---------------------------------------------------------------------------
  # D-364 test 1: non-empty Done{0} → work_ready{branch, real_sha}
  #
  # Full contract: a Replay stream ending in Done{exit_status: 0} over a
  # non-empty worktree causes the shim to commit and emit a {:packet,4}
  # work_ready frame; the Worker forwards {:work_ready, worker_id, branch,
  # real_sha} where real_sha is the actual commit SHA, not a placeholder.
  # ---------------------------------------------------------------------------

  describe "D-364 shim bridge" do
    @tag :ac_14
    @tag :d_364
    test "D-364: non-empty Done{0} yields work_ready with real branch and sha" do
      tmp_dir = mk_tmp("shim_bridge")
      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)

      # The worktree the Worker will allocate for the shim sits beside the repo.
      # We pre-determine the branch name the shim will commit to.
      branch = "feat/agent-work"
      n = System.unique_integer([:positive])
      shim_bin = Path.join(tmp_dir, "shim_agent_#{n}")

      # D-364: Tau.Factory.CodingAgentShim MUST exist and expose a write/2 API.
      # This line fails with UndefinedFunctionError on the current branch (correct
      # fail-before state — the shim does not exist yet).
      #
      # The fixture must cause the shim to write `output.txt` inside the worktree
      # so the diff is non-empty. The worktree path is resolved by the Worker at
      # runtime; we let the shim use whatever `ws` the Worker allocates.
      shim_bin =
        CodingAgentShim.write(shim_bin,
          adapter: Tau.CodingAgents.Replay,
          replay_fixture: non_empty_fixture(_ws_placeholder = ""),
          branch: branch
        )

      assert File.exists?(shim_bin),
             "D-364: CodingAgentShim.write/2 must produce an executable file"

      {sup, registry_name} = start_fleet(:shim_bridge)
      report_to = self()

      {:ok, worker_id} =
        @worker_supervisor.spawn(sup, :implementer, "brief for #487", base_ref,
          repo_dir: repo_dir,
          agent_bin: shim_bin,
          report_to: report_to,
          registry: registry_name
        )

      # D-364: The Worker must forward {:work_ready, worker_id, branch, sha}
      # where sha is the REAL HEAD sha the shim committed (not a placeholder).
      assert_receive {:work_ready, ^worker_id, ^branch, head_sha},
                     10_000,
                     "D-364: The CodingAgentShim must emit a work_ready frame after committing " <>
                       "the agent's diff; the Worker forwards {:work_ready, worker_id, branch, head_sha}. " <>
                       "Fails on the current branch: Tau.Factory.CodingAgentShim is undefined."

      # D-364: head_sha must be a real 40-char hex SHA (the actual commit the
      # shim created), not a canned placeholder.
      assert Regex.match?(~r/\A[0-9a-fA-F]{40}\z/, head_sha),
             "D-364: head_sha must be a real 40-char commit SHA; got #{inspect(head_sha)}"

      # D-364 single-writer discipline: exactly one work_ready (no duplicate).
      refute_received {:work_ready, ^worker_id, _, _},
                      "D-364: only one work_ready must be emitted per worker (single-writer)"

      refute_received {:worker_exit, ^worker_id, :no_work_product},
                      "D-364: a worker that emitted work_ready must NOT also surface :no_work_product"
    end

    # D-364 test 2: Done{0}+empty diff → no work_ready, surfaces :no_work_product
    #
    # Full contract: a Replay stream ending in Done{exit_status: 0} with an
    # empty diff (agent ran but changed nothing) causes the shim to emit NO
    # work_ready and exit 0; the Worker's D-326 fail-closed path maps this to
    # {:worker_exit, worker_id, :no_work_product}.
    @tag :ac_14
    @tag :d_364
    test "D-364: Done{0} with empty diff yields no work_ready, surfaces :no_work_product" do
      tmp_dir = mk_tmp("shim_empty")
      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)

      branch = "feat/empty-run"
      n = System.unique_integer([:positive])
      shim_bin = Path.join(tmp_dir, "shim_empty_#{n}")

      # D-364: Again UndefinedFunctionError on current branch — correct fail-before.
      shim_bin =
        CodingAgentShim.write(shim_bin,
          adapter: Tau.CodingAgents.Replay,
          replay_fixture: empty_diff_fixture(),
          branch: branch
        )

      {sup, registry_name} = start_fleet(:shim_empty)
      report_to = self()

      {:ok, worker_id} =
        @worker_supervisor.spawn(sup, :implementer, "empty-run brief", base_ref,
          repo_dir: repo_dir,
          agent_bin: shim_bin,
          report_to: report_to,
          registry: registry_name
        )

      # D-364 fail-closed: an empty diff must NOT produce a work_ready.
      assert_receive {:worker_exit, ^worker_id, :no_work_product},
                     10_000,
                     "D-364: Done{0}+empty diff must surface {:worker_exit, worker_id, :no_work_product}, " <>
                       "not a work_ready. False-green on empty diff (D-326 requirement)."

      refute_received {:work_ready, ^worker_id, _, _},
                      "D-364: empty-diff run must NOT emit a work_ready frame"
    end

    # D-364 test 3: Done{-1} (error/death) → no work_ready, non-zero exit
    #
    # Full contract: a Replay stream ending in Done{exit_status: -1} causes the
    # shim to emit NO work_ready and exit non-zero; the Worker maps this to
    # {:worker_exit, worker_id, {:exit_status, n}} for the retry ladder.
    @tag :ac_14
    @tag :d_364
    test "D-364: Done{-1} yields no work_ready and non-zero exit for retry ladder" do
      tmp_dir = mk_tmp("shim_fail")
      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)

      branch = "feat/fail-run"
      n = System.unique_integer([:positive])
      shim_bin = Path.join(tmp_dir, "shim_fail_#{n}")

      # D-364: UndefinedFunctionError on current branch — correct fail-before.
      shim_bin =
        CodingAgentShim.write(shim_bin,
          adapter: Tau.CodingAgents.Replay,
          replay_fixture: failed_fixture(),
          branch: branch
        )

      {sup, registry_name} = start_fleet(:shim_fail)
      report_to = self()

      {:ok, worker_id} =
        @worker_supervisor.spawn(sup, :implementer, "fail-run brief", base_ref,
          repo_dir: repo_dir,
          agent_bin: shim_bin,
          report_to: report_to,
          registry: registry_name
        )

      # D-364: non-zero exit must surface as {:worker_exit, worker_id, {:exit_status, n}}.
      assert_receive {:worker_exit, ^worker_id, {:exit_status, exit_n}},
                     10_000,
                     "D-364: Done{-1} must cause the shim to exit non-zero and the Worker to " <>
                       "surface {:worker_exit, worker_id, {:exit_status, n}} for the retry ladder."

      assert exit_n != 0,
             "D-364: non-zero exit code required for Done{-1} path; got exit_n=#{inspect(exit_n)}"

      refute_received {:work_ready, ^worker_id, _, _},
                      "D-364: Done{-1} must NOT produce a work_ready"
    end
  end
end
