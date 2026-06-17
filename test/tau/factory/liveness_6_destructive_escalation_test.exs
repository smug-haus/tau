defmodule Tau.Factory.Liveness6DestructiveEscalationTest do
  @moduledoc """
  Gating test for issue #617 — LIVE-liveness-6 / D-319 / INV-20.

  ## Invariant

  > E-DESTRUCTIVE escalation fires for any destructive or irreversible action
  > requested (e.g. force-push, history rewrite, data migration). Falsified by:
  > the coordinator executing such an action without escalating.

  (docs/arch/02-requirements/liveness.md, SPEC-FACTORY-GOV.md B7/B8/D-319)

  ## Correct boundary (SPEC-FACTORY-MERGE §4 B7, SPEC-FACTORY-GOV §4 B7/B8)

  SPEC-FACTORY-MERGE §4 B7: any non-M push to origin/main must be classified
  as E-DESTRUCTIVE. M IS the authorized sole writer of origin/main (C200-B4).
  M's own controlled CAS push MUST NOT be blocked — it is M's authorized op.

  SPEC-FACTORY-GOV §4 B7/B8: ActionClassifier.classify/1 gates destructive
  actions on effecting paths. A {:deny, :destructive} verdict routes to K as
  E-DESTRUCTIVE via "factory:control". The denylist correctly contains
  :force_push — for non-M actors. M's own merge push must use a non-destructive
  action kind (e.g. :merge_push / :cas_push) that is :allow — otherwise every
  authorized merge is permanently blocked.

  ## Test 1 — D-319 B8 routing

  Uses an injected build_fun that returns
  {:build_failed, {:destructive_action_denied, :force_push}}, simulating what
  MUST happen when a non-M actor's destructive push is detected. Asserts that
  MergeAuthority broadcasts {:escalate, {:"E-DESTRUCTIVE", :unit}} on
  "factory:control" (the B8 routing boundary).

  FAIL-BEFORE (original broken state — classify not called):
    The {:destructive_action_denied, _} routing branch is dead code; no
    E-DESTRUCTIVE broadcast is ever emitted. assert_receive times out and FAILS.

  ## Test 2 — D-319 M-exemption (PRIMARY FAIL-BEFORE)

  Exercises the REAL default do_build_in_worktree/4 path (no build_fun
  injection). A minimal bare git repo is provided; the build will proceed
  past the classify step if the fix is applied (using an :allow action kind
  for M's authorized push).

  FAIL-BEFORE (current broken state): do_build_in_worktree/4 calls
  ActionClassifier.classify(%Action{kind: :force_push}) unconditionally.
  The captured log contains "destructive_action_denied" because classify
  returns {:deny, :destructive} and the push is blocked. The refute_log
  assertion FAILS.

  POST-FIX (conformant state): do_build_in_worktree/4 uses a non-destructive
  action kind (:merge_push / :cas_push / or no classify call on M's own push);
  classify/1 returns :allow; the git push proceeds. The log either contains
  {:health_red, ...} (if health check runs on the minimal repo) or no build
  failure at all. The refute_log assertion PASSES.

  ## AC/D-NNN linkage

    - LIVE-liveness-6 (issue #617, audit finding)
    - D-319 (no unilateral destruction — action classifier gate; SPEC-FACTORY-GOV)
    - INV-20 (no autonomously executed destructive action)
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Tau.Factory.MergeAuthority
  alias Tau.Factory.Ledger.Writer, as: LedgerWriter

  @moduletag :capture_log
  @moduletag :live_liveness_6
  @moduletag :d_319
  @moduletag :inv_20

  # ---------------------------------------------------------------------------
  # CAS seam: allows :committing to run without a real origin/main push.
  # ---------------------------------------------------------------------------

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

  defp new_unit do
    n = System.unique_integer([:positive])

    %{
      id: "u-liveness6-#{n}",
      hash: "hash-liveness6-#{n}",
      run: "run-liveness6-#{n}",
      branch: "feat/liveness6-#{n}"
    }
  end

  # Set up a minimal git topology:
  #   origin.git — bare repo
  #   work/      — clone; main has one commit; unit branch has one commit.
  # No Elixir project scaffold — health check will fail after the push, but
  # the classify check happens BEFORE the push, so we can observe whether the
  # build was blocked by classify (wrong) or by health (correct after fix).
  defp setup_real_git_repo(unit) do
    tmp = Briefly.create!(type: :directory)
    work_path = Path.join(tmp, "work")
    origin_path = Path.join(tmp, "origin.git")

    {_, 0} = System.cmd("git", ["init", "-b", "main", work_path])

    git = fn args ->
      System.cmd("git", args, cd: work_path, stderr_to_stdout: true)
    end

    git.(["config", "user.email", "test@tau.test"])
    git.(["config", "user.name", "Tau Test"])
    File.write!(Path.join(work_path, "README"), "init")
    git.(["add", "README"])
    {_, 0} = git.(["commit", "-m", "init"])

    {_, 0} = System.cmd("git", ["init", "--bare", origin_path])
    {_, 0} = System.cmd("git", ["symbolic-ref", "HEAD", "refs/heads/main"], cd: origin_path)
    {_, 0} = git.(["remote", "add", "origin", origin_path])
    {_, 0} = git.(["push", "-u", "origin", "main"])

    # Feature branch off main with one commit.
    {_, 0} = git.(["checkout", "-b", unit.branch])
    File.write!(Path.join(work_path, "feature.txt"), "feature work")
    {_, 0} = git.(["add", "."])
    {_, 0} = git.(["commit", "-m", "feature commit"])
    {_, 0} = git.(["push", "origin", unit.branch])
    {_, 0} = git.(["checkout", "main"])

    work_path
  end

  # ---------------------------------------------------------------------------
  # Test 1 — D-319 B8 routing: destructive action signal escalates to K as
  #           E-DESTRUCTIVE on "factory:control"
  # ---------------------------------------------------------------------------

  describe "LIVE-liveness-6 / D-319 — B8 routing: {:destructive_action_denied, …} → E-DESTRUCTIVE on factory:control" do
    @tag :live_liveness_6
    @tag :d_319
    @tag :inv_20
    test "LIVE-liveness-6 / D-319: build_fun signaling {:destructive_action_denied, :force_push} causes E-DESTRUCTIVE on factory:control" do
      # -----------------------------------------------------------------------
      # SPEC-FACTORY-GOV §4 B8 / D-319 / INV-20:
      #   When any effecting path signals {:destructive_action_denied, action}
      #   (ActionClassifier returned {:deny, :destructive}), MergeAuthority MUST
      #   broadcast {:escalate, {:"E-DESTRUCTIVE", :unit}} on "factory:control"
      #   so the Coordinator can halt/surface the escalation.
      #
      # This tests the B8 routing boundary — not whether M's own push is
      # blocked (wrong boundary per SPEC-FACTORY-MERGE C200-B4), but whether
      # the E-DESTRUCTIVE escalation is correctly routed when a destructive
      # action is detected from an external/non-M source.
      #
      # FAIL-BEFORE (original: classify not called at all):
      #   The {:destructive_action_denied, _} handler is dead code; no
      #   E-DESTRUCTIVE broadcast ever fires; assert_receive times out.
      # -----------------------------------------------------------------------

      ledger = start_ledger()
      unit = new_unit()
      repo_dir = setup_real_git_repo(unit)

      seed_pass_verdicts(ledger, unit)

      :ok = Phoenix.PubSub.subscribe(Tau.PubSub, "factory:control")
      :ok = Phoenix.PubSub.subscribe(Tau.PubSub, "factory:pr:#{unit.id}")

      ma_name = unique(:liveness6_ma_t1)
      tasks_name = unique(:liveness6_tasks_t1)

      # Inject a build_fun that simulates ActionClassifier denying a :force_push
      # from a non-M actor — the signal the real code path MUST produce when
      # classify/1 returns {:deny, :destructive} for a non-M destructive action.
      injected_build_fun = fn _units, _base ->
        {:build_failed, {:destructive_action_denied, :force_push}}
      end

      _ma =
        start_supervised!(
          {MergeAuthority,
           name: ma_name,
           ledger: ledger,
           repo_dir: repo_dir,
           required_halves: [:critic, :reviewer],
           tasks_name: tasks_name,
           cas: PassingCas,
           build_fun: injected_build_fun,
           build_backoff_ms: 10,
           build_retry_max: 0},
          id: ma_name
        )

      :queued = MergeAuthority.request_merge(ma_name, unit)

      # KEY ASSERTION — D-319 B8:
      # MergeAuthority MUST broadcast E-DESTRUCTIVE on "factory:control" when
      # a destructive action is detected (INV-20:
      # □(destructive(a) → escalate ∧ ¬auto_execute)).
      assert_receive {:escalate, {:"E-DESTRUCTIVE", :unit}},
                     5_000,
                     """
                     LIVE-liveness-6 / D-319 B8 VIOLATED.

                     Expected {:escalate, {:"E-DESTRUCTIVE", :unit}} on "factory:control"
                     after build_fun signaled {:build_failed, {:destructive_action_denied, :force_push}},
                     but no such message was received within 5 seconds.

                     MergeAuthority MUST route a {:destructive_action_denied, _} build failure
                     to the Coordinator as E-DESTRUCTIVE via Phoenix.PubSub on "factory:control".
                     (SPEC-FACTORY-GOV §4 B8 / D-319 / INV-20)
                     """

      assert_receive {:merge_result, :rejected},
                     2_000,
                     """
                     D-319: expected :rejected on "factory:pr:#{unit.id}" after
                     E-DESTRUCTIVE escalation, but no :rejected was received.
                     A destructive-action-denied build failure must terminate the unit
                     as :rejected (terminal; D-319 non-retryable path).
                     """
    end
  end

  # ---------------------------------------------------------------------------
  # Test 2 — D-319 M-exemption (PRIMARY FAIL-BEFORE):
  #           M's authorized merge push MUST NOT be blocked by ActionClassifier.
  #           Uses the REAL default do_build_in_worktree/4 path (no injection).
  #           Asserts the build failure reason is NOT :destructive_action_denied.
  # ---------------------------------------------------------------------------

  describe "LIVE-liveness-6 / D-319 — M-exemption: real build path must NOT be blocked by classify(:force_push)" do
    @tag :live_liveness_6
    @tag :d_319
    @tag :inv_20
    @tag timeout: 30_000
    test "LIVE-liveness-6 / D-319: real do_build_in_worktree/4 must not log :destructive_action_denied for M's authorized push" do
      # -----------------------------------------------------------------------
      # SPEC-FACTORY-MERGE §4 C200-B4 / SPEC-FACTORY-GOV §4 B7:
      #   M's authorized push must use a non-destructive action kind so that
      #   ActionClassifier.classify/1 returns :allow.
      #
      # FAIL-BEFORE (current broken state):
      #   do_build_in_worktree/4 calls classify(%Action{kind: :force_push})
      #   unconditionally — :force_push ∈ @destructive → {:deny, :destructive}
      #   → short-circuits immediately with
      #     {:build_failed, {:destructive_action_denied, :force_push}}
      #   → Logger.warning logs "build failed: {:destructive_action_denied, :force_push}"
      #   → The captured log CONTAINS "destructive_action_denied".
      #   The refute assertion FAILS.
      #
      # POST-FIX (conformant state):
      #   do_build_in_worktree/4 uses classify(%Action{kind: :merge_push}) or
      #   classify(%Action{kind: :cas_push}) or does not classify M's own push
      #   as :force_push; classify returns :allow; the git push proceeds.
      #   Build may succeed (:merged) or fail with {:health_red, ...} on this
      #   minimal repo, but the log does NOT contain "destructive_action_denied".
      #   The refute assertion PASSES.
      # -----------------------------------------------------------------------

      ledger = start_ledger()
      unit = new_unit()
      repo_dir = setup_real_git_repo(unit)

      seed_pass_verdicts(ledger, unit)

      :ok = Phoenix.PubSub.subscribe(Tau.PubSub, "factory:pr:#{unit.id}")

      ma_name = unique(:liveness6_ma_t2)
      tasks_name = unique(:liveness6_tasks_t2)

      # NO build_fun injection — exercises the real default do_build_in_worktree/4.
      # This is the path that hits ActionClassifier.classify/1.
      _ma =
        start_supervised!(
          {MergeAuthority,
           name: ma_name,
           ledger: ledger,
           repo_dir: repo_dir,
           required_halves: [:critic, :reviewer],
           tasks_name: tasks_name,
           cas: PassingCas,
           build_backoff_ms: 10,
           build_retry_max: 0},
          id: ma_name
        )

      # Capture all logs during the build so we can inspect the failure reason.
      log =
        capture_log(fn ->
          :queued = MergeAuthority.request_merge(ma_name, unit)

          # Wait for any terminal outcome (merged or rejected).
          receive do
            {:merge_result, _} -> :ok
          after
            25_000 -> :timeout
          end
        end)

      # PRIMARY ASSERTION — D-319 M-exemption:
      # The real do_build_in_worktree/4 path MUST NOT log :destructive_action_denied.
      # FAIL-BEFORE: current code calls classify(:force_push) on M's own push →
      # log contains "build failed: {:destructive_action_denied, :force_push}".
      # POST-FIX: classify uses :allow action kind; log contains either
      # {:health_red, ...} or nothing (on a successful build).
      refute log =~ "destructive_action_denied",
             """
             LIVE-liveness-6 / D-319 M-exemption VIOLATED.

             The real do_build_in_worktree/4 path logged "destructive_action_denied",
             meaning ActionClassifier.classify/1 was called with :force_push (which is
             always denied) on M's own authorized merge push.

             Current log excerpt:
               #{String.slice(log, 0, 500)}

             SPEC-FACTORY-MERGE §4 C200-B4: M is the authorized sole writer of
             origin/main. M's own CAS push must NOT be classified as a destructive
             :force_push — only non-M actors' pushes are destructive (SPEC-FACTORY-MERGE B7).

             FIX: do_build_in_worktree/4 must use a non-destructive action kind
             (e.g. :merge_push or :cas_push, which is :allow) when classifying M's
             own authorized push, NOT :force_push (which is always {:deny, :destructive}).
             (SPEC-FACTORY-GOV §4 B7; D-319; INV-20)
             """
    end
  end
end
