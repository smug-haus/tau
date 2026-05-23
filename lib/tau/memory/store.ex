defmodule Tau.Memory.Store do
  @moduledoc """
  Behaviour for durable memory storage.

  Callbacks: `write/1`, `delete/1`, `search/2` (FTS5 full-text),
  `semantic_search/2` (sqlite-vec embeddings).

  See `docs/spec/SPEC-MEMORY-STORE.md` and `docs/adr/0020-memory-store-sqlite-driver.md`.

  ## Invariants

  - D-045: Exactly one process holds the write connection. No handle escapes
    the owning process's heap.
  - D-046: `embedding_status` ∈ `"pending" | "ready" | "failed"`. The `"failed"`
    state carries a `"transient"` / `"terminal"` kind in metadata. Pending rows
    are included in FTS results (search/2); excluded from semantic_search/2.
  - D-047: Migrations run to completion before the owner reports `:ok`.
  """

  @type entry :: %{
          required(String.t()) => String.t() | map()
        }

  @type id :: String.t()

  @type search_opts :: [limit: pos_integer(), scope: String.t()]

  @type embedding :: [float()]

  @doc """
  Persist a memory entry.

  Returns `{:ok, id}` where `id` is a UUIDv7 (time-sortable). The row is created with
  `embedding_status = "pending"`. Never raises on invalid input; returns
  `{:error, reason}` instead.
  """
  @callback write(entry()) :: {:ok, id()} | {:error, term()}

  @doc """
  Delete a memory entry by id.

  Idempotent: returns `:ok` whether or not the row existed. Returns
  `{:error, reason}` only on a DB error.
  """
  @callback delete(id()) :: :ok | {:error, term()}

  @doc """
  Full-text search over memory entries (FTS5).

  Returns `{:ok, [map()]}` ordered by FTS rank descending. Rows with any
  `embedding_status` (`"pending"`, `"ready"`, `"failed"`) are included (D-046).

  Options:
  - `:limit` — maximum number of results (default 10).
  - `:scope` — filter results to this scope value.
  """
  @callback search(query :: String.t(), opts :: search_opts()) ::
              {:ok, [map()]} | {:error, term()}

  @doc """
  Semantic (vector) search over memory entries using the sqlite-vec extension.

  Only rows with `embedding_status = "ready"` are returned. Pending and failed
  rows are excluded (D-046). Results are ordered by cosine distance ascending
  (nearest first).

  Options:
  - `:limit` — maximum number of results (default 10).
  - `:scope` — filter results to this scope value.
  """
  @callback semantic_search(embedding :: embedding(), opts :: search_opts()) ::
              {:ok, [map()]} | {:error, term()}

  @doc "Look up the configured store implementation."
  @spec impl() :: module()
  def impl, do: Application.get_env(:tau, :memory_store, Tau.Memory.Store.SQLite)
end
