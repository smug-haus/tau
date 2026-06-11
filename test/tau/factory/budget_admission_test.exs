defmodule Tau.Factory.BudgetAdmissionTest do
  @moduledoc """
  Gating tests for PR #439 (P4b1-Budget) — AC-4 / D-320 / D-332 / D-315.

  Verifies:
    - D-320: hard pre-admission ceiling (budget_precheck denies at/after ceiling).
    - D-332: budget conservation (Σ debits == total − remaining at all points;
             debits are append-only; duplicate (unit_id, dimension) pairs both persist).
    - D-315: durability / rebuild from L (Budget.Owner restart rebuilds snapshot
             from Ledger truth; persisted debits survive projection loss).

  Written BEFORE production code exists (oracle-separation phase, factory-loop §4b).
  Tests fail at runtime (UndefinedFunctionError / FunctionClauseError) until the
  implementer creates:
    - `lib/tau/factory/budget/owner.ex` (Tau.Factory.Budget.Owner — wholly absent)
    - `lib/tau/factory/ledger/writer.ex` extended with `debit_budget/4` and
      `budget_debited/1` (Tau.Factory.Ledger.Writer already exists; new functions
      will raise UndefinedFunctionError until added)

  ## Pinned API contract (implementer must conform exactly)

  ### Tau.Factory.Ledger.Writer extensions (new functions on existing GenServer)

    - `debit_budget(writer, unit_id, dimension, cost) :: {:ok, ref}`
        Appends a budget-debit row (append-only; no UPDATE/DELETE).
        WAL-before-ack: ack arrives only after the durable SQLite WAL commit.
        `unit_id` is a string; `dimension` is an atom (e.g. `:tokens`);
        `cost` is a non-negative integer.
        Multiple calls with the same `(unit_id, dimension)` each append a separate
        row — there is no upsert/merge; every call is independently durable.

    - `budget_debited(writer) :: %{atom() => non_neg_integer()}`
        Returns a map of `%{dimension => total_cost}` by summing all recorded
        debit rows per dimension. Used by Budget.Owner.init/1 to rebuild the
        ETS snapshot from Ledger truth.

  ### Tau.Factory.Budget.Owner (new GenServer; wholly absent before this PR)

    - `start_link(opts) :: GenServer.on_start()`
        Required options:
          `:ledger`  — writer ref (pid or registered name).
          `:totals`  — `%{atom() => non_neg_integer()}` — per-dimension budget limits.
          `:name`    — registered name for the GenServer process.
        `init/1` reads `totals` + calls `Ledger.Writer.budget_debited/1` to obtain
        the current Σ spend per dimension, then creates a `read_concurrency: true`
        ETS table named after the process's registered name. The ETS table stores
        `{dimension, remaining}` tuples where `remaining = limit - spent`.

    - `budget_precheck(server_name, dimension) :: :ok | {:exhausted, dimension}`
        Reads the ETS table DIRECTLY by the registered name (the table is named
        by the atom given as `:name` at start_link time). Does NOT issue a
        GenServer.call — bypasses the owner's mailbox. Returns `:ok` if remaining
        > 0 for the dimension, `{:exhausted, dimension}` otherwise.
        NOTE: the ETS table name IS the `:name` option passed to start_link.

    - `debit(server, unit_id, dimension, cost) :: :ok`
        1. Calls `Ledger.Writer.debit_budget(ledger, unit_id, dimension, cost)`
           first (WAL-before-ack; Ledger is truth).
        2. Then decrements the ETS snapshot: `remaining' = max(0, remaining - cost)`.

  AC linkage: AC-4 / D-320 / D-332 / D-315.
  """

  use ExUnit.Case, async: true

  @moduletag :ac_4
  @moduletag :d_320
  @moduletag :d_332
  @moduletag :d_315
  @moduletag :capture_log

  # Runtime module references — file compiles even when modules do not yet exist.
  # Using @mod attributes avoids alias-time resolution and compile-time crashes.
  @writer Tau.Factory.Ledger.Writer
  @owner Tau.Factory.Budget.Owner

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Start an isolated Ledger.Writer and Budget.Owner pair backed by a tmp DB.
  # Returns {writer_name, owner_name} so tests can reference them.
  defp start_isolated_pair(totals) do
    db_path = Briefly.create!(extname: ".db")
    uid = System.unique_integer([:positive])
    writer_name = :"test_budget_writer_#{uid}"
    owner_name = :"test_budget_owner_#{uid}"

    start_supervised!(
      {@writer, db_path: db_path, name: writer_name},
      id: :"writer_#{uid}"
    )

    start_supervised!(
      {@owner, ledger: writer_name, totals: totals, name: owner_name},
      id: :"owner_#{uid}"
    )

    {writer_name, owner_name}
  end

  # ---------------------------------------------------------------------------
  # D-320 — hard pre-admission ceiling
  # ---------------------------------------------------------------------------

  describe "AC-4 / D-320 — budget_precheck denies admission at the ceiling" do
    @tag :d_320
    test "AC-4 / D-320: precheck returns :ok while headroom remains, {:exhausted, dim} at ceiling" do
      totals = %{tokens: 100}
      {writer_name, owner_name} = start_isolated_pair(totals)

      # Headroom intact initially.
      assert :ok = @owner.budget_precheck(owner_name, :tokens)

      # Debit up to 99 — still headroom.
      :ok = @owner.debit(writer_name, "unit-1", :tokens, 50)
      :ok = @owner.debit(writer_name, "unit-2", :tokens, 49)

      assert :ok = @owner.budget_precheck(owner_name, :tokens)

      # Debit the final token — exactly at ceiling (remaining becomes 0).
      :ok = @owner.debit(writer_name, "unit-3", :tokens, 1)

      # At or past the ceiling: admission must be denied.
      assert {:exhausted, :tokens} = @owner.budget_precheck(owner_name, :tokens)
    end

    @tag :d_320
    test "AC-4 / D-320: overrun is bounded — recorded spend does not exceed ceiling by more than one in-flight action" do
      totals = %{tokens: 10}
      {writer_name, owner_name} = start_isolated_pair(totals)

      # Drain to exactly the limit.
      :ok = @owner.debit(writer_name, "unit-a", :tokens, 10)

      assert {:exhausted, :tokens} = @owner.budget_precheck(owner_name, :tokens)

      # Total recorded spend via Ledger must not exceed the ceiling.
      debited = @writer.budget_debited(writer_name)
      assert Map.get(debited, :tokens, 0) <= totals.tokens
    end

    @tag :d_320
    test "AC-4 / D-320: a fresh owner with no prior debits allows any dimension with headroom" do
      totals = %{tokens: 500, cost_usd_micros: 1_000_000}
      {_writer_name, owner_name} = start_isolated_pair(totals)

      assert :ok = @owner.budget_precheck(owner_name, :tokens)
      assert :ok = @owner.budget_precheck(owner_name, :cost_usd_micros)
    end
  end

  # ---------------------------------------------------------------------------
  # D-332 — budget conservation
  # ---------------------------------------------------------------------------

  describe "AC-4 / D-332 — Σ recorded debits == total − remaining at all observation points" do
    @tag :d_332
    test "AC-4 / D-332: conservation holds after each debit" do
      totals = %{tokens: 200}
      {writer_name, owner_name} = start_isolated_pair(totals)

      # Observation 1: no debits yet.
      debited = @writer.budget_debited(writer_name)
      spent = Map.get(debited, :tokens, 0)
      # Derive remaining from ETS via budget_precheck and a successive-debit probe
      # is indirect — instead confirm the conservation law structurally:
      # spent == 0, so remaining must equal total.
      assert spent == 0

      # Debit 60.
      :ok = @owner.debit(writer_name, "unit-1", :tokens, 60)

      # Observation 2: after 60 debit.
      debited = @writer.budget_debited(writer_name)
      spent2 = Map.get(debited, :tokens, 0)
      assert spent2 == 60

      # Debit 40 more.
      :ok = @owner.debit(writer_name, "unit-2", :tokens, 40)

      # Observation 3: after 100 total.
      debited = @writer.budget_debited(writer_name)
      spent3 = Map.get(debited, :tokens, 0)
      assert spent3 == 100

      # Conservation: spent + remaining == total.
      # We know total = 200 and spent = 100, so remaining must be 100.
      # Confirm by checking that precheck still passes (remaining > 0).
      assert :ok = @owner.budget_precheck(owner_name, :tokens)

      # Drain the remainder.
      :ok = @owner.debit(writer_name, "unit-3", :tokens, 100)

      debited = @writer.budget_debited(writer_name)
      spent4 = Map.get(debited, :tokens, 0)
      assert spent4 == 200

      # Conservation: spent(200) + remaining(0) == total(200).
      assert {:exhausted, :tokens} = @owner.budget_precheck(owner_name, :tokens)
    end

    @tag :d_332
    test "AC-4 / D-332: debits are append-only — two debits at same (unit_id, dimension) both persist" do
      totals = %{tokens: 1_000}
      {writer_name, _owner_name} = start_isolated_pair(totals)

      :ok = @owner.debit(writer_name, "unit-dup", :tokens, 30)
      :ok = @owner.debit(writer_name, "unit-dup", :tokens, 20)

      # Both rows must persist — total must reflect the SUM, not the latest.
      debited = @writer.budget_debited(writer_name)
      assert Map.get(debited, :tokens, 0) == 50
    end

    @tag :d_332
    test "AC-4 / D-332: budget_debited returns separate Σ per dimension" do
      totals = %{tokens: 500, cost_usd_micros: 1_000_000}
      {writer_name, _owner_name} = start_isolated_pair(totals)

      :ok = @owner.debit(writer_name, "unit-x", :tokens, 100)
      :ok = @owner.debit(writer_name, "unit-x", :cost_usd_micros, 200)
      :ok = @owner.debit(writer_name, "unit-y", :tokens, 50)

      debited = @writer.budget_debited(writer_name)
      assert Map.get(debited, :tokens, 0) == 150
      assert Map.get(debited, :cost_usd_micros, 0) == 200
    end
  end

  # ---------------------------------------------------------------------------
  # D-315 — durability / rebuild from L after Budget.Owner restart
  # ---------------------------------------------------------------------------

  describe "AC-4 / D-315 — Budget.Owner restart rebuilds snapshot from Ledger truth" do
    @tag :d_315
    test "AC-4 / D-315: debits survive Budget.Owner process loss — fresh owner reflects persisted spend" do
      db_path = Briefly.create!(extname: ".db")
      uid = System.unique_integer([:positive])
      writer_name = :"test_durability_writer_#{uid}"
      owner_name = :"test_durability_owner_#{uid}"

      start_supervised!(
        {@writer, db_path: db_path, name: writer_name},
        id: :"dur_writer_#{uid}"
      )

      owner_spec_id = :"dur_owner_#{uid}"

      start_supervised!(
        {@owner, ledger: writer_name, totals: %{tokens: 300}, name: owner_name},
        id: owner_spec_id
      )

      # Debit 250 tokens while the owner is alive.
      :ok = @owner.debit(writer_name, "unit-persist-1", :tokens, 150)
      :ok = @owner.debit(writer_name, "unit-persist-2", :tokens, 100)

      # Verify ceiling not yet hit (50 tokens remain).
      assert :ok = @owner.budget_precheck(owner_name, :tokens)

      # STOP the Budget.Owner — simulates a process crash/restart.
      stop_supervised!(owner_spec_id)

      # START a FRESH Budget.Owner against the SAME Ledger.Writer (same DB truth).
      start_supervised!(
        {@owner, ledger: writer_name, totals: %{tokens: 300}, name: owner_name},
        id: owner_spec_id
      )

      # The fresh owner must have rebuilt its snapshot from L truth:
      # 250 tokens already spent → 50 remaining.
      # Debit 51 tokens — must exhaust the budget.
      :ok = @owner.debit(writer_name, "unit-post-restart", :tokens, 50)
      # Now exactly at ceiling (300 spent).
      assert {:exhausted, :tokens} = @owner.budget_precheck(owner_name, :tokens)

      # Conservation: Ledger must record all 300 tokens.
      debited = @writer.budget_debited(writer_name)
      assert Map.get(debited, :tokens, 0) == 300
    end

    @tag :d_315
    test "AC-4 / D-315: a Budget.Owner started with a populated Ledger immediately reflects prior spend" do
      db_path = Briefly.create!(extname: ".db")
      uid = System.unique_integer([:positive])
      writer_name = :"test_prepop_writer_#{uid}"
      owner_name = :"test_prepop_owner_#{uid}"

      start_supervised!(
        {@writer, db_path: db_path, name: writer_name},
        id: :"prepop_writer_#{uid}"
      )

      # Insert debits directly via the Writer (no Owner started yet).
      assert {:ok, _} = @writer.debit_budget(writer_name, "pre-1", :tokens, 80)
      assert {:ok, _} = @writer.debit_budget(writer_name, "pre-2", :tokens, 70)

      # Now start an Owner that must rebuild from those 150 tokens.
      start_supervised!(
        {@owner, ledger: writer_name, totals: %{tokens: 200}, name: owner_name},
        id: :"prepop_owner_#{uid}"
      )

      # 50 tokens remain (200 - 150). Debit 50 more to hit ceiling exactly.
      :ok = @owner.debit(writer_name, "post-start", :tokens, 50)

      assert {:exhausted, :tokens} = @owner.budget_precheck(owner_name, :tokens)
    end
  end

  # ---------------------------------------------------------------------------
  # B4 — budget_precheck bypasses the GenServer mailbox (direct ETS read)
  # ---------------------------------------------------------------------------

  describe "AC-4 / B4 — budget_precheck is a direct ETS read that bypasses the owner mailbox" do
    @tag :d_320
    test "AC-4 / B4: budget_precheck can be called with only the registered name (no pid required)" do
      # B4 contract: `budget_precheck(name, dimension)` resolves the ETS table
      # by the registered name atom, NOT by the GenServer pid. This means the
      # caller never needs to look up the owner pid — it reads ETS directly.
      # If the implementation incorrectly routes through the mailbox
      # (e.g. GenServer.call), this test still passes in isolation but the
      # mailbox-bypass contract is violated; the critic's gate covers that.
      # What we can assert deterministically: the call works with just the name.
      totals = %{tokens: 1_000}
      {_writer_name, owner_name} = start_isolated_pair(totals)

      # Call using only the atom name (no pid lookup).
      result = @owner.budget_precheck(owner_name, :tokens)
      assert result == :ok
    end

    @tag :d_320
    test "AC-4 / B4: budget_precheck reflects the ETS snapshot, not a fresh DB read" do
      # After a debit the ETS snapshot must be updated synchronously.
      # budget_precheck must see the updated value immediately — no async lag.
      totals = %{tokens: 5}
      {writer_name, owner_name} = start_isolated_pair(totals)

      assert :ok = @owner.budget_precheck(owner_name, :tokens)

      :ok = @owner.debit(writer_name, "unit-snap", :tokens, 5)

      # ETS snapshot was updated by debit/4 after the WAL commit.
      assert {:exhausted, :tokens} = @owner.budget_precheck(owner_name, :tokens)
    end
  end
end
