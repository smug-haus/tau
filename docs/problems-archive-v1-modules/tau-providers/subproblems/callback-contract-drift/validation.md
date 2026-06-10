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

# Validation: `stream_contract/0` mandatory callback + `@stream_contract` attribute spec

## Overview

The solution proposes a hybrid of Proposal 3 (a mandatory
`@callback stream_contract() :: Tau.Provider.StreamContract.t()` plus a typed
struct) and Proposal 1 (a `@stream_contract` module attribute carrying canonical
prose), with the runtime decode paths and the assembler tolerances explicitly
left alone. This validation extracts eight distinct propositions from
Recommendation + What changes + What does not change. Each receives a six-field
Toulmin with an explicit named falsification strategy. Outcome: seven claims
withstand; claim 6 ("All remaining adapters … add `@impl stream_contract/0`")
is **partially falsified** by counter-example construction — the enumeration in
the solution lists `Copilot` as one of the eleven adapters, but no module in
`lib/tau/providers/copilot/` carries `@behaviour Tau.Provider`; the actual
eleven-adapter set is the one this validation checked. Qualifier narrowed in
place; no revision required.

## Toulmin per claim

The MITRE empirical study on Toulmin formalism found that participants
"found it difficult to generate Toulmin structures, and their structures varied
greatly even though they started with the same content"
(<https://www.mitre.org/news-insights/publication/empirical-evaluation-structured-argumentation-using-toulmin-argument>).
The per-field prompts below are filled explicitly to counter that variance.

### Claim 1: Adding a mandatory `@callback stream_contract() :: Tau.Provider.StreamContract.t()` satisfies the acceptance criterion's "behaviour declares the mandatory event-emission rules for `stream/3`" clause.

- **Claim (C):** "Add a mandatory `@callback stream_contract() ::
  Tau.Provider.StreamContract.t()` to `Tau.Provider`, backed by a new
  `Tau.Provider.StreamContract` struct" — and (problem.md:60-66) "such that any
  adapter not conforming to these rules is detectable without reading the
  adapter's decode path."
- **Grounds (G):** `lib/tau/provider.ex:67` today says only "elements are
  `Tau.Provider.Event` structs". The struct sketch in proposal-3.md:48-66
  encodes the missing axes (`text_framing`, `tool_call_delta`,
  `block_id_uniqueness`, `thinking_framing`). After the change, an adapter's
  posture is readable in its `stream_contract/0` body without opening the
  decode path — e.g. Bedrock returns `text_framing: :delta_only`
  (proposal-3.md:86-93) rather than today's implicit emission at
  `lib/tau/providers/bedrock.ex:118-119`.
- **Warrant (W):** A behaviour callback whose return type is a typed struct
  promotes adapter posture from implicit (read decode source) to explicit
  (read one function). Behaviour callbacks are Tau's canonical declarative
  seam (OTP non-negotiable #2: "Extensibility seams MUST be behaviours.
  Pattern match on atoms and structs.").
- **Qualifier (Q):** Holds for adapters that honestly declare their posture.
  An adapter that returns `conformant()` while still emitting bare deltas
  satisfies the callback but lies; that residual is closed by claim 7
  (self-consistency test), not by this claim.
- **Rebuttal (R):** Does NOT hold if the struct's field set fails to model
  a real divergence — e.g. an adapter that *interleaves* tool-call deltas
  across two blocks has no field expressing that. The four fields are
  necessary but may not be exhaustive; future divergences may require new
  fields.
- **Backing (B):** `.claude/rules/otp-non-negotiables.md` invariant #2
  ("Extensibility seams MUST be behaviours … pattern match on atoms and
  structs"); prior art `@callback capabilities() :: capabilities()` at
  `lib/tau/provider.ex:70` — same "declare-your-posture-as-a-struct" idiom
  the solution mirrors.

#### Falsification attempt for claim 1

- **Strategy:** Counter-example construction — try to construct a
  non-conforming adapter that the new callback would NOT detect.
- **Attempt:** Examined Bedrock (`lib/tau/providers/bedrock.ex:118-119`),
  Gemini (`lib/tau/providers/gemini.ex:95-109`), and the OpenAI shared wire
  (`lib/tau/providers/shared/openai_chat_wire.ex:158-166`). For each, asked
  "does the four-field struct express the divergence?". Bedrock's
  `text_framing: :delta_only` + `block_id_uniqueness: :sentinel` covers
  both its issues. Gemini's `text_framing: :delta_only` + `tool_call_delta:
  :atomic` covers its tool-call batching. The OpenAI wire's "first-delta
  TextStart synthesis" is *conformant* once synthesised (sequence is
  Start→Delta→End), so no new axis needed. Then probed the
  open-question case (solution.md:128-133): adapters with no fixture
  available. The callback still requires a declaration; detection is not
  blocked by fixture absence — only the self-consistency test (claim 7) is.
- **Outcome:** withstood — the struct's field set models every divergence
  cited in problem.md. Future axes may surface, but the criterion as
  written ("detectable without reading the adapter's decode path") is
  satisfied today.
- **Action:** none.

### Claim 2: A `@stream_contract` module attribute on `Tau.Provider` (prose canonical sequence) is additive — composes with the callback rather than conflicts.

- **Claim (C):** "simultaneously add a `@stream_contract` module attribute to
  `Tau.Provider` carrying the human-readable canonical sequence" and
  "composition, not mixing" (solution.md:73-78).
- **Grounds (G):** Proposal-1.md:39-59 shows the attribute as a bare map of
  required sequences. Proposal-3.md:38-66 shows the struct as machine-
  readable. The attribute is doc-only (proposal-1.md:30-32: "No runtime
  overhead"); the struct is machine-checkable. Their effects are disjoint
  (prose vs. typed value).
- **Warrant (W):** Two declarative artefacts at the same module compose
  when one is prose-for-humans and the other is data-for-tools and neither
  is the source of truth for the other. The behaviour module already
  carries `@type` (prose-shaped) alongside `@callback` (machine-shaped)
  — e.g. `capabilities` at `lib/tau/provider.ex:59-70`.
- **Qualifier (Q):** Holds provided the prose attribute and the struct
  fields remain semantically aligned over time (i.e., a struct field added
  later is also reflected in the attribute prose).
- **Rebuttal (R):** Does NOT hold if the attribute is treated as
  load-bearing — e.g. a future Mix task asserts adapter moduledocs
  reference it (proposal-1.md:84-117 sketches exactly this). At that
  point the attribute is no longer "prose"; it becomes a second
  enforcement axis with a drift risk against the struct.
- **Backing (B):** `tau-architecture` §"behaviour callback order is
  load-bearing"; the existing `lib/tau/provider.ex` already uses prose
  `@typedoc` alongside `@type` alongside `@callback` without conflict.

#### Falsification attempt for claim 2

- **Strategy:** Edge-case enumeration — list ways the two artefacts could
  conflict.
- **Attempt:** Enumerated four edge cases: (a) attribute claims a sequence
  the struct cannot express → conflict; (b) struct adds a field the
  attribute prose omits → drift but not contradiction; (c) attribute
  becomes Mix-task-checked → enforcement axis multiplies; (d) consumer
  reads attribute and bypasses struct → consumer-level drift. Of these,
  (a) is preventable by treating struct as source of truth at the
  behaviour module; (b) is a documentation hygiene concern, not a
  conflict; (c) is exactly what proposal-1 envisaged but the solution
  defers it ("Mix task omitted as superseded by self-consistency test"
  solution.md:148-150); (d) is the rebuttal above.
- **Outcome:** withstood — given the solution's deferral of the Mix task,
  the attribute remains prose and composes cleanly with the struct.
- **Action:** none. Note for future PR authors: keep the struct as source
  of truth; the attribute is a human-facing mirror.

### Claim 3: The new mandatory callback is type-checkable by Dialyzer when the return type doesn't match `StreamContract.t()`.

- **Claim (C):** "the struct makes non-conformance machine-detectable at
  compile time" (solution.md:21) — i.e., a `stream_contract/0` returning
  the wrong shape is caught by Dialyzer.
- **Grounds (G):** Proposal-3.md:147-148 asserts "Dialyzer will flag any
  adapter whose `stream_contract/0` return type doesn't match
  `StreamContract.t()`." The `@callback` syntax with a struct return type
  is supported in Elixir/Dialyzer; the project already uses this for
  `@callback capabilities() :: capabilities()`
  (`lib/tau/provider.ex:59-70`).
- **Warrant (W):** Dialyzer's success-typing follows `@callback`
  specifications; an implementation whose actual return diverges from the
  callback's typespec produces a warning under `mix dialyzer`. The project
  runs Dialyzer as a hard lint (`CLAUDE.md` Project Context: "Lint: …
  `mix dialyzer`").
- **Qualifier (Q):** Holds for *structural* divergences (wrong field, wrong
  field type). Does NOT hold for *value* divergences within the declared
  type (e.g. returning `text_framing: :delta_only` while emitting
  start/delta/end events). Value-level correctness is claim 7's territory.
- **Rebuttal (R):** Dialyzer's success-typing is permissive; if an adapter
  returns a value of the right struct shape but with `nil` in a non-
  enforced field, Dialyzer may not flag it. The `@enforce_keys` in
  proposal-3.md:48 limits this (compile-time error for missing keys), but
  optional fields remain permissive.
- **Backing (B):** Elixir documentation, "Defining behaviours" — Dialyzer
  checks `@callback` specs against `@impl` implementations. The existing
  `capabilities/0` callback in `Tau.Provider` is the working precedent.

#### Falsification attempt for claim 3

- **Strategy:** Type-level check (mentally) — model whether Dialyzer would
  warn on each divergence kind.
- **Attempt:** Enumerated: (i) adapter omits `stream_contract/0` entirely
  → Elixir compiler emits "behaviour callback not implemented" warning
  (predates Dialyzer); (ii) adapter returns `{:ok, struct}` instead of the
  struct → Dialyzer flags `{:ok, ...}` ≠ `StreamContract.t()`; (iii) adapter
  returns `%StreamContract{text_framing: "delta_only"}` (string not atom)
  → Dialyzer flags because the type declares `:delta_only` atom literals;
  (iv) adapter returns `%StreamContract{...}` with all fields legal but
  semantically lying → Dialyzer cannot detect (this is claim 7's
  territory).
- **Outcome:** withstood — for structural divergence (the claim's scope).
  Confirms the rebuttal above: value-level lies escape Dialyzer.
- **Action:** none. The qualifier already excludes value-level
  divergence.

### Claim 4: `lib/tau/providers/anthropic.ex` can declare `StreamContract.conformant()` without behavioural changes.

- **Claim (C):** "`lib/tau/providers/anthropic.ex` — add `@impl Tau.Provider`
  `stream_contract/0` returning `StreamContract.conformant()`."
  (solution.md:89-90).
- **Grounds (G):** `lib/tau/providers/anthropic.ex:182-247` shows
  `dispatch/3` emitting `TextStart` on `content_block_start`, `TextDelta`
  on `content_block_delta`, `TextEnd` on `content_block_stop` — and
  symmetric `ToolCallStart`/`ToolCallDelta`/`ToolCallEnd` and
  `ThinkingStart`/`ThinkingDelta`/`ThinkingEnd`. Each block carries a
  unique `block_id` (`"anth_text_#{idx}"`, `cb["id"]` for tool_use).
- **Warrant (W):** A declaration of `conformant()`
  (`text_framing: :start_delta_end, tool_call_delta: :streaming,
  block_id_uniqueness: :per_stream, thinking_framing: :start_delta_end`)
  matches Anthropic's observed sequence iff the dispatch emits framing
  for every block kind with unique ids. The grep above confirms it does.
- **Qualifier (Q):** Holds for Anthropic's primary (Messages API) wire
  format. The Bedrock-Anthropic shared path
  (`lib/tau/providers/bedrock.ex:111-124` reuses Anthropic-shaped JSON)
  is a *different* adapter and is correctly declared `:delta_only` in the
  solution.
- **Rebuttal (R):** Does NOT hold if Anthropic introduces a wire-level
  shape (e.g. a multi-block-start without a paired stop) that breaks
  framing. The declaration would then need updating. The codebase today
  does not exhibit this case.
- **Backing (B):** `lib/tau/providers/anthropic.ex:182-247` itself
  (working source code, post-PR-373); the existing
  `capabilities/0` pattern at the same module documents this
  declare-your-posture idiom.

#### Falsification attempt for claim 4

- **Strategy:** Counter-example construction — try to find an Anthropic
  emission path that violates `conformant()`.
- **Attempt:** Walked every `dispatch/3` clause for Anthropic
  (`lib/tau/providers/anthropic.ex:182-260`). The `content_block_start`,
  `content_block_delta`, `content_block_stop` handlers always pair
  `TextStart` with `TextEnd` on the same `anth_text_#{idx}` id. For
  thinking blocks, the same start/delta/end triplet uses
  `anth_think_#{idx}`. For tool_use, the dispatch uses `cb["id"]`
  consistently (proposal does emit `ToolCallStart` + `ToolCallDelta`
  fragments + `ToolCallEnd`). No clause was found that emits a delta
  without a preceding start on the same id.
- **Outcome:** withstood.
- **Action:** none.

### Claim 5: `lib/tau/providers/bedrock.ex` honestly declares `:delta_only` + `:sentinel`, and `lib/tau/providers/gemini.ex` honestly declares `:delta_only` + `:atomic` — neither requires decode-path changes.

- **Claim (C):** Bedrock returns
  `%StreamContract{text_framing: :delta_only, block_id_uniqueness:
  :sentinel, …}`; Gemini returns
  `%StreamContract{text_framing: :delta_only, tool_call_delta: :atomic,
  …}` (solution.md:91-94).
- **Grounds (G):** Bedrock at `lib/tau/providers/bedrock.ex:118-119`:
  `decode_anthropic_event(%{"type" => "content_block_delta", "delta" =>
  %{"text" => t}}, p), do: {[%Event.TextDelta{block_id: "text", text: t}],
  p}` — bare `TextDelta` with hardcoded sentinel `"text"`, no
  `content_block_start` handler emitting `TextStart`. Gemini at
  `lib/tau/providers/gemini.ex:95-110`: emits `%Event.TextDelta{block_id:
  "text"}` and (for tool calls) `[ToolCallStart, ToolCallEnd]` in a
  single decoded chunk with no `ToolCallDelta` between them.
- **Warrant (W):** The struct's value space (`:delta_only`, `:sentinel`,
  `:atomic`) was designed exactly to express these divergences (the
  problem.md cited them as the motivating cases). An honest declaration
  is the literal mapping of the observed emission to the struct field
  set.
