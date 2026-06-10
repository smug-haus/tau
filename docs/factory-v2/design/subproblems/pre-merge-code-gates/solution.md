---
template_version: 1
template_name: solution
parent_problem: ../problem.md
node_kind: leaf
synthesised_from: [proposals/proposal-2.md, proposals/proposal-3.md, proposals/proposal-4.md]
selection_method: hybrid
revision: 0
---

# Solution: `tau-code-gates` plugin — five adversarial decks on ecosystem substrates, unified by a hash-stamped manifest runner that cannot silent-skip

## Recommendation

Ship the pre-merge code-gate substrate as a Claude Code plugin
(`plugins/tau-code-gates/`) that exposes **five independent decks** —
`CapabilityFidelity`, `NoUnreachableRescue`, `BehaviourClosure`,
`SpecSymbolExistence`, `TelemetryConsumers` — each constructed backwards
from a verified v1 failure (proposal-4), each implementing one
`Tau.Gate.Deck` behaviour callback that returns an enumerated input set
and findings (proposal-3), and each delegating its checking engine to an
existing ecosystem tool (proposal-2) wherever one exists: Credo's
custom-check framework for `NoUnreachableRescue`, Elixir compiler +
Dialyxir for `BehaviourClosure`, Sourceror for `CapabilityFidelity` /
`SpecSymbolExistence` / the AST-side of `TelemetryConsumers`,
`:telemetry`'s ETS handler table for the runtime side of
`TelemetryConsumers`. A single umbrella task `mix tau.gate.code` runs
every registered deck, writes a hash-stamped manifest
(`/tmp/tau-gate.json`) whose `overall_verdict` the CI status check
consumes verbatim, and exits non-zero if **any** deck reports findings,
**any** deck returns `inputs_enumerated == []`, **any** deck's
`inputs_processed != inputs_enumerated`, **any** required-deck module
fails to load, or the manifest artifact fails to upload. The same Mix
tasks run pre-commit via a `PreToolUse` hook in the plugin so the
implementer agent sees verdicts before pushing. Each deck records its
`tool_of_record` (`bespoke | dialyxir | credo | sourceror | telemetry`)
in the manifest, satisfying root §AC-D "ecosystem reuse" by
construction; bespoke surface is bounded to ~600 LoC of glue plus the
flag→callback table, all justified per deck in `priv/gate/decks.toml`.

## Selected from

- **Chosen:** hybrid of `proposals/proposal-2.md` (ecosystem adoption +
  Claude Code plugin shape), `proposals/proposal-3.md` (deck behaviour
  + hash-stamped manifest + `tool_of_record` recording), and
  `proposals/proposal-4.md` (five gates constructed backwards from
  named v1 failures with named falsifiers).

- **Why chosen.** Scoring against the leaf acceptance criterion:

  | # | Fit | Decomplecting depth | Migration cost | Risk | Reversibility |
  |---|---|---|---|---|---|
  | 1 (in-repo substrate) | Partially | Substantial | Medium | Low | Easy |
  | 2 (adapt-from-ecosystem) | Yes | Deep | Medium | Low | Easy |
  | 3 (ASIC sign-off decks) | Yes | Deep | Medium | Low | Easy |
  | 4 (five adversarial gates) | Yes | Substantial | Medium-high | Low | Easy |

  Proposal-2 wins on root §AC-D (ecosystem reuse over reinvention) —
  it is the only proposal that names a specific existing tool per
  check, justifies bespoke surface explicitly, and adopts the
  claude-code-elixir / Anthropic plugin patterns the prompt directs us
  toward. Proposal-3 wins on root §AC-C (silent-skip impossibility) —
  its `inputs_enumerated/inputs_processed/findings` triple plus the
  hash-stamped manifest is the only proposal whose silent-skip
  guarantee survives at five independent layers (runner, deck, CI, the
  manifest itself, the artifact upload). Proposal-4 wins on root §AC-A
  (failure-class coverage) — each gate is constructed backwards from a
  specific, grep-verifiable v1 merge the gate must have blocked, which
  is the Toulmin-warrant test the v1 review process failed to apply.
  Proposal-1 dominates on none and reinvents what proposal-2 adopts;
  it is not selected.

  None of the three winning proposals dominates the others on every
  axis — proposal-2 has no manifest discipline, proposal-3 leaves the
  per-deck failure derivation implicit, proposal-4 underweights
  ecosystem adoption. The hybrid takes the load-bearing element of
  each: the *engine substrate* from proposal-2, the *verdict
  protocol* from proposal-3, and the *adversarial gate construction*
  from proposal-4. The combination is more than the sum: ecosystem
  adoption without a manifest still permits stdout-scraping (the v1
  failure mode); a manifest runner without ecosystem adoption is the
  reinvention root §AC-D forbids; either without adversarial
  construction risks "platform looking for a use case" (proposal-3's
  self-cited weakness).

