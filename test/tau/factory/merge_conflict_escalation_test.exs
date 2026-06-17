defmodule Tau.Factory.MergeConflictEscalationTest do
  @moduledoc """
  Gating test for issue #616 — invariant LIVE-liveness-5.

  ## Invariant (LIVE-liveness-5)

  `E-CONFLICT` escalation fires for any unresolvable merge conflict the
  system cannot mechanically reconcile. Falsified by: the coordinator
  attempting a forced or speculative merge past an unresolvable conflict.

  ## What this enforces (SPEC-FACTORY-MERGE.md §5 "Escalation reasons M raises"
  and SPEC-FACTORY-CORE.md §6 D-317 / liveness.md §E-CONFLICT)

  When the Merge Authority's build step encounters an unresolvable git
  rebase conflict (`{:build_failed, {:git_conflict, _}}`), the system
  MUST:

    1. Detect the conflict as a distinct, non-retryable failure — NOT fold
       it into the D-394 bounded-retry climb (which applies to transient
       build errors, not permanent conflict failures).
    2. Signal the conflict to the Unit FSM so U can raise `E-CONFLICT`
       (SPEC-FACTORY-CORE D-317; "unresolvable merge conflict" → per-unit
       escalation). Per SPEC-FACTORY-MERGE §5: "E-CONFLICT (unresolvable
       rebase) is raised by U on a rejected/looping rebase, not by M".
    3. Specifically: M MUST broadcast `{:merge_result, {:conflict, _}}` on
       the per-PR PubSub topic so U can pattern-match it and escalate
       `:"E-CONFLICT"` instead of re-gating (INV-2 `:rejected` path).

  The `report_to` field on the Unit receives:

      {:unit_terminal, unit_id, :escalated, %{reason: :"E-CONFLICT"}}

  and NOT:

      {:unit_terminal, unit_id, :escalated, %{reason: :E_MERGE_STALLED}}

  which is what the CURRENT code produces (the conflict is folded into the
  D-394 retry climb, exhausted retries broadcast `{:merge_result, :rejected}`,
  U re-gates, gate passes, merge_fun is called again, loop continues until
  state_timeout fires `:E_MERGE_STALLED` rather than `:"E-CONFLICT"`).

  ## Fail-before validity (oracle separation, factory-loop §4b)

  Against the CURRENT code:

  - `bounded_retry_or_eject/2` handles `{:git_conflict, _}` as a generic
    `_other` retryable failure (merge_authority.ex:440-442).
  - After `build_retry_max` failures MA broadcasts `{:merge_result, :rejected}`.
  - U pattern-matches `:rejected` → re-gates (INV-2 path, unit.ex:635-639).
  - With `gate_fun` always returning `:pass`, U loops back to `awaiting_merge`,
    calls `merge_fun` again, triggers another set of MA retries.
  - Eventually U's `state_timeout` fires `:E_MERGE_STALLED`, not `:"E-CONFLICT"`.
  - The final assertion (`reason: :"E-CONFLICT"`) FAILS against the current code.
  - The intermediate assertion for `{:merge_result, {:conflict, _}}` confirms MA
    is NOT emitting the distinct conflict signal.

  ## D-NNN / AC linkage
    - LIVE-liveness-5 (issue #616)
    - SPEC-FACTORY-MERGE §5 (E-CONFLICT escalation)
    - SPEC-FACTORY-CORE D-317 (total escalation set)
  """

  use ExUnit.Case, async: false

  alias Tau.Factory.Ledger.Writer, as: LedgerWriter
  alias Tau.Factory.MergeAuthority
  alias Tau.Factory.UnitSupervisor

  @moduletag :capture_log
  @moduletag :"LIVE-liveness-5"

  @scheduler Tau.Factory.Scheduler
  @unit_supervisor UnitSupervisor

  # ---------------------------------------------------------------------------
  # CAS seam — always passes (we never reach the CAS push for a conflict)
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
    writer_name = unique(:conflict_ledger)
    start_supervised!({LedgerWriter, db_path: db_path, name: writer_name}, id: writer_name)
    writer_name
  end

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
    ma_name = unique(:conflict_ma)
    tasks_name = unique(:conflict_tasks)

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

  defp empty_scope do
    %{
      deps: [],
      files: MapSet.new(),
      codepoints: MapSet.new(),
      specs: MapSet.new(),
      resources: MapSet.new()
    }
  end

  defp spawn_worker do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp pr_topic(unit_id), do: "factory:pr:#{unit_id}"

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

  defp make_unit do
    idx = System.unique_integer([:positive])

    %{
      id: "u-conflict-#{idx}",
      hash: "hash-conflict-#{idx}",
      run: "run-conflict-#{idx}",
      branch: "feat/conflict-#{idx}"
    }
  end

  # ---------------------------------------------------------------------------
  # LIVE-liveness-5 — E-CONFLICT escalation on unresolvable rebase conflict
  #
  # Inject a build_fun returning {:build_failed, {:git_conflict, output}}.
  # The system MUST:
  #   (a) Detect the conflict as non-retryable (NOT fold into D-394 retry climb).
  #   (b) Broadcast {:merge_result, {:conflict, _}} on the per-PR PubSub topic.
  #   (c) The Unit receives it and escalates :"E-CONFLICT" (not :E_MERGE_STALLED).
  # ---------------------------------------------------------------------------

  describe "LIVE-liveness-5 — E-CONFLICT escalation on unresolvable rebase conflict" do
    @tag :"LIVE-liveness-5"
    test "LIVE-liveness-5: a git_conflict build failure must escalate E-CONFLICT, not fold into D-394 retry or stall" do
      ledger = start_ledger()
      unit = make_unit()
      {work_path, _tip} = setup_git_repo(unit)

      # Build fun simulating an unresolvable git rebase conflict.
      # {:git_conflict, _} is the designated conflict-failure shape per
      # SPEC-FACTORY-MERGE §5: M must distinguish it from a transient
      # {:git_error, _} (which is retryable under D-394).
      conflict_output = "CONFLICT (content): Merge conflict in README\nAutomatic merge failed"

      build_fun = fn _units, _base ->
        {:build_failed, {:git_conflict, conflict_output}}
      end

      sched = unique(:sched_conflict)
      sup = unique(:sup_conflict)
      start_supervised!({@scheduler, name: sched, w_cap: 10}, id: sched)
      start_supervised!({@unit_supervisor, name: sup}, id: sup)

      # Short state_timeout on the Unit so a stall-based failure (the buggy path)
      # resolves within the test window rather than blocking for the default 30 s.
      # Correct behaviour fires E-CONFLICT well within this budget.
      unit_state_timeout_ms = 3_000

      # Small build_backoff_ms for test speed; default build_retry_max=3 applies.
      ma = start_merge_authority(ledger, work_path, build_fun, build_backoff_ms: 50)

      # Subscribe to the per-PR PubSub topic to observe what MA broadcasts.
      :ok = Phoenix.PubSub.subscribe(Tau.PubSub, pr_topic(unit.id))

      merge_fun = fn _uid, _hash ->
        MergeAuthority.request_merge(ma, unit)
      end

      unit_opts = [
        unit_id: unit.id,
        declared_scope: empty_scope(),
        hash: unit.hash,
        scheduler: sched,
        report_to: self(),
        pubsub: Tau.PubSub,
        worker_fun: fn _role -> {:ok, spawn_worker()} end,
        gate_fun: fn _coord -> :pass end,
        merge_fun: merge_fun,
        timeouts: [state_timeout_ms: unit_state_timeout_ms]
      ]

      unit_pid = @unit_supervisor.start_unit(sup, unit_opts)
      assert is_pid(unit_pid)

      # Drive oracle → implementing → gating(:pass) → awaiting_merge.
      # On awaiting_merge entry the Unit calls merge_fun → MA triggers build_fun.
      drive_to_awaiting_merge(unit_pid)

      # (b) MA MUST broadcast {:merge_result, {:conflict, _}} on the per-PR topic.
      #
      # CURRENT CODE FAILS HERE: merge_authority.ex:440-442 routes {:git_conflict, _}
      # via the _other catch-all to bounded_retry_or_eject, which after N_build=3
      # exhaustion broadcasts {:merge_result, :rejected} — NOT {:merge_result,
      # {:conflict, _}}. The assertion below therefore fails.
      assert_receive {:merge_result, {:conflict, _conflict_details}},
                     4_000,
                     "LIVE-liveness-5: MergeAuthority did NOT broadcast " <>
                       "{:merge_result, {:conflict, _}} on topic #{pr_topic(unit.id)} " <>
                       "after a {:build_failed, {:git_conflict, _}} from the build_fun. " <>
                       "Per SPEC-FACTORY-MERGE §5, an unresolvable rebase conflict must be " <>
                       "broadcast as {:merge_result, {:conflict, _}} — not {:merge_result, :rejected} " <>
                       "— so the Unit can escalate :'E-CONFLICT' rather than re-gating (INV-2). " <>
                       "Current code folds git_conflict into the D-394 bounded-retry climb " <>
                       "(merge_authority.ex:440-442 _other clause) and eventually broadcasts " <>
                       "{:merge_result, :rejected}, driving a silent INV-2 re-gate loop that " <>
                       "ends only on :state_timeout with :E_MERGE_STALLED."

      # (c) The Unit MUST reach :escalated with reason :"E-CONFLICT".
      #
      # CURRENT CODE ALSO FAILS HERE (secondary): even if (b) were fixed but U had
      # no :"E-CONFLICT" clause, U would loop on re-gates or time out with
      # :E_MERGE_STALLED. Either way the reason would not be :"E-CONFLICT".
      assert_receive {:unit_terminal, unit_id, :escalated, provenance},
                     4_000,
                     "LIVE-liveness-5: Unit did NOT reach terminal :escalated within the " <>
                       "allowed window after {:merge_result, {:conflict, _}} was broadcast. " <>
                       "The Unit FSM must handle {:merge_result, {:conflict, _}} in awaiting_merge " <>
                       "and escalate :'E-CONFLICT' immediately — not re-gate (INV-2) or stall."

      assert unit_id == unit.id,
             "LIVE-liveness-5: wrong unit_id in terminal report " <>
               "(expected #{unit.id}, got #{unit_id})"

      assert provenance.reason == :"E-CONFLICT",
             "LIVE-liveness-5: Unit escalated with reason #{inspect(provenance.reason)}, " <>
               "not :'E-CONFLICT'. Per SPEC-FACTORY-CORE D-317 and SPEC-FACTORY-MERGE §5, " <>
               "an unresolvable merge conflict MUST map to the :'E-CONFLICT' escalation code, " <>
               "not :E_MERGE_STALLED (state_timeout) or :E_MERGE_STALLED or any other reason. " <>
               "Likely cause: MergeAuthority routes {:git_conflict, _} through D-394 " <>
               "bounded-retry rather than as a distinct non-retryable conflict failure that " <>
               "broadcasts {:merge_result, {:conflict, _}} to the per-PR topic."

      # Guard: no stall-based escalation alongside the E-CONFLICT.
      refute_received {:unit_terminal, ^unit_id, :escalated, %{reason: :E_MERGE_STALLED}},
                      "LIVE-liveness-5: :E_MERGE_STALLED (state_timeout) arrived alongside " <>
                        ":'E-CONFLICT'. The conflict signal must arrive before the Unit's " <>
                        "state_timeout fires — a stall-based escalation indicates the conflict " <>
                        "broadcast was too slow or never emitted."
    end
  end
end
