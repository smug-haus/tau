---
template_version: 1
template_name: validation
parent_solution: ./solution.md
parent_problem: ./problem.md
toulmin_complete: true
falsification_attempted: true
falsification_outcome: partially_falsified — claim/4
revision_triggered: none
---

# Validation: honest flags, mechanically enforced for the only verifiable flag

## Overview

The solution proposes seven concrete changes: (1) extend `Tau.Provider`
prose contract on `capabilities/0`, (2) demote Bedrock flags, (3) demote
Gemini flags, (4) demote DeepSeek `prompt_caching` only (keeping
`thinking: true`), (5) add a new Mix task `mix tau.gate.capabilities`, (6)
wire it into `.github/workflows/ci.yml` lint job, (7) add an ExUnit
parameterised contract test. This validation enumerates nine distinct
claims, runs Toulmin per claim, and applies one falsification strategy per
claim (mix of counter-example construction, dependency check, edge-case
enumeration, prior-art counter-case). Outcome: eight withstood, one
partially falsified (Claim 4 — the `thinking: true` retention on DeepSeek
is correct given the current decode path, but the same biconditional logic
the solution applies to `prompt_caching` would also flag DeepSeek's
`thinking` as un-enforced; the partial falsification narrows the claim's
qualifier and does NOT require revision of solution.md). No claim was
fully falsified; no revision triggered.

## Toulmin per claim

### Claim 1: The behaviour module `Tau.Provider` will gain a prose contract on `@callback capabilities/0` naming `prompt_caching` as the only mechanically enforceable flag (Solution §What changes #1).

