---
template_version: 1
template_name: proposal
proposal_id: 2
parent_problem: ../problem.md
approach_axis: adopt-from-claude-code-ecosystem
confidence: medium
---

# Proposal 2 — Adopt swingerman/atdd as the AC↔test pipeline; bolt a thin Tau-specific compiler-tracer "per-AC mutator" onto cabbage gating tests

## Approach (one sentence)

Replace the v1 prose-PR-body AC declaration with a **Gherkin `.feature` file authored by Claude under the `swingerman/atdd` plugin's `discover-acs` + `atdd` skills**, compile each scenario to an ExUnit gating test via **`cabbage-ex/cabbage`** (Gherkin → ExUnit at compile time), validate the file's frontmatter against a JSON Schema using **`hashicorp/front-matter-schema`** in CI, and run a **thin, in-house `Tau.Gate.PerACMutator` Elixir compiler-tracer** that, for each `AC-N`-tagged scenario, locates the cited `module/fun/arity` entry-point call sites in the *compiled* tree and replaces them with `raise "AC-N user path disabled"` at compile time before running only that scenario's tests — pass = green test (silent-pass; FAIL the gate), fail = red test (the AC actually exercises the named path).

## Rationale

The leaf's complecting hypothesis names two distinct problems that the ecosystem already solves separately and well:

