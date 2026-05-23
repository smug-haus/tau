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

  # ADR-0012: known providers for fallback-chain validation. The schema
  # itself stays permissive (additionalProperties: true on the outer
  # `providers` object so future keys land softly), but the
  # `resolve_fallback_chains/1` post-processor rejects unknown modules
  # fail-closed so a typo in `.tau/settings.json` doesn't produce a
  # silent no-op chain.
  @known_providers [
    Tau.Providers.Anthropic,
    Tau.Providers.OpenAI.Chat,
    Tau.Providers.OpenAI.Responses,
    Tau.Providers.Gemini,
    Tau.Providers.Bedrock,
    Tau.Providers.Replay
  ]

  # Compile-time-built schema map. json_schema/0 returns the
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
      "ask" => %{"type" => "array", "items" => %{"type" => "string"}},
      # ADR-0012: per-provider fallback chains for retryable errors.
      # Shape: %{"<primary-provider>" => ["<fallback1>", ...]}.
      # Strings are resolved to provider modules at load time by
      # `resolve_fallback_chains/1`; unknown modules fail closed.
      "providers" => %{
        "type" => "object",
        "additionalProperties" => true,
        "properties" => %{
          "fallback_chains" => %{
            "type" => "object",
            "additionalProperties" => %{
              "type" => "array",
              "items" => %{"type" => "string"}
            }
          }
        }
      },
      "rate_limits" => %{
        "type" => "object",
        "additionalProperties" => %{
          "type" => "object",
          "additionalProperties" => true,
          "properties" => %{
            "rpm" => %{"type" => "integer", "minimum" => 0},
            "tpm" => %{"type" => "integer", "minimum" => 0}
          }
        }
      },
      # ADR-0016: credential custody is the OS, not Tau. The
      # `backend` enum picks a `Tau.Settings.Vault` implementation;
      # `auto` resolves at runtime via `:os.type/0`. Defaults to
      # `env` (`System.get_env/1` passthrough) when omitted.
      "vault" => %{
        "type" => "object",
        "additionalProperties" => true,
        "properties" => %{
          "backend" => %{
            "type" => "string",
            "enum" => ~w(env keychain_mac keychain_linux keychain_windows auto)
          }
        }
      },
      # SPEC-CODING-AGENT / D-037: deployment-wide default for
      # the coding-agent session-mode surface. `default_agent` is a
      # short name resolved via `Tau.CLI.resolve_coding_agent/1`
      # (e.g. `"claude_code"`, `"replay"`). The CLI flag
      # `--coding-agent` overrides; in-flight sessions snapshot at init.
      "coding_agent" => %{
        "type" => "object",
        "additionalProperties" => true,
        "properties" => %{
          "default_agent" => %{"type" => ["string", "null"]},
          "expose_tau_context" => %{"type" => "boolean"}
        }
      },
      # SPEC-OTEL-REPORTER / AC-2: OpenTelemetry export settings.
      # `enabled` gates reporter startup; all other keys are optional and
      # take the defaults documented in SPEC-OTEL-REPORTER §6 (D-053/D-054).
      "otel" => %{
        "type" => "object",
        "additionalProperties" => false,
        "properties" => %{
          "enabled" => %{"type" => "boolean"},
          "endpoint" => %{
            "type" => "string",
            "description" => "OTLP gRPC or HTTP endpoint, e.g. http://localhost:4317"
          },
          "headers" => %{
            "type" => "object",
            "additionalProperties" => %{"type" => "string"},
            "description" => "Extra HTTP headers for OTLP export, e.g. authentication tokens."
          },
          "sampling_ratio" => %{
            "type" => "number",
            "minimum" => 0,
            "maximum" => 1,
            "description" => "Probability [0.0, 1.0] that any given span is exported. Default 1.0."
          },
          "max_open_spans" => %{
            "type" => "integer",
            "minimum" => 1,
            "description" => "Upper bound on in-flight spans (D-054). Default 1000."
          },
          "sweep_interval_ms" => %{
            "type" => "integer",
            "minimum" => 1000,
            "description" => "How often to sweep for stale spans in ms (D-053). Default 60000."
          },
          "sweep_age_ms" => %{
            "type" => "integer",
            "minimum" => 1000,
            "description" =>
              "Age threshold in ms after which an open span is force-finished (D-053). Default 120000."
          }
        }
      }
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

  @doc "List of provider modules recognised by `resolve_fallback_chains/1`."
  @spec known_providers() :: [module()]
  def known_providers, do: @known_providers

  @doc """
  Resolve a `%{"providers" => %{"fallback_chains" => %{...}}}` block
  into atom-keyed maps with module-list values, rejecting any string
  that doesn't resolve to a known provider module.

  Mirrors the tone of `Tau.Providers.RateLimiter.sizes_from_settings/2`:
  accepts both atom and string keys (Settings.Loader uses
  `Jason.decode(_, keys: :atoms)`, so atoms are the common case;
  string keys are tolerated for hand-built test fixtures).

  Returns `{:ok, chains}` on success, where `chains` is
  `%{provider_atom => [provider_module]}`. Returns
  `{:error, {:unknown_provider, str}}` when any module reference
  doesn't resolve — fail-closed: a typo upstream is loud here, not
  a silent no-op chain at session-start time.
  """
  @spec resolve_fallback_chains(map()) ::
          {:ok, %{module() => [module()]}} | {:error, {:unknown_provider, String.t()}}
  def resolve_fallback_chains(settings) when is_map(settings) do
    providers = Map.get(settings, :providers) || Map.get(settings, "providers") || %{}

    chains =
      Map.get(providers, :fallback_chains) || Map.get(providers, "fallback_chains") || %{}

    Enum.reduce_while(chains, {:ok, %{}}, fn {key, list}, {:ok, acc} ->
      with {:ok, key_mod} <- to_known_module(key),
           {:ok, list_mods} <- resolve_module_list(list) do
        {:cont, {:ok, Map.put(acc, key_mod, list_mods)}}
      else
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp resolve_module_list(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn entry, {:ok, acc} ->
      case to_known_module(entry) do
        {:ok, mod} -> {:cont, {:ok, acc ++ [mod]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  # An atom passed in programmatically is already a resolved module
  # reference; trust it iff it implements `Tau.Provider` (or is one of
  # our `@known_providers` for the test-only Replay case). String input
  # — the .tau/settings.json path — is strict: only `@known_providers`
  # are accepted, otherwise it's a typo and we fail closed.
  defp to_known_module(mod) when is_atom(mod) do
    cond do
      mod in @known_providers -> {:ok, mod}
      implements_provider?(mod) -> {:ok, mod}
      true -> {:error, {:unknown_provider, inspect(mod)}}
    end
  end

  defp to_known_module(str) when is_binary(str) do
    try do
      mod = String.to_existing_atom("Elixir." <> str)
      if mod in @known_providers, do: {:ok, mod}, else: {:error, {:unknown_provider, str}}
    rescue
      ArgumentError -> {:error, {:unknown_provider, str}}
    end
  end

  defp implements_provider?(mod) do
    Code.ensure_loaded(mod)

    function_exported?(mod, :stream, 3) and
      function_exported?(mod, :capabilities, 0) and
      function_exported?(mod, :default_model, 0)
  end
end
