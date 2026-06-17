defmodule Tau.Factory.D335MutationRequiredHalfTest do
  @moduledoc """
  Gating test for issue #638 (D-335 — CON-6 verdict conservation gap).

  D-335 states: a unit is `merged` only with a fresh PASS verdict per required
  gate half for its exact `hash`. The engine-fixed gate floor is
  `[:mutation, :critic, :reviewer]` (Gate.gate_floor/0, D-354), so `:mutation`
  is a required gate half by design.

  The gap: MergeAuthority.init/1 and Tau.Factory.Supervisor.init/1 both default
  `required_halves` to `[:critic, :reviewer]`, omitting `:mutation`. A unit with
  PASS verdicts only for `:critic` and `:reviewer` (no `:mutation` PASS) can
  therefore be merged in the default deployment configuration, directly falsifying
  D-335.

  This test exercises the real entry point — MergeAuthority.start_link/1 with NO
  `required_halves` override (the default deployment path) and
  MergeAuthority.request_merge/2 — with a unit that has PASS verdicts only for
  `:critic` and `:reviewer`. It asserts that cas_push is NOT called, i.e. the
  merge is blocked because the `:mutation` PASS verdict is absent.

  AC linkage: D-335.

  Written BEFORE any production fix exists (oracle-separation phase).
  This test FAILS against the current code because the default required_halves
  of [:critic, :reviewer] allows a merge without a :mutation PASS verdict,
  causing cas_push to be called even though :mutation has no PASS verdict.
  """

  use ExUnit.Case, async: true

  alias Tau.Factory.Ledger.Writer
  alias Tau.Factory.MergeAuthority

  @moduletag :capture_log

  @tag :d_335
  test "D-335: default required_halves must include :mutation; a unit with no :mutation PASS verdict must NOT reach cas_push" do
    test_pid = self()
    tmp_dir = Briefly.create!(type: :directory)

    unit = %{
      id: "u-d335-mutation-#{System.unique_integer([:positive])}",
      hash: "hash-d335-#{System.unique_integer([:positive])}",
      run: "run-d335-001",
      branch: "feat/d335-mutation-test-#{System.unique_integer([:positive])}"
    }

    db_path = Briefly.create!(extname: ".db")
    writer_name = :"d335_writer_#{System.unique_integer([:positive])}"

    writer =
      start_supervised!(
        {Writer, db_path: db_path, name: writer_name},
        id: writer_name
      )

    # Seed PASS verdicts for :critic and :reviewer ONLY — NO :mutation PASS.
    # This mirrors the default deployment configuration: a PR that has passed
    # the two default required halves but NOT the gate-floor-required :mutation half.
    for half <- [:critic, :reviewer] do
      {:ok, _} =
        Writer.append_verdict(writer, %{
          hash: unit.hash,
          run: unit.run,
          half: half,
          status: :pass,
          idempotency_key: "d335-ikey-#{half}-#{System.unique_integer([:positive])}"
        })
    end

    # Build a real git topology so fetch_main_oid/1 succeeds (it runs before the
    # injected build_fun). The topology: bare origin + working clone with feature branch.
    origin_path = Path.join(tmp_dir, "origin.git")
    work_path = Path.join(tmp_dir, "work")

    {_, 0} = System.cmd("git", ["init", "-b", "main", work_path])
    git_work = fn args -> System.cmd("git", args, cd: work_path, stderr_to_stdout: true) end
    git_work.(["config", "user.email", "test@tau.test"])
    git_work.(["config", "user.name", "Tau Test"])

    File.write!(Path.join(work_path, "README"), "initial\n")
    git_work.(["add", "README"])
    {_, 0} = git_work.(["commit", "-m", "initial commit"])

    {_, 0} = System.cmd("git", ["init", "--bare", origin_path])
    {_, 0} = System.cmd("git", ["symbolic-ref", "HEAD", "refs/heads/main"], cd: origin_path)
    {_, 0} = git_work.(["remote", "add", "origin", origin_path])
    {_, 0} = git_work.(["push", "-u", "origin", "main"])

    # Feature branch with a commit — tip is used by the build_fun stub.
    {_, 0} = git_work.(["checkout", "-b", unit.branch])
    File.write!(Path.join(work_path, "feature_#{unit.id}"), "feature content\n")
    {_, 0} = git_work.(["add", "."])
    {_, 0} = git_work.(["commit", "-m", "feature for #{unit.branch}"])
    {tip_raw, 0} = git_work.(["rev-parse", "HEAD"])
    tip = String.trim(tip_raw)
    {_, 0} = git_work.(["push", "origin", unit.branch])
    {_, 0} = git_work.(["checkout", "main"])

    # Record the base OID of origin/main before any merge attempt.
    {base_oid_raw, 0} =
      System.cmd("git", ["rev-parse", "refs/heads/main"], cd: origin_path)

    base_oid = String.trim(base_oid_raw)

    # A CAS module whose assert_all_verdicts_live delegates to the real Ledger.Writer
    # so the verdict check is genuine. cas_push signals the test process when invoked —
    # if it fires at all, the merge was attempted despite the absent :mutation PASS.
    #
    # We store the test_pid in persistent_term so the defmodule body (which cannot
    # close over outer variables) can retrieve it.
    pterm_key = {__MODULE__, :test_pid, unit.id}
    :persistent_term.put(pterm_key, test_pid)

    defmodule D335ObservingCas do
      @moduledoc false

      def assert_all_verdicts_live(ledger, units, required_halves) do
        alias Tau.Factory.Ledger.Writer

        Enum.reduce_while(units, :all_pass, fn u, :all_pass ->
          all_pass? =
            Enum.all?(required_halves, fn half ->
              case Writer.latest_verdict_status(ledger, %{
                     hash: u.hash,
                     run: u.run,
                     half: half
                   }) do
                {:ok, :pass} -> true
                _ -> false
              end
            end)

          if all_pass? do
            {:cont, :all_pass}
          else
            {:halt, {:revoked, u}}
          end
        end)
      end

      def cas_push(repo_dir, tip, expected_oid) do
        # Signal: cas_push was called. The test treats this as a D-335 violation.
        keys =
          :persistent_term.get()
          |> Enum.filter(fn
            {{Tau.Factory.D335MutationRequiredHalfTest, :test_pid, _}, _} -> true
            _ -> false
          end)

        case keys do
          [{_, pid} | _] when is_pid(pid) ->
            send(pid, {:cas_push_called, repo_dir, tip, expected_oid})

          _ ->
            :ok
        end

        :ok
      end
    end

    ma_name = :"d335_ma_#{System.unique_integer([:positive])}"
    tasks_name = :"d335_ma_tasks_#{System.unique_integer([:positive])}"

    # Start MergeAuthority WITHOUT specifying :required_halves — use the default.
    # D-335 + Gate.gate_floor/0 require the default to be [:mutation, :critic, :reviewer].
    # Current code defaults to [:critic, :reviewer], omitting :mutation.
    _ma_pid =
      start_supervised!(
        {
          MergeAuthority,
          # Inject an instant build_fun — we test verdict gating, not build mechanics.
          # Inject the observing CAS that performs the real verdict check.
          name: ma_name,
          ledger: writer,
          repo_dir: work_path,
          tasks_name: tasks_name,
          build_fun: fn units, base -> {:built, units, base, tip} end,
          cas: D335ObservingCas
        },
        id: ma_name
      )

    # Submit the unit for merging. Non-blocking; returns :queued immediately.
    assert :queued = MergeAuthority.request_merge(ma_name, unit)

    # Allow MergeAuthority time to complete the full cycle (instant build_fun).
    :timer.sleep(300)

    # D-335 assertion: cas_push MUST NOT have been called.
    # If it was called, MergeAuthority reached the push stage despite the absent
    # :mutation PASS verdict — a direct D-335 (CON-6) violation.
    #
    # Against current code (default required_halves = [:critic, :reviewer]):
    #   - assert_all_verdicts_live checks only :critic and :reviewer → :all_pass
    #   - cas_push IS called → this assertion FAILS (test correctly gates the bug)
    #
    # After the fix (default required_halves = Gate.gate_floor() = [:mutation, :critic, :reviewer]):
    #   - assert_all_verdicts_live checks :mutation → :none → {:revoked, unit}
    #   - cas_push is NOT called → this assertion PASSES
    refute_received {:cas_push_called, _, _, _},
                    "D-335 (CON-6, issue #638): cas_push was called despite the absent :mutation " <>
                      "PASS verdict. The default required_halves MUST include :mutation " <>
                      "(Gate.gate_floor/0 = [:mutation, :critic, :reviewer]). " <>
                      "Current default [:critic, :reviewer] omits the gate_floor :mutation half, " <>
                      "allowing a merge to land without the mutation gate passing. " <>
                      "base_oid=#{base_oid} tip=#{tip}"
  end
end
