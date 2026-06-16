defmodule Tau.Factory.BudgetRebuildOnRestartTest do
  @moduledoc """
  Gating test for issue #544 — INV-DS-BUDGET-REBUILD.

  Invariant statement:
    On Budget.Owner restart, the ETS snapshot MUST be rebuilt from durable truth
    (Ledger). If any of Exqlite.Sqlite3.prepare/fetch_all/release fails during
    the rebuild query, Owner.init/1 MUST NOT proceed with a silent empty-map
    fallback (`%{}`) — which would overstate available budget. Instead the init
    MUST fail (propagate the error / crash), so the supervisor can either retry
    with the expectation that the DB recovers, or escalate.

  Root cause being guarded against:
    `do_budget_debited/1` in `lib/tau/factory/ledger/writer.ex` has an
    `else`-branch `_ -> %{}` that silently returns an empty map on any DB error.
    `Owner.init/1` assigns this without checking for an error sentinel, then
    populates ETS with `limit - 0 = limit` for every dimension — as if no debits
    exist — and returns `{:ok, state}`. After a restart in which the ledger query
    fails, the Owner starts successfully with a fully-overstated budget snapshot.

  Test strategy:
    1. Start a real Ledger.Writer backed by a Briefly temp DB.
    2. Record debits that exhaust the full token budget (100 of 100).
    3. Stop the Owner but keep the Writer alive.
    4. Open an independent Exqlite connection to the SAME DB file and DROP the
       `budget_debits` table, then close that connection. This causes the Writer's
       next `budget_debited` call to fail at `prepare/2` ("no such table"), which
       triggers the buggy `else -> %{}` branch.
    5. Start a FRESH Budget.Owner (restart scenario). It calls
       `Writer.budget_debited`, gets `%{}` (the bug), and populates ETS as if
       zero debits exist.
    6. Assert that `budget_precheck/2` returns `{:exhausted, :tokens}` — the
       correct answer given 100/100 tokens have been spent and are durably
       recorded in the Ledger (before the table was dropped). Under the bug it
       returns `:ok`, falsifying the invariant.

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

  describe "INV-DS-BUDGET-REBUILD — Owner restart after ledger query failure must NOT overstate budget" do
    @tag :inv_ds_budget_rebuild
    test "INV-DS-BUDGET-REBUILD: fresh Owner after table-drop must not overstate remaining budget" do
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

      # Exhaust the full budget: debit 100 tokens.
      :ok = @owner.debit(writer_name, "unit-rebuild-1", :tokens, 60)
      :ok = @owner.debit(writer_name, "unit-rebuild-2", :tokens, 40)

      # Confirm budget is genuinely exhausted before we simulate the failure.
      assert {:exhausted, :tokens} = @owner.budget_precheck(owner_name, :tokens)

      # Confirm the Ledger records the full 100 tokens spent.
      assert %{tokens: 100} = @writer.budget_debited(writer_name)

      # Stop the Budget.Owner to simulate a crash/restart.
      stop_supervised!(owner_spec_id)

      # -----------------------------------------------------------------------
      # Simulate a ledger DB failure during Owner restart:
      # Open a second Exqlite connection to the same DB file and DROP the
      # budget_debits table. The Writer's subsequent budget_debited call will
      # fail at prepare/2 ("no such table: budget_debits"), triggering the
      # buggy `else -> %{}` branch in do_budget_debited/1.
      # -----------------------------------------------------------------------
      {:ok, conn} = Exqlite.Sqlite3.open(db_path)
      {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, "DROP TABLE IF EXISTS budget_debits")
      :done = Exqlite.Sqlite3.step(conn, stmt)
      :ok = Exqlite.Sqlite3.release(conn, stmt)
      :ok = Exqlite.Sqlite3.close(conn)

      # -----------------------------------------------------------------------
      # Start a FRESH Budget.Owner (the "restart" scenario).
      # Owner.init/1 calls Writer.budget_debited/1; the Writer internally runs
      # do_budget_debited/1; SQLite returns an error ("no such table") and the
      # current code silently returns %{} instead of propagating the error.
      # Owner.init/1 then computes remaining = 100 - 0 = 100 for :tokens and
      # populates ETS accordingly — overstating the available budget.
      #
      # INV-DS-BUDGET-REBUILD requires this to NOT happen. Conformant behaviour:
      #   Either (a) Owner.init/1 returns {:stop, reason} so start_link returns
      #   {:error, ...}, OR (b) if the Owner does start, budget_precheck must
      #   still return {:exhausted, :tokens} because the durable truth (100/100
      #   spent) must be honoured.
      #
      # Under the current BUG: start_supervised! succeeds and budget_precheck
      # returns :ok — wrong answer; this assertion will fail, confirming the
      # invariant is violated.
      # -----------------------------------------------------------------------
      start_supervised!(
        {@owner, ledger: writer_name, totals: %{tokens: 100}, name: owner_name},
        id: owner_spec_id
      )

      # The budget is fully spent (100/100). A correctly-rebuilt snapshot must
      # deny further admission. The bug causes this to return :ok (wrong).
      assert {:exhausted, :tokens} = @owner.budget_precheck(owner_name, :tokens)
    end
  end
end
