---
template_version: 1
template_name: proposal
proposal_id: 4
parent_problem: ../problem.md
---

# Proposal 4: Adversarial main-side coherence — construct the joint-state failure, then build the trap for it

## Approach

Treat the coherence check not as a "lint the spec" task but as a property
suite whose properties are derived **adversarially from constructed
failures**: for each failure pattern that v1 demonstrably tolerated, write
the smallest two-PR (or single-edit) construction that produces the bad
joint state, then build the `main`-side check whose contract is "this exact
joint state is impossible to reach without the check tripping." The check
runs on every push to `main` and on a 24h cadence; on failure it opens a
GitHub issue auto-milestoned to the current focus milestone, writes a
machine-readable verdict to `.factory/coherence-verdicts/<sha>.json` that
the operability-sibling dashboard consumes, and CANNOT silent-skip — an
empty input set returns `"0 applicable, checked"` as a structured verdict
distinguishable from `"infrastructure failure"` (which itself fails the
workflow and opens an issue). The check suite lives as a Mix umbrella sub-
project `apps/tau_coherence/` consumed by `.github/workflows/main-
coherence.yml`, with one Mix task per failure construction so each can be
re-run in isolation by the dashboard or by a developer triaging the issue
the suite filed.

## Rationale

The complecting hypothesis is that *joint state* across artifacts is
invisible to *per-diff* gates: two PRs each gate-green can land a
contradictory `main`. The decomplecting move is to give joint-state its
own oracle that runs on the joint state itself (the post-merge tree),
keyed by failure constructions rather than by abstract "things that
should be true." Adversarial derivation prevents the design-error mode
where the check enumerates only failures the author imagined: every
property in the suite traces to a *constructed* failure that was either
observed in v1 (#9, the B5/D-171 case) or that we prove can occur from
two individually-valid PRs. Failure constructions also serve as the
suite's own regression tests — the check itself has a test that
asserts the constructed bad joint-state triggers it — which closes the
"check that never fires because the bug it was written for can no
longer be constructed" failure mode silently inherited from v1.

## Sketch

### Failure constructions (the contract of the suite)

Each construction is an *exact* recipe — a sequence of git operations
on a fixture repo producing the bad joint state on `main`. Each is
stored under `apps/tau_coherence/test/constructions/<id>/` as a
shell script that produces the fixture and a property test that
asserts the corresponding check trips on it.

**C1. Cross-PR gate-relocate vs SPEC-update split.**
- PR-A moves `Mix.Tasks.Tau.Gate.AcLinkage` from `lib/mix/tasks/` to
  `apps/tau_factory/lib/mix/tasks/`. Per-PR gate-existence check
  passes (the module still exists, just at a new path).
- PR-B (parallel, before A merges) updates SPEC-FACTORY-GATES §4
  "the gate module is `Mix.Tasks.Tau.Gate.AcLinkage` and lives at
  `lib/mix/tasks/tau/gate/ac_linkage.ex`". Per-PR SPEC-vs-code check
  on PR-B passes against PR-B's base.
- Joint state on `main` after both merge: SPEC §4 names a path
  that no longer exists. Per-PR gates cannot catch this.
- **Catching mechanism:** `Mix.Tasks.Tau.Coherence.SpecPathResolve`
  parses every SPEC §4 path citation (regex over `lib/**/*.ex`
  + heredoc-style fences) and asserts `File.exists?/1` on each, with
  AST resolution of every named module via `Code.ensure_loaded?/1`
  after compile. Verdict: `:ok | {:error, [{spec, path_or_module,
  reason}, ...]}`.

**C2. Cumulative `rescue` count monotonically rising despite per-PR
"-1 rescue site" budget.**
- Audit baseline: 7 flagged `rescue` sites at SHA `S0` (root #10).
- PR-X removes one flagged rescue → audit budget says +1, count
  goes 7→6. Per-PR check passes.
- PR-Y, days later, in unrelated code, adds two new `rescue` clauses
  that were not in the audit's flagged set; the per-PR check has no
  comparison baseline because the audit ingestion sibling only checks
  the *flagged* set. Count goes 6→8.
- Joint state on `main`: total `rescue` count exceeds baseline despite
  every PR being "improving."
- **Catching mechanism:**
  `Mix.Tasks.Tau.Coherence.RescueLedger` counts every `rescue` / `catch
  :exit` site in `lib/` via `Sourceror.parse_string!` AST traversal,
  classifies each as `:legitimate | :under_waiver | :unknown` using
  `.factory/rescue-waivers.yml` (one waiver entry per legitimate site,
  with expiry date), and asserts `count(:unknown) == 0 AND
  count(total) <= ledger_baseline + sum(delta) on `main` history`. The
  ledger publishes a *direction-of-travel* invariant (monotone non-
  increasing modulo explicit waiver additions) that no single PR can
  satisfy or break alone.

**C3. Telemetry consumer ratio dropping cumulatively (64.9% orphans
today → 70% next month).**
- PR-P emits a new `[:tau, :foo, :start]` event with a consumer in
  `lib/tau/telemetry/handlers/foo.ex`. Per-PR consumer-presence check
  passes.
- PR-Q, two weeks later, deletes the handler module (the team that
  owned it pivoted) but does not delete the emission. Per-PR check on
  PR-Q sees a deletion of a handler — but emission sites are in *other*
  files, untouched by the diff, so the per-PR check is scoped only to
  the diff and approves.
- Joint state on `main`: emission with no consumer; the 64.9% orphan
  ratio creeps to 65.x%, then 66%, etc., undetected.
- **Catching mechanism:** `Mix.Tasks.Tau.Coherence.TelemetryConsumers`
  enumerates every `:telemetry.execute/3` site (grep+AST) and every
  `:telemetry.attach*/4` site, and asserts that for every distinct
  event-name prefix emitted, at least one non-test, non-`:debug`-only
  attach exists in compiled `lib/`. The check also publishes the ratio
  `consumed / emitted` as a telemetry event itself
  (`[:tau, :coherence, :telemetry_ratio]`) that the dashboard plots;
  the workflow **fails** the push when ratio drops below a recorded
  baseline in `.factory/telemetry-baseline.json` (so the only way for
  the ratio to drop is an explicit baseline-lowering commit, which
  must be reviewed).

**C4. SPEC drift from individually-valid PR edits (the B5/D-171
construction generalised).**
- SPEC-PERMISSION-PROMPTS §4 B5 says "6 modes" at SHA `S1`. PR-M
  amends §6 D-171 to say "3 modes" because the runtime now has 3
  active modes; the PR-M reviewer checks §6 internally and approves.
- The §4 B5 prose was untouched. Joint state on `main`: §4 says 6,
  §6 says 3, both inside the same document.
- This generalises to *every* SPEC §4 vs §6 numeric / list claim:
  named modes, named states, named callbacks, named events, named
  D-NNN counts.
- **Catching mechanism:**
  `Mix.Tasks.Tau.Coherence.SpecInternalConsistency` extracts
  structured claims from each SPEC via a per-SPEC sidecar YAML
  manifest `docs/spec/SPEC-FOO.coherence.yml` of the form

      claims:
        modes: { in_section_4: 6, in_section_6: 3, expected: equal }
        callbacks: { in_section_4: [a, b], in_dnnn: [a, b], expected: equal }

  and asserts each `expected: equal` constraint holds. The SPEC's
  authoring template includes the sidecar with a single
  `claims: { dummy: { expected: trivially_true } }` entry so the
  manifest is *always present* — its absence on a SPEC file fails
  the suite immediately. (This is how it cannot silent-skip on
  "no SPEC has a sidecar yet": the absence is the first finding.)
  For the v1 B5/D-171 case, the manifest entry would be the
  single-line claim `modes: { in_section_4: 6, in_dnnn_171: 3,
  expected: equal }` and the suite would fail on first run with the
  exact citation.

**C5. `main` going red and staying red between merges.**
- PR-R lands with the per-PR gate green at SHA `S_R`. The merge
  causes a transitive compile warning in unrelated code (an `import`
  now ambiguous because of a module the same PR introduced); CI on
  the post-merge `main` push is red.
- The factory loop's `cycle step 8d` is supposed to halt the loop,
  but in v1 four PRs (#411-#414) merged against a red CI anyway
  (root #7).
- **Catching mechanism:**
  `Mix.Tasks.Tau.Coherence.MainHealth` consumes the GitHub Checks
  API for SHA = `git rev-parse origin/main`, asserts every required
  check is `success`, and on failure (a) opens an issue, (b)
  writes a sentinel file `.factory/STOP-FACTORY-MAIN-RED` (the
  factory loop's start-of-step check already halts on this sentinel
  per `factory-loop.md`), and (c) refuses to clear the sentinel
  until a subsequent green `main` is observed. This converts "main is
  red" from a transient state any subsequent merge can paper over
  into a sticky operator-visible condition.

### Generalisation

The construction set is **extensible by construction**: any future
joint-state failure pattern surfaces as a new directory under
`apps/tau_coherence/test/constructions/<id>/` with (a) a fixture
script, (b) a property test asserting "construction triggers
check," (c) a new or extended Mix task implementing the check. The
suite refuses to release with an unwired construction: the umbrella
project's `mix test` target enumerates construction directories and
fails if any lacks a matching task in
`apps/tau_coherence/lib/mix/tasks/`. This closes the "we wrote the
problem statement but never built the check" failure mode.

The generalised contract for an entry in the suite:

    construction_id: string                  # e.g. "C1"
    failure_class_addressed: [ "#1", "#9" ]  # from root §Hypothesis
    fixture_script: path                     # produces the bad joint state
    check_task: atom                         # Mix.Tasks.Tau.Coherence.*
    sidecar_inputs: [ path, ... ]            # YAML manifests it consumes
    expected_verdict_on_fixture: :error
    expected_verdict_on_clean: :ok

The umbrella's `test` task asserts every construction's check task
returns `:error` on its fixture and `:ok` on a clean checkout. A new
failure pattern surfaces in v1.x → C-N is added → check task is added
→ regression test added → suite gains coverage permanently.

### Silent-skip impossibility

Every failure mode for "the check didn't run / passed vacuously" is
itself a failure construction:

- **No SPEC sidecar present (C4 vacuous):** the workflow asserts every
  `docs/spec/SPEC-*.md` has a sibling `*.coherence.yml`; absence is a
  first-class failure with a named SPEC.
- **No `.factory/rescue-waivers.yml` present (C2 vacuous):** absence
  fails the workflow (the audit-ingestion sibling produces it; if
  that sibling has not run, this sibling halts and demands it).
- **No telemetry baseline file (C3 vacuous):** absence fails the
  workflow on first run; the workflow's `--initialize` mode (one-time)
  writes the baseline from the current `main` and commits a PR for
  human review, but the *check* on subsequent pushes fails without
  the baseline.
- **GitHub Checks API unreachable (C5 vacuous):** the workflow
  retries with backoff up to 5 minutes; on persistent failure it
  fails the workflow with exit code 2 (distinct from "found drift,"
  exit 1, and "all clean," exit 0) and opens an issue tagged
  `infra/coherence-unreachable`.
- **Empty SPEC catalog (suite vacuous):** the workflow writes
  `{ "verdict": "0_applicable_checked", "spec_count": 0,
  "construction_count": N }` and exits 0; but the dashboard's
  health card surfaces `spec_count == 0` as a warning, so a regression
  that empties the catalog is visible. This is the *only* legitimate
  vacuous outcome and it is structurally distinguishable from "didn't
  run."

The workflow's exit code is mechanically meaningful:
`0 = checked, no findings (including legitimate vacuous)`,
`1 = checked, findings present (issue filed)`,
`2 = could not check (infrastructure)`. A check that returns no exit
code is itself a failure pattern: the workflow's outer wrapper asserts
a non-empty verdict file at `.factory/coherence-verdicts/<sha>.json`
before exiting; absence triggers exit 2.

### Concrete artifacts

- `.github/workflows/main-coherence.yml` — runs on `push: branches:
  [main]` and on `schedule: cron: '0 6 * * *'`. Jobs: `c1_spec_paths`,
  `c2_rescue_ledger`, `c3_telemetry_consumers`, `c4_spec_internal`,
  `c5_main_health`, `verdict_emit`, `issue_open_on_failure`. No
  `|| true`; no `continue-on-error`; every job's failure fails the
  workflow.
- `apps/tau_coherence/lib/mix/tasks/tau/coherence/{spec_path_resolve,
  rescue_ledger, telemetry_consumers, spec_internal_consistency,
  main_health}.ex` — one Mix task per check.
- `apps/tau_coherence/lib/tau/coherence/verdict.ex` — `Verdict` struct
  + JSON encoder for `.factory/coherence-verdicts/<sha>.json`.
- `apps/tau_coherence/test/constructions/c{1..5}/` — fixture scripts
  and property tests.
- `docs/spec/*.coherence.yml` — per-SPEC structured claims sidecars.
- `.factory/rescue-waivers.yml` — populated by audit-ingestion sibling.
- `.factory/telemetry-baseline.json` — `consumed/emitted` ratio
  baseline.
- `.factory/STOP-FACTORY-MAIN-RED` — sentinel touched by C5 on
  red-main detection, consumed by `factory-loop.md` start-of-step
  check.

## Tradeoffs

### Strengths

- **Anchored to constructed failures, not imagined ones.** Every check
  has a fixture that triggers it; the suite has a regression test for
  the existence of its own findings, closing the "check that never
  fires" failure mode v1 displayed at scale.
- **Cross-PR joint state is the explicit unit of analysis.** C1, C3,
  C4 are all unreachable from per-diff gates by construction; this
  sibling owns exactly that surface.
- **Direction-of-travel invariants** (C2 monotonic `rescue` count,
  C3 consumer ratio) prevent the "boil the frog" failure mode where
  no single PR is bad but the trajectory is.
- **Silent-skip impossibility is itself property-tested.** Every
  vacuous-outcome path is a construction with an expected verdict;
  the suite asserts `:ok` on clean and the specific vacuous-outcome
  string on the no-input case.
- **Operability sibling integration is just file-emission**
  (`.factory/coherence-verdicts/<sha>.json`); no synchronous coupling.
- **Acceptance criteria (a)-(e) all addressed concretely:** workflow
  file named; mix task names enumerated; manifest format defined;
  issue-opener Action named; reuse-vs-build documented (Sourceror
  reused, sidecar manifest format bespoke and justified by SPEC
  structural-claim shape that no off-the-shelf linter knows).

### Weaknesses

- **Per-SPEC sidecar authorship burden.** Every SPEC gains a
  `*.coherence.yml`; authors must list structural claims they want
  cross-checked. Adoption rests on culture *and* on the suite refusing
  to pass when a SPEC lacks a sidecar — the latter creates friction
  on legitimate fast-path doc edits.
- **Construction maintenance burden.** Each new failure mode requires
  three artifacts (fixture, property test, check task) before the
  suite can be augmented. This is a feature for rigour, a cost for
  velocity.
- **`rescue` ledger waiver list can be gamed** by adding a waiver
  entry rather than removing the `rescue` — the waiver review becomes
  the real gate, and there is no automated check that a waiver is
  *justified*, only that it is *present*. (The pre-merge code-gates
  sibling owns the per-PR rescue check; this sibling owns only the
  cumulative count, so the gaming surface is bounded but real.)
- **Sentinel-file coupling to factory-loop.md** (C5 writes
  `.factory/STOP-FACTORY-MAIN-RED`) creates a cross-leaf dependency.
  If the loop changes its sentinel-check semantics, this sibling's
  C5 effect changes silently. Document the contract in
  `factory-loop.md`'s "kill switch" section as a co-owned protocol.
- **Mix umbrella sub-project adoption** requires a top-level
  `mix.exs` restructure if the project is not already an umbrella.
  Less invasive: place tasks in the existing single project under
  `lib/mix/tasks/tau/coherence/`. The umbrella is the cleaner long-
  term home; the disruption may not be justified by this leaf alone.
- **GitHub Checks API rate limits** under high merge cadence (C5
  polls) — a known constraint requiring caching.

### Costs

- **New code surface:** ~1500-2000 LOC across 5 check tasks +
  `Verdict` + fixtures + property tests; ~50 LOC of YAML per existing
  SPEC (currently 11 SPECs catalogued in `spec-before-code.md` →
  ~550 LOC of sidecar manifest one-time + ongoing maintenance).
- **CI minutes:** each check is a clean compile + AST traversal of
  `lib/` (~50k LOC) + grep over `test/` and `docs/`. Estimate
  90-150s per check, 5 checks = ~8-12min wall, parallelisable to
  ~3min via workflow `matrix:`. Daily cron + per-push = ~24×3min +
  N×3min per push day = ~2-3 CI-hours/day. Bounded.
- **Knowledge cost:** authors must learn the sidecar manifest schema
  (≈30min onboarding doc) and the construction-add procedure
  (≈45min runbook). Both go in `docs/factory-v2/coherence/`.
- **Operational cost:** when the suite fires, the auto-filed issue
  must be triaged within the milestone cycle, not allowed to
  accumulate as "known drift." This requires the operability
  sibling's dashboard to surface unresolved coherence-verdict issues
  prominently.

## Dependencies

- **Audit-ingestion sibling** must produce `.factory/rescue-waivers.yml`
  (C2 input) and `.factory/telemetry-baseline.json` (C3 input) on its
  first run; bootstrap order: audit-ingestion before coherence-suite.
- **Operability sibling's dashboard** must consume
  `.factory/coherence-verdicts/<sha>.json` and `.factory/STOP-FACTORY-
  MAIN-RED`; the verdict format is owned here, the rendering there.
- **Factory-loop.md** must continue to honour `.factory/STOP-FACTORY-
  MAIN-RED` sentinel-on-step-start (already exists per inherited
  rules), with the additional contract that this file is *only*
  cleared by a subsequent green `main` observation, not by manual
  removal.
- **Sourceror** dep for AST traversal of `lib/` (~ ¬new dep — already
  in `mix.lock` for unrelated tooling; if not, add explicitly).
- **`gh` CLI** available in CI for issue-opening (already present).
- **Spec-before-code.md Appendix B source-maps** as the seed for
  C1's path-existence assertions (re-used; not rebuilt).

## Confidence

**Medium-high.** The construction-first method is well-anchored — the
v1 audit produced four of the five constructions empirically (B5/D-
171, the orphan-telemetry ratio, the red-main merges, the rescue
accumulation), so the suite is not speculative. The remaining design
risk is the per-SPEC sidecar adoption cost (the manifest schema may
need iteration before authors find it tolerable). What would raise
confidence: a 200-line prototype of `Mix.Tasks.Tau.Coherence.
SpecInternalConsistency` exercised against the SPEC-PERMISSION-
PROMPTS B5/D-171 case, asserting the check trips on the current
`main` state. That prototype is ~2 hours of work and would close the
"manifest schema is plausible in theory" gap.

## Prior art / references

- `factory-loop.md` "kill switch" section — the `.claude/STOP-FACTORY`
  sentinel pattern this proposal extends with `STOP-FACTORY-MAIN-RED`.
- `tau-architecture` skill — for the OTP non-negotiables that C2
  enforces cumulatively (NN #7 is the rescue rule).
- Property-based testing in Tau (`StreamData`) — the suite reuses
  the project's existing property idiom; each construction's
  property test is an instance.
- `sobelow` / `credo`'s warning-budget pattern — direction-of-
  travel invariants for code-quality counts. C2 generalises this
  pattern.
- The `lock-files-as-invariants` pattern (Cargo `Cargo.lock`, npm
  `package-lock.json`) — `.factory/telemetry-baseline.json` and
  `.factory/rescue-waivers.yml` are invariant-bearing lock files,
  not configuration.
- The "constructions-as-tests" pattern from Erlang's `proper_statem`
  — each failure construction is a state machine fixture asserting
  the check responds correctly.
- `Mix.Tasks.Tau.Gate.*` (`factory-loop.md` gate 5.1/5.2/5.3) —
  this proposal mirrors that naming convention deliberately so
  `Coherence.*` tasks are discoverable alongside `Gate.*` tasks.
