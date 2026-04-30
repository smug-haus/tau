defmodule Tau.Settings.SchemaTest do
  @moduledoc """
  Validates that `Tau.Settings.Schema.json_schema/0` is a well-formed
  JSON Schema (Draft 2020-12), parses cleanly via `ex_json_schema`, and
  accepts realistic settings inputs while rejecting obviously bad ones.

  Also smoke-tests `priv/scripts/gen_settings_schema.exs` end-to-end so
  the `mix tau.gen.schema` alias's first invocation cannot regress.
  """
  use ExUnit.Case, async: true

  alias Tau.Settings.Schema

  test "json_schema/0 returns a Draft 2020-12 object schema" do
    s = Schema.json_schema()
    assert s["$schema"] == "https://json-schema.org/draft/2020-12/schema"
    assert s["type"] == "object"
    assert is_map(s["properties"])
    assert is_binary(s["title"])
  end

  test "every list-merged key in Tau.Settings.Loader is declared in the schema" do
    # Loader merges these as arrays; the schema must describe them as such.
    list_keys = ~w(hooks extensions mcp allow deny ask permissions)
    schema_keys = Schema.known_top_level_keys()
    Enum.each(list_keys, fn k -> assert k in schema_keys end)
  end

  test "the schema is parseable by ex_json_schema and accepts a realistic settings doc" do
    resolved =
      Schema.json_schema()
      |> ExJsonSchema.Schema.resolve()

    valid = %{
      "model" => "claude-opus-4-7",
      "provider" => "anthropic",
      "theme" => "dark",
      "permissions" => %{"mode" => "plan", "rules" => ["Bash(git push)"]},
      "mcp" => [
        %{"name" => "fs", "transport" => "stdio", "command" => "node", "args" => ["fs.js"]}
      ],
      "hooks" => [%{"event" => "user_prompt_submit", "module" => "MyApp.Hook"}],
      "extensions" => ["my_app"],
      "allow" => ["Read(*)"],
      "deny" => [],
      "ask" => []
    }

    assert :ok == ExJsonSchema.Validator.validate(resolved, valid)
  end

  test "rejects an unknown permissions.mode value" do
    resolved = Schema.json_schema() |> ExJsonSchema.Schema.resolve()

    bad = %{"permissions" => %{"mode" => "godmode"}}

    assert {:error, errors} = ExJsonSchema.Validator.validate(resolved, bad)
    assert Enum.any?(errors, fn {msg, _} -> String.contains?(msg, "godmode") end)
  end

  describe "priv/scripts/gen_settings_schema.exs" do
    test "writes priv/schemas/settings.schema.json with a Jason-encodable schema" do
      tmp = Path.join(System.tmp_dir!(), "tau-gen-schema-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      script = Path.join(File.cwd!(), "priv/scripts/gen_settings_schema.exs")
      assert File.exists?(script), "script must exist for `mix tau.gen.schema` to work"

      # Run the script with cwd=tmp so it writes into the tmp dir, not the repo.
      File.cd!(tmp, fn -> Code.eval_file(script) end)

      out_path = Path.join(tmp, "priv/schemas/settings.schema.json")
      assert File.exists?(out_path)

      decoded = out_path |> File.read!() |> Jason.decode!()
      assert decoded["type"] == "object"
      assert decoded["$schema"] == "https://json-schema.org/draft/2020-12/schema"
    end
  end
end
