defmodule Tau.Factory.LedgerSupervisionTest do
  @moduledoc """
  Gating tests for PR #433 (P2-Ledger) — AC-1 / D-312.

  Verifies that `Tau.Factory.Supervisor` starts `Tau.Factory.Ledger.Writer`
  as a live supervised child and restarts it after a crash.

  Written BEFORE production code exists (oracle-separation phase).
  These tests fail with UndefinedFunctionError until the implementer creates:
    - `lib/tau/factory/supervisor.ex`
    - `lib/tau/factory/ledger/writer.ex`
    - `lib/tau/factory/ledger/migrations.ex`

  AC linkage: AC-1 / D-312.
  """

  use ExUnit.Case, async: false

  @moduletag :ac_1
  @moduletag :d_312
  @moduletag :capture_log

  # Runtime module references — file compiles even when modules do not yet exist.
  # Each test fails with UndefinedFunctionError at call-time (not CompileError).
  @supervisor Tau.Factory.Supervisor
  @writer Tau.Factory.Ledger.Writer

  # ---------------------------------------------------------------------------
  # AC-1 / D-312: Tau.Factory.Supervisor supervises Tau.Factory.Ledger.Writer
  # ---------------------------------------------------------------------------

  describe "AC-1 / D-312 — Tau.Factory.Supervisor supervises Tau.Factory.Ledger.Writer" do
    setup do
      db_path = Briefly.create!(extname: ".db")

      # Start the full supervisor tree against an isolated tmp-dir DB.
      # Uses a unique name to avoid clashing with any application-started instance.
      sup_name = :"test_factory_sup_#{System.unique_integer([:positive])}"

      sup_pid =
        start_supervised!(
          {
            @supervisor,
            db_path: db_path, name: sup_name
          },
          id: sup_name
        )

      %{sup_pid: sup_pid, db_path: db_path, sup_name: sup_name}
    end

    test "AC-1 / D-312: Tau.Factory.Ledger.Writer is alive after supervisor start",
         %{sup_pid: sup_pid} do
      # The Writer must be a child of the supervisor.
      children = Supervisor.which_children(sup_pid)
      writer_child = Enum.find(children, fn {id, _, _, _} -> id == @writer end)

      assert writer_child != nil,
             "Expected Tau.Factory.Ledger.Writer to be a child of Tau.Factory.Supervisor"

      {_id, writer_pid, :worker, _} = writer_child
      assert is_pid(writer_pid), "Expected writer pid to be a pid"
      assert Process.alive?(writer_pid), "Expected writer process to be alive"
    end

    test "AC-1 / D-312: Tau.Factory.Ledger.Writer restarts after abnormal exit",
         %{sup_pid: sup_pid} do
      # Capture the original writer pid.
      children_before = Supervisor.which_children(sup_pid)

      {_, writer_pid_before, :worker, _} =
        Enum.find(children_before, fn {id, _, _, _} -> id == @writer end)

      assert Process.alive?(writer_pid_before)

      # Kill the writer abnormally — the supervisor must restart it.
      Process.exit(writer_pid_before, :kill)

      # Give the supervisor a moment to restart the child.
      Process.sleep(100)

      children_after = Supervisor.which_children(sup_pid)

      {_, writer_pid_after, :worker, _} =
        Enum.find(children_after, fn {id, _, _, _} -> id == @writer end)

      assert Process.alive?(writer_pid_after),
             "Tau.Factory.Ledger.Writer was not restarted by the supervisor after kill"

      assert writer_pid_after != writer_pid_before,
             "Expected a new pid after restart (supervisor created a fresh process)"
    end
  end
end
