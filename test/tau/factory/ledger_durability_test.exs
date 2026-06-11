defmodule Tau.Factory.LedgerDurabilityTest do
  @moduledoc """
  Gating tests for PR #433 (P2-Ledger) — AC-2 / D-315 (RPO=0, WAL-before-ack).

  Verifies that a verdict acked by `append_verdict/2` survives a Writer process
  restart against the same DB file, proving WAL was committed before the ack.

  Written BEFORE production code exists (oracle-separation phase).
  These tests fail with UndefinedFunctionError until the implementer creates:
    - `lib/tau/factory/ledger/writer.ex`
    - `lib/tau/factory/ledger/migrations.ex`

  AC linkage: AC-2 / D-315.
  """

  use ExUnit.Case, async: true

  @moduletag :ac_2
  @moduletag :d_315
  @moduletag :capture_log

  # Runtime module references — file compiles even when modules do not yet exist.
  @writer Tau.Factory.Ledger.Writer

  # ---------------------------------------------------------------------------
  # AC-2 / D-315: WAL-before-ack — acked writes survive process restart
  # ---------------------------------------------------------------------------

  describe "AC-2 / D-315 — WAL-before-ack: acked verdict survives Writer restart" do
    test "AC-2 / D-315: append_verdict returns {:ok, ref} only after WAL commit; verdict readable after restart" do
      db_path = Briefly.create!(extname: ".db")
      writer_name = :"test_ledger_writer_#{System.unique_integer([:positive])}"

      # Start writer against isolated tmp DB.
      writer_pid =
        start_supervised!(
          {@writer, db_path: db_path, name: writer_name},
          id: writer_name
        )

      verdict = %{
        hash: "abc123",
        run: "run-001",
        half: :critic,
        status: :pass,
        idempotency_key: "ikey-#{System.unique_integer([:positive])}"
      }

      # Append a verdict — ack must come ONLY after WAL commit (D-315 RPO=0).
      assert {:ok, _ref} = @writer.append_verdict(writer_pid, verdict)

      # Stop the writer cleanly — simulates a process restart.
      stop_supervised!(writer_name)

      # Start a FRESH writer process against the SAME DB file.
      writer_pid2 =
        start_supervised!(
          {@writer, db_path: db_path, name: writer_name},
          id: writer_name
        )

      # The acked verdict must be readable from the fresh process —
      # it was WAL-committed before the ack, so it survives restart.
      assert {:ok, :pass} =
               @writer.latest_verdict_status(writer_pid2, %{
                 hash: "abc123",
                 run: "run-001",
                 half: :critic
               })
    end

    test "AC-2 / D-315: latest_verdict_status returns :none for an unknown coordinate" do
      db_path = Briefly.create!(extname: ".db")
      writer_name = :"test_ledger_writer_none_#{System.unique_integer([:positive])}"

      writer_pid =
        start_supervised!(
          {@writer, db_path: db_path, name: writer_name},
          id: writer_name
        )

      assert :none =
               @writer.latest_verdict_status(writer_pid, %{
                 hash: "no-such-hash",
                 run: "no-such-run",
                 half: :reviewer
               })
    end
  end
end
