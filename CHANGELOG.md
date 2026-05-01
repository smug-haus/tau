# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `Tau.Command.command_spec/1` macro for declarative argument parsing
  on slash commands (positional `arg`, boolean `flag`, keyword `option`).
  Pre-parser tokenises the tail string and binds it to the spec before
  invoking `execute/2`. Missing/unknown args return tagged errors that
  surface to the model. Commands without a spec continue to receive the
  raw tail string (backwards-compatible). (Closes #15.)

### Tests
- Property suite: thinking-block signature byte-exact preservation audit
  (`test/tau/persistence/thinking_roundtrip_property_test.exs`). Pins
  Anthropic's signed-thinking contract — signatures must round-trip
  byte-for-byte through both the JSONL persistence write path
  (Replay session → `Tau.Session.message_to_data/1` →
  `Tau.Persistence.Jsonl` → `Jason.encode!`) and the read path
  (`File.stream!` → `Jason.decode!` → `Tau.Session.events_to_messages/1`
  via `Tau.fork/2`). Driven with `StreamData` over the base64 alphabet
  and printable-Unicode signatures, with explicit edge-case anchors
  (whitespace, newlines, non-ASCII, empty). (Closes #68.)

### Fixed
- TUI: `Tau.TUI.App.update/2` now handles
  `%Tau.Session.Events.Cancelled{}` and
  `%Tau.Session.Events.SessionEnd{}`. Previously both fell through to
  the catch-all clause, so pressing ESC produced no UI feedback and a
  terminating session left the status bar reading `streaming`. Status
  is stringified before storage so the existing `to_string/1` call in
  the status bar continues to work. (Closes #26.)

### Changed
- `:accept_edits` permissions mode is now argument-aware for Bash:
  destructive commands (`rm -rf`, `sudo`, `dd`, `mkfs`, `shred`, fork
  bombs, raw disk writes) deny; non-destructive commands auto-allow.
  Other tools under `:accept_edits` retain `:ask` semantics. New
  pure helper `Tau.Permissions.Heuristics.destructive_bash?/1`.
  (Closes #22.)
- `Tau.Session` now dispatches a turn's parallel tool calls through a
  single `Task.Supervisor.async_stream_nolink/4` iterator under
  `Tau.Tools.TaskSupervisor` instead of one `async_nolink/2` Task per
  call plus an ad-hoc `spawn_link` watcher. Honours
  `max_concurrency: System.schedulers_online()` and `on_timeout: :kill_task`;
  the `:tool_done` mailbox-message contract is unchanged. Tool worker
  exits (`{:exit, _}` from the stream) still synthesise an
  `is_error: true` `ToolResult` so the FSM never loses a
  `tool_call → tool_result` correspondence. (Closes #33.)

### Added
- `Tau.start_session(tools_whitelist: ["Read", "Grep"])` restricts a
  session's tools at spawn time. The whitelist filter applies before
  the permissions evaluator; missing tools synthesise an `is_error`
  ToolResult the same way deny rules do. `:all` (default) preserves
  current behaviour. Surfaced via `Tau.snapshot/1`. New telemetry:
  `[:tau, :session, :tool_whitelisted]`. Foundation for ADR-0014
  subagent personas. (Refs #18, closes #91.)
- Model-invokable skills: the model can activate a discovered skill
  by emitting a tool_call to the synthetic `__activate_skill__` tool.
  Skills with `disable_model_invocation: true` are excluded from the
  exposed list; their bodies are still injected as system messages
  (background context). New PubSub event:
  `%Tau.Session.Events.SkillActivated{}`. New telemetry:
  `[:tau, :session, :skill_activated]`. New JSONL event kind:
  `skill_activated`. Builds on #16 (PR #94) and ADR-0013. (Closes #17.)
- Skill `allowed-tools` whitelist enforcement: when `data.active_skill` is
  set, the permissions evaluator denies any tool not listed in
  `active_skill.allowed_tools` before consulting the regular rule set.
  Skill activation lives on the session FSM and clears on `:end_turn` or
  `:cancel`. See ADR-0013. (Closes #16.)
- Provider fallback chains — sessions retry against the next provider
  in `settings.providers.fallback_chains[primary]` on a retryable
  `%Event.Error{}` mid-stream. Transcript is content-transformed for
  the target provider via `Tau.Providers.Shared.ContentTransform`
  (thinking stripped, images placeholdered for non-vision targets,
  `cache_control` removed for non-caching targets). Per-message
  semantics: the next user turn starts against the primary provider.
  New telemetry: `[:tau, :provider, :fallback]`. New PubSub event:
  `%Tau.Session.Events.ProviderFallback{}`. New settings key:
  `providers.fallback_chains`. See ADR-0012. (Refs #19, closes #41.)
- Per-provider token-bucket rate limiter — one `Tau.Providers.RateLimiter`
  GenServer per configured provider, supervised by
  `Tau.Providers.RateLimiter.Supervisor`. Provider `stream/3` calls now
  acquire a permit before sending; 429 responses halve the bucket; settings
  reload re-sizes buckets without restart. New telemetry:
  `[:tau, :provider, :rate_limit, :acquired | :throttled | :rejected | :halved]`.
  See ADR-0011. (Refs #19, closes #39.)
- `Tau.Providers.Shared.ToolSpec.adapt/2` — pure cross-provider tool-schema
  normaliser. Each provider's `build_body` now hands its tools list through
  `adapt/2` so callers pass `Tau.Tool` modules or raw normalised maps and the
  helper produces the provider-native shape. Gemini's reduced JSON-Schema
  subset is handled by a dedicated down-shifter; lossy transforms log a
  warning once. (Refs #19, closes #37.)
- `Tau.Cost` / `Tau.Cost.Tracker` — per-provider token aggregation. The
  tracker is a lifecycle anchor for the `:tau_cost_counters` ETS table
  and a telemetry handler on `[:tau, :provider, :request, :stop]`;
  writers `:ets.update_counter/3` directly, readers
  (`Tau.Cost.summary/1`, `Tau.Cost.for_session/1`) do table scans —
  no GenServer mailbox in the hot path. `Tau.Session` emits the stop
  event after every assistant turn. Token counts only; dollar pricing
  deferred to a follow-up. See ADR-0010. (Refs #19, closes #40.)
- `Tau.Provider.chat/4` — provider-agnostic non-streaming entry point
  that drains `stream/3` through `Tau.Message.Assembler` and returns
  the assembled `%Assistant{}`. Provider modules can override via the
  optional `@callback chat/3` for native non-SSE endpoints. (Refs #19,
  closes #36.)
- `Tau.update_provider/2` — reconfigure a live session's provider,
  model, or `provider_ctx` without restart. The change applies on
  the next provider call; in-flight streams keep using the previous
  provider. Persisted as a `"reconfigure"` JSONL event; new
  telemetry `[:tau, :session, :reconfigure]`. (Refs #19, closes
  #38.)

## [0.1.0] — 2026-05-01

### Added (milestones M0 — M8)

- **M0** — Mix scaffold, supervision tree, telemetry handlers, settings &
  permissions caches publishing to `:persistent_term`, registry container,
  CLAUDE.md + TAU.md, Apache-2.0 license, CI/CD workflows.
- **M1** — `Tau.Provider` + `Tau.Provider.Event` + `Tau.Message.{User,Assistant,ToolResult}`
  + `Tau.Providers.Anthropic` (Messages API streaming) + shared SSE parser
  + cross-provider id sanitizer + `mix tau.hello` smoke task.
- **M2** — `Tau.Tool` + four built-ins (Read/Write/Edit/Bash), pluggable
  `Tau.Tools.Operations.Local`, JSONL persistence with ULID events,
  `Tau.Message.Assembler`, the real `Tau.Session` `:gen_statem`,
  `Tau.Session.Events` for PubSub broadcasting.
- **M3** — settings cascade loader (managed/user/project/local) with
  watcher reload, permission rule compilation + evaluation, hook
  behaviour + dispatcher + shell-hook generator, TAU.md memory cascade
  with @import resolution.
- **M4** — MCP transports (stdio with `{:line, _}` framing, HTTP via
  Finch, SSE via Mint+shared SSE parser), `Tau.MCP.Server` GenServer,
  `Tau.MCP.ToolAdapter` runtime module generation, manager with
  reconciliation against settings.
- **M5** — `Tau.Extension` behaviour + DSL, `Tau.Extensions.Loader` with
  hot-reload hooks, slash command parser, skills with YAML frontmatter
  parser.
- **M6** — Ratatouille TUI MVU app subscribing to session PubSub topics,
  Optimus-based escript CLI (run/resume/sessions/version/doctor/tui),
  bundled default system prompt under 1k tokens.
- **M7** — OpenAI Chat (with widened OpenAI-compatible coverage),
  OpenAI Responses (with reasoning effort), Gemini
  (streamGenerateContent SSE), AWS Bedrock with full SigV4 signing
  and the AWS event-stream binary framing parser.
- **M8** — Burrito release-step wrapping for macOS/Linux/Windows x86_64
  & arm64, devcontainer (Elixir 1.18.1 / OTP 27.2), bundled example
  skill, intro Livebook, README and CHANGELOG polish, replay-provider
  for offline tests.

### Changed
- Repo wiped of unrelated Clojure AoC2020 content.

### Fixed
- Session FSM: `{:user_message, _}` casts that arrive while the session
  is mid-turn (`:provider_streaming` / `:tool_executing`) are now
  postponed via `:gen_statem`'s built-in `:postpone` action and
  re-delivered on return to `:awaiting_user`, preserving cast order
  and preventing interleaving with the active provider stream or
  tool execution. New telemetry:
  `[:tau, :session, :user_message, :enqueued | :delivered]`. See
  ADR-0009. (Closes #64.)

### Notes
- Local toolchain in the dev sandbox is Elixir 1.17.3 / OTP 25.3.
  `mix format --check-formatted` is clean across all 80+ files.
  Full compile and test runs in CI on Elixir 1.18.1 / OTP 27.2.

### Notes
- Implementation milestones M1 — M8 are tracked in
  `/root/.claude/plans/clear-out-this-repo-fluffy-hamming.md`.
- Local toolchain: Erlang/OTP 25.3 (Ubuntu apt) + Elixir 1.17.3
  (precompiled OTP-25 build from elixir-lang releases). `mix deps.get`
  is blocked in the development sandbox (proxy interferes with Erlang
  httpc to `repo.hex.pm`); `mix format --check-formatted` and
  syntax-checks all pass locally. Full compile + tests will run on
  GitHub Actions.
