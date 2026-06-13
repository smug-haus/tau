defmodule Tau.Factory.MergeResultPubSubTest do
  @moduledoc """
  Gating test for PR #477 — the **emission half** of the D-356 merge-result
  delivery contract (SPEC-FACTORY-MERGE §6 D-356; cross-ref SPEC-FACTORY-CORE
  §4 B6 / §6 D-356).

  ## What this enforces (SPEC-FACTORY-MERGE §6 D-356)

  On every TERMINAL outcome of a train member, the `MergeAuthority` broadcasts
  the authoritative async result over `Phoenix.PubSub` on the shared
  `Tau.PubSub` instance, to the per-PR topic `"factory:pr:\#{id}"`:

    * `{:merge_result, :merged}`   on `cas_push` `:ok`, for every member of the
      train (after the D-355 durable `record_merge_outcome` row — WAL-before-ack);
    * `{:merge_result, :rejected}` on any TERMINAL rejection of a member (a
      verdict-revoked eject is terminal; a mere requeue is NOT and does not
      publish).

  The `[:tau, :factory, :merge, …]` telemetry is a DERIVED observer projection
  (§4 B8), never the control-path delivery; a driver-side telemetry→Unit bridge
  that re-derives the result is FORBIDDEN.

  ## Fail-before validity (oracle separation, factory-loop §4b)

  On THIS branch the `MergeAuthority` emits the merge outcome SOLELY via
  `telemetry(:merged, …)` / `telemetry(:reject, …)` (merge_authority.ex
  `:committing`) and does NOT call `Phoenix.PubSub.broadcast/3`. A test process
  subscribed to `"factory:pr:\#{id}"` therefore receives NOTHING — the
  `assert_receive {:merge_result, _}` below TIMES OUT against the current code.
  A test that passed against the current code would be vacuous.

  This file exercises the REAL `MergeAuthority` (no UnitDriver, no bridge): it
  drives a real `request_merge/2` to a deterministic `:merged` (PassingCas) and
  to a deterministic TERMINAL `:rejected` (RevokingCas → verdict-revoked eject),
  asserting the broadcast lands on the per-PR topic.

  ## D-NNN linkage
    - D-356 — every test in this file.
  """

  use ExUnit.Case, async: false

  alias Tau.Factory.MergeAuthority

  @moduletag :capture_log
  @moduletag :d_356

  # ---------------------------------------------------------------------------
  # Injected CAS seams — drive :committing deterministically without real CAS.
  # The MergeAuthority accepts a `:cas` module (default Tau.Factory.Merge.Cas).
  # ---------------------------------------------------------------------------

  defmodule PassingCas do
    @moduledoc false
    # Verdicts live, push lands → :committing reaches the :merged branch.
    def assert_all_verdicts_live(_ledger, _units, _required_halves), do: :all_pass
    def cas_push(_repo_dir, _tip, _base), do: :ok
  end

  defmodule RevokingCas do
    @moduledoc false
    # A required verdict is revoked at the merge instant → :committing ejects
    # the member with NO push. For a single-member train this is a TERMINAL
    # rejection of that member (not a requeue), so D-356 publishes :rejected.
    def assert_all_verdicts_live(_ledger, [unit | _], _required_halves),
      do: {:revoked, unit}

    def cas_push(_repo_dir, _tip, _base), do: :ok
  end

  defmodule StaleRefCas do
    @moduledoc false
    # Verdicts live, but the CAS push reports a stale ref → :committing takes the
    # `{:error, :stale_ref}` branch, which REQUEUES the train for a rebase + re-gate.
    # A requeue is NOT a terminal outcome: D-356 explicitly does NOT publish a
    # {:merge_result, _} broadcast on a mere requeue (the emission half fires only
    # on a terminal :merged or terminal :rejected).
    def assert_all_verdicts_live(_ledger, _units, _required_halves), do: :all_pass
    def cas_push(_repo_dir, _tip, _base), do: {:error, :stale_ref}
  end

  # ---------------------------------------------------------------------------
  # Helpers (mirror merge_outcome_durability_test.exs / merge_verdict_revoke_test.exs)
  # ---------------------------------------------------------------------------

  defp unique(base), do: :"#{base}_#{System.unique_integer([:positive])}"

  defp start_ledger do
    db_path = Briefly.create!(extname: ".db")
    writer_name = unique(:merge_result_ledger)

    start_supervised!(
      {Tau.Factory.Ledger.Writer, db_path: db_path, name: writer_name},
      id: writer_name
    )

    writer_name
  end

  # A build_fun that returns a built train immediately, carrying the real
  # committed `tip` so the durable outcome's commit_sha is a real oid. `base` is
  # the real origin/main oid M captured (start_build runs `git rev-parse origin/main`).
  defp built_build_fun(tip) do
    fn units, base -> {:built, units, base, tip} end
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

  defp start_merge_authority(ledger, repo_dir, build_fun, cas) do
    ma_name = unique(:merge_result_ma)
    tasks_name = unique(:merge_result_tasks)

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

  defp pr_topic(unit_id), do: "factory:pr:#{unit_id}"

  # ---------------------------------------------------------------------------
  # D-356 emission, MERGED — a completed merge broadcasts {:merge_result, :merged}
  # on the per-PR topic of the shared Tau.PubSub.
  # ---------------------------------------------------------------------------

  describe "D-356 — MergeAuthority broadcasts {:merge_result, :merged} on factory:pr:#id" do
    @tag :d_356
    test "D-356: a real request_merge that lands publishes {:merge_result, :merged} on the per-PR topic" do
      ledger = start_ledger()

      unit = %{
        id: "u-merged-#{System.unique_integer([:positive])}",
        hash: "hash-#{System.unique_integer([:positive])}",
        run: "run-#{System.unique_integer([:positive])}",
        branch: "feat/merge-result-merged-#{System.unique_integer([:positive])}"
      }

      {work_path, tip} = setup_git_repo(unit)
      ma = start_merge_authority(ledger, work_path, built_build_fun(tip), PassingCas)

      # Subscribe to the per-PR topic on the shared Tau.PubSub BEFORE the merge
      # is requested (the same ordering U's consume half relies on, D-356).
      :ok = Phoenix.PubSub.subscribe(Tau.PubSub, pr_topic(unit.id))

      assert :queued = MergeAuthority.request_merge(ma, unit)

      # The authoritative async result MUST arrive as a PubSub broadcast on the
      # per-PR topic — NOT as telemetry only.
      assert_receive {:merge_result, :merged},
                     5_000,
                     "D-356: MergeAuthority must broadcast {:merge_result, :merged} on " <>
                       "#{pr_topic(unit.id)} (shared Tau.PubSub) when a merge lands. " <>
                       "Receiving nothing means the outcome is still telemetry-only — the " <>
                       "control-path delivery (the broadcast) is absent."
    end
  end

  # ---------------------------------------------------------------------------
  # D-356 emission, REJECTED — a TERMINAL rejection broadcasts
  # {:merge_result, :rejected} on the per-PR topic.
  # ---------------------------------------------------------------------------

  describe "D-356 — MergeAuthority broadcasts {:merge_result, :rejected} on a terminal reject" do
    @tag :d_356
    test "D-356: a verdict-revoked eject (terminal reject) publishes {:merge_result, :rejected} on the per-PR topic" do
      ledger = start_ledger()

      unit = %{
        id: "u-rejected-#{System.unique_integer([:positive])}",
        hash: "hash-#{System.unique_integer([:positive])}",
        run: "run-#{System.unique_integer([:positive])}",
        branch: "feat/merge-result-rejected-#{System.unique_integer([:positive])}"
      }

      {work_path, tip} = setup_git_repo(unit)
      # RevokingCas → assert_all_verdicts_live returns {:revoked, unit} → the
      # single-member train is ejected with no push: a TERMINAL rejection (D-356),
      # not a requeue.
      ma = start_merge_authority(ledger, work_path, built_build_fun(tip), RevokingCas)

      :ok = Phoenix.PubSub.subscribe(Tau.PubSub, pr_topic(unit.id))

      assert :queued = MergeAuthority.request_merge(ma, unit)

      assert_receive {:merge_result, :rejected},
                     5_000,
                     "D-356: a TERMINAL rejection (verdict-revoked eject of a single-member " <>
                       "train) must broadcast {:merge_result, :rejected} on #{pr_topic(unit.id)} " <>
                       "(shared Tau.PubSub). Receiving nothing means the reject outcome is still " <>
                       "telemetry-only — the control-path delivery is absent."

      # A terminal reject must NOT also publish :merged on the same topic.
      refute_received {:merge_result, :merged}
    end
  end

  # ---------------------------------------------------------------------------
  # D-356 emission, REQUEUE — a mere requeue (stale-ref CAS / non-health build
  # failure) is NOT terminal and broadcasts NOTHING on the per-PR topic. This is
  # the negative half of the D-356 emission contract: the broadcast fires ONLY on
  # a terminal :merged / :rejected, never on a re-gate requeue.
  # ---------------------------------------------------------------------------

  describe "D-356 — a requeued train member broadcasts NO merge-result on the per-PR topic" do
    @tag :d_356
    test "D-356: a stale-ref CAS requeue (re-gate, not terminal) publishes NO {:merge_result, _} on the per-PR topic" do
      ledger = start_ledger()

      unit = %{
        id: "u-requeue-#{System.unique_integer([:positive])}",
        hash: "hash-#{System.unique_integer([:positive])}",
        run: "run-#{System.unique_integer([:positive])}",
        branch: "feat/merge-result-requeue-#{System.unique_integer([:positive])}"
      }

      {work_path, tip} = setup_git_repo(unit)
      # StaleRefCas → assert_all_verdicts_live :all_pass, then cas_push returns
      # {:error, :stale_ref} → the train is REQUEUED for rebase + re-gate. A
      # requeue is NOT terminal: D-356 must NOT broadcast on the per-PR topic.
      ma = start_merge_authority(ledger, work_path, built_build_fun(tip), StaleRefCas)

      :ok = Phoenix.PubSub.subscribe(Tau.PubSub, pr_topic(unit.id))

      assert :queued = MergeAuthority.request_merge(ma, unit)

      # The stale-ref path requeues (does not push, does not terminally reject).
      # Across the requeue window NO merge-result broadcast may land on the topic —
      # neither :merged nor :rejected. A spurious broadcast here would falsely
      # signal a terminal outcome to a subscribed Unit on a mere re-gate.
      refute_receive {:merge_result, _any},
                     1_500,
                     "D-356: a mere requeue (stale-ref CAS → rebase + re-gate) must broadcast " <>
                       "NOTHING on #{pr_topic(unit.id)}. The emission half fires ONLY on a " <>
                       "terminal :merged / :rejected; a broadcast on requeue would falsely " <>
                       "terminate a subscribed Unit mid-re-gate."
    end
  end
end
