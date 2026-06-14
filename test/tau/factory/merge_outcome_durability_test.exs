defmodule Tau.Factory.MergeOutcomeDurabilityTest do
  @moduledoc """
  Gating test for PR #465 (#462 — the durable merge-outcome Ledger row, RPO=0 at
  the merge boundary).

  ## What this enforces

  Today the merge outcome (`:merged` / `:rejected`) is carried SOLELY by
  ephemeral telemetry (`lib/tau/factory/merge_authority.ex` ~line 264 —
  `telemetry(:merged, ...)`). It is the only terminal-deciding control-loop fact
  NOT in the durable Ledger — the lone hole in RPO=0 / D-315. The crash window:
  a Unit resuming at `:awaiting_merge` (D-344) UNCONDITIONALLY re-calls
  `merge_fun` (`unit.ex` `awaiting_merge(:internal, :on_enter, ...)`), so a merge
  that already LANDED is re-submitted on crash-resume — re-doing terminal work
  (`--force-with-lease` protects the ref, not the per-unit outcome under train
  batching) and able to escalate an already-merged PR as `E_MERGE_STALLED`.

  The fix this test pins:

    1. The MergeAuthority appends a DURABLE, append-only `merge_outcomes` row
       (`Ledger.Writer.record_merge_outcome/2`) WAL-before-ack, and does so
       BEFORE the ephemeral telemetry projection fires. Telemetry/PubSub becomes
       a derived projection of the durable row.
    2. The outcome is readable via `Ledger.Reader.merge_outcome_for/2` and
       survives the producer (MergeAuthority) process dying — read from a
       SEPARATELY-supervised Ledger (RPO=0 / D-315).
    3. Reconcile-on-resume (load-bearing): a Unit resuming at `:awaiting_merge`
       for a unit whose `:merged` outcome is ALREADY in L MUST NOT re-call
       `merge_fun` (no double-submit, D-344 "re-does no terminal work"). A
       `:rejected` outcome routes to re-gate, NOT re-merge (INV-2).

  ## Pinned contract (the implementer MUST conform; SPEC §4/§6 amendment lands
  in this PR)

    - `Ledger.Writer.record_merge_outcome(ledger, attrs)` — append-only, no
      UPDATE/DELETE. WAL-before-ack (D-315). `attrs` fields:
        * `:unit_id`    — `String.t()`; the unit's `:id`.
        * `:outcome`    — `:merged | :rejected`.
        * `:commit_sha` — `String.t() | nil`; present (the merged tip) for
                          `:merged`, `nil` for `:rejected`.
        * `:reason`     — `term() | nil`; the reject reason for `:rejected`,
                          `nil` for `:merged`.
        * `:run`        — `String.t()`; the unit's run id.
      Returns `{:ok, ref}`.
    - `Ledger.Reader.merge_outcome_for(ledger, unit_id)` — the LATEST outcome
      for `unit_id`, or `:none`. Shape:
        * `{:merged, commit_sha}` for a merged unit;
        * `{:rejected, reason}` for a rejected unit;
        * `:none` when no outcome row exists.
    - `Tau.Factory.Unit` at `:awaiting_merge` on entry reconciles against the
      durable outcome via the unit's existing `:ledger` opt before calling
      `merge_fun`: if a `:merged` outcome is present it does NOT call `merge_fun`
      (idempotent resume → terminal :merged); if a `:rejected` outcome is present
      it routes to `:gating` (re-gate); only with `:none` does it call
      `merge_fun`.

  ## Fail-before validity (oracle separation, factory-loop §4b)

  On THIS branch (no implementer yet) `Ledger.Writer.record_merge_outcome/2` and
  `Ledger.Reader.merge_outcome_for/2` do NOT exist, and the MergeAuthority writes
  no outcome row; the Unit's `:awaiting_merge` entry unconditionally calls
  `merge_fun`. Every assertion below therefore FAILS (UndefinedFunctionError on
  the new ops; the no-double-submit assertion fails because the current Unit
  always re-submits). A test that passed against the current code would be
  vacuous.

  D-NNN linkage: D-355 (durable merge outcome, allocated in SPEC-FACTORY-MERGE §6
  by this PR). Established tags `:d_315` (RPO=0 / WAL-before-ack) and `:d_344`
  (resume reconcile) also apply.
  """

  use ExUnit.Case, async: false

  alias Tau.Factory.Ledger.Reader, as: LedgerReader
  alias Tau.Factory.Ledger.Writer, as: LedgerWriter
  alias Tau.Factory.MergeAuthority

  @moduletag :capture_log
  @moduletag :d_355
  @moduletag :d_315
  @moduletag :d_344

  @unit_supervisor Tau.Factory.UnitSupervisor
  @scheduler Tau.Factory.Scheduler

  # ---------------------------------------------------------------------------
  # Injected CAS seam — drives a MergeAuthority merge to completion WITHOUT real
  # git. The MergeAuthority accepts a `:cas` module (default Tau.Factory.Merge.Cas).
  # This stub returns :all_pass (verdicts live) and :ok (push lands), so the
  # :committing state reaches the :merged branch deterministically.
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

  # Start a REAL, SEPARATELY-supervised Ledger.Writer against an isolated temp DB
  # (the durable store outlives any producer that writes to it). Returns its name.
  defp start_ledger do
    db_path = Briefly.create!(extname: ".db")
    writer_name = unique(:merge_outcome_ledger)

    start_supervised!(
      {LedgerWriter, db_path: db_path, name: writer_name},
      id: writer_name
    )

    writer_name
  end

  # build_fun that returns a built train immediately, carrying the REAL committed
  # `tip` so the durable outcome's commit_sha is a real oid. `base` is the real
  # origin/main oid M captured (start_build runs `git rev-parse origin/main`).
  defp built_build_fun(tip) do
    fn units, base -> {:built, units, base, tip} end
  end

  # Set up a real git topology so MergeAuthority.start_build's `fetch_main_oid`
  # (git fetch + rev-parse origin/main) succeeds. Mirrors the idiom in
  # merge_serialized_test.exs / merge_force_with_lease_test.exs. Returns the work
  # dir path and the unit branch tip oid (a real commit sha).
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

  # Start a MergeAuthority with the injected build_fun + PassingCas seam against a
  # real git work dir.
  defp start_merge_authority(ledger, repo_dir, build_fun) do
    ma_name = unique(:merge_outcome_ma)
    tasks_name = unique(:merge_outcome_tasks)

    start_supervised!(
      {MergeAuthority,
       name: ma_name,
       ledger: ledger,
       repo_dir: repo_dir,
       required_halves: [:critic, :reviewer],
       tasks_name: tasks_name,
       cas: PassingCas,
       build_fun: build_fun},
      id: ma_name
    )

    ma_name
  end

  defp empty_scope do
    %{
      deps: [],
      files: MapSet.new(),
      codepoints: MapSet.new(),
      specs: MapSet.new(),
      resources: MapSet.new()
    }
  end

  defp start_scheduler(name) do
    start_supervised!({@scheduler, name: name, w_cap: 10}, id: name)
  end

  defp spawn_worker do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # ORACLE 1 — Durable outcome, WAL-before-ack ordering.
  #
  # Drive a real MergeAuthority to complete a merge for a unit; assert the merge
  # outcome is in L (Ledger.Reader.merge_outcome_for/2 returns {:merged, tip}),
  # and that the durable row is already present when the telemetry projection
  # fires (WAL-before-ack: durable BEFORE the ephemeral projection).
  # ---------------------------------------------------------------------------

  describe "D-355 / d_315 — outcome is a durable Ledger row written WAL-before-ack" do
    @tag :d_355
    @tag :d_315
    test "D-355/d_315: a completed merge records {:merged, commit_sha} in L, durable before the telemetry projection" do
      ledger = start_ledger()
      test_pid = self()

      unit = %{
        id: "u-merged-#{System.unique_integer([:positive])}",
        hash: "hash-#{System.unique_integer([:positive])}",
        run: "run-#{System.unique_integer([:positive])}",
        branch: "feat/merge-outcome-durable-#{System.unique_integer([:positive])}"
      }

      {work_path, tip} = setup_git_repo(unit)
      ma = start_merge_authority(ledger, work_path, built_build_fun(tip))

      # Attach a telemetry handler on the :merged projection. WAL-before-ack means
      # the durable row MUST already be readable from L at the instant the
      # ephemeral telemetry projection fires. The handler only SIGNALS the firing;
      # the durable read is done in the test body so a missing read op surfaces as
      # a clean UndefinedFunctionError, not a detached-handler timeout.
      handler_id = "merge-outcome-durable-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:tau, :factory, :merge, :merged],
        fn _event, _measurements, _metadata, _config -> send(test_pid, :merged_fired) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert :queued = MergeAuthority.request_merge(ma, unit)

      # The merge runs off M's mailbox; allow it to reach :committing → :merged.
      assert_receive :merged_fired,
                     5_000,
                     "merge_outcome_durable/d_315: the :merged telemetry projection never fired"

      # WAL-before-ack: the durable write happens BEFORE the synchronous
      # telemetry projection (`telemetry(:merged, ...)` at merge_authority.ex:264
      # runs after the durable append returns). Because telemetry is dispatched
      # synchronously inside the M process, by the time we observe :merged_fired
      # the durable row is already WAL-committed and therefore readable. A :none
      # here means the producer emitted the telemetry BEFORE the durable write
      # (ordering violation) — or never wrote the durable row at all.
      assert {:merged, ^tip} = LedgerReader.merge_outcome_for(ledger, unit.id),
             "merge_outcome_durable/d_315: the durable merge-outcome row MUST be present " <>
               "in L (and equal {:merged, #{inspect(tip)}}) by the time the telemetry " <>
               "projection fires (WAL-before-ack, D-315). merge_outcome_for/2 returned " <>
               "#{inspect(LedgerReader.merge_outcome_for(ledger, unit.id))} — the outcome is " <>
               "still ephemeral-only."
    end
  end

  # ---------------------------------------------------------------------------
  # ORACLE 2 — Survives a producer crash (RPO=0).
  #
  # Read the outcome from the SEPARATELY-supervised Ledger AFTER the
  # MergeAuthority (the producer) process is killed. The durable row must still
  # be there — the merge outcome's RPO is 0.
  # ---------------------------------------------------------------------------

  describe "D-355 / d_315 — the outcome survives a producer crash (RPO=0)" do
    @tag :d_355
    @tag :d_315
    test "D-355/d_315: after the MergeAuthority dies, the merged outcome is still in L" do
      ledger = start_ledger()
      test_pid = self()

      unit = %{
        id: "u-crash-#{System.unique_integer([:positive])}",
        hash: "hash-crash-#{System.unique_integer([:positive])}",
        run: "run-crash-#{System.unique_integer([:positive])}",
        branch: "feat/merge-outcome-crash-#{System.unique_integer([:positive])}"
      }

      {work_path, tip} = setup_git_repo(unit)
      ma = start_merge_authority(ledger, work_path, built_build_fun(tip))

      handler_id = "merge-outcome-crash-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:tau, :factory, :merge, :merged],
        fn _event, _measurements, _metadata, _config -> send(test_pid, :merged_fired) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert :queued = MergeAuthority.request_merge(ma, unit)
      assert_receive :merged_fired, 5_000, "the merge never completed"

      # KILL the producer (MergeAuthority). The durably-supervised Ledger is a
      # different process and is unaffected.
      ma_pid = Process.whereis(ma)
      assert is_pid(ma_pid)
      Process.exit(ma_pid, :kill)

      # The outcome MUST still be readable from L after the producer is gone (RPO=0).
      assert {:merged, ^tip} = LedgerReader.merge_outcome_for(ledger, unit.id),
             "merge_outcome_durable/d_315 (RPO=0): the merge outcome must survive the " <>
               "producer's death. After killing the MergeAuthority, " <>
               "merge_outcome_for/2 returned " <>
               "#{inspect(LedgerReader.merge_outcome_for(ledger, unit.id))} — a non-merged " <>
               "result means the outcome was ephemeral (lost with the producer), not durable."
    end
  end

  # ---------------------------------------------------------------------------
  # ORACLE 3 — Reconcile-on-resume: no double-submit (the load-bearing crux).
  #
  # A Unit resuming at :awaiting_merge for a unit whose :merged outcome is ALREADY
  # in L MUST NOT re-call merge_fun. We seed the durable :merged outcome directly
  # in L, then start a REAL Unit (via UnitSupervisor.start_unit) wired with the
  # :ledger opt and a merge_fun that RECORDS every call into an external Agent.
  # The Unit is driven to :awaiting_merge; on entry it must reconcile against the
  # durable outcome and reach :merged WITHOUT the already-decided unit's id ever
  # appearing in the recorded merge_fun calls.
  # ---------------------------------------------------------------------------

  describe "D-355 / d_344 — reconcile-on-resume does not re-submit an already-landed merge" do
    @tag :d_355
    @tag :d_344
    test "D-355/d_344: a Unit reaching :awaiting_merge with a recorded :merged outcome does NOT call merge_fun" do
      ledger = start_ledger()
      test_pid = self()

      tip = "tip-resume-#{System.unique_integer([:positive])}"
      unit_id = "u-resume-merged-#{System.unique_integer([:positive])}"
      run = "run-resume-#{System.unique_integer([:positive])}"

      sched = unique(:sched_resume_merged)
      sup = unique(:sup_resume_merged)
      start_scheduler(sched)
      start_supervised!({@unit_supervisor, name: sup}, id: sup)

      # Seed the DURABLE :merged outcome BEFORE the Unit reaches :awaiting_merge —
      # this models a merge that already landed prior to the (resumed) Unit.
      {:ok, _} =
        LedgerWriter.record_merge_outcome(ledger, %{
          unit_id: unit_id,
          outcome: :merged,
          commit_sha: tip,
          reason: nil,
          run: run
        })

      # Sanity: the durable outcome is readable.
      assert {:merged, ^tip} = LedgerReader.merge_outcome_for(ledger, unit_id)

      # merge_fun records the unit_id of every call into an external Agent. The
      # already-decided unit MUST NOT appear.
      {:ok, calls} = Agent.start_link(fn -> [] end)
      on_exit(fn -> if Process.alive?(calls), do: Agent.stop(calls) end)

      merge_fun = fn uid, _hash ->
        Agent.update(calls, fn acc -> [uid | acc] end)
        :queued
      end

      opts = [
        unit_id: unit_id,
        declared_scope: empty_scope(),
        hash: "hash-#{unit_id}",
        scheduler: sched,
        report_to: test_pid,
        ledger: ledger,
        worker_fun: fn _role -> {:ok, spawn_worker()} end,
        gate_fun: fn _coord -> :pass end,
        merge_fun: merge_fun,
        timeouts: [state_timeout_ms: 5_000]
      ]

      unit_pid = @unit_supervisor.start_unit(sup, opts)
      assert is_pid(unit_pid)

      # Drive oracle → implementing → gating(:pass) → awaiting_merge.
      drive_to_awaiting_merge(unit_pid)

      # On entering :awaiting_merge, the Unit reconciles against the durable
      # :merged outcome and reaches :merged WITHOUT re-submitting.
      assert_receive {:unit_terminal, ^unit_id, :merged, _provenance},
                     5_000,
                     "merge_outcome_durable/d_344: a Unit whose :merged outcome is already " <>
                       "durable in L must reconcile to :merged on :awaiting_merge entry"

      :timer.sleep(50)
      recorded = Agent.get(calls, & &1)

      refute unit_id in recorded,
             "merge_outcome_durable/d_344: the Unit re-called merge_fun for a unit whose " <>
               ":merged outcome was ALREADY durable in L (double-submit). Recorded merge_fun " <>
               "calls: #{inspect(recorded)}. The :awaiting_merge entry MUST reconcile against " <>
               "merge_outcome_for/2 and skip the re-submit (D-344 — re-does no terminal work)."
    end

    @tag :d_355
    @tag :d_344
    test "D-355/d_344: a Unit reaching :awaiting_merge with a recorded :rejected outcome routes to re-gate, not re-merge" do
      ledger = start_ledger()
      test_pid = self()

      unit_id = "u-resume-rejected-#{System.unique_integer([:positive])}"
      run = "run-resume-rej-#{System.unique_integer([:positive])}"

      sched = unique(:sched_resume_rejected)
      sup = unique(:sup_resume_rejected)
      start_scheduler(sched)
      start_supervised!({@unit_supervisor, name: sup}, id: sup)

      # Seed a DURABLE :rejected outcome.
      {:ok, _} =
        LedgerWriter.record_merge_outcome(ledger, %{
          unit_id: unit_id,
          outcome: :rejected,
          commit_sha: nil,
          reason: :stale_ref,
          run: run
        })

      assert {:rejected, :stale_ref} = LedgerReader.merge_outcome_for(ledger, unit_id)

      {:ok, calls} = Agent.start_link(fn -> [] end)
      on_exit(fn -> if Process.alive?(calls), do: Agent.stop(calls) end)

      merge_fun = fn uid, _hash ->
        Agent.update(calls, fn acc -> [uid | acc] end)
        :queued
      end

      # gate_fun records each invocation. A :rejected reconcile MUST route back to
      # :gating (re-gate, INV-2), so gate_fun is called AGAIN after the first pass.
      {:ok, gate_calls} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> if Process.alive?(gate_calls), do: Agent.stop(gate_calls) end)

      regate_signal = test_pid

      gate_fun = fn _coord ->
        n = Agent.get_and_update(gate_calls, fn c -> {c, c + 1} end)
        # The second gate call is the re-gate after the :rejected reconcile.
        if n >= 1, do: send(regate_signal, :regated)
        :pass
      end

      opts = [
        unit_id: unit_id,
        declared_scope: empty_scope(),
        hash: "hash-#{unit_id}",
        scheduler: sched,
        report_to: test_pid,
        ledger: ledger,
        worker_fun: fn _role -> {:ok, spawn_worker()} end,
        gate_fun: gate_fun,
        merge_fun: merge_fun,
        timeouts: [state_timeout_ms: 5_000]
      ]

      unit_pid = @unit_supervisor.start_unit(sup, opts)
      assert is_pid(unit_pid)

      drive_to_awaiting_merge(unit_pid)

      # The :rejected reconcile routes BACK to :gating (re-gate), so the gate runs
      # a second time. It MUST NOT call merge_fun for this unit (no re-merge).
      assert_receive :regated,
                     5_000,
                     "merge_outcome_durable/d_344: a Unit whose :rejected outcome is durable " <>
                       "in L must route to re-gate (:gating) on :awaiting_merge entry (INV-2), " <>
                       "not re-call merge_fun"

      :timer.sleep(50)
      recorded = Agent.get(calls, & &1)

      refute unit_id in recorded,
             "merge_outcome_durable/d_344: with a durable :rejected outcome the Unit must " <>
               "re-gate, NOT re-merge. merge_fun was called for #{inspect(unit_id)} " <>
               "(recorded: #{inspect(recorded)})."
    end
  end

  # ---------------------------------------------------------------------------
  # Drive a Unit forward to :awaiting_merge by delivering {:worker_done, pid} for
  # the oracle and implementing workers (mirrors unit_snapshot_durability_test.exs).
  # ---------------------------------------------------------------------------

  defp drive_to_awaiting_merge(unit_pid) do
    deliver_worker_done(unit_pid)
    :timer.sleep(50)
    deliver_worker_done(unit_pid)
    :timer.sleep(100)
  end

  defp deliver_worker_done(unit_pid) do
    :timer.sleep(50)

    case :sys.get_state(unit_pid) do
      {state, data} when state in [:oracle, :implementing] ->
        worker_pid = Map.get(data, :worker_pid)
        if is_pid(worker_pid), do: send(unit_pid, {:worker_done, worker_pid})

      _ ->
        :ok
    end
  end
end
