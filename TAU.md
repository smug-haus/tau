# tau — runtime memory mirror

This file is the canonical project memory loaded by Tau's own memory cascade
when running inside this repo. It mirrors `CLAUDE.md` (which `@import`s it),
so both Claude Code and Tau read the same `.claude/rules/` and
`.claude/skills/` overlay.

## Project Context

**Stack:** Elixir 1.18.1 / Erlang OTP 27.2 (`.tool-versions`).
**Test:** `mix test` (property: `mix test --only property`).
**Key dirs:** `lib/tau/`, `test/`, `priv/`.

## OTP non-negotiables (quick reference)

Full prose: `.claude/rules/otp-non-negotiables.md`.

1. Every stateful subsystem is a process under a supervisor.
2. Every extensibility seam is a behaviour; pattern match on atoms and structs.
3. No GenServer wrapping stateless logic.
4. Cross-process events use `Phoenix.PubSub` or monitored refs (never `:global`).
5. Telemetry events for everything user-visible or perf-sensitive.
6. Properties before examples for invariant-bearing modules.
7. Let it crash; supervise; restart. No `try/rescue` across process boundaries.
8. Pure functions are the default; processes are the exception.

## Pointers

- `CLAUDE.md` and `.claude/skills/` — coordinator config and on-demand skills.
- `docs/adr/README.md` — ADR conventions and index.
- `docs/PROJECT.md` — project overview and repo layout.
- `docs/MISSION.md` — mission statement and pointers to systems of record for state.
