defmodule Tau.Factory.MergeTrainBatchSizeTest do
  @moduledoc """
  Gating test for issue #585 — HR-5 merge-train throughput stability.

  ## Invariant under test

  SPEC-FACTORY-MERGE §4 B8 + D-341:

  > "Paired `[:tau, :factory, :merge, …]` spans … `:queue`. The `:queue`
  > span's `max_restale_count` / `max_wait_ms` are the **live falsification
  > test for LIV-2** (an unbounded climb is starvation surfacing). Spans
  > also feed the `T_int` model the §sizing rule depends on — measurement
  > is a binding input, not optional instrumentation."

  When M transitions from `:idle` → `:integrating` (train assembled),
  it MUST emit a `[:tau, :factory, :merge, :queue]` telemetry event whose
  measurements map includes BOTH `:max_restale_count` and `:max_wait_ms`.

  Without this event the runtime falsification of LIV-2 / D-341 (FIFO+aging
  starvation guard) is unenforceable. The SPEC treats its absence as a
  binding gap, not optional instrumentation.

  ## Why the previous batch-size assertion was vacuous

  The prior version of this test asserted `length(train) >= 2` after two
  units were queued behind a blocked first build. Commit `1d65e6e` changed
  `start_build/1` to `train = [unit | rest]` (full-queue assembly), so the
  assertion passed against the post-implementation code. A gating test MUST
  fail before the production change it gates; that one no longer did.

  ## Current failure mode (B8 gap, D-341)

  `start_build/1` (merge_authority.ex:591-617) emits only
  `[:tau, :factory, :merge, :integrating]` via the private `telemetry/3`
  helper. No path in the module emits `[:tau, :factory, :merge, :queue]`
  with `max_restale_count` / `max_wait_ms`. A telemetry handler attached
  to that event never fires.

  ## Fail-before validity (oracle separation)

  Against the current code the `[:tau, :factory, :merge, :queue]` handler
  is never invoked, so the test times out on `assert_receive` and FAILS.

  ## Test strategy

  1. Attach a telemetry handler for `[:tau, :factory, :merge, :queue]`
     that forwards the measurement map to the test process.
  2. Start MA with a build_fun that signals arrival then blocks.
  3. Submit one unit via `MergeAuthority.request_merge/2`.
  4. Wait for the first-build signal (MA has entered :integrating).
  5. Assert that the queue telemetry event was received with BOTH
     `:max_restale_count` and `:max_wait_ms` keys in measurements.

  The test exercises `MergeAuthority.request_merge/2` — the real
  user-facing entry point (§4 B1). No hand-built struct bypasses the
  gen_statem.

  ## AC/D-NNN linkage: HR-5, D-341, SPEC-FACTORY-MERGE §4 B8
  """

  use ExUnit.Case, async: false

  alias Tau.Factory.Ledger.Writer, as: LedgerWriter
  alias Tau.Factory.MergeAuthority

  @moduletag :capture_log
  @moduletag :"HR-5"

  # ---------------------------------------------------------------------------
  # Injected CAS seam: always passes (no real git push).
  # ---------------------------------------------------------------------------

  defmodule PassingCas do
    @moduledoc false
    def assert_all_verdicts_live(_ledger, _units, _required_halves), do: :all_pass
    def cas_push(_repo_dir, _tip, _base), do: :ok
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp start_writer_with_pass_verdicts(units) when is_list(units) do
    db_path = Briefly.create!(extname: ".db")
    writer_name = :"test_ma_writer_hr5_#{System.unique_integer([:positive])}"

    writer =
      start_supervised!(
        {LedgerWriter, db_path: db_path, name: writer_name},
        id: writer_name
      )

    for unit <- units, do: seed_pass_verdicts(writer, unit)
    writer
  end

  defp seed_pass_verdicts(writer, %{hash: hash, run: run}) do
    for half <- [:critic, :reviewer] do
      {:ok, _} =
        LedgerWriter.append_verdict(writer, %{
          hash: hash,
          run: run,
          half: half,
          status: :pass,
          idempotency_key: "ikey-hr5-#{half}-#{System.unique_integer([:positive])}"
        })
    end
  end

  # Minimal git topology: bare origin + work clone with one branch per unit.
  defp setup_git_repo(tmp_dir, units) do
    origin_path = Path.join(tmp_dir, "origin.git")
    work_path = Path.join(tmp_dir, "work")

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

    for unit <- units do
      {_, 0} = git_work.(["checkout", "main"])
      {_, 0} = git_work.(["checkout", "-b", unit.branch])
      feature_name = String.replace(unit.branch, "/", "_")
      File.write!(Path.join(work_path, "feature_#{feature_name}"), "feature work")
      {_, 0} = git_work.(["add", "."])
      {_, 0} = git_work.(["commit", "-m", "feature commit #{unit.branch}"])
      {_, 0} = git_work.(["push", "origin", unit.branch])
      {_, 0} = git_work.(["checkout", "main"])
    end

    work_path
  end

  # ---------------------------------------------------------------------------
  # HR-5 / D-341 / B8: queue telemetry emitted on train assembly
  # ---------------------------------------------------------------------------

  describe "HR-5 / D-341 — [:tau, :factory, :merge, :queue] telemetry emitted on train assembly" do
    @tag :"HR-5"
    test "HR-5 [D-341] [B8]: start_build/1 MUST emit [:tau, :factory, :merge, :queue] with max_restale_count and max_wait_ms when assembling a train" do
      test_pid = self()
      tmp_dir = Briefly.create!(type: :directory)

      u1 = %{
        id: "u-hr5-q-1-#{System.unique_integer([:positive])}",
        hash: "hash-hr5-q-1-#{System.unique_integer([:positive])}",
        run: "run-hr5-q-1",
        branch: "feat/hr5-queue-unit-1"
      }

      writer = start_writer_with_pass_verdicts([u1])
      work_path = setup_git_repo(tmp_dir, [u1])

      # Attach a telemetry handler that forwards the queue event's measurements
      # to the test process. The handler id is unique to this test run to avoid
      # collisions with concurrent tests.
      handler_id = "test-hr5-queue-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:tau, :factory, :merge, :queue],
        fn _event, measurements, _metadata, _config ->
          send(test_pid, {:queue_telemetry, measurements})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      # build_fun: signal arrival so the test knows MA entered :integrating,
      # then block until released. The block prevents the train from completing
      # before we can assert on the telemetry event.
      build_fun = fn train, _base ->
        barrier_ref = make_ref()
        send(test_pid, {:at_build_barrier, barrier_ref})

        receive do
          {:proceed, ^barrier_ref} -> :ok
        after
          15_000 -> raise "HR-5 queue test: build barrier timed out"
        end

        {:built, train, "base-q", "tip-q"}
      end

      ma_name = :"test_ma_hr5_queue_#{System.unique_integer([:positive])}"
      tasks_name = :"test_ma_tasks_hr5_queue_#{System.unique_integer([:positive])}"

      ma_pid =
        start_supervised!(
          {
            MergeAuthority,
            name: ma_name,
            ledger: writer,
            repo_dir: work_path,
            required_halves: [:critic, :reviewer],
            tasks_name: tasks_name,
            build_fun: build_fun,
            cas: PassingCas,
            pubsub: Tau.PubSub,
            post_merge_health_fun: fn _dir, _lang, _ctx -> :green end
          },
          id: ma_name
        )

      # Submit u1 via the real entry point — M should transition to :integrating,
      # triggering start_build/1 which MUST emit the :queue telemetry event.
      assert MergeAuthority.request_merge(ma_pid, u1) == :queued

      # Wait for MA to enter :integrating (the build_fun has been invoked).
      assert_receive {:at_build_barrier, barrier_ref},
                     5_000,
                     "HR-5 queue test: MA did not enter :integrating within 5 s"

      # Assert the :queue telemetry event was emitted during start_build/1.
      # Conformant code emits [:tau, :factory, :merge, :queue] with
      # max_restale_count and max_wait_ms before launching the Task.
      # Non-conformant code (current) never emits this event; the assert_receive
      # times out and the test FAILS.
      assert_receive {:queue_telemetry, measurements},
                     500,
                     "HR-5 / D-341 / B8: [:tau, :factory, :merge, :queue] telemetry was NOT emitted during train assembly — " <>
                       "start_build/1 MUST emit this event with :max_restale_count and :max_wait_ms before launching the build Task " <>
                       "(SPEC-FACTORY-MERGE §4 B8 — the live LIV-2 starvation falsification watch)"

      assert Map.has_key?(measurements, :max_restale_count),
             "HR-5 / D-341: [:tau, :factory, :merge, :queue] measurements MUST include :max_restale_count; " <>
               "got: #{inspect(Map.keys(measurements))}"

      assert Map.has_key?(measurements, :max_wait_ms),
             "HR-5 / D-341: [:tau, :factory, :merge, :queue] measurements MUST include :max_wait_ms; " <>
               "got: #{inspect(Map.keys(measurements))}"

      # Release the build so the process terminates cleanly.
      send(ma_pid, {:proceed, barrier_ref})
    end
  end
end
