defmodule Tau.Providers.Copilot.Auth do
  @moduledoc """
  Auth subsystem for `Tau.Providers.Copilot`.

  Copilot authentication uses a two-token model:

    1. **OAuth token** — long-lived GitHub OAuth token stored by the
       Copilot CLI at `~/.config/github-copilot/hosts.json`.
    2. **API token** — short-lived (~30 min) token obtained by
       exchanging the OAuth token at the Copilot internal token
       endpoint. This is what the Copilot completions API accepts.

  ## Resolution order

  ```
  COPILOT_TOKEN env var                             (headless / CI)
    or GITHUB_COPILOT_TOKEN env var                 (alias)
    or ~/.config/github-copilot/hosts.json          (Copilot CLI)
    or ~/.config/github-copilot/apps.json           (alternative path)
  ```

  Returns:
    * `{:ok, oauth_token_string}` — the long-lived OAuth token
    * `{:error, :no_auth}` — no token found anywhere

  ## Short-lived API tokens

  `token/1` returns the usable API token, delegating the expiry check and
  refresh action entirely to `Tau.Providers.Copilot.TokenStore`. The store
  serializes both within a single `handle_call`, so concurrent callers
  queue behind one in-flight refresh rather than each firing their own —
  preventing the thundering-herd race that would otherwise trip GitHub's
  rate limiter.

  D-056: The API token MUST be refreshed when `expires_at - now < 5 min`
  to avoid mid-turn token-expired failures. Refresh failure surfaces as
  `{:error, :oauth_refresh_failed}` and MUST be surfaced to the user
  with an actionable message.

  ## Error variants

    * `{:error, :no_auth}` — no OAuth token found
    * `{:error, :oauth_expired}` — OAuth token itself is expired (401)
    * `{:error, :oauth_refresh_failed}` — API token exchange failed (non-401 error)
    * `{:error, :oauth_malformed}` — hosts.json exists but cannot be parsed
  """

  alias Tau.Providers.Copilot.TokenStore

  @hosts_json_path "~/.config/github-copilot/hosts.json"
  @apps_json_path "~/.config/github-copilot/apps.json"
  @token_endpoint "https://api.github.com/copilot_internal/v2/token"

  @type oauth_token :: String.t()
  @type api_token_info :: %{token: String.t(), expires_at: integer()}

  @type error ::
          {:error, :no_auth | :oauth_expired | :oauth_refresh_failed | :oauth_malformed}

  # ---------------------------------------------------------------------------
  # OAuth token resolution (from disk / env)
  # ---------------------------------------------------------------------------

  @doc """
  Resolve the long-lived GitHub OAuth token.

  Checks env vars first, then `hosts.json`, then `apps.json`.
  `opts[:hosts_json_path]` overrides the default path (for tests).
  `opts[:apps_json_path]` overrides the apps.json path (for tests).

  Returns `{:ok, oauth_token}` or `{:error, :no_auth | :oauth_malformed}`.
  """
  @spec resolve_oauth(map() | keyword()) :: {:ok, oauth_token()} | error()
  def resolve_oauth(opts \\ %{}) do
    case env_token() do
      token when is_binary(token) and token != "" ->
        {:ok, token}

      _ ->
        resolve_from_file(opts)
    end
  end

  @doc """
  Return the usable short-lived API token, refreshing via the TokenStore
  if the cached token is absent or nearing expiry.

  Delegates the expiry check + refresh to `Tau.Providers.Copilot.TokenStore`
  via a single serialized `handle_call`, eliminating the thundering-herd race.
  At most one in-flight refresh exists per store instance; concurrent callers
  queue and receive the result of that one refresh.

  `opts[:token_store]` overrides the registered name (default:
  `Tau.Providers.Copilot.TokenStore`). Pass a test-specific atom to isolate
  tests.

  `opts[:hosts_json_path]` / `opts[:apps_json_path]` are forwarded to
  `resolve_oauth/1` when a refresh is needed.

  Returns `{:ok, token_string}` or an error tuple.
  """
  @spec token(map() | keyword()) :: {:ok, String.t()} | error()
  def token(opts \\ %{}) do
    store_name = opt(opts, :token_store) || Tau.Providers.Copilot.TokenStore

    refresh_fn = fn ->
      with {:ok, oauth_token} <- resolve_oauth(opts) do
        refresh(oauth_token, opts)
      end
    end

    TokenStore.token(refresh_fn, store_name)
  end

  @doc """
  Exchange the long-lived OAuth token for a short-lived API token.

  Makes a `POST https://api.github.com/copilot_internal/v2/token`
  request with the OAuth token in the `Authorization` header.

  `opts[:base_url]` overrides the default endpoint (for tests).
  `opts[:finch]` overrides the Finch instance (defaults to `Tau.Providers.Finch`).

  Returns `{:ok, %{token: t, expires_at: epoch_ms}}`,
  `{:error, :oauth_expired}` (401 — OAuth token rejected or expired), or
  `{:error, :oauth_refresh_failed}` (other HTTP / network error).
  """
  @spec refresh(oauth_token(), map() | keyword()) ::
          {:ok, api_token_info()} | {:error, :oauth_expired | :oauth_refresh_failed}
  def refresh(oauth_token, opts \\ %{}) do
    base_url = opt(opts, :base_url) || @token_endpoint
    finch_name = opt(opts, :finch) || Tau.Providers.Finch

    request =
      Finch.build(
        :post,
        base_url,
        [
          {"Authorization", "token #{oauth_token}"},
          {"Accept", "application/json"},
          {"Editor-Version", "tau/1.0"},
          {"Copilot-Integration-Id", "tau"}
        ],
        ""
      )

    case Finch.request(request, finch_name, receive_timeout: 30_000) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        parse_api_token(body)

      {:ok, %Finch.Response{status: 401}} ->
        :telemetry.execute(
          [:tau, :copilot, :auth, :refresh_failed],
          %{system_time: System.system_time()},
          %{status: 401, reason: :oauth_expired}
        )

        {:error, :oauth_expired}

      {:ok, %Finch.Response{status: status}} ->
        :telemetry.execute(
          [:tau, :copilot, :auth, :refresh_failed],
          %{system_time: System.system_time()},
          %{status: status}
        )

        {:error, :oauth_refresh_failed}

      {:error, reason} ->
        :telemetry.execute(
          [:tau, :copilot, :auth, :refresh_failed],
          %{system_time: System.system_time()},
          %{reason: inspect(reason)}
        )

        {:error, :oauth_refresh_failed}
    end
  end

  @doc """
  Translate an `error()` into a user-actionable message string.
  Used by `tau doctor` and the Copilot provider stream error surface.
  """
  @spec describe_error(error()) :: String.t()
  def describe_error({:error, :no_auth}) do
    "No GitHub Copilot auth found. Either set COPILOT_TOKEN in env, or " <>
      "install the GitHub Copilot CLI and run `gh auth login --scopes copilot`."
  end

  def describe_error({:error, :oauth_expired}) do
    "Your GitHub Copilot OAuth token has expired. " <>
      "Run `gh auth login --scopes copilot` to renew."
  end

  def describe_error({:error, :oauth_refresh_failed}) do
    "GitHub Copilot API token refresh failed. Check your network connection " <>
      "and that your GitHub subscription includes Copilot. " <>
      "Run `gh auth login --scopes copilot` to re-authenticate."
  end

  def describe_error({:error, :oauth_malformed}) do
    "Could not parse ~/.config/github-copilot/hosts.json. " <>
      "Run `gh auth login --scopes copilot` to rewrite it, " <>
      "or set COPILOT_TOKEN in env."
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp env_token do
    System.get_env("COPILOT_TOKEN") || System.get_env("GITHUB_COPILOT_TOKEN")
  end

  defp resolve_from_file(opts) do
    hosts_path =
      opt(opts, :hosts_json_path) ||
        Path.expand(@hosts_json_path)

    apps_path =
      opt(opts, :apps_json_path) ||
        Path.expand(@apps_json_path)

    case read_oauth_from_file(hosts_path) do
      {:ok, _} = ok -> ok
      {:error, :no_auth} -> read_oauth_from_file(apps_path)
      {:error, _} = err -> err
    end
  end

  # hosts.json shape (written by `gh auth login --scopes copilot`):
  #   {
  #     "github.com": {
  #       "oauth_token": "<token>",
  #       "user": "username"
  #     }
  #   }
  #
  # apps.json shape (alternative, written by some Copilot CLI versions):
  #   {
  #     "github.com:Copilot": {
  #       "oauth_token": "<token>"
  #     }
  #   }
  #
  # In both cases we look for any top-level key containing "github.com"
  # and extract the "oauth_token" field.
  defp read_oauth_from_file(path) do
    with {:ok, body} <- read_file(path),
         {:ok, decoded} <- decode_json(body) do
      extract_oauth_token(decoded)
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, body} -> {:ok, body}
      {:error, :enoent} -> {:error, :no_auth}
      {:error, _} -> {:error, :oauth_malformed}
    end
  end

  defp decode_json(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> {:error, :oauth_malformed}
    end
  end

  defp extract_oauth_token(decoded) when is_map(decoded) do
    # Find the first key containing "github.com" and extract oauth_token
    result =
      Enum.find_value(decoded, fn {key, value} ->
        if String.contains?(key, "github.com") and is_map(value) do
          case Map.get(value, "oauth_token") do
            token when is_binary(token) and token != "" -> token
            _ -> nil
          end
        end
      end)

    case result do
      nil -> {:error, :no_auth}
      token -> {:ok, token}
    end
  end

  defp extract_oauth_token(_), do: {:error, :oauth_malformed}

  defp parse_api_token(body) do
    case Jason.decode(body) do
      {:ok, %{"token" => token, "expires_at" => expires_at}}
      when is_binary(token) ->
        case parse_expires_at(expires_at) do
          {:ok, expires_ms} ->
            {:ok, %{token: token, expires_at: expires_ms}}

          :error ->
            {:error, :oauth_refresh_failed}
        end

      _ ->
        {:error, :oauth_refresh_failed}
    end
  end

  # expires_at may be:
  #   - an ISO 8601 string, e.g. "2026-05-19T12:34:56Z"
  #   - a Unix epoch integer (seconds), as returned by some API versions
  # Both are converted to milliseconds epoch.
  defp parse_expires_at(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> {:ok, DateTime.to_unix(dt, :millisecond)}
      _ -> :error
    end
  end

  defp parse_expires_at(epoch_s) when is_integer(epoch_s) do
    {:ok, DateTime.from_unix!(epoch_s, :second) |> DateTime.to_unix(:millisecond)}
  end

  defp parse_expires_at(_), do: :error

  defp opt(opts, key) when is_map(opts), do: Map.get(opts, key)
  defp opt(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp opt(_, _), do: nil
end
