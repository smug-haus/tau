defmodule Tau.Settings.SchemaTest do
  @moduledoc """
  Validates that `Tau.Settings.Schema.json_schema/0` is a well-formed
  JSON Schema (Draft 7 — `ex_json_schema 0.11` doesn't support
  newer drafts), parses cleanly via `ex_json_schema`, and accepts
  realistic settings inputs while rejecting obviously bad ones.

  Also pins `priv/scripts/gen_settings_schema.exs` as a path the
  `mix tau.gen.schema` alias can reach (we don't run the script —
  that would require `File.cd!` which mutates OS-global cwd).
  """
  use ExUnit.Case, async: true

  alias Tau.Settings.Schema

  test "json_schema/0 returns a Draft 7 object schema" do
    s = Schema.json_schema()
    assert s["$schema"] == "http://json-schema.org/draft-07/schema#"
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

  test "the schema is parseable by ex_json_schema (Draft 7) and accepts a realistic settings doc" do
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

    # ex_json_schema doesn't echo the offending value into the message;
    # assert on path + message keyword instead.
    assert Enum.any?(errors, fn {msg, path} ->
             path == "#/permissions/mode" and msg =~ "enum"
           end)
  end

  describe "resolve_fallback_chains/1 (ADR-0012)" do
    test "resolves string-keyed chains to atom modules from the known set" do
      settings = %{
        providers: %{
          fallback_chains: %{
            "Tau.Providers.Anthropic" => ["Tau.Providers.OpenAI.Chat", "Tau.Providers.Gemini"]
          }
        }
      }

      assert {:ok, chains} = Schema.resolve_fallback_chains(settings)

      assert chains == %{
               Tau.Providers.Anthropic => [
                 Tau.Providers.OpenAI.Chat,
                 Tau.Providers.Gemini
               ]
             }
    end

    test "rejects unknown providers fail-closed" do
      settings = %{
        providers: %{fallback_chains: %{"Tau.Providers.Anthropic" => ["NotARealProvider"]}}
      }

      assert {:error, {:unknown_provider, "NotARealProvider"}} =
               Schema.resolve_fallback_chains(settings)
    end

    test "atom keys + atom values (programmatic API) round-trip" do
      settings = %{
        providers: %{
          fallback_chains: %{Tau.Providers.Anthropic => [Tau.Providers.OpenAI.Chat]}
        }
      }

      assert {:ok,
              %{Tau.Providers.Anthropic => [Tau.Providers.OpenAI.Chat]}} =
               Schema.resolve_fallback_chains(settings)
    end

    test "missing :providers key returns an empty chain map" do
      assert {:ok, %{}} = Schema.resolve_fallback_chains(%{})
    end
  end

  describe "priv/scripts/gen_settings_schema.exs" do
    test "the script exists where the mix alias expects it and parses cleanly" do
      script = Path.join(File.cwd!(), "priv/scripts/gen_settings_schema.exs")
      assert File.exists?(script), "script must exist for `mix tau.gen.schema` to work"

      # We don't run the script here — File.cd! mutates OS-global cwd and
      # races with the parallel test compiler. The schema's content is
      # covered by the other tests in this file; this one just pins the
      # path the alias references.
      assert {:ok, _ast} = script |> File.read!() |> Code.string_to_quoted()
    end
  end
end
