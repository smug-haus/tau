defmodule Tau.Tool.ValidatorTest do
  use ExUnit.Case, async: true

  alias Tau.Tool.Validator

  defmodule StrictTool do
    @moduledoc false
    @behaviour Tau.Tool

    alias Tau.Tool.Result

    @impl true
    def name, do: "Strict"
    @impl true
    def description, do: "Strict schema for tests"

    @impl true
    def parameters do
      %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string"},
          "count" => %{"type" => "integer", "minimum" => 1}
        },
        "required" => ["path"],
        "additionalProperties" => false
      }
    end

    @impl true
    def execute(_params, _ctx), do: {:ok, %Result{content: "ok"}}
  end

  defmodule LooseTool do
    @moduledoc false
    @behaviour Tau.Tool

    alias Tau.Tool.Result

    @impl true
    def name, do: "Loose"
    @impl true
    def description, do: "Empty schema"
    @impl true
    def parameters, do: %{}

    @impl true
    def execute(_p, _ctx), do: {:ok, %Result{content: "ok"}}
  end

  test "valid args against a strict schema returns :ok" do
    assert :ok == Validator.validate(StrictTool, %{"path" => "/tmp/x"})
    assert :ok == Validator.validate(StrictTool, %{"path" => "/tmp/x", "count" => 3})
  end

  test "missing a required property returns {:error, _}" do
    assert {:error, errors} = Validator.validate(StrictTool, %{"count" => 3})
    summary = Validator.format_errors(errors)
    assert summary =~ "path" or summary =~ "required"
  end

  test "additionalProperties violation is rejected" do
    assert {:error, errors} = Validator.validate(StrictTool, %{"path" => "/x", "weird" => 1})

    assert Validator.format_errors(errors) =~ "weird" or
             Validator.format_errors(errors) =~ "Schema does not allow additional properties"
  end

  test "value-type / minimum violation is rejected" do
    assert {:error, errors} = Validator.validate(StrictTool, %{"path" => "/x", "count" => 0})
    assert is_list(errors) and errors != []
  end

  test "empty schema accepts any args" do
    assert :ok == Validator.validate(LooseTool, %{"anything" => "goes"})
    assert :ok == Validator.validate(LooseTool, nil)
  end

  test "args nil is treated as %{}" do
    assert {:error, _} = Validator.validate(StrictTool, nil)
  end

  test "format_errors joins multiple errors" do
    errors = [{"is required", "#/path"}, {"must be integer", "#/count"}]
    assert Validator.format_errors(errors) == "#/path: is required; #/count: must be integer"
  end
end
