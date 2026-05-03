# ADR-0018: TUI runs as a transient child of Tau.TUI.Supervisor

- **Status:** Accepted
- **Date:** 2026-05-03
- **Deciders:** the agent loop, with no objection from @smug-haus
- **Related:**
  - Issue: #153 (TUI broken in prod / Burrito binary)
  - Code: `lib/tau/tui/supervisor.ex`, `lib/tau/tui/app.ex`
  - Prior: OTP non-negotiables #1 and #7 at
    `.claude/rules/otp-non-negotiables.md`

## Context

Prior to issue #153, `Tau.TUI.App.run/0` called
`Ratatouille.Runtime.start_link/1` directly. That function only spawns
the `Ratatouille.Runtime` Task — it does **not** start
`Ratatouille.EventManager` or `Ratatouille.Window`, which the Runtime
requires on entry (`EventManager.subscribe(state.event_manager, self())`
is the first call the runtime makes). The canonical entry point is
`Ratatouille.Runtime.Supervisor.start_link/1`, which boots Window +
EventManager + Runtime under a `:one_for_all` supervisor.

The crash manifested in the Burrito binary (`./burrito_out/tau_linux_arm64`
run with no args) as:

```
** (stop) exited in: GenServer.call(Ratatouille.EventManager, {:subscribe, ...}, 5000)
    ** (EXIT) no process: the process is not alive...
```

A WIP fix in commit `11cd14a` tried
`Application.ensure_all_started(:ratatouille)`, but ratatouille's
`mix.exs` has `extra_applications: [:logger]` with no `mod:` — it is a
library application, so "starting" it is a no-op for processes.

A second problem: the old code started the Ratatouille runtime from an
inline Task in `Tau.Application.start/2`. The runtime supervisor was
therefore **orphaned** — its lifecycle was bound to the Task, not to
Tau.Supervisor. On abnormal Task exit the supervisor leaked, and on
normal application shutdown the ordering was undefined.

## Decision

Introduce `Tau.TUI.Supervisor`, a permanent `DynamicSupervisor` in the
Tau.Application supervision tree (position 11, before
`Sessions.Supervisor`). When the TUI is invoked,
`Tau.TUI.App.run/0` calls `Tau.TUI.Supervisor.start_runtime/1`, which
starts `Ratatouille.Runtime.Supervisor` as a transient child with
`type: :supervisor`. `run/0` then monitors the returned pid and blocks
until it receives the `:DOWN` message.

`Ratatouille.Runtime.Supervisor` is the Ratatouille-canonical supervisor
that starts Window, EventManager, and Runtime under `:one_for_all`.

## Consequences

**Problems prevented:**

- Orphaned `Ratatouille.Runtime.Supervisor` outliving Tau.Supervisor on
  shutdown.
- Task crash leaking the Ratatouille supervisor with no owner.
- Bare `receive` loop in `run/0` violated non-negotiable #7 in spirit
  (the monitored process was unsupervised); now the supervisor is the
  unit of monitoring.

**Trade-off:**

`Tau.TUI.Supervisor` runs even when the TUI is never invoked — e.g., in
headless/server deployments and during `mix test`. Cost is one empty
`DynamicSupervisor` (a handful of heap words; negligible).

**OTP non-negotiables satisfied:**

- #1: Every stateful subsystem (the Ratatouille runtime) runs as a
  supervised process.
- #7: Let it crash; supervise; restart. The `:transient` restart
  strategy means a clean exit or a `:normal` shutdown does not restart
  the TUI.

## Alternatives considered

- **`Application.ensure_all_started(:ratatouille)`** — no-op; the dep
  has no `mod:`. Rejected.
- **Start `Ratatouille.Runtime.Supervisor` directly inside the
  `Tau.Application` children list** — the TUI is optional and launched
  lazily; a static child would start and immediately fail (no TTY) on
  every application boot. Rejected.
- **Spawn a supervised Task that calls `Ratatouille.Runtime.Supervisor.start_link/1`**
  — still orphans the Ratatouille supervisor relative to Tau.Supervisor
  on Task exit. Rejected.