1. **AC↔test pipeline.** `swingerman/atdd` (MIT, 97 stars, last release v1.5.1 2026-05-22, active) was built for *exactly this failure mode* — "AI writes unit tests that pass but don't verify the right behavior" (its README's opening problem). It enforces a Given/When/Then layer plus a `spec-guardian` agent that detects implementation-detail leakage. We do not need to invent that.
2. **Gherkin-to-ExUnit compilation.** `cabbage-ex/cabbage` (MIT, 153 stars, on hex.pm 297k downloads) was built for exactly the BEAM half: compile-time translation of `.feature` files into ExUnit cases. The output *is* the gating-test path the v1 factory loop already knows how to handle.

What the ecosystem does NOT solve is the **per-AC mutation** (each AC's *specific* entry-point call site must be the thing whose absence reddens *its* test). Off-the-shelf Elixir mutation testing (`muzak`, `darwin`, `exavier`, `muex`) all do *global random* mutations across whole modules; none accept a "mutate exactly this `mod/fun/arity` call site, run exactly these scenarios" instruction. That is the in-house piece — and it is small (one tracer module + one mix task) because Elixir's compiler-tracer hook (`@compile {:tracers, [...]}`) gives us a first-class API into call-site rewriting at `:macro_expand` / `:remote_function` events.

The proposal is therefore **adopt-heavy, build-thin**: ~90% of the surface area is upstream code under MIT, with a ~150-line Tau-side gate that the audit can re-verify against the upstream's stable API.

## Sketch

### Component inventory (adopted)

| Component                              | Source                                                                       | License | Stars | Last activity   | Failure class addressed                                    |
| -------------------------------------- | ---------------------------------------------------------------------------- | ------- | ----- | --------------- | ---------------------------------------------------------- |
| `swingerman/atdd` plugin               | `https://github.com/swingerman/atdd`                                         | MIT     | 97    | 2026-05-22 v1.5.1 | #6 — Claude writes tests against wrong layer (implementation-leakage guard) |
| `cabbage-ex/cabbage`                   | `https://github.com/cabbage-ex/cabbage`                                      | MIT     | 153   | 2025-03-14      | #6 — mechanical Gherkin → ExUnit binding (no manual glue) |
| `cabbage-ex/gherkin`                   | `https://github.com/cabbage-ex/gherkin`                                      | MIT     | 16    | 2024-06-25      | Gherkin parsing for the in-house tracer's scenario-tag reader |
| `hashicorp/front-matter-schema`        | `https://github.com/hashicorp/front-matter-schema`                           | MPL-2.0 | (HashiCorp-owned action; production-grade) | active | #5 — schema-validated PR-body frontmatter; cannot silent-skip a missing AC declaration |
| `mtfoley/pr-compliance-action`         | `https://github.com/mtfoley/pr-compliance-action`                            | MIT     | (Marketplace action) | active | #5 — enforces "PR body links to an issue" + required-sections regex |
| Elixir `@compile {:tracers, [...]}`    | Built-in (`hexdocs.pm/elixir/Code.html`)                                     | Apache-2.0 | (stdlib) | stable since 1.10 | #6 — call-site-precise mutation, replacing v1's whole-module revert |

### Component inventory (in-house — explicit gaps)

| Component                                | Lines (est.) | Why bespoke                                                                                                     |
| ---------------------------------------- | ------------ | --------------------------------------------------------------------------------------------------------------- |
| `Tau.Gate.PerACMutator` (compiler tracer)| ~120         | No ecosystem mutation tool offers "mutate `mod/fun/arity` at exactly these call sites for exactly this test tag." |
| `mix tau.gate.ac_binding`                | ~80          | CLI wrapper: parse `.feature`, drive tracer, run scoped `mix test`, assert red.                                 |
| `feature.schema.json`                    | ~40 lines JSON | Tau-specific shape constraints (AC-N, D-NNN, `entrypoint:` MFA, `gating_test:` path).                          |
| `.github/workflows/ac-binding.yml` step  | ~30          | Wires the two upstream actions + the in-house mix task into the existing `lint` job.                            |

### Per-AC `.feature` shape (the AC declaration *is* the test plan)

```gherkin
---
ac: AC-B6
issue: "#341"
spec: docs/spec/SPEC-PERMISSION-PROMPTS.md
entrypoint:
  mfa: "Tau.Session.set_permissions_mode/2"
gating_test: test/tau/session/permissions_mode_test.exs
---
Feature: AC-B6 — set_permissions_mode/2 honours user verdict
  @ac:AC-B6 @entrypoint:Tau.Session.set_permissions_mode/2
  Scenario: Operator selects "always allow" for Bash
    Given a session in :awaiting_permission for a Bash tool call
    When the operator decides :always_allow via Tau.Session.set_permissions_mode/2
    Then the session FSM transitions to :running
    And the verdict persists for subsequent matching tool calls in the session
```

Frontmatter is validated by `hashicorp/front-matter-schema` against:

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "required": ["ac", "issue", "entrypoint", "gating_test"],
  "properties": {
    "ac": { "pattern": "^(AC-[A-Z0-9]+|D-[0-9]{3})$" },
    "issue": { "pattern": "^#[0-9]+$" },
    "spec": { "pattern": "^docs/spec/SPEC-[A-Z0-9-]+\\.md$" },
    "entrypoint": {
      "type": "object",
      "required": ["mfa"],
      "properties": { "mfa": { "pattern": "^[A-Z][A-Za-z0-9_.]+(\\.[a-z_][A-Za-z0-9_!?]*)/[0-9]+$" } }
    },
    "gating_test": { "pattern": "^test/.+\\.exs$" }
  }
}
```

### `Tau.Gate.PerACMutator` (sketch — Elixir compiler tracer)

```elixir
defmodule Tau.Gate.PerACMutator do
  @moduledoc """
  Compile-time mutator. For a given `{module, function, arity}` MFA cited in a
  Gherkin scenario's `@entrypoint:` tag, rewrites all call sites in the
  recompiled tree to `raise "AC-#{ac} user path disabled"`. The companion mix
  task then runs ONLY the scenario's gating test and asserts it goes red. If
  it stays green, the test does not exercise the cited entry-point — gate fails.
  """

  @behaviour :elixir_compiler_tracer  # conceptual; uses the documented :tracers contract

  # Receives every macro-expanded remote call. We match the target MFA and
  # ask the compiler to substitute the AST.
  def trace({:remote_function, _meta, mod, fun, arity}, env) do
    case Process.get(:tau_per_ac_target) do
      {^mod, ^fun, ^arity, ac} -> rewrite!(env, ac)
      _ -> :ok
    end
  end

  def trace(_event, _env), do: :ok

  defp rewrite!(env, ac) do
    # Records the rewrite intent for the per-file transformer pass; the
    # accompanying compiler pass replaces the matched node with:
    #   raise "AC-#{ac} entry point disabled by Tau.Gate.PerACMutator"
    send(self(), {:tau_mutator_hit, env.file, env.line, ac})
    :ok
  end
end

defmodule Mix.Tasks.Tau.Gate.AcBinding do
  use Mix.Task
  @shortdoc "Per-AC mutation gate (Gate 5.3-prime)"

  @impl Mix.Task
  def run(_argv) do
    features = Path.wildcard("test/features/**/*.feature")
    Enum.each(features, &check_feature/1)
  end

  defp check_feature(path) do
    %{frontmatter: fm, scenarios: scenarios} = Tau.Gate.FeatureLoader.load!(path)
    Enum.each(scenarios, fn scenario ->
      ac    = Map.fetch!(scenario.tags, :ac)
      mfa   = parse_mfa!(fm["entrypoint"]["mfa"])
      gtest = fm["gating_test"]

      Process.put(:tau_per_ac_target, Tuple.append(mfa, ac))
      Code.put_compiler_option(:tracers, [Tau.Gate.PerACMutator])

      with :ok          <- recompile_project(),
           {:ok, result} <- run_one_test(gtest, ac) do
        case result do
          %{failures: f} when f >= 1 -> :ok                            # AC really exercises the path
          %{failures: 0}             -> halt!("AC #{ac}: test did not redden when #{inspect mfa} was disabled")
        end
      end
    end)
  end
end
```

### CI wiring (extends the existing `lint` job)

```yaml
      - name: Validate AC frontmatter schema
        uses: hashicorp/front-matter-schema@main
        with:
          files: test/features/**/*.feature
          schema: ${{ toJSON(fromJSON(env.AC_FRONTMATTER_SCHEMA)) }}

      - name: Enforce PR-body issue link + required sections
        uses: mtfoley/pr-compliance-action@v0.6
        with:
          ignoreTeamMembers: false
          ignoreAuthors: ''
          bodyRegexComment: 'Missing required sections; see PR template.'
          bodyRegexFlags: 'gi'
          bodyAutoClose: false

      - name: Gate 5.3-prime — per-AC binding mutator
        run: mix tau.gate.ac_binding
```

### Silent-skip impossibility

Three layers, each fail-loud:

1. **PR-body layer:** `mtfoley/pr-compliance-action` fails CI if the PR body omits the `Closes #N` / required-sections fences. v1's "missing field = pass" behaviour is impossible because the action exits non-zero on missing match.
2. **Feature-file layer:** `hashicorp/front-matter-schema` fails CI on a missing `ac:` / `entrypoint:` / `gating_test:` key — the schema is `required`. A `.feature` file without frontmatter is rejected by the schema action's "no files matched" path (configurable to fail-on-empty).
3. **Mutator layer:** `mix tau.gate.ac_binding` enumerates `test/features/**/*.feature`; for every scenario it MUST (a) parse the entrypoint MFA, (b) locate ≥1 call site in the recompiled tree (zero call sites → fail with `:entrypoint_unreachable`), (c) observe ≥1 red test in the scoped run (zero failures → fail with `:gate_silent_pass`). Each of (a)/(b)/(c) is a fail, not a skip; the task has no early-exit branch.

The contrast with v1: `ci.yml:88-100` checks "if no gating-test paths declared, exit 0." Under this proposal there are no per-PR declared paths to be absent — the path *is* the `gating_test:` frontmatter field, and the file's existence is what the schema action checks. No PR body = no `.feature` files in the diff = the `mix tau.gate.ac_binding` task iterates the diff and asserts ≥1 `.feature` per claimed `AC-N` in the PR body (this last lookup uses the PR-body-issue-link side of `mtfoley/pr-compliance-action`'s parsed output).

