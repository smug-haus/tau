defmodule Tau.Factory.CoordinatorIdempotentRehydrationTest do
  @moduledoc """
  Gating test for issue #607 — INV-SA-FC1-IDEMPOTENT.

  Invariant: After a Coordinator crash and resume from Ledger state, no unit is
  double-processed (select is idempotent on Ledger). A unit that was snapshotted
  at a non-:planned state (e.g. :gating) MUST NOT re-run earlier FSM phases
  (oracle, implementing) on rehydration — it must resume at its snapshotted state.

  ## The gap

  The Coordinator `init/1` reads `Ledger.Reader.latest_unit_snapshots/1` and
  correctly filters terminal units. For non-terminal units it calls
  `drive_fun.(unit_id)` — passing ONLY the `unit_id` binary, discarding the
  snapshotted Ledger state (coordinator.ex line ~176: `[{unit_id, _state} | rest]`).

  The SPEC (SPEC-FACTORY-CORE §5 D-344, line ~1227) requires:

    > "these units resume the loop at their snapshotted state"

  With the current implementation `drive_fun` receives only a binary. The
  supervisor's `to_unit_work_item/1` (supervisor.ex ~377-389) then reconstructs
  the work_item with `hash: ""` and `declared_scope: @empty_scope`, and
  `Unit.init/1` unconditionally returns `{:ok, :planned, data, ...}` (unit.ex
  line ~201) regardless of the ledger snapshot. A unit that was at :gating before
  the crash restarts at :planned and re-runs oracle + implementing — double-processing.

  ## Oracle

  The `drive_fun` MUST receive a work_item that carries the snapshotted FSM state
  so the Unit can resume at that state. Concretely, the work_item passed to
  `drive_fun` on rehydration MUST be a map (not a plain binary) that includes
  `resume_state: <snapshotted_atom>`.

  The test:
    1. Seeds L with a unit snapshotted at :gating.
    2. Seeds L with a unit snapshotted at :implementing.
    3. Seeds L with a unit at :merged (terminal — must NOT be driven at all).
    4. Starts `Coordinator.start_link/1` (the real supervised entry point) with
       `ledger:` set.
    5. Captures every work_item the Coordinator passes to `drive_fun`.
    6. Asserts:
       a. The terminal (:merged) unit is never driven (D-344 invariant).
       b. The :gating unit is driven with `resume_state: :gating` in the
          work_item — NOT as a plain binary (which would cause `:planned` restart).
       c. The :implementing unit is driven with `resume_state: :implementing`.

  This test FAILS against the current production code because `drive_fun` receives
  plain `unit_id` binaries, not maps with `resume_state`.

  AC/D-NNN linkage: INV-SA-FC1-IDEMPOTENT, D-344.
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log
  @moduletag :inv_sa_fc1_idempotent
  @moduletag :d_344

  @coordinator Tau.Factory.Coordinator
  @writer Tau.Factory.Ledger.Writer

  defp unique_name(base) do
    suffix = System.unique_integer([:positive])
    :"#{base}_#{suffix}"
  end

  defp start_ledger do
    db_path = Briefly.create!(extname: ".db")
    writer_name = unique_name(:idem_ledger)

    start_supervised!(
      {@writer, db_path: db_path, name: writer_name},
      id: writer_name
    )

    writer_name
  end

  # ---------------------------------------------------------------------------
  # INV-SA-FC1-IDEMPOTENT: rehydrated units receive snapshotted state in the
  # work_item so the Unit FSM can resume at that state, not restart at :planned.
  # ---------------------------------------------------------------------------

  @tag :inv_sa_fc1_idempotent
  @tag :d_344
  test "INV-SA-FC1-IDEMPOTENT: drive_fun receives resume_state from Ledger so units resume at snapshotted state, not :planned" do
    ledger = start_ledger()

    gating_unit = "unit-gating-#{System.unique_integer([:positive])}"
    implementing_unit = "unit-implementing-#{System.unique_integer([:positive])}"
    merged_unit = "unit-merged-#{System.unique_integer([:positive])}"

    # Seed L: gating_unit was at :gating before the crash.
    assert {:ok, _} =
             @writer.snapshot_unit(ledger, %{
               unit_id: gating_unit,
               state: :gating,
               idempotency_key: "#{gating_unit}:snapshot:0"
             })

    # Seed L: implementing_unit was at :implementing before the crash.
    assert {:ok, _} =
             @writer.snapshot_unit(ledger, %{
               unit_id: implementing_unit,
               state: :implementing,
               idempotency_key: "#{implementing_unit}:snapshot:0"
             })

    # Seed L: merged_unit is terminal — must not be driven on resume.
    assert {:ok, _} =
             @writer.snapshot_unit(ledger, %{
               unit_id: merged_unit,
               state: :merged,
               idempotency_key: "#{merged_unit}:snapshot:0"
             })

    # Capture every work_item the Coordinator passes to drive_fun. The Agent is
    # owned by the test process and outlives any Coordinator restart.
    {:ok, drive_log} = Agent.start_link(fn -> [] end)
    on_exit(fn -> if Process.alive?(drive_log), do: Agent.stop(drive_log) end)

    test_pid = self()
    coord_name = unique_name(:coord_idem)

    drive_fun = fn work_item ->
      Agent.update(drive_log, fn log -> [work_item | log] end)
      send(test_pid, {:driven, work_item})
      # Signal the Coordinator that this unit has completed so the loop can drain.
      unit_id =
        cond do
          is_map(work_item) -> Map.get(work_item, :unit_id, work_item)
          is_binary(work_item) -> work_item
          true -> inspect(work_item)
        end

      coord_pid = Process.whereis(coord_name)
      if is_pid(coord_pid), do: send(coord_pid, {:unit_terminal, unit_id, :merged})
      :ok
    end

    opts = [
      name: coord_name,
      pubsub: Tau.PubSub,
      select_fun: fn -> nil end,
      drive_fun: drive_fun,
      scheduler: nil,
      ledger: ledger
    ]

    start_supervised!({@coordinator, opts})

    # Wait for both non-terminal units to be driven. Timeout indicates neither
    # was rehydrated, which is also a failure (different from the state assertion).
    assert_receive {:driven, _work1}, 2_000
    assert_receive {:driven, _work2}, 2_000

    # Allow a window for any (incorrect) third drive.
    Process.sleep(100)

    driven_items = Agent.get(drive_log, &Enum.reverse(&1))

    # Oracle (a): terminal unit must NEVER be driven.
    driven_ids =
      Enum.map(driven_items, fn item ->
        cond do
          is_map(item) -> Map.get(item, :unit_id)
          is_binary(item) -> item
          true -> inspect(item)
        end
      end)

    refute merged_unit in driven_ids,
           "INV-SA-FC1-IDEMPOTENT violation: terminal (:merged) unit was driven on " <>
             "resume (driven_ids=#{inspect(driven_ids)})"

    assert length(driven_items) == 2,
           "Expected exactly 2 rehydrated units driven (the 2 non-terminal ones); " <>
             "got #{length(driven_items)}: #{inspect(driven_ids)}"

    # Oracle (b): each driven work_item MUST be a map carrying resume_state.
    # A plain binary means the snapshotted state was discarded — the Unit will
    # restart at :planned and re-run oracle + implementing (double-processing).
    Enum.each(driven_items, fn item ->
      assert is_map(item),
             "INV-SA-FC1-IDEMPOTENT violation: drive_fun received #{inspect(item)} " <>
               "(a plain binary), not a map with resume_state. The Coordinator " <>
               "discarded the Ledger-snapshotted state; the Unit will restart at " <>
               ":planned and re-run oracle+implementing — double-processing."

      assert Map.has_key?(item, :resume_state),
             "INV-SA-FC1-IDEMPOTENT violation: work_item #{inspect(item)} has no " <>
               ":resume_state key. The snapshotted Ledger state must be threaded " <>
               "through drive_fun so the Unit FSM can resume at the correct state."
    end)

    # Oracle (c): the work_items must carry the correct resume_state atoms.
    find_item = fn uid ->
      Enum.find(driven_items, fn item ->
        is_map(item) and Map.get(item, :unit_id) == uid
      end)
    end

    gating_item = find_item.(gating_unit)
    implementing_item = find_item.(implementing_unit)

    assert gating_item != nil,
           "gating_unit was not driven or work_item lacked :unit_id; driven=#{inspect(driven_items)}"

    assert implementing_item != nil,
           "implementing_unit was not driven or work_item lacked :unit_id; driven=#{inspect(driven_items)}"

    assert Map.get(gating_item, :resume_state) == :gating,
           "INV-SA-FC1-IDEMPOTENT violation: gating_unit work_item has resume_state=" <>
             "#{inspect(Map.get(gating_item, :resume_state))}; expected :gating. " <>
             "A :planned restart would re-run oracle+implementing (double-processing)."

    assert Map.get(implementing_item, :resume_state) == :implementing,
           "INV-SA-FC1-IDEMPOTENT violation: implementing_unit work_item has resume_state=" <>
             "#{inspect(Map.get(implementing_item, :resume_state))}; expected :implementing."
  end
end
