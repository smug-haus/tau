defmodule Tau.Factory.MergeBuildRetryTest do
  @moduledoc """
  Gating test for PR #534 (issue #523) — D-394 bounded, backed-off
  build-failure requeue with per-member terminal eject.

  ## Background

  Before D-394, `MergeAuthority` requeued any non-health-red build failure
  (`{:build_failed, {:git_error, _}}` or a task `:DOWN`) INSTANTLY with NO
  attempt bound. A deterministic `{:build_failed, {:git_error, 1, "boom"}}`
  would loop ~6000× in ~5 min until the Unit's fixed 30 s `:awaiting_merge`
  timeout fired a spurious `:E_MERGE_STALLED` (#523).

  D-394 introduces:
    - A per-member `build_attempts` counter (in-memory per M-lifetime).
    - A `T_backoff` dwell between retries (`:idle` with `backoff_pending = true`;
      a generic `{:timeout, T_backoff, :build_backoff}` timer).
    - On the `N_build`-th consecutive retryable failure: terminal per-member eject
      (durable `{:rejected, :build_retry_exhausted}` row + `{:merge_result, :rejected}`
      broadcast).
    - A wedged build (`:state_timeout` on the build task) is terminal at B=1
      (`{:rejected, :build_wedged}` row + broadcast), never folded into the retry
      climb.

  ## Fail-before validity (oracle separation, factory-loop §4b)

  Against the current code (no D-394 implementation):
    - Test 1 (bounded count + throttle): the 4th `{:build_invoked}` arrives
      immediately (unbounded requeue); `refute_receive` for the 4th invocation
      FAILS. The backoff-gap assertion also FAILS (zero delay between invocations).
    - Test 2 (no premature build mid-backoff): no backoff exists; a new build
      launches immediately, producing a spurious `{:build_invoked}` before the
      backoff window; assertion FAILS.
    - Test 3 (terminal eject on exhaustion): no terminal eject; after the 3rd
      failure M re-queues again; `LedgerReader.merge_outcome_for` returns `:none`,
      no `{:merge_result, :rejected}` broadcast fires; assertions FAIL.
    - Test 4 (transient recovers): build_fun succeeds on the 3rd attempt; the
      result must be `:merged` not `:rejected`. Against current code this MAY pass
      (no bound logic exists to wrongly eject a recovering member); this test
      serves as a regression guard — a bounded implementation that resets
      `build_attempts` on success will keep this passing.
    - Test 5 (wedge terminal at B=1): the wedge requeue fires `transition_from_idle`
      which immediately starts another build — the wedge loop is unbounded; no
      durable row is written, no broadcast fires; assertions FAIL.

  ## D-NNN linkage: D-394, AC-10.
  """

  use ExUnit.Case, async: false

  alias Tau.Factory.Ledger.Reader, as: LedgerReader
  alias Tau.Factory.Ledger.Writer, as: LedgerWriter
  alias Tau.Factory.MergeAuthority

  @moduletag :capture_log
  @moduletag :"D-394"
  @moduletag :"AC-10"

  # ---------------------------------------------------------------------------
  # Injected CAS seams
  # ---------------------------------------------------------------------------

  defmodule PassingCas do
    @moduledoc false
    def assert_all_verdicts_live(_ledger, _units, _required_halves), do: :all_pass
    def cas_push(_repo_dir, _tip, _base), do: :ok
  end

  # ---------------------------------------------------------------------------
  # Helpers — mirror reject_durable_outcome_test.exs / merge_result_pubsub_test.exs
  # ---------------------------------------------------------------------------

  defp unique(base), do: :"#{base}_#{System.unique_integer([:positive])}"

  defp start_ledger do
    db_path = Briefly.create!(extname: ".db")
    writer_name = unique(:build_retry_ledger)
    start_supervised!({LedgerWriter, db_path: db_path, name: writer_name}, id: writer_name)
    writer_name
  end

  # Real git topology so MergeAuthority.start_build's fetch_main_oid succeeds.
  defp setup_git_repo(unit) do
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

    feature_name = String.replace(unit.branch, "/", "_")
    {_, 0} = git_work.(["checkout", "-b", unit.branch])
    File.write!(Path.join(work_path, "feature_#{feature_name}"), "feature work")
    {_, 0} = git_work.(["add", "."])
    {_, 0} = git_work.(["commit", "-m", "feature commit for #{unit.branch}"])
    {tip, 0} = git_work.(["rev-parse", "HEAD"])
    tip = String.trim(tip)
    {_, 0} = git_work.(["push", "origin", unit.branch])
    {_, 0} = git_work.(["checkout", "main"])

    {work_path, tip}
  end

  defp start_merge_authority(ledger, repo_dir, build_fun, opts \\ []) do
    ma_name = unique(:build_retry_ma)
    tasks_name = unique(:build_retry_tasks)

    base_opts = [
      name: ma_name,
      ledger: ledger,
      repo_dir: repo_dir,
      required_halves: [:critic, :reviewer],
      tasks_name: tasks_name,
      cas: PassingCas,
      build_fun: build_fun
    ]

    start_supervised!(
      {MergeAuthority, Keyword.merge(base_opts, opts)},
      id: ma_name
    )

    ma_name
  end

  defp pr_topic(unit_id), do: "factory:pr:#{unit_id}"

  defp make_unit do
    idx = System.unique_integer([:positive])

    %{
      id: "u-retry-#{idx}",
      hash: "hash-retry-#{idx}",
      run: "run-retry-#{idx}",
      branch: "feat/build-retry-#{idx}"
    }
  end

  # ---------------------------------------------------------------------------
  # Test 1 — Bounded count + throttle (D-394, AC-10)
  #
  # Inject a build_fun that always returns a retryable failure AND records each
  # invocation timestamp. Assert: exactly 3 invocations, NO 4th, consecutive
  # gaps ≥ build_backoff_ms.
  # ---------------------------------------------------------------------------

  describe "D-394 / AC-10 — bounded build-failure requeue: count cap + backoff throttle" do
    @tag :"D-394"
    @tag :"AC-10"
    test "D-394 AC-10: retryable build failure is retried exactly N_build=3 times with ≥T_backoff gaps between launches" do
      ledger = start_ledger()
      test_pid = self()

      unit = make_unit()
      {work_path, _tip} = setup_git_repo(unit)

      # Build fun that always fails with a retryable git_error.
      # Each invocation sends its monotonic timestamp to the test process so we
      # can count invocations and measure inter-launch gaps.
      build_fun = fn _units, _base ->
        send(test_pid, {:build_invoked, System.monotonic_time(:millisecond)})
        {:build_failed, {:git_error, 1, "boom"}}
      end

      _ma =
        start_merge_authority(ledger, work_path, build_fun,
          build_retry_max: 3,
          build_backoff_ms: 50
        )

      :ok = Phoenix.PubSub.subscribe(Tau.PubSub, pr_topic(unit.id))

      assert :queued = MergeAuthority.request_merge(_ma, unit)

      # Collect the first 3 invocation timestamps. Each is separated by at least
      # build_backoff_ms (50 ms injected). Allow generous total window: 3 attempts
      # × (50 ms backoff + 100 ms slack) = ~450 ms plus task spin-up overhead.
      ts1 = assert_receive({:build_invoked, _}, 2_000)
      ts2 = assert_receive({:build_invoked, _}, 2_000)
      ts3 = assert_receive({:build_invoked, _}, 2_000)

      {_, ts1} = ts1
      {_, ts2} = ts2
      {_, ts3} = ts3

      # After the 3rd failure the implementer applies the terminal eject. Give it
      # time to process, then assert NO 4th invocation arrives within a window
      # large enough that unbounded code would have already launched it (200 ms).
      refute_receive {:build_invoked, _},
                     200,
                     "D-394 AC-10 (bounded count): a 4th build_fun invocation arrived after N_build=3 " <>
                       "exhaustion — the requeue must be bounded at N_build attempts, not unbounded."

      # Throttle: each consecutive gap must be ≥ build_backoff_ms (50 ms).
      gap1 = ts2 - ts1
      gap2 = ts3 - ts2

      assert gap1 >= 50,
             "D-394 AC-10 (throttle): gap between invocation 1 and 2 was #{gap1} ms, " <>
               "expected ≥ 50 ms (build_backoff_ms). The D-394 T_backoff dwell between " <>
               "retry launches is missing — invocations are not throttled."

      assert gap2 >= 50,
             "D-394 AC-10 (throttle): gap between invocation 2 and 3 was #{gap2} ms, " <>
               "expected ≥ 50 ms (build_backoff_ms). The D-394 T_backoff dwell between " <>
               "retry launches is missing — invocations are not throttled."
    end
  end

  # ---------------------------------------------------------------------------
  # Test 2 — No premature build mid-backoff (INV-3, D-394, AC-10)
  #
  # During the armed backoff window after the 1st failure, a second request_merge
  # must return :queued WITHOUT launching a new build task (INV-3 preserved).
  # ---------------------------------------------------------------------------

  describe "D-394 / AC-10 — INV-3 preserved mid-backoff: second request_merge enqueues only" do
    @tag :"D-394"
    @tag :"AC-10"
    test "D-394 AC-10 INV-3: a request_merge issued during the backoff dwell returns :queued and does NOT launch a build" do
      ledger = start_ledger()
      test_pid = self()

      unit1 = make_unit()
      unit2 = make_unit()
      {work_path, _tip} = setup_git_repo(unit1)
      setup_git_repo(unit2)

      # Use a large backoff (500 ms) so we can issue a second request_merge while
      # firmly inside the backoff window.
      large_backoff_ms = 500

      build_fun = fn _units, _base ->
        send(test_pid, {:build_invoked, System.monotonic_time(:millisecond)})
        {:build_failed, {:git_error, 1, "boom"}}
      end

      ma =
        start_merge_authority(ledger, work_path, build_fun,
          build_retry_max: 3,
          build_backoff_ms: large_backoff_ms
        )

      # Submit unit1 and wait for the first build invocation, confirming the
      # machine entered :integrating.
      assert :queued = MergeAuthority.request_merge(ma, unit1)

      assert_receive {:build_invoked, _},
                     2_000,
                     "D-394 AC-10 INV-3: first build never launched (test setup failure)"

      # Now we are in the backoff window (large_backoff_ms = 500 ms). Submit
      # unit2 — it must be enqueued (:queued) but must NOT trigger a new build
      # launch during the backoff period.
      assert :queued = MergeAuthority.request_merge(ma, unit2),
             "D-394 AC-10 INV-3: request_merge during backoff must return :queued"

      # Assert NO additional build_invoked arrives within the backoff window
      # (allow 300 ms — well inside the 500 ms backoff). Against unbounded code
      # the next build launches immediately and this assertion FAILS.
      refute_receive {:build_invoked, _},
                     300,
                     "D-394 AC-10 INV-3: a build was launched during the backoff dwell window — " <>
                       "INV-3 (no second build while backoff_pending) is violated. " <>
                       "No build should launch until the {timeout, T_backoff, :build_backoff} fires."
    end
  end

  # ---------------------------------------------------------------------------
  # Test 3 — Terminal eject on exhaustion (D-394, AC-10, D-355, D-356)
  #
  # After N_build=3 consecutive retryable failures:
  #   a) LedgerReader.merge_outcome_for returns {:rejected, :build_retry_exhausted}
  #   b) {:merge_result, :rejected} is broadcast on the per-PR topic
  #   c) No further build invocations (unit dropped, not requeued)
  # ---------------------------------------------------------------------------

  describe "D-394 / AC-10 — terminal eject on N_build exhaustion: durable row + broadcast" do
    @tag :"D-394"
    @tag :"AC-10"
    test "D-394 AC-10: after N_build=3 retryable failures the unit is terminally ejected with {:rejected, :build_retry_exhausted} and a D-356 broadcast" do
      ledger = start_ledger()
      test_pid = self()

      unit = make_unit()
      {work_path, _tip} = setup_git_repo(unit)

      build_fun = fn _units, _base ->
        send(test_pid, {:build_invoked, :erlang.monotonic_time(:millisecond)})
        {:build_failed, {:git_error, 1, "boom"}}
      end

      ma =
        start_merge_authority(ledger, work_path, build_fun,
          build_retry_max: 3,
          build_backoff_ms: 50
        )

      :ok = Phoenix.PubSub.subscribe(Tau.PubSub, pr_topic(unit.id))

      assert :queued = MergeAuthority.request_merge(ma, unit)

      # Drain all 3 invocations.
      assert_receive {:build_invoked, _}, 2_000
      assert_receive {:build_invoked, _}, 2_000
      assert_receive {:build_invoked, _}, 2_000

      # The D-356 broadcast must arrive after the 3rd exhaustion.
      assert_receive {:merge_result, :rejected},
                     2_000,
                     "D-394 AC-10 (broadcast): no {:merge_result, :rejected} broadcast on " <>
                       "#{pr_topic(unit.id)} after N_build=3 exhaustion. The D-356 terminal " <>
                       "rejection broadcast is missing — the unit was likely requeued instead " <>
                       "of terminally ejected."

      # The durable row must be present (D-355 WAL-before-ack — written before
      # the broadcast fires).
      assert {:rejected, :build_retry_exhausted} =
               LedgerReader.merge_outcome_for(ledger, unit.id),
             "D-394 AC-10 (durable row): LedgerReader.merge_outcome_for returned " <>
               "#{inspect(LedgerReader.merge_outcome_for(ledger, unit.id))} after N_build=3 " <>
               "exhaustion. Expected {:rejected, :build_retry_exhausted}. Either the durable " <>
               "row was not written (non-terminal requeue) or the wrong reason was recorded."

      # No further build launches: the unit must be dropped, not requeued.
      refute_receive {:build_invoked, _},
                     200,
                     "D-394 AC-10 (no requeue after eject): a 4th build invocation arrived " <>
                       "after terminal exhaustion eject — the unit must be dropped, not requeued."
    end
  end

  # ---------------------------------------------------------------------------
  # Test 4 — Transient recovers: reset guard, no false eject (D-394, AC-10)
  #
  # A build_fun that fails twice then succeeds must result in :merged (not
  # :rejected). This pins the `build_attempts` reset-on-success invariant.
  # ---------------------------------------------------------------------------

  describe "D-394 / AC-10 — transient failure recovers: build_attempts reset on success" do
    @tag :"D-394"
    @tag :"AC-10"
    test "D-394 AC-10 (reset guard): a build_fun that fails twice then returns {:built,_} results in :merged, not :rejected" do
      ledger = start_ledger()

      unit = make_unit()
      {work_path, tip} = setup_git_repo(unit)

      {:ok, attempt_counter} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> if Process.alive?(attempt_counter), do: Agent.stop(attempt_counter) end)

      # Fail twice, succeed on the 3rd attempt.
      build_fun = fn units, base ->
        n = Agent.get_and_update(attempt_counter, fn c -> {c + 1, c + 1} end)

        if n <= 2 do
          {:build_failed, {:git_error, 1, "transient"}}
        else
          {:built, units, base, tip}
        end
      end

      ma =
        start_merge_authority(ledger, work_path, build_fun,
          build_retry_max: 3,
          build_backoff_ms: 50
        )

      :ok = Phoenix.PubSub.subscribe(Tau.PubSub, pr_topic(unit.id))

      assert :queued = MergeAuthority.request_merge(ma, unit)

      # Wait for the terminal outcome — either :merged (correct) or :rejected
      # (wrong: false eject). Allow up to 3 attempts × (50 ms backoff + overhead).
      result =
        receive do
          {:merge_result, outcome} -> outcome
        after
          5_000 ->
            flunk(
              "D-394 AC-10 (reset guard): no {:merge_result, _} broadcast received within 5 s. " <>
                "The build_fun that fails twice then succeeds should eventually produce a " <>
                "terminal outcome (either :merged on success or :rejected on premature eject)."
            )
        end

      assert result == :merged,
             "D-394 AC-10 (reset guard): expected {:merge_result, :merged} for a build_fun " <>
               "that fails twice then succeeds, but got {:merge_result, #{inspect(result)}}. " <>
               "The D-394 implementation must not prematurely eject a member that would succeed " <>
               "within N_build attempts — or must correctly count only consecutive failures."

      assert {:merged, _sha} = LedgerReader.merge_outcome_for(ledger, unit.id),
             "D-394 AC-10 (reset guard durable): LedgerReader returned " <>
               "#{inspect(LedgerReader.merge_outcome_for(ledger, unit.id))} — expected " <>
               "{:merged, _} for a unit whose build recovered within N_build attempts."
    end
  end

  # ---------------------------------------------------------------------------
  # Test 5 — Wedge terminal at B=1 (D-394, AC-10)
  #
  # A build task that blocks past build_timeout_ms must be killed and the unit
  # terminally ejected at B=1 (reason: :build_wedged), with a durable row and
  # a D-356 broadcast, never requeued.
  # ---------------------------------------------------------------------------

  describe "D-394 / AC-10 — wedged build is terminal at B=1 with reason :build_wedged" do
    @tag :"D-394"
    @tag :"AC-10"
    test "D-394 AC-10 (wedge): a build task that blocks past build_timeout_ms is killed and the unit ejected at B=1 with {:rejected, :build_wedged}" do
      ledger = start_ledger()
      test_pid = self()

      unit = make_unit()
      {work_path, _tip} = setup_git_repo(unit)

      # build_timeout_ms is injected small so the test is fast.
      wedge_timeout_ms = 150

      build_fun = fn _units, _base ->
        send(test_pid, {:build_invoked, System.monotonic_time(:millisecond)})
        # Block indefinitely — simulates a wedged build. The gen_statem's
        # :state_timeout (build_timeout_ms) must kill this task and eject the unit.
        receive do
          :never -> :ok
        end
      end

      ma =
        start_merge_authority(ledger, work_path, build_fun,
          build_retry_max: 3,
          build_backoff_ms: 50,
          build_timeout_ms: wedge_timeout_ms
        )

      :ok = Phoenix.PubSub.subscribe(Tau.PubSub, pr_topic(unit.id))

      assert :queued = MergeAuthority.request_merge(ma, unit)

      # First (and only) build invocation.
      assert_receive {:build_invoked, _},
                     2_000,
                     "D-394 AC-10 (wedge): the wedged build was never launched (test setup failure)"

      # The D-356 broadcast must arrive after the build_timeout fires.
      # Allow wedge_timeout_ms + generous overhead.
      assert_receive {:merge_result, :rejected},
                     3_000,
                     "D-394 AC-10 (wedge broadcast): no {:merge_result, :rejected} broadcast " <>
                       "on #{pr_topic(unit.id)} after wedge timeout (#{wedge_timeout_ms} ms). " <>
                       "A wedged build must be terminal at B=1 per D-394 — the timeout handler " <>
                       "must eject the unit, not requeue it."

      # Durable row must record :build_wedged.
      assert {:rejected, :build_wedged} = LedgerReader.merge_outcome_for(ledger, unit.id),
             "D-394 AC-10 (wedge durable row): LedgerReader.merge_outcome_for returned " <>
               "#{inspect(LedgerReader.merge_outcome_for(ledger, unit.id))} — expected " <>
               "{:rejected, :build_wedged}. The wedge eject must write a durable row with " <>
               "reason :build_wedged (D-394 / D-355 WAL-before-ack) before broadcasting."

      # No requeue: only one build invocation must have occurred.
      refute_receive {:build_invoked, _},
                     200,
                     "D-394 AC-10 (wedge no requeue): a second build invocation arrived after " <>
                       "a wedge eject — a wedged build is terminal at B=1 and must NOT be " <>
                       "requeued into the retry climb."
    end
  end
end
