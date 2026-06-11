defmodule Tau.Factory.MergeSerializedTest do
  @moduledoc """
  Gating tests for PR #434 (P3a — MergeAuthority gen_statem + verdict-gated CAS).

  Tests AC-1 (D-302) and AC-2 (D-302): serialized merge via a single gen_statem,
  non-blocking request_merge, and at most one :integrating train at a time.

  Written BEFORE production code exists (oracle-separation phase).
  These tests fail with UndefinedFunctionError until the implementer creates:
    - lib/tau/factory/merge_authority.ex
    - lib/tau/factory/merge/cas.ex
    - lib/tau/factory/supervisor.ex (extended with MergeAuthority + MergeTasks)

  AC linkage: AC-1 / D-302, AC-2 / D-302.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log

  # Runtime module references — file compiles even when modules do not yet exist.
  @merge_authority Tau.Factory.MergeAuthority
  @writer Tau.Factory.Ledger.Writer

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Start an isolated Ledger.Writer against a tmp DB and seed PASS verdicts for
  # both :critic and :reviewer for the given unit.
  defp start_writer_with_pass_verdicts(unit) do
    db_path = Briefly.create!(extname: ".db")
    writer_name = :"test_ma_writer_#{System.unique_integer([:positive])}"

    writer =
      start_supervised!(
        {@writer, db_path: db_path, name: writer_name},
        id: writer_name
      )

    seed_pass_verdicts(writer, unit)
    writer
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

  # Set up a real git topology in tmp_dir:
  #   - origin.git: bare repo with an initial commit on main
  #   - work/: clone; unit's branch created off main with its own commit
  # Returns {origin_path, work_path, initial_main_oid, tip}
  defp setup_git_repo(tmp_dir, unit) do
    origin_path = Path.join(tmp_dir, "origin.git")
    work_path = Path.join(tmp_dir, "work")

    # Init a non-bare work repo first, commit on main, then push to bare origin.
    # This avoids the git-version-dependent --initial-branch flag on bare repos.
    {_, 0} = System.cmd("git", ["init", "-b", "main", work_path])

    git_work = fn args -> System.cmd("git", args, cd: work_path) end

    git_work.(["config", "user.email", "test@tau.test"])
    git_work.(["config", "user.name", "Tau Test"])

    # Initial commit on main
    File.write!(Path.join(work_path, "README"), "initial")
    git_work.(["add", "README"])
    {_, 0} = git_work.(["commit", "-m", "initial commit"])

    # Create bare origin and push main
    {_, 0} = System.cmd("git", ["init", "--bare", origin_path])
    {_, 0} = git_work.(["remote", "add", "origin", origin_path])
    {_, 0} = git_work.(["push", "-u", "origin", "main"])

    {main_oid, 0} = git_work.(["rev-parse", "HEAD"])
    main_oid = String.trim(main_oid)

    # Create the unit's feature branch; sanitize branch name for filename use
    feature_name = String.replace(unit.branch, "/", "_")
    {_, 0} = git_work.(["checkout", "-b", unit.branch])
    File.write!(Path.join(work_path, "feature_#{feature_name}"), "feature work")
    {_, 0} = git_work.(["add", "."])
    {_, 0} = git_work.(["commit", "-m", "feature commit for #{unit.branch}"])
    {tip, 0} = git_work.(["rev-parse", "HEAD"])
    tip = String.trim(tip)
    {_, 0} = git_work.(["push", "origin", unit.branch])

    # Return to main
    {_, 0} = git_work.(["checkout", "main"])

    {origin_path, work_path, main_oid, tip}
  end

  # ---------------------------------------------------------------------------
  # AC-1 / D-302: Supervised start; initial state is :idle
  # ---------------------------------------------------------------------------

  describe "AC-1 / D-302 — MergeAuthority starts supervised in :idle state" do
    @tag :ac_1
    @tag :d_302
    test "AC-1 / D-302: after start_link, :sys.get_state returns {:idle, _} and process is alive" do
      tmp_dir = Briefly.create!(type: :directory)

      unit = %{
        id: "u1",
        hash: "abc-#{System.unique_integer([:positive])}",
        run: "run-001",
        branch: "feat/ac1-test"
      }

      writer = start_writer_with_pass_verdicts(unit)

      {_origin_path, work_path, _main_oid, _tip} = setup_git_repo(tmp_dir, unit)

      ma_name = :"test_ma_ac1_#{System.unique_integer([:positive])}"
      tasks_name = :"test_ma_tasks_ac1_#{System.unique_integer([:positive])}"

      # This is the runtime call that will fail until production code exists.
      # The call exercises the real start_link entry point.
      result =
        start_supervised!(
          {@merge_authority,
           name: ma_name,
           ledger: writer,
           repo_dir: work_path,
           required_halves: [:critic, :reviewer],
           tasks_name: tasks_name,
           build_fun: fn _units, _base -> {:built, [], "base", "tip"} end},
          id: ma_name
        )

      assert is_pid(result), "start_link must return a pid; got #{inspect(result)}"
      assert Process.alive?(result), "MergeAuthority process must be alive after start"

      # :sys.get_state on a gen_statem returns {state_name, data}
      {state_name, _data} = :sys.get_state(result)

      assert state_name == :idle,
             "AC-1 / D-302: initial state must be :idle; got #{inspect(state_name)}"
    end
  end

  # ---------------------------------------------------------------------------
  # AC-2 / D-302: request_merge is non-blocking; at most one :integrating train
  # ---------------------------------------------------------------------------

  describe "AC-2 / D-302 — request_merge is non-blocking; at most one :integrating train" do
    @tag :ac_2
    @tag :d_302
    test "AC-2 / D-302: concurrent request_merge calls return :queued immediately; only one :at_barrier arrives within window" do
      tmp_dir = Briefly.create!(type: :directory)
      test_pid = self()
      n_units = 4

      units =
        for i <- 1..n_units do
          %{
            id: "u#{i}",
            hash: "hash-#{i}-#{System.unique_integer([:positive])}",
            run: "run-#{i}",
            branch: "feat/unit-#{i}"
          }
        end

      # Set up a single git repo with all unit branches.
      # setup_git_repo already creates the branch for hd(units); remaining
      # branches are created below. The tip from setup is discarded here —
      # we rebuild all tips uniformly in the loop below.
      {_origin_path, work_path, _main_oid, _first_tip} =
        setup_git_repo(tmp_dir, hd(units))

      # Create remaining branches
      git_work = fn args -> System.cmd("git", args, cd: work_path) end
      git_work.(["config", "user.email", "test@tau.test"])
      git_work.(["config", "user.name", "Tau Test"])

      tips =
        for unit <- units do
          {_, 0} = git_work.(["checkout", "main"])
          # Branch for hd(units) already exists; checkout existing or create new.
          case git_work.(["checkout", unit.branch]) do
            {_, 0} -> :ok
            _ -> {_, 0} = git_work.(["checkout", "-b", unit.branch])
          end

          feature_name = String.replace(unit.branch, "/", "_")
          File.write!(Path.join(work_path, "feature_#{feature_name}"), "feature for #{unit.branch}")
          {_, 0} = git_work.(["add", "."])
          {_, 0} = git_work.(["commit", "-m", "feature #{unit.branch}"])
          {tip, 0} = git_work.(["rev-parse", "HEAD"])
          tip = String.trim(tip)
          {_, 0} = git_work.(["push", "origin", unit.branch])
          {_, 0} = git_work.(["checkout", "main"])
          tip
        end

      # Start a writer and seed pass verdicts for all units
      db_path = Briefly.create!(extname: ".db")
      writer_name = :"test_ma_writer_ac2_#{System.unique_integer([:positive])}"

      writer =
        start_supervised!(
          {@writer, db_path: db_path, name: writer_name},
          id: writer_name
        )

      for unit <- units, do: seed_pass_verdicts(writer, unit)

      # Barrier build_fun using the first tip — blocks until test sends :proceed
      # This lets us observe how many :at_barrier messages arrive (= integrating trains)
      first_tip_oid = hd(tips)

      blocking_build_fun = fn _units, _base ->
        ref = make_ref()
        send(test_pid, {:at_barrier, ref, first_tip_oid})

        receive do
          {:proceed, ^ref} -> :ok
        after
          10_000 -> raise "barrier timeout"
        end

        {:built, [], "base", first_tip_oid}
      end

      ma_name = :"test_ma_ac2_#{System.unique_integer([:positive])}"
      tasks_name = :"test_ma_tasks_ac2_#{System.unique_integer([:positive])}"

      ma_pid =
        start_supervised!(
          {@merge_authority,
           name: ma_name,
           ledger: writer,
           repo_dir: work_path,
           required_halves: [:critic, :reviewer],
           tasks_name: tasks_name,
           build_fun: blocking_build_fun},
          id: ma_name
        )

      # Fire N concurrent request_merge calls — ALL must return :queued immediately
      # (non-blocking per [C206] / B1).
      t0 = System.monotonic_time(:millisecond)

      results =
        units
        |> Enum.map(fn unit ->
          Task.async(fn ->
            @merge_authority.request_merge(ma_pid, unit)
          end)
        end)
        |> Enum.map(&Task.await(&1, 5_000))

      t1 = System.monotonic_time(:millisecond)
      elapsed = t1 - t0

      # All must return :queued
      for result <- results do
        assert result == :queued,
               "AC-2 / D-302: request_merge must return :queued immediately; got #{inspect(result)}"
      end

      # Non-blocking: all N calls must return well within T_int.
      # We allow 3000 ms as a generous upper bound (real T_int is minutes).
      assert elapsed < 3000,
             "AC-2 / D-302: request_merge must be non-blocking; #{n_units} calls took #{elapsed}ms"

      # Allow M to start one :integrating train
      # Exactly ONE :at_barrier must arrive within a reasonable window.
      assert_receive {:at_barrier, ref, _tip},
                     5_000,
                     "AC-2 / D-302: expected M to enter :integrating and trigger at_barrier"

      # Drain inbox briefly — no second :at_barrier should arrive while the first barrier holds.
      # (Only one :integrating train at a time — INV-3)
      :timer.sleep(200)

      barrier_count =
        Enum.reduce(1..100, 0, fn _i, acc ->
          receive do
            {:at_barrier, _ref2, _tip2} -> acc + 1
          after
            0 -> acc
          end
        end)

      assert barrier_count == 0,
             "AC-2 / D-302: only ONE :integrating train must exist at a time (INV-3); " <>
               "got #{barrier_count} extra :at_barrier messages while first barrier was held"

      # Release the first barrier and let M settle
      send(ma_pid, {:proceed, ref})
      :timer.sleep(200)
    end
  end
end
