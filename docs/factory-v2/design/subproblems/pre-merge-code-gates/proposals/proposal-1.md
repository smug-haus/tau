---
template_version: 1
template_name: proposal
proposal_id: 1
parent_problem: ../problem.md
---

# Proposal 1: In-repo AST-checker substrate with enumerator-manifest contract (`Tau.Gate.CodeShape`)

## Approach

Build a single in-repo Elixir library, `Tau.Gate.CodeShape`, that exposes four
independent analyzers — `Tau.Gate.CodeShape.Contracts`,
`Tau.Gate.CodeShape.NoRescue`, `Tau.Gate.CodeShape.CapabilityFidelity`,
`Tau.Gate.CodeShape.TelemetryConsumers` — each implementing a
`Tau.Gate.CodeShape.Analyzer` behaviour with the callbacks `inputs/1`,
`analyze/2`, `name/0`, and `description/0`. A driver Mix task
`Mix.Tasks.Tau.Gate.CodeShape` runs every registered analyzer over the
production-code diff, writes one JSON verdict file per analyzer to
`_build/tau-gate/<analyzer>.json`, and exits non-zero if any analyzer reports
violations OR if any analyzer's `inputs/1` returns `[]` without a matching
written acknowledgement under `priv/tau/gate/manifests/<analyzer>.empty.toml`.
The CI workflow file `.github/workflows/tau-gate-code-shape.yml` invokes the
task as a required status check on every PR; the verdict JSONs are uploaded
as workflow artifacts and consumed by the merge gate.

## Rationale

The complecting hypothesis names two strands: (a) the four checks are
complected with "the agent's word" because today only the critic/reviewer pair
reads the diff, and (b) "no findings" is complected with "no inputs scanned"
because silent skip is indistinguishable from clean output. This proposal
decomplects both by reifying the input set as an explicit, returned data
structure (`inputs/1` is a callback, not a comment) and by making
`length(inputs) == 0` a deterministic per-PR failure unless accompanied by a
written empty-justification manifest. The four analyzers share an
enumerate-then-analyze skeleton and a verdict schema, but each implements one
failure class — they are composed by the driver, not woven together. The
Analyzer behaviour is the seam the post-merge coherence sibling and the audit-
ingestion sibling reuse, so the substrate is grown, not duplicated.

## Sketch

### Behaviour and verdict shape

```elixir
defmodule Tau.Gate.CodeShape.Analyzer do
  @moduledoc """
  An analyzer enumerates its inputs and produces a verdict.

  Inputs are returned explicitly so that an empty input set is a
  deterministic, machine-checkable condition — not silent skip.
  """

  @type input :: %{path: String.t(), module: module() | nil, meta: map()}
  @type finding :: %{
          severity: :error | :warning,
          input: input(),
          location: String.t(),
          rule: atom(),
          message: String.t()
        }
  @type verdict :: %{
          analyzer: atom(),
          inputs: [input()],
          findings: [finding()],
          started_at: DateTime.t(),
          finished_at: DateTime.t()
        }

  @callback name() :: atom()
  @callback description() :: String.t()
  @callback inputs(opts :: keyword()) :: [input()]
  @callback analyze(inputs :: [input()], opts :: keyword()) :: [finding()]
end
```

### File layout

```
lib/tau/gate/code_shape.ex                      # registry + driver
lib/tau/gate/code_shape/analyzer.ex             # behaviour above
lib/tau/gate/code_shape/contracts.ex            # failure class #1
lib/tau/gate/code_shape/no_rescue.ex            # failure class #2
lib/tau/gate/code_shape/capability_fidelity.ex  # failure class #3
lib/tau/gate/code_shape/telemetry_consumers.ex  # failure class #4
lib/mix/tasks/tau.gate.code_shape.ex            # CLI entry point
priv/tau/gate/manifests/                        # empty-input acks (toml)
test/tau/gate/code_shape/                       # property + golden tests
.github/workflows/tau-gate-code-shape.yml       # required status check
```

### Analyzer #1 — Contracts (`@behaviour` completeness + struct existence)

