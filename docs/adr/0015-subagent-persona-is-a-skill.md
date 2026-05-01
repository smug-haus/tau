# ADR-0015: Subagent persona is a `Tau.Skill`; the spawn never loosens parent permissions

- **Status:** Proposed
- **Date:** 2026-05-01
- **Deciders:** the agent loop, with no objection from @smug-haus
- **Related:**
  - Issues: #32 (Agent tool), #16 (skill `allowed_tools` enforcement,
    prerequisite), #18 (tracker)
  - Code: `lib/tau/skill.ex`, `lib/tau/skills/`,
    `lib/tau/permissions/evaluator.ex` (mode definitions),
    `lib/tau/session.ex` (`dispatch_tools/2`, `:permissions_mode`
    metadata)
  - Prior ADRs: ADR-0005 (skills are read-only at session start),
    ADR-0013 (skill activation lives on the session FSM, scoped to one
    turn — this ADR extends that activation model to a per-session
    lifetime for subagent personas), ADR-0014 (subagents are sessions)

## Context

Once the `Agent` tool exists (ADR-0014), two questions remain:

1. **Persona.** A subagent should behave differently from its
   parent: an `Explore` agent reads and reports; a `Plan` agent
   designs but doesn't write; a `general-purpose` agent has the
   full kit. Where does the persona — system prompt addendum,
   tool whitelist, default model — come from?
2. **Permissions.** A child running with a more permissive mode
   than its parent (e.g. parent in `:plan`, child in `:bypass`)
   would let the model trivially escape the parent's safety
   posture by spawning a subagent. We need an inheritance rule
   the model can't subvert.

For the persona question, the harness already has an extensible,
filesystem-discovered, read-only-at-load primitive that carries
exactly the fields a persona needs:

```elixir
%Tau.Skill{
  name: String.t(),
  body: String.t(),
  description: String.t(),
  allowed_tools: [String.t()],   # tool whitelist
  disable_model_invocation: bool, # never auto-invoked
  paths: [String.t()],           # discovery roots
  path: Path.t()
}
```

`Tau.Skills.Loader.discover/1` already finds them in
`<cwd>/.claude/agents/<name>.md` and the equivalent user/managed
roots, parses frontmatter, and registers them in
`Tau.Skills.Registry`. ADR-0005 codifies the load contract: pure,
per-session, side-effect-free.

A skill _is_ a persona: a markdown body to inject into the
prompt, a tool whitelist, a name. We don't need a parallel
"agent definitions" registry; we need to use what's there.

For the permissions question, `Tau.Permissions.Evaluator` already
defines a mode lattice
(`:bypass | :auto | :default | :accept_edits | :dont_ask | :plan`).
The natural rule is: a subagent's effective mode is at most as
permissive as its parent's. The Agent tool can _request_ a stricter
mode for the child (typical: `:plan` for an `Explore` subagent, so
the child literally cannot write); it can never _request_ a
broader one.

## Decision

**`subagent_type` resolves to a skill name; the resolved skill
supplies the system prompt addendum and the child's tool
whitelist. Permissions are inherited and may only be tightened.**

Specifics:

1. **Persona = skill lookup.** The `Agent` tool's `subagent_type`
   parameter is a skill name. At spawn time the tool calls
   `Tau.Skills.Loader.lookup/2` (or its eventual equivalent
   keyed off the same registry skills load into). If found, the
   skill's `body` is the system prompt addendum (joined onto the
   tool's `system_prompt` parameter), and the skill's
   `allowed_tools` list is the child's tool whitelist. If
   `subagent_type` is omitted, the child runs as a `general-purpose`
   subagent — full tool access (subject to permissions) and no
   added persona.

