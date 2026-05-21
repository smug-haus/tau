# SPEC-PROMPT-CACHING — Provider prompt caching

| **Status** | Draft — covers M1 scope (Anthropic + OpenAI-family ordering). Gemini explicit, Mistral, Bedrock-native deferred. |
| --- | --- |
| **Owner** | tau-coordinator (Anthropic prompt cache is the M1 unlock for self-hosting cost) |
| **Method** | PSDH (`.claude/skills/design-reasoning`); L0 + L1 + boundary contracts. L2 deferred. |
| **Why now** | A single M1 verification run on 2026-05-20 consumed 7.05M uncached input tokens (~$106 in Anthropic spend) because `Tau.Providers.Anthropic` advertises `prompt_caching: true` and sets the beta header but emits no `cache_control` markers in the request body. User mandate (2026-05-20): "It's not usable without prompt caching." |

**Changelog:** #317: initial draft. Defines a `Tau.Provider` behaviour extension (`cache_regions/2`, optional `prepare_cache/3` for resource-based caches, `parse_cache_usage/1`); D-063 (cache-region policy), D-064 (marker placement determinism), D-065 (response-usage normalization). Scope of the first PR is the behaviour callbacks + Anthropic implementation + OpenAI-family ordering verify; remaining adapters listed under §8 deferrals.

## 0. Why this spec exists

Without server-side prompt caching, every Tau session pays full input cost on every turn. A coordinator session re-sends 90%+ of its conversation history each turn — system prompt, tools array, prior assistant/tool_result messages — all replayed verbatim. With caching, only the new content is fresh; the stable prefix is served from the provider's cache at ~10% of full price.

This is coordination-heavy because:
- **Shared state.** The cache lives at the provider, keyed by exact prefix bytes. A change anywhere before a marker invalidates the cache from that point forward.
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
- Gemini 2.5+ also has an implicit prefix-cache (Family B-style), but the discount is only guaranteed via the explicit path.
- Response: `usageMetadata.cachedContentTokenCount`.

**Family E — Routing-key hint**
- Providers: Mistral.
- Caller supplies a `prompt_cache_key` string in the request body; backend uses it for routing; opaque to the caller (no cache-hit reporting).
- 90% read discount per Mistral's docs; no documented TTL.

**Family F — Transparent proxy**
- Providers: GitHub Copilot.
- GitHub's infrastructure applies caching when proxying to Anthropic/Bedrock/Google; not exposed to the caller. Tau's adapter passes the request through; Copilot handles caching at the proxy.

## 3. Constraints (C1..C7)

- **★ [C1] All Family A markers respect the 4-breakpoint ceiling.** Anthropic and Bedrock-Claude reject requests with >4 `cache_control` markers. The placement policy MUST be deterministic and total ≤4.

- **★ [C2] Stable-prefix ordering is the cross-family contract.** Even providers in Families B–E rely on stable content appearing at the start of the request for prefix matching to hit. The `Tau.Provider` contract MUST guarantee a canonical ordering — system blob → tools → message history → fresh user input — for all adapters, irrespective of whether they need explicit markers.

- **★ [C3] A miss must be observable without spelunking.** Cache hits/misses are silent in the API; Tau MUST surface a per-request hit-rate signal via telemetry so cost regressions are noticed.

- **★ [C4] No retroactive marker shifts within a turn.** Anthropic's cache key is the byte-prefix up to the marker. If Tau changes a marker position mid-turn (e.g., on retry), the prefix bytes differ and the cache invalidates. The marker positions MUST be derived once per request and not adjusted on retry.

- **★ [C5] Cache strategy is per-provider, not per-session.** A `--provider anthropic` session has Anthropic's policy; switching providers (D-041 model swap or ADR-0012 fallback) MUST cleanly switch caching strategy without lingering markers in the message accumulator that the new provider can't interpret.

- **★ [C6] Behaviour additions are opt-in for adapter authors.** The new callbacks (`cache_regions/2`, optional `prepare_cache/3`, optional `parse_cache_usage/1`) MUST have default implementations so existing adapters (Replay, Custom, undefined-future) continue compiling and running with caching simply disabled. A future adapter without caching support MUST NOT block on this spec.

- **★ [C7] The 5-min ephemeral TTL is the default; 1-hour is opt-in per provider.** Coordinator sessions complete within a 5-min window between consecutive turns (the TTL is sliding — every cache hit resets it). The 1-hour tier costs 2× write and offers no benefit for active sessions; it's only useful for resumable sessions or warm-pool scenarios, both of which are out of scope for M1.

## 4. Boundary contracts

### B1 — `Tau.Provider` behaviour extension

