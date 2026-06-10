---
template_version: 1
template_name: proposal
proposal_id: 1
parent_problem: ../problem.md
---

# Proposal 1: Manifest-extractor + pure-predicate suite + always-emit verdict sink (first-principles)

## Approach

Make cross-artifact coherence a **pure function over a typed manifest
of the repository at a commit**. Build the system as five composable
layers, each with a single responsibility and a machine-checkable
output:

1. **Extractors** (`lib/tau/coherence/extract/*`) — pure modules that
   walk `lib/`, `test/`, `docs/spec/`, `docs/adr/`, and `.claude/` and
   emit a typed `%Tau.Coherence.Manifest{}` struct. One extractor per
   artifact kind: `DnnnIndex`, `SpecContracts`, `AdrGraph`,
   `SourceMap`, `TelemetrySites`, `TelemetryConsumers`.
2. **Predicates** (`lib/tau/coherence/check/*`) — pure functions
   `Manifest.t() -> [Finding.t()]`. One module per failure-class
   axis: `DnnnUniqueness`, `SpecSymbolResolution`,
   `SpecContradiction`, `AdrSupersession`,
   `TelemetryConsumerCumulative`. Each predicate is total: it always
   returns either `{:ok, []}` (no findings, *checked*) or
   `{:ok, [%Finding{}, ...]}`. The `:ok` wrapper is the
   silent-skip-impossibility primitive — there is no third return.
3. **Runner** (`Mix.Tasks.Tau.Coherence.Run`) — orchestrates all
   extractors and predicates, writes a single JSON verdict file
   `_build/coherence/verdict-<sha>.json` whose schema requires a
   `checks: [...]` array containing exactly one entry per
   registered predicate. A predicate that crashes is recorded as
   `status: "infrastructure_failure"` — which is itself a failing
   verdict, not a skip.
4. **Sink** (`.github/workflows/main-coherence.yml`) — triggered on
   `push: branches: [main]` and on `schedule: cron: '0 6 * * *'`.
   Runs the runner, uploads the verdict JSON as an artifact, calls
   `Mix.Tasks.Tau.Coherence.OpenIssue` on any non-empty findings (the
   task is idempotent — it dedupes by a content hash so identical
   findings collapse onto one open issue), and posts the verdict
   summary to a project-wide `coherence` GitHub status check the
   operability dashboard subscribes to.
5. **Verdict consumer contract** — the verdict JSON schema is
   published at `priv/coherence/verdict.schema.json` and the
   operability sibling reads it directly; no prose interface.

Silent-skip impossibility is achieved structurally: the runner
**enumerates registered predicates** from a compile-time registry
(`Tau.Coherence.Registry`); the workflow asserts the verdict's
`checks` length equals the registry length (a build-time exported
constant). A missing predicate fails the workflow.

## Rationale

The complecting hypothesis identifies three weaves: (a) "what a SPEC
says" is woven with "what the codebase does" through prose source-
maps; (b) "when a contradiction was introduced" is woven with "which
PR introduced it" because checks run per-PR; (c) "D-NNN uniqueness"
is woven with "did the author remember to grep." This proposal
decomplects all three by making the manifest the **single source of
ground truth** that every predicate consumes uniformly. The
manifest is not a SPEC and not code — it is the *extracted facts*
from both. Predicates compare facts; facts come from extractors;
extractors are pure. The runner does not know what a SPEC is; the
predicate does not know what a file is. Each layer has one job. The
silent-skip class is dissolved because every predicate is a total
function over the manifest — there is no "skip" arm to its return
type. The "checked, no findings" case is `{:ok, []}`, which is
*data*, not the absence of data; the workflow asserts data is
present for every predicate.

## Sketch

### Manifest shape (`lib/tau/coherence/manifest.ex`)

```elixir
defmodule Tau.Coherence.Manifest do
  @moduledoc "Typed facts extracted from the repo at a commit."

  @type t :: %__MODULE__{
          sha: String.t(),
          dnnn_index: %{(id :: String.t()) => [Occurrence.t()]},
          spec_contracts: [SpecContract.t()],
          adrs: [Adr.t()],
          source_maps: %{(spec_id :: String.t()) => [Path.t()]},
          telemetry_sites: [TelemetrySite.t()],
          telemetry_consumers: [TelemetryConsumer.t()]
        }

  defstruct [:sha, :dnnn_index, :spec_contracts, :adrs,
             :source_maps, :telemetry_sites, :telemetry_consumers]
end

defmodule Tau.Coherence.Manifest.SpecContract do
  @type t :: %__MODULE__{
          spec_id: String.t(),     # "SPEC-PERMISSION-PROMPTS"
          section: String.t(),     # "§4 B5"
          dnnn_ids: [String.t()],  # ["D-090", ...]
          symbols: [Symbol.t()],   # named module/function/struct/callback
          invariants: [Invariant.t()] # {axis, predicate} pairs
        }
  defstruct [:spec_id, :section, :dnnn_ids, :symbols, :invariants]
end
```

