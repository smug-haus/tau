# Azure OpenAI Provider

`Tau.Providers.AzureOpenAI` — Azure OpenAI Chat Completions (deployment-based).

Uses the same OpenAI-compatible wire format as `Tau.Providers.OpenAI.Chat` for
the request body and SSE stream. Auth and URL differ; see C80 (SPEC-USER-TURN §3).

## Authentication

Azure uses an `api-key` HTTP header (not `Authorization: Bearer`).

Set `AZURE_OPENAI_API_KEY` to your Azure OpenAI key. Three resolution paths,
evaluated in priority order:

1. Application env: `config :tau, Tau.Providers.AzureOpenAI, api_key: "..."`
2. Vault: `Tau.Settings.Vault.resolve({:vault, "AZURE_OPENAI_API_KEY"})`
3. Environment variable: `AZURE_OPENAI_API_KEY`

## Endpoint and deployment

Azure OpenAI uses a deployment-based URL:

```
{endpoint}/openai/deployments/{deployment}/chat/completions?api-version={api-version}
```

Configure each value:

| Config key | App env key | Env var | Default |
|---|---|---|---|
| `api_key` | `api_key` | `AZURE_OPENAI_API_KEY` | — (required) |
| `endpoint` | `endpoint` | `AZURE_OPENAI_ENDPOINT` | — (required) |
| `deployment` | `deployment` | `AZURE_OPENAI_DEPLOYMENT` | — (required) |
| `api_version` | `api_version` | `AZURE_OPENAI_API_VERSION` | `"2024-12-01-preview"` |

Example application env:

```elixir
config :tau, Tau.Providers.AzureOpenAI,
  api_key: "your-azure-key",
  endpoint: "https://my-resource.openai.azure.com",
  deployment: "my-gpt4o",
  api_version: "2024-12-01-preview"
```

The `deployment` name also acts as the model identifier (passed as the `model`
field in the request body). The actual model (e.g., GPT-4o, GPT-4o-mini) is
determined by your Azure deployment configuration.

## Error surface

Missing `api_key` → `stream/3` returns `{:error, :missing_api_key}` synchronously.
Missing `endpoint` → `{:error, :missing_endpoint}` synchronously.
Missing `deployment` → `{:error, :missing_deployment}` synchronously.
HTTP 401/429 → in-stream `%Tau.Provider.Event.Error{}` (no raise).

## Usage

```
tau tui -p azure
# or
tau tui -p azure-openai
```

Or set as the default provider:

```elixir
config :tau, :default_provider, Tau.Providers.AzureOpenAI
```

## Capabilities

| Capability      | Supported |
|-----------------|-----------|
| Thinking        | false |
| Tools           | true |
| Vision          | true |
| Prompt caching  | false |
| Parallel tools  | true |

## Diagnostics

```
tau doctor
```

Reports `provider Tau.Providers.AzureOpenAI: configured (deployment: <name>)` when
all three required values are present, or names the first missing value otherwise.
