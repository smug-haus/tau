# ADR-0005: Skills discovery is per-session and side-effect-free

- **Status:** Accepted
- **Date:** 2026-04-30
- **Deciders:** @smug-haus
- **Related:**
  - Issue: #49
  - Code: `lib/tau/skills/loader.ex`,
    `lib/tau/extensions/loader.ex`,
    `lib/tau/session.ex`,
    `lib/tau/registries.ex`
  - Non-negotiables: #1 (every stateful subsystem is a process under
    a supervisor), #3 (no GenServer that wraps stateless logic)

## Context

Skills live in three places:

- `~/.tau/skills/<name>/SKILL.md` — user-global
- `<cwd>/.tau/skills/<name>/SKILL.md` — project-local
- `priv/skills/<name>/SKILL.md` — bundled with Tau
- (and extension-provided, via the `Tau.Extension` `skills/0`
  callback)

cwd-local skills change per session (working in repo A vs repo B
gives different "deploy" skills), so loading must be cwd-aware.
The original implementation made `Tau.Skills.Loader.load_all/1`
both walk the filesystem _and_ `Registry.register/3` parsed
`%Tau.Skill{}` structs into the global `:unique`
`Tau.Skills.Registry`. Sessions then re-read via
`Tau.Skills.Loader.list/0`.

That had three concrete problems (#49):

1. **Registry ownership tied to session pid.** `Registry.register/3`
   uses the calling pid as owner. Sessions register; when a session
   dies, Registry auto-removes its entries. Other sessions started
   before that death now see the entries vanish from under them.
2. **Silent ownership conflicts.** `Registry.register/3` returns
   `{:error, {:already_registered, _}}` if the key is owned by
   another live pid. `load_one/1` ignored the return and pretended
   `{:ok, skill}`. A second session's registration silently
   no-ops; it sees only the first session's stale entry.
3. **Violates non-negotiable #1** — the registry was being treated
   as long-lived state owned by transient processes.

The fix is to recognise that **the registry was a redundant
intermediate**. Sessions already store loaded skills on
`data.skills`. Discovery doesn't need any global state.

## Decision

Skills discovery is a **pure function**:

- `Tau.Skills.Loader.discover(cwd) :: [{name, %Tau.Skill{}}]`
  walks `~/.tau/skills`, `<cwd>/.tau/skills`, and `priv/skills`,
  parses every `SKILL.md` it finds, and returns the list.
  **No Registry side effects.**
- `Tau.Skills.Loader.parse(path) :: {:ok, %Tau.Skill{}} | {:error, term()}`
  is the per-file pure parser.

`Tau.Skills.Registry` continues to exist, but only **extension
authors** register entries into it (via
`Tau.Extensions.Loader.register_module/1`, which runs from the
long-lived `Extensions.Loader` GenServer's pid — proper non-neg-#1
ownership). Sessions consume from both sources at boot:

```elixir
discovered = Tau.Skills.Loader.discover(cwd)
extension  = Tau.Skills.Loader.list_extension_skills()  # registry select
skills     = merge_by_name(discovered, extension)
```

`load_all/1`, `load_one/1`, and `list/0` are removed from
`Tau.Skills.Loader`'s public API — they encoded the old
mixed-concerns model. Pre-alpha, no deprecation cycle.

## Consequences

- Sessions are read-only consumers of the skills registry. No
  per-session-pid ownership leaks.
- Filesystem-discovered skills cost N file reads per session start
  (typically a handful). The Phase-11 ETS-backed cache
  (`Tau.Memory.Cache`-style) can be added later if measurements
  show this matters; tracked in #53.
- Extension authors writing `skill "foo", "priv/skills/foo/SKILL.md"`
  get the same `%Tau.Skill{}` shape as filesystem-discovered
  skills, since `Tau.Extensions.Loader.register_module/1` now
  parses the path at registration time and registers a `%Skill{}`
  rather than a raw path string. Closes a latent type
  inconsistency in the registry.
- Test session leakage (#52) becomes a non-issue for skill state —
  there's no per-session-pid registry to leak. The FSM-leak
  problem itself (open file descriptors, etc.) is still tracked
  separately.
- Removing `load_all/1` is a breaking API change. Pre-alpha; we
  accept it. Extension authors using it would have been getting
  the wrong (broken) behaviour anyway.

## Alternatives considered

- **Load skills once at boot from a long-lived owner.** Loses
  cwd-specific discovery — the user's `<repo-A>/.tau/skills/deploy`
  skill wouldn't appear in a session opened in repo B. Wrong
  shape.
- **Use a `:duplicate` (per-session-keyed) registry.** Solves the
  ownership-conflict half but doesn't solve the death-cascades-
  remove-entries half, and the registry stops being a useful
  global look-up. Worse than no registry.
- **Per-session ETS table owned by the session FSM.** Same death
  cascade as the registry approach, plus more boilerplate. Not
  worth it for a list a session reads exactly once at init.

## Notes

The `Tau.Skill` struct is unchanged. The `disable_model_invocation`
flag still controls whether the model sees the skill in context;
the pure-discovery refactor doesn't touch the injection logic.

If a future session-driver needs to react to skill changes
mid-session, that's a separate ADR — broadcast on a
`"skills:#{cwd}"` PubSub topic and have the session re-discover.
Not implemented today; today, skill bodies are baked in at session
start.