### Predicate contract (`lib/tau/coherence/check.ex`)

```elixir
defmodule Tau.Coherence.Check do
  @callback name() :: String.t()
  @callback applies_to(Manifest.t()) :: boolean()
  @callback run(Manifest.t()) :: {:ok, [Finding.t()]} | {:error, term()}

  # Note: no `:skip` constructor. {:ok, []} means "checked, none found."
  # `:error` is a hard failure — runner records it as infrastructure_failure.
end

defmodule Tau.Coherence.Finding do
  @type severity :: :blocker | :warn
  @type t :: %__MODULE__{
          check: String.t(),
          severity: severity(),
          locations: [{Path.t(), pos_integer()}],
          message: String.t(),
          dedup_key: String.t() # SHA256 of (check, locations, message_template)
        }
  defstruct [:check, :severity, :locations, :message, :dedup_key]
end
```

### A concrete predicate — `SpecContradiction` (catches the PERMISSION-PROMPTS B5/D-171 case)

```elixir
defmodule Tau.Coherence.Check.SpecContradiction do
  @behaviour Tau.Coherence.Check

  @impl true
  def name, do: "spec_contradiction"

  @impl true
  def applies_to(%Manifest{spec_contracts: cs}), do: length(cs) > 0

  @impl true
  def run(%Manifest{spec_contracts: contracts}) do
    findings =
      contracts
      |> Enum.flat_map(& &1.invariants)
      |> Enum.group_by(& &1.axis)               # {:permission_modes, _}
      |> Enum.flat_map(&detect_conflicts/1)
    {:ok, findings}
  end

  defp detect_conflicts({axis, [_one]}), do: []
  defp detect_conflicts({axis, invariants}) do
    case Enum.uniq_by(invariants, & &1.value) do
      [_one] -> []
      multiple ->
        [%Finding{
          check: "spec_contradiction",
          severity: :blocker,
          locations: Enum.map(multiple, & &1.location),
          message: "Axis #{axis} has conflicting values: " <>
                   Enum.map_join(multiple, ", ", &"#{&1.value} (#{loc(&1)})"),
          dedup_key: dedup(axis, multiple)
        }]
    end
  end
end
```

When the extractor parses SPEC-PERMISSION-PROMPTS, the `permission_modes`
axis appears with value `6` (§4 B5) and value `3` (§6 D-171); the
predicate emits a blocker finding on first run.

### Registry (compile-time, makes "I forgot to register my check" impossible to silent-skip)

```elixir
defmodule Tau.Coherence.Registry do
  @checks [
    Tau.Coherence.Check.DnnnUniqueness,
    Tau.Coherence.Check.SpecSymbolResolution,
    Tau.Coherence.Check.SpecContradiction,
    Tau.Coherence.Check.AdrSupersession,
    Tau.Coherence.Check.TelemetryConsumerCumulative
  ]
  def all, do: @checks
  def count, do: length(@checks)
end
```

### Runner (`lib/mix/tasks/tau.coherence.run.ex`)

```elixir
defmodule Mix.Tasks.Tau.Coherence.Run do
  use Mix.Task
  @shortdoc "Run cross-artifact coherence checks on current tree"

  def run(_argv) do
    manifest = Tau.Coherence.Extractor.build(File.cwd!())
    checks = Tau.Coherence.Registry.all()

    results =
      Enum.map(checks, fn mod ->
        try do
          case mod.run(manifest) do
            {:ok, findings} -> {mod.name(), :checked, findings}
            {:error, reason} -> {mod.name(), :infrastructure_failure, reason}
          end
        rescue
          e -> {mod.name(), :infrastructure_failure, Exception.message(e)}
        end
      end)

    verdict = build_verdict(manifest.sha, results)
    File.mkdir_p!("_build/coherence")
    File.write!("_build/coherence/verdict-#{manifest.sha}.json",
                Jason.encode!(verdict, pretty: true))

    exit_code = if any_blocker_or_infra_failure?(results), do: 1, else: 0
    System.halt(exit_code)
  end
end
```