`inputs/1` returns every module in `lib/` that has at least one `@behaviour`
attribute, plus every module that names a `%Foo{}` struct in a `@spec` or
`@doc` block. `analyze/2` parses each module with `Code.string_to_quoted/1`
(via `Sourceror` for whitespace-preserving traversal), resolves the behaviour
module's `@callback` set, and emits a finding for each callback not exported
at the declared arity. The struct-existence pass loads each named struct
module and emits a finding when `function_exported?(mod, :__struct__, 0)`
returns false. Output keys: `:missing_callback`, `:unknown_struct`,
`:behaviour_module_missing`.

### Analyzer #2 — NoRescue (NN #7 conformance)

`inputs/1` returns every `.ex`/`.exs` file under `lib/` and `test/support/`
(but not `test/`, where rescue is sometimes legitimate for assertion-fixture
construction; the exclusion list is data, in `priv/tau/gate/manifests/no_rescue.scope.toml`,
not code). `analyze/2` walks each file's AST and emits a finding for every
`try/rescue`, `try/catch :exit`, or bare `catch :exit` clause. Each finding
carries `file:line` and the matched clause source. There is no allowlist of
"legitimate" sites in code — the only way to suppress a finding is to add
an entry to `priv/tau/gate/manifests/no_rescue.waivers.toml` keyed by
`<file>:<line>` with a required `expires_at:` ISO-8601 date ≤ 90 days from
the entry's commit date (enforced by a property test on the manifest file
itself).

### Analyzer #3 — CapabilityFidelity

`inputs/1` returns every adapter module under `lib/tau/providers/` (or
configurably any module implementing `Tau.Provider`). `analyze/2`:

1. Loads the module and reads `module.capabilities/0` (or the equivalent
   `@capabilities` attribute).
2. Loads the lookup table `Tau.Gate.CodeShape.CapabilityFidelity.required_callbacks/0`,
   which is a pure map of `capability_atom => [{callback_name, arity}, ...]`,
   committed in the analyzer module itself (`prompt_caching` =>
   `[{:cache_regions, 2}]`, `tool_use` => `[{:tools, 1}, {:render_tool_call, 2}]`,
   etc.).
3. For every flag set true, checks `function_exported?/3` for every required
   callback. Emits `:capability_flag_without_callback` finding for each gap.

The capability → callback map is a data table — adding a new capability is a
PR that touches the map; the gate then fails any adapter that opts in
without exporting the callback. This is the exact mechanism root §B cites as
the model.

### Analyzer #4 — TelemetryConsumers

`inputs/1` returns every distinct event name passed to `:telemetry.execute/2`
or `:telemetry.execute/3` in `lib/`, discovered by an AST traversal that
matches `{{:., _, [:telemetry, :execute]}, _, [event_list | _]}` and
evaluates literal `event_list` ASTs (non-literal event names fail the gate as
`:dynamic_event_name`, because we cannot prove a consumer exists for an event
we cannot name at compile time).

`analyze/2` then walks every module in `lib/` looking for
`:telemetry.attach`, `:telemetry.attach_many`, or
`:telemetry_metrics.<x>` calls, builds the set of consumed event prefixes,
and emits `:telemetry_event_without_consumer` for each emitted event with no
matching consumer prefix. Test-only attaches (modules under `test/`) are
ignored by construction (`inputs/1` only walks `lib/`); `Logger`-only
consumers are excluded by a small allow-list of handler-module names in
`priv/tau/gate/manifests/telemetry.consumer_kinds.toml` (`Tau.Telemetry.Handler`,
`Tau.OtelReporter`, etc. — the allow-list is itself audited because adding to
it requires a PR).

### Driver and silent-skip-impossibility

```elixir
defmodule Mix.Tasks.Tau.Gate.CodeShape do
  use Mix.Task
  @impl true
  def run(argv) do
    Mix.Task.run("compile")

    analyzers = [
      Tau.Gate.CodeShape.Contracts,
      Tau.Gate.CodeShape.NoRescue,
      Tau.Gate.CodeShape.CapabilityFidelity,
      Tau.Gate.CodeShape.TelemetryConsumers
    ]

    verdicts = Enum.map(analyzers, &run_one(&1, argv))
    write_verdicts(verdicts)

    exit_code =
      cond do
        Enum.any?(verdicts, &(&1.findings != [])) -> 1
        Enum.any?(verdicts, &empty_inputs_unjustified?/1) -> 2
        Enum.any?(verdicts, &(&1.error != nil)) -> 3
        true -> 0
      end

    System.halt(exit_code)
  end
end
```

