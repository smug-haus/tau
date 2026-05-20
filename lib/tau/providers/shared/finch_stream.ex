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
    * cooperative cancellation (ADR-0017): if `init_partial` carries
      a `:cancel_flag` (a `:counters` ref), the receive loop checks
      the counter at every boundary and exits cleanly with a
      `%Event.Error{reason: :cancelled, retryable?: false}` when the
      flag is non-zero.

  Provider modules supply a `decode/2` that turns parsed events (SSE map
  or raw binary) into `Tau.Provider.Event` structs and an opaque partial
  state.

  ## Rate-limiter feedback

  If `init_partial` carries a `:provider` key (a module that implements
  `Tau.Provider`), the engine fire-and-forgets a
  `Tau.Providers.RateLimiter.record_response/2` call when an HTTP 429 is
  observed (per ADR-0011). Providers that don't want this behaviour
  simply omit `:provider` from their partial state.
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
          {:ok, _} ->
            Process.send(parent, {ref, :end}, [])

          {:error, e} ->
            Process.send(parent, {ref, {:error, e}}, [])

          # Finch.stream/4 also returns the 3-tuple form
          # `{:error, exception, partial_result}` when an error
          # interrupts a stream that had already produced partial
          # output (e.g. Mint connection timeout during a slow
          # first-load against a local Ollama). Without this clause
          # the FSM crashes with CaseClauseError.
          {:error, e, _partial} ->
            Process.send(parent, {ref, {:error, e}}, [])
        end
      end)

    cancel_flag =
      case init_partial do
        %{cancel_flag: r} when not is_nil(r) -> r
        _ -> nil
      end

    %{
      ref: ref,
      task: task,
      mode: mode,
      sse: SSE.new(),
      partial: init_partial,
      pending: [],
      finished?: false,
      status: nil,
      error_body: nil,
      cancel_flag: cancel_flag
    }
  end

  defp next(%{pending: [evt | rest]} = s, _decoder) do
    {[evt], %{s | pending: rest}}
  end

  defp next(%{finished?: true}, _), do: {:halt, :done}

  defp next(s, decoder) do
    # ADR-0017: cooperative cancellation. Check the flag before
    # blocking on the next chunk. The counter is set by
    # `Tau.Session` on a `:cancel` cast; observing it here lets the
    # stream halt within one chunk boundary so the upstream socket
    # is released promptly via `cleanup/1`.
    if cancelled?(s) do
      {[%Event.Error{reason: :cancelled, retryable?: false}], %{s | finished?: true}}
    else
      receive do
        {ref, msg} when ref == s.ref -> handle(msg, s, decoder) |> recur(decoder)
      after
        250 ->
          if cancelled?(s) do
            {[%Event.Error{reason: :cancelled, retryable?: false}], %{s | finished?: true}}
          else
            wait_remainder(s, decoder)
          end
      end
    end
  end

  # If we hit the 250ms cancel-poll window without a cancel and without
  # a chunk message, fall through to the receive that yields a retryable
  # timeout error. We've already burned 250ms; budget the remainder.
  #
  # The per-chunk timeout is 300s. Opus on a deep-deliberation turn can
  # legitimately pause for 60-180s between chunks while it reasons about
  # a complex tool call (real-world: empirically observed during M1
  # coordinator verification, 2026-05-20, issue #307). The prior 60s
  # budget misread that thinking time as transport failure; D-061 retry
  # (#303) then re-issued the same prompt, which incurred the same
  # thinking time, and the session died after exhausting retries.
  # HTTP transport failures still fail fast at the OS / Mint level
  # (RST, connection close, etc.); only the legitimate "silent
  # connection, model is thinking" case is held open longer here.
  defp wait_remainder(s, decoder) do
    receive do
      {ref, msg} when ref == s.ref -> handle(msg, s, decoder) |> recur(decoder)
    after
      299_750 ->
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
    # Don't emit the Error event yet — buffer the body chunks so the
    # rendered error includes Anthropic's structured `error.type` and
    # `error.message`. The Error is finalised on :done / :end below.
    maybe_notify_rate_limiter(s, n)
    %{s | status: n, error_body: ""}
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

  defp handle({:data, chunk}, %{status: n} = s, _decoder)
       when is_integer(n) and n not in 200..299 do
    %{s | error_body: (s.error_body || "") <> chunk}
  end

  defp handle({:data, _chunk}, s, _decoder), do: s

  defp handle(:done, s, _), do: finalise_error_if_pending(s)

  defp handle(:end, s, _), do: %{finalise_error_if_pending(s) | finished?: true}

  defp handle({:error, reason}, s, _) do
    %{s | pending: s.pending ++ [%Event.Error{reason: reason, retryable?: true}], finished?: true}
  end

  defp finalise_error_if_pending(%{status: n, error_body: body} = s)
       when is_integer(n) and n not in 200..299 and is_binary(body) do
    err = %Event.Error{
      reason: build_error_reason(n, body),
      retryable?: n in [408, 429, 500, 502, 503, 504]
    }

    %{s | pending: s.pending ++ [err], error_body: nil}
  end

  defp finalise_error_if_pending(s), do: s

  defp build_error_reason(status, body) do
    case Jason.decode(body) do
      {:ok, %{"error" => %{"type" => type, "message" => msg}}} ->
        {:http_status, status, %{type: type, message: msg}}

      {:ok, %{"type" => type, "message" => msg}} ->
        {:http_status, status, %{type: type, message: msg}}

      _ ->
        # Non-JSON body — surface the first 500 chars verbatim so the
        # user sees rate-limit detail even from a non-Anthropic source.
        {:http_status, status, %{body: String.slice(body, 0, 500)}}
    end
  end

  defp maybe_notify_rate_limiter(%{partial: %{provider: provider}}, status)
       when is_atom(provider) do
    Tau.Providers.RateLimiter.record_response(provider, %{status: status})
  end

  defp maybe_notify_rate_limiter(_, _), do: :ok

  # ADR-0017: returns true iff the cancel-flag counter has been
  # incremented from the FSM. A `nil` flag means the caller opted out
  # of cooperative cancellation (e.g. a third-party provider that
  # didn't thread the ctx key through).
  defp cancelled?(%{cancel_flag: nil}), do: false

  defp cancelled?(%{cancel_flag: ref}) do
    :counters.get(ref, 1) > 0
  end
end
