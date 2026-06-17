defmodule Tau.Factory.MergeTrainBisectTest do
  @moduledoc """
  Gating test for issue #604 — INV-MAI-8 (bisect on health-red, B>1 trains).

  ## Invariant under test (INV-MAI-8)

  SPEC-FACTORY-MERGE §2 C2 + §4 B2 + §5 (`:integrating` table) + §6 D-303:

  > "When a batch health check is red, M must bisect the train to identify the
  > culprit unit and eject it before re-integrating the rest, costing O(log B)
  > health runs. Falsified if M discards the entire batch on a single red health
  > result without bisecting."

  Concretely:
  - `Tau.Factory.Merge.Train.bisect/2` must exist (C2 pure module).
  - On `{:build_failed, {:health_red, report}}` for a B=2 train, M must NOT
    broadcast `{:merge_result, :rejected}` for the INNOCENT unit.
  - The innocent unit MUST be re-queued and eventually merged (re-integrated).
  - Only the CULPRIT unit receives a terminal `:rejected` outcome.

  ## Current failure mode

  `integrating/3` `:health_red` branch (merge_authority.ex lines 373-401):
  - Iterates over ALL train members and writes `:rejected` + broadcasts
    `{:merge_result, :rejected}` for every member — no bisect, no survivor
    detection.
  - `eject_train/1` sets `train: []` — entire batch discarded.
  - `Tau.Factory.Merge.Train` does not exist in lib/; no `bisect/2` call exists
    anywhere in the production code.

  ## Why `build_fun` injection is not a bypass

  The SPEC §4 B2 boundary contract specifies `build_fun` as the Task-result
  producer (the `rebase_train → gate → health` pipeline). Injecting `build_fun`
  exercises M via the real `request_merge/2` entry point (§4 B1) and tests M's
  response to `{:build_failed, {:health_red, _}}` — the invariant's exact trigger.
  This matches the test strategy used in `merge_train_batch_size_test.exs` and
  `merge_result_pubsub_test.exs`.

  ## Fail-before validity (oracle separation)

  Against the current code, the innocent unit ALWAYS receives
  `{:merge_result, :rejected}` because the `:health_red` branch rejects the
  entire train without bisecting. The `refute_receive {:merge_result, :rejected}`
  assertion therefore FAILS.

  ## Test strategy

  1. Submit u_setup to get M into `:integrating` with a blocking build.
     MergeAuthority forwards `{:proceed, ref}` messages from its mailbox to
     the build Task (`:integrating` state, lines 335–341 of merge_authority.ex).
  2. While u_setup is blocked, submit u_culprit and u_innocent to queue.
  3. Signal u_setup to return `{:built, ...}` (successful merge), draining
     the first train and returning M to `:idle`.
  4. M calls `start_build/1` with [u_culprit, u_innocent] → B=2 train.
  5. build_fun for any sub-train containing u_culprit returns health-red.
     build_fun for a sub-train with only u_innocent returns {:built, ...}.
  6. Assert (a): u_culprit receives `{:merge_result, :rejected}`.
  7. Assert (b): u_innocent does NOT receive `{:merge_result, :rejected}` —
     this FAILS against current code (entire train ejected without bisect).
  8. Assert (c): u_innocent eventually receives `{:merge_result, :merged}`.

  ## AC/D-NNN linkage: INV-MAI-8, AC-5 (D-303), SPEC-FACTORY-MERGE §2 C2, §4 B2
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log
  @moduletag timeout: 60_000
  @moduletag :"INV-MAI-8"

  alias Tau.Factory.Ledger.Writer, as: LedgerWriter
  alias Tau.Factory.MergeAuthority

  # ---------------------------------------------------------------------------
  # CAS seam: always passes the live-verdict check and the push.
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
    writer_name = unique(:bisect_ledger)

    start_supervised!(
      {LedgerWriter, db_path: db_path, name: writer_name},
      id: writer_name
    )

    writer_name
  end

  defp seed_pass_verdicts(writer, %{hash: hash, run: run}) do
    for half <- [:critic, :reviewer] do
      {:ok, _} =
        LedgerWriter.append_verdict(writer, %{
          hash: hash,
          run: run,
          half: half,
          status: :pass,
          idempotency_key: "ikey-bisect-#{half}-#{System.unique_integer([:positive])}"
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

    tips =
      Enum.map(units, fn unit ->
        {_, 0} = git_work.(["checkout", "main"])
        {_, 0} = git_work.(["checkout", "-b", unit.branch])
        feature_name = String.replace(unit.branch, "/", "_")
        File.write!(Path.join(work_path, "feature_#{feature_name}"), "feature work for #{unit.id}")
        {_, 0} = git_work.(["add", "."])
        {_, 0} = git_work.(["commit", "-m", "feature commit #{unit.branch}"])
        {tip_raw, 0} = git_work.(["rev-parse", "HEAD"])
        tip = String.trim(tip_raw)
        {_, 0} = git_work.(["push", "origin", unit.branch])
        {_, 0} = git_work.(["checkout", "main"])
        {unit.id, tip}
      end)

    {work_path, Map.new(tips)}
  end

  defp pr_topic(unit_id), do: "factory:pr:#{unit_id}"

  # ---------------------------------------------------------------------------
  # INV-MAI-8: B=2 train with health-red — culprit ejected, innocent re-integrated
  # ---------------------------------------------------------------------------

  describe "INV-MAI-8 — health-red on B=2 train: culprit ejected, innocent re-integrated" do
    @tag :"INV-MAI-8"
    @tag :ac_5
    @tag :d_303
    test "INV-MAI-8: when a B=2 train is health-red, M bisects, ejects the culprit, and re-integrates the innocent survivor" do
      test_pid = self()
      tmp_dir = Briefly.create!(type: :directory)

      u_setup = %{
        id: "u-setup-#{System.unique_integer([:positive])}",
        hash: "hash-setup-#{System.unique_integer([:positive])}",
        run: "run-setup",
        branch: "feat/bisect-setup-#{System.unique_integer([:positive])}"
      }

      u_culprit = %{
        id: "u-culprit-#{System.unique_integer([:positive])}",
        hash: "hash-culprit-#{System.unique_integer([:positive])}",
        run: "run-culprit",
        branch: "feat/bisect-culprit-#{System.unique_integer([:positive])}"
      }

      u_innocent = %{
        id: "u-innocent-#{System.unique_integer([:positive])}",
        hash: "hash-innocent-#{System.unique_integer([:positive])}",
        run: "run-innocent",
        branch: "feat/bisect-innocent-#{System.unique_integer([:positive])}"
      }

      {work_path, tips} = setup_git_repo(tmp_dir, [u_setup, u_culprit, u_innocent])

      ledger = start_ledger()

      for unit <- [u_setup, u_culprit, u_innocent],
          do: seed_pass_verdicts(ledger, unit)

      # Build-phase tracking: an Agent counter increments on each build invocation.
      {:ok, phase_agent} = Agent.start_link(fn -> 1 end)

      # The test process sends {:proceed, barrier_ref} to ma_pid; MA forwards it
      # to the Task via the :integrating forward clause (merge_authority.ex:336).
      barrier_ref = make_ref()

      culprit_id = u_culprit.id
      innocent_id = u_innocent.id

      build_fun = fn train, base ->
        phase = Agent.get_and_update(phase_agent, fn n -> {n, n + 1} end)

        case phase do
          1 ->
            # Phase 1 — u_setup (B=1 train): block until the test signals.
            # We block so the test can enqueue u_culprit + u_innocent while M is
            # in :integrating, ensuring they both land in the NEXT train (B=2).
            send(test_pid, {:phase1_blocking, barrier_ref})

            receive do
              {:proceed, ^barrier_ref} -> :ok
            after
              20_000 -> raise "INV-MAI-8: phase 1 build barrier timed out"
            end

            tip = tips[u_setup.id]
            {:built, train, base, tip}

          _ ->
            # Phase 2+ — bisect sub-trains or B=2 initial health check.
            # A sub-train containing u_culprit → health-red.
            # A sub-train with only u_innocent → built (green survivor).
            has_culprit = Enum.any?(train, fn u -> u.id == culprit_id end)

            if has_culprit do
              {:build_failed, {:health_red, "tip red: culprit #{culprit_id} present"}}
            else
              tip = tips[innocent_id]
              {:built, train, base, tip}
            end
        end
      end

      ma_name = unique(:bisect_ma)
      tasks_name = unique(:bisect_tasks)

      ma_pid =
        start_supervised!(
          {MergeAuthority,
           name: ma_name,
           ledger: ledger,
           repo_dir: work_path,
           required_halves: [:critic, :reviewer],
           tasks_name: tasks_name,
           build_fun: build_fun,
           cas: PassingCas,
           pubsub: Tau.PubSub,
           post_merge_health_fun: fn _dir, _lang, _ctx -> :green end},
          id: ma_name
        )

      # Subscribe to PubSub topics for both units BEFORE submitting (D-356).
      :ok = Phoenix.PubSub.subscribe(Tau.PubSub, pr_topic(u_culprit.id))
      :ok = Phoenix.PubSub.subscribe(Tau.PubSub, pr_topic(u_innocent.id))

      # --- Phase 1: submit u_setup → M enters :integrating (blocking) ---
      assert :queued = MergeAuthority.request_merge(ma_pid, u_setup)

      assert_receive {:phase1_blocking, ^barrier_ref},
                     5_000,
                     "INV-MAI-8: M did not start the Phase 1 build within 5s"

      # Enqueue u_culprit and u_innocent while M is blocked in :integrating.
      # D-302 / INV-3: only one train at a time — both queue up for the NEXT train.
      assert :queued = MergeAuthority.request_merge(ma_pid, u_culprit)
      assert :queued = MergeAuthority.request_merge(ma_pid, u_innocent)

      # Signal u_setup build to complete (sent to MA, forwarded to the Task).
      send(ma_pid, {:proceed, barrier_ref})

      # --- Phase 2: u_setup merges; M assembles B=2 [u_culprit, u_innocent] ---
      #
      # The Phase 2+ build_fun returns health-red for any train that includes
      # u_culprit, and {:built, ...} for trains with only u_innocent.
      #
      # CONFORMANT bisect path (INV-MAI-8):
      #   (a) bisect/2 identifies u_culprit as the culprit (1 bisect step for B=2)
      #   (b) M ejects u_culprit → {:merge_result, :rejected}
      #   (c) M re-queues u_innocent → eventually merges → {:merge_result, :merged}
      #
      # NON-CONFORMANT path (current code):
      #   (a) M ejects the entire B=2 train without bisecting
      #   (b) BOTH u_culprit AND u_innocent receive {:merge_result, :rejected}

      # ASSERTION (a): u_culprit MUST receive {:merge_result, :rejected}.
      # Passes against current code (all members ejected) AND conformant code.
      assert_receive {:merge_result, :rejected},
                     30_000,
                     "INV-MAI-8: expected {:merge_result, :rejected} for u_culprit " <>
                       "(it is the health-red culprit and MUST be ejected). " <>
                       "PubSub topic: #{pr_topic(u_culprit.id)}"

      # ASSERTION (b): u_innocent MUST NOT receive {:merge_result, :rejected}.
      # FAILS against current code — this is the primary INV-MAI-8 gate assertion.
      # Current code ejects the entire train; u_innocent is incorrectly rejected.
      refute_receive {:merge_result, :rejected},
                     2_000,
                     "INV-MAI-8 VIOLATION: u_innocent received {:merge_result, :rejected} " <>
                       "on PubSub topic #{pr_topic(u_innocent.id)}. " <>
                       "M MUST bisect the B=2 train to find the culprit and " <>
                       "re-integrate the innocent survivor — discarding the entire " <>
                       "batch without bisecting violates INV-MAI-8 " <>
                       "(SPEC-FACTORY-MERGE §2 C2: 'bisect/2 — O(log B) culprit search'; " <>
                       "§5 :integrating: 'health RED → bisect(train) → eject culprit → re-integrate rest')."

      # ASSERTION (c): u_innocent MUST eventually be re-integrated and merged.
      # Unreachable against current code (fails at assertion b first).
      assert_receive {:merge_result, :merged},
                     30_000,
                     "INV-MAI-8: expected {:merge_result, :merged} for u_innocent " <>
                       "on PubSub topic #{pr_topic(u_innocent.id)}. " <>
                       "After bisect ejects u_culprit, the innocent survivor " <>
                       "MUST be re-integrated (SPEC-FACTORY-MERGE §5: " <>
                       "'health RED → bisect(train) → eject culprit → re-integrate rest')."

      Agent.stop(phase_agent)
    end
  end
end