## What changes

### Artifact inventory — every concrete component the spec creates

#### Elixir code under `lib/`

- `lib/tau/gate/deck.ex` — defines `Tau.Gate.Deck` behaviour with
  callbacks `deck_id/0`, `tool_of_record/0`, `enumerate_inputs/0`,
  `run/1`; types `input()`, `finding()`, `result()`. (~80 LoC)
- `lib/tau/gate/manifest.ex` — writes the hash-stamped JSON manifest,
  computes `overall_verdict`, validates against
  `priv/gate/manifest.schema.json`. (~120 LoC)
- `lib/tau/gate/enumeration.ex` — input-set helpers (wildcards,
  compiled-module lists, behaviour-implementor enumeration). (~80 LoC)
- `lib/tau/gate/waiver.ex` — reads `priv/gate/waivers.toml`, enforces
  `expires_at` and `rule_id` schema, rejects expired entries; uses
  `:toml_elixir` (already in dep tree). (~100 LoC)
- `lib/tau/telemetry/attach.ex` — production wrapper around
  `:telemetry.attach/4` that tags handler IDs with `prod:` prefix so
  the `TelemetryConsumers` deck can distinguish production handlers
  from test handlers (proposal-2 weakness mitigation). (~30 LoC)

#### Five deck modules under `lib/tau/gate/decks/`

Each implements `Tau.Gate.Deck` and is co-located with its property
tests under `test/tau/gate/decks/`.

- `lib/tau/gate/decks/capability_fidelity.ex` — proposal-4 Failure 1.
  `tool_of_record/0` returns `:sourceror`. Reads
  `Tau.Provider.Capabilities.required_callbacks/0` (the
  flag→callback table — proposal-1's contribution kept here as a
  pure data module under `lib/tau/provider/capabilities.ex`, ~40 LoC)
  and asserts every `true`-valued flag has its callback exported.
  Inventory: every `.ex` file under `lib/tau/providers/*.ex`. (~150
  LoC)
- `lib/tau/gate/decks/no_unreachable_rescue.ex` — proposal-4 Failure
  2 + proposal-2 §#2. `tool_of_record/0` returns `:credo`. Delegates
  to three Credo custom checks:
  `Tau.Credo.Checks.NoTryRescueAcrossProcess`,
  `Tau.Credo.Checks.NoCatchExit`,
  `Tau.Credo.Checks.NoRescueWithoutJustification`. Inventory: every
  `.ex` file under `lib/tau/`. (~120 LoC deck + ~180 LoC across the
  three Credo checks below)
- `lib/tau/gate/decks/behaviour_closure.ex` — proposal-4 Failure 3
  + proposal-2 §#1 Dialyxir path. `tool_of_record/0` returns
  `:dialyxir`. Drives `mix dialyzer --halt-exit-status` with a
  cached PLT and parses output for `callback_missing`,
  `callback_arg_type_mismatch`, `callback_not_exported`. Inventory:
  every module returned by `:application.get_key(:tau, :modules)`.
  (~150 LoC)
- `lib/tau/gate/decks/spec_symbol_existence.ex` — proposal-4
  Failure 4. `tool_of_record/0` returns `:sourceror`. Walks every
  `docs/spec/SPEC-*.md` §4, extracts backticked CamelCase tokens,
  cross-checks against the compiled module set. Inventory: every
  file matching `docs/spec/SPEC-*.md`. (~140 LoC)
- `lib/tau/gate/decks/telemetry_consumers.ex` — proposal-4 Failure 5
  + proposal-2 §#4. `tool_of_record/0` returns `:sourceror_and_telemetry`.
  Step 1: Sourceror walk over `lib/` to collect every literal event
  list passed to `:telemetry.execute/{2,3}`. Step 2: boots
  `Application.ensure_all_started(:tau)` and reads
  `:ets.tab2list(:telemetry_handler_table)`. Step 3: filters
  handlers by `prod:` ID prefix (per `lib/tau/telemetry/attach.ex`).
  Step 4: asserts every emitted event prefix has a matching
  production handler. Inventory: emitted-events list (must be ≥1)
  and prod-handlers list (must be ≥1). (~180 LoC)

#### Credo custom checks under `lib/tau/credo/checks/`

- `lib/tau/credo/checks/no_try_rescue_across_process.ex` — adopts
  proposal-2 §#2 pattern; uses `Credo.Code.prewalk/2`,
  `IssueMeta.for/2`. (~80 LoC)
