---
template_version: 1
template_name: solution
parent_problem: ../problem.md
node_kind: leaf
synthesised_from: [proposals/proposal-3.md, proposals/proposal-1.md]
selection_method: hybrid
revision: 1
---

# Solution: honest flags, mechanically enforced for the only verifiable flag

## Recommendation

Adopt Proposal 3's "honest flags + documented contract" as the spine of the
fix, and graft on Proposal 1's structural-enforcement idea — but implemented as
a **project-level CI gate task** (`mix tau.gate.capabilities`) rather than a
`@before_compile` hook. The new gate, modelled on the existing
`tau.gate.ac_linkage` / `tau.gate.masking` / `tau.gate.mutation` family, scans
every `Tau.Providers.*` module and fails CI when `capabilities().prompt_caching
== true` is not paired with an exported `cache_regions/2`, and vice versa. The
behaviour module gains a single, prose-level `@doc` contract that names which
flags are mechanically enforceable (`prompt_caching` only) and which are
advisory-by-documentation (`thinking`, `tools`, `vision`, `parallel_tools`).
Every adapter whose declared `prompt_caching: true` is unbacked is demoted in
the same PR: today that means **Bedrock, Gemini, and DeepSeek**. No new
`@callback`, no `@optional_callbacks` churn, no `@before_compile`, no
`__using__` macro, no API-breaking type change.

## Selected from

- **Chosen:** hybrid of `proposals/proposal-3.md` (documented caveat + flag
  demotion) + `proposals/proposal-1.md` (the enforcement idea, but reshaped
  into a CI-gate task instead of a `@before_compile` hook).
- **Why chosen:** Proposal 3 wins on every comparison axis (zero API breakage,
  zero new callbacks, smallest diff, scores Yes on fit) but admits one
  weakness — "no enforcement prevents a future PR from silently re-elevating
  Bedrock or Gemini `thinking` to `true` without implementing the decode
  path". For the `prompt_caching` flag specifically, that weakness can be
  closed cheaply by adding the same kind of CI gate the repo already has for
  every other enforcement need. We borrow the *motivation* of Proposal 1
  (mechanical, not human-discipline-only) while rejecting its *mechanism*
  (`@before_compile` via `__using__`) because every existing adapter binds via
  `@behaviour Tau.Provider` directly (verified: `grep -n '@behaviour
  Tau.Provider\|use Tau.Provider' lib/tau/providers/*.ex` returns nine
  `@behaviour` matches and zero `use` matches), so the hook never fires
  unless every adapter is also migrated to `use Tau.Provider` — that
  migration is exactly what the prior selector's solution overlooked.
  Proposal 2's typed-level enum is rejected on cost (eleven-adapter migration
  plus ~15–20 caller sites for a problem whose only mechanically verifiable
  flag is `prompt_caching`). Proposal 4's runtime probe is rejected on the
  fixture-fidelity weakness its own author flagged (Confidence: Low).

### Comparison table

| # | Fit | Decomplecting depth | Migration cost | Risk | Reversibility |
|---|---|---|---|---|---|
| 1 | Yes — but mechanism (`@before_compile`) silently no-ops against `@behaviour`-binding adapters | Substantial in principle, Surface in practice | Medium (audit + migrate all adapters to `use`) | Medium (silent no-op already happened) | Easy |
| 2 | Yes | Deep | High (11 adapters + 15–20 caller sites) | Medium | Hard (API break) |
| 3 | Yes (via the "documented caveat" branch of the AC) | Substantial | Low (3 adapter edits + 1 doc + 1 test) | Low | Easy |
| 4 | Partially — fixture fidelity gap | Substantial | High (11 adapters + supervisor + caller migration) | Medium-High | Hard |
| **Hybrid (3 + CI gate)** | **Yes** | **Substantial** | **Low (3 adapter edits + 1 doc + 1 test + 1 mix task)** | **Low** | **Easy** |

## What changes

Concrete, file-level enumeration:

1. **`lib/tau/provider.ex`** — extend the `@typedoc` and `@doc` on
   `@callback capabilities/0` with the prose contract from Proposal 3 §Sketch
   (flag-by-flag truthfulness semantics). Explicitly name `prompt_caching` as
   the only mechanically enforceable flag and state that the enforcement runs
   as the CI gate `mix tau.gate.capabilities`. **No new `@callback`, no
   change to `@optional_callbacks`, no `__using__` macro, no
   `@before_compile`.** (The existing `@callback cache_regions/2` declared at
   `lib/tau/provider.ex:110` is already correctly paired with its
   `@optional_callbacks` entry at line 131 and remains untouched.)

