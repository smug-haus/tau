---
template_version: 1
template_name: solution
parent_problem: problem.md
node_kind: leaf
synthesised_from:
  - proposals/proposal-1.md
  - proposals/proposal-3.md
selection_method: hybrid
revision: 0
---

# Solution: `stream_contract/0` mandatory callback + `@stream_contract` attribute spec

## Recommendation

Add a mandatory `@callback stream_contract() :: Tau.Provider.StreamContract.t()` to
`Tau.Provider`, backed by a new `Tau.Provider.StreamContract` struct (Proposal 3), and
simultaneously add a `@stream_contract` module attribute to `Tau.Provider` carrying the
human-readable canonical sequence (Proposal 1). The struct makes non-conformance
machine-detectable at compile time and self-falsifying via a property test; the attribute
gives new adapter authors an immediate narrative specification at the behaviour module.
Non-conforming adapters (Bedrock, Gemini) declare their actual posture
(`:delta_only`, `:sentinel`) rather than claiming conformance — making the gap visible in
code. The normaliser shim (Proposal 2) and the live decode-path rewrites (Proposal 4)
are explicitly deferred: the declaration layer is the work this problem asks for;
elimination of non-conformance is a separate, riskier task that should follow once the
contract is codified and the test baseline is green.

## Selected from

- **Chosen:** hybrid of `proposals/proposal-3.md` (primary) + `proposals/proposal-1.md`
  (secondary).
- **Why chosen:** See scoring table below.

### Scoring table

| # | Fit | Decomplecting depth | Migration cost | Risk | Reversibility |
|---|-----|---------------------|----------------|------|---------------|
| 1 | Partially | Surface | Low | Low | Easy |
| 2 | Partially | Substantial | Medium | Low | Easy |
| 3 | Yes | Deep | Medium | Low | Easy |
| 4 | Yes | Deep | High | High | Hard |

**Proposal 1** satisfies the acceptance criterion only partially: `@stream_contract` as a
bare map attribute and a doc-coverage Mix task make the gap *readable* but not
machine-checkable at the type or callback level. An adapter that omits the moduledoc
paragraph still compiles and passes Dialyzer. Decomplecting is surface-level — the
complecting (contract decision per-adapter) remains; only documentation moves.

**Proposal 2** satisfies the criterion partially. `EventNormaliser.wrap` enforces the
sequence at runtime but does not *declare* it at the behaviour layer — the `@callback`
docstring is unchanged, and adapters are not required to declare their posture.
Non-conformance is hidden rather than surfaced. The normaliser is a valuable follow-on
once the declaration exists, but alone it does not answer "which event types are
mandatory" at the behaviour module.

**Proposal 3** satisfies the criterion fully. The mandatory `stream_contract/0` callback
forces each adapter to publish its posture as a typed struct; Dialyzer flags missing
implementations; a self-consistency test holds adapters to their declaration. This is
the deepest decomplecting available without changing live decode paths: contract
decisions move from implicit per-adapter to the single shared struct type. Migration
cost is medium (11 adapters × ~5 LOC) but low risk — the callback is pure/stateless;
no stream path changes.

**Proposal 4** also satisfies the criterion fully and eliminates root-cause non-conformance,
but carries high risk (live decode-path rewrites for Bedrock and Gemini, fixture
dependencies, possible Assembler coupling) and is hard to reverse if a fixture gap
causes a regression. It is the right *follow-on* once the declaration layer is in place
and fixtures are confirmed, not the right first step.

**Hybrid rationale:** Proposal 3 alone is the right primary selection. Proposal 1's
`@stream_contract` map attribute adds complementary value as narrative documentation
co-located with the callback — it costs nothing (already proposed, ~10 LOC) and
immediately answers "what does a conformant sequence look like" for new adapter authors
without requiring them to decode the struct. The two elements are additive, not
conflicting: the attribute is prose; the callback is machine-checkable. This is
composition, not mixing.

## What changes

- **`lib/tau/provider/stream_contract.ex`** (new file) — define
  `Tau.Provider.StreamContract` struct with fields `text_framing`, `tool_call_delta`,
  `block_id_uniqueness`, `thinking_framing`; provide `conformant/0` convenience
  constructor.
- **`lib/tau/provider.ex`** — add `@callback stream_contract() ::
  Tau.Provider.StreamContract.t()`; add `@stream_contract` map attribute with canonical
  sequence prose; update `@callback stream/3` docstring to reference both.
