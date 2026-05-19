defmodule Tau.Memory.StubEmbedder do
  @moduledoc """
  Test stub for `Tau.Memory.Embedder`.

  By default (no configuration): does nothing — embedding_status stays 'pending'.
  When `Application.get_env(:tau, :stub_embedder_result)` is set, immediately
  calls `Store.SQLite.store_embedding/3` with that result on the calling process,
  allowing end-to-end pipeline tests without spawning async Tasks.

  Set the result *before* calling `write/1`:

      Application.put_env(:tau, :stub_embedder_result, {:ok, List.duplicate(0.0, 1536)})
      # ... write and assert ...
      Application.delete_env(:tau, :stub_embedder_result)
  """

  @behaviour Tau.Memory.Embedder

  alias Tau.Memory.Store.SQLite, as: MemoryStore

  @impl Tau.Memory.Embedder
  def embed(store, entry_id, _content) do
    case Application.get_env(:tau, :stub_embedder_result) do
      nil ->
        # No-op: leave embedding_status as 'pending'.
        {:ok, nil}

      result ->
        # Synchronously (on calling process) call back into the store so tests
        # can assert status transitions without async waits.
        MemoryStore.store_embedding(store, entry_id, result)
        {:ok, nil}
    end
  end
end
