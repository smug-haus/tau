defmodule Tau.Commands.Builtin.Logout do
  @moduledoc """
  Built-in `/logout [provider]` command.

  Clears Tau's own credential entry for the named provider from the
  configured `Tau.Settings.Vault` backend.

  **CRITICAL — single-writer rule:** This command MUST NOT touch
  `~/.claude/.credentials.json`.  That file is owned exclusively by
  Claude Code.  `/logout` only clears entries that Tau itself stored via
  `Tau.Settings.Vault`.

  ## Provider aliases

  | Alias | Vault credential name |
  |---|---|
  | `anthropic` | `ANTHROPIC_API_KEY` |
  | `openai` | `OPENAI_API_KEY` |
  | `gemini` | `GEMINI_API_KEY` |
  | `bedrock` | `AWS_SECRET_ACCESS_KEY` |

  If `provider` is omitted or unrecognised, returns `{:error, ...}`.

  ## Backend behaviour

  Deletion is delegated to the configured vault backend via
  `Tau.Settings.Vault.delete/1`.  Backends that do not support
  deletion (e.g. the default `Env` passthrough) return
  `{:error, :read_only}`, which surfaces as an error notice.
  """

  @behaviour Tau.Commands.Builtin

  alias Tau.Settings.Vault

  # Maps the user-facing provider alias to the vault credential name Tau
  # uses for that provider (as documented in each provider's @moduledoc).
  @credential_map %{
    "anthropic" => "ANTHROPIC_API_KEY",
    "openai" => "OPENAI_API_KEY",
    "gemini" => "GEMINI_API_KEY",
    "bedrock" => "AWS_SECRET_ACCESS_KEY"
  }

  @impl Tau.Commands.Builtin
  def name, do: "/logout"

  @impl Tau.Commands.Builtin
  def description, do: "Remove stored credentials for a provider"

  @impl Tau.Commands.Builtin
  def run(args, _data) do
    provider = String.trim(args)

    cond do
      provider == "" ->
        known = @credential_map |> Map.keys() |> Enum.sort() |> Enum.join(", ")
        {:error, "Provider required. Known providers: #{known}"}

      not Map.has_key?(@credential_map, provider) ->
        known = @credential_map |> Map.keys() |> Enum.sort() |> Enum.join(", ")
        {:error, "Unknown provider: #{provider}. Known providers: #{known}"}

      true ->
        cred_name = @credential_map[provider]

        case Vault.delete(cred_name) do
          :ok ->
            {:notice, "Logged out of #{provider}."}

          {:error, :not_found} ->
            {:error, "No credential stored for #{provider}."}

          {:error, :not_implemented} ->
            {:error,
             "Credential removal is not supported on this platform. " <>
               "Remove the credential manually via your system credential store."}

          {:error, :read_only} ->
            {:error,
             "Vault backend does not support credential removal. " <>
               "Unset the environment variable #{cred_name} manually."}

          {:error, reason} ->
            {:error, "Failed to remove credential for #{provider}: #{inspect(reason)}"}
        end
    end
  end
end
