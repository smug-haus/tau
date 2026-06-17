defmodule Tau.Factory.BudgetRebuildOnRestartTest do
  @moduledoc """
  Gating test for issue #544 — INV-DS-BUDGET-REBUILD.

  Invariant statement:
    On Budget.Owner restart, the ETS snapshot MUST be rebuilt from durable truth
    (Ledger). If any of Exqlite.Sqlite3.prepare/fetch_all/release fails during
    the rebuild query, Owner.init/1 MUST propagate the error — returning
    `{:stop, reason}` so that `start_link` returns `{:error, reason}`. The
    supervisor then decides whether to retry (expecting the DB to recover) or
    escalate. Starting with a silent conservative default (`remaining = 0`)
    conceals the failure from the supervisor and violates the invariant by NOT
    rebuilding from durable truth.

  Root cause being guarded against:
    Two variants of the bug are guarded simultaneously:
    a) `do_budget_debited/1` swallows DB errors with `else _ -> %{}` AND
       `Owner.init/1` assigns this directly — Owner starts with `remaining = limit`
       (overstated budget).
    b) `do_budget_debited/1` returns `{:error, reason}` BUT `Owner.init/1`
       silently maps it to a conservative default (`remaining = 0`) — Owner starts
       without error, hiding the DB failure from its supervisor.

  Both variants violate INV-DS-BUDGET-REBUILD. The correct behaviour is (c):
    `Owner.init/1` MUST return `{:stop, {:budget_rebuild_failed, reason}}` on any
    `{:error, reason}` from `Writer.budget_debited/1`, so `start_link` returns
    `{:error, {:budget_rebuild_failed, reason}}`.

  Test strategy:
    1. Start a real Ledger.Writer backed by a Briefly temp DB.
    2. Record a partial debit (60 of 100 tokens). Budget is NOT exhausted.
    3. Stop the Budget.Owner but keep the Writer alive (the DB file remains).
    4. Open an independent Exqlite connection to the SAME DB file and DROP the
       `budget_debits` table, then close that connection.
    5. Attempt to start a FRESH Budget.Owner (the "restart" scenario).
       `Owner.init/1` calls `Writer.budget_debited/1`; the Writer encounters
       "no such table" and returns `{:error, reason}`.
    6. Assert that `start_supervised` (without `!`) returns `{:error, _}` —
       the Owner MUST NOT start when durable truth is unavailable, regardless of
       whether it would overstate or understate the budget.

  Why the conservative-default (variant B) also fails this test:
    The current production code (variant B) maps `{:error, reason}` to
    `remaining = 0` and returns `{:ok, state}`. This causes `start_supervised`
    to return `{:ok, pid}`, not `{:error, _}`. The assertion below
    fails: `{:ok, pid} != {:error, _}`. The test correctly identifies that the
    Owner is hiding a DB failure from its supervisor, violating INV-DS-BUDGET-REBUILD.

  AC / D-NNN linkage: INV-DS-BUDGET-REBUILD (#544)
  """

  use ExUnit.Case, async: true

  @moduletag :inv_ds_budget_rebuild
  @moduletag :capture_log

  @writer Tau.Factory.Ledger.Writer
  @owner Tau.Factory.Budget.Owner

  # ---------------------------------------------------------------------------
  # INV-DS-BUDGET-REBUILD
  # ---------------------------------------------------------------------------

  describe "INV-DS-BUDGET-REBUILD — Owner.init/1 must propagate ledger query failure, not hide it" do
    @tag :inv_ds_budget_rebuild
    test "INV-DS-BUDGET-REBUILD: Owner start_link returns {:error,_} when budget_debited fails — must not start with conservative default" do
      db_path = Briefly.create!(extname: ".db")
      uid = System.unique_integer([:positive])
      writer_name = :"test_rebuild_writer_#{uid}"
      owner_name = :"test_rebuild_owner_#{uid}"
      owner_spec_id = :"rebuild_owner_#{uid}"

      # Start a real Ledger.Writer.
      start_supervised!(
        {@writer, db_path: db_path, name: writer_name},
        id: :"rebuild_writer_#{uid}"
      )

      # Start the initial Budget.Owner with a 100-token budget.
      start_supervised!(
        {@owner, ledger: writer_name, totals: %{tokens: 100}, name: owner_name},
        id: owner_spec_id
      )

      # Partially debit: 60 of 100 tokens. Budget is NOT exhausted (40 remain).
      :ok = @owner.debit(writer_name, "unit-rebuild-1", :tokens, 60)

      # Confirm 40 tokens remain (not exhausted).
      assert :ok = @owner.budget_precheck(owner_name, :tokens)

      # Confirm durable record: 60 tokens written to Ledger.
      assert %{tokens: 60} = @writer.budget_debited(writer_name)

      # Stop the Budget.Owner to simulate a crash/restart.
      stop_supervised!(owner_spec_id)

      # -----------------------------------------------------------------------
      # Simulate a ledger DB failure BEFORE the Owner restarts:
      # Open a second Exqlite connection to the same DB file and DROP the
      # budget_debits table. The Writer's next budget_debited call will fail at
      # prepare/2 ("no such table: budget_debits").
      # -----------------------------------------------------------------------
      {:ok, conn} = Exqlite.Sqlite3.open(db_path)
      {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, "DROP TABLE IF EXISTS budget_debits")
      :done = Exqlite.Sqlite3.step(conn, stmt)
      :ok = Exqlite.Sqlite3.release(conn, stmt)
      :ok = Exqlite.Sqlite3.close(conn)

      # -----------------------------------------------------------------------
      # INV-DS-BUDGET-REBUILD: attempt to start a FRESH Budget.Owner.
      #
      # `Owner.init/1` MUST return `{:stop, reason}` when `Writer.budget_debited/1`
      # returns `{:error, reason}`, propagating the failure to the supervisor.
      #
      # Two bugs are guarded:
      #   Bug A (merge-base): `else _ -> %{}` -> debited = %{} -> remaining = 100
      #     (overstated). `start_supervised` succeeds -> `{:ok, pid}`. FAIL.
      #   Bug B (current code): `{:error, _}` -> conservative remaining = 0.
      #     `start_supervised` STILL succeeds -> `{:ok, pid}`. FAIL.
      #     The DB failure is hidden from the supervisor; the Owner starts silently
      #     with incorrect (zero) remaining even though 40 tokens are genuinely
      #     available, and the supervisor never gets a signal to retry or escalate.
      #
      # Conformant behaviour: `start_supervised` returns `{:error, _}`.
      # -----------------------------------------------------------------------
      result =
        start_supervised(
          {@owner, ledger: writer_name, totals: %{tokens: 100}, name: owner_name},
          id: owner_spec_id
        )

      assert {:error, _} = result,
             "INV-DS-BUDGET-REBUILD: Budget.Owner must not start when " <>
               "the ledger rebuild query fails. Got: #{inspect(result)}. " <>
               "Owner.init/1 must return {:stop, reason} so that the supervisor " <>
               "receives the failure and can retry or escalate."
    end
  end
end
