# ADR-0004: `Phoenix.PubSub` is at the top of the supervision tree

- **Status:** Accepted
- **Date:** 2026-04-30
- **Deciders:** @smug-haus
- **Related:**
  - Issue: #54
  - Code: `lib/tau/application.ex`,
    `lib/tau/settings/cache.ex`,
    `lib/tau/permissions/rule_set.ex`
  - Non-negotiable #4: "Cross-process events use `Phoenix.PubSub`
    topics or monitored refs. Never `Process.whereis/1 |> send(...)`."

## Context

Tau's supervision tree was originally ordered by what looked like
"bigger-blocks-of-state first" — `Tau.Settings.Cache`,
`Tau.Memory.Cache`, `Tau.Permissions.RuleSet`, and only then
`{Phoenix.PubSub, name: Tau.PubSub}`.

That had two costs:

1. `Tau.Settings.Cache.publish/1` couldn't broadcast on PubSub from
   its own `init/1` (PubSub didn't exist yet), so it gained a
   `Process.whereis(Tau.PubSub)` guard — exactly the pattern
   non-negotiable #4 forbids.
2. `Tau.Permissions.RuleSet` couldn't subscribe to a `"settings"`
   topic to learn about reloads, so `Settings.Cache` direct-`send/2`'d
   it — also forbidden by non-negotiable #4. Two delivery channels
   for the same event, only the deprecated one driving updates.

We need PubSub to be the only fan-out for cross-process events,
and we need it to be available from any other process's `init/1`.

## Decision

`{Phoenix.PubSub, name: Tau.PubSub}` is the **second** child of
`Tau.Supervisor` (only `Tau.Telemetry.Supervisor` precedes it). Any
subsystem that broadcasts or subscribes can do so from its own
`init/1` without a `Process.whereis` guard. With the
`:rest_for_one` strategy, a PubSub crash deliberately cascades to
every subsystem that depends on it.

Specifics:

- `Tau.Settings.Cache.publish/1` calls
  `Phoenix.PubSub.broadcast(Tau.PubSub, "settings", _)`
  unconditionally. No guards.
- `Tau.Permissions.RuleSet.init/1` calls
  `Phoenix.PubSub.subscribe(Tau.PubSub, "settings")` and handles
  `{:settings_reloaded, settings}` from its mailbox. The earlier
  `Settings.Cache → send/2 → RuleSet` direct path is removed.
- The supervisor's moduledoc enumerates the boot order with the
  rationale, so a future re-ordering is obvious to flag.

## Consequences

- Non-negotiable #4 is enforceable: any new subsystem's `init/1`
  can publish/subscribe on PubSub without ceremony, and any
  remaining `Process.whereis(...) |> send(...)` is a code smell
  to be flagged.
- A PubSub crash takes down everything that uses it, which is
  what we want — restart the world below it cleanly rather than
  let subscribers leak orphan state.
- Adds two lines of guarantee to the supervisor's moduledoc;
  costs zero performance.
- `Tau.Permissions.RuleSet` joins the PubSub registry on init —
  one extra registry insert at boot, immaterial.

## Alternatives considered

- **Keep the boot order, accept the `whereis` guards.** Convenient
  but encodes the violation of non-negotiable #4 directly in
  load-bearing code. Future readers would copy the pattern.
- **Split PubSub broadcast into a separate "broadcaster" GenServer
  that boots later.** Adds a process to dodge a process-ordering
  problem. The fix is to fix the order.
- **Boot PubSub conditionally inside `Settings.Cache.init/1`.**
  Conflates the responsibilities (Settings shouldn't own PubSub
  lifecycle) and breaks `:rest_for_one`'s cascade.

## Notes

This ADR also implicitly says: **any future cross-process event
must be PubSub or a monitored ref.** Direct `send/2` between named
processes is acceptable only inside a single subsystem (e.g., a
GenServer's own internal `cast`), not for cross-subsystem
notifications.

If a contributor finds themselves typing `Process.whereis(...) |> send(...)`
in production code, they're either re-introducing this bug or
need to file an ADR superseding this one.
