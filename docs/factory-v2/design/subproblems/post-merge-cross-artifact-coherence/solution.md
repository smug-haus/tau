---
template_version: 1
template_name: solution
parent_problem: ./problem.md
node_kind: leaf
synthesised_from:
  - proposals/proposal-1.md
  - proposals/proposal-4.md
  - proposals/proposal-3.md
selection_method: hybrid
revision: 0
---

# Solution: Manifest-driven pure-predicate coherence suite, with adversarial fixtures, direction-of-travel invariants, expiring-waiver registry, and STOP-FACTORY-MAIN-* sentinel wiring

## Recommendation

Build cross-artifact coherence on `main` as a pure function over a typed
manifest of the repository at a SHA, surfaced through eight `Tau.Coherence.Check`
behaviour modules dispatched by a compile-time `Tau.Coherence.Registry`, run by
`Mix.Tasks.Tau.Coherence.Run` on every `push: branches: [main]` and on a daily
cron via `.github/workflows/main-coherence.yml`. Each check ships with an
adversarial fixture (construction `C<N>`) under
`test/tau/coherence/constructions/c<n>/` whose property test asserts the check
trips on the fixture — the check itself has a regression test for its own
firing, closing v1's "check that never fires" failure mode. Two checks
(`RescueLedger`, `TelemetryConsumerCumulative`) are direction-of-travel
invariants keyed to baseline lock-files in `priv/coherence/`. Legitimate
exceptions are recorded in `priv/coherence/waivers.toml` with mandatory
`expires_at` (CodeClimate pattern, adapted from P3); a waiver past expiry
re-fails. On `:fail`, `Mix.Tasks.Tau.Coherence.OpenIssue` files a deduplicated
GitHub issue (auto-milestoned to the focus milestone, labelled `coherence`),
`Mix.Tasks.Tau.Coherence.PublishStatus` writes a verdict file the operability
sibling consumes, and `Mix.Tasks.Tau.Coherence.MainHealth` writes
`.claude/STOP-FACTORY-MAIN-RED` (a new sibling sentinel of `.claude/STOP-FACTORY`)
to halt the factory loop until a subsequent green `main` is observed.
Silent-skip is structurally impossible because (a) the `Check` callback signature
has no `:skip` arm; (b) the runner enumerates `Registry.all/0` at compile time and
asserts every registered check produced exactly one verdict entry; (c) the
workflow asserts `len(verdict.checks) == Tau.Coherence.Registry.count()`; (d)
exit codes are typed (`0` = checked-clean, `1` = checked-with-findings, `2` =
infrastructure failure / silent-skip detected, `3` = manifest parse error); (e)
the workflow contains no `if:`-conditional steps, no `continue-on-error`, and
no `|| true`, and a `lint`-job regression test in `test/tau/coherence/workflow_format_test.exs`
greps the workflow source for those tokens.

## Selected from

- **Chosen:** hybrid of `proposals/proposal-1.md` and `proposals/proposal-4.md`,
  with two named elements adopted from `proposals/proposal-3.md`. The hybrid
  takes P1's substrate (typed manifest, pure-predicate `Check` behaviour,
  compile-time `Registry`, JSON-schema-validated verdict, workflow registry-
  equality assertion) — this is the strongest decomplecting move and gives
  the most rigorous mechanical silent-skip dissolution. It takes P4's
  discipline (every predicate ships with an adversarial construction fixture
  whose property test asserts the predicate trips; direction-of-travel
  invariants for `rescue` count and telemetry consumer ratio; the
  `STOP-FACTORY-MAIN-RED` sentinel for red-`main` detection wired to the
  factory loop's existing kill-switch protocol) — these close failure modes
  (check-that-never-fires, cumulative-tail drift, red-main merges) that P1
  alone does not address. From P3 it takes (a) the expiring-waiver registry
  (CodeClimate technical-debt pattern) realised as `priv/coherence/waivers.toml`
  with a mandatory `expires_at` field the runner enforces, and (b) the
  "release-degradation halts new merges" semantics, realised through the
  STOP-FACTORY sentinel mechanism rather than P3's OTLP collector (OTLP is
  rejected as an unjustified operational dependency: a file under
  `_build/coherence/` is sufficient for the operability sibling).

  **Comparison against acceptance criterion:**

  | # | Fit | Decomplecting depth | Migration cost | Risk | Reversibility |
  |---|---|---|---|---|---|
  | 1 (manifest+predicate) | Yes | Deep | Medium | Low | Easy |
  | 2 (polya-audit agent) | Partially | Surface | Low | High (LLM in gate) | Easy |
  | 3 (fitness functions) | Yes | Substantial | Medium | Medium (OTLP) | Easy |
  | 4 (adversarial constructions) | Yes | Deep | Medium | Low | Easy |

  P2 is **rejected outright**: its `SPEC-SPEC-CONTRA` rule places a Claude-call
  in the gating path. Root §Background states "the v2 factory must therefore
  not rely on Claude (or any single agent) telling the truth about its own
  work — it must rely on independent mechanisms that produce verdicts Claude
  cannot influence." An agent-constrained detector with non-deterministic
  recall violates this directly; the rest of P2's deterministic mix-task
  detectors are subsumed by P1's predicate substrate.

  P1 alone misses the cumulative-drift checks (`rescue` ledger, telemetry
  ratio direction-of-travel) and the red-`main` sticky-state sentinel — P4
  contributes these specifically. P4 alone lacks P1's compile-time registry
  + verdict-schema discipline; P1's `Registry.count()` assertion is a more
  robust silent-skip primitive than P4's per-construction enumeration. The
  hybrid is composition, not averaging: each proposal contributes a distinct
  primitive the other lacks.

  P3 contributes only its expiring-waiver registry and its
  "degraded-release-blocks-new-merges" insight; its OTLP, fitness.toml
  manifest, and umbrella mix project are explicitly rejected (the
  compile-time Erlang `Registry` module is a stronger primitive than a TOML
  manifest because demoting `required: true` to `required: false` in TOML is
  a silent weakening, whereas removing a module from `@checks` at compile
  time is a registry-equality workflow failure).