### Configuration / adaptation per adopted component

- **`swingerman/atdd`**: install via `claude plugins install swingerman/atdd@v1.5.1`. Configure `engineer.config.yml` so its `pipeline-builder` agent targets `language: elixir, framework: cabbage` (the plugin's pipeline templates already support pluggable test-framework targets via its parser→IR→generator triad — that's exactly the seam needed). Disable the agent's bespoke parser (`dae_gherkin.py`) for Elixir-output mode; emit `.feature` files instead of Python tests.
- **`cabbage-ex/cabbage`**: add `{:cabbage, "~> 0.4"}` to `mix.exs` `test`-only deps. Cabbage compiles `test/features/*.feature` to ExUnit cases at compile time, producing test names that include the scenario name — which the `@ac:` tag policy can map deterministically.
- **`cabbage-ex/gherkin`**: pulled in transitively; the in-house tracer uses its parser directly to read `@ac:` / `@entrypoint:` scenario tags (the same tags Cabbage uses to generate `@tag` macros on the ExUnit case).
- **`hashicorp/front-matter-schema`**: action ref `hashicorp/front-matter-schema@main`. Schema lives at `.github/schemas/feature-frontmatter.json`. The action's `files` input is set to `test/features/**/*.feature`.
- **`mtfoley/pr-compliance-action`**: action ref `mtfoley/pr-compliance-action@v0.6`. Configure `ignoreTeamMembers: false` (the factory is the author), regex enforces `^Closes #\d+` and a `## Acceptance criteria` section header.
- **Elixir `:tracers`**: enabled per-mix-task invocation only (`Code.put_compiler_option(:tracers, [Tau.Gate.PerACMutator])`); not added to project-wide compiler options to keep normal `mix compile` untouched.