`empty_inputs_unjustified?/1` returns true when `inputs == []` AND no file
matching `priv/tau/gate/manifests/<analyzer_name>.empty.toml` exists with a
non-empty `reason:` field whose `expires_at:` is in the future. The check is
mechanical: empty inputs without justification → exit 2 → CI red.

Exit-code semantics are part of the contract:

| code | meaning                         |
|------|---------------------------------|
| 0    | every analyzer ran; no findings |
| 1    | at least one finding            |
| 2    | empty inputs without manifest   |
| 3    | analyzer crashed (treated as failure, NEVER skipped) |

### CI workflow

```yaml
# .github/workflows/tau-gate-code-shape.yml
name: tau-gate-code-shape
on:
  pull_request:
  push: { branches: [main] }
jobs:
  code-shape:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: erlef/setup-beam@v1
        with: { otp-version: "27.2", elixir-version: "1.18.1" }
      - run: mix deps.get
      - run: mix compile --warnings-as-errors
      - run: mix tau.gate.code_shape
      - if: always()
        uses: actions/upload-artifact@v4
        with:
          name: tau-gate-code-shape-verdicts
          path: _build/tau-gate/*.json
```

The workflow is declared a **required status check** in the repo's branch
protection on `main`. The merge gate (owned by the
pre-merge-evidence-and-skip-integrity sibling) refuses merge when this check
is not green; this proposal's contract with that sibling is the JSON verdict
schema above plus the workflow name.

### Verdict consumption

The four verdict JSONs are the machine-checkable artifact. They are read
by:

- the merge gate (sibling sub-problem) — only the exit code is load-bearing,
  but the JSON is rendered into a sticky PR comment for human readability;
- the operability dashboard (sibling sub-problem) — aggregates verdicts
  across PRs to surface "analyzer X has been finding violations for N
  consecutive PRs" trends;
- the audit-ingestion sibling — historical audit findings are translated
  into analyzer manifests (e.g., a known `rescue` site enters
  `no_rescue.waivers.toml` with a `remediated_by:` issue link and a
  90-day `expires_at:`).

## Tradeoffs

### Strengths

- **Silent-skip impossibility is a property of the protocol, not a wish.**
  The `inputs/1` callback returns a list that the driver inspects; empty
  without a manifest is exit 2. There is no code path that produces "passed
  with nothing to check" by accident (root §C).
- **Every component is concrete.** Mix task name, behaviour module, analyzer
  modules, manifest directory layout, CI workflow filename, exit-code table,
  verdict JSON schema — all named in the sketch (root §B).
- **Bespoke is justified per check, in one place.** The four analyzers share
  a single behaviour, so the "reuse vs build" decision is made once at the
  Analyzer-callback boundary. Dialyzer's `@behaviour` warnings could feed the
  Contracts analyzer's `:missing_callback` rule via parsing Dialyzer PLT
  output, but Dialyzer cannot enforce struct existence in `@doc` strings —
  the bespoke AST pass is justified for that. The rationale belongs in
  each analyzer's `@moduledoc`.
- **Failure-class coverage is one-to-one.** Each of #1, #2, #3, #4 maps to
  one analyzer module; the spec satisfies root §A "exactly one mechanism per
  class" cleanly.
- **OTP non-negotiable conformance is enforced by the same substrate that
  enforces everything else.** NN #7 stops being prose; it becomes a list of
  `file:line` violations the gate refuses to merge.
- **Verdicts are independent of agent self-report.** The analyzers run in
  CI on the GitHub-hosted runner; their output is JSON; the merge gate keys
  on exit code. No agent's natural-language verdict is in the trust path
  (root §G).

### Weaknesses

