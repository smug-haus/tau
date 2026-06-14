defmodule Tau.Factory.CodingAgentShimContainmentTest do
  @moduledoc """
  Gating test for PR #504 (#487 — A1: wire real Tau.CodingAgent substrate as the
  worker agent). Advances AC-14, D-367 (SPEC-FACTORY-FLEET §4 B4-A1, §6).

  Written BEFORE production code exists (oracle-separation, factory-loop §4b).
  These tests MUST FAIL against the current branch because:
    - `Tau.Factory.CodingAgentShim` does not exist yet.
    - Calling `Tau.Factory.CodingAgentShim.write/2` will raise
      `UndefinedFunctionError`.

  ## The contract under test (D-367)

  SPEC-FACTORY-FLEET §4 B4-A1 and §6 D-367:

    * The shim Port is linked into the Worker (D-316), so a shim crash
      propagates to the Worker exactly as the canned script's would; the
      Worker's death-cert + janitor capture (B5) are unchanged.
    * The shim links/monitors its own ClaudeCode dispatcher so a `claude`
      crash surfaces in-stream as a non-recoverable `%Error{recoverable:
      false}` / `%Done{exit_status: -1}` (SPEC-CODING-AGENT D-035), NOT a
      silent shim hang.
    * No `try/rescue` crosses the Worker↔shim Port boundary.
    * `□( crashes(claude) ⇒ surfaces in-stream Done/Error, not silent-hang )`
      ∧ `□( crashes(shim) ⇒ blast_radius ⊆ {worker} )`.

  ## Test strategy

  We inject dispatcher/adapter failures via the Replay adapter's error path:
  a fixture whose `%Error{recoverable: false}` causes the dispatcher to
  manufacture a synthetic `%Done{exit_status: -1}` (SPEC-CODING-AGENT B1
  guarantee). The shim must NOT hang on this path — it must exit non-zero
  promptly so the Worker observes `{:exit_status, n}` and surfaces a
  death-certificate.

  Two cases:
  1. **Non-recoverable Error + Done{-1}**: the Replay fixture emits
     `%Error{recoverable: false}` (which the dispatcher maps to
     `%Done{exit_status: -1}`). The shim exits non-zero. The Worker
     surfaces `{:worker_exit, worker_id, {:exit_status, n}}`. No hang.
  2. **Sibling-worker isolation**: one Worker runs a crashing shim; a
     sibling Worker running a clean shim is unaffected (blast radius = {w}).

  ## AC linkage
    - AC-14 / D-367 — all tests below.
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log
  @moduletag :ac_14
  @moduletag :d_367

  alias Tau.CodingAgent.Event
  alias Tau.Factory.CodingAgentShim

  @worker_registry Tau.Factory.WorkerRegistry
  @worker_supervisor Tau.Factory.WorkerSupervisor

  # Maximum time (ms) we allow the shim to resolve a crash before we declare hang.
  @crash_resolve_timeout_ms 5_000

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
    registry_name = :"cont_reg_#{tag}_#{n}"
    sup_name = :"cont_sup_#{tag}_#{n}"

    {:ok, _reg} =
      start_supervised({@worker_registry, name: registry_name}, id: :"reg_#{n}")

    {:ok, sup} =
      start_supervised(
        {@worker_supervisor, name: sup_name, registry: registry_name},
        id: :"sup_#{n}"
      )

    {sup, registry_name}
  end

  # A fixture that simulates a non-recoverable adapter/dispatcher failure.
  # SPEC-CODING-AGENT B1: the dispatcher guarantees exactly one %Done{} even
  # when an unrecoverable Error is encountered; the synthetic sentinel is -1.
  defp crash_fixture do
    [
      %Event.Start{agent: :replay, version: "0.0.0", pid: nil},
      %Event.AssistantText{text: "about to crash", turn: 0},
      %Event.Error{reason: :dispatcher_crash, recoverable: false},
      %Event.Done{exit_status: -1, final_message: nil}
    ]
  end

  # A fixture that completes successfully with a non-empty diff.
  defp success_fixture do
    [
      %Event.Start{agent: :replay, version: "0.0.0", pid: nil},
      %Event.AssistantText{text: "clean run", turn: 0},
      %Event.FileEdit{path: "output_sibling.txt", kind: :create},
      %Event.Cost{tokens: %{}, usd: 0.0, duration_ms: 0},
      %Event.Done{exit_status: 0, final_message: nil}
    ]
  end

  # ---------------------------------------------------------------------------
  # D-367 test 1: dispatcher crash surfaces as terminal event, not a silent hang
  #
  # Full contract: a non-recoverable %Error{} + Done{-1} in the stream causes
  # the shim to exit non-zero promptly; the Worker surfaces
  # {:worker_exit, worker_id, {:exit_status, n}}. NOT a silent hang.
  # □( crashes(claude) ⇒ surfaces in-stream Done/Error, not silent-hang )
  # ---------------------------------------------------------------------------

  describe "D-367 crash containment" do
    @tag :ac_14
    @tag :d_367
    test "D-367: dispatcher crash surfaces as terminal event not a silent hang" do
      tmp_dir = mk_tmp("shim_crash")
      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)

      n = System.unique_integer([:positive])
      shim_bin = Path.join(tmp_dir, "shim_crash_#{n}")

      # D-367: UndefinedFunctionError on current branch — correct fail-before state.
      shim_bin =
        CodingAgentShim.write(shim_bin,
          adapter: Tau.CodingAgents.Replay,
          replay_fixture: crash_fixture(),
          branch: "feat/crash-#{n}",
          workspace_backend: Tau.CodingAgent.Workspace.Cwd
        )

      {sup, registry_name} = start_fleet(:shim_crash)
      report_to = self()

      {:ok, worker_id} =
        @worker_supervisor.spawn(sup, :implementer, "crash test brief", base_ref,
          repo_dir: repo_dir,
          agent_bin: shim_bin,
          report_to: report_to,
          registry: registry_name
        )

      # D-367: crash must resolve as a death-cert within the timeout — not hang.
      # The Worker surfaces {:worker_exit, worker_id, {:exit_status, n}} for n != 0.
      assert_receive {:worker_exit, ^worker_id, reason},
                     @crash_resolve_timeout_ms,
                     "D-367: a non-recoverable stream error + Done{-1} must cause the shim to " <>
                       "exit non-zero and the Worker to surface a {:worker_exit, worker_id, reason} " <>
                       "death-cert within #{@crash_resolve_timeout_ms}ms. A silent hang here violates " <>
                       "D-367. Fails on current branch: Tau.Factory.CodingAgentShim is undefined."

      # D-367: the reason must indicate a non-zero exit (not a normal/no_work_product).
      assert reason not in [:normal, :no_work_product],
             "D-367: crash path must NOT surface :normal or :no_work_product; got #{inspect(reason)}"

      # D-367: no false work_ready must have been emitted before the crash.
      refute_received {:work_ready, ^worker_id, _, _},
                      "D-367: a crashing shim must NOT emit a work_ready frame"
    end

    # D-367 test 2: blast radius — sibling worker unaffected by crashing shim
    #
    # Full contract: □( crashes(shim) ⇒ blast_radius ⊆ {worker} ).
    # One Worker's shim crashes; its sibling Worker running a clean shim
    # completes with work_ready unaffected.
    @tag :ac_14
    @tag :d_367
    test "D-367: crash blast radius is contained to the crashing worker, sibling unaffected" do
      tmp_dir = mk_tmp("shim_blast")
      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)

      n = System.unique_integer([:positive])
      crash_bin = Path.join(tmp_dir, "shim_crash_blast_#{n}")
      clean_bin = Path.join(tmp_dir, "shim_clean_blast_#{n}")

      # D-367: UndefinedFunctionError on current branch — correct fail-before state.
      crash_bin =
        CodingAgentShim.write(crash_bin,
          adapter: Tau.CodingAgents.Replay,
          replay_fixture: crash_fixture(),
          branch: "feat/crash-blast-#{n}",
          workspace_backend: Tau.CodingAgent.Workspace.Cwd
        )

      clean_bin =
        CodingAgentShim.write(clean_bin,
          adapter: Tau.CodingAgents.Replay,
          replay_fixture: success_fixture(),
          branch: "feat/clean-blast-#{n}",
          workspace_backend: Tau.CodingAgent.Workspace.Cwd
        )

      {sup, registry_name} = start_fleet(:shim_blast)
      report_to = self()

      # Spawn crashing worker.
      {:ok, crash_worker_id} =
        @worker_supervisor.spawn(sup, :implementer, "crash worker brief", base_ref,
          repo_dir: repo_dir,
          agent_bin: crash_bin,
          report_to: report_to,
          registry: registry_name
        )

      # Spawn sibling clean worker.
      {:ok, clean_worker_id} =
        @worker_supervisor.spawn(sup, :implementer, "clean worker brief", base_ref,
          repo_dir: repo_dir,
          agent_bin: clean_bin,
          report_to: report_to,
          registry: registry_name
        )

      # D-367: crashing worker must surface its death-cert within the crash window.
      assert_receive {:worker_exit, ^crash_worker_id, crash_reason},
                     @crash_resolve_timeout_ms,
                     "D-367: crashing worker must surface a death-cert within #{@crash_resolve_timeout_ms}ms"

      assert crash_reason not in [:normal, :no_work_product],
             "D-367: crash reason must be non-normal; got #{inspect(crash_reason)}"

      # D-367: sibling (clean) worker must complete successfully, unaffected by the crash.
      assert_receive {:work_ready, ^clean_worker_id, _branch, head_sha},
                     @crash_resolve_timeout_ms,
                     "D-367: the sibling (clean) worker must complete with work_ready, " <>
                       "unaffected by the crashing worker. blast_radius(crashing_w) must = " <>
                       "{crashing_w}, not {crashing_w, sibling_w}. " <>
                       "Fails on current branch: Tau.Factory.CodingAgentShim is undefined."

      assert Regex.match?(~r/\A[0-9a-fA-F]{40}\z/, head_sha),
             "D-367: sibling work_ready must carry a real 40-char sha; got #{inspect(head_sha)}"

      # D-367: crash worker must NOT have produced a work_ready.
      refute_received {:work_ready, ^crash_worker_id, _, _},
                      "D-367: the crashing worker must NOT emit a work_ready"
    end
  end
end
