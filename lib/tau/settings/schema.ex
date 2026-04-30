defmodule Tau.Settings.Schema do
  @moduledoc """
  Canonical JSON Schema (Draft 7) for Tau settings files.

  Draft 7 (not 2020-12) because Tau pins `ex_json_schema ~> 0.10`, which
  only supports drafts 4/6/7. The features we rely on (`type`,
  `properties`, `additionalProperties`, `enum`, `items`, `required`,
  `$id`) are all available in Draft 7. Bump when the validator gets
  newer-draft support.

  Single source of truth shared by:

    * `mix tau.gen.schema` — writes `priv/schemas/settings.schema.json`
      so editors with JSON Schema integrations (VS Code, JetBrains)
      get completion and validation in `.tau/settings.json` files.
    * (future) the interactive `tau init` wizard, see the onboarding
      feature request.

  ## additionalProperties policy

  The top level uses `additionalProperties: false`: editors flag
  typos like `extentions` against the canonical key list, and the
  schema documents the API surface honestly. Sub-objects under
  `permissions`, individual MCP server entries, and individual
  hook entries keep `additionalProperties: true` so vendor-specific
  fields (e.g. an MCP server with a custom `auth` block) don't
  trip validation while we're still iterating on those shapes.

  Known top-level keys are kept in lockstep with `Tau.Settings.Loader` —
  in particular, every key listed here as `type: "array"` should appear
  in `Tau.Settings.Loader`'s list-merge set so cascade semantics match.
  """

  @schema_uri "http://json-schema.org/draft-07/schema#"
  @schema_id "https://raw.githubusercontent.com/smug-haus/tau/main/priv/schemas/settings.schema.json"

  @permissions_modes ~w(default accept_edits plan auto dont_ask bypass)
  @mcp_transports ~w(stdio sse http)
  @themes ~w(light dark auto)

  # Compile-time-built schema map (M13). json_schema/0 returns the
  # same literal map on every call without rebuilding it.
  @schema %{
    "$schema" => @schema_uri,
    "$id" => @schema_id,
    "title" => "Tau Settings",
    "description" => "Configuration for the Tau OTP/BEAM agentic coding harness.",
    "type" => "object",
    # M14: top-level keys are an enumerated set; typos in editors get
    # flagged. Sub-schemas stay permissive while their shapes settle.
    "additionalProperties" => false,
    "properties" => %{
      "model" => %{"type" => "string"},
      "provider" => %{"type" => "string"},
      "data_dir" => %{"type" => "string"},
      "theme" => %{"type" => "string", "enum" => @themes},
      "permissions" => %{
        "type" => "object",
        "additionalProperties" => true,
        "properties" => %{
          "mode" => %{"type" => "string", "enum" => @permissions_modes},
          "rules" => %{"type" => "array", "items" => %{"type" => "string"}}
        }
      },
      "mcp" => %{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "additionalProperties" => true,
          "required" => ["name"],
          "properties" => %{
            "name" => %{"type" => "string"},
            "transport" => %{"type" => "string", "enum" => @mcp_transports},
            "command" => %{"type" => "string"},
            "args" => %{"type" => "array", "items" => %{"type" => "string"}},
            "env" => %{
              "type" => "object",
              "additionalProperties" => %{"type" => "string"}
            },
            "url" => %{"type" => "string"}
          }
        }
      },
      "hooks" => %{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "additionalProperties" => true,
          "required" => ["event"],
          "properties" => %{
            "event" => %{"type" => "string"},
            "match" => %{"type" => "object"},
            "command" => %{"type" => "string"},
            "module" => %{"type" => "string"}
          }
        }
      },
      "extensions" => %{"type" => "array", "items" => %{"type" => "string"}},
      "allow" => %{"type" => "array", "items" => %{"type" => "string"}},
      "deny" => %{"type" => "array", "items" => %{"type" => "string"}},
      "ask" => %{"type" => "array", "items" => %{"type" => "string"}}
    }
  }

  @known_top_level_keys @schema |> Map.fetch!("properties") |> Map.keys() |> Enum.sort()

  @doc """
  Return the JSON Schema as a plain map. Serialise via
  `Jason.encode_to_iodata!(schema, pretty: true)` to get the on-disk
  artifact.
  """
  @spec json_schema() :: map()
  def json_schema, do: @schema

  @doc "List of known top-level keys (useful for tests / drift checks)."
  @spec known_top_level_keys() :: [String.t()]
  def known_top_level_keys, do: @known_top_level_keys
end