- **AST analyzers have false-positive risk that requires a waiver mechanism,
  and waivers can themselves rot.** The `no_rescue.waivers.toml` 90-day
  expiry forces re-justification, but if 80% of `rescue` sites end up
  waived, the gate's signal degrades. There is no automated cap on waiver
  count — that gap is intentional (caps belong in the operability sibling's
  dashboard, not in this leaf), but it is a real weakness of this proposal
  taken alone.
- **TelemetryConsumers' dynamic-event-name rule is strict.** Code that
  computes event names at runtime (e.g., `[:tau, adapter_kind, :request,
  :stop]` where `adapter_kind` is a parameter) will fail the gate. The
  workaround is to enumerate the adapter kinds in the analyzer's manifest,
  which moves coupling from code into data — defensible but real.
- **Compile-cost grows with analyzer count.** The driver runs
  `mix compile` and then traverses every file under `lib/`. On the current
  Tau codebase this is fast (~3s for 200 files), but a four-fold scan plus
  Sourceror parsing will be perceptibly slower than a single pass. A future
  optimization is one AST walk that all four analyzers consume; this
  proposal does not pre-optimize for it.
- **The capability → callback map is a single point of editorial trust.**
  Adding a new capability without updating the map silently exempts that
  capability from gating. The mitigation is that the map's keys are an
  enumeration the Contracts analyzer's `Tau.Provider` callback check
  cross-references — but this is a second-order safety, not a first-order
  one. A reviewer could miss it.
- **No pre-existing community AST library covers the four checks; building
  in-repo means we own maintenance.** Sourceror is well-maintained, but
  the analyzer modules themselves are bespoke project code.

### Costs

- **Build cost.** Four analyzer modules (~150–300 LOC each), one behaviour
  module (~40 LOC), one driver Mix task (~120 LOC), one CI workflow file
  (~30 LOC), property tests for each analyzer (~200 LOC each), golden tests
  with representative violating fixtures (~50 LOC each). Total ~1.5–2.5
  kLOC of new code.
- **Dependency cost.** One new prod dependency on `:sourceror` (~80 KB).
  No new runtime cost — the analyzer code lives in `lib/` but only runs
  under `Mix.env() == :test` or under the `tau.gate.code_shape` task; it
  does not load in `prod` because Mix tasks are stripped from releases.