- `lib/tau/credo/checks/no_catch_exit.ex` — same shape. (~60 LoC)
- `lib/tau/credo/checks/no_rescue_without_justification.ex` —
  proposal-4 Failure 2 annotation grammar: requires a
  `# rescue: <Mod.fun/arity> <reason>` comment within 3 lines above
  every `try/rescue` site, cross-checks `Mod.fun/arity` exists via
  `Code.ensure_loaded?/1` + `function_exported?/3`. (~120 LoC)

#### Mix tasks under `lib/mix/tasks/`

- `lib/mix/tasks/tau.gate.code.ex` — umbrella runner (proposal-3
  pattern); reads `priv/gate/decks.toml` for `@required_decks`,
  iterates, fails on any missing deck module, writes manifest, exits
  non-zero on any FAIL/ERROR/empty-inventory. (~150 LoC)
- `lib/mix/tasks/tau.gate.capability_fidelity.ex` — thin shim invoking
  the deck for local runs. (~20 LoC)
- `lib/mix/tasks/tau.gate.no_unreachable_rescue.ex` — same. (~20 LoC)
- `lib/mix/tasks/tau.gate.behaviour_closure.ex` — same. (~20 LoC)
- `lib/mix/tasks/tau.gate.spec_symbol_existence.ex` — same. (~20 LoC)
- `lib/mix/tasks/tau.gate.telemetry_consumers.ex` — same. (~20 LoC)

#### Configuration / registry files under `priv/`

- `priv/gate/decks.toml` — canonical registry of required deck IDs;
  the umbrella runner refuses to start if `@required_decks` does not
  exactly equal the keys in this file. Format:
  ```toml
  [decks.capability_fidelity]
  module = "Tau.Gate.Decks.CapabilityFidelity"
  required = true
  tool_of_record = "sourceror"
  ```
- `priv/gate/manifest.schema.json` — JSON schema (draft 2020-12) the
  manifest writer validates against; CI consumer also validates.
- `priv/gate/waivers.toml` — per-finding waivers
  `{file, line, rule_id, expires_at, justification, remediated_by}`;
  expired waivers are removed by the deck, treated as findings.
- `priv/gates/<deck_id>.inputs.json` (per proposal-4) — explicit
  per-deck input inventory for any deck whose enumeration is not
  fully implicit from `Path.wildcard/1`. Absent or empty file → exit 2.
- `priv/gate/telemetry.consumer_kinds.toml` — allowlist of production
  handler modules (per proposal-1); editing the file requires a PR.
- `priv/gate/README.md` — ≤80 lines explaining the deck contract,
  the inventory pattern, the annotation grammar for rescues, and the
  waiver schema. (Not documentation-only — readers run the gate; the
  README is the user manual for `priv/gate/`.)

#### Claude Code plugin under `plugins/tau-code-gates/`

- `plugins/tau-code-gates/.claude-plugin/plugin.json` — manifest
  pinning Anthropic plugin schema version; declares the slash command,
  hook, skill.
- `plugins/tau-code-gates/commands/tau-code-gates-run.md` — slash
  command `/tau-code-gates:run` that invokes `mix tau.gate.code` and
  pretty-prints the manifest.
- `plugins/tau-code-gates/hooks/pre-tool-use.json` — registers a
  `PreToolUse` hook matching `Bash` calls whose `command` matches
  `^git commit\b` or `^gh pr ready\b`; invokes `run-gates.sh`; exit
  non-zero blocks the tool call. Mirrors Anthropic's documented
  `PreToolUse` contract.
- `plugins/tau-code-gates/hooks/run-gates.sh` — bash script invoking
  `mix tau.gate.code --manifest /tmp/tau-gate-prehook.json`; surfaces
  findings to the agent transcript via stdout. Stdlib bash only.
- `plugins/tau-code-gates/skills/interpret-findings/SKILL.md` —
  progressive-disclosure skill for reading manifest findings;
  triggered by manifest JSON or `verdict: fail` in agent context.
- `plugins/tau-code-gates/agents/gate-doctor.md` — sub-agent invoked
  with the `gate-doctor` slash command; reads a failed manifest and
  proposes specific code changes (no auto-edits — proposes only).

Plugin registration: `.claude-plugin/marketplace.json` at the repo root
adds `tau-code-gates` to Tau's own marketplace.

#### CI workflow under `.github/workflows/`

- `.github/workflows/ci.yml` — **edited** (not new): adds five
  required jobs whose names match the five deck IDs. Each job pins
  `erlef/setup-beam@v1` with `version-file: .tool-versions,
  version-type: strict`, runs `mix deps.get` and `mix compile
  --warnings-as-errors`, then invokes its single Mix task. No
  `continue-on-error`. No `|| true`. No `if:` gate keyed on PR-body
  shape. The existing `lint` umbrella's `|| true` at line 115 and
  the early-exits at lines 88-100 and 213-223 are removed in the
  same PR as job-1 lands (coordinated with the
  pre-merge-evidence-and-skip-integrity sibling).
