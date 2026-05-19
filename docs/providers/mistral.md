# Mistral Provider

`Tau.Providers.Mistral` — OpenAI-compatible Chat Completions endpoint at
`https://api.mistral.ai/v1`. Supports Mistral's flagship models including
`mistral-large-latest`, `mistral-small-latest`, and `open-mistral-nemo`.

## Authentication

Set `MISTRAL_API_KEY` to your Mistral API key. Three resolution paths,
evaluated in priority order:

1. Application env: `config :tau, Tau.Providers.Mistral, api_key: "..."`
2. Vault: `Tau.Settings.Vault.resolve({:vault, "MISTRAL_API_KEY"})`
3. Environment variable: `MISTRAL_API_KEY`

Missing key → `stream/3` returns `{:error, :missing_api_key}` synchronously.

## Base URL Override

To route requests through a proxy or a local Mistral-compatible endpoint:

1. Application env: `config :tau, Tau.Providers.Mistral, base_url: "https://..."`
2. Environment variable: `MISTRAL_BASE_URL`
3. Default: `https://api.mistral.ai/v1`

Note: the base URL should include `/v1`; `chat/completions` is appended automatically.

## Usage

```
tau tui -p mistral
```

Or set as the default provider:

```
config :tau, :default_provider, Tau.Providers.Mistral
```

## Capabilities

| Capability      | Supported |
|-----------------|-----------|
| Thinking        | false     |
| Tools           | true      |
| Vision          | false     |
| Prompt caching  | false     |
| Parallel tools  | true      |

## Diagnostics

```
tau doctor
```

Reports `provider Tau.Providers.Mistral: mistral configured` if a key
is present, `not configured` otherwise.
