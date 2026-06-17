defmodule Tau.Factory.MergeTrainBatchSizeTest do
  @moduledoc """
  Gating test for issue #585 — HR-5 merge-train throughput stability.

  ## Invariant under test

  SPEC-FACTORY-MERGE §3 [C213-B4]:

  > "The merge-train breaks the loop (HR-5). Integrating a batch of B green
  > units in one rebase+gate+health cycle makes the re-stale cost O(1) per
  > batch rather than O(W) per unit."
  >
  > "…operate conservatively (small W_cap, B ≥ 2, never B = 1 which is the
  > unstable serial regime)."

  When multiple units have been submitted to M and are waiting in the queue
  at train-assembly time, `start_build/1` MUST assemble a train with B ≥ 2
  — i.e. the train passed to the `build_fun` MUST contain more than one unit.
  A single-member train (B = 1) is the serial regime HR-5 explicitly forbids.

  ## Current failure mode (audit finding, issue #585)

  `start_build/1` at merge_authority.ex:433-434 unconditionally builds a
  single-member train:

      defp start_build(%{queue: [unit | rest]} = data) do
        train = [unit]    # ← always 1, never B ≥ 2

  Every other `train =` assignment (lines 235/479/577) merely reads or
  filters the existing single-member train; no path assembles B ≥ 2. The
  `Tau.Factory.Merge.Train` module (C2, `assemble/2`) does not exist.

  ## Fail-before validity (oracle separation)

  Against the current code, the second build_fun call receives a train of
  exactly 1 unit, so the `assert length(train) >= 2` assertion FAILS.

  ## Test strategy

  1. Start M with a blocking build_fun.
  2. Submit the first unit — M enters :integrating with train=[u1] (the
     queue was empty, no batch opportunity yet; this is acceptable).
  3. While M is blocked in :integrating, submit 2 more units — they queue.
  4. Unblock the first build (returns :built); M transitions back to :idle
     and calls start_build/1 with queue=[u2, u3].
  5. The second build_fun invocation MUST receive a train with length ≥ 2.

  The test exercises `MergeAuthority.request_merge/2` — the real user-facing
  entry point (§4 B1). No hand-built struct bypasses the gen_statem.

  ## AC/D-NNN linkage: HR-5, [C213-B4], SPEC-FACTORY-MERGE §3
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

  # Poll :sys.get_state until the MA reaches expected_state or deadline passes.
  defp wait_for_state(pid, expected_state, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Enum.find_value(Stream.repeatedly(fn -> :ok end), fn _ ->
      try do
        {state, _data} = :sys.get_state(pid)

        if state == expected_state do
          true
        else
          if System.monotonic_time(:millisecond) >= deadline do
            throw(:timeout)
          end

          :timer.sleep(10)
          false
        end
      rescue
        _ ->
          if System.monotonic_time(:millisecond) >= deadline do
            throw(:timeout)
          end

          :timer.sleep(10)
          false
      end
    end)
  catch
    :timeout -> false
  end

  # ---------------------------------------------------------------------------
  # HR-5 / [C213-B4]: train batch size ≥ 2 when queue has ≥ 2 units waiting
  # ---------------------------------------------------------------------------

  describe "HR-5 / [C213-B4] — merge-train assembles B ≥ 2 when ≥ 2 units queued" do
    @tag :"HR-5"
    test "HR-5 [C213-B4]: when ≥ 2 units are in the queue at transition_from_idle, the assembled train has length ≥ 2" do
      test_pid = self()
      tmp_dir = Briefly.create!(type: :directory)

      u1 = %{
        id: "u-hr5-1-#{System.unique_integer([:positive])}",
        hash: "hash-hr5-1-#{System.unique_integer([:positive])}",
        run: "run-hr5-1",
        branch: "feat/hr5-unit-1"
      }

      u2 = %{
        id: "u-hr5-2-#{System.unique_integer([:positive])}",
        hash: "hash-hr5-2-#{System.unique_integer([:positive])}",
        run: "run-hr5-2",
        branch: "feat/hr5-unit-2"
      }

      u3 = %{
        id: "u-hr5-3-#{System.unique_integer([:positive])}",
        hash: "hash-hr5-3-#{System.unique_integer([:positive])}",
        run: "run-hr5-3",
        branch: "feat/hr5-unit-3"
      }

      units = [u1, u2, u3]

      writer = start_writer_with_pass_verdicts(units)
      work_path = setup_git_repo(tmp_dir, units)

      # build_fun:
      #  - First invocation: block until test sends {:proceed, ref}, then return :built.
      #    This gives the test time to submit u2 and u3 while M is :integrating.
      #  - Second invocation: record the train length and return :built immediately.
      #
      # The barrier mechanism mirrors merge_serialized_test.exs: the MA process
      # forwards {:proceed, ref} info-messages to the Task process (integrating/3,
      # line ~200-209). The task blocks in receive waiting for that ref.

      build_count = :atomics.new(1, [])
      :atomics.put(build_count, 1, 0)

      build_fun = fn train, _base ->
        n = :atomics.add_get(build_count, 1, 1)

        case n do
          1 ->
            # First build: announce barrier arrival, then block.
            barrier_ref = make_ref()
            send(test_pid, {:at_first_barrier, barrier_ref})

            receive do
              {:proceed, ^barrier_ref} -> :ok
            after
              15_000 -> raise "HR-5 test: first-build barrier timed out"
            end

            {:built, train, "base-1", "tip-1"}

          _ ->
            # Subsequent builds: record train size and complete immediately.
            send(test_pid, {:second_build_train_size, length(train)})
            {:built, train, "base-2", "tip-2"}
        end
      end

      ma_name = :"test_ma_hr5_#{System.unique_integer([:positive])}"
      tasks_name = :"test_ma_tasks_hr5_#{System.unique_integer([:positive])}"

      ma_pid =
        start_supervised!(
          {
            MergeAuthority,
            # Inject :green so M returns to :idle cleanly after CAS succeeds.
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

      # Step 1: submit u1 — M should enter :integrating with train=[u1].
      assert MergeAuthority.request_merge(ma_pid, u1) == :queued

      # Step 2: wait for M to reach the first-build barrier.
      assert_receive {:at_first_barrier, barrier_ref},
                     5_000,
                     "HR-5: MA did not enter :integrating within 5 s"

      # Step 3: submit u2 and u3 while M is :integrating — they must queue.
      assert MergeAuthority.request_merge(ma_pid, u2) == :queued
      assert MergeAuthority.request_merge(ma_pid, u3) == :queued

      # Step 4: release the first build.
      # MA.integrating/3 forwards {:proceed, ref} messages to the blocked task.
      send(ma_pid, {:proceed, barrier_ref})

      # Step 5: wait for the second build invocation and assert batch size ≥ 2.
      # Conformant code assembles train=[u2, u3] (length=2).
      # Current (non-conformant) code assembles train=[u2] only (length=1).
      assert_receive {:second_build_train_size, batch_size},
                     10_000,
                     "HR-5: second build_fun was not invoked within 10 s after releasing first build"

      assert batch_size >= 2,
             "HR-5 / [C213-B4]: start_build/1 MUST assemble a train of B ≥ 2 " <>
               "when ≥ 2 units are queued at transition_from_idle time; " <>
               "got B = #{batch_size} (the unstable serial regime the arch §5 [C213-B4] forbids)"
    end
  end
end