- `.github/workflows/tau-gate-code.yml` — **new**: dedicated
  umbrella job that runs `mix tau.gate.code --manifest
  /tmp/tau-gate.json` and uploads the manifest as a workflow
  artifact. Required status check named `tau-gate-code / umbrella`.
  Artifact upload step uses `if: always()` so a failed gate still
  uploads the manifest for audit.

#### GitHub branch protection (operational change, not a file)

Five status checks added to `main`'s required-status-checks set, plus
`tau-gate-code / umbrella`. `Require branches to be up to date before
merging` ON (prevents stale-base manifest reuse). Done via
`gh api repos/:owner/:repo/branches/main/protection -X PUT` — script
checked in at `priv/gate/branch_protection.json` and applied by a
one-shot `mix tau.gate.bootstrap.branch_protection` task.

#### Test surface under `test/`

- `test/tau/gate/deck_behaviour_test.exs` — property tests on the
  behaviour contract (every implementation satisfies type specs).
- `test/tau/gate/decks/<deck>_test.exs` — per-deck property tests
  + golden tests against `test/support/gates/<deck>/{good,bad}/`
  fixtures.
- `test/tau/credo/checks/<check>_test.exs` — uses Credo's
  `assert_issue/1` testing API from `hexdocs.pm/credo/testing_checks.html`.
- `test/tau/gate/manifest_test.exs` — schema validation, hash stability.
- `test/tau/gate/umbrella_test.exs` — runner-level tests: missing
  deck → exit non-zero; empty inventory → exit 2; deck crash → exit 3
  (matches existing Gate 5.3 exit-3 convention).

### Dependencies added to `mix.exs`

- `:sourceror, "~> 1.0", runtime: false` — Apache-2.0; AST traversal.
- `:boundary, "~> 0.10"` — MIT; compile-time cross-module dep
  constraints (deferred until adapter migration PR lands).
- `:telemetry_registry, "~> 0.3"` — Apache-2.0; declarative event
  discovery (used for documentation/discovery, not for the gate's
  verdict — the gate keys on ETS introspection).
- `:toml_elixir, "~> 2.0", runtime: false` — for `decks.toml` and
  `waivers.toml`.
- `:dialyxir, "~> 1.4"` — already present at `mix.exs:133`.
- `:credo, "~> 1.7"` — already present at `mix.exs:132`.

## What does not change

- The existing Mix gates `mix tau.gate.{ac_linkage,masking,mutation}`
  and their CI wiring (owned by sibling
  **intent-capture-and-ac-binding** and shared with the
  evidence-and-skip-integrity sibling). The five new decks are
  additive, not a replacement.
- The `Tau.Provider` behaviour contract itself — the
  `Capabilities` lookup table is added as a *data* module
  (`Tau.Provider.Capabilities`), not as a behaviour change. The
  existing `capabilities/0` callback signature is preserved.
- The branch protection for the existing `lint`, `test`, and
  `mutation-check` jobs.
- The OTP non-negotiables prose at `.claude/rules/otp-non-negotiables.md`
  — the rule remains source-of-truth; the gate enforces it
  mechanically. Per root §AC-G, the rule is not documentation-only
  because it is now paired with `Tau.Credo.Checks.*` enforcement.
- The existing AC-binding mechanism, the masking detection, and the
  mutation gate (Gate 5.3).
- The `Tau.Gate.Common` verdict helper (mentioned in proposal-2) — it
  is reused for the per-deck shim verdicts that flow into the manifest
  writer, so the operability dashboard sibling needs no schema change.
- Production-runtime behaviour of any module under `lib/tau/`. The
  gate code runs only under Mix tasks; Mix tasks are stripped from
  Burrito releases. Zero runtime cost in `prod`.
- The four existing failure-class corrective actions catalogued in
  `docs/factory-v2/corrective-actions.md` — the gate enables the
  cleanup, the cleanup itself is processed by the factory.

## Silent-skip impossibility — five-layer enforcement (implementation level)

This is the single load-bearing property of the leaf; the
implementation makes it impossible at five independent layers, so
failure of any one defence does not collapse the rest. Per root §AC-C
and leaf-AC (b):

1. **Runner layer.** `Mix.Tasks.Tau.Gate.Code` reads
   `priv/gate/decks.toml`; `@required_decks` MUST equal the file's keys
   set or the runner raises `Tau.Gate.Manifest.MismatchError` and exits
   3. For each required deck ID, `Code.ensure_loaded?(mod) and
   function_exported?(mod, :enumerate_inputs, 0)` is checked; a missing
   deck raises `UndefinedFunctionError` (uncaught — exits non-zero).
   There is no clause that returns PASS from a missing deck module.

