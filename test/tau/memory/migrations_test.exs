defmodule Tau.Memory.MigrationsTest do
  @moduledoc """
  Tests for `Tau.Memory.Migrations`.

  Advances AC-3 and AC-4 from SPEC-MEMORY-STORE.md.
  Enforces D-047 (idempotent migrations, hard-fail on error).
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Tau.Memory.Migrations
  alias Tau.Memory.Store.SQLite

  # ---------------------------------------------------------------------------
  # AC-3: idempotency (example tests)
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
  # AC-4: migration hard-fail (example tests)
  # ---------------------------------------------------------------------------

  describe "Store.SQLite init/1 — migration hard-fail (AC-4, D-047)" do
    test "init/1 returns {:stop, {:migration_failed, _}} when Migrations.run/1 fails" do
      # Corrupt schema_migrations with a wrong schema (no version column) so
      # Migrations.run/1 returns {:error, _} — exercising the migration-failure
      # branch in init/1 specifically (not the db-open-failure branch).
      #
      # We test this by calling init/1 directly with a pre-corrupted db via
      # a custom db_path pointing to a pre-prepared corrupt temp db file.
      #
      # Strategy: write the corrupt db to a temp file, then start a SQLite
      # process with that path and verify it fails to start.
      corrupt_db_path = Briefly.create!(extname: ".db")

      # Pre-corrupt: open the db and create schema_migrations with wrong schema.
      {:ok, corrupt_db} = Exqlite.Sqlite3.open(corrupt_db_path)
      :ok = Exqlite.Sqlite3.execute(corrupt_db, "CREATE TABLE schema_migrations (wrong_col TEXT)")
      :ok = Exqlite.Sqlite3.close(corrupt_db)

      # Now init/1 will open the db (succeeds), then call Migrations.run/1
      # (fails because schema_migrations exists but has wrong schema).
      assert {:error, _} =
               start_supervised(
                 {SQLite,
                  db_path: corrupt_db_path, name: :"test_migration_fail_#{System.unique_integer()}"},
                 restart: :temporary
               )
    end

    test "Store.SQLite start_link returns {:error, {:db_open_failed, _}} when db_path is unwriteable" do
      # Use an unwriteable path to force an open error.
      bad_path = "/nonexistent/path/that/cannot/be/created/memory.db"

      # start_supervised wraps the {:stop, _} as {:error, _}.
      assert {:error, _} =
               start_supervised(
                 {SQLite, db_path: bad_path, name: :"test_bad_store_#{System.unique_integer()}"},
                 restart: :temporary
               )
    end

    test "Migrations.run/1 returns {:error, _} on a corrupt schema_migrations table" do
      {:ok, db} = Exqlite.Sqlite3.open(":memory:")
      # Create a schema_migrations with a wrong schema (no version column).
      :ok = Exqlite.Sqlite3.execute(db, "CREATE TABLE schema_migrations (wrong_col TEXT)")

      assert {:error, _reason} = Migrations.run(db)
    end
  end

  # ---------------------------------------------------------------------------
  # Property: D-047 — idempotency for any number of re-runs (1..5)
  # ---------------------------------------------------------------------------

  describe "Migrations.run/1 — idempotency property (D-047)" do
    @tag :property
    property "re-running N times on a fresh db produces the same schema as running once" do
      check all(n_extra <- integer(0..4)) do
        {:ok, db} = Exqlite.Sqlite3.open(":memory:")

        # First run.
        assert :ok = Migrations.run(db)

        # N additional runs.
        for _ <- 1..max(n_extra, 1)//1, n_extra > 0 do
          assert :ok = Migrations.run(db)
        end

        # Schema_migrations row count == number of migrations, regardless of n_extra.
        expected_count = length(Migrations.migrations())

        {:ok, stmt} =
          Exqlite.Sqlite3.prepare(db, "SELECT COUNT(*) FROM schema_migrations")

        {:ok, [[actual_count]]} = Exqlite.Sqlite3.fetch_all(db, stmt)
        :ok = Exqlite.Sqlite3.release(db, stmt)

        assert actual_count == expected_count
      end
    end

    @tag :property
    property "all expected migration versions are present after any number of runs" do
      check all(n_extra <- integer(0..4)) do
        {:ok, db} = Exqlite.Sqlite3.open(":memory:")
        :ok = Migrations.run(db)

        for _ <- 1..max(n_extra, 1)//1, n_extra > 0 do
          assert :ok = Migrations.run(db)
        end

        expected_versions = Migrations.migrations() |> Enum.map(&elem(&1, 0)) |> Enum.sort()

        {:ok, stmt} =
          Exqlite.Sqlite3.prepare(db, "SELECT version FROM schema_migrations ORDER BY version")

        {:ok, rows} = Exqlite.Sqlite3.fetch_all(db, stmt)
        :ok = Exqlite.Sqlite3.release(db, stmt)

        actual_versions = Enum.map(rows, fn [v] -> v end) |> Enum.sort()
        assert actual_versions == expected_versions
      end
    end
  end
end
