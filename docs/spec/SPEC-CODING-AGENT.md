# SPEC: Coding-Agent Adapter

| | |
|---|---|
| **Status** | Approved (Phase 1A landed; Phase 1B/Phase 2 implementation pending). |
| **Date** | 2026-05-15 |
| **Scope** | A behaviour-shaped adapter that lets tau drive external coding assistants (Claude Code, Aider, Codex CLI, Gemini CLI, …) as sub-agents over a subprocess + structured-event transport. |
| **Method** | PSDH (`.claude/skills/design-reasoning`); L0 + boundary contracts. L2 deferred until first impl lands. |
| **Disposition** | **Additional, optional** feature. Does NOT replace `Tau.Provider`. Users who run tau with an API key are unaffected. |
| **Tracking issue** | #191 |

## 0. Why this spec exists

Sonnet/Opus via Anthropic API costs per-turn. A Claude Max plan sits idle
unless used through Claude Code. The same gap exists for GitHub Copilot
(included in the user's IDE subscription) and Aider-with-Claude. The
user's stated goal: leverage **the existing subscription** by delegating
work to its CLI front-end instead of paying for raw API tokens.

This spec defines a generalized adapter so tau can drive **any**
CLI-driven coding assistant. It is not a rearchitecture: today's
provider path (`Tau.Provider`) remains the default. The coding-agent
path is a new, parallel surface.

The spec sits in M4 (Sub-agents & coordination) on the basis that the
adapter is structurally a "sub-agent dispatcher whose worker happens to
live in a child OS process rather than a BEAM process."

## 1. Triage

| # | Property | Score | Evidence |
|---|----------|-------|----------|
| 1 | Shared mutable state | 1 | session ↔ subprocess ↔ workspace files concurrent with editor |
| 2 | Temporal coupling | 1 | subprocess start order, MCP-server handshake before first turn, cancel propagation |
| 3 | Cross-process coordination | 1 | BEAM ↔ Port ↔ OS subprocess ↔ optional MCP sub-servers ↔ file system |
| 4 | Feedback loops | 0 | one-shot prompt → response; no closed feedback loop within a turn |
| 5 | State accumulation | 1 | workspace edits accumulate; agent-session resume state outside tau's persistence |

**Triage score: 4/5. L0 + boundary contracts required.**

## 2. Component decomposition

| # | Boundary | Operation |
|---|----------|-----------|
| B1 | `Tau.Session` (or `Tau.Tools.Builtin.Delegate`) ↔ `Tau.CodingAgent` dispatcher | task submission, cancel, status |
| B2 | dispatcher ↔ subprocess (`Port`) | argv assembly, stdin write, stdout/stderr read, exit-status capture |
| B3 | subprocess ↔ workspace files | edits the user's cwd (or a worktree) |
| B4 | subprocess ↔ optional tau-context MCP server | session memory queries, permission checks, sub-agent dispatch |
| B5 | dispatcher ↔ telemetry / PubSub | normalized event broadcast for TUI/audit |
| B6 | dispatcher ↔ host user config (`~/.claude/`, `~/.config/aider/`, …) | credentials inherited; tau does **not** manage them |

## 3. L0 — constraints by question

Format: `[Cn-Bm]` = constraint number + boundary. **★** marks non-obvious.

### Q1: What can be written by more than one actor?

- **★ [C1-B3]** Coding agent edits files in cwd; user's editor (VS Code, Emacs) may have the same files open. No file-lock coordination between tau, the agent, and the editor. Mitigation: warn user; recommend save-before-delegate.
- **[C2-B3]** Two concurrent `Delegate` tool calls in the same session writing the same file race at the OS level. Mitigation: serialize at dispatcher granularity per workspace path; or require non-overlapping cwd subtrees.

### Q2: What ordering assumptions are implicit?

- **★ [C3-B2]** Stream-json events from Claude Code arrive in monotonically increasing turn order, but tool_use_start / tool_use_result pairs may interleave across tools. Normalizer MUST handle interleaving by event id, not by arrival order.
- **[C4-B2]** Subprocess `exit_status` may arrive before all stdout lines are drained (Port semantics with `:line` packetization). Dispatcher MUST drain remaining stdout before emitting `:done`.
- **★ [C5-B4]** If the optional `tau-context` MCP server is enabled, it MUST be reachable BEFORE the agent invokes its first MCP tool. Dispatcher MUST start the server, get its address, and pass it via `--mcp-config` before `start/2` returns.

### Q3: What happens if a component fails silently?

- **★ [C6-B2]** Subprocess writes garbage to stdout (e.g. mixed stream-json with rogue prints). Normalizer MUST emit `%Event.Error{}` on parse failure and continue draining; MUST NOT crash the dispatcher.
- **[C7-B2]** Subprocess hangs (no output, no exit). Dispatcher MUST enforce an inactivity timeout (configurable, default 120s) and SIGTERM the subprocess on timeout.
- **★ [C8-B6]** Host config dir absent / corrupted (e.g. expired Claude Code OAuth). Subprocess fails immediately with auth error. Adapter MUST surface a user-actionable message ("run `claude /login`") in the `%Event.Error{}` reason.

### Q4: What invariants must hold across restarts?

- **[C9-B1]** Cancelling a session MUST cancel its running coding-agent subprocess within the standard 250ms grace then SIGKILL.
- **[C10-B2]** Session crash MUST NOT leave zombie subprocesses. Port linking + trap_exit at dispatcher level.

### Q5: What's the contract surface visible to extensions?

- **[C11-B1]** `Tau.CodingAgent` is a behaviour. Custom adapters can be loaded via the same mechanism as MCP transports or providers (settings + module discovery).

### Q6: What's the user-visible failure surface?

- **★ [C12-B5]** All adapter errors MUST reach the TUI transcript. The pre-D-009 pattern (silent empty content) MUST NOT recur. Tests assert visible surface for: auth failure, subprocess-not-found, timeout, parse error, non-zero exit.

### Q7: What does cost look like?

- **[C13-B2]** Most coding agents emit their own usage (Claude Code stream-json `result` event has cost_usd, duration_ms, tokens). Adapter MUST surface these as a `%Event.Cost{}` so tau's session-cost aggregator can include them — separately tagged from provider-direct cost so the user sees the split.

### Q8: What's NOT in scope?

- IDE-native agents (Cursor, Cline) that are editor-bound, not CLI-driven.
- Mid-turn agent migration (start with Claude Code, finish with Aider).
- A single turn that simultaneously uses a provider AND a coding agent.
- Forcing the coding agent to use tau's Read/Edit/Bash tools (see §7 Q1 — currently rejected, may revisit).

## 4. Proposed boundary contracts

These contracts are **proposed**; treat as targets for the design-review
pass that converts this draft into Status: Approved.

### B1 — dispatcher API

```elixir
@behaviour Tau.CodingAgent

@callback start(task, ctx) :: {:ok, Enumerable.t()} | {:error, term()}
@callback cancel(handle :: term()) :: :ok
@callback capabilities() :: %{
            streaming: boolean(),
            tool_restriction: boolean(),
            mcp_client: boolean(),
            session_resume: boolean(),
            cost_reporting: boolean(),
            workspace_isolation: :cwd | :worktree | :either
          }
@callback configure(map()) :: {:ok, map()} | {:error, term()}

@type task :: %{
        prompt: String.t(),
        workspace: Path.t(),
        session_id: String.t(),
        resume_id: String.t() | nil,
        allowed_tools: [String.t()] | :all,
        mcp_servers: [map()],
        timeout: pos_integer() | :infinity
      }
```

The returned Enumerable emits `Tau.CodingAgent.Event` structs:

```
Start{agent: atom, version: String.t(), pid: pid()}
AssistantText{text: String.t(), turn: integer()}
ToolUse{id: String.t(), name: String.t(), input: map()}
ToolResult{tool_use_id: String.t(), content: String.t(), is_error: bool}
FileEdit{path: String.t(), kind: :create | :modify | :delete}
Cost{tokens: map(), usd: float() | nil, duration_ms: integer()}
Error{reason: term(), recoverable: bool}
Done{exit_status: integer(), final_message: String.t() | nil}
```

### B2 — subprocess transport

- Port-based: `Port.open({:spawn_executable, exec}, [:binary, :exit_status, :stderr_to_stdout, args: argv, line: 8192])`.
- Each agent module declares its argv builder.
- Cancellation: write nothing further to stdin, send SIGTERM, await 250ms, SIGKILL.
- Linked to dispatcher; dispatcher trap_exit, surfaces unexpected death as `Event.Error`.

### B3 — workspace

- **Default: per-task git worktree** (safer; protects the user's working tree from concurrent agent edits).
- Opt-in: dispatcher's cwd via an explicit `--cwd` flag on the Delegate tool / session mode. The user-facing wording is "run in my current directory" so the trade-off is visible.
- Adapter MUST validate the workspace exists and is a directory before spawn.
- D-033 stands regardless: the path is **always** explicit in `task.workspace`; the dispatcher MUST NOT silently inherit tau's cwd. Worktree creation is the caller's responsibility (Phase 1B Team B); this contract just enforces the boundary.

### B4 — `tau-context` MCP server

- A small MCP server tau spawns alongside the coding-agent subprocess.
- Exposes (subset):
  - `tau_memory_query(query)` — read session memory
  - `tau_memory_write(kind, key, body)` — write to memory (subject to permissions)
  - `tau_session_status()` — current session metadata
  - `tau_delegate(prompt, agent)` — recursive delegation (with depth limit)
- The coding-agent's own Read/Edit/Bash are **not** replaced. Tau-context is supplementary, not substitutionary.
- **Enabled by default.** Disable via `coding_agent.expose_tau_context = false` in settings. Rationale: the tau-context surface is the only way audit/permissions/memory cross the BEAM⇄subprocess boundary; making it opt-in turned out to mean "almost never on", which defeats the point.

### B5 — telemetry

- `[:tau, :coding_agent, :start]` with `%{agent, model, workspace}`
- `[:tau, :coding_agent, :event]` per emitted Event (sampled if high-volume)
- `[:tau, :coding_agent, :stop]` with `%{duration_ms, exit_status, events_count}`
- `[:tau, :coding_agent, :exception]` on unexpected dispatcher crash

### B6 — credentials

- Subprocess inherits the host user's env and config dir.
- Tau MUST NOT read or copy `~/.claude/credentials.json` (or equivalent).
- Tau MAY check existence and surface a "not configured" error if absent.

## 5. Acceptance criteria

- **AC-1** — behaviour defined with `ClaudeCode` and `Replay` implementations; both pass a shared contract test.
- **AC-2** — `tau --coding-agent claude_code` invokes a real `claude` subprocess for a one-turn round-trip; transcript renders the assistant response; ESC cancels cleanly.
- **AC-3** — `Tau.Tools.Builtin.Delegate` callable from a provider conversation; tool_use → coding-agent run → tool_result fold-back works end-to-end.
- **AC-4** — telemetry events emitted in the documented pattern; verified by test attaching a handler.
- **AC-5** — kill-the-BEAM property test: 50 random session-cancel timings against a Replay adapter leave zero zombie subprocesses.
- **AC-6** — auth-failure surface test: `~/.claude/credentials.json` removed; the user-visible error is `"Claude Code not authenticated — run 'claude /login'"` (or equivalent), not an opaque stack trace.

## 6. Runtime invariants

| ID | Invariant |
|---|---|
| **D-031** | The dispatcher MUST emit a normalized `Tau.CodingAgent.Event` stream regardless of adapter backend. Adapters MUST translate; the FSM/TUI/audit code MUST NOT switch on agent type. |
| **D-032** | Subprocess lifecycle MUST be bound to the session lifecycle. Session crash, ESC cancel, or shutdown MUST result in subprocess termination (SIGTERM → 250ms grace → SIGKILL). No exceptions. |
| **D-033** | Workspace boundary MUST be explicit at task-submission time. The dispatcher MUST NOT silently inherit tau's cwd; the task struct carries the workspace path. |
| **D-034** | Telemetry parity with `Tau.Provider`. Start/event/stop/exception in the documented shape. |
| **D-035** | Adapter failures surface in-stream as `%CodingAgent.Event.Error{}` events. Adapters MUST NOT raise for transport, auth, or parse errors. Hard configuration errors (no executable on PATH, malformed argv) may return synchronous `{:error, reason}` from `start/2`. |
| **D-036** | Auth boundary — tau MUST NOT inject or copy credentials. The subprocess inherits the host user's config dir. Tau MAY check existence and emit a user-actionable "not configured" error. |

## 7. Resolved design questions

### Q1 — Should the coding agent use tau's tools via MCP, or its native tools?

**Options considered**

| Option | Description | Pro | Con |
|---|---|---|---|
| **A** | Agent uses its native tools. Tau audits post-hoc via stream-json events + optional fs-events. | Preserves agent capability. Lower latency. Simpler. | Tau is not in the loop on every edit. Hooks/permissions don't apply to the agent's actions. |
| **B** | Tau exposes Read/Edit/Bash via an MCP server; agent is started with `--disallowed-tools` for its native ones and `--mcp-config` for tau's. | Unified audit, hooks, permissions. | Cripples Claude Code (loses multi-edit, plan mode, web-fetch). Higher latency. Likely brittle across agent versions. |
| **C** (hybrid) | Agent uses its native tools. Tau ALSO exposes a `tau-context` MCP server with session-memory + permission-query + recursive-delegate tools. Coding agent calls these in addition to its native set. | Best of both — agent keeps capability, tau gains a small audit/context window. | Tau-context becomes a permanent API surface that adapters must respect. |

**Resolved: Option C, with the tau-context MCP server enabled by default.** Setting becomes `coding_agent.expose_tau_context = false` to disable. Option B is explicitly rejected.

**Reasoning:** The user's stated goal is "use coding agents without API calls." Forcing tau's tools through MCP (B) works against that goal — it degrades the very agent we want to leverage. The earlier draft positioned C as opt-in; on reflection that meant "almost never on", and the audit/memory surface is the entire point of integrating at all. C as default makes the cross-boundary contract visible to every adapter.

### Q2 — Primary integration surface: tool or session mode?

**Options considered**

- **Tool** (`Tau.Tools.Builtin.Delegate`): provider-driven conversation can hand off subtasks. Composes with everything else (permissions, hooks, sub-agents).
- **Session mode** (`--coding-agent claude_code`): the TUI's "Send" goes directly to the coding agent. Tau becomes a thin shell over Claude Code.
- **Both** (independent).

**Resolved: both, but session mode first.** Session mode is the cleaner first user-facing slice and the simpler dispatcher consumer once Phase 1A's substrate exists; the Delegate tool follows in Phase 2. The earlier draft favoured Tool-first because of code-reuse with #32, but session-mode-first gives the user a working `tau --coding-agent` path the day Phase 1B Team B lands, without waiting on the provider conversation plumbing.

### Q3 — Workspace isolation

- Run in user's cwd (matches the current shell session, lets the user see edits in their editor).
- Run in a worktree (safer, but harder to view edits live).
- Configurable per task.

**Resolved: per-task with worktree as default.** `--cwd` is opt-in on the Delegate tool / session mode for the user who explicitly wants the agent to edit their working tree. Rationale: a concurrent editor session + an agent rewriting the same files is the most common destructive interaction surface flagged in §3 ([C1-B3] / [C2-B3]); making worktree the default takes that out of play unless the user asks for it.

### Q4 — Cost aggregation

Adapters that surface cost (Claude Code does; Aider doesn't reliably) emit `Event.Cost`. Tau's session-cost aggregator records these as a separate line item with adapter-tagged provenance (`coding_agent.claude_code` vs `provider.anthropic`) so the user sees the split.

**Resolved: yes; adapter-tagged line items, with an explicit "unknown" sentinel (`usd: nil`) when the adapter can't measure.** Aggregation lives in Phase 1B Team D.

### Q5 — Session resume

Claude Code supports `--resume <session-id>`. Should tau persist coding-agent session ids and offer resume across tau sessions?

**Resolved: yes for the session-mode surface; no for the Delegate tool surface.** Each tool call is its own discrete delegation; sharing resume state across tool calls re-introduces the temporal coupling §3 [C3-B2] / [C4-B2] worked hard to remove. Session-mode resume is the natural fit because the human is already in a conversational frame; persistence shape lands with Phase 1B Team D.

## 8. Out of scope (explicit)

- Cursor / Cline / other IDE-native agents.
- Forcing the coding agent to use tau's tools (Q1 option B).
- Mid-turn agent migration.
- Coding agent and provider concurrent in the same turn.

## Appendix A — source map

Phase 1A (this PR — landed):

```
lib/tau/coding_agent.ex                          # behaviour + run/4
lib/tau/coding_agent/event.ex                    # event structs
lib/tau/coding_agent/supervisor.ex               # DynamicSupervisor for dispatchers
lib/tau/coding_agent/dispatcher.ex               # lifecycle/cancel/telemetry GenServer
lib/tau/coding_agents/replay.ex                  # test fixture adapter
test/fixtures/coding_agent_replay_default.jsonl  # default Replay fixture
test/tau/coding_agent_test.exs                   # behaviour contract
test/tau/coding_agent/dispatcher_test.exs        # dispatcher contract
test/tau/coding_agent/telemetry_test.exs         # D-034 shape
test/tau/coding_agent/lifecycle_property_test.exs # AC-5 skeleton
```

Phase 1B / Phase 2 (planned):

```
lib/tau/coding_agents/claude_code.ex             # first real adapter (Team A)
lib/tau/cli.ex                                   # --coding-agent flag (Team B)
lib/tau/coding_agent/workspace.ex                # worktree creation (Team B)
lib/tau/mcp/servers/tau_context.ex               # tau-context MCP server (Team C)
lib/tau/cost.ex                                  # adapter-tagged line items (Team D)
lib/tau/tools/builtin/delegate.ex                # tool surface (Phase 2)
```

Total runtime invariants claimed by this spec: **D-031 through D-036** (6).

## Appendix B — non-goals discussion

- **Why not just "MCP all the way down"?** The MCP spec is tool-shaped, not agent-shaped. There is no MCP method `delegate_task(prompt)` that an MCP server can implement; you'd have to define a one-off tool and shoehorn agent semantics into it. Subprocess + stream-json is the actual interface coding agents expose for delegation today.
- **Why not in-BEAM sub-agents (#32) for this?** In-BEAM sub-agents use tau's provider stack, which is the very thing we're trying to bypass. Different goal.
- **Why not a Tau.Provider implementation that shells out to `claude -p`?** Considered. Rejected because the Provider contract is "produce assistant tokens + tool_use events"; the coding-agent contract is "do this whole task end-to-end, including any tool calls." Different abstraction level. Forcing a coding agent into the Provider mold loses signal.
