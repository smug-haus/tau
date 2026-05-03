# Tau — project overview

## What this is

Tau is an OTP/BEAM agentic coding harness — a from-scratch reimagining of
the Pi harness ([`badlogic/pi-mono`](https://github.com/badlogic/pi-mono),
TypeScript) using Elixir idioms. Pi is minimal and opinionated; Tau is
deliberately broader (full MCP, four providers, TUI + CLI + library) but
holds the same line on transparency: no magic, no closed-box behaviour,
the loop is small enough to read in an afternoon.

## Milestone status

The current pre-alpha implements **M0** — supervision tree boots clean,
public API surface declared as `{:error, :not_implemented}` stubs. Real
behaviour lands across **M1 — M8**. GitHub milestones are the
plan-of-record: each milestone's description holds the milestone plan;
issues are filed against the milestone and surface on the `Tau`
project board.

## Layout

```
lib/tau.ex                              — public API (delegates to Tau.Session)
lib/tau/application.ex                  — supervision tree
lib/tau/registries.ex                   — Registry container
lib/tau/session.ex                      — :gen_statem (the loop)
lib/tau/message/assembler.ex            — pure event-to-message folding
lib/tau/provider.ex                     — behaviour
lib/tau/providers/{anthropic,gemini,bedrock,openai}.ex
lib/tau/tool.ex                         — behaviour
lib/tau/tools/builtin/{read,write,edit,bash}.ex
lib/tau/permissions/{rule_set,evaluator,matchers}.ex
lib/tau/hook.ex                         — behaviour
lib/tau/persistence.ex                  — behaviour (default: jsonl)
lib/tau/compactor.ex                    — behaviour
lib/tau/mcp/{server,manager,tool_adapter}.ex
lib/tau/mcp/transport/{stdio,sse,http}.ex
lib/tau/extension.ex + extension/dsl.ex — extension DSL
lib/tau/cli.ex + tui/                   — escript + Ratatouille TUI
```

## Pointers

- **GitHub issues** — the live backlog (`is:open` for active work).
- **GitHub milestones** — `M0`–`M8` plus named refactors; description
  holds the milestone plan.
- **GitHub `Tau` project board** — Todo / In Progress / In Review / Done
  across milestones.
- **`docs/adr/`** — architectural decisions (start with
  `docs/adr/README.md`).
- `priv/livebooks/` — walkthroughs that double as smoke tests.
- `/root/.claude/plans/` — host-specific path used historically for
  milestone-scale plans. Prefer **GitHub milestones** as plan-of-record
  going forward.
- [`badlogic/pi-mono`](https://github.com/badlogic/pi-mono) — reference
  implementation we ported from.
- [hexdocs Erlang/Elixir stdlib](https://hexdocs.pm/elixir/) —
  `:gen_statem`, `Registry`, `Task.Supervisor`, `:persistent_term`.

## Architecture & token budget

The `claude-harness` template's stated baseline is **~1,150 t**: ~450 t
in `CLAUDE.md`, ~300 t in always-loaded rules, ~400 t in skill
description metadata across 4 vendored skills. Tau ships **~1,600 t
total** — about 450 t over baseline.

Breakdown of the overshoot:

- **Four extra Tau-specific skills** (`tau-toolchain`,
  `tau-architecture`, `tau-github-workflow`, `tau-adr`) at ~100 t of
  description metadata each ⇒ ~+400 t.
- **Slightly heavier OTP rules file** vs the harness's generic rules ⇒
  ~+50 t.

The overshoot is justified: Tau's domain — OTP correctness, Erlang/Elixir
toolchain quirks, GitHub-native workflow, ADRs — is genuinely
discriminative. Skill descriptions are short enough that the router can
match on them without loading the body, so the metadata cost buys
disclosure.

**Audit point:** revisit after the four Tau skills have been used in
earnest. If a skill is rarely loaded, fold it into another (or into a
rule); if its description is over-broad, tighten the trigger language.
