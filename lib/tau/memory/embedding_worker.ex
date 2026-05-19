defmodule Tau.Memory.EmbeddingWorker do
  @moduledoc """
  Off-process embedding pipeline for `Tau.Memory.Store.SQLite`.

  Implements the `Tau.Memory.Embedder` behaviour. Each call to `embed/3` spawns
  a `Task` under `Tau.Tools.TaskSupervisor` (via `Task.Supervisor.async_nolink/2`)
  so the embedding network call (via Finch/HTTP) never runs on the
  `Store.SQLite` owner GenServer and an embedding crash is isolated to its task
  rather than propagating to the caller (D-045, SPEC-MEMORY-STORE §3 C-004).

  ## Error classification

  Network timeouts → `:transient` (eligible for retry).
  Content-too-long / policy rejection → `:terminal` (not retried).

  On success: `Store.SQLite.store_embedding/3` is called with `{:ok, embedding}`.
  On failure: `Store.SQLite.store_embedding/3` is called with `{:error, kind, reason}`.

  The embedding provider is resolved via `Application.get_env(:tau, :embedder,
  Tau.Memory.EmbeddingWorker)`. Override in tests with `Tau.Memory.MockEmbedder`
  (Mox) or configure a different module implementing `Tau.Memory.Embedder`.

  ## Configuring the embedding HTTP endpoint

  Set `:tau, :embedding_url` (e.g. `"https://api.openai.com/v1/embeddings"`) and
  `:tau, :embedding_api_key`. When unconfigured, `embed/3` returns
  `{:error, :terminal, :not_configured}` and marks the entry as failed.
  """

  @behaviour Tau.Memory.Embedder

  alias Tau.Memory.Store.SQLite, as: MemoryStore

  require Logger

  @default_dim 1536
  @request_timeout_ms 30_000

  @doc """
  Spawn a Task to embed `content` and update the store.

  `store` is a `GenServer.server()` (pid or registered name). The Task calls
  back into `store` with `Store.SQLite.store_embedding/3` when done.

  Returns `{:ok, task}` immediately; the store update happens asynchronously.
  """
  @impl Tau.Memory.Embedder
  @spec embed(GenServer.server(), String.t(), String.t()) :: {:ok, Task.t()}
  def embed(store, entry_id, content) do
    task =
      Task.Supervisor.async_nolink(Tau.Tools.TaskSupervisor, fn ->
        :telemetry.span(
          [:tau, :memory, :embedding],
          %{entry_id: entry_id},
          fn ->
            result = do_embed(content)
            MemoryStore.store_embedding(store, entry_id, result)

            meta =
              case result do
                {:ok, _} -> %{status: :ready}
                {:error, kind, _} -> %{status: :failed, kind: kind}
              end

            {result, meta}
          end
        )
      end)

    {:ok, task}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp do_embed(content) do
    url = Application.get_env(:tau, :embedding_url)
    api_key = Application.get_env(:tau, :embedding_api_key)

    cond do
      is_nil(url) or is_nil(api_key) ->
        Logger.warning(
          "[EmbeddingWorker] Not configured: set :tau, :embedding_url and :embedding_api_key"
        )

        {:error, :terminal, :not_configured}

      byte_size(content) > 32_768 ->
        {:error, :terminal, :content_too_long}

      true ->
        call_embedding_api(url, api_key, content)
    end
  end

  defp call_embedding_api(url, api_key, content) do
    body = Jason.encode!(%{"input" => content, "model" => "text-embedding-3-small"})

    headers = [
      {"authorization", "Bearer #{api_key}"},
      {"content-type", "application/json"}
    ]

    request = Finch.build(:post, url, headers, body)
    finch_name = Application.get_env(:tau, :finch_name, Tau.Finch)

    case Finch.request(request, finch_name, receive_timeout: @request_timeout_ms) do
      {:ok, %Finch.Response{status: 200, body: resp_body}} ->
        parse_embedding_response(resp_body)

      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        kind = classify_http_error(status)
        {:error, kind, {:http_error, status, resp_body}}

      {:error, %Mint.TransportError{}} = err ->
        {:error, :transient, err}

      {:error, reason} ->
        {:error, :transient, reason}
    end
  end

  defp parse_embedding_response(body) do
    case Jason.decode(body) do
      {:ok, %{"data" => [%{"embedding" => embedding} | _]}} when is_list(embedding) ->
        dim = Application.get_env(:tau, :embedding_dim, @default_dim)

        if length(embedding) == dim do
          {:ok, embedding}
        else
          {:error, :terminal, {:dim_mismatch, expected: dim, got: length(embedding)}}
        end

      {:ok, _other} ->
        {:error, :terminal, :unexpected_response_shape}

      {:error, reason} ->
        {:error, :terminal, {:json_decode_error, reason}}
    end
  end

  defp classify_http_error(status) when status in [413, 422, 400], do: :terminal
  defp classify_http_error(429), do: :transient
  defp classify_http_error(status) when status >= 500, do: :transient
  defp classify_http_error(_), do: :terminal
end
