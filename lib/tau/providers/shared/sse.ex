defmodule Tau.Providers.Shared.SSE do
  @moduledoc """
  Pure incremental parser for Server-Sent Events.

  Anthropic, OpenAI Responses, OpenAI Chat, and Gemini all stream over SSE
  with the same wire format: lines of `field: value`, blank line terminates
  one event.

  Usage:

      buffer = SSE.new()
      {events, buffer} = SSE.feed(buffer, chunk)

  Each event is `%{event: String.t() | nil, data: String.t(), id: String.t() | nil,
  retry: integer | nil}`. Multi-line `data:` values are joined with newlines per
  the spec.

  This module has zero process state — it's pure folding over a binary
  buffer plus a partially-built event.
  """

  defstruct buffer: "", current: %{}

  @type event :: %{
          event: String.t() | nil,
          data: String.t(),
          id: String.t() | nil,
          retry: integer() | nil
        }

  @type t :: %__MODULE__{buffer: binary(), current: map()}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Feed a chunk of bytes into the parser. Returns `{events, new_state}`.
  """
  @spec feed(t(), binary()) :: {[event()], t()}
  def feed(%__MODULE__{buffer: buf, current: cur}, chunk) when is_binary(chunk) do
    parse_lines(buf <> chunk, cur, [])
  end

  defp parse_lines(buf, current, acc) do
    case :binary.split(buf, ["\r\n", "\n"]) do
      [_only] ->
        {Enum.reverse(acc), %__MODULE__{buffer: buf, current: current}}

      [line, rest] ->
        cond do
          line == "" ->
            # Blank line: dispatch the current event if any.
            if map_size(current) == 0 do
              parse_lines(rest, %{}, acc)
            else
              event = finalize(current)
              parse_lines(rest, %{}, [event | acc])
            end

          String.starts_with?(line, ":") ->
            # Comment line — ignore.
            parse_lines(rest, current, acc)

          true ->
            current = parse_field(line, current)
            parse_lines(rest, current, acc)
        end
    end
  end

  defp parse_field(line, current) do
    {field, value} =
      case :binary.split(line, ":") do
        [f, v] -> {f, strip_leading_space(v)}
        [f] -> {f, ""}
      end

    case field do
      "event" -> Map.put(current, :event, value)
      "data" -> Map.update(current, :data, value, &(&1 <> "\n" <> value))
      "id" -> Map.put(current, :id, value)
      "retry" -> Map.put(current, :retry, parse_int(value))
      _ -> current
    end
  end

  defp finalize(current) do
    %{
      event: Map.get(current, :event),
      data: Map.get(current, :data, ""),
      id: Map.get(current, :id),
      retry: Map.get(current, :retry)
    }
  end

  defp strip_leading_space(<<" ", rest::binary>>), do: rest
  defp strip_leading_space(rest), do: rest

  defp parse_int(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> nil
    end
  end
end
