# Tau

> An OTP/BEAM agentic coding harness — configurable, flexible, extensible.

Tau is a from-scratch reimagining of the [Pi harness][pi] (`badlogic/pi-mono`,
TypeScript) built around Elixir/OTP idioms. It runs on the BEAM and ships as
a Hex library, an escript, and a self-contained binary (via Burrito).

[pi]: https://github.com/badlogic/pi-mono

## Status

**Pre-alpha.** M0 (project skeleton + supervision tree boots clean) is in.
M1 — M8 milestones are tracked in `CHANGELOG.md` and in the plan at
`/root/.claude/plans/clear-out-this-repo-fluffy-hamming.md`.

## Design philosophy

- **No shortcuts.** Every stateful subsystem is a process under a supervisor.
- **No OO smell.** Every extensibility seam is a behaviour. Pattern match on
  atoms and structs; never on stringified types. No abstract base classes,
  no inheritance simulation, no string-keyed dispatch tables.
- **Lean on the BEAM.** Concurrency is `Task.Supervisor` + `:gen_statem`.
  Lookups are `Registry`. Hot-path reads are `:persistent_term`. Fanout is
  `Phoenix.PubSub`. Subprocess management is `Port` (and `:erlexec` for Bash).
  Hot reload is `Code.compile_file/1` + `:code.purge/1`.

## Quick start

```sh
# Install Erlang/Elixir per .tool-versions (asdf or mise recommended).
asdf install   # or `mise install`

mix deps.get
mix compile
mix test

# Headless one-shot:
ANTHROPIC_API_KEY=... mix tau.hello

# Build the escript:
mix escript.build
./tau                       # interactive TUI
./tau run "summarize this repo" --provider anthropic
./tau resume <session-id>
./tau sessions list
./tau mcp add filesystem -- npx @modelcontextprotocol/server-filesystem /tmp
```

## Architecture at a glance

```
Tau.Supervisor                                  (:rest_for_one)
├── Tau.Telemetry.Supervisor
├── Tau.Settings.Cache              (->:persistent_term)
├── Tau.Settings.Watcher            (file_system)
├── Tau.Memory.Cache                (ETS)
├── Tau.Permissions.RuleSet         (->:persistent_term)
├── Tau.Registries
│   ├── Tau.Tools.Registry
│   ├── Tau.Hooks.Registry
│   ├── Tau.Commands.Registry
│   ├── Tau.Skills.Registry
│   └── Tau.Sessions.Registry
├── Tau.PubSub                      (Phoenix.PubSub)
├── Tau.Providers.Finch
├── Tau.Tools.TaskSupervisor
├── Tau.Extensions.Loader
├── Tau.MCP.Supervisor
│   ├── Tau.MCP.Manager
│   └── Tau.MCP.ServerSupervisor
└── Tau.Sessions.Supervisor
    └── Tau.Session                 (:gen_statem, one per active session)
```

## Extending

Five behaviours cover every extensibility seam:

| Behaviour                  | Purpose                                       |
|----------------------------|-----------------------------------------------|
| `Tau.Tool`                 | Model-callable capability (e.g. `Read`, `Bash`) |
| `Tau.Provider`             | LLM backend (Anthropic, OpenAI, Gemini, Bedrock) |
| `Tau.Hook`                 | Blocking lifecycle hooks (pre/post tool, session start, etc.) |
| `Tau.Permissions.Matcher`  | Custom rule matchers (glob, path prefix, regex, ...) |
| `Tau.Persistence`          | Session storage (default: JSONL) |
| `Tau.MCP.Transport`        | MCP wire protocol (stdio, SSE, HTTP) |
| `Tau.Compactor`            | Context compaction strategy |
| `Tau.Extension`            | Bundles tools/hooks/commands/skills together |

See `lib/tau/*.ex` and the `priv/livebooks/` walkthroughs.

## License

Apache-2.0. See `LICENSE`.
