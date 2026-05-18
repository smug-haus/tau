defmodule Tau.Message.AssemblerTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Tau.Message.Assembler
  alias Tau.Message.Assistant
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

  describe "finalize/3 — source-agnostic terminal fold (D-009)" do
    test "non-empty blocks pass through with stop_reason applied" do
      base = Assistant.new(content: [])
      blocks = [%{type: :text, text: "hello"}]

      msg = Assembler.finalize(base, blocks, stop_reason: :end_turn)

      assert msg.content == blocks
      assert msg.stop_reason == :end_turn
    end

    test "empty blocks + :error + error_message → \"Error: \" <> em block" do
      base = Assistant.new(content: [], stop_reason: :error, error_message: "auth failed")

      msg = Assembler.finalize(base, [])

      assert msg.content == [%{type: :text, text: "Error: auth failed"}]
      assert msg.stop_reason == :error
    end

    test "empty blocks + :error without error_message → source-agnostic fallback text" do
      base = Assistant.new(content: [])

      msg = Assembler.finalize(base, [], stop_reason: :error)

      assert msg.content == [%{type: :text, text: "Error: stream ended with no content"}]
    end

    test "empty blocks + non-error → \"(empty response)\"" do
      base = Assistant.new(content: [])

      msg = Assembler.finalize(base, [], stop_reason: :end_turn)

      assert msg.content == [%{type: :text, text: "(empty response)"}]
    end

    test "base.stop_reason is used when opts[:stop_reason] is absent" do
      base = Assistant.new(content: [], stop_reason: :tool_use)

      msg = Assembler.finalize(base, [%{type: :text, text: "x"}])

      assert msg.stop_reason == :tool_use
    end
  end

  describe "finalize/3 — property" do
    @describetag :property

    property "finalize/3 content is never [] for any blocks list and base" do
      block_gen =
        StreamData.bind(
          StreamData.string(:alphanumeric, min_length: 0, max_length: 16),
          fn t -> StreamData.constant(%{type: :text, text: t}) end
        )

      stop_gen =
        StreamData.member_of([nil, :stop, :end_turn, :error, :aborted, :tool_use])

      check all(
              blocks <- StreamData.list_of(block_gen, min_length: 0, max_length: 5),
              stop <- stop_gen,
              opts_stop <- stop_gen
            ) do
        base = Assistant.new(content: [], stop_reason: stop)
        msg = Assembler.finalize(base, blocks, stop_reason: opts_stop)

        refute msg.content == [], "finalize/3 must never yield empty content"
      end
    end
  end

  defp run(events), do: Enum.reduce(events, Assembler.new(), &Assembler.step(&2, &1))
end