2. **Deck layer.** Every deck implements the behaviour callback
   `enumerate_inputs/0 :: {:ok, [input()]} | {:error, atom(), String.t()}`.
   The umbrella's `deck_passes?/1` includes:
   ```elixir
   defp deck_passes?(%{verdict: :error}), do: false
   defp deck_passes?(%{inputs_enumerated: []}), do: false  # explicit
   defp deck_passes?(%{inputs_enumerated: e, inputs_processed: p}) when e != p, do: false
   defp deck_passes?(%{findings: findings}) when findings != [], do: false
   defp deck_passes?(_), do: true
   ```
   There is **no clause matching `inputs_enumerated: []` that returns
   true.** A property test
   `test/tau/gate/umbrella_test.exs:test "no clause returns true on empty inventory"`
   enumerates the `deck_passes?/1` clauses via Sourceror and asserts
   structurally that no clause returning `true` admits an empty inputs
   list. The check is on the *source AST* — the test itself cannot be
   silenced without showing in the masking gate's diff scan.

3. **Manifest layer.** `Tau.Gate.Manifest` validates the written JSON
   against `priv/gate/manifest.schema.json` (JSON Schema draft
   2020-12) on write; schema requires `decks: minItems: 5`,
   `overall_verdict: enum: ["PASS","FAIL","ERROR"]`. Writing an
   invalid manifest raises and exits 3. The manifest also includes
   `commit_sha: <git rev-parse HEAD>`; a CI consumer rejects a
   manifest whose `commit_sha` does not match `GITHUB_SHA`.

4. **CI workflow layer.** Each of the five deck jobs is a separate
   GitHub Actions job (proposal-4). No `continue-on-error`. No
   `|| true`. No `if:` keyed on PR-body shape. The umbrella job
   `tau-gate-code / umbrella` runs `mix tau.gate.code` with
   `set -euo pipefail` in the shell prelude. Branch protection lists
   six required checks; a missing check (e.g. a renamed job that no
   longer reports) is treated as RED by branch protection. The
   manifest artifact upload uses `if: always()` so a crashed runner
   still uploads partial state for audit.

5. **Audit-trail layer.** The manifest is retained as a workflow
   artifact for 90 days. The operability sibling's dashboard reads
   manifests across PRs and surfaces "deck X reported `inputs_count:
   0` on PR Y" as a first-class alert. A reviewer claiming a gate
   passed must point to the artifact; the PR comment auto-posted by
   the workflow contains the artifact URL and the `overall_verdict`.

A defence-in-depth diagram (informational, in `priv/gate/README.md`):
runner → deck → manifest → CI → audit. Each layer's null hypothesis
"this gate passed without checking anything" is mechanically
falsified at that layer; collapsing all five requires a coordinated
malicious change across five independent surfaces, every one of which
shows in `git diff`.

## Failure-class coverage map (root §AC-A: exactly one mechanism per class)

| Failure class (root §Hypothesis) | Mechanism (this leaf) | Falsifying v1 incident (proposal-4) |
|---|---|---|
| #1 contracts drift (code-side, struct existence) | `Tau.Gate.Decks.SpecSymbolExistence` | `ToolUseStart` named in SPEC-USER-TURN §4 :75, absent from `lib/` |
| #1 contracts drift (code-side, `@behaviour` completeness) | `Tau.Gate.Decks.BehaviourClosure` (Dialyxir + behaviour_info introspection) | `deepseek.ex:30` declares `@behaviour Tau.Provider` with missing callbacks silenced by `@optional_callbacks` |
| #2 `try/rescue` against unreachable conditions (NN #7) | `Tau.Gate.Decks.NoUnreachableRescue` (3 Credo checks + annotation grammar) | `session.ex:488-494` and the seven flagged rescue sites that moved zero between audits |
| #3 capability-flag fidelity | `Tau.Gate.Decks.CapabilityFidelity` (Sourceror + flag→callback table at `Tau.Provider.Capabilities`) | `deepseek.ex:51`, `bedrock.ex:36`, `gemini.ex:30` declare `prompt_caching: true` without `cache_regions/2` |
| #4 telemetry events without production consumer | `Tau.Gate.Decks.TelemetryConsumers` (Sourceror static + ETS introspection + `prod:` handler-ID tagging) | `compaction.ex` emits `[:tau, :compaction, :exception]` from 4 callsites; 0 production consumers attach |

Every class is named in exactly one deck. No class is covered by
"agent discipline" or "human review" only. The critic/reviewer pair
remains for quality checks (root §AC-B) but is not load-bearing for
any of these classes.

## Build-order — week-by-week deliverables with dependency graph

Total scope: 5 PRs across 5 weeks, plus 3 corrective-actions PRs
processed by the factory in parallel. Each PR is green-CI before the
next opens. Each PR is one coherent shippable increment per
`.claude/rules/factory-loop.md`.

### Dependency graph

```
PR-1 (substrate)
   ↓
