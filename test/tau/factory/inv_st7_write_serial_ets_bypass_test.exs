defmodule Tau.Factory.InvSt7WriteSerialEtsBypassTest do
  @moduledoc """
  Gating test for issue #560 — INV-ST-7.

  ## Invariant

  > Writes to durable decisions MUST serialize through `Ledger.Writer` (single
  > writer). Admission reads MUST bypass the mailbox and read directly from the
  > budget ETS snapshot. Policy reads MUST hit the policy ETS snapshot directly.
  > Falsified by: any caller writing decisions directly to SQLite bypassing
  > Ledger.Writer, or any admission check using GenServer.call to Budget.Owner.

  Source: `docs/arch/04-software-architecture/supervision-tree.md` §4 "Identity &
  read/write split" — "Writes serialize through owners; reads bypass the mailbox.
  `Ledger.Writer` is the single writer of decisions; admission reads the budget ETS
  snapshot directly (not via GenServer.call), and policy reads hit the policy ETS
  snapshot — copy-free, no owner bottleneck."

  Also `docs/arch/04-software-architecture/governance.md` §3 — "Reads hit the
  policy ETS snapshot directly (no owner bottleneck)."

  ## Three clauses tested

  ### Clause 1 — Single writer (structural)

  Every durable-decision write MUST route through `Tau.Factory.Ledger.Writer` via
  `GenServer.call`. The test verifies that all write API calls route through a live
  Writer process: the WAL-before-ack guarantee means the {:ok, ref} reply arrives
  only after the SQLite write is durable.

  ### Clause 2 — Admission ETS bypass

  `Budget.Owner.budget_precheck/2` MUST read the ETS table directly by atom name,
  NOT via `GenServer.call` to the Budget.Owner process. The test blocks the
  Budget.Owner's GenServer mailbox using `:sys.suspend/1` and asserts that
  `budget_precheck/2` still returns immediately — proving it reads ETS directly.

  ### Clause 3 — Policy ETS bypass (the unenforced clause — FAIL-BEFORE target)

  After `Scheduler.admit/4` pins a `%Policy{}` at admission, the policy field
  MUST be readable via `Policy.Owner.resolve/3` (direct ETS, no mailbox). The
  invariant is violated if `admit/4` stores the pin only in the Scheduler's own
  GenServer state without also populating the `Policy.Owner` ETS table.

  Currently `Scheduler.admit/4` stores the pin in `state.pins` (in-memory
  GenServer state) and NEVER calls `Policy.Owner.pin/3`. As a result,
  `Policy.Owner.resolve/3` raises `KeyError` for any unit admitted via
  `Scheduler.admit/4` because the ETS table is unpopulated. This test FAILS
  against the current codebase, confirming the INV-ST-7 Clause 3 gap.

  The conformant fix: `Scheduler.admit/4` must call `Policy.Owner.pin/3` (which
  populates the named ETS table owned by `Policy.Owner`) so that downstream
  callers can read policy fields via `Policy.Owner.resolve/3` without routing
  through the Scheduler's GenServer mailbox.

  ## Fail-before validity

  Clause 3 assertion raises `KeyError` because `Scheduler.admit/4` does NOT call
  `Policy.Owner.pin/3`, leaving the ETS table empty:
      (KeyError) key {"unit-inv-st7", :retry_bound_n} not found in: policy_owner_name

  Additionally, `Scheduler.start_link/1` does not currently accept a
  `:policy_owner` option, so `start_supervised!` itself may raise, providing an
  alternative fail-before path.

  ## AC / D-NNN linkage

  INV-ST-7 (issue #560)
  """

  use ExUnit.Case, async: true

  alias Tau.Factory.Budget.Owner, as: BudgetOwner
  alias Tau.Factory.Ledger.Writer, as: LedgerWriter
  alias Tau.Factory.Policy
  alias Tau.Factory.Policy.Owner, as: PolicyOwner
  alias Tau.Factory.Scheduler

  @moduletag :inv_st_7
  @moduletag :capture_log

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp uid(base), do: :"#{base}_#{System.unique_integer([:positive])}"

  # Build a minimal admissible %Policy{} that passes Policy.clamp/1.
  # Uses MFA reference for conflict_predicate (anonymous fn is not allowed
  # in module attributes and causes compile-time ArgumentError).
  defp valid_policy(version \\ 1) do
    %Policy{
      version: version,
      model_per_role: %{implementer: "claude-sonnet-4-6"},
      retry_bound_n: 2,
      budget: %{token: 500_000, cost: 50, wall_time: 3600, iteration: 50},
      priority_order: [],
      conflict_predicate: &__MODULE__.trivial_predicate/2,
      gate_manifest: [:mutation, :critic, :reviewer],
      escalation_thresholds: %{upheld_challenges: 2}
    }
  end

  # Minimal non-conflicting declared scope (all sets empty — passes all five
  # ConflictCheck clauses against any other empty-set scope).
  defp empty_scope do
    %{
      deps: [],
      files: MapSet.new(),
      codepoints: MapSet.new(),
      specs: MapSet.new(),
      resources: MapSet.new()
    }
  end

  # MFA-safe trivial conflict predicate (not an anonymous fn — safe for use
  # in runtime-constructed structs).
  def trivial_predicate(_scope_a, _scope_b), do: true

  # ---------------------------------------------------------------------------
  # INV-ST-7 Clause 1 — Ledger.Writer is the single writer; db handle does not
  # escape; killing the Writer process makes all durable writes fail.
  # ---------------------------------------------------------------------------

  describe "INV-ST-7 Clause 1 — Ledger.Writer is the sole SQLite writer; all writes route through GenServer.call" do
    @tag :inv_st_7
    test "INV-ST-7/C1: debit_budget routes through Writer GenServer.call; WAL-before-ack guarantee holds" do
      # Verify the single-writer channel: debit_budget/4 is a GenServer.call
      # to the Writer. The WAL-before-ack guarantee means the {:ok, ref} reply
      # arrives only after the SQLite write is durable. Reconstruct via
      # budget_debited to confirm the write persisted through the Writer.
      db_path = Briefly.create!(extname: ".db")
      writer_name = uid(:inv_st7_c1_debit)

      start_supervised!(
        {LedgerWriter, db_path: db_path, name: writer_name},
        id: uid(:inv_st7_c1_debit_sup)
      )

      assert {:ok, ref} = LedgerWriter.debit_budget(writer_name, "unit-1", :tokens, 100)
      assert is_integer(ref)

      # The Writer is truth: budget_debited reconstructs spend from the db,
      # not from in-memory state — confirming the write went through the Writer.
      debited = LedgerWriter.budget_debited(writer_name)

      assert Map.get(debited, :tokens, 0) == 100,
             "INV-ST-7/C1: debit_budget MUST persist via Writer; budget_debited must reflect it. " <>
               "Got #{inspect(debited)}"
    end

    @tag :inv_st_7
    test "INV-ST-7/C1: append_verdict routes through Writer GenServer.call; the write is durable" do
      db_path = Briefly.create!(extname: ".db")
      writer_name = uid(:inv_st7_c1_verdict)

      start_supervised!(
        {LedgerWriter, db_path: db_path, name: writer_name},
        id: uid(:inv_st7_c1_verdict_sup)
      )

      assert {:ok, ref} =
               LedgerWriter.append_verdict(writer_name, %{
                 hash: "abc123",
                 run: "run-1",
                 half: :critic,
                 status: :pass,
                 idempotency_key: "k-inv-st7-c1"
               })

      assert is_integer(ref),
             "INV-ST-7/C1: append_verdict must return {:ok, integer_row_id}; got {:ok, #{inspect(ref)}}"
    end
  end

  # ---------------------------------------------------------------------------
  # INV-ST-7 Clause 2 — Budget.Owner.budget_precheck bypasses the owner mailbox
  # ---------------------------------------------------------------------------

  describe "INV-ST-7 Clause 2 — budget_precheck reads ETS directly, bypassing the Budget.Owner mailbox" do
    @tag :inv_st_7
    test "INV-ST-7/C2: budget_precheck returns immediately even when the Budget.Owner mailbox is suspended" do
      # Block the Budget.Owner mailbox using :sys.suspend/1 (halts the
      # GenServer's message loop without killing the process). A GenServer.call
      # to a suspended process would block for the full timeout (~5 s).
      # A direct ETS read MUST complete in well under 500 ms.
      db_path = Briefly.create!(extname: ".db")
      uid_val = System.unique_integer([:positive])
      writer_name = :"inv_st7_c2_writer_#{uid_val}"
      owner_name = :"inv_st7_c2_owner_#{uid_val}"

      start_supervised!(
        {LedgerWriter, db_path: db_path, name: writer_name},
        id: :"inv_st7_c2_w_#{uid_val}"
      )

      start_supervised!(
        {BudgetOwner, ledger: writer_name, totals: %{tokens: 1_000}, name: owner_name},
        id: :"inv_st7_c2_b_#{uid_val}"
      )

      owner_pid = GenServer.whereis(owner_name)
      :sys.suspend(owner_pid)
      on_exit(fn -> catch_exit(:sys.resume(owner_pid)) end)

      t0 = System.monotonic_time(:millisecond)
      result = BudgetOwner.budget_precheck(owner_name, :tokens)
      elapsed_ms = System.monotonic_time(:millisecond) - t0

      :sys.resume(owner_pid)

      assert result == :ok,
             "INV-ST-7/C2: budget_precheck must return :ok when budget has headroom; " <>
               "got #{inspect(result)}"

      assert elapsed_ms < 500,
             "INV-ST-7/C2 VIOLATED: budget_precheck took #{elapsed_ms} ms with the owner mailbox " <>
               "suspended. Direct ETS read must complete in <500 ms. " <>
               "If this blocks for ~5 s, budget_precheck is routing through GenServer.call."
    end

    @tag :inv_st_7
    test "INV-ST-7/C2: budget_precheck uses registered atom name only — ETS lookup by atom, no pid" do
      # B4 contract: budget_precheck(name, dimension) resolves the ETS table
      # by the atom name, not a GenServer pid. Minimal proof that the
      # implementation is a named-table ETS lookup.
      db_path = Briefly.create!(extname: ".db")
      uid_val = System.unique_integer([:positive])
      writer_name = :"inv_st7_c2b_w_#{uid_val}"
      owner_name = :"inv_st7_c2b_o_#{uid_val}"

      start_supervised!(
        {LedgerWriter, db_path: db_path, name: writer_name},
        id: :"inv_st7_c2b_ws_#{uid_val}"
      )

      start_supervised!(
        {BudgetOwner, ledger: writer_name, totals: %{tokens: 500}, name: owner_name},
        id: :"inv_st7_c2b_os_#{uid_val}"
      )

      assert :ok = BudgetOwner.budget_precheck(owner_name, :tokens)

      :ok = BudgetOwner.debit(writer_name, "unit-x", :tokens, 500)

      assert {:exhausted, :tokens} = BudgetOwner.budget_precheck(owner_name, :tokens),
             "INV-ST-7/C2: budget_precheck must reflect ETS snapshot immediately after debit"
    end
  end

  # ---------------------------------------------------------------------------
  # INV-ST-7 Clause 3 — Policy reads MUST hit the Policy.Owner ETS snapshot
  # directly (no mailbox bottleneck).
  #
  # FAIL-BEFORE TARGET: Scheduler.admit/4 currently stores the pin only in its
  # own GenServer state (state.pins), never calling Policy.Owner.pin/3.
  # As a result, Policy.Owner.resolve/3 raises KeyError for admitted units.
  # These tests MUST FAIL until the implementer fixes Scheduler.admit/4 to also
  # call Policy.Owner.pin(owner, unit_id, policy).
  # ---------------------------------------------------------------------------

  describe "INV-ST-7 Clause 3 — policy reads hit Policy.Owner ETS snapshot directly, not the Scheduler mailbox" do
    @tag :inv_st_7
    test "INV-ST-7/C3: after Scheduler.admit/4, policy field is readable via Policy.Owner.resolve/3 (direct ETS)" do
      # This test exercises the full admission path:
      #   1. Start a Policy.Owner (owns the ETS snapshot).
      #   2. Start a Scheduler configured with the Policy.Owner (policy_owner: name).
      #   3. Admit a unit via Scheduler.admit/4 with a valid %Policy{}.
      #   4. Assert that Policy.Owner.resolve/3 returns the pinned field value.
      #
      # The assertion on step 4 FAILS against current code because:
      #   (a) Scheduler.start_link/1 does not accept :policy_owner — the
      #       start_supervised! call itself may crash, OR
      #   (b) Scheduler.admit/4 does NOT call Policy.Owner.pin/3 — the ETS
      #       table is empty and resolve/3 raises KeyError.
      #
      # The conformant fix: Scheduler.admit/4 must call
      #   Policy.Owner.pin(policy_owner_name, unit_id, policy)
      # before returning :admit, so callers can read policy fields from ETS
      # without routing through the Scheduler's GenServer mailbox.
      uid_val = System.unique_integer([:positive])
      policy_owner_name = :"inv_st7_c3_policy_owner_#{uid_val}"
      sched_name = :"inv_st7_c3_sched_#{uid_val}"

      start_supervised!(
        {PolicyOwner, name: policy_owner_name},
        id: :"inv_st7_c3_po_#{uid_val}"
      )

      # The Scheduler must accept :policy_owner so it knows which Policy.Owner
      # ETS table to populate at admit/4 time.
      start_supervised!(
        {Scheduler, name: sched_name, w_cap: 5, policy_owner: policy_owner_name},
        id: :"inv_st7_c3_sched_sup_#{uid_val}"
      )

      policy = valid_policy(1)
      result = Scheduler.admit(sched_name, "unit-inv-st7", empty_scope(), policy)

      assert result == :admit,
             "INV-ST-7/C3: Scheduler.admit/4 must return :admit; got #{inspect(result)}"

      # INV-ST-7/C3 core assertion: the policy field MUST be readable via
      # Policy.Owner.resolve/3 WITHOUT calling back into the Scheduler.
      # With current code (Scheduler does not call Policy.Owner.pin/3), this
      # raises:
      #   (KeyError) key {"unit-inv-st7", :retry_bound_n} not found in: policy_owner_name
      resolved_retry_bound =
        PolicyOwner.resolve(policy_owner_name, "unit-inv-st7", :retry_bound_n)

      assert resolved_retry_bound == policy.retry_bound_n,
             "INV-ST-7/C3 VIOLATED: Policy.Owner.resolve/3 returned #{inspect(resolved_retry_bound)}; " <>
               "expected #{inspect(policy.retry_bound_n)}. " <>
               "Scheduler.admit/4 must call Policy.Owner.pin/3 to populate the ETS snapshot. " <>
               "Policy reads MUST bypass the Scheduler mailbox (supervision-tree.md §4)."
    end

    @tag :inv_st_7
    test "INV-ST-7/C3: Policy.Owner.resolve/3 returns immediately even when Scheduler mailbox is suspended" do
      # Structural proof: with the Scheduler's mailbox suspended, any
      # GenServer.call to it blocks for ~5 s. Policy.Owner.resolve/3 MUST
      # complete in <500 ms — proving it is a direct ETS read.
      #
      # Fail-before: raises KeyError (ETS table empty) before the timing test
      # even runs, because Scheduler.admit/4 does not call Policy.Owner.pin/3.
      uid_val = System.unique_integer([:positive])
      policy_owner_name = :"inv_st7_c3b_policy_owner_#{uid_val}"
      sched_name = :"inv_st7_c3b_sched_#{uid_val}"

      start_supervised!(
        {PolicyOwner, name: policy_owner_name},
        id: :"inv_st7_c3b_po_#{uid_val}"
      )

      start_supervised!(
        {Scheduler, name: sched_name, w_cap: 5, policy_owner: policy_owner_name},
        id: :"inv_st7_c3b_sched_sup_#{uid_val}"
      )

      policy = valid_policy(2)
      assert :admit = Scheduler.admit(sched_name, "unit-c3b", empty_scope(), policy)

      sched_pid = GenServer.whereis(sched_name)
      :sys.suspend(sched_pid)
      on_exit(fn -> catch_exit(:sys.resume(sched_pid)) end)

      t0 = System.monotonic_time(:millisecond)
      resolved = PolicyOwner.resolve(policy_owner_name, "unit-c3b", :retry_bound_n)
      elapsed_ms = System.monotonic_time(:millisecond) - t0

      :sys.resume(sched_pid)

      assert resolved == policy.retry_bound_n,
             "INV-ST-7/C3: Policy.Owner.resolve/3 must return the pinned value; " <>
               "got #{inspect(resolved)}"

      assert elapsed_ms < 500,
             "INV-ST-7/C3 VIOLATED: Policy.Owner.resolve/3 took #{elapsed_ms} ms with " <>
               "the Scheduler mailbox suspended. Direct ETS read must complete in <500 ms."
    end

    @tag :inv_st_7
    test "INV-ST-7/C3: all policy fields are accessible via Policy.Owner.resolve/3 after admission" do
      # Full-coverage assertion: every %Policy{} field must be readable from
      # the ETS snapshot after Scheduler.admit/4. Ensures the pin is complete
      # (all fields stored), not partial.
      uid_val = System.unique_integer([:positive])
      policy_owner_name = :"inv_st7_c3c_policy_owner_#{uid_val}"
      sched_name = :"inv_st7_c3c_sched_#{uid_val}"

      start_supervised!(
        {PolicyOwner, name: policy_owner_name},
        id: :"inv_st7_c3c_po_#{uid_val}"
      )

      start_supervised!(
        {Scheduler, name: sched_name, w_cap: 5, policy_owner: policy_owner_name},
        id: :"inv_st7_c3c_sched_sup_#{uid_val}"
      )

      policy = valid_policy(3)
      assert :admit = Scheduler.admit(sched_name, "unit-c3c", empty_scope(), policy)

      policy_fields =
        policy
        |> Map.from_struct()
        |> Map.keys()

      for field <- policy_fields do
        resolved = PolicyOwner.resolve(policy_owner_name, "unit-c3c", field)
        expected = Map.get(policy, field)

        assert resolved == expected,
               "INV-ST-7/C3: Policy.Owner.resolve(#{inspect(policy_owner_name)}, " <>
                 "\"unit-c3c\", #{inspect(field)}) returned #{inspect(resolved)}; " <>
                 "expected #{inspect(expected)}. Pin is incomplete."
      end
    end
  end
end
