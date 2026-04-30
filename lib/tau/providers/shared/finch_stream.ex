defmodule Tau.Providers.Shared.FinchStream do
  @moduledoc """
  Shared streaming engine for provider clients.

  Two parsing modes:

    * `:sse` (default) — chunks fed through `Tau.Providers.Shared.SSE`,
      decoder receives `%{event, data, id, retry}` events.
    * `:raw` — chunks pass straight through to the decoder, which is
      responsible for any framing it needs (used by Bedrock's AWS
      event-stream binary framing).

  Handles the common boilerplate either way:

    * spawns a linked Task driving `Finch.stream/4`
    * forwards `{:status, _}/{:headers, _}/{:data, _}/:done` chunks
      back as messages
    * 60-second receive timeout with retryable `%Event.Error{}`
    * cleanup of the spawned task on Stream halt

  Provider modules supply a `decode/2` that turns parsed events (SSE map
  or raw binary) into `Tau.Provider.Event` structs and an opaque partial
  state.
  """

  alias Tau.Provider.Event
  alias Tau.Providers.Shared.SSE

  @doc """
  Returns a `Stream.resource/3` of `Tau.Provider.Event` structs.

  `decoder` is `(event, partial_state) -> {events, partial_state}`.
  In `:sse` mode the decoder receives an SSE event map; in `:raw` mode
  it receives the raw binary chunk.
  """
  @spec run(Finch.Request.t(), (any(), term() -> {[Event.t()], term()}), term(), keyword()) ::
          Enumerable.t()
  def run(request, decoder, init_partial \\ %{}, opts \\ []) do
    mode = Keyword.get(opts, :mode, :sse)

    Stream.resource(
      fn -> open(request, init_partial, mode) end,
      fn s -> next(s, decoder) end,
      &cleanup/1
    )
  end

  defp open(request, init_partial, mode) do
    parent = self()
    ref = make_ref()

    task =
      Task.async(fn ->
        Finch.stream(request, Tau.Providers.Finch, nil, fn
          {:status, n}, _ -> Process.send(parent, {ref, {:status, n}}, [])
          {:headers, h}, _ -> Process.send(parent, {ref, {:headers, h}}, [])
          {:data, c}, _ -> Process.send(parent, {ref, {:data, c}}, [])
          {:done}, _ -> Process.send(parent, {ref, :done}, [])
        end)
        |> case do
          {:ok, _} -> Process.send(parent, {ref, :end}, [])
          {:error, e} -> Process.send(parent, {ref, {:error, e}}, [])
        end
      end)

    %{
      ref: ref,
      task: task,
      mode: mode,
      sse: SSE.new(),
      partial: init_partial,
      pending: [],
      finished?: false,
      status: nil
    }
  end

  defp next(%{pending: [evt | rest]} = s, _decoder) do
    {[evt], %{s | pending: rest}}
  end

  defp next(%{finished?: true}, _), do: {:halt, :done}

  defp next(s, decoder) do
    receive do
      {ref, msg} when ref == s.ref -> handle(msg, s, decoder) |> recur(decoder)
    after
      60_000 ->
        {[%Event.Error{reason: :timeout, retryable?: true}], %{s | finished?: true}}
    end
  end

  defp recur(%{pending: [], finished?: false} = s, decoder), do: next(s, decoder)
  defp recur(s, decoder), do: next(s, decoder)

  defp cleanup(:done), do: :ok

  defp cleanup(s) do
    if s.task && Process.alive?(s.task.pid), do: Task.shutdown(s.task, :brutal_kill)
    :ok
  end

  defp handle({:status, n}, s, _decoder) when n in 200..299, do: %{s | status: n}

  defp handle({:status, n}, s, _decoder) do
    err = %Event.Error{reason: {:http_status, n}, retryable?: n in [408, 429, 500, 502, 503, 504]}
    %{s | status: n, pending: s.pending ++ [err], finished?: true}
  end

  defp handle({:headers, _}, s, _), do: s

  defp handle({:data, chunk}, %{status: st, mode: :sse} = s, decoder) when st in 200..299 do
    {sse_events, sse} = SSE.feed(s.sse, chunk)

    {events, partial} =
      Enum.reduce(sse_events, {[], s.partial}, fn ev, {acc, p} ->
        {evs, p2} = decoder.(ev, p)
        {acc ++ evs, p2}
      end)

    %{s | sse: sse, partial: partial, pending: s.pending ++ events}
  end

  defp handle({:data, chunk}, %{status: st, mode: :raw} = s, decoder) when st in 200..299 do
    {events, partial} = decoder.(chunk, s.partial)
    %{s | partial: partial, pending: s.pending ++ events}
  end

  defp handle({:data, _chunk}, s, _decoder), do: s

  defp handle(:done, s, _), do: s

  defp handle(:end, s, _), do: %{s | finished?: true}

  defp handle({:error, reason}, s, _) do
    %{s | pending: s.pending ++ [%Event.Error{reason: reason, retryable?: true}], finished?: true}
  end
end
