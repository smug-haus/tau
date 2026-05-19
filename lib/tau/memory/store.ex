defmodule Tau.Memory.Store do
  @moduledoc """
  Behaviour for durable memory storage.

  PR1 delivers `write/1` and `delete/1`. `search/2` (FTS5) lands in PR2;
  `semantic_search/2` (sqlite-vec embeddings) in PR3.

  See `docs/spec/SPEC-MEMORY-STORE.md` and `docs/adr/0020-memory-store-sqlite-driver.md`.

  ## Invariants

  - D-045: Exactly one process holds the write connection. No handle escapes
    the owning process's heap.
  - D-046: `embedding_status` ∈ `"pending" | "ready" | "failed"`. The `"failed"`
    state carries a `"transient"` / `"terminal"` kind in metadata.
  - D-047: Migrations run to completion before the owner reports `:ok`.
  """

  @type entry :: %{
          required(String.t()) => String.t() | map()
        }

  @type id :: String.t()

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

  @doc "Look up the configured store implementation."
  @spec impl() :: module()
  def impl, do: Application.get_env(:tau, :memory_store, Tau.Memory.Store.SQLite)
end
