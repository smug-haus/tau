# DeepSeek Provider

`Tau.Providers.DeepSeek` — OpenAI-compatible Chat Completions endpoint at
`https://api.deepseek.com`. Supports DeepSeek-V3 (`deepseek-chat`) and
DeepSeek-R1 (`deepseek-reasoner`). DeepSeek-R1's chain-of-thought reasoning
is decoded from `delta.reasoning` into Tau's `ThinkingStart`/`ThinkingDelta`/
`ThinkingEnd` events by the shared `OpenAIChatWire` decoder.

## Authentication

Set `DEEPSEEK_API_KEY` to your DeepSeek API key. Three resolution paths,
evaluated in priority order:

1. Application env: `config :tau, Tau.Providers.DeepSeek, api_key: "ds-..."`
2. Vault: `Tau.Settings.Vault.resolve({:vault, "DEEPSEEK_API_KEY"})`
3. Environment variable: `DEEPSEEK_API_KEY`

Missing key → `stream/3` returns `{:error, :missing_api_key}` synchronously.

## Base URL Override

To route requests through a proxy or a local DeepSeek-compatible endpoint:

1. Application env: `config :tau, Tau.Providers.DeepSeek, base_url: "https://..."`
2. Environment variable: `DEEPSEEK_BASE_URL`
3. Default: `https://api.deepseek.com`

## Usage

```
tau tui -p deepseek
```

Or set as the default provider:

```
config :tau, :default_provider, Tau.Providers.DeepSeek
```

## Capabilities

| Capability      | Supported |
|-----------------|-----------|
| Thinking        | true (DeepSeek-R1 `delta.reasoning`) |
| Tools           | true |
| Vision          | false |
| Prompt caching  | true |
| Parallel tools  | true |

## Diagnostics

```
tau doctor
```

Reports `provider Tau.Providers.DeepSeek: deepseek configured` if a key
is present, `not configured` otherwise.
