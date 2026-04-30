import Config

config :tau,
  # Default provider; overridden by user/project settings.json or runtime env.
  default_provider: Tau.Providers.Anthropic,
  default_model: "claude-opus-4-7",
  # Where session JSONL is written. ~/.tau/sessions/<sha256(cwd)[..15]>/<ulid>.jsonl
  data_dir: nil,
  # Persistence backend. Pluggable via Tau.Persistence behaviour.
  persistence: Tau.Persistence.Jsonl,
  # Compaction strategy. Pluggable via Tau.Compactor behaviour.
  compactor: Tau.Compactor.SummarizeTail,
  # Built-in tools registered at boot. MCP/extension tools added dynamically.
  builtin_tools: [
    Tau.Tools.Builtin.Read,
    Tau.Tools.Builtin.Write,
    Tau.Tools.Builtin.Edit,
    Tau.Tools.Builtin.Bash
  ]

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:session_id, :tool_call_id, :provider]

config :logger, level: :info

import_config "#{config_env()}.exs"
