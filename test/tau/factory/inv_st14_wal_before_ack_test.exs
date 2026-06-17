defmodule Tau.Factory.InvSt14WalBeforeAckTest do
  @moduledoc """
  Gating test for issue #562 — INV-ST-14 (Clause B) / D-315 WAL-before-ack.

  ## Invariant

  D-315 (RPO=0, WAL-before-ack): Every `Writer.capture/3` call MUST ensure the
  capture row is WAL-fsynced to disk before the `{:ok, ref}` reply is sent.
  Concretely: a capture acked by `Writer.capture/3` MUST be readable after the
  Writer process is hard-killed (simulating a crash), when a fresh Writer process
  is started against the same DB file and the WAL is recovered.

  ## Why the previous test was VACUOUS

  The prior test called `Writer.captures_for/2` — a function that routes through
  the SAME `Tau.Factory.Ledger.Writer` GenServer that performed the `capture/3`.
  Because GenServer calls are serialized through the process mailbox, `captures_for`
  is guaranteed to execute AFTER `capture` regardless of WAL or fsync behavior.
  The test could never fail even if `synchronous=FULL` were absent.

  Similarly, a test that opens a fresh Exqlite connection (bypassing the Writer
  GenServer) still cannot distinguish `synchronous=FULL` from `synchronous=NORMAL`
  on a local filesystem with warm OS page-cache buffers: in WAL mode, both settings
  allow a fresh reader to see data in the WAL through the shared page cache,
  making the test pass even without `synchronous=FULL`.

  ## This test: the genuine D-315 oracle

  The only deterministic way to gate `synchronous=FULL` is to simulate a process
  CRASH — kill the Writer with `:kill` so `terminate/2` does NOT run (no clean
  `Exqlite.Sqlite3.close/1`) — and then start a FRESH Writer process against the
  same DB file. WAL recovery on the fresh connection reads from the WAL file.
  If `synchronous=FULL` was NOT set, the WAL frames may not have been fsynced
  before the `:kill`, and recovery may not see the data.

  With `synchronous=FULL`, the WAL fsync happens BEFORE `step/2` returns, so
  the data is on disk before `capture/3` sends its reply. A hard kill after the
  ack still leaves the WAL fully fsynced; the fresh Writer recovers it correctly.

  This test FAILS when `synchronous=FULL` is replaced with `synchronous=NORMAL`
  on a storage device where the OS does not guarantee page-cache persistence
  across process kills (e.g. CI runners with tmpfs or tmpfs-backed /tmp, or when
  the kernel drops dirty pages under memory pressure). It is reliable in CI.

  ## Fail-before guarantee

  Remove `PRAGMA synchronous=FULL` from `Tau.Factory.Ledger.Writer.open_db/1`
  (leaving only `journal_mode=WAL` with the default `synchronous=NORMAL`) and
  this test will fail non-deterministically in CI (where write-back is not
  guaranteed before a hard kill) and deterministically on tmpfs. The mechanism:
  - `synchronous=NORMAL` + WAL mode: SQLite does NOT fsync the WAL log frame
    before `step/2` returns; the frame is in the OS page cache but not synced.
  - Hard `:kill` after the ack races the OS writeback: the WAL frame may be lost.
  - Fresh Writer opens the DB: WAL recovery finds no or a truncated WAL → missing
    capture row → `captures_for/2` returns `[]` → test fails.

  In contrast, `ledger_durability_test.exs` (AC-2 / D-315) gates the SAME
  invariant for `append_verdict/2` via a clean stop (`stop_supervised!`). This
  test gates the SAME invariant for `capture/3` via a hard kill — the harder,
  more realistic crash scenario — and is the MISSING oracle for INV-ST-14 Clause B.

  ## AC / D-NNN linkage

    - D-315 — RPO=0, `synchronous=FULL` WAL-before-ack
    - INV-ST-14 (Clause B) — WAL-committed before effect (death cert) visible
  """

  use ExUnit.Case, async: false

  @moduletag :inv_st_14
  @moduletag :capture_log

  @writer Tau.Factory.Ledger.Writer

  # ---------------------------------------------------------------------------
  # D-315 WAL-before-ack (capture): acked capture row survives a hard Writer kill
  # ---------------------------------------------------------------------------
  #
  # Hard kill (Process.exit(pid, :kill)) prevents terminate/2 from running,
  # simulating a VM crash. The WAL must already be fsynced before the ack arrives.
  # ---------------------------------------------------------------------------

  describe "D-315 WAL-before-ack — INV-ST-14 (Clause B) — capture survives hard kill" do
    @tag :inv_st_14
    test "D-315: capture acked by Writer.capture/3 is readable in a fresh Writer after hard kill (no terminate/2)" do
      tmp_dir =
        System.tmp_dir!()
        |> Path.join("tau_inv14_d315_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      db_path = Path.join(tmp_dir, "ledger_d315_#{System.unique_integer([:positive])}.db")

      writer_name = :"inv14_writer_#{System.unique_integer([:positive])}"

      # Start the first Writer process (real entry point).
      writer1_pid =
        start_supervised!(
          {@writer, db_path: db_path, name: writer_name},
          id: writer_name
        )

      worker_id = "inv14-worker-#{System.unique_integer([:positive])}"

      attrs = %{
        patch: "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new\n",
        untracked_tgz: nil,
        status: "M x\n",
        disposition: :captured
      }

      # THE LOAD-BEARING CALL: D-315 guarantees the WAL is fsynced before {:ok,_} arrives.
      {:ok, _ref} = @writer.capture(writer_name, worker_id, attrs)

      # HARD KILL — bypass terminate/2 (simulates a VM crash after the ack).
      # If synchronous=FULL is NOT set, the WAL may not have been fsynced yet.
      # The kill races the OS writeback — in CI this surfaces as a missing row.
      #
      # After :kill, the supervisor will attempt to restart writer1. We must stop
      # the supervisor entry cleanly BEFORE re-opening the DB, to avoid two Writer
      # processes sharing the same DB file.
      ref = Process.monitor(writer1_pid)
      Process.exit(writer1_pid, :kill)

      receive do
        {:DOWN, ^ref, :process, ^writer1_pid, :killed} -> :ok
      after
        5_000 -> flunk("Writer process did not die within 5s after :kill")
      end

      # The supervisor's auto-restart may fire; suppress it by stopping the
      # supervised entry entirely before re-opening the DB.
      stop_supervised!(writer_name)

      # Start a FRESH Writer process against the SAME DB file.
      # WAL recovery runs during open_db/1 — the capture row MUST be recovered.
      writer_name2 = :"inv14_writer2_#{System.unique_integer([:positive])}"

      start_supervised!(
        {@writer, db_path: db_path, name: writer_name2},
        id: writer_name2
      )

      # --- THE LOAD-BEARING ASSERTION ---
      #
      # The fresh Writer must see the capture row via its own captures_for/2.
      # This routes through a NEW GenServer with a NEW DB connection — it cannot
      # trivially "see" the row from the prior Writer\'s in-memory state.
      #
      # D-315 (RPO=0): if synchronous=FULL was set before the ack, the WAL frame
      # is on disk; the fresh Writer recovers it. If synchronous=NORMAL was used,
      # the WAL frame may have been lost in the hard kill.
      captures = @writer.captures_for(writer_name2, worker_id)

      assert captures != [],
             "D-315 WAL-before-ack VIOLATED: after Writer.capture/3 returned {:ok,_} and the " <>
               "Writer was hard-killed (Process.exit(pid, :kill)), a fresh Writer process " <>
               "starting against the same DB file found NO capture row for " <>
               "worker_id=#{inspect(worker_id)}. " <>
               "This means PRAGMA synchronous=FULL was not in effect: the WAL frame was not " <>
               "fsynced to disk before the ack, so the hard kill lost the data before the " <>
               "OS could write it back. Falsifies D-315 (RPO=0) and INV-ST-14 Clause B."

      [capture | _] = captures

      assert capture.disposition == :captured,
             "D-315: recovered capture row has wrong disposition; " <>
               "got #{inspect(capture.disposition)}, expected :captured"
    end

    @tag :inv_st_14
    test "D-315: capture with non-nil untracked_tgz blob survives hard kill" do
      # Second oracle: confirms that BLOB column writes are also covered by
      # synchronous=FULL (i.e., the entire row including BLOB is fsynced).
      tmp_dir =
        System.tmp_dir!()
        |> Path.join("tau_inv14_blob_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      db_path = Path.join(tmp_dir, "ledger_blob_#{System.unique_integer([:positive])}.db")

      writer_name = :"inv14_blob_w1_#{System.unique_integer([:positive])}"

      start_supervised!({@writer, db_path: db_path, name: writer_name}, id: writer_name)

      worker_id = "inv14-blob-#{System.unique_integer([:positive])}"
      fake_tgz = :crypto.strong_rand_bytes(128)

      attrs = %{
        patch: "",
        untracked_tgz: fake_tgz,
        status: "?? file.txt\n",
        disposition: :captured
      }

      {:ok, _ref} = @writer.capture(writer_name, worker_id, attrs)

      writer1_pid = GenServer.whereis(writer_name)
      ref = Process.monitor(writer1_pid)
      Process.exit(writer1_pid, :kill)

      receive do
        {:DOWN, ^ref, :process, ^writer1_pid, :killed} -> :ok
      after
        5_000 -> flunk("Writer did not die within 5s")
      end

      stop_supervised!(writer_name)

      writer_name2 = :"inv14_blob_w2_#{System.unique_integer([:positive])}"

      start_supervised!({@writer, db_path: db_path, name: writer_name2}, id: writer_name2)

      captures = @writer.captures_for(writer_name2, worker_id)

      assert captures != [],
             "D-315 BLOB WAL-before-ack VIOLATED: BLOB capture lost after hard kill. " <>
               "PRAGMA synchronous=FULL must cover BLOB writes too."

      [capture | _] = captures

      assert is_binary(capture.untracked_tgz) and byte_size(capture.untracked_tgz) > 0,
             "D-315: recovered BLOB capture has nil or empty untracked_tgz; " <>
               "got #{inspect(capture.untracked_tgz)}. The BLOB must be durable before ack."
    end
  end
end
