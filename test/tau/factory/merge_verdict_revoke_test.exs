defmodule Tau.Factory.MergeVerdictRevokeTest do
  @moduledoc """
  Gating tests for PR #434 (P3a — MergeAuthority gen_statem + verdict-gated CAS).

  Tests AC-3 (D-300): a verdict revoked AFTER the build starts is re-read in
  :committing; the push must NOT occur and origin/main must remain unchanged.

  This pins the HR-2 value-staleness contract: `assert_all_verdicts_live/3`
  re-reads the LATEST verdict status at the merge instant, not at gate time.

  Written BEFORE production code exists (oracle-separation phase).
  These tests fail with UndefinedFunctionError until the implementer creates:
    - lib/tau/factory/merge_authority.ex
    - lib/tau/factory/merge/cas.ex

  AC linkage: AC-3 / D-300.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log

  # Runtime module references — file compiles even when modules do not yet exist.
  @merge_authority Tau.Factory.MergeAuthority
  @writer Tau.Factory.Ledger.Writer

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp seed_pass_verdicts(writer, %{hash: hash, run: run}) do
    for half <- [:critic, :reviewer] do
      {:ok, _} =
        @writer.append_verdict(writer, %{
          hash: hash,
          run: run,
          half: half,
          status: :pass,
          idempotency_key: "ikey-#{half}-#{System.unique_integer([:positive])}"
        })
    end
  end

  defp setup_git_repo(tmp_dir, unit) do
    origin_path = Path.join(tmp_dir, "origin.git")
    work_path = Path.join(tmp_dir, "work")

    {_, 0} = System.cmd("git", ["init", "-b", "main", work_path])

    git_work = fn args -> System.cmd("git", args, cd: work_path) end
    git_work.(["config", "user.email", "test@tau.test"])
    git_work.(["config", "user.name", "Tau Test"])

    File.write!(Path.join(work_path, "README"), "initial")
    git_work.(["add", "README"])
    {_, 0} = git_work.(["commit", "-m", "initial commit"])

    {_, 0} = System.cmd("git", ["init", "--bare", origin_path])
    {_, 0} = git_work.(["remote", "add", "origin", origin_path])
    {_, 0} = git_work.(["push", "-u", "origin", "main"])

    {main_oid, 0} = git_work.(["rev-parse", "HEAD"])
    main_oid = String.trim(main_oid)

    {_, 0} = git_work.(["checkout", "-b", unit.branch])
    File.write!(Path.join(work_path, "feature_#{unit.id}"), "feature")
    {_, 0} = git_work.(["add", "."])
    {_, 0} = git_work.(["commit", "-m", "feature for #{unit.branch}"])
    {tip, 0} = git_work.(["rev-parse", "HEAD"])
    tip = String.trim(tip)
    {_, 0} = git_work.(["push", "origin", unit.branch])
    {_, 0} = git_work.(["checkout", "main"])

    {origin_path, work_path, main_oid, tip}
  end

  defp origin_main_oid(origin_path) do
    {oid, 0} =
      System.cmd("git", ["rev-parse", "refs/heads/main"], cd: origin_path)

    String.trim(oid)
  end

  # ---------------------------------------------------------------------------
  # AC-3 / D-300: verdict revoked mid-build => no push, origin/main unchanged
  # ---------------------------------------------------------------------------

  describe "AC-3 / D-300 — verdict revoked after build starts; no push occurs" do
    @tag :ac_3
    @tag :d_300
    test "AC-3 / D-300: revoke a required half after :integrating starts; assert no push and origin/main unchanged" do
      tmp_dir = Briefly.create!(type: :directory)
      test_pid = self()

      unit = %{
        id: "u-revoke",
        hash: "hash-revoke-#{System.unique_integer([:positive])}",
        run: "run-revoke-001",
        branch: "feat/revoke-test"
      }

      db_path = Briefly.create!(extname: ".db")
      writer_name = :"test_ma_writer_revoke_#{System.unique_integer([:positive])}"

      writer =
        start_supervised!(
          {@writer, db_path: db_path, name: writer_name},
          id: writer_name
        )

      seed_pass_verdicts(writer, unit)

      {origin_path, work_path, initial_main_oid, tip} = setup_git_repo(tmp_dir, unit)

      # Barrier build_fun: signals test_pid and blocks until :proceed.
      # This lets the test revoke a verdict AFTER :integrating is entered
      # but BEFORE :committing can run.
      barrier_build_fun = fn _units, _base ->
        ref = make_ref()
        send(test_pid, {:at_barrier, ref, tip})

        receive do
          {:proceed, ^ref} -> :ok
        after
          10_000 -> raise "barrier timeout in verdict_revoke test"
        end

        {:built, [unit], initial_main_oid, tip}
      end

      ma_name = :"test_ma_revoke_#{System.unique_integer([:positive])}"
      tasks_name = :"test_ma_tasks_revoke_#{System.unique_integer([:positive])}"

      ma_pid =
        start_supervised!(
          {@merge_authority,
           name: ma_name,
           ledger: writer,
           repo_dir: work_path,
           required_halves: [:critic, :reviewer],
           tasks_name: tasks_name,
           build_fun: barrier_build_fun},
          id: ma_name
        )

      # Submit unit — returns :queued immediately (non-blocking, [C206])
      assert :queued = @merge_authority.request_merge(ma_pid, unit)

      # Wait for M to enter :integrating and reach the barrier
      assert_receive {:at_barrier, ref, ^tip},
                     5_000,
                     "AC-3 / D-300: expected M to enter :integrating"

      # AT THE BARRIER: revoke one required half (flip :pass -> :fail)
      # This simulates a late challenge or incomplete-fix finding.
      {:ok, _} =
        @writer.revoke_verdict(writer, %{
          hash: unit.hash,
          run: unit.run,
          half: :critic,
          status: :fail,
          idempotency_key: "revoke-ikey-#{System.unique_integer([:positive])}"
        })

      # Verify the revocation is visible to the writer immediately
      assert {:ok, :fail} =
               @writer.latest_verdict_status(writer, %{
                 hash: unit.hash,
                 run: unit.run,
                 half: :critic
               }),
             "AC-3 / D-300: revocation must be readable from the writer before proceeding"

      # Release the barrier — M will proceed to :committing, re-read the verdict,
      # find :fail, and must NOT push.
      send(ma_pid, {:proceed, ref})

      # Allow M time to complete :committing
      :timer.sleep(500)

      # ASSERTION: origin/main must be unchanged — no merge occurred
      current_oid = origin_main_oid(origin_path)

      assert current_oid == initial_main_oid,
             "AC-3 / D-300 (D-300, HR-2): a revoked verdict must prevent the push; " <>
               "origin/main advanced from #{initial_main_oid} to #{current_oid} — MERGE OCCURRED (VIOLATION)"
    end

    @tag :ac_3
    @tag :d_300
    test "AC-3 / D-300: when both halves remain :pass, merge lands (baseline for the revoke test)" do
      # This baseline ensures the barrier seam and git topology actually work:
      # without revocation, a push with valid CAS should land.
      tmp_dir = Briefly.create!(type: :directory)
      test_pid = self()

      unit = %{
        id: "u-baseline",
        hash: "hash-baseline-#{System.unique_integer([:positive])}",
        run: "run-baseline-001",
        branch: "feat/baseline-test"
      }

      db_path = Briefly.create!(extname: ".db")
      writer_name = :"test_ma_writer_baseline_#{System.unique_integer([:positive])}"

      writer =
        start_supervised!(
          {@writer, db_path: db_path, name: writer_name},
          id: writer_name
        )

      seed_pass_verdicts(writer, unit)

      {origin_path, work_path, initial_main_oid, tip} = setup_git_repo(tmp_dir, unit)

      barrier_build_fun = fn _units, _base ->
        ref = make_ref()
        send(test_pid, {:at_barrier, ref, tip})

        receive do
          {:proceed, ^ref} -> :ok
        after
          10_000 -> raise "barrier timeout in baseline test"
        end

        {:built, [unit], initial_main_oid, tip}
      end

      ma_name = :"test_ma_baseline_#{System.unique_integer([:positive])}"
      tasks_name = :"test_ma_tasks_baseline_#{System.unique_integer([:positive])}"

      ma_pid =
        start_supervised!(
          {@merge_authority,
           name: ma_name,
           ledger: writer,
           repo_dir: work_path,
           required_halves: [:critic, :reviewer],
           tasks_name: tasks_name,
           build_fun: barrier_build_fun},
          id: ma_name
        )

      assert :queued = @merge_authority.request_merge(ma_pid, unit)
      assert_receive {:at_barrier, ref, ^tip}, 5_000

      # Do NOT revoke — both verdicts remain :pass
      send(ma_pid, {:proceed, ref})

      # Allow M time to complete the push
      :timer.sleep(800)

      # With valid verdicts and a fresh lease, the push should have landed.
      # origin/main should now equal tip.
      current_oid = origin_main_oid(origin_path)

      assert current_oid == tip,
             "AC-3 baseline: with PASS verdicts and no stale ref, origin/main must advance to tip; " <>
               "expected #{tip}, got #{current_oid}"
    end
  end
end