Note the deliberate `try/rescue` — this is in a Mix task, NOT across
a process boundary, and exists solely to convert a crashed predicate
into an `infrastructure_failure` verdict. NN #7 forbids rescue
*across process boundaries*; a Mix task is a single OS process and
this rescue is the recording mechanism for silent-skip impossibility,
not a swallowed error.

### Verdict schema (`priv/coherence/verdict.schema.json`)

```json
{
  "$id": "https://tau/coherence/verdict.schema.json",
  "type": "object",
  "required": ["sha", "ran_at", "checks", "registry_count"],
  "properties": {
    "sha": {"type": "string", "pattern": "^[0-9a-f]{40}$"},
    "ran_at": {"type": "string", "format": "date-time"},
    "registry_count": {"type": "integer", "minimum": 1},
    "checks": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["name", "status", "findings"],
        "properties": {
          "name": {"type": "string"},
          "status": {"enum": ["checked", "infrastructure_failure"]},
          "findings": {"type": "array", "items": {"$ref": "#/$defs/finding"}}
        }
      }
    }
  }
}
```

Workflow asserts: `len(verdict.checks) == verdict.registry_count`
AND every predicate name in `Tau.Coherence.Registry` appears in
`verdict.checks`. A predicate that fails to run cannot disappear; a
predicate added without runner-wiring fails the registry-equality
assertion.

### Source-map manifest (decomplecting "prose Appendix B" from "what the check uses")

Each SPEC grows a sidecar `docs/spec/SPEC-*.source-map.yaml` (or the
extractor parses Appendix B if the sidecar is absent; sidecar wins
when both exist):

```yaml
spec_id: SPEC-PERMISSION-PROMPTS
binds:
  - path: lib/tau/session.ex
    symbols: [Tau.Session.set_permissions_mode/2]
    invariants: [D-090, D-091]
  - path: lib/tau/session/events.ex
    symbols: [Tau.Session.Events.PermissionRequest]
```

Extractor reads the sidecar; `SpecSymbolResolution` predicate uses
`Sourceror` (already a peer of `Mix` for Tau, used by `mix
format`) to confirm each symbol resolves in the current `main`
checkout. A missing symbol emits a blocker finding citing both the
SPEC line and the missing module path.

### Workflow (`.github/workflows/main-coherence.yml`)

```yaml
name: main-coherence
on:
  push:
    branches: [main]
  schedule:
    - cron: '0 6 * * *'
permissions:
  contents: read
  issues: write

jobs:
  coherence:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: erlef/setup-beam@v1
        with: {otp-version: '27.2', elixir-version: '1.18.1'}
      - run: mix deps.get && mix compile --warnings-as-errors
      - run: mix tau.coherence.run
        id: coherence
      - name: Verify verdict completeness (silent-skip guard)
        run: |
          REG=$(mix run --no-start -e 'IO.puts(Tau.Coherence.Registry.count())')
          CHK=$(jq '.checks | length' _build/coherence/verdict-*.json)
          test "$REG" = "$CHK" || { echo "Verdict missing checks"; exit 2; }
      - uses: actions/upload-artifact@v4
        with: {name: coherence-verdict, path: _build/coherence/}
      - name: Open or update issue on failure
        if: failure()
        run: mix tau.coherence.open_issue _build/coherence/verdict-*.json
        env: {GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}}
      - name: Post status to dashboard
        if: always()
        run: mix tau.coherence.publish_status _build/coherence/verdict-*.json
```

`if: always()` on the publish step is the verdict-consumption
guarantee: the dashboard ALWAYS sees a verdict (pass or fail or
infrastructure_failure), never a vacuum.

### Build-order

The build proceeds bottom-up so each layer is testable in isolation
and gates the next.

1. **Manifest types and extractor for `DnnnIndex`** (smallest
   surface, no SPEC parsing needed; regex-only). Property test:
   extractor is a pure function of repo state.
2. **`DnnnUniqueness` predicate + runner skeleton + verdict schema +
   silent-skip guard test.** Predicate emits findings for any
   already-violated D-NNN identifier; this proves the substrate.
3. **`AdrSupersession` predicate.** ADRs are smaller-surface than
   SPECs; extractor proves the `AdrGraph` shape; predicate validates
   bidirectional supersession links.
