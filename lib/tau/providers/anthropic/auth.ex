defmodule Tau.Providers.Anthropic.Auth do
  @moduledoc """
  Auth resolver for `Tau.Providers.Anthropic`. Returns either an
  API-key tuple or an OAuth tuple, or a structured error that
  `stream/3` surfaces to the user as a `MessageEnd` line.

  Supports two auth paths (D-017 in
  `docs/spec/SPEC-USER-TURN.md`):

    1. **API key** (`x-api-key` header). Sourced from explicit
       `:api_key` opt → `Application.get_env(:tau, Tau.Providers.Anthropic)[:api_key]`
       → vault `{:vault, "ANTHROPIC_API_KEY"}` (defaults to env).
    2. **Claude Code OAuth** (`Authorization: Bearer <token>` plus
       `anthropic-beta: oauth-2025-04-20`). Sourced from
       `~/.claude/.credentials.json`, top-level key `claudeAiOauth`.

  Pro/Max users do not have API keys; they authenticate via the
  OAuth path that Claude Code maintains. Without (2), Tau's TUI
  cannot serve the dominant user population.

  Tau v1 does NOT refresh OAuth tokens itself (D-018) — refresh
  would race with Claude Code's own refresh on the same file. An
  expired token surfaces an actionable error: "Your Claude Code
  OAuth token expired; run `claude /login` to renew."

  ## Resolution order (first non-error wins)

  ```
  opts[:api_key]                                 (per-call override)
    or Application.get_env(:tau, Anthropic)[:api_key]
    or Tau.Settings.Vault.resolve({:vault, "ANTHROPIC_API_KEY"})
    or read_oauth_credentials()                  (~/.claude/.credentials.json)
  ```

  Returns:
    * `{:ok, {:api_key, key_string}}`
    * `{:ok, {:oauth, %{access_token, expires_at, scopes, subscription_type}}}`
    * `{:error, :no_auth}` — no key and no OAuth file
    * `{:error, :oauth_expired}` — OAuth file present but token past `expires_at`
    * `{:error, :oauth_missing_scope}` — OAuth scopes lack `user:inference`
    * `{:error, :oauth_malformed}` — file exists but does not parse / lacks expected keys
  """

  @oauth_credentials_path "~/.claude/.credentials.json"
  @required_scope "user:inference"

  @type api_key :: {:api_key, String.t()}
  @type oauth :: {:oauth, %{
          access_token: String.t(),
          expires_at: integer(),
          scopes: [String.t()],
          subscription_type: String.t()
        }}

  @type ok :: {:ok, api_key() | oauth()}
  @type error ::
          {:error,
           :no_auth | :oauth_expired | :oauth_missing_scope | :oauth_malformed}

  @doc """
  Resolve auth from opts, app env, vault, then Claude Code OAuth file.

  `opts[:credentials_path]` is honored for tests (override the
  default `~/.claude/.credentials.json`).
  """
  @spec resolve(map() | keyword()) :: ok() | error()
  def resolve(opts \\ %{}) do
    case api_key_from_opts_or_env(opts) do
      key when is_binary(key) and key != "" ->
        {:ok, {:api_key, key}}

      _ ->
        resolve_oauth(opts)
    end
  end

  defp api_key_from_opts_or_env(opts) do
    Tau.Settings.Vault.resolve(opt(opts, :api_key)) ||
      Application.get_env(:tau, Tau.Providers.Anthropic, [])[:api_key] ||
      Tau.Settings.Vault.resolve({:vault, "ANTHROPIC_API_KEY"})
  end

  defp resolve_oauth(opts) do
    path =
      opt(opts, :credentials_path) ||
        Path.expand(@oauth_credentials_path)

    with {:ok, body} <- read_file(path),
         {:ok, decoded} <- decode_json(body),
         {:ok, oauth_block} <- fetch_oauth_block(decoded),
         {:ok, parsed} <- parse_oauth_block(oauth_block),
         :ok <- assert_unexpired(parsed),
         :ok <- assert_scope(parsed) do
      {:ok, {:oauth, parsed}}
    end
  end

  defp decode_json(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> {:error, :oauth_malformed}
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, body} -> {:ok, body}
      {:error, :enoent} -> {:error, :no_auth}
      {:error, _other} -> {:error, :oauth_malformed}
    end
  end

  defp fetch_oauth_block(%{"claudeAiOauth" => block}) when is_map(block), do: {:ok, block}
  defp fetch_oauth_block(_), do: {:error, :oauth_malformed}

  defp parse_oauth_block(%{
         "accessToken" => access_token,
         "expiresAt" => expires_at,
         "scopes" => scopes
       } = block)
       when is_binary(access_token) and is_integer(expires_at) and is_list(scopes) do
    {:ok,
     %{
       access_token: access_token,
       expires_at: expires_at,
       scopes: scopes,
       subscription_type: block["subscriptionType"] || "unknown"
     }}
  end

  defp parse_oauth_block(_), do: {:error, :oauth_malformed}

  defp assert_unexpired(%{expires_at: expires_at}) do
    now_ms = :os.system_time(:millisecond)
    if expires_at > now_ms, do: :ok, else: {:error, :oauth_expired}
  end

  defp assert_scope(%{scopes: scopes}) do
    if @required_scope in scopes, do: :ok, else: {:error, :oauth_missing_scope}
  end

  defp opt(opts, key) when is_map(opts), do: Map.get(opts, key)
  defp opt(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp opt(_, _), do: nil

  @doc """
  Translate an `error()` into a user-actionable message string. Used
  by `Tau.Providers.Anthropic.stream/3` and `tau doctor` so the user
  sees one renewal path or the other.
  """
  @spec describe_error(error()) :: String.t()
  def describe_error({:error, :no_auth}) do
    "No Anthropic auth found. Either set ANTHROPIC_API_KEY in env, or " <>
      "run `claude /login` to authenticate via your Claude Pro/Max subscription."
  end

  def describe_error({:error, :oauth_expired}) do
    "Your Claude Code OAuth token expired. Run `claude /login` to renew, " <>
      "or set ANTHROPIC_API_KEY in env."
  end

  def describe_error({:error, :oauth_missing_scope}) do
    "Your Claude Code OAuth token lacks the `#{@required_scope}` scope " <>
      "needed for the Messages API. Run `claude /login` to refresh, or " <>
      "set ANTHROPIC_API_KEY in env."
  end

  def describe_error({:error, :oauth_malformed}) do
    "Could not parse ~/.claude/.credentials.json. Either run `claude /login` " <>
      "to rewrite it, or set ANTHROPIC_API_KEY in env."
  end
end
