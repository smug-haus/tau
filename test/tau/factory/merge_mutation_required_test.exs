defmodule Tau.Factory.MergeMutationRequiredTest do
  @moduledoc """
  Gating tests for issue #651 (FR-4.1 / INV-1 conformance).

  INV-1 Gate-before-merge: nothing reaches `main` without BOTH judgement
  oracles (critic, reviewer) AND ALL mechanical gates (ac_linkage, masking,
  mutation) PASS on that exact diff.

  FR-4.1 identifies the gap: `required_halves` defaults to `[:critic, :reviewer]`
  in both `MergeAuthority` (merge_authority.ex:217) and `Supervisor`
  (supervisor.ex:107), so the `:mutation` verdict is NEVER checked at the merge
  instant even though Gate.run/1 appends it to the Ledger.

  These tests exercise the invariant at its governing boundary: `request_merge/2`
  (the real user-facing entry point, D-302 / B1). They:

    1. Seed ONLY `:critic` and `:reviewer` PASS verdicts -- no `:mutation` verdict.
    2. Assert that origin/main does NOT advance (the merge is blocked).

  Under current production code (required_halves default = [:critic, :reviewer])
  test "FR-4.1: only critic+reviewer pass..." FAILS: origin/main advances because
  the default never checks :mutation.

  The conformant implementation must default required_halves to
  [:mutation, :critic, :reviewer] in both MergeAuthority and Supervisor.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log

  @merge_authority Tau.Factory.MergeAuthority
  @writer Tau.Factory.Ledger.Writer

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp seed_critic_reviewer_pass_only(writer, %{hash: hash, run: run}) do
    # Seed ONLY the two judgement-oracle halves -- deliberately omitting :mutation.
    # Under INV-1 this is insufficient: the mutation gate must also pass.
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

  defp seed_all_three_pass(writer, %{hash: hash, run: run}) do
    # All three floor halves pass -- the conformant merge-allowed state.
    for half <- [:mutation, :critic, :reviewer] do
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
    File.write!(Path.join(work_path, "feature_#{unit.id}"), "feature content")
    {_, 0} = git_work.(["add", "."])
    {_, 0} = git_work.(["commit", "-m", "feature for #{unit.branch}"])
    {tip, 0} = git_work.(["rev-parse", "HEAD"])
    tip = String.trim(tip)
    {_, 0} = git_work.(["push", "origin", unit.branch])
    {_, 0} = git_work.(["checkout", "main"])

    {origin_path, work_path, main_oid, tip}
  end

  defp origin_main_oid(origin_path) do
    {oid, 0} = System.cmd("git", ["rev-parse", "refs/heads/main"], cd: origin_path)
    String.trim(oid)
  end

  # Barrier build_fun: notifies the test process and blocks until released.
  # Allows assertions to run after the build completes but before :committing.
  defp barrier_build_fun(test_pid, tip, unit, base_oid) do
    fn _units, _base ->
      ref = make_ref()
      send(test_pid, {:at_barrier, ref, tip})

      receive do
        {:proceed, ^ref} -> :ok
      after
        10_000 -> raise "barrier timeout in merge_mutation_required_test"
      end

      {:built, [unit], base_oid, tip}
    end
  end

  # ---------------------------------------------------------------------------
  # FR-4.1 / INV-1: :mutation verdict must be in the default required_halves
  # ---------------------------------------------------------------------------

  describe "FR-4.1 / INV-1 -- :mutation verdict is a default required half" do
    @tag :fr_4_1
    @tag :inv_1
    test "FR-4.1: only critic+reviewer pass, no :mutation verdict -- merge MUST be blocked, origin/main unchanged" do
      # This test is RED under current production code: required_halves defaults
      # to [:critic, :reviewer], so the :mutation check is skipped and origin/main
      # advances. Under the conformant implementation the merge is blocked.
      tmp_dir = Briefly.create!(type: :directory)
      test_pid = self()

      unit = %{
        id: "u-fr41-no-mutation",
        hash: "hash-fr41-no-mutation-#{System.unique_integer([:positive])}",
        run: "run-fr41-001",
        branch: "feat/fr41-no-mutation-test"
      }

      db_path = Briefly.create!(extname: ".db")
      writer_name = :"test_ma_writer_fr41_#{System.unique_integer([:positive])}"

      writer =
        start_supervised!(
          {@writer, db_path: db_path, name: writer_name},
          id: writer_name
        )

      # Seed ONLY critic + reviewer PASS -- :mutation verdict is absent.
      seed_critic_reviewer_pass_only(writer, unit)

      {origin_path, work_path, initial_main_oid, tip} =
        setup_git_repo(tmp_dir, unit)

      build_fun = barrier_build_fun(test_pid, tip, unit, initial_main_oid)

      ma_name = :"test_ma_fr41_#{System.unique_integer([:positive])}"
      tasks_name = :"test_ma_tasks_fr41_#{System.unique_integer([:positive])}"

      ma_pid =
        start_supervised!(
          {
            @merge_authority,
            name: ma_name,
            ledger: writer,
            repo_dir: work_path,
            # No required_halves override -- exercises the production default (INV-1).
            tasks_name: tasks_name,
            build_fun: build_fun
          },
          id: ma_name
        )

      # request_merge/2 is the real user-facing entry point (D-302 / B1).
      assert :queued = @merge_authority.request_merge(ma_pid, unit)

      # Wait for the build to complete (M is about to enter :committing).
      assert_receive {:at_barrier, ref, ^tip},
                     5_000,
                     "FR-4.1: expected M to reach build barrier"

      # Release the barrier -- M will enter :committing and re-read verdicts.
      send(ma_pid, {:proceed, ref})

      # Allow M time to complete :committing.
      :timer.sleep(500)

      # ASSERTION (INV-1 / FR-4.1): without a :mutation PASS verdict the merge
      # must be blocked. origin/main MUST remain at initial_main_oid.
      current_oid = origin_main_oid(origin_path)

      assert current_oid == initial_main_oid,
             "FR-4.1 / INV-1: merge MUST be blocked when :mutation verdict is absent " <>
               "(required_halves default must include :mutation). " <>
               "origin/main advanced from #{initial_main_oid} to #{current_oid} -- VIOLATION."
    end

    @tag :fr_4_1
    @tag :inv_1
    test "FR-4.1 baseline: all three floor halves pass (mutation+critic+reviewer) -- merge MUST land" do
      # Baseline: when all three floor halves carry PASS verdicts, the merge
      # must succeed. This pins the conformant end-state and guards against an
      # over-restrictive fix that rejects all merges.
      tmp_dir = Briefly.create!(type: :directory)
      test_pid = self()

      unit = %{
        id: "u-fr41-all-pass",
        hash: "hash-fr41-all-pass-#{System.unique_integer([:positive])}",
        run: "run-fr41-002",
        branch: "feat/fr41-all-pass-test"
      }

      db_path = Briefly.create!(extname: ".db")
      writer_name = :"test_ma_writer_fr41b_#{System.unique_integer([:positive])}"

      writer =
        start_supervised!(
          {@writer, db_path: db_path, name: writer_name},
          id: writer_name
        )

      # Seed all three floor halves as PASS.
      seed_all_three_pass(writer, unit)

      {origin_path, work_path, initial_main_oid, tip} =
        setup_git_repo(tmp_dir, unit)

      build_fun = barrier_build_fun(test_pid, tip, unit, initial_main_oid)

      ma_name = :"test_ma_fr41b_#{System.unique_integer([:positive])}"
      tasks_name = :"test_ma_tasks_fr41b_#{System.unique_integer([:positive])}"

      ma_pid =
        start_supervised!(
          {
            @merge_authority,
            name: ma_name,
            ledger: writer,
            repo_dir: work_path,
            # No required_halves override -- production default must include :mutation.
            tasks_name: tasks_name,
            build_fun: build_fun
          },
          id: ma_name
        )

      assert :queued = @merge_authority.request_merge(ma_pid, unit)

      assert_receive {:at_barrier, ref, ^tip},
                     5_000,
                     "FR-4.1 baseline: expected M to reach build barrier"

      send(ma_pid, {:proceed, ref})

      # Allow M time to complete the push.
      :timer.sleep(800)

      # With all three floor halves PASS and a fresh CAS, the merge must land.
      current_oid = origin_main_oid(origin_path)

      assert current_oid == tip,
             "FR-4.1 baseline: with mutation+critic+reviewer all PASS, merge must land; " <>
               "expected origin/main=#{tip}, got #{current_oid}."
    end
  end
end
