defmodule Tau.Factory.InvSt4BudgetOwnerRestartTest do
  @moduledoc """
  Gating test for issue #559 — INV-ST-4.

  Invariant statement: when `Tau.Factory.Ledger.Writer` and
  `Tau.Factory.Budget.Owner` are both supervised by
  `Tau.Factory.Supervisor`, the supervisor strategy MUST be
  `:rest_for_one` so a `Ledger.Writer` crash cascades a `Budget.Owner`
  restart (Budget.Owner's ETS snapshot depends on Ledger.Writer being up;
  a stale snapshot against an absent writer is a correctness hazard).

  Source: `docs/arch/04-software-architecture/supervision-tree.md` lines
  65-67 and 89-90, which specify a NESTED `Ledger.Supervisor [rest_for_one]`
  containing `Ledger.Writer -> Budget.Owner`.

  ## Violation path (what this test gates)

  `Tau.Factory.Supervisor.init_ledger_only/1` (lines 127-151) uses
  `Supervisor.init(children, strategy: :one_for_one)`. When `budget_opts`
  are non-nil, `maybe_add_budget_owner/3` appends `Budget.Owner` to the
  child list. Under `:one_for_one`, a `Ledger.Writer` crash does NOT
  cascade a `Budget.Owner` restart -- the invariant is violated.

  ## Test entry point

  Exercises `Tau.Factory.Supervisor.start_link/1` (the real user-facing
  supervisor entry point) in ledger-only mode (no `enabled: true`) with
  non-nil `budget_opts` so both children are present under the
  `:one_for_one` path.

  ## Fail-before validity

  With the current `:one_for_one` strategy in `init_ledger_only`, killing
  `Ledger.Writer` does NOT cause `Budget.Owner` to restart. This test
  therefore FAILS (the Budget.Owner pid is unchanged) until the
  implementer fixes the strategy to `:rest_for_one`.

  AC / D-NNN linkage: INV-ST-4
  """

  use ExUnit.Case, async: false

  @moduletag :inv_st_4
  @moduletag :capture_log

  @supervisor Tau.Factory.Supervisor
  @writer Tau.Factory.Ledger.Writer
  @owner Tau.Factory.Budget.Owner

  # ---------------------------------------------------------------------------
  # Helper: find the pid of a direct child of sup_pid by child module.
  # ---------------------------------------------------------------------------

  defp child_pid_by_mod(sup_pid, target_mod) do
    sup_pid
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {_id, pid, _type, mods} when is_pid(pid) ->
        if target_mod in List.wrap(mods), do: pid, else: nil

      _ ->
        nil
    end)
  end

  # ---------------------------------------------------------------------------
  # INV-ST-4: Ledger.Writer crash MUST restart Budget.Owner (rest_for_one)
  # ---------------------------------------------------------------------------

  describe "INV-ST-4 -- rest_for_one: Ledger.Writer crash cascades Budget.Owner restart" do
    @tag :inv_st_4
    test "INV-ST-4: after Ledger.Writer is killed, Budget.Owner receives a new pid (rest_for_one cascade)" do
      db_path = Briefly.create!(extname: ".db")
      uid = System.unique_integer([:positive])
      sup_name = :"inv_st4_sup_#{uid}"
      budget_owner_name = :"inv_st4_budget_owner_#{uid}"

      # Start the supervisor in ledger-only mode (no `enabled: true`) but
      # with budget_opts so Budget.Owner is included as a child alongside
      # Ledger.Writer. This exercises the init_ledger_only path.
      sup_pid =
        start_supervised!(
          {
            @supervisor,
            db_path: db_path,
            name: sup_name,
            budget_opts: [
              totals: %{tokens: 1_000},
              name: budget_owner_name
            ]
          },
          id: sup_name
        )

      # Both children must be alive after start.
      writer_pid_before = child_pid_by_mod(sup_pid, @writer)
      owner_pid_before = child_pid_by_mod(sup_pid, @owner)

      assert is_pid(writer_pid_before),
             "INV-ST-4: Tau.Factory.Ledger.Writer must be a live child of the supervisor"

      assert is_pid(owner_pid_before),
             "INV-ST-4: Tau.Factory.Budget.Owner must be a live child of the supervisor " <>
               "when budget_opts are provided"

      # Kill Ledger.Writer abnormally. Under :rest_for_one the supervisor MUST
      # also restart Budget.Owner (it is downstream of Writer in the child list).
      # Under :one_for_one (the violation) Budget.Owner is left running with its
      # stale ETS snapshot against an absent writer.
      ref = Process.monitor(writer_pid_before)
      Process.exit(writer_pid_before, :kill)

      # Wait for the crash to be processed by the supervisor.
      assert_receive {:DOWN, ^ref, :process, ^writer_pid_before, :killed}, 2_000

      # Allow the supervisor to restart children.
      Process.sleep(150)

      owner_pid_after = child_pid_by_mod(sup_pid, @owner)

      assert is_pid(owner_pid_after),
             "INV-ST-4: Tau.Factory.Budget.Owner must be restarted after Ledger.Writer crash"

      assert owner_pid_after != owner_pid_before,
             "INV-ST-4: Budget.Owner must receive a NEW pid after Ledger.Writer crash -- " <>
               "supervision strategy MUST be :rest_for_one so Budget.Owner restarts " <>
               "alongside Ledger.Writer. Got same pid #{inspect(owner_pid_before)}, which " <>
               "means the supervisor is using :one_for_one and the stale ETS snapshot " <>
               "is left live against an absent writer " <>
               "(supervision-tree.md lines 65-67, 89-90)."
    end
  end
end
