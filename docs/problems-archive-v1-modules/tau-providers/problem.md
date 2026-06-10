---
template_version: 1
template_name: problem
node_kind: internal
depth: 0
parent: —
status: decomposed
---

# Problem: tau-providers behaviour contract divergence

## Statement

The `@behaviour Tau.Provider` defines a shared contract for eleven adapters, but
four concerns leak across the contract boundary in ways that make the adapters
silently non-interchangeable: `capabilities/0` flags are decorative (Bedrock and
Gemini declare `thinking: true, prompt_caching: true` while implementing
neither); usage maps are only canonically normalised by Anthropic; `retryable?`
classification is scattered across three layers with incompatible criteria; and
auth-resolution logic is duplicated, each adapter inventing its own priority
chain with no shared scaffold.

## Context

- `lib/tau/provider.ex` — 6 callbacks: `stream/3`, `capabilities/0`,
  `default_model/0`, `configure/1` (optional), `cache_regions/2` (optional),
  `context_window/1` (optional).
- `lib/tau/provider/event.ex` — canonical event union (12 struct types).
- `lib/tau/providers/anthropic.ex` — only adapter with a `merge_usage/2` that
  emits the full B3 canonical map (`input_tokens`, `output_tokens`,
  `cache_read`, `cache_write`, `cache_breakdown`).
- `lib/tau/providers/shared/openai_chat_wire.ex` — shared SSE decode used by
  OpenAI Chat, Groq, Mistral, DeepSeek, AzureOpenAI, Custom; emits
  `%Event.Done{usage: %{}}` (empty map) — no normalisation.
- `lib/tau/providers/bedrock.ex` — declares `thinking: true, prompt_caching:
  true`; emits only `TextDelta` (no `TextStart`/`TextEnd`) and no usage.
- `lib/tau/providers/gemini.ex` — declares `thinking: true, prompt_caching:
  true`; emits only `TextDelta` (no `TextStart`/`TextEnd`) and no usage.
- Auth resolution is per-adapter with no shared behaviour; Copilot has a
  dedicated two-token model (OAuth + short-lived API token) while all others
  use a `nil` guard + `System.get_env` chain.
- SPEC-PROMPT-CACHING §4 B3 defines the canonical usage key contract;
  only Anthropic honours it.

## Complecting hypothesis

1. **`capabilities/0` flag truth is complected with per-adapter decode
   implementation:** whether an adapter actually synthesises `ThinkingStart` /
   `ThinkingEnd` events or honours cache regions is only discoverable by reading
   each adapter's decode path, not by inspecting the behaviour flag.
2. **Usage normalisation is complected with adapter identity:** the `%Event.Done{}`
   contract specifies a `usage` map, but what keys are present depends on which
   adapter produced the event — only Anthropic emits the B3 canonical set; all
   others emit `%{}`.
3. **Auth-resolution strategy is complected with each adapter module:** the
   priority chain (app env → vault → env var) is reimplemented in full per
   adapter with no shared scaffold, meaning vault-resolution bugs can exist in
   some adapters but not others.

## Decomposition strategy

The parent problem decomposes along the **concern (Hickey)** axis: four
distinct concerns are woven together across the provider surface. Each
sub-problem names exactly one woven concern and the adapter set where it
manifests. The sub-problems are MECE because:

- No concern lives in two sub-problems (each names one distinct contract gap).
- Their union covers every concern in the statement.
- Each is at the same altitude: a specific gap in what `@behaviour Tau.Provider`
  enforces vs what adapters actually deliver.

## Sub-problems (filled by decomposer)

1. **callback-contract-drift** — Adapters omit or vary structural event emission
   (TextStart/TextEnd synthesis, ToolCallDelta streaming) without the behaviour
   detecting or documenting the gap.
2. **capabilities-flag-fidelity** — `capabilities/0` flags (`thinking`,
   `prompt_caching`) diverge from what adapters actually implement, making them
   decorative rather than enforceable.
3. **usage-normalisation** — `%Event.Done{usage: map()}` carries an implicit
   per-adapter schema; only Anthropic emits the B3 canonical key set; all others
   emit `%{}`, silently breaking cost tracking and context-window display.
4. **auth-resolution-scatter** — Each adapter reinvents its own credential
   priority chain (app env → vault → env var) with no shared behaviour or
   scaffold, causing vault-resolution inconsistencies across adapters.

## Acceptance criterion

The behaviour contract at `lib/tau/provider.ex` and associated shared
infrastructure enforces (or accurately documents as optional) every observable
divergence currently present across the eleven adapters, such that a new adapter
author cannot silently ship a broken implementation by following only the
`@behaviour` callbacks.

## Out of scope

- Transport layer (FinchStream, AwsEventStream, SSE parsing) — these are
  not part of the behaviour surface.
- Rate limiting (`Tau.Providers.RateLimiter`) — shared infrastructure, not
  per-adapter contract.
- Tool spec shape (`Tau.Providers.Shared.ToolSpec`) — a separate concern.
- Replay provider's test-harness contract — intentionally divergent; not a
  production adapter.
- Performance or throughput concerns.

## Amendment log

- (none yet)
