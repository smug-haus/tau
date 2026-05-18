defmodule Tau.Memory.Store.SQLite do
  @moduledoc """
  SQLite-backed implementation of `Tau.Memory.Store`.

  A `GenServer` that owns a single `Exqlite.Sqlite3` write connection (a NIF
  reference). The connection never escapes this process's heap (D-045). All
  writes are serialised through the mailbox (D-045, ADR-0020): SQLite has a
  single-writer constraint that the mailbox enforces without external locking.

  Schema migrations run to completion in `init/1` before the process reports
  `{:ok, state}`. A migration failure causes `init/1` to return
  `{:stop, {:migration_failed, reason}}`, hard-failing boot (D-047).

  Database location: `Path.join(Tau.Settings.data_dir(), "memory.db")`.
  WAL mode is enabled immediately after `open`.

  ## Telemetry

  Every `write/1` and `delete/1` call emits:

    - `[:tau, :memory, :write | :delete, :start]` — before the operation.
    - `[:tau, :memory, :write | :delete, :stop]` — after a successful operation.
    - `[:tau, :memory, :write | :delete, :exception]` — if `handle_call` raises.

  Measurements on `:stop`: `%{duration: non_neg_integer()}` (nanoseconds).
  Metadata on `:stop`: `%{id: binary()}` (write only).
  """

  @behaviour Tau.Memory.Store

  use GenServer

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
  is optional (defaults to `{}`). Returns `{:ok, ulid}` or `{:error, reason}`.
  """
  @spec write(map()) :: {:ok, String.t()} | {:error, term()}
  def write(entry) do
    GenServer.call(__MODULE__, {:write, entry})
  end

  @impl Tau.Memory.Store
  @doc """
  Delete a memory entry by id.

  Idempotent: `:ok` whether or not the row existed.
  """
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(id) do
    GenServer.call(__MODULE__, {:delete, id})
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    db_path = Keyword.get(opts, :db_path, default_db_path())

    with :ok <- File.mkdir_p(Path.dirname(db_path)),
         {:ok, db} <- Exqlite.Sqlite3.open(db_path),
         :ok <- Exqlite.Sqlite3.execute(db, "PRAGMA journal_mode=WAL"),
         :ok <- Tau.Memory.Migrations.run(db) do
      {:ok, %{db: db}}
    else
      {:error, reason} ->
        {:stop, {:migration_failed, reason}}
    end
  end

  @impl GenServer
  def handle_call({:write, entry}, _from, %{db: db} = state) do
    t0 = System.monotonic_time()
    :telemetry.execute([:tau, :memory, :write, :start], %{system_time: System.system_time()}, %{})

    result = do_write(db, entry)

    duration = System.monotonic_time() - t0

    case result do
      {:ok, id} ->
        :telemetry.execute(
          [:tau, :memory, :write, :stop],
          %{duration: duration},
          %{id: id}
        )

      {:error, _} ->
        :ok
    end

    {:reply, result, state}
  end

  def handle_call({:delete, id}, _from, %{db: db} = state) do
    t0 = System.monotonic_time()

    :telemetry.execute(
      [:tau, :memory, :delete, :start],
      %{system_time: System.system_time()},
      %{id: id}
    )

    result = do_delete(db, id)

    duration = System.monotonic_time() - t0

    :telemetry.execute(
      [:tau, :memory, :delete, :stop],
      %{duration: duration},
      %{id: id}
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

  defp required_string(map, key) do
    case Map.get(map, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      nil -> {:error, {:missing_field, key}}
      "" -> {:error, {:empty_field, key}}
      other -> {:error, {:invalid_field, key, other}}
    end
  end
end