PR-2 (CapabilityFidelity)  ←—  CA-1 (add @capabilities to adapters, where missing)
   ↓
PR-3 (BehaviourClosure)   ←—  CA-2 (reconcile capability liars: Bedrock/Gemini/DeepSeek)
   ↓
PR-4 (TelemetryConsumers)  ←—  CA-3 (migrate :telemetry.attach callsites to Tau.Telemetry.attach + add consumers/remove emits)
   ↓
PR-5 (NoUnreachableRescue + SpecSymbolExistence + plugin shipping)
```

CA = corrective-action PR, processed by the factory in parallel with
the gate PR that depends on it. CAs are pre-existing corrective
actions catalogued by `docs/factory-v2/corrective-actions.md` and
root §AC-F.

### Week 1 — PR-1: Substrate + manifest + umbrella runner (no decks yet)

**Deliverables:**

- `lib/tau/gate/deck.ex` (behaviour)
- `lib/tau/gate/manifest.ex` + `priv/gate/manifest.schema.json`
- `lib/tau/gate/enumeration.ex`
- `lib/tau/gate/waiver.ex` + `priv/gate/waivers.toml` (empty)
- `lib/mix/tasks/tau.gate.code.ex` (umbrella)
- `priv/gate/decks.toml` (empty `decks = {}`)
- `priv/gate/README.md`
- `.github/workflows/tau-gate-code.yml`
- Bootstrap empty-input ack: `priv/gate/manifests/_no_decks.empty.toml`
  with a 14-day expiry; the umbrella exits 0 only while this ack is
  valid AND `decks.toml` is empty. PR-2 removes the ack and adds the
  first deck; the umbrella refuses to pass if both ack and decks are
  empty after the expiry.
- Property tests for runner edge cases (missing deck → fail, empty
  inventory → fail, etc.).
- Dependency adds to `mix.exs`: `:sourceror`, `:toml_elixir`. Boundary
  and telemetry_registry deferred to PR-4.

**Dependencies:** none. Sibling
`pre-merge-evidence-and-skip-integrity` coordinated for branch-
protection registration of the new workflow.

**Exit criteria:** umbrella runs, produces valid manifest with empty
`decks`, CI workflow registered as required check. Gate is *up* but
non-blocking until PR-2.

### Week 2 — PR-2: CapabilityFidelity deck + CA-1

**Deliverables (PR-2):**

- `lib/tau/provider/capabilities.ex` (flag→callback data table)
- `lib/tau/gate/decks/capability_fidelity.ex`
- `lib/mix/tasks/tau.gate.capability_fidelity.ex`
- Update `priv/gate/decks.toml` to declare `capability_fidelity`
- Remove the bootstrap empty-ack from PR-1
- Add `gate-capability-fidelity` job to `ci.yml`; register as required
- Property + golden tests under
  `test/tau/gate/decks/capability_fidelity_test.exs` and
  `test/support/gates/capability_fidelity/{good,bad}/`

**Deliverables (CA-1, separate PR):** add `@capabilities` module
attribute to every adapter under `lib/tau/providers/` that doesn't
already export the equivalent (where the gate will key off it).

**Dependencies:** PR-1 merged. CA-1 is a parallel PR that can land
before, during, or after PR-2, but the *combination* of PR-2 + CA-1
must produce a green main; the gate red is then on the specific
liars CA-2 addresses.

**Exit criteria:** gate red on `main` shows exactly the three known
liars (DeepSeek, Bedrock, Gemini) and no others — the gate is
correctly calibrated.

### Week 3 — PR-3: BehaviourClosure deck + CA-2

**Deliverables (PR-3):**

- `lib/tau/gate/decks/behaviour_closure.ex`
- `lib/mix/tasks/tau.gate.behaviour_closure.ex`
- Update `priv/gate/decks.toml`
- Add `gate-behaviour-closure` job to `ci.yml`; register as required
- PLT caching configured in `ci.yml` keyed on `mix.lock`
- Property + golden tests

**Deliverables (CA-2):** reconcile the three known capability liars
— either implement `cache_regions/2` per adapter OR set
`prompt_caching: false` for that adapter. Same PR for all three to
keep `main` green when both gates light up. Coordinated with CA-1's
merge.

**Dependencies:** PR-1, PR-2 merged. CA-2 must land *before or
in-same-PR-as* PR-3 to keep `main` green; otherwise `main` goes red on
the first gate-red push (proposal-3 weakness: bootstrap red on initial
adoption).

**Exit criteria:** `main` green; gate red on synthetic
test fixtures only.

### Week 4 — PR-4: TelemetryConsumers deck + CA-3 + Boundary/telemetry_registry adoption

**Deliverables (PR-4):**

- `lib/tau/telemetry/attach.ex` (production-handler wrapper with
  `prod:` ID prefix)
- `lib/tau/gate/decks/telemetry_consumers.ex`
- `lib/mix/tasks/tau.gate.telemetry_consumers.ex`
- `priv/gate/telemetry.consumer_kinds.toml`
- Update `priv/gate/decks.toml`
- Add `gate-telemetry-consumers` job to `ci.yml`; register as required
- Dependency adds to `mix.exs`: `:boundary`, `:telemetry_registry`
- Property + golden tests

**Deliverables (CA-3):** migrate every production
`:telemetry.attach/4` call in `lib/` to `Tau.Telemetry.attach/4`. For
every emitted event with no production consumer, either register a
consumer (preferred, via `Tau.OtelReporter` or `Tau.Telemetry.Handler`)
or remove the `:telemetry.execute/3` call.

**Mitigation for proposal-2 weakness (CA-3 is large):** a *sunset
manifest* `priv/gate/manifests/telemetry.sunset.toml` accepts
warning-only findings for the first 21 days post-PR-4-merge; the
sunset file has a hard expiry the gate enforces. The factory uses the
window to land CA-3 incrementally; on day 22 the gate goes blocking
red on any remaining gap.

**Dependencies:** PR-1..PR-3 merged. CA-3 is the largest CA; the
sunset ramp is mandatory.

**Exit criteria:** gate green on `main` after sunset window. ~78
events without consumers (per audit) reduced to zero.

### Week 5 — PR-5: NoUnreachableRescue + SpecSymbolExistence + Claude Code plugin

**Deliverables (PR-5):**

- `lib/tau/credo/checks/no_try_rescue_across_process.ex`
- `lib/tau/credo/checks/no_catch_exit.ex`
- `lib/tau/credo/checks/no_rescue_without_justification.ex`
- `.credo.exs` updated with the three checks
- `lib/tau/gate/decks/no_unreachable_rescue.ex`
- `lib/tau/gate/decks/spec_symbol_existence.ex`
- `lib/mix/tasks/tau.gate.no_unreachable_rescue.ex`
- `lib/mix/tasks/tau.gate.spec_symbol_existence.ex`
- Update `priv/gate/decks.toml`
- Add `gate-no-unreachable-rescue` and `gate-spec-symbol-existence`
  jobs to `ci.yml`; register as required
- `priv/gate/waivers.toml` populated with the 7 known rescue sites,
  each with `remediated_by:` issue link and 90-day `expires_at:`
- Annotation migration: every legitimate rescue in `lib/tau/` gets a
  `# rescue: <Mod.fun/arity> <reason>` comment in this PR
