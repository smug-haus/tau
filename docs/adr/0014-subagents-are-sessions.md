# ADR-0014: Subagents are sessions, spawned by the `Agent` tool

- **Status:** Accepted
- **Date:** 2026-05-01
- **Deciders:** the agent loop, with no objection from @smug-haus
- **Related:**
  - Issues: #18 (tracker), #32 (Agent tool), #34 (coordination — deferred),
    #16 (skill `allowed_tools` enforcement, prerequisite)
  - Code: `lib/tau/session.ex`, `lib/tau/sessions/supervisor.ex`,
    `lib/tau/registries.ex` (`Tau.Sessions.Registry`),
    `lib/tau/hook.ex` (declares `:subagent_start`),
    `lib/tau/tools/builtin/` (where the `Agent` tool will live)
  - Prior ADRs: ADR-0008 (user code never runs synchronously in the
    FSM), ADR-0009 (queue user messages during active turns),
    ADR-0010 (cost tracker), ADR-0012 (provider fallback is FSM-internal)

## Context

The harness needs to let one model session delegate work to a child:
the analogue of Claude Code's `Task` tool, the pattern called out
explicitly in `CLAUDE.md` (the parent agent acts as a coordinator,
the child does the actual digging or planning). Today there is no
delegation primitive.

Two shapes were on the table:

1. **Subagents as a new entity** — a `Tau.Subagent` behaviour, its
   own dynamic supervisor, its own registry, its own persistence
   namespace, its own lifecycle events.
2. **Subagents as full sessions** — a child `Tau.Session` under the
   existing `Tau.Sessions.Supervisor`, registered in the existing
   `Tau.Sessions.Registry`, with subagent-ness encoded in metadata
   on the session header.

Several existing facts in the codebase point at (2):

- `Tau.Session.fork/2` already creates a new session whose
  persistence header references a `parent_event_id` from another
  session. The "child of another session" shape is implemented; we
  just haven't used it for live spawns yet.
- `Tau.Session.Meta.metadata` reserves keys like `:forked_from` for
  tagging provenance — a `:parent_session_id`/`:subagent_type` pair
  fits the same niche without a schema change.
- `Tau.Sessions.Supervisor` is a `DynamicSupervisor` with
  `:one_for_one`; child crash isolation is already what we want.
- `Tau.Sessions.Registry` is `:unique` keyed by session id; child
  sessions register the same way, and `Tau.cancel/1` /
  `Tau.snapshot/1` work on them with no extra plumbing.
- The hook contract (`lib/tau/hook.ex:14`) already declares
  `:subagent_start` as a lifecycle hook — the design has been
  earmarked, just not implemented.

A second supervisor / registry would duplicate machinery for no
behavioural difference: subagents stream, persist, broadcast, and
cancel exactly like top-level sessions. The only thing that's
genuinely new is _how_ they get spawned (by a tool call, not by
`Tau.start_session/1` from outside) and _what_ the parent does
with the result.

## Decision

**A subagent is a `Tau.Session` whose metadata names its parent.**
Spawning is the job of a built-in tool, `Tau.Tools.Builtin.Agent`.
The parent's session FSM does not learn a new state; it sees the
spawn as one of its tool calls.

Concretely:

1. **Spawn point** — `Tau.Tools.Builtin.Agent` (`:parallel` execution
   mode) takes the model-supplied `description`,
   `system_prompt`, `subagent_type`, and an optional `model`/
   `provider`. Inside its `execute/2` it:
   - dispatches the `:subagent_start` hook with payload
     `%{parent_session_id, parent_tool_call_id, subagent_type,
        brief, permissions_mode}` (hook may halt or rewrite);
   - calls `Tau.start_session/1` with computed opts (see ADR-0015
     for how `subagent_type`, permissions, and `:tools_whitelist`
     are derived);
   - subscribes to the child's `"session:<child_id>"` PubSub topic;
   - sends the brief as the child's first user message;
   - awaits the child's first `%MessageEnd{stop_reason: :end_turn}`
     and returns its assembled assistant text as the
     `Tau.Tool.Result.content`.

2. **Same supervisor, same registry** — the child is started by the
   existing `Tau.Sessions.Supervisor.start_session/1`. No new
   supervisor, no new registry. Subagent-ness is purely a metadata
   convention.

3. **Reserved metadata keys** added to `Tau.Session.Meta`'s contract:
   - `:parent_session_id` — id of the spawning session.
   - `:parent_tool_call_id` — the parent's tool call that spawned
     this child (so persistence can link back to the exact event).
   - `:subagent_type` — the skill name resolving the persona
     (see ADR-0015).
   These travel through the session header and are JSON-encodable
   per the existing `Meta.metadata` rules.

