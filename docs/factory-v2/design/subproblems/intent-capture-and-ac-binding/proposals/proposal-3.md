---
template_version: 1
template_name: proposal
proposal_id: 3
parent_problem: ../problem.md
---

# Proposal 3: AC-binding as a sign-off Bill-of-Materials — adapt from ASIC tape-out, DO-178C, Bazel, Snakemake, and IR runbooks

## Approach

Treat each PR as a tape-out package whose central artefact is a machine-checkable
**AC Bill-of-Materials (AC-BOM)** that the factory signs off the way a regulated
hardware/software pipeline signs off a release. The AC-BOM is a single
declarative file checked into the PR (`pr-bom.yaml`) that, for every `AC-N` /
`D-NNN`, names: (i) a typed user-path target (`{kind: cli, argv: [...]}` or
`{kind: mfa, m: Tau.Session, f: set_permissions_mode, a: 2}` or
`{kind: http, route: ..., method: ...}`); (ii) the gating-test file paths and
`@tag`s; (iii) the SPEC anchor (`SPEC-PERMISSION-PROMPTS#AC-B6`); (iv) a
per-AC **mutation recipe** that names the exact call-site to neutralise. A
mandatory CI workflow — modeled on an ASIC sign-off "rule deck" — runs five
independent verifications against the AC-BOM and produces a signed
verdict file that branch protection requires; the workflow has no conditional
branches that can short-circuit (no `if:` on the deck steps, no `|| true`),
mirroring DRC/LVS sign-off in EDA. The five checks correspond to the five
"questions" a tape-out checklist asks: does the artefact exist, does it match
the spec, does it survive perturbation, is its provenance traceable, and is
the deck itself uncorrupted.

## Rationale

