# TAU.md — bootstrap memory for Tau itself

This file is the canonical project memory loaded by Tau's own memory cascade
when running inside this repo. It mirrors `CLAUDE.md` (which `@import`s it),
so both Claude Code and Tau read the same source of truth.

## What this is

Tau is an OTP/BEAM agentic coding harness — a from-scratch reimagining of
the Pi harness ([`badlogic/pi-mono`](https://github.com/badlogic/pi-mono),
TypeScript) using Elixir idioms. The current pre-alpha implements **M0**:
supervision tree boots clean, public API surface declared as
`{:error, :not_implemented}` stubs.

## Non-negotiables (correctness invariants)

1. Every stateful subsystem is a process under a supervisor.
2. Every extensibility seam is a behaviour. Pattern match on atoms and structs.
3. No GenServer that wraps stateless logic.
4. Cross-process events use `Phoenix.PubSub` or monitored refs. Never `:global`.
5. Telemetry events for everything user-visible or perf-sensitive.
6. Properties before examples for invariant-bearing modules.
7. Let it crash; supervise; restart. Don't `try/rescue` across process
   boundaries.
8. Pure functions are the default; processes are the exception.

## Behaviours (read in this order)

`Tau.Tool` · `Tau.Provider` · `Tau.Hook` · `Tau.Permissions.Matcher` ·
`Tau.Persistence` · `Tau.MCP.Transport` · `Tau.Compactor` · `Tau.Extension`.

## Layout

```
lib/tau.ex                          — public API
lib/tau/application.ex              — supervision tree
lib/tau/session.ex                  — :gen_statem
lib/tau/provider.ex                 — behaviour
lib/tau/tool.ex                     — behaviour
lib/tau/tools/builtin/{read,write,edit,bash}.ex
lib/tau/providers/{anthropic,gemini,bedrock,openai}.ex
lib/tau/mcp/{server,manager}.ex     — MCP integration
lib/tau/extension.ex                — extension DSL host
```

## Common commands

```sh
mix deps.get && mix compile
mix test
mix test --only property
mix format --check-formatted && mix credo --strict && mix dialyzer
mix tau.hello                  # one-shot smoke test
mix escript.build && ./tau     # local TUI run
```

## Don'ts

- No "Manager"/"Service" GenServers for shared state convenience — split
  into per-entity processes or use `:persistent_term`/ETS.
- No hand-rolled `receive` loop where `:gen_statem` fits.
- No HTTP client besides Finch/Mint.
- No `IO.puts` for logging — use telemetry or `Logger`.
- No new event format mid-loop — extend `Tau.Provider.Event`.

## Pointers

- Plan: `/root/.claude/plans/clear-out-this-repo-fluffy-hamming.md`
- Reference: `https://github.com/badlogic/pi-mono`
- Erlang/Elixir stdlib: `:gen_statem`, `Registry`, `Task.Supervisor`,
  `:persistent_term`.
