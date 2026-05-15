# SPEC: Coding-Agent Adapter

| | |
|---|---|
| **Status** | DRAFT — design review pending. Open questions in §7. |
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

- Default: dispatcher's cwd (the same cwd tau itself runs in).
- Optional: per-task worktree (requires git repo).
- Adapter MUST validate the workspace exists and is a directory before spawn.

### B4 — optional `tau-context` MCP server

- A small MCP server tau spawns alongside the coding-agent subprocess.
- Exposes (subset, opt-in per task):
  - `tau_memory_query(query)` — read session memory
  - `tau_memory_write(kind, key, body)` — write to memory (subject to permissions)
  - `tau_session_status()` — current session metadata
  - `tau_delegate(prompt, agent)` — recursive delegation (with depth limit)
- The coding-agent's own Read/Edit/Bash are **not** replaced. Tau-context is supplementary, not substitutionary.
- Disabled by default. Enable via `coding_agent.expose_tau_context = true` in settings.

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

## 7. Open design questions (resolve before Status: Approved)

### Q1 — Should the coding agent use tau's tools via MCP, or its native tools?

**Options**

| Option | Description | Pro | Con |
|---|---|---|---|
| **A** (lean) | Agent uses its native tools. Tau audits post-hoc via stream-json events + optional fs-events. | Preserves agent capability. Lower latency. Simpler. | Tau is not in the loop on every edit. Hooks/permissions don't apply to the agent's actions. |
| **B** | Tau exposes Read/Edit/Bash via an MCP server; agent is started with `--disallowed-tools` for its native ones and `--mcp-config` for tau's. | Unified audit, hooks, permissions. | Cripples Claude Code (loses multi-edit, plan mode, web-fetch). Higher latency. Likely brittle across agent versions. |
| **C** (hybrid) | Agent uses its native tools. Tau ALSO exposes a `tau-context` MCP server with session-memory + permission-query + recursive-delegate tools. Coding agent calls these in addition to its native set. | Best of both — agent keeps capability, tau gains a small audit/context window. | Tau-context becomes a permanent API surface that adapters must respect. |

**Leaning: A as default, C as opt-in (`expose_tau_context = true`).** Reject B for now.

**Reasoning:** The goal stated by the user is "use coding agents without API calls." Forcing tau's tools through MCP works against that goal — it degrades the very agent we want to leverage. Audit is real, but it's a separate problem with cheaper solutions (post-hoc fs diff + the event stream is already an auditable transcript).

### Q2 — Primary integration surface: tool or session mode?

**Options**

- **Tool** (`Tau.Tools.Builtin.Delegate`): provider-driven conversation can hand off subtasks. Composes with everything else (permissions, hooks, sub-agents).
- **Session mode** (`--coding-agent claude_code`): the TUI's "Send" goes directly to the coding agent. Tau becomes a thin shell over Claude Code.
- **Both** (independent).

**Leaning: both, but Tool first.** The Tool surface is structurally identical to existing in-BEAM sub-agents (#32) and reuses more code. The session-mode is mostly an argv flag and a different default route — simpler once the dispatcher exists.

### Q3 — Workspace isolation

- Run in user's cwd (matches the current shell session, lets the user see edits in their editor).
- Run in a worktree (safer, but harder to view edits live).
- Configurable per task.

**Leaning: per-task with cwd as default**, and a `--worktree` flag on the Delegate tool / session mode.

### Q4 — Cost aggregation

Adapters that surface cost (Claude Code does; Aider doesn't reliably) emit `Event.Cost`. Tau's session-cost aggregator records these as a separate line item (`coding_agent.claude_code` vs `provider.anthropic`) so the user sees the split.

**Leaning: best-effort with explicit "unknown" sentinel when the adapter can't measure.**

### Q5 — Session resume

Claude Code supports `--resume <session-id>`. Should tau persist coding-agent session ids and offer resume across tau sessions?

**Leaning: yes for the session-mode surface; no for the tool surface (each tool call is its own discrete delegation).**

## 8. Out of scope (explicit)

- Cursor / Cline / other IDE-native agents.
- Forcing the coding agent to use tau's tools (Q1 option B).
- Mid-turn agent migration.
- Coding agent and provider concurrent in the same turn.

## Appendix A — proposed source map (when implementation lands)

```
lib/tau/coding_agent.ex                          # behaviour
lib/tau/coding_agent/event.ex                    # event structs
lib/tau/coding_agent/supervisor.ex               # DynamicSupervisor for dispatchers
lib/tau/coding_agent/dispatcher.ex               # Port owner GenServer
lib/tau/coding_agents/claude_code.ex             # first adapter
lib/tau/coding_agents/replay.ex                  # test fixture adapter
lib/tau/tools/builtin/delegate.ex                # tool surface
lib/tau/cli.ex                                   # --coding-agent flag wiring
```

## Appendix B — non-goals discussion

- **Why not just "MCP all the way down"?** The MCP spec is tool-shaped, not agent-shaped. There is no MCP method `delegate_task(prompt)` that an MCP server can implement; you'd have to define a one-off tool and shoehorn agent semantics into it. Subprocess + stream-json is the actual interface coding agents expose for delegation today.
- **Why not in-BEAM sub-agents (#32) for this?** In-BEAM sub-agents use tau's provider stack, which is the very thing we're trying to bypass. Different goal.
- **Why not a Tau.Provider implementation that shells out to `claude -p`?** Considered. Rejected because the Provider contract is "produce assistant tokens + tool_use events"; the coding-agent contract is "do this whole task end-to-end, including any tool calls." Different abstraction level. Forcing a coding agent into the Provider mold loses signal.