```elixir
# All optional. Default implementations: caching disabled.

@type cache_region ::
        :system        # the system blob
        | :tools       # the tools array
        | {:history, non_neg_integer()}  # the prior-N messages (excluding the freshest user turn)

@callback cache_regions(messages :: [Tau.Message.t()], opts :: map()) ::
            {:explicit, [cache_region()]}
            | :automatic
            | :none

@callback prepare_cache(messages :: [Tau.Message.t()], opts :: map(), ctx :: map()) ::
            {:ok, opaque_cache_ref :: term()}
            | :skip
            | {:error, term()}

@callback parse_cache_usage(provider_usage :: map()) ::
            %{
              write_tokens: non_neg_integer(),
              read_tokens: non_neg_integer(),
              storage_tokens: non_neg_integer()  # for Gemini-style billed storage
            }
```

- `cache_regions/2` returns the policy. Adapters in Family A return `{:explicit, [...]}` to drive marker injection. Families B and C return `:automatic` (no body modification; ordering is the contract). Family E returns `:explicit` with a single hint-region. Family D returns `:explicit` AND requires `prepare_cache/3` to manage the resource lifecycle.
- `prepare_cache/3` is called once before the request is built. It allows Family D adapters to materialize a `cachedContent` resource and thread its name through to `build_body/3` via the returned ref. Default returns `:skip`.
- `parse_cache_usage/1` normalizes the per-provider response into a common shape so the cost tracker and the telemetry layer don't switch on provider.

### B2 — Canonical request ordering

Every adapter's `build_body/3` MUST emit content in this order:

1. `system` (stable across turns; cache breakpoint A in Family A)
2. `tools` (stable across turns; cache breakpoint B in Family A)
3. Historical messages, oldest first (stable; cache breakpoint C placed on the LAST message *before* the freshest user message in Family A)
4. The current/freshest user message (variable; never cached)

This ordering is the substrate for Families B, C, D, and E to do their automatic/implicit caching. Marker placement in Family A relies on this same ordering.

## 5. State model

Cache state is **server-side**, owned by the provider. Tau does not maintain a session-level cache directory except for Family D (Gemini explicit) — see B1's `prepare_cache/3`. For Families A, B, C, E, F, the only Tau-side state is the canonical request shape; the cache is a property of the request bytes themselves.

For Family D, Tau MUST hold the `cachedContent` resource ID for the session's lifetime, invalidate it when the system prompt or tools array changes, and pass it through to each `build_body/3` call. This state belongs to the session (`Tau.Session.data`), not to the adapter, since the same `cachedContent` ID is reused across many requests in the session.

## 6. PSDH catalog (D-xxx) — runtime invariants

| ID | Statement | Severity | Detection |
|---|---|---|---|
| D-063 | **Cache region policy.** `Tau.Providers.Anthropic.cache_regions/2` MUST return `{:explicit, [:system, :tools, {:history, n}]}` where `n = max(0, length(messages) - 1)` (history = everything except the freshest user message). The Anthropic adapter MUST inject exactly three `cache_control` markers per request, one per region, when each region is non-empty. Empty regions (no system, no tools, only one message) MUST NOT contribute a marker. Total markers per request MUST be ≤3 (one headroom under the 4-breakpoint ceiling for future extensions). | high | property test `test/tau/providers/anthropic_cache_policy_test.exs` — generate random conversations; assert `count_cache_control(body) == count_non_empty_regions(messages)` |
| D-064 | **Marker placement determinism.** For a given `(system, tools, messages)` tuple the markers MUST land on byte-identical positions across invocations. No randomness, no time-dependence, no settings-cache-dependence. Specifically: marker A is on the LAST text block of the `system` array; marker B is on the LAST tool spec; marker C is on the LAST content block of `messages[length(messages) - 2]` (the message immediately before the freshest user input). | high | example test in the same file: build two requests from the same input 1 s apart, assert byte-identical request bodies |
| D-065 | **Usage normalization.** `Tau.Providers.Anthropic.parse_cache_usage/1` MUST translate the response's `cache_creation_input_tokens` / `cache_read_input_tokens` / `cache_creation.ephemeral_5m_input_tokens` / `cache_creation.ephemeral_1h_input_tokens` fields into the canonical `%{write_tokens, read_tokens, storage_tokens: 0}` shape. `storage_tokens` is always 0 for Anthropic (no storage billing). Future Family D (Gemini) adapter populates `storage_tokens` from `usageMetadata.cachedContentTokenCount` × time-held. | medium | unit test on the parse function with several sample response payloads (one with 0 cache activity, one with write-only, one with mixed write+read) |

3 D-xxx entries. Each enforceable.

## 7. Acceptance criteria

- **AC-1 — Anthropic explicit markers placed.** After this PR, a `tau run` against Anthropic emits a request body with `cache_control` markers on the last system block, last tool spec, and the second-to-last message (when each is non-empty). Verified by capturing the request body via Bypass-style stub in `test/tau/providers/anthropic_cache_policy_test.exs`.

