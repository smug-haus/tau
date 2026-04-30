defmodule Tau.MCP.Transport.Sse do
  @moduledoc """
  SSE transport for MCP. Server pushes notifications + responses on a
  long-lived `GET`; client posts requests via a separate endpoint.

  Uses `Tau.Providers.Shared.SSE` for parsing.

  Config:

      %{
        "sse_url" => "https://mcp.example.com/events",
        "post_url" => "https://mcp.example.com/messages",
        "headers" => %{"authorization" => "Bearer ..."}
      }

  Lifecycle: opens the SSE GET in a linked Task that forwards each
  parsed event back to this caller process.
  """

  @behaviour Tau.MCP.Transport

  alias Tau.Providers.Shared.SSE

  @impl Tau.MCP.Transport
  def connect(%{} = config) do
    sse_url = config["sse_url"] || config[:sse_url]
    post_url = config["post_url"] || config[:post_url]
    headers = Map.get(config, "headers", %{}) |> Enum.to_list()
    parent = self()
    ref = make_ref()

    task =
      Task.async(fn ->
        request = Finch.build(:get, sse_url, headers ++ [{"accept", "text/event-stream"}])

        Finch.stream(request, Tau.Providers.Finch, SSE.new(), fn
          {:status, _}, acc ->
            acc

          {:headers, _}, acc ->
            acc

          {:data, chunk}, acc ->
            {events, acc2} = SSE.feed(acc, chunk)

            Enum.each(events, fn ev ->
              if ev.data != "", do: Process.send(parent, {ref, {:line, ev.data}}, [])
            end)

            acc2

          {:done}, acc ->
            Process.send(parent, {ref, :done}, [])
            acc
        end)
      end)

    {:ok, %{ref: ref, task: task, post_url: post_url, headers: headers, queue: :queue.new()}}
  end

  @impl Tau.MCP.Transport
  def send(%{post_url: url, headers: headers} = state, payload) do
    headers = [{"content-type", "application/json"} | headers]
    body = IO.iodata_to_binary(payload)

    case Finch.build(:post, url, headers, body) |> Finch.request(Tau.Providers.Finch) do
      {:ok, _} -> {:ok, state}
      err -> err
    end
  end

  @impl Tau.MCP.Transport
  def recv(%{ref: ref, queue: q} = state, timeout) do
    case :queue.out(q) do
      {{:value, line}, q2} ->
        {:ok, [line], %{state | queue: q2}}

      {:empty, _} ->
        receive do
          {^ref, {:line, line}} -> {:ok, [line], state}
          {^ref, :done} -> {:error, :closed}
        after
          timeout -> {:error, :timeout}
        end
    end
  end

  @impl Tau.MCP.Transport
  def close(%{task: task}) do
    if task && Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
    :ok
  end
end
