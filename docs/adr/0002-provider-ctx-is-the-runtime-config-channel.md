# ADR-0002: Provider runtime configuration goes through `:provider_ctx`, not `Application` env

- **Status:** Accepted
- **Date:** 2026-04-30
- **Deciders:** @smug-haus
- **Related:**
  - Issue: #51 (the contradiction this ADR resolves)
  - Code: `lib/tau.ex`, `lib/tau/session.ex`, `lib/tau/provider.ex`,
    `lib/tau/providers/replay.ex`
  - Non-negotiable: "No `Application.put_env/3` for runtime state"
    (CLAUDE.md non-negotiable #1)

## Context

`Tau.Provider.stream/3` accepts a `ctx :: map()` whose documented
keys (`:session_id`, `:cancel_pid`, `:request_id`) cover identity
and lifecycle but not configuration. Provider implementations have
historically reached for `Application.get_env(:tau, __MODULE__)` to
read per-call config — most visibly `Tau.Providers.Replay`, which
takes a `:fixture` from app env.

This made tests painful and broke the project's
"no `Application.put_env/3` for runtime state" rule:

- Every test that needed a Replay fixture set
  `Application.put_env(:tau, Tau.Providers.Replay, fixture: ...)`
  from inside `setup` and reset it in `on_exit`. App env is
  process-global, so tests had to be `async: false` and
  near-misses produced confusing leaks across files.
- The Replay moduledoc explicitly forbade exactly the pattern
  the tests needed (#51).

We need a per-session, non-persisted, in-memory channel for
runtime provider config that tests can populate cleanly and
production code uses for things like routing tags, custom
headers, replay fixtures, etc.

## Decision

`Tau.start_session/1` accepts a new `:provider_ctx` option, a map
that is stored on the session FSM's data and **merged into the
`ctx` argument every time the session calls `provider.stream/3`**.
The session's identity fields (`:session_id` etc.) take
precedence; `:provider_ctx` fills in everything else.

```elixir
{:ok, sid} =
  Tau.start_session(
    provider: Tau.Providers.Replay,
    provider_ctx: %{replay_fixture: events}
  )
```

Specifically:

- `provider_ctx` is **not persisted** in the JSONL session header
  (unlike `:metadata`). Non-JSON-encodable values (function
  references, raw event structs, agent pids) are fine.
- `provider_ctx` is **not propagated to forks/resumes**. Resuming
  a session from disk produces an empty `provider_ctx`; callers
  that need per-resume config supply it on `Tau.resume/1` (TBD —
  follow-up if anyone needs it).
- Providers that read `provider_ctx` keys document them on their
  own moduledoc; the `Tau.Provider` ctx type stays
  intentionally open (`map()`) so providers can claim whatever
  keys they need without behaviour-level coordination.
- `Application.get_env(:tau, ProviderModule)` remains a valid
  fallback for genuinely deployment-wide config (default model,
  endpoint URL, API key resolution chain). It must not be set
  from inside a `setup` block.

## Consequences

- Tests that need per-test provider config become trivially
  `async: true`-eligible (the per-test config is per-session,
  not global).
- Replay's moduledoc no longer lies: tests pass fixtures via
  `provider_ctx`, not `Application.put_env`.
- Other providers (Anthropic, Gemini, Bedrock, OpenAI) gain a
  natural extension point for things like per-request routing
  hints, custom signing keys, or trace IDs without polluting
  `:metadata` (which IS persisted) or app env.
- Adds ~15 lines to `Tau.Session.init/1` and one option to
  `Tau.start_session/1`. The cost is small.
- Resume / fork lose `provider_ctx`; that's a deliberate
  trade-off (the persisted state should be sufficient to
  reconstruct a session, and provider-side config is
  inherently call-site-specific). If a user reports needing
  resume-time provider_ctx, file a follow-up.

## Alternatives considered

- **Pass via `:metadata`.** Rejected because metadata is
  persisted via `Jason.encode!/2` — non-encodable values (event
  structs, pids, fns) crash the session at init. ADR-0001's
  metadata-contract docstring already pins this constraint.
- **Per-test stub provider modules.** Workable but verbose; each
  test inlines a `defmodule` and the helper-module-per-test
  pattern doesn't extend cleanly to non-test callers (production
  routing tags, etc.) that have the same need.
- **Process dictionary on the test pid + a registered name in
  the test's setup.** Works, but the FSM runs in a different
  process so the test can't put-and-the-FSM-reads. Solving that
  needs an Agent or a registered name per test, which is more
  moving parts than the `:provider_ctx` opt.
- **Add specific opt-keys to `Tau.start_session/1` for each
  provider's needs.** Doesn't scale; `Tau.Providers.MyVendor`
  shouldn't have to land changes in `Tau.start_session/1` to
  configure itself.

## Notes

The merge in `Session.start_provider` is one-direction
(`Map.merge(provider_ctx, session_fields)` — session fields win).
Providers cannot override `:session_id` from `provider_ctx`,
which prevents tests / extensions from confusing the FSM about
its own identity.

If a future provider needs per-call (not per-session)
configuration — e.g. routing the next request differently — the
caller can update `provider_ctx` between turns via a future
`Tau.update_session/2`-style API. Not implemented yet; file an
issue if needed.
