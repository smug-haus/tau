defmodule Tau.Providers.Shared.ToolSpec.GeminiSubsetTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import ExUnit.CaptureLog

  alias Tau.Providers.Shared.ToolSpec.GeminiSubset

  describe "downshift/1" do
    test "nil passes through" do
      assert GeminiSubset.downshift(nil) == nil
    end

    test "schema without oneOf/additionalProperties is unchanged and silent" do
      schema = %{"type" => "object", "properties" => %{"x" => %{"type" => "string"}}}

      log =
        capture_log(fn ->
          assert GeminiSubset.downshift(schema) == schema
        end)

      assert log == ""
    end

    test "strips top-level oneOf and warns" do
      schema = %{
        "type" => "object",
        "oneOf" => [%{"required" => ["a"]}, %{"required" => ["b"]}],
        "properties" => %{"a" => %{"type" => "string"}, "b" => %{"type" => "string"}}
      }

      log =
        capture_log(fn ->
          out = GeminiSubset.downshift(schema)
          refute Map.has_key?(out, "oneOf")
          assert out["type"] == "object"
          assert out["properties"] == schema["properties"]
        end)

      assert log =~ "ToolSpec.GeminiSubset"
    end

    test "strips nested oneOf inside properties" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "x" => %{
            "type" => "object",
            "oneOf" => [%{"required" => ["a"]}, %{"required" => ["b"]}]
          }
        }
      }

      capture_log(fn ->
        out = GeminiSubset.downshift(schema)
        refute Map.has_key?(out["properties"]["x"], "oneOf")
      end)
    end

    test "strips anyOf the same way as oneOf" do
      schema = %{"type" => "object", "anyOf" => [%{}, %{}]}

      capture_log(fn ->
        out = GeminiSubset.downshift(schema)
        refute Map.has_key?(out, "anyOf")
      end)
    end

    test "clamps schema-valued additionalProperties to false and warns" do
      schema = %{
        "type" => "object",
        "additionalProperties" => %{"type" => "string"}
      }

      log =
        capture_log(fn ->
          out = GeminiSubset.downshift(schema)
          assert out["additionalProperties"] == false
        end)

      assert log =~ "ToolSpec.GeminiSubset"
    end

    test "leaves additionalProperties: false untouched" do
      schema = %{"type" => "object", "additionalProperties" => false}

      log =
        capture_log(fn ->
          assert GeminiSubset.downshift(schema) == schema
        end)

      assert log == ""
    end

    test "handles atom keys equivalently" do
      schema = %{type: "object", oneOf: [%{}, %{}]}

      capture_log(fn ->
        out = GeminiSubset.downshift(schema)
        refute Map.has_key?(out, :oneOf)
        assert out[:type] == "object"
      end)
    end
  end

  describe "idempotency" do
    @describetag :property

    property "down-shift twice equals down-shift once" do
      check all(schema <- schema_with_lossy_keywords()) do
        first =
          capture_log(fn -> Process.put({__MODULE__, :first}, GeminiSubset.downshift(schema)) end)

        once = Process.get({__MODULE__, :first})

        twice_log =
          capture_log(fn -> Process.put({__MODULE__, :twice}, GeminiSubset.downshift(once)) end)

        twice = Process.get({__MODULE__, :twice})

        # Second pass over already-clean schema must not warn.
        assert twice_log == ""
        assert once == twice
        _ = first
      end
    end
  end

  defp schema_with_lossy_keywords do
    StreamData.fixed_map(%{
      "type" => StreamData.constant("object"),
      "oneOf" => StreamData.list_of(StreamData.constant(%{}), max_length: 2),
      "additionalProperties" =>
        StreamData.one_of([
          StreamData.constant(false),
          StreamData.fixed_map(%{"type" => StreamData.constant("string")})
        ]),
      "properties" =>
        StreamData.map_of(
          StreamData.string(:alphanumeric, min_length: 1, max_length: 4),
          StreamData.fixed_map(%{"type" => StreamData.constant("string")}),
          max_length: 3
        )
    })
  end
end
