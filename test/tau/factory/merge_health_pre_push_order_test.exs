defmodule Tau.Factory.MergeHealthPrePushOrderTest do
  @moduledoc """
  Gating test for issue #603 — INV-MAI-5: health check must run pre-CAS-push.

  ## Invariant (INV-MAI-5, D-303)

  "The health check on the batch tip must run pre-push (before any CAS push),
  so a red tip is ejected before landing on origin/main. Falsified if a CAS
  push is attempted on a batch tip that produced a :red health result."

  The SPEC §4 B5 contract (D-303) states:
    For the bootstrap toolchain the recipe is `mix compile --warnings-as-errors`
    + `mix test`, run in an isolated workspace on the batch **tip**, **pre-push**.

  The phrase "pre-push" means: health MUST complete before ANY push to origin —
  including the intermediate push to `origin/<branch>` that `do_build_in_worktree`
  does to make the tip addressable for the subsequent CAS step. No push of any
  kind may precede a green health result.

  ## What this test asserts

  Uses the REAL default build_fun (no injection) so the actual
  `do_build_in_worktree/4` code path is exercised. The topology is constructed
  so that rebase necessarily produces a NEW commit SHA (a diverged-main scenario):
  after the feature branch was created, a new commit is added to main. When
  MergeAuthority processes the unit, it rebases the feature branch onto the
  updated main, producing a different tip SHA. If production code pushes before
  health, `origin/<branch>` will be updated to the new rebased SHA even though
  health returned :red. The test asserts that `origin/<branch>` is NOT updated
  when health is red — i.e., the push did NOT precede the health check.

  ## Fail-before validity (oracle separation)

  Against the current production code this test is EXPECTED TO FAIL: the
  current `do_build_in_worktree/4` does `git push --force-with-lease` at the
  push step BEFORE calling `Health.check`. This means `origin/<branch>` will
  be updated to the rebased SHA even when health is red, causing the assertion
  `assert branch_oid_after == branch_oid_before` to fail.

  After a correct implementation (push moved to after health returns :green),
  the test passes: on a :red health result the worktree is discarded without
  pushing, so `origin/<branch>` remains at the original SHA.

  ## D-NNN linkage: INV-MAI-5 / D-303 / AC-5.
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log
  @moduletag :"INV-MAI-5"
  @moduletag :"D-303"
  @moduletag timeout: 120_000

  @merge_authority Tau.Factory.MergeAuthority
  @writer Tau.Factory.Ledger.Writer

  # ---------------------------------------------------------------------------
  # Fixture mix project helpers
  # ---------------------------------------------------------------------------

  defp write_mix_project(base_dir) do
    File.mkdir_p!(Path.join(base_dir, "lib"))
    File.mkdir_p!(Path.join(base_dir, "test"))

    File.write!(Path.join(base_dir, "mix.exs"), """
    defmodule HealthPrePushFixture.MixProject do
      use Mix.Project

      def project do
        [
          app: :health_pre_push_fixture,
          version: "0.1.0",
          elixir: "~> 1.14",
          start_permanent: Mix.env() == :prod,
          deps: []
        ]
      end
    end
    """)

    File.write!(Path.join(base_dir, "lib/health_pre_push_fixture.ex"), """
    defmodule HealthPrePushFixture do
      @moduledoc "Minimal health fixture module."

      def hello, do: :world
    end
    """)

    File.write!(Path.join(base_dir, "test/test_helper.exs"), """
    ExUnit.start()
    """)

    File.write!(Path.join(base_dir, "test/health_pre_push_fixture_test.exs"), """
    defmodule HealthPrePushFixtureTest do
      use ExUnit.Case

      test "passes (green baseline)" do
        assert HealthPrePushFixture.hello() == :world
      end
    end
    """)
  end

  # Build the git topology with a DIVERGED main.
  #
  # Returns: {origin_path, work_path, branch_name, branch_oid_before_rebase}
  #
  # Topology:
  #   initial -- (main) -- [extra-main-commit]   <- main advances AFTER branch
  #           \- (feature/...) -- [red-test-commit]  <- branch has failing test
  #
  # When MergeAuthority processes the feature branch it will:
  #   1. fetch origin
  #   2. rebase feature onto updated main  <- produces a NEW commit SHA
  #   3. push HEAD:feature (BEFORE health in current buggy code)
  #   4. health -> :red
  #   5. {:build_failed, {:health_red, _}}
  #
  # The test checks whether step 3 actually updated origin/feature — which
  # would be a direct violation of INV-MAI-5 ("pre-push" means no push before
  # a green health result).
  defp setup_diverged_repo(tmp_dir) do
    origin_path = Path.join(tmp_dir, "origin.git")
    work_path = Path.join(tmp_dir, "work")

    write_mix_project(work_path)

    {_, 0} = System.cmd("git", ["init", "-b", "main", work_path])

    git_work = fn args ->
      System.cmd("git", args, cd: work_path, stderr_to_stdout: true)
    end

    git_work.(["config", "user.email", "test@tau.test"])
    git_work.(["config", "user.name", "Tau Test"])
    {_, 0} = git_work.(["add", "."])
    {_, 0} = git_work.(["commit", "-m", "initial: green fixture"])

    # Create and push the bare origin
    {_, 0} = System.cmd("git", ["init", "--bare", origin_path])
    {_, 0} = System.cmd(
      "git", ["symbolic-ref", "HEAD", "refs/heads/main"],
      cd: origin_path
    )
    {_, 0} = git_work.(["remote", "add", "origin", origin_path])
    {_, 0} = git_work.(["push", "-u", "origin", "main"])

    branch_name = "feat/inv-mai5-diverge-#{System.unique_integer([:positive])}"

    # Create the feature branch with a FAILING test
    {_, 0} = git_work.(["checkout", "-b", branch_name])

    File.write!(Path.join(work_path, "test/health_pre_push_fixture_test.exs"), """
    defmodule HealthPrePushFixtureTest do
      use ExUnit.Case

      test "passes (green baseline)" do
        assert HealthPrePushFixture.hello() == :world
      end

      test "intentionally failing (red tip for INV-MAI-5)" do
        assert false, "always fails — makes this branch tip health-red"
      end
    end
    """)

    {_, 0} = git_work.(["add", "."])
    {_, 0} = git_work.(["commit", "-m", "red: failing test for INV-MAI-5"])
    {_, 0} = git_work.(["push", "origin", branch_name])

    # Record the branch OID on origin BEFORE MergeAuthority touches it
    {branch_oid_raw, 0} =
      System.cmd("git", ["rev-parse", "refs/heads/#{branch_name}"], cd: origin_path)

    branch_oid_before = String.trim(branch_oid_raw)

    # Switch back to main and add a NEW commit — this diverges main from the
    # branch's merge-base, so the rebase will produce a DIFFERENT commit SHA.
    {_, 0} = git_work.(["checkout", "main"])

    File.write!(Path.join(work_path, "lib/health_pre_push_fixture.ex"), """
    defmodule HealthPrePushFixture do
      @moduledoc "Minimal health fixture module (updated after branch creation)."

      def hello, do: :world
      def version, do: "1.1"
    end
    """)

    {_, 0} = git_work.(["add", "."])
    {_, 0} = git_work.(["commit", "-m", "main: advance past branch diverge point"])
    {_, 0} = git_work.(["push", "origin", "main"])

    {origin_path, work_path, branch_name, branch_oid_before}
  end

  defp origin_ref_oid(origin_path, ref) do
    case System.cmd("git", ["rev-parse", "refs/heads/#{ref}"], cd: origin_path) do
      {oid, 0} -> {:ok, String.trim(oid)}
      {_, _} -> {:error, :not_found}
    end
  end

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

  defp wait_for_idle(ma_pid, timeout_ms \\ 90_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_idle(ma_pid, deadline)
  end

  defp do_wait_for_idle(ma_pid, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      :timeout
    else
      {state, _data} = :sys.get_state(ma_pid)

      if state == :idle do
        :ok
      else
        :timer.sleep(200)
        do_wait_for_idle(ma_pid, deadline)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # INV-MAI-5 — origin/<branch> MUST NOT be updated before health returns green
  #
  # Gate: exercises the REAL default build_fun (do_build_in_worktree/4) via the
  # real git + mix toolchain. The topology forces a rebase that changes the tip
  # SHA, making any premature push to origin/<branch> observable.
  #
  # FAIL-BEFORE: The current production code at do_build_in_worktree/4 pushes
  # `origin/<branch>` BEFORE calling `Health.check`. When health returns :red
  # on this red-tip branch, the push has already mutated `origin/<branch>`, so
  # `branch_oid_after != branch_oid_before`. This assertion will FAIL against
  # current production code.
  # ---------------------------------------------------------------------------

  describe "INV-MAI-5 — origin/<branch> is NOT pushed before health returns green" do
    @tag :"INV-MAI-5"
    @tag :ac_5
    @tag :d_303
    test "INV-MAI-5: when health is red, origin/<branch> ref is NOT updated (push did not precede health)" do
      tmp_dir = Briefly.create!(type: :directory)

      {origin_path, work_path, branch_name, branch_oid_before} =
        setup_diverged_repo(tmp_dir)

      unit = %{
        id: "u-inv-mai5-#{System.unique_integer([:positive])}",
        hash: "hash-inv-mai5-#{System.unique_integer([:positive])}",
        run: "run-inv-mai5-001",
        branch: branch_name
      }

      db_path = Briefly.create!(extname: ".db")
      writer_name = :"test_inv_mai5_writer_#{System.unique_integer([:positive])}"

      writer =
        start_supervised!(
          {@writer, db_path: db_path, name: writer_name},
          id: writer_name
        )

      seed_pass_verdicts(writer, unit)

      ma_name = :"test_inv_mai5_ma_#{System.unique_integer([:positive])}"
      tasks_name = :"test_inv_mai5_tasks_#{System.unique_integer([:positive])}"

      ma_pid =
        start_supervised!(
          {
            @merge_authority,
            name: ma_name,
            ledger: writer,
            repo_dir: work_path,
            required_halves: [:critic, :reviewer],
            tasks_name: tasks_name
            # NO build_fun injection — exercises the real do_build_in_worktree/4
            # so the actual push-before-health bug is observable.
          },
          id: ma_name
        )

      assert :queued = @merge_authority.request_merge(ma_pid, unit)

      # Wait for MergeAuthority to process: real build_fun ->
      # fetch -> rebase -> push-before-health (bug) OR health -> push (correct)
      # -> {:build_failed, {:health_red, _}} -> eject -> :idle.
      result = wait_for_idle(ma_pid)

      assert result == :ok,
             "INV-MAI-5: timed out waiting for MergeAuthority to return to :idle " <>
               "after a red health eject. M MUST NOT hang when health is red."

      # PRIMARY ASSERTION — INV-MAI-5 direct falsification guard:
      #
      # If production code pushes BEFORE health (the bug):
      #   origin/<branch> now points to the rebased tip SHA != branch_oid_before
      #   -> assertion fails  (test catches the violation <- EXPECTED with current code)
      #
      # If the invariant is correctly enforced (push only after health = :green):
      #   origin/<branch> still points to branch_oid_before (unchanged)
      #   -> assertion passes (test confirms correct behaviour <- post-fix state)
      {:ok, branch_oid_after} = origin_ref_oid(origin_path, branch_name)

      assert branch_oid_after == branch_oid_before,
             "INV-MAI-5 VIOLATED: origin/#{branch_name} was updated from " <>
               "#{branch_oid_before} to #{branch_oid_after} even though health " <>
               "returned :red. The invariant requires health to run PRE-PUSH — " <>
               "no push to origin (including origin/<branch>) may precede a green " <>
               "health result (D-303, B5, SPEC-FACTORY-MERGE §4 B5 'pre-push')."
    end
  end
end
