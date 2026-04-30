defmodule Tau.MCP.Transport.Http do
  @moduledoc """
  Request/response HTTP transport for MCP servers that expose a single
  POST endpoint and respond with one JSON-RPC message per request.

  No server-pushed notifications — use `Tau.MCP.Transport.Sse` for that.

  Config:

      %{ "url" => "https://mcp.example.com/rpc",
         "headers" => %{"authorization" => "Bearer ..."} }
  """

  @behaviour Tau.MCP.Transport

  @impl Tau.MCP.Transport
  def connect(%{} = config) do
    url = config["url"] || config[:url]
    headers = Map.get(config, "headers", %{}) |> Enum.to_list()
    {:ok, %{url: url, headers: headers, queue: :queue.new()}}
  end

  @impl Tau.MCP.Transport
  def send(%{url: url, headers: headers, queue: q} = state, payload) do
    body = IO.iodata_to_binary(payload)
    headers = [{"content-type", "application/json"} | headers]

    case Finch.build(:post, url, headers, body) |> Finch.request(Tau.Providers.Finch) do
      {:ok, %Finch.Response{status: s, body: resp}} when s in 200..299 ->
        {:ok, %{state | queue: :queue.in(resp, q)}}

      {:ok, %Finch.Response{status: s}} ->
        {:error, {:http_status, s}}

      {:error, e} ->
        {:error, e}
    end
  end

  @impl Tau.MCP.Transport
  def recv(%{queue: q} = state, _timeout) do
    case :queue.out(q) do
      {{:value, line}, q2} -> {:ok, [line], %{state | queue: q2}}
      {:empty, _} -> {:error, :empty}
    end
  end

  @impl Tau.MCP.Transport
  def close(_state), do: :ok
end
