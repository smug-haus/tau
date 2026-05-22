# Tau — project overview

## What this is

Tau is an OTP/BEAM agentic coding harness — a from-scratch reimagining of
the Pi harness ([`badlogic/pi-mono`](https://github.com/badlogic/pi-mono),
TypeScript) using Elixir idioms. Pi is minimal and opinionated; Tau is
deliberately broader (full MCP, multiple providers, TUI + CLI + library)
but holds the same line on transparency: no magic, no closed-box
behaviour, the loop is small enough to read in an afternoon.

## Milestones and status

Milestone state lives on GitHub, not in this file. To check the current
state:

```sh
gh api 'repos/{owner}/{repo}/milestones?state=all' \
  --jq '.[] | "\(.state) | \(.title) — open:\(.open_issues) closed:\(.closed_issues)"'
```

Each milestone's description holds its plan; issues are filed against
the milestone and surface on the `Tau` project board. The mission
across milestones is `docs/MISSION.md`.

## Layout

The repo's `lib/` is the product; `web/lib/` is the optional dashboard
poncho. Conceptual structure:

```
lib/tau.ex                              — public API (delegates to Tau.Session)
lib/tau/application.ex                  — supervision tree
lib/tau/registries.ex                   — Registry container
lib/tau/session.ex                      — :gen_statem (the session loop)
lib/tau/message/                        — pure event-to-message folding
lib/tau/provider.ex                     — provider behaviour
lib/tau/providers/                      — provider adapters (one per LLM API)
lib/tau/tool.ex                         — tool behaviour
lib/tau/tools/builtin/                  — built-in tools
lib/tau/permissions/                    — permission rule sets + evaluator
lib/tau/hook.ex                         — hook behaviour
lib/tau/persistence.ex                  — persistence behaviour (default JSONL)
lib/tau/compactor.ex                    — compactor behaviour
lib/tau/mcp/                            — MCP transports + server adapter
lib/tau/extension.ex                    — extension DSL host
lib/tau/extensions/loader.ex            — runtime extension loader
lib/tau/cli.ex                          — escript entry + arg parsing
lib/tau/tui/                            — Ratatouille TUI
lib/mix/tasks/                          — mix tasks (release, qa, gates, etc.)
web/lib/tau_web/                        — Phoenix poncho (`:tau_web`)
```

For exact file inventories use `find lib web/lib -name '*.ex' | sort` —
do not maintain a list here (it rots).

## Pointers

- **GitHub issues** — the live backlog (`gh issue list`).
- **GitHub milestones** — the plan-of-record; each milestone's description
  holds its plan.
- **GitHub `Tau` project board** — Todo / In Progress / In Review / Done
  across milestones.
- **`docs/adr/`** — architectural decisions (start with `docs/adr/README.md`).
- **`docs/spec/`** — component contracts (start with `docs/adr/0023-documentation-taxonomy.md`'s catalog).
- **`docs/MISSION.md`** — mission and where state vs design lives.
- **`priv/livebooks/`** — walkthroughs that double as smoke tests.
- [`badlogic/pi-mono`](https://github.com/badlogic/pi-mono) — reference
  implementation we ported from.
- [hexdocs Erlang/Elixir stdlib](https://hexdocs.pm/elixir/) —
  `:gen_statem`, `Registry`, `Task.Supervisor`, `:persistent_term`.
