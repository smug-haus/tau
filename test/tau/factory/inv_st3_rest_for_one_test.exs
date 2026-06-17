defmodule Tau.Factory.InvSt3RestForOneTest do
  @moduledoc """
  Gating test for issue #558 — **INV-ST-3** (rest_for_one spine).

  Pins the invariant:

  > `Tau.Factory.Supervisor` MUST use `:rest_for_one` strategy so that a crash
  > of any earlier child restarts all later children.

  ## What this exercises

  The `init_ledger_only/1` path (the default / `enabled: false` path) uses
  `:one_for_one` (line 150). When `coordinator_opts` are provided, the
  `maybe_add_coordinator/5` helper appends `Tau.Factory.Coordinator` as a
  later sibling under that `:one_for_one` supervisor. Under `:one_for_one`,
  killing `Tau.Factory.Ledger.Writer` (an earlier child that the Coordinator
  depends on) does NOT restart the Coordinator — the Coordinator survives with
  a stale reference to the now-dead writer.

  Under `:rest_for_one`, killing the Writer MUST restart all later children,
  including the Coordinator. This test asserts that behaviour by:

  1. Starting `Tau.Factory.Supervisor` via the real `start_link/1` with
     `enabled: false` (the ledger-only / default path) AND with
     `coordinator_opts` so the Coordinator is appended as a downstream child.
  2. Capturing the pids of both the Writer and the Coordinator.
  3. Killing the Writer with `:kill`.
  4. Asserting that the Coordinator's registered name resolves to a **new pid**
     after the Writer's restart — confirming `:rest_for_one` cascaded the restart
     to the downstream Coordinator.

  The test FAILS today because `init_ledger_only/1` uses `:one_for_one`:
  the Coordinator is not restarted when the Writer is killed, so its pid
  remains unchanged and the assertion fails.

  ## AC / D-NNN linkage

  - INV-ST-3 — supervision spine must be `:rest_for_one` so a LedgerWriter
    crash cascades to all downstream dependents.
  """

  use ExUnit.Case, async: false

  @moduletag :inv_st3
  @moduletag :capture_log

  @supervisor Tau.Factory.Supervisor
  @writer Tau.Factory.Ledger.Writer

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique_name(base) do
    :"#{base}_#{System.unique_integer([:positive])}"
  end

  # Walk a supervisor's children list and find the pid of the child whose
  # child-spec module list includes target_mod.
  defp find_child_pid(sup_pid, target_mod) do
    sup_pid
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {_id, pid, _type, mods} when is_pid(pid) ->
        if target_mod in List.wrap(mods), do: pid, else: nil

      _ ->
        nil
    end)
  end

  # Poll until Process.whereis(name) resolves to a pid different from
  # excluded_pid, or the deadline (in ms) passes. Returns the new pid or
  # :timeout.
  defp await_new_pid(name, excluded_pid, deadline_ms) do
    start = System.monotonic_time(:millisecond)

    Stream.repeatedly(fn -> Process.sleep(20) end)
    |> Enum.reduce_while(:timeout, fn _, _acc ->
      case Process.whereis(name) do
        pid when is_pid(pid) and pid != excluded_pid ->
          {:halt, pid}

        _ ->
          if System.monotonic_time(:millisecond) - start >= deadline_ms do
            {:halt, :timeout}
          else
            {:cont, :timeout}
          end
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # INV-ST-3: a LedgerWriter crash must restart all downstream children
  # (rest_for_one on the ledger-only path with dependents present).
  # ---------------------------------------------------------------------------

  describe "INV-ST-3 — rest_for_one spine: LedgerWriter crash cascades to downstream children" do
    @tag :inv_st3
    test "INV-ST-3: killing LedgerWriter restarts the Coordinator (rest_for_one required)" do
      db_path = Briefly.create!(extname: ".db")
      sup_name = unique_name(:inv_st3_sup)
      coord_name = unique_name(:inv_st3_coord)

      # Minimal Coordinator opts. The Coordinator needs pubsub, select_fun,
      # drive_fun. We supply idle no-op funs so it starts cleanly.
      coordinator_opts = [
        name: coord_name,
        pubsub: Tau.PubSub,
        select_fun: fn -> nil end,
        drive_fun: fn _work -> :ok end
      ]

      sup_pid =
        start_supervised!(
          {
            @supervisor,
            db_path: db_path, name: sup_name, coordinator_opts: coordinator_opts
          },
          id: sup_name
        )

      assert is_pid(sup_pid),
             "INV-ST-3: Tau.Factory.Supervisor must start successfully"

      # Capture the Writer's pid BEFORE the crash.
      writer_pid_before = find_child_pid(sup_pid, @writer)

      assert is_pid(writer_pid_before),
             "INV-ST-3: Tau.Factory.Ledger.Writer must be a child of the supervisor"

      # Capture the Coordinator's pid BEFORE the crash.
      coord_pid_before = Process.whereis(coord_name)

      assert is_pid(coord_pid_before),
             "INV-ST-3: Tau.Factory.Coordinator must be a child of the supervisor " <>
               "when coordinator_opts are provided. No Coordinator child was found — " <>
               "maybe_add_coordinator did not append it."

      # Kill the Writer (an earlier child in the dependency order).
      # Under :one_for_one this restarts ONLY the Writer.
      # Under :rest_for_one this restarts the Writer AND all later children,
      # including the Coordinator.
      ref = Process.monitor(writer_pid_before)
      Process.exit(writer_pid_before, :kill)

      # Wait for the Writer's :DOWN signal to confirm it is dead.
      assert_receive {:DOWN, ^ref, :process, ^writer_pid_before, :killed},
                     2000,
                     "INV-ST-3: Tau.Factory.Ledger.Writer did not exit after :kill"

      # Wait for the Coordinator to be restarted under the same registered name.
      # Under :rest_for_one the supervisor restarts all later children including
      # the Coordinator, so a new pid will appear. Under :one_for_one no new
      # Coordinator pid appears — this assertion fails.
      coord_pid_after = await_new_pid(coord_name, coord_pid_before, 2000)

      assert is_pid(coord_pid_after) and coord_pid_after != coord_pid_before,
             "INV-ST-3: after killing Tau.Factory.Ledger.Writer, Tau.Factory.Coordinator " <>
               "MUST be restarted (a new pid must appear under #{inspect(coord_name)}). " <>
               "The restart did not occur, which proves the supervision strategy is " <>
               ":one_for_one instead of :rest_for_one. When downstream dependents are " <>
               "present in init_ledger_only/1, the spine MUST use :rest_for_one so that " <>
               "a LedgerWriter crash cascades to all later children (INV-ST-3). " <>
               "coord_pid_before=#{inspect(coord_pid_before)}, " <>
               "coord_pid_after=#{inspect(coord_pid_after)}"
    end
  end
end
