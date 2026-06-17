defmodule Tau.Factory.InvLineageAtomicTest do
  @moduledoc """
  Gating test for INV-LINEAGE-ATOMIC.

  ## Invariant statement (issue #550)

  > A lineage record must be written in the same transaction as the merge
  > record (WAL before merge ack). No merge commit may be observable in the
  > ledger without its complete lineage record. Falsified if a merge commit
  > exists in the ledger without a corresponding complete lineage record.

  ## What this enforces

  SPEC-FACTORY-GOV §4 B10 / C210:

  > A merge record written **without** its lineage row is an audit hole
  > (C210-B10, NFR-AUDIT=100%). The lineage MUST be written in the *same
  > transaction* as the merge record (WAL before ack, D-353; INV-16/RPO=0).

  The invariant is violated at the **real user-facing write path**: all four
  `MergeAuthority` merge-record write sites (`merge_authority.ex` lines 245,
  322, 360, 553) call `LedgerWriter.record_merge_outcome/2` — which writes
  ONLY into `merge_outcomes` with no paired lineage row. After such a call,
  `LedgerReader.lineage_for/2` returns `:none` for the same unit, proving a
  merge commit is observable in L without its lineage.

  ## Boundary under test

  `LedgerWriter.record_merge_outcome/2` is the boundary this invariant
  governs: it is the entry point MergeAuthority actually calls at every
  merge-record write site. The oracles below call this function (the real
  production path) and assert that no merge is observable without a lineage
  record.

  ## Fail-before validity (oracle separation, factory-loop §4b)

  On the current branch (no implementer yet):

  - `LedgerWriter.record_merge_outcome/2` exists and inserts a `merge_outcomes`
    row without any lineage row (confirmed: `do_record_merge_outcome/2` at
    writer.ex lines 688-712 is a bare single INSERT, no BEGIN/COMMIT, no
    lineage insert).
  - After the call, `LedgerReader.lineage_for/2` returns `:none` — the merge
    is observable in L with no lineage, directly falsifying INV-LINEAGE-ATOMIC.
  - ORACLE 1 therefore fails: it asserts `lineage_for/2` does NOT return
    `:none`, but it does.
  - ORACLE 2 asserts `record_merge_outcome/2` returns `{:error, _}` when
    called without lineage attrs (or that it is replaced by a new API
    requiring lineage attrs). The current implementation returns `{:ok, ref}`,
    so ORACLE 2 also fails.

  D-NNN linkage: **D-353** (same-txn lineage co-write, NFR-AUDIT=100%).
  Cross-refs: INV-16 (durable factory state / RPO=0), issue #550, issue #668.
  """

  use ExUnit.Case, async: true

  alias Tau.Factory.Ledger.Reader, as: LedgerReader
  alias Tau.Factory.Ledger.Writer, as: LedgerWriter

  @moduletag :capture_log
  @moduletag :inv_lineage_atomic

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp start_ledger do
    db_path = Briefly.create!(extname: ".db")
    writer_name = :"inv_lineage_atomic_ledger_#{System.unique_integer([:positive])}"

    start_supervised!(
      {LedgerWriter, db_path: db_path, name: writer_name},
      id: writer_name
    )

    writer_name
  end

  defp merge_outcome_attrs(unit_id) do
    %{
      unit_id: unit_id,
      outcome: :merged,
      commit_sha: "sha-#{System.unique_integer([:positive])}",
      reason: nil,
      run: "run-#{System.unique_integer([:positive])}"
    }
  end

  # ---------------------------------------------------------------------------
  # ORACLE 1 — No merge commit is observable without its complete lineage.
  #
  # Calls `record_merge_outcome/2` (the path MergeAuthority uses at ALL four
  # merge-record write sites) and asserts that a lineage record is immediately
  # queryable via `lineage_for/2`. On the current branch this fails: the merge
  # row is written but `lineage_for/2` returns `:none` — a merge commit is
  # observable in L without lineage, directly falsifying INV-LINEAGE-ATOMIC.
  # ---------------------------------------------------------------------------

  describe "INV-LINEAGE-ATOMIC — no merge observable in L without its lineage" do
    @tag :inv_lineage_atomic
    test "INV-LINEAGE-ATOMIC: after record_merge_outcome/2, lineage_for/2 returns a non-none record" do
      ledger = start_ledger()
      unit_id = "u-inv-lineage-atomic-#{System.unique_integer([:positive])}"
      attrs = merge_outcome_attrs(unit_id)

      # This is the REAL entry point MergeAuthority calls (merge_authority.ex
      # lines 245, 322, 360, 553). INV-LINEAGE-ATOMIC requires that every merge
      # record write is co-transactional with a lineage record. Either:
      #   (a) `record_merge_outcome/2` is updated to require and write lineage
      #       atomically, OR
      #   (b) MergeAuthority is updated to call `record_merge_with_lineage/3`
      #       instead, and `record_merge_outcome/2` without lineage is rejected.
      # In EITHER case, a successful `record_merge_outcome/2` call MUST have a
      # corresponding lineage row immediately visible in L.
      {:ok, _ref} = LedgerWriter.record_merge_outcome(ledger, attrs)

      lineage_result = LedgerReader.lineage_for(ledger, unit_id)

      refute lineage_result == :none,
             "INV-LINEAGE-ATOMIC: record_merge_outcome/2 wrote a merge record for unit " <>
               "#{unit_id} but lineage_for/2 returned :none — a merge commit is observable " <>
               "in L without its lineage record, directly falsifying INV-LINEAGE-ATOMIC " <>
               "(SPEC-FACTORY-GOV §4 B10 / C210). Every merge-record write MUST be " <>
               "co-transactional with a lineage row (WAL-before-ack, D-353, INV-16/RPO=0). " <>
               "Got: #{inspect(lineage_result)}"

      assert match?({:ok, _}, lineage_result),
             "INV-LINEAGE-ATOMIC: lineage_for/2 must return {:ok, %Lineage{}} for unit " <>
               "#{unit_id} immediately after record_merge_outcome/2 succeeds. " <>
               "Got: #{inspect(lineage_result)}"
    end

    @tag :inv_lineage_atomic
    test "INV-LINEAGE-ATOMIC: a rejected merge via record_merge_outcome/2 also has a lineage record" do
      # The invariant applies to ALL merge outcomes, not just :merged.
      # merge_authority.ex line 245 writes :rejected outcomes through the same
      # `record_merge_outcome/2` path. The audit must cover rejections too.
      ledger = start_ledger()
      unit_id = "u-inv-lineage-atomic-rej-#{System.unique_integer([:positive])}"

      rejected_attrs = %{
        unit_id: unit_id,
        outcome: :rejected,
        commit_sha: nil,
        reason: :build_failed,
        run: "run-#{System.unique_integer([:positive])}"
      }

      {:ok, _ref} = LedgerWriter.record_merge_outcome(ledger, rejected_attrs)

      lineage_result = LedgerReader.lineage_for(ledger, unit_id)

      refute lineage_result == :none,
             "INV-LINEAGE-ATOMIC: record_merge_outcome/2 wrote a :rejected merge record for " <>
               "unit #{unit_id} but lineage_for/2 returned :none — no lineage for a rejection " <>
               "outcome violates INV-LINEAGE-ATOMIC (every merge write must be co-transactional " <>
               "with a lineage row). Got: #{inspect(lineage_result)}"
    end
  end

  # ---------------------------------------------------------------------------
  # ORACLE 2 — `record_merge_outcome/2` without lineage attrs is rejected.
  #
  # The correct fix must make calling `record_merge_outcome/2` alone (without
  # paired lineage) return {:error, _} — since any successful return would
  # produce a merge observable without lineage in L. On the current branch
  # `record_merge_outcome/2` returns {:ok, ref}, so this oracle fails.
  # ---------------------------------------------------------------------------

  describe "INV-LINEAGE-ATOMIC — lone record_merge_outcome/2 (no lineage) is rejected" do
    @tag :inv_lineage_atomic
    test "INV-LINEAGE-ATOMIC: record_merge_outcome/2 alone (without lineage) returns {:error, _}" do
      ledger = start_ledger()
      unit_id = "u-inv-lineage-atomic-lone-#{System.unique_integer([:positive])}"
      attrs = merge_outcome_attrs(unit_id)

      # INV-LINEAGE-ATOMIC: the only correct implementation is one where calling
      # `record_merge_outcome/2` WITHOUT paired lineage attrs is rejected — since
      # any successful return would produce a merge without lineage in L.
      # Expected post-fix: {:error, :lineage_required} | {:error, {:lineage_required, _}}
      # On the current branch, `record_merge_outcome/2` returns {:ok, ref},
      # so this assert fails.
      result = LedgerWriter.record_merge_outcome(ledger, attrs)

      assert match?({:error, _}, result),
             "INV-LINEAGE-ATOMIC: record_merge_outcome/2 without lineage attrs MUST return " <>
               "{:error, _} (e.g. {:error, :lineage_required}) to prevent any merge write " <>
               "from succeeding without its paired lineage row. On the current branch this " <>
               "returns {:ok, ref} — a merge row is written to L with no lineage, directly " <>
               "falsifying INV-LINEAGE-ATOMIC. Got: #{inspect(result)}"
    end
  end
end