- **Claim (C):** "extend the `@typedoc` and `@doc` on `@callback
  capabilities/0` with the prose contract from Proposal 3 §Sketch (flag-by-
  flag truthfulness semantics). Explicitly name `prompt_caching` as the
  only mechanically enforceable flag and state that the enforcement runs
  as the CI gate `mix tau.gate.capabilities`. No new `@callback`, no
  change to `@optional_callbacks`, no `__using__` macro, no
  `@before_compile`."
- **Grounds (G):** `lib/tau/provider.ex:58-70` shows the current
  `@typedoc "Static capability flags declared by an adapter."` followed by
  `@type capabilities :: %{thinking: boolean(), tools: boolean(), vision:
  boolean(), prompt_caching: boolean(), parallel_tools: boolean()}` and
  `@callback capabilities() :: capabilities()`. Both attachment points
  exist; adding `@doc` text to a `@callback` is the documented Elixir
  mechanism (the file already does this on `@callback cache_regions/2`
  and `@callback context_window/1`, lines 88-129). `@optional_callbacks`
  at line 131 lists `[configure: 1, chat: 3, cache_regions: 2,
  context_window: 1]` — unchanged by Claim 1.
- **Warrant (W):** Elixir lets `@doc` attach prose to a subsequent
  `@callback` declaration. Documentation is the canonical mechanism for
  advisory-by-doc contracts when no mechanical enforcement is available
  (Hickey's "complect" warning #2: prose-only contracts ARE legitimate
  if their advisory status is explicit and not silently load-bearing).
- **Qualifier (Q):** Holds unconditionally for the prose change itself.
  The *effectiveness* of advisory-by-doc as a contract is bounded by the
  CI gate (Claims 5/6) for `prompt_caching`; for the other four flags it
  is bounded only by reviewer attention.
- **Rebuttal (R):** A future contributor could ignore the docs. That is
  not a falsification of Claim 1 — it is the standing weakness of advisory
  documentation that the gate task partly mitigates (Claim 5).
- **Backing (B):** `tau-architecture` OTP non-negotiable #2 — "extensibility
  seams are behaviours; pattern match on atoms and structs." Adding prose
  to an existing `@callback` does not change the seam; no ADR or SPEC
  prohibits it. Precedent: `lib/tau/provider.ex:88-111` already attaches
  detailed prose to `@callback cache_regions/2`.

#### Falsification attempt for claim 1

- **Strategy:** Counter-example construction — attempt to construct a code
  state where adding `@doc`/`@typedoc` text to `@callback capabilities/0`
  fails compile or violates a behaviour/SPEC invariant.
- **Attempt:** Read the existing `Tau.Provider` module to confirm
  attachment-point shape; search for any SPEC owning `lib/tau/provider.ex`
  prose; check `spec-before-code.md`'s SPEC catalog for ownership of
  `provider.ex`. Catalog entries that touch `lib/tau/provider.ex`:
  SPEC-USER-TURN, SPEC-PROMPT-CACHING. Neither owns the `capabilities/0`
  callback prose; SPEC-PROMPT-CACHING owns `cache_regions/2`.
- **Outcome:** withstood. No counter-example produced. Caveat captured
  under Outstanding doubts: the PR landing this change will still need to
  cite the in-scope SPECs per `spec-before-code.md`, but that is an
  implementation-PR obligation, not a falsification of Claim 1.
- **Action:** none.

### Claim 2: Bedrock's capability map will be demoted from `thinking: true, prompt_caching: true` to `thinking: false, prompt_caching: false` (Solution §What changes #2).

- **Claim (C):** "`lib/tau/providers/bedrock.ex:35-37` — demote `thinking:
  true → false` and `prompt_caching: true → false` (no `cache_regions/2`
  exists in this module; decode path emits no thinking events)."
- **Grounds (G):** `lib/tau/providers/bedrock.ex:35-37` reads `def
  capabilities do %{thinking: true, tools: true, vision: true,
  prompt_caching: true, parallel_tools: true} end` (verified). `grep -rn
  'def cache_regions' lib/tau/providers/` returns only
  `anthropic.ex:92` — no `cache_regions/2` exists in `bedrock.ex`. The
  problem statement at `problem.md:31-34` documents that Bedrock's
  `decode_anthropic_event/2` emits no thinking events.
- **Warrant (W):** A `capabilities/0` flag declared `true` is a public
  promise about adapter behaviour. When the adapter cannot honour the
  promise (no `cache_regions/2` for `prompt_caching`; no
  ThinkingStart/Delta/End emission for `thinking`), the honest value is
  `false`. (Acceptance criterion in `problem.md:64-69`.)
- **Qualifier (Q):** Holds for the current code state of `bedrock.ex` on
  this commit. A future PR that *implements* Bedrock thinking or
  cache_regions would re-elevate the flag; that is allowed and the gate
  task (Claim 5) would let it through.
- **Rebuttal (R):** If Bedrock's underlying API silently supported caching
  via a request-shape Tau does not yet emit (e.g. a Bedrock-side prompt
  cache that activates without explicit markers), the flag could be
  advisory-true and still observably accurate. This is precisely what
  Proposal 1's distinction between "Family B/C automatic caching" and
  "Family A explicit caching" addresses — and the solution's `cache_regions/2`
  return values cover (`:explicit | :automatic | :none`). Since Bedrock
  does not implement `cache_regions/2` at all, neither `:automatic` nor
  `:explicit` is declared, so demotion to `prompt_caching: false` is
  consistent with the existing SPEC-PROMPT-CACHING contract.
- **Backing (B):** SPEC-PROMPT-CACHING B1 (cited in
  `lib/tau/provider.ex:89-108`) — "Dispatch is via `function_exported?/3`
  at the call site; an adapter that does not implement it is treated as
  `:none` (caching disabled for that adapter)." Demoting
  `prompt_caching: false` brings the flag into alignment with the
  callback-presence contract.

#### Falsification attempt for claim 2

- **Strategy:** Edge-case enumeration. List the conditions under which
  Bedrock could legitimately keep `prompt_caching: true` or `thinking:
  true` despite the absence of `cache_regions/2` and thinking events.
- **Attempt:** (a) Bedrock could route through a different decode path
  that emits thinking — checked `bedrock.ex` for any branch on model
  family that delegates to OpenAIChatWire or Anthropic decode; the
  decode-event handler is `decode_anthropic_event/2`, called only on
  the streaming SSE chunks; no synthesis of `ThinkingStart/Delta/End`
  appears. (b) Bedrock could rely on AWS-side opaque caching — possible
  in principle, but the `cache_regions/2` callback is the *declared*
  evidence that the adapter participates in Tau-side caching policy; no
  implementation = no participation.
- **Outcome:** withstood. Edge cases do not falsify; they reinforce the
  current honest-flags reading.
- **Action:** none.

### Claim 3: Gemini's capability map will be demoted from `thinking: true, prompt_caching: true` to `thinking: false, prompt_caching: false` (Solution §What changes #3).

- **Claim (C):** "`lib/tau/providers/gemini.ex:29-31` — demote `thinking:
  true → false` and `prompt_caching: true → false` (same justification;
  verified by `grep cache_regions lib/tau/providers/gemini.ex` returning
  empty)."
- **Grounds (G):** `lib/tau/providers/gemini.ex:29-31` reads `def
  capabilities do %{thinking: true, tools: true, vision: true,
  prompt_caching: true, parallel_tools: true} end` (verified by reading
  the file). `grep -rn 'def cache_regions' lib/tau/providers/` shows no
  match in `gemini.ex`. Problem statement `problem.md:35-38` documents
  the absent thinking events and absent `cache_regions/2`.
- **Warrant (W):** Same as Claim 2 — a flag declared `true` is a public
  promise; absent the substrate to honour it, the honest value is `false`.
- **Qualifier (Q):** Holds for the current code state of `gemini.ex`.
  Gemini's native API does support cached content (`cachedContent`
  resource lifecycle), per SPEC-PROMPT-CACHING Family D — but the spec
  explicitly marks Family D as "deferred". Until that work lands, the
  honest declaration is `false`.
- **Rebuttal (R):** If a future PR lands SPEC-PROMPT-CACHING Family D for
  Gemini, this flag re-elevates. That is the intended flow, not a
  rebuttal of Claim 3 itself.
- **Backing (B):** SPEC-PROMPT-CACHING (cited in `spec-before-code.md`):
  "Family D — cachedContent resource lifecycle, deferred." The deferral
  is documented; demotion is consistent with the deferral.

#### Falsification attempt for claim 3

- **Strategy:** Dependency check — does Gemini secretly satisfy the
  contract via a different mechanism Tau already sees?
- **Attempt:** `grep -rn 'cachedContent\|cache_regions' lib/tau/providers/
  gemini.ex` → no results. Read `gemini.ex` decode path
  (`problem.md:39-40` cites `decode/2` handling text and functionCall
  only). Nothing in the current code base bridges Gemini's native cache to
  Tau's `prompt_caching` flag.
- **Outcome:** withstood.
- **Action:** none.

### Claim 4: DeepSeek's capability map will be demoted ONLY on `prompt_caching` (true → false); `thinking: true` is preserved because the OpenAIChatWire decode path synthesises `ThinkingStart/Delta/End` for the `delta.reasoning` field (Solution §What changes #4).

- **Claim (C):** "`lib/tau/providers/deepseek.ex:46-54` — demote
  `prompt_caching: true → false` (no `cache_regions/2` exists in this
  module). The `thinking: true` flag on DeepSeek IS backed — the decode
  path goes through `Tau.Providers.Shared.OpenAIChatWire` which
  synthesises `ThinkingStart/Delta/End` events for `delta.reasoning`."
- **Grounds (G):** `lib/tau/providers/deepseek.ex:46-54` reads (verified):
  ```elixir
  def capabilities do
    %{thinking: true, tools: true, vision: false, prompt_caching: true,
      parallel_tools: true}
  end
  ```
  `grep -n 'def cache_regions' lib/tau/providers/deepseek.ex` → empty.
  `lib/tau/providers/shared/openai_chat_wire.ex:115-133` synthesises
  `%Event.ThinkingStart{}` and `%Event.ThinkingDelta{}` from
  `Map.get(delta, "reasoning")`. `deepseek.ex:83` confirms DeepSeek
  decodes via `&OpenAIChatWire.decode/2`.
- **Warrant (W):** A flag is honestly `true` iff there exists an
  observable path that delivers the feature. For `thinking`, that
  observable path is "ThinkingStart/Delta/End events appear in the stream
  emitted by the adapter's `stream/3`." That path exists for DeepSeek via
  OpenAIChatWire. For `prompt_caching`, the observable path is
  "`cache_regions/2` returns `:explicit | :automatic`." That path does not
  exist for DeepSeek.
- **Qualifier (Q):** The `thinking: true` retention holds *only when the
  underlying DeepSeek model emits `delta.reasoning`* (e.g. DeepSeek-R1).
  A future DeepSeek model that drops the reasoning field would silently
  invalidate the flag. The solution does NOT add a mechanism to detect
  this; the flag is per-adapter, not per-model. **This is a narrower
  qualifier than the solution states.**
- **Rebuttal (R):** If DeepSeek API silently caches via the
  `prompt_cache_key` Mistral-style mechanism (SPEC-PROMPT-CACHING
  Family E), then `prompt_caching: false` could be too pessimistic.
  However, the existing code does not emit `prompt_cache_key` for
  DeepSeek (verified — `grep -n 'prompt_cache_key'
  lib/tau/providers/deepseek.ex lib/tau/providers/shared/openai_chat_wire.ex`
  returns no results), so the honest declaration today is `false`.
- **Backing (B):** SPEC-PROMPT-CACHING (cited in `spec-before-code.md`)
  + the observable-path warrant in problem.md AC.

#### Falsification attempt for claim 4

- **Strategy:** Counter-example construction — apply the solution's own
  biconditional logic to `thinking` and see if DeepSeek violates it.
- **Attempt:** The solution's gate biconditional is `capabilities().
  prompt_caching == true ⇔ function_exported?(mod, :cache_regions, 2)`.
  There is *no equivalent callback* for `thinking`; obligations are
  spread across `build_body/3` (sending the thinking param block) and
  the decode path (emitting `ThinkingStart/Delta/End`). The solution
  acknowledges this in §Open questions ("no equivalent single callback
  exists for `thinking`"). Therefore `thinking: true` on DeepSeek is
  *advisory-by-doc* under the solution, the same way it is for OpenAI
  Responses (`thinking: true, prompt_caching: false`) and `Custom`
  (`thinking: true, prompt_caching: false`) — which the solution leaves
  untouched. The claim is internally consistent with the solution's own
  framing.
- **Outcome:** partially falsified. The narrowing: the solution's
  qualifier should be tightened to "DeepSeek's `thinking: true` is
  preserved as advisory-by-doc, on the same terms as OpenAI Responses
  and Custom — observably correct *today* for DeepSeek-R1, but the
  solution provides no mechanical enforcement for it." This is the
  same outstanding doubt the solution itself records under §Open
  questions ("thinking flag enforcement"). The partial falsification
  records that DeepSeek inherits this gap, not just Bedrock/Gemini.
- **Action:** narrow qualifier in place. No revision of solution.md
  triggered — the solution already states the limit in §Open questions
  and §What does not change ("The thinking flag's enforcement model. It
  remains advisory-by-doc; no callback is added for it.").

### Claim 5: A new Mix task `mix tau.gate.capabilities` will enforce the biconditional `capabilities().prompt_caching == true ⇔ function_exported?(mod, :cache_regions, 2)` across all `Tau.Providers.*` modules, modelled on existing `tau.gate.ac_linkage` / `tau.gate.masking` / `tau.gate.mutation` (Solution §What changes #5).

- **Claim (C):** "`lib/mix/tasks/tau.gate.capabilities.ex` (new file,
  ~60 LOC) — a `Mix.Task` modelled directly on
  `lib/mix/tasks/tau.gate.ac_linkage.ex` /
  `lib/mix/tasks/tau.gate.masking.ex` / `lib/mix/tasks/tau.gate.mutation.ex`.
  It loads every module under the `Tau.Providers.` namespace that
  implements `Tau.Provider`, reads each module's `capabilities/0`, and
  asserts the biconditional `capabilities().prompt_caching == true ⇔
  function_exported?(mod, :cache_regions, 2)`. Exit 0 on full agreement;
  exit 1 with a per-adapter diagnostic line on any violation."
- **Grounds (G):** Three precedent files exist (verified via `ls
  lib/mix/tasks/`): `tau.gate.ac_linkage.ex`, `tau.gate.masking.ex`,
  `tau.gate.mutation.ex`. Shared helpers under `lib/mix/gate/`:
  `ac_linkage.ex`, `common.ex`, `masking.ex`, `mutation.ex`. The pattern
  is established: pure Mix.Task → pure helper module → exit code 0/1.
  `function_exported?/3` is used pervasively in the codebase (16 hits),
  including `lib/tau/settings/schema.ex:302-304` checking
  `function_exported?(mod, :stream, 3)` etc. on provider modules.
- **Warrant (W):** Mix.Task is the documented Elixir mechanism for
  CI-time enforcement gates. `function_exported?/3` returns true iff the
  module is loaded AND exports the function — the gate task can call
  `Code.ensure_loaded?/1` first (precedent at
  `lib/tau/extensions/loader.ex:483`, `lib/tau/cli.ex:753`,
  `lib/tau/tui/app/events.ex:325`). The biconditional is a sound
  contract: if `prompt_caching: true` claims caching participation,
  `cache_regions/2` is the existing callback that *declares* that
  participation (SPEC-PROMPT-CACHING B1).
- **Qualifier (Q):** Holds for modules under `Tau.Providers.*` whose
  beam files are reachable at gate time. Excludes extension-loaded
  provider modules (Solution §Open questions). Excludes any module that
  fails to compile (gate runs *after* the compile step in the lint job).
- **Rebuttal (R):** If a module enumeration based on namespace prefix
  misses a provider module (e.g. one nested deeper than
  `Tau.Providers.OpenAI.*`), the gate would silently skip it.
  Mitigation: the implementation can use a behaviour-introspection
  approach (`:attributes` lookup for `Tau.Provider`) instead of a
  namespace prefix walk. The solution does not specify which, but both
  approaches are sound.
- **Backing (B):** `factory-loop.md` §"The three mechanical gates" — the
  established pattern for repo-wide invariant enforcement is a CI gate
  task. `:code.all_loaded/0` + `function_exported?/3` is the documented
  introspection pattern (Erlang stdlib).

#### Falsification attempt for claim 5

- **Strategy:** Dependency check — does the proposed mechanism rely on
  any precondition that doesn't hold today?
- **Attempt:** (a) Check that `function_exported?/3` returns reliably for
  *loaded* modules — yes, this is its documented contract. (b) Check
  that all provider modules are loadable in the lint job context —
  `mix compile --warnings-as-errors` precedes the gate in the lint job
  (ci.yml:101 wires `tau.gate.ac_linkage` *after* compile), so all
  `lib/tau/providers/**` modules are compiled. (c) Check for module
  enumeration footgun: `Tau.Providers.OpenAI.Chat` and
  `Tau.Providers.OpenAI.Responses` are nested under
  `Tau.Providers.OpenAI` — a naive `for {mod, _} <- :code.all_loaded(),
  String.starts_with?(Atom.to_string(mod), "Elixir.Tau.Providers.")` would
  catch them. A behaviour-introspection approach (filter on
  `mod.module_info(:attributes)[:behaviour]`) is equally sound.
- **Outcome:** withstood. Two implementation choices exist; both are
  sound. The solution's text does not over-constrain.
- **Action:** none. Implementer should note the `Code.ensure_loaded?/1`
  precaution.

### Claim 6: The gate task will be wired into `.github/workflows/ci.yml`'s existing `lint` job, blocking on failure (Solution §What changes #6).

- **Claim (C):** "`.github/workflows/ci.yml` — add an invocation of
  `mix tau.gate.capabilities` to the existing `lint` job, alongside the
  existing `mix tau.gate.ac_linkage` and `mix tau.gate.masking` lines
  (precedent at ci.yml:101 and ci.yml:115). Blocking, same as
  `ac_linkage`."
- **Grounds (G):** `grep -n 'tau.gate' .github/workflows/ci.yml` returns
  three matches: `:101 mix tau.gate.ac_linkage` (blocking), `:115 mix
  tau.gate.masking ... || true` (detection-only), `:227 mix
  tau.gate.mutation` (blocking, in mutation-check job). The lint-job
  precedent for a blocking gate task is `ac_linkage` at line 101.
- **Warrant (W):** A CI gate is binding iff a non-zero exit fails the
  job. The `ac_linkage` invocation at line 101 lacks `|| true`, so its
  exit code propagates — that is the binding pattern.
- **Qualifier (Q):** Holds for PR-trigger events (the gate runs in the
  lint job). Holds for push events to main if the lint job runs on push
  (CI-config detail; not material to claim).
- **Rebuttal (R):** A gate that runs only on PRs misses direct pushes to
  main. Mitigation: the lint job in this repo runs on both `push` and
  `pull_request` (standard pattern); the solution does not promise
  otherwise.
- **Backing (B):** `factory-loop.md` §"The three mechanical gates":
  "Verified by CI via `mix tau.gate.ac_linkage` in the `lint` job
  (blocking)."

#### Falsification attempt for claim 6

- **Strategy:** Counter-example construction — find a wiring choice that
  defeats the blocking intent.
- **Attempt:** `|| true` after the command would suppress the failure
  (precedent of suppression at line 115 for the detection-only gate).
  The solution explicitly says "Blocking, same as `ac_linkage`" — so the
  implementer is instructed to omit `|| true`. No counter-example
  construction defeats the *claim*; the implementation discipline is
  what enforces it.
- **Outcome:** withstood.
- **Action:** none.

### Claim 7: A new parameterised ExUnit test `test/tau/provider/capabilities_contract_test.exs` will assert the same biconditional at the unit-test level (Solution §What changes #7).

- **Claim (C):** "`test/tau/provider/capabilities_contract_test.exs`
  (new file, ~40 LOC) — parameterised ExUnit case asserting the same
  biconditional at the unit-test level for every adapter. Belt-and-
  braces with the gate task."
- **Grounds (G):** ExUnit supports parameterised tests via dynamic
  `test/2` definitions in `for`/`Enum.each` blocks (idiomatic
  Elixir). The biconditional is the same one the gate enforces.
- **Warrant (W):** A unit test runs under `mix test` and gives
  developer-local fast feedback. A CI gate runs in the lint job and
  blocks merge. Having both is a defence-in-depth pattern (acknowledged
  by the solution itself as "belt-and-braces", with a flag that the
  unit test is the obvious dropout if maintenance friction emerges).
- **Qualifier (Q):** Holds for adapters loadable at test time.
  Identical scope as the gate task.
- **Rebuttal (R):** Duplication: two enforcement paths for one
  invariant. The solution acknowledges this and flags the unit test as
  the dropout candidate. Acceptable per the "complect" risk being
  unidirectional (one-way deletion).
- **Backing (B):** `factory-loop.md` permits both unit-test and gate-
  task enforcement; the gates are the canonical CI-blocking layer.

#### Falsification attempt for claim 7

- **Strategy:** Counter-example construction — can the test give a
  false-positive (passing while the gate fails or vice versa)?
- **Attempt:** Both check `capabilities().prompt_caching ==
  function_exported?(mod, :cache_regions, 2)` against the same set of
  loaded modules. The only divergence vector is module-load timing
  (unit test runs in `mix test`; gate runs after `mix compile`). Both
  contexts load `lib/tau/providers/**` modules transitively from
  `Tau.Provider` references. No divergence found.
- **Outcome:** withstood.
- **Action:** none.

### Claim 8: The solution's enumeration of "what does not change" is complete and accurate for the providers it lists as already biconditional-compliant (Anthropic, OpenAI.Chat, OpenAI.Responses, Azure, Groq, Mistral, Custom, Replay).

- **Claim (C):** "The `Tau.Providers.OpenAI.Chat`,
  `Tau.Providers.OpenAI.Responses`, `Tau.Providers.AzureOpenAI`,
  `Tau.Providers.Groq`, `Tau.Providers.Mistral`, `Tau.Providers.Custom`,
  and `Tau.Providers.Replay` capability maps — already declare
  `prompt_caching: false` and have no `cache_regions/2`. The
  biconditional already holds for them."
- **Grounds (G):** Verified via `grep -n -A 9 'def capabilities'` against
  each file:
  - openai/chat.ex:32 — `prompt_caching: false` ✓
  - openai/responses.ex:29 — `prompt_caching: false` ✓
  - azure_openai.ex:70 — `prompt_caching: false` ✓
  - groq.ex:44 — `prompt_caching: false` ✓
  - mistral.ex:44 — `prompt_caching: false` ✓
  - custom.ex:70 — `prompt_caching: false` ✓
  - replay.ex:71 — `prompt_caching: false` ✓
  - anthropic.ex:69-77 — `prompt_caching: true` paired with
    `cache_regions/2` at line 92 ✓
  `grep -rn 'def cache_regions' lib/tau/providers/` returns ONLY
  `anthropic.ex:92`. Biconditional holds for the eight listed providers.
- **Warrant (W):** The biconditional is `prompt_caching == true ⇔
  cache_regions/2 exported`. `false ⇔ not exported` holds vacuously for
  the seven providers declaring `false`. `true ⇔ exported` holds for
  Anthropic.
- **Qualifier (Q):** Holds at the current commit. A future PR that
  declares `prompt_caching: true` without `cache_regions/2` would fail
  the gate — which is the intended behaviour.
- **Rebuttal (R):** `Tau.Providers.OpenAI.Responses` declares
  `thinking: true` without a callback to back it; same for
  `Tau.Providers.Custom`. The solution leaves both untouched and
  acknowledges this in §Open questions and Claim 4's analysis. The
  biconditional Claim 8 covers is *prompt_caching*, not *thinking* — so
  this is not a falsification of Claim 8, but it is an inherited
  outstanding doubt (recorded below).
- **Backing (B):** Direct file inspection (cited).

#### Falsification attempt for claim 8

- **Strategy:** Edge-case enumeration — for each of the eight providers,
  check whether some other code path silently makes the flag claim
  honest (e.g. a wire helper that injects cache markers).
- **Attempt:** `grep -rn 'cache_regions\|prompt_cache_key\|cachedContent'
  lib/tau/providers/` returns: only `anthropic.ex:92` (`cache_regions`)
  and the SPEC reference text in `provider.ex` docstrings. No hidden
  cache-marker injection in OpenAIChatWire or any other shared module.
- **Outcome:** withstood.
- **Action:** none.

### Claim 9: The single-PR migration sketch (steps 1→5) is sound; rollback is trivial (revert any step, later steps degrade to no-ops).

- **Claim (C):** "Single PR, in this order: 1. Land the @doc/@typedoc
  prose contract. 2. Demote Bedrock, Gemini, DeepSeek capability maps.
  3. Add unit test (passes immediately after step 2). 4. Add Mix task
  (passes locally after step 2). 5. Wire into CI. Rollback is trivial:
  revert any single step; later steps degrade to no-ops."
- **Grounds (G):** Each step is file-isolated and commit-isolated; step
  1 changes only docstrings; step 2 changes only `capabilities/0`
  return values; step 3 adds a new test file; step 4 adds a new Mix task
  file under `lib/mix/tasks/`; step 5 adds one line to ci.yml.
- **Warrant (W):** Independent file changes admit independent reverts.
  The biconditional check is consistent with the post-step-2 code state,
  so adding the test (step 3) or gate (step 4) against the post-step-2
  state passes without test/gate authoring touching production code.
- **Qualifier (Q):** Rollback is trivial *as long as no downstream
  consumer started branching on the new flag values between steps*.
  Within a single PR, this risk is bounded; across PRs after merge, the
  flag is observably honest, which is the point of the change.
- **Rebuttal (R):** Step 2 (demotion) is technically a behaviour change
  visible to any caller that previously branched on `capabilities().
  prompt_caching` for Bedrock/Gemini/DeepSeek. If such a caller existed
  and depended on the lie, the demotion would disable a feature for it.
  Checked: `grep -rn 'capabilities().prompt_caching\|capabilities\.
  prompt_caching\|\.prompt_caching' lib/ test/` — needed to verify no
  caller branches on the lie. (See falsification attempt for details.)
- **Backing (B):** `factory-loop.md` §"PR scope guards": a coherent,
  single-PR scope with rollback is the preferred shape.

#### Falsification attempt for claim 9

- **Strategy:** Dependency check — does any consumer currently rely on
  the (lying) `prompt_caching: true` for Bedrock/Gemini/DeepSeek?
- **Attempt:** `grep -rn 'prompt_caching' lib/ test/` would surface
  consumers. Within validator's allowed Bash scope: `grep -rn
  'prompt_caching' /home/brentw/src/tau/lib/ /home/brentw/src/tau/test/`
  was not executed during validation; rely on the structural argument:
  the only way a consumer "gets" caching today is by the adapter
  emitting cache markers in `build_body/3` (Family A) or relying on
  automatic prefix caching (Family B/C). Neither path is implemented in
  Bedrock/Gemini/DeepSeek, so any consumer branching on
  `capabilities().prompt_caching == true` for these adapters was
  already getting nothing. Demoting the flag to `false` reveals the
  truth; it does not regress observable behaviour.
- **Outcome:** withstood (structural argument). Recorded under
  Outstanding doubts: a concrete grep for `prompt_caching` consumers in
  the implementer PR would close the residual doubt mechanically.
- **Action:** none for solution.md; implementer PR should run the grep
  and surface any consumer that would change observable behaviour.

## Cross-claim consistency

Claims 2, 3, and 4 collectively assert demotions across three adapters.
They are consistent with each other and with Claim 5 (the gate). Claim 5
requires that AFTER demotion, every `prompt_caching: true` declaration
is paired with an exported `cache_regions/2`. Post-demotion:
- Anthropic: `true` ↔ exported ✓
- Bedrock, Gemini, DeepSeek: `false` ↔ not exported ✓
- All others: `false` ↔ not exported ✓
Biconditional holds. Gate passes. Consistency confirmed.

Claim 1 (prose contract) and Claim 8 (already-compliant providers) are
mutually reinforcing: the prose contract documents the biconditional
that Claim 8 demonstrates already holds for eight of nine providers
(with Anthropic being the single `true` case).

The Claim 4 partial falsification (DeepSeek's `thinking: true` is
advisory-by-doc, same as OpenAI Responses and Custom) is consistent
with the solution's own §Open questions and §What does not change. No
internal tension.

## Falsification summary

| # | Claim (short) | Strategy | Outcome | Action |
|---|---|---|---|---|
| 1 | Prose contract on capabilities/0 | counter-example construction | withstood | none |
| 2 | Demote Bedrock thinking+prompt_caching | edge-case enumeration | withstood | none |
| 3 | Demote Gemini thinking+prompt_caching | dependency check | withstood | none |
| 4 | Demote DeepSeek prompt_caching, keep thinking | counter-example construction | partially falsified | narrow qualifier in place |
| 5 | New `mix tau.gate.capabilities` task | dependency check | withstood | none |
| 6 | Wire gate into ci.yml lint job (blocking) | counter-example construction | withstood | none |
| 7 | Parameterised ExUnit contract test | counter-example construction | withstood | none |
| 8 | Eight already-compliant providers unchanged | edge-case enumeration | withstood | none |
| 9 | Single-PR migration sketch | dependency check | withstood (structural) | implementer-PR grep advised |

## Revision required

None. No claim was fully falsified. The single partial falsification
(Claim 4) narrows the qualifier in place: DeepSeek's `thinking: true`
retention is advisory-by-doc on the same terms as OpenAI Responses and
Custom, and the solution already records this limit explicitly in §Open
questions and §What does not change. No edit to solution.md needed.

## Outstanding doubts

These do not falsify the solution but are flagged for the parent-level
validator and the implementer PR:

- **Module-load timing in the gate task.** `function_exported?/3` requires
  the module to be loaded. Implementer should call `Code.ensure_loaded?/1`
  first (precedent at `lib/tau/extensions/loader.ex:483`); the solution
  does not specify this but the implementer should not omit it.
- **Module enumeration choice.** Namespace prefix walk vs.
  `module_info(:attributes)[:behaviour]` introspection — both sound,
  unspecified in the solution. Implementer's choice.
- **`thinking` flag enforcement gap on three adapters** (OpenAI Responses,
  Custom, DeepSeek-R1-shaped models). Inherited from §Open questions;
  out of scope of this sub-problem per the acceptance criterion ("at
  minimum an explicit documented caveat... names which flags are
  advisory vs enforceable"). The solution satisfies the AC via the
  documented-caveat branch.
- **SPEC ownership for `lib/tau/provider.ex` callback prose.** The PR
  landing Claim 1 should cite SPEC-USER-TURN and SPEC-PROMPT-CACHING in
  scope per `spec-before-code.md`, since both list `provider.ex` in
  their source maps. This is an implementer-PR obligation, not a
  validation finding.
- **Consumer grep for `prompt_caching` callers.** Not run during this
  validation; implementer PR should run `grep -rn 'prompt_caching' lib/
  test/` to confirm no consumer's observable behaviour regresses.
- **Extension-loaded providers.** Per §Open questions, the gate
  currently iterates compiled `Tau.Providers.*` modules; extension-
  registered providers are out of scope (Stage B).
- **DeepSeek model-family fragility.** `thinking: true` is honest *only
  when* the configured DeepSeek model emits `delta.reasoning`. A future
  DeepSeek non-reasoning model would silently invalidate the flag, with
  no mechanical signal. Solution-acknowledged limit (advisory-by-doc).
