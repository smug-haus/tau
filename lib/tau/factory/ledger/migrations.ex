defmodule Tau.Factory.Ledger.Migrations do
  @moduledoc """
  Ordered, idempotent schema migrations for the factory ledger.

  Mirrors `Tau.Memory.Migrations`. Each migration is a
  `{version :: String.t(), sql :: String.t()}` pair. `run/1` checks
  `ledger_schema_migrations` before applying each entry; already-applied
  migrations are skipped.

  ## Invariants

  - Idempotent: re-running against a fully-migrated DB is a no-op.
  - Append-only: never mutate an existing entry's SQL; add a new entry instead.

  ## D-335 partial unique index

  `CREATE UNIQUE INDEX verdicts_original_uidx ON verdicts (hash, run, half)
  WHERE supersedes_id IS NULL` enforces that only ONE original (non-superseded)
  verdict row may exist per `(hash, run, half)` coordinate. A revoke inserts a
  new row with `supersedes_id` set, which is exempt from the index.
  """

  @migrations [
    {"20260609_001_ledger_schema_migrations",
     """
     CREATE TABLE IF NOT EXISTS ledger_schema_migrations (
       version    TEXT PRIMARY KEY,
       applied_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
     )
     """},
    {"20260609_002_verdicts",
     """
     CREATE TABLE IF NOT EXISTS verdicts (
       id               INTEGER PRIMARY KEY AUTOINCREMENT,
       hash             TEXT    NOT NULL,
       run              TEXT    NOT NULL,
       half             TEXT    NOT NULL CHECK (half IN ('critic', 'reviewer')),
       status           TEXT    NOT NULL CHECK (status IN ('pass', 'fail')),
       idempotency_key  TEXT    NOT NULL,
       supersedes_id    INTEGER REFERENCES verdicts(id),
       inserted_at      TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
     )
     """},
    {"20260609_003_verdicts_original_uidx",
     """
     CREATE UNIQUE INDEX IF NOT EXISTS verdicts_original_uidx
       ON verdicts (hash, run, half)
       WHERE supersedes_id IS NULL
     """},
    {"20260611_004_budget_debits",
     """
     CREATE TABLE IF NOT EXISTS budget_debits (
       id          INTEGER PRIMARY KEY AUTOINCREMENT,
       unit_id     TEXT    NOT NULL,
       dimension   TEXT    NOT NULL,
       cost        INTEGER NOT NULL,
       inserted_at TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
     )
     """},
    {"20260611_005_captures",
     """
     CREATE TABLE IF NOT EXISTS captures (
       id             INTEGER PRIMARY KEY AUTOINCREMENT,
       worker_id      TEXT    NOT NULL,
       patch          TEXT    NOT NULL DEFAULT '',
       untracked_tgz  BLOB,
       status         TEXT    NOT NULL DEFAULT '',
       disposition    TEXT    NOT NULL DEFAULT 'captured',
       inserted_at    TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
     )
     """},
    {"20260612_006_unit_snapshots",
     """
     CREATE TABLE IF NOT EXISTS unit_snapshots (
       id               INTEGER PRIMARY KEY AUTOINCREMENT,
       unit_id          TEXT    NOT NULL,
       state            TEXT    NOT NULL,
       idempotency_key  TEXT    NOT NULL UNIQUE,
       inserted_at      TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
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
    # Bootstrap: create ledger_schema_migrations unconditionally (IF NOT EXISTS).
    # This is the only migration that cannot check ledger_schema_migrations first.
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
    sql = "SELECT 1 FROM ledger_schema_migrations WHERE version = ?1 LIMIT 1"

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
    sql = "INSERT OR IGNORE INTO ledger_schema_migrations (version) VALUES (?1)"

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
