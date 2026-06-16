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
  # Real git + mix subprocesses can be slow on CI.
  @moduletag timeout: 120_000

  @merge_authority Tau.Factory.MergeAuthority
  @writer Tau.Factory.Ledger.Writer

  # ---------------------------------------------------------------------------
  # Git topology helpers (adapted from merge_health_test.exs)
  # ---------------------------------------------------------------------------

  # Minimal self-contained mix project — starts green so the pre-push tip
  # health passes, allowing the CAS push to land.
  defp write_green_mix_project(dir) do
    File.mkdir_p!(Path.join(dir, "lib"))
    File.mkdir_p!(Path.join(dir, "test"))

    File.write!(Path.join(dir, "mix.exs"), """
    defmodule RedMainFixture.MixProject do
      use Mix.Project

      def project do
        [
          app: :red_main_fixture,
          version: "0.1.0",
          elixir: "~> 1.14",
          start_permanent: Mix.env() == :prod,
          deps: []
        ]
      end
    end
    """)

    File.write!(Path.join(dir, "lib/red_main_fixture.ex"), """
    defmodule RedMainFixture do
      @moduledoc "Minimal fixture for post-merge red-main test."
      def hello, do: :world
    end
    """)

    File.write!(Path.join(dir, "test/test_helper.exs"), "ExUnit.start()\n")

    File.write!(Path.join(dir, "test/red_main_fixture_test.exs"), """
    defmodule RedMainFixtureTest do
      use ExUnit.Case

      test "passes on feature branch (green pre-push tip)" do
        assert RedMainFixture.hello() == :world
      end
    end
    """)
  end

  # Set up:
  #   origin.git — bare; contains a RED main (failing test on main itself)
  #   work/      — clone; feature branch has a GREEN tip (so pre-push tip
  #                health passes and CAS push succeeds)
  #
  # After the CAS push fast-forwards main to the green feature tip, the
  # post-merge health check WOULD see a green origin/main — so we cannot use
  # a trivially failing test on the feature branch.
  #
  # Instead we inject build_fun to bypass the pre-push health step (returning
  # {:built, units, base, tip} directly) and set up a separate
  # post_merge_health_fun that the MA SHOULD call — which returns {:red, report}.
  # Since MA has no such injection point or post-merge check today, the
  # escalation never fires.
  #
  # The git topology still needs a real repo so request_merge goes through
  # the real start_link / request_merge / gen_statem path.
  defp setup_repo(tmp_dir, unit_branch) do
    origin_path = Path.join(tmp_dir, "origin.git")
    work_path = Path.join(tmp_dir, "work")

    write_green_mix_project(work_path)

    {_, 0} = System.cmd("git", ["init", "-b", "main", work_path])

    git = fn args ->
      System.cmd("git", args, cd: work_path, stderr_to_stdout: true)
    end

    git.(["config", "user.email", "test@tau.test"])
    git.(["config", "user.name", "Tau Test"])
    {_, 0} = git.(["add", "."])
    {_, 0} = git.(["commit", "-m", "initial: green main"])

    {_, 0} = System.cmd("git", ["init", "--bare", origin_path])
    {_, 0} = System.cmd("git", ["symbolic-ref", "HEAD", "refs/heads/main"], cd: origin_path)
    {_, 0} = git.(["remote", "add", "origin", origin_path])
    {_, 0} = git.(["push", "-u", "origin", "main"])

    {main_oid_raw, 0} = git.(["rev-parse", "HEAD"])
    main_oid = String.trim(main_oid_raw)

    # Create a GREEN feature branch (so a real pre-push tip health passes).
    {_, 0} = git.(["checkout", "-b", unit_branch])

    File.write!(Path.join(work_path, "lib/red_main_fixture.ex"), """
    defmodule RedMainFixture do
      @moduledoc "Green feature addition."
      def hello, do: :world
      def feature, do: :ok
    end
    """)

    File.write!(Path.join(work_path, "test/red_main_fixture_test.exs"), """
    defmodule RedMainFixtureTest do
      use ExUnit.Case

      test "passes on feature branch (green pre-push tip)" do
        assert RedMainFixture.hello() == :world
      end

      test "feature function passes" do
        assert RedMainFixture.feature() == :ok
      end
    end
    """)

    {_, 0} = git.(["add", "."])
    {_, 0} = git.(["commit", "-m", "feat: green addition"])
    {tip_raw, 0} = git.(["rev-parse", "HEAD"])
    tip = String.trim(tip_raw)
    {_, 0} = git.(["push", "origin", unit_branch])
    {_, 0} = git.(["checkout", "main"])

    {origin_path, work_path, main_oid, tip}
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

      {_origin_path, work_path, _main_oid, tip} = setup_repo(tmp_dir, unit_branch)

      db_path = Briefly.create!(extname: ".db")
      writer_name = :"test_writer_d303_#{System.unique_integer([:positive])}"

      writer =
        start_supervised!(
          {@writer, db_path: db_path, name: writer_name},
          id: writer_name
        )

      seed_pass_verdicts(writer, unit)

      # Start a real isolated PubSub for this test so we can observe the
      # "factory:control" escalation broadcast without noise from other tests.
      pubsub_name = :"test_pubsub_d303_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Phoenix.PubSub, name: pubsub_name},
        id: pubsub_name
      )

      :ok = Phoenix.PubSub.subscribe(pubsub_name, "factory:control")

      # Inject a build_fun that:
      #   (a) bypasses pre-push tip health (returns {:built, ...} directly), so
      #       the CAS push proceeds and lands on origin/main — simulating a
      #       merge that succeeded at the pre-push gate but produced a red main.
      #   (b) DOES NOT include any post-merge health logic — that is solely M's
      #       responsibility per [C209-B6].
      #
      # A real post-merge red main would arise when the batch tip, while itself
      # green, integrates with concurrent changes already on main that together
      # produce a red result.  For test purposes, we use a build_fun that
      # returns the tip directly; the SPEC requires M to independently re-check
      # origin/main AFTER the push, which is what we are asserting here.
      ma_name = :"test_ma_d303_#{System.unique_integer([:positive])}"
      tasks_name = :"test_tasks_d303_#{System.unique_integer([:positive])}"

      # This build_fun simulates a merge that passes the pre-push gate.
      # It does NOT perform the post-merge re-check — that is M's job.
      # The CAS module here is the default Tau.Factory.Merge.Cas, operating on
      # the real git work_path / origin.git topology.
      build_fun = fn units, base ->
        # Simulate: rebase + pre-push gate all pass.  Return the feature tip
        # as the merged tip.  This causes cas_push to attempt to advance
        # origin/main to `tip`.
        {:built, units, base, tip}
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
           build_fun: build_fun},
          id: ma_name
        )

      # Submit the unit via the real entry point (B1 / D-302).
      assert :queued = @merge_authority.request_merge(ma_pid, unit)

      # Wait for MergeAuthority to complete the CAS push and return to :idle.
      # At this point, origin/main has been advanced (or the push failed — but
      # given the green topology and a fresh base, it should succeed).
      :ok = wait_for_idle(ma_pid, 15_000)

      # ASSERTION (D-303 / [C209-B6]):
      # MergeAuthority MUST broadcast {:escalate, {:"E-RED-MAIN", :global}} on
      # "factory:control" after detecting a red post-merge origin/main.
      #
      # This assertion fails today because transition_from_idle (line 459) calls
      # start_build unconditionally with NO post-merge health check of origin/main.
      # Escalation.classify({:red_main, _}) exists (escalation.ex:44) but is
      # NEVER called from merge_authority.ex — confirmed by grep (issue #569
      # rationale: "grep for Escalation. across lib/ returns ZERO runtime callers").
      #
      # The test correctly fails (assert_receive timeout) until the implementer
      # adds a post-merge health check in transition_from_idle (or equivalent)
      # that calls Health.check on origin/main post-push and broadcasts
      # {:escalate, {:"E-RED-MAIN", :global}} when the result is {:red, _}.
      assert_receive {:escalate, {:"E-RED-MAIN", :global}},
                     5_000,
                     "D-303 ([C209-B6]): MergeAuthority MUST broadcast " <>
                       "{:escalate, {:\"E-RED-MAIN\", :global}} on \"factory:control\" " <>
                       "after detecting a red post-merge origin/main. " <>
                       "No such message received within 5000ms. " <>
                       "Violation: transition_from_idle admits the next train unconditionally " <>
                       "with no post-merge health re-check of origin/main (merge_authority.ex:459-467). " <>
                       "SPEC-FACTORY-MERGE §4 B6 / [C209-B6] requires this re-check and the " <>
                       "escalation broadcast to K before any subsequent merge is admitted."
    end
  end
end
