---
template_version: 1
template_name: proposal
proposal_id: 3
parent_problem: ../problem.md
---

# Proposal 3: Continuous Architectural Fitness Functions for cross-artifact coherence on `main`

## Approach

Adopt the **Continuous Architectural Fitness Function** discipline from
Ford/Parsons/Kua (*Building Evolutionary Architectures*) and instantiate it
as a `main`-side check suite under a new `priv/fitness/` Mix project that
runs on every `push: branches: [main]` and on a daily `schedule` cron. Each
**coherence invariant** is encoded as a *named fitness function* — a pure
function that consumes the repository snapshot (a checked-out worktree at
the post-merge SHA) and returns a `%Tau.Fitness.Verdict{}` (`:pass`,
`:fail`, `:not_applicable` — never absent, never `:skipped`). The suite is
modelled after **SonarQube's quality-gate baseline** (a versioned manifest
of named conditions with required thresholds) and reports verdicts via the
**OpenTelemetry post-deploy verification** pattern (every fitness function
emits a `[:tau, :fitness, :function, :stop]` span; the dashboard reads the
OTLP stream rather than parsing CI logs). On any `:fail` the suite opens a
GitHub issue auto-milestoned to the focus milestone and tagged
`area:coherence`, populated from a deterministic template that enumerates
the contradicting artifacts; **Erlang/OTP system-tests' loud-failure
discipline** is the cultural anchor — there is no "warning" verdict, only
pass/fail/N-A. Adapted from **Sentry Release Health** and **canary analysis
(Flagger/LaunchDarkly)**: each merge to `main` is treated as a "release";
the suite is the release's automated post-deploy verification; a failing
verdict marks `main` as **degraded** in the dashboard's release-health view
and the factory-loop's pre-merge gate refuses to merge new PRs until the
degradation is resolved or explicitly waived with an expiring `WAIVER`
entry (CodeClimate-style technical-debt baseline).

## Rationale

The complecting hypothesis names three weaves: (a) "what a SPEC says" with
"what the codebase does" via prose-only Appendix B; (b) "when a
contradiction emerged" with "which PR introduced it"; (c) "D-NNN
uniqueness" with "the author remembered to grep." Fitness functions
**decomplect verdict from author intent**: the function runs unconditionally
on `main`, against the post-merge artifact set, irrespective of who merged
what when. SonarQube's baseline-manifest pattern decomplects "what is
checked" from "what each check does" — a versioned `fitness.toml`
enumerates every invariant, so a gate that has nothing to check returns
`:not_applicable` against a named, audited entry rather than silently
not-running (root §Acceptance C). OpenTelemetry post-deploy verification
decomplects "verdict emission" from "verdict consumption" — the dashboard,
the issue-opener, and the factory's pre-merge gate all subscribe to the
same span stream rather than racing each other to parse CI artifacts.
Sentry Release Health and Flagger canary analysis decomplect "merge
happened" from "merge is healthy" — a merge that introduces a SPEC↔SPEC
contradiction is a *degraded release*, not merely a closed PR, and the
factory's downstream behaviour reflects that. The OTP system-test ethos
decomplects "failure detected" from "human decides what to do" — the issue
opens automatically, with structured evidence, not after a human review of
a flaky-test report.

## Sketch

### Repository layout

```
priv/fitness/                          # new mini-Mix project (not part of main app)
  mix.exs
  lib/
    tau/fitness.ex                     # entry point: load manifest, run suite, emit OTLP
    tau/fitness/verdict.ex             # %Verdict{name, status, evidence, duration_ms}
    tau/fitness/manifest.ex            # parse priv/fitness/fitness.toml
    tau/fitness/runner.ex              # execute one fitness function; emit telemetry span
    tau/fitness/reporter/issue.ex      # GitHub issue opener (uses `gh` CLI)
    tau/fitness/reporter/otlp.ex       # OpenTelemetry exporter
    tau/fitness/reporter/release.ex    # Sentry-style release-health write
    tau/fitness/functions/
      dnnn_uniqueness.ex               # FF-001
      spec_contract_symbols.ex         # FF-002
      spec_cross_contradiction.ex      # FF-003
      adr_supersession_integrity.ex    # FF-004
      telemetry_consumer_cumulative.ex # FF-005
      appendix_b_path_resolution.ex    # FF-006
  priv/
    fitness.toml                       # baseline manifest (versioned)
    waivers.toml                       # expiring-waiver registry (CodeClimate-style)
  test/
    tau/fitness/                       # property tests per FF + golden-cases for v1 bugs
```

