defmodule Tau.Providers.Shared.ToolSpecTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Tau.Providers.Shared.ToolSpec

  @sample %{
    name: "Read",
    description: "Read a file",
    parameters: %{
      "type" => "object",
      "properties" => %{"path" => %{"type" => "string"}},
      "required" => ["path"]
    }
  }

  describe "adapt/2 — empty inputs" do
    test "nil passes through as nil for every provider" do
      for provider <- providers() do
        assert ToolSpec.adapt(nil, provider) == nil
      end
    end

    test "empty list passes through as empty list" do
      for provider <- providers() do
        assert ToolSpec.adapt([], provider) == []
      end
    end
  end

  describe "adapt/2 — Anthropic shape" do
    test "produces %{name, description, input_schema}" do
      assert [tool] = ToolSpec.adapt([@sample], Tau.Providers.Anthropic)
      assert tool.name == "Read"
      assert tool.description == "Read a file"
      assert tool.input_schema == @sample.parameters
      refute Map.has_key?(tool, :parameters)
      refute Map.has_key?(tool, :function)
      refute Map.has_key?(tool, :type)
    end
  end

  describe "adapt/2 — OpenAI Chat shape" do
    test "wraps in %{type: \"function\", function: %{name, description, parameters}}" do
      assert [tool] = ToolSpec.adapt([@sample], Tau.Providers.OpenAI.Chat)
      assert tool.type == "function"
      assert tool.function.name == "Read"
      assert tool.function.description == "Read a file"
      assert tool.function.parameters == @sample.parameters
      refute Map.has_key?(tool, :input_schema)
      refute Map.has_key?(tool, :name)
    end
  end

  describe "adapt/2 — OpenAI Responses shape" do
    test "flat %{type: \"function\", name, description, parameters}" do
      assert [tool] = ToolSpec.adapt([@sample], Tau.Providers.OpenAI.Responses)
      assert tool.type == "function"
      assert tool.name == "Read"
      assert tool.description == "Read a file"
      assert tool.parameters == @sample.parameters
      refute Map.has_key?(tool, :function)
      refute Map.has_key?(tool, :input_schema)
    end
  end

  describe "adapt/2 — Gemini shape" do
    test "produces %{name, description, parameters} after subset down-shift" do
      assert [tool] = ToolSpec.adapt([@sample], Tau.Providers.Gemini)
      assert tool.name == "Read"
      assert tool.description == "Read a file"
      # Plain schema with no oneOf/additionalProperties is unchanged.
      assert tool.parameters == @sample.parameters
      refute Map.has_key?(tool, :input_schema)
      refute Map.has_key?(tool, :type)
      refute Map.has_key?(tool, :function)
    end
  end

  describe "adapt/2 — Bedrock shape" do
    test "Anthropic-on-Bedrock uses Anthropic shape" do
      assert [tool] = ToolSpec.adapt([@sample], Tau.Providers.Bedrock)
      assert tool.name == "Read"
      assert tool.description == "Read a file"
      assert tool.input_schema == @sample.parameters
    end
  end

  describe "adapt/2 — Tau.Tool module input" do
    test "extracts canonical fields via behaviour callbacks" do
      [tool] = ToolSpec.adapt([Tau.Tools.Builtin.Read], Tau.Providers.Anthropic)
      assert tool.name == Tau.Tools.Builtin.Read.name()
      assert tool.description == Tau.Tools.Builtin.Read.description()
      assert tool.input_schema == Tau.Tools.Builtin.Read.parameters()
    end
  end

  describe "adapt/2 — string-keyed map input" do
    test "accepts string keys interchangeably with atom keys" do
      string_keyed = %{
        "name" => "Edit",
        "description" => "edit a file",
        "parameters" => %{"type" => "object"}
      }

      [tool] = ToolSpec.adapt([string_keyed], Tau.Providers.Anthropic)
      assert tool.name == "Edit"
      assert tool.description == "edit a file"
      assert tool.input_schema == %{"type" => "object"}
    end
  end

  # --- property tests -------------------------------------------------------

  describe "properties" do
    @describetag :property

    property "adapt/2 is total for every supported provider" do
      check all(
              tools <- StreamData.list_of(tool_map_gen(), max_length: 4),
              provider <- StreamData.member_of(providers())
            ) do
        result = ToolSpec.adapt(tools, provider)
        assert is_list(result)
        assert length(result) == length(tools)
      end
    end

    property "Anthropic adapt is idempotent on its own output (atom-key fields)" do
      check all(tools <- StreamData.list_of(tool_map_gen(), min_length: 1, max_length: 3)) do
        first = ToolSpec.adapt(tools, Tau.Providers.Anthropic)

        # Re-feed: each output map already has :name/:description/:parameters
        # if we rename :input_schema → :parameters. This proves the helper
        # round-trips a normalised map without losing or mutating fields.
        reshaped =
          Enum.map(first, fn %{name: n, description: d, input_schema: s} ->
            %{name: n, description: d, parameters: s}
          end)

        again = ToolSpec.adapt(reshaped, Tau.Providers.Anthropic)
        assert first == again
      end
    end
  end

  # --- helpers --------------------------------------------------------------

  defp providers do
    [
      Tau.Providers.Anthropic,
      Tau.Providers.OpenAI.Chat,
      Tau.Providers.OpenAI.Responses,
      Tau.Providers.Gemini,
      Tau.Providers.Bedrock
    ]
  end

  defp tool_map_gen do
    StreamData.fixed_map(%{
      name: StreamData.string(:alphanumeric, min_length: 1, max_length: 16),
      description: StreamData.string(:alphanumeric, max_length: 32),
      parameters: schema_gen()
    })
  end

  defp schema_gen do
    StreamData.fixed_map(%{
      "type" => StreamData.constant("object"),
      "properties" => properties_gen()
    })
  end

  defp properties_gen do
    StreamData.map_of(
      StreamData.string(:alphanumeric, min_length: 1, max_length: 8),
      StreamData.fixed_map(%{
        "type" =>
          StreamData.member_of(["string", "integer", "number", "boolean", "array", "object"])
      }),
      max_length: 4
    )
  end
end
