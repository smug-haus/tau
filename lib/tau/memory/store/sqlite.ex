defmodule Tau.Memory.Store.SQLite do
  @moduledoc """
  SQLite-backed implementation of `Tau.Memory.Store`.

  A `GenServer` that owns a single `Exqlite.Sqlite3` write connection (a NIF
  reference). The connection never escapes this process's heap (D-045). All
  writes and searches are serialised through the mailbox (D-045, ADR-0020):
  SQLite has a single-writer constraint that the mailbox enforces without
  external locking. Read operations (search/2, semantic_search/2) also route
  through the mailbox to avoid exposing the db reference.

  Schema migrations run to completion in `init/1` before the process reports
  `{:ok, state}`. A DB-open failure causes `init/1` to return
  `{:stop, {:db_open_failed, reason}}`. A migration failure causes `init/1` to
  return `{:stop, {:migration_failed, reason}}`, hard-failing boot (D-047).

  Database location: `Path.join(Tau.Settings.data_dir(), "memory.db")`.
  WAL mode is enabled immediately after `open`.

  PR2 adds `search/2` (FTS5 full-text search). The FTS index is maintained by
  three triggers added in migrations 004–006 (insert, delete, update). Pending
  and failed rows are included in FTS results per D-046.

  PR3 adds `semantic_search/2` (sqlite-vec vector search). The sqlite-vec
  loadable extension is loaded in `init/1` before migrations run. Vector data
  lives in the `memory_vec` vec0 virtual table (migration 007). Only rows with
  `embedding_status = "ready"` are included in semantic search results (D-046).

  The embedding pipeline (populating `memory_vec` and transitioning
  `embedding_status` from `"pending"` to `"ready"` or `"failed"`) runs OFF this
  GenServer via `Tau.Memory.EmbeddingWorker`. After each successful `write/1`,
  the store dispatches embedding via the configured `Tau.Memory.Embedder`
  implementation (default: `Tau.Memory.EmbeddingWorker`). The worker calls back
  into the GenServer with `store_embedding/3` to update state, keeping the
  embedding network call off the owner process.

  ## Telemetry

  Every `write/1`, `delete/1`, `search/2`, and `semantic_search/2` call emits:

    - `[:tau, :memory, :write | :delete | :search | :semantic_search, :start]` — before.
    - `[:tau, :memory, :write | :delete | :search | :semantic_search, :stop]` — on success.
    - `[:tau, :memory, :write | :delete | :search | :semantic_search, :exception]` — on error.

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

  @impl Tau.Memory.Store
  @doc """
  Semantic (vector) similarity search via sqlite-vec.

  Only rows with `embedding_status = "ready"` are returned (D-046). Results
  are ordered by cosine distance ascending (nearest first). `embedding` must be
  a list of floats matching the dimension used when `store_embedding/3` was
  called (1536 for OpenAI text-embedding-3-small; configurable via `:vec_dim`).

  Options: `:limit` (default 10), `:scope` (filter by scope value).
  """
  @spec semantic_search([float()], keyword()) :: {:ok, [map()]} | {:error, term()}
  def semantic_search(embedding, opts \\ []), do: semantic_search(__MODULE__, embedding, opts)

  @doc "Semantic search via a named or pid server. Useful in tests."
  @spec semantic_search(GenServer.server(), [float()], keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def semantic_search(server, embedding, opts) do
    GenServer.call(server, {:semantic_search, embedding, opts})
  end

  @doc """
  Store a computed embedding for an entry and transition its `embedding_status`
  to `"ready"` (or `"failed"` on error).

  Called by `Tau.Memory.EmbeddingWorker` — runs OFF the owner GenServer — after
  the embedding network call completes. The result is applied atomically via
  a single GenServer.call so the connection never escapes the owner process.

  `embedding` is a list of floats. `error_kind` is `:transient` or `:terminal`
  for the failure path; ignored on success.
  """
  @spec store_embedding(GenServer.server(), String.t(), {:ok, [float()]} | {:error, atom(), term()}) ::
          :ok | {:error, term()}
  def store_embedding(server, entry_id, result) do
    GenServer.call(server, {:store_embedding, entry_id, result})
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

    # Dispatch embedding off-process after a successful write.
    # The embedder is configured via :tau, :embedder (default: Tau.Memory.EmbeddingWorker).
    # It calls back into this GenServer via store_embedding/3 when done.
    case result do
      {:ok, id} ->
        content = Map.get(entry, "content", "")
        embedder = Application.get_env(:tau, :embedder, Tau.Memory.EmbeddingWorker)
        embedder.embed(self(), id, content)

      _ ->
        :ok
    end

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

  def handle_call({:semantic_search, embedding, opts}, _from, %{db: db} = state) do
    result =
      :telemetry.span(
        [:tau, :memory, :semantic_search],
        %{},
        fn ->
          r = do_semantic_search(db, embedding, opts)

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

  def handle_call({:store_embedding, entry_id, {:ok, embedding}}, _from, %{db: db} = state) do
    result = do_store_embedding(db, entry_id, embedding)
    {:reply, result, state}
  end

  def handle_call({:store_embedding, entry_id, {:error, kind, _reason}}, _from, %{db: db} = state)
      when kind in [:transient, :terminal] do
    result = do_mark_embedding_failed(db, entry_id, kind)
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
  # sqlite-vec extension is loaded after WAL mode is set and before migrations
  # run, so the vec0 virtual table migration (007) can reference vec0.
  defp open_db(db_path) do
    with {:ok, db} <- Exqlite.Sqlite3.open(db_path),
         :ok <- Exqlite.Sqlite3.execute(db, "PRAGMA journal_mode=WAL"),
         :ok <- load_vec_extension(db) do
      {:ok, db}
    else
      {:error, reason} -> {:stop, {:db_open_failed, reason}}
    end
  end

  defp load_vec_extension(db) do
    with :ok <- Exqlite.Sqlite3.enable_load_extension(db, true),
         {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, "SELECT load_extension(?1)"),
         :ok <- Exqlite.Sqlite3.bind(stmt, [SqliteVec.path()]),
         _result <- Exqlite.Sqlite3.step(db, stmt),
         :ok <- Exqlite.Sqlite3.release(db, stmt) do
      # Disable general extension loading after the vec extension is loaded.
      # This closes the extension-loading channel while keeping vec0 active.
      Exqlite.Sqlite3.enable_load_extension(db, false)
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

  # Semantic search using the memory_vec vec0 virtual table.
  # Only rows with embedding_status = 'ready' are returned (D-046).
  # Vectors are passed as JSON arrays (sqlite-vec accepts JSON text for match).
  defp do_semantic_search(db, embedding, opts) when is_list(embedding) do
    limit = Keyword.get(opts, :limit, 10)
    scope = Keyword.get(opts, :scope)

    case Jason.encode(embedding) do
      {:ok, embedding_json} ->
        {sql, params} = build_semantic_search_sql(embedding_json, scope, limit)

        with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, sql),
             :ok <- Exqlite.Sqlite3.bind(stmt, params),
             {:ok, rows} <- Exqlite.Sqlite3.fetch_all(db, stmt),
             :ok <- Exqlite.Sqlite3.release(db, stmt) do
          {:ok, Enum.map(rows, &semantic_row_to_map/1)}
        end

      {:error, reason} ->
        {:error, {:invalid_embedding, reason}}
    end
  end

  defp do_semantic_search(_db, embedding, _opts),
    do: {:error, {:invalid_embedding, embedding}}

  # sqlite-vec KNN queries require LIMIT on the vec0 virtual table itself —
  # wrapping it in a subquery satisfies the optimizer. The outer query then
  # joins memory_entries and filters to embedding_status = 'ready' (D-046).
  # Results ordered by vec0 cosine distance ascending (nearest first).
  defp build_semantic_search_sql(embedding_json, nil, limit) do
    sql = """
    SELECT e.id, e.kind, e.scope, e.content, e.metadata, e.embedding_status,
           e.created_at, e.updated_at, v.distance
    FROM (
      SELECT entry_id, distance
        FROM memory_vec
       WHERE embedding MATCH ?1
       LIMIT ?2
    ) AS v
    JOIN memory_entries AS e ON e.id = v.entry_id
    WHERE e.embedding_status = 'ready'
    ORDER BY v.distance
    """

    {String.trim(sql), [embedding_json, limit]}
  end

  defp build_semantic_search_sql(embedding_json, scope, limit) do
    sql = """
    SELECT e.id, e.kind, e.scope, e.content, e.metadata, e.embedding_status,
           e.created_at, e.updated_at, v.distance
    FROM (
      SELECT entry_id, distance
        FROM memory_vec
       WHERE embedding MATCH ?1
       LIMIT ?2
    ) AS v
    JOIN memory_entries AS e ON e.id = v.entry_id
    WHERE e.embedding_status = 'ready'
      AND e.scope = ?3
    ORDER BY v.distance
    """

    {String.trim(sql), [embedding_json, limit, scope]}
  end

  defp semantic_row_to_map([
         id,
         kind,
         scope,
         content,
         metadata_json,
         embedding_status,
         created_at,
         updated_at,
         distance
       ]) do
    %{
      "id" => id,
      "kind" => kind,
      "scope" => scope,
      "content" => content,
      "metadata" => Jason.decode!(metadata_json),
      "embedding_status" => embedding_status,
      "created_at" => created_at,
      "updated_at" => updated_at,
      "distance" => distance
    }
  end

  # Store a computed embedding: upsert into memory_vec (vec0 doesn't support
  # SQL UPSERT syntax, so we DELETE then INSERT inside an explicit transaction)
  # and flip embedding_status to 'ready'. The transaction guarantees that a
  # failed INSERT rolls back the DELETE rather than leaving the row vector-less.
  defp do_store_embedding(db, entry_id, embedding) when is_list(embedding) do
    case Jason.encode(embedding) do
      {:ok, embedding_json} ->
        delete_sql = "DELETE FROM memory_vec WHERE entry_id = ?1"
        insert_sql = "INSERT INTO memory_vec(entry_id, embedding) VALUES (?1, ?2)"

        with :ok <- Exqlite.Sqlite3.execute(db, "BEGIN"),
             {:ok, del_stmt} <- Exqlite.Sqlite3.prepare(db, delete_sql),
             :ok <- Exqlite.Sqlite3.bind(del_stmt, [entry_id]),
             _del_result <- Exqlite.Sqlite3.step(db, del_stmt),
             :ok <- Exqlite.Sqlite3.release(db, del_stmt),
             {:ok, ins_stmt} <- Exqlite.Sqlite3.prepare(db, insert_sql),
             :ok <- Exqlite.Sqlite3.bind(ins_stmt, [entry_id, embedding_json]),
             step_result <- Exqlite.Sqlite3.step(db, ins_stmt),
             :ok <- Exqlite.Sqlite3.release(db, ins_stmt) do
          case step_result do
            :done ->
              Exqlite.Sqlite3.execute(db, "COMMIT")
              update_embedding_status(db, entry_id, "ready")

            {:error, reason} ->
              Exqlite.Sqlite3.execute(db, "ROLLBACK")
              {:error, reason}
          end
        else
          {:error, reason} ->
            Exqlite.Sqlite3.execute(db, "ROLLBACK")
            {:error, reason}
        end

      {:error, reason} ->
        {:error, {:invalid_embedding, reason}}
    end
  end

  defp do_store_embedding(_db, _entry_id, embedding),
    do: {:error, {:invalid_embedding, embedding}}

  # Mark an entry's embedding as failed; encode the error kind in metadata.
  defp do_mark_embedding_failed(db, entry_id, kind) when kind in [:transient, :terminal] do
    # Read current metadata, merge error kind, write back.
    read_sql = "SELECT metadata FROM memory_entries WHERE id = ?1"

    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, read_sql),
         :ok <- Exqlite.Sqlite3.bind(stmt, [entry_id]),
         {:ok, rows} <- Exqlite.Sqlite3.fetch_all(db, stmt),
         :ok <- Exqlite.Sqlite3.release(db, stmt) do
      case rows do
        [[metadata_json]] ->
          metadata = Jason.decode!(metadata_json)
          new_metadata = Map.put(metadata, "embedding_error_kind", to_string(kind))
          new_metadata_json = Jason.encode!(new_metadata)

          update_sql = """
          UPDATE memory_entries
             SET embedding_status = 'failed', metadata = ?1, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
           WHERE id = ?2
          """

          with {:ok, stmt2} <- Exqlite.Sqlite3.prepare(db, String.trim(update_sql)),
               :ok <- Exqlite.Sqlite3.bind(stmt2, [new_metadata_json, entry_id]),
               step_result <- Exqlite.Sqlite3.step(db, stmt2),
               :ok <- Exqlite.Sqlite3.release(db, stmt2) do
            case step_result do
              :done -> :ok
              {:error, reason} -> {:error, reason}
            end
          end

        [] ->
          {:error, {:not_found, entry_id}}
      end
    end
  end

  defp update_embedding_status(db, entry_id, status) when status in ["ready", "failed"] do
    sql = """
    UPDATE memory_entries
       SET embedding_status = ?1, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
     WHERE id = ?2
    """

    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, String.trim(sql)),
         :ok <- Exqlite.Sqlite3.bind(stmt, [status, entry_id]),
         step_result <- Exqlite.Sqlite3.step(db, stmt),
         :ok <- Exqlite.Sqlite3.release(db, stmt) do
      case step_result do
        :done -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

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
