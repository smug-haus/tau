defmodule Tau.Factory.MergeBuildCleanTreeTest do
  @moduledoc """
  Gating tests for PR #522 (issue #521, D-385).

  D-385 — MergeAuthority build MUST run in a PRIVATE ephemeral worktree forked
  from the unit branch; M MUST NOT checkout/rebase/run the toolchain in the
  shared repo_dir tree. After a build, repo_dir's HEAD stays on its original
  branch (main) and its index is clean. repo_dir is the ref anchor only.

  Test 1 gates D-385: with a concurrent worktree holding unit-1, default_build
  still produces :merged and never mutates repo_dir's HEAD or index.
  Test 2 gates Sandbox.seed hygiene: .gitignore exists and suppresses .tau-factory/.

  Both tests FAIL before the implementer adds private-worktree build isolation
  to default_build/3 in lib/tau/factory/merge_authority.ex.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Tau.Factory.MergeAuthority
  alias Tau.Factory.Ledger.Writer, as: LedgerWriter
  alias Tau.Factory.Dogfood.Sandbox

  # ---------------------------------------------------------------------------
  # Test-local CAS stub — satisfies the CAS behaviour without a real remote.
  # ---------------------------------------------------------------------------

  defmodule StubCas do
    @moduledoc false

    def assert_all_verdicts_live(_ledger, _units, _halves), do: :all_pass

    def cas_push(_repo_dir, _tip, _expected_oid), do: :ok
  end

  # ---------------------------------------------------------------------------
  # Git helpers
  # ---------------------------------------------------------------------------

  # Build a real git topology:
  #   origin.git — bare repo
  #   work/      — clone; main has two commits (base + divergent);
  #                unit-1 branches from the FIRST commit and carries a
  #                COMMITTED, WARNING-FREE work file (lib/work.ex).
  #
  # The divergent commit on main makes the rebase genuinely non-trivial.
  # A minimal mix project (mix.exs + test/test_helper.exs) is seeded on
  # both main and unit-1 so Health.check (mix compile + mix test) passes
  # once the private-worktree build rebases and runs in the worktree.
  #
  # Returns {origin_path, work_path, base_oid}
  defp setup_repo(tmp_dir) do
    origin_path = Path.join(tmp_dir, "origin.git")
    work_path = Path.join(tmp_dir, "work")

    {_, 0} = System.cmd("git", ["init", "-b", "main", work_path])
    git = fn args -> System.cmd("git", args, cd: work_path, stderr_to_stdout: true) end
    git.(["config", "user.email", "test@tau.test"])
    git.(["config", "user.name", "Tau Test"])

    # Minimal Elixir project scaffold so Health.check passes.
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

    # Base commit — the fork point for unit-1.
    git.(["add", "."])
    {_, 0} = git.(["commit", "-m", "base: scaffold"])
    {base_raw, 0} = git.(["rev-parse", "HEAD"])
    base_oid = String.trim(base_raw)

    # Bare origin — push main at base.
    {_, 0} = System.cmd("git", ["init", "--bare", origin_path])
    {_, 0} = System.cmd("git", ["symbolic-ref", "HEAD", "refs/heads/main"], cd: origin_path)
    {_, 0} = git.(["remote", "add", "origin", origin_path])
    {_, 0} = git.(["push", "-u", "origin", "main"])

    # unit-1 branches from base; carries a committed, warning-free work file.
    {_, 0} = git.(["checkout", "-b", "unit-1"])

    File.write!(
      Path.join(work_path, "lib/work.ex"),
      "defmodule Work do\n  def answer, do: 42\nend\n"
    )

    {_, 0} = git.(["add", "lib/work.ex"])
    {_, 0} = git.(["commit", "-m", "feat: add lib/work.ex"])
    {_, 0} = git.(["push", "origin", "unit-1"])

    # Divergent commit on main (makes rebase non-trivial).
    {_, 0} = git.(["checkout", "main"])
    File.write!(Path.join(work_path, "README"), "divergent main commit\n")
    {_, 0} = git.(["add", "README"])
    {_, 0} = git.(["commit", "-m", "main: divergent commit"])
    {_, 0} = git.(["push", "origin", "main"])

    # Stay on main.
    {origin_path, work_path, base_oid}
  end

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
  # D-385 Test 1 — build isolation: private worktree; repo_dir HEAD untouched
  # ---------------------------------------------------------------------------

  describe "D-385 — default_build uses private ephemeral worktree; repo_dir HEAD stays on main" do
    @tag :d_385
    # Health.check runs mix compile + mix test — allow ample time.
    @tag timeout: 180_000
    test "D-385: concurrent worktree holding unit-1 does not cause collision; outcome :merged; repo_dir HEAD stays on main; index clean" do
      tmp_dir = Briefly.create!(type: :directory)

      unit = %{
        id: "d385-unit-#{System.unique_integer([:positive])}",
        hash: "hash-d385-#{System.unique_integer([:positive])}",
        run: "run-d385-001",
        branch: "unit-1"
      }

      {_origin_path, work_path, _base_oid} = setup_repo(tmp_dir)

      # Record repo_dir's starting HEAD (must be main).
      {starting_head_raw, 0} =
        System.cmd("git", ["rev-parse", "--abbrev-ref", "HEAD"], cd: work_path)

      starting_head = String.trim(starting_head_raw)

      assert starting_head == "main",
             "D-385 setup: repo_dir must start on main; got #{inspect(starting_head)}"

      # REPRODUCE THE COLLISION PRECONDITION:
      # A concurrent worktree checks out unit-1 in repo_dir. If default_build
      # tries `git checkout unit-1` in repo_dir (the pre-D-385 bug), git returns
      # "fatal: 'unit-1' is already used by worktree" and the build fails.
      other_ws = Path.join(tmp_dir, "other-worker-ws")

      {wt_out, wt_exit} =
        System.cmd("git", ["worktree", "add", other_ws, "unit-1"],
          cd: work_path,
          stderr_to_stdout: true
        )

      assert wt_exit == 0,
             "D-385 setup: failed to add competing worktree for unit-1: #{wt_out}"

      on_exit(fn ->
        System.cmd("git", ["worktree", "remove", "--force", other_ws], cd: work_path)
      end)

      # Ledger.Writer with pass verdicts so CAS proceeds to commit.
      db_path = Briefly.create!(extname: ".db")
      writer_name = :"test_d385_writer_#{System.unique_integer([:positive])}"

      writer =
        start_supervised!(
          {LedgerWriter, db_path: db_path, name: writer_name},
          id: writer_name
        )

      seed_pass_verdicts(writer, unit)

      # Subscribe to the per-unit PubSub topic BEFORE starting MA.
      # Topic: "factory:pr:<unit.id>" — D-356 (MergeAuthority broadcasts here).
      Phoenix.PubSub.subscribe(Tau.PubSub, "factory:pr:#{unit.id}")

      # Start MergeAuthority with NO build_fun override.
      # This exercises the REAL default_build/3 path — oracle separation is genuine.
      # Inject StubCas so commit step does not push to a real remote.
      ma_name = :"test_d385_ma_#{System.unique_integer([:positive])}"
      tasks_name = :"test_d385_tasks_#{System.unique_integer([:positive])}"

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

      # Submit the unit via the REAL entry point — no build_fun override.
      :queued = MergeAuthority.request_merge(ma_name, unit)

      # Wait for the per-unit PubSub outcome.
      # Pre-fix: default_build tries `git checkout unit-1` in repo_dir →
      # "fatal: 'unit-1' is already used by worktree" → {:build_failed,
      # {:git_error, 128, "..."}} → MA requeues → no :merged broadcast.
      # Post-fix: default_build uses a private `--detach` worktree →
      # no collision → rebase succeeds → Health.check passes → :merged.
      outcome =
        receive do
          {:merge_result, :merged} ->
            :merged

          {:merge_result, :rejected} ->
            :rejected
        after
          # Health.check (mix compile + mix test) takes ~30s; generous headroom.
          150_000 -> :timeout
        end

      # D-385 assertion (a): outcome MUST be :merged.
      # Pre-fix failure: outcome == :timeout (MA requeues indefinitely due to
      # git checkout collision; no terminal rejection is ever broadcast).
      assert outcome == :merged,
             "D-385: expected :merged but got #{inspect(outcome)}. " <>
               "default_build/3 likely tried `git checkout unit-1` in repo_dir while a " <>
               "concurrent worktree holds that branch. Fix: use a private `--detach` " <>
               "worktree in default_build/3 (the D-385 private-worktree build isolation)."

      # D-385 assertion (b): committed work file survives at the built tip.
      {work_ex_content, show_exit} =
        System.cmd("git", ["show", "origin/unit-1:lib/work.ex"],
          cd: work_path,
          stderr_to_stdout: true
        )

      assert show_exit == 0,
             "D-385: lib/work.ex must exist at the built tip on origin/unit-1"

      assert String.contains?(work_ex_content, "def answer"),
             "D-385: committed content must survive at built tip; got: #{inspect(work_ex_content)}"

      # D-385 assertion (c): the tip on unit-1 is rebased onto the divergent main commit.
      {parent_subject, _} =
        System.cmd("git", ["log", "--oneline", "-1", "origin/unit-1^"],
          cd: work_path,
          stderr_to_stdout: true
        )

      assert String.contains?(parent_subject, "divergent"),
             "D-385: tip parent must be the divergent main commit; got: #{inspect(parent_subject)}"

      # D-385 assertion (d): repo_dir HEAD still points at main after build.
      # This is the direct INV-11 / D-385 falsifier: if default_build checked out
      # unit-1 in repo_dir, HEAD would have moved off main.
      {head_after_raw, 0} =
        System.cmd("git", ["rev-parse", "--abbrev-ref", "HEAD"], cd: work_path)

      head_after = String.trim(head_after_raw)

      assert head_after == "main",
             "D-385 (INV-11): repo_dir HEAD must remain on main after build; " <>
               "got #{inspect(head_after)}. default_build mutated repo_dir's HEAD — " <>
               "M must use a private ephemeral worktree, leaving repo_dir as ref anchor only."

      # D-385 assertion (e): repo_dir index/working tree is clean after build.
      # If default_build ran rebase in repo_dir, the index would be dirty.
      {status_after, 0} =
        System.cmd("git", ["status", "--porcelain"], cd: work_path)

      assert String.trim(status_after) == "",
             "D-385 (INV-11): repo_dir index/working tree must be clean after build; " <>
               "got: #{inspect(status_after)}. default_build left dirty state in repo_dir."
    end
  end

  # ---------------------------------------------------------------------------
  # D-385 Test 2 — Sandbox.seed hygiene: .gitignore protects .tau-factory/
  # ---------------------------------------------------------------------------

  describe "D-385 — Sandbox.seed hygiene: .gitignore contains .tau-factory/" do
    @tag :d_385
    test "D-385: after Sandbox.seed/1, .gitignore exists and suppresses .tau-factory/ from git status" do
      tmp_dir = Briefly.create!(type: :directory)
      work_path = Path.join(tmp_dir, "seed_work")

      # Minimal git repo for Sandbox.seed/1 to operate on.
      {_, 0} = System.cmd("git", ["init", "-b", "main", work_path])
      git = fn args -> System.cmd("git", args, cd: work_path, stderr_to_stdout: true) end
      git.(["config", "user.email", "test@tau.test"])
      git.(["config", "user.name", "Tau Test"])

      # Bare origin so seed/1 can push.
      origin_path = Path.join(tmp_dir, "seed_origin.git")
      {_, 0} = System.cmd("git", ["init", "--bare", origin_path])
      {_, 0} = System.cmd("git", ["symbolic-ref", "HEAD", "refs/heads/main"], cd: origin_path)
      {_, 0} = git.(["remote", "add", "origin", origin_path])

      # Initial commit so seed/1 can push the scaffold commit.
      File.write!(Path.join(work_path, ".keep"), "")
      {_, 0} = git.(["add", ".keep"])
      {_, 0} = git.(["commit", "-m", "initial"])
      {_, 0} = git.(["push", "-u", "origin", "main"])

      # Invoke Sandbox.seed/1 — the function under test.
      :ok = Sandbox.seed(work_path)

      # D-385 assertion: .gitignore must exist.
      gitignore_path = Path.join(work_path, ".gitignore")

      assert File.exists?(gitignore_path),
             "D-385: Sandbox.seed/1 must write .gitignore; file missing at #{gitignore_path}"

      gitignore_content = File.read!(gitignore_path)

      assert String.contains?(gitignore_content, ".tau-factory/"),
             "D-385: .gitignore must contain '.tau-factory/' to protect the Ledger dir; " <>
               "got content: #{inspect(gitignore_content)}"

      # D-385 corollary: after seeding, a .tau-factory/ directory must NOT appear
      # as an untracked entry in git status — the .gitignore suppresses it.
      File.mkdir_p!(Path.join(work_path, ".tau-factory"))
      File.write!(Path.join(work_path, ".tau-factory/ledger.db"), "")
      {status_out, 0} = System.cmd("git", ["status", "--short"], cd: work_path)

      refute String.contains?(status_out, ".tau-factory"),
             "D-385: .tau-factory/ must be suppressed by .gitignore in git status; " <>
               "got: #{inspect(status_out)}"
    end
  end
end