2. **Active-skill activation in the child.** The child session is
   started with the resolved skill installed as its
   `:active_skill` from turn one. This activates the same
   `allowed_tools`-enforcement path ADR-0013 builds for normal
   skill invocations (the work landed in #16): `Tau.Permissions.Evaluator`
   consults the active-skill whitelist before falling through to
   global rules. Because subagents cannot dismiss their persona —
   the harness pins it for the lifetime of the session, not "until
   the model says it's done" — there's an explicit option
   `:persona_lifetime: :session` (default for subagents) that
   distinguishes from the per-turn lifetime ADR-0013 uses for
   model-driven skill invocations.

3. **Permissions are inherited; tightening is allowed,
   loosening is not.** The Agent tool's `permissions_mode`
   parameter is optional. Effective child mode is computed by:

   ```elixir
   parent_mode = parent_session.metadata[:permissions_mode] || :default
   requested  = params["permissions_mode"]  # optional, atom-coerced
   child_mode = clamp(requested || parent_mode, ceiling: parent_mode)
   ```

   where `clamp(_, ceiling: parent)` returns the requested mode if
   the lattice places it at or below the parent, otherwise returns
   the parent. The lattice (most permissive → most restrictive):

   ```text
   :bypass  >  :auto  >  :default  >  :accept_edits
                                    \  :dont_ask
                                     \ :plan
   ```

   `:accept_edits`, `:dont_ask`, and `:plan` are not strictly
   ordered against each other (they restrict different operations);
   for ceiling purposes, any of the three is "more restrictive
   than `:default`" and ceiling-comparable accordingly. The
   evaluator already encodes which tools each mode allows; the
   ceiling check is a small lookup over a fixed lattice and lives
   in `Tau.Permissions.Evaluator` (or a small sibling module if
   the evaluator stays purely match-based).

4. **`:tools_whitelist` plumbed as a session option.** A new
   session opt `:tools_whitelist :: [String.t()] | :all` is
   accepted by `Tau.start_session/1` and stored in the FSM data.
   `dispatch_tools/2` filters the model's tool calls against it
   before evaluating permissions; calls outside the list become
   synthesised `is_error: true` ToolResults the same way deny
   rules already do. (This is the same machinery #16 needs for
   skill-active dispatch; the option just exposes it on the start
   path.) `:all` is the default and matches today's behaviour.

5. **Failure modes — fail closed.**
   - `subagent_type` names a skill that does not exist → the
     `Agent` tool returns `is_error: true` with
     `"Unknown subagent_type: #{name}"`. We do not fall back to
     `general-purpose` silently; a misnamed persona is a model
     mistake the parent should see.
   - Skill's `allowed_tools` references a tool that isn't
     registered → the unknown name is dropped from the effective
     whitelist; load-time telemetry already surfaces this case
     for normal skill activation.
   - Requested permissions mode above the parent's ceiling →
     downgraded to the parent's mode, with a `:telemetry.execute`
     event under `[:tau, :permissions, :ceiling_clamped]` so the
     downgrade is observable.

## Consequences

- Subagent personas live as ordinary markdown files in
  `.claude/agents/<name>.md` (or wherever skills already
  discover from). Anyone who can write a skill can write an
  agent persona; nothing new to learn, nothing new to load.
- The parent's safety posture is monotonic across delegation:
  a `:plan` parent can spawn a `:plan` child (or stricter), but
  never a `:bypass` child. Models cannot escalate by delegating.
- The `Agent` tool gains no persona-management code of its own —
  it looks up a skill and plumbs flags through. Adding a new
  subagent type is a markdown file, not a code change.
- `:tools_whitelist` as a session opt is independently useful
  (sandboxed sessions in tests, restricted skill activations
  per #16) — we get a single mechanism that works for both
  cases instead of one for skills and another for subagents.
- The decision binds subagent persona to the skill format. If we
  later want richer persona metadata (default model, default
  provider, suggested temperature), the right move is to add
  fields to `Tau.Skill` (one struct, used by both code paths)
  rather than fork a separate "agent definition" type.
- The mode ceiling rule means UI hints — "this delegate call
  would have run in `:bypass` but was clamped to `:plan`" —
  fall out of the existing telemetry. No model-visible
  surface change.

## Alternatives considered

- **A separate `Tau.Agent.Definition` registry, keyed by
  `subagent_type`, with its own loader/discovery roots.**
  Rejected: parallel infrastructure to the skill loader for
  identical machinery. The skill struct already carries every
  field a persona needs.
- **Spawn-time personas defined inline by the model
  (`system_prompt`, `allowed_tools` passed as Agent-tool args
  with no skill lookup).** Considered, partially adopted — the
  Agent tool _does_ accept `system_prompt` directly and treats
  it as an addendum to the resolved skill. But making this the
  _only_ mode would push prompt engineering into every callsite
  and lose the discoverable, version-controlled persona library
  that skills give us. The merged model — skill as default,
  inline as override — keeps both ergonomics.
- **Permissions ceiling = parent mode strictly (no requesting
  stricter modes from the spawn).** Rejected: the typical use
  case for `Explore` subagents is precisely "I want this child
  to be unable to write even though I can". Refusing tightening
  forecloses on the most useful ergonomic.
- **No ceiling at all — let the model ask for whatever mode it
  wants.** Rejected on safety grounds. The mode is a property
  of the user's intent, not the model's. The child's ceiling
  must be the parent's mode; otherwise the safety posture is
  decorative.
- **Persona via slash-command-style file commands rather than
  skills.** Slash commands (per ADR-0008) are user-driven, run
  in a Task, return a string the model never sees as
  "personality". Wrong shape for personas, which need to colour
  the model's whole subagent session.

## Notes

- This ADR builds on the active-skill enforcement path that landed
  with #16 / ADR-0013. Without that, the whitelist is decorative
  and the mode-clamp is the only real protection — with it, the
  child's `dispatch_tools/2` filters before evaluating permissions.
- The `:persona_lifetime` distinction (per-turn vs per-session)
  is small and lives next to the active-skill machinery; it
  doesn't merit its own ADR.
- Recursion: a subagent spawning its own subagent inherits the
  ceiling chain naturally — each Agent-tool call clamps against
  its immediate parent, so the deepest descendant cannot exceed
  the most restrictive ancestor.
