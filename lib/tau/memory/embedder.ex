defmodule Tau.Memory.Embedder do
  @moduledoc """
  Behaviour for pluggable embedding providers.

  Implementations generate a vector representation for a given text `content`
  and update the memory store entry asynchronously. The actual network call
  MUST NOT run on the `Tau.Memory.Store.SQLite` owner GenServer (D-045).

  ## Built-in implementation

  `Tau.Memory.EmbeddingWorker` implements this behaviour by spawning a `Task`
  for each embedding request and calling back into the store via
  `Tau.Memory.Store.SQLite.store_embedding/3`.

  ## Selecting an implementation

  Configure via `Application.put_env(:tau, :embedder, MyEmbedder)` or
  use the default (`Tau.Memory.EmbeddingWorker`) when `:tau, :embedder` is unset.

  In tests, configure a `Mox`-based mock:

      Mox.defmock(MockEmbedder, for: Tau.Memory.Embedder)
      Application.put_env(:tau, :embedder, MockEmbedder)
  """

  @doc """
  Asynchronously embed `content` for `entry_id` and update `store`.

  Implementations MUST:
  - Run the network call off the calling process (spawn a Task or use a pool).
  - Call `Tau.Memory.Store.SQLite.store_embedding/3` when the embedding is ready
    or has failed, passing `{:ok, [float()]}` or `{:error, kind, reason}`.
  - Never raise across process boundaries; return `{:error, kind, reason}` instead.

  Returns `{:ok, task_or_ref}` immediately; the store update is asynchronous.
  """
  @callback embed(store :: GenServer.server(), entry_id :: String.t(), content :: String.t()) ::
              {:ok, term()}
end
