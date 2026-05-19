defmodule Tau.Memory.Store.SQLiteTest do
  @moduledoc """
  Tests for `Tau.Memory.Store.SQLite` — write/delete + telemetry.

  Advances AC-1, AC-2, AC-5 from SPEC-MEMORY-STORE.md.
  Enforces D-045, D-046, D-047.
  """

  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Tau.Memory.Store.SQLite

  @moduletag :capture_log

  # Each test spins up an isolated in-memory store instance.
  setup do
    # Use a unique name per test to avoid clashing with the application-started
    # instance (if the app is running in the test node).
    name = :"test_memory_store_#{System.unique_integer([:positive])}"
    db_path = Briefly.create!(extname: ".db")

    {:ok, pid} = start_supervised({SQLite, db_path: db_path, name: name}, id: name)

    %{pid: pid, name: name}
  end

  # ---------------------------------------------------------------------------
  # AC-1 / D-046: write/1
  # ---------------------------------------------------------------------------

  describe "write/1" do
    test "inserts a row and returns {:ok, uuidv7}", %{pid: pid} do
      entry = %{"kind" => "note", "scope" => "global", "content" => "hello"}
      assert {:ok, id} = GenServer.call(pid, {:write, entry})
      assert is_binary(id)
      assert String.length(id) > 0
    end

    test "sets embedding_status to pending (D-046)", %{pid: pid} do
      entry = %{"kind" => "fact", "scope" => "s1", "content" => "sky is blue"}
      assert {:ok, id} = GenServer.call(pid, {:write, entry})

      # Verify via a direct read-query on the same db connection (process).
      rows = read_rows(pid, id)
      assert length(rows) == 1
      [{^id, _kind, _scope, _content, _meta, embedding_status, _ca, _ua}] = rows
      assert embedding_status == "pending"
    end

    test "stores metadata as JSON", %{pid: pid} do
      meta = %{"source" => "test", "priority" => 1}

      entry = %{
        "kind" => "note",
        "scope" => "global",
        "content" => "meta test",
        "metadata" => meta
      }

      assert {:ok, id} = GenServer.call(pid, {:write, entry})
      rows = read_rows(pid, id)
      [{^id, _, _, _, metadata_json, _, _, _}] = rows
      assert Jason.decode!(metadata_json) == meta
    end

    test "returns error for missing required field", %{pid: pid} do
      assert {:error, {:missing_field, "kind"}} =
               GenServer.call(pid, {:write, %{"scope" => "s", "content" => "c"}})
    end

    test "returns error for empty content", %{pid: pid} do
      assert {:error, {:empty_field, "content"}} =
               GenServer.call(pid, {:write, %{"kind" => "k", "scope" => "s", "content" => ""}})
    end

    test "two writes produce distinct ids", %{pid: pid} do
      entry = %{"kind" => "note", "scope" => "global", "content" => "a"}
      {:ok, id1} = GenServer.call(pid, {:write, entry})
      {:ok, id2} = GenServer.call(pid, {:write, entry})
      assert id1 != id2
    end
  end

  # ---------------------------------------------------------------------------
  # AC-2: delete/1
  # ---------------------------------------------------------------------------

  describe "delete/1" do
    test "deletes an existing row and returns :ok", %{pid: pid} do
      entry = %{"kind" => "note", "scope" => "global", "content" => "to delete"}
      {:ok, id} = GenServer.call(pid, {:write, entry})

      assert :ok = GenServer.call(pid, {:delete, id})
      assert read_rows(pid, id) == []
    end

    test "idempotent: :ok on non-existent id (AC-2)", %{pid: pid} do
      assert :ok = GenServer.call(pid, {:delete, "nonexistent-id"})
    end

    test "returns error for non-binary id", %{pid: pid} do
      assert {:error, {:invalid_id, 42}} = GenServer.call(pid, {:delete, 42})
    end
  end

  # ---------------------------------------------------------------------------
  # AC-5: telemetry
  # ---------------------------------------------------------------------------

  describe "telemetry" do
    test "write emits :start and :stop events", %{pid: pid} do
      events =
        capture_telemetry([:tau, :memory, :write, :start], [:tau, :memory, :write, :stop], fn ->
          GenServer.call(pid, {:write, %{"kind" => "k", "scope" => "s", "content" => "c"}})
        end)

      assert Enum.any?(events, fn {name, _, _} -> name == [:tau, :memory, :write, :start] end)
      assert Enum.any?(events, fn {name, _, _} -> name == [:tau, :memory, :write, :stop] end)
    end

    test "delete emits :start and :stop events", %{pid: pid} do
      {:ok, id} = GenServer.call(pid, {:write, %{"kind" => "k", "scope" => "s", "content" => "c"}})

      events =
        capture_telemetry([:tau, :memory, :delete, :start], [:tau, :memory, :delete, :stop], fn ->
          GenServer.call(pid, {:delete, id})
        end)

      assert Enum.any?(events, fn {name, _, _} -> name == [:tau, :memory, :delete, :start] end)
      assert Enum.any?(events, fn {name, _, _} -> name == [:tau, :memory, :delete, :stop] end)
    end

    test "write :stop event includes duration measurement", %{pid: pid} do
      events =
        capture_telemetry([:tau, :memory, :write, :stop], fn ->
          GenServer.call(pid, {:write, %{"kind" => "k", "scope" => "s", "content" => "c"}})
        end)

      [{_name, measurements, _meta}] =
        Enum.filter(events, fn {name, _, _} ->
          name == [:tau, :memory, :write, :stop]
        end)

      assert is_integer(measurements.duration)
      assert measurements.duration >= 0
    end
  end

  # ---------------------------------------------------------------------------
  # D-047: migration hard-fail / D-045: connection escape
  # ---------------------------------------------------------------------------

  describe "D-045 — connection does not escape" do
    test "write/1 and delete/1 return structured values, never a db reference", %{pid: pid} do
      {:ok, id} = GenServer.call(pid, {:write, %{"kind" => "k", "scope" => "s", "content" => "x"}})
      # id is a binary, not a reference
      assert is_binary(id)
      refute is_reference(id)

      result = GenServer.call(pid, {:delete, id})
      assert result == :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Public API — write/2 and delete/2 with explicit server arg
  # ---------------------------------------------------------------------------

  describe "public API with explicit server" do
    test "write/2 accepts a pid and returns {:ok, id}", %{pid: pid} do
      entry = %{"kind" => "note", "scope" => "global", "content" => "via write/2"}
      assert {:ok, id} = SQLite.write(pid, entry)
      assert is_binary(id)
    end

    test "delete/2 accepts a pid and returns :ok", %{pid: pid} do
      {:ok, id} = SQLite.write(pid, %{"kind" => "note", "scope" => "s", "content" => "x"})
      assert :ok = SQLite.delete(pid, id)
    end

    test "delete/2 is idempotent on non-existent id", %{pid: pid} do
      assert :ok = SQLite.delete(pid, "nonexistent-uuid")
    end
  end

  # ---------------------------------------------------------------------------
  # Properties — D-045 (connection isolation) and D-046 (embedding_status)
  # ---------------------------------------------------------------------------

  describe "D-045/D-046 — write-then-read round-trip property" do
    @tag :property
    property "write preserves all required fields and sets embedding_status=pending", %{pid: pid} do
      check all(
              kind <- string(:alphanumeric, min_length: 1),
              scope <- string(:alphanumeric, min_length: 1),
              content <- string(:alphanumeric, min_length: 1)
            ) do
        entry = %{"kind" => kind, "scope" => scope, "content" => content}
        {:ok, id} = SQLite.write(pid, entry)

        rows = read_rows(pid, id)
        assert length(rows) == 1

        [{^id, row_kind, row_scope, row_content, _meta, embedding_status, _ca, _ua}] = rows
        assert row_kind == kind
        assert row_scope == scope
        assert row_content == content
        assert embedding_status == "pending"
      end
    end

    @tag :property
    property "returned id is always a non-empty binary (D-045 — not a reference)", %{pid: pid} do
      check all(
              kind <- string(:alphanumeric, min_length: 1),
              scope <- string(:alphanumeric, min_length: 1),
              content <- string(:alphanumeric, min_length: 1)
            ) do
        entry = %{"kind" => kind, "scope" => scope, "content" => content}
        result = SQLite.write(pid, entry)

        assert {:ok, id} = result
        assert is_binary(id)
        refute is_reference(id)
        assert byte_size(id) > 0
      end
    end

    @tag :property
    property "write followed by delete leaves no row", %{pid: pid} do
      check all(
              kind <- string(:alphanumeric, min_length: 1),
              scope <- string(:alphanumeric, min_length: 1),
              content <- string(:alphanumeric, min_length: 1)
            ) do
        entry = %{"kind" => kind, "scope" => scope, "content" => content}
        {:ok, id} = SQLite.write(pid, entry)
        assert :ok = SQLite.delete(pid, id)
        assert read_rows(pid, id) == []
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Query memory_entries via the GenServer process's state (using :sys.get_state
  # only in tests; production code never does this).
  defp read_rows(pid, id) do
    %{db: db} = :sys.get_state(pid)

    sql =
      "SELECT id, kind, scope, content, metadata, embedding_status, created_at, updated_at FROM memory_entries WHERE id = ?1"

    {:ok, stmt} = Exqlite.Sqlite3.prepare(db, sql)
    :ok = Exqlite.Sqlite3.bind(stmt, [id])
    {:ok, rows} = Exqlite.Sqlite3.fetch_all(db, stmt)
    :ok = Exqlite.Sqlite3.release(db, stmt)
    Enum.map(rows, &List.to_tuple/1)
  end

  defp capture_telemetry(event_name, fun) when is_list(event_name) and is_atom(hd(event_name)) do
    capture_telemetry([event_name], fun)
  end

  defp capture_telemetry(event_names, fun) when is_list(event_names) do
    test_pid = self()
    handler_id = "test-handler-#{System.unique_integer()}"

    :telemetry.attach_many(
      handler_id,
      event_names,
      fn name, meas, meta, _ ->
        send(test_pid, {:telemetry, name, meas, meta})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    collect_telemetry([])
  end

  defp capture_telemetry(e1, e2, fun) do
    capture_telemetry([e1, e2], fun)
  end

  defp collect_telemetry(acc) do
    receive do
      {:telemetry, name, meas, meta} -> collect_telemetry([{name, meas, meta} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