- **`lib/tau/providers/anthropic.ex`** — add `@impl Tau.Provider` `stream_contract/0`
  returning `StreamContract.conformant()`.
- **`lib/tau/providers/bedrock.ex`** — add `@impl` `stream_contract/0` returning
  `%StreamContract{text_framing: :delta_only, block_id_uniqueness: :sentinel, ...}`.
- **`lib/tau/providers/gemini.ex`** — add `@impl` `stream_contract/0` returning
  `%StreamContract{text_framing: :delta_only, tool_call_delta: :atomic, ...}`.
- **All remaining adapters** (`openai_chat_wire` consumers, Groq, Mistral, DeepSeek,
  AzureOpenAI, Custom, Copilot, Replay) — add `@impl` `stream_contract/0`; conformant
  adapters return `StreamContract.conformant()`; others declare their actual posture.
- **`test/tau/provider_stream_contract_test.exs`** (new file) — self-consistency test
  per adapter: call `stream_contract/0`, run a Replay-fixture stream, assert emitted
  events match the declared contract.
- **`lib/tau/provider.ex`** — optionally add `known_adapters/0` helper (or hardcode list
  in the test module).

## What does not change

- `Tau.Provider.Event` struct definitions — no new event types.
- `Tau.Message.Assembler` — tolerances are left in place; removing them is a follow-on
  gated on Proposal 4 (adapter fixes) landing.
- `Tau.Providers.Bedrock` and `Tau.Providers.Gemini` decode paths — no behavioural
  changes; non-conformance is declared, not fixed.
- `lib/tau/providers/shared/openai_chat_wire.ex` — TextStart synthesis logic unchanged.
- Session FSM (`lib/tau/session.ex`) and render loop — no changes.
- The `@callback stream/3` signature — no new required parameters.

## Migration sketch

First introduce `Tau.Provider.StreamContract` struct and `@stream_contract` attribute in
`provider.ex` (no compilation breakage yet — callback is not yet mandatory). Then add
`@callback stream_contract/0` and implement it on all eleven adapters in the same PR,
ensuring `mix compile --warnings-as-errors` passes before merging. Land the
self-consistency test in the same PR with Replay fixtures confirmed for Bedrock and
Gemini. If fixture confirmation for a specific adapter is blocked, that adapter may ship
a `:test_only` or `:unknown` sentinel value with a `# TODO` and a follow-on issue filed
— but the callback implementation must exist for the PR to compile. Proposal 4 (decode
rewrites) is a separate subsequent PR once this test baseline is green.

## Open questions

- **Replay fixture completeness:** do byte-accurate Bedrock `content_block_start` /
  `content_block_stop` and Gemini `functionCall` fixtures exist in `test/support/`?
  Without them, the self-consistency test for those adapters cannot run. The landing
  strategy above handles this via a `:test_only` posture, but it degrades the test
  value.
- **`Tau.Providers.Replay` posture:** the Replay adapter is intentionally divergent.
  Should it declare `stream_contract/0` with a special `:replay` variant, or re-emit the
  original adapter's contract? This needs a decision before the callback can be marked
  `@impl`.
- **`known_adapters/0` vs hardcoded list:** adding a helper on the behaviour introduces
  coupling between the behaviour and the adapter module list. A module attribute or a
  test-only helper may be cleaner. No strong opinion here; worth a one-line note in the
  PR.
- **OpenAI shared wire path gap:** `openai_chat_wire.ex:108-166` silently omits
  `TextStart` on empty first deltas. This is not fixed by this solution; should it be
  tracked in a separate issue before or after this PR lands?

## Linked sub-problems / proposals

- `proposals/proposal-1.md` — `@stream_contract` module attribute + compile-time
  typedoc spec (contributes narrative attribute; Mix task omitted as superseded by
  self-consistency test)
- `proposals/proposal-2.md` — `EventNormaliser` stream wrapper (deferred; valid
  follow-on after declaration layer lands)
- `proposals/proposal-3.md` — mandatory `stream_contract/0` callback + Dialyzer struct
  (primary; full acceptance criterion satisfaction)
- `proposals/proposal-4.md` — fix non-conforming adapters at source (deferred; right
  follow-on once declaration + test baseline is green)

## Revision history

- (revision 0 — initial)
