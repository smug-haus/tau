defmodule Tau.Providers.Shared.ContentTransform do
  @moduledoc """
  Pure cross-provider content transform for transcript replay.

  When the session FSM falls back from one provider to another
  (ADR-0012), some content blocks don't survive the hop:

    * `:thinking` blocks carry an opaque, provider-specific
      `signature` — Anthropic's signed reasoning hashes do not
      verify on OpenAI / Gemini / Bedrock. We strip them
      unconditionally on any cross-provider transform; the
      destination model gets the visible text only via the
      surrounding text blocks.
    * `:image` blocks require `capabilities().vision == true`
      on the destination. When the destination is text-only we
      downgrade each image to a textual placeholder
      `"[image: <media_type>, <bytes> bytes]"` so the model still
      sees that *something* was there at that point in the
      conversation.
    * `cache_control` keys (Anthropic prompt caching) only mean
      anything to a destination with
      `capabilities().prompt_caching == true`. Otherwise they're
      noise that some providers reject; we drop them.

  Tool-call ids go through `Tau.Providers.Shared.IdSanitizer.sanitize/2`
  to satisfy the destination provider's id constraint.

  This module is **pure**: same input always yields the same
  output, no process state, no IO, no side effects. The session
  FSM calls it inline (ADR-0008 only forbids *user-supplied* sync
  work in the FSM; pure helpers are fine).
  """

  alias Tau.Message.{Assistant, ToolResult, User}
  alias Tau.Providers.Shared.IdSanitizer

  @doc """
  Transform a list of messages so the destination provider can
  consume them.

  When `from_provider == to_provider` the only work done is
  id-sanitization (which is itself a no-op when ids are already
  compliant), so the function is safe to call unconditionally.
  """
  @spec transform([Tau.Message.t()], module(), module()) :: [Tau.Message.t()]
  def transform(messages, from_provider, to_provider)
      when is_list(messages) and is_atom(from_provider) and is_atom(to_provider) do
    caps = capabilities_of(to_provider)

    messages
    |> Enum.map(&transform_message(&1, caps))
    |> IdSanitizer.sanitize(to_provider)
  end

  # --- per-message dispatch -------------------------------------------------

  defp transform_message(%Assistant{content: content} = msg, caps) when is_list(content) do
    %{msg | content: transform_blocks(content, caps)}
  end

  defp transform_message(%User{content: content} = msg, caps) when is_list(content) do
    %{msg | content: transform_blocks(content, caps)}
  end

  defp transform_message(%User{content: text} = msg, _caps) when is_binary(text), do: msg

  defp transform_message(%ToolResult{content: content} = msg, caps) when is_list(content) do
    %{msg | content: transform_blocks(content, caps)}
  end

  defp transform_message(%ToolResult{} = msg, _caps), do: msg

  defp transform_message(other, _caps), do: other

  # --- per-block dispatch ---------------------------------------------------

  defp transform_blocks(blocks, caps) do
    blocks
    |> Enum.flat_map(&transform_block(&1, caps))
    |> Enum.map(&drop_cache_control(&1, caps))
  end

  # Thinking blocks never survive a cross-provider transform.
  defp transform_block(%{type: :thinking}, _caps), do: []

  # Image blocks survive only when the destination is vision-capable.
  defp transform_block(%{type: :image} = b, %{vision: true}), do: [b]

  defp transform_block(%{type: :image, data: data, media_type: mt}, _caps) do
    bytes = if is_binary(data), do: byte_size(data), else: 0
    [%{type: :text, text: "[image: #{mt}, #{bytes} bytes]"}]
  end

  defp transform_block(block, _caps), do: [block]

  # `cache_control` is Anthropic-shaped; drop it for non-caching
  # destinations regardless of which kind of block it's attached to.
  defp drop_cache_control(block, %{prompt_caching: true}), do: block

  defp drop_cache_control(block, _caps) when is_map(block) do
    block
    |> Map.delete(:cache_control)
    |> Map.delete("cache_control")
  end

  defp drop_cache_control(block, _caps), do: block

  # --- capability lookup ----------------------------------------------------

  # Provider modules implement `capabilities/0` (Tau.Provider behaviour).
  # If the module isn't loaded or doesn't implement it (e.g. a test
  # double), default to the most-conservative shape so the transform
  # is correct-by-default.
  defp capabilities_of(provider) when is_atom(provider) do
    Code.ensure_loaded(provider)

    if function_exported?(provider, :capabilities, 0) do
      provider.capabilities()
    else
      %{
        thinking: false,
        tools: false,
        vision: false,
        prompt_caching: false,
        parallel_tools: false
      }
    end
  end
end
