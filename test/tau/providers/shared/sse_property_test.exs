defmodule Tau.Providers.Shared.SSEPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Tau.Providers.Shared.SSE

  @moduletag :property

  property "splitting a chunk at any boundary yields the same events" do
    check all(
            count <- StreamData.integer(1..6),
            datas <-
              StreamData.list_of(StreamData.string(:alphanumeric, min_length: 1, max_length: 12),
                length: count
              ),
            split_at <- StreamData.integer(1..4)
          ) do
      payload =
        datas
        |> Enum.map_join("\n\n", fn d -> "data: #{d}" end)
        |> Kernel.<>("\n\n")

      {whole_events, _} = SSE.feed(SSE.new(), payload)

      mid = max(min(split_at, byte_size(payload) - 1), 1)
      <<a::binary-size(mid), b::binary>> = payload
      {events_a, buf} = SSE.feed(SSE.new(), a)
      {events_b, _} = SSE.feed(buf, b)

      assert events_a ++ events_b == whole_events
    end
  end

  property "comments and blank lines are skipped" do
    check all(
            comment <- StreamData.string(:alphanumeric, max_length: 16),
            data <- StreamData.string(:alphanumeric, min_length: 1, max_length: 16)
          ) do
      payload = ":#{comment}\n\ndata: #{data}\n\n"
      {events, _} = SSE.feed(SSE.new(), payload)
      assert [%{data: ^data}] = events
    end
  end
end
