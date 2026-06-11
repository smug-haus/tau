defmodule Tau.Factory.Ledger.Writer do
  @moduledoc """
  Single-writer `GenServer` owning one `Exqlite.Sqlite3` connection for the
  factory verdict ledger.

  The connection never escapes this process's heap (D-045 pattern). All writes
  are serialised through the mailbox, satisfying SQLite's single-writer
  constraint without external locking.

  On init: opens the DB at `:db_path`, sets `PRAGMA journal_mode=WAL` and
  `PRAGMA synchronous=FULL`, runs schema migrations. A DB-open or migration
  failure causes `init/1` to return `{:stop, reason}`, hard-failing boot.

  ## WAL-before-ack (D-315, RPO=0)

  `PRAGMA synchronous=FULL` causes SQLite to fsync the WAL to disk before
  returning from the write call. The `GenServer.call/2` reply is sent only
  after the `Exqlite.Sqlite3.step/2` call (the SQLite write) returns, so the
  caller's `{:ok, ref}` is guaranteed to arrive after the WAL commit is durable.

  ## Append-only invariant (D-335)

  There are NO `UPDATE` statements in this module. Revocations insert a NEW row
  with `supersedes_id` pointing at the latest existing row for the coordinate.
  The partial unique index on `verdicts (hash, run, half) WHERE supersedes_id IS
  NULL` enforces that only one original row per coordinate exists; the
  uniqueness constraint does not apply to superseding rows.

  ## Public API

    - `start_link/1` — start and register the process.
    - `append_verdict/2` — insert an original verdict; returns `{:ok, ref}` or
      `{:error, reason}` on a duplicate-original constraint violation.
    - `revoke_verdict/2` — insert a superseding verdict row; returns `{:ok, ref}`.
    - `latest_verdict_status/2` — return `{:ok, :pass | :fail}` or `:none`.
  """

  use GenServer

  alias Tau.Factory.Ledger.Migrations

  require Logger

  @type verdict_attrs :: %{
          hash: String.t(),
          run: String.t(),
          half: :critic | :reviewer,
          status: :pass | :fail,
          idempotency_key: String.t()
        }

  @type coord :: %{
          hash: String.t(),
          run: String.t(),
          half: :critic | :reviewer
        }

  @type ref :: integer()

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Start the writer (typically supervised by `Tau.Factory.Supervisor`).

  Options:
    - `:db_path` (required) — path to the SQLite database file.
    - `:name` — registered name for the process (defaults to `__MODULE__`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Insert an original verdict row.

  Returns `{:ok, ref}` (the inserted row id) on success, or `{:error, reason}`
  if a duplicate original already exists at the `(hash, run, half)` coordinate
  (the partial unique index fires). NEVER raises on constraint violations.
  """
  @spec append_verdict(GenServer.server(), verdict_attrs()) :: {:ok, ref()} | {:error, term()}
  def append_verdict(server, attrs) do
    GenServer.call(server, {:append_verdict, attrs})
  end

  @doc """
  Insert a superseding verdict row.

  Finds the current latest row for the coordinate and inserts a new row with
  `supersedes_id` set to that row's id. Returns `{:ok, ref}` (the new row id).
  Never issues an UPDATE — append-only (D-335).
  """
  @spec revoke_verdict(GenServer.server(), verdict_attrs()) :: {:ok, ref()} | {:error, term()}
  def revoke_verdict(server, attrs) do
    GenServer.call(server, {:revoke_verdict, attrs})
  end

  @doc """
  Return the status of the latest row in the supersede chain for the given
  coordinate, or `:none` if no row exists.
  """
  @spec latest_verdict_status(GenServer.server(), coord()) ::
          {:ok, :pass | :fail} | :none
  def latest_verdict_status(server, coord) do
    GenServer.call(server, {:latest_verdict_status, coord})
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    db_path = Keyword.fetch!(opts, :db_path)

    case File.mkdir_p(Path.dirname(db_path)) do
      {:error, reason} ->
        {:stop, {:db_open_failed, reason}}

      :ok ->
        with {:ok, db} <- open_db(db_path),
             :ok <- run_migrations(db) do
          {:ok, %{db: db}}
        end
    end
  end

  @impl GenServer
  def handle_call({:append_verdict, attrs}, _from, %{db: db} = state) do
    result = do_append_verdict(db, attrs)
    {:reply, result, state}
  end

  def handle_call({:revoke_verdict, attrs}, _from, %{db: db} = state) do
    result = do_revoke_verdict(db, attrs)
    {:reply, result, state}
  end

  def handle_call({:latest_verdict_status, coord}, _from, %{db: db} = state) do
    result = do_latest_verdict_status(db, coord)
    {:reply, result, state}
  end

  @impl GenServer
  def terminate(_reason, %{db: db}) do
    Exqlite.Sqlite3.close(db)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp open_db(db_path) do
    with {:ok, db} <- Exqlite.Sqlite3.open(db_path),
         :ok <- Exqlite.Sqlite3.execute(db, "PRAGMA journal_mode=WAL"),
         :ok <- Exqlite.Sqlite3.execute(db, "PRAGMA synchronous=FULL") do
      {:ok, db}
    else
      {:error, reason} -> {:stop, {:db_open_failed, reason}}
    end
  end

  defp run_migrations(db) do
    case Migrations.run(db) do
      :ok -> :ok
      {:error, reason} -> {:stop, {:migration_failed, reason}}
    end
  end

  # Insert an original verdict (supersedes_id IS NULL).
  # The partial unique index rejects a second original at the same coordinate.
  # Constraint errors are translated to tagged tuples — never raised.
  defp do_append_verdict(db, %{
         hash: hash,
         run: run,
         half: half,
         status: status,
         idempotency_key: idempotency_key
       }) do
    sql = """
    INSERT INTO verdicts (hash, run, half, status, idempotency_key)
    VALUES (?1, ?2, ?3, ?4, ?5)
    """

    half_text = atom_to_half(half)
    status_text = atom_to_status(status)

    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, String.trim(sql)),
         :ok <- Exqlite.Sqlite3.bind(stmt, [hash, run, half_text, status_text, idempotency_key]),
         step_result <- Exqlite.Sqlite3.step(db, stmt),
         :ok <- Exqlite.Sqlite3.release(db, stmt) do
      case step_result do
        :done -> {:ok, last_insert_rowid(db)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # Insert a superseding verdict row. Finds the current latest row id for the
  # coordinate and sets supersedes_id. Never issues an UPDATE (D-335).
  defp do_revoke_verdict(db, %{
         hash: hash,
         run: run,
         half: half,
         status: status,
         idempotency_key: idempotency_key
       }) do
    half_text = atom_to_half(half)
    status_text = atom_to_status(status)

    case fetch_latest_id(db, hash, run, half_text) do
      {:ok, latest_id} ->
        sql = """
        INSERT INTO verdicts (hash, run, half, status, idempotency_key, supersedes_id)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6)
        """

        with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, String.trim(sql)),
             :ok <-
               Exqlite.Sqlite3.bind(stmt, [
                 hash,
                 run,
                 half_text,
                 status_text,
                 idempotency_key,
                 latest_id
               ]),
             step_result <- Exqlite.Sqlite3.step(db, stmt),
             :ok <- Exqlite.Sqlite3.release(db, stmt) do
          case step_result do
            :done -> {:ok, last_insert_rowid(db)}
            {:error, reason} -> {:error, reason}
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Return the status of the row with the highest id for this coordinate.
  # This is the latest row regardless of supersedes_id depth.
  defp do_latest_verdict_status(db, %{hash: hash, run: run, half: half}) do
    half_text = atom_to_half(half)

    sql = """
    SELECT status FROM verdicts
    WHERE hash = ?1 AND run = ?2 AND half = ?3
    ORDER BY id DESC
    LIMIT 1
    """

    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, String.trim(sql)),
         :ok <- Exqlite.Sqlite3.bind(stmt, [hash, run, half_text]),
         {:ok, rows} <- Exqlite.Sqlite3.fetch_all(db, stmt),
         :ok <- Exqlite.Sqlite3.release(db, stmt) do
      case rows do
        [[status_text]] -> {:ok, text_to_status(status_text)}
        [] -> :none
      end
    end
  end

  # Fetch the id of the latest (highest id) row for a coordinate.
  defp fetch_latest_id(db, hash, run, half_text) do
    sql = """
    SELECT id FROM verdicts
    WHERE hash = ?1 AND run = ?2 AND half = ?3
    ORDER BY id DESC
    LIMIT 1
    """

    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, sql),
         :ok <- Exqlite.Sqlite3.bind(stmt, [hash, run, half_text]),
         {:ok, rows} <- Exqlite.Sqlite3.fetch_all(db, stmt),
         :ok <- Exqlite.Sqlite3.release(db, stmt) do
      case rows do
        [[id]] -> {:ok, id}
        [] -> {:error, :not_found}
      end
    end
  end

  defp last_insert_rowid(db) do
    case Exqlite.Sqlite3.execute(db, "SELECT last_insert_rowid()") do
      :ok ->
        # execute/2 doesn't return rows; use prepare+step pattern
        fetch_last_rowid(db)

      _ ->
        fetch_last_rowid(db)
    end
  end

  defp fetch_last_rowid(db) do
    sql = "SELECT last_insert_rowid()"

    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, sql),
         {:ok, rows} <- Exqlite.Sqlite3.fetch_all(db, stmt),
         :ok <- Exqlite.Sqlite3.release(db, stmt) do
      case rows do
        [[id]] -> id
        _ -> nil
      end
    else
      _ -> nil
    end
  end

  defp atom_to_half(:critic), do: "critic"
  defp atom_to_half(:reviewer), do: "reviewer"

  defp atom_to_status(:pass), do: "pass"
  defp atom_to_status(:fail), do: "fail"

  defp text_to_status("pass"), do: :pass
  defp text_to_status("fail"), do: :fail
end