4. **SPEC source-map sidecars** authored for each catalog entry,
   gating the next predicate. SPEC-PERMISSION-PROMPTS,
   SPEC-USER-TURN, SPEC-TUI-HEADLESS first (they have the most §4
   surface). Initial CI workflow runs steps 1–3 from this point.
5. **`SpecSymbolResolution` predicate.** Extractor uses `Sourceror`
   to resolve symbols; predicate emits a blocker per unresolved.
6. **`SpecContradiction` predicate.** First check, on a known case
   (PERMISSION-PROMPTS B5/D-171), MUST emit a blocker; this is the
   regression-fixture acceptance test.
7. **`TelemetrySite` and `TelemetryConsumer` extractors** plus
   `TelemetryConsumerCumulative` predicate. Reuses extractor work
   from the pre-merge-code-gates sibling (its per-PR extractor and
   this one share `Tau.Coherence.Extract.Telemetry`).
8. **Issue-opener and dashboard publish tasks**
   (`Mix.Tasks.Tau.Coherence.OpenIssue`,
   `Mix.Tasks.Tau.Coherence.PublishStatus`). The opener dedupes by
   `dedup_key`; the publisher writes to the operability sibling's
   verdict ingest endpoint per its published contract.
9. **`main-coherence.yml` wired on `push: branches: [main]` AND
   `schedule: cron`**, with the silent-skip guard step. This is the
   merge-blocking activation point for the workflow itself.
10. **Backfill pass on current `main`** — run the suite against the
    current HEAD, file issues for every finding (the
    PERMISSION-PROMPTS contradiction surfaces here), close the
    issues by remediation, *then* the steady-state guarantee holds.

Each step is a single PR; each PR's AC declares the predicate(s) it
adds and a regression-fixture test in `test/tau/coherence/` that
proves the predicate emits the expected finding on a planted
contradiction.

## Tradeoffs

### Strengths

- **Silent-skip is structurally impossible**, not policy. The check
  callback signature has no `:skip` arm. The runner records every
  registered predicate, the verdict schema requires non-empty
  `checks`, and the workflow asserts registry-count equality.
  Removing a predicate from the runner without removing it from the
  registry fails the workflow; adding one to the registry without
  wiring also fails.
- **Decomplects facts from predicates from execution from sink.**
  Adding a new contradiction class is a single new predicate file
  plus a registry entry — no workflow change, no schema change. Per
  Hickey: simple = un-braided.
- **Verdicts are typed data with a published JSON schema** — the
  operability sibling consumes them by reading a file, not by parsing
  prose; the dashboard contract is `priv/coherence/verdict.schema.json`,
  which is version-controlled.
