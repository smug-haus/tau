defmodule Tau.Providers.AzureOpenAI do
  @moduledoc """
  Azure OpenAI Chat Completions provider.

  Azure OpenAI speaks the OpenAI Chat Completions wire format for the request
  body and the SSE response stream. The body and SSE helpers from
  `Tau.Providers.Shared.OpenAIChatWire` are reused without modification.

  Two things differ from the standard OpenAI-compatible providers:

  1. **Auth header** — Azure uses `api-key: <key>` (NOT `Authorization: Bearer`).
     `OpenAIChatWire.headers/1` MUST NOT be called for Azure requests.
  2. **URL shape** — Azure's endpoint is deployment-based:
     `{endpoint}/openai/deployments/{deployment}/chat/completions?api-version={api-version}`.
     There is no fixed base URL; the full URL is composed from configured values.

  ## Configuration

  Priority order for each required value:

  ### `api_key`
  1. `config :tau, Tau.Providers.AzureOpenAI, api_key: "..."`
  2. `Tau.Settings.Vault.resolve({:vault, "AZURE_OPENAI_API_KEY"})`
  3. `System.get_env("AZURE_OPENAI_API_KEY")`

  ### `endpoint`
  1. `config :tau, Tau.Providers.AzureOpenAI, endpoint: "https://..."`
  2. `System.get_env("AZURE_OPENAI_ENDPOINT")`

  ### `deployment`
  1. `config :tau, Tau.Providers.AzureOpenAI, deployment: "..."`
  2. `System.get_env("AZURE_OPENAI_DEPLOYMENT")`

  ### `api_version`
  1. `config :tau, Tau.Providers.AzureOpenAI, api_version: "..."`
  2. `System.get_env("AZURE_OPENAI_API_VERSION")`
  3. `"2024-12-01-preview"` (stable default)

  Missing `api_key`, `endpoint`, or `deployment` → `stream/3` returns
  `{:error, :missing_api_key}` synchronously before any network call.

  ## Auth / URL shape

  Azure OpenAI MUST use `api-key: <key>` (not `Authorization: Bearer`) and the
  deployment-based URL pattern.
  """

  @behaviour Tau.Provider

  alias Tau.Provider.ContextWindows
  alias Tau.Providers.RateLimiter
  alias Tau.Providers.Shared.{FinchStream, OpenAIChatWire, TokenEstimate}

  @default_api_version "2024-12-01-preview"
  # The deployment name acts as the model identifier for Azure OpenAI.
  @default_model "gpt-4o"

  @impl Tau.Provider
  def default_model, do: @default_model

  @impl Tau.Provider
  def context_window(model), do: ContextWindows.lookup(__MODULE__, model)

  @impl Tau.Provider
  def capabilities do
    %{
      thinking: false,
      tools: true,
      vision: true,
      prompt_caching: false,
      parallel_tools: true
    }
  end

  @impl Tau.Provider
  def stream(messages, opts \\ %{}, ctx \\ %{}) do
    case resolve_config() do
      {:error, reason} ->
        {:error, reason}

      {:ok, %{api_key: key, endpoint: endpoint, deployment: deployment, api_version: api_version}} ->
        est = TokenEstimate.estimate(messages)

        case RateLimiter.acquire(__MODULE__, est) do
          {:error, :rate_limit_timeout} ->
            {:error, :rate_limited}

          :ok ->
            body = OpenAIChatWire.build_body(messages, opts, __MODULE__, deployment)
            url = build_url(endpoint, deployment, api_version)
            headers = azure_headers(key)

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

  # C80: Azure MUST use `api-key` header, not `Authorization: Bearer`.
  defp azure_headers(api_key) do
    [
      {"api-key", api_key},
      {"content-type", "application/json"},
      {"accept", "text/event-stream"}
    ]
  end

  # C80: Azure URL is deployment-based, composed at request time.
  defp build_url(endpoint, deployment, api_version) do
    endpoint = String.trim_trailing(endpoint, "/")
    "#{endpoint}/openai/deployments/#{deployment}/chat/completions?api-version=#{api_version}"
  end

  defp resolve_config do
    env = Application.get_env(:tau, __MODULE__, [])
    api_key = env[:api_key] || vault_key() || System.get_env("AZURE_OPENAI_API_KEY")
    endpoint = env[:endpoint] || System.get_env("AZURE_OPENAI_ENDPOINT")
    deployment = env[:deployment] || System.get_env("AZURE_OPENAI_DEPLOYMENT")

    api_version =
      env[:api_version] || System.get_env("AZURE_OPENAI_API_VERSION") || @default_api_version

    cond do
      is_nil(api_key) or api_key == "" ->
        {:error, :missing_api_key}

      is_nil(endpoint) or endpoint == "" ->
        {:error, :missing_endpoint}

      is_nil(deployment) or deployment == "" ->
        {:error, :missing_deployment}

      true ->
        {:ok,
         %{api_key: api_key, endpoint: endpoint, deployment: deployment, api_version: api_version}}
    end
  end

  defp vault_key do
    if Code.ensure_loaded?(Tau.Settings.Vault) do
      Tau.Settings.Vault.resolve({:vault, "AZURE_OPENAI_API_KEY"})
    end
  end
end
