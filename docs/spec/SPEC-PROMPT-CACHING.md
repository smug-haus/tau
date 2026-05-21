# SPEC-PROMPT-CACHING — Provider prompt caching

| **Status** | Draft v4 — covers M1 scope (Anthropic only). Three critic rounds; 11 BLOCKING findings closed across v1–v4. v4 adds the §4 B3 boundary contract that traces the cache-usage data path end-to-end (Anthropic response key → canonical usage-map key → Tracker ETS column), eliminates the redundant `parse_cache_usage/1` callback (the adapter's `merge_usage/2` normalisation IS the mechanism), and corrects AC-2's harness from `Tau.Providers.Replay` to a Bypass-served Anthropic SSE response. |
| --- | --- |
| **Owner** | tau-coordinator (Anthropic prompt cache is the M1 unlock for self-hosting cost) |
| **Method** | PSDH (`.claude/skills/design-reasoning`); L0 + L1 + boundary contracts. L2 deferred. |
| **Why now** | A single M1 verification run on 2026-05-20 consumed 7.05M uncached input tokens (~$106 in Anthropic spend) because `Tau.Providers.Anthropic` advertises `prompt_caching: true` and sets the beta header but emits no `cache_control` markers in the request body. User mandate (2026-05-20): "It's not usable without prompt caching." |

**Changelog:**

- v1 (#317 draft): initial design.
- v2 (#317, post-critic): adopted critic-recommended path (1) — markers are derived inside `build_body/3` per request and NEVER persisted to `data.messages`, eliminating cross-provider fallback handoff concerns entirely. Simplified `cache_regions/2` return shape to `:explicit | :automatic | :none` (no payload). Deferred `prepare_cache/3` until Gemini is actually scoped. Rewrote D-063/D-064 marker-placement rules to use "stable boundary" semantics that handle the tool-loop case and the post-compaction case correctly.
- v3 (#317, post-second-critic-round): **AC-6 descoped** from dollar pricing to ETS counter separation. **AC-1 strengthened** to call `build_body/3` directly. **AC-3 scoped to Anthropic-only**. System-field shape change named in Appendix B. **D-065 / C8 1h reconciliation**: Tau never emits `ttl: "1h"`. D-064 compaction-tiebreaker = latest-list-position summary.
- v4 (#317, post-third-critic-round): the third critic round closed 4 of 5 v3 findings but surfaced two new BLOCKINGs (f-6, f-7) with one root cause — **every revision described the cache-usage endpoints (response keys, ETS columns) but never the data path connecting them**. `Tau.Cost.Tracker.handle_event/4` reads `usage[:cache_read]` / `usage[:cache_write]`; `Anthropic.merge_usage/2` emits `cache_creation_input_tokens` / `cache_read_input_tokens` — a key-name mismatch that silently zeroes the counters. v4 adds **§4 B3 — the cache-usage normalisation contract** which traces the path end-to-end and fixes it at the source: the adapter's `merge_usage/2` emits the canonical `cache_read` / `cache_write` keys the Tracker already reads. This makes the separate `parse_cache_usage/1` behaviour callback **redundant — it is removed from B1**; normalisation is each adapter's own `merge_usage` responsibility. **AC-2's harness corrected** from `Tau.Providers.Replay` (a different adapter that never runs `Anthropic.decode/2`) to a `Bypass`-served Anthropic SSE response, exercising the real decode path. **OpenAI-family `cache_regions/2` gold-plating cut** (f-8): those adapters keep the C6 default of `:none` until the per-family follow-up that actually wires `OrderingCheck`.

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

- **★ [C6] Behaviour additions are opt-in for adapter authors.** The single new callback `cache_regions/2` is an `@optional_callback` on `Tau.Provider`. Dispatch is via `function_exported?/3` at call site (matches the existing `Tau.Provider.configure/1` pattern). A future adapter without caching MUST NOT block on this spec. Default behaviour when the callback is absent: caching disabled (`cache_regions/2` is treated as `:none`). Cache-usage normalisation is NOT a callback — it is each adapter's own `merge_usage`-side responsibility (see B3).

- **★ [C7] 5-min ephemeral TTL only (in this PR).** Coordinator sessions complete within a 5-min window between consecutive turns. The 1-hour tier costs 2× write and offers no benefit for active sessions. The Anthropic adapter MUST NOT emit `ttl: "1h"` in any `cache_control` block. The `extended-cache-ttl-2025-04-11` beta header is CONDITIONALLY removed (it is currently in `@beta_headers`) — see Appendix B for the file change. A future opt-in (e.g., for resumable sessions) re-enables the header and the `ttl: "1h"` field together.

- **★ [C8] Cost tracker records cache dimensions as distinct counters.** `Tau.Cost` already has `cache_read` and `cache_write` integer ETS columns alongside `input_tokens` / `output_tokens` (`lib/tau/cost.ex` line 17-23). This PR wires the per-turn counts from Anthropic's `cache_creation_input_tokens` and `cache_read_input_tokens` into those columns. **Dollar pricing per model is OUT OF SCOPE for this PR** — `Tau.Cost` moduledoc (line 11-14) explicitly defers per-model pricing to a follow-up issue. A future SPEC-COST-PRICING will own the dollar layer (`input_price` field on a per-model table; `cache_write_multiplier` defaulting to 1.25 for Anthropic 5-min and 2.0 for 1h; `cache_read_multiplier` defaulting to 0.10). Until that ships, the user observes cost via raw token counts in the dashboard plus the `[:tau, :session, :cache_usage]` telemetry feed — a 90% read discount surfaces as cache_read tokens growing while input_tokens stays flat across turns. That is sufficient to detect a regression; it is not sufficient to compute an exact dollar bill.

## 4. Boundary contracts

### B1 — `Tau.Provider` behaviour extension

```elixir
# @optional_callbacks; dispatch via function_exported?/3.
# Default behaviour when the callback is absent: caching disabled for that adapter.

@callback cache_regions(messages :: [Tau.Message.t()], opts :: map()) ::
            :explicit | :automatic | :none
```

`cache_regions/2` returns the policy *intent*:
- `:explicit` — adapter SHOULD emit cache markers inside its own `build_body/3`. Used by Family A (Anthropic, Bedrock-Claude). The adapter owns the placement; the callback is only a policy switch.
- `:automatic` — adapter relies on provider-side automatic prefix caching (Families B and C). No body changes required, but the adapter MUST honour the C2 canonical ordering.
- `:none` — caching disabled for this turn. Default for all adapters that don't implement the callback.

`cache_regions/2` is the **only** new behaviour callback in this PR. Cache-usage normalisation does NOT need a callback — it is each adapter's own responsibility inside its existing usage-merge code (see B3). Earlier drafts proposed a `parse_cache_usage/1` callback; v4 removed it as redundant.

**Deferred to follow-up issues (Gemini scoping):**
- `prepare_cache/3` for Family D's pre-flight resource creation. Lifecycle (per-request vs per-session, invalidation triggers) will be specified when Gemini caching is actually implemented. Shipping the contract empty would commit to a shape the implementer might want to change.

### B2 — Canonical request ordering (enforced)

Every adapter's `build_body/3` MUST emit content in this order:

1. `system` (stable across turns)
2. `tools` (stable across turns)
3. Historical messages, oldest first (stable up to the latest stable boundary; see D-064)
4. Fresh user/tool-result input (variable; never cached)

`Tau.Providers.Shared.OrderingCheck.validate!/1` (new helper) takes the assembled body shape and raises if ordering is violated. The Anthropic adapter calls it as the last step of `build_body/3`. (Other adapters: follow-up — see §8.)

### B3 — Cache-usage normalisation path (end-to-end)

This contract names every hop the cache-token counts traverse, from the provider's HTTP response to the cost ledger. It exists because v1–v3 each described the two endpoints (the response field names; the `Tau.Cost` ETS columns) but never the path between them — and the path is where the data was being silently dropped.

**The canonical key contract.** Every provider adapter's `usage` map — the `usage` field on `%Tau.Provider.Event.Done{}`, which flows into `%Tau.Message.Assistant{}.usage` — MUST use these integer keys:

```elixir
%{
  input_tokens: non_neg_integer(),
  output_tokens: non_neg_integer(),
  cache_read: non_neg_integer(),    # canonical — tokens served from cache
  cache_write: non_neg_integer(),   # canonical — tokens written to cache
  cache_breakdown: map()            # optional, adapter-specific diagnostics
                                    # (Anthropic: %{ephemeral_5m: n, ephemeral_1h: m})
}
```

`cache_read` and `cache_write` are the keys `Tau.Cost.Tracker.handle_event/4` already reads (`tracker.ex` — `cr = nz(usage[:cache_read])`, `cw = nz(usage[:cache_write])`). No Tracker change is required or permitted by this PR.

**The bug being fixed.** `Tau.Providers.Anthropic.merge_usage/2` currently emits `cache_creation_input_tokens` and `cache_read_input_tokens` — Anthropic's wire field names, not the canonical keys. The Tracker reads `cache_read`/`cache_write`, finds nothing, and `nz(nil)` zeroes the counters. **This PR fixes it in `merge_usage/2`**: map Anthropic's `cache_creation_input_tokens → cache_write`, `cache_read_input_tokens → cache_read`, and carry the 5m/1h split (when present) into `cache_breakdown`.

**The full path, every hop, no change needed except hop 1:**

1. `Tau.Providers.Anthropic.merge_usage/2` — **CHANGED**: emit canonical `cache_read`/`cache_write`/`cache_breakdown` keys instead of Anthropic-wire names.
2. `Tau.Message.Assembler.step/2` (on `%Event.Done{}`) — unchanged: copies `usage` verbatim into `message.usage`.
3. `Tau.Session.finalize_assistant/2` — unchanged: forwards `usage: msg.usage` into the `[:tau, :provider, :request, :stop]` telemetry measurements.
4. `Tau.Cost.Tracker.handle_event/4` — unchanged: reads `usage[:cache_read]` / `usage[:cache_write]`, increments the ETS row. Once hop 1 emits the right keys, this works with zero change.
5. The new `[:tau, :session, :cache_usage]` telemetry (AC-4) — `Tau.Session` reads `msg.usage[:cache_read]` / `[:cache_write]` / `[:cache_breakdown]` directly at the `:provider_done` boundary and emits. No callback indirection.

Because normalisation happens in each adapter's own usage-merge code (hop 1), the cross-provider story needs no shared abstraction: OpenAI's adapter maps `cached_tokens → cache_read`; DeepSeek maps `prompt_cache_hit_tokens → cache_read`; etc. Each is a few lines in that adapter's existing usage code, landed in that adapter's own follow-up PR. This PR only touches Anthropic's `merge_usage/2`.

## 5. State model

Cache state is **server-side**, owned by the provider. Tau holds no session-level cache directory in this PR (Gemini's resource lifecycle is the deferred Family D case).

For Families A, B, C, E, F: the only Tau-side state is the canonical request shape and the marker positions derived per-request. **Nothing is persisted back to `data.messages`** (per C5). Markers exist only in the JSON body sent to the provider.

## 6. PSDH catalog (D-xxx) — runtime invariants

| ID | Statement | Severity | Detection |
|---|---|---|---|
| D-063 | **Cache region policy switch.** `Tau.Providers.Anthropic.cache_regions/2` MUST return `:explicit` when (a) the session has at least one message and (b) `opts[:caching]` is not explicitly disabled. Returning `:none` MUST cause `build_body/3` to skip all marker injection. Returning `:explicit` MUST cause `build_body/3` to inject markers per D-064. | high | unit test in `test/tau/providers/anthropic_cache_policy_test.exs`: `cache_regions/2` returns `:explicit` for non-empty messages, `:none` when `opts[:caching] == false` |
| D-064 | **Marker placement — pure function, stable-boundary semantics.** Marker positions are a pure function of `(system, tools, messages, opts)`. Three markers are emitted per request when their target region is non-empty: **(A)** the LAST text block of the `system` block-array (`Anthropic.system_field/2` returns `[%{type: "text", text: ..., cache_control?: ...}]` after this PR; see Appendix B); **(B)** the LAST tool spec in `tools`; **(C)** the LAST content block of the **last-stable-boundary message** in `messages`, defined as the most recent message satisfying (in order of preference): (i) `%User{metadata: %{role: :compaction_summary}}` — the compaction summary is the strongest cache anchor when present; **if multiple compaction summaries are pinned (older + newer across multiple compaction events), the latest-list-position one wins**; (ii) the second-to-last message whose `role` is `:assistant` OR `%ToolResult{}` — the message immediately before the freshest input; (iii) skip marker C entirely if no stable boundary exists (e.g., first turn with one user message). Total markers ≤3 per request; the 4-breakpoint ceiling is preserved with one headroom slot. **Derivation MUST NOT read** `:os.system_time/0`, `Tau.Settings.Cache.get/0`, `:rand`, or the process dictionary. | high | property test in `test/tau/providers/anthropic_cache_policy_test.exs`: (1) assert byte-identical body for same input across two invocations 1.5 s apart (catches `:os.system_time/0` leaks; Settings.Cache reload is vacuous since Anthropic.build_body doesn't read it); (2) assert correct marker count for empty-system, no-tools, post-compaction, tool-loop, and multi-summary fixture scenarios; (3) two-turn stability: build body for turn N and turn N+1 with one new user message appended; assert byte-identical prefix up to and including marker C |
| D-065 | **Usage normalisation at the adapter (B3 hop 1).** `Tau.Providers.Anthropic.merge_usage/2` MUST emit the canonical `usage` map keys from B3: `cache_creation_input_tokens → cache_write`, `cache_read_input_tokens → cache_read`, plus `cache_breakdown` carrying the Anthropic `ephemeral_5m_input_tokens` / `ephemeral_1h_input_tokens` split when the response includes it. **Tau NEVER opts into 1h** (C7 — adapter never emits `ttl: "1h"`); if the server promotes anyway, the 1h tokens appear in `cache_breakdown.ephemeral_1h` for diagnostics AND are summed into the canonical `cache_write` counter. The future SPEC-COST-PRICING split-bills 1h at 2× using `cache_breakdown`; until then the `cache_write` counter sum is the regression-detection signal. | medium | unit test on `merge_usage/2` with four sample Anthropic response payloads: (a) no cache activity → `cache_read: 0, cache_write: 0`; (b) write-only 5m → `cache_write > 0`, `cache_read: 0`; (c) mixed write+read → both > 0, `cache_breakdown.ephemeral_5m > 0`; (d) server-promoted 1h → `cache_breakdown.ephemeral_1h > 0` asserted summed into `cache_write` |

3 D-xxx entries. Each enforceable.

## 7. Acceptance criteria

- **AC-1 — Anthropic markers placed in the wire body.** `Tau.Providers.Anthropic.build_body/3` is made `@doc false`-public in this PR (it is currently `defp`) so the test can call it directly. AC-1 calls `build_body/3` with synthetic input and asserts the returned map has `cache_control` markers on the last system block, last tool spec, and the last-stable-boundary message (when each is non-empty), per D-064. This is the substance proof for marker injection — not via Replay, not via response-side telemetry. Three fixture cases at minimum: (1) full conversation with system + tools + multiple messages including a compaction summary; (2) first turn with only a user input (markers A,B only when system+tools present; marker C skipped); (3) empty system + empty tools (markers A,B skipped; marker C placed). New file: `test/tau/providers/anthropic_cache_policy_test.exs`.

- **AC-2 — Response-side B3 path round-trips.** A `Bypass`-served Anthropic SSE response (the harness already used by `test/tau/providers/anthropic/http_error_stream_test.exs`) drives the real `Anthropic.decode/2` → `merge_usage/2` path. Two cases: a response whose `message_start` usage carries `cache_creation_input_tokens > 0`, and one carrying `cache_read_input_tokens > 0`. Assert (1) the resulting `%Event.Done{}.usage` map has canonical `cache_write` / `cache_read` keys per B3; (2) when driven through a `Tau.Session`, the `[:tau, :session, :cache_usage]` telemetry fires with the correct split; (3) `Tau.Cost.Tracker`'s ETS row for that session shows the `cache_read` / `cache_write` columns incremented. **No real API key required** — `Bypass` serves a recorded SSE body locally. This test exercises B3 hops 1→5 end-to-end. It does NOT verify marker emission on the request body — that is AC-1's job. New file: `test/tau/providers/anthropic_cache_cassette_test.exs`. Note: `Tau.Providers.Replay` is NOT used — it is a distinct adapter that never runs `Anthropic.decode/2` and so cannot exercise B3 hop 1.

- **AC-3 — Canonical ordering enforced for Anthropic.** `Tau.Providers.Shared.OrderingCheck.validate!/1` ships in this PR with a signature `validate!(body :: %{required(:system) => list_or_nil, required(:tools) => list_or_nil, required(:messages) => list}) :: :ok | no_return()`. Called as the LAST step of `Tau.Providers.Anthropic.build_body/3`. A property test in `test/tau/providers/anthropic_cache_policy_test.exs` generates random shapes and asserts ordering-violation maps raise, ordering-compliant maps return `:ok`. **Other adapters are out of scope for this PR.** A follow-up issue covers extension to OpenAI-Chat-wire, Bedrock (whose body is `build_payload/2` not `build_body/3`), and Gemini — each needs a shape adapter or per-provider validator. The validator's signature is intentionally Anthropic-shaped in this PR; the follow-up will generalize.

- **AC-4 — Telemetry on hit rate.** Every assistant turn emits `[:tau, :session, :cache_usage]` telemetry with measurements `%{write_tokens, read_tokens, storage_tokens}` and metadata `%{session_id, provider, breakdown}`. The OTel reporter (SPEC-OTEL-REPORTER) consumes this. This is the user-facing signal for C3.

- **AC-5 — Regression guard against the 4-breakpoint cap.** Property test fixture: 3 system blocks + 5 tools + 8 messages including 2 compaction summaries + 4 tool turns. This shape would naively offer 5+ candidate marker positions; assertion: the Anthropic adapter emits exactly 3 markers (A on last system block, B on last tool, C on the latest compaction summary per D-064's compaction-tiebreaker). Random generation is constrained to inputs that have ≥3 distinct stable boundaries available; assertions never run on under-constrained inputs that would pass trivially.

- **AC-6 — Cost tracker records cache token counters.** `Tau.Cost.Tracker` already reads `usage[:cache_read]` / `usage[:cache_write]` and increments ETS columns 4 and 5 (`tracker.ex` `handle_event/4`). **No Tracker change is in scope** — once B3 hop 1 (the `merge_usage/2` fix, D-065) emits the canonical keys, the existing Tracker path carries the data correctly. AC-6 is verified by AC-2 hop (3): the Bypass-driven session run shows the Tracker's ETS row for that session with non-zero `cache_read` / `cache_write` columns. The existing `test/tau/cost_test.exs` is additionally extended with one fixture passing a canonical-key usage map (`%{cache_read: N, cache_write: M, ...}`) directly to the telemetry handler, asserting both columns increment — a focused unit test of the Tracker independent of the adapter. **Dollar-price computation is OUT OF SCOPE** per C8 (deferred to a future SPEC-COST-PRICING).

## 8. Scope of the first PR (#317) vs. follow-ups

**In scope for #317:**
- The single new behaviour callback `cache_regions/2` declared as an `@optional_callback` on `Tau.Provider`.
- `Tau.Providers.Shared.OrderingCheck.validate!/1` shared helper — Anthropic body-shape signature only.
- Anthropic adapter implementation: `cache_regions/2` returns `:explicit` for non-empty sessions; `split_system/1` / `system_field/2` transition from joined-string to block-array shape (named in Appendix B); `build_body/3` injects ≤3 markers per D-064 and calls `OrderingCheck.validate!/1`; `merge_usage/2` emits canonical `cache_read`/`cache_write`/`cache_breakdown` keys per B3 + D-065.
- Removal of `extended-cache-ttl-2025-04-11` from `@beta_headers` in `lib/tau/providers/anthropic.ex` (C7). The base `prompt-caching-2024-07-31` header stays (GA-equivalent; harmless).
- Telemetry event `[:tau, :session, :cache_usage]` wired in `Tau.Session` at the `:provider_done` boundary, reading the canonical usage-map keys.
- Tests for D-063, D-064, D-065, AC-1 through AC-6.
- SPEC-PROMPT-CACHING.md (this file) registered in `.claude/rules/spec-before-code.md`.

**NOT in scope (deliberately cut to avoid behaviour-free churn):**
- OpenAI-family `cache_regions/2` definitions. Per C6 a missing callback defaults to `:none`. Nothing in this PR couples behaviour to an `:automatic` return (no `OrderingCheck` call for those adapters, no telemetry branch). Adding six one-line `:automatic` callbacks would change zero observable behaviour. The OpenAI family stays at the `:none` default and adopts `:automatic` in the per-family follow-up that actually wires `OrderingCheck` for it.
- Any `Tau.Cost.Tracker` change — the Tracker already reads the canonical keys (AC-6).

**Deferred to follow-up issues (file at PR-merge time):**
- **OrderingCheck extension to remaining adapters** — OpenAI-Chat-wire (6 adapters share `Tau.Providers.Shared.OpenAIChatWire.build_body/4`), Bedrock (uses `build_payload/2` not `build_body/3`), Gemini (own body shape). Each needs a shape adapter or per-provider validator; the spec-time decision deferred is whether to canonicalize at a Tau pre-shape layer or keep validators per-adapter.
- **SPEC-COST-PRICING** — `Tau.Cost` per-model dollar-pricing schema and the `cache_write_multiplier` / `cache_read_multiplier` per-tier breakdown. Picks up where AC-6 leaves off: counters → dollars.
- **Bedrock-Claude explicit markers** — Family A. The C5 marker-isolation makes this safe to defer: Anthropic→Bedrock fallback no longer carries `cache_control` into the message accumulator (because nothing is persisted there), so the fallback hop is correct by construction. Bedrock simply caches nothing until its adapter implements `cache_regions/2`. Mechanical port of the Anthropic placement once it lands.
- **Gemini explicit caching** — Family D. Requires `prepare_cache/3` (lifecycle TBD), session-level cache-resource state. Not on the M1 critical path.
- **Mistral `prompt_cache_key`** — Family E. Trivial: hash the stable prefix, attach as a top-level body field. The `cache_regions/2` mechanism doesn't fit Family E directly; the Mistral PR may add a separate callback or extend `:explicit` semantics. Defer until Mistral becomes a coordinator-relevant provider.
- **DeepSeek field-name handling** — adapter exists; response uses `prompt_cache_hit_tokens` / `prompt_cache_miss_tokens`; needs `merge_usage`-side normalisation mapping `prompt_cache_hit_tokens → cache_read` (per the B3 canonical-key contract). Trivial.
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
| D-063, D-064 | `lib/tau/provider.ex` (new `@optional_callback cache_regions/2` `@callback` spec); `lib/tau/providers/anthropic.ex` — (a) `cache_regions/2` new, (b) `split_system/1` / `system_field/2` transition from joined-string to block-array shape `[%{type: "text", text: ..., cache_control?: %{type: "ephemeral"}}]`, (c) `build_body/3` injects ≤3 markers per D-064 and calls `OrderingCheck.validate!/1` — `build_body/3` becomes `@doc false`-public so AC-1 can call it directly, (d) removal of `extended-cache-ttl-2025-04-11` from `@beta_headers`; `test/tau/providers/anthropic_cache_policy_test.exs` (new file) |
| B3, D-065 | `lib/tau/providers/anthropic.ex` (`merge_usage/2` — emit canonical `cache_read`/`cache_write`/`cache_breakdown` keys, B3 hop 1); `test/tau/providers/anthropic_cache_policy_test.exs` (`merge_usage/2` unit tests with the four payloads incl. 1h-promotion). NO change to `assembler.ex`, `session.ex` finalize path, or `cost/tracker.ex` — B3 hops 2–4 already carry canonical keys unchanged. |
| C2, AC-3 | `lib/tau/providers/shared/ordering_check.ex` (new shared helper, `validate!/1` with Anthropic body-shape signature); `lib/tau/providers/anthropic.ex` (call-site addition in `build_body/3`); Anthropic-only property tests in `test/tau/providers/anthropic_cache_policy_test.exs`. Extension to other adapters: follow-up issues. |
| AC-2 | `test/tau/providers/anthropic_cache_cassette_test.exs` (new file; `Bypass`-served Anthropic SSE — NOT `Tau.Providers.Replay`; exercises B3 hops 1→5 end-to-end) |
| AC-4 | `lib/tau/session.ex` (emit `[:tau, :session, :cache_usage]` telemetry on each `:provider_done` event, reading `msg.usage[:cache_read]` / `[:cache_write]` / `[:cache_breakdown]` directly — no callback indirection); `test/tau/session/cache_telemetry_test.exs` (new file) |
| AC-6, C8 | NO production-code change — `Tau.Cost.Tracker.handle_event/4` already reads the canonical `cache_read`/`cache_write` keys (verified `tracker.ex`). `test/tau/cost_test.exs` extended with one fixture passing a canonical-key usage map to the telemetry handler, asserting columns 4/5 increment. End-to-end coverage is AC-2 hop (3). |
