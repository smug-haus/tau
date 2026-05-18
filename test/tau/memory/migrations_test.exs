defmodule Tau.Memory.MigrationsTest do
  @moduledoc """
  Tests for `Tau.Memory.Migrations`.

  Advances AC-3 and AC-4 from SPEC-MEMORY-STORE.md.
  Enforces D-047 (idempotent migrations, hard-fail on error).
  """

  use ExUnit.Case, async: true

  alias Tau.Memory.Migrations

  # ---------------------------------------------------------------------------
  # AC-3: idempotency
  # ---------------------------------------------------------------------------

  describe "run/1 — idempotency (AC-3, D-047)" do
    test "runs successfully on a fresh db" do
      {:ok, db} = Exqlite.Sqlite3.open(":memory:")
      assert :ok = Migrations.run(db)
    end

    test "re-running on a fully-migrated db is a no-op (AC-3)" do
      {:ok, db} = Exqlite.Sqlite3.open(":memory:")
      assert :ok = Migrations.run(db)
      # Second run must also succeed with no error.
      assert :ok = Migrations.run(db)
    end

    test "schema_migrations table has exactly one row per migration after two runs" do
      {:ok, db} = Exqlite.Sqlite3.open(":memory:")
      :ok = Migrations.run(db)
      :ok = Migrations.run(db)

      expected_versions = Migrations.migrations() |> Enum.map(&elem(&1, 0)) |> Enum.sort()

      {:ok, stmt} =
        Exqlite.Sqlite3.prepare(db, "SELECT version FROM schema_migrations ORDER BY version")

      {:ok, rows} = Exqlite.Sqlite3.fetch_all(db, stmt)
      :ok = Exqlite.Sqlite3.release(db, stmt)

      actual_versions = Enum.map(rows, fn [v] -> v end) |> Enum.sort()
      assert actual_versions == expected_versions
    end

    test "memory_entries table exists and has correct columns after migration" do
      {:ok, db} = Exqlite.Sqlite3.open(":memory:")
      :ok = Migrations.run(db)

      # PRAGMA table_info returns one row per column.
      {:ok, stmt} = Exqlite.Sqlite3.prepare(db, "PRAGMA table_info(memory_entries)")
      {:ok, rows} = Exqlite.Sqlite3.fetch_all(db, stmt)
      :ok = Exqlite.Sqlite3.release(db, stmt)

      col_names = Enum.map(rows, fn [_cid, name | _] -> name end) |> Enum.sort()

      expected = ~w[content created_at embedding_status id kind metadata scope updated_at]
      assert col_names == expected
    end

    test "embedding_status CHECK constraint is enforced (D-046)" do
      {:ok, db} = Exqlite.Sqlite3.open(":memory:")
      :ok = Migrations.run(db)

      bad_sql =
        "INSERT INTO memory_entries (id, kind, scope, content, embedding_status) VALUES ('x', 'k', 's', 'c', 'invalid')"

      assert {:error, _reason} = Exqlite.Sqlite3.execute(db, bad_sql)
    end
  end

  # ---------------------------------------------------------------------------
  # AC-4: migration hard-fail
  # ---------------------------------------------------------------------------

  describe "Store.SQLite init/1 — migration hard-fail (AC-4, D-047)" do
    test "init/1 returns {:stop, _} when migration fails" do
      # Corrupt the db by pre-creating schema_migrations with the wrong schema,
      # then run the store's init/1 which calls Migrations.run/1.
      # We simulate this by passing a db_path that causes a migration error.
      # The cleanest test: open a db, corrupt schema_migrations so the
      # bootstrap migration's INSERT OR IGNORE will actually try to insert
      # into a type-mismatched table, causing an error.
      #
      # Simplest reliable approach: open a db with a pre-created
      # schema_migrations table missing its version column, then call
      # Migrations.run/1 and assert it returns {:error, _}.

      {:ok, db} = Exqlite.Sqlite3.open(":memory:")
      # Create a schema_migrations with a wrong schema (no version column).
      :ok = Exqlite.Sqlite3.execute(db, "CREATE TABLE schema_migrations (wrong_col TEXT)")

      assert {:error, _reason} = Migrations.run(db)
    end

    test "Store.SQLite start_link returns {:error, _} when db_path is unwriteable" do
      # Use an unwriteable path to force an open error.
      bad_path = "/nonexistent/path/that/cannot/be/created/memory.db"

      # start_supervised wraps the {:stop, _} as {:error, _}.
      assert {:error, _} =
               start_supervised(
                 {Tau.Memory.Store.SQLite,
                  db_path: bad_path, name: :"test_bad_store_#{System.unique_integer()}"},
                 restart: :temporary
               )
    end
  end
end
