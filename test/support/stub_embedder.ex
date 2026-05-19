defmodule Tau.Memory.StubEmbedder do
  @moduledoc """
  Test stub for `Tau.Memory.Embedder`.

  By default (no configuration): does nothing — embedding_status stays 'pending'.
  When `Application.get_env(:tau, :stub_embedder_result)` is set, calls
  `Store.SQLite.store_embedding/3` with that result and emits
  `[:tau, :memory, :embedding, :start/:stop]` telemetry (matching
  `EmbeddingWorker`'s span). This lets tests sync deterministically on the
  stop event rather than relying on timing.

  The stub is called from a Task spawned by `Store.SQLite.handle_continue/2`,
  so it runs off the store's GenServer process — `GenServer.call` back to the
  store is safe.

  Set the result *before* calling `write/1`:

      Application.put_env(:tau, :stub_embedder_result, {:ok, List.duplicate(0.0, 1536)})
      # ... write, wait for [:tau, :memory, :embedding, :stop] telemetry, assert ...
      Application.delete_env(:tau, :stub_embedder_result)
  """

  @behaviour Tau.Memory.Embedder

  alias Tau.Memory.Store.SQLite, as: MemoryStore

  @impl Tau.Memory.Embedder
  def embed(store, entry_id, _content) do
    result = Application.get_env(:tau, :stub_embedder_result)

    :telemetry.span(
      [:tau, :memory, :embedding],
      %{entry_id: entry_id},
      fn ->
        case result do
          nil ->
            # No-op: leave embedding_status as 'pending'.
            meta = %{status: :pending}
            {{:ok, nil}, meta}

          embedding_result ->
            # Call back into the store. Safe because this function runs off the
            # store's GenServer process (inside a Task spawned by handle_continue).
            MemoryStore.store_embedding(store, entry_id, embedding_result)

            meta =
              case embedding_result do
                {:ok, _} -> %{status: :ready}
                {:error, kind, _} -> %{status: :failed, kind: kind}
              end

            {{:ok, nil}, meta}
        end
      end
    )
  end
end
