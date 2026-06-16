# SPEC: Coding-Agent Adapter

| | |
|---|---|
| **Date** | 2026-05-15 |
| **Scope** | A behaviour-shaped adapter that lets tau drive external coding assistants (Claude Code, Aider, Codex CLI, Gemini CLI, …) as sub-agents over a subprocess + structured-event transport. |
| **Method** | PSDH (`.claude/skills/design-reasoning`); L0 + boundary contracts. L2 deferred until first impl lands. |
| **Disposition** | **Additional, optional** feature. Does NOT replace `Tau.Provider`. Users who run tau with an API key are unaffected. |
| **Tracking issue** | #191 |

> **Downstream consumer (A1, #487).** The `:tau_factory` worker fleet drives this
> substrate as a worker's `agent_bin` to perform real dogfooding. The bridge — an
> `agent_bin`-shaped **CodingAgent shim** that adapts this SPEC's
> `Enumerable.t()`/`%Event{}` model (the dispatcher's single-`%Done{}` guarantee,
> §4 B1) to the worker's `{:packet,4}` `work_ready` Port contract, and owns the
> branch+commit step this substrate does **not** perform — is specified in
> `SPEC-FACTORY-FLEET §4 B4-A1` + D-364..D-367. No change to this SPEC's D-031..D-039
> is required; the factory consumes the contract as-is.

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
- **[C14-B1]** Before WI-C the coding-agent finalize path carried its own mirror of the Assembler's D-009 guarantee; two copies of one invariant drift silently. Mitigation: the terminal fold is unified in `Tau.Message.Assembler.finalize/3`; no path holds independent visible-content logic.

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

## 4. Boundary contracts

These contracts are **locked** as of Phase 1A landing. Amendments require
a new PR that updates this section AND a follow-on test or invariant
expressing the change.

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
        skip_permissions: boolean(),
        mcp_servers: [map()],
        timeout: pos_integer() | :infinity
      }
