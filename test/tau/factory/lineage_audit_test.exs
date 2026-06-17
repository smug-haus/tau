defmodule Tau.Factory.LineageAuditTest do
  @moduledoc """
  Gating test for D-353 — Audit traceability = 100% (NFR-AUDIT).

  ## What this enforces

  D-353 (SPEC-FACTORY-GOV §4 B10 / §6 D-353):

  > Every merge is fully traceable along
  > `main_commit → gate_verdicts → gating_test_paths → claims(AC/D-NNN) → specs → issues`
  > with **no null edge**; the `%Lineage{}` row is written in the **same
  > transaction as the merge record** (WAL before the merge ack), so an audit
  > can never observe a merge without its lineage; traceability is a **join
  > over FK edges, not a grep**.

  Current gap (issue #668): `Ledger.Writer.record_merge_outcome/2` writes ONLY
  into `merge_outcomes` — no lineage row, no co-transaction write. The Ledger
  schema has NO tables for gating-test-paths, AC/D-NNN tokens, SPEC refs, or
  issue FKs. `Ledger.Reader` has no lineage join. `Tau.Factory.Lineage` does not
  exist. Every assertion below therefore fails before the implementer lands the
  fix.

  ## Pinned contracts

  The implementer MUST deliver (conforming to SPEC-FACTORY-GOV §4 B10 / §6
  D-353 and docs/arch/04-software-architecture/governance.md §5):

  - `Tau.Factory.Lineage` struct with fields:
    `main_commit`, `unit_id`, `gate_verdicts`, `gating_test_paths`, `claims`,
    `specs`, `issues` — each non-nil, each a non-empty list or non-nil scalar.

  - `Ledger.Writer.record_merge_with_lineage(server, merge_attrs, lineage_attrs)`
    — writes BOTH a `merge_outcomes` row AND a `lineage` row in a **single
    SQLite transaction** (WAL-before-ack; D-315). Returns `{:ok, %{merge_ref:,
    lineage_ref:}}` after the WAL commit is durable.

  - `Ledger.Reader.lineage_for(server, unit_id)` — returns the lineage record
    as `{:ok, %Tau.Factory.Lineage{}}` or `:none`.

  - The lineage schema enforces NOT NULL on every link column; an attempt to
    insert a lineage row with any null edge MUST return `{:error, _}`.

  ## Fail-before validity (oracle separation, factory-loop §4b)

  On THIS branch (no implementer yet):
  - `Tau.Factory.Lineage` does not exist → compile-time `UndefinedFunctionError`.
  - `Ledger.Writer.record_merge_with_lineage/3` does not exist.
  - `Ledger.Reader.lineage_for/2` does not exist.
  - The Ledger schema has no lineage table.

  All three oracles below fail against the current code.

  D-NNN linkage: **D-353** (NFR-AUDIT=100%, lineage co-transaction write).
  Cross-refs: D-315 (WAL-before-ack / RPO=0), INV-16 (same-txn durability).
  """

  use ExUnit.Case, async: true

  alias Tau.Factory.Ledger.Reader, as: LedgerReader
  alias Tau.Factory.Ledger.Writer, as: LedgerWriter

  # Runtime alias only — Tau.Factory.Lineage does not exist until the
  # implementer lands it. Using the module atom directly in assertions avoids
  # a compile-time struct-expansion error while still asserting the struct name.
  @lineage_module Tau.Factory.Lineage

  @moduletag :capture_log
  @moduletag :d_353

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp start_ledger do
    db_path = Briefly.create!(extname: ".db")
    writer_name = :"lineage_audit_ledger_#{System.unique_integer([:positive])}"

    start_supervised!(
      {LedgerWriter, db_path: db_path, name: writer_name},
      id: writer_name
    )

    writer_name
  end

  defp full_lineage_attrs do
    unit_id = "u-lineage-#{System.unique_integer([:positive])}"
    commit = "sha-#{System.unique_integer([:positive])}"

    merge_attrs = %{
      unit_id: unit_id,
      outcome: :merged,
      commit_sha: commit,
      reason: nil,
      run: "run-#{System.unique_integer([:positive])}"
    }

    lineage_attrs = %{
      main_commit: commit,
      unit_id: unit_id,
      gate_verdicts: [
        %{
          half: :critic,
          verdict: :pass,
          diff_hash: "dhash-c-#{System.unique_integer([:positive])}"
        },
        %{
          half: :reviewer,
          verdict: :pass,
          diff_hash: "dhash-r-#{System.unique_integer([:positive])}"
        },
        %{
          half: :mutation,
          verdict: :pass,
          diff_hash: "dhash-m-#{System.unique_integer([:positive])}"
        }
      ],
      gating_test_paths: ["test/tau/factory/lineage_audit_test.exs"],
      claims: ["D-353", "AC-10"],
      specs: ["SPEC-FACTORY-GOV"],
      issues: ["668"]
    }

    {merge_attrs, lineage_attrs}
  end

  # ---------------------------------------------------------------------------
  # ORACLE 1 — Full end-to-end lineage join returns all six links.
  #
  # record_merge_with_lineage/3 writes both rows in one transaction (D-353);
  # lineage_for/2 returns the full %Lineage{} chain with no null edge.
  # ---------------------------------------------------------------------------

  describe "D-353 — record_merge_with_lineage/3 co-writes lineage; lineage_for/2 returns the full chain" do
    @tag :d_353
    test "D-353: lineage_for/2 returns all six links for a recorded merge — commit, verdicts, paths, claims, specs, issues" do
      ledger = start_ledger()
      {merge_attrs, lineage_attrs} = full_lineage_attrs()
      unit_id = merge_attrs.unit_id

      # The real co-transaction entry point — both rows in one WAL commit.
      assert {:ok, %{merge_ref: _, lineage_ref: _}} =
               LedgerWriter.record_merge_with_lineage(ledger, merge_attrs, lineage_attrs),
             "D-353: record_merge_with_lineage/3 must return {:ok, %{merge_ref:, lineage_ref:}} " <>
               "after writing both rows in a single SQLite transaction (WAL-before-ack, D-315)."

      # The join — not a grep, not separate single-table reads.
      # Use a runtime struct-name check rather than a compile-time %Lineage{} pattern
      # so the file compiles even before Tau.Factory.Lineage exists; the assertion
      # still fails (UndefinedFunctionError on lineage_for/2) before the implementer
      # lands the fix.
      lineage_result = LedgerReader.lineage_for(ledger, unit_id)

      assert match?({:ok, _}, lineage_result),
             "D-353: lineage_for/2 must return {:ok, %Lineage{}} for a unit with a recorded " <>
               "merge+lineage. Got: #{inspect(lineage_result)}."

      {:ok, lineage} = lineage_result

      assert lineage.__struct__ == @lineage_module,
             "D-353: lineage_for/2 must return a %Tau.Factory.Lineage{} struct. " <>
               "Got struct: #{inspect(lineage.__struct__)}."

      # Every link is non-nil and non-empty — no null edge.
      assert lineage.main_commit != nil and lineage.main_commit != "",
             "D-353 (NFR-AUDIT): main_commit link is null — null edge violates the lineage chain."

      assert lineage.unit_id == unit_id,
             "D-353: lineage.unit_id must match the unit for which the merge was recorded."

      assert is_list(lineage.gate_verdicts) and lineage.gate_verdicts != [],
             "D-353 (NFR-AUDIT): gate_verdicts link is empty or nil — null edge on the " <>
               "commit→verdicts step."

      # All required halves must be present.
      verdict_halves = Enum.map(lineage.gate_verdicts, & &1.half)

      assert :critic in verdict_halves,
             "D-353 (NFR-AUDIT): gate_verdicts missing :critic half — incomplete verdict coverage."

      assert :reviewer in verdict_halves,
             "D-353 (NFR-AUDIT): gate_verdicts missing :reviewer half — incomplete verdict coverage."

      assert is_list(lineage.gating_test_paths) and lineage.gating_test_paths != [],
             "D-353 (NFR-AUDIT): gating_test_paths link is empty or nil — null edge on the " <>
               "verdicts→paths step."

      assert is_list(lineage.claims) and lineage.claims != [],
             "D-353 (NFR-AUDIT): claims link is empty or nil — null edge on the " <>
               "paths→AC/D-NNN step."

      assert is_list(lineage.specs) and lineage.specs != [],
             "D-353 (NFR-AUDIT): specs link is empty or nil — null edge on the " <>
               "AC/D-NNN→SPEC step."

      assert is_list(lineage.issues) and lineage.issues != [],
             "D-353 (NFR-AUDIT): issues link is empty or nil — null edge on the " <>
               "SPEC→issue step."
    end
  end

  # ---------------------------------------------------------------------------
  # ORACLE 2 — Null-edge rejection: a lineage row with any null link is refused.
  #
  # The Ledger schema enforces NOT NULL on every lineage column. An attempt to
  # insert a lineage row with a null claims field MUST return {:error, _} so
  # the per-cycle reconciliation never observes a partially-linked lineage.
  # ---------------------------------------------------------------------------

  describe "D-353 — null edge on any lineage link is refused by the schema (NFR-AUDIT)" do
    @tag :d_353
    test "D-353: record_merge_with_lineage/3 returns {:error, _} when claims is nil" do
      ledger = start_ledger()
      {merge_attrs, lineage_attrs} = full_lineage_attrs()

      # Inject a null edge — claims missing.
      null_claims_lineage = Map.put(lineage_attrs, :claims, nil)

      assert {:error, _reason} =
               LedgerWriter.record_merge_with_lineage(ledger, merge_attrs, null_claims_lineage),
             "D-353 (NFR-AUDIT): a lineage row with a null claims edge MUST be refused " <>
               "({:error, _}). A null edge would silently break the paths→AC/D-NNN link, " <>
               "making the merge untraceable."
    end

    @tag :d_353
    test "D-353: record_merge_with_lineage/3 returns {:error, _} when gating_test_paths is nil" do
      ledger = start_ledger()
      {merge_attrs, lineage_attrs} = full_lineage_attrs()

      null_paths_lineage = Map.put(lineage_attrs, :gating_test_paths, nil)

      assert {:error, _reason} =
               LedgerWriter.record_merge_with_lineage(ledger, merge_attrs, null_paths_lineage),
             "D-353 (NFR-AUDIT): a lineage row with null gating_test_paths MUST be refused. " <>
               "The verdicts→paths link would be severed."
    end

    @tag :d_353
    test "D-353: record_merge_with_lineage/3 returns {:error, _} when issues is nil" do
      ledger = start_ledger()
      {merge_attrs, lineage_attrs} = full_lineage_attrs()

      null_issues_lineage = Map.put(lineage_attrs, :issues, nil)

      assert {:error, _reason} =
               LedgerWriter.record_merge_with_lineage(ledger, merge_attrs, null_issues_lineage),
             "D-353 (NFR-AUDIT): a lineage row with null issues MUST be refused. " <>
               "The SPEC→issue final link would be severed."
    end
  end

  # ---------------------------------------------------------------------------
  # ORACLE 3 — Same-transaction atomicity: if the lineage write fails, the
  # merge record is NOT committed (no merge without its lineage, D-353 / C210).
  #
  # Supply an invalid lineage (null claims) and assert that the merge_outcome
  # row is also absent — the whole transaction rolls back.
  # ---------------------------------------------------------------------------

  describe "D-353 — same-transaction rollback: a failed lineage write leaves no orphan merge record" do
    @tag :d_353
    test "D-353: after a failed record_merge_with_lineage/3 call, the merge record is NOT in L" do
      ledger = start_ledger()
      {merge_attrs, lineage_attrs} = full_lineage_attrs()
      unit_id = merge_attrs.unit_id

      # Force a lineage-write failure via a null edge.
      null_lineage = Map.put(lineage_attrs, :claims, nil)

      # The co-transaction write MUST fail.
      assert {:error, _} =
               LedgerWriter.record_merge_with_lineage(ledger, merge_attrs, null_lineage),
             "D-353: expected record_merge_with_lineage/3 to return {:error, _} for null claims."

      # The merge record MUST also be absent — the transaction rolled back atomically.
      assert :none = LedgerReader.merge_outcome_for(ledger, unit_id),
             "D-353 (C210 same-transaction): after a failed co-transaction write, the merge " <>
               "record MUST also be absent from L. merge_outcome_for/2 returned " <>
               "#{inspect(LedgerReader.merge_outcome_for(ledger, unit_id))} — the merge was " <>
               "committed without its lineage, creating an audit hole."
    end
  end
end