## Tradeoffs

### Strengths

- **Adoption ratio favourable.** Five upstream components (one Claude plugin + 16 skills + 3 agents from `swingerman/atdd`; two BEAM libraries from `cabbage-ex`; two GitHub Actions; stdlib tracer hook) carry the bulk; in-house surface is one tracer + one mix task + one JSON schema (≤ ~300 LOC + 40 LOC schema). The audit re-verification target is small.
- **`swingerman/atdd` is purpose-built for the exact v1 failure mode.** Its `spec-guardian` agent's stated job is to detect implementation-detail leakage in Given/When/Then — i.e. catch "this test was written against a struct, not the user path" *before* the test is written. v1 had nothing analogous.
- **Cabbage compile-time generation cuts an entire failure surface.** No manual glue between Gherkin and ExUnit means "the test that runs is provably derived from the AC text" — no test-author free hand to short-circuit to a private helper.
- **Per-AC compiler-tracer mutation is strictly stronger than v1's Gate 5.3.** v1 reverts *every non-test path* to merge-base and asserts ≥1 failure anywhere in the suite; an under-asserting test fails for any reason (compile error, unrelated rev) and the gate believes the AC is exercised. Per-AC mutation fails only when the named call site goes away — false-green is mechanically impossible for the AC's own entry point.
- **No silent-skip surface anywhere.** The three-layer fail-loud structure above closes failure class #5 *for this leaf's gates* by construction.
- **Aligns with `docs/factory-v2/design/problem.md` §D ("Ecosystem reuse over reinvention").** Bespoke surface is explicitly justified and minimal.

### Weaknesses

