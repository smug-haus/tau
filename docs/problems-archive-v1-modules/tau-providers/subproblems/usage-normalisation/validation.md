---
template_version: 1
template_name: validation
parent_solution: solution.md
parent_problem: problem.md
toulmin_complete: true
falsification_attempted: true
falsification_outcome: partially_falsified — claim/6
revision_triggered: none
---

# Validation: typed `%Event.Usage{}` + shared `UsageNorm` scaffold + conformance test

## Overview

The solution makes seven distinct propositions, blending compile-time
shape enforcement (a new `%Tau.Provider.Event.Usage{}` struct with
`@enforce_keys [:input_tokens, :output_tokens]`), a shared
wire-format-to-canonical scaffold (`Tau.Provider.UsageNorm`), per-adapter
wire-extraction edits (OpenAI-family `stream_options.include_usage`,
Bedrock `message_start`/`message_stop` accumulation, Gemini
`usageMetadata` read, Anthropic delegation), and a shared
`Tau.Test.ProviderConformance` template iterated per adapter. Each claim
is run through full Toulmin and a named falsification strategy; the
strategies span counter-example construction, dependency check, edge-case
enumeration, integration check, and type-level check. Six claims withstand;
claim 6 (the consumer-migration claim) is **partially falsified** by a
codebase counter-example — most consumers already use atom keys, not
string keys — and is narrowed in place. No solution or problem revision
is triggered; the narrowed qualifier is recorded for the parent.

## Toulmin per claim

### Claim 1: Replace `usage: map()` on `%Event.Done{}` with a typed `%Tau.Provider.Event.Usage{}` struct (`@enforce_keys [:input_tokens, :output_tokens]`; `cache_read`, `cache_write`, `cache_breakdown` defaulted).

- **Claim (C):** A new struct `Tau.Provider.Event.Usage` with required
  `:input_tokens` / `:output_tokens` and defaulted cache fields replaces
  the `usage: map()` field in `%Event.Done{}`.
- **Grounds (G):** `lib/tau/provider/event.ex:90-95` today defines
  `Done` with `defstruct [:stop_reason, usage: %{}]` and
  `@type t :: %__MODULE__{stop_reason: atom(), usage: map()}` — the
  unconstrained `map()` is the exact shape the solution displaces. Two
  sibling structs in the same module (`ToolCallEnd`, `Error`) already
  follow the `@enforce_keys` + `defstruct [...]` pattern the solution
  proposes (`event.ex:83-87`, `event.ex:97-106`), so the proposed shape
  is a precedented intra-file pattern, not a new style.
- **Warrant (W):** OTP non-negotiable #2 — "extensibility seams MUST be
  behaviours; pattern match on atoms and structs". The `Done.usage` field
  is a cross-adapter extensibility seam currently typed as an opaque
  `map()`; a struct converts pattern-matched access (`event.usage.input_tokens`)
  from a runtime `KeyError` risk into a compile-time `KeyError` and a
  Dialyzer-visible shape, which is the design principle's intent.
- **Qualifier (Q):** Holds for the `%Event.Done{}` emission contract.
  The Replay adapter's JSONL deserialiser (see open question §2) must
  construct the struct rather than emit a raw map; the solution
  acknowledges this and scopes a `Event.Usage.from_replay/1` helper in
  PR 2 or PR 3.
- **Rebuttal (R):** If a hypothetical future adapter has no concept of
  `output_tokens` (e.g. a streaming generator that bills only on input),
  `@enforce_keys` would force a `0` placeholder. That is arguably a
  category error in the contract; the solution's PR 1 keeps
  `usage: nil` allowed during transition, which softens the rebuttal but
  doesn't dismiss it.
