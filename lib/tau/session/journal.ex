defmodule Tau.Session.Journal do
  @moduledoc """
  Pure persistence and serialisation helpers for `Tau.Session`.

  Converts between in-memory `Tau.Message` structs and the JSONL wire
  format written by `Tau.Persistence`. Also provides event-replay helpers
  used on fork and resume to reconstruct the message history from persisted
  events.

  All functions are pure (no process, no ETS, no side effects) except
  `persist/3`, which calls the persistence backend held on the session data.

  ## Round-trip contract

  For any valid message `m`:
  `m == event_to_message(message_to_event_data(m) |> wrap_as_event(kind))`
  """

  alias Tau.Message.{Assistant, ToolResult, User}

  @doc """
  Append an event to the session's persistence backend and return updated data.

  Generates a fresh event id and appends the event atomically. On persistence
  error the data is returned unchanged (fire-and-forget contract — a write
  failure is logged at the persistence layer, not surfaced to the FSM).
  """
  @spec persist(Tau.Session.Data.t(), String.t(), map()) :: Tau.Session.Data.t()
  def persist(data, kind, payload) do
    event = %{
      "id" => generate_event_id(),
      "parent_id" => nil,
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "kind" => kind,
      "data" => payload
    }

    case data.persistence.append(data.persist_handle, event) do
      {:ok, h} -> %{data | persist_handle: h}
      {:error, _} -> data
    end
  end

  @doc """
  Serialise a message to the JSONL wire format used by `persist/3`.

  Returns a map suitable for embedding as the `"data"` field of a persisted
  event.
  """
  @spec message_to_data(Tau.Message.t()) :: map()
  def message_to_data(%User{} = m), do: %{role: "user", content: serialize_content(m.content)}

  def message_to_data(%Assistant{} = m) do
    %{
      role: "assistant",
      content: Enum.map(m.content, &serialize_block/1),
      stop_reason: m.stop_reason && to_string(m.stop_reason),
      usage: m.usage,
      model: m.model
    }
  end

  def message_to_data(%ToolResult{} = m), do: tool_result_to_data(m)

  @doc """
  Serialise a `%ToolResult{}` to the JSONL wire format.
  """
  @spec tool_result_to_data(ToolResult.t()) :: map()
  def tool_result_to_data(%ToolResult{} = m) do
    %{
      role: "tool_result",
      tool_call_id: m.tool_call_id,
      tool_name: m.tool_name,
      content: serialize_content(m.content),
      is_error: m.is_error,
      details: m.details
    }
  end

  @doc """
  Deserialise a list of raw persisted events into `Tau.Message` structs.

  Used on `Tau.fork/2` and `Tau.resume/1` to rebuild the in-memory history.
  Events with unknown or undeserializable kinds are silently dropped.
  """
  @spec events_to_messages([map()]) :: [Tau.Message.t()]
  def events_to_messages(events) do
    events
    |> Enum.map(&event_to_message/1)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Deserialise one raw persisted event to a `Tau.Message` struct, or `nil`
  if the kind is not deserializable (e.g. telemetry-only events).
  """
  @spec event_to_message(map()) :: Tau.Message.t() | nil
  def event_to_message(%{"kind" => "user_message", "data" => d}) do
    User.new(d["content"])
  end

  def event_to_message(%{"kind" => "assistant_message", "data" => d}) do
    Assistant.new(
      content: deserialize_blocks(d["content"]),
      stop_reason: stop_reason_atom(d["stop_reason"]),
      usage: d["usage"] || %{},
      model: d["model"]
    )
  end

  def event_to_message(%{"kind" => "tool_result", "data" => d}) do
    ToolResult.new(
      tool_call_id: d["tool_call_id"],
      tool_name: d["tool_name"],
      content: d["content"],
      details: d["details"] || %{},
      is_error: d["is_error"] || false
    )
  end

  def event_to_message(%{"kind" => "compaction", "data" => %{"summary" => s}})
      when is_binary(s) and s != "" do
    User.new(s, metadata: %{role: :compaction_summary})
  end

  def event_to_message(_), do: nil

  @doc """
  Return the formatted compaction summary as it should be persisted.

  Wraps the inner summary text in `<conversation_summary>` tags so the
  "compaction" JSONL event can reconstruct the synthetic user message verbatim
  on fork/resume.
  """
  @spec format_summary_for_persist(String.t() | nil) :: String.t() | nil
  def format_summary_for_persist(nil), do: nil

  def format_summary_for_persist(summary_text) when is_binary(summary_text) do
    "<conversation_summary>\n#{summary_text}\n</conversation_summary>"
  end

  @doc """
  Extract the most recently swapped model from a preload event list.

  D-041: folds the last `model_swap` event from a preload so resume and fork
  both converge on the most recently swapped model. Returns `nil` when no swap
  is recorded.
  """
  @spec model_from_preload([map()]) :: String.t() | nil
  def model_from_preload(preload) when is_list(preload) do
    Enum.reduce(preload, nil, fn
      %{"kind" => "model_swap", "data" => %{"to" => to}}, _acc when is_binary(to) -> to
      _, acc -> acc
    end)
  end

  def model_from_preload(_), do: nil

  # --- Private serialisation helpers ----------------------------------------

  defp serialize_content(s) when is_binary(s), do: s
  defp serialize_content(blocks) when is_list(blocks), do: Enum.map(blocks, &serialize_block/1)

  defp serialize_block(%{type: :text, text: t}), do: %{"type" => "text", "text" => t}

  defp serialize_block(%{type: :image, data: d, media_type: mt}) when is_binary(d) do
    %{"type" => "image", "media_type" => mt, "data_b64" => Base.encode64(d)}
  end

  defp serialize_block(%{type: :tool_call} = b),
    do: %{"type" => "tool_call", "id" => b.id, "name" => b.name, "arguments" => b.arguments}

  defp serialize_block(%{type: :thinking, text: t, signature: s}),
    do: %{"type" => "thinking", "text" => t, "signature" => s}

  defp serialize_block(other), do: other

  defp deserialize_blocks(blocks) when is_list(blocks),
    do: Enum.map(blocks, &deserialize_block/1)

  defp deserialize_blocks(other), do: other

  defp deserialize_block(%{"type" => "text", "text" => t}), do: %{type: :text, text: t}

  defp deserialize_block(%{"type" => "tool_call", "id" => id, "name" => n, "arguments" => a}),
    do: %{type: :tool_call, id: id, name: n, arguments: a}

  defp deserialize_block(%{"type" => "thinking", "text" => t} = b),
    do: %{type: :thinking, text: t, signature: b["signature"]}

  defp deserialize_block(other), do: other

  defp stop_reason_atom(nil), do: nil
  defp stop_reason_atom(s) when is_binary(s), do: String.to_atom(s)
  defp stop_reason_atom(s), do: s

  defp generate_event_id do
    case Code.ensure_loaded?(Uniq.UUID) do
      true -> apply(Uniq.UUID, :uuid7, [])
      _ -> "evt_" <> (:crypto.strong_rand_bytes(10) |> Base.url_encode64(padding: false))
    end
  end
end
