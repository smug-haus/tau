defmodule Tau.Factory.UnitD326NoWorkProductTest do
  @moduledoc """
  Gating test for issue #541 / D-326 — full-chain enforcement of the
  fail-closed exit-0-without-work_ready invariant at the Unit FSM boundary.

  D-326 (SPEC-FACTORY-FLEET §4 B1/B4, SPEC-FACTORY-CORE §4 B8):

    A worker's successful completion MUST be signalled by an in-band
    work_ready(branch, head_sha) frame emitted BEFORE the agent exits, not
    by exit status 0 alone. An exit_status 0 with no prior work_ready event
    MUST be surfaced as worker_exit(worker_id, :no_work_product) to the
    Unit's retry ladder, never as success.

  Falsified by: a Unit FSM treating exit_status 0 without a prior work_ready
  frame as successful completion (advancing to :gating rather than retrying).

  ## What this test covers

  The test exercises the complete D-326 enforcement chain end-to-end through
  the real `Tau.Factory.Unit` entry point (`UnitSupervisor.start_unit/2`).

  Oracle phase: uses a synthetic in-process worker that sends the required
  5-tuple `{:work_ready, worker_id, branch, head_sha, gating_test_paths}`
  directly to the Unit. This is the INV-WF-13-conformant oracle completion
  signal required by the current Unit FSM. It is necessary because
  `Tau.Factory.Worker` sends only a 4-tuple form which the Unit now rejects
  for the oracle->implementing transition.

  Implementing phase: uses a real `WorkerSupervisor.spawn/5` backed by a real
  agent binary that exits 0 without emitting a work_ready frame. The Worker
  converts the silent exit into `worker_exit(:no_work_product)` (via the
  independent death monitor) and delivers it to the Unit, which MUST route it
  to the retry ladder — NOT to the gate.

  ## Gate-5.3 fail-before contract

  This test gates D-326 at the full-chain boundary. At the merge-base,
  the Unit's oracle state does NOT recognise the 5-tuple work_ready form
  (INV-WF-13 not yet landed). A 5-tuple oracle completion signal is treated
  as an unexpected message and discarded; the Unit stays in :oracle until
  state_timeout fires and escalates.

  The test asserts that the Unit SPECIFICALLY re-entered :implementing with
  attempt_count > 1 (the retry ladder fired for :no_work_product). This
  assertion FAILS at the merge-base because the Unit escalates from :oracle
  (never reaching :implementing), making the test a genuine gating check for
  the INV-WF-13 oracle advancement combined with D-326 routing.

  ## AC / D-NNN linkage
    - D-326 — every test in this file (gate 5.1 token).
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log
  @moduletag :d_326

  @unit_supervisor Tau.Factory.UnitSupervisor
  @scheduler Tau.Factory.Scheduler
  @worker_supervisor Tau.Factory.WorkerSupervisor

  # ---------------------------------------------------------------------------
  # Helpers
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

  # An agent binary that exits 0 WITHOUT emitting a work_ready frame.
  # D-326 fail-closed: the Worker must convert this into
  # {:worker_exit, worker_id, :no_work_product} — never a success.
  defp silent_exit0_agent_bin(tmp_dir) do
    bin_path = Path.join(tmp_dir, "silent_exit0_agent_#{System.unique_integer([:positive])}")

    File.write!(bin_path, """
    #!/bin/sh
    exit 0
    """)

    File.chmod!(bin_path, 0o755)
    bin_path
  end

  defp mk_tmp do
    tmp_dir =
      Path.join(System.tmp_dir!(), "tau_d326_nwp_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    tmp_dir
  end

  defp empty_scope do
    %{
      deps: [],
      files: MapSet.new(),
      codepoints: MapSet.new(),
      specs: MapSet.new(),
      resources: MapSet.new()
    }
  end

  # Resolve the worker pid from the registry by polling until the Worker
  # has registered itself (it registers during init/1).
  defp resolve_pid_from_registry(registry_name, worker_id, attempts \\ 20) do
    case Registry.lookup(registry_name, worker_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] when attempts > 0 ->
        Process.sleep(20)
        resolve_pid_from_registry(registry_name, worker_id, attempts - 1)

      [] ->
        {:error, :not_found}
    end
  end

  # ---------------------------------------------------------------------------
  # D-326 end-to-end: real Worker + real agent binary exits 0 without work_ready
  # -> the Unit routes :no_work_product to the retry ladder, NEVER gates.
  #
  # Oracle phase: synthetic in-process worker sends the required 5-tuple
  # work_ready (INV-WF-13-conformant) so the Unit advances to :implementing.
  # Implementing phase: real Worker with silent-exit-0 agent (D-326 boundary).
  #
  # Gate-5.3 fail-before: at the merge-base, the Unit's oracle does NOT
  # recognise the 5-tuple form — it discards it as unexpected. The Unit stays
  # in :oracle, eventually escalates (state_timeout), and never reaches
  # :implementing. The assertion `match?({:implementing, data} when data.attempt_count > 1)`
  # FAILS at the merge-base, making this a genuine gating test.
  # ---------------------------------------------------------------------------

  describe "D-326 end-to-end" do
    @tag :d_326
    test "D-326: silent-exit-0 implementing worker routes :no_work_product to retry ladder, gate never called" do
      test_pid = self()
      n = System.unique_integer([:positive])
      unit_id = "u-d326-nwp-#{n}"
      scheduler_name = :"sched_d326_nwp_#{n}"
      unit_sup_name = :"unitsup_d326_nwp_#{n}"
      worker_reg_name = :"wreg_d326_nwp_#{n}"
      worker_sup_name = :"wsup_d326_nwp_#{n}"

      tmp_dir = mk_tmp()
      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)

      # Implementing agent: exits 0 without work_ready — D-326 boundary under test.
      impl_agent = silent_exit0_agent_bin(tmp_dir)

      start_supervised!({@scheduler, name: scheduler_name, w_cap: 10}, id: scheduler_name)
      start_supervised!({@unit_supervisor, name: unit_sup_name}, id: unit_sup_name)

      start_supervised!({Tau.Factory.WorkerRegistry, name: worker_reg_name},
        id: :"wreg_#{n}"
      )

      start_supervised!(
        {@worker_supervisor, name: worker_sup_name, registry: worker_reg_name},
        id: :"wsup_#{n}"
      )

      gate_called_ref = :counters.new(1, [:atomics])

      gate_fun = fn _coord ->
        :counters.add(gate_called_ref, 1, 1)
        :pass
      end

      # The worker_fun is called from within the Unit process. self() == unit_pid.
      #
      # Oracle phase (:test_author): send the required 5-tuple work_ready via a
      # synthetic in-process worker. The 5-tuple carries a non-empty
      # gating_test_paths list, satisfying INV-WF-13 Clause 1.
      #
      # NOTE: Tau.Factory.Worker sends only 4-tuple work_ready events. The Unit
      # (after INV-WF-13) rejects 4-tuples in oracle and stays stuck. Using a
      # synthetic worker here is the only way to advance oracle->implementing.
      #
      # The synthetic worker sends the spawn request to test_pid to avoid
      # running Process.spawn inside the Unit's process (which would confuse
      # Process.monitor semantics). The Unit blocks on receive waiting for
      # {:oracle_worker_pid, pid} from the test process.
      #
      # Implementing phase (:implementer): use a real Worker backed by a
      # silent-exit-0 agent to exercise the D-326 boundary end-to-end.
      worker_fun = fn role ->
        unit_pid = self()

        case role do
          :test_author ->
            oracle_worker_id = "oracle-#{System.unique_integer([:positive])}"
            send(test_pid, {:spawn_oracle_worker, unit_pid, oracle_worker_id, self()})

            receive do
              {:oracle_worker_pid, pid} -> {:ok, pid, oracle_worker_id}
            after
              3_000 -> {:error, :oracle_worker_spawn_timeout}
            end

          :implementer ->
            {:ok, worker_id} =
              @worker_supervisor.spawn(
                worker_sup_name,
                role,
                "test brief",
                base_ref,
                repo_dir: repo_dir,
                agent_bin: impl_agent,
                report_to: unit_pid,
                registry: worker_reg_name
              )

            case resolve_pid_from_registry(worker_reg_name, worker_id) do
              {:ok, worker_pid} -> {:ok, worker_pid, worker_id}
              {:error, reason} -> {:error, reason}
            end
        end
      end

      opts = [
        unit_id: unit_id,
        declared_scope: empty_scope(),
        hash: "hash-#{unit_id}",
        scheduler: scheduler_name,
        report_to: test_pid,
        worker_fun: worker_fun,
        gate_fun: gate_fun,
        merge_fun: fn _uid, _hash -> :queued end,
        timeouts: [state_timeout_ms: 3_000]
      ]

      unit_pid = @unit_supervisor.start_unit(unit_sup_name, opts)
      assert is_pid(unit_pid), "D-326: start_unit must return a pid"

      # Serve the oracle worker spawn request from the test process.
      # The Unit's worker_fun sends {:spawn_oracle_worker, unit_pid, worker_id, reply_to}
      # to test_pid; we spawn the synthetic worker here and reply with the pid.
      oracle_worker_pid =
        receive do
          {:spawn_oracle_worker, u_pid, oracle_worker_id, reply_to} ->
            # Spawn the synthetic oracle worker. It sends the required 5-tuple
            # work_ready (INV-WF-13 Clause 1) to the Unit and stays alive briefly
            # so the Unit can monitor it.
            oracle_pid =
              spawn(fn ->
                send(
                  u_pid,
                  {:work_ready, oracle_worker_id, "feat/oracle", "aabb0011",
                   ["test/tau/factory/unit_d326_no_work_product_test.exs"]}
                )

                Process.sleep(500)
              end)

            send(reply_to, {:oracle_worker_pid, oracle_pid})
            oracle_pid
        after
          5_000 ->
            flunk("D-326: timed out waiting for oracle worker spawn request from Unit")
        end

      assert is_pid(oracle_worker_pid)

      # Poll for the Unit to re-enter :implementing with attempt_count > 1.
      #
      # This is the primary D-326 + INV-WF-13 joint assertion:
      #   - INV-WF-13: the oracle 5-tuple advances oracle->implementing (attempt_count=1)
      #   - D-326: the silent-exit-0 implementing worker fires worker_exit(:no_work_product),
      #            which the Unit routes to the retry ladder, re-entering :implementing
      #            with attempt_count=2.
      #
      # At the merge-base (Gate-5.3 reverted state), the Unit's oracle does NOT
      # recognise the 5-tuple form (INV-WF-13 not yet present). The 5-tuple is
      # discarded as an unexpected message; the Unit stays in :oracle until
      # state_timeout fires and escalates. The poll returns {:escalated, _}, and
      # the assertion `assert {:implementing, data} with attempt_count > 1`
      # FAILS — correctly gating the invariant.
      #
      # Polling up to 200 * 50ms = 10s before declaring failure.
      final_state =
        Enum.reduce_while(1..200, nil, fn _, _ ->
          Process.sleep(50)

          case :sys.get_state(unit_pid) do
            {:implementing, data} when data.attempt_count > 1 ->
              # SUCCESS: retry ladder fired for :no_work_product; D-326 confirmed.
              {:halt, {:implementing_retried, data}}

            {:gating, _data} ->
              # D-326 violation: Unit gated without a valid work_ready.
              {:halt, {:gating_violation, :gating}}

            {:escalated, data} ->
              # Possible outcomes:
              # - D-326-conformant: retry ladder exhausted (all implementing attempts failed)
              # - Gate-5.3 fail: Unit escalated from :oracle (merge-base, INV-WF-13 absent)
              # We cannot distinguish here; the assertion below handles both.
              {:halt, {:escalated, data}}

            {:merged, data} ->
              {:halt, {:merged_violation, data}}

            _ ->
              {:cont, nil}
          end
        end)

      gate_calls = :counters.get(gate_called_ref, 1)

      # -----------------------------------------------------------------------
      # D-326 primary assertion: gate_fun MUST NOT be called when the
      # implementing worker exits 0 without emitting a work_ready frame.
      # -----------------------------------------------------------------------
      assert gate_calls == 0,
             "D-326 [B4/B8] end-to-end: gate_fun MUST NOT be called when the implementing " <>
               "worker's agent exits 0 without emitting a work_ready frame. " <>
               "gate_fun was called #{gate_calls} times."

      refute match?({:gating_violation, _}, final_state),
             "D-326 [B4/B8] end-to-end: Unit MUST NOT enter :gating on an implementing " <>
               "worker that exits 0 without emitting a work_ready frame."

      refute match?({:merged_violation, _}, final_state),
             "D-326 [B4/B8]: Unit must NOT reach :merged when no work_ready was emitted."

      # -----------------------------------------------------------------------
      # Joint D-326 + INV-WF-13 assertion (primary gate-5.3 discriminator):
      # The Unit MUST have successfully advanced oracle->implementing (via
      # 5-tuple work_ready) AND the retry ladder MUST have fired at least once
      # for :no_work_product (attempt_count > 1 in :implementing).
      #
      # This assertion FAILS at the merge-base because the Unit never reaches
      # :implementing (oracle discards the 5-tuple and eventually escalates).
      # -----------------------------------------------------------------------
      assert match?({:implementing_retried, _}, final_state),
             "D-326 [B4/B8] end-to-end: after oracle advances to :implementing (via " <>
               "5-tuple work_ready) and the silent-exit-0 implementing worker fires " <>
               "worker_exit(:no_work_product), the Unit MUST re-enter :implementing " <>
               "with attempt_count > 1 (retry ladder confirmed). " <>
               "Got: #{inspect(final_state)}. gate_fun calls: #{gate_calls}. " <>
               "FAIL: either the oracle did not advance to :implementing (INV-WF-13 " <>
               "5-tuple not accepted) or the D-326 :no_work_product was not routed " <>
               "to the retry ladder."

      case final_state do
        {:implementing_retried, data} ->
          assert data.attempt_count > 1,
                 "D-326 [B4/B8]: attempt_count must exceed 1 after the retry ladder fires " <>
                   "for :no_work_product; got attempt_count=#{data.attempt_count}"

        _ ->
          :ok
      end
    end
  end
end
