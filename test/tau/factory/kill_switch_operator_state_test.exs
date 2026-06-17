defmodule Tau.Factory.KillSwitchOperatorStateTest do
  @moduledoc """
  Gating test for issue #549 — INV-KILLSWITCH-OPERATOR-STATE.

  The invariant (docs/arch/04-software-architecture/governance.md §6,
  SPEC-FACTORY-CORE.md B9) states:

    "The kill signal lives in operator state (an ETS flag under a control
    owner, or a durable control row), NEVER in the project's git/solution
    tree and NEVER solely in process heap."

  Falsification evidence (issue #549):
    - `KillSwitch.init/1` stores `%{sentinel_triggered: false}` in GenServer
      process heap; no `:ets.new` call.
    - `request_halt/1` only broadcasts via PubSub; no ETS flag is written.
    - The filesystem-sentinel path (`File.exists?/1`) makes the file the
      primary signal medium — the file-based form the invariant explicitly
      forbids as operator state for this component.

  This test exercises the REAL entry points — `KillSwitch.start_link/1` and
  `KillSwitch.request_halt/1` — then inspects the KillSwitch process's ETS
  ownership to confirm the halt flag is durable operator state, not transient
  heap state.

  The test MUST fail against the current implementation (no ETS table is
  created or populated by the KillSwitch process) and MUST pass only once the
  implementation stores the halt flag in an ETS table owned by the KillSwitch
  process.

  AC/D-NNN linkage: INV-KILLSWITCH-OPERATOR-STATE, #549.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log
  @moduletag :inv_killswitch_operator_state

  @kill_switch Tau.Factory.KillSwitch

  # Derive unique registered names per test to avoid collisions across async runs.
  defp unique_name(base) do
    suffix = System.unique_integer([:positive])
    :"#{base}_#{suffix}"
  end

  # ---------------------------------------------------------------------------
  # Helper: collect all ETS tables owned by a given pid.
  # :ets.all/0 returns all table ids; :ets.info(tid, :owner) gives the owner.
  # ---------------------------------------------------------------------------

  defp ets_tables_owned_by(pid) do
    :ets.all()
    |> Enum.filter(fn tid ->
      try do
        :ets.info(tid, :owner) == pid
      rescue
        _ -> false
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Test 1 — INV-KILLSWITCH-OPERATOR-STATE (load-bearing):
  # After request_halt/1, the KillSwitch process MUST own an ETS table
  # containing the halt flag as durable operator state.
  #
  # Current implementation stores halt state only in process heap
  # (%{sentinel_triggered: false}) and broadcasts via PubSub — no ETS write.
  # This test FAILS against current code because the KillSwitch process owns
  # no ETS tables at all.
  # ---------------------------------------------------------------------------

  @tag :inv_killswitch_operator_state
  test "INV-KILLSWITCH-OPERATOR-STATE: request_halt/1 writes halt flag to an ETS table owned by the KillSwitch process, not only to process heap" do
    ks_name = unique_name(:ks_operator_state)

    start_supervised!(
      {@kill_switch, name: ks_name, pubsub: Tau.PubSub},
      id: ks_name
    )

    ks_pid = Process.whereis(ks_name)
    assert is_pid(ks_pid), "KillSwitch did not register under #{inspect(ks_name)}"

    # Snapshot ETS ownership BEFORE request_halt; the table must exist after start_link
    # (operator state is allocated on init, not lazily on halt).
    tables_before = ets_tables_owned_by(ks_pid)

    assert Enum.any?(tables_before),
           "INV-KILLSWITCH-OPERATOR-STATE violation: KillSwitch.start_link/1 did not " <>
             "create an ETS table owned by the KillSwitch process. " <>
             "The kill signal requires durable operator state (ETS flag under a control " <>
             "owner), not process heap. Current implementation stores state only in " <>
             "GenServer process heap (%{sentinel_triggered: false})."

    # Trigger the halt.
    :ok = @kill_switch.request_halt(ks_name)

    # Give the GenServer a moment to process the synchronous call (it is a call,
    # so the reply arrives after the handler returns, but the ETS write must
    # happen inside the handler before the reply).
    ks_pid_after = Process.whereis(ks_name)
    assert is_pid(ks_pid_after), "KillSwitch crashed after request_halt/1"
    assert ks_pid_after == ks_pid, "KillSwitch restarted (unexpected)"

    # Assert that at least one ETS table owned by the KillSwitch process
    # records the halt flag (key :halt or :halted, value true/1).
    tables_after = ets_tables_owned_by(ks_pid)

    halt_flag_present =
      Enum.any?(tables_after, fn tid ->
        # Accept any of the plausible conformant storage shapes:
        #   {:halt, true}, {:halted, true}, {:halt_pending, true}, {_, 1}
        halt_entries =
          try do
            :ets.match(tid, {:"$1", :"$2"})
          rescue
            _ -> []
          end

        Enum.any?(halt_entries, fn
          [key, val] when key in [:halt, :halted, :halt_pending, :kill] ->
            val in [true, 1]

          _ ->
            false
        end)
      end)

    assert halt_flag_present,
           "INV-KILLSWITCH-OPERATOR-STATE violation: after request_halt/1, no ETS table " <>
             "owned by the KillSwitch process contains a halt flag. " <>
             "Observed ETS tables owned by KillSwitch pid #{inspect(ks_pid)}: " <>
             inspect(tables_after) <>
             ". The invariant requires the kill signal to be recorded as durable " <>
             "operator state in ETS (key :halt/:halted/:halt_pending/:kill → true/1), " <>
             "not only broadcast via PubSub and lost if the process restarts."
  end

  # ---------------------------------------------------------------------------
  # Test 2 — INV-KILLSWITCH-OPERATOR-STATE (structural init check):
  # init/1 MUST allocate an ETS table as the operator-state owner.
  # Process-heap state (%{sentinel_triggered: false}) is irrecoverably lost
  # on restart. The ETS table must be allocated at init time, not lazily.
  #
  # This test will fail against the current implementation because
  # KillSwitch.init/1 creates no ETS table at all.
  # ---------------------------------------------------------------------------

  @tag :inv_killswitch_operator_state
  test "INV-KILLSWITCH-OPERATOR-STATE: KillSwitch init/1 allocates operator-state ETS table (structural allocation check)" do
    ks_name = unique_name(:ks_ets_alloc)

    start_supervised!(
      {@kill_switch, name: ks_name, pubsub: Tau.PubSub},
      id: ks_name
    )

    ks_pid = Process.whereis(ks_name)
    assert is_pid(ks_pid)

    # init/1 MUST create an ETS table; this is the structural requirement.
    tables = ets_tables_owned_by(ks_pid)

    assert Enum.any?(tables),
           "INV-KILLSWITCH-OPERATOR-STATE violation: KillSwitch.init/1 did not create " <>
             "any ETS table owned by the KillSwitch process (pid #{inspect(ks_pid)}). " <>
             "Operator state MUST be allocated in init/1, not lazily on halt. " <>
             "Current implementation stores state only in GenServer process heap " <>
             "(%{pubsub: _, sentinel_path: _, poll_interval: _, sentinel_triggered: false}) " <>
             "with no :ets.new call."
  end
end