2. **`lib/tau/providers/bedrock.ex:35-37`** — demote `thinking: true → false`
   and `prompt_caching: true → false` (no `cache_regions/2` exists in this
   module; decode path emits no thinking events).

3. **`lib/tau/providers/gemini.ex:29-31`** — demote `thinking: true → false`
   and `prompt_caching: true → false` (same justification; verified by
   `grep cache_regions lib/tau/providers/gemini.ex` returning empty).

4. **`lib/tau/providers/deepseek.ex:46-54`** — demote `prompt_caching: true →
   false` (no `cache_regions/2` exists in this module; verified by
   `grep -n 'def cache_regions' lib/tau/providers/deepseek.ex` returning
   empty). The `thinking: true` flag on DeepSeek IS backed — the decode path
   goes through `Tau.Providers.Shared.OpenAIChatWire` which synthesises
   `ThinkingStart/Delta/End` events for `delta.reasoning` (per problem.md
   Context, `openai_chat_wire.ex:115-166`) — so `thinking: true` stays.

5. **`lib/mix/tasks/tau.gate.capabilities.ex`** (new file, ~60 LOC) — a
   `Mix.Task` modelled directly on `lib/mix/tasks/tau.gate.ac_linkage.ex` /
   `lib/mix/tasks/tau.gate.masking.ex` / `lib/mix/tasks/tau.gate.mutation.ex`
   (precedent files already exist in `lib/mix/tasks/`). It loads every
   module under the `Tau.Providers.` namespace that implements
   `Tau.Provider`, reads each module's `capabilities/0`, and asserts the
   biconditional

   ```
   capabilities().prompt_caching == true  ⇔  function_exported?(mod, :cache_regions, 2)
   ```

   Exit 0 on full agreement; exit 1 with a per-adapter diagnostic line on any
   violation. The task is pure: no side effects, no network, no GenServer.
   Shared helpers (if any emerge) live under `lib/mix/gate/`, following the
   existing layout.

6. **`.github/workflows/ci.yml`** — add an invocation of `mix
   tau.gate.capabilities` to the existing `lint` job, alongside the existing
   `mix tau.gate.ac_linkage` and `mix tau.gate.masking` lines (precedent at
   ci.yml:101 and ci.yml:115). Blocking, same as `ac_linkage`.

7. **`test/tau/provider/capabilities_contract_test.exs`** (new file, ~40 LOC) —
   parameterised ExUnit case asserting the same biconditional at the unit-test
   level for every adapter. Belt-and-braces with the gate task: the test runs
   under `mix test` (developer-local fast feedback) and the gate task runs in
   CI (PR-blocking, mirrors the gate-task pattern used elsewhere in the repo).

## What does not change

- The `capabilities/0` return shape (still `%{atom() => boolean()}`).
- The set of `@callback` declarations in `Tau.Provider` (no addition; no
  removal). `@optional_callbacks` is unchanged — `cache_regions/2` and
  `context_window/1` remain optional, both still paired with `@callback`
  declarations as the behaviour requires.
- The binding style of any adapter (`@behaviour Tau.Provider` stays — no
  forced migration to `use Tau.Provider`).
- The `Tau.Providers.Anthropic` capability map (already honest: declares
  `prompt_caching: true` and implements `cache_regions/2` at
  `lib/tau/providers/anthropic.ex:92`).
- The `Tau.Providers.OpenAI.Chat`, `Tau.Providers.OpenAI.Responses`,
  `Tau.Providers.AzureOpenAI`, `Tau.Providers.Groq`,
  `Tau.Providers.Mistral`, `Tau.Providers.Custom`, and `Tau.Providers.Replay`
  capability maps — already declare `prompt_caching: false` and have no
  `cache_regions/2`. The biconditional already holds for them.
- The `thinking` flag's enforcement model. It remains advisory-by-doc; no
  callback is added for it. Decomplecting a flag whose decode-path
  obligations are not localisable to a single callback is left for a future
  PR (open question below).