- **Qualifier (Q):** Holds as long as the decode paths remain unchanged
  (the solution explicitly defers fixing them: "Bedrock and Gemini decode
  paths — no behavioural changes", solution.md:108-110). If a future PR
  fixes framing without updating the declaration, the self-consistency
  test (claim 7) catches the drift.
- **Rebuttal (R):** Does NOT hold for the *unhandled clauses* — e.g.
  Bedrock's `defp decode_anthropic_event(_, p), do: {[], p}` swallows
  `content_block_start` and `content_block_stop` silently
  (`lib/tau/providers/bedrock.ex:124`). The declaration `:delta_only`
  describes what *is* emitted; it does not describe what is *silently
  ignored from upstream*. The acceptance criterion ("detectable without
  reading the decode path") is still met because the declaration plus
  the test exercise the emitted stream end-to-end.
- **Backing (B):** problem.md:30-40 cites both adapters as the canonical
  divergence cases the struct is designed to model.

#### Falsification attempt for claim 5

- **Strategy:** Counter-example construction — try a decode-path case
  where the declaration would mislead consumers.
- **Attempt:** For Bedrock, considered: if a stream contains multiple
  text blocks (multi-message response), every `TextDelta` carries the
  same `"text"` block_id. Consumers reading `block_id` cannot
  disambiguate. But `block_id_uniqueness: :sentinel` *declares exactly
  this* — consumers pattern-matching on the declaration are warned. For
  Gemini, considered: a function call with empty `args` produces
  `ToolCallEnd{params: %{}}` — does this break `:atomic`? Inspecting
  `lib/tau/providers/gemini.ex:107-109`, the pair is always
  `[ToolCallStart, ToolCallEnd]` — empty args are still atomic; the
  declaration holds.
- **Outcome:** withstood. The declarations match the observed emission.
- **Action:** none.

### Claim 6: All remaining adapters (`openai_chat_wire` consumers, Groq, Mistral, DeepSeek, AzureOpenAI, Custom, Copilot, Replay) add `@impl stream_contract/0` returning either `conformant()` or their actual posture.

- **Claim (C):** "All remaining adapters (`openai_chat_wire` consumers,
  Groq, Mistral, DeepSeek, AzureOpenAI, Custom, Copilot, Replay) — add
  `@impl` `stream_contract/0`" (solution.md:95-97).
- **Grounds (G):** `grep -rln "@behaviour Tau.Provider"
  /home/brentw/src/tau/lib/` lists exactly eleven files: `anthropic.ex`,
  `azure_openai.ex`, `bedrock.ex`, `custom.ex`, `deepseek.ex`,
  `gemini.ex`, `groq.ex`, `mistral.ex`, `openai/chat.ex`,
  `openai/responses.ex`, `replay.ex`. The solution cites "all eleven
  adapters" (solution.md:119); the count matches.
- **Warrant (W):** A mandatory `@callback` requires every
  `@behaviour Tau.Provider` module to implement it for the project to
  compile. The eleven-file enumeration is exactly the set that needs
  the implementation.
- **Qualifier (Q):** Holds for the eleven-file set as currently
  enumerated by `grep`. **Narrowed (see falsification):** does NOT
  include `Tau.Providers.Copilot` despite the solution's enumeration
  naming it — no module in `lib/tau/providers/copilot/` carries
  `@behaviour Tau.Provider`; the directory contains only `auth.ex` and
  `token_store.ex` (auth subsystem only). The eleventh adapter is
  Replay, which IS listed.
- **Rebuttal (R):** Does NOT hold if a new `@behaviour Tau.Provider`
  module lands between the solution's authoring and the PR's landing —
  the migration count would be 12, not 11. Mitigated by the migration
  sketch's instruction to run `mix compile --warnings-as-errors` before
  merging (solution.md:120-121) — any missing implementation would
  surface there.
- **Backing (B):** Elixir compiler emits "behaviour callback X is not
  implemented" warning for every missing `@impl`; `mix
  --warnings-as-errors` turns it fatal.

#### Falsification attempt for claim 6

- **Strategy:** Counter-example construction — enumerate the
  `@behaviour Tau.Provider` modules and compare to the solution's
  adapter list.
- **Attempt:** `grep -rln "@behaviour Tau.Provider\b" lib/` returns 11
  modules. Solution lists 11 names. Diff:
  - Solution's "openai_chat_wire consumers" implicitly covers Groq,
    Mistral, DeepSeek, AzureOpenAI, Custom — confirmed by grep.
  - Solution lists `Copilot` — NOT present as a `@behaviour
    Tau.Provider` module. `ls lib/tau/providers/copilot/` shows only
    `auth.ex` (Auth subsystem) and `token_store.ex` (GenServer). No
    `copilot.ex` provider module exists.
  - Solution omits `OpenAI.Chat` and `OpenAI.Responses` from the
    explicit list (they are presumably folded into "openai_chat_wire
    consumers", but Responses uses a different wire).
- **Outcome:** **partially falsified**. The intent (every
  `@behaviour Tau.Provider` module implements the callback) is correct
  and machine-enforced by the compiler. The *enumeration* in the
  solution is sloppy: it lists a non-existent Copilot provider and
  elides `OpenAI.Responses`. The actual implementation set is the
  eleven returned by grep.
- **Action:** Qualifier narrowed in place to "the eleven modules
  returned by `grep -rln '@behaviour Tau.Provider\\b' lib/`": the
  solution's enumeration is informative-only; the compile-warning gate
  is the operative mechanism. No revision triggered because the
  acceptance criterion ("any adapter not conforming is detectable") is
  unaffected — the criterion keys on the *callback*, not on the
  solution's prose enumeration.

### Claim 7: A self-consistency test (`test/tau/provider_stream_contract_test.exs`) makes the declared contract self-falsifying against observed events.

- **Claim (C):** "`test/tau/provider_stream_contract_test.exs` (new file)
  — self-consistency test per adapter: call `stream_contract/0`, run a
  Replay-fixture stream, assert emitted events match the declared
  contract." (solution.md:98-100).
- **Grounds (G):** Proposal-3.md:104-135 sketches the test shape. The
  Replay adapter exists at `lib/tau/providers/replay.ex` and implements
  `@behaviour Tau.Provider` (grep result above). Fixtures for Bedrock
  and Gemini may or may not exist (open question, solution.md:128-133).
- **Warrant (W):** Falsifiability requires an external check that can
  contradict the declaration. A test that drives the real stream and
  pattern-matches `text_framing: :start_delta_end ⇒ ∀ TextDelta:
  preceded by TextStart on the same block_id` (proposal-3.md:126-133)
  is exactly that. It closes the residual from claim 3's rebuttal
  (value-level lies escape Dialyzer).
- **Qualifier (Q):** Holds for adapters with a Replay fixture available.
  Does NOT hold for adapters where the fixture is missing —
  solution.md:129-133 acknowledges this and proposes a `:test_only` /
  `:unknown` sentinel as a degraded mode. In that mode, the test value
  for those adapters is purely the declaration's presence, not its
  fidelity.
- **Rebuttal (R):** Does NOT hold if the Replay fixture itself is
  non-byte-accurate — a fixture sanitised to "look like" the provider's
  output but not produced from real bytes can mask divergence.
- **Backing (B):** proposal-3.md "Prior art" §190-196 cites three
  precedents for the declare-then-verify pattern (Tau's
  `capabilities/0`, SPEC-PROMPT-CACHING `cache_regions/2`, Erlang
  `:gen_statem` callback-mode).

#### Falsification attempt for claim 7

- **Strategy:** Dependency check — verify the Replay-fixture
  infrastructure exists or can be added without a separate epic.
- **Attempt:** Examined `lib/tau/providers/replay.ex` exists (grep
  confirmed). The solution's open question (solution.md:128-133)
  acknowledges the fixture-completeness risk explicitly and proposes a
  `:test_only`/`:unknown` sentinel as a fallback. The proposal
  (proposal-3.md:177-180) calls this a "Dependency" — meaning the
  authors know the test value degrades when fixtures are absent. No
  evidence that the dependency is impossible to satisfy; it is
  acknowledged as work to do.
- **Outcome:** withstood, with the qualifier already present (test
  value depends on fixture availability).
- **Action:** none. The open question survives to PR-authoring time.

### Claim 8: The solution does NOT modify `Tau.Provider.Event`, `Tau.Message.Assembler`, Bedrock/Gemini decode paths, the OpenAI shared wire, the session FSM/render loop, or the `@callback stream/3` signature.

- **Claim (C):** "What does not change" enumeration (solution.md:105-114)
  — six explicit non-modifications, plus claim that the existing
  assembler tolerances "are left in place; removing them is a follow-on
  gated on Proposal 4".
- **Grounds (G):** `lib/tau/message/assembler.ex:133-138` shows
  `update_block/3` silently returning state unchanged when a delta
  arrives for an un-started block (`nil` branch returns state). The
  solution explicitly does not touch this. The "What changes" list
  (solution.md:82-102) modifies only `provider.ex`, a new
  `stream_contract.ex`, eleven adapter modules, and one new test file
  — none of the six "does not change" targets.
- **Warrant (W):** The "What changes" enumeration is mutually
  exhaustive with "What does not change" by construction of the
  solution template; a PR landing only the listed edits satisfies the
  claim by inspection.
- **Qualifier (Q):** Holds for the PR as scoped. If the PR is expanded
  mid-flight (e.g. an adapter author "while I'm here" removes an
  assembler tolerance), the claim is violated and the PR is out-of-scope
  per the factory loop's scope-guard rule.
- **Rebuttal (R):** Does NOT hold if `Tau.Provider.known_adapters/0` is
  added to `provider.ex` as a helper (open question, solution.md:139-142)
  — that IS a change to `provider.ex` beyond the callback. The solution
  mentions it but defers the decision. If added, it does not change
  `stream/3` semantics, so the substantive claim survives.
- **Backing (B):** `.claude/rules/factory-loop.md` §PR scope guards:
  "frozen scope … mid-flight scope growth becomes a separate PR".

#### Falsification attempt for claim 8

- **Strategy:** Edge-case enumeration — list each "does not change"
  target and check whether the listed changes touch it.
- **Attempt:** Iterated the six items: (a) `Tau.Provider.Event` — listed
  changes touch only `provider.ex` and `provider/stream_contract.ex`;
  Event is in `provider/event.ex` — disjoint. (b) `Tau.Message.Assembler`
  — listed changes do not touch `message/assembler.ex` — disjoint.
  (c) Bedrock/Gemini decode paths — listed changes add `stream_contract/0`
  to each adapter, not modifications to `decode_*` clauses — disjoint.
  (d) `openai_chat_wire.ex` — listed changes add `stream_contract/0` to
  the consumer adapters, not to the shared wire — disjoint. (e) Session
  FSM / render loop — listed changes do not touch `session.ex` or any
  TUI module — disjoint. (f) `@callback stream/3` signature — the
  signature at `provider.ex:67-68` is unchanged; only the docstring
  is updated. All six hold.
- **Outcome:** withstood.
- **Action:** none.

## Cross-claim consistency

The eight claims are mutually consistent. The recurring structure is:
declaration layer (claims 1-3) + per-adapter implementations (claims 4-6) +
external check (claim 7) + scope discipline (claim 8). Two potential
tensions resolved:

- **Claim 2 (attribute composes with callback) vs. claim 8 (provider.ex
  scope).** Both apply: the attribute IS in `provider.ex` (a permitted
  change per the "What changes" list); claim 8's "does not change"
  enumeration explicitly excludes the callback signature, not the file.
  No tension.
- **Claim 3 (Dialyzer catches structural divergence) vs. claim 7
  (test catches value-level divergence).** Complementary, not
  conflicting — the two together close the gap that either alone leaves
  open (claim 3 rebuttal explicitly defers value-level checks to claim
  7).

The internal `:replay` vs `:test_only` open question (solution.md:134-138)
is the only unresolved interaction across claims — it affects claim 6
(does Replay get a special declaration?) and claim 7 (does Replay
participate in the self-consistency test?). The solution flags it for
PR-authoring time; both downstream claims tolerate either resolution.

## Falsification summary

| # | Claim (short) | Strategy | Outcome | Action |
|---|---|---|---|---|
| 1 | Callback satisfies "detectable without reading decode path" | Counter-example construction | withstood | none |
| 2 | `@stream_contract` attribute composes with callback | Edge-case enumeration | withstood | none |
| 3 | Dialyzer catches structural callback-return divergence | Type-level check | withstood | none |
| 4 | Anthropic can declare `conformant()` w/o behavioural change | Counter-example construction | withstood | none |
| 5 | Bedrock `:delta_only/:sentinel` + Gemini `:delta_only/:atomic` are honest declarations | Counter-example construction | withstood | none |
| 6 | All remaining adapters add `@impl stream_contract/0` | Counter-example construction | **partially falsified** | qualifier narrowed in place |
| 7 | Self-consistency test makes declaration falsifiable | Dependency check | withstood (qualified by fixture availability) | none |
| 8 | Six "does not change" targets are disjoint from "what changes" | Edge-case enumeration | withstood | none |

## Revision required

No file-level revision is needed. The single partial falsification
(claim 6) is a *prose enumeration* issue: the solution's "Copilot"
mention names a module that does not exist as a `@behaviour
Tau.Provider` implementer, and `OpenAI.Responses` is missing from the
explicit per-adapter list. Neither affects the acceptance criterion or
the operative migration mechanism (the compiler's
behaviour-callback-not-implemented warning, made fatal by `mix compile
--warnings-as-errors`). Qualifier 6 is narrowed in place to "the eleven
modules returned by `grep -rln '@behaviour Tau.Provider\\b' lib/`".

- **Target file:** none — qualifier narrowed in-validation.
- **Revision kind:** n/a
- **Rationale:** Acceptance criterion remains satisfied. The
  implementing PR author will discover the correct adapter set via
  compile warnings regardless of the solution's prose. Calling for a
  full re-run of propose/select on a prose enumeration would over-react
  to a non-substantive defect.

## Outstanding doubts

- **Fixture completeness for Bedrock and Gemini self-consistency tests
  (claim 7's qualifier).** The solution flags this as an open question.
  Until fixtures are confirmed, claim 7's test value for these adapters
  degrades to "the declaration exists and is well-typed" — i.e. claim 1
  + claim 3 territory, not claim 7's runtime falsifiability. A parent-
  level validator inheriting this node's solution should carry this
  doubt forward.
- **Replay adapter's posture (open question solution.md:134-138).**
  The solution defers the choice of `:replay` sentinel vs. re-emitting
  the original adapter's contract. Either is workable for claim 6's
  enforcement; the choice affects only the test's interpretation, not
  the criterion satisfaction.
- **OpenAI shared wire's first-delta `TextStart` synthesis gap
  (open question solution.md:143-145).** When the upstream sends only
  empty deltas, no `TextStart` is synthesised. This is an
  *implementation-side* defect in `openai_chat_wire.ex`, not a
  declaration-layer defect. The solution correctly defers it; a parent-
  level validator should note that the declaration layer landed here
  does not by itself fix it.
- **`known_adapters/0` helper coupling (open question
  solution.md:139-142).** Adding it couples the behaviour module to the
  adapter list. If added, it should be test-only or a module attribute.
  The solution defers the decision; both options preserve all eight
  claims.
