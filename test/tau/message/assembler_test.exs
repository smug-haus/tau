defmodule Tau.Message.AssemblerTest do
  use ExUnit.Case, async: true

  alias Tau.Message.Assembler
  alias Tau.Provider.Event

  describe "step/2 — text blocks" do
    test "assembles a single text block from deltas" do
      events = [
        %Event.Start{request_id: "r1", model: "claude-opus-4-7"},
        %Event.TextStart{block_id: "b0"},
        %Event.TextDelta{block_id: "b0", text: "Hello "},
        %Event.TextDelta{block_id: "b0", text: "world"},
        %Event.TextEnd{block_id: "b0"},
        %Event.Done{stop_reason: :stop, usage: %{output_tokens: 2}}
      ]

      msg = run(events) |> Assembler.assistant()

      assert [%{type: :text, text: "Hello world"}] = msg.content
      assert msg.stop_reason == :stop
      assert msg.usage == %{output_tokens: 2}
      assert msg.model == "claude-opus-4-7"
    end

    test "preserves block order across multiple blocks" do
      events = [
        %Event.Start{request_id: "r1", model: "m"},
        %Event.TextStart{block_id: "a"},
        %Event.TextDelta{block_id: "a", text: "A"},
        %Event.TextEnd{block_id: "a"},
        %Event.TextStart{block_id: "b"},
        %Event.TextDelta{block_id: "b", text: "B"},
        %Event.TextEnd{block_id: "b"},
        %Event.Done{stop_reason: :stop}
      ]

      assert [%{text: "A"}, %{text: "B"}] =
               run(events) |> Assembler.assistant() |> Map.fetch!(:content)
    end
  end

  describe "step/2 — tool calls" do
    test "buffers JSON deltas and decodes at ToolCallEnd" do
      events = [
        %Event.Start{request_id: "r1", model: "m"},
        %Event.ToolCallStart{tool_call_id: "tc1", name: "Read"},
        %Event.ToolCallDelta{tool_call_id: "tc1", json_fragment: "{\"path\":"},
        %Event.ToolCallDelta{tool_call_id: "tc1", json_fragment: "\"a.txt\"}"},
        %Event.ToolCallEnd{tool_call_id: "tc1", params: %{"path" => "a.txt"}},
        %Event.Done{stop_reason: :tool_use}
      ]

      [tc] = run(events) |> Assembler.assistant() |> Map.fetch!(:content)
      assert tc.type == :tool_call
      assert tc.id == "tc1"
      assert tc.name == "Read"
      assert tc.arguments == %{"path" => "a.txt"}
    end
  end

  describe "step/2 — error handling" do
    test "Error event produces a finished message with error_message set" do
      events = [
        %Event.Start{request_id: "r1", model: "m"},
        %Event.TextStart{block_id: "x"},
        %Event.TextDelta{block_id: "x", text: "partial"},
        %Event.Error{reason: {:http_status, 503}, retryable?: true}
      ]

      msg = run(events) |> Assembler.assistant()
      assert msg.stop_reason == :error
      assert msg.error_message =~ "503"
      assert [%{type: :text, text: "partial"}] = msg.content
    end
  end

  defp run(events), do: Enum.reduce(events, Assembler.new(), &Assembler.step(&2, &1))
end
