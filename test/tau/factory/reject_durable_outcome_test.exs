defmodule Tau.Factory.RejectDurableOutcomeTest do
  @moduledoc """
  Gating test for PR #483 (#466) — the SYMMETRIC half of the durable
  merge-outcome RPO=0 guarantee (D-355).

  ## Background — the asymmetry this closes

  #462/#465 (D-355) made `:merged` durable: on a successful `cas_push`, the
  MergeAuthority appends a `merge_outcomes` row (`:outcome => :merged`)
  WAL-before-ack (`merge_authority.ex` `:committing` → `:ok`), enabling a Unit
  resuming at `:awaiting_merge` to reconcile to the terminal outcome without
  re-submitting an already-landed merge.

  The REJECT side was left ephemeral. On a TERMINAL `:health_red` eject
  (`merge_authority.ex` ~line 196-212 — "do NOT requeue; health failure is
  terminal for this tip") the producer today emits ONLY
  `telemetry(:reject, …)` + a `{:merge_result, :rejected}` PubSub broadcast.
  It writes **no** durable `merge_outcomes` row. So a Unit that crashes after a
  terminal reject and resumes at `:awaiting_merge` reads
  `merge_outcome_for/2 => :none` (not `:rejected`) and **re-submits** the merge
  the train already terminally rejected — re-doing terminal work and able to
  loop / escalate a PR M already ejected. This is the lone remaining hole in
  RPO=0 (D-315) at the merge boundary on the reject side.

  ## What this enforces (mirrors `merge_outcome_durability_test.exs` on the
  reject side)

    1. **Durable reject row (producer-written).** Driving the REAL
       MergeAuthority to a TERMINAL `:health_red` ejection writes a durable,
       append-only `merge_outcomes` row with `:outcome => :rejected` for the
       ejected member, readable from a SEPARATELY-supervised Ledger
       (WAL-before-ack, RPO=0 / D-315) — exactly as the `:merged` side records
       `{:merged, tip}`. The #462 test SEEDS a `:rejected` row by hand; this
       test proves the PRODUCER writes it.

    2. **Reconcile-on-resume — no re-submit.** With a durable `:rejected`
       outcome present, a real Unit entering `:awaiting_merge` reconciles to
       `:rejected` (its existing arm → re-gate, INV-2) and does NOT call
       `merge_fun` (no fresh `request_merge` for an already-terminally-rejected
       member). Mirrors the #462 merged-reconcile assertion on the reject side.

    3. **Requeue writes nothing.** A NON-terminal `:stale_ref` requeue
       (`merge_authority.ex` `:committing` → `{:error, :stale_ref}`) writes NO
       `merge_outcomes` row — only TERMINAL outcomes are durable.

  ## Pinned contract (SPEC-FACTORY-MERGE §6 — D-355 extended to symmetry in
  THIS PR; conforms to the existing #462 durable-row pattern)

    - `Ledger.Writer.record_merge_outcome/2` accepts `:outcome => :rejected`
      with `:commit_sha => nil` and `:reason => term()` (already in the typespec
      at `writer.ex` `merge_outcome_attrs/0`).
    - `Ledger.Reader.merge_outcome_for/2` returns `{:rejected, reason}` for a
      rejected unit; `:none` when no outcome row exists.
    - The MergeAuthority, on a TERMINAL reject (health-red eject), records the
      durable `:rejected` row via the SAME WAL-before-ack path it uses for
      `:merged`, per ejected member, BEFORE acking. A non-terminal requeue
      records nothing.

  ## Fail-before validity (oracle separation, factory-loop §4b)

  On THIS branch (no implementer yet) the `:health_red` terminal eject writes
  NO durable row: `merge_outcome_for/2` returns `:none` after the eject, so
  assertion (1) FAILS. With no durable `:rejected` row produced, the Unit's
  `:awaiting_merge` entry reads `:none` and re-submits, so the
  reconcile-no-resubmit assertion (2) FAILS. A test that passed against the
  current code would be vacuous. Assertion (3) is the refute that must REMAIN
  true after the fix (requeue stays non-durable); it guards over-recording.

  D-NNN linkage: D-355 (durable merge outcome, symmetric). Established tags
  `:d_315` (RPO=0 / WAL-before-ack) and `:d_344` (resume reconcile) also apply.
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
  # Injected seams (mirror merge_outcome_durability_test.exs).
  #
  # StaleRefCas drives the non-terminal requeue path: verdicts live but the push
  # is rejected with {:error, :stale_ref}. For the terminal-eject oracles the
  # build_fun returns a health-red failure, so :committing is never reached and
  # the cas module is unused.
  # ---------------------------------------------------------------------------

  defmodule StaleRefCas do
    @moduledoc false
    def assert_all_verdicts_live(_ledger, _units, _required_halves), do: :all_pass
    def cas_push(_repo_dir, _tip, _base), do: {:error, :stale_ref}
  end

  # ---------------------------------------------------------------------------
  # Helpers (mirror merge_outcome_durability_test.exs)
  # ---------------------------------------------------------------------------

  defp unique(base), do: :"#{base}_#{System.unique_integer([:positive])}"

  defp start_ledger do
    db_path = Briefly.create!(extname: ".db")
    writer_name = unique(:reject_outcome_ledger)

    start_supervised!(
      {LedgerWriter, db_path: db_path, name: writer_name},
      id: writer_name
    )

    writer_name
  end

  # build_fun returning a TERMINAL health-red build failure. The return value
  # becomes the {ref, result} task message MergeAuthority receives in
  # :integrating; {:build_failed, {:health_red, report}} drives the terminal
  # eject (merge_authority.ex:201 — "do NOT requeue").
  defp health_red_build_fun(report) do
    fn _units, _base -> {:build_failed, {:health_red, report}} end
  end

  # build_fun returning a built train (carries the real committed tip), so the
  # :committing state is reached and StaleRefCas can exercise the requeue path.
  defp built_build_fun(tip) do
    fn units, base -> {:built, units, base, tip} end
  end

  # Real git topology so MergeAuthority.start_build's fetch_main_oid succeeds
  # (mirrors merge_outcome_durability_test.exs / merge_serialized_test.exs).
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

  defp start_merge_authority(ledger, repo_dir, build_fun, cas) do
    ma_name = unique(:reject_outcome_ma)
    tasks_name = unique(:reject_outcome_tasks)

    start_supervised!(
      {MergeAuthority,
       name: ma_name,
       ledger: ledger,
       repo_dir: repo_dir,
       required_halves: [:critic, :reviewer],
       tasks_name: tasks_name,
       cas: cas,
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
  # ORACLE 1 — Durable reject row, producer-written, WAL-before-ack (RPO=0).
  #
  # Drive a real MergeAuthority to a TERMINAL :health_red eject; assert the
  # producer wrote a durable {:rejected, _} merge_outcomes row for the ejected
  # member, readable from the SEPARATELY-supervised Ledger by the time the
  # :reject telemetry projection fires (WAL-before-ack, the same ordering the
  # :merged side proves).
  # ---------------------------------------------------------------------------

  describe "D-355 / d_315 — a terminal :health_red eject writes a durable :rejected outcome row" do
    @tag :d_355
    @tag :d_315
    test "D-355/d_315: a terminal health-red eject records {:rejected, _} in L, durable before the telemetry projection" do
      ledger = start_ledger()
      test_pid = self()

      unit = %{
        id: "u-rejected-#{System.unique_integer([:positive])}",
        hash: "hash-rej-#{System.unique_integer([:positive])}",
        run: "run-rej-#{System.unique_integer([:positive])}",
        branch: "feat/reject-outcome-durable-#{System.unique_integer([:positive])}"
      }

      {work_path, _tip} = setup_git_repo(unit)

      # The build never reaches :committing — the build_fun returns a terminal
      # health-red failure, so M ejects from :integrating. A cas module is still
      # required to start the server.
      ma =
        start_merge_authority(
          ledger,
          work_path,
          health_red_build_fun(%{summary: "red tip"}),
          StaleRefCas
        )

      # The reject path emits telemetry(:reject, %{...}, %{reason: :build_failed,
      # ...}) for the eject (merge_authority.ex:197). Signal on it: by the time
      # it fires synchronously inside M, the durable :rejected row MUST already be
      # WAL-committed (WAL-before-ack) IF the producer records it — mirroring the
      # :merged proof.
      handler_id = "reject-outcome-durable-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:tau, :factory, :merge, :reject],
        fn _event, _measurements, _metadata, _config -> send(test_pid, :reject_fired) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert :queued = MergeAuthority.request_merge(ma, unit)

      assert_receive :reject_fired,
                     5_000,
                     "reject_outcome_durable/d_315: the :reject telemetry projection never fired"

      # The DURABLE assertion: a terminal health-red eject MUST have written a
      # durable {:rejected, _} row for the ejected member. Today the producer
      # writes NO row on the reject path, so this returns :none — the fail-before.
      assert {:rejected, _reason} = LedgerReader.merge_outcome_for(ledger, unit.id),
             "reject_outcome_durable/d_315: a TERMINAL health-red eject MUST record a " <>
               "durable {:rejected, _} merge_outcomes row for the ejected member " <>
               "(WAL-before-ack, D-355 symmetric), readable by the time the :reject " <>
               "telemetry projection fires. merge_outcome_for/2 returned " <>
               "#{inspect(LedgerReader.merge_outcome_for(ledger, unit.id))} — the reject " <>
               "outcome is still ephemeral-only (the asymmetry #466 closes)."
    end

    @tag :d_355
    @tag :d_315
    test "D-355/d_315: after the MergeAuthority dies, the rejected outcome is still in L (RPO=0)" do
      ledger = start_ledger()
      test_pid = self()

      unit = %{
        id: "u-rej-crash-#{System.unique_integer([:positive])}",
        hash: "hash-rej-crash-#{System.unique_integer([:positive])}",
        run: "run-rej-crash-#{System.unique_integer([:positive])}",
        branch: "feat/reject-outcome-crash-#{System.unique_integer([:positive])}"
      }

      {work_path, _tip} = setup_git_repo(unit)

      ma =
        start_merge_authority(
          ledger,
          work_path,
          health_red_build_fun(%{summary: "red tip"}),
          StaleRefCas
        )

      handler_id = "reject-outcome-crash-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:tau, :factory, :merge, :reject],
        fn _event, _measurements, _metadata, _config -> send(test_pid, :reject_fired) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert :queued = MergeAuthority.request_merge(ma, unit)
      assert_receive :reject_fired, 5_000, "the reject never completed"

      # KILL the producer; the durably-supervised Ledger is a different process.
      ma_pid = Process.whereis(ma)
      assert is_pid(ma_pid)
      Process.exit(ma_pid, :kill)

      assert {:rejected, _reason} = LedgerReader.merge_outcome_for(ledger, unit.id),
             "reject_outcome_durable/d_315 (RPO=0): the reject outcome must survive the " <>
               "producer's death. After killing the MergeAuthority, merge_outcome_for/2 " <>
               "returned #{inspect(LedgerReader.merge_outcome_for(ledger, unit.id))} — a " <>
               "non-rejected result means the reject outcome was ephemeral (lost with the " <>
               "producer), not durable."
    end
  end

  # ---------------------------------------------------------------------------
  # ORACLE 2 — Reconcile-on-resume: a durable :rejected → no re-submit.
  #
  # The load-bearing CONSEQUENCE of oracle 1: with a durable :rejected outcome
  # present, a Unit entering :awaiting_merge reconciles to :rejected (its
  # existing arm → re-gate) and does NOT issue a fresh merge_fun call for the
  # already-terminally-rejected member. The durable :rejected row is seeded
  # directly (its production write is oracle 1's responsibility).
  # ---------------------------------------------------------------------------

  describe "D-355 / d_344 — reconcile-on-resume does not re-submit an already-rejected merge" do
    @tag :d_355
    @tag :d_344
    test "D-355/d_344: a Unit reaching :awaiting_merge with a durable :rejected outcome does NOT call merge_fun (no re-submit)" do
      ledger = start_ledger()
      test_pid = self()

      unit_id = "u-resume-rejected-#{System.unique_integer([:positive])}"
      run = "run-resume-rej-#{System.unique_integer([:positive])}"

      sched = unique(:sched_resume_rejected)
      sup = unique(:sup_resume_rejected)
      start_scheduler(sched)
      start_supervised!({@unit_supervisor, name: sup}, id: sup)

      # Seed a DURABLE :rejected outcome — modelling the row a terminal health-red
      # eject leaves behind (oracle 1) before the Unit (resumed) reaches
      # :awaiting_merge.
      {:ok, _} =
        LedgerWriter.record_merge_outcome(ledger, %{
          unit_id: unit_id,
          outcome: :rejected,
          commit_sha: nil,
          reason: :build_failed,
          run: run
        })

      assert {:rejected, :build_failed} = LedgerReader.merge_outcome_for(ledger, unit_id)

      # merge_fun records the unit_id of every call. The already-rejected unit
      # MUST NOT appear — reconcile routes to re-gate, not re-merge (INV-2).
      {:ok, calls} = Agent.start_link(fn -> [] end)
      on_exit(fn -> if Process.alive?(calls), do: Agent.stop(calls) end)

      merge_fun = fn uid, _hash ->
        Agent.update(calls, fn acc -> [uid | acc] end)
        :queued
      end

      # gate_fun signals the re-gate (second gate call) the :rejected reconcile
      # must trigger (INV-2 — a :rejected re-gates at U).
      {:ok, gate_calls} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> if Process.alive?(gate_calls), do: Agent.stop(gate_calls) end)

      regate_signal = test_pid

      gate_fun = fn _coord ->
        n = Agent.get_and_update(gate_calls, fn c -> {c, c + 1} end)
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

      assert_receive :regated,
                     5_000,
                     "reject_outcome_durable/d_344: a Unit whose :rejected outcome is durable " <>
                       "in L must route to re-gate (:gating) on :awaiting_merge entry (INV-2), " <>
                       "not re-call merge_fun"

      :timer.sleep(50)
      recorded = Agent.get(calls, & &1)

      refute unit_id in recorded,
             "reject_outcome_durable/d_344: with a durable :rejected outcome the Unit must " <>
               "re-gate, NOT re-submit the merge. merge_fun was called for #{inspect(unit_id)} " <>
               "(recorded: #{inspect(recorded)}). The :awaiting_merge entry MUST reconcile " <>
               "against merge_outcome_for/2 and skip the re-submit (D-344)."
    end
  end

  # ---------------------------------------------------------------------------
  # ORACLE 3 — Requeue writes nothing (only TERMINAL outcomes are durable).
  #
  # A NON-terminal :stale_ref requeue (cas_push → {:error, :stale_ref}) must NOT
  # write any merge_outcomes row. This refute guards over-recording: the fix MUST
  # distinguish terminal rejects (durable) from requeues (ephemeral).
  # ---------------------------------------------------------------------------

  describe "D-355 — a non-terminal :stale_ref requeue writes NO durable outcome row" do
    @tag :d_355
    test "D-355: a :stale_ref requeue records NO merge_outcomes row (only terminal outcomes are durable)" do
      ledger = start_ledger()
      test_pid = self()

      unit = %{
        id: "u-requeue-#{System.unique_integer([:positive])}",
        hash: "hash-requeue-#{System.unique_integer([:positive])}",
        run: "run-requeue-#{System.unique_integer([:positive])}",
        branch: "feat/reject-outcome-requeue-#{System.unique_integer([:positive])}"
      }

      {work_path, tip} = setup_git_repo(unit)

      # built_build_fun reaches :committing; StaleRefCas: verdicts live but push
      # is rejected with :stale_ref → requeue (non-terminal). The reject telemetry
      # fires with reason: :stale_ref.
      ma = start_merge_authority(ledger, work_path, built_build_fun(tip), StaleRefCas)

      handler_id = "reject-outcome-requeue-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:tau, :factory, :merge, :reject],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:reject_fired, Map.get(metadata, :reason)})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert :queued = MergeAuthority.request_merge(ma, unit)

      assert_receive {:reject_fired, :stale_ref},
                     5_000,
                     "reject_outcome_durable: the :stale_ref requeue telemetry never fired"

      # Give any (erroneous) durable write a chance to land, then assert NONE did.
      :timer.sleep(100)

      assert :none = LedgerReader.merge_outcome_for(ledger, unit.id),
             "reject_outcome_durable: a NON-terminal :stale_ref requeue MUST NOT write a " <>
               "merge_outcomes row (only TERMINAL outcomes are durable). merge_outcome_for/2 " <>
               "returned #{inspect(LedgerReader.merge_outcome_for(ledger, unit.id))} — a " <>
               "requeue was incorrectly recorded as a terminal outcome."
    end
  end

  # ---------------------------------------------------------------------------
  # Drive a Unit forward to :awaiting_merge (mirrors
  # merge_outcome_durability_test.exs).
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
