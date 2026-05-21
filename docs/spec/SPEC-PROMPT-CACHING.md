# SPEC-PROMPT-CACHING — Provider prompt caching

| **Status** | Draft v2 — covers M1 scope (Anthropic only). All other adapters carry `:none` defaults. Critic-reviewed; 4 BLOCKING findings folded in (path-1 marker handling, smarter D-064 placement, cost-tracker AC, header reconciliation). |
| --- | --- |
| **Owner** | tau-coordinator (Anthropic prompt cache is the M1 unlock for self-hosting cost) |
| **Method** | PSDH (`.claude/skills/design-reasoning`); L0 + L1 + boundary contracts. L2 deferred. |
| **Why now** | A single M1 verification run on 2026-05-20 consumed 7.05M uncached input tokens (~$106 in Anthropic spend) because `Tau.Providers.Anthropic` advertises `prompt_caching: true` and sets the beta header but emits no `cache_control` markers in the request body. User mandate (2026-05-20): "It's not usable without prompt caching." |

**Changelog:**

- v1 (#317 draft): initial design.
- v2 (#317, post-critic): adopted critic-recommended path (1) — markers are derived inside `build_body/3` per request and NEVER persisted to `data.messages`, eliminating cross-provider fallback handoff concerns entirely. Simplified `cache_regions/2` return shape to `:explicit | :automatic | :none` (no payload). Deferred `prepare_cache/3` until Gemini is actually scoped. Rewrote D-063/D-064 marker-placement rules to use "stable boundary" semantics that handle the tool-loop case and the post-compaction case correctly. Added AC-6 (cost tracker prices write/read at differential rates) — without this, the user-visible cost-regression signal stays invisible to `Tau.Cost`. Resolved C7 vs the always-on `extended-cache-ttl-2025-04-11` beta header by making the header conditional on a per-request opt-in. Replaced AC-2's manual smoke with a Replay-provider cassette test (factory-loop substance rule).

## 0. Why this spec exists

Without server-side prompt caching, every Tau session pays full input cost on every turn. A coordinator session re-sends 90%+ of its conversation history each turn — system prompt, tools array, prior assistant/tool_result messages — all replayed verbatim. With caching, only the new content is fresh; the stable prefix is served from the provider's cache at ~10% of full price.

This is coordination-heavy because:
- **Shared state** lives at the provider, keyed by exact prefix bytes. A change anywhere before a marker invalidates the cache from that point forward.
- **Temporal coupling.** The marker on turn N must align with the prefix that turn N+1 will re-send for the cache to hit. Wrong placement = silent miss = silent cost regression.
- **No error surface.** A miss is not an error — it just bills full price. Bugs accumulate as a budget drain rather than a stacktrace.
- **Mechanism diverges per provider** (see §2). A unified policy with per-adapter translation is required to avoid duplicating the placement logic in N adapter files.

## 1. PSDH triage

| Signal | Score (0–1) | Note |
|---|---|---|
| Shared mutable state | 1 | Provider cache; many requests read/write it; cache key derives from request structure |
| Temporal coupling | 1 | Marker placement on turn N must align with turn N+1's prefix bytes |
| Feedback loop | 0.5 | Misses are silent cost regressions, not visible errors |
| Cross-process | 0 | Caching is per-request; no Tau-side processes coordinate |
| State accumulation | 0.5 | Conversation grows over turns; the "what to cache" decision must move with it |

**Total: 3/5 → coordination-heavy → SPEC required (per `spec-before-code.md`).**

## 2. Mechanism families across Tau providers

Six families, derived from web research (2026-05-20). Cited sources in §10.

**Family A — Explicit per-block markers** (`cache_control: {type: "ephemeral"}`)
- Providers: Anthropic (direct), AWS Bedrock (Claude via InvokeModel and Converse `cachePoint`).
- Caller places markers on individual content blocks; up to 4 breakpoints per request; byte-exact prefix match; write surcharge (1.25× for 5 min, 2× for 1 h) + 90% read discount.
- Response: `usage.cache_creation_input_tokens`, `usage.cache_read_input_tokens`.

**Family B — Automatic prefix hashing** (zero opt-in)
- Providers: OpenAI, Azure OpenAI, Groq.
- Provider auto-detects prefix matches (first ~1024 tokens at minimum, 128-token increments after); no body field required; OpenAI/Azure accept an optional `prompt_cache_key` routing hint.
- 50% read discount; no write surcharge; 5–10 min TTL.
- Response: `usage.prompt_tokens_details.cached_tokens`.

**Family C — Automatic disk-backed prefix cache**
- Providers: DeepSeek.
- Same shape as Family B from the caller's perspective; differs in storage (disk, multi-day TTL).
- 90% read discount; no write surcharge; "a few hours to a few days" TTL.
- Response: `usage.prompt_cache_hit_tokens` / `usage.prompt_cache_miss_tokens` (note: different field names).

**Family D — Explicit resource-based caching**
- Providers: Google Gemini (direct + Vertex AI).
- Pre-flight: caller `POST`s a `cachedContent` resource with the content to cache, receives a resource name. Subsequent inference requests reference the resource name. **Storage is billed by the hour** (the only provider where caching can increase cost if hit rate is low).
- Response: `usageMetadata.cachedContentTokenCount`.

**Family E — Routing-key hint**
- Providers: Mistral.
- Caller supplies a `prompt_cache_key` string in the request body; backend uses it for routing; opaque to the caller (no cache-hit reporting).
- 90% read discount per Mistral's docs; no documented TTL.

**Family F — Transparent proxy**
- Providers: GitHub Copilot.
- GitHub's infrastructure applies caching when proxying. Tau adapter passes through.

## 3. Constraints (C1..C8)

- **★ [C1] Family A markers respect the 4-breakpoint ceiling.** Anthropic and Bedrock-Claude reject requests with >4 `cache_control` markers. The placement policy MUST be deterministic and total ≤4.

- **★ [C2] Stable-prefix ordering is the cross-family contract.** Even providers in Families B–E rely on stable content appearing at the start of the request for prefix matching to hit. The `Tau.Provider` contract MUST guarantee a canonical ordering — system blob → tools → message history → fresh user/tool-result input — for all adapters, irrespective of whether they need explicit markers. The canonical ordering is enforced at runtime by a shared `Tau.Providers.Shared.OrderingCheck.validate!/1` called from each adapter's `build_body/3`.

- **★ [C3] A miss must be observable without spelunking.** Cache hits/misses are silent in the API. Tau MUST surface a per-request hit-rate signal via the `[:tau, :session, :cache_usage]` telemetry event so cost regressions are noticed.

- **★ [C4] Marker derivation is a pure function** of `(system, tools, messages, opts)`. The Family A adapter MUST NOT consult `:os.system_time/0`, `Tau.Settings.Cache.get/0`, `:rand`, the process dictionary, or any other ambient state at marker-derivation time. This is the testable form of "no retroactive marker shifts" — D-061 retry re-builds the request body, and byte-identical inputs MUST produce byte-identical bodies.

- **★ [C5] Markers live in the request body, never in `data.messages`.** Family A adapters annotate content blocks inside `build_body/3` at request-construction time. The annotations are not persisted back to the session's message accumulator. This is the **critic's path (1)**: it eliminates cross-provider fallback handoff concerns at the source. The existing `Tau.Providers.Shared.ContentTransform.drop_cache_control/2` becomes a defensive backstop — never load-bearing — because there's nothing in `data.messages` to strip in the first place.

- **★ [C6] Behaviour additions are opt-in for adapter authors.** The new callbacks (`cache_regions/2`, `parse_cache_usage/1`) are `@optional_callbacks` on `Tau.Provider`. Dispatch is via `function_exported?/3` at call site (matches the existing `Tau.Provider.configure/1` pattern). A future adapter without caching MUST NOT block on this spec. Default behaviour: caching disabled (`cache_regions/2` returns `:none`; `parse_cache_usage/1` returns zeros).

- **★ [C7] 5-min ephemeral TTL only (in this PR).** Coordinator sessions complete within a 5-min window between consecutive turns. The 1-hour tier costs 2× write and offers no benefit for active sessions. The Anthropic adapter MUST NOT emit `ttl: "1h"` in any `cache_control` block. The `extended-cache-ttl-2025-04-11` beta header is CONDITIONALLY removed (it is currently in `@beta_headers`) — see Appendix B for the file change. A future opt-in (e.g., for resumable sessions) re-enables the header and the `ttl: "1h"` field together.

- **★ [C8] Cost tracker prices cache dimensions separately.** `Tau.Cost` (and any sibling cost-tracking module) MUST treat `cache_creation_input_tokens` and `cache_read_input_tokens` as distinct line items, priced at the per-model `cache_write_multiplier` (default 1.25 for Anthropic 5-min) and `cache_read_multiplier` (default 0.10 for Anthropic) respectively. Without this, the user-visible cost-regression signal is invisible.

## 4. Boundary contracts

### B1 — `Tau.Provider` behaviour extension

```elixir
# All callbacks @optional_callbacks; dispatch via function_exported?/3.
# Default behaviour when a callback is absent: caching disabled for that adapter.

@callback cache_regions(messages :: [Tau.Message.t()], opts :: map()) ::
            :explicit | :automatic | :none

@callback parse_cache_usage(provider_usage :: map()) ::
            %{
              write_tokens: non_neg_integer(),
              read_tokens: non_neg_integer(),
              storage_tokens: non_neg_integer(),  # for future Family D
              breakdown: map()                    # optional per-adapter metadata
                                                   # (e.g., Anthropic's 5m vs 1h split)
            }
```

`cache_regions/2` returns the policy *intent*:
- `:explicit` — adapter SHOULD emit cache markers inside its own `build_body/3`. Used by Family A (Anthropic, Bedrock-Claude). The adapter owns the placement; the callback is only a policy switch.
- `:automatic` — adapter relies on provider-side automatic prefix caching (Families B and C). No body changes required, but the adapter MUST honour the C2 canonical ordering.
- `:none` — caching disabled for this turn. Default for all adapters that don't implement the callback.

`parse_cache_usage/1` normalises the per-provider response usage into a common shape. `breakdown` is optional; Anthropic populates it with `%{ephemeral_5m: n}` (and `ephemeral_1h: m` once that path opens) so telemetry can distinguish tiers.

**Deferred to follow-up issues (Gemini scoping):**
- `prepare_cache/3` for Family D's pre-flight resource creation. Lifecycle (per-request vs per-session, invalidation triggers) will be specified when Gemini caching is actually implemented. Shipping the contract empty would commit to a shape the implementer might want to change.

### B2 — Canonical request ordering (enforced)

Every adapter's `build_body/3` MUST emit content in this order:

1. `system` (stable across turns)
2. `tools` (stable across turns)
3. Historical messages, oldest first (stable up to the latest stable boundary; see D-064)
4. Fresh user/tool-result input (variable; never cached)

`Tau.Providers.Shared.OrderingCheck.validate!/1` (new helper) takes the assembled body shape and raises if ordering is violated. Each adapter calls it as the last step of `build_body/3`. This converts AC-3 from a "negative audit" into a runtime invariant per the critic's f-14.

## 5. State model

Cache state is **server-side**, owned by the provider. Tau holds no session-level cache directory in this PR (Gemini's resource lifecycle is the deferred Family D case).

For Families A, B, C, E, F: the only Tau-side state is the canonical request shape and the marker positions derived per-request. **Nothing is persisted back to `data.messages`** (per C5). Markers exist only in the JSON body sent to the provider.

## 6. PSDH catalog (D-xxx) — runtime invariants

| ID | Statement | Severity | Detection |
|---|---|---|---|
| D-063 | **Cache region policy switch.** `Tau.Providers.Anthropic.cache_regions/2` MUST return `:explicit` when (a) the session has at least one message and (b) `opts[:caching]` is not explicitly disabled. Returning `:none` MUST cause `build_body/3` to skip all marker injection. Returning `:explicit` MUST cause `build_body/3` to inject markers per D-064. | high | unit test in `test/tau/providers/anthropic_cache_policy_test.exs`: `cache_regions/2` returns `:explicit` for non-empty messages, `:none` when `opts[:caching] == false` |
| D-064 | **Marker placement — pure function, stable-boundary semantics.** Marker positions are a pure function of `(system, tools, messages, opts)`. Three markers are emitted per request when their target region is non-empty: **(A)** the LAST text block of the `system` array; **(B)** the LAST tool spec in `tools`; **(C)** the LAST content block of the **last-stable-boundary message** in `messages`, defined as the most recent message that satisfies any of (in order of preference): (i) `%User{metadata: %{role: :compaction_summary}}` — the compaction summary is the strongest cache anchor when present; (ii) the second-to-last message whose `role` is `:assistant` OR `%ToolResult{}` — the message immediately before the freshest input; (iii) skip marker C entirely if no stable boundary exists (e.g., first turn with one user message). Total markers ≤3 per request; the 4-breakpoint ceiling is preserved with one headroom slot. **Derivation MUST NOT read** `:os.system_time/0`, `Tau.Settings.Cache.get/0`, `:rand`, or the process dictionary. | high | property test in `test/tau/providers/anthropic_cache_policy_test.exs`: assert byte-identical body for same input across two invocations 1.5 s apart with `Settings.Cache` reload in between; assert correct marker count for empty-system, no-tools, post-compaction, and tool-loop fixture scenarios |
| D-065 | **Usage normalization with breakdown.** `Tau.Providers.Anthropic.parse_cache_usage/1` MUST translate the response's `cache_creation_input_tokens` / `cache_read_input_tokens` fields into the canonical `%{write_tokens, read_tokens, storage_tokens: 0, breakdown: %{...}}` shape. `breakdown` carries the Anthropic-specific `ephemeral_5m_input_tokens` and `ephemeral_1h_input_tokens` split when the response includes them — Tau's adapter never requests 1h (C7) but the response can carry 1h tokens from server-side promotions and Tau MUST sum them into `write_tokens` for cost-tracking correctness. `storage_tokens` is always 0 for Anthropic (no storage billing). | medium | unit test on the parse function with three sample response payloads: (a) no cache activity; (b) write-only (first turn after marker emission); (c) mixed write+read with `breakdown.ephemeral_5m_input_tokens > 0` |

3 D-xxx entries. Each enforceable.

## 7. Acceptance criteria

- **AC-1 — Anthropic explicit markers placed.** A `tau run` against Anthropic emits a request body with `cache_control` markers on the last system block, last tool spec, and the last-stable-boundary message (when each is non-empty), per D-064. Verified by request-body assertions in `anthropic_cache_policy_test.exs` using `Tau.Providers.Replay`-style fixture (captured request body inspected, not just the response).

- **AC-2 — Cassette test asserts cache hit lifecycle.** A two-turn integration test using a Replay-provider cassette where turn 1's response carries `cache_creation_input_tokens > 0` and turn 2's response carries `cache_read_input_tokens > 0`. Assert `[:tau, :session, :cache_usage]` telemetry fires with the correct write/read split for each turn. **No real API key required.** This replaces the manual smoke from v1 per the critic's f-9 / f-13 — the factory loop's substance rule forbids "manual smoke" as a CI-blocking signal.

- **AC-3 — Canonical ordering enforced at runtime.** Every adapter's `build_body/3` calls `Tau.Providers.Shared.OrderingCheck.validate!/1`. A property test on each adapter (Anthropic, OpenAI, Azure OpenAI, Groq, Bedrock, Gemini, Mistral, DeepSeek) generates random message/tool shapes and asserts the validator passes for every adapter on every shape. A failing adapter raises and is caught by the property test.

- **AC-4 — Telemetry on hit rate.** Every assistant turn emits `[:tau, :session, :cache_usage]` telemetry with measurements `%{write_tokens, read_tokens, storage_tokens}` and metadata `%{session_id, provider, breakdown}`. The OTel reporter (SPEC-OTEL-REPORTER) consumes this. This is the user-facing signal for C3.

- **AC-5 — Regression guard against the 4-breakpoint cap.** A property test generates messages/tools/system that would naively want 5+ markers (e.g., a long compaction-summary-pinned conversation followed by many tool turns); assertion: the Anthropic adapter still emits ≤3.

- **AC-6 — Cost tracker prices cache dimensions.** `Tau.Cost` is extended to charge `cache_creation_input_tokens` at `model.cache_write_multiplier × input_price` (default 1.25 for Anthropic) and `cache_read_input_tokens` at `model.cache_read_multiplier × input_price` (default 0.10). Existing test fixtures for `Tau.Cost` are extended with a cache-bearing usage map; assert the per-line-item charges and the session total. This satisfies C8.

## 8. Scope of the first PR (#317) vs. follow-ups

**In scope for #317:**
- The two new behaviour callbacks (`cache_regions/2`, `parse_cache_usage/1`) declared as `@optional_callbacks` on `Tau.Provider`.
- `Tau.Providers.Shared.OrderingCheck.validate!/1` shared helper.
- Anthropic adapter implementation: `cache_regions/2` returns `:explicit` for non-empty sessions, `build_body/3` injects ≤3 markers per D-064, `parse_cache_usage/1` translates the response with `breakdown`.
- Removal of `extended-cache-ttl-2025-04-11` from `@beta_headers` in `lib/tau/providers/anthropic.ex` (C7). The base `prompt-caching-2024-07-31` header stays (it is GA-equivalent at this point; harmless to keep).
- OpenAI-family `cache_regions/2` returns `:automatic`; each adapter calls `OrderingCheck.validate!/1`.
- Telemetry event `[:tau, :session, :cache_usage]` wired in `Tau.Session` at the `:provider_done` boundary.
- `Tau.Cost` extension (AC-6).
- Tests for D-063, D-064, D-065, AC-1 through AC-6.
- SPEC-PROMPT-CACHING.md (this file) registered in `.claude/rules/spec-before-code.md`.

**Deferred to follow-up issues (file at PR-merge time):**
- **Bedrock-Claude explicit markers** — Family A. The C5 marker-isolation makes this safe to defer: Anthropic→Bedrock fallback no longer carries `cache_control` into the message accumulator (because nothing is persisted there), so the fallback hop is correct by construction. Bedrock simply caches nothing until its adapter implements `cache_regions/2`. Mechanical port of the Anthropic placement once it lands.
- **Gemini explicit caching** — Family D. Requires `prepare_cache/3` (lifecycle TBD), session-level cache-resource state. Not on the M1 critical path.
- **Mistral `prompt_cache_key`** — Family E. Trivial: hash the stable prefix, attach as a top-level body field. The `cache_regions/2` mechanism doesn't fit Family E directly; the Mistral PR may add a separate callback or extend `:explicit` semantics. Defer until Mistral becomes a coordinator-relevant provider.
- **DeepSeek field-name handling** — adapter exists; response uses `prompt_cache_hit_tokens` instead of `cached_tokens`; needs a `parse_cache_usage/1` implementation. Trivial.
- **Copilot proxy passthrough** — verify the adapter doesn't strip caching headers when proxying. Audit + test, no logic change expected.

**Permanently out of scope:**
- A Tau-side cache (e.g., persisting prompts to local SQLite for replay-on-cache-miss). Provider caches are sufficient; a second cache layer would duplicate effort and add invalidation complexity.
- Cache-warming background jobs. Optimization, not correctness.

## 9. Why this spec is small

This spec deliberately ships only the policy layer + the Anthropic implementation. Each future adapter can be added with a one-callback PR that satisfies the contract. The behaviour pattern with `@optional_callbacks` makes the incremental rollout safe: an adapter without the callback gets the default (caching disabled) and continues working.

The C5 path-1 decision (markers are body-build-time only) makes provider fallback safe without per-destination filtering. This is the single most important design choice in v2 — it removes an entire failure surface that v1 left unaddressed.

The user mandate is M1 cost. M1 uses Anthropic. Shipping more than Anthropic in this PR risks scope creep on the M1 critical path.

## 10. Sources (web research, 2026-05-20)

- Anthropic: https://docs.anthropic.com/en/docs/build-with-claude/prompt-caching
- OpenAI: https://openai.com/index/api-prompt-caching/
- Azure OpenAI: https://learn.microsoft.com/en-us/azure/ai-services/openai/how-to/prompt-caching
- AWS Bedrock: https://docs.aws.amazon.com/bedrock/latest/userguide/prompt-caching.html
- Gemini: https://ai.google.dev/gemini-api/docs/caching
- Groq: https://console.groq.com/docs/prompt-caching
- DeepSeek: https://api-docs.deepseek.com/guides/kv_cache
- Mistral: https://docs.mistral.ai/api
- Copilot: https://docs.github.com/en/copilot/reference/ai-models/model-hosting

## Appendix B — Source map for the first PR

| Constraint | Files |
|---|---|
| D-063, D-064 | `lib/tau/provider.ex` (new `@optional_callbacks` declarations with `@callback` specs), `lib/tau/providers/anthropic.ex` (`cache_regions/2`, `build_body/3` marker injection per D-064 stable-boundary semantics, removal of `extended-cache-ttl-2025-04-11` from `@beta_headers`), `test/tau/providers/anthropic_cache_policy_test.exs` (new file) |
| D-065 | `lib/tau/providers/anthropic.ex` (`parse_cache_usage/1`), `test/tau/providers/anthropic_cache_policy_test.exs` (parse unit tests with `breakdown` field) |
| C2, AC-3 | `lib/tau/providers/shared/ordering_check.ex` (new shared helper, `validate!/1`), all adapter `build_body/3` paths (call site addition), per-adapter property tests |
| AC-2 | `test/tau/providers/anthropic_cache_cassette_test.exs` (new file; uses a recorded request/response cassette to drive the two-turn flow without a real API key) |
| AC-4 | `lib/tau/session.ex` (emit `[:tau, :session, :cache_usage]` telemetry on each `:provider_done` event), `test/tau/session/cache_telemetry_test.exs` (new file) |
| AC-6, C8 | `lib/tau/cost.ex` (add `cache_write_multiplier`, `cache_read_multiplier` to model pricing entries; extend per-line-item charging), `test/tau/cost_test.exs` (extend fixtures with cache-bearing usage maps) |
