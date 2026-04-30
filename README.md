# Tau

> An OTP/BEAM agentic coding harness — configurable, flexible, extensible.

Tau is a from-scratch reimagining of the [Pi harness][pi] (`badlogic/pi-mono`,
TypeScript) built around Elixir/OTP idioms. It runs on the BEAM and ships as
a Hex library, an escript, and a self-contained binary (via Burrito).

[pi]: https://github.com/badlogic/pi-mono

## Status

**Pre-alpha — first compile-passing cut of M0–M8.**

Done:

- Supervision tree (M0)
- `Tau.Provider` behaviour, Anthropic streaming, OpenAI (Chat + Responses),
  Gemini, Bedrock with SigV4 (M1, M7)
- Tools (Read/Write/Edit/Bash) and the `:gen_statem` session FSM with
  JSONL persistence and PubSub fanout (M2)
- Settings cascade, permissions evaluator + matchers, hooks dispatcher,
  TAU.md memory cascade (M3)
- MCP stdio + SSE + HTTP transports, dynamic ToolAdapter generation (M4)
- Extensions DSL, slash-command parser, skills with frontmatter (M5)
- Ratatouille TUI app, escript CLI with run/resume/sessions/doctor (M6)
- Burrito release wrapping for cross-platform binaries (M8)

Pending verification: full `mix test` on a real CI runner — the dev
sandbox blocks `mix deps.get` from reaching `repo.hex.pm` via Erlang's
httpc (curl works, Erlang doesn't). Verify on GitHub Actions per
`.github/workflows/ci.yml`.

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
├── Tau.PubSub                      (Phoenix.PubSub — ADR-0004: at the top)
├── Tau.Registries
│   ├── Tau.Tools.Registry
│   ├── Tau.Hooks.Registry
│   ├── Tau.Commands.Registry
│   ├── Tau.Skills.Registry         (extension-provided skills only — ADR-0005)
│   └── Tau.Sessions.Registry
├── Tau.Settings.Cache              (->:persistent_term)
├── Tau.Settings.Watcher            (file_system)
├── Tau.Permissions.RuleSet         (->:persistent_term, subscribes to "settings")
├── Tau.Providers.Finch
├── Tau.Tools.TaskSupervisor
├── Tau.Extensions.Loader
├── Tau.MCP.Supervisor
│   ├── Tau.MCP.Manager
│   └── Tau.MCP.ServerSupervisor
└── Tau.Sessions.Supervisor
    └── Tau.Session                 (:gen_statem, one per active session)
```

(`Tau.Memory.Cache` was removed in ADR-0006 until measurements
justify a per-session memory-file cache.)

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
