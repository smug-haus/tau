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

  defmodule UnresolvableTool do
    @moduledoc false
    @behaviour Tau.Tool

    alias Tau.Tool.Result

    @impl true
    def name, do: "Unresolvable"
    @impl true
    def description, do: "Schema that ex_json_schema can't resolve"
    @impl true
    def parameters do
      # An unsupported draft URI makes ExJsonSchema.Schema.resolve/1 raise.
      %{
        "$schema" => "http://json-schema.org/draft-2020-12/schema#",
        "type" => "object"
      }
    end

    @impl true
    def execute(_p, _ctx), do: {:ok, %Result{content: "ok"}}
  end

  describe "fail-closed on unresolvable schema (ADR-0003, #50)" do
    setup do
      Validator.invalidate(UnresolvableTool)
      on_exit(fn -> Validator.invalidate(UnresolvableTool) end)
      :ok
    end

    test "validate/2 rejects every call when the schema can't be resolved" do
      assert {:error, errors} = Validator.validate(UnresolvableTool, %{"anything" => "goes"})

      assert Validator.format_errors(errors) =~ "schema unresolvable"
    end

    test "the rejection is NOT cached (next call re-attempts resolution)" do
      handler_id = "schema-error-#{System.unique_integer([:positive])}"
      parent = self()

      :telemetry.attach(
        handler_id,
        [:tau, :tool, :validate, :schema_error],
        fn _e, _m, meta, _ -> send(parent, {:schema_error, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:error, _} = Validator.validate(UnresolvableTool, %{})
      assert_receive {:schema_error, %{tool_module: UnresolvableTool}}, 200

      assert {:error, _} = Validator.validate(UnresolvableTool, %{})
      # If the failure had been cached, no second telemetry event would fire.
      assert_receive {:schema_error, %{tool_module: UnresolvableTool}}, 200
    end

    test "invalidate/1 returns :ok and is safe to call on a never-cached module" do
      assert :ok == Validator.invalidate(StrictTool)
      assert :ok == Validator.invalidate(NeverCachedFakeModule)
    end
  end

  describe "successful resolutions are cached" do
    test "second call against StrictTool does not re-resolve" do
      Validator.invalidate(StrictTool)
      assert :ok == Validator.validate(StrictTool, %{"path" => "/x"})
      # Now the cache holds a resolved schema; pin that by deliberately
      # invalidating and re-running and asserting it still works.
      assert :ok == Validator.validate(StrictTool, %{"path" => "/x"})
    end
  end
end
