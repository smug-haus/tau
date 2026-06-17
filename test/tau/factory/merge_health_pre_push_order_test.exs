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

  The SPEC §4 B4 contract (D-301) states:
    Pre: `assert_all_verdicts_live == :all_pass`; M is the **sole** writer of
    `origin/main`.

  The SPEC §5 state table `:integrating` exit states:
    `{:build_failed, :health_red}` → `:idle` (bisect/eject).
    The `cas_push` runs only from `:committing`, which is entered only via
    `Task {:built, ...}` — a result returned ONLY when health is `:green`.

  ## What this test asserts

  Using the real default build path (`build_fun` not injected — `Health.check`
  runs via real `mix test` execution on a synthetic mix project), a CAS module
  is injected that records whether `cas_push/3` is ever called. When the batch
  tip has a failing test (health returns `{:red, _}`), `cas_push` MUST NOT be
  called — neither for `origin/main` nor for any other ref. Any call to
  `cas_push` when health was red is a direct violation of INV-MAI-5.

  ## Fail-before validity (oracle separation)

  Against the current production code the test is EXPECTED TO PASS (the
  overturned audit finding confirms the CAS push to origin/main is not
  attempted on a red health result). However, the test is required as a
  gating/regression guard: any future refactor that calls `cas_push` before
  completing health will cause this test to fail immediately, catching the
  invariant violation at the unit-test boundary.

  The test exercises the invariant's EXACT falsification condition stated in
  the issue body: "Falsified if a CAS push is attempted on a batch tip that
  produced a :red health result."

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
  # Injected CAS that records whether cas_push was ever called.
  # If cas_push is called, it sends a message to the registered :inv_mai5_spy
  # process. It also forwards to the real CAS so M can continue normally.
  # ---------------------------------------------------------------------------

  defmodule SpyCas do
    @moduledoc false

    def assert_all_verdicts_live(ledger, units, required_halves) do
      Tau.Factory.Merge.Cas.assert_all_verdicts_live(ledger, units, required_halves)
    end

    def cas_push(repo_dir, tip, base) do
      # Notify the spy process that cas_push was called.
      case Process.whereis(:inv_mai5_spy) do
        nil -> :ok
        pid -> send(pid, {:cas_push_called, %{repo_dir: repo_dir, tip: tip, base: base}})
      end

      Tau.Factory.Merge.Cas.cas_push(repo_dir, tip, base)
    end
  end

  # ---------------------------------------------------------------------------
  # Fixture mix project helpers (mirrors merge_health_test.exs setup)
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

  # Build the synthetic git topology.
  # Returns: {origin_path, work_path, main_oid}
  defp setup_fixture_repo(tmp_dir) do
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

    {_, 0} = System.cmd("git", ["init", "--bare", origin_path])

    {_, 0} =
      System.cmd("git", ["symbolic-ref", "HEAD", "refs/heads/main"], cd: origin_path)

    {_, 0} = git_work.(["remote", "add", "origin", origin_path])
    {_, 0} = git_work.(["push", "-u", "origin", "main"])

    {main_oid_raw, 0} = git_work.(["rev-parse", "HEAD"])
    main_oid = String.trim(main_oid_raw)

    {origin_path, work_path, main_oid}
  end

  # Add a RED branch: introduces a failing test.
  # Returns: {branch_name, tip_oid}
  defp add_red_branch(work_path, branch_name) do
    git_work = fn args ->
      System.cmd("git", args, cd: work_path, stderr_to_stdout: true)
    end

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
    {_, 0} = git_work.(["commit", "-m", "red: failing test for INV-MAI-5 invariant check"])
    {tip_raw, 0} = git_work.(["rev-parse", "HEAD"])
    tip = String.trim(tip_raw)
    {_, 0} = git_work.(["push", "origin", branch_name])
    {_, 0} = git_work.(["checkout", "main"])

    {branch_name, tip}
  end

  defp origin_main_oid(origin_path) do
    {oid, 0} = System.cmd("git", ["rev-parse", "refs/heads/main"], cd: origin_path)
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
  # INV-MAI-5 — cas_push MUST NOT be called when health is red
  #
  # This is the direct falsification guard for the invariant statement:
  # "Falsified if a CAS push is attempted on a batch tip that produced a
  # :red health result."
  #
  # Uses the real default build_fun (Health.check via mix test) — not injected.
  # Injects SpyCas to detect any cas_push call.
  # ---------------------------------------------------------------------------

  describe "INV-MAI-5 — health check is pre-CAS; cas_push never called on a red tip" do
    @tag :"INV-MAI-5"
    @tag :ac_5
    @tag :d_303
    test "INV-MAI-5: when batch tip health is red, cas_push (origin/main CAS) is never attempted" do
      # Register the spy process under a known name so SpyCas.cas_push/3 can
      # notify us if it is ever called.
      spy_pid = self()
      Process.register(spy_pid, :inv_mai5_spy)

      on_exit(fn ->
        if Process.whereis(:inv_mai5_spy) == spy_pid do
          Process.unregister(:inv_mai5_spy)
        end
      end)

      tmp_dir = Briefly.create!(type: :directory)

      {origin_path, work_path, initial_main_oid} = setup_fixture_repo(tmp_dir)

      {branch_name, _tip} =
        add_red_branch(work_path, "feat/inv-mai5-red-#{System.unique_integer([:positive])}")

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
          {@merge_authority,
           name: ma_name,
           ledger: writer,
           repo_dir: work_path,
           required_halves: [:critic, :reviewer],
           tasks_name: tasks_name,
           # Inject SpyCas to detect any cas_push call.
           # The real build_fun (Health.check via mix test) is NOT injected —
           # health runs via real subprocess execution.
           cas: SpyCas},
          id: ma_name
        )

      assert :queued = @merge_authority.request_merge(ma_pid, unit)

      # Wait for M to process: real build_fun → Health.check (red) →
      # {:build_failed, {:health_red, _}} → eject → :idle.
      # The :committing state is NEVER entered on a red health result.
      result = wait_for_idle(ma_pid)

      assert result == :ok,
             "INV-MAI-5: timed out waiting for MergeAuthority to return to :idle " <>
               "after a red health eject. M MUST NOT hang when health is red."

      # PRIMARY ASSERTION — INV-MAI-5 falsification guard:
      # cas_push MUST NOT have been called when health returned :red.
      refute_received {:cas_push_called, _},
                      "INV-MAI-5 VIOLATED: cas_push was called on a batch tip whose " <>
                        "health check returned :red. The invariant requires health to gate " <>
                        "the CAS push — a red health result MUST eject the unit BEFORE any " <>
                        "CAS push is attempted (D-303, B5, SPEC-FACTORY-MERGE §4 B4 pre-condition)."

      # SECONDARY ASSERTION — confirm origin/main is unchanged (belt-and-suspenders).
      current_oid = origin_main_oid(origin_path)

      assert current_oid == initial_main_oid,
             "INV-MAI-5 / D-303: origin/main MUST be unchanged after a red health eject.\n" <>
               "Expected (initial): #{initial_main_oid}\n" <>
               "Got (current):      #{current_oid}"
    end
  end
end