- All non-provider call sites and all callers of `adapter.capabilities()`.

## Migration sketch

Single PR, in this order:

1. Land the `@doc` / `@typedoc` prose contract on
   `Tau.Provider.capabilities/0` (no behaviour change).
2. Demote `Tau.Providers.Bedrock`, `Tau.Providers.Gemini`, and
   `Tau.Providers.DeepSeek` capability maps to their honest values. Compile
   stays green (boolean values unchanged in shape).
3. Add `test/tau/provider/capabilities_contract_test.exs`; it passes the
   moment step 2 is in place.
4. Add `lib/mix/tasks/tau.gate.capabilities.ex`; run it locally
   (`mix tau.gate.capabilities`) to confirm exit 0.
5. Wire the gate into `.github/workflows/ci.yml`'s `lint` job.

Rollback is trivial: revert any single step; later steps degrade to no-ops.
The CI gate (step 5) is the only step with cross-PR enforcement — it can be
reverted by deleting one line in ci.yml.

## Open questions

- **`thinking` flag enforcement.** The biconditional pattern works for
  `prompt_caching` because there is exactly one callback (`cache_regions/2`)
  whose presence is necessary AND sufficient evidence that the adapter
  participates. No equivalent single callback exists for `thinking` — the
  obligations are spread across `build_body/3` (sending the param block) and
  the decode path (emitting `ThinkingStart/Delta/End`). Proposal 1's
  `thinking_config/1` is one possible synthesis target, but until the
  decode-path side is also enforced, the callback only proves something is
  exported. The current solution leaves `thinking` advisory-by-doc and demotes
  the two lying adapters (Bedrock, Gemini); whether a future enforcement
  layer should target it is for a follow-up sub-problem.
- **Should the test live alongside the gate or replace it?** This solution
  ships both belt-and-braces. If maintenance friction surfaces, the unit test
  is the obvious dropout candidate (the CI gate is the contract; the unit
  test only mirrors it).
- **Future adapters added via extensions** (per SPEC-EXTENSIONS) — the gate
  task currently iterates `Tau.Providers.*`; whether it should also iterate
  loaded extension modules is a Stage B question once extensions can register
  providers.

## Linked sub-problems / proposals

- `proposals/proposal-1.md` — Enforce capability flags via mandatory optional
  callbacks. Mechanism rejected (`@before_compile` silently no-ops against
  `@behaviour`-binding adapters; every current adapter binds via `@behaviour`,
  none via `use`); enforcement *motivation* preserved as the CI gate task.
- `proposals/proposal-2.md` — Replace boolean flags with a typed capability
  level struct. Rejected on migration cost and API breakage for a problem
  whose mechanically verifiable surface is one flag.
- `proposals/proposal-3.md` — Documented advisory caveat in behaviour. Chosen
  as the spine of the solution.
- `proposals/proposal-4.md` — Runtime capability probe. Rejected on the
  fixture-fidelity weakness its own author flagged (Confidence: Low).

## Revision history

- (revision 0 — initial selection) Proposed Proposal 3 + a `@before_compile`
  enforcer for `prompt_caching`. Falsified on three points: (a) the
  enforcer never fires because every adapter binds via `@behaviour`, not
  `use` (verified: `grep -n '@behaviour Tau.Provider\|use Tau.Provider'
  lib/tau/providers/*.ex` returns nine `@behaviour` matches, zero `use`);
  (b) the proposal would add `@optional_callbacks thinking_config: 1` without
  a matching `@callback thinking_config(...)` declaration, emitting a compile
  warning ("undefined callback function ..."); (c) the violation enumeration
  omitted `Tau.Providers.DeepSeek`, which declares `prompt_caching: true` at
  `lib/tau/providers/deepseek.ex:51` without exporting `cache_regions/2`.
- (revision 1 — current) Replaced `@before_compile` enforcer with a CI-gate
  task (`mix tau.gate.capabilities`) modelled on the existing
  `tau.gate.ac_linkage` / `tau.gate.masking` / `tau.gate.mutation` family;
  this enforcement mechanism is binding-style-agnostic. Added DeepSeek to
  the demotion list. Removed all `@callback` / `@optional_callbacks` churn
  — no behaviour-level changes beyond `@doc` / `@typedoc` prose.