The complecting hypothesis on this leaf is that AC text, user-path entry, and
test entry are linked only by prose, so the test-author can satisfy the AC
form against the wrong code-path with no mechanical detector. Prior art from
heavily-gated, low-trust pipelines outside the Claude Code ecosystem solves
exactly this — the BOM concept (electronics manufacturing), the rule-deck
sign-off (ASIC), the traceability matrix (DO-178C / IEC 62304), reproducible
build-graph artefacts (Bazel / Snakemake), and the structured runbook
(incident response) — by making the deliverable a typed manifest that an
independent checker compares against the physical build. Translation: the
PR body's prose becomes a typed YAML the factory parses; the "test exercises
the user path" claim becomes a graph relation (`AC → user_path_target →
gating_test → mutation_recipe`) that mechanical checkers traverse; and the
"factory ran the gate" claim becomes a signed verdict file whose absence
fails branch protection. None of these patterns rely on agent self-report or
human review for the structurally-checkable part — they rely on the manifest
being typed and the deck being unskippable, which directly answers AC (c).

## Sketch

### Five prior-art patterns and their concrete translations

#### Pattern 1 — ASIC tape-out **sign-off rule deck** (DRC/LVS/ERC)

- **Source.** Industry-standard EDA sign-off methodology; canonical reference:
  Wayne Wolf, *Modern VLSI Design* (4th ed., 2008), ch. 4 §"Sign-off"; tool
  vendor docs (Cadence Pegasus, Mentor Calibre, Synopsys IC Validator). A
  publicly-readable open-source analogue: the KLayout DRC engine
  (https://www.klayout.de/doc/manual/drc_basic.html).
- **What it solves.** A foundry refuses to manufacture a chip unless every
  rule in the deck has been run and a green log is produced; the deck is
  versioned and signed; engineers cannot disable individual rules to pass
  sign-off. Maps directly to root §AC C (silent-skip impossibility).
- **Translation to our factory.** `Tau.Factory.AcBomGate` is a single mix
  task `mix tau.gate.ac_bom` whose body is a flat list of five checks
  (below) with no early-exit. The mix task's exit code is the deck's
  verdict. The CI step that runs it has no `if:` predicate and no
  `continue-on-error: true`. The verdict file
  (`.factory/verdicts/<sha>.json`) is signed with `sigstore cosign` (the
  open-source supply-chain signing tool — https://www.sigstore.dev/) and
  the merge-gate workflow refuses any commit whose SHA lacks a co-signed
  verdict matching the PR head SHA.
- **Rejected as inapplicable.** EDA's "waivers" mechanism, where a senior
  engineer can sign off a known-failing rule. v1 already showed this
  becomes the silent-skip vector; we adopt deck rigor without waivers.
  Time-boxed waivers live in the audit-ingestion sibling, not here.

#### Pattern 2 — DO-178C / IEC 62304 **traceability matrix** (HLR → LLR → code → test)

- **Source.** RTCA DO-178C §6.5 and §11.21 ("Trace data"); ISO/IEC 62304:2006
  §5.5 ("Software unit implementation and verification"). Practitioner
  reference: Leanna Rierson, *Developing Safety-Critical Software* (CRC
  Press, 2013), ch. 6.
- **What it solves.** Every high-level requirement must trace bidirectionally
  to a low-level requirement, to a code unit, and to a verification (test).
  The audit asks: pick any requirement and walk forward to the test; pick
  any test and walk backward to the requirement. Orphan code and orphan
  tests are findings. Maps directly to AC (a) — every AC paired with
  resolvable entry point and gating tests — and to failure class #1 (AC
  side: AC text naming non-existent symbols).
- **Translation to our factory.** The AC-BOM IS the traceability matrix.
  Schema:
  ```yaml
  # pr-bom.yaml — committed at PR root, validated by mix task
  schema_version: 1
  pr: 415
  acs:
    - id: AC-B6
      text: "/perms allow-tool grants tool capability for the session"
      spec_anchor: docs/spec/SPEC-PERMISSION-PROMPTS.md#AC-B6
      user_path:
        kind: mfa
        module: Tau.Session
        function: set_permissions_mode
        arity: 2
      gating_tests:
        - path: test/tau/session/permissions_mode_test.exs
          tag: ac_b6
      mutation_recipe:
        kind: function_no_op
        target: {m: Tau.Session, f: set_permissions_mode, a: 2}
        expectation: at_least_one_failure_in_tagged_tests
  ```
  Two new mix tasks enforce bidirectional traceability:
  `mix tau.gate.ac_bom.forward` walks AC → user_path → test (every link
  must resolve to a real symbol/file via `Code.ensure_loaded?/1` and
  `:erlang.function_exported/3`) and `mix tau.gate.ac_bom.backward` walks
  every `@tag :ac_*` test backward to an AC in the BOM (every tagged test
  must belong to exactly one AC). Orphan in either direction fails the deck.
- **Rejected as inapplicable.** DO-178C's Level-A independence requirement
  (independent verifier from a separate organisation) — we have no separate
  organisation. We get partial independence by requiring the test-author
  agent and implementer agent to be separate processes with separate
  contexts (already required by factory-loop.md phase 4b), but we do not
  fake organisational separation.

#### Pattern 3 — Bazel / Snakemake / DVC **content-addressed build graph**

- **Source.** Bazel — https://bazel.build/concepts/build-ref; Snakemake —
  Köster & Rahmann, "Snakemake — a scalable bioinformatics workflow
  engine," *Bioinformatics* 28(19):2520, 2012; DVC —
  https://dvc.org/doc/user-guide/pipelines/defining-pipelines. The
  unifying primitive: a build is a DAG of rules where each rule has typed
  inputs and outputs, every output is content-addressed, and the build
  engine refuses to declare success without proof every output was
  produced from its declared inputs.
- **What it solves.** Eliminates the "passed on my machine" / "appeared
  to pass" failure mode (failure class #7 — PRs citing local-mix evidence,
  partly owned by the evidence-and-skip-integrity sibling but the
  reproducibility primitive is shared). Maps to AC (b) (per-AC mutation
  must produce red).
- **Translation to our factory.** The AC-BOM is the rule file; the
  per-AC mutation check is a rule whose inputs are `{source tree at
  HEAD, mutation_recipe}` and whose declared output is a
  `mutation_verdict.json` of shape `{ac_id, mutated_sha, tagged_test_run_id,
  failures_observed: integer}`. The deck refuses to admit a verdict whose
  `failures_observed == 0`. Implementation uses `mix muzak` patterns
  (Doctor — https://github.com/devonestes/muzak — the leading Elixir
  mutation-testing library) for the *mechanism* of source mutation (AST
  rewriting), but driven by our `mutation_recipe` rather than muzak's
  default mutation operators. Each per-AC mutation runs in a sandboxed
  worktree (per worktree-discipline.md) with cosigned outputs.
- **Rejected as inapplicable.** Full hermetic builds (Nix-style) — Tau's
  test suite has too many Elixir-ecosystem assumptions (`mix deps`, local
  `~/.mix`) to make hermetic enforcement productive *for this leaf*; the
  evidence-and-skip-integrity sibling owns reproducibility-of-CI-itself,
  and we depend on its work for the *runner* being trusted.

#### Pattern 4 — GitHub **required status checks** with branch protection rules

- **Source.** GitHub Docs, "About protected branches" —
  https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/defining-the-mergeability-of-pull-requests/about-protected-branches.
  Canonical large-monorepo deployments: Kubernetes' tide bot
  (https://github.com/kubernetes/test-infra/tree/master/prow/cmd/tide),
  the Linux kernel's `0day` testing infra. Pattern: the merge button is
  controlled by a list of named status checks; merging is impossible
  until every named check has reported success against the *exact* head
  SHA.
- **What it solves.** Class #7 (merging PRs against red CI) becomes
  structurally impossible at the GitHub layer, not the convention layer.
  Maps to AC (c) (cannot silent-skip).
- **Translation to our factory.** Branch protection on `main` requires
  the named check `factory/ac-bom-deck` to PASS against the PR head SHA.
  The `ac-bom-deck` GitHub-Actions job runs `mix tau.gate.ac_bom` and
  uploads the cosigned verdict; the check name is configured server-side
  (not in `.github/workflows/`, which a PR could amend). A bootstrap mix
  task `mix tau.factory.branch_protection.assert` connects to the GitHub
  API and asserts the required-check set matches a constant in the
  factory code, failing CI if a previous PR has weakened protection.
- **Rejected as inapplicable.** Auto-merge bots that re-base and merge in
  the background (tide, mergify) — we want human (or coordinator) intent
  for merge timing per factory-loop.md; we only borrow the
  required-status-check primitive.

#### Pattern 5 — Incident-response **structured runbook** with verification steps

- **Source.** PagerDuty Incident Response handbook
  (https://response.pagerduty.com/), particularly the "Runbook" and
  "Postmortem" pages; the Google SRE Workbook (O'Reilly, 2018) ch. 9
  ("Incident Response"). Pattern: a runbook is a numbered list where
  each step has (a) a command to run, (b) expected output, (c) what to
  do if the output differs. The runbook is mechanically executable; an
  on-call who is half-asleep can follow it.
- **What it solves.** The PR-body field that v1 treated as prose
  ("AC-B6 advanced because…") becomes a numbered, executable runbook
  whose verification steps the deck literally runs. Maps to AC (e)
  (concrete artifacts to build — specifically the PR-body schema).
- **Translation to our factory.** The `pr-bom.yaml` is rendered into
  the PR description by a `.github/workflows/render-bom.yml` workflow on
  every push; the human-readable section shows AC, user-path, tests,
  and the mutation recipe as a "you can reproduce this locally with"
  block. The implementer/test-author agents read the schema (not the
  rendered prose) via a published JSON-Schema
  (`schemas/pr-bom.schema.json`) so their reasoning is constrained to
  the structured shape.
- **Rejected as inapplicable.** The "postmortem" half of IR runbooks
  (blameless review, action items) — handled separately by the
  knowledge-memory-and-audit-ingestion sibling.

### The five deck checks (the mix task body)

```elixir
# lib/tau/factory/ac_bom_gate.ex (sketch)
defmodule Tau.Factory.AcBomGate do
  @moduledoc """
  ASIC-tape-out-style sign-off deck for the PR's AC-BOM.

  Five independent checks, no early exit, no waivers, no silent-skip.
  Returns {:ok, verdict} only when all five pass; {:fail, [findings]}
  otherwise.
  """

  @spec run(Path.t()) :: {:ok, map()} | {:fail, [map()]}
  def run(pr_root) do
    bom = AcBom.load!(Path.join(pr_root, "pr-bom.yaml"))
    findings = []
      |> append(Check.SchemaValid.run(bom))         # Check 1: deck itself uncorrupted
      |> append(Check.SymbolsResolve.run(bom))      # Check 2: artefact exists (DO-178C forward trace)
      |> append(Check.TestsTagged.run(bom))         # Check 3: artefact matches spec (DO-178C backward trace)
      |> append(Check.PerAcMutation.run(bom))       # Check 4: survives perturbation (Snakemake/Bazel rule)
      |> append(Check.ProvenanceSigned.run(bom))    # Check 5: provenance traceable (sigstore)

    case findings do
      [] -> {:ok, render_verdict(bom)}
      list -> {:fail, list}
    end
  end

  # Each Check.X.run returns [] on pass or [finding_struct, ...] on fail.
  # There is no version that returns :skipped.
