defmodule Tau.Providers.Shared.IdSanitizerTest do
  use ExUnit.Case, async: true

  alias Tau.Message.{Assistant, ToolResult}
  alias Tau.Providers.Shared.IdSanitizer

  describe "sanitize_id/2" do
    test "anthropic-compatible id passes through" do
      assert IdSanitizer.sanitize_id("abc_123-XYZ", Tau.Providers.Anthropic) == "abc_123-XYZ"
    end

    test "anthropic strips disallowed characters" do
      result = IdSanitizer.sanitize_id("call|abc/xyz!", Tau.Providers.Anthropic)
      assert byte_size(result) <= 64
      refute String.contains?(result, "|")
      refute String.contains?(result, "/")
      refute String.contains?(result, "!")
    end

    test "anthropic shortens overlong ids" do
      long_id = String.duplicate("a", 200)
      result = IdSanitizer.sanitize_id(long_id, Tau.Providers.Anthropic)
      assert byte_size(result) <= 64
    end

    test "stable: same input → same output" do
      a = IdSanitizer.sanitize_id("call|with|pipes", Tau.Providers.Anthropic)
      b = IdSanitizer.sanitize_id("call|with|pipes", Tau.Providers.Anthropic)
      assert a == b
    end
  end

  describe "sanitize/2 — message-list invariants" do
    test "tool_call ids and matching tool_call_ids stay paired" do
      original_id = "call|abc"

      messages = [
        %Assistant{
          content: [%{type: :tool_call, id: original_id, name: "Read", arguments: %{}}],
          timestamp: DateTime.utc_now()
        },
        %ToolResult{
          tool_call_id: original_id,
          tool_name: "Read",
          content: "ok",
          timestamp: DateTime.utc_now()
        }
      ]

      [a, tr] = IdSanitizer.sanitize(messages, Tau.Providers.Anthropic)
      [tc] = a.content

      # ids changed (because the original had a |) but they still match each other
      refute tc.id == original_id
      assert tc.id == tr.tool_call_id
    end

    test "non-tool_call blocks are untouched" do
      messages = [
        %Assistant{
          content: [%{type: :text, text: "hello"}],
          timestamp: DateTime.utc_now()
        }
      ]

      [a] = IdSanitizer.sanitize(messages, Tau.Providers.Anthropic)
      assert a.content == [%{type: :text, text: "hello"}]
    end
  end
end
