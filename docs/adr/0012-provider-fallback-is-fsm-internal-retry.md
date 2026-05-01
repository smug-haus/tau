# ADR-0012: Provider fallback is an FSM-internal retry, not a wrapper provider

- **Status:** Accepted
- **Date:** 2026-05-01
- **Deciders:** the agent loop, with no objection from @smug-haus
- **Related:**
  - Issue: #41 (sub-issue of #19)
  - Code: `lib/tau/session.ex` (the new
    `:provider_event` retryable-error clause and the
    `original_provider` data field), `lib/tau/providers/shared/content_transform.ex`,
    `lib/tau/session/events/provider_fallback.ex`,
    `lib/tau/settings/schema.ex` (`providers.fallback_chains`).
  - Prior: ADR-0002 (settings come from `Tau.Settings.Cache`),
    ADR-0008 (user code never runs synchronously in the FSM),
    ADR-0009 (user messages queue during an active turn),
    ADR-0011 (per-provider rate limiter — fallback can be
    triggered by `:rate_limited`).

## Context

A retryable provider error today (e.g. a 5xx mid-stream, or the
brand-new `{:error, :rate_limited}` synthesised by
`Tau.Providers.RateLimiter` / surfaced as
`%Tau.Provider.Event.Error{retryable?: true}`) ends the assistant
turn with `stop_reason: :error`. Issue #41 calls for an automatic
fallback to a configured next provider, applying the cross-provider
content transforms we already need for transcript replay
(`Tau.Providers.Shared.IdSanitizer` + a new `ContentTransform`).

Two layering questions had to be answered before writing code.

**(1) Where does the retry live? FSM clause vs. wrapper provider.**
A natural OO refactor would put fallback behind a
`Tau.Providers.Fallback` module that itself implements
`Tau.Provider`, wraps a `[primary | fallbacks]` list, and is
transparent to the session FSM. Concretely:

- It would need its own subscription to `Tau.Settings.Cache` to
  observe chain changes — duplicating the per-session refresh
  the FSM already gets for free at the start of every turn.
- The per-provider rate limiter (ADR-0011) needs to know which
  provider is being called *right now* so it can debit the right
  bucket; a wrapper would have to thread the inner provider
  through `acquire/3` separately, breaking the "one provider
  module = one limiter" mapping.
- The reset-the-assembler-on-error path is an FSM-internal
  transition; you can't replay a half-streamed Anthropic SSE on
  OpenAI Chat. A wrapper that wanted to swap mid-stream would
  re-implement the same bookkeeping the FSM already does.
- The `Tau.Provider` behaviour is *streaming providers*, not
  *orchestration*. Adding a callback or a new struct field for
  fallback would conflate the two concerns and force every real
  provider to opt out.

The FSM already owns:

- the assembler reset on `%Event.Error{}`
  (`Tau.Message.Assembler.step/2` records the error; the FSM
  finalises the assistant message),
- shutting down a still-running `provider_task` on cancel,
- the persistence handle, so a `provider_fallback` JSONL event
  is one extra `persist_event/3` call.

Threading retry through the FSM is **one new clause + one new
data field**. A wrapper provider is an entire faux-provider
module that has to mock half the FSM's surface area.

**(2) Is fallback per-message or session-sticky?** A session that
falls back from Anthropic to OpenAI on one turn could either:

- *Per-message*: the next user turn always tries Anthropic first
  again. If Anthropic is back, we use it; if not, we fall back
  again.
- *Session-sticky*: once we fall back, the rest of the session
  continues on the new provider until the user explicitly
  reconfigures via `Tau.update_provider/2`.

Issue #41's body floats *per-message*. We agree, but the issue's
phrasing "drives the next user turn" is ambiguous; we are pinning
it here.

Failures in this domain are overwhelmingly *transient*: 429
rate-limits, 5xx blips, regional Bedrock outages. A session-sticky
swap would mask the recovery — the operator restores the primary
upstream, but the session keeps using the secondary until the
process restarts. Worse, if the secondary is the cheaper / lower-
quality fallback, every user gets a silently-degraded experience
with no signal that the primary is healthy again.

Per-message has the opposite shape: each turn is a fresh probe of
the primary. The cost is one extra failed call per outage-turn, in
exchange for automatic recovery and a clear telemetry / PubSub
signal (`%Events.ProviderFallback{}`) the operator can react to.

## Decision

Provider fallback is implemented as a new `:provider_streaming`
clause on `Tau.Session`, gated by a per-turn `fallback_chain_remaining`
list. Fallback is per-message: at the start of every
`:start_provider` internal transition, the chain is re-derived from
`Tau.Settings.Cache.get/0` keyed by the original (user-configured)
provider.

Specifics:

- **New data field.** `data.original_provider` carries the
  user-configured provider for the lifetime of the session.
  `data.provider` shape-shifts during a fallback turn and is
  restored to `original_provider` at `finalize_assistant/2`.
  We chose the explicit field over shape-shifting `data.provider`
  alone because (a) snapshots, persistence headers, and
  `Tau.snapshot/1` callers see a stable `:provider` between turns,
  and (b) the next turn's `:start_provider` clause re-derives the
  chain from `original_provider`, not whichever fallback won the
  previous turn.

