defmodule Tau.Providers.Shared.FinchStream do
  @moduledoc """
  Shared SSE-streaming engine for provider clients.

  Handles the boilerplate of:

    * spawning a linked Task that drives `Finch.stream/4`
    * forwarding `{:status, _}/{:headers, _}/{:data, _}/:done` chunks back
      as messages
    * incremental SSE parsing via `Tau.Providers.Shared.SSE`
    * 60-second timeout with retryable error events

  Provider modules supply a `decode/3` callback that turns SSE events into
  their normalised `Tau.Provider.Event` structs. The engine owns the
  Stream.resource/3 lifecycle.

  Usage:

      Tau.Providers.Shared.FinchStream.run(request, fn evt, partial ->
        Tau.Providers.OpenAI.Chat.decode(evt, partial)
      end)
  """

  alias Tau.Provider.Event
  alias Tau.Providers.Shared.SSE

  @doc """
  Returns a `Stream.resource/3` of `Tau.Provider.Event` structs.

  `decoder` is `(sse_event, partial_state) -> {events, partial_state}`.
  """
  @spec run(Finch.Request.t(), (map(), term() -> {[Event.t()], term()})) :: Enumerable.t()
  def run(request, decoder, init_partial \\ %{}) do
    Stream.resource(
      fn -> open(request, init_partial) end,
      fn s -> next(s, decoder) end,
      &cleanup/1
    )
  end

  defp open(request, init_partial) do
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

  defp handle({:data, chunk}, %{status: st} = s, decoder) when st in 200..299 do
    {sse_events, sse} = SSE.feed(s.sse, chunk)

    {events, partial} =
      Enum.reduce(sse_events, {[], s.partial}, fn ev, {acc, p} ->
        {evs, p2} = decoder.(ev, p)
        {acc ++ evs, p2}
      end)

    %{s | sse: sse, partial: partial, pending: s.pending ++ events}
  end

  defp handle({:data, _chunk}, s, _decoder), do: s

  defp handle(:done, s, _), do: s

  defp handle(:end, s, _), do: %{s | finished?: true}

  defp handle({:error, reason}, s, _) do
    %{s | pending: s.pending ++ [%Event.Error{reason: reason, retryable?: true}], finished?: true}
  end
end