### Behaviour and verdict shape

```elixir
defmodule Tau.Fitness.Function do
  @moduledoc "Behaviour for one coherence invariant. Pure; deterministic; loud."
  @callback id() :: String.t()                    # e.g. "FF-003"
  @callback name() :: String.t()                  # human title
  @callback applies?(repo_snapshot :: map()) :: boolean()
  @callback evaluate(repo_snapshot :: map()) :: Tau.Fitness.Verdict.t()
  # No silent-skip: applies?/1 false ==> verdict %{status: :not_applicable, evidence: reason}
end

defmodule Tau.Fitness.Verdict do
  @enforce_keys [:function_id, :status, :evidence, :duration_ms]
  defstruct [:function_id, :status, :evidence, :duration_ms, :sha, :emitted_at]
  @type status :: :pass | :fail | :not_applicable
  # NOTE: there is no :skipped, :warning, :unknown — those are bugs, not statuses.
end
```

### Manifest (SonarQube-baseline pattern)

```toml
# priv/fitness/fitness.toml
schema_version = 1

[[function]]
id = "FF-001"
module = "Tau.Fitness.Functions.DnnnUniqueness"
required = true
description = "Every D-NNN identifier in lib/test/docs/.claude has one definition."

[[function]]
id = "FF-002"
module = "Tau.Fitness.Functions.SpecContractSymbols"
required = true
description = "Every module/function/struct/callback named in any SPEC §4 resolves on main."

[[function]]
id = "FF-003"
module = "Tau.Fitness.Functions.SpecCrossContradiction"
required = true
description = "No two SPEC entries make contradictory claims about the same surface (e.g. PERMISSION-PROMPTS §4 B5 vs §6 D-171)."

[[function]]
id = "FF-004"
module = "Tau.Fitness.Functions.AdrSupersessionIntegrity"
required = true
description = "Every ADR claiming `supersedes: ADR-N` is matched by ADR-N having `superseded_by: ADR-M` (bidirectional)."

[[function]]
id = "FF-005"
module = "Tau.Fitness.Functions.TelemetryConsumerCumulative"
required = true
description = "Every `:telemetry.execute/3` site in lib/ has ≥1 registered handler in lib/ (no consumer-removal-without-emission-removal)."

[[function]]
id = "FF-006"
module = "Tau.Fitness.Functions.AppendixBPathResolution"
required = true
description = "Every file path named in any SPEC's Appendix B source-map exists on main."
```

### Workflow wiring

```yaml
# .github/workflows/main-coherence.yml
name: main-coherence
on:
  push:
    branches: [main]
  schedule:
    - cron: "0 7 * * *"        # daily 07:00 UTC drift sweep
  workflow_dispatch:           # manual rerun
jobs:
  fitness:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - uses: erlef/setup-beam@v1
        with: { version-file: .tool-versions, version-type: strict }
      - name: Run fitness suite
        run: mix tau.fitness.run --manifest priv/fitness/fitness.toml --report otlp,issue,release
        # Exit codes:
        #   0 = all required functions :pass or :not_applicable
        #   2 = at least one required function :fail
        #   3 = infrastructure failure (manifest parse error, missing FF module, etc.)
        # No `|| true`. No early-exit on empty inputs.
      - name: Upload verdicts artifact
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: fitness-verdicts
          path: _build/fitness/verdicts.json
```

### Mix-task entry

```elixir
defmodule Mix.Tasks.Tau.Fitness.Run do
  use Mix.Task
  @shortdoc "Run the post-merge fitness suite against the current main."
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv,
      strict: [manifest: :string, report: :string])
    snapshot   = Tau.Fitness.Snapshot.capture(File.cwd!())
    manifest   = Tau.Fitness.Manifest.load!(opts[:manifest])
    verdicts   = Tau.Fitness.Runner.run_all(manifest, snapshot)
    :ok        = Tau.Fitness.Reporter.dispatch(verdicts, parse_reports(opts[:report]))
    exit_code  = Tau.Fitness.exit_code_for(verdicts)
    System.halt(exit_code)
  end
end
```

