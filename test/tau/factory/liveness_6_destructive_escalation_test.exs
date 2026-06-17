defmodule Tau.Factory.Liveness6DestructiveEscalationTest do
  @moduledoc """
  Gating test for issue #617 — LIVE-liveness-6 / D-319 / INV-20.

  ## Invariant

  > E-DESTRUCTIVE escalation fires for any destructive or irreversible action
  > requested (e.g. force-push, history rewrite, data migration). Falsified by:
  > the coordinator executing such an action without escalating.

  (docs/arch/02-requirements/liveness.md, SPEC-FACTORY-GOV.md B7/B8/D-319)

  ## The gap (audit finding — issue #617)

  `MergeAuthority.do_build_in_worktree/4` (the default `:build_fun` path) calls
  `System.cmd("git", ["push", "--force-with-lease", "origin", "HEAD:<branch>"])`
  directly with **no prior call to `ActionClassifier.classify/1`** (the gate
  mandated by D-319 / SPEC-FACTORY-GOV §4 B7 C207). `ActionClassifier` and its
  `@destructive` denylist (`:force_push`, `:history_rewrite`, `:release`,
  `:external_publish`, `:data_migration`) exist but are dead code.

  ## Contract under test (SPEC-FACTORY-GOV §4 B7, C207, D-319)

  `ActionClassifier.classify/1` MUST be called **before** any side-effecting
  execution of the `git push --force-with-lease` in the default build path.

  The `@destructive` denylist includes `:force_push`.
  `ActionClassifier.classify(%Action{kind: :force_push})` → `{:deny, :destructive}`.
  If `classify/1` is called before the push, the push is blocked and
  `origin/<branch>` is NOT updated.

  ## Observable used by this test

  The test sets up a git topology where:
    1. A feature branch is created off an **initial** `main` commit.
    2. `origin/main` is then **advanced** by one more commit, so the feature
       branch sits behind origin/main.
    3. `MergeAuthority` is started WITHOUT an injected `build_fun` (real default
       `do_build_in_worktree/4` runs).
    4. After the build concludes, the test reads `origin/<branch>`.

  Expected (conformant, post-fix):
    - `classify(%Action{kind: :force_push})` is called → `{:deny, :destructive}`
      → push is blocked → `origin/<branch>` retains its original SHA.

  Fail-before (current, broken):
    - `classify/1` NOT called → `git push --force-with-lease` runs directly
      → rebase creates a new SHA and pushes it to `origin/<branch>`
      → `origin/<branch>` SHA CHANGES from its original value.

  The assertion `assert origin_branch_sha == original_tip` FAILS against current
  code (SHA changed = push executed without classification).

  ## AC/D-NNN linkage

    - LIVE-liveness-6 (issue #617, audit finding)
    - D-319 (no unilateral destruction — action classifier gate; SPEC-FACTORY-GOV)
    - INV-20 (no autonomously executed destructive action)
  """

  use ExUnit.Case, async: false

  alias Tau.Factory.MergeAuthority
  alias Tau.Factory.Ledger.Writer, as: LedgerWriter

  @moduletag :capture_log
  @moduletag :live_liveness_6
  @moduletag :d_319
  @moduletag :inv_20

  # CAS seam: lets :committing run without a real origin/main push.
  defmodule PassingCas do
    @moduledoc false
    def assert_all_verdicts_live(_ledger, _units, _required_halves), do: :all_pass
    def cas_push(_repo_dir, _tip, _base), do: :ok
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique(base), do: :"#{base}_#{System.unique_integer([:positive])}"

  defp start_ledger do
    db_path = Briefly.create!(extname: ".db")
    writer_name = unique(:liveness6_ledger)

    start_supervised!(
      {LedgerWriter, db_path: db_path, name: writer_name},
      id: writer_name
    )

    writer_name
  end

  defp seed_pass_verdicts(ledger, %{hash: hash, run: run}) do
    for half <- [:critic, :reviewer] do
      {:ok, _} =
        LedgerWriter.append_verdict(ledger, %{
          hash: hash,
          run: run,
          half: half,
          status: :pass,
          idempotency_key: "ikey-#{half}-#{System.unique_integer([:positive])}"
        })
    end
  end

  # Set up a git topology where feature branch sits behind origin/main.
  # Returns {work_path, origin_path, original_branch_tip}.
  defp setup_git_repo_advanced_main(unit) do
    tmp_dir = Briefly.create!(type: :directory)
    work_path = Path.join(tmp_dir, "work")
    origin_path = Path.join(tmp_dir, "origin.git")

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

    # Feature branch off initial main.
    feature_name = String.replace(unit.branch, "/", "_")
    {_, 0} = git_work.(["checkout", "-b", unit.branch])
    File.write!(Path.join(work_path, "feature_#{feature_name}"), "feature work")
    {_, 0} = git_work.(["add", "."])
    {_, 0} = git_work.(["commit", "-m", "feature commit"])
    {original_tip_raw, 0} = git_work.(["rev-parse", "HEAD"])
    original_tip = String.trim(original_tip_raw)
    {_, 0} = git_work.(["push", "origin", unit.branch])
    {_, 0} = git_work.(["checkout", "main"])

    # Advance origin/main beyond the initial commit.  Now the feature branch
    # is behind origin/main, so the rebase in do_build_in_worktree/4 produces
    # a NEW commit SHA — making it observable whether the push executed.
    File.write!(Path.join(work_path, "advance"), "advance main")
    git_work.(["add", "."])
    {_, 0} = git_work.(["commit", "-m", "advance origin/main"])
    {_, 0} = git_work.(["push", "origin", "main"])

    {work_path, origin_path, original_tip}
  end

  defp origin_branch_sha(origin_path, branch) do
    {raw, 0} = System.cmd("git", ["rev-parse", "refs/heads/#{branch}"], cd: origin_path)
    String.trim(raw)
  end

  # ---------------------------------------------------------------------------
  # LIVE-liveness-6 / D-319 — gating test
  # ---------------------------------------------------------------------------

  describe "LIVE-liveness-6 / D-319 — classify/1 must gate push in default build_fun" do
    @tag :live_liveness_6
    @tag :d_319
    @tag :inv_20
    test "LIVE-liveness-6 / D-319: :force_push classified as destructive; origin/<branch> must NOT advance" do
      # -----------------------------------------------------------------------
      # D-319 / SPEC-FACTORY-GOV §4 B7, C207:
      #   ActionClassifier.classify/1 MUST be called BEFORE git push
      #   --force-with-lease in do_build_in_worktree/4.
      #   :force_push ∈ @destructive → {deny, :destructive} → push MUST NOT run.
      #
      # Observable: origin/<branch> SHA must stay at original_tip after the build.
      # FAIL-BEFORE: current code skips classify/1; rebase + push execute;
      #              origin/<branch> SHA changes. Assertion below FAILS.
      # -----------------------------------------------------------------------

      ledger = start_ledger()

      unit = %{
        id: "u-liveness6-#{System.unique_integer([:positive])}",
        hash: "hash-liveness6-#{System.unique_integer([:positive])}",
        run: "run-liveness6-#{System.unique_integer([:positive])}",
        branch: "feat/liveness6-#{System.unique_integer([:positive])}"
      }

      {work_path, origin_path, original_tip} = setup_git_repo_advanced_main(unit)
      seed_pass_verdicts(ledger, unit)

      :ok = Phoenix.PubSub.subscribe(Tau.PubSub, "factory:pr:#{unit.id}")

      ma_name = unique(:liveness6_ma)
      tasks_name = unique(:liveness6_tasks)

      # No :build_fun override — uses real default do_build_in_worktree/4.
      _ma =
        start_supervised!(
          {MergeAuthority,
           name: ma_name,
           ledger: ledger,
           repo_dir: work_path,
           required_halves: [:critic, :reviewer],
           tasks_name: tasks_name,
           cas: PassingCas,
           build_backoff_ms: 10,
           build_retry_max: 0},
          id: ma_name
        )

      :queued = MergeAuthority.request_merge(ma_name, unit)

      # Wait for the build to complete (any terminal outcome).
      assert_receive {:merge_result, _},
                     15_000,
                     "Timeout: MergeAuthority never emitted a merge_result on factory:pr:#\{unit.id\}"

      Process.sleep(200)

      # KEY ASSERTION — LIVE-liveness-6 / D-319:
      # If classify/1 was called before the push and returned {:deny, :destructive},
      # the push was blocked and origin/<branch> MUST still be at original_tip.
      #
      # If the SHA changed, the push ran WITHOUT classification — D-319 violation.
      actual_sha = origin_branch_sha(origin_path, unit.branch)

      assert actual_sha == original_tip,
             """
             LIVE-liveness-6 / D-319 VIOLATED.

             origin/<branch> SHA changed after the default build path ran:
               original (before build): #{original_tip}
               actual   (after build):  #{actual_sha}

             A changed SHA means git push --force-with-lease executed WITHOUT
             ActionClassifier.classify/1 being called first.

             do_build_in_worktree/4 MUST call:
               ActionClassifier.classify(%Action{kind: :force_push})
             BEFORE executing:
               git push --force-with-lease origin HEAD:<branch>

             Since :force_push ∈ @destructive, classify/1 returns {:deny, :destructive},
             which MUST block the push (SPEC-FACTORY-GOV §4 B7 C207, D-319,
             INV-20: □(destructive(a) → escalate ∧ ¬auto_execute)).
             """
    end
  end
end
