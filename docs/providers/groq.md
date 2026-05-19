# Groq Provider

`Tau.Providers.Groq` — OpenAI-compatible Chat Completions endpoint at
`https://api.groq.com/openai/v1`. Default model: `llama-3.3-70b-versatile`.

## Authentication

Set `GROQ_API_KEY` to your Groq API key. Three resolution paths,
evaluated in priority order:

1. Application env: `config :tau, Tau.Providers.Groq, api_key: "gsk_..."`
2. Vault: `Tau.Settings.Vault.resolve({:vault, "GROQ_API_KEY"})`
3. Environment variable: `GROQ_API_KEY`

Missing key → `stream/3` returns `{:error, :missing_api_key}` synchronously.

## Base URL Override

To route requests through a proxy or a local Groq-compatible endpoint:

1. Application env: `config :tau, Tau.Providers.Groq, base_url: "https://..."`
2. Environment variable: `GROQ_BASE_URL`
3. Default: `https://api.groq.com/openai/v1`

## Usage

```
tau tui -p groq
```

Or set as the default provider:

```
config :tau, :default_provider, Tau.Providers.Groq
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

Reports `provider Tau.Providers.Groq: groq configured` if a key
is present, `not configured` otherwise.