## What changes

### New code under `lib/tau/coherence/`

- `lib/tau/coherence/manifest.ex` — `%Tau.Coherence.Manifest{sha,
  dnnn_index, spec_contracts, adrs, source_maps, telemetry_sites,
  telemetry_consumers, rescue_sites, main_health}` typed struct + sub-structs
  `SpecContract`, `Adr`, `TelemetrySite`, `TelemetryConsumer`, `RescueSite`,
  `Invariant`, `Symbol`, `Occurrence`. Pure data; no behaviour.
- `lib/tau/coherence/extract.ex` — entry-point pure function
  `Tau.Coherence.Extract.build(repo_root :: Path.t()) :: Manifest.t()` that
  composes the per-kind extractors below.
- `lib/tau/coherence/extract/dnnn_index.ex` — regex-scan of `lib/`, `test/`,
  `docs/`, `.claude/` for `D-\d{3}`; returns `%{id => [Occurrence{path,
  line, context}]}`.
- `lib/tau/coherence/extract/spec_contracts.ex` — reads each
  `docs/spec/SPEC-*.source-map.yaml` sidecar (or, if absent, the SPEC's
  Appendix B); each `SpecContract` records section, named D-NNN ids,
  symbols, and machine-readable invariants (axis-tagged via
  `<!-- axis: <name>; value: <expr> -->` markers in the SPEC body OR
  declared in the sidecar's `invariants:` key).
- `lib/tau/coherence/extract/adr_graph.ex` — reads `docs/adr/*.md`,
  extracts `supersedes:` / `superseded_by:` metadata into an `AdrGraph`.
- `lib/tau/coherence/extract/source_map.ex` — parses Appendix B of each
  SPEC (or its sidecar) into `%{spec_id => [Path.t()]}`.
- `lib/tau/coherence/extract/telemetry.ex` — AST-walks `lib/**/*.ex` via
  `Sourceror` for `:telemetry.execute/3` sites and
  `:telemetry.attach{,_many}/4` registrations. Returns
  `{[TelemetrySite{}], [TelemetryConsumer{}]}`. (Shared with the
  pre-merge-code-gates sibling per its Dependencies section; whichever
  sibling lands first authors the module.)
- `lib/tau/coherence/extract/rescue_sites.ex` — AST-walks `lib/**/*.ex`
  via `Sourceror` for `rescue` / `catch :exit` clauses; classifies each
  against `priv/coherence/rescue_waivers.toml` (`:legitimate |
  :under_waiver | :unknown`).
- `lib/tau/coherence/extract/main_health.ex` — calls the GitHub Checks
  API for `git rev-parse origin/main`; returns the success/failure of every
  required check on the most-recent `main` SHA.

### New check behaviour and predicates

- `lib/tau/coherence/check.ex` — defines the behaviour:
  ```elixir
  @callback name() :: String.t()
  @callback applies_to(Manifest.t()) :: boolean()
  @callback run(Manifest.t()) :: {:ok, [Finding.t()]} | {:error, term()}
  ```
  No `:skip` constructor. `{:ok, []}` is the "checked, no findings"
  return; `{:error, _}` is infrastructure failure.
- `lib/tau/coherence/finding.ex` — `%Finding{check, severity, locations,
  message, dedup_key}` struct + JSON encoder. `dedup_key =
  :crypto.hash(:sha256, ...)` over `(check, locations, message_template)`.
- `lib/tau/coherence/registry.ex` — compile-time `@checks` module list +
  `all/0` and `count/0`. **A check must appear in this list to run; a check
  whose module name is in the list but not loaded is `:infrastructure_failure`.**
- `lib/tau/coherence/check/dnnn_uniqueness.ex` — emits a `:blocker` for
  each D-NNN with > 1 definition site (covers Hypothesis #9 sub-case).
- `lib/tau/coherence/check/spec_symbol_resolution.ex` — for each
  `SpecContract.symbols`, uses `Code.ensure_loaded?/1` and
  `Module.defines?/3` (or `Code.ensure_compiled/1` + `function_exported?/3`)
  to verify resolution on `main`; emits `:blocker` per unresolved symbol
  (covers C1 — cross-PR gate-relocate + SPEC-update split).
- `lib/tau/coherence/check/spec_contradiction.ex` — groups
  `SpecContract.invariants` by `axis`; emits `:blocker` for any axis with
  > 1 distinct `value`. Covers the v1 PERMISSION-PROMPTS B5/D-171 case as
  a first-run regression fixture (planted in
  `test/tau/coherence/constructions/c4/`).
- `lib/tau/coherence/check/adr_supersession.ex` — for each ADR with
  `supersedes: ADR-N`, asserts ADR-N has `superseded_by: ADR-M`; emits
  `:blocker` per unidirectional link.
- `lib/tau/coherence/check/telemetry_consumer_cumulative.ex` — for each
  distinct event-name prefix in `telemetry_sites`, asserts ≥1 entry in
  `telemetry_consumers` outside `test/` and outside `:debug`-only handlers.
  **Direction-of-travel variant**: if the consumer-ratio
  (`consumed / emitted`) falls below the baseline in
  `priv/coherence/telemetry_baseline.json`, emit `:blocker`. The only way
  to lower the baseline is an explicit PR that edits the baseline file
  (which goes through the pre-merge gate suite).
- `lib/tau/coherence/check/rescue_ledger.ex` — direction-of-travel:
  asserts `count(rescue_sites where classification == :unknown) == 0` AND
  `count(rescue_sites) <= ledger_baseline.total +
  sum(waivers_with_status:add)`. Baseline in
  `priv/coherence/rescue_baseline.json`; waivers in
  `priv/coherence/rescue_waivers.toml`.
- `lib/tau/coherence/check/main_health.ex` — asserts the current
  `origin/main` SHA has every required GitHub check at `:success`; on
  fail, writes `.claude/STOP-FACTORY-MAIN-RED` (the factory loop's
  start-of-step check halts on this sentinel — see "Cross-artifact
  contracts" below) AND emits a `:blocker` finding. Sentinel is cleared
  only by a subsequent observation of green `main` (the check rewrites
  the sentinel as absent on a clean run).

### New Mix tasks

- `lib/mix/tasks/tau.coherence.run.ex` — `Mix.Tasks.Tau.Coherence.Run`:
  builds the manifest, iterates `Tau.Coherence.Registry.all/0`, invokes
  each check, assembles a `%Verdict{sha, ran_at, registry_count, checks:
  [%CheckResult{name, status, findings}]}`, writes
  `_build/coherence/verdict-<sha>.json`, exits per the typed exit-code
  table:
  - `0` — all checks `{:ok, []}` OR all findings have an active waiver.
  - `1` — at least one `{:ok, [findings]}` with no active waiver.
  - `2` — at least one `{:error, _}` (infrastructure failure) OR
    `len(checks) != Registry.count()` (silent-skip detected).
  - `3` — manifest parse error (sidecar YAML unparseable, ADR metadata
    malformed).
- `lib/mix/tasks/tau.coherence.open_issue.ex` —
  `Mix.Tasks.Tau.Coherence.OpenIssue`: reads the verdict JSON, dedupes
  findings by `dedup_key` against open `coherence`-labelled issues
  (via `gh issue list`), creates one issue per unique key with title
  `coherence/<check_name>: <message_summary>` and body containing the
  full finding JSON; milestones to the current focus milestone via
  `gh api repos/:owner/:repo/milestones --jq '.[] | select(.state == "open")
  | .title' | head -1`.
- `lib/mix/tasks/tau.coherence.publish_status.ex` —
  `Mix.Tasks.Tau.Coherence.PublishStatus`: writes
  `_build/coherence/published/latest.json` and `_build/coherence/published/<sha>.json`,
  which the operability sibling's dashboard polls (or which the
  operability sibling subscribes to via a filesystem-watcher; the
  contract is "this file always exists after a coherence run").

### New schema and manifest files

- `priv/coherence/verdict.schema.json` — JSON-schema for the verdict file
  consumed by the operability sibling and asserted in CI. Required
  fields: `sha` (40-hex), `ran_at` (RFC3339), `registry_count`
  (positive int), `checks` (array of `{name, status, findings}` where
  `status ∈ {"checked", "infrastructure_failure"}` and `findings` is an
  array conforming to `#/$defs/finding`).
- `priv/coherence/waivers.toml` — expiring-waiver registry (CodeClimate
  pattern, adapted from P3). Each entry: `check_id`, `dedup_key`,
  `reason`, `expires_at` (RFC3339), `opened_by`, `opened_in_pr`. The
  runner enforces `expires_at`: a waiver past expiry is ignored and its
  finding re-fails.
- `priv/coherence/rescue_baseline.json` — `%{"total": <int>, "as_of_sha":
  "<sha>"}`. Authored once at suite bootstrap (Build-order step 11);
  amended only by a PR that explicitly lowers (or, with waiver, raises)
  the total.
- `priv/coherence/rescue_waivers.toml` — per-`rescue`-site classification
  feeding `extract/rescue_sites.ex`. Each entry: `file`, `line`,
  `classification` (`:legitimate | :under_waiver`), `reason`, and (for
  `:under_waiver`) `expires_at`.
- `priv/coherence/telemetry_baseline.json` — `%{"consumed": <int>,
  "emitted": <int>, "ratio": <float>, "as_of_sha": "<sha>"}`. Authored
  once at suite bootstrap; lowered only by explicit PR.
- `docs/spec/SPEC-*.source-map.yaml` — per-SPEC sidecar (one per entry
  in the catalog). Fields: `spec_id`, `binds: [{path, symbols,
  invariants}]`, `invariants: [{axis, value, location}]`. The
  `SourceMapPresence` meta-check emits a finding for any catalog entry
  missing a sidecar (closes "the sidecar requirement could be silently
  dropped" failure mode).

### New construction fixtures (P4 discipline, adversarial regression)

Each construction is a directory under
`test/tau/coherence/constructions/c<N>/` containing:

- `fixture.sh` — shell script producing the bad joint state in a
  temp fixture repo (or seeded files under a fixture dir for the
  pure-Elixir checks).
- `<check>_construction_test.exs` — property test asserting the
  corresponding check trips on the fixture AND passes on a clean
  control fixture.

The constructions:

- `c1/` — cross-PR SPEC-path-vs-code split (covers
  `SpecSymbolResolution`).
- `c2/` — `rescue` count creep despite per-PR audit budget (covers
  `RescueLedger`).
- `c3/` — telemetry consumer ratio drop (covers
  `TelemetryConsumerCumulative`).
- `c4/` — SPEC internal contradiction generalising the
  PERMISSION-PROMPTS B5/D-171 case (covers `SpecContradiction`).
- `c5/` — red-`main` state after a merge (covers `MainHealth`; verifies
  the `STOP-FACTORY-MAIN-RED` sentinel is created and the next clean
  run removes it).
- `c6/` — D-NNN re-use across two SPEC files (covers
  `DnnnUniqueness`).
- `c7/` — ADR-N claims `supersedes: ADR-M` but ADR-M lacks
  `superseded_by: ADR-N` (covers `AdrSupersession`).
- `c8/` — SPEC catalog entry exists in
  `.claude/rules/spec-before-code.md` but the SPEC has no
  `SPEC-*.source-map.yaml` sidecar (covers `SourceMapPresence`).

Umbrella enforcement: `test/tau/coherence/constructions_completeness_test.exs`
enumerates the construction directories and fails if any lacks a
matching predicate module under `lib/tau/coherence/check/`. **This
closes "we wrote the construction but never built the check" — a v1
failure pattern.**

### New CI workflow

- `.github/workflows/main-coherence.yml` — triggers:
  ```yaml
  on:
    push: { branches: [main] }
    schedule: [{ cron: "0 6 * * *" }]
    workflow_dispatch:
  permissions:
    contents: read
    issues: write
  concurrency: { group: main-coherence, cancel-in-progress: false }
  ```
  Single job `coherence` with steps:
  1. `actions/checkout@v4` with `fetch-depth: 0`.
  2. `erlef/setup-beam@v1` reading `.tool-versions` (strict).
  3. `mix deps.get && mix compile --warnings-as-errors`.
  4. `mix tau.coherence.run` — captures exit code.
  5. **Silent-skip guard** (runs even on prior-step failure):
     ```bash
     REG=$(mix run --no-start -e 'IO.puts(Tau.Coherence.Registry.count())')
     CHK=$(jq '.checks | length' _build/coherence/verdict-*.json)
     test "$REG" = "$CHK" || { echo "::error::Verdict missing checks"; exit 2; }
     ```
  6. `actions/upload-artifact@v4` for `_build/coherence/`
     (`if: always()`).
  7. `mix tau.coherence.open_issue _build/coherence/verdict-*.json`
     (`if: failure()`, env `GH_TOKEN`).
  8. `mix tau.coherence.publish_status _build/coherence/verdict-*.json`
     (`if: always()`).

  **No `if:`-conditional steps that gate on PR-body content** (root §C
  anti-pattern). **No `continue-on-error`. No `|| true`. No early-exit
  expressions.**

- `test/tau/coherence/workflow_format_test.exs` — `lint`-job regression
  test that reads
  `.github/workflows/main-coherence.yml` as plain text and asserts:
  - `|| true` does not appear.
  - `continue-on-error: true` does not appear.
  - Every step has a `run:` or `uses:` (no empty steps).
  - The `silent-skip guard` step exists with exactly the expected
    `REG=...; CHK=...; test` shape (regression against future
    sloppification).

### Cross-artifact contracts

- **`.claude/rules/factory-loop.md` — sentinel co-ownership.** Add a
  paragraph under "Kill switch" stating that `.claude/STOP-FACTORY-MAIN-RED`
  is a sibling sentinel of `.claude/STOP-FACTORY`, written by
  `Mix.Tasks.Tau.Coherence.MainHealth` on red-`main` detection, checked at
  the start of every factory step, and cleared only by a subsequent green
  `main` observation. Both sentinels are `.gitignore`d.
- **`.gitignore`** — add `.claude/STOP-FACTORY-MAIN-RED` and
  `_build/coherence/` and `.code_audit/main-coherence/`.
- **`.claude/rules/spec-before-code.md`** — add: "Every SPEC entry in the
  catalog MUST have a `docs/spec/SPEC-*.source-map.yaml` sidecar; the
  `SourceMapPresence` meta-check emits a `:blocker` finding for any catalog
  entry lacking one."
- **`docs/spec/SPEC-MAIN-COHERENCE.md`** — the spec for this leaf's
  deliverable (per `spec-before-code.md` — this leaf is itself
  coordination-heavy; PSDH triage = 4/5). §3 lists D-NNN invariants for
  silent-skip impossibility, registry equality, waiver expiry, sentinel
  semantics. §4 names every module above. Appendix B source-map names every
  file path above. The SPEC is authored as the first PR of the build-order.

### Silent-skip impossibility — implementation-level proof

The acceptance criterion's "the suite cannot silent-skip" requirement is
discharged by **five mutually reinforcing mechanisms**, no single one of which
is the load-bearing primitive:

1. **No `:skip` arm in the `Check` callback.** The behaviour signature is
   `{:ok, [Finding.t()]} | {:error, term()}`. A check that wants to "not
   apply" returns `{:ok, []}` — which is *data*, not the absence of data.
   The runner records `{:ok, []}` as `status: "checked", findings: []` in
   the verdict. There is no third return value the check can produce to
   silently disappear.
2. **Compile-time `Registry.all/0` is the iteration source.** The runner
   does NOT iterate `File.ls!/1` or `Code.all_loaded/0` or any
   filesystem-shaped source; it iterates the compile-time module list. A
   predicate file present on disk but not in `@checks` does not run; a
   predicate in `@checks` but missing on disk produces
   `:infrastructure_failure`. Both are detectable.
3. **Verdict-schema validation in CI.** The workflow validates
   `_build/coherence/verdict-*.json` against
   `priv/coherence/verdict.schema.json` (schema requires non-empty
   `checks` array and every entry conformant). A truncated verdict file
   fails the validation step.
4. **Registry-equality workflow assertion.** The workflow's silent-skip
   guard step asserts `len(verdict.checks) ==
   Tau.Coherence.Registry.count()`. A check that crashed during the
   `Mix.Tasks.Tau.Coherence.Run` (the rescue inside the runner that
   converts crashes to `:infrastructure_failure`) STILL produces a verdict
   entry; if the rescue itself fails (e.g. OOM), the verdict file is
   truncated AND the registry-equality assertion fires.
5. **Typed exit codes + workflow-format regression test.** Exit codes are
   distinct integers per failure class; the workflow has no `|| true` and
   no `continue-on-error`; a regression test in
   `test/tau/coherence/workflow_format_test.exs` greps the workflow source
   to prevent reintroduction of either token. The v1 anti-pattern at
   `ci.yml:115` (`|| true`) is structurally impossible because the test
   fails on any PR that adds the token.

**The construction-fixture discipline is the meta-check on (1)-(5):** if
any of these mechanisms is silently disabled (e.g. someone replaces
`{:ok, []}` returns with an `:skipped` atom and updates the runner to
filter), the construction property tests under `test/tau/coherence/`
fail because the predicates no longer trip on planted fixtures.

## What does not change

- The existing per-PR gates `Mix.Tasks.Tau.Gate.{AcLinkage, Masking,
  Mutation}` (from PR-B / issue #370) remain in `.github/workflows/ci.yml`.
  This sibling adds a `main`-side suite; it does not replace the per-PR
  suite.
- The `polya-audit` plugin at `.claude/plugins/polya-audit/` remains a
  design-review tool for humans and coordinators; this proposal does NOT
  invoke it from CI. P2's agent-driven approach is rejected and the
  plugin's CI integration surface is unchanged.
- `Phoenix.PubSub` and the existing `[:tau, ...]` telemetry namespace are
  not touched. This suite emits its OWN telemetry under
  `[:tau, :coherence, ...]` for observability (e.g. dashboard-side
  consumption of run latency, finding counts), but the coherence verdict
  itself is a file artifact, not a telemetry event.
- The OTLP exporter and `Tau.OtelReporter` are NOT used as the verdict
  channel. P3's OTLP-as-single-source-of-truth is rejected: a file under
  `_build/coherence/` is simpler, has no operational dependency, and is
  trivially observable. (The dashboard sibling MAY subscribe to
  `[:tau, :coherence, ...]` telemetry for live updates, but the
  authoritative verdict is the file.)
- The Mix project is NOT restructured into an umbrella. P4's umbrella
  proposal is rejected as scope creep — all new modules live under
  `lib/tau/coherence/` and `lib/mix/tasks/`.
- D-NNN allocation rules in `CLAUDE.md` are unchanged; the `DnnnUniqueness`
  check enforces them mechanically, dissolving the "did the author grep"
  weave from the *enforcement* side without replacing the documentation.
- `mix.exs` deps gain one new entry: `{:sourceror, "~> 1.0"}` (if not
  already a transitive dep via `credo` / `mix format`). No other new deps;
  `Jason`, `Yaml_elixir`, `ExUnit`, `StreamData` are all present.

## Migration sketch

Bottom-up, one PR per Build-order step (see §Build-order). Substrate
first (manifest types, check behaviour, registry, verdict schema, runner
skeleton, silent-skip guard) — proven by the `DnnnUniqueness` check
finding existing duplicates on `main` (if any) or returning `{:ok, []}`
on a clean tree. Then the smaller-surface predicates (`AdrSupersession`,
`SourceMapPresence`). Then SPEC sidecars are authored one PR per SPEC
(roughly 11 small PRs in parallel from different agents — these are the
content cost). Then the SPEC-aware predicates (`SpecSymbolResolution`,
`SpecContradiction`). Then the direction-of-travel predicates
(`RescueLedger`, `TelemetryConsumerCumulative`) with their baseline
lock-files initialised from the current `main` state via a one-time
`mix tau.coherence.init_baselines` task. Then the workflow wiring with
the silent-skip guard. Then the backfill pass that files issues for
every finding the suite produces on current `main`. Each PR's AC
declares the predicate(s) it adds and references the construction
fixture in `test/tau/coherence/constructions/c<N>/`; the construction
completeness test enforces wire-up.

## Open questions

- **Axis-tag convention adoption rate.** `SpecContradiction` needs each
  SPEC invariant tagged with a machine-readable `axis` identifier. The
  PERMISSION-PROMPTS B5/D-171 case uses `axis: permission_modes` and trips
  on first run, but the other 10 SPECs need an annotation pass before
  their full coverage materialises. **Resolution:** the `SourceMapPresence`
  meta-check emits a `:warn` finding for any SPEC whose sidecar has zero
  `invariants:` entries, surfacing partial coverage as data rather than
  as silent absence; full coverage rolls in as SPECs are amended.
- **Telemetry consumer-registration convention.** The
  `TelemetryConsumerCumulative` check identifies handlers by AST-walking
  `:telemetry.attach{,_many}/4` and `Phoenix.PubSub.subscribe/2`; an
  exotic handler registered via custom indirection is invisible. **Resolution:**
  the pre-merge-code-gates sibling owns canonicalising the
  consumer-registration convention; this sibling's check uses what that
  sibling defines. Until then, the `TelemetryConsumerCumulative` check's
  severity is `:warn`, not `:blocker`, for handlers not matching the
  canonical patterns (the ratio check remains `:blocker`).
- **Waiver-renewal review process.** A waiver can be renewed indefinitely
  by submitting a PR amending `expires_at`. The mechanical gate prevents
  silent indefinite use, but enforcement of "renewal must be justified" is
  social (PR review). The operability sibling's dashboard surfaces active
  waivers and their countdown; whether to add a hard "renewal requires
  ADR" rule is deferred to a future amendment.
- **First-run noise on backfill.** Backfill (Build-order step 12) will
  likely surface dozens of findings on current `main` (the
  PERMISSION-PROMPTS contradiction; probable D-NNN duplicates from v1
  drift; likely SPEC §4 symbols that no longer resolve after refactors;
  the orphan-telemetry ratio creep). The suite will fail daily until
  these are remediated. **Resolution:** the workflow files issues, does
  not auto-revert; remediation is incremental; the "fails-loud-rather-
  than-silent" promise still holds. A coordinator may choose to grant
  short-expiry waivers (e.g. 2 weeks) for known backfill findings while
  remediation lands.
- **Sentinel-clear race.** `MainHealth` writes
  `.claude/STOP-FACTORY-MAIN-RED` on red detection and clears it on green
  detection. If the daily cron observes green but a `push: branches:
  [main]` event hours later races with a concurrent merge that turns
  `main` red, there is a window where the sentinel may not be re-written
  before the factory loop's next step. **Resolution:** `concurrency: {
  group: main-coherence }` prevents overlapping coherence runs; the
  factory loop's step always runs `git fetch origin && git rev-parse
  main` itself for staleness, so a stale-by-window sentinel is bounded by
  one factory cycle.

## Linked sub-problems / proposals

- `proposals/proposal-1.md` — Manifest-extractor + pure-predicate suite +
  always-emit verdict sink (first-principles). **Substrate adopted.**
- `proposals/proposal-2.md` — Scheduled `polya-audit` coherence-agent run
  on `main`, driven by a YAML rules-pack. **Rejected** for placing
  Claude-call in gating path (root §Background violation).
- `proposals/proposal-3.md` — Continuous Architectural Fitness Functions
  for cross-artifact coherence on `main`. **Two elements adopted**:
  expiring-waiver registry (CodeClimate pattern) and
  "degraded-blocks-new-merges" semantics (realised via STOP-FACTORY
  sentinel, NOT OTLP).
- `proposals/proposal-4.md` — Adversarial main-side coherence — construct
  the joint-state failure, then build the trap for it. **Discipline
  adopted**: construction fixtures + property tests + direction-of-travel
  invariants + STOP-FACTORY-MAIN-RED sentinel.

## Build-order

The build proceeds bottom-up so each layer is testable in isolation and
gates the next. Each step is one PR (parallel batches noted), each PR's
AC declares the artifacts it adds, and each PR carries a construction
fixture or a property test that fails-before / passes-after.

1. **`docs/spec/SPEC-MAIN-COHERENCE.md` (spec-before-code).** §3 lists
   D-NNN invariants for silent-skip impossibility, registry equality,
   waiver expiry, sentinel semantics. §4 names every module the
   subsequent PRs introduce. Appendix B source-maps every file path. AC:
   the spec exists, the catalog entry is added to
   `.claude/rules/spec-before-code.md`, and the file lints clean.
2. **Manifest types and `Tau.Coherence.Extract.DnnnIndex` extractor.**
   Smallest surface, no SPEC parsing. AC: `Tau.Coherence.Extract.build/1`
   returns a `Manifest{}` with `dnnn_index` populated; property test
   asserts purity (same input → same output). Construction c6/ fixture
   planted (D-NNN duplicate) and tested.
3. **`Tau.Coherence.Check` behaviour + `Tau.Coherence.Finding` +
   `Tau.Coherence.Registry` (empty) + `verdict.schema.json` +
   `Mix.Tasks.Tau.Coherence.Run` skeleton.** AC: runner produces a
   verdict file with `checks: []` and exits 0; verdict validates against
   the schema. Workflow test asserts registry-equality guard fires when
   the registry is non-empty but the verdict has fewer checks (negative
   test).
4. **`DnnnUniqueness` predicate + register in `Registry`.** AC:
   construction c6/ fixture trips the predicate; clean control passes;
   runner exit code transitions to 1 in the failure case. **First
   construction test live.** Workflow runs but is not yet wired into CI.
5. **`AdrSupersession` predicate.** ADRs are smaller-surface than SPECs;
   extractor builds `AdrGraph`; predicate validates bidirectional
   supersession links. AC: construction c7/ trips; clean passes.
6. **`SourceMapPresence` meta-predicate.** Walks
   `.claude/rules/spec-before-code.md` catalog; emits `:blocker` for any
   catalog SPEC lacking a `SPEC-*.source-map.yaml`. AC: construction c8/
   trips (missing sidecar); a clean repo with sidecars on every catalog
   entry passes. **At this point the suite knows what it does not yet
   cover; coverage rolls in as sidecars are authored.**
7. **SPEC sidecar authoring — parallel batch of ~11 small PRs**, one per
   SPEC in the catalog. Each PR adds
   `docs/spec/SPEC-<NAME>.source-map.yaml` with `binds`, `symbols`, and
   `invariants` extracted from the SPEC's Appendix B and §4. AC per PR:
   `SourceMapPresence` no longer emits a finding for this SPEC; sidecar
   parses cleanly.
8. **`SpecSymbolResolution` predicate.** Uses `Sourceror` /
   `Code.ensure_loaded?` to resolve each `SpecContract.symbols` entry.
   AC: construction c1/ trips (cross-PR SPEC-path-vs-code split); clean
   passes.
9. **`SpecContradiction` predicate.** Groups invariants by `axis`; emits
   `:blocker` for axes with > 1 distinct value. AC: construction c4/
   (the v1 PERMISSION-PROMPTS B5/D-171 case, planted as fixture) trips;
   clean passes. **This is the regression-fixture for failure class #9.**
10. **`Tau.Coherence.Extract.Telemetry` extractor +
    `TelemetryConsumerCumulative` predicate.** If the
    pre-merge-code-gates sibling has shipped its telemetry extractor,
    consume it directly; if not, author here and that sibling consumes
    from this. AC: construction c3/ trips; clean passes. Baseline file
    initialised but not yet enforced.
11. **`Mix.Tasks.Tau.Coherence.InitBaselines` (one-time bootstrap).**
    Walks the current `main` tree and writes
    `priv/coherence/rescue_baseline.json` and
    `priv/coherence/telemetry_baseline.json`. AC: the task is idempotent
    when re-run on the same SHA; the resulting files commit cleanly.
12. **`RescueLedger` predicate + `rescue_waivers.toml` + baseline
    enforcement.** Walks `lib/` for `rescue` / `catch :exit`; classifies
    against waivers; enforces direction-of-travel against the baseline.
    AC: construction c2/ trips (count creep); clean passes; an
    explicit-lowering PR (one entry waived) passes.
13. **`MainHealth` predicate + `STOP-FACTORY-MAIN-RED` sentinel +
    `factory-loop.md` amendment co-ownership paragraph.** Polls
    GitHub Checks API for `origin/main`. AC: construction c5/ creates
    the sentinel on red detection; the next clean run removes it;
    `factory-loop.md` is amended to document the sentinel as a sibling
    of `STOP-FACTORY`.
14. **Waiver registry + `priv/coherence/waivers.toml` + runner expiry
    enforcement.** AC: an expired waiver no longer suppresses its
    finding; a not-yet-expired waiver does; a missing `expires_at`
    field is a manifest parse error (exit 3).
15. **`Mix.Tasks.Tau.Coherence.OpenIssue` and
    `Mix.Tasks.Tau.Coherence.PublishStatus`.** Issue-opener dedupes by
    `dedup_key` against open `coherence`-labelled issues; publisher
    writes to `_build/coherence/published/`. AC: tested against a stub
    `gh` (Bash script that echoes args) in CI; verdict file is always
    present after a run.
16. **`.github/workflows/main-coherence.yml` wired with all triggers +
    silent-skip guard + workflow-format regression test.** AC: the
    workflow runs green on a clean `main` and red on a planted
    contradiction; the workflow-format test asserts no `|| true`, no
    `continue-on-error`, and the exact silent-skip guard step shape.
17. **Backfill pass.** Run the suite against the current `main` via
    `workflow_dispatch`; review the filed issues; remediate or grant
    short-expiry waivers per finding. AC: after backfill, the daily
    cron run is green; the steady-state guarantee holds.
18. **Construction-completeness test.** Author
    `test/tau/coherence/constructions_completeness_test.exs` that
    enumerates `test/tau/coherence/constructions/c*/` and fails if any
    lacks a matching predicate in `Tau.Coherence.Registry`. AC: a
    planted construction with no matching check fails the test; the
    existing set passes. **This is the meta-meta-check; closes "we
    wrote the construction but never built the check."**

Each step is one PR (steps 7's parallel batch excepted); each PR
references this leaf's spec (`SPEC-MAIN-COHERENCE.md`); each PR's AC
declares the artifacts it adds and the construction fixture it
exercises.

## Revision history

- (revision 0 — initial synthesis from proposals 1, 4, with elements
  adopted from 3.)