### Silent-skip impossibility — mechanism

Three reinforcing constraints make a silent skip structurally impossible:

1. **Manifest is the source of truth.** `Runner.run_all/2` iterates the
   manifest, not the filesystem. A function listed in `fitness.toml` but
   whose module does not exist on `main` produces a `:fail` verdict with
   evidence `{:missing_module, id}` — exit code 2. A function listed but
   not `required` still runs; only its `required` flag governs exit-code
   contribution.
2. **No `:skipped` status exists.** `Verdict.status` is the type
   `:pass | :fail | :not_applicable`. A function whose `applies?/1`
   returns false MUST still produce a `:not_applicable` verdict with
   evidence describing *why* (e.g. `{:no_spec_files_found, [...]}`). The
   runner asserts every manifest entry produced exactly one verdict and
   crashes (exit 3) if any are absent.
3. **`mix.exs` of `priv/fitness/` has zero non-stdlib runtime deps.** The
   suite cannot fail to install. The workflow has no conditional `if:` on
   the `mix tau.fitness.run` step; it runs unconditionally on every
   trigger. There is no `continue-on-error` and no `|| true`.

### Concrete v1-bug repro test (golden case)

```elixir
# test/tau/fitness/functions/spec_cross_contradiction_test.exs
defmodule Tau.Fitness.Functions.SpecCrossContradictionTest do
  use ExUnit.Case, async: true
  alias Tau.Fitness.Functions.SpecCrossContradiction, as: FF

  test "detects PERMISSION-PROMPTS §4 B5 vs §6 D-171 mode-count contradiction" do
    snapshot = Tau.Fitness.Snapshot.from_fixture("test/fixtures/permission_prompts_v1_bug")
    verdict  = FF.evaluate(snapshot)
    assert verdict.status == :fail
    assert {:contradiction, "D-171", _details} in verdict.evidence
  end
end
```

If FF-003 ever returns `:pass` against the v1-bug fixture, the suite has
regressed and CI fails before it even reaches `main`.

### Waiver registry (CodeClimate technical-debt baseline)

```toml
# priv/fitness/waivers.toml
# An expiring escape hatch. A waiver flips a specific (function_id, evidence_hash)
# from :fail to :pass for a bounded window. Beyond expiry, the fail returns.
[[waiver]]
function_id    = "FF-005"
evidence_hash  = "sha256:abc...123"
reason         = "Issue #482 — telemetry handler removal lands in next PR"
expires_at     = "2026-06-30T00:00:00Z"
opened_by      = "brent.walter@gmail.com"
```

A waiver is granted only via PR (so it goes through the pre-merge gate
suite). The fitness runner refuses to honour a waiver past `expires_at`.
The dashboard surfaces active waivers and their countdown.

## Tradeoffs

### Strengths

- **Direct fit to acceptance criterion (a).** Each named check in the
  acceptance criterion maps 1:1 to a fitness function (FF-001..FF-006);
  the manifest is the audit trail.
- **Mechanically enforces acceptance criterion (c) silent-skip
  impossibility.** Status enum has no `:skipped`; manifest-driven
  iteration cannot silently drop a check; no `|| true` anywhere.
- **Single span stream serves dashboard, issue-opener, factory-loop
  pre-merge gate** (criterion d). OpenTelemetry decomplects verdict
  emission from consumption — sibling **operability** subproblem consumes
  the same stream without extra plumbing.
- **Reuses ecosystem patterns** (criterion d): SonarQube baseline,
  OpenTelemetry OTLP, CodeClimate waiver model, Sentry release-health,
  Flagger canary halts. Bespoke surface limited to the FF modules
  themselves, justified because no off-the-shelf check understands Tau's
  `SPEC §4` / D-NNN / Appendix B conventions.
- **Forward-compatible with audit ingestion** (sibling
  **knowledge-memory-and-audit-ingestion**): a new audit finding becomes
  a new entry in `fitness.toml` plus a new FF module — same shape, same
  enforcement, same dashboard view.