- **`swingerman/atdd` is Python-primary (99% Python in the repo).** Its `pipeline-builder` ships pipelines for pytest / Jest / JUnit / Go-test / RSpec. Elixir/Cabbage is **not** an out-of-the-box target. We must configure the plugin's pipeline-generation prompts to emit `.feature` files only (skipping its Python test generator) and rely on Cabbage downstream. This is straightforward but is *not* the well-trodden path; the first AC will surface adaptation cost.
- **Cabbage's last release on Hex was 0.4.1 (2023-09-18); upstream commits to 2025-03.** The package works but is in maintenance mode. If it falls behind Elixir 1.20+ macros, we inherit a maintenance burden. Mitigation: fork-and-pin at a known-good SHA; the API is small.
- **Compiler-tracer mutation is sound only if the test runs against freshly-recompiled code.** Stale `_build` artefacts make the mutator a no-op. We must invoke `mix compile --force` inside `mix tau.gate.ac_binding` for the duration of each scenario. Slower CI (~20-40s per AC). Acceptable, but worth measuring under a real PR with 5+ ACs before locking in.
- **`hashicorp/front-matter-schema` is HashiCorp-owned and not particularly popular.** No star metric appears publicly. Risk: action goes stale. Mitigation: small wrapper script (~15 LOC) over Python's `jsonschema` could replace it. Document this fallback in `.claude/rules/factory-loop.md` so the dependency is replaceable.
- **Gherkin-as-AC has a learning-curve cost for the implementer agent.** The agent currently writes prose ACs in PR bodies. Switching to a structured `.feature` per AC is a behavioural change for *every* PR in the factory, not just gated ones; the `implementer.md` persona prompt must be updated. Risk: agent regression on the first few PRs.
- **MFA-precision mutation cannot cover ACs whose "user path" is structural (e.g. "the supervision tree restarts X within Y ms") rather than a single call site.** For those, fall back to v1-style global mutation under a `gate_type: structural` frontmatter override — but this *re-opens* the silent-pass hole for that subset. We must enumerate which ACs are structural and accept the residual risk.
- **Two BDD framework dependencies (Cabbage and the upstream Gherkin parser) plus a Python-primary plugin add three new dep-update vectors.** Higher supply-chain surface than a single bespoke Mix task would have.

### Costs

- **Initial: ~3-5 PR-days.** (1) Install + configure `swingerman/atdd` for Elixir target, (2) add `cabbage` + first `test/features/` directory with a representative AC, (3) write the tracer + mix task + JSON schema, (4) wire the four CI steps, (5) update `implementer.md` and `factory-loop.md` to teach the new flow.
- **Ongoing per-PR: +1-3 min CI** (mostly `mix compile --force` per AC scenario) and **+5-15 min agent time** (Gherkin authoring under `atdd` skills).
- **Dependency monitoring:** Cabbage / Gherkin / atdd / front-matter-schema / pr-compliance-action — five upstreams to track. `dependabot` covers Hex and Actions; the Claude plugin needs manual version-pinning in `.claude/plugins/`.

## Dependencies

- **Sibling-leaf coupling:** `pre-merge-evidence-and-skip-integrity` owns the *gate execution substrate*; this proposal asserts that the schema action + tracer-task have no silent-skip surface, but the *enforcement* that CI must be the evidence source (not local mix output) is its sibling's problem. The two leaves must agree the schema action runs on PR events with `if:` predicate set to *always-true-when-applicable* (no `github.event_name == 'push'` exclusion that lets push-bypass land).
- **`knowledge-memory-and-audit-ingestion`:** if an audit finding implies a new AC-binding constraint (e.g. "ACs whose entrypoint is in `lib/tau/session.ex` MUST also cite a property test"), the audit registry must feed `feature.schema.json` extensions at PR time. The schema is the integration seam.
- **Tau project state:** Cabbage requires Elixir ≥ 1.13; we're on 1.18. Compatible. ExUnit ≥ 1.10. Compatible.

## Confidence

**Medium.** High confidence that the upstream components exist and address the failure mode they claim to. Medium-not-high because (a) `swingerman/atdd` has not been deployed against an Elixir codebase at the public scale — we are the first non-Python user we have evidence of; (b) the compiler-tracer mutator depends on the `:macro_expand` / `:remote_function` events firing during recompile in a way that's not unit-tested by Elixir core for this use case (the documented use case is `xref`-style observation, not rewriting); a prototype is necessary before committing.

## Prior art

