defmodule Tau.Memory.Migrations do
  @moduledoc """
  Ordered, idempotent schema migrations for the memory store.

  Each migration is a `{version :: String.t(), sql :: String.t()}` pair.
  `run/1` checks `schema_migrations` before applying each entry; already-applied
  migrations are skipped.

  ## Invariants

  - D-047: Idempotent. Re-running against a fully-migrated DB is a no-op.
  - C-007: Migrations are append-only. Never mutate an existing entry's SQL;
    add a new entry instead.

  ## Adding a migration

  Append to the `@migrations` list. The version string must sort lexicographically
  after all existing versions; ISO-8601 prefix (e.g. `"20260518_001"`) is
  recommended.

  PR2 adds the `memory_fts` FTS5 virtual table migration here.
  PR3 adds the `memory_vec` sqlite-vec virtual table migration here.
  """

  @migrations [
    {"20260518_001_schema_migrations",
     """
     CREATE TABLE IF NOT EXISTS schema_migrations (
       version    TEXT PRIMARY KEY,
       applied_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
     )
     """},
    {"20260518_002_memory_entries",
     """
     CREATE TABLE IF NOT EXISTS memory_entries (
       id               TEXT PRIMARY KEY,
       kind             TEXT NOT NULL,
       scope            TEXT NOT NULL,
       content          TEXT NOT NULL,
       metadata         TEXT NOT NULL DEFAULT '{}',
       embedding_status TEXT NOT NULL DEFAULT 'pending'
                        CHECK (embedding_status IN ('pending', 'ready', 'failed')),
       created_at       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
       updated_at       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
     )
     """}
  ]

  @doc "Expose the migration list. Used by tests to verify idempotency."
  @spec migrations() :: [{String.t(), String.t()}]
  def migrations, do: @migrations

  @doc """
  Apply pending migrations to `db` (an `Exqlite.Sqlite3` db reference).

  Returns `:ok` or `{:error, reason}`. Idempotent: already-applied migrations
  are skipped. Failures halt the run immediately.
  """
  @spec run(reference()) :: :ok | {:error, term()}
  def run(db) do
    # Bootstrap: create schema_migrations unconditionally (IF NOT EXISTS).
    # This is the only migration that cannot check schema_migrations first.
    {bootstrap_version, bootstrap_sql} = hd(@migrations)

    with :ok <- exec(db, String.trim(bootstrap_sql)),
         :ok <- record(db, bootstrap_version) do
      @migrations
      |> tl()
      |> Enum.reduce_while(:ok, fn {version, sql}, :ok ->
        case applied?(db, version) do
          {:ok, true} ->
            {:cont, :ok}

          {:ok, false} ->
            case exec(db, String.trim(sql)) do
              :ok ->
                case record(db, version) do
                  :ok -> {:cont, :ok}
                  {:error, _} = err -> {:halt, err}
                end

              {:error, _} = err ->
                {:halt, err}
            end

          {:error, _} = err ->
            {:halt, err}
        end
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp exec(db, sql) do
    case Exqlite.Sqlite3.execute(db, sql) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp applied?(db, version) do
    sql = "SELECT 1 FROM schema_migrations WHERE version = ?1 LIMIT 1"

    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, sql),
         :ok <- Exqlite.Sqlite3.bind(stmt, [version]),
         {:ok, rows} <- Exqlite.Sqlite3.fetch_all(db, stmt),
         :ok <- Exqlite.Sqlite3.release(db, stmt) do
      {:ok, rows != []}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp record(db, version) do
    sql = "INSERT OR IGNORE INTO schema_migrations (version) VALUES (?1)"

    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, sql),
         :ok <- Exqlite.Sqlite3.bind(stmt, [version]),
         step_result <- Exqlite.Sqlite3.step(db, stmt),
         :ok <- Exqlite.Sqlite3.release(db, stmt) do
      case step_result do
        :done -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end
end