- **Fallback chain initialisation.** Inside
  `handle_event(:internal, :start_provider, :provider_streaming, data)`,
  read
  `Tau.Settings.Cache.get() |> get_in([:providers, :fallback_chains, original_provider])`
  (with string-key fallback) and store it as
  `data.fallback_chain_remaining`.

- **Retryable-error clause.** A new `handle_event(:info,
  {:provider_event, %PEvent.Error{retryable?: true} = ev},
  :provider_streaming, data)` clause, inserted *before* the
  generic `:provider_event` clause, branches:

  - `fallback_chain_remaining == []` → fall through to the
    existing error path (synthesise a Done with
    `Assembler.step/2`, `finalize_assistant/2`).
  - non-empty → pop the next provider, emit
    `[:tau, :provider, :fallback]` telemetry, broadcast
    `%Events.ProviderFallback{}`, persist a `provider_fallback`
    JSONL event, transform `data.messages` via
    `Tau.Providers.Shared.ContentTransform.transform/3`, shut
    down the still-running provider task, reset the assembler,
    and re-enter `:start_provider` with the new provider.

- **Pure content transform.** The new
  `Tau.Providers.Shared.ContentTransform.transform/3` module is
  pure: strips `%{type: :thinking}` blocks unconditionally
  (signatures don't survive cross-provider hops), downgrades
  `%{type: :image}` blocks to `[image: ...]` placeholders when
  the destination's `capabilities().vision == false`, drops
  `cache_control` map keys when `prompt_caching == false`, and
  threads through `Tau.Providers.Shared.IdSanitizer.sanitize/2`
  for tool-call id rewrites. Pure → fine to call inline in the
  FSM (ADR-0008 only forbids *user-supplied* sync work).

- **Settings shape.** `providers.fallback_chains` is a map from
  provider atom (or stringified module) to a list of provider
  modules. Module strings are resolved at load time via
  `String.to_existing_atom/1`; unknown modules fail closed
  (rejected by `Tau.Settings.Schema`'s validator) so a typo in
  `.tau/settings.json` doesn't produce a silent no-op fallback.

## Consequences

- The FSM gains one clause and one data field. No provider
  module changes; no new behaviour callback.
- Fallback semantics are uniform across providers: if a stream
  emits `%Event.Error{retryable?: true}`, the chain takes over.
  Providers don't need to know about each other.
- Cross-process consumers (TUI, telemetry log, persistence
  reader) get a single canonical signal:
  `[:tau, :provider, :fallback]` telemetry +
  `%Events.ProviderFallback{}` PubSub. The TUI can render
  "fell back from Anthropic to OpenAI" in the status bar
  without reaching into `:sys.get_state/1`.
- Per-message means every turn starts with a fresh probe of the
  primary. For a totally-down primary, that's one wasted call
  per turn; in exchange, recovery is automatic.
- ADR-0009's queue semantics are preserved: a
  `:user_message` cast that arrives mid-fallback stays
  postponed until the FSM returns to `:awaiting_user`, exactly
  as it did during a non-fallback turn.
- A session that exhausts its chain ends up exactly where the
  pre-fallback FSM ended up: a synthetic
  `%Assistant{stop_reason: :error}` and a return to
  `:awaiting_user`. No new error surface for callers.

## Alternatives considered

- **Wrapper `Tau.Providers.Fallback` implementing `Tau.Provider`.**
  Rejected: duplicates settings observation, breaks the
  one-limiter-per-provider mapping, and re-implements the
  assembler-reset path the FSM already owns.
- **New behaviour callback (`@callback fallback_for/1`).**
  Rejected: providers don't know about each other, and the
  callback would have nothing to compute that
  `Tau.Settings.Cache` doesn't already publish.
- **Session-sticky fallback.** Rejected: masks recovery,
  silently degrades quality, and offers no operator signal
  when the primary returns. Per-message is one wasted call
  per outage-turn — a price worth paying for honesty.
- **Wait-and-retry the same provider on
  `%Event.Error{retryable?: true}` before falling back.**
  Tabled. The rate limiter (ADR-0011) already does in-mailbox
  backoff for 429s; once we add a real retry policy that
  question recurs. For now, retryable-on-the-stream means
  "the provider gave up retrying internally; fall over."

## Notes

The "drives the next user turn" wording in #41's open-questions
section is consistent with this ADR if you read "drives" as "is
the starting point of"; we are explicitly not using the
fallback-winner as the next turn's starting provider.

The cross-provider content rewrites are the same shape we'll
need for `Tau.update_provider/2` ergonomic reuse and for any
future "replay this transcript on a different provider" workflow,
so `ContentTransform` is intentionally kept as a free-standing
pure module rather than being inlined into the FSM clause.