- SPEC §4 audit: every backtick CamelCase token in
  `docs/spec/SPEC-*.md` §4 verified to resolve or to carry a
  `(not yet implemented; tracked by #NNN)` annotation
- Claude Code plugin under `plugins/tau-code-gates/`:
  - `.claude-plugin/plugin.json`
  - `commands/tau-code-gates-run.md` (slash command)
  - `hooks/pre-tool-use.json` (blocks `git commit` / `gh pr ready`)
  - `hooks/run-gates.sh`
  - `skills/interpret-findings/SKILL.md`
  - `agents/gate-doctor.md`
- `.claude-plugin/marketplace.json` updated to register the plugin
- One-shot `mix tau.gate.bootstrap.branch_protection` invocation
  to finalise all five status checks as required

**Dependencies:** PR-1..PR-4 merged. PR-5 lands last because the
annotation migration is wide-touching (~7+ rescue sites) and the SPEC
audit may surface findings that need follow-up SPEC amendments.

**Exit criteria:** all five decks green on `main`; manifest written
on every PR; plugin's `PreToolUse` hook fires locally; sibling
`pre-merge-evidence-and-skip-integrity` confirms the merge gate
consumes the manifest's `overall_verdict`.

### Post-week-5: stability hardening (not part of build-order)

- Operability sibling consumes manifest artifacts (no schema change
  needed; manifest is the contract).
- Audit-ingestion sibling translates historical findings into waivers
  with `remediated_by:` issue links (root §AC-F).
- 72-hour soak before the post-merge `main` health check considers
  the substrate stable.

## Migration sketch

