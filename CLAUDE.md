# CLAUDE.md — bootstrap for Claude Code sessions in this repo

This file orients Claude Code (and other Anthropic-compatible coding agents)
to the Tau codebase. **Read it fully before making non-trivial changes.**

The same content, with Tau-flavoured imports, lives at `TAU.md` so that Tau
itself can dogfood its memory cascade.

@TAU.md

---

## What this is

Tau is an OTP/BEAM agentic coding harness — a from-scratch reimagining of
the Pi harness ([`badlogic/pi-mono`](https://github.com/badlogic/pi-mono),
TypeScript) using Elixir idioms. Pi is minimal and opinionated; Tau is
deliberately broader (full MCP, four providers, TUI + CLI + library) but
holds the same line on transparency: no magic, no closed-box behaviour,
the loop is small enough to read in an afternoon.

The current pre-alpha implements **M0** — supervision tree boots clean,
public API surface declared as `{:error, :not_implemented}` stubs. Real
behaviour lands in subsequent milestones (M1 — M8). See `CHANGELOG.md`
and the plan at `/root/.claude/plans/`.

## Non-negotiables

These are not style preferences; they are correctness invariants. **Do not
violate them without an explicit, written justification in the PR description.**

1. **Every stateful subsystem is a process under a supervisor.**
   No module-level mutable state. No `:ets` tables outside a process that
   owns them. No `Application.put_env/3` for runtime state.

2. **Every extensibility seam is a behaviour.**
   No abstract base classes, no inheritance simulation, no string-keyed
   dispatch tables. Pattern match on atoms and structs.

3. **No GenServer that wraps stateless logic just to "own" it.**
   If it has no state, it's a module of pure functions.

4. **Cross-process events use `Phoenix.PubSub` topics or monitored refs.**
   Never `Process.whereis/1 |> send(...)`. Never `:global`.

5. **Telemetry events for everything user-visible or perf-sensitive.**
   `:telemetry.execute/3`, `[:tau, ...]` namespace. Pair `*.start` with
   `*.stop` (and `*.exception`) for span semantics.

6. **Properties before examples for invariant-bearing modules.**
   `Permissions.Evaluator`, `Settings.Loader` merge, `Message.Assembler`,
   permission matchers — all property-tested with `StreamData`. Examples
   come second, as illustrations.

7. **Let it crash; supervise; restart.**
   Don't `try/rescue` across process boundaries. Don't catch `:exit`. Trust
   the supervisor.

8. **Pure functions are the default; processes are the exception.**
   When in doubt, write a module with `@spec`s and unit tests. Reach for a
   process only when you need state, isolation, concurrency, or lifecycle.

## Project layout

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

Behaviours are the entry points to understand the system. Read them in this
order: `Tau.Tool` → `Tau.Provider` → `Tau.Hook` → `Tau.Persistence` →
`Tau.MCP.Transport` → `Tau.Compactor` → `Tau.Extension`.

## Common workflows

```sh
mix deps.get
mix compile                        # must be warning-free
mix format --check-formatted       # CI gate
mix credo --strict                 # CI gate
mix dialyzer                       # CI gate
mix test                           # ExUnit
mix test --only property           # property suite (longer budget)
mix tau.hello                      # one-shot smoke test against a provider
mix escript.build && ./tau         # local TUI run
iex -S mix                         # REPL: Tau.start_session/1 etc.
```

## What NOT to do

- **Do not** introduce a "Manager" or "Service" GenServer to "own" shared
  state for convenience. Push state into `:persistent_term` / ETS, or split
  into per-entity processes (one per session, one per MCP server, etc.).
- **Do not** replace `:gen_statem` with a hand-rolled `receive` loop.
- **Do not** add an HTTP client besides Finch / Mint.
- **Do not** add a JSON library besides Jason (revisit stdlib `JSON`
  separately if needed).
- **Do not** `IO.puts/1` for logging. Use telemetry or `Logger`.
- **Do not** invent a new event format mid-loop. Extend `Tau.Provider.Event`.
- **Do not** swallow errors. Errors flow as tagged tuples or as
  `%Tau.Provider.Event.Error{}` items in streams. Never raise on user input.
- **Do not** check shell output via screen scraping in `Bash` tool callers.
  Tools return structured `details` for that.

## When to use sub-agents

- `Explore` for read-only codebase queries that span multiple files. Don't
  spawn it for a single file you already know the path to.
- `Plan` for anything that touches a behaviour contract or the supervision
  tree. Talk to it before making the change, not after.
- `general-purpose` for end-to-end tasks that include both research and
  edits.
- Don't spawn an agent for a single-file rename or a comment fix.

## Style

- Apache-2.0 (see `LICENSE`).
- `mix format` enforced; line length 100 (see `.formatter.exs`).
- Credo strict mode; see `.credo.exs` for the few relaxations.
- `@moduledoc` on every public module; `@spec` on every public function.
- Comments only when documenting a non-obvious invariant. Don't paraphrase
  the code.
- Function names are verbs; module names are nouns; behaviours are nouns
  describing the role (`Tau.Tool`, not `Tau.IExecuteTools`).

## Where to find more

- `/root/.claude/plans/` — full implementation plan, milestones M0 — M8.
- `priv/livebooks/` — walkthroughs that double as smoke tests.
- `https://github.com/badlogic/pi-mono` — reference implementation we ported from.
- `https://hexdocs.pm/elixir/` — stdlib docs (`:gen_statem`, `Registry`,
  `Task.Supervisor`, `:persistent_term`).
