defmodule Tau.Memory.Store.SQLite do
  @moduledoc """
  SQLite-backed implementation of `Tau.Memory.Store`.

  A `GenServer` that owns a single `Exqlite.Sqlite3` write connection (a NIF
  reference). The connection never escapes this process's heap (D-045). All
  writes and searches are serialised through the mailbox (D-045, ADR-0020):
  SQLite has a single-writer constraint that the mailbox enforces without
  external locking. Read operations (search/2) also route through the mailbox
  to avoid exposing the db reference.

  Schema migrations run to completion in `init/1` before the process reports
  `{:ok, state}`. A DB-open failure causes `init/1` to return
  `{:stop, {:db_open_failed, reason}}`. A migration failure causes `init/1` to
  return `{:stop, {:migration_failed, reason}}`, hard-failing boot (D-047).

  Database location: `Path.join(Tau.Settings.data_dir(), "memory.db")`.
  WAL mode is enabled immediately after `open`.

  PR2 adds `search/2` (FTS5 full-text search). The FTS index is maintained by
  three triggers added in migrations 004–006 (insert, delete, update). Pending
  and failed rows are included in FTS results per D-046.

  ## Telemetry

  Every `write/1`, `delete/1`, and `search/2` call emits:

    - `[:tau, :memory, :write | :delete | :search, :start]` — before the operation.
    - `[:tau, :memory, :write | :delete | :search, :stop]` — after a successful operation.
    - `[:tau, :memory, :write | :delete | :search, :exception]` — on error or exception.

  Measurements on `:stop`: `%{duration: non_neg_integer()}` (nanoseconds).
  Metadata on `:stop`: `%{id: binary()}` (write only); `%{count: non_neg_integer()}` (search).

  Events are emitted via `:telemetry.span/3` which guarantees pairing of
  `:start` with `:stop` or `:exception` on every code path.
  """

  @behaviour Tau.Memory.Store

  use GenServer

  alias Tau.Memory.Migrations

  require Logger

  @type state :: %{db: reference()}

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc "Start the store (typically supervised by `Tau.Memory.Supervisor`)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl Tau.Memory.Store
  @doc """
  Insert a memory entry.

  `entry` must have string keys `"kind"`, `"scope"`, `"content"`. `"metadata"`
  is optional (defaults to `{}`). Returns `{:ok, uuid7}` (UUIDv7) or `{:error, reason}`.
  """
  @spec write(map()) :: {:ok, String.t()} | {:error, term()}
  def write(entry), do: write(__MODULE__, entry)

  @doc """
  Insert a memory entry via a named or pid server.

  Allows tests to exercise the public callback rather than the raw
  `GenServer.call` tuple.
  """
  @spec write(GenServer.server(), map()) :: {:ok, String.t()} | {:error, term()}
  def write(server, entry) do
    GenServer.call(server, {:write, entry})
  end

  @impl Tau.Memory.Store
  @doc """
  Delete a memory entry by id.

  Idempotent: `:ok` whether or not the row existed.
  """
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(id), do: delete(__MODULE__, id)

  @doc """
  Delete a memory entry by id via a named or pid server.

  Allows tests to exercise the public callback rather than the raw
  `GenServer.call` tuple.
  """
  @spec delete(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def delete(server, id) do
    GenServer.call(server, {:delete, id})
  end

  @impl Tau.Memory.Store
  @doc """
  Full-text search via FTS5.

  Returns `{:ok, [map()]}` ordered by FTS rank descending. Rows with any
  `embedding_status` are included per D-046. Options: `:limit` (default 10),
  `:scope` (filter by scope value).
  """
  @spec search(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def search(query, opts \\ []), do: search(__MODULE__, query, opts)

  @doc "Search via a named or pid server. Useful in tests."
  @spec search(GenServer.server(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def search(server, query, opts) do
    GenServer.call(server, {:search, query, opts})
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    db_path = Keyword.get(opts, :db_path, default_db_path())

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
  def handle_call({:write, entry}, _from, %{db: db} = state) do
    result =
      :telemetry.span(
        [:tau, :memory, :write],
        %{},
        fn ->
          r = do_write(db, entry)

          meta =
            case r do
              {:ok, id} -> %{id: id}
              _ -> %{}
            end

          {r, meta}
        end
      )

    {:reply, result, state}
  end

  def handle_call({:delete, id}, _from, %{db: db} = state) do
    result =
      :telemetry.span(
        [:tau, :memory, :delete],
        %{id: id},
        fn ->
          r = do_delete(db, id)
          {r, %{id: id}}
        end
      )

    {:reply, result, state}
  end

  def handle_call({:search, query, opts}, _from, %{db: db} = state) do
    result =
      :telemetry.span(
        [:tau, :memory, :search],
        %{},
        fn ->
          r = do_search(db, query, opts)

          meta =
            case r do
              {:ok, rows} -> %{count: length(rows)}
              _ -> %{}
            end

          {r, meta}
        end
      )

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

  defp default_db_path do
    Path.join(Tau.Settings.data_dir(), "memory.db")
  end

  # Separate db-open from migration so init/1 can return distinct stop reasons.
  defp open_db(db_path) do
    with {:ok, db} <- Exqlite.Sqlite3.open(db_path),
         :ok <- Exqlite.Sqlite3.execute(db, "PRAGMA journal_mode=WAL") do
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

  defp do_write(db, entry) do
    with {:ok, kind} <- required_string(entry, "kind"),
         {:ok, scope} <- required_string(entry, "scope"),
         {:ok, content} <- required_string(entry, "content") do
      id = Uniq.UUID.uuid7() |> to_string()
      metadata_json = Jason.encode!(Map.get(entry, "metadata", %{}))

      sql = """
      INSERT INTO memory_entries (id, kind, scope, content, metadata, embedding_status)
      VALUES (?1, ?2, ?3, ?4, ?5, 'pending')
      """

      with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, String.trim(sql)),
           :ok <- Exqlite.Sqlite3.bind(stmt, [id, kind, scope, content, metadata_json]),
           step_result <- Exqlite.Sqlite3.step(db, stmt),
           :ok <- Exqlite.Sqlite3.release(db, stmt) do
        case step_result do
          :done -> {:ok, id}
          {:error, reason} -> {:error, reason}
        end
      end
    end
  end

  defp do_delete(db, id) when is_binary(id) do
    sql = "DELETE FROM memory_entries WHERE id = ?1"

    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, sql),
         :ok <- Exqlite.Sqlite3.bind(stmt, [id]),
         step_result <- Exqlite.Sqlite3.step(db, stmt),
         :ok <- Exqlite.Sqlite3.release(db, stmt) do
      case step_result do
        :done -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp do_delete(_db, id), do: {:error, {:invalid_id, id}}

  defp do_search(db, query, opts) when is_binary(query) do
    limit = Keyword.get(opts, :limit, 10)
    scope = Keyword.get(opts, :scope)

    {sql, params} = build_search_sql(query, scope, limit)

    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, sql),
         :ok <- Exqlite.Sqlite3.bind(stmt, params),
         {:ok, rows} <- Exqlite.Sqlite3.fetch_all(db, stmt),
         :ok <- Exqlite.Sqlite3.release(db, stmt) do
      {:ok, Enum.map(rows, &row_to_map/1)}
    end
  end

  defp do_search(_db, query, _opts), do: {:error, {:invalid_query, query}}

  # Build FTS5 search SQL. When scope is provided, filter on it.
  # The FTS table is joined to memory_entries via rowid to retrieve all columns.
  # Pending and failed rows are included (D-046).
  defp build_search_sql(query, nil, limit) do
    sql = """
    SELECT e.id, e.kind, e.scope, e.content, e.metadata, e.embedding_status,
           e.created_at, e.updated_at
    FROM memory_fts AS f
    JOIN memory_entries AS e ON e.rowid = f.rowid
    WHERE memory_fts MATCH ?1
    ORDER BY rank
    LIMIT ?2
    """

    {String.trim(sql), [query, limit]}
  end

  defp build_search_sql(query, scope, limit) do
    sql = """
    SELECT e.id, e.kind, e.scope, e.content, e.metadata, e.embedding_status,
           e.created_at, e.updated_at
    FROM memory_fts AS f
    JOIN memory_entries AS e ON e.rowid = f.rowid
    WHERE memory_fts MATCH ?1
      AND e.scope = ?2
    ORDER BY rank
    LIMIT ?3
    """

    {String.trim(sql), [query, scope, limit]}
  end

  defp row_to_map([
         id,
         kind,
         scope,
         content,
         metadata_json,
         embedding_status,
         created_at,
         updated_at
       ]) do
    %{
      "id" => id,
      "kind" => kind,
      "scope" => scope,
      "content" => content,
      "metadata" => Jason.decode!(metadata_json),
      "embedding_status" => embedding_status,
      "created_at" => created_at,
      "updated_at" => updated_at
    }
  end

  defp required_string(map, key) do
    case Map.get(map, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      nil -> {:error, {:missing_field, key}}
      "" -> {:error, {:empty_field, key}}
      other -> {:error, {:invalid_field, key, other}}
    end
  end
end