- **Predicates are pure functions over the manifest** — property-
  testable with `StreamData` against synthetic manifests, per Tau's
  invariant-bearing-modules convention (OTP NN #6).
- **Failure-class #9 caught on first run** by the regression-fixture
  test: the PERMISSION-PROMPTS B5/D-171 contradiction surfaces as a
  blocker finding when the suite is wired.
- **D-NNN uniqueness mechanized**, dissolving the "did the author
  grep" weave: extractor scans `lib/`, `test/`, `docs/`, `.claude/`
  in one pass and the predicate emits a blocker per duplicate.

### Weaknesses

- **Manifest extraction is the bottleneck for correctness.** A SPEC
  whose Appendix B is prose without a sidecar may extract incomplete
  source-maps; the suite's coverage is bounded by extractor
  completeness. Mitigation: sidecar requirement in
  `spec-before-code.md` and a meta-predicate
  `SourceMapPresence` that emits a finding for any SPEC missing a
  sidecar (so the gap surfaces as a finding, not as silent partial
  coverage). Still, a sidecar that lies about its bindings can't be
  caught without symbol resolution — the next predicate does that,
  so the gap closes on the second check, not the first.
- **`SpecContradiction` predicate depends on an "axis" tag in the
  extracted invariant**, which means SPEC authors must declare a
  machine-readable axis identifier alongside each invariant (e.g.
  `<!-- axis: permission_modes -->` in the SPEC source or in the
  sidecar). Existing SPECs need a one-time annotation pass. Without
  annotation the predicate cannot distinguish "same axis with
  conflicting values" from "two unrelated values that happen to be
  near each other."
- **Backfill pass (Build-order step 10) may surface dozens of
  findings on current `main`.** The factory cannot enforce "no
  blocker findings on `main`" until the backfill is remediated;
  there is a window where the daily-cadence run will fail every day.
  Mitigation: the workflow opens *issues*, not auto-reverts;
  remediation is incremental. The "fails-loud-rather-than-silent"
  promise still holds.
- **Telemetry consumer extraction has to model Phoenix.PubSub
  handlers and `:telemetry.attach`-based handlers**; both forms
  must be recognized. A non-standard handler registration (a custom
  GenServer that subscribes via undocumented means) will be invisible
  and produce a false-positive "no consumer" finding. Mitigation:
  the predicate is `:warn` severity, not `:blocker`, until the
  consumer-registration convention is canonicalized in the
  pre-merge sibling.
- **Daily cron may file duplicate issues** if dedup is implemented
  naively. Dedup is by `dedup_key = SHA256(check, locations,
  message_template)`; the opener consults open issues with the same
  key first. Adds operational complexity.

### Costs

- **New code surface:** ~6 extractors (200 LOC each) + 5 predicates
  (~150 LOC each) + manifest types + runner + opener + publisher =
  roughly **2200 LOC of Elixir** plus ~400 LOC of test scaffolding,
  spread across ~10 PRs in the Build-order.
- **New dependencies:** `Sourceror` (Hex package, MIT-licensed; used
  by `mix format` already, so no transitive impact on the build).
  No new test deps — `ExUnit` + existing `StreamData`.
- **SPEC sidecar authoring:** one ~50-line YAML file per SPEC in the
  catalog; currently 11 SPECs → ~550 lines of curated YAML, written
  by the SPEC author when authoring or amending a SPEC. Authored once
  per SPEC; amended only when the SPEC's source-map changes.
- **CI minutes:** one workflow per `push: branches: [main]` + one
  per day; estimated 4-6 minutes per run. Negligible vs current
  `lint` and `mutation-check` jobs.
- **Storage:** verdict JSON ~10 KB per run, retained as an artifact
  for 90 days = ~100 verdicts × 10 KB = 1 MB. Negligible.

## Dependencies

- **Pre-merge-code-gates sibling** publishes the
  `Tau.Coherence.Extract.Telemetry` extractor (shared module) — if
  it hasn't, this proposal builds it and that sibling consumes from
  here. Either direction works; one author per module.
- **Operability-and-hygiene-enforcement sibling** publishes a
  verdict-ingest contract (a file path the dashboard polls, or an
  HTTP endpoint the publisher posts to). Until that contract exists,
  the publisher writes to `_build/coherence/published/` as a stub
  and the operability sibling reads from there.
- **`spec-before-code.md` rule update** — add "every SPEC in the
  catalog MUST have a `SPEC-*.source-map.yaml` sidecar" as an
  invariant. Without the rule update, the meta-predicate
  `SourceMapPresence` is the only enforcement and SPEC authors may
  not understand why the daily check is failing on new SPECs.
- **Knowledge-memory-and-audit-ingestion sibling** writes structured
  audit findings in the same `%Finding{}` shape this proposal
  defines, so the dashboard can render both kinds uniformly — this
  is a shared-type opportunity, not a hard dependency.

## Confidence

**High.** The substrate is composed of well-understood primitives:
pure-function manifests, total predicates, JSON-schema-validated
verdicts, and a GitHub Actions workflow with a registry-equality
guard. The hardest design risk (silent-skip impossibility) is
discharged by a typing argument: the callback signature lacks a skip
arm and the verdict schema requires non-empty `checks`. The PERMISSION-
PROMPTS B5/D-171 case is a concrete regression fixture that proves
the substrate works on first run. What would lower confidence: a
SPEC corpus too varied for the axis-tag convention to land cleanly
on the first try — but the design lets the predicate emit findings
incrementally as axes are tagged, with no all-or-nothing migration.

## Prior art / references

- **Sourceror** (`https://github.com/doorgan/sourceror`) — Elixir
  AST traversal already used by `mix format`; relied on for symbol
  resolution in `SpecSymbolResolution`.
- **JSON-schema-validated CI verdicts** — pattern from
  CodeQL/CodeScan SARIF format; same hardness against silent-skip.
- **Tau's own `Tau.Factory.Gate`** (per `factory-loop.md`) — the
  three mechanical gates already follow this pattern (pure function +
  CLI wrapper + CI wire); this proposal extends the pattern to
  `main`-side checks rather than per-PR.
- **OTP behaviours** — predicates are behaviours (`@callback`); the
  registry uses module pattern matching, consistent with OTP NN #2.