```

**External tool boundary (D-387).** The `ClaudeCode` adapter ALWAYS appends
`--disallowedTools "Bash(git:*)"` to the CLI argv — the git-deny baseline is a
property of the adapter's argv builder, never of the spawn brief. This
unconditional deny is the LOAD-BEARING guarantee: `git ∉ effective-toolset` is
enforced by the deny alone, which `Argv.build/2` appends to every argv and which
empirically survives even `--dangerously-skip-permissions`. The `--allowed-tools`
whitelist is OPTIONAL defense-in-depth (a positive Read,Write,Edit,Bash list that
EXCLUDES git): `Argv.build/2` supports it when a task supplies `allowed_tools`,
but it is NOT wired on the factory path in this PR — no factory component sets
`task.allowed_tools`, so the deny is the sole git-exclusion mechanism that ships.
A future hardening MAY add the whitelist on the factory path; until then the SPEC
asserts no MUST for it. Because git is absent from the sub-agent's effective
toolset, the sub-agent CANNOT commit and leaves an UNCOMMITTED working tree; the
shim's existing single `git status --porcelain` detection (D-364,
SPEC-FACTORY-FLEET) then commits it uniformly. This makes the coding-agent path
symmetric with the API path — the untrusted sub-agent is bounded EXTERNALLY. It
is a first-class external destructive-action control: the concrete git-deny that
the egress / ActionClassifier design (#494, SPEC-FACTORY-GOV) deferred toward.
Enforced by the CLI flag, not the brief.

**Per-worker config isolation (D-388).** The factory worker spawns `claude` with
`CLAUDE_CONFIG_DIR` set to a per-invocation isolated directory, seeded with the
subscription OAuth credential ONLY (copied from `~/.claude/.credentials.json`,
respecting D-375 — no API key) plus an empty/minimal `settings.json` that has NO
`hooks` key and NO operator hooks/plugins/skills/MCP/memory. The isolated path is
injected via the adapter's `port_env` (where D-375 already scrubs `ANTHROPIC_*`),
so no operator host configuration leaks into the sub-agent process. This closes
the host-config leak (#526) and clears the headless permission gate: the prior
headless deadlock (#519) was the operator's plugin hooks leaking in, not headless
mode itself. Credential scope only — does NOT alter D-036 (no credential
injection beyond the scoped subscription OAuth) or D-374/D-375 (metered-credential
scrub).

**Headless permission posture (D-383, revised by D-389).** `task.skip_permissions`
controls the adapter's permission posture. `true` ⇒ the `ClaudeCode` adapter
appends `--dangerously-skip-permissions`; absent/`false` ⇒ no permission flag
(interactive default-deny retained). With the D-388 config isolation in place the
factory runs the sub-agent under the always-on D-387 `--disallowedTools
"Bash(git:*)"` git-deny boundary WITHOUT `--dangerously-skip-permissions` — a
deny-bounded posture, not a blanket bypass (D-389). The `skip_permissions` field/argv seam is RETAINED as an opt-in escape
hatch but is NO LONGER the factory default; the factory dogfood task no longer
forces `skip_permissions: true`. Only a contained-context caller may set it
`true`; non-factory callers (interactive session, the Delegate tool) MUST leave
it unset. Permission posture only — does NOT alter D-036 (no credential
injection) or D-374/D-375 (metered-credential scrub).

**Session-mode integration shape (Phase 1B Team B, resolved 2026-05-15
toward "FSM-extended").** The session FSM (`lib/tau/session.ex`,
`:gen_statem`) hosts a new `:coding_agent_streaming` state **parallel
to** the existing `:provider_streaming` state. The transition rules:

* `:awaiting_user` + user submits + `data.coding_agent != nil` →
  `:coding_agent_streaming` (skipping `:start_provider`).
* `:coding_agent_streaming` consumes the dispatcher's normalized
  events: `Event.AssistantText` folds into a `%Tau.Message.Assistant{}`
  text content block; `Event.ToolUse` appends an Anthropic-shaped
  `%{type: :tool_call, ...}` content block; `Event.ToolResult` flushes
  the in-progress assistant message, appends a `%Tau.Message.ToolResult{}`,
  broadcasts a `%Events.ToolEnd{}`, and starts a fresh pending
  assistant message; `Event.FileEdit` and `Event.Cost` emit telemetry
  only (cost aggregation lands in Phase 1B Team D); `Event.Done`
  finalizes — through the shared source-agnostic fold
  `Tau.Message.Assembler.finalize/3` — and returns to `:awaiting_user`.

The normalization step is deliberate: **coding-agent events become
`Tau.Message` structs**, which means the existing TUI render path,
JSONL persistence, and `/resume` apply unchanged (D-037). Adapters are
addressed by atom on `data.coding_agent`; the FSM never switches on
agent type (D-031).

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

**Reserved synthetic `Done.exit_status` sentinels** (emitted by the
dispatcher when the adapter cannot supply a real exit code; adapters
MUST NOT emit these values for real subprocess exits):

| Value | Meaning |
|-------|---------|
| `-1`  | Unexpected death / inactivity timeout / synchronous `start/2` error / unrecoverable `%Event.Error{}` from adapter |
| `-2`  | Cooperative cancel via `cancel/1` |

The dispatcher **guarantees** every run terminates with exactly one
`%Done{}` event so consumers never need to switch on Error-as-terminator.

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

**Phase 1B Team B implementation (landed).** Worktree creation lives in
`Tau.CodingAgent.Workspace`, a pluggable behaviour with two backends:

- `Tau.CodingAgent.Workspace.Git` — default when tau is invoked inside
  a git repository. Creates a per-session worktree at
  `~/.tau/worktrees/<session_id>/` on branch
  `tau/coding-agent/<session_id>`. Cleaned up on session terminate
  (normal exit, crash, or supervisor shutdown) via
  `git worktree remove --force`.
- `Tau.CodingAgent.Workspace.Cwd` — passthrough fallback when tau was
  invoked outside a git repo, and the surface tests rely on. No state
  is allocated; cleanup is a no-op. A
  `[:tau, :coding_agent, :workspace, :git_repo_absent]` telemetry
  event marks the fallback so `tau doctor` can surface it.

Backend resolution is automatic — the user does not have to think about
worktree vs cwd. `:coding_agent_workspace_backend` can be passed to
`Tau.start_session/1` to override (tests use this).

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
| **D-037** | Coding-agent runs are **first-class sessions**: dispatcher events normalize into `Tau.Message.Assistant{}` / `Tau.Message.ToolResult{}` on ingestion so the session FSM's existing `data.messages` list, JSONL persistence, `%Events.MessageEnd{}` broadcast, TUI render path, and `/resume` apply unchanged. The `:coding_agent_streaming` state lives parallel to `:provider_streaming` and is selected at `process_user_message/2` time when `data.coding_agent != nil`. The no-coding-agent path remains byte-identical to today's provider flow. The terminal fold producing the final `%Tau.Message.Assistant{}`, including the D-009 visible-content guarantee, is source-agnostic: both the provider and coding-agent finalize paths route through `Tau.Message.Assembler.finalize/3`. No path may carry a parallel `ensure_visible_content` implementation. |
| **D-038** | Cost line items MUST be tagged by source so the user sees the split. Each `%Tau.CodingAgent.Event.Cost{}` folds into the session-cost aggregator as a `%Tau.CodingAgent.Cost{}` record carrying the adapter atom (`source/1` yields `"coding_agent.<agent>"`); provider-direct cost continues to land tagged `"provider.<provider>"` via the existing `[:tau, :provider, :request, :stop]` event. The session FSM emits `[:tau, :coding_agent, :cost]` per fold (D-034 parity) and persists a `coding_agent_cost` JSONL event so `/resume` recomputes totals from disk. Cost-folding failures MUST degrade gracefully (D-035): `[:tau, :coding_agent, :cost, :failed]` surfaces the reason but does not crash the session. |
| **D-039** | Delegate-tool recursion MUST bottom out. `Tau.Tools.Builtin.Delegate` carries a `depth` parameter (default 0) and refuses calls at `depth >= 2`, returning a `ToolResult{is_error: true, details.kind: :depth_exceeded}` synchronously before any dispatcher starts. The same ceiling propagates through the per-run tau-context MCP server's `tau_delegate` tool (`tau_context_max_depth` in `Tau.CodingAgent.Dispatcher.ctx`), so coding-agent-driven re-entry hits the same limit. Each Delegate invocation is **stateless** (no resume id is persisted across calls — SPEC §7 Q5). |
| **D-375** | Adapter-level metered-credential scrub — defense-in-depth. `Tau.CodingAgents.ClaudeCode.start/2` MUST pass `{:env, [{~c"ANTHROPIC_API_KEY", false}, {~c"ANTHROPIC_AUTH_TOKEN", false}, {~c"ANTHROPIC_BASE_URL", false}]}` in `Port.open` options by default so the `claude` subprocess never inherits any metered Anthropic credential from the host environment (Erlang Port treats `{key, false}` as POSIX unsetenv on the child). The three scrubbed variables cover all metered-spend vectors: `ANTHROPIC_API_KEY` (primary API key), `ANTHROPIC_AUTH_TOKEN` (metered bearer token honoured by the claude CLI), and `ANTHROPIC_BASE_URL` (proxy endpoint redirect). The sole opt-out is `ctx[:allow_metered] == true`, which passes all three through to the child unchanged. This invariant is a sibling of D-374 (factory-plane guard) and together they form the two-layer cost-safety fence: D-374 is fail-closed at the worker-spawn boundary; D-375 is defense-in-depth at the adapter boundary. Enforced by `test/tau/factory/cost_safety_fence_test.exs` (tags `:d_375` — 2 tests): (a) default: canaries for all three variables absent from `claude` child env; (b) `allow_metered: true`: all three canaries present in child env. |
| **D-383** | Headless permission posture — opt-in boolean. `task.skip_permissions: true` ⇒ `ClaudeCode` adapter appends `--dangerously-skip-permissions`; absent/`false` ⇒ flag absent (interactive default-deny retained). Sound because outer boundaries contain the agent: worker workspace isolation (FLEET D-309–D-316) + metered-credential scrub (D-374/D-375) + ActionClassifier on egress (D-319). Interactive permission prompts are inapplicable headless (deadlock). **Revised by D-389:** the factory default no longer sets `skip_permissions: true` — with D-388 config isolation the factory runs under the always-on D-387 `--disallowedTools "Bash(git:*)"` git-deny boundary WITHOUT this flag; the field/seam is retained only as an opt-in escape hatch. Non-factory callers (interactive session, Delegate tool) MUST leave it unset. Back-compat: a task built without `:skip_permissions` → no flag. Enforced by `test/tau/factory/skip_permissions_d383_test.exs` (tags `:d_383` — 7 tests). |
| **D-387** | External tool boundary — argv git-deny. `Tau.CodingAgents.ClaudeCode.Argv.build/2` MUST ALWAYS emit `--disallowedTools "Bash(git:*)"` (the unconditional git-deny floor) on every argv — this always-on deny is the LOAD-BEARING guarantee that `git ∉ effective-toolset` (it survives even `--dangerously-skip-permissions`). The `--allowed-tools` whitelist (a positive list EXCLUDING `Bash(git...)`) is OPTIONAL defense-in-depth: `Argv.build/2` MAY emit it when a task supplies `allowed_tools`, but it is NOT wired on the factory path in this PR (no factory component sets `task.allowed_tools`), so the deny is the sole shipping git-exclusion mechanism. Adding the whitelist on the factory path is future hardening, not a MUST here. Sound because git ∉ effective-toolset ⇒ the untrusted sub-agent CANNOT commit ⇒ it leaves an uncommitted tree that the shim's single `git status --porcelain` detection (D-364, SPEC-FACTORY-FLEET) commits uniformly — bounding the sub-agent EXTERNALLY, symmetric with the API path. This is the first-class external destructive-action control the egress/ActionClassifier design (#494, SPEC-FACTORY-GOV) deferred toward. Enforced by `test/tau/factory/agent_boundary_model_test.exs` (tag `:d_387`). |
| **D-388** | Per-worker config isolation — `CLAUDE_CONFIG_DIR`. The worker MUST spawn `claude` with `CLAUDE_CONFIG_DIR` (injected via the adapter's `port_env`, alongside the D-375 `ANTHROPIC_*` scrub) pointing at a per-invocation isolated directory seeded with the subscription OAuth credential ONLY (copied from `~/.claude/.credentials.json`, no API key — D-375) plus a minimal `settings.json` with NO `hooks` key and NO operator hooks/plugins/skills/MCP/memory. Sound because no operator host config can leak into the sub-agent process: closes the host-config leak (#526) and clears the headless permission gate (the #519 deadlock was operator plugin hooks leaking in, not headless mode). Enforced by `test/tau/factory/agent_boundary_model_test.exs` (tag `:d_388`). |
| **D-389** | Deny-bounded posture, not blanket bypass. With D-388 config isolation in place, the factory path MUST run the sub-agent under the always-on D-387 `--disallowedTools "Bash(git:*)"` git-deny boundary WITHOUT `--dangerously-skip-permissions`. The `skip_permissions` field/argv seam (D-383) is RETAINED as an opt-in escape hatch but MUST NOT be the factory default — the factory dogfood task MUST NOT force `skip_permissions: true`. Sound because the always-on git-deny + config isolation already bound the agent; a blanket permission bypass is strictly broader than required. Enforced by `test/tau/factory/agent_boundary_model_test.exs` (tag `:d_389`). |

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

**Surface A (session mode)** landed in Phase 1B Team B (#195 — `--coding-agent` flag + `:coding_agent_streaming` FSM state). **Surface B (Delegate tool)** lands in Phase 2 of this issue. The Delegate surface is stateless by design (Q5): each tool call spawns a fresh dispatcher under a per-task git worktree (Q3), invokes the requested adapter, drains the event stream synchronously, and returns the assembled final text + audit-trail (tool uses / tool results / file edits / cost) as a `Tau.Tool.Result`. Recursion is bounded at depth 2 — see D-039.

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

Phase 1B Team B (this PR — landed):

```
lib/tau/coding_agent/workspace.ex                # behaviour + dispatch
lib/tau/coding_agent/workspace/git.ex            # per-session worktree backend
lib/tau/coding_agent/workspace/cwd.ex            # passthrough backend
lib/tau/cli.ex                                   # --coding-agent flag + resolver
lib/tau/tui/app.ex                               # plumbs flag through RuntimeOpts
lib/tau/tui/runtime_opts.ex                      # documented :coding_agent key
lib/tau/session.ex                               # :coding_agent_streaming state + helpers; finalize via Assembler.finalize/3
lib/tau/settings/schema.ex                       # coding_agent.default_agent
test/tau/cli_coding_agent_flag_test.exs          # CLI flag parse + resolver
test/tau/coding_agent/workspace_test.exs         # worktree create/cleanup
test/tau/session/coding_agent_streaming_test.exs # FSM drives Replay end-to-end
```

Phase 1B Team C (this PR — landed):

```
lib/tau/coding_agent/tau_context.ex              # Bandit child-spec + start_link
lib/tau/coding_agent/tau_context/auth.ex         # bearer-token mint + Plug auth
lib/tau/coding_agent/tau_context/router.ex       # JSON-RPC 2.0 router (Plug)
lib/tau/coding_agent/tau_context/tools.ex        # tools/list + tools/call
test/tau/coding_agent/tau_context_test.exs       # supervisor + lifecycle
test/tau/coding_agent/tau_context/auth_test.exs  # auth Plug contract
test/tau/coding_agent/tau_context/auth_routing_test.exs # mount-point routing
test/tau/coding_agent/tau_context/router_test.exs # JSON-RPC dispatch
test/tau/coding_agent/tau_context/tools_test.exs  # tool implementations
```

Phase 1B Team D (this PR — landed):

```
lib/tau/coding_agent/cost.ex                     # adapter-tagged cost record + JSONL round-trip
lib/tau/coding_agent/event.ex                    # %Start{} gains :session_id (resume plumbing)
lib/tau/coding_agents/claude_code/stream_json.ex # populates %Start.session_id from system/init
lib/tau/coding_agents/replay.ex                  # JSONL fixtures round-trip :session_id
lib/tau/cost/tracker.ex                          # second handler folds coding-agent rows into ETS
lib/tau/session.ex                               # capture session_id; cost fold-in; resume_id; coding_agent_state
test/tau/session/coding_agent_cost_test.exs      # D-038 fold + telemetry + JSONL
test/tau/session/coding_agent_resume_test.exs    # %Start.session_id → task.resume_id
test/tau/coding_agent/telemetry_audit_test.exs   # D-034 audit + :external ClaudeCode parity
```

Phase 2 (this PR — landed):

```
lib/tau/tools/builtin/delegate.ex                # Delegate tool — Surface B
test/tau/tools/builtin/delegate_test.exs         # tool contract + cancel/timeout
lib/tau/permissions/matchers.ex                  # Glob/Regex arg_for: Delegate(agent)
config/config.exs                                # builtin_tools registration
```

PR #520 — D-383 headless skip-permissions (this PR — landing):

```
lib/tau/coding_agent.ex                              # task typespec: optional(:skip_permissions) => boolean()
lib/tau/coding_agents/claude_code/argv.ex            # maybe_append_skip_permissions/2 (D-383)
lib/tau/factory/agent_bin.ex                         # resolve_claude_code passes skip_permissions to shim
lib/tau/factory/coding_agent_shim.ex                 # config bakes + Runner threads skip_permissions into task
lib/mix/tasks/tau.factory.dogfood.ex                 # sandbox path sets skip_permissions: true via AgentBin.resolve/1
test/tau/factory/skip_permissions_d383_test.exs      # D-383 gating test (7 tests, :d_383 tag)
```

PR #528 — D-387/388/389 unified agent-boundary model:

```
lib/tau/coding_agents/claude_code/argv.ex            # always-append --disallowedTools "Bash(git:*)" (load-bearing); optional --allowed-tools whitelist supported but NOT wired on factory path (D-387)
lib/tau/coding_agents/claude_code/config_dir.ex      # NEW — per-invocation CLAUDE_CONFIG_DIR seeding (creds-only + minimal settings, no hooks) (D-388)
lib/tau/coding_agents/claude_code.ex                 # seed_config_dir/2 + CLAUDE_CONFIG_DIR in port_env (D-388)
lib/tau/factory/agent_bin.ex                         # drop forcing skip_permissions: true on the factory path (D-389)
lib/mix/tasks/tau.factory.dogfood.ex                 # dogfood task no longer forces skip_permissions: true (D-389)
test/tau/factory/agent_boundary_model_test.exs       # D-387/388/389 gating test (:d_387 / :d_388 / :d_389 tags)
```

Total runtime invariants claimed by this spec: **D-031 through D-039, D-375, D-383, D-387 through D-389** (14).

## Appendix B — non-goals discussion

- **Why not just "MCP all the way down"?** The MCP spec is tool-shaped, not agent-shaped. There is no MCP method `delegate_task(prompt)` that an MCP server can implement; you'd have to define a one-off tool and shoehorn agent semantics into it. Subprocess + stream-json is the actual interface coding agents expose for delegation today.
- **Why not in-BEAM sub-agents (#32) for this?** In-BEAM sub-agents use tau's provider stack, which is the very thing we're trying to bypass. Different goal.
- **Why not a Tau.Provider implementation that shells out to `claude -p`?** Considered. Rejected because the Provider contract is "produce assistant tokens + tool_use events"; the coding-agent contract is "do this whole task end-to-end, including any tool calls." Different abstraction level. Forcing a coding agent into the Provider mold loses signal.
