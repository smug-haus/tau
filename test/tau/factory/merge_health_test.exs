defmodule Tau.Factory.MergeHealthTest do
  @moduledoc """
  Gating tests for PR #436 (P3b — pre-push tip health gate, D-303, AC-5).

  Tests AC-5 (D-303): a red batch tip (failing test or compile error) is
  health-checked in the `:integrating` Task and NO merge lands — `origin/main`
  is unchanged, the unit is ejected, and a `[:tau, :factory, :merge, :health]`
  red telemetry fires. A GREEN tip passes health and proceeds to the CAS (happy-
  path control, proving health gates rather than blocks unconditionally).

  Pins the HR-3 / FC-5 contract: the engine owns execution and judgement;
  a bad adapter cannot fake `:green`. Uses a REAL hermetic mix project inside a
  synthetic git topology — no `build_fun` injection for the health assertions.

  Written BEFORE production code exists (oracle-separation phase — phase 4b).
  Tests fail at RUNTIME (UndefinedFunctionError / FunctionClauseError) until
  the implementer creates:
    - lib/tau/factory/merge/health.ex   (Tau.Factory.Merge.Health)
    - lib/tau/factory/merge_authority.ex (EXTENDED — health stage in Task)

  AC linkage: AC-5 / D-303.
  """

  # Health check + mix subprocess = minutes of potential wall time on slow CI.
  # async: false avoids resource contention from parallel test processes each
  # running mix subprocesses.
  use ExUnit.Case, async: false

  @moduletag :capture_log
  # Increase timeout — mix compile + mix test inside a fixture adds real wall time.
  @moduletag timeout: 120_000

  # ---------------------------------------------------------------------------
  # Runtime module references (anti-compile-crash idiom from P3a).
  # The file compiles even when these modules do not yet exist; tests fail at
  # runtime with UndefinedFunctionError (Gate 5.3 correct fail-before state).
  # ---------------------------------------------------------------------------

  @health Tau.Factory.Merge.Health
  @merge_authority Tau.Factory.MergeAuthority
  @writer Tau.Factory.Ledger.Writer

  # ---------------------------------------------------------------------------
  # Fixture mix project helpers
  # ---------------------------------------------------------------------------

  # Write a minimal dependency-free mix project into `base_dir`.
  # The project has one passing test so it starts green.
  defp write_mix_project(base_dir) do
    File.mkdir_p!(Path.join(base_dir, "lib"))
    File.mkdir_p!(Path.join(base_dir, "test"))

    File.write!(Path.join(base_dir, "mix.exs"), """
    defmodule HealthFixture.MixProject do
      use Mix.Project

      def project do
        [
          app: :health_fixture,
          version: "0.1.0",
          elixir: "~> 1.14",
          start_permanent: Mix.env() == :prod,
          deps: []
        ]
      end
    end
    """)

    File.write!(Path.join(base_dir, "lib/health_fixture.ex"), """
    defmodule HealthFixture do
      @moduledoc "Minimal health fixture module."

      def hello, do: :world
    end
    """)

    File.write!(Path.join(base_dir, "test/test_helper.exs"), """
    ExUnit.start()
    """)

    File.write!(Path.join(base_dir, "test/health_fixture_test.exs"), """
    defmodule HealthFixtureTest do
      use ExUnit.Case

      test "passes (green baseline)" do
        assert HealthFixture.hello() == :world
      end
    end
    """)
  end

  # Build the synthetic git topology for health tests:
  #   origin.git (bare)
  #   work/       (working checkout — contains the fixture mix project on main)
  #
  # Returns: {origin_path, work_path, main_oid}
  defp setup_fixture_repo(tmp_dir) do
    origin_path = Path.join(tmp_dir, "origin.git")
    work_path = Path.join(tmp_dir, "work")

    # Write the fixture mix project into the working directory.
    write_mix_project(work_path)

    {_, 0} = System.cmd("git", ["init", "-b", "main", work_path])

    git_work = fn args ->
      System.cmd("git", args, cd: work_path, stderr_to_stdout: true)
    end

    git_work.(["config", "user.email", "test@tau.test"])
    git_work.(["config", "user.name", "Tau Test"])
    {_, 0} = git_work.(["add", "."])
    {_, 0} = git_work.(["commit", "-m", "initial: green fixture"])

    {_, 0} = System.cmd("git", ["init", "--bare", origin_path])

    {_, 0} =
      System.cmd("git", ["symbolic-ref", "HEAD", "refs/heads/main"], cd: origin_path)

    {_, 0} = git_work.(["remote", "add", "origin", origin_path])
    {_, 0} = git_work.(["push", "-u", "origin", "main"])

    {main_oid_raw, 0} = git_work.(["rev-parse", "HEAD"])
    main_oid = String.trim(main_oid_raw)

    {origin_path, work_path, main_oid}
  end

  # Add a GREEN branch to the work repo: a trivial passing change off main.
  # Returns: {branch_name, tip_oid}
  defp add_green_branch(work_path, branch_name) do
    git_work = fn args ->
      System.cmd("git", args, cd: work_path, stderr_to_stdout: true)
    end

    {_, 0} = git_work.(["checkout", "-b", branch_name])

    File.write!(Path.join(work_path, "lib/health_fixture.ex"), """
    defmodule HealthFixture do
      @moduledoc "Minimal health fixture module — green change."

      def hello, do: :world
      def green_addition, do: :ok
    end
    """)

    File.write!(Path.join(work_path, "test/health_fixture_test.exs"), """
    defmodule HealthFixtureTest do
      use ExUnit.Case

      test "passes (green baseline)" do
        assert HealthFixture.hello() == :world
      end

      test "green addition passes" do
        assert HealthFixture.green_addition() == :ok
      end
    end
    """)

    {_, 0} = git_work.(["add", "."])
    {_, 0} = git_work.(["commit", "-m", "green: add passing test"])
    {tip_raw, 0} = git_work.(["rev-parse", "HEAD"])
    tip = String.trim(tip_raw)
    {_, 0} = git_work.(["push", "origin", branch_name])
    {_, 0} = git_work.(["checkout", "main"])

    {branch_name, tip}
  end

  # Add a RED branch: introduces a failing test.
  # Returns: {branch_name, tip_oid}
  defp add_red_branch(work_path, branch_name) do
    git_work = fn args ->
      System.cmd("git", args, cd: work_path, stderr_to_stdout: true)
    end

    {_, 0} = git_work.(["checkout", "-b", branch_name])

    File.write!(Path.join(work_path, "test/health_fixture_test.exs"), """
    defmodule HealthFixtureTest do
      use ExUnit.Case

      test "passes (green baseline)" do
        assert HealthFixture.hello() == :world
      end

      test "intentionally failing test (red tip)" do
        assert false, "this test always fails — used to make the tip red for D-303"
      end
    end
    """)

    {_, 0} = git_work.(["add", "."])
    {_, 0} = git_work.(["commit", "-m", "red: add intentionally failing test"])
    {tip_raw, 0} = git_work.(["rev-parse", "HEAD"])
    tip = String.trim(tip_raw)
    {_, 0} = git_work.(["push", "origin", branch_name])
    {_, 0} = git_work.(["checkout", "main"])

    {branch_name, tip}
  end

  defp origin_main_oid(origin_path) do
    {oid, 0} =
      System.cmd("git", ["rev-parse", "refs/heads/main"], cd: origin_path)

    String.trim(oid)
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

  # Poll :sys.get_state until M reaches :idle or the deadline passes.
  # Returns :ok when :idle is reached, :timeout otherwise.
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
  # AC-5 / D-303 — Test 1: red tip → no merge (the HR-3 non-fake proof)
  # ---------------------------------------------------------------------------

  describe "AC-5 / D-303 — red batch tip is ejected; no merge lands" do
    @tag :ac_5
    @tag :d_303
    test "AC-5 / D-303: a red tip (failing test) is health-checked in :integrating; origin/main unchanged; health telemetry red" do
      tmp_dir = Briefly.create!(type: :directory)

      {origin_path, work_path, initial_main_oid} = setup_fixture_repo(tmp_dir)

      {branch_name, _tip} =
        add_red_branch(work_path, "feat/red-health-#{System.unique_integer([:positive])}")

      unit = %{
        id: "u-red-#{System.unique_integer([:positive])}",
        hash: "hash-red-#{System.unique_integer([:positive])}",
        run: "run-red-001",
        branch: branch_name
      }

      db_path = Briefly.create!(extname: ".db")
      writer_name = :"test_health_writer_red_#{System.unique_integer([:positive])}"

      writer =
        start_supervised!(
          {@writer, db_path: db_path, name: writer_name},
          id: writer_name
        )

      seed_pass_verdicts(writer, unit)

      # Attach telemetry handler before starting the MA, so we capture the
      # [:tau, :factory, :merge, :health] event from the Task.
      test_pid = self()
      handler_id = "health-test-red-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:tau, :factory, :merge, :health],
        fn _event, measurements, metadata, _cfg ->
          send(test_pid, {:telemetry_health, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      ma_name = :"test_ma_health_red_#{System.unique_integer([:positive])}"
      tasks_name = :"test_ma_tasks_health_red_#{System.unique_integer([:positive])}"

      ma_pid =
        start_supervised!(
          {@merge_authority,
           name: ma_name,
           ledger: writer,
           repo_dir: work_path,
           required_halves: [:critic, :reviewer],
           tasks_name: tasks_name},
          id: ma_name
        )

      assert :queued = @merge_authority.request_merge(ma_pid, unit)

      # Wait for M to complete the Task and return to :idle.
      # The Task runs: rebase + health_check(tip); health is RED → build_failed → :idle.
      result = wait_for_idle(ma_pid)

      assert result == :ok,
             "AC-5 / D-303: timed out waiting for MergeAuthority to return to :idle " <>
               "after ejecting the red unit. M must not hang on a red health result."

      # ASSERTION 1: origin/main must be UNCHANGED — no merge landed.
      current_oid = origin_main_oid(origin_path)

      assert current_oid == initial_main_oid,
             "AC-5 / D-303 (D-303, HR-3, INV-4): a red batch tip MUST NOT land on " <>
               "origin/main. origin/main must remain at its initial oid.\n" <>
               "Expected (initial): #{initial_main_oid}\n" <>
               "Got (current):      #{current_oid}\n" <>
               "This means health did not gate the merge — VIOLATION of D-303"

      # ASSERTION 2: a [:tau, :factory, :merge, :health] red telemetry event fired.
      # This proves the health judgement was executed (not skipped/bypassed).
      assert_receive {:telemetry_health, _measurements, metadata},
                     500,
                     "AC-5 / D-303: expected a [:tau, :factory, :merge, :health] telemetry " <>
                       "event after the red tip was checked. None received within 500ms."

      assert metadata[:result] == :red,
             "AC-5 / D-303: health telemetry metadata must include result: :red for a " <>
               "red tip; got #{inspect(metadata[:result])}. " <>
               "The engine must judge the tip red from REAL execution (HR-3)."
    end
  end

  # ---------------------------------------------------------------------------
  # AC-5 / D-303 — Test 2: green tip → merges (the control; proves gating not blocking)
  # ---------------------------------------------------------------------------

  describe "AC-5 / D-303 — green batch tip passes health and lands on origin/main" do
    @tag :ac_5
    @tag :d_303
    test "AC-5 / D-303: a green tip passes health in :integrating and CAS merges it onto origin/main" do
      tmp_dir = Briefly.create!(type: :directory)

      {origin_path, work_path, initial_main_oid} = setup_fixture_repo(tmp_dir)

      {branch_name, tip} =
        add_green_branch(work_path, "feat/green-health-#{System.unique_integer([:positive])}")

      unit = %{
        id: "u-green-#{System.unique_integer([:positive])}",
        hash: "hash-green-#{System.unique_integer([:positive])}",
        run: "run-green-001",
        branch: branch_name
      }

      db_path = Briefly.create!(extname: ".db")
      writer_name = :"test_health_writer_green_#{System.unique_integer([:positive])}"

      writer =
        start_supervised!(
          {@writer, db_path: db_path, name: writer_name},
          id: writer_name
        )

      seed_pass_verdicts(writer, unit)

      test_pid = self()
      handler_id = "health-test-green-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:tau, :factory, :merge, :health],
        fn _event, measurements, metadata, _cfg ->
          send(test_pid, {:telemetry_health, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      ma_name = :"test_ma_health_green_#{System.unique_integer([:positive])}"
      tasks_name = :"test_ma_tasks_health_green_#{System.unique_integer([:positive])}"

      ma_pid =
        start_supervised!(
          {@merge_authority,
           name: ma_name,
           ledger: writer,
           repo_dir: work_path,
           required_halves: [:critic, :reviewer],
           tasks_name: tasks_name},
          id: ma_name
        )

      assert :queued = @merge_authority.request_merge(ma_pid, unit)

      # Wait for M to process: rebase + health_check (green) → :built → :committing → CAS → :idle.
      result = wait_for_idle(ma_pid)

      assert result == :ok,
             "AC-5 / D-303: timed out waiting for MergeAuthority to return to :idle " <>
               "after a green merge. M must complete the full pipeline."

      # ASSERTION 1: origin/main ADVANCED to the unit's tip — merge landed.
      current_oid = origin_main_oid(origin_path)

      refute current_oid == initial_main_oid,
             "AC-5 / D-303 (control): a green tip MUST land on origin/main; " <>
               "origin/main must advance beyond its initial oid. " <>
               "Still at initial oid #{initial_main_oid} — health is blocking all merges."

      assert current_oid == tip,
             "AC-5 / D-303 (control): origin/main must equal the merged unit tip.\n" <>
               "Expected (tip): #{tip}\n" <>
               "Got (current):  #{current_oid}"

      # ASSERTION 2: a [:tau, :factory, :merge, :health] green telemetry event fired.
      assert_receive {:telemetry_health, _measurements, metadata},
                     500,
                     "AC-5 / D-303: expected a [:tau, :factory, :merge, :health] telemetry " <>
                       "event after the green tip was checked. None received within 500ms."

      assert metadata[:result] == :green,
             "AC-5 / D-303 (control): health telemetry metadata must include result: :green; " <>
               "got #{inspect(metadata[:result])}"
    end
  end

  # ---------------------------------------------------------------------------
  # AC-5 / D-303 — Test 3: Merge.Health.check/3 direct (judgement is execution-derived)
  # ---------------------------------------------------------------------------

  describe "AC-5 / D-303 — Merge.Health.check/3 direct: real execution, not adapter claim" do
    @tag :ac_5
    @tag :d_303
    test "AC-5 / D-303: Health.check/3 returns {:red, report} for a repo with a failing test" do
      # Proves HR-3: the judgement comes from REAL subprocess execution,
      # not from any adapter returning a pre-cooked :green.
      tmp_dir = Briefly.create!(type: :directory)

      {_origin_path, work_path, _initial_main_oid} = setup_fixture_repo(tmp_dir)

      {branch_name, _tip} =
        add_red_branch(work_path, "feat/direct-red-#{System.unique_integer([:positive])}")

      # Checkout the red branch in the work repo so Health.check sees the red tip.
      {_, 0} = System.cmd("git", ["checkout", branch_name], cd: work_path)

      result = @health.check(work_path, :elixir, %{})

      assert match?({:red, _report}, result),
             "AC-5 / D-303 (HR-3): Merge.Health.check/3 must return {:red, report} " <>
               "when the repo has a failing test. Got: #{inspect(result)}. " <>
               "The judgement must come from REAL execution — not an adapter claim."

      {:red, report} = result

      assert report != nil,
             "AC-5 / D-303: the red report must be non-nil (must identify the failing phase)"
    end

    @tag :ac_5
    @tag :d_303
    test "AC-5 / D-303: Health.check/3 returns :green for a repo with all passing tests" do
      # Proves health gates rather than blocks unconditionally — a green repo passes.
      tmp_dir = Briefly.create!(type: :directory)

      {_origin_path, work_path, _initial_main_oid} = setup_fixture_repo(tmp_dir)

      {branch_name, _tip} =
        add_green_branch(work_path, "feat/direct-green-#{System.unique_integer([:positive])}")

      {_, 0} = System.cmd("git", ["checkout", branch_name], cd: work_path)

      result = @health.check(work_path, :elixir, %{})

      assert result == :green,
             "AC-5 / D-303: Merge.Health.check/3 must return :green when the repo " <>
               "compiles without warnings and all tests pass. Got: #{inspect(result)}. " <>
               "Health must gate, not unconditionally block."
    end
  end
end
