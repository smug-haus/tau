---
template_version: 1
template_name: solution
parent_problem: problem.md
node_kind: leaf
synthesised_from: [proposals/proposal-1.md, proposals/proposal-2.md]
selection_method: hybrid
revision: 0
---

# Solution: typed `%Event.Usage{}` struct plus shared `UsageNorm` scaffold and conformance test

## Recommendation

Replace `usage: map()` on `%Event.Done{}` with a typed `%Tau.Provider.Event.Usage{}`
struct (`@enforce_keys [:input_tokens, :output_tokens]`; `cache_read`,
`cache_write`, `cache_breakdown` defaulted), and introduce
`Tau.Provider.UsageNorm` as the shared wire-format-to-canonical scaffold each
adapter uses to construct that struct from its upstream payload. The struct
fixes the *shape* contract at the type system; `UsageNorm` plus per-adapter
wire-extraction edits (OpenAI-family `stream_options.include_usage`, Bedrock
`message_start`/`message_stop` accumulation, Gemini `usageMetadata` read,
Anthropic delegating to its existing `merge_usage/2`) fix the *data* gap. A
shared conformance test iterates all production adapters and asserts the
struct invariants on a representative replay fixture per adapter — this is the
verification mechanism the acceptance criterion names.

## Selected from

- **Chosen:** hybrid of `proposals/proposal-1.md` and `proposals/proposal-2.md`
- **Why chosen:** Proposal 2 is the strongest decomplecting mechanism on
  hypothesis (1) — a struct removes "adapter identity determines key presence"
  at the type-system level, which neither a behaviour callback (P1) nor a
  consumer-side normaliser (P3) nor a test (P4) can match. Proposal 1 is the
  strongest mechanism on hypothesis (2) — the `UsageNorm` module is the shared
  scaffold adapters call into to convert their wire format. Neither proposal
  alone is sufficient: P2 alone leaves adapters to hand-roll their own
  extraction (the scaffold is missing), and P1 alone leaves `usage` as an
  unstructured `map()` that a careless adapter can still leave empty. Combined,
  the struct enforces shape and `UsageNorm` supplies the wire-extraction
  helpers — composition, not aggregation. Proposal 3 is rejected because its
  own tradeoffs document that it fails the AC ("the AC explicitly requires
  adapters to emit real counts, not consumers to zero-fill"); the consumer-side
  normaliser would mask, not fix, the silent-zero problem. Proposal 4's
  conformance-test scaffold is incorporated as the verification harness, not
  the primary mechanism — its forcing-function-via-test-failure approach is
  weaker than P2's compile-time enforcement, but the shared
  `Tau.Test.ProviderConformance` template is the right shape for AC
  verification once the struct and `UsageNorm` are in place.

## What changes

- `lib/tau/provider/event.ex` — add `Tau.Provider.Event.Usage` struct with
  `@enforce_keys [:input_tokens, :output_tokens]` and defaulted cache fields;
  update `Done.t()` to `usage: Tau.Provider.Event.Usage.t() | nil`.
- `lib/tau/provider/usage_norm.ex` — new module with `zero/0`, `nonneg/1`,
  `from_openai/1`, `from_gemini/1`, `from_bedrock/1`, `from_anthropic/1`
  helpers returning `%Event.Usage{}` (not raw maps). `from_anthropic/1`
  internally delegates to the existing `Anthropic.merge_usage/2` shape.
- `lib/tau/providers/shared/openai_chat_wire.ex` — set
  `stream_options: %{include_usage: true}` in `build_body/4`; accumulate the
  final SSE chunk's `usage` into partial; emit
  `%Event.Done{usage: UsageNorm.from_openai(raw)}` on `[DONE]`.
- `lib/tau/providers/bedrock.ex` — accumulate usage from `message_start` into
  partial; emit `%Event.Done{usage: UsageNorm.from_bedrock(raw)}` in
  `message_stop` handler.
- `lib/tau/providers/gemini.ex` — read `json["usageMetadata"]` in finish-reason
  handler; emit `%Event.Done{usage: UsageNorm.from_gemini(raw)}`.
- `lib/tau/providers/anthropic.ex` — wrap existing `merge_usage/2` output in
  `%Event.Usage{}` via `UsageNorm.from_anthropic/1`.
- `test/support/provider_conformance.ex` — shared ExUnit case template
  (Proposal 4 shape) that asserts the last `%Event.Done{}` in a fixture stream
  carries a `%Event.Usage{}` with non-negative-integer required fields.
- `test/tau/providers/*_conformance_test.exs` — one per production adapter
  (Anthropic, OpenAI.Chat, OpenAI.Responses, Gemini, Bedrock, Groq, Mistral,
  DeepSeek, AzureOpenAI, Custom, Copilot), each `use`-ing the shared template
  with its adapter module and fixture path.
- `priv/fixtures/*.jsonl` — new or extended fixture files for adapters that
  lack a usage-bearing fixture today.
- Consumer migration: `Tau.Session`, `Tau.Cost.Tracker`, and any TUI
  context-window display that reads `event.usage["input_tokens"]` /
  `Map.get(event.usage, ...)` migrates to `event.usage.input_tokens` struct
  access.
- SPEC amendment: `docs/spec/SPEC-PROMPT-CACHING.md` §4 B3 references the new
  `%Event.Usage{}` struct as the canonical carrier; `Tau.Provider.UsageNorm`
  is named as the shared adapter-side scaffold. D-065 wording updated to match.

## What does not change

- The `Tau.Provider` behaviour gains no new mandatory callback. The scaffold
  is a plain module adapters call into; the struct enforces shape. (Optional
  `normalise_usage/1` from P1 is dropped — the struct + `UsageNorm` module
  together cover its decomplecting role without adding a behaviour surface.)
- `%Event.Done{}` keeps `usage: nil` allowed during transition, so existing
  emission sites that have not yet been migrated still compile.
- The `Replay` provider's JSONL fixture format is unchanged; conformance tests
  reuse it.
- No new HTTP client, JSON library, or runtime dependency is introduced.
- Out-of-scope items in `problem.md` (event sequencing, capabilities flags,
  auth resolution) remain untouched.

## Migration sketch

Three sequenced PRs, each independently shippable and reversible:

1. **Struct + scaffold + Anthropic migration.** Land `Tau.Provider.Event.Usage`,
   `Tau.Provider.UsageNorm` (with `from_anthropic/1` and `zero/0`), update
   `Anthropic` to emit `%Event.Usage{}`, migrate `Tau.Session` and
   `Tau.Cost.Tracker` consumers to struct access. Anthropic was already the
   only adapter emitting real counts, so this PR is behaviour-preserving for it
   and behaviour-improving for consumers (typed access). Reversible: revert
   the consumer-access change and the `Done.t()` typespec.
2. **OpenAI-family + Bedrock + Gemini wire-extraction + their conformance
   tests.** Add `stream_options.include_usage` to OpenAI-family request bodies,
   accumulate Bedrock `message_start` usage, read Gemini `usageMetadata`. Each
   adapter's conformance test goes red before the wire-extraction lands and
   green after — the test is the forcing function (Proposal 4's contribution).
   Reversible per-adapter.
3. **Shared conformance template + remaining adapters.** Land
   `Tau.Test.ProviderConformance` and the per-adapter conformance test files
   for adapters whose fixtures already exist; author missing fixtures last.
   Wire `mix tau.conformance` Mix task as a fast targeted gate.

Order matters: the struct must land before adapters can emit it; the
conformance tests must follow the wire-extraction so they go green on the same
PR rather than landing as known-failing baseline.

## Open questions

- **Should `Done.usage` be `@enforce_keys`-required (not `nil`-allowed) after
  the migration completes?** A follow-up tightening PR could remove the `nil`
  default once every emission site is migrated, converting "careless adapter
  emits nil" from a Dialyzer warning into a compile error. The initial PRs
  leave `nil` allowed to keep migration staged.
- **How does Replay reconstruct `%Event.Usage{}` from JSONL?** The Replay
  decoder currently materialises raw maps; a small deserialiser
  `Event.Usage.from_replay/1` is needed. Scope this in PR 2 or PR 3.
- **Are `OpenAI.Responses`, `Groq`, `Mistral`, `DeepSeek`, `Azure`, `Custom`,
  `Copilot` all on the same `OpenAIChatWire` decode path?** If yes, the
  OpenAI-family fix in PR 2 covers all of them; if any has a divergent decode
  loop, that adapter needs its own wire-extraction edit. Verify by grep before
  scoping PR 2.
- **Does `cache_breakdown` need a typespec narrower than `map()`?** SPEC-
  PROMPT-CACHING §4 B3 defines sub-keys for Anthropic only; other adapters
  pass `%{}`. Left as `map()` initially; tighten if a downstream consumer
  requires it.
- **Should `UsageNorm` be moved under `Tau.Provider.Event.Usage` as
  constructor helpers (`Event.Usage.from_openai/1`) rather than a sibling
  module?** Stylistic; sibling module mirrors the existing
  `Tau.Provider.Event.Error` placement and keeps wire-shape knowledge out of
  the canonical struct module.

## Linked sub-problems / proposals

- `proposals/proposal-1.md` — `normalise_usage/1` behaviour callback with
  shared zero-default scaffold. Contributes: the `Tau.Provider.UsageNorm`
  module and the wire-extraction obligation at each adapter.
- `proposals/proposal-2.md` — `%Event.Usage{}` typed struct replaces
  `usage: map()` in `Done.t()`. Contributes: the type-level enforcement of
  the canonical key set; the primary decomplecting mechanism.
- `proposals/proposal-3.md` — Stream post-processor at the session boundary.
  Rejected: per its own tradeoffs, fails the acceptance criterion by zero-
  filling rather than extracting real wire data.
- `proposals/proposal-4.md` — Shared `ExUnit.Case` template +
  `mix tau.conformance`. Contributes: the verification harness shape
  (`Tau.Test.ProviderConformance` template, per-adapter conformance files,
  Mix task). Rejected as the primary mechanism in favour of struct-level
  enforcement.

## Revision history

- (revision 0 — initial)
