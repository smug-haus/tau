defmodule Tau.Factory.BudgetConservationD332Test do
  @moduledoc """
  Gating test for issue #635 — D-332 budget conservation.

  D-332 states: `Σ recorded_action_cost = total − remaining` at all times
  (single-writer double-entry).  Equivalently: `spent + remaining == total`
  must hold as a runtime identity at every observable point.

  The audit (issue #635) found that `Budget.Owner.update_ets_remaining/3`
  clamps the ETS remaining counter at 0 on overshoot but does NOT assert or
  enforce the conservation equation.  When a caller debits more than the
  total, ETS stores `remaining = 0` while the Ledger records `spent > total`,
  so `spent + remaining > total` — conservation is violated.

  This test confirms the violation is real and must fail against the current
  implementation.  It exercises the real entry points:
    - `Budget.Owner.debit/4` (the user-facing spend path)
    - `Budget.Owner.budget_precheck/2` (the admission check)
    - `Ledger.Writer.budget_debited/1` (Σ spent from durable truth)
    - `:ets.lookup/2` on the named ETS table (the remaining projection)

  No hand-built struct bypasses the real path.

  AC linkage: D-332.
  """

  use ExUnit.Case, async: true

  @moduletag :d_332
  @moduletag :capture_log

  @writer Tau.Factory.Ledger.Writer
  @owner Tau.Factory.Budget.Owner

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp start_isolated_pair(totals) do
    db_path = Briefly.create!(extname: ".db")
    uid = System.unique_integer([:positive])
    writer_name = :"test_cons_writer_#{uid}"
    owner_name = :"test_cons_owner_#{uid}"

    start_supervised!(
      {@writer, db_path: db_path, name: writer_name},
      id: :"cons_writer_#{uid}"
    )

    start_supervised!(
      {@owner, ledger: writer_name, totals: totals, name: owner_name},
      id: :"cons_owner_#{uid}"
    )

    {writer_name, owner_name}
  end

  # Read the live `remaining` for `dimension` directly from the ETS projection
  # owned by the named Budget.Owner.  The ETS table is named after the owner
  # (B4 contract) and is `:public`, so any process may read it without routing
  # through the GenServer mailbox.
  defp ets_remaining(owner_name, dimension) do
    case :ets.lookup(owner_name, dimension) do
      [{^dimension, remaining}] -> remaining
      [] -> 0
    end
  end

  # ---------------------------------------------------------------------------
  # D-332 — conservation identity: spent + remaining == total, at all points
  # ---------------------------------------------------------------------------

  describe "D-332 — budget conservation: spent + remaining == total at every observable point" do
    @tag :d_332
    test "D-332: conservation holds after a partial debit (no overshoot)" do
      total = 100
      totals = %{tokens: total}
      {writer_name, owner_name} = start_isolated_pair(totals)

      # Initial state: 0 spent, total remaining.
      debited = @writer.budget_debited(writer_name)
      spent = Map.get(debited, :tokens, 0)
      remaining = ets_remaining(owner_name, :tokens)

      assert spent + remaining == total,
             "D-332 initial: spent(#{spent}) + remaining(#{remaining}) != total(#{total})"

      # Debit 40 tokens.
      :ok = @owner.debit(writer_name, "unit-partial", :tokens, 40)

      debited2 = @writer.budget_debited(writer_name)
      spent2 = Map.get(debited2, :tokens, 0)
      remaining2 = ets_remaining(owner_name, :tokens)

      assert spent2 + remaining2 == total,
             "D-332 after partial debit: spent(#{spent2}) + remaining(#{remaining2}) != total(#{total})"
    end

    @tag :d_332
    test "D-332: conservation holds after draining the budget to exactly zero" do
      total = 50
      totals = %{tokens: total}
      {writer_name, owner_name} = start_isolated_pair(totals)

      :ok = @owner.debit(writer_name, "unit-full", :tokens, 50)

      debited = @writer.budget_debited(writer_name)
      spent = Map.get(debited, :tokens, 0)
      remaining = ets_remaining(owner_name, :tokens)

      # spent == 50, remaining == 0, total == 50 → conservation holds.
      assert spent + remaining == total,
             "D-332 at ceiling: spent(#{spent}) + remaining(#{remaining}) != total(#{total})"
    end

    @tag :d_332
    test "D-332: conservation holds even when a debit causes overshoot beyond the total" do
      # This test catches the documented gap: update_ets_remaining/3 clamps
      # remaining at 0 on overshoot, but the Ledger still records the full
      # debit cost.  If the clamped ETS value is used as-is, then:
      #
      #   spent(e.g. 120) + remaining(0) = 120 ≠ total(100)
      #
      # A conformant implementation must either:
      #   (a) refuse the overshoot (prevent the debit call from recording more
      #       than the ceiling), OR
      #   (b) adjust the recorded Ledger cost to match the actual spend
      #       (so Σ debits reflects the clamped remaining).
      #
      # Either way: spent + remaining == total must hold after the call.
      # The current implementation satisfies neither — it appends the full
      # `cost` to the Ledger and clamps ETS independently, breaking parity.
      total = 100
      totals = %{tokens: total}
      {writer_name, owner_name} = start_isolated_pair(totals)

      # First debit to 90.
      :ok = @owner.debit(writer_name, "unit-1", :tokens, 90)

      # Second debit of 20 overshoots by 10 (90 + 20 = 110 > 100).
      :ok = @owner.debit(writer_name, "unit-2", :tokens, 20)

      debited = @writer.budget_debited(writer_name)
      spent = Map.get(debited, :tokens, 0)
      remaining = ets_remaining(owner_name, :tokens)

      # D-332: spent + remaining MUST equal total at all times.
      assert spent + remaining == total,
             "D-332 overshoot: spent(#{spent}) + remaining(#{remaining}) != total(#{total}); " <>
               "ETS clamps remaining to 0 but Ledger recorded full overshoot cost — " <>
               "conservation is violated"
    end

    @tag :d_332
    test "D-332: conservation holds across multiple dimensions independently" do
      totals = %{tokens: 200, cost_usd_micros: 1_000_000}
      {writer_name, owner_name} = start_isolated_pair(totals)

      :ok = @owner.debit(writer_name, "unit-a", :tokens, 80)
      :ok = @owner.debit(writer_name, "unit-a", :cost_usd_micros, 300_000)
      :ok = @owner.debit(writer_name, "unit-b", :tokens, 60)

      debited = @writer.budget_debited(writer_name)

      for {dim, total} <- totals do
        spent = Map.get(debited, dim, 0)
        remaining = ets_remaining(owner_name, dim)

        assert spent + remaining == total,
               "D-332 dimension #{dim}: spent(#{spent}) + remaining(#{remaining}) != total(#{total})"
      end
    end
  end
end
