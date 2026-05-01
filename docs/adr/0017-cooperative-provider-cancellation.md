# ADR-0017: Cooperative cancellation of in-flight provider streams

- **Status:** Accepted
- **Date:** 2026-05-01
- **Deciders:** @smug-haus
- **Related:**
  - Issue: #69
  - Code: `lib/tau/session.ex`, `lib/tau/providers/shared/finch_stream.ex`,
    `lib/tau/providers/{anthropic,gemini,bedrock,replay}.ex`,
    `lib/tau/providers/openai/{chat,responses}.ex`,
    `lib/tau/provider.ex`
  - Prior ADRs: ADR-0002 (`provider_ctx` is the runtime config channel)

## Context

`Tau.Session` cancelled in-flight provider streams via
`Task.shutdown(provider_task, :brutal_kill)`. Brutally killing the
streaming task has three problems:

1. The upstream HTTP connection is half-open until the OS-level TCP
   timeout fires. Finch's connection pool gets the socket back
   eventually, but the provider's billing meter keeps running.
2. SSE streams may emit trailing events after the cancel arrives;
   those events race a freshly-started subsequent turn through the
   `{:provider_event, _}` mailbox.
3. It violates the spirit of "let it crash; supervise; restart"
   (CLAUDE.md non-negotiable #7). Brutal-killing our own streaming
   task is fine — the task is internal infrastructure, not user
   code — but the implied catch on the *next* turn's setup makes
   the design fragile.

We need a path where the streaming task observes a cancel signal
between chunks and exits cleanly, releasing the upstream socket and
emitting a final `%Event.Error{reason: :cancelled}` so the assembler
records partial content and the persistence layer logs a coherent
transcript.

## Decision

Cancellation is cooperative by default. The session allocates a
small `:counters` array (one slot, single counter) per provider
stream, threads it through `Tau.Provider.stream/3`'s `ctx` map as
`:cancel_flag`, and the streaming engine
(`Tau.Providers.Shared.FinchStream`) checks the counter at every
receive boundary. When the counter is non-zero the engine emits
`%Event.Error{reason: :cancelled, retryable?: false}` and halts the
`Stream.resource`, which triggers its `cleanup/1` and lets the
underlying Finch task be torn down promptly via
`Task.shutdown(:brutal_kill)` — that kill is internal-only (we own
the task), it does not catch a `:exit` from user code, and it
completes the socket close path Finch needs to return the
connection.

Specifics:

- `Tau.Provider.ctx` documents `:cancel_flag` as an optional key
  whose value is a `:counters` reference. Providers that don't
  honour the flag still work; providers that do (all five real
  ones, plus `Replay` for tests) honour it via the shared
  streaming engine or their own chunk loop.
- `Tau.Session.handle_event(:cast, :cancel, _, _)` sets the flag
  with `:counters.add(flag, 1, 1)`, then calls
  `Task.yield(provider_task, 250)`. If yield returns `{:ok, _}`
  the cooperative path completed and `[:tau, :provider, :request,
  :cancelled]` telemetry fires; otherwise
  `Task.shutdown(provider_task, :brutal_kill)` is the fallback and
  `[:tau, :provider, :request, :brutal_kill]` fires instead.
- The persisted JSONL `cancellation` record carries the mechanism
  (`reason: "cooperative"` or `reason: "brutal_kill"`) plus the
  user-facing `cause` (`"user"`).

The 250ms timeout was chosen to be a few times the typical SSE
chunk period (10–60ms for most provider streams) so a healthy
stream always returns through the cooperative path, while a wedged
stream (TLS retransmit storm, decoder deadlock) doesn't keep the
session pinned indefinitely. It is not user-configurable today;
file an issue if a deployment needs to tune it.

## Consequences

- Cancelled streams release the upstream socket within one chunk
  boundary in the common case. Partial assistant content is
  preserved on the assembler before the `%Event.Error{reason:
  :cancelled}` lands, so fork/resume sees a coherent transcript.
- The brutal-kill path remains as a safety net. Tests can force it
  by ignoring the cancel flag (e.g. a Replay variant whose chunk
  loop never observes the counter).
- `Tau.Provider.ctx` now has a documented additive key. The type
  is still `map()` (per ADR-0002, providers claim keys without
  behaviour-level coordination), so existing third-party
  providers continue to compile and run unchanged — they just
  forfeit cooperative cancellation until they thread the flag
  through their own chunk loop.
- Telemetry consumers that filter on
  `[:tau, :provider, :request, :*]` see two new tail events
  (`:cancelled`, `:brutal_kill`). The default handler in
  `Tau.Telemetry.Handlers` attaches both.
- `:counters` is part of OTP — no new dependency.

## Alternatives considered

- **Use `Process.flag(:trap_exit, true)` + a termination message
  from the FSM.** Requires the streaming task to handle the
  message in its own receive loop, which means restructuring
  every provider's stream to be a manual receive loop. Rejected:
  too much refactoring for a feature that only the streaming
  engine needs to know about.
- **Use a registered name and a `Process.whereis/1 |> send/2`
  cancel signal.** Banned by CLAUDE.md non-negotiable #4
  ("never `Process.whereis/1 |> send(...)`. Never `:global`.").
- **Use `Process.monitor/1` and have the streaming task watch the
  FSM pid for a `:DOWN`.** Helps if the FSM crashes, but
  doesn't help if the FSM wants to cancel a single turn while
  staying alive. Doesn't compose with the per-turn semantics.
- **Use `Phoenix.PubSub` topic per session for cancel.** Works,
  but every provider would need to subscribe and demux. The
  `:counters` ref is leaner: one allocation, two operations
  (`add/3`, `get/2`), no PubSub round-trip.
- **Skip the cooperative path entirely and just shorten the brutal
  kill grace period.** Doesn't solve the upstream-socket problem
  — the kill is from the BEAM's perspective, not the kernel's.

## Notes

`:counters` is preferred over `:atomics` because the cancel flag
is a single boolean — `:counters.new(1, [])` is cheap, the
`:counters.add/3` from the FSM and `:counters.get/2` from the
streaming task are both lock-free, and the ref is a normal Erlang
term (cheap to put in a map and pass through `provider_ctx`).

If a future provider needs richer cancel state (e.g. a "soft
stop" that drains the current sentence before halting), extend
the counter to two slots and document the protocol in this ADR's
successor — don't repurpose slot 1.
