# Custom Provider

`Tau.Providers.Custom` — configure-by-URL OpenAI-Chat-compatible provider.

Targets any endpoint that speaks the OpenAI Chat Completions wire format
at `<base_url>/v1/chat/completions`. Useful for local inference servers
(Ollama, vLLM, LM Studio) and compatible proxies or gateways.

## Authentication

The `api_key` is **optional**. Local endpoints (Ollama, vLLM) typically
need no key. When absent the `Authorization` header is omitted entirely —
this is valid and expected behaviour.

Three resolution paths for `api_key`, evaluated in priority order:

1. Application env: `config :tau, Tau.Providers.Custom, api_key: "sk-..."`
2. Vault: `Tau.Settings.Vault.resolve({:vault, "CUSTOM_API_KEY"})`
3. Environment variable: `CUSTOM_API_KEY`

## Base URL

**Required.** Missing or empty `base_url` → `stream/3` returns
`{:error, :missing_base_url}` synchronously, with no network call.

Two resolution paths:

1. Application env: `config :tau, Tau.Providers.Custom, base_url: "http://localhost:11434"`
2. Environment variable: `CUSTOM_BASE_URL`

A trailing `/` is stripped automatically; the request URL appends
`/v1/chat/completions`.

## Model

1. Application env: `config :tau, Tau.Providers.Custom, default_model: "llama3"`
2. Environment variable: `CUSTOM_MODEL`
3. Sentinel `"custom-model"` — override per-call via `opts[:model]`

## Extra Headers

To forward additional HTTP headers (e.g. for authentication proxies):

```elixir
config :tau, Tau.Providers.Custom,
  headers: [{"x-api-gateway-key", "gw-..."}]
```

The `:headers` key accepts a list of `{string, string}` tuples or a
string-keyed map. These are merged after the base headers
(`content-type`, `accept`, and `authorization` when `api_key` is set).

## Usage

```
tau tui -p custom
```

Or set as the default provider:

```elixir
config :tau, :default_provider, Tau.Providers.Custom
```

Typical local Ollama setup:

```elixir
config :tau, Tau.Providers.Custom,
  base_url: "http://localhost:11434",
  default_model: "llama3.2"
```

Or via environment variables:

```sh
CUSTOM_BASE_URL=http://localhost:11434 CUSTOM_MODEL=llama3.2 tau tui -p custom
```

## Capabilities

| Capability      | Supported |
|-----------------|-----------|
| Thinking        | true (pass-through via `delta.reasoning`) |
| Tools           | true |
| Vision          | false |
| Prompt caching  | false |
| Parallel tools  | true |

## Diagnostics

```
tau doctor
```

Reports `base_url set (<url>)` or `not set`, and `api_key configured` or
`none (optional)`.