end
```

The CI workflow step is:

```yaml
# .github/workflows/ci.yml (the ac-bom-deck job)
ac-bom-deck:
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v4
    - uses: erlef/setup-beam@v1
      with: { otp-version: '27.2', elixir-version: '1.18.1' }
    - run: mix deps.get
    - run: mix tau.gate.ac_bom
    # No `if:`, no `continue-on-error`, no `|| true`. The job's exit
    # status IS the verdict. Branch protection's required check name
    # is "ac-bom-deck" (this job).
    - run: cosign sign-blob --yes .factory/verdicts/${{ github.sha }}.json > .factory/verdicts/${{ github.sha }}.sig
    - uses: actions/upload-artifact@v4
      with: { name: ac-bom-verdict, path: .factory/verdicts/ }
```

### How silent-skip is made impossible

1. **Schema-mandatory PR-BOM.** Check 1 (`SchemaValid`) fails if `pr-bom.yaml`
   is missing, syntactically invalid, or lacks any AC declared in the PR
   body's `## Acceptance criteria` section. There is no "if no BOM, skip
   gracefully" branch.
2. **Forward+backward orphan detection.** Check 2 and Check 3 together
   enforce DO-178C's bidirectional trace: no AC without a real symbol
   and tagged test, no tagged `:ac_*` test without an AC entry. Either
   orphan kind fails the deck.
