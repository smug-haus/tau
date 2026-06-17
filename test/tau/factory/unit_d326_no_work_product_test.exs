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

  The existing tests cover the boundary in isolation:
  - `worker_completion_event_test.exs` Oracle 3: Worker side only — a real
    Worker running a real agent binary that exits 0 without work_ready emits
    `{:worker_exit, worker_id, :no_work_product}` to `report_to`.
  - `unit_worker_exit_test.exs`: Unit side only — the Unit processes a
    SYNTHETIC `{:worker_exit, worker_id, :no_work_product}` message (no real
    Worker or agent binary involved).

  **This test closes the gap**: it exercises the complete enforcement chain
  end-to-end through the real `Tau.Factory.Unit` entry point
  (`UnitSupervisor.start_unit/2`) with a `worker_fun` that calls the real
  `WorkerSupervisor.spawn/5` backed by a real agent binary that exits 0
  without emitting a work_ready frame for the implementing phase. The Worker
  converts the silent exit into `worker_exit(:no_work_product)` and delivers
  it to the Unit (via `report_to: self()` — the Unit's own pid), which must
  route it to the retry ladder — NOT to the gate.

  The oracle phase uses a work-ready-emitting agent so the Unit advances
  to :implementing normally; the D-326 enforcement is tested on the
  implementing phase only.

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

  # An agent binary that emits ONE {:packet,4}-framed JSON work_ready frame
  # and then exits 0. Used for the oracle phase so the Unit advances normally.
  defp work_ready_agent_bin(tmp_dir, branch, head_sha) do
    bin_path = Path.join(tmp_dir, "wr_agent_#{System.unique_integer([:positive])}")

    json = ~s({"type":"work_ready","branch":"#{branch}","head_sha":"#{head_sha}"})
    len = byte_size(json)

    b0 = Bitwise.band(Bitwise.bsr(len, 24), 0xFF)
    b1 = Bitwise.band(Bitwise.bsr(len, 16), 0xFF)
    b2 = Bitwise.band(Bitwise.bsr(len, 8), 0xFF)
    b3 = Bitwise.band(len, 0xFF)

    oct = fn b -> "\\" <> (b |> Integer.to_string(8) |> String.pad_leading(3, "0")) end
    len_prefix = oct.(b0) <> oct.(b1) <> oct.(b2) <> oct.(b3)

    File.write!(bin_path, """
    #!/bin/sh
    printf '#{len_prefix}'
    printf '%s' '#{json}'
    exit 0
    """)

    File.chmod!(bin_path, 0o755)
    bin_path
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
  # → the Unit routes :no_work_product to the retry ladder, NEVER gates.
  #
  # Oracle phase: real Worker with work-ready-emitting agent (oracle advances
  # to implementing normally).
  # Implementing phase: real Worker with silent-exit-0 agent (D-326 boundary).
  # ---------------------------------------------------------------------------

  describe "D-326 end-to-end — real Worker runs silent-exit-0 agent → Unit routes :no_work_product to retry ladder" do
    @tag :d_326
    test "D-326: implementing Worker that exits 0 without work_ready routes :no_work_product to retry ladder — gate_fun never called" do
      test_pid = self()
      n = System.unique_integer([:positive])
      unit_id = "u-d326-nwp-#{n}"
      scheduler_name = :"sched_d326_nwp_#{n}"
      unit_sup_name = :"unitsup_d326_nwp_#{n}"
      worker_reg_name = :"wreg_d326_nwp_#{n}"
      worker_sup_name = :"wsup_d326_nwp_#{n}"

      tmp_dir = mk_tmp()
      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)

      # Oracle agent: emits work_ready so the Unit advances oracle → implementing.
      oracle_agent = work_ready_agent_bin(tmp_dir, "feat/oracle", "aabb0011")
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
      # We use role to select which agent binary to run:
      # - :oracle  → work_ready agent (Unit advances to implementing)
      # - :implementer → silent-exit-0 agent (D-326 boundary under test)
      worker_fun = fn role ->
        unit_pid = self()

        # Oracle phase uses :test_author role; implementing phase uses :implementer.
        agent_bin = if role == :test_author, do: oracle_agent, else: impl_agent

        {:ok, worker_id} =
          @worker_supervisor.spawn(
            worker_sup_name,
            role,
            "test brief",
            base_ref,
            repo_dir: repo_dir,
            agent_bin: agent_bin,
            report_to: unit_pid,
            registry: worker_reg_name
          )

        case resolve_pid_from_registry(worker_reg_name, worker_id) do
          {:ok, worker_pid} ->
            {:ok, worker_pid, worker_id}

          {:error, reason} ->
            {:error, reason}
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
        timeouts: [state_timeout_ms: 10_000]
      ]

      unit_pid = @unit_supervisor.start_unit(unit_sup_name, opts)
      assert is_pid(unit_pid), "D-326: start_unit must return a pid"

      # Poll until the Unit has entered implementing AND its attempt_count has
      # incremented beyond 1 (indicating the retry ladder has fired at least once
      # due to the :no_work_product from the silent-exit-0 implementing worker),
      # OR it escalates (ladder exhausted — still a D-326-conformant outcome).
      #
      # The oracle phase completes normally (work_ready emitted), so
      # attempt_count == 1 in the first implementing pass; after the silent agent
      # exits 0 and the Worker delivers worker_exit(:no_work_product), the Unit
      # routes it to the retry ladder and re-enters implementing with
      # attempt_count == 2.
      final_state =
        Enum.reduce_while(1..200, nil, fn _, _ ->
          Process.sleep(50)

          case :sys.get_state(unit_pid) do
            {:implementing, data} when data.attempt_count > 1 ->
              # Retry ladder fired: attempt_count incremented after :no_work_product.
              {:halt, {:implementing, data}}

            {:gating, _data} ->
              # D-326 violation: the Unit gated on a worker that did not emit work_ready.
              {:halt, {:gating_violation, :gating}}

            {:escalated, data} ->
              # Ladder exhausted — D-326 conformant (gate was never called).
              {:halt, {:escalated, data}}

            {:merged, data} ->
              # Should not happen — gate_fun only runs after work_ready, which never arrives.
              {:halt, {:merged_violation, data}}

            _ ->
              {:cont, nil}
          end
        end)

      gate_calls = :counters.get(gate_called_ref, 1)

      # D-326 primary assertion: gate_fun must NEVER be called when the
      # implementing worker exits 0 without emitting a work_ready frame.
      assert gate_calls == 0,
             "D-326 [B4/B8] end-to-end: gate_fun MUST NOT be called when the implementing " <>
               "worker's agent exits 0 without emitting a work_ready frame. " <>
               "The Worker must convert exit-0-without-work_ready to " <>
               "worker_exit(:no_work_product) and the Unit must route it to the retry ladder. " <>
               "gate_fun was called #{gate_calls} times. " <>
               "FAIL: this indicates either (1) the Worker forwarded a work_ready despite no " <>
               "in-band frame, (2) the Worker reported exit-0 as a successful completion, " <>
               "or (3) the Unit treated exit-0-without-work_ready as completing the D-326 " <>
               "implementing→gating transition."

      refute match?({:gating_violation, _}, final_state),
             "D-326 [B4/B8] end-to-end: Unit MUST NOT enter :gating on an implementing " <>
               "worker that exits 0 without emitting a work_ready frame. " <>
               "exit-0-without-work_ready must produce worker_exit(:no_work_product), " <>
               "routed to the retry ladder, never the gate."

      refute match?({:merged_violation, _}, final_state),
             "D-326 [B4/B8]: Unit must NOT reach :merged when no work_ready was emitted."

      # The Unit must have advanced the retry ladder (re-entered implementing with
      # attempt_count > 1) OR escalated (ladder exhausted — both are D-326-conformant).
      assert match?({:implementing, _}, final_state) or match?({:escalated, _}, final_state),
             "D-326 [B4/B8] end-to-end: after a silent-exit-0 implementing worker, the Unit " <>
               "must re-enter :implementing (retry ladder fired) or reach :escalated " <>
               "(ladder exhausted). Got: #{inspect(final_state)}. " <>
               "gate_fun calls: #{gate_calls}."

      case final_state do
        {:implementing, data} ->
          assert data.attempt_count > 1,
                 "D-326 [B4/B8]: attempt_count must exceed 1 after the retry ladder fires " <>
                   "for :no_work_product; got attempt_count=#{data.attempt_count}"

        {:escalated, _} ->
          # Acceptable: ladder fired until exhausted (D-318). Gate was still 0.
          :ok

        _ ->
          :ok
      end
    end
  end
end
