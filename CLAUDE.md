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

## You are the coordinator

For this repo you operate as a **coordinator**, not a hands-on
implementer. Implement directly only when the task is small,
self-contained, and faster to do than to brief. For anything
non-trivial — multi-file changes, new behaviours, anything
crossing a subsystem boundary — you delegate to subagents and
integrate their results.

**Default to delegation.** If a task touches more than two files
or involves design choices, dispatch a subagent. If the task is
"go read X" or "rename Y in one file", do it yourself.

**Plan before you delegate.** For anything multi-step, dispatch
the `Plan` subagent first, hand its output to one or more
`general-purpose` subagents as their brief, and use yourself
only to integrate / merge / decide.

**Always isolate parallel work in worktrees.** When you dispatch
two or more subagents that may both edit files, **every** dispatch
MUST set `isolation: "worktree"` on the Agent tool call.
Subagents share the working tree by default; without isolation,
two parallel agents on different branches will clobber each
other's edits and `git checkout`s — branches end up at HEAD with
no commits, edits land on the wrong branch, and the working tree
is left half-applied. (This bit me once; don't repeat it.)

Worktree-isolated agents create their own branch and commit
there; on return they hand back the branch name + path. Pull /
merge from the parent worktree as the next step.

**Single-agent foreground work** (no parallel siblings) does not
need isolation — the parent and child can't race a single
working tree.

## When to use sub-agents

- `Explore` for read-only codebase queries that span multiple files. Don't
  spawn it for a single file you already know the path to.
- `Plan` for anything that touches a behaviour contract or the supervision
  tree. Talk to it before making the change, not after.
- `general-purpose` for end-to-end tasks that include both research and
  edits — these implementation agents almost always want
  `isolation: "worktree"` because in a coordinator session you
  often have several running at once.
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

## Workflow: GitHub issues are the backlog

Every feature, bug, polish item, and doc gap lives as a GitHub issue
on this repo. **Before writing code, file an issue (or find one) and
reference it.** Plans live in issue comments; PRs link back to issues;
commits close them.

1. **Triage on entry.** A new finding becomes an issue with:
   - title: `<type>: <one-liner>`, where `<type>` ∈ `bug | feature |
     polish | docs | chore | refactor | perf | test`,
   - labels: a GitHub-built-in (`bug` / `enhancement` / `documentation`)
     plus at least one `area:<subsystem>` label (see list below),
   - body: problem statement, reproducer or evidence, optional fix
     direction. No design discussion in PR descriptions — link to the
     issue.

2. **Plans start from issues.** When asked to implement something, the
   first step is to scan the relevant open issues
   (`mcp__github__list_issues` / `mcp__github__search_issues` for
   sub-agents, the GitHub web UI for humans). Any milestone-scale plan
   that lands in `/root/.claude/plans/` references issue numbers and
   identifies which commits close which issues.

3. **Commits and PRs reference issues.** Commit messages end with
   `Closes #N` (or `Refs #N` for partial work). PR descriptions enumerate
   every issue the PR closes so the auto-link populates.

4. **Area labels.** Use these consistently so filters like
   `is:open label:area:session` work:
   `area:session`, `area:cli`, `area:tui`, `area:tools`,
   `area:providers`, `area:mcp`, `area:skills`, `area:extensions`,
   `area:permissions`, `area:hooks`, `area:memory`, `area:settings`,
   `area:persistence`, `area:telemetry`, `area:ci`, `area:docs`,
   `area:onboarding`. (Until labels are pre-created in the repo, embed
   them as a `**Area:**` line in the issue body — issue search supports
   that too.)

5. **Sub-agent rules.** `Explore` and `Plan` subagents must consult
   issue state before proposing new design. If a finding doesn't have an
   issue yet, the subagent files one (or returns a "needs to be filed"
   line in its report so the parent agent files it).

6. **No backlog parking lots in code.** Avoid `# TODO` comments. If
   something needs to happen later, file the issue and reference its
   number from the source line: `# See #42`.

## Architectural decisions: ADRs in `docs/adr/`

The non-negotiables above tell you what's _forbidden_. ADRs in
`docs/adr/` tell you what was _chosen_, and why a future change
would need fresh justification. **Read the ADR index
(`docs/adr/README.md`) before proposing any change that touches the
supervision tree, a behaviour contract, a public struct's hidden
contract, or a layering decision the obvious refactor would
invert.**

When to file a new ADR:

- A behaviour callback you're tempted to add as `@optional_callbacks`
  (capture why some implementations can skip it).
- An OTP shape that looks redundant (a process where a function
  would do, a registry that's not strictly needed) — explain the
  reason or it'll get refactored away.
- A field on a public struct with a hidden contract
  (JSON-encodable values, namespaced keys, default semantics).
- A naming or layering choice that the obvious refactor would
  invert.

When _not_ to file an ADR:

- Anything covered explicitly by a non-negotiable (just follow the
  rule).
- Bug fixes that don't change architecture; polish; doc rewording.

Process: copy `docs/adr/0000-template.md` to the next number, fill
it in, link it from the PR description, and reference it in the
commit message ("ADR-0007"). See `docs/adr/README.md` for the
full conventions.

## Where to find more

- **GitHub issues** — the live backlog. `is:open` for active work.
- **`docs/adr/`** — architectural decisions (start with
  `docs/adr/README.md`).
- `/root/.claude/plans/` — milestone-scale plans (M0–M8 implementation
  plan, large refactors). Smaller decisions live in issue comments.
- `priv/livebooks/` — walkthroughs that double as smoke tests.
- `https://github.com/badlogic/pi-mono` — reference implementation we ported from.
- `https://hexdocs.pm/elixir/` — stdlib docs (`:gen_statem`, `Registry`,
  `Task.Supervisor`, `:persistent_term`).
