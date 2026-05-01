# ADR-0011: Per-provider rate limiter is a stateful GenServer (not an ETS-owner)

- **Status:** Accepted
- **Date:** 2026-05-01
- **Deciders:** the agent loop, with no objection from @smug-haus
- **Related:**
  - Issue: #39 (sub-issue of #19)
  - Code: `lib/tau/providers/rate_limiter.ex`,
    `lib/tau/providers/rate_limiter/token_bucket.ex`,
    `lib/tau/providers/rate_limiter/supervisor.ex`
  - Prior: ADR-0002 (settings come from `Tau.Settings.Cache`, not
    `Application.get_env/2` for runtime state), ADR-0004 (PubSub is
    the cross-process event channel), ADR-0010 (cost tracker owns
    ETS, *not* GenServer state — the contrasting pattern), CLAUDE.md
    non-negotiable #1 (process-per-subsystem with the per-entity
    carve-out).

## Context

Issue #39 calls for per-provider request budgeting: a token-bucket
rate limiter sits between `Tau.Session` and the provider's HTTP
client, gating outgoing calls and reacting to upstream `429`
responses by halving the bucket. Five providers ship today
(Anthropic, OpenAI Chat, OpenAI Responses, Gemini, Bedrock); each
has its own RPM/TPM ceiling that the limiter has to honour
independently.

Two questions arose during design.

**(1) Why is this a GenServer, when ADR-0010 just made the cost
tracker an ETS-owner?** Cost counters fan in from many writers
(every session, every turn) and fan out to many readers. That
topology is the one place ADR-0010 calls out as ETS-shaped:
writes are independent (`update_counter` commutes), reads are
scans, and a GenServer mailbox would serialise an
embarrassingly-parallel workload.

The rate limiter is the opposite shape:

- **Writes are not commutative.** `take(bucket, n)` depends on
  `last_refill_ms` *and* on every prior `take` since that refill.
  The token-bucket refill is `min(size, current + elapsed_ms *
  rate / 1000)`, then subtract the request — the arithmetic
  cannot be expressed as a CRDT-style merge.
- **Reads and writes are 1:1.** Every provider call is exactly
  one `acquire/3` plus one `record_response/2`. The mailbox is
  *not* the bottleneck the upstream API is.
- **Wait queues are intrinsically serial.** When the bucket is
  empty, callers block on `GenServer.call/3` until refill. The
  GenServer mailbox *is* the wait queue — that's the Right Tool.
  Reimplementing it on top of ETS would be a hand-rolled mutex.

So this is a true stateful GenServer in the non-negotiable #1
sense. It's not a "Manager" GenServer (one process owning all
providers' state) — it's *one process per provider*, the
explicit carve-out CLAUDE.md grants for per-entity processes.

**(2) On settings reload, restart the limiter or update in
place?** The natural Elixir reflex is "let it crash; supervise;
restart". But restarting a limiter throws away its in-flight
wait queue — every blocked caller wakes up with `:noproc` and
reissues, *flooding the upstream right after a config change*.
That's a self-inflicted thundering herd at exactly the moment
the operator is most likely to be tuning the limiter.

Restarting is also unnecessary: `RateLimiter` runs the
token-bucket arithmetic in pure functions
(`Tau.Providers.RateLimiter.TokenBucket`); resizing a bucket is
a one-line state transformation that preserves
`current_tokens` and `last_refill_ms`. The supervisor handles
the *add new provider* and *remove configured provider* cases;
existing limiters self-update via their own `"settings"`
subscription (mirroring `Tau.Permissions.RuleSet`).

Pushback on the issue body's suggestion: the issue sketch
proposes `Application.get_env(:tau, :rate_limits)` for reading
config. That's forbidden by ADR-0002 — runtime config goes
through `Tau.Settings.Cache` (which publishes to
`:persistent_term` and broadcasts on PubSub).

## Decision

`Tau.Providers.RateLimiter` is a `GenServer`, one instance per
configured provider, supervised by
`Tau.Providers.RateLimiter.Supervisor` (a small static
`Supervisor` shell wrapping a `DynamicSupervisor` and a
reconciliation `GenServer`).

Specifics:

- **Pure core.** `Tau.Providers.RateLimiter.TokenBucket`
  implements `take/3`, `refill/2`, `halve/1`, `resize/3` as
  pure functions on a `%TokenBucket{size, current, rate_per_sec,
  last_refill_ms}` struct. The property suite pins these.
- **Process shape.** The GenServer holds
  `%{provider, rpm_bucket, tpm_bucket, half_until}`. `acquire/3`
  is a `GenServer.call/3` with caller-supplied timeout.
  `record_response/2` is a `cast`.
- **Naming.** Limiters register under a new
  `Tau.Providers.RateLimiter.Registry` (added to
  `Tau.Registries`) keyed by provider module.
- **Settings reload.** Each limiter subscribes to PubSub topic
  `"settings"` in its `init/1`. On `{:settings_reloaded,
  settings}` it resizes its buckets in place via
  `TokenBucket.resize/3`. The supervisor *also* subscribes —
  it reconciles the set of running children against the new
  config (start new, stop removed, leave existing alone).
- **429 handling.** When `record_response/2` is called with
  `%{status: 429}`, the limiter halves both buckets and sets
  `half_until = now + 60s`. Subsequent reloads within that
  window keep the halved size as a floor.
- **Telemetry.** `[:tau, :provider, :rate_limit, :acquired |
  :throttled | :rejected | :halved]`.

## Consequences

- The mailbox is the wait queue: blocked `acquire` calls park
  on `GenServer.call/3` and are woken when refill makes a
  permit available.
- Settings reload is non-disruptive. Operators can tune RPM /
  TPM live without flushing wait queues.
- Crashing a limiter loses its bucket state and waiters — they
  see `:noproc` from the call. The supervisor restarts the
  child fresh from the current settings.
- The implementation does NOT use a tokenizer to estimate
  token counts pre-flight. `Tau.Providers.Shared.TokenEstimate`
  uses `byte_size / 4` over the messages — within ~30% of real
  for English prose, fine for budget gating. A real tokenizer
  is filed as a follow-up.
- Provider `stream/3` callers see one new synchronous error:
  `{:error, :rate_limited}` (mirroring the existing
  `{:error, :missing_api_key}` pattern).

## Alternatives considered

- **ETS-owner shape (mirroring ADR-0010).** Rejected: bucket
  arithmetic is intrinsically serial, and a wait queue on top
  of ETS is a hand-rolled mutex.
- **One Manager GenServer for all providers.** Rejected by
  CLAUDE.md non-negotiable #1.
- **Crash-and-restart on settings reload.** Rejected: drops
  the in-flight wait queue, causing a thundering herd.
- **`Application.get_env/2` for config (issue body
  suggested).** Rejected per ADR-0002.

## Notes

The choice mirrors `Tau.Sessions.Supervisor` (per-session FSM
under a DynamicSupervisor) and `Tau.MCP.Supervisor`: per-entity
processes named via `Registry`, supervised dynamically,
reconciled against settings. The "reconcile, don't restart"
pattern is the shared idiom for "long-lived state that should
survive a config change".
