defmodule Tau.Settings.Schema do
  @moduledoc """
  Canonical JSON Schema (Draft 2020-12) for Tau settings files.

  Single source of truth shared by:

    * `mix tau.gen.schema` — writes `priv/schemas/settings.schema.json`
      so editors with JSON Schema integrations (VS Code, JetBrains)
      get completion and validation in `.tau/settings.json` files.
    * (future) the interactive `tau init` wizard, see the onboarding
      feature request.

  The schema is intentionally permissive (`additionalProperties: true`
  at every level) so an out-of-band setting added in a feature branch
  doesn't immediately make stable releases red. Tighten field-by-field
  as subsystems freeze their config surface.

  Known top-level keys are kept in lockstep with `Tau.Settings.Loader` —
  in particular, every key listed here as `type: "array"` should appear
  in `Tau.Settings.Loader`'s list-merge set so cascade semantics match.
  """

  @schema_uri "https://json-schema.org/draft/2020-12/schema"
  @schema_id "https://raw.githubusercontent.com/smug-haus/tau/main/priv/schemas/settings.schema.json"

  @permissions_modes ~w(default accept_edits plan auto dont_ask bypass)
  @mcp_transports ~w(stdio sse http)
  @themes ~w(light dark auto)

  @doc """
  Return the JSON Schema as a plain map. Serialise via
  `Jason.encode_to_iodata!(schema, pretty: true)` to get the on-disk
  artifact.
  """
  @spec json_schema() :: map()
  def json_schema do
    %{
      "$schema" => @schema_uri,
      "$id" => @schema_id,
      "title" => "Tau Settings",
      "description" => "Configuration for the Tau OTP/BEAM agentic coding harness.",
      "type" => "object",
      "additionalProperties" => true,
      "properties" => %{
        "model" => %{"type" => "string"},
        "provider" => %{"type" => "string"},
        "data_dir" => %{"type" => "string"},
        "theme" => %{"type" => "string", "enum" => @themes},
        "permissions" => permissions_schema(),
        "mcp" => array_of(mcp_server_schema()),
        "hooks" => array_of(hook_schema()),
        "extensions" => array_of(%{"type" => "string"}),
        "allow" => array_of(%{"type" => "string"}),
        "deny" => array_of(%{"type" => "string"}),
        "ask" => array_of(%{"type" => "string"})
      }
    }
  end

  @doc "List of known top-level keys (useful for tests / drift checks)."
  @spec known_top_level_keys() :: [String.t()]
  def known_top_level_keys do
    json_schema() |> Map.fetch!("properties") |> Map.keys() |> Enum.sort()
  end

  defp permissions_schema do
    %{
      "type" => "object",
      "additionalProperties" => true,
      "properties" => %{
        "mode" => %{"type" => "string", "enum" => @permissions_modes},
        "rules" => array_of(%{"type" => "string"})
      }
    }
  end

  defp mcp_server_schema do
    %{
      "type" => "object",
      "additionalProperties" => true,
      "required" => ["name"],
      "properties" => %{
        "name" => %{"type" => "string"},
        "transport" => %{"type" => "string", "enum" => @mcp_transports},
        "command" => %{"type" => "string"},
        "args" => array_of(%{"type" => "string"}),
        "env" => %{"type" => "object", "additionalProperties" => %{"type" => "string"}},
        "url" => %{"type" => "string"}
      }
    }
  end

  defp hook_schema do
    %{
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
  end

  defp array_of(item_schema), do: %{"type" => "array", "items" => item_schema}
end
