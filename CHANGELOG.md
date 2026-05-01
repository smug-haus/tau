# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
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