The substrate lands in PR-1 with no behavioural impact (empty
`decks.toml`, bootstrap ack). PR-2..PR-5 each add one or two decks
guarded by their corrective-action PR landing first or
in-the-same-merge. The build-order's signature property: at every
intermediate state, `main` is green — either because the deck hasn't
landed yet, or because the corrective action has reconciled the known
liars. The only acceptable transient red is during CA-3's 21-day
sunset window for TelemetryConsumers, which is bounded by the sunset
manifest's expiry. After PR-5, the factory's pre-merge gate cannot
silent-skip any of the four code-shape failure classes, and a new
failure class is one new deck module + one row in `decks.toml` + one
CI job + one branch-protection update — bounded incremental cost.

## Open questions

- **SPEC §4 deferral annotation format** — proposal-4 specifies
  `(not yet implemented; tracked by #NNN)`. Should the format also
  carry a `D-NNN` invariant reference for SPECs that bind D-numbers?
  Validator should consider whether sibling
  **post-merge-cross-artifact-coherence** wants to own SPEC↔SPEC
  consistency on the same regex.
- **Sourceror cost on growth** — proposal-3 weakness: at ~500
  modules the four-deck Sourceror walks become CI-budget-sensitive.
  The solution does not include incremental mode. Should the
  validator falsify against projected codebase size?
- **Plugin schema versioning fragility** — proposal-2 weakness:
  Claude Code's plugin manifest schema is young (2026 H1). We pin to
  a specific version but renovate-style updates are not specified.
  The operability sibling may need a plugin-version-drift alert.
- **Waiver-rot cap** — proposal-1's open weakness inherited here: no
  automated cap on waiver count. The operability dashboard surfaces
  waiver count as a metric, but does not block merges on count
  alone. Should the gate fail at, e.g., >20 active waivers per
  rule_id? Out of scope for this leaf; flagged for operability sibling.
- **Boundary adoption bootstrap** — adding `use Boundary` to every
  adapter is a one-shot wide-touching change. Should this be one
  separate CA or sequenced per-adapter behind a warning-only mode?
  Proposal-2 suggests warning-only initially; the build-order defers
  Boundary adoption to PR-4 but does not commit to a specific
  per-adapter sequence.
- **Dialyzer determinism on the BehaviourClosure deck** — Dialyzer is
  occasionally non-deterministic on cross-module type inference; PLT
  cache invalidation on OTP upgrade is a known footgun. The
  build-order pins setup-beam to `.tool-versions` strictly, but a
  cold-PLT crash on the gate is still possible. Mitigation: deck's
  `tool_of_record/0` returning `:dialyxir` makes the choice
  switchable to bespoke (proposal-1's approach) if Dialyzer proves
  unreliable in CI.

## Linked sub-problems / proposals

- `proposals/proposal-1.md` — In-repo AST-checker substrate
  (`Tau.Gate.CodeShape`). **Not selected** standalone — reinvents
  what ecosystem tools already provide; rejected on root §AC-D.
  Contributions taken: the per-analyzer behaviour pattern (refactored
  into `Tau.Gate.Deck`), the `priv/gate/manifests/` waiver+expiry
  discipline (kept), the capability→callback table pattern (kept as
  `Tau.Provider.Capabilities` data module), the exit-code table
  semantics (kept on the umbrella runner).
- `proposals/proposal-2.md` — Adapt-from-ecosystem with Claude Code
  plugin wrapping. **Selected (hybrid component).** Provides the
  *engine substrate per check*: Credo for `NoUnreachableRescue`,
  Dialyxir for `BehaviourClosure`, Sourceror for the AST-side decks,
  `telemetry_registry` + ETS introspection for `TelemetryConsumers`,
  and the entire Claude Code plugin shape (`PreToolUse` hook, slash
  command, skill, agents). Satisfies root §AC-D directly.
- `proposals/proposal-3.md` — ASIC sign-off rule deck.
  **Selected (hybrid component).** Provides the *verdict protocol*:
  `Tau.Gate.Deck` behaviour, hash-stamped JSON manifest,
  `tool_of_record` field, umbrella runner enforcing
  `inputs_enumerated == inputs_processed`, and the five-layer
  silent-skip-impossibility argument. Satisfies root §AC-C and
  leaf-AC (b) at maximum depth.
- `proposals/proposal-4.md` — Five adversarial gates.
  **Selected (hybrid component).** Provides the *adversarial deck
  construction*: each of the five decks (including SpecSymbolExistence,
  the +1 beyond the leaf's four named classes) is constructed
  backwards from a grep-verified v1 failure with a named falsifier.
  Satisfies root §AC-A "exactly one mechanism per failure class" by
  construction and adds the SpecSymbolExistence deck addressing the
  code-side of failure class #1.

## Revision history

- (revision 0 — initial; hybrid of proposals 2, 3, 4 with rejected
  contributions from proposal-1)
