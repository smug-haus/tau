defmodule Tau.Factory.MergeBuildCleanTreeTest do
  @moduledoc """
  Gating tests for PR #522 (issue #521, D-384).

  D-384 — MergeAuthority.default_build/3 produces a clean rebased tree from any
  prior repo_dir state; a staged deletion (the run-#4 index state) MUST NOT
  prevent rebase or lose committed work.

  Both tests FAIL before the implementer adds:
    1. `git reset --hard HEAD` before `git rebase` in `default_build/3`
       (lib/tau/factory/merge_authority.ex)
    2. `.gitignore` containing `.tau-factory/` written by `Sandbox.seed/1`
       (lib/tau/factory/dogfood/sandbox.ex)

  These tests exercise the REAL default build path via `request_merge/2` with
  NO `build_fun` override — oracle separation is genuine.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Tau.Factory.MergeAuthority
  alias Tau.Factory.Ledger.Writer, as: LedgerWriter
  alias Tau.Factory.Dogfood.Sandbox

  # ---------------------------------------------------------------------------
  # Test-local CAS stub
  # No production code — just an inline module that satisfies the CAS behaviour
  # the MergeAuthority asks for, so committing completes without a real remote.
  # ---------------------------------------------------------------------------

  defmodule StubCas do
    @moduledoc false

    def assert_all_verdicts_live(_ledger, _units, _halves), do: :all_pass

    def cas_push(_repo_dir, _tip, _expected_oid), do: :ok
  end

  # ---------------------------------------------------------------------------
  # Git helpers (mirrored from merge_serialized_test.exs pattern)
  # ---------------------------------------------------------------------------

  # Build a real git topology:
  #   origin.git — bare repo
  #   work/      — clone with main + unit branch
  #
  # main has TWO commits (base + divergent), unit-1 branches from the FIRST
  # commit and adds `lib/work.ex` — so the rebase is genuinely non-trivial
  # (there is a divergent commit on main that must be applied on top).
  #
  # Also seeds a minimal Elixir project (mix.exs + test/test_helper.exs) on
  # main so Health.check (mix compile + mix test) passes after the fix lands.
  #
  # Returns {origin_path, work_path, base_oid, unit_tip}
  defp setup_dirty_repo(tmp_dir) do
    origin_path = Path.join(tmp_dir, "origin.git")
    work_path = Path.join(tmp_dir, "work")

    # Init non-bare work repo, identity, initial commit on main.
    {_, 0} = System.cmd("git", ["init", "-b", "main", work_path])
    git = fn args -> System.cmd("git", args, cd: work_path, stderr_to_stdout: true) end
    git.(["config", "user.email", "test@tau.test"])
    git.(["config", "user.name", "Tau Test"])

    # Seed a minimal Elixir project so Health.check passes (mix compile + mix test).
    File.mkdir_p!(Path.join(work_path, "lib"))
    File.mkdir_p!(Path.join(work_path, "test"))

    File.write!(Path.join(work_path, "mix.exs"), """
    defmodule WorkRepo.MixProject do
      use Mix.Project
      def project, do: [app: :work_repo, version: "0.1.0", elixir: "~> 1.14", deps: []]
      def application, do: [extra_applications: [:logger]]
    end
    """)

    File.write!(Path.join(work_path, "test/test_helper.exs"), "ExUnit.start()\n")

    # Initial commit — the base off which unit-1 will branch.
    git.(["add", "."])
    {_, 0} = git.(["commit", "-m", "base: scaffold"])
    {base_oid_raw, 0} = git.(["rev-parse", "HEAD"])
    base_oid = String.trim(base_oid_raw)

    # Create bare origin and push main at base.
    {_, 0} = System.cmd("git", ["init", "--bare", origin_path])
    {_, 0} = System.cmd("git", ["symbolic-ref", "HEAD", "refs/heads/main"], cd: origin_path)
    {_, 0} = git.(["remote", "add", "origin", origin_path])
    {_, 0} = git.(["push", "-u", "origin", "main"])

    # Branch unit-1 from base_oid; add a COMMITTED work-product file.
    {_, 0} = git.(["checkout", "-b", "unit-1"])

    File.write!(
      Path.join(work_path, "lib/work.ex"),
      "defmodule Work do\n  def answer, do: 42\nend\n"
    )

    {_, 0} = git.(["add", "lib/work.ex"])
    {_, 0} = git.(["commit", "-m", "feat: add lib/work.ex (committed unit work)"])
    {unit_tip_raw, 0} = git.(["rev-parse", "HEAD"])
    unit_tip = String.trim(unit_tip_raw)
    {_, 0} = git.(["push", "origin", "unit-1"])

    # Return to main, add a DIVERGENT commit (makes rebase non-trivial).
    {_, 0} = git.(["checkout", "main"])
    File.write!(Path.join(work_path, "README"), "divergent main commit\n")
    {_, 0} = git.(["add", "README"])
    {_, 0} = git.(["commit", "-m", "main: divergent commit"])
    {_, 0} = git.(["push", "origin", "main"])

    # Stay on main.
    {origin_path, work_path, base_oid, unit_tip}
  end

  # Seed pass verdicts for a unit in the given writer.
  defp seed_pass_verdicts(writer, unit) do
    for half <- [:critic, :reviewer] do
      {:ok, _} =
        LedgerWriter.append_verdict(writer, %{
          hash: unit.hash,
          run: unit.run,
          half: half,
          status: :pass,
          idempotency_key: "ikey-#{half}-#{System.unique_integer([:positive])}"
        })
    end
  end

  # ---------------------------------------------------------------------------
  # D-384 test 1 — build on dirty repo (staged deletion of committed file)
  # ---------------------------------------------------------------------------

  describe "D-384 — default_build idempotent on dirty repo_dir" do
    @tag :d_384
    # Allow enough time for Health.check (mix compile + mix test) after the fix.
    @tag timeout: 120_000
    test "D-384: staged deletion of committed work file does not block rebase; committed content survives at built tip" do
      tmp_dir = Briefly.create!(type: :directory)
      test_pid = self()

      unit = %{
        id: "d384-unit-#{System.unique_integer([:positive])}",
        hash: "hash-d384-#{System.unique_integer([:positive])}",
        run: "run-d384-001",
        branch: "unit-1"
      }

      {_origin_path, work_path, _base_oid, _unit_tip} = setup_dirty_repo(tmp_dir)

      # Start Ledger.Writer with pass verdicts so CAS proceeds to commit.
      db_path = Briefly.create!(extname: ".db")
      writer_name = :"test_d384_writer_#{System.unique_integer([:positive])}"

      writer =
        start_supervised!(
          {LedgerWriter, db_path: db_path, name: writer_name},
          id: writer_name
        )

      seed_pass_verdicts(writer, unit)

      # Subscribe to PubSub BEFORE starting MA so we receive the merge result.
      Phoenix.PubSub.subscribe(Tau.PubSub, "factory:pr:#{unit.id}")

      # Attach a telemetry listener for :reject events so we can detect the
      # non-terminal build failure (git_error requeue) WITHOUT waiting for
      # infinite requeue cycles to time out. The :reject telemetry fires on
      # the FIRST failed build attempt; PubSub :rejected fires only on terminal
      # (health_red) ejections. We use telemetry as the early-failure signal.
      telemetry_handler_id = "d384-reject-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        telemetry_handler_id,
        [:tau, :factory, :merge, :reject],
        fn _event, _measurements, _metadata, _config ->
          send(test_pid, :build_rejected_by_telemetry)
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(telemetry_handler_id) end)

      # Check out the unit branch so the index has lib/work.ex tracked.
      # The staged deletion must be planted on unit-1, not on main — main
      # never had lib/work.ex so force-remove there is a no-op.
      {_, 0} =
        System.cmd("git", ["checkout", "unit-1"],
          cd: work_path,
          stderr_to_stdout: true
        )

      # PLANT the run-#4 index state: a staged deletion of the committed file.
      # This replicates the dirty-repo condition that causes `git rebase` to abort
      # without `git reset --hard HEAD` first (the bug D-384 fixes).
      {_, 0} =
        System.cmd("git", ["update-index", "--force-remove", "lib/work.ex"],
          cd: work_path,
          stderr_to_stdout: true
        )

      # Confirm the deletion is actually staged (guard: setup must be correct).
      {git_status, 0} = System.cmd("git", ["status", "--short"], cd: work_path)

      assert String.contains?(git_status, "D") and String.contains?(git_status, "lib/work.ex"),
             "D-384 setup: staged deletion not visible in git status; got: #{inspect(git_status)}"

      # Start MergeAuthority with NO build_fun override — exercises the REAL
      # default_build/3 path (lib/tau/factory/merge_authority.ex).
      # Inject StubCas so the commit step does not push to a real remote.
      ma_name = :"test_d384_ma_#{System.unique_integer([:positive])}"
      tasks_name = :"test_d384_tasks_#{System.unique_integer([:positive])}"

      _ma_pid =
        start_supervised!(
          {MergeAuthority,
           name: ma_name,
           ledger: writer,
           repo_dir: work_path,
           required_halves: [:critic, :reviewer],
           tasks_name: tasks_name,
           cas: StubCas,
           pubsub: Tau.PubSub},
          id: ma_name
        )

      # Submit the unit — exercises the REAL default_build/3 via request_merge/2.
      # default_build/3 is private; request_merge is the real entry point.
      :queued = MergeAuthority.request_merge(ma_name, unit)

      # Wait for either:
      #   {:merge_result, :merged}   — build + commit succeeded (expected after fix)
      #   :build_rejected_by_telemetry — telemetry :reject fired on requeue
      #                                  (expected before fix: staged deletion aborts rebase)
      #
      # The CURRENT code (no reset --hard) will trigger :build_rejected_by_telemetry
      # because rebase fails, returns {:build_failed, {:git_error, 1, ...}}, and
      # the MA requeues. We surface that as a test failure so the test fails RED.
      # After the fix, the :merged PubSub message arrives instead.
      outcome =
        receive do
          {:merge_result, :merged} ->
            :merged

          :build_rejected_by_telemetry ->
            :build_failed_on_dirty_repo
        after
          # Health.check (mix compile + mix test) can take ~30s; allow headroom.
          90_000 -> :timeout
        end

      # D-384 assertion (a): build MUST succeed.
      # Current code fails: git rebase aborts due to staged deletion →
      # {:build_failed, {:git_error, 1, "cannot rebase..."}} → :reject telemetry →
      # outcome == :build_failed_on_dirty_repo → this assert fires.
      assert outcome == :merged,
             "D-384: expected :merged but got #{inspect(outcome)}. " <>
               "default_build/3 failed on dirty repo_dir (run-#4 staged deletion). " <>
               "Fix: add 'git reset --hard HEAD' before 'git rebase <base>' in default_build/3."

      # D-384 assertion (b): committed work file survives at the built tip.
      {file_content_at_tip, show_exit} =
        System.cmd("git", ["show", "HEAD:lib/work.ex"], cd: work_path, stderr_to_stdout: true)

      assert show_exit == 0,
             "D-384: lib/work.ex must exist at the built tip"

      assert String.contains?(file_content_at_tip, "def answer"),
             "D-384: committed content must survive at built tip; got: #{inspect(file_content_at_tip)}"

      # D-384 assertion (c): tip is rebased onto the divergent main commit.
      {parent_subject, 0} =
        System.cmd("git", ["log", "--oneline", "-1", "HEAD^"], cd: work_path)

      assert String.contains?(parent_subject, "divergent"),
             "D-384: tip parent must be the divergent main commit; got: #{inspect(parent_subject)}"

      # D-384 assertion (d): working tree is clean after build.
      {status_after, 0} = System.cmd("git", ["status", "--short"], cd: work_path)

      assert String.trim(status_after) == "",
             "D-384: working tree must be clean after build; got: #{inspect(status_after)}"
    end
  end

  # ---------------------------------------------------------------------------
  # D-384 test 2 — Sandbox.seed writes .gitignore containing .tau-factory/
  # ---------------------------------------------------------------------------

  describe "D-384 — Sandbox.seed writes .gitignore to protect Ledger dir" do
    @tag :d_384
    test "D-384: after Sandbox.seed/1, .gitignore exists and contains .tau-factory/" do
      tmp_dir = Briefly.create!(type: :directory)
      work_path = Path.join(tmp_dir, "seed_work")

      # Minimal git repo setup so Sandbox.seed/1 has a valid git repo to operate on.
      {_, 0} = System.cmd("git", ["init", "-b", "main", work_path])
      git = fn args -> System.cmd("git", args, cd: work_path, stderr_to_stdout: true) end
      git.(["config", "user.email", "test@tau.test"])
      git.(["config", "user.name", "Tau Test"])

      # Bare origin so seed/1 can push.
      origin_path = Path.join(tmp_dir, "seed_origin.git")
      {_, 0} = System.cmd("git", ["init", "--bare", origin_path])
      {_, 0} = System.cmd("git", ["symbolic-ref", "HEAD", "refs/heads/main"], cd: origin_path)
      {_, 0} = git.(["remote", "add", "origin", origin_path])

      # Seed requires an initial commit + push before it can commit scaffold.
      File.write!(Path.join(work_path, ".keep"), "")
      {_, 0} = git.(["add", ".keep"])
      {_, 0} = git.(["commit", "-m", "initial"])
      {_, 0} = git.(["push", "-u", "origin", "main"])

      # Invoke Sandbox.seed/1 — the function under test.
      :ok = Sandbox.seed(work_path)

      # D-384 assertion: .gitignore must exist and contain .tau-factory/.
      gitignore_path = Path.join(work_path, ".gitignore")

      assert File.exists?(gitignore_path),
             "D-384: Sandbox.seed/1 must write .gitignore; file missing at #{gitignore_path}"

      gitignore_content = File.read!(gitignore_path)

      assert String.contains?(gitignore_content, ".tau-factory/"),
             "D-384: .gitignore must contain '.tau-factory/' to protect the Ledger dir; " <>
               "got content: #{inspect(gitignore_content)}"

      # D-384 corollary: after seed, no untracked .tau-factory/ entry appears
      # in git status (the .gitignore must suppress it).
      File.mkdir_p!(Path.join(work_path, ".tau-factory"))
      File.write!(Path.join(work_path, ".tau-factory/ledger.db"), "")
      {status_out, 0} = System.cmd("git", ["status", "--short"], cd: work_path)

      refute String.contains?(status_out, ".tau-factory"),
             "D-384: .tau-factory/ must be suppressed by .gitignore in git status; " <>
               "got: #{inspect(status_out)}"
    end
  end
end
