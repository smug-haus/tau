defmodule Tau.Providers.Custom do
  @moduledoc """
  Configure-by-URL OpenAI-Chat-compatible provider.

  Targets any endpoint that speaks the OpenAI Chat Completions wire format
  (`/v1/chat/completions`). Useful for local inference servers (Ollama,
  vLLM, LM Studio) and compatible proxies.

  Wire-level helpers live in `Tau.Providers.Shared.OpenAIChatWire`.

  ## Configuration

  ### `base_url` (required)

  1. `config :tau, Tau.Providers.Custom, base_url: "http://localhost:11434"`
  2. `System.get_env("CUSTOM_BASE_URL")`

  Missing base_url → `stream/3` returns `{:error, :missing_base_url}` synchronously.
  Trailing `/` is stripped; the request URL appends `/v1/chat/completions`.

  ### `api_key` (optional)

  1. `config :tau, Tau.Providers.Custom, api_key: "sk-..."`
  2. `Tau.Settings.Vault.resolve({:vault, "CUSTOM_API_KEY"})`
  3. `System.get_env("CUSTOM_API_KEY")`

  A nil `api_key` is valid — local endpoints (Ollama, vLLM) typically
  need no key. When nil the `Authorization` header is omitted entirely.

  ### `headers` (optional)

  Extra HTTP headers merged onto the base set:

  1. `config :tau, Tau.Providers.Custom, headers: [{"x-foo", "bar"}]`

  ### `default_model`

  1. `config :tau, Tau.Providers.Custom, default_model: "llama3"`
  2. `System.get_env("CUSTOM_MODEL")`
  3. Sentinel `"custom-model"` — override via `opts[:model]` at call-time.

  ## Authentication contract

  `Tau.Providers.Custom` is a configure-by-URL OpenAI-Chat-compatible
  provider; a nil `api_key` is valid (it omits the `Authorization` header).
  The one synchronous hard-config error is `{:error, :missing_base_url}`;
  upstream 401/429 arrive in-stream as `%Event.Error{}`.
  """

  @behaviour Tau.Provider

  alias Tau.Providers.RateLimiter
  alias Tau.Providers.Shared.{FinchStream, OpenAIChatWire, TokenEstimate}

  @sentinel_model "custom-model"

  @impl Tau.Provider
  def default_model do
    Application.get_env(:tau, __MODULE__, [])[:default_model] ||
      System.get_env("CUSTOM_MODEL") ||
      @sentinel_model
  end

  @impl Tau.Provider
  def capabilities do
    %{
      thinking: true,
      tools: true,
      vision: false,
      prompt_caching: false,
      parallel_tools: true
    }
  end

  @impl Tau.Provider
  def stream(messages, opts \\ %{}, ctx \\ %{}) do
    case resolve_config() do
      {:error, reason} ->
        {:error, reason}

      {:ok, %{base_url: base_url, api_key: api_key, headers: extra_headers}} ->
        est = TokenEstimate.estimate(messages)

        case RateLimiter.acquire(__MODULE__, est) do
          {:error, :rate_limit_timeout} ->
            {:error, :rate_limited}

          :ok ->
            model = default_model()
            body = OpenAIChatWire.build_body(messages, opts, __MODULE__, model)
            url = base_url <> "/v1/chat/completions"
            headers = build_headers(api_key, extra_headers)

            request = Finch.build(:post, url, headers, Jason.encode!(body))

            {:ok,
             FinchStream.run(
               request,
               &OpenAIChatWire.decode/2,
               %{
                 tool_calls: %{},
                 model: nil,
                 provider: __MODULE__,
                 cancel_flag: ctx[:cancel_flag]
               }
             )}
        end
    end
  end

  # --- Private helpers -------------------------------------------------------

  # Authorization header is omitted when api_key is nil.
  defp build_headers(api_key, extra_headers) do
    base = [
      {"content-type", "application/json"},
      {"accept", "text/event-stream"}
    ]

    with_auth =
      if is_nil(api_key) do
        base
      else
        [{"authorization", "Bearer #{api_key}"} | base]
      end

    with_auth ++ List.wrap(extra_headers)
  end

  defp resolve_config do
    env = Application.get_env(:tau, __MODULE__, [])

    base_url =
      env[:base_url] ||
        System.get_env("CUSTOM_BASE_URL")

    if is_nil(base_url) or base_url == "" do
      {:error, :missing_base_url}
    else
      api_key =
        env[:api_key] ||
          vault_key() ||
          System.get_env("CUSTOM_API_KEY")

      extra_headers = env[:headers] || []

      {:ok,
       %{
         base_url: String.trim_trailing(base_url, "/"),
         api_key: api_key,
         headers: extra_headers
       }}
    end
  end

  defp vault_key do
    if Code.ensure_loaded?(Tau.Settings.Vault) do
      Tau.Settings.Vault.resolve({:vault, "CUSTOM_API_KEY"})
    end
  end
end
