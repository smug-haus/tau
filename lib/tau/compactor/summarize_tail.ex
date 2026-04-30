defmodule Tau.Compactor.SummarizeTail do
  @moduledoc """
  Default compaction strategy.

  `should_compact?/2`: triggers when the running message list exceeds
  `:compaction_threshold_messages` (default 50) or when usage reports
  `input_tokens` over `:compaction_threshold_tokens` (default 120_000).

  `compact/2`: replaces the oldest 60% of messages with a single
  synthetic `Tau.Message.User` carrying a `<conversation summary>` block
  produced by asking the configured provider to summarise them. The most
  recent 40% are preserved verbatim so tool-result pairing isn't broken.

  This is a stateless module — it just constructs messages. The session
  FSM is responsible for swapping context and persisting the
  `compaction` event.
  """

  @behaviour Tau.Compactor

  alias Tau.Message
  alias Tau.Provider.Event

  @impl Tau.Compactor
  def should_compact?([], _usage), do: false

  def should_compact?(messages, usage) do
    msg_count_threshold = Application.get_env(:tau, :compaction_threshold_messages, 50)
    token_threshold = Application.get_env(:tau, :compaction_threshold_tokens, 120_000)

    length(messages) >= msg_count_threshold or
      Map.get(usage, :input_tokens, 0) >= token_threshold
  end

  @impl Tau.Compactor
  def compact(messages, ctx) do
    {pinned, conv} = Enum.split_with(messages, &pinned?/1)

    case conv do
      [] ->
        # Nothing conversational to summarise — emitting an empty
        # <conversation_summary> block would just be noise.
        {:ok, pinned}

      _ ->
        cutoff = max(div(length(conv) * 6, 10), 1)
        {old, recent} = Enum.split(conv, cutoff)

        case summarise(old, ctx) do
          {:ok, summary_text} ->
            synth =
              Message.User.new("<conversation_summary>\n#{summary_text}\n</conversation_summary>")

            {:ok, pinned ++ [synth | recent]}

          {:error, _} = err ->
            err
        end
    end
  end

  defp pinned?(%Message.User{metadata: %{role: :system}}), do: true
  defp pinned?(_), do: false

  defp summarise([], _ctx), do: {:ok, ""}

  defp summarise(old_messages, ctx) do
    provider = Map.get(ctx, :provider, Tau.Provider.default())

    prompt =
      Message.User.new("""
      Summarise the following conversation in 2-3 paragraphs. Focus on what was
      accomplished, what files were changed, and what the next step should be.
      Preserve any commands the user asked to be remembered.

      Conversation:
      #{Enum.map_join(old_messages, "\n", &one_line/1)}
      """)

    case provider.stream([prompt], %{}, %{}) do
      {:ok, stream} ->
        text =
          stream
          |> Enum.reduce("", fn
            %Event.TextDelta{text: t}, acc -> acc <> t
            _, acc -> acc
          end)

        {:ok, text}

      err ->
        err
    end
  end

  defp one_line(%Message.User{content: c}) when is_binary(c), do: "[user] #{c}"
  defp one_line(%Message.User{}), do: "[user] (multi-block)"

  defp one_line(%Message.Assistant{content: blocks}) do
    text =
      Enum.find_value(blocks, "", fn
        %{type: :text, text: t} -> t
        _ -> nil
      end)

    "[assistant] " <> String.slice(text, 0..240)
  end

  defp one_line(%Message.ToolResult{tool_name: n}), do: "[tool_result:#{n}]"
end