- **AC-2 — Cache hits observed against the real API.** A two-request smoke (manual; documented in this spec but not gated in CI because it requires a real API key): issue request 1, observe `cache_creation_input_tokens > 0` in the response; issue request 2 with the same prefix, observe `cache_read_input_tokens > 0`. The smoke is captured in `docs/m1-verification/cache-smoke.md` as the M1 acceptance evidence for this spec.

- **AC-3 — OpenAI-family ordering preserved.** Adapters in Family B (OpenAI, Azure OpenAI, Groq) return `:automatic` from `cache_regions/2`; no body change is required, but their existing `build_body` paths MUST be audited to confirm they emit content in the canonical order (system → tools → history → fresh). Each gets a small unit test asserting the ordering.

- **AC-4 — Telemetry on hit rate.** Every assistant turn emits `[:tau, :session, :cache_usage]` telemetry with measurements `%{write_tokens, read_tokens, storage_tokens}` and metadata `%{session_id, provider}`. The OTel reporter (SPEC-OTEL-REPORTER) consumes this. This is the user-facing signal for C3.

- **AC-5 — Regression guard against C1 (4-breakpoint cap).** A property test generates messages/tools/system that would naively want 5+ markers; assertion: the Anthropic adapter still emits ≤4. This catches future scope-creep that adds a marker without removing one.

## 8. Scope of the first PR (#317) vs. follow-ups

**In scope for #317:**
- The three new behaviour callbacks (default implementations + dispatch).
- Anthropic adapter implementation of `cache_regions/2` and `parse_cache_usage/1`. No `prepare_cache/3` (Anthropic is not Family D).
- Ordering audit + unit tests for OpenAI-family adapters (no body changes; just asserts).
- Telemetry event wired into `Tau.Session` at the request boundary.
- Tests for D-063, D-064, D-065.
- SPEC-PROMPT-CACHING.md (this file) lives at `docs/spec/SPEC-PROMPT-CACHING.md` and is registered in `.claude/rules/spec-before-code.md`'s catalog.

**Deferred to follow-up issues (file at PR-merge time):**
- **Bedrock-Claude explicit markers** — Family A but slightly different wire format (`cachePoint` for Converse, `cache_control` for InvokeModel). Mechanical port of the Anthropic logic. Small, independent.
- **Gemini explicit caching** — Family D. Requires `prepare_cache/3`, session-level cache-resource lifecycle, invalidation on system-prompt change. Materially more work; not on the M1 critical path.
- **Mistral `prompt_cache_key`** — Family E. Trivial: hash the stable prefix, attach as a body field. Small follow-up.
- **DeepSeek field-name handling** — adapter exists, response uses `prompt_cache_hit_tokens` instead of `cached_tokens`; needs a `parse_cache_usage/1` implementation.
- **Copilot proxy passthrough** — verify the adapter doesn't strip caching headers when proxying. Audit + test, no logic change expected.

**Permanently out of scope:**
- A Tau-side cache (e.g., persisting prompts to local SQLite for replay-on-cache-miss). Provider caches are sufficient; a second cache layer would duplicate effort and add invalidation complexity.
- Cache-warming background jobs. Optimization, not correctness.

## 9. Why this spec is small

This spec deliberately ships only the policy layer + the Anthropic implementation. Each adapter can be added with a one-callback PR that satisfies the contract. The behaviour pattern (rather than `case` on provider name) makes that incremental rollout safe: an adapter without the callback gets the default (caching disabled) and continues working.

The user mandate is M1 cost. M1 uses Anthropic. Shipping more than Anthropic in this PR risks scope creep on the M1 critical path.

## 10. Sources (web research, 2026-05-20)

- Anthropic: https://platform.claude.com/docs/en/docs/build-with-claude/prompt-caching
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
| D-063, D-064 | `lib/tau/provider.ex` (new callbacks with defaults), `lib/tau/providers/anthropic.ex` (`cache_regions/2`, `build_body/3` marker injection), `test/tau/providers/anthropic_cache_policy_test.exs` (new file) |
| D-065 | `lib/tau/providers/anthropic.ex` (`parse_cache_usage/1`), `test/tau/providers/anthropic_cache_policy_test.exs` (parse unit tests) |
| AC-3 | `lib/tau/providers/openai/*.ex`, `lib/tau/providers/azure_openai.ex`, `lib/tau/providers/groq.ex` (no logic change; ordering-audit unit tests in their existing test files) |
| AC-4 | `lib/tau/session.ex` (emit `[:tau, :session, :cache_usage]` telemetry on each `:provider_done` event), `test/tau/session/cache_telemetry_test.exs` (new file) |