4. **Result delivery: synchronous handoff (v1).** The parent's tool
   turn blocks on the child's first `:end_turn`. The child's
   assistant text becomes the parent's `ToolResult.content`. Three
   delivery modes were considered (synchronous handoff,
   fork-and-await, fire-and-forget — see #18 critic comment); v1
   ships the first. Multiple parallel `Agent` tool calls in a
   single assistant turn already give us "fork-and-await" via
   the existing `:parallel` tool fan-out.

5. **Cancellation cascade.** `Tau.Session` data grows a
   `child_session_ids :: MapSet.t(String.t())` field. When the
   `Agent` tool task starts a child it casts
   `{:register_child, child_id}` to the parent FSM; on
   `Tau.cancel/1` or `:stop` the parent iterates the set and calls
   `Tau.cancel/1` on each child before tearing down its own tool
   tasks. The `Agent` tool task itself uses `Process.monitor/1` on
   the parent FSM; if the parent dies before the child finishes,
   the task observes `:DOWN` and calls `Tau.cancel/1` on the child
   to flush its persistence.

6. **Persistence — same JSONL backend, parent linkage in the
   header.** `Tau.Persistence.Jsonl.open/2` already accepts
   `:parent_event_id`; subagents pass their parent's tool call id.
   Tree-walking the chain is the same code path used by `fork/2`.
   `Tau.list_sessions/1` already surfaces children because they
   live in the same persistence root.

7. **Telemetry.** New events under
   `[:tau, :session, :subagent, :start | :stop | :exception]`,
   emitted by the `Agent` tool task. The hook
   `:subagent_start` is already declared. No new lifecycle states
   on the FSM.

## Consequences

- The session FSM stays unchanged in shape: same state set (see
  `lib/tau/session.ex`'s `@moduledoc`), same callback module. The
  only `data` change is the `child_session_ids` set and a new
  `handle_event` clause for `{:register_child, _}`.
- Tools, hooks, persistence, telemetry, and TUI subscribers
  (`Tau.stream/2`) work on subagents with no special-casing —
  they're sessions, the harness already understands them.
- A subagent crash never crashes the parent: child crashes are
  contained by `Tau.Sessions.Supervisor`'s `:one_for_one`; the
  `Agent` tool task observes the child's `%SessionEnd{}` and
  returns `is_error: true` to the parent's transcript.
- Deep nesting (subagent-of-subagent) works for free, since
  children are sessions and can themselves call `Agent`. We expose
  no recursion-depth limit at the architectural level; if abuse
  shows up in practice, a limit lands as a new ADR or a settings
  knob, not a structural change here.
- `Tau.snapshot/1`, `Tau.cancel/1`, `Tau.stop/1` work on subagent
  ids out of the box. Tools that introspect "the session I'm
  running in" via `ctx.session_id` already get the right id when
  they're called inside a subagent.
- The parent's transcript gains a `tool_result` whose `content`
  is the child's final assistant text. The full child transcript
  remains addressable by `child_session_id` — callers (TUI,
  forensics, evals) walk parent → children via metadata.
- Cost is tracked per session, so `Tau.Cost.summary/1` (ADR-0010)
  needs no change to bill subagent token usage to its own
  session id; aggregation across a parent/children tree is a
  follow-up reporting concern, not an architectural one.

## Alternatives considered

- **A separate `Tau.Subagents.Supervisor` and `Tau.Subagents.Registry`.**
  Rejected: zero behavioural distinction from sessions, would
  require parallel implementations of `cancel`, `snapshot`,
  persistence, and stream subscription. Two registries to look
  up by id is worse, not better.
- **A `Tau.Subagent` behaviour with its own callbacks.** Rejected:
  the work a subagent does is a session loop. A new behaviour
  would be a misleading parallel hierarchy; nothing about
  delegation needs an extensibility seam at the
  agent-implementation level. The seam that does need extension
  — the persona — is a `Tau.Skill` (ADR-0015).
- **Child as a function call inside the parent FSM** (run the
  child's loop in-process, no PubSub round-trip). Rejected:
  violates ADR-0008 (no user code synchronously in the FSM) and
  forecloses on observability — the TUI/CLI can already subscribe
  to a session topic and watch a subagent stream live.
- **Fire-and-forget / async result mode in v1.** Rejected for v1.
  The `Agent` tool's blocking await maps directly onto the
  model's mental model of a tool call ("I called it, I get a
  result"); progress streaming and async modes (#34) are cleaner
  to add once the synchronous baseline is in.

## Notes

- This ADR sets the supervision/persistence/lifecycle shape.
  Persona resolution (`subagent_type` → skill, `allowed_tools`
  whitelist, permission inheritance) is ADR-0015.
- Inter-agent message-passing beyond "child returns one summary"
  (issue #34) is intentionally out of scope. Reopen the
  conversation with a new ADR superseding the relevant section
  here when a real use case appears.
- The `Agent` tool's parameter shape is owned by issue #32. ADRs
  pin _what_ the spawn produces and _where_ it lives in the tree;
  the JSON Schema can iterate without an ADR rewrite.
