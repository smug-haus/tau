defmodule Tau.Factory.InvDsDecisionReplayableTest do
  @moduledoc """
  Gating test for issue #545 — INV-DS-DECISION-REPLAYABLE.

  ## Invariant

  **INV-DS-DECISION-REPLAYABLE:** The decision log is replayable: re-reading the
  durable decision log reconstructs the orchestrator's state exactly, without
  re-executing any nondeterministic step. Falsified if recovery requires running an
  LLM, git command, or other nondeterministic activity to reconstruct in-flight unit
  state.

  ## The gap this test closes

  The `unit_snapshots` table (migrations.ex:74-80) has columns
  `(id, unit_id, state, idempotency_key, frozen_scope, inserted_at)` — NO `head_sha`
  column. `do_snapshot_unit` (writer.ex:642-677) never writes the gate/merge
  coordinate.

  `data.head_sha` (unit.ex:204) is initialised to `nil` and populated ONLY from the
  runtime `{:work_ready, worker_id, branch, head_sha}` message (unit.ex:268, 411) —
  a nondeterministic step that requires a live worker to reproduce.

  The gate (unit.ex:577) and merge (unit.ex:633) both compute:

      coordinate = data.head_sha || data.hash

  After a crash while the Unit is in-flight at `:gating` or `:awaiting_merge`, the
  Coordinator rehydrates the Unit at the snapshotted FSM state (D-344) but the
  gate/merge coordinate (`head_sha`) is ABSENT from the durable log. Reconstructing
  it requires the new worker to re-send `work_ready` — a nondeterministic activity.

  This violates INV-DS-DECISION-REPLAYABLE: a decision (the gate/merge coordinate)
  was not durably persisted and cannot be recovered without a nondeterministic step.

  ## What the conformant implementation must do

  `snapshot_unit/2` must persist the gate/merge coordinate (`head_sha`) so that after
  a crash the Coordinator can reconstruct the full in-flight Unit state from the
  Ledger alone.

  The reader contract:

      Ledger.Reader.coordinate_for(server, unit_id) :: {:ok, String.t()} | :none

  Returns `{:ok, coordinate}` where `coordinate` is the persisted `head_sha` (or the
  declared `hash` if `head_sha` was never captured), or `:none` if no snapshot exists.

  ## Fail-before validity (oracle separation)

  `Ledger.Reader.coordinate_for/2` does not exist in the current codebase. Calling it
  raises `UndefinedFunctionError`, which is the correct fail-before state. The test
  also asserts that the coordinate returned equals the asserted `head_sha` — which
  would fail even if a stub returning `:none` were present.

  ## AC/D-NNN linkage

  INV-DS-DECISION-REPLAYABLE (#545)
  """

  use ExUnit.Case, async: false

  alias Tau.Factory.Ledger.Reader, as: LedgerReader
  alias Tau.Factory.Ledger.Writer, as: LedgerWriter

  @moduletag :capture_log
  @moduletag :inv_ds_decision_replayable

  @unit_supervisor Tau.Factory.UnitSupervisor
  @scheduler Tau.Factory.Scheduler

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique(base), do: :"#{base}_#{System.unique_integer([:positive])}"

  defp start_ledger do
    db_path = Briefly.create!(extname: ".db")
    writer_name = unique(:inv_replayable_ledger)

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

  # A long-lived worker that parks until stopped.
  defp spawn_worker do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  # Drive oracle to implementing via the legacy 2-tuple seam.
  defp advance_oracle(unit_pid) do
    :timer.sleep(60)

    case :sys.get_state(unit_pid) do
      {:oracle, data} ->
        worker_pid = Map.get(data, :worker_pid)
        if is_pid(worker_pid), do: send(unit_pid, {:worker_done, worker_pid})

      _ ->
        :ok
    end

    :timer.sleep(80)
  end

  # Poll until the Unit reaches `target_state` or `max_ms` elapses.
  defp wait_for_state(unit_pid, target_state, max_ms \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + max_ms

    Stream.repeatedly(fn ->
      case :sys.get_state(unit_pid) do
        {^target_state, _} -> :reached
        _ -> :not_yet
      end
    end)
    |> Enum.find_value(fn
      :reached ->
        true

      :not_yet ->
        if System.monotonic_time(:millisecond) < deadline do
          :timer.sleep(20)
          nil
        else
          false
        end
    end)
  end

  # ---------------------------------------------------------------------------
  # INV-DS-DECISION-REPLAYABLE — the gate/merge coordinate (head_sha) is durably
  # persisted and recoverable from the Ledger after a crash, WITHOUT re-running
  # any nondeterministic step.
  #
  # Drive a REAL Unit to :gating (where data.head_sha has been captured from the
  # 3-tuple work_ready seam), hard-kill it, then read the coordinate back from the
  # Ledger via Ledger.Reader.coordinate_for/2.
  #
  # Current failure mode: Ledger.Reader.coordinate_for/2 is undefined ->
  # UndefinedFunctionError. Even if a stub existed, the snapshot table has no
  # head_sha column, so no coordinate can be returned.
  # ---------------------------------------------------------------------------

  describe "INV-DS-DECISION-REPLAYABLE -- gate/merge coordinate survives a crash in the durable log" do
    @tag :inv_ds_decision_replayable
    test "INV-DS-DECISION-REPLAYABLE: head_sha captured from work_ready is readable from the Ledger after a hard kill" do
      ledger = start_ledger()
      test_pid = self()

      unit_id = "u-inv-replayable-#{System.unique_integer([:positive])}"
      sched = unique(:sched_inv_replayable)
      sup = unique(:sup_inv_replayable)

      start_scheduler(sched)
      start_supervised!({@unit_supervisor, name: sup}, id: sup)

      # The coordinate the 3-tuple worker asserts. Deliberately different from the
      # declared hash so the test can distinguish which value was persisted.
      declared_hash = "declared-hash-inv-replayable-#{System.unique_integer([:positive])}"
      asserted_head_sha = "agent-sha-inv-replayable-#{System.unique_integer([:positive])}"
      asserted_branch = "feat/inv-ds-decision-replayable-branch"

      refute declared_hash == asserted_head_sha,
             "Test setup: declared_hash and asserted_head_sha must differ to make the " <>
               "INV-DS-DECISION-REPLAYABLE assertion meaningful"

      # Store the worker_id so we can send work_ready from outside the worker_fun.
      {:ok, worker_id_store} = Agent.start_link(fn -> nil end)
      on_exit(fn -> if Process.alive?(worker_id_store), do: Agent.stop(worker_id_store) end)

      worker_fun = fn role ->
        worker_pid = spawn_worker()

        case role do
          :test_author ->
            # oracle uses the legacy 2-tuple seam (no worker_id needed).
            {:ok, worker_pid}

          :implementer ->
            worker_id = "wid-inv-replayable-#{System.unique_integer([:positive])}"
            Agent.update(worker_id_store, fn _ -> worker_id end)
            # 3-tuple seam: returns worker_id so Unit can match work_ready.
            {:ok, worker_pid, worker_id}
        end
      end

      # gate_fun BLOCKS so the Unit parks in :gating, never reaching a terminal sink.
      # This ensures we can kill it mid-flight at :gating (where head_sha was captured).
      gate_entered = self()

      gate_fun = fn _coord ->
        send(gate_entered, :gate_entered)

        receive do
          :never -> :pass
        end
      end

      opts = [
        unit_id: unit_id,
        declared_scope: empty_scope(),
        hash: declared_hash,
        scheduler: sched,
        report_to: test_pid,
        ledger: ledger,
        worker_fun: worker_fun,
        gate_fun: gate_fun,
        merge_fun: fn _uid, _hash -> :queued end,
        timeouts: [state_timeout_ms: 60_000]
      ]

      unit_pid = @unit_supervisor.start_unit(sup, opts)
      assert is_pid(unit_pid), "Unit must start successfully"

      # Drive oracle through (legacy seam).
      advance_oracle(unit_pid)

      assert wait_for_state(unit_pid, :implementing),
             "INV-DS-DECISION-REPLAYABLE: Unit must reach :implementing after oracle completes"

      # Retrieve the worker_id set by the 3-tuple implementer worker_fun.
      worker_id = Agent.get(worker_id_store, & &1)
      refute is_nil(worker_id), "worker_id must be set by the 3-tuple implementer worker_fun"

      # Deliver work_ready with the asserted coordinate — this is the nondeterministic
      # step that captures head_sha into data. The Unit will transition to :gating and
      # call gate_fun, which blocks.
      send(unit_pid, {:work_ready, worker_id, asserted_branch, asserted_head_sha})

      # Wait for :gating (confirmed via the gate_fun entry signal).
      assert_receive :gate_entered,
                     5_000,
                     "INV-DS-DECISION-REPLAYABLE: Unit must enter :gating (gate_fun must be called). " <>
                       "Without this the head_sha capture has not yet been exercised."

      # Allow the :gating entry-snapshot to be written to the Ledger before killing
      # the process. The snapshot MUST include head_sha for the invariant to hold.
      :timer.sleep(200)

      # HARD-KILL the Unit mid-flight at :gating. This simulates a crash.
      # The Unit is :temporary under the DynamicSupervisor -- it will not be restarted.
      Process.exit(unit_pid, :kill)
      refute Process.alive?(unit_pid), "Unit must be dead after hard kill"

      # POST-CRASH REPLAY: read the gate/merge coordinate from the Ledger alone.
      # INV-DS-DECISION-REPLAYABLE requires that no nondeterministic step (no new
      # worker, no git command, no LLM call) is needed to reconstruct this value.
      #
      # The conformant implementation must:
      #   1. Persist head_sha in unit_snapshots (via snapshot_unit/2 at :gating entry),
      #   2. Expose it via Ledger.Reader.coordinate_for(server, unit_id).
      #
      # Current failure: Ledger.Reader.coordinate_for/2 is UNDEFINED ->
      # UndefinedFunctionError (correct fail-before state for oracle separation).
      result = LedgerReader.coordinate_for(ledger, unit_id)

      assert match?({:ok, _}, result),
             "INV-DS-DECISION-REPLAYABLE: Ledger.Reader.coordinate_for/2 must return " <>
               "{:ok, coordinate} for a unit that was in-flight at :gating when it crashed. " <>
               "Got: #{inspect(result)}. " <>
               "A return of :none or an UndefinedFunctionError means the coordinate was not " <>
               "durably persisted -- reconstructing it would require re-running the nondeterministic " <>
               "work_ready step, violating INV-DS-DECISION-REPLAYABLE."

      {:ok, persisted_coordinate} = result

      assert persisted_coordinate == asserted_head_sha,
             "INV-DS-DECISION-REPLAYABLE: the persisted coordinate must equal the agent-asserted " <>
               "head_sha (\"#{asserted_head_sha}\"), NOT the pre-declared hash (\"#{declared_hash}\") " <>
               "and NOT nil. Got: #{inspect(persisted_coordinate)}. " <>
               "The coordinate (head_sha) is the gate/merge key; after a crash the Coordinator " <>
               "must recover it from the Ledger to resume gating without re-executing any " <>
               "nondeterministic step (INV-DS-DECISION-REPLAYABLE, durable-spine.md S1)."

      refute persisted_coordinate == declared_hash,
             "INV-DS-DECISION-REPLAYABLE: the persisted coordinate must be the captured head_sha, " <>
               "not the pre-declared work_item.hash. If the declared hash is returned, snapshot_unit/2 " <>
               "is writing the fallback (data.hash) rather than the captured coordinate (data.head_sha)."
    end
  end

  # ---------------------------------------------------------------------------
  # INV-DS-DECISION-REPLAYABLE -- coordinate_for MUST return :none when no
  # snapshot exists (fresh Ledger). Guards against a stub that always returns
  # {:ok, _} regardless of the unit_id, making the positive test vacuous.
  # ---------------------------------------------------------------------------

  describe "INV-DS-DECISION-REPLAYABLE -- coordinate_for returns :none on a fresh Ledger" do
    @tag :inv_ds_decision_replayable
    test "INV-DS-DECISION-REPLAYABLE: coordinate_for returns :none when no snapshot exists for a unit_id" do
      ledger = start_ledger()

      unknown_unit_id = "u-inv-replayable-unknown-#{System.unique_integer([:positive])}"

      # On a fresh Ledger with no snapshots, coordinate_for must return :none.
      # Current failure: Ledger.Reader.coordinate_for/2 is UNDEFINED.
      result = LedgerReader.coordinate_for(ledger, unknown_unit_id)

      assert result == :none,
             "INV-DS-DECISION-REPLAYABLE: Ledger.Reader.coordinate_for/2 must return :none " <>
               "when no snapshot exists for the given unit_id (fresh Ledger). " <>
               "Got: #{inspect(result)}."
    end
  end
end
