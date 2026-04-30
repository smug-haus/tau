# ADR-0008: User code never runs synchronously inside the session FSM

- **Status:** Accepted
- **Date:** 2026-04-30
- **Deciders:** @smug-haus
- **Related:**
  - Issue: #59
  - Code: `lib/tau/session.ex` (slash-command dispatch path)
  - Prior: ADR-0001 (issues), ADR-0002 (provider_ctx), ADR-0005
    (skills are read-only), ADR-0007 (compaction summaries pin)

## Context

`Tau.Session` is a `:gen_statem` — a single process owns the
session's mailbox. Anything that runs inside its `handle_event`
callbacks blocks every other message: cancel signals, provider
events, post-tool-use hooks, the lot.

Tools (`Tau.Tool.execute/2`) already run inside Tasks under
`Tau.Tools.TaskSupervisor`, exactly to prevent a misbehaving tool
from deadlocking the FSM. Slash commands (`Tau.Command.execute/2`)
did not — `Tau.Session.expand_slash_command/2` invoked
`mod.execute/2` directly inside `handle_event(:cast, {:user_message, msg}, _, data)`.
A slash command that did `Process.sleep(:infinity)`, called a
synchronous network API, or simply raised would deadlock or crash
the session (#59).

We need a uniform rule: **user-supplied callbacks (commands, hooks,
tools, future extensions) never run synchronously inside the FSM.**

## Decision

Slash-command bodies dispatch via
`Task.Supervisor.async_nolink/2` under
`Tau.Tools.TaskSupervisor`. The session FSM holds a `:command_task`
field on its data while waiting; the task's result arrives as a
`{:command_done, result, original_msg}` info message that
`handle_event/4` consumes the same way it consumes `{:tool_done, …}`.

While `command_task` is set, additional `{:user_message, _}` casts
are **postponed** (gen_statem's `:postpone` action) so the user's
follow-up message lands in order after the command completes.

Cancellation kills the command task the same way it kills tool
tasks.

Specifics:

- Dispatch path:
  `expand_slash_command/2` returns either `:passthrough` (no
  slash command, or a file-command — file commands are pure
  `File.read/1` and stay synchronous) or
  `{:async, mod, name, args, msg}`. The handler spawns the task
  and stays in `:awaiting_user` with `command_task: task` set.
- Result handler:
  `handle_event(:info, {:command_done, result, original_msg}, _, data)`
  applies the result (`{:inject, _} | {:replace, _} | {:run, _} | :ignore`)
  to `original_msg` and falls through to the rest of the
  user-message handling (hooks, persist, dispatch to provider).
- Crash handler: `try/rescue` inside the task wraps every
  `mod.execute/2`. A crash becomes
  `{:command_done, {:crashed, msg}, original_msg}`; the session
  surfaces a synthetic error message instead of falling over.
- Timeout: hard 30s default per command. The task is shut down
  with `Task.shutdown(task, :brutal_kill)` and the result is
  `{:command_done, {:timeout, 30_000}, msg}`.

## Consequences

- A misbehaving slash-command extension can no longer deadlock or
  crash the session FSM. The worst case is a 30s wait until the
  task is brutally killed.
- Slash commands gain the same isolation guarantees tools have:
  supervised, crash-isolated, observable via telemetry.
- The session's data struct grows a `:command_task` field. The
  state itself doesn't multiply — gen_statem stays in
  `:awaiting_user` while the command runs; postpone handles
  ordering.
- Follow-up commands typed by the user while the previous one
  runs are postponed (and processed in order), not dropped.
- File-commands (`Tau.Commands.Files`) stay synchronous — they're
  bounded `File.read/1`s with no user code involved. Promoting
  them to async would buy nothing.

## Alternatives considered

- **Wrap `mod.execute/2` in `try/rescue` + Task.yield(timeout)**
  inside `handle_event/4`. Bounds blocking time but doesn't
  achieve concurrent responsiveness (cancel sits in the mailbox
  for the full timeout). Worse than the spawn-and-info approach
  for ~10 LOC less.
- **Run the entire `handle_event(:cast, {:user_message, …})` in
  a Task.** Would also work for hooks/tool dispatch, but the FSM
  needs the message-ordering guarantees that gen_statem postponing
  gives. Async-everything is a much larger refactor for a smaller
  ergonomic win.
- **Reject slash-command extensions that look "slow" (heuristic
  on body length etc.).** False positive nightmare. Don't.

## Notes

The same rule should apply to future `Tau.Hook` invocations that
currently run synchronously in
`Tau.Hooks.Dispatcher.run_one/3` — programmatic
`mod.handle/2` is in the FSM's process. Hooks ship inline today
because they're expected to be fast and synchronous (rewrite
payload, return). When that becomes an issue, file an ADR
superseding this one to cover hooks too.

The 30s default timeout is configurable via
`Application.get_env(:tau, :slash_command_timeout_ms)`. Long-running
commands should structure themselves as `{:run, "<prompt>"}`
returns that drive the model rather than blocking the command
worker.
