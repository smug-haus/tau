defmodule Tau.Providers.Shared.SSETest do
  use ExUnit.Case, async: true

  alias Tau.Providers.Shared.SSE

  describe "feed/2 — basic events" do
    test "single complete event" do
      {events, _} = SSE.feed(SSE.new(), "event: foo\ndata: bar\n\n")
      assert events == [%{event: "foo", data: "bar", id: nil, retry: nil}]
    end

    test "multi-line data is joined with newlines" do
      {events, _} = SSE.feed(SSE.new(), "data: line1\ndata: line2\n\n")
      assert [%{data: "line1\nline2"}] = events
    end

    test "comments are ignored" do
      {events, _} = SSE.feed(SSE.new(), ": ignored\ndata: ok\n\n")
      assert [%{data: "ok"}] = events
    end

    test "id and retry parsed" do
      {events, _} = SSE.feed(SSE.new(), "id: 42\nretry: 3000\ndata: x\n\n")
      assert [%{id: "42", retry: 3000, data: "x"}] = events
    end
  end

  describe "feed/2 — incremental parsing" do
    test "splits across feeds" do
      buf = SSE.new()
      {a, buf} = SSE.feed(buf, "data: hel")
      assert a == []
      {b, buf} = SSE.feed(buf, "lo\n\n")
      assert [%{data: "hello"}] = b
      {c, _} = SSE.feed(buf, "data: world\n\n")
      assert [%{data: "world"}] = c
    end

    test "multiple events in one feed" do
      data = "data: a\n\ndata: b\n\ndata: c\n\n"
      {events, _} = SSE.feed(SSE.new(), data)
      assert ["a", "b", "c"] == Enum.map(events, & &1.data)
    end

    test "CRLF line endings work" do
      {events, _} = SSE.feed(SSE.new(), "data: ok\r\n\r\n")
      assert [%{data: "ok"}] = events
    end
  end
end