- **Failure → action is mechanical.** Sentry/Flagger pattern: a `:fail`
  marks `main` degraded and the factory's pre-merge gate refuses new
  merges until resolved or explicitly waived. No "follow-up issue"
  deflection.
- **Property-test friendly.** Each FF is a pure function over a
  snapshot — ideal for StreamData property tests and golden fixtures.

### Weaknesses

- **Manifest can rot.** If `fitness.toml` is edited carelessly (a
  required FF demoted to non-required, an FF removed), the suite weakens
  without anyone noticing. Mitigation: a meta-FF (FF-000) that asserts
  the manifest at HEAD is a superset of the manifest from the most
  recent tagged release; manifest-shrinking requires an ADR. Cost: a new
  enforcement surface to maintain.
- **Waivers can become permanent debt** if no human watches the expiry.
  Mitigation: the dashboard's release-health view highlights waivers in
  their final 7 days red; the OperationsAndHygiene sibling owns
  surfacing this. Risk remains: a waiver can be renewed indefinitely by
  PR. Renewal requires re-justification, but enforcement is social.
- **OpenTelemetry exporter complexity.** Adds an OTLP endpoint to the
  factory's operational dependencies; offline / sandboxed CI runs need a
  null exporter fallback. Cost: one more moving piece.
- **GitHub-issue-opener is a side effect with a token.** The Action
  needs `issues: write` and `GH_TOKEN`; misconfiguration silently
  prevents issue creation. Mitigation: the OTLP span is the source of
  truth; the issue is a notification. The reporter logs a structured
  error when issue creation fails but does NOT change the verdict.
- **`Tau.Fitness.Snapshot.capture/1` is non-trivial.** Parsing every
  SPEC's §4 to extract "named symbols" is bespoke; brittle to SPEC
  format drift. Mitigation: SPEC §4 is constrained to a fenced
  block with declared schema (an upstream amendment to
  `spec-before-code.md`) — but that amendment is a prerequisite, not a
  given.
- **Daily cron + per-push triggers means redundant runs.** Cost is
  small (one CI minute), but noisy. Mitigation: dedupe on SHA in the
  reporter.
- **The fitness functions themselves are code that can have bugs.** An
  FF that false-passes is invisible; an FF that false-fails wastes
  cycles. Mitigation: each FF ships with a golden-fixture test
  (positive: a v1 bug it must detect; negative: a `main` snapshot it
  must pass against) and a StreamData property where applicable.

### Costs

- **New Mix project**: ~12 modules + manifest + waiver registry +
  schemas + ~6 FF modules with tests each. Estimate: ~1500 LoC initial.
- **New CI workflow**: `.github/workflows/main-coherence.yml` (~40
  lines).
- **New runtime dependency**: `opentelemetry_exporter` (+
  `opentelemetry_api`, already in Tau for B3 — check). If absent, add.
- **Operational cost**: OTLP collector endpoint (or a self-hosted
  Jaeger / Tempo / SigNoz instance for the dashboard). Or a file-based
  collector for the MVP, swappable later. Sibling **operability** owns
  the receiving surface.
- **One-off content cost**: SPEC §4 sections must be parseable. PR to
  `spec-before-code.md` to add a fenced-block schema constraint —
  modest amendment, one PR.
- **Documentation**: ADR explaining the fitness-function model and the
  manifest-evolution policy.
- **Cadence**: ~1 CI minute per push + ~1 CI minute per day. Negligible
  $.

## Dependencies

- **spec-before-code.md amendment**: SPEC §4 declares symbols in a
  fenced block with a stable schema (so FF-002 can parse mechanically).
  Estimate: one small PR.
- **Sibling pre-merge-evidence-and-skip-integrity solution** must
  guarantee CI's `mix tau.fitness.run` step is never wrapped in `|| true`
  and the workflow has no `continue-on-error` — this proposal *assumes*
  that invariant is enforced upstream of itself; without it, fitness
  functions can be silently neutered at the workflow layer.
- **Sibling operability-and-hygiene-enforcement** consumes the OTLP
  stream and presents the dashboard view; that integration must exist
  for criterion (c)'s "alarm the dashboard" half. If absent at v2
  launch, the issue-opener half (criterion c first half) still works
  standalone.
