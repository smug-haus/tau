defmodule Tau.Factory.LedgerFrozenScopeTest do
  @moduledoc """
  Gating test for issue #584 — HR-4: a unit's declared file set and
  gating-test paths are frozen at admission and stored in the Ledger
  (frozen_scope). Falsified if the scope changes after admission or
  if the gating-test path set is not persisted in the Ledger.

  ## What this enforces

  **HR-4 (durable-spine.md §3 `units` schema):** the `units` table carries a
  `frozen_scope` column — `declared file set + declared gating-test paths`.
  The Ledger's `frozen_scope_for/2` read-op MUST return the scope that was
  present at unit admission (the `declared_scope` + `gating_test_paths`
  supplied to `Unit.start_link/1`).

  The audit finding (issue #584) confirms:

  1. `unit_snapshots` CREATE TABLE (migrations.ex:72-81): columns are only
     `(id, unit_id, state, idempotency_key, inserted_at)` — no `frozen_scope`,
     `declared_scope`, or `gating_paths` column.

  2. `do_snapshot_unit/2` (writer.ex:550-575): binds exactly
     `[unit_id, state_text, idempotency_key]` — no scope binding.

  3. `Unit.init/1` (unit.ex:152-195): `declared_scope` is held in-memory
     only (line 154); a crash loses it.

  ## Fail-before validity (oracle separation)

  On this branch `Ledger.Reader.frozen_scope_for/2` does not exist and
  `snapshot_unit/2` accepts no scope fields — this test will fail with
  `UndefinedFunctionError` until the implementer:
    a. Adds a `frozen_scope` column (or table) to the Ledger schema.
    b. Extends `snapshot_unit/2` (or adds a new API) to persist the scope.
    c. Adds `Ledger.Reader.frozen_scope_for/2` to read it back.
    d. Wires `Unit.start_link/1` to persist the scope at the first
       `planned` snapshot (i.e., at admission).

  A test that passes against the current (non-persisting) implementation
  would be vacuous and a gate bypass.

  ## Entry point

  Exercises the real boundary: `UnitSupervisor.start_unit/2` →
  `Unit.start_link/1` (with `:ledger` and `:gating_test_paths` opts) →
  `Ledger.Writer` (extended for scope) → `Ledger.Reader.frozen_scope_for/2`.

  Does NOT use a hand-built struct bypassing the real path.

  AC/D-NNN linkage: HR-4.
  """

  use ExUnit.Case, async: false

  alias Tau.Factory.Ledger.Reader, as: LedgerReader
  alias Tau.Factory.Ledger.Writer, as: LedgerWriter

  @moduletag :capture_log
  @moduletag :hr_4

  @unit_supervisor Tau.Factory.UnitSupervisor
  @scheduler Tau.Factory.Scheduler

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique(base), do: :"#{base}_#{System.unique_integer([:positive])}"

  defp start_ledger do
    db_path = Briefly.create!(extname: ".db")
    writer_name = unique(:hr4_ledger)

    start_supervised!(
      {LedgerWriter, db_path: db_path, name: writer_name},
      id: writer_name
    )

    writer_name
  end

  # A ConflictCheck.scope() struct matching the B10/I2 contract.
  defp declared_scope(extra_files \\ []) do
    base_files = MapSet.new(["lib/tau/factory/coordinator.ex" | extra_files])

    %{
      deps: [],
      files: base_files,
      codepoints: MapSet.new(),
      specs: MapSet.new(),
      resources: MapSet.new()
    }
  end

  defp start_scheduler(name) do
    start_supervised!({@scheduler, name: name, w_cap: 10}, id: name)
  end

  defp spawn_worker do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  # Base Unit opts. `:gating_test_paths` is the NEW field required by HR-4.
  defp unit_opts(unit_id, sched, ledger, scope, gating_test_paths) do
    [
      unit_id: unit_id,
      declared_scope: scope,
      gating_test_paths: gating_test_paths,
      hash: "hash-#{unit_id}",
      scheduler: sched,
      report_to: self(),
      ledger: ledger,
      worker_fun: fn _role -> {:ok, spawn_worker()} end,
      gate_fun: fn _coord -> :pass end,
      merge_fun: fn _uid, _hash -> :queued end,
      timeouts: [state_timeout_ms: 10_000]
    ]
  end

  # ---------------------------------------------------------------------------
  # HR-4 — frozen_scope is persisted at admission (planned entry) and readable
  # from the Ledger via frozen_scope_for/2.
  #
  # On the current branch both frozen_scope_for/2 and the schema column are
  # absent, so this test fails with UndefinedFunctionError. That is the
  # correct fail-before state — a vacuous-pass would be a gate bypass.
  # ---------------------------------------------------------------------------

  describe "HR-4 — frozen_scope is persisted in the Ledger at unit admission" do
    @tag :hr_4
    test "HR-4: frozen_scope_for/2 returns the declared_scope and gating_test_paths after a unit is admitted" do
      ledger = start_ledger()
      unit_id = "u-hr4-scope-#{System.unique_integer([:positive])}"
      sched = unique(:sched_hr4_scope)
      sup = unique(:sup_hr4_scope)
      start_scheduler(sched)
      start_supervised!({@unit_supervisor, name: sup}, id: sup)

      scope = declared_scope(["lib/tau/factory/unit.ex"])
      gating_paths = ["test/tau/factory/ledger_frozen_scope_test.exs"]

      unit_pid =
        @unit_supervisor.start_unit(
          sup,
          unit_opts(unit_id, sched, ledger, scope, gating_paths)
        )

      assert is_pid(unit_pid)

      # Allow the :planned entry snapshot (admission) to land in the Ledger.
      :timer.sleep(150)

      # HR-4: the Ledger MUST expose frozen_scope_for/2 and it MUST return the
      # declared_scope and gating_test_paths supplied at start_link time.
      #
      # On the current branch this fails with UndefinedFunctionError because:
      #   - Ledger.Reader.frozen_scope_for/2 does not exist
      #   - unit_snapshots table has no frozen_scope column
      #   - snapshot_unit/2 does not accept or persist scope fields
      result = LedgerReader.frozen_scope_for(ledger, unit_id)

      assert result != :none,
             "HR-4: frozen_scope_for/2 returned :none for unit #{inspect(unit_id)}. " <>
               "The Ledger has no frozen_scope persisted — the unit's declared file set " <>
               "and gating-test paths were NOT durably stored at admission. " <>
               "This is exactly the gap the HR-4 audit finding (issue #584) documents: " <>
               "unit_snapshots has no frozen_scope column (migrations.ex:72-81) and " <>
               "do_snapshot_unit/2 binds no scope (writer.ex:550-575)."

      {:ok, frozen} = result

      # The frozen scope must carry the declared files.
      assert Map.get(frozen, :files) == scope.files,
             "HR-4: frozen_scope.files mismatch. " <>
               "Expected #{inspect(scope.files)}, got #{inspect(Map.get(frozen, :files))}. " <>
               "The declared file set was not faithfully persisted at admission."

      # The frozen scope must carry the declared gating-test paths.
      assert Map.get(frozen, :gating_test_paths) == gating_paths,
             "HR-4: frozen_scope.gating_test_paths mismatch. " <>
               "Expected #{inspect(gating_paths)}, got #{inspect(Map.get(frozen, :gating_test_paths))}. " <>
               "The gating-test path set was not faithfully persisted — " <>
               "a crash after admission would lose the paths the Gate mutation check keys on."
    end

    @tag :hr_4
    test "HR-4: frozen_scope survives a Ledger.Writer process restart (RPO=0, D-315)" do
      # The frozen_scope must be WAL-committed (D-315) — it must survive a
      # Writer process restart, not only a process-alive read.
      db_path = Briefly.create!(extname: ".db")
      writer_name = unique(:hr4_wal_writer)

      start_supervised!(
        {LedgerWriter, db_path: db_path, name: writer_name},
        id: writer_name
      )

      unit_id = "u-hr4-wal-#{System.unique_integer([:positive])}"
      sched = unique(:sched_hr4_wal)
      sup = unique(:sup_hr4_wal)
      start_scheduler(sched)
      start_supervised!({@unit_supervisor, name: sup}, id: sup)

      scope = declared_scope()
      gating_paths = ["test/tau/factory/my_gating_test.exs"]

      unit_pid =
        @unit_supervisor.start_unit(
          sup,
          unit_opts(unit_id, sched, writer_name, scope, gating_paths)
        )

      assert is_pid(unit_pid)

      # Allow the :planned snapshot to land.
      :timer.sleep(150)

      # Kill and restart the Ledger.Writer — frozen_scope must survive the restart.
      stop_supervised!(writer_name)

      start_supervised!(
        {LedgerWriter, db_path: db_path, name: writer_name},
        id: writer_name
      )

      # HR-4 + D-315: the frozen_scope MUST still be readable from the fresh writer.
      result = LedgerReader.frozen_scope_for(writer_name, unit_id)

      assert result != :none,
             "HR-4 / D-315: frozen_scope_for/2 returned :none after Writer restart. " <>
               "The frozen_scope was either never persisted or not WAL-committed before ack. " <>
               "A crash-recovered Coordinator cannot reconstruct the conflict check without " <>
               "this data — Scheduler.admit/3 would re-admit with an empty scope (livelock risk)."

      {:ok, frozen} = result

      assert Map.get(frozen, :gating_test_paths) == gating_paths,
             "HR-4 / D-315: gating_test_paths not durable across Writer restart. " <>
               "Expected #{inspect(gating_paths)}, got #{inspect(Map.get(frozen, :gating_test_paths))}."
    end

    @tag :hr_4
    test "HR-4: frozen_scope is immutable after admission — only the original scope is in the Ledger" do
      # Pins the read-once contract: the scope written at admission is the
      # scope returned by frozen_scope_for/2. No post-admission mutation is
      # possible because the Ledger is append-only (D-335).
      ledger = start_ledger()
      unit_id = "u-hr4-immut-#{System.unique_integer([:positive])}"
      sched = unique(:sched_hr4_immut)
      sup = unique(:sup_hr4_immut)
      start_scheduler(sched)
      start_supervised!({@unit_supervisor, name: sup}, id: sup)

      original_scope = declared_scope(["lib/tau/factory/ledger/writer.ex"])
      gating_paths = ["test/tau/factory/ledger_frozen_scope_test.exs"]

      unit_pid =
        @unit_supervisor.start_unit(
          sup,
          unit_opts(unit_id, sched, ledger, original_scope, gating_paths)
        )

      assert is_pid(unit_pid)

      # Allow admission snapshot to land.
      :timer.sleep(150)

      result = LedgerReader.frozen_scope_for(ledger, unit_id)

      assert result != :none,
             "HR-4: no frozen_scope persisted for #{inspect(unit_id)} — " <>
               "admission did not durably write the scope."

      {:ok, frozen} = result

      # The scope MUST match exactly what was declared at start_link time.
      assert Map.get(frozen, :files) == original_scope.files,
             "HR-4 (immutability): frozen_scope.files does not match the original " <>
               "declared_scope. Expected #{inspect(original_scope.files)}, " <>
               "got #{inspect(Map.get(frozen, :files))}. The scope was either not " <>
               "persisted at admission or was mutated post-admission — both violate HR-4."
    end
  end
end
