defmodule Tau.Providers.Shared.OpenAIChatWireTest do
  @moduledoc """
  Regression guard (B1 — `__MODULE__` hazard) for the OpenAIChatWire extraction.

  Key invariant: `build_body/4` called with `Tau.Providers.OpenAI.Chat` as
  `provider_mod` produces `ToolSpec`-shaped tools for that provider, not a
  `FunctionClauseError` from an unknown `OpenAIChatWire` atom.
  """
  use ExUnit.Case, async: true

  alias Tau.Message.{Assistant, ToolResult, User}
  alias Tau.Provider.Event
  alias Tau.Providers.Shared.OpenAIChatWire

  @provider Tau.Providers.OpenAI.Chat
  @default_model "gpt-4o-mini"

  @sample_tool %{
    name: "search",
    description: "Search the web",
    parameters: %{
      "type" => "object",
      "properties" => %{"query" => %{"type" => "string"}},
      "required" => ["query"]
    }
  }

  describe "build_body/4 — tool-bearing request (B1 regression guard)" do
    test "shapes tools for Tau.Providers.OpenAI.Chat, not OpenAIChatWire" do
      messages = [User.new("find elixir")]
      opts = %{tools: [@sample_tool], tool_choice: :auto}

      body = OpenAIChatWire.build_body(messages, opts, @provider, @default_model)

      assert body.stream == true
      assert body.model == @default_model

      # ToolSpec.shape/2 for OpenAI.Chat wraps in %{type: "function", function: %{...}}
      assert [tool] = body.tools
      assert tool.type == "function"
      assert tool.function.name == "search"
      assert tool.function.description == "Search the web"
      assert tool.function.parameters == @sample_tool.parameters
      assert body.tool_choice == "auto"
    end

    test "nil tools omits the :tools key" do
      body = OpenAIChatWire.build_body([User.new("hi")], %{}, @provider, @default_model)
      refute Map.has_key?(body, :tools)
    end

    test "empty tools list passes through as empty list" do
      body = OpenAIChatWire.build_body([User.new("hi")], %{tools: []}, @provider, @default_model)
      assert body.tools == []
    end
  end

  describe "build_body/4 — message serialisation" do
    test "User with binary content becomes %{role: user, content: ...}" do
      body = OpenAIChatWire.build_body([User.new("hello")], %{}, @provider, @default_model)
      assert [%{role: "user", content: "hello"}] = body.messages
    end

    test "ToolResult serialised with role: tool" do
      tr = %ToolResult{
        tool_call_id: "tc1",
        tool_name: "search",
        content: "result text",
        timestamp: DateTime.utc_now()
      }

      body =
        OpenAIChatWire.build_body(
          [User.new("q"), tr],
          %{},
          @provider,
          @default_model
        )

      assert [_, %{role: "tool", tool_call_id: "tc1", content: "result text"}] = body.messages
    end

    test "opts[:model] overrides default" do
      body =
        OpenAIChatWire.build_body([User.new("hi")], %{model: "gpt-4"}, @provider, @default_model)

      assert body.model == "gpt-4"
    end
  end

  describe "headers/1" do
    test "produces authorization, content-type, and accept headers" do
      headers = OpenAIChatWire.headers("sk-test")

      assert {"authorization", "Bearer sk-test"} in headers
      assert {"content-type", "application/json"} in headers
      assert {"accept", "text/event-stream"} in headers
    end
  end

  describe "decode/2 — SSE decoding" do
    test "[DONE] produces Event.Done{stop_reason: :stop}" do
      partial = %{tool_calls: %{}, model: nil, provider: @provider}
      {events, _} = OpenAIChatWire.decode(%{data: "[DONE]"}, partial)
      assert [%Event.Done{stop_reason: :stop}] = events
    end

    test "empty data produces no events" do
      partial = %{tool_calls: %{}, model: nil, provider: @provider}
      {events, _} = OpenAIChatWire.decode(%{data: ""}, partial)
      assert events == []
    end

    test "text delta chunk emits TextStart + TextDelta on first chunk" do
      partial = %{tool_calls: %{}, model: "gpt-4o-mini", provider: @provider}

      chunk =
        Jason.encode!(%{
          "id" => "chatcmpl-1",
          "model" => "gpt-4o-mini",
          "choices" => [
            %{"delta" => %{"content" => "hello"}, "finish_reason" => nil}
          ]
        })

      {events, partial2} = OpenAIChatWire.decode(%{data: chunk}, partial)

      assert Enum.any?(events, &match?(%Event.TextStart{block_id: "text"}, &1))
      assert Enum.any?(events, &match?(%Event.TextDelta{block_id: "text", text: "hello"}, &1))
      assert Map.get(partial2, :text_started?) == true
    end

    test "tool_calls delta emits ToolCallStart + ToolCallDelta" do
      partial = %{tool_calls: %{}, model: "gpt-4o-mini", provider: @provider}

      chunk =
        Jason.encode!(%{
          "id" => "chatcmpl-2",
          "model" => "gpt-4o-mini",
          "choices" => [
            %{
              "delta" => %{
                "tool_calls" => [
                  %{
                    "index" => 0,
                    "id" => "call_abc",
                    "function" => %{"name" => "search", "arguments" => "{\"query\""}
                  }
                ]
              },
              "finish_reason" => nil
            }
          ]
        })

      {events, _partial2} = OpenAIChatWire.decode(%{data: chunk}, partial)

      assert Enum.any?(events, &match?(%Event.ToolCallStart{tool_call_id: "call_abc"}, &1))

      assert Enum.any?(
               events,
               &match?(%Event.ToolCallDelta{tool_call_id: "call_abc"}, &1)
             )
    end
  end

  describe "Assistant message serialisation" do
    test "assistant with tool_calls round-trips through build_body" do
      assistant = %Assistant{
        content: [
          %{type: :text, text: "calling tool"},
          %{type: :tool_call, id: "call_1", name: "search", arguments: %{"query" => "elixir"}}
        ],
        stop_reason: :tool_use,
        timestamp: DateTime.utc_now()
      }

      body =
        OpenAIChatWire.build_body(
          [User.new("hi"), assistant],
          %{},
          @provider,
          @default_model
        )

      [_user_msg, asst_msg] = body.messages
      assert asst_msg.role == "assistant"
      assert [tc] = asst_msg.tool_calls
      assert tc.id == "call_1"
      assert tc.type == "function"
      assert tc.function.name == "search"
    end
  end
end