- **Sibling knowledge-memory-and-audit-ingestion** writes its outputs
  as new FF entries; needs an agreed shape (FF module + manifest entry).
- **GitHub Actions secrets**: `GH_TOKEN` with `issues: write`,
  `contents: read`, `actions: read`. Repository setting.
- **Optional**: an OTLP collector. For the MVP, a JSON file under
  `_build/fitness/verdicts.json` is sufficient; the dashboard reads it
  via a Phoenix LiveView in the operability sibling.

## Confidence

**High** for the fitness-function-as-discipline core (Ford/Parsons/Kua's
pattern is widely deployed in industry — ThoughtWorks Technology Radar
elevated it to Adopt in 2018), the SonarQube baseline-manifest shape,
and the loud-failure verdict enum (OTP system-test convention is
boringly battle-tested). **Medium** for the OTLP-as-single-source-of-
truth coupling — viable but introduces operational dependency on a
collector; if rejected, a JSON-file fallback degrades the dashboard
side without weakening the core gate. **Medium** for the SPEC §4
parseability assumption — requires a small upstream amendment to
`spec-before-code.md`; high-confidence achievable but not free.

What would raise confidence to high across the board: a 1-day spike
implementing FF-001 (D-NNN uniqueness) end-to-end against the current
`main` and verifying it detects the known duplicates in the codebase
(if any) while emitting an OTLP span the operability dashboard renders.

## Prior art / references

- **Ford, Parsons, Kua — *Building Evolutionary Architectures* (O'Reilly,
  2017; 2nd ed. 2022)**: the canonical text on architectural fitness
  functions. Chapter 2 defines the term; Chapter 5 covers
  cross-component / "holistic" fitness functions, which is what this
  leaf needs.
- **ThoughtWorks Technology Radar (Vol. 19, Apr 2018)**: architectural
  fitness functions elevated to "Adopt."
- **SonarQube Quality Gates** —
  <https://docs.sonarsource.com/sonarqube-server/latest/instance-administration/analysis-functions/quality-gates/>:
  baseline-manifest model; "new code" vs "overall code" partition;
  required/optional conditions; mandatory pass/fail emission.
- **CodeClimate Maintainability + Technical Debt** —
  <https://docs.codeclimate.com/docs/maintainability>: debt ratio as
  baseline; the waiver-with-expiry pattern is adapted from CodeClimate's
  issue snooze + reopening flow.
- **Sentry Release Health** —
  <https://docs.sentry.io/product/releases/health/>: a release is
  "healthy / unhealthy / degraded" based on automated post-deploy
  signals; halts deployment of subsequent releases under a degraded
  state.
- **OpenTelemetry "Post-Deploy Verification"** — Honeycomb, Lightstep,
  Tempo, and the OTel community pattern of emitting deploy-marker
  spans + automated verification spans on the same trace; consumers
  subscribe rather than scrape logs.
- **Erlang/OTP `common_test` and system-test discipline** —
  Joe Armstrong's "let it crash" philosophy applied at the test
  level: a system test that detects a regression *fails*; there is no
  "warning" state. Adapted here as the no-`:warning`-status invariant.
- **LaunchDarkly Release Guard / Flagger canary analysis** —
  <https://docs.flagger.app/usage/metrics>: a canary analysis emits a
  pass/fail decision after a defined window; the deployment proceeds
  or rolls back automatically. Adapted as "degraded `main` blocks new
  merges until resolved."
- **GitHub's own ruleset / required-checks** —
  <https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets>:
  enforces that named required checks must pass before merge; the
  `main-coherence` job is added to the required-check list, closing
  the loop between fitness verdict and pre-merge gate (criterion d's
  reuse — branch protection is GitHub-native, not bespoke).
- **Project-internal**: existing `.github/workflows/ci.yml` and the
  `mix tau.gate.ac_linkage` / `mix tau.gate.masking` / `mix
  tau.gate.mutation` Mix tasks established by PR-B / issue #370 are
  the *per-PR* precedent — the fitness suite is the *per-`main`*
  generalisation of that same shape.
