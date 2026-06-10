---
template_version: 1
template_name: solution
parent_problem: ./problem.md
node_kind: root
synthesised_from:
  - subproblems/callback-contract-drift/solution.md
  - subproblems/capabilities-flag-fidelity/solution.md
  - subproblems/usage-normalisation/solution.md
  - subproblems/auth-resolution-scatter/solution.md
selection_method: synthesis
mode: non-leaf
revision: 0
---

# Solution: Make `Tau.Provider` enforce or honestly document every observable adapter divergence

## Recommendation

Land four composable, file-disjoint workstreams that together convert the
`Tau.Provider` contract from a decorative interface into a partial-enforcement /
honest-documentation surface. Each workstream is the recommendation of one
child sub-problem; together they discharge the module-level acceptance
criterion ("a new adapter author cannot silently ship a broken implementation
by following only the `@behaviour` callbacks") via three complementary
mechanisms: (a) **type-level enforcement** — a typed `%Event.Usage{}` struct
replaces `usage: map()`; a mandatory `stream_contract/0` callback returning a
`%Tau.Provider.StreamContract{}` forces each adapter to publish its
text-framing / tool-call-delta posture; (b) **CI-gate enforcement** — a new
`mix tau.gate.capabilities` joins the existing `tau.gate.*` family, asserting
the `prompt_caching` ⇔ `cache_regions/2` biconditional, and a shared
`Tau.Test.ProviderConformance` template iterates every production adapter to
assert the usage-struct invariants on replay fixtures; (c) **shared
scaffolds** — `Tau.Providers.Auth` for the standard `opt → app_env → vault →
system_env` chain, and `Tau.Provider.UsageNorm` for wire-to-struct usage
extraction; (d) **honest documentation** — an ADR for auth, prose `@doc`
upgrades on `capabilities/0`, a `@stream_contract` attribute on
`Tau.Provider`, and the existing flag demotions for Bedrock, Gemini, DeepSeek.
The four workstreams touch disjoint files and ship as four separate PRs that
can largely parallelise under the factory-loop conflict check; the only
serialisation requirement is the usage-normalisation workstream's PR 1
(struct + Anthropic + consumer migration) which must land before PRs 2 and 3
of that workstream.

## Selected from

- **Synthesised from:** child solutions at
  `subproblems/callback-contract-drift/solution.md`,
  `subproblems/capabilities-flag-fidelity/solution.md`,
  `subproblems/usage-normalisation/solution.md`,
  `subproblems/auth-resolution-scatter/solution.md`.

- **Composition rationale:** the four sub-problems were carved on Hickey's
  *concern* axis (callback shape, capability honesty, usage data, auth
  resolution); each is one woven concern named in `problem.md`. Their
  recommendations compose directly — none retracts or constrains another, and
  the file-touch sets are nearly disjoint:

  | Workstream | Touches `lib/tau/provider.ex` | New module(s) | New CI gate / test |
  |---|---|---|---|
  | callback-contract-drift | yes (new `@callback`, `@stream_contract` attr) | `Tau.Provider.StreamContract` | `provider_stream_contract_test.exs` |
  | capabilities-flag-fidelity | yes (`@doc` / `@typedoc` on `capabilities/0`) | `Mix.Tasks.Tau.Gate.Capabilities` | `capabilities_contract_test.exs` + `mix tau.gate.capabilities` (CI) |
  | usage-normalisation | yes (`Event.Usage` struct; `Done.t()` typespec) | `Tau.Provider.Event.Usage`, `Tau.Provider.UsageNorm`, `Tau.Test.ProviderConformance` | per-adapter `*_conformance_test.exs` + `mix tau.conformance` |
  | auth-resolution-scatter | no | `Tau.Providers.Auth`, `ADR-00XX-auth-resolution-policy.md` | `auth_test.exs` + `auth_policy_test.exs` (telemetry) |

  The three workstreams that touch `lib/tau/provider.ex` edit disjoint
  regions (event union, capabilities callback docstring, new stream_contract
  callback), so the file overlap is a sequencing concern handled by the
  factory-loop's freshness re-check (cycle step 8a) — not a content conflict.
  No child's recommendation forces a behaviour-API break for external
  implementors beyond what its own sub-problem makes unavoidable
  (`stream_contract/0` is the one new mandatory callback; the other three
  workstreams add scaffolds, structs, gates, and docs only).

  **Three forms of enforcement compose intentionally.** Type-level
  enforcement (struct shape, mandatory callback) catches the "absent
  implementation" failure mode at compile time. CI-gate enforcement catches
  the "declared but unimplemented" failure mode (`prompt_caching: true`
  without `cache_regions/2`; `stream_contract` declaration not matching
  emitted events). Documentation (`@doc`, ADR, `@stream_contract` attribute)
  closes the residual case where a flag's obligations span too many
  callsites to localise mechanically (`thinking: true`). Each layer covers
  what the previous layer cannot — composition, not redundancy.

## What changes

Grouped by workstream so each maps to one factory-loop PR. File-level
enumeration is per child solution; only the inter-workstream additions are
new at this level.

### Workstream A — auth-resolution-scatter (orthogonal; ships first or in parallel)

- **New** `lib/tau/providers/auth.ex` — shared
  `resolve_api_key/3` / `resolve_api_key_or_error/3`, unconditional
  `Tau.Settings.Vault.resolve/1` call.
- **Modified** `lib/tau/providers/{mistral,deepseek,groq,azure_openai,custom,gemini}.ex`
  — delete private `vault_key/0` helpers; call the shared resolver; Gemini
  gains the missing vault leg.
- **New** `docs/adr/ADR-00XX-auth-resolution-policy.md` — canonical chain
  plus per-adapter exception table (Anthropic OAuth, Bedrock AWS-triple,
  Copilot two-token, Azure non-key fields, Custom `base_url`).
- **New** `test/tau/providers/auth_test.exs` and
  `test/tau/providers/auth_policy_test.exs` — unit + cross-adapter
  telemetry regression.

### Workstream B — usage-normalisation (three sequenced PRs B1 → B2 → B3)

- **B1 — struct + scaffold + Anthropic + consumer migration.**
  - **New** `lib/tau/provider/event.ex` extension —
    `%Tau.Provider.Event.Usage{}` with
    `@enforce_keys [:input_tokens, :output_tokens]`; `Done.usage ::
    Event.Usage.t() | nil`.
  - **New** `lib/tau/provider/usage_norm.ex` — `from_openai/1`,
    `from_gemini/1`, `from_bedrock/1`, `from_anthropic/1`, `zero/0`,
    `nonneg/1`.
  - **Modified** `lib/tau/providers/anthropic.ex` —
    `merge_usage/2` output wrapped via `UsageNorm.from_anthropic/1`.
  - **Modified** `lib/tau/session.ex`, `lib/tau/cost/tracker.ex`, any TUI
    consumer — struct-field access.
- **B2 — wire-extraction for non-Anthropic adapters.**
  - **Modified** `lib/tau/providers/shared/openai_chat_wire.ex` —
    `stream_options.include_usage: true` in `build_body/4`; emit
    `%Event.Done{usage: UsageNorm.from_openai(raw)}`.
  - **Modified** `lib/tau/providers/bedrock.ex` — accumulate
    `message_start` usage; emit on `message_stop`.
  - **Modified** `lib/tau/providers/gemini.ex` — read
    `json["usageMetadata"]`; emit via `UsageNorm.from_gemini(raw)`.
- **B3 — shared conformance harness + missing fixtures.**
  - **New** `test/support/provider_conformance.ex` — shared ExUnit case
    template (asserts last `%Event.Done{}` has `%Event.Usage{}` with
    non-negative integers).
  - **New** `test/tau/providers/{anthropic,openai_chat,openai_responses,
    gemini,bedrock,groq,mistral,deepseek,azure_openai,custom,copilot}_conformance_test.exs`.
  - **New/extended** `priv/fixtures/*.jsonl` for adapters lacking
    usage-bearing fixtures.
  - **New** `mix tau.conformance` Mix task as a fast targeted gate.
- **Amendment** to `docs/spec/SPEC-PROMPT-CACHING.md` §4 B3 — names
  `%Event.Usage{}` as canonical carrier and `Tau.Provider.UsageNorm` as
  shared adapter-side scaffold; D-065 wording updated to match. This SPEC
  amendment ships with B1 (the struct's home PR).

### Workstream C — capabilities-flag-fidelity (single PR)

- **Modified** `lib/tau/provider.ex` — prose `@doc` / `@typedoc` on
  `@callback capabilities/0` (per-flag truthfulness semantics; names
  `prompt_caching` as the only mechanically enforceable flag; names the
  CI gate).
- **Modified** `lib/tau/providers/bedrock.ex`, `lib/tau/providers/gemini.ex`,
  `lib/tau/providers/deepseek.ex` — demote `prompt_caching: true → false`;
  Bedrock + Gemini also demote `thinking: true → false` (DeepSeek's
  thinking flag is backed by `OpenAIChatWire` reasoning synthesis and
  stays).
- **New** `lib/mix/tasks/tau.gate.capabilities.ex` (~60 LOC) — CI gate
  modelled on `tau.gate.ac_linkage` / `tau.gate.masking` /
  `tau.gate.mutation`; asserts
  `capabilities().prompt_caching == true ⇔ function_exported?(mod, :cache_regions, 2)`.
- **Modified** `.github/workflows/ci.yml` — add `mix tau.gate.capabilities`
  to the existing `lint` job.
- **New** `test/tau/provider/capabilities_contract_test.exs` (~40 LOC) —
  parameterised ExUnit mirror of the gate task for developer-local feedback.

### Workstream D — callback-contract-drift (single PR)

- **New** `lib/tau/provider/stream_contract.ex` —
  `%Tau.Provider.StreamContract{text_framing, tool_call_delta,
  block_id_uniqueness, thinking_framing}`; `conformant/0` constructor.
- **Modified** `lib/tau/provider.ex` — add `@callback stream_contract/0`
  (mandatory); add `@stream_contract` module attribute (prose canonical
  sequence); update `@callback stream/3` docstring to reference both.
- **Modified** every adapter (`anthropic, bedrock, gemini, openai_chat,
  openai_responses, groq, mistral, deepseek, azure_openai, custom,
  copilot, replay`) — implement `@impl Tau.Provider stream_contract/0`
  returning a `%StreamContract{}` that matches its actual posture
  (conformant adapters use `StreamContract.conformant()`; Bedrock and
  Gemini declare `:delta_only` / `:sentinel` etc).
- **New** `test/tau/provider_stream_contract_test.exs` —
  self-consistency test: for each adapter, run a Replay-fixture stream
  and assert emitted events match the declared contract.

### Cross-workstream additions

- **Documentation** — `docs/PROVIDER-CONTRACT.md` (or amendment to an
  existing provider doc) lists the four enforcement mechanisms
  (`stream_contract/0`, `%Event.Usage{}`, `mix tau.gate.capabilities`,
  `Tau.Providers.Auth`) and points at each workstream's spec / ADR /
  test entrypoint. This consolidates what is otherwise four scattered
  artifacts into one operator-readable index.

## What does not change

- The `Tau.Provider` callback list **except** for the single new
  `stream_contract/0` (Workstream D). `configure/1` stays optional and
  unused; `cache_regions/2` stays optional; `context_window/1` stays
  optional.
- `Tau.Provider.Event` event types other than `%Event.Done{}`'s `usage`
  typespec — no new event variants, no changes to `TextStart/End`,
  `ToolCallStart/Delta/End`, `ThinkingStart/Delta/End`, `Error`.
- Live decode paths for Bedrock and Gemini (other than the usage
  extraction in B2) — they continue to omit `TextStart/End` framing;
  the `stream_contract/0` declaration makes the gap visible but does
  not fix it. (Fixing the live paths is deferred to a future
  sub-problem per the callback-contract-drift child's open questions.)
- `Tau.Message.Assembler` tolerances — left in place; tightening is
  gated on the decode-path fixes.
- `Tau.Providers.Anthropic.Auth` (OAuth-capable), `Tau.Providers.Bedrock`
  AWS-credential resolution, and `Tau.Providers.Copilot.Auth` two-token
  model — these remain bespoke per the auth-resolution-scatter ADR's
  exception table.
- Out-of-scope items from `problem.md`: transport layer (FinchStream,
  AwsEventStream, SSE parsing), rate limiting
  (`Tau.Providers.RateLimiter`), tool-spec shape
  (`Tau.Providers.Shared.ToolSpec`), Replay provider's test-harness
  contract, performance / throughput.

## Migration sketch

Four workstreams, four (or six with B2/B3) PRs. The factory-loop conflict
check (rule `.claude/rules/factory-loop.md` §"Parallel execution") is the
arbiter for scheduling. Sequence:

1. **PR-A (Workstream A — auth-resolution-scatter).** Fully orthogonal:
   touches `lib/tau/providers/*.ex` (not `lib/tau/provider.ex`), adds a new
   shared module, an ADR, and two test files. Can run in parallel with any
   other workstream. Reversibility: easy (delete `Tau.Providers.Auth`;
   restore private `vault_key/0` from VCS).
2. **PR-B1 (Workstream B PR 1 — struct + scaffold + Anthropic + consumers).**
   Lands `%Event.Usage{}`, `Tau.Provider.UsageNorm`, Anthropic migration,
   and the SPEC-PROMPT-CACHING §4 B3 amendment. **Must precede** PR-B2 and
   PR-B3 (struct must exist before adapters can emit it; conformance tests
   must follow wire-extraction so they go green on landing). Behaviour-
   preserving for Anthropic (it already emitted real counts); behaviour-
   improving for consumers (typed access).
3. **PR-C (Workstream C — capabilities-flag-fidelity).** Independent of B
   and D content-wise (touches `@doc` / `@typedoc` on `capabilities/0`,
   not the event union or the new callback), but touches the same file
   `lib/tau/provider.ex`. Under the factory-loop's freshness re-check,
   this means if PR-C lands between PR-B1's gate and merge, PR-B1 must
   rebase and re-gate. Schedule PR-C either before PR-B1 or after PR-B3
   to avoid serialising B's three PRs through C's rebase.
4. **PR-D (Workstream D — callback-contract-drift).** Adds the mandatory
   `stream_contract/0` callback. This is the only workstream that breaks
   `@behaviour Tau.Provider` for external implementors (out-of-scope per
   the project; all current implementors are in-tree). Same
   `lib/tau/provider.ex` overlap concern as PR-C. Schedule after PR-B1
   has landed to minimise the rebase blast radius on B's later PRs.
5. **PR-B2 (Workstream B PR 2 — wire-extraction).** Modifies
   `openai_chat_wire.ex`, `bedrock.ex`, `gemini.ex`. Each adapter's
   conformance test (introduced in PR-B3) goes from red to green when
   wire-extraction lands; the test is the forcing function. File-disjoint
   from PR-A, PR-C, PR-D — can parallelise freely.
6. **PR-B3 (Workstream B PR 3 — conformance harness + missing fixtures).**
   Lands `Tau.Test.ProviderConformance`, per-adapter conformance test
   files for the eleven production adapters, the `mix tau.conformance`
   task, and any missing fixtures. File-disjoint from every other
   workstream's source files; conflicts only with itself.

**Recommended order under the factory-loop conflict check:**
PR-A and PR-B1 in parallel (fully disjoint files);
then PR-C (after PR-B1 to claim the `lib/tau/provider.ex` edit window);
then PR-D (after PR-C, same file-overlap reason);
then PR-B2 and PR-B3 in parallel (file-disjoint from A/C/D and from each
other except for the fixture directory).

**Reversibility** is per-workstream:
- A: easy (delete shared module).
- B: B3 → B2 → B1 reverse order; struct revert requires consumer-access
  revert.
- C: trivial (revert demotions; delete gate task; remove CI line).
- D: easy at struct level (delete `stream_contract.ex`); harder if any
  external implementor has already implemented the callback (out of
  scope today).

## Combined acceptance criteria

The module-level acceptance criterion (`problem.md`) decomposes into four
sub-AC sets, one per workstream. **All four AC sets MUST PASS for the
module-level criterion to be satisfied.** Each set is taken verbatim from
the relevant child solution; identifiers prefixed by workstream letter.

### AC-A (auth-resolution-scatter)

- AC-A1: `Tau.Providers.Auth.resolve_api_key/3` exists and follows
  `opt → app_env → vault → system_env`.
- AC-A2: Every adapter in {Mistral, DeepSeek, Groq, AzureOpenAI, Custom,
  Gemini} has its private `vault_key/0` deleted and routes credential
  resolution through `Tau.Providers.Auth`.
- AC-A3: `docs/adr/ADR-00XX-auth-resolution-policy.md` documents the chain
  and the per-adapter exception table.
- AC-A4: `test/tau/providers/auth_policy_test.exs` asserts every adapter
  in the standard list emits `[:tau, :vault, :get]` telemetry during
  credential resolution.

### AC-B (usage-normalisation)

- AC-B1: `%Tau.Provider.Event.Usage{}` struct exists with
  `@enforce_keys [:input_tokens, :output_tokens]`; `Done.usage`
  typespec updated.
- AC-B2: `Tau.Provider.UsageNorm` exists with `from_openai/1`,
  `from_gemini/1`, `from_bedrock/1`, `from_anthropic/1` returning
  `%Event.Usage{}`.
- AC-B3: Every production adapter emits a non-nil `%Event.Usage{}` on
  `%Event.Done{}`, verified by the per-adapter conformance test.
- AC-B4: `Tau.Test.ProviderConformance` template exists; one
  `*_conformance_test.exs` per production adapter passes.
- AC-B5: SPEC-PROMPT-CACHING §4 B3 amended to name `%Event.Usage{}`
  as canonical carrier and `UsageNorm` as the shared scaffold; D-065
  wording matches.

### AC-C (capabilities-flag-fidelity)

- AC-C1: `mix tau.gate.capabilities` exists, returns exit 0 on
  current `main`, and is wired into `.github/workflows/ci.yml`'s
  `lint` job as a blocking check.
- AC-C2: `Tau.Providers.Bedrock`, `Tau.Providers.Gemini`,
  `Tau.Providers.DeepSeek` declare `prompt_caching: false`; Bedrock
  and Gemini also declare `thinking: false`.
- AC-C3: `Tau.Provider.capabilities/0` `@doc` and `@typedoc` name
  `prompt_caching` as the only mechanically enforceable flag and name
  the gate.
- AC-C4 (meta): `test/tau/provider/capabilities_contract_test.exs`
  exists and asserts the biconditional at the unit-test level.

### AC-D (callback-contract-drift)

- AC-D1: `Tau.Provider.StreamContract` struct exists with the four
  declared fields.
- AC-D2: `@callback stream_contract/0` is declared on `Tau.Provider`
  (mandatory, not optional).
- AC-D3: Every adapter implements `@impl Tau.Provider stream_contract/0`
  returning a `%StreamContract{}` matching its actual posture.
- AC-D4: `test/tau/provider_stream_contract_test.exs` exists and the
  self-consistency assertion (declared posture matches Replay-fixture
  output) passes for every adapter.
- AC-D5: `Tau.Provider.@stream_contract` module attribute exists
  carrying the canonical sequence prose.

### Module-level AC (synthesis)

- AC-M1: A new adapter author following the `@behaviour Tau.Provider`
  callbacks (including the new mandatory `stream_contract/0`) cannot
  pass `mix compile --warnings-as-errors`, `mix test`, AND
  `mix tau.gate.capabilities` without (a) declaring a usage struct
  that conforms to `Event.Usage` shape, (b) declaring a stream
  contract that matches their emitted events, (c) declaring
  `prompt_caching: true` only if they implement `cache_regions/2`, and
  (d) routing standard API-key resolution through `Tau.Providers.Auth`
  (or having an ADR exception row). This is the operational form of
  the module-level criterion in `problem.md`; an integration test
  scaffolding a stub adapter and asserting each gate fires verifies it.

## Open questions

- **Live decode-path remediation for Bedrock and Gemini.** The
  callback-contract-drift solution declares non-conformance via
  `stream_contract/0` but explicitly defers fixing the decode paths
  (no `TextStart/End` synthesis, no ToolCallDelta streaming). The
  declaration layer makes the gap visible; eliminating it is a
  separate sub-problem. Should a follow-up issue be filed before this
  module-level solution ships, or after the gate-passing baseline is
  in place?
- **Replay adapter posture under `stream_contract/0`.** The Replay
  adapter is intentionally divergent (test-harness contract is out of
  scope per `problem.md`); should it declare a special `:replay`
  variant or re-emit the original adapter's contract? Decision needed
  before PR-D can compile.
- **`thinking` flag enforcement.** No equivalent biconditional pattern
  exists for `thinking: true` because obligations span `build_body/3`
  and the decode path. Whether a future enforcement layer (e.g.
  `thinking_config/1` callback) should target it is a follow-up
  sub-problem; the current solution leaves it advisory-by-doc and
  demotes the two lying adapters.
- **`Event.Usage.from_replay/1` deserialiser.** The Replay decoder
  materialises raw maps from JSONL; reconstructing `%Event.Usage{}` on
  fixture replay needs a small adapter. Scope into PR-B2 or PR-B3.
- **`configure/1` dead-callback cleanup.** The auth-resolution-scatter
  solution explicitly defers this (would force breaking changes on every
  external implementor). Whether to file a follow-up issue now or wait
  for a concrete need is undecided.
- **Future adapters added via extensions** (per SPEC-EXTENSIONS Stage B).
  The `mix tau.gate.capabilities` task iterates `Tau.Providers.*`; whether
  it should also iterate loaded extension modules is a Stage B question.
- **SPEC home for `stream_contract/0`.** Is the new callback a
  SPEC-PROMPT-CACHING amendment, a new `SPEC-PROVIDER-CONTRACT`, or an
  ADR? The callback-contract-drift child does not specify; the
  cross-workstream `docs/PROVIDER-CONTRACT.md` index proposed above is a
  candidate home but is not a SPEC under `.claude/rules/spec-before-code.md`.
- **PR-D scope vs `spec-before-code.md`.** Adding a mandatory `@callback`
  to a multi-implementor behaviour may trigger the spec-before-code rule
  (the `Tau.Provider` behaviour itself is coordination-heavy by virtue of
  having eleven implementations). Confirm before PR-D that no existing
  SPEC owns this surface; if not, a small spec or ADR may need to land
  with PR-D.

## Linked sub-problems / proposals

- `subproblems/auth-resolution-scatter/` → "Extract `Tau.Providers.Auth`
  shared resolver, migrate standard adapters, add ADR + telemetry
  regression test; leave `configure/1` alone."
- `subproblems/callback-contract-drift/` → "Add mandatory
  `stream_contract/0` callback backed by `%Tau.Provider.StreamContract{}`
  struct + `@stream_contract` prose attribute; declare non-conformance
  for Bedrock/Gemini rather than fixing decode paths in this scope."
- `subproblems/capabilities-flag-fidelity/` → "Honest flag demotions for
  Bedrock/Gemini/DeepSeek + `mix tau.gate.capabilities` CI gate enforcing
  the `prompt_caching ⇔ cache_regions/2` biconditional + prose `@doc`
  contract; leave `thinking` advisory-by-doc."
- `subproblems/usage-normalisation/` → "Typed `%Event.Usage{}` struct
  replacing `usage: map()` + shared `Tau.Provider.UsageNorm` wire-extraction
  scaffold + per-adapter conformance test template; staged across three
  PRs (struct → wire-extraction → conformance harness)."

## Revision history

- (revision 0 — initial)
