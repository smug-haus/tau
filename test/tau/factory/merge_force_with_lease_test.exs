defmodule Tau.Factory.MergeForceWithLeaseTest do
  @moduledoc """
  Gating tests for PR #434 (P3a — MergeAuthority gen_statem + verdict-gated CAS).

  Tests AC-4 (D-301): origin/main advancing between gate and CAS must cause the
  --force-with-lease push to be rejected; no merge must land; the unit requeues.

  This pins the HR-1 / FC-3 freshness-via-VCS-primitive contract: the CAS
  applies as `git push --force-with-lease=refs/heads/main:<expected_old_oid>`,
  so if origin/main advances after M captured `base` but before cas_push runs,
  the remote rejects the push atomically. M MUST NOT retry or force past the
  lease rejection.

  Written BEFORE production code exists (oracle-separation phase).
  These tests fail with UndefinedFunctionError until the implementer creates:
    - lib/tau/factory/merge_authority.ex
    - lib/tau/factory/merge/cas.ex

  AC linkage: AC-4 / D-301.
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
    {_, 0} = System.cmd("git", ["symbolic-ref", "HEAD", "refs/heads/main"], cd: origin_path)
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

  # Advance origin/main directly by pushing a new commit to the bare repo.
  # This simulates origin/main moving AFTER M captured `base` — the staleness scenario.
  # Done by cloning the bare repo into a separate tmp dir, committing, and pushing.
  defp advance_origin_main(origin_path) do
    advance_dir = Path.join(System.tmp_dir!(), "advance_#{System.unique_integer([:positive])}")
    File.mkdir_p!(advance_dir)

    {_, 0} = System.cmd("git", ["clone", origin_path, advance_dir])

    git_adv = fn args -> System.cmd("git", args, cd: advance_dir) end
    git_adv.(["config", "user.email", "test@tau.test"])
    git_adv.(["config", "user.name", "Tau Test"])

    File.write!(Path.join(advance_dir, "advance_#{System.unique_integer([:positive])}"), "advance")
    git_adv.(["add", "."])
    git_adv.(["commit", "-m", "advance origin/main to make base stale"])
    git_adv.(["push", "origin", "main"])

    {new_oid, 0} = git_adv.(["rev-parse", "HEAD"])
    new_oid = String.trim(new_oid)

    File.rm_rf!(advance_dir)
    new_oid
  end

  defp origin_main_oid(origin_path) do
    {oid, 0} =
      System.cmd("git", ["rev-parse", "refs/heads/main"], cd: origin_path)

    String.trim(oid)
  end

  # ---------------------------------------------------------------------------
  # AC-4 / D-301: force-with-lease rejected when origin/main advances mid-gate
  # ---------------------------------------------------------------------------

  describe "AC-4 / D-301 — --force-with-lease rejected when origin/main advances mid-gate" do
    @tag :ac_4
    @tag :d_301
    test "AC-4 / D-301: advancing origin/main at the barrier causes CAS push rejection; no merge lands" do
      tmp_dir = Briefly.create!(type: :directory)
      test_pid = self()

      unit = %{
        id: "u-stale",
        hash: "hash-stale-#{System.unique_integer([:positive])}",
        run: "run-stale-001",
        branch: "feat/stale-test"
      }

      db_path = Briefly.create!(extname: ".db")
      writer_name = :"test_ma_writer_stale_#{System.unique_integer([:positive])}"

      writer =
        start_supervised!(
          {@writer, db_path: db_path, name: writer_name},
          id: writer_name
        )

      seed_pass_verdicts(writer, unit)

      {origin_path, work_path, initial_main_oid, tip} = setup_git_repo(tmp_dir, unit)

      # Barrier build_fun: signals test_pid at the barrier point with the tip oid.
      # Blocks until :proceed. Returns the ORIGINAL base (which will become stale).
      barrier_build_fun = fn _units, base ->
        ref = make_ref()
        send(test_pid, {:at_barrier, ref, base, tip})

        receive do
          {:proceed, ^ref} -> :ok
        after
          10_000 -> raise "barrier timeout in force_with_lease test"
        end

        # Return the original base — M will use this as expected_old_oid in cas_push.
        # By the time M calls cas_push, origin/main will have advanced past this oid.
        {:built, [unit], base, tip}
      end

      ma_name = :"test_ma_stale_#{System.unique_integer([:positive])}"
      tasks_name = :"test_ma_tasks_stale_#{System.unique_integer([:positive])}"

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

      # Wait for M to enter :integrating and reach the barrier
      assert_receive {:at_barrier, ref, base, ^tip},
                     5_000,
                     "AC-4 / D-301: expected M to enter :integrating and hit the barrier"

      # VERIFY: base matches initial_main_oid (M captured the correct base)
      assert base == initial_main_oid,
             "AC-4 / D-301: M must capture initial main oid as base; " <>
               "expected #{initial_main_oid}, got #{base}"

      # AT THE BARRIER: advance origin/main directly (bypassing M — test-only).
      # This makes M's captured `base` stale.
      advancing_oid = advance_origin_main(origin_path)

      # Verify origin/main has advanced
      assert origin_main_oid(origin_path) == advancing_oid,
             "AC-4 / D-301: test setup error — origin/main did not advance"

      refute advancing_oid == initial_main_oid,
             "AC-4 / D-301: test setup error — advancing oid must differ from initial"

      # Release the barrier — M proceeds to :committing with stale `base`.
      # cas_push must issue `git push --force-with-lease=refs/heads/main:<initial_main_oid>`
      # which the remote will REJECT because origin/main is now at advancing_oid.
      send(ma_pid, {:proceed, ref})

      # Allow M time to attempt and fail the push
      :timer.sleep(800)

      # ASSERTION 1: origin/main must equal the test's advancing commit, NOT the unit's tip.
      # The rejected push must not have overwritten advancing_oid.
      current_oid = origin_main_oid(origin_path)

      assert current_oid == advancing_oid,
             "AC-4 / D-301 (D-301, HR-1, FC-3): --force-with-lease push must be rejected " <>
               "when origin/main advanced; origin/main must remain at the advancing commit.\n" <>
               "Expected: #{advancing_oid}\n" <>
               "Got:      #{current_oid}\n" <>
               "This means M pushed past a stale lease — VIOLATION of D-301 (freshness via VCS primitive)"

      # ASSERTION 2: origin/main must NOT equal the unit tip (no merge landed).
      refute current_oid == tip,
             "AC-4 / D-301: the unit tip must NOT be on origin/main after a stale-ref rejection; " <>
               "tip #{tip} is now on origin/main — merge occurred despite stale lease"
    end

    @tag :ac_4
    @tag :d_301
    test "AC-4 / D-301: Merge.Cas.cas_push returns {:error, :stale_ref} when origin/main advanced" do
      # Directly exercises Tau.Factory.Merge.Cas.cas_push/3 in isolation:
      # set up a repo where origin/main has advanced past expected_old_oid,
      # call cas_push, assert {:error, :stale_ref}.
      tmp_dir = Briefly.create!(type: :directory)
      origin_path = Path.join(tmp_dir, "origin_cas.git")
      work_path = Path.join(tmp_dir, "work_cas")

      {_, 0} = System.cmd("git", ["init", "-b", "main", work_path])

      git_work = fn args -> System.cmd("git", args, cd: work_path) end
      git_work.(["config", "user.email", "test@tau.test"])
      git_work.(["config", "user.name", "Tau Test"])

      File.write!(Path.join(work_path, "README"), "initial")
      git_work.(["add", "README"])
      {_, 0} = git_work.(["commit", "-m", "initial"])
      {_, 0} = System.cmd("git", ["init", "--bare", origin_path])
      {_, 0} = System.cmd("git", ["symbolic-ref", "HEAD", "refs/heads/main"], cd: origin_path)
      {_, 0} = git_work.(["remote", "add", "origin", origin_path])
      {_, 0} = git_work.(["push", "-u", "origin", "main"])

      {old_oid, 0} = git_work.(["rev-parse", "HEAD"])
      old_oid = String.trim(old_oid)

      # Create a feature branch tip
      {_, 0} = git_work.(["checkout", "-b", "feat/cas-test"])
      File.write!(Path.join(work_path, "feat"), "feat")
      {_, 0} = git_work.(["add", "."])
      {_, 0} = git_work.(["commit", "-m", "feat commit"])
      {tip, 0} = git_work.(["rev-parse", "HEAD"])
      tip = String.trim(tip)
      {_, 0} = git_work.(["push", "origin", "feat/cas-test"])
      {_, 0} = git_work.(["checkout", "main"])

      # Advance origin/main AFTER capturing old_oid
      _advancing_oid = advance_origin_main(origin_path)

      # Now old_oid is stale. Call cas_push with the stale expected_old_oid.
      # This must return {:error, :stale_ref}.
      result =
        apply(Tau.Factory.Merge.Cas, :cas_push, [work_path, tip, old_oid])

      assert match?({:error, :stale_ref}, result),
             "AC-4 / D-301: Merge.Cas.cas_push/3 must return {:error, :stale_ref} " <>
               "when origin/main has advanced past expected_old_oid; got #{inspect(result)}"
    end

    @tag :ac_4
    @tag :d_301
    test "AC-4 / D-301: Merge.Cas.assert_all_verdicts_live returns :all_pass when both halves are :pass" do
      # Directly exercises assert_all_verdicts_live/3.
      # When all required halves have latest status :pass, must return :all_pass.
      unit = %{
        id: "u-live",
        hash: "hash-live-#{System.unique_integer([:positive])}",
        run: "run-live-001",
        branch: "feat/live-test"
      }

      db_path = Briefly.create!(extname: ".db")
      writer_name = :"test_ma_writer_live_#{System.unique_integer([:positive])}"

      writer =
        start_supervised!(
          {@writer, db_path: db_path, name: writer_name},
          id: writer_name
        )

      for half <- [:critic, :reviewer] do
        {:ok, _} =
          @writer.append_verdict(writer, %{
            hash: unit.hash,
            run: unit.run,
            half: half,
            status: :pass,
            idempotency_key: "ikey-#{half}-#{System.unique_integer([:positive])}"
          })
      end

      result =
        apply(Tau.Factory.Merge.Cas, :assert_all_verdicts_live, [
          writer,
          [unit],
          [:critic, :reviewer]
        ])

      assert result == :all_pass,
             "AC-4 / D-301: assert_all_verdicts_live must return :all_pass when all halves are :pass; " <>
               "got #{inspect(result)}"
    end

    @tag :ac_4
    @tag :d_301
    test "AC-4 / D-301: Merge.Cas.assert_all_verdicts_live returns {:revoked, unit} when a half is :fail" do
      # When any required half has latest status :fail, must return {:revoked, unit}.
      unit = %{
        id: "u-revoked",
        hash: "hash-revoked-#{System.unique_integer([:positive])}",
        run: "run-revoked-001",
        branch: "feat/revoked-test"
      }

      db_path = Briefly.create!(extname: ".db")
      writer_name = :"test_ma_writer_revoked_#{System.unique_integer([:positive])}"

      writer =
        start_supervised!(
          {@writer, db_path: db_path, name: writer_name},
          id: writer_name
        )

      # Append :pass for reviewer
      {:ok, _} =
        @writer.append_verdict(writer, %{
          hash: unit.hash,
          run: unit.run,
          half: :reviewer,
          status: :pass,
          idempotency_key: "ikey-reviewer-#{System.unique_integer([:positive])}"
        })

      # Append :pass for critic, then revoke to :fail
      {:ok, _} =
        @writer.append_verdict(writer, %{
          hash: unit.hash,
          run: unit.run,
          half: :critic,
          status: :pass,
          idempotency_key: "ikey-critic-orig-#{System.unique_integer([:positive])}"
        })

      {:ok, _} =
        @writer.revoke_verdict(writer, %{
          hash: unit.hash,
          run: unit.run,
          half: :critic,
          status: :fail,
          idempotency_key: "ikey-critic-revoke-#{System.unique_integer([:positive])}"
        })

      result =
        apply(Tau.Factory.Merge.Cas, :assert_all_verdicts_live, [
          writer,
          [unit],
          [:critic, :reviewer]
        ])

      assert match?({:revoked, _}, result),
             "AC-4 / D-301: assert_all_verdicts_live must return {:revoked, unit} " <>
               "when a required half has been revoked to :fail; got #{inspect(result)}"
    end
  end
end