3. **Per-AC mutation requires `failures_observed >= 1`.** Check 4 fails
   if mutating the AC's declared call-site does not produce ≥1 failure
   in that AC's tagged tests. A "test passes anyway" outcome is the
   classic v1 failure mode and is now the explicit failure signal.
4. **Required status check at GitHub layer.** Even if a PR amended
   `.github/workflows/ci.yml` to remove the deck, branch protection
   requires the `factory/ac-bom-deck` named check to be GREEN against
   the PR head SHA before the merge button enables. A PR with the
   workflow removed reports "missing required check" and cannot merge.
5. **Cosigned verdict file.** Check 5 fails if the verdict is not
   sigstore-cosigned by a key whose public half is committed to the
   factory's `keys/` directory. A faked-locally verdict has no
   signature; a verdict signed by a key not in the repo is rejected.
6. **No exit code besides 0 (deck PASS) or non-zero (deck FAIL).** There
   is no `:skipped`, `:not_applicable`, `:waived`, or `:warn-only` exit.
   The single binary outcome is enforced by `Tau.Factory.AcBomGate.run/1`
   returning only `{:ok, _} | {:fail, _}`.

### Reuse-vs-build decision record (AC d)

- **AST mutation mechanism.** ADOPT `muzak`
  (https://github.com/devonestes/muzak) for the source-rewriting
  primitive. Its mutation operators are not what we want, but its
  AST-rewrite-and-recompile loop is exactly the work we'd otherwise
  reinvent. Wrap with a `Tau.Factory.Mutation` module that takes our
  `mutation_recipe` and drives muzak as a library.
- **Coverage with per-test tagging.** DEFER `excoveralls`; coverage is
  not the right primitive (a covered line is not an exercised
  invariant). We use `@tag :ac_*` on ExUnit tests and grep for tags,
  not coverage percentages.
- **YAML schema validation.** ADOPT `ymlr` for serialisation
  (https://github.com/ufirstgroup/ymlr) and `ex_json_schema`
  (https://github.com/jonasschmidt/ex_json_schema) for validating
  `pr-bom.yaml` against `schemas/pr-bom.schema.json`. Reject building
  a bespoke YAML schema engine.
- **Cosign for signing.** ADOPT sigstore `cosign` as the verdict
  signer — already widely deployed in supply-chain security and free.
- **GitHub branch protection.** ADOPT the GitHub-native required-status-
  check mechanism rather than building an in-repo merge bot.
- **BUILD bespoke:** `Tau.Factory.AcBom`, `Tau.Factory.AcBomGate`, the
  five `Check.*` modules, the `pr-bom.yaml` schema, the
  `render-bom.yml` workflow, the `assert_branch_protection` bootstrap
  mix task. All have no upstream equivalent.

### Concrete artefacts to build (AC e)

- `lib/tau/factory/ac_bom.ex` — schema, loader, serializer (~200 LoC).
- `lib/tau/factory/ac_bom_gate.ex` — orchestrator returning binary verdict.
- `lib/tau/factory/check/{schema_valid,symbols_resolve,tests_tagged,per_ac_mutation,provenance_signed}.ex`
  — one module per deck check (~150 LoC each).
- `lib/tau/factory/mutation.ex` — muzak-driver wrapper for our recipes.
- `lib/mix/tasks/tau.gate.ac_bom.ex` — single CLI entry; exit 0/non-0.
- `lib/mix/tasks/tau.factory.branch_protection.assert.ex` — bootstrap
  invariant check against GitHub API.
- `schemas/pr-bom.schema.json` — JSON-Schema for the BOM.
- `.github/workflows/ci.yml` — replace existing `mix tau.gate.ac_linkage`
  step with `mix tau.gate.ac_bom`; new `render-bom.yml` workflow for the
  PR-body rendering pass.
- `.factory/verdicts/.gitkeep` — verdict directory.
- `keys/factory.pub` — committed cosign public key.
- One initial `pr-bom.yaml` example checked in, used by the deck's own
  self-test suite.

## Tradeoffs

### Strengths

- **Five-layer independence.** Each prior-art pattern targets a distinct
  v1 failure mode (rule-deck → silent-skip; trace matrix → orphan
  AC/test; build-graph → reproducibility; required-status-check → red-CI
  merging; runbook → prose-vs-structure). Their failure modes are
  uncorrelated, so the combined gate is robust to any single pattern
  being circumvented.
- **All five patterns come from contexts where the operator is presumed
  hostile or unreliable** (EDA, regulated medical/aviation, supply-chain
  signing, on-call humans, untrusted GitHub PRs from outside contributors).
  This matches root §Background — the v2 factory must not rely on
  Claude telling the truth about its own work.
- **The BOM is the test plan, the PR description, the trace matrix, and
  the mutation recipe simultaneously** — directly addressing the leaf's
  complecting hypothesis (prose and tests are linked only by prose).
- **Branch protection at the GitHub layer means the silent-skip vector
  cannot live in `ci.yml` PRs** — closing the v1 vector at `:88-100`,
  `:213-223`, `:115` permanently.
- **AC (a) (b) (c) (d) (e) all addressed concretely**, not as future
  work.

### Weaknesses

- **Five separate prior-art adaptations is a wide surface to maintain.**
  When sigstore/cosign deprecates a CLI flag, when muzak's API drifts,
  or when GitHub renames a branch-protection field, the deck must be
  updated. The hygiene cost is non-trivial and not borne by this leaf.
- **The bidirectional trace check (Check 3 — backward) requires a tag
  convention on tests** (`@tag :ac_b6`). Existing tests without tags
  are invisible to the gate; rolling out the convention across the
  existing test suite is a migration burden separate from this leaf.
  Mitigation: only NEW tests added in a PR are required to be tagged;
  legacy tests are allowlisted via a hash file.
- **The mutation check (Check 4) needs a callable `mutation_recipe`
  vocabulary** — we sketch `function_no_op` but real ACs will need
  richer recipes (`return_constant`, `swap_branches`, `delete_call_site`).
  Designing the vocabulary is non-trivial and may produce false-positive
  failures when an honest test happens to also exercise an unrelated
  path the mutation touched.
- **Cosign adds an external binary dependency to CI** — must be installed
  in the CI runner image and version-pinned. A failure to install fails
  every PR (which is the correct behaviour, but increases CI fragility).
- **Compared to proposals 1 and 2** (which presumably take more
  incremental routes — file-internal extraction or sub-state-machine
  decomposition), this proposal demands the largest one-time
  factory-engineering investment and the largest set of new
  dependencies. Its strength is breadth of coverage, its weakness is
  upfront cost.
- **GitHub-native branch protection means GitHub outages halt merging.**
  Acceptable for a factory whose merge cadence is human/coordinator-
  driven, but an explicit dependency on GitHub Enterprise SLAs.
- **Honest weakness: the "agents read the schema, not prose" claim
  depends on subagent discipline.** If an implementer agent ignores
  the schema and pattern-matches prose anyway, the structure does not
  prevent it. Mitigated by the deck not caring what the agent thought
  (the deck checks the manifest), but the test-author who writes a
  wrong-target manifest still fools the deck — that residual is owned
  by phase-4b in factory-loop.md and is not closeable here.

### Costs

- **One-time build:** ~1500 LoC Elixir (estimated) across the BOM, deck,
  five checks, mutation wrapper, two mix tasks, JSON-Schema. Plus
  ~200 lines of GitHub-Actions YAML and the bootstrap branch-protection
  PR.
- **Per-PR overhead:** authoring `pr-bom.yaml` adds ~20-60 lines of YAML
  per PR (one block per AC). The test-author agent (already required by
  factory-loop.md phase 4b) generates the YAML, so human cost is near
  zero; agent cost is one additional structured-output step.
- **CI runtime cost:** per-AC mutation runs the tagged test subset once
  per AC. For a PR with 5 ACs and 10 tagged tests each, that's 5×
  recompile-and-run-10-tests. Estimated +2-5 minutes per PR on top of
  the existing test job.
- **External dependencies added to CI:** `cosign` binary, `muzak` hex
  package, `ymlr` hex package, `ex_json_schema` hex package.
- **Knowledge cost:** the factory team must understand five prior-art
  domains at least at the "what does this gate check" level. Mitigated
  by each Check module being ~150 LoC and self-documenting.
- **Migration cost for existing tests:** allowlist hash file requires
  one PR to bootstrap (count current untagged tests, record their hashes).

## Dependencies

- The evidence-and-skip-integrity sibling owns the trusted-CI-runner
  primitive — this deck assumes the runner itself is not compromised.
  If that sibling chooses self-hosted runners or attestation-based
  runners, the cosign-key location and the deck's trust-root reference
  it.
- The knowledge-memory-and-audit-ingestion sibling owns the
  "audit-finding → AC-BOM constraint" pipeline. The deck consumes the
  audit-derived constraints as additional Check rules when that sibling
  ships.
- A first PR landing the bootstrap deck + branch-protection assertion
  must be merged with a transitional waiver (single, time-boxed, signed
  by the coordinator) before subsequent PRs are subject to the deck.
- Hex packages: `muzak`, `ymlr`, `ex_json_schema`. System package:
  `sigstore-cosign`.
- GitHub repo permissions: ability to set branch-protection rules
  programmatically (admin or "manage branch protections" scope).

## Confidence

**High** on the prior-art mapping (each of the five patterns is widely
deployed and well-documented in the cited sources). **Medium** on the
per-AC mutation-recipe vocabulary — designing a vocabulary that is
expressive enough for real ACs without producing false-positive
failures is genuine design work, and would benefit from a 2-3 PR
prototype against existing ACs (e.g. AC-B6) before broader rollout.
**Medium** on the cosign integration — solid technology but the
specifics of key custody for an agent-driven factory need a short ADR.

What would raise confidence to High overall:

- A prototype of `Tau.Factory.AcBom.load!/1` + `Check.SymbolsResolve.run/1`
  against the existing AC-B6 case from the audit (concrete falsification
  probe). Approx 2 PRs to demonstrate the orphan-detection works against
  a real v1 failure.
- A worked AC-BOM for the most recent merged PR (#414) showing the
  per-AC mutation recipes round-trip through muzak and produce expected
  red.

## Prior art / references

- **EDA sign-off (ASIC tape-out):** Wayne Wolf, *Modern VLSI Design*
  (Prentice Hall, 4th ed. 2008), ch. 4 §"Sign-off methodology"; KLayout
  DRC engine — https://www.klayout.de/doc/manual/drc_basic.html.
- **DO-178C traceability matrix:** RTCA DO-178C "Software Considerations
  in Airborne Systems and Equipment Certification" §6.5, §11.21
  (RTCA Inc., 2011); Leanna Rierson, *Developing Safety-Critical
  Software* (CRC Press, 2013), ch. 6.
- **IEC 62304 medical-device software lifecycle:** IEC 62304:2006 §5.5
  ("Software unit implementation and verification") and §5.7
  ("Software system testing").
- **Bazel build graph:** https://bazel.build/concepts/build-ref; the
  "rules" + content-addressed outputs design.
- **Snakemake workflow engine:** Köster J, Rahmann S, "Snakemake — a
  scalable bioinformatics workflow engine," *Bioinformatics*
  28(19):2520–2522, 2012, doi:10.1093/bioinformatics/bts480.
- **DVC data pipelines:** https://dvc.org/doc/user-guide/pipelines/defining-pipelines.
- **GitHub branch protection + required status checks:**
  https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/defining-the-mergeability-of-pull-requests/about-protected-branches;
  Kubernetes Prow/Tide — https://github.com/kubernetes/test-infra/tree/master/prow/cmd/tide.
- **Sigstore cosign supply-chain signing:** https://www.sigstore.dev/;
  Newman et al., "Sigstore: Software Signing for Everybody," ACM CCS
  2022.
- **PagerDuty Incident Response handbook:**
  https://response.pagerduty.com/.
- **Google SRE Workbook:** Beyer et al., O'Reilly 2018, ch. 9
  ("Incident Response").
- **Muzak (Elixir mutation testing — adopted as primitive):**
  https://github.com/devonestes/muzak.
- **ex_json_schema (PR-BOM validation):**
  https://github.com/jonasschmidt/ex_json_schema.
- **Internal cross-references:** `.claude/rules/factory-loop.md`
  §"The three mechanical gates" (the gates this proposal replaces);
  root `problem.md` §Hypothesis #6 (AC-B6 falsification probe — the
  motivating failure case); `docs/spec/SPEC-PERMISSION-PROMPTS.md` AC-B6
  (the canonical AC that must round-trip through the deck).
