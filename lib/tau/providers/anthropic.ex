defmodule Tau.Providers.Anthropic do
  @moduledoc """
  Anthropic Messages API client.

  Streams `POST /v1/messages?stream=true` (SSE), parses content-block events,
  and yields normalised `Tau.Provider.Event` structs.

  ## Configuration

  Auth precedence (per call → settings → app env → process env):

      :api_key in opts
      Application.get_env(:tau, Tau.Providers.Anthropic)[:api_key]
      System.get_env("ANTHROPIC_API_KEY")

  ## Streaming

  The returned `Stream.resource/3` opens a Finch streaming request and parses
  SSE events incrementally. Cancellation is handled by the Stream halting:
  when the consumer stops iterating, Finch's connection is released.

  ## Notes

  This module is **stateless** — there is no GenServer here. Concurrent
  streams share the `Tau.Providers.Finch` pool. Errors arrive in-stream as
  `%Tau.Provider.Event.Error{}`; only invalid configuration (missing API
  key) returns `{:error, _}` synchronously.
  """

  @behaviour Tau.Provider

  alias Tau.Message.{Assistant, ToolResult, User}
  alias Tau.Provider.Event
  alias Tau.Providers.Shared.SSE

  @api_url "https://api.anthropic.com"
  @api_version "2023-06-01"
  @beta_headers "prompt-caching-2024-07-31,extended-cache-ttl-2025-04-11"
  @default_model "claude-opus-4-7"
  @default_max_tokens 8192

  @impl Tau.Provider
  def default_model, do: @default_model

  @impl Tau.Provider
  def capabilities do
    %{
      thinking: true,
      tools: true,
      vision: true,
      prompt_caching: true,
      parallel_tools: true
    }
  end

  @impl Tau.Provider
  def stream(messages, opts \\ %{}, ctx \\ %{}) do
    case api_key() do
      nil ->
        {:error, :missing_api_key}

      key ->
        {system, user_messages} = split_system(messages)
        body = build_body(system, user_messages, opts)

        request =
          Finch.build(
            :post,
            "#{base_url()}/v1/messages",
            headers(key),
            Jason.encode!(body)
          )

        stream =
          Stream.resource(
            fn -> start_stream(request, ctx) end,
            &next_event/1,
            &cleanup/1
          )

        {:ok, stream}
    end
  end

  # --- Streaming engine -----------------------------------------------------

  defp start_stream(request, ctx) do
    parent = self()
    ref = make_ref()

    # Drive Finch in a linked task; events flow back as messages so we can
    # interleave SSE parsing with cancellation checks in the Stream itself.
    task =
      Task.async(fn ->
        Finch.stream(request, Tau.Providers.Finch, nil, fn
          {:status, status}, _ -> Process.send(parent, {ref, {:status, status}}, [])
          {:headers, headers}, _ -> Process.send(parent, {ref, {:headers, headers}}, [])
          {:data, chunk}, _ -> Process.send(parent, {ref, {:data, chunk}}, [])
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
      ctx: ctx,
      sse: SSE.new(),
      partial: %{},
      pending: [],
      status: nil,
      headers: [],
      finished?: false,
      emitted_start?: false,
      model: nil,
      request_id: nil
    }
  end

  defp next_event(%{pending: [event | rest]} = state) do
    {[event], %{state | pending: rest}}
  end

  defp next_event(%{finished?: true}) do
    {:halt, :done}
  end

  defp next_event(state) do
    receive do
      {ref, msg} when ref == state.ref ->
        handle_msg(msg, state) |> emit_or_continue()
    after
      60_000 ->
        {[%Event.Error{reason: :timeout, retryable?: true}], %{state | finished?: true}}
    end
  end

  defp emit_or_continue(%{pending: [], finished?: false} = state), do: next_event(state)
  defp emit_or_continue(state), do: next_event(state)

  defp cleanup(:done), do: :ok

  defp cleanup(state) do
    if state.task && Process.alive?(state.task.pid) do
      Task.shutdown(state.task, :brutal_kill)
    end

    :ok
  end

  defp handle_msg({:status, status}, state) when status in 200..299 do
    %{state | status: status}
  end

  defp handle_msg({:status, status}, state) do
    err = %Event.Error{
      reason: {:http_status, status},
      retryable?: status in [408, 409, 429, 500, 502, 503, 504]
    }

    %{state | status: status, pending: state.pending ++ [err], finished?: true}
  end

  defp handle_msg({:headers, headers}, state) do
    request_id =
      Enum.find_value(headers, fn
        {"request-id", v} -> v
        {"x-request-id", v} -> v
        _ -> nil
      end)

    %{state | headers: headers, request_id: request_id}
  end

  defp handle_msg({:data, chunk}, %{status: s} = state) when s in 200..299 do
    {sse_events, sse} = SSE.feed(state.sse, chunk)
    {events, partial, model} = decode_events(sse_events, state.partial, state.model)

    pending =
      if not state.emitted_start? and model do
        [%Event.Start{request_id: state.request_id || "anth_unknown", model: model} | events]
      else
        events
      end

    %{
      state
      | sse: sse,
        partial: partial,
        model: model,
        pending: state.pending ++ pending,
        emitted_start?: state.emitted_start? || not is_nil(model)
    }
  end

  defp handle_msg({:data, chunk}, state) do
    # Non-2xx body — append to error accumulator (kept in partial[:error_body])
    body = Map.get(state.partial, :error_body, "") <> chunk
    %{state | partial: Map.put(state.partial, :error_body, body)}
  end

  defp handle_msg(:done, state), do: state

  defp handle_msg(:end, state), do: %{state | finished?: true}

  defp handle_msg({:error, reason}, state) do
    err = %Event.Error{reason: reason, retryable?: true}
    %{state | pending: state.pending ++ [err], finished?: true}
  end

  # --- SSE event decoding ---------------------------------------------------

  defp decode_events(sse_events, partial, model) do
    Enum.reduce(sse_events, {[], partial, model}, fn evt, {acc, p, m} ->
      case decode_one(evt, p, m) do
        {events, new_p, new_m} -> {acc ++ events, new_p, new_m}
        :skip -> {acc, p, m}
      end
    end)
  end

  defp decode_one(%{event: nil, data: ""}, _p, _m), do: :skip

  defp decode_one(%{data: data} = evt, partial, model) do
    case Jason.decode(data) do
      {:ok, json} -> dispatch(evt[:event] || json["type"], json, partial, model)
      {:error, _} -> :skip
    end
  end

  defp dispatch("message_start", %{"message" => msg}, partial, _model) do
    {[], Map.put(partial, :usage, msg["usage"] || %{}), msg["model"]}
  end

  defp dispatch("content_block_start", %{"index" => idx, "content_block" => cb}, partial, model) do
    case cb["type"] do
      "text" ->
        block_id = "anth_text_#{idx}"

        {[%Event.TextStart{block_id: block_id}],
         Map.put(partial, idx, %{kind: :text, id: block_id}), model}

      "thinking" ->
        block_id = "anth_think_#{idx}"

        {[%Event.ThinkingStart{block_id: block_id}],
         Map.put(partial, idx, %{kind: :thinking, id: block_id}), model}

      "tool_use" ->
        tool_id = cb["id"]
        name = cb["name"]

        {[%Event.ToolCallStart{tool_call_id: tool_id, name: name}],
         Map.put(partial, idx, %{kind: :tool_use, id: tool_id, name: name, args: ""}), model}

      _ ->
        :skip
    end
  end

  defp dispatch("content_block_delta", %{"index" => idx, "delta" => d}, partial, model) do
    case Map.get(partial, idx) do
      %{kind: :text, id: id} ->
        {[%Event.TextDelta{block_id: id, text: d["text"] || ""}], partial, model}

      %{kind: :thinking, id: id} ->
        text = d["thinking"] || d["text"] || ""
        {[%Event.ThinkingDelta{block_id: id, text: text}], partial, model}

      %{kind: :tool_use, id: id} = tu ->
        frag = d["partial_json"] || ""

        {[%Event.ToolCallDelta{tool_call_id: id, json_fragment: frag}],
         Map.put(partial, idx, %{tu | args: tu.args <> frag}), model}

      _ ->
        :skip
    end
  end

  defp dispatch("content_block_stop", %{"index" => idx}, partial, model) do
    case Map.get(partial, idx) do
      %{kind: :text, id: id} ->
        {[%Event.TextEnd{block_id: id}], Map.delete(partial, idx), model}

      %{kind: :thinking, id: id} ->
        {[%Event.ThinkingEnd{block_id: id, signature: nil}], Map.delete(partial, idx), model}

      %{kind: :tool_use, id: id, args: args} ->
        params =
          case Jason.decode(args) do
            {:ok, m} when is_map(m) -> m
            _ -> %{}
          end

        {[%Event.ToolCallEnd{tool_call_id: id, params: params}], Map.delete(partial, idx), model}

      _ ->
        :skip
    end
  end

  defp dispatch("message_delta", %{"delta" => d, "usage" => u}, partial, model) do
    stop_reason = normalise_stop(d["stop_reason"])
    usage = merge_usage(Map.get(partial, :usage, %{}), u)
    {[%Event.Done{stop_reason: stop_reason, usage: usage}], partial, model}
  end

  defp dispatch("message_stop", _data, partial, model), do: {[], partial, model}
  defp dispatch("ping", _data, partial, model), do: {[], partial, model}

  defp dispatch("error", %{"error" => err}, partial, model) do
    reason = {err["type"] || "error", err["message"] || ""}

    retryable? = err["type"] in ["overloaded_error", "api_error", "rate_limit_error"]
    {[%Event.Error{reason: reason, retryable?: retryable?}], partial, model}
  end

  defp dispatch(_unknown, _data, partial, model), do: {[], partial, model}

  defp normalise_stop("end_turn"), do: :stop
  defp normalise_stop("max_tokens"), do: :length
  defp normalise_stop("tool_use"), do: :tool_use
  defp normalise_stop("stop_sequence"), do: :stop_sequence
  defp normalise_stop(nil), do: :stop
  defp normalise_stop(_), do: :stop

  defp merge_usage(start_u, delta_u) do
    %{
      input_tokens: get_in(start_u, ["input_tokens"]) || 0,
      output_tokens: get_in(delta_u, ["output_tokens"]) || 0,
      cache_creation_input_tokens: get_in(start_u, ["cache_creation_input_tokens"]) || 0,
      cache_read_input_tokens: get_in(start_u, ["cache_read_input_tokens"]) || 0
    }
  end

  # --- Request body construction --------------------------------------------

  defp split_system(messages) do
    {sys, rest} =
      Enum.split_with(messages, fn
        %User{metadata: %{role: :system}} -> true
        _ -> false
      end)

    system_text =
      sys
      |> Enum.map(fn %User{content: c} -> if is_binary(c), do: c, else: "" end)
      |> Enum.join("\n\n")
      |> case do
        "" -> nil
        s -> s
      end

    {system_text, rest}
  end

  defp build_body(system, messages, opts) do
    body = %{
      model: opts[:model] || @default_model,
      max_tokens: opts[:max_tokens] || @default_max_tokens,
      stream: true,
      messages: Enum.map(messages, &to_anthropic/1)
    }

    body
    |> maybe_put(:system, system_field(system, opts))
    |> maybe_put(:temperature, opts[:temperature])
    |> maybe_put(:tools, opts[:tools])
    |> maybe_put(:tool_choice, tool_choice(opts[:tool_choice]))
    |> maybe_put(:thinking, thinking(opts))
    |> maybe_put(:stop_sequences, opts[:stop_sequences])
  end

  defp system_field(_string_system = nil, opts) do
    case opts[:system] do
      nil ->
        nil

      bin when is_binary(bin) ->
        bin

      blocks when is_list(blocks) ->
        blocks
    end
  end

  defp system_field(string, _opts), do: string

  defp tool_choice(nil), do: nil
  defp tool_choice(:auto), do: %{type: "auto"}
  defp tool_choice(:any), do: %{type: "any"}
  defp tool_choice(:none), do: %{type: "none"}
  defp tool_choice({:tool, name}), do: %{type: "tool", name: name}

  defp thinking(opts) do
    case opts[:reasoning] || opts[:thinking_budget] do
      nil ->
        nil

      level when level in [:minimal, :low, :medium, :high, :xhigh] ->
        %{type: "enabled", budget_tokens: budget_for(level)}

      n when is_integer(n) and n > 0 ->
        %{type: "enabled", budget_tokens: n}

      _ ->
        nil
    end
  end

  defp budget_for(:minimal), do: 1024
  defp budget_for(:low), do: 4096
  defp budget_for(:medium), do: 16_384
  defp budget_for(:high), do: 32_768
  defp budget_for(:xhigh), do: 64_000

  defp to_anthropic(%User{content: c}) when is_binary(c), do: %{role: "user", content: c}

  defp to_anthropic(%User{content: blocks}) when is_list(blocks),
    do: %{role: "user", content: Enum.map(blocks, &block_out/1)}

  defp to_anthropic(%Assistant{content: blocks}),
    do: %{role: "assistant", content: Enum.map(blocks, &block_out/1)}

  defp to_anthropic(%ToolResult{
         tool_call_id: id,
         content: c,
         is_error: e
       }) do
    %{
      role: "user",
      content: [
        %{
          type: "tool_result",
          tool_use_id: id,
          content: tool_result_content(c),
          is_error: e
        }
      ]
    }
  end

  defp tool_result_content(c) when is_binary(c), do: c
  defp tool_result_content(blocks) when is_list(blocks), do: Enum.map(blocks, &block_out/1)

  defp block_out(%{type: :text, text: t}), do: %{type: "text", text: t}

  defp block_out(%{type: :image, data: d, media_type: mt}),
    do: %{type: "image", source: %{type: "base64", media_type: mt, data: Base.encode64(d)}}

  defp block_out(%{type: :thinking, text: t, signature: sig}) do
    base = %{type: "thinking", thinking: t}
    if sig, do: Map.put(base, :signature, sig), else: base
  end

  defp block_out(%{type: :tool_call, id: id, name: name, arguments: args}),
    do: %{type: "tool_use", id: id, name: name, input: args || %{}}

  defp block_out(other), do: other

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)

  # --- Auth & transport plumbing -------------------------------------------

  defp api_key do
    Application.get_env(:tau, __MODULE__, [])[:api_key] ||
      System.get_env("ANTHROPIC_API_KEY")
  end

  defp base_url do
    Application.get_env(:tau, __MODULE__, [])[:base_url] ||
      System.get_env("ANTHROPIC_BASE_URL") ||
      @api_url
  end

  defp headers(key) do
    [
      {"x-api-key", key},
      {"anthropic-version", @api_version},
      {"anthropic-beta", @beta_headers},
      {"content-type", "application/json"},
      {"accept", "text/event-stream"}
    ]
  end
end