- **Migration cost.** Every existing `rescue`/`catch :exit` site under
  `lib/` (audit count: ~7+ with new ones accumulated) needs either removal
  or a waiver manifest entry. Every adapter with `prompt_caching: true`
  but no `cache_regions/2` (audit count: at least Bedrock per root #3)
  needs reconciliation in the same PR that introduces the gate. Every
  telemetry event with no consumer (audit count: 64.9% of 121 sites ≈ 78
  events) needs either a consumer or removal. This is intentional — the
  gate enables the cleanup work the prior audit already itemized.
- **Test surface impact.** Each analyzer gets property tests (e.g., "for
  any module without a `@behaviour`, the Contracts analyzer emits no
  `:missing_callback` finding") and golden tests (a known-bad fixture
  module exercised against the analyzer, expected JSON checked into
  `test/support/golden/`).
- **Knowledge cost.** One Elixir engineer fluent in AST traversal and one
  CI engineer familiar with required-status-check configuration. No new
  paradigm.

## Dependencies

- `:sourceror` (~> 1.0) added to `mix.exs` `:deps`.
- Branch protection on `main` updated to require the
  `tau-gate-code-shape / code-shape` status check (operationally done by
  the pre-merge-evidence-and-skip-integrity sibling, but this proposal
  cannot land without that being applied to the same workflow).
- The `Tau.Provider` behaviour and `capabilities/0` callback are stable;
  if they are refactored, the CapabilityFidelity analyzer's map needs
  migration.
- No dependency on Dialyzer being green — this proposal is independent of
  Dialyzer to avoid coupling the gate's failure mode to Dialyzer's
  occasional non-determinism on cross-module type inference.

## Confidence

**Medium-high.** The behaviour-based analyzer protocol is a direct
application of one OTP non-negotiable (#2 — extensibility seams are
behaviours) to the gate substrate itself. The exit-code-table protocol is
a well-trodden Unix idiom. The two pieces of risk that hold confidence
below "high" are: (a) the TelemetryConsumers dynamic-event-name policy
will require iteration once the real codebase's event-name patterns are
classified, and (b) the waiver-rot dynamic is a known unsolved gap that
this leaf intentionally hands off. Confidence rises to "high" with a
72-hour prototype that runs Contracts and NoRescue against the current
`lib/tau/` tree and produces verdicts the team agrees match their
expectations.

## Prior art / references

- `Mix.Tasks.Credo` (and its `--strict` mode) — same shape: CLI Mix task
  with non-zero exit, configurable checks, AST traversal. We could *embed*
  some analyzers as Credo plugins, but Credo's check API is per-file and
  does not natively express "enumerate inputs first" — the manifest
  contract is the load-bearing innovation this proposal preserves.
- `mix dialyzer` — provides behaviour-callback checks as warnings; we
  consume Dialyzer's output as one data source into the Contracts analyzer
  rather than depending on Dialyzer for verdict.
- `Sourceror` (Github: `doorgan/sourceror`) — the AST-traversal library
  used in Phoenix's `mix phx.gen.auth` for structural codemods; the same
  primitives suit per-file rule enforcement.
- The Mix.Tasks.Tau.Gate.* family already cited in root §B (current
  `mix tau.gate.ac_linkage`, `mix tau.gate.masking`, `mix tau.gate.mutation`)
  — this proposal extends the same pattern; the `CodeShape` task is the
  logical fourth member.

## Build-order

The proposal is shippable in five sequential PRs, each green-CI before the
next is opened. The build-order is itself the proof that the substrate is
incrementally adoptable rather than a big-bang rewrite.

1. **PR-1 — Substrate, no checks.** Land
   `Tau.Gate.CodeShape.Analyzer` behaviour, `Mix.Tasks.Tau.Gate.CodeShape`
   driver, verdict JSON schema, exit-code table, manifest-directory
   convention, and the CI workflow `tau-gate-code-shape.yml` registered
   with branch protection. The analyzer registry is empty in this PR — the
   task runs, finds no analyzers, returns exit 2 (no inputs unjustified)
   until a `priv/tau/gate/manifests/_no_analyzers.empty.toml` ack is added
   for this single bootstrap PR. Property test:
   "driver crashes if any analyzer crashes" must pass.

2. **PR-2 — Analyzer #2 (NoRescue) and waiver manifest.** First analyzer
   shipped is NoRescue because the audit already itemized the violating
   sites — same PR adds `priv/tau/gate/manifests/no_rescue.waivers.toml`
   with the seven known sites, each with a `remediated_by:` issue link and
   a 90-day `expires_at:`. NoRescue is the simplest analyzer (one AST
   pattern) and the highest-signal proof the substrate works end-to-end.

3. **PR-3 — Analyzer #1 (Contracts).** Adds the `@behaviour` callback
   completeness and struct-existence checks. Surfaces the known SPEC §4
   struct-name drift; this PR's body lists every finding the new analyzer
   produces and either removes the offending `@doc` claim or implements
   the missing callback.

4. **PR-4 — Analyzer #3 (CapabilityFidelity).** Adds the analyzer and the
   capability → callback map. Same-PR reconciles the known liars
   (Bedrock `prompt_caching: true` without `cache_regions/2`, et al.) by
   either implementing the callback or setting the flag false.

5. **PR-5 — Analyzer #4 (TelemetryConsumers).** Adds the analyzer and the
   consumer-kinds manifest. Highest-finding-volume analyzer (≈78 events
   without consumers); this PR is paired with a parallel cleanup PR that
   either registers consumers via `Tau.Telemetry.Handler` or removes the
   emit sites. Because TelemetryConsumers' findings are non-blocking
   warnings for the first 14 days after merge (a sunset-style ramp
   encoded in `priv/tau/gate/manifests/telemetry.sunset.toml`), the team
   has a bounded window to clean up before the gate goes red. The sunset
   manifest itself has a hard expiry the gate enforces.

A subsequent maintenance PR consolidates the four analyzers behind a
single AST-walk pass if profiling shows the four-pass cost matters; that
optimization is explicitly out of build-order scope.