- **`swingerman/atdd`** (Claude Code plugin) — `https://github.com/swingerman/atdd` — README opening problem statement: "AI writes code without constraints — without acceptance tests anchoring behavior, AI can 'willy-nilly plop code around' and write unit tests that pass but don't verify the right behavior." This is the v1 failure verbatim.
- **`cabbage-ex/cabbage`** — `https://github.com/cabbage-ex/cabbage` — production BEAM Gherkin runner; 297k Hex downloads validates real-world stability.
- **`mtfoley/pr-compliance-action`** — `https://github.com/marketplace/actions/pr-compliance-action` — already adopted-by-default in many enterprise GitHub orgs for the exact "PR must link to an issue, must have these sections" enforcement.
- **`hashicorp/front-matter-schema`** — `https://github.com/hashicorp/front-matter-schema` — HashiCorp's own internal-doc gating uses this; the JSON-Schema-over-frontmatter pattern is the same one GitHub Docs uses (`lib/frontmatter.ts` in their docs repo).
- **Elixir compiler tracers** — Elixir 1.10+ `@compile {:tracers, [...]}` documented at `https://hexdocs.pm/elixir/Code.html`; AppSignal's 2020 walkthrough `https://blog.appsignal.com/2020/03/10/building-compile-time-tools-with-elixir-compiler-tracing-features.html` confirms the public-API stability and gives the reference shape for the in-house tracer.
- **Existing factory-loop machinery in Tau** — `mix tau.gate.ac_linkage` / `mix tau.gate.masking` / `mix tau.gate.mutation` in `.github/workflows/ci.yml` already prove the "in-house mix task as a CI gate" pattern works. This proposal generalises that pattern by replacing the *content* (prose AC) with a *machine-readable* `.feature` file.

## Build-order (favours adopt-over-build)

The build-order is **strictly adopt → adopt → adopt → adopt → adapt → build → wire**, surfacing risk early and only committing to in-house code after each upstream's fit is proven.

1. **Install `swingerman/atdd` plugin** (1 PR-hour). Verify on a throwaway feature whether its `discover-acs` skill produces sensible Gherkin for a Tau-shaped AC (e.g. AC-B6 rewritten). **Halt criterion:** if the plugin's Elixir-target adaptation costs > 1 PR-day, fall back to authoring `.feature` files directly via the implementer persona (drop `swingerman/atdd`; keep cabbage + tracer). This is the riskiest adoption.
2. **Add `cabbage-ex/cabbage` dep + author one hand-written `.feature`** (1 PR-hour). Verify cabbage compiles it to a runnable ExUnit test. **Halt criterion:** if cabbage breaks against Elixir 1.18.1, fork at a known-good SHA before continuing.
3. **Add `hashicorp/front-matter-schema` CI step + `feature.schema.json`** (30 min). Validates the AC-frontmatter shape end-to-end on a real PR.
4. **Add `mtfoley/pr-compliance-action` CI step** (30 min). Closes the "PR body lacks `Closes #N`" silent-skip path for this leaf (the rest is `pre-merge-evidence-and-skip-integrity` sibling territory).
5. **Adapt `swingerman/atdd` `pipeline-builder` to emit `.feature` files for Elixir** (~1 PR-day). The plugin's IR is intended to be language-pluggable; this is the proof that adoption holds at adapter level.
6. **Build `Tau.Gate.PerACMutator` + `mix tau.gate.ac_binding`** (~2 PR-days). This is the *only* materially-bespoke surface. Validate against the first hand-written `.feature` from step 2: deleting the entrypoint MFA's body MUST redden the test; reverting that MUST green it.
7. **Wire the `mix tau.gate.ac_binding` step into `.github/workflows/ci.yml`'s `lint` job** (1 PR-hour). Reuse the existing PR-body extraction and exit-code handling from the v1 gates.
8. **Update `.claude/agents/implementer.md` + `.claude/rules/factory-loop.md`** (~1 PR-hour). Replace v1 "Gating-test paths" PR-body section with "Feature files (one per AC)" pointing to `test/features/<issue>/<ac>.feature`. The factory-loop refine bound, freshness re-check, post-merge `main` health check all remain unchanged.

**Total estimated bespoke surface:** ≤ 300 LOC of Elixir + 40 LOC of JSON schema + ~80 LOC of YAML wiring. **Total adoption surface:** entire `swingerman/atdd` plugin (~2k LOC Python + 16 skills + 3 agents) + `cabbage` (~1k LOC Elixir) + two GitHub Actions (HashiCorp + mtfoley, both maintained externally). Adoption-to-bespoke ratio ≈ 10:1.
