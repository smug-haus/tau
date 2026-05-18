defmodule Tau.Providers.Shared.OpenAIChatWire do
  @moduledoc """
  Shared wire-level helpers for OpenAI Chat Completions-compatible endpoints.

  Extracted from `Tau.Providers.OpenAI.Chat` so that future providers sharing
  the same `/v1/chat/completions` wire format (Groq, DeepSeek, Mistral, Azure,
  Custom) can reuse the body construction, SSE decoding, and header building
  without duplication.

  ## `__MODULE__` hazard — explicit caller_module parameter

  `Tau.Providers.Shared.ToolSpec.shape/2` dispatches on the exact provider
  module atom (`Tau.Providers.OpenAI.Chat`, `Tau.Providers.Groq`, …). Were
  these helpers to call `ToolSpec.adapt(tools, __MODULE__)`, the atom would
  resolve to this module, which has no `ToolSpec.shape/2` clause, producing a
  `FunctionClauseError` on every tool-bearing request.

  To resolve this cleanly, `build_body/3` accepts the caller's module as an
  explicit `provider_mod` parameter (e.g. `Tau.Providers.OpenAI.Chat`).
  `FinchStream`'s `partial.provider` field is likewise set by the caller;
  this module never references `__MODULE__` for provider-dispatched paths.

  ## Extracted public API

    * `build_body/3` — builds the JSON-serialisable request body map.
    * `decode/2`     — decodes one SSE event into `Tau.Provider.Event` structs.
    * `headers/1`    — builds HTTP request headers given an API key binary.
  """

  alias Tau.Message.{Assistant, ToolResult, User}
  alias Tau.Provider.Event
  alias Tau.Providers.Shared.ToolSpec

  @doc """
  Build the JSON-serialisable request body for a Chat Completions request.

  `provider_mod` MUST be the caller's provider module atom (e.g.
  `Tau.Providers.OpenAI.Chat`) — it is passed to `ToolSpec.adapt/2` so that
  tool shapes are formatted for the correct provider.

  `default_model` is the caller's default model string (e.g. `"gpt-4o-mini"`).
  """
  @spec build_body([Tau.Message.t()], map(), module(), String.t()) :: map()
  def build_body(messages, opts, provider_mod, default_model) do
    body = %{
      model: opts[:model] || default_model,
      stream: true,
      messages: Enum.map(messages, &to_openai/1)
    }

    body
    |> maybe_put(:temperature, opts[:temperature])
    |> maybe_put(:max_tokens, opts[:max_tokens])
    |> maybe_put(:tools, ToolSpec.adapt(opts[:tools], provider_mod))
    |> maybe_put(:tool_choice, openai_tool_choice(opts[:tool_choice]))
  end

  @doc """
  Decode one SSE event (as `%{data: binary()}`) into a list of
  `Tau.Provider.Event` structs and an updated partial accumulator.

  `partial` is an opaque map maintained by `FinchStream`; it carries at
  minimum `%{tool_calls: %{}, model: nil, provider: provider_mod}`.
  """
  @spec decode(%{data: String.t()}, map()) :: {[Event.t()], map()}
  def decode(%{data: "[DONE]"}, partial), do: {[%Event.Done{stop_reason: :stop}], partial}

  def decode(%{data: ""}, partial), do: {[], partial}

  def decode(%{data: data}, partial) do
    case Jason.decode(data) do
      {:ok, json} -> decode_chunk(json, partial)
      _ -> {[], partial}
    end
  end

  @doc """
  Build HTTP request headers for an OpenAI Chat Completions request.

  `api_key` is the bearer token string.
  """
  @spec headers(String.t()) :: [{String.t(), String.t()}]
  def headers(api_key) do
    [
      {"authorization", "Bearer #{api_key}"},
      {"content-type", "application/json"},
      {"accept", "text/event-stream"}
    ]
  end

  # --- SSE chunk decoding ---------------------------------------------------

  defp decode_chunk(%{"choices" => [%{"delta" => delta} = choice | _]} = json, partial) do
    model = json["model"]

    {start_events, partial} =
      if is_nil(partial.model) and not is_nil(model) do
        {[%Event.Start{request_id: json["id"] || "openai_unk", model: model}],
         %{partial | model: model}}
      else
        {[], partial}
      end

    # OpenAI's streaming format has no analogue of `TextStart` — it just
    # emits deltas. The assembler's `update_block/3` silently drops
    # deltas for un-started blocks, so we MUST inject a synthetic
    # `TextStart` before the first non-empty delta. Tracked per-stream
    # via the `:text_started?` flag in `partial`.
    #
    # Thinking models (Qwen3, DeepSeek-R1, others) emit chain-of-thought
    # via the non-standard `delta.reasoning` field on the same
    # OpenAI-compatible endpoint. Decoded into Tau's existing Thinking*
    # events; same start/delta/end synthesis as text since the upstream
    # protocol has no explicit start/end markers.
    {thinking_events, partial} =
      case Map.get(delta, "reasoning") do
        nil ->
          {[], partial}

        "" ->
          {[], partial}

        text ->
          if Map.get(partial, :thinking_started?, false) do
            {[%Event.ThinkingDelta{block_id: "thinking", text: text}], partial}
          else
            {[
               %Event.ThinkingStart{block_id: "thinking"},
               %Event.ThinkingDelta{block_id: "thinking", text: text}
             ], Map.put(partial, :thinking_started?, true)}
          end
      end

    {text_events, partial} =
      case Map.get(delta, "content") do
        nil ->
          {[], partial}

        "" ->
          {[], partial}

        text ->
          # Close any open thinking block before the first content delta;
          # thinking always precedes content in these models.
          close_thinking =
            if Map.get(partial, :thinking_started?, false) and
                 not Map.get(partial, :thinking_closed?, false) do
              [%Event.ThinkingEnd{block_id: "thinking", signature: nil}]
            else
              []
            end

          partial =
            if close_thinking != [],
              do: Map.put(partial, :thinking_closed?, true),
              else: partial

          if Map.get(partial, :text_started?, false) do
            {close_thinking ++ [%Event.TextDelta{block_id: "text", text: text}], partial}
          else
            {close_thinking ++
               [
                 %Event.TextStart{block_id: "text"},
                 %Event.TextDelta{block_id: "text", text: text}
               ], Map.put(partial, :text_started?, true)}
          end
      end

    {tool_events, partial} = decode_tool_calls(Map.get(delta, "tool_calls", []), partial)

    {finish_events, partial} =
      case Map.get(choice, "finish_reason") do
        nil ->
          {[], partial}

        reason ->
          # Close any still-open blocks before Done so the assembler's
          # `build_content/1` sees finalized blocks. Both text and
          # thinking blocks may be open at this point.
          close_thinking =
            if Map.get(partial, :thinking_started?, false) and
                 not Map.get(partial, :thinking_closed?, false),
               do: [%Event.ThinkingEnd{block_id: "thinking", signature: nil}],
               else: []

          close_text =
            if Map.get(partial, :text_started?, false),
              do: [%Event.TextEnd{block_id: "text"}],
              else: []

          done =
            case reason do
              "stop" -> %Event.Done{stop_reason: :stop}
              "length" -> %Event.Done{stop_reason: :length}
              "tool_calls" -> %Event.Done{stop_reason: :tool_use}
              other -> %Event.Done{stop_reason: String.to_atom(other)}
            end

          {close_thinking ++ close_text ++ [done], partial}
      end

    {start_events ++ thinking_events ++ text_events ++ tool_events ++ finish_events, partial}
  end

  defp decode_chunk(_, partial), do: {[], partial}

  defp decode_tool_calls(tcs, partial) when is_list(tcs) do
    Enum.reduce(tcs, {[], partial}, fn tc, {events, p} ->
      idx = tc["index"] || 0
      key = idx
      existing = Map.get(p.tool_calls, key, %{id: nil, name: nil, args: ""})
      id = tc["id"] || existing.id
      func = tc["function"] || %{}
      name = func["name"] || existing.name

      delta_args = func["arguments"] || ""
      args = existing.args <> delta_args

      new_evts =
        cond do
          existing.id == nil and id != nil ->
            [%Event.ToolCallStart{tool_call_id: id, name: name || ""}] ++
              if delta_args == "",
                do: [],
                else: [%Event.ToolCallDelta{tool_call_id: id, json_fragment: delta_args}]

          delta_args != "" ->
            [%Event.ToolCallDelta{tool_call_id: id, json_fragment: delta_args}]

          true ->
            []
        end

      tool_calls = Map.put(p.tool_calls, key, %{id: id, name: name, args: args})
      {events ++ new_evts, %{p | tool_calls: tool_calls}}
    end)
  end

  defp decode_tool_calls(_, partial), do: {[], partial}

  # --- Message serialisation ------------------------------------------------

  defp to_openai(%User{content: c}) when is_binary(c), do: %{role: "user", content: c}

  defp to_openai(%User{content: blocks}) when is_list(blocks) do
    %{role: "user", content: Enum.map(blocks, &block_out/1)}
  end

  defp to_openai(%Assistant{content: blocks}) do
    text =
      Enum.find_value(blocks, fn
        %{type: :text, text: t} -> t
        _ -> nil
      end)

    tcs = Enum.filter(blocks, &match?(%{type: :tool_call}, &1))

    base = %{role: "assistant", content: text}

    if tcs == [] do
      base
    else
      Map.put(base, :tool_calls, Enum.map(tcs, &assistant_tc/1))
    end
  end

  defp to_openai(%ToolResult{tool_call_id: id, content: c}) do
    %{role: "tool", tool_call_id: id, content: render_tr(c)}
  end

  defp render_tr(s) when is_binary(s), do: s

  defp render_tr(blocks) when is_list(blocks) do
    Enum.map_join(blocks, "\n", fn
      %{type: :text, text: t} -> t
      _ -> ""
    end)
  end

  defp assistant_tc(%{type: :tool_call, id: id, name: n, arguments: a}) do
    %{id: id, type: "function", function: %{name: n, arguments: Jason.encode!(a || %{})}}
  end

  defp block_out(%{type: :text, text: t}), do: %{type: "text", text: t}

  defp block_out(%{type: :image, data: d, media_type: mt}),
    do: %{type: "image_url", image_url: %{url: "data:#{mt};base64,#{Base.encode64(d)}"}}

  defp block_out(other), do: other

  # --- Utilities ------------------------------------------------------------

  defp openai_tool_choice(nil), do: nil
  defp openai_tool_choice(:auto), do: "auto"
  defp openai_tool_choice(:none), do: "none"
  defp openai_tool_choice(:any), do: "required"
  defp openai_tool_choice({:tool, name}), do: %{type: "function", function: %{name: name}}

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)
end