- **Backing (B):** `.claude/rules/otp-non-negotiables.md` §2 ("pattern
  match on atoms and structs") and the SPEC-PROMPT-CACHING §4 B3
  canonical-key contract (lines 126-149 in
  `docs/spec/SPEC-PROMPT-CACHING.md`) which already enumerates the keys
  the struct enshrines.

#### Falsification attempt for claim 1

- **Strategy:** type-level check (mental Dialyzer pass + struct-shape
  audit).
- **Attempt:** Examined the proposed `@type` and `@enforce_keys` against
  the existing 12 sibling structs in `event.ex`. The `Done.t()` change
  to `usage: Tau.Provider.Event.Usage.t() | nil` is well-typed and
  composes with the existing `Tau.Provider.Event.t()` union (lines
  108-120). The transitional `| nil` qualifier (per the solution) means
  no in-flight emission site becomes a Dialyzer error on PR 1.
- **Outcome:** withstood.
- **Action:** none.

### Claim 2: Introduce `Tau.Provider.UsageNorm` as the shared wire-format-to-canonical scaffold each adapter uses to construct that struct from its upstream payload, with `zero/0`, `nonneg/1`, `from_openai/1`, `from_gemini/1`, `from_bedrock/1`, `from_anthropic/1` helpers returning `%Event.Usage{}`.

- **Claim (C):** A new pure module `Tau.Provider.UsageNorm` provides per-wire-format
  constructors that each return a `%Event.Usage{}`, and `from_anthropic/1`
  delegates to the existing `Anthropic.merge_usage/2`.
- **Grounds (G):** `lib/tau/providers/anthropic.ex:284-303` already
  contains the canonical-key normaliser as adapter-private
  `merge_usage/2` + `nonneg/1`. SPEC-PROMPT-CACHING line 110 explicitly
  describes the current state: "Cache-usage normalisation does NOT need
  a callback — it is each adapter's own responsibility inside its
  existing usage-merge code." The shared-scaffold gap the solution fills
  is documented in the same SPEC's §4 B3 hop description (lines 145-155).
- **Warrant (W):** OTP non-negotiable #8 — "Pure functions are the
  default; processes are the exception." A wire-to-canonical mapper is
  pure (no shared state, no message passing); the right container is a
  module, not a behaviour callback or GenServer. The solution explicitly
  rejects the behaviour-callback alternative (proposal 1) and the
  consumer-side normaliser (proposal 3) on this basis.
- **Qualifier (Q):** Holds for the four named wire families
  (Anthropic-native, OpenAI Chat, Gemini, Bedrock-Anthropic-wrapped). For
  any future wire family that isn't OpenAI/Gemini/Bedrock/Anthropic, a
  new `from_<family>/1` helper must be added.
- **Rebuttal (R):** If two adapters end up needing per-instance state
  (e.g. a streaming usage accumulator that must survive across multiple
  SSE chunks), a pure module's helpers can't carry that state — the
  caller must hold the partial accumulator. The solution already
  contemplates this for Bedrock and OpenAI ("accumulate the final SSE
  chunk's `usage` into partial"), so the rebuttal is honoured by the
  callers, not the scaffold.
- **Backing (B):** `.claude/rules/otp-non-negotiables.md` §3 ("MUST NOT
  wrap stateless logic in a GenServer") and §8 (pure functions
  default). The Anthropic `merge_usage/2` precedent is the worked
  example of the warrant.

#### Falsification attempt for claim 2

- **Strategy:** counter-example construction (try to construct an
  adapter that the proposed scaffold can't serve).
- **Attempt:** Examined the 11 production adapters in
  `lib/tau/providers/`. Anthropic-native (Anthropic, Bedrock's wrapped
  Anthropic) → `from_anthropic`. OpenAI Chat family (OpenAI.Chat, Groq,
  Mistral, DeepSeek, AzureOpenAI, Custom) → `from_openai`. Gemini →
  `from_gemini`. Copilot's directory exists but routes through OpenAI
  Chat wire (it imports `OpenAIChatWire` indirectly via the Chat
  adapter pattern — see the open question §3 in the solution which
  explicitly asks this). OpenAI.Responses is the unresolved case — its
  own decode path is not the Chat-wire path, and the solution lists it
  as a named conformance target but does not specify a
  `from_openai_responses/1` helper. This is not a falsification of the
  scaffold's existence; it is a gap in the scaffold's enumeration that
  surfaces as the open question §3.
- **Outcome:** withstood (with one named gap acknowledged in the
  solution's own open question §3).
- **Action:** none beyond what the solution itself already lists.

### Claim 3: OpenAI-family adapters set `stream_options: %{include_usage: true}` in `build_body/3` and emit `%Event.Done{usage: UsageNorm.from_openai(raw)}` on `[DONE]`.

- **Claim (C):** Setting `stream_options.include_usage: true` in
  `OpenAIChatWire.build_body/4` causes the upstream API to send a final
  SSE chunk carrying `usage`, which the decoder accumulates and emits in
  `%Event.Done{}`.
- **Grounds (G):** `lib/tau/providers/shared/openai_chat_wire.ex:44-56`
  shows the current `build_body/4` body composition — it sets only
  `model`, `stream: true`, `messages`, `temperature`, `max_tokens`,
  `tools`, `tool_choice`. No `stream_options` is present, confirming
  the data is not requested. `openai_chat_wire.ex:66` shows
  `decode(%{data: "[DONE]"}, partial)` returns
  `[%Event.Done{stop_reason: :stop}]` with no usage extraction;
  `openai_chat_wire.ex:191-200` shows the `finish_reason` path also
  emits `%Event.Done{stop_reason: <atom>}` with no usage. The OpenAI
  Chat Completions API documentation (referenced in problem.md
  `lib/tau/providers/shared/openai_chat_wire.ex:66` context) confirms
  `stream_options.include_usage` is the documented opt-in.
- **Warrant (W):** The OpenAI streaming protocol is opt-in for usage
  emission — without `include_usage`, the final SSE chunk omits the
  `usage` field. Sending `stream_options.include_usage: true` is the
  documented and only path to receive the data. Reading and emitting it
  in `%Event.Done{}` is then a pure-data transform fulfilling claim 1.
- **Qualifier (Q):** Holds for OpenAI Chat Completions wire and every
  family member that proxies it (Groq, Mistral, DeepSeek, AzureOpenAI,
  Custom, and — per open question §3 — Copilot). Holds also for any
  third-party server that implements the OpenAI Chat Completions
  contract faithfully.
- **Rebuttal (R):** A proxy server that rejects unknown body fields
  (some self-hosted Llama servers do) would error on
  `stream_options.include_usage`. The `Custom` adapter is the
  most-exposed instance; the solution does not call this out but the
  rebuttal is real for self-hosted-LLM users.
- **Backing (B):** OpenAI API reference for `stream_options` (the
  `include_usage` flag is the public, documented mechanism); the
  existing `OpenAIChatWire` moduledoc which already lists the wire
  family members (lines 5-8).

#### Falsification attempt for claim 3

- **Strategy:** edge-case enumeration (enumerate the failure modes the
  proposed change introduces or fails to handle).
- **Attempt:** Enumerated: (a) server rejects unknown field — Custom
  adapter risk noted in rebuttal; (b) server silently ignores the field
  — final chunk has no `usage`, `from_openai/1` returns
  `%Event.Usage{input_tokens: 0, output_tokens: 0}` via `zero/0`, which
  is the solution's documented zero-fallback semantics; (c) the `[DONE]`
  chunk arrives before the usage-bearing chunk — checked the SSE order
  contract: the OpenAI API emits the usage chunk *before* `[DONE]`, so
  the decoder's accumulator-then-emit ordering aligns with the wire
  contract; (d) Azure OpenAI's API surface may not honour
  `stream_options` in all deployment SKUs — possible, but the worst case
  reduces to case (b) — zero values, not a crash.
- **Outcome:** withstood (rebuttal acknowledged but does not falsify the
  claim for compliant servers, which the AC scopes the claim to).
- **Action:** none; the Custom-server rebuttal could be added to the
  solution's open questions but does not block the claim.

### Claim 4: Bedrock accumulates usage from `message_start` and emits `%Event.Done{usage: UsageNorm.from_bedrock(raw)}` in the `message_stop` handler; Gemini reads `usageMetadata` and emits `%Event.Done{usage: UsageNorm.from_gemini(raw)}`.

- **Claim (C):** Two wire-extraction edits — Bedrock accumulates the
  `message_start.usage` block into the partial, then on `message_stop`
  constructs the canonical struct; Gemini reads
  `json["usageMetadata"]` (or `json["candidates"][...]["usageMetadata"]`)
  in the finish-reason handler.
- **Grounds (G):** `lib/tau/providers/bedrock.ex:111-122` shows the
  current `decode_anthropic_event` clauses: `message_start` handler
  emits a `Start` event but does not touch `m["usage"]`; the
  `message_stop` handler emits `%Event.Done{stop_reason: :stop}` with
  no usage. `lib/tau/providers/gemini.ex:112-118` shows the
  `finishReason` handler emits `%Event.Done{stop_reason: :stop}` (or
  `:length`) and never reads `json["usageMetadata"]`. Both gaps are
  exactly as problem.md describes.
- **Warrant (W):** The native wire formats both carry usage data; the
  adapter is the only point at which the data can be extracted before
  the event union normalises away the wire-format detail. Per
  claim 1's warrant, the canonical struct must be populated by the
  adapter, not by a downstream consumer.
- **Qualifier (Q):** Bedrock holds for the Anthropic-on-Bedrock wire
  (the only one Bedrock currently implements per
  `bedrock.ex:111-122`). If Bedrock were extended to host other
  on-platform model families (Cohere, Meta), each would need its own
  accumulation pattern. Gemini holds for the v1beta `generateContent`
  streaming format; v1 differs in `usageMetadata` placement, but the
  current Tau Gemini adapter is v1beta-targeted.
- **Rebuttal (R):** Bedrock's binary event-stream framing
  (`decode_frame/2`, lines 100-109) deserialises the inner JSON
  per-frame; if a `message_start` frame arrives without a `usage`
  object (possible during error injection or partial-server-response
  cases), the partial accumulator must accept `nil` gracefully —
  `nonneg/1` already does this in `Anthropic.merge_usage/2`, so the
  pattern is established but the new Bedrock-side accumulator must
  inherit it.
- **Backing (B):** Bedrock's Anthropic-wire contract is the same wire
  protocol the native Anthropic adapter already handles in
  `anthropic.ex:284-300`. Gemini's `usageMetadata` schema is documented
  in Google's GenerativeAI REST API reference; the existing Tau adapter
  reads adjacent fields (`candidates[].content.parts[]`,
  `candidates[].finishReason`) so the field-path traversal pattern is
  precedented.
- 
#### Falsification attempt for claim 4

- **Strategy:** dependency check (verify the upstream wire contracts
  the claim depends on are present today).
- **Attempt:** (a) Bedrock — Anthropic on Bedrock currently emits
  `message_start.message.usage` per the Anthropic wire contract
  Bedrock proxies; the partial accumulator pattern from Anthropic is
  directly applicable. (b) Gemini — Google's REST reference confirms
  `usageMetadata` is in every streaming `generateContent` response when
  the generation succeeds (it is omitted in error paths, which the
  zero-fallback handles). (c) Bedrock's `decode_anthropic_event/2`
  pattern has a final fallthrough `defp ... (_, p), do: {[], p}`
  (line 124) — a `message_start`-with-usage clause must be added
  *before* the fallthrough, not after, or the new clause will be
  dead. This is a routine ordering concern, not a falsification.
- **Outcome:** withstood.
- **Action:** none; the clause-ordering note is captured in the
  PR-implementer brief implicit to the migration sketch.

### Claim 5: A shared `Tau.Test.ProviderConformance` ExUnit case template asserts the last `%Event.Done{}` in a fixture stream carries a `%Event.Usage{}` with non-negative-integer required fields, instantiated per adapter (11 production adapters named).

- **Claim (C):** A reusable ExUnit `use` template iterates over a
  per-adapter fixture and asserts the canonical-struct invariants on
  the final `Done` event; 11 per-adapter test files instantiate it.
- **Grounds (G):** The Replay provider's JSONL fixture format is
  reused (per solution "What does not change"). The acceptance
  criterion in `problem.md` line 62-66 explicitly names "a shared
  conformance test or typespec that all adapters satisfy" as the
  verification mechanism, so the test's role is part of the AC, not
  an added implementation cost. ExUnit's `__using__/1` macro pattern
  is the established way to share test cases in this codebase (e.g.
  `test/support/tui_pty_helper.ex` precedent for shared test
  infrastructure).
- **Warrant (W):** OTP non-negotiable #6 — "Invariant-bearing modules
  MUST have properties before examples." A conformance test that
  iterates *every* production adapter is property-shaped at the
  adapter dimension (universal quantification over adapters), even if
  the per-adapter body is example-based on a fixture. This converts
  "did this PR break adapter X" from a `git grep`-and-hope check to a
  mechanical CI gate.
- **Qualifier (Q):** Holds for adapters with a usage-bearing fixture.
  The solution explicitly defers fixture authoring for adapters whose
  fixtures don't exist today ("priv/fixtures/*.jsonl — new or extended
  fixture files"); until those land, the conformance test for that
  adapter will be skipped or use a synthesised fixture.
- **Rebuttal (R):** A conformance test passing on a fixture does not
  prove the adapter passes against the *live* upstream API. The
  fixture is recorded at one point in time; if the live API changes
  its usage schema, the fixture lags and the test is stale-green.
  The solution does not address fixture refresh policy; this is a
  weakness inherited from the codebase-wide fixture story, not a
  new defect introduced by this solution.
- **Backing (B):** `.claude/rules/otp-non-negotiables.md` §6
  (properties before examples) and SPEC-PROMPT-CACHING's existing
  test-coverage discipline (lines 195 — "Tests for D-063, D-064,
  D-065, AC-1 through AC-6"), which already establishes that adapter
  invariants are test-enforced.

#### Falsification attempt for claim 5

- **Strategy:** integration check (does an integration test for this
  contract exist, or could it be written, that exercises the
  user-visible boundary?).
- **Attempt:** Examined whether the `Tau.Cost.Tracker.handle_event/4`
  path (`tracker.ex:121-127`) is reachable from a fixture-driven
  conformance test. The Tracker reads `usage[:input_tokens]`,
  `usage[:output_tokens]`, `usage[:cache_read]`, `usage[:cache_write]`
  — all canonical keys. The conformance test as proposed asserts the
  `%Event.Usage{}` shape; this is necessary but not sufficient for
  the user-visible Tracker outcome. A second assertion that the
  Tracker's ETS row is incremented after the fixture replays is
  trivially addable (SPEC-PROMPT-CACHING AC-2 already uses this
  Bypass-driven pattern). The conformance test as scoped is therefore
  a *shape* gate; an *end-to-end* gate is a strict additional layer
  the solution does not require but the AC's "verified by" clause
  permits. This does not falsify the claim; it narrows what the
  conformance test alone proves.
- **Outcome:** withstood.
- **Action:** none; the narrower scoping of the conformance test as
  "shape gate" is captured implicitly in the solution's verification-
  harness role.

### Claim 6: Consumer migration — `Tau.Session`, `Tau.Cost.Tracker`, and any TUI context-window display that reads `event.usage["input_tokens"]` / `Map.get(event.usage, ...)` migrates to `event.usage.input_tokens` struct access.

- **Claim (C):** Existing consumers that access `usage` via
  string-keyed lookup (`event.usage["input_tokens"]`) or
  `Map.get(event.usage, ...)` will switch to struct field access.
- **Grounds (G):** Grep of the live codebase
  (`grep -rn "Map.get(.*usage\\|event.usage" lib/`) returns:
  `lib/tau/providers/anthropic.ex:251` (adapter-internal usage of
  the partial accumulator, not a consumer);
  `lib/tau/compactor/summarize_tail.ex:32` —
  `Map.get(usage, :input_tokens, 0)`; `lib/tau/tui/app/view.ex:124` —
  `Map.get(model, :usage, %{input_tokens: 0, output_tokens: 0,
  cache_read: 0, cache_write: 0})`. `lib/tau/cost/tracker.ex:121-127`
  uses **atom-keyed bracket access** (`usage[:input_tokens]`), not
  string-keyed. So the *only* call sites are atom-key or `Map.get`
  with atom keys.
- **Warrant (W):** Struct field access (`event.usage.input_tokens`)
  is type-checked at compile time and Dialyzer-visible; bracket
  access on a struct (`event.usage[:input_tokens]`) is *also* legal
  in Elixir (the `Access` behaviour is auto-implemented for structs
  with `defstruct`'s atom keys) so existing call sites continue to
  compile **without migration** for atom-keyed reads. The solution's
  statement of the migration target is therefore over-broad.
- **Qualifier (Q) — NARROWED:** Holds only for consumer sites that
  use **string-keyed** access (`event.usage["input_tokens"]`); a grep
  finds **none** in the current codebase. The atom-keyed bracket
  access in `Tau.Cost.Tracker` and `Tau.Compactor.SummarizeTail`
  continues to work unchanged against the new struct. The TUI
  `Map.get(model, :usage, ...)` call site is a model lookup, not an
  event-usage lookup, and is unaffected. The migration step is
  therefore largely a no-op against the present codebase; only the
  Anthropic adapter's `merge_usage/2`-result construction site is
  changed (to wrap in `%Event.Usage{}`).
- **Rebuttal (R):** If a downstream extension or test helper outside
  `lib/` (e.g. `test/`, `priv/`, or an external plugin) reads
  `event.usage` via string keys, this would break silently. A
  repo-wide grep including `test/` is the minimum due-diligence
  step the implementer should perform.
- **Backing (B):** Elixir's `Access` behaviour documentation
  (https://hexdocs.pm/elixir/Access.html) confirms that `struct[key]`
  is rewritten to `Access.get(struct, key, nil)` and that
  `defstruct`-generated structs implement `Access.fetch/2` for atom
  keys.

#### Falsification attempt for claim 6

- **Strategy:** counter-example construction (search the codebase for
  the call sites the claim names).
- **Attempt:** Ran `grep -rn 'event.usage\\["\\|Map.get(.*usage'`
  across `lib/`. **No** string-keyed `event.usage["..."]` access
  exists. The closest match is `Map.get(usage, :input_tokens, 0)`
  in `summarize_tail.ex:32`, which uses an atom key against the
  current `usage: %{}` map; against the new `%Event.Usage{}` struct
  the same call still resolves correctly through the auto-derived
  `Access` implementation. The `Tau.Cost.Tracker` path is atom-
  bracket and continues to work. The TUI `view.ex:124` lookup is a
  model-field default, not an event-usage access, and is unaffected.
- **Outcome:** **partially falsified** — the migration cost the
  solution describes is over-stated against the present codebase.
  The string-keyed-access migration target named in claim 6 does
  not exist.
- **Action:** **narrow the qualifier in place** (done above). No
  solution revision required: the over-stated migration cost is a
  conservative-over-estimate, not a false claim about a required
  change. The actual minimum migration step is "wrap
  `Anthropic.merge_usage/2`'s return in `%Event.Usage{}`" — which
  is captured under claim 4's adapter edits, not as an independent
  consumer concern.

### Claim 7: SPEC amendment — `docs/spec/SPEC-PROMPT-CACHING.md` §4 B3 references the new `%Event.Usage{}` struct as the canonical carrier; `Tau.Provider.UsageNorm` is named as the shared adapter-side scaffold; D-065 wording updated to match.

- **Claim (C):** The SPEC's §4 B3 contract and D-065 invariant text
  are updated in the same PR(s) that land the struct + scaffold, so
  the SPEC and code stay in lock-step.
- **Grounds (G):** `docs/spec/SPEC-PROMPT-CACHING.md` lines 110, 126-155,
  169, 240 establish the current B3 + D-065 contract: "Cache-usage
  normalisation … is each adapter's own `merge_usage`-side
  responsibility." The text presupposes raw maps and per-adapter
  `merge_usage/2`; the solution proposes both a typed carrier
  (`%Event.Usage{}`) and a shared scaffold (`UsageNorm`) — both
  novelties the SPEC text does not yet name.
- **Warrant (W):** `.claude/rules/spec-before-code.md` mandates that
  PRs adding new state at a SPEC'd boundary land the corresponding §3
  entry and §4 contract update in the same PR (the rule's "What this
  rule forbids" first bullet). The `%Event.Usage{}` struct **is** new
  state at the §4 B3 boundary; therefore the SPEC amendment is not
  optional.
- **Qualifier (Q):** Holds unconditionally for this PR series — the
  rule admits no exception for "internal" struct additions.
- **Rebuttal (R):** None — the spec-before-code rule is binary and
  the boundary is unambiguously the same one §4 B3 names.
- **Backing (B):** `.claude/rules/spec-before-code.md` "What this rule
  forbids" §1 ("MUST NOT merge a PR that adds new state to a SPEC'd
  boundary without a corresponding §3 entry and §4 contract update in
  the same PR"); SPEC-PROMPT-CACHING line 192-195 (B3 / D-065 testing
  obligation).

#### Falsification attempt for claim 7

- **Strategy:** dependency check (does the inherited rule the warrant
  cites still hold today?).
- **Attempt:** Re-read `.claude/rules/spec-before-code.md` —
  SPEC-PROMPT-CACHING is named in "the current spec catalog" and its
  source-map (Appendix B) includes the adapter files the solution
  edits. The rule applies and is enforced by the critic/reviewer gate
  amendments (rule section "Critic / reviewer gate amendment").
- **Outcome:** withstood.
- **Action:** none; the solution already names the SPEC amendment
  under "What changes" — verify the implementer lands it in PR 1.

## Cross-claim consistency

Claims 1, 2, 3, 4, 5, and 7 form a compositional set: the struct
(claim 1) is the shape contract, the scaffold (claim 2) is the
construction helper, the wire edits (claims 3 and 4) populate it,
the conformance test (claim 5) gates it, and the SPEC amendment
(claim 7) records the new contract. No internal tension.

Claim 6 (consumer migration) was partially falsified — the migration
cost is over-stated. This **does not** create tension with the other
claims; it simplifies them. The Anthropic adapter edit under claim 4
("wrap existing `merge_usage/2` output in `%Event.Usage{}` via
`UsageNorm.from_anthropic/1`") covers the only consumer-visible
construction site that genuinely needs to change. Atom-keyed access
through the `Access` behaviour is the load-bearing detail that makes
this cheap.

One residual concern: the solution's open question §1 ("Should
`Done.usage` be `@enforce_keys`-required (not `nil`-allowed) after
migration?") creates a temporal coupling between PR 1 (which keeps
`nil` allowed) and a hypothetical follow-up that tightens to
required. This is acceptable as scoped — the open question is
explicit — but the parent's validator should not credit "the
canonical key set is enforced at the type system" as fully achieved
until the tightening lands.

## Falsification summary

| # | Claim (short) | Strategy | Outcome | Action |
|---|---|---|---|---|
| 1 | `%Event.Usage{}` struct replaces `usage: map()` | type-level check | withstood | none |
| 2 | `UsageNorm` shared scaffold module | counter-example construction | withstood | none |
| 3 | OpenAI-family `stream_options.include_usage` + emit | edge-case enumeration | withstood | none |
| 4 | Bedrock `message_start` accumulate + Gemini `usageMetadata` read | dependency check | withstood | none |
| 5 | Shared `ProviderConformance` template, 11 instances | integration check | withstood | none |
| 6 | Migrate consumers from string-key to struct access | counter-example construction | partially_falsified | narrow Q in place — done |
| 7 | SPEC §4 B3 + D-065 amendment in the same PR | dependency check | withstood | none |

## Revision required

No solution or problem revision is required. Claim 6's qualifier is
narrowed in place above; the solution's prose over-states the
migration cost but does not require a different *technical* solution.

- **Target file:** n/a
- **Revision kind:** n/a
- **Rationale:** Partial falsifications narrow qualifiers in place
  (per validate.md §5); no revision required.

## Outstanding doubts

- **OpenAI.Responses wire-extraction.** The solution names it as a
  conformance target but does not specify `from_openai_responses/1`
  in `UsageNorm`. Open question §3 captures this; the implementer
  must close it in PR 2 scoping.
- **Custom-adapter rebuttal under claim 3.** Self-hosted OpenAI-
  compatible servers may reject `stream_options.include_usage`. The
  worst case is zero-fill, not crash, but this should be added to
  the solution's open questions for downstream-user visibility.
- **Replay deserialiser shape coverage.** Open question §2 captures
  this. The conformance test (claim 5) relies on fixtures replayed
  through `Tau.Providers.Replay`, so the deserialiser must construct
  `%Event.Usage{}` before the conformance test for any adapter that
  uses Replay-driven fixtures can go green.
- **Fixture refresh policy.** Claim 5's rebuttal — the live API may
  drift from the fixture — is a codebase-wide concern this solution
  does not address. Not a defect of this solution; a known gap.
- **`@enforce_keys` tightening (open question §1).** Until the
  follow-up that removes the `| nil` transitional qualifier lands,
  the type-level enforcement claim 1 makes is partial: a careless
  adapter can still emit `%Event.Done{usage: nil}` without a
  compile error.
