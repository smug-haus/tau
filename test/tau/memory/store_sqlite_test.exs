defmodule Tau.Memory.Store.SQLiteTest do
  @moduledoc """
  Tests for `Tau.Memory.Store.SQLite` — write/delete + FTS5 search + telemetry.

  PR1: AC-1, AC-2, AC-5 from SPEC-MEMORY-STORE.md. D-045, D-046, D-047.
  PR2: search/2 (FTS5). D-046 (pending/failed rows included in FTS results).
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
  # AC-6 / D-046: search/2 (FTS5 full-text search — PR2)
  # ---------------------------------------------------------------------------

  describe "search/2 — FTS5 full-text search (D-046)" do
    test "returns matching rows by content", %{pid: pid} do
      SQLite.write(pid, %{"kind" => "note", "scope" => "global", "content" => "the quick brown fox"})

      SQLite.write(pid, %{
        "kind" => "note",
        "scope" => "global",
        "content" => "completely unrelated entry"
      })

      assert {:ok, results} = SQLite.search(pid, "fox", [])
      assert length(results) == 1
      [result] = results
      assert result["content"] == "the quick brown fox"
    end

    test "includes pending rows (D-046)", %{pid: pid} do
      # write creates rows with embedding_status = 'pending'
      SQLite.write(pid, %{"kind" => "fact", "scope" => "s1", "content" => "pending content here"})

      assert {:ok, results} = SQLite.search(pid, "pending", [])
      assert length(results) == 1
      assert hd(results)["embedding_status"] == "pending"
    end

    test "includes failed rows (D-046)", %{pid: pid} do
      {:ok, id} =
        SQLite.write(pid, %{"kind" => "fact", "scope" => "s1", "content" => "failed entry content"})

      # Manually flip the embedding_status to 'failed' via a direct SQL update.
      %{db: db} = :sys.get_state(pid)

      {:ok, stmt} =
        Exqlite.Sqlite3.prepare(
          db,
          "UPDATE memory_entries SET embedding_status='failed' WHERE id=?1"
        )

      :ok = Exqlite.Sqlite3.bind(stmt, [id])
      :done = Exqlite.Sqlite3.step(db, stmt)
      :ok = Exqlite.Sqlite3.release(db, stmt)

      assert {:ok, results} = SQLite.search(pid, "failed entry", [])
      assert Enum.any?(results, fn r -> r["id"] == id end)
    end

    test "filters by scope when :scope opt is provided", %{pid: pid} do
      SQLite.write(pid, %{"kind" => "note", "scope" => "ns1", "content" => "scoped result"})
      SQLite.write(pid, %{"kind" => "note", "scope" => "ns2", "content" => "scoped result"})

      assert {:ok, results} = SQLite.search(pid, "scoped", scope: "ns1")
      assert length(results) == 1
      assert hd(results)["scope"] == "ns1"
    end

    test "respects :limit option", %{pid: pid} do
      for i <- 1..5 do
        SQLite.write(pid, %{
          "kind" => "note",
          "scope" => "global",
          "content" => "limit test entry #{i}"
        })
      end

      assert {:ok, results} = SQLite.search(pid, "limit test", limit: 3)
      assert length(results) <= 3
    end

    test "returns {:ok, []} when no rows match", %{pid: pid} do
      assert {:ok, []} = SQLite.search(pid, "xyzzy_no_match_ever", [])
    end

    test "returns {:error, _} for non-binary query", %{pid: pid} do
      assert {:error, {:invalid_query, 42}} = SQLite.search(pid, 42, [])
    end

    test "result maps include all expected keys", %{pid: pid} do
      SQLite.write(pid, %{"kind" => "note", "scope" => "global", "content" => "key check entry"})

      assert {:ok, [result]} = SQLite.search(pid, "key check", [])

      expected_keys = ~w[id kind scope content metadata embedding_status created_at updated_at]
      assert Enum.all?(expected_keys, &Map.has_key?(result, &1))
    end

    test "search emits :start and :stop telemetry events", %{pid: pid} do
      SQLite.write(pid, %{"kind" => "k", "scope" => "s", "content" => "telemetry check"})

      events =
        capture_telemetry(
          [:tau, :memory, :search, :start],
          [:tau, :memory, :search, :stop],
          fn -> SQLite.search(pid, "telemetry", []) end
        )

      assert Enum.any?(events, fn {name, _, _} -> name == [:tau, :memory, :search, :start] end)
      assert Enum.any?(events, fn {name, _, _} -> name == [:tau, :memory, :search, :stop] end)
    end

    test "search :stop event includes duration measurement", %{pid: pid} do
      SQLite.write(pid, %{"kind" => "k", "scope" => "s", "content" => "duration check"})

      events =
        capture_telemetry([:tau, :memory, :search, :stop], fn ->
          SQLite.search(pid, "duration", [])
        end)

      [{_name, measurements, _meta}] =
        Enum.filter(events, fn {name, _, _} -> name == [:tau, :memory, :search, :stop] end)

      assert is_integer(measurements.duration)
      assert measurements.duration >= 0
    end
  end

  # ---------------------------------------------------------------------------
  # Properties — search/2 (D-046)
  # ---------------------------------------------------------------------------

  describe "search/2 properties (D-046)" do
    @tag :property
    property "all written rows with matching content are returned by search", %{pid: pid} do
      check all(
              kind <- string(:alphanumeric, min_length: 1),
              scope <- string(:alphanumeric, min_length: 1),
              # Use a unique token to avoid cross-test collisions
              token <- string(:alphanumeric, min_length: 6)
            ) do
        content = "searchable_#{token}"
        {:ok, id} = SQLite.write(pid, %{"kind" => kind, "scope" => scope, "content" => content})

        {:ok, results} = SQLite.search(pid, content, [])
        ids = Enum.map(results, & &1["id"])
        assert id in ids
      end
    end

    @tag :property
    property "search results always have embedding_status in pending|ready|failed", %{pid: pid} do
      check all(
              kind <- string(:alphanumeric, min_length: 1),
              scope <- string(:alphanumeric, min_length: 1),
              token <- string(:alphanumeric, min_length: 6)
            ) do
        content = "status_check_#{token}"
        SQLite.write(pid, %{"kind" => kind, "scope" => scope, "content" => content})

        {:ok, results} = SQLite.search(pid, content, [])

        Enum.each(results, fn r ->
          assert r["embedding_status"] in ["pending", "ready", "failed"]
        end)
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
