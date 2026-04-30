defmodule Tau.Providers.Shared.IdSanitizer do
  @moduledoc """
  Pure tool-call-id sanitization for cross-provider message replay.

  Different providers have different id constraints:

    * Anthropic — `^[a-zA-Z0-9_-]+$`, max 64 chars
    * OpenAI Chat — `call_<24-char-base32>`, ≤ 40 chars
    * OpenAI Responses — opaque, often > 100 chars with `|` separators
    * Gemini — opaque
    * Bedrock — depends on the underlying model

  When replaying a transcript across providers, the caller must rewrite
  ids to satisfy the *destination* provider's constraints while preserving
  pairing between `tool_use` blocks and their `tool_result` blocks.

  This module is pure: given a list of messages and a provider module, it
  returns a new message list with ids rewritten via a stable hash so the
  same input always produces the same output.
  """

  @anthropic_max 64
  @openai_chat_max 40

  @doc """
  Sanitize ids in a list of messages targeting a particular provider.

  Tool-call ids in `Tau.Message.Assistant.content` (`%{type: :tool_call, id: ...}`)
  and `tool_call_id` fields in `Tau.Message.ToolResult` are rewritten in tandem.
  """
  @spec sanitize([Tau.Message.t()], module()) :: [Tau.Message.t()]
  def sanitize(messages, provider) do
    constraint = constraint_for(provider)
    {messages, _mapping} = Enum.map_reduce(messages, %{}, &remap(&1, &2, constraint))
    messages
  end

  @doc "Sanitize a single id according to a provider constraint."
  @spec sanitize_id(String.t(), module()) :: String.t()
  def sanitize_id(id, provider) do
    constraint = constraint_for(provider)
    do_sanitize(id, constraint)
  end

  defp remap(%Tau.Message.Assistant{content: blocks} = msg, mapping, constraint) do
    {blocks, mapping} =
      Enum.map_reduce(blocks, mapping, fn
        %{type: :tool_call, id: id} = b, m ->
          new_id = Map.get_lazy(m, id, fn -> do_sanitize(id, constraint) end)
          {Map.put(b, :id, new_id), Map.put(m, id, new_id)}

        b, m ->
          {b, m}
      end)

    {%{msg | content: blocks}, mapping}
  end

  defp remap(%Tau.Message.ToolResult{tool_call_id: id} = msg, mapping, constraint) do
    new_id = Map.get_lazy(mapping, id, fn -> do_sanitize(id, constraint) end)
    {%{msg | tool_call_id: new_id}, Map.put(mapping, id, new_id)}
  end

  defp remap(msg, mapping, _constraint), do: {msg, mapping}

  defp constraint_for(Tau.Providers.Anthropic), do: {:re, ~r/^[a-zA-Z0-9_-]+$/, @anthropic_max}
  defp constraint_for(Tau.Providers.OpenAI.Chat), do: {:re, ~r/^[a-zA-Z0-9_-]+$/, @openai_chat_max}
  defp constraint_for(_), do: {:any, nil, 1024}

  defp do_sanitize(id, {:any, _, max_len}) do
    if byte_size(id) <= max_len, do: id, else: short_hash(id, max_len)
  end

  defp do_sanitize(id, {:re, re, max_len}) do
    if Regex.match?(re, id) and byte_size(id) <= max_len do
      id
    else
      short_hash(id, max_len)
    end
  end

  defp short_hash(id, max_len) do
    digest = :crypto.hash(:sha256, id) |> Base.url_encode64(padding: false)
    "tc_" <> binary_part(digest, 0, min(max_len - 3, byte_size(digest)))
  end
end
