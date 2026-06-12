defmodule Tau.Factory.UnitSnapshotDurabilityTest do
  @moduledoc """
  Gating test for PR #459 (P5c-1 — the Unit FSM snapshots each transition to the
  Ledger, D-318 / D-344).

  ## What this enforces

  **D-318 / SPEC-FACTORY-CORE §5 (line 391):** *"Every transition
  `snapshot_unit/2`s durable state to L before its external effect (D-315,
  LIV-5)."* and **C6 (§4 component table):** the Unit *"snapshots each
  transition to L."*

  Today the `Tau.Factory.Unit` FSM does NOT write to the Ledger on any
  transition — `init/1` does not read a `:ledger` opt and no state function
  calls `Ledger.Writer.snapshot_unit/2`. The Coordinator's D-344 durable
  resume (`Ledger.Reader.latest_unit_snapshots/1`) can therefore only rehydrate
  the *injected test seam* in `coordinator_recovery_test.exs`, never a REAL
  unit's state — because no real unit ever persists its state.

  This test closes that gap. It drives the REAL Unit FSM (via the real
  `UnitSupervisor.start_unit/2` entry point and the injected boundary seams the
  existing `unit_termination_test.exs` uses — `worker_fun`, `gate_fun`,
  `merge_fun`) and asserts the durable side via the pinned Ledger read op
  `Ledger.Reader.latest_unit_snapshots/1`.

  ## Pinned contract (implementer MUST conform)

  - `Tau.Factory.Unit.start_link/1` accepts a NEW optional `:ledger` opt
    (`GenServer.server()`). When present, EVERY Unit state transition durably
    writes the post-transition FSM state via
    `Ledger.Writer.snapshot_unit(ledger, %{unit_id:, state:, idempotency_key:})`
    BEFORE the transition's external effect (SPEC §5 line 391).
  - The `state` written is the Unit FSM state atom, drawn from the §4 B3
    enumeration: `planned | oracle | implementing | gating | refine_k |
    awaiting_merge | merged | escalated`.
  - `idempotency_key` is deterministic per `{unit_id, kind, coordinate}` so a
    replayed same-state write is a no-op (§4 B3, D-315): re-entering or
    re-snapshotting the same coordinate does not corrupt the latest-state read.
  - The durable read op `Ledger.Reader.latest_unit_snapshots/1` returns
    `%{unit_id => latest_state_atom}` (highest row id wins, §4 B3).

  ## Fail-before validity (oracle separation, factory-loop §4b)

  On THIS branch (no implementer yet) the Unit never calls `snapshot_unit/2`, so
  `latest_unit_snapshots(ledger)` is EMPTY for every unit driven here — each
  assertion that L contains the unit's state FAILS. The test passes only once the
  Unit writes a durable snapshot on each transition. A test that passed against
  the current (non-snapshotting) Unit would be vacuous.

  SPEC sources (docs/spec/SPEC-FACTORY-CORE.md):
    - §4 component table C6: Unit "snapshots each transition to L".
    - §4 B3 `snapshot_unit/2` / `latest_unit_snapshots/1` (pinned attrs + read).
    - §5 Unit state enumeration, line 391: "Every transition `snapshot_unit/2`s
      durable state to L before its external effect (D-315, LIV-5)."
    - §6 D-318 (bounded laddered retry — the durable PR state), D-344 (recovery
      progress depends on real units persisting their state).

  AC/D-NNN linkage: D-318, D-344.
  """

  use ExUnit.Case, async: false

  alias Tau.Factory.Ledger.Reader, as: LedgerReader
  alias Tau.Factory.Ledger.Writer, as: LedgerWriter

  @moduletag :capture_log
  @moduletag :d_318
  @moduletag :d_344

  @unit_supervisor Tau.Factory.UnitSupervisor
  @scheduler Tau.Factory.Scheduler

  # Terminal sinks per §5 / §4 B3.
  @terminal_states [:merged, :escalated]

  # The non-terminal FSM states a Unit may snapshot before a terminal sink.
  @non_terminal_states [:planned, :oracle, :implementing, :gating, :awaiting_merge]

  # ---------------------------------------------------------------------------
  # Helpers (mirror unit_termination_test.exs for the FSM drive idiom, plus the
  # coordinator_recovery_test.exs idiom for a real supervised Ledger.Writer).
  # ---------------------------------------------------------------------------

  defp unique(base), do: :"#{base}_#{System.unique_integer([:positive])}"

  # Start a REAL Ledger.Writer against an isolated temp DB; return its name.
  defp start_ledger do
    db_path = Briefly.create!(extname: ".db")
    writer_name = unique(:snap_ledger)

    start_supervised!(
      {LedgerWriter, db_path: db_path, name: writer_name},
      id: writer_name
    )

    writer_name
  end

  defp empty_scope do
    %{
      deps: [],
      files: MapSet.new(),
      codepoints: MapSet.new(),
      specs: MapSet.new(),
      resources: MapSet.new()
    }
  end

  defp start_scheduler(name) do
    start_supervised!({@scheduler, name: name, w_cap: 10}, id: name)
  end

  # A long-lived worker process the Unit monitors via Process.monitor/1.
  defp spawn_worker do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  # Base Unit opts with the NEW :ledger opt injected (pinned contract).
  defp base_unit_opts(unit_id, scheduler_name, report_to, ledger, overrides) do
    defaults = [
      unit_id: unit_id,
      declared_scope: empty_scope(),
      hash: "hash-#{unit_id}",
      scheduler: scheduler_name,
      report_to: report_to,
      ledger: ledger,
      worker_fun: fn _role -> {:ok, spawn_worker()} end,
      gate_fun: fn -> :pass end,
      merge_fun: fn _uid, _hash -> :queued end,
      timeouts: [state_timeout_ms: 5_000]
    ]

    Keyword.merge(defaults, overrides)
  end

  # Deliver {:worker_done, worker_pid} for whichever worker the FSM is waiting on
  # (oracle or implementing). Reads :worker_pid from FSM state data (pinned seam).
  defp deliver_worker_done(unit_pid) do
    :timer.sleep(50)

    case :sys.get_state(unit_pid) do
      {state, data} when state in [:oracle, :implementing] ->
        worker_pid = Map.get(data, :worker_pid)
        if is_pid(worker_pid), do: send(unit_pid, {:worker_done, worker_pid})

      _ ->
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # D-318a — Terminal transition is durably snapshotted to L.
  #
  # Drive a real Unit to :merged. Assert latest_unit_snapshots/1 holds
  # unit_id => :merged. On a non-snapshotting Unit, L is empty → FAIL.
  # ---------------------------------------------------------------------------

  describe "D-318 — the terminal transition is durably snapshotted to the Ledger" do
    @tag :d_318
    @tag :d_344
    test "D-318: a Unit driven to :merged leaves unit_id => :merged in latest_unit_snapshots/1" do
      ledger = start_ledger()
      test_pid = self()
      unit_id = "u-snap-merged-#{System.unique_integer([:positive])}"
      sched = unique(:sched_snap_merged)
      sup = unique(:sup_snap_merged)
      start_scheduler(sched)
      start_supervised!({@unit_supervisor, name: sup}, id: sup)

      opts =
        base_unit_opts(unit_id, sched, test_pid, ledger,
          gate_fun: fn -> :pass end,
          merge_fun: fn _uid, _hash -> :queued end
        )

      unit_pid = @unit_supervisor.start_unit(sup, opts)
      assert is_pid(unit_pid)

      # oracle → implementing → gating(:pass) → awaiting_merge.
      deliver_worker_done(unit_pid)
      :timer.sleep(50)
      deliver_worker_done(unit_pid)
      :timer.sleep(100)

      # Terminal: deliver :merged.
      send(unit_pid, {:merge_result, :merged})

      assert_receive {:unit_terminal, ^unit_id, :merged, _provenance}, 5_000

      # Give the terminal transition's durable snapshot time to land.
      :timer.sleep(100)

      snapshots = LedgerReader.latest_unit_snapshots(ledger)

      assert Map.get(snapshots, unit_id) == :merged,
             "D-318: the terminal transition must be durably snapshotted to L; " <>
               "expected latest_unit_snapshots[#{inspect(unit_id)}] == :merged, " <>
               "got #{inspect(Map.get(snapshots, unit_id))} (full map: #{inspect(snapshots)}). " <>
               "An empty/missing entry means the Unit never called snapshot_unit/2 — " <>
               "the absence this test exists to catch."
    end
  end

  # ---------------------------------------------------------------------------
  # D-318b — Escalation terminal is durably snapshotted (second terminal path).
  # ---------------------------------------------------------------------------

  describe "D-318 — the escalation terminal is durably snapshotted to the Ledger" do
    @tag :d_318
    @tag :d_344
    test "D-318: a Unit driven to :escalated leaves unit_id => :escalated in latest_unit_snapshots/1" do
      ledger = start_ledger()
      test_pid = self()
      unit_id = "u-snap-esc-#{System.unique_integer([:positive])}"
      sched = unique(:sched_snap_esc)
      sup = unique(:sup_snap_esc)
      start_scheduler(sched)
      start_supervised!({@unit_supervisor, name: sup}, id: sup)

      # gate always fails → ladder exhausts → :escalated.
      gate_fun = fn -> {:fail, ["always-fail"]} end

      opts =
        base_unit_opts(unit_id, sched, test_pid, ledger,
          gate_fun: gate_fun,
          merge_fun: fn _uid, _hash -> :queued end
        )

      unit_pid = @unit_supervisor.start_unit(sup, opts)
      assert is_pid(unit_pid)

      # Drive oracle + every implementing attempt to exhaust the retry ladder.
      for _i <- 1..9 do
        deliver_worker_done(unit_pid)
        :timer.sleep(60)
      end

      assert_receive {:unit_terminal, ^unit_id, :escalated, _provenance}, 10_000

      :timer.sleep(100)

      snapshots = LedgerReader.latest_unit_snapshots(ledger)

      assert Map.get(snapshots, unit_id) == :escalated,
             "D-318: the :escalated terminal transition must be durably snapshotted to L; " <>
               "expected latest_unit_snapshots[#{inspect(unit_id)}] == :escalated, " <>
               "got #{inspect(Map.get(snapshots, unit_id))} (full map: #{inspect(snapshots)})."
    end
  end

  # ---------------------------------------------------------------------------
  # D-318c / D-344 — MID-FLIGHT durability across a crash (load-bearing oracle).
  #
  # Drive a real Unit to a NON-terminal state (:gating, reached when gate_fun
  # blocks) then HARD-KILL the Unit process. Because each transition is durably
  # snapshotted BEFORE its external effect (SPEC §5 line 391), L must still hold
  # a readable snapshot for the unit at a non-terminal state — survived the
  # crash. This is exactly the state the Coordinator's D-344 resume rehydrates.
  #
  # On a non-snapshotting Unit, L holds NOTHING for this unit after the kill → the
  # assertion that L has the unit at a non-terminal state FAILS.
  # ---------------------------------------------------------------------------

  describe "D-318 / D-344 — a mid-flight Unit killed before terminal leaves a durable snapshot in L" do
    @tag :d_318
    @tag :d_344
    test "D-318/D-344: a Unit blocked at :gating then hard-killed still has a non-terminal snapshot in L" do
      ledger = start_ledger()
      test_pid = self()
      unit_id = "u-snap-crash-#{System.unique_integer([:positive])}"
      sched = unique(:sched_snap_crash)
      sup = unique(:sup_snap_crash)
      start_scheduler(sched)
      start_supervised!({@unit_supervisor, name: sup}, id: sup)

      # gate_fun BLOCKS so the FSM parks in :gating (a non-terminal state) and
      # never reaches a terminal sink. We signal entry to gating, then block.
      gate_entered = self()

      gate_fun = fn ->
        send(gate_entered, :gate_entered)

        receive do
          :never -> :pass
        end
      end

      opts =
        base_unit_opts(unit_id, sched, test_pid, ledger,
          gate_fun: gate_fun,
          merge_fun: fn _uid, _hash -> :queued end,
          # Long timeout: the FSM must PARK in :gating, not time out.
          timeouts: [state_timeout_ms: 60_000]
        )

      unit_pid = @unit_supervisor.start_unit(sup, opts)
      assert is_pid(unit_pid)

      # oracle → implementing → (enter gating).
      deliver_worker_done(unit_pid)
      :timer.sleep(50)
      deliver_worker_done(unit_pid)

      # Confirm the FSM has entered :gating (the gate_fun is now blocked).
      assert_receive :gate_entered,
                     5_000,
                     "FSM never entered :gating — cannot exercise mid-flight durability"

      # Allow the entry-snapshot for the in-flight state to be durably written.
      :timer.sleep(150)

      # HARD-KILL the Unit mid-flight (a crash). It is :temporary under the
      # DynamicSupervisor, so it is not restarted; the test process is unaffected.
      Process.exit(unit_pid, :kill)
      refute Process.alive?(unit_pid)

      # The durable snapshot MUST survive the crash and be readable from L.
      snapshots = LedgerReader.latest_unit_snapshots(ledger)
      persisted = Map.get(snapshots, unit_id)

      assert persisted != nil,
             "D-318/D-344: a Unit killed mid-flight must have left a durable snapshot " <>
               "in L (snapshot_unit/2 on each transition, BEFORE the external effect — " <>
               "SPEC §5 line 391). latest_unit_snapshots had no entry for " <>
               "#{inspect(unit_id)} (full map: #{inspect(snapshots)}) — the Unit never " <>
               "persisted its state, so D-344 resume could never rehydrate a real unit."

      refute persisted in @terminal_states,
             "D-318/D-344: the unit was killed BEFORE any terminal sink, so its durable " <>
               "snapshot must be a non-terminal state; got #{inspect(persisted)}."

      assert persisted in @non_terminal_states,
             "D-318/D-344: the durable mid-flight snapshot must be a recognised non-terminal " <>
               "FSM state (one of #{inspect(@non_terminal_states)}); got #{inspect(persisted)}."
    end
  end

  # ---------------------------------------------------------------------------
  # D-318d — Idempotence: same-coordinate / repeated snapshots do not corrupt or
  # duplicate the latest-state read.
  #
  # Drive a Unit to :merged (terminal). The merged snapshot is the latest. Re-read
  # latest_unit_snapshots/1 several times and assert the latest stays :merged — a
  # single stable terminal entry per unit_id (highest-id-wins, INSERT OR IGNORE
  # idempotency per §4 B3). A non-idempotent writer would either drift the latest
  # state or duplicate rows that break highest-id-wins.
  # ---------------------------------------------------------------------------

  describe "D-318 — repeated/same-state snapshots are idempotent in the latest read" do
    @tag :d_318
    @tag :d_344
    test "D-318: the latest snapshot for a merged unit stays :merged across repeated reads (idempotent)" do
      ledger = start_ledger()
      test_pid = self()
      unit_id = "u-snap-idem-#{System.unique_integer([:positive])}"
      sched = unique(:sched_snap_idem)
      sup = unique(:sup_snap_idem)
      start_scheduler(sched)
      start_supervised!({@unit_supervisor, name: sup}, id: sup)

      opts =
        base_unit_opts(unit_id, sched, test_pid, ledger,
          gate_fun: fn -> :pass end,
          merge_fun: fn _uid, _hash -> :queued end
        )

      unit_pid = @unit_supervisor.start_unit(sup, opts)
      assert is_pid(unit_pid)

      deliver_worker_done(unit_pid)
      :timer.sleep(50)
      deliver_worker_done(unit_pid)
      :timer.sleep(100)

      send(unit_pid, {:merge_result, :merged})
      assert_receive {:unit_terminal, ^unit_id, :merged, _provenance}, 5_000
      :timer.sleep(100)

      # Re-read several times; idempotent writer keeps a single stable latest entry.
      reads =
        for _ <- 1..5 do
          Map.get(LedgerReader.latest_unit_snapshots(ledger), unit_id)
        end

      assert Enum.all?(reads, &(&1 == :merged)),
             "D-318: the latest snapshot for a merged unit must stay :merged across " <>
               "repeated reads (idempotent, highest-id-wins per §4 B3); got #{inspect(reads)}."
    end
  end
end
