defmodule Tau.Factory.MergeRedMainEscalationTest do
  @moduledoc """
  Gating test for issue #569 (D-303 — post-merge E-RED-MAIN escalation).

  D-303 has two halves:
    (a) Pre-push: a red batch tip is ejected before any push (covered by
        merge_health_test.exs / AC-5).
    (b) Post-merge: after cas_push returns :ok, MergeAuthority MUST perform
        a post-merge health check on origin/main.  If origin/main is red,
        MergeAuthority MUST broadcast {:escalate, {:"E-RED-MAIN", :global}}
        on "factory:control" (SPEC-FACTORY-MERGE §4 B6 / [C209-B6]) AND
        MUST NOT admit the next queued unit to a build until an operator
        clears the red flag.

  This file tests the post-merge half only (the un-implemented clause).

  Boundary exercised: `Tau.Factory.MergeAuthority.request_merge/2` — the
  real user-facing entry point (not a hand-built struct or injected seam).

  AC linkage: @tag :d_303 covers the D-303 token required by Gate 5.1.

  ## Design intent: why post_merge_health_fun injection is required

  The SPEC (§4 B6, [C209-B6]) states E-RED-MAIN fires on a POST-MERGE
  origin/main re-check, not a pre-push tip health check.  The pre-push check
  handles a red batch tip (ejected before push); E-RED-MAIN is for the
  scenario where the push SUCCEEDS (cas_push returns :ok) but origin/main
  is thereafter observed red — e.g., the merged tip, while itself green,
  interacts with concurrent changes already on main that produce a red result.

  To test this:
  1. `build_fun` is injected to return {:built, units, base, tip} directly,
     bypassing the real pre-push health subprocess (simulating a merge that
     passed all pre-push gates and whose cas_push would succeed).
  2. A `PassingCas` module is injected so cas_push returns :ok without
     touching real git.
  3. `post_merge_health_fun` is injected to return {:red, report}, simulating
     the origin/main re-check finding a red state after the push.

  Without injection (2) and (3), a real CAS push against a green git topology
  succeeds and a real post-merge health check on the green origin/main returns
  :green — E-RED-MAIN never fires.  The test would time out, asserting a
  condition that can never be true in a green topology.

  The original test (commit 58ece18) was written with this design intent
  (see the comment at lines 96-100 of that commit) but omitted the
  `post_merge_health_fun` key from the `start_supervised!` opts and omitted
  the PassingCas injection.  Without those, the test asserts E-RED-MAIN on a
  green post-merge main, which contradicts [C209-B6] and cannot pass against
  any correct implementation.  This rewrite corrects the omission.

  Failure mode before implementation:
    The test asserts {:escalate, {:"E-RED-MAIN", :global}} arrives on
    "factory:control" within 5_000 ms.  Because MergeAuthority has NO
    post-merge health check today (transition_from_idle unconditionally
    proceeds to start_build with no origin/main re-check), this message is
    never sent → the assert_receive times out → test fails.
  """

  # async: false — this test runs real git subprocesses and subscribes to
  # a global-ish PubSub topic; serializing avoids cross-test PubSub noise.
  use ExUnit.Case, async: false

  @moduletag :capture_log
  # Real git subprocesses can be slow on CI.
  @moduletag timeout: 120_000

  @merge_authority Tau.Factory.MergeAuthority
  @writer Tau.Factory.Ledger.Writer

  # ---------------------------------------------------------------------------
  # Injected CAS seam — identical to merge_build_retry_test.exs / reject_durable_outcome_test.exs
  # ---------------------------------------------------------------------------

  defmodule PassingCas do
    @moduledoc false
    def assert_all_verdicts_live(_ledger, _units, _required_halves), do: :all_pass
    def cas_push(_repo_dir, _tip, _base), do: :ok
  end

  # ---------------------------------------------------------------------------
  # Git topology helper — minimal real repo so start_build's fetch_main_oid succeeds
  # ---------------------------------------------------------------------------

  defp setup_repo(tmp_dir, unit_branch) do
    origin_path = Path.join(tmp_dir, "origin.git")
    work_path = Path.join(tmp_dir, "work")

    {_, 0} = System.cmd("git", ["init", "-b", "main", work_path])

    git = fn args ->
      System.cmd("git", args, cd: work_path, stderr_to_stdout: true)
    end

    git.(["config", "user.email", "test@tau.test"])
    git.(["config", "user.name", "Tau Test"])
    File.write!(Path.join(work_path, "README"), "initial\n")
    {_, 0} = git.(["add", "README"])
    {_, 0} = git.(["commit", "-m", "initial: green main"])

    {_, 0} = System.cmd("git", ["init", "--bare", origin_path])
    {_, 0} = System.cmd("git", ["symbolic-ref", "HEAD", "refs/heads/main"], cd: origin_path)
    {_, 0} = git.(["remote", "add", "origin", origin_path])
    {_, 0} = git.(["push", "-u", "origin", "main"])

    {main_oid_raw, 0} = git.(["rev-parse", "HEAD"])
    main_oid = String.trim(main_oid_raw)

    # Create a feature branch so request_merge has a real branch to submit.
    {_, 0} = git.(["checkout", "-b", unit_branch])
    File.write!(Path.join(work_path, "feature.txt"), "feature work\n")
    {_, 0} = git.(["add", "."])
    {_, 0} = git.(["commit", "-m", "feat: feature work"])
    {tip_raw, 0} = git.(["rev-parse", "HEAD"])
    tip = String.trim(tip_raw)
    {_, 0} = git.(["push", "origin", unit_branch])
    {_, 0} = git.(["checkout", "main"])

    {work_path, main_oid, tip}
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

  defp wait_for_idle(ma_pid, timeout_ms \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      {state, _} = :sys.get_state(ma_pid)
      state
    end)
    |> Enum.find_value(fn state ->
      if state == :idle do
        :ok
      else
        if System.monotonic_time(:millisecond) > deadline do
          :timeout
        else
          :timer.sleep(100)
          nil
        end
      end
    end) || :timeout
  end

  # ---------------------------------------------------------------------------
  # D-303 (post-merge clause) — E-RED-MAIN escalation
  # ---------------------------------------------------------------------------

  describe "D-303 — post-merge red origin/main triggers E-RED-MAIN escalation to Coordinator" do
    @tag :d_303
    test "D-303: red post-merge origin/main → E-RED-MAIN escalated on factory:control; next merge gated closed" do
      tmp_dir = Briefly.create!(type: :directory)
      unit_branch = "feat/d303-post-merge-#{System.unique_integer([:positive])}"

      unit = %{
        id: "u-d303-#{System.unique_integer([:positive])}",
        hash: "hash-d303-#{System.unique_integer([:positive])}",
        run: "run-d303-001",
        branch: unit_branch
      }

      {work_path, _main_oid, tip} = setup_repo(tmp_dir, unit_branch)

      db_path = Briefly.create!(extname: ".db")
      writer_name = :"test_writer_d303_#{System.unique_integer([:positive])}"

      writer =
        start_supervised!(
          {@writer, db_path: db_path, name: writer_name},
          id: writer_name
        )

      seed_pass_verdicts(writer, unit)

      # Isolated PubSub so we can observe the "factory:control" escalation
      # broadcast without noise from other tests.
      pubsub_name = :"test_pubsub_d303_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Phoenix.PubSub, name: pubsub_name},
        id: pubsub_name
      )

      :ok = Phoenix.PubSub.subscribe(pubsub_name, "factory:control")

      ma_name = :"test_ma_d303_#{System.unique_integer([:positive])}"
      tasks_name = :"test_tasks_d303_#{System.unique_integer([:positive])}"

      # build_fun: simulates a merge that passes all pre-push gates.
      # Returns {:built, units, base, tip} immediately — the pre-push health
      # step is bypassed so the CAS step proceeds.
      #
      # This simulates the scenario documented in [C209-B6]: the batch tip
      # was itself green (pre-push health passed), but after the push,
      # origin/main is observed red (e.g. due to interaction with concurrent
      # changes already on main that were not in the batch tip's test suite).
      build_fun = fn units, base ->
        {:built, units, base, tip}
      end

      # post_merge_health_fun: injected to simulate a red post-merge main.
      # This is the function MergeAuthority SHOULD call after cas_push succeeds
      # ([C209-B6] / §4 B6 / §5 batch lifecycle diagram "post-merge main re-check").
      # Returns {:red, report} — the condition under which E-RED-MAIN fires.
      post_merge_health_fun = fn _repo_dir, _lang, _ctx ->
        {:red, %{phase: :post_merge_check, output: "simulated red post-merge main"}}
      end

      ma_pid =
        start_supervised!(
          {@merge_authority,
           name: ma_name,
           ledger: writer,
           repo_dir: work_path,
           required_halves: [:critic, :reviewer],
           tasks_name: tasks_name,
           pubsub: pubsub_name,
           cas: PassingCas,
           build_fun: build_fun,
           post_merge_health_fun: post_merge_health_fun},
          id: ma_name
        )

      # Submit the unit via the real entry point (B1 / D-302).
      assert :queued = @merge_authority.request_merge(ma_pid, unit)

      # Wait for MergeAuthority to complete the CAS (which returns :ok via
      # PassingCas) and process the post-merge health check.
      # M should detect red and broadcast {:escalate, {:"E-RED-MAIN", :global}}
      # on "factory:control" before returning to :idle.
      :ok = wait_for_idle(ma_pid, 15_000)

      # ASSERTION (D-303 / [C209-B6]):
      # MergeAuthority MUST broadcast {:escalate, {:"E-RED-MAIN", :global}} on
      # "factory:control" after detecting a red post-merge origin/main.
      #
      # This assertion fails today because transition_from_idle (or its successor)
      # calls start_build unconditionally with NO post-merge health check.
      # Escalation.classify({:red_main, _}) exists (escalation.ex:44) but is
      # NEVER called from merge_authority.ex — grep for Escalation. across lib/
      # returns ZERO runtime callers (issue #569 rationale).
      #
      # The test correctly fails (assert_receive timeout) until the implementer
      # adds a post-merge health check (using the injected post_merge_health_fun
      # or the real Health.check when not injected) that broadcasts
      # {:escalate, {:"E-RED-MAIN", :global}} when the result is {:red, _}.
      assert_receive {:escalate, {:"E-RED-MAIN", :global}},
                     5_000,
                     "D-303 ([C209-B6]): MergeAuthority MUST broadcast " <>
                       "{:escalate, {:\"E-RED-MAIN\", :global}} on \"factory:control\" " <>
                       "after detecting a red post-merge origin/main. " <>
                       "No such message received within 5000ms. " <>
                       "The post_merge_health_fun was injected to return {:red, _}, " <>
                       "simulating a red origin/main after a successful cas_push. " <>
                       "Violation: merge_authority.ex has no post-merge health re-check " <>
                       "of origin/main (SPEC-FACTORY-MERGE §4 B6 / [C209-B6]). " <>
                       "The SPEC requires this re-check and the escalation broadcast to K " <>
                       "before any subsequent merge is admitted."
    end

    @tag :d_303
    test "D-303: after E-RED-MAIN escalation, next queued unit is not built (merge precondition closed)" do
      # SPEC §4 B6 post: □ red(main) → ¬∃ d. merge(d) until operator clears.
      # After a red post-merge main is detected, M MUST gate the merge precondition
      # closed — the next queued unit MUST NOT be built while main is red.
      tmp_dir = Briefly.create!(type: :directory)
      unit_branch_1 = "feat/d303-gated-a-#{System.unique_integer([:positive])}"
      unit_branch_2 = "feat/d303-gated-b-#{System.unique_integer([:positive])}"

      unit1 = %{
        id: "u-d303-a-#{System.unique_integer([:positive])}",
        hash: "hash-d303-a-#{System.unique_integer([:positive])}",
        run: "run-d303-a-001",
        branch: unit_branch_1
      }

      unit2 = %{
        id: "u-d303-b-#{System.unique_integer([:positive])}",
        hash: "hash-d303-b-#{System.unique_integer([:positive])}",
        run: "run-d303-b-001",
        branch: unit_branch_2
      }

      {work_path, _main_oid, tip1} = setup_repo(tmp_dir, unit_branch_1)

      # Add a second branch for unit2.
      git = fn args ->
        System.cmd("git", args, cd: work_path, stderr_to_stdout: true)
      end

      {_, 0} = git.(["checkout", "-b", unit_branch_2])
      File.write!(Path.join(work_path, "feature2.txt"), "feature 2 work\n")
      {_, 0} = git.(["add", "."])
      {_, 0} = git.(["commit", "-m", "feat: feature 2 work"])
      {_, 0} = git.(["push", "origin", unit_branch_2])
      {_, 0} = git.(["checkout", "main"])

      db_path = Briefly.create!(extname: ".db")
      writer_name = :"test_writer_d303_gated_#{System.unique_integer([:positive])}"

      writer =
        start_supervised!(
          {@writer, db_path: db_path, name: writer_name},
          id: writer_name
        )

      seed_pass_verdicts(writer, unit1)
      seed_pass_verdicts(writer, unit2)

      pubsub_name = :"test_pubsub_d303_gated_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Phoenix.PubSub, name: pubsub_name},
        id: pubsub_name
      )

      :ok = Phoenix.PubSub.subscribe(pubsub_name, "factory:control")

      test_pid = self()

      build_invocations =
        :ets.new(:"build_invocations_#{System.unique_integer([:positive])}", [
          :public,
          :ordered_set
        ])

      ma_name = :"test_ma_d303_gated_#{System.unique_integer([:positive])}"
      tasks_name = :"test_tasks_d303_gated_#{System.unique_integer([:positive])}"

      # build_fun: records every invocation; returns :built for unit1's tip.
      # If M starts a build for unit2 AFTER detecting red main, that is a violation.
      build_fun = fn units, base ->
        unit_ids = Enum.map(units, & &1.id)
        send(test_pid, {:build_invoked, unit_ids})
        :ets.insert(build_invocations, {System.monotonic_time(), unit_ids})
        {:built, units, base, tip1}
      end

      # post_merge_health_fun always returns red — simulates the red post-merge main.
      post_merge_health_fun = fn _repo_dir, _lang, _ctx ->
        {:red, %{phase: :post_merge_check, output: "simulated red post-merge main"}}
      end

      ma_pid =
        start_supervised!(
          {@merge_authority,
           name: ma_name,
           ledger: writer,
           repo_dir: work_path,
           required_halves: [:critic, :reviewer],
           tasks_name: tasks_name,
           pubsub: pubsub_name,
           cas: PassingCas,
           build_fun: build_fun,
           post_merge_health_fun: post_merge_health_fun},
          id: ma_name
        )

      # Submit both units: unit1 is in the first train; unit2 queued behind.
      assert :queued = @merge_authority.request_merge(ma_pid, unit1)
      assert :queued = @merge_authority.request_merge(ma_pid, unit2)

      # Wait for unit1's merge to complete (build + CAS + post-merge red check).
      :ok = wait_for_idle(ma_pid, 15_000)

      # ASSERTION 1: E-RED-MAIN was broadcast.
      assert_receive {:escalate, {:"E-RED-MAIN", :global}},
                     5_000,
                     "D-303 ([C209-B6]): E-RED-MAIN must be broadcast after " <>
                       "the post-merge health check returns {:red, _}."

      # ASSERTION 2: unit2's build was NOT invoked after the red main was detected.
      # Give a generous window: if M admits unit2 to a build while main is red,
      # a {:build_invoked, [unit2.id]} message arrives within ~200 ms.
      unit2_id = unit2.id

      refute_receive {:build_invoked, [^unit2_id | _]},
                     500,
                     "D-303 ([C209-B6] post): □ red(main) → ¬∃ d. merge(d) — " <>
                       "MergeAuthority MUST NOT admit unit2 to a build while " <>
                       "origin/main is red. The merge precondition must be closed " <>
                       "after E-RED-MAIN fires."
    end
  end
end
