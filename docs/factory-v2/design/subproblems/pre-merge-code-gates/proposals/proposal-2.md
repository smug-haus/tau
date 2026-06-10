---
template_version: 1
template_name: proposal
proposal_id: 2
parent_problem: ../problem.md
---

# Proposal 2: ADAPT-FROM-ECOSYSTEM — host four checks on existing Elixir static-analysis substrate plus a Claude Code lint plugin, with a thin bespoke shim per check

## Approach

For each of the four code-shape failure classes (#1 code-side contract
drift, #2 NN #7 `rescue` / `catch :exit` proliferation, #3 capability-flag
fidelity, #4 telemetry-consumer presence), adopt an existing Elixir or
Claude Code component as the analysis substrate and bolt only a thin
bespoke shim that (a) enumerates inputs explicitly, (b) emits a stable
machine-readable verdict (`{:ok, [] | findings}`), and (c) is wired into
CI as a required check that cannot silent-skip. Concretely:

- **#1 contract drift** — adopt the Elixir compiler's built-in
  `@behaviour` / `@impl` warnings plus **Dialyzer** (`:dialyxir 1.4`,
  already a dep) callback-mismatch checks; bolt a 60-line Sourceror-based
  shim that asserts every name a SPEC §4 backticks resolves to a real
  symbol in the compiled `.beam` files. The shim drives Dialyzer in
  `--halt-exit-status` mode and parses its PLT output for
  `callback_missing` / `callback_arg_type_mismatch` / `callback_not_exported`
  diagnostics — these already exist; v1 simply ignores them.
- **#2 NN #7 `rescue` proliferation** — adopt **Credo**'s custom-check
  framework (already a dep) and write three Credo checks
  (`Tau.Credo.Checks.NoTryRescueAcrossProcess`,
  `NoCatchExit`, `NoRescueOnUnreachable`) using the documented
  `Credo.Code.prewalk/2` AST API. Surface them via `mix credo --strict`
  which CI already runs, and add a paired `mix credo diff` blocking
  step (already in CI at `ci.yml:67-70`) so new violations cannot land
  even if legacy ones remain.
- **#3 capability-flag fidelity** — adopt **Boundary** (`:boundary
  ~> 0.10`) for cross-module dependency constraints and use it to
  declare that any module marking itself as a `Tau.Provider` adapter
  with `prompt_caching: true` MUST be in a boundary that exports
  `cache_regions/2`. Bolt a bespoke `Mix.Tasks.Tau.Gate.Capability` (60
  LoC, Sourceror-based) that walks `lib/tau/providers/*.ex`, extracts
  the `@capabilities` module attribute via AST, and asserts the
  exports table contains every callback the declared capability implies.
- **#4 telemetry-consumer presence** — adopt **`telemetry_registry`**
  (`~> 0.3`) for declarative event discovery, plus a runtime ETS
  inspection of `:telemetry`'s `telemetry_handler_table` to enumerate
  registered handlers. Bolt a `Mix.Tasks.Tau.Gate.TelemetryConsumers`
  shim (~80 LoC) that (i) boots the application in `MIX_ENV=test`
  *without* test handlers attached, (ii) walks every
  `:telemetry.execute/3` callsite under `lib/` via Sourceror, (iii)
  asserts each event prefix has ≥1 handler registered by
  `Application.start/2` (not by `setup`/`setup_all`), distinguishing
  production from test handlers by the module path of the attaching
  call.

Wrap all four as a Claude Code **plugin** (`tau-code-gates`) that
exposes a single `tau-code-gates:run` slash command for local
pre-commit use and ships a `PreToolUse` hook that fires the same gates
when an implementer agent tries to `git commit`. The plugin's CI
counterpart is four new required-status-check jobs in `ci.yml`, each
calling one Mix task without `continue-on-error` and without `|| true`.

## Rationale

The complecting hypothesis names the dependency on agent self-report and
the fusion of "behaviour-callback completeness" with "capability-flag
fidelity". Both decomplect cleanly by adopting independent oracles whose
verdicts the agent cannot influence: the Elixir compiler, Dialyzer,
Credo's AST walker, Boundary's compile-time constraint solver, and
`telemetry`'s ETS-backed registry. None of these can be silenced by
edits to a PR body or by an agent claiming "fixed." Adoption is
overwhelmingly cheap because three of the four substrates (Credo,
Dialyxir, Sourceror) are already in the Elixir toolchain consensus and
two of those (Credo, Dialyxir) are already declared deps in `mix.exs`
at lines 132–133. The bespoke surface shrinks to ≤300 LoC of glue
across all four checks, versus a build-from-scratch path that
re-implements AST traversal, callback-introspection, and CI plumbing
from zero. Operability survives because every shim returns the same
`{:ok, findings_list}` shape that Tau's existing
`Mix.Gate.Common` already consumes, so the dashboard work in
`operability-and-hygiene-enforcement` ingests these checks without a
schema change.

## Sketch

### Adopted components, per check

| Failure | Adopted component | URL | License | Maturity | What it gives us |
|---|---|---|---|---|---|
| #1 (struct/symbol existence) | **Sourceror** | github.com/doorgan/sourceror | Apache-2.0 | v1.x, used by `mix format` and Phoenix internals; >1k stars; active 2024-2025 | AST traversal with comment-preserving zipper; `Sourceror.parse_string!/1` + `Sourceror.prewalk/3` to find every backticked symbol in `docs/spec/SPEC-*.md` §4 and resolve it against the compiled module exports |
| #1 (`@behaviour`/`@impl`) | **Elixir compiler** (built-in) + **Dialyxir 1.4** | hexdocs.pm/dialyxir + elixir-lang.org | Apache-2.0 / Apache-2.0 | shipped with OTP; Dialyxir v1.4 active | Compile-time warnings: "function X required by behaviour Y is not implemented"; Dialyzer's `callback_arg_type_mismatch` and `callback_not_exported` warnings |
| #2 (NN #7 conformance) | **Credo** custom-check framework | github.com/rrrene/credo | MIT | v1.7, the de-facto Elixir linter; ships in `mix.exs:132` already | `use Credo.Check`, `Credo.Code.prewalk/2`, `IssueMeta.for/2` — documented testing API (`assert_issue/1`) for confidence; `mix credo diff` for "no new violations" gating |
| #3 (capability-flag fidelity) | **Boundary 0.10** + Sourceror | github.com/sasa1977/boundary | MIT | v0.10.x, Saša Jurić, widely used in Phoenix shops | Compile-time enforcement of "boundary X depends on Y"; we use it as the *export* oracle (a capability-tagged boundary MUST export the matching callback name) |
| #4 (telemetry-consumer presence) | **`telemetry_registry`** + `:telemetry` ETS table | github.com/beam-telemetry/telemetry_registry | Apache-2.0 | v0.3, Erlang Ecosystem Foundation maintained | `discover_all/0` walks the application tree to find declared events; ETS introspection of `telemetry_handler_table` enumerates live handlers |
| (wrapping) | **`claude-code-elixir`** plugin pattern | github.com/georgeguimaraes/claude-code-elixir | (per repo) | Active 2025–2026; provides `mix-credo` / `mix-compile` PostToolUse hook patterns | The PostToolUse-hook-runs-credo pattern; we reuse the hook script shape and substitute our four gates |
| (PreToolUse gate substrate) | **Anthropic claude-code/plugins** examples | github.com/anthropics/claude-code/tree/main/plugins | MIT | Official; reference for PreToolUse-blocking pattern | The "exit non-zero from PreToolUse blocks the tool call" contract — we mirror it for `git commit` and `gh pr ready` |

### Per-check configuration / adaptation

**`Mix.Tasks.Tau.Gate.Contracts` (#1)** — ~120 LoC bespoke wrapper
around adopted substrates:

```elixir
defmodule Mix.Tasks.Tau.Gate.Contracts do
  @shortdoc "Verifies SPEC §4 symbols + @behaviour/@impl completeness."
  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("compile", ["--warnings-as-errors"])  # adopts compiler warns
    {:ok, _} = Application.ensure_all_started(:tau)

    findings =
      []
      |> Kernel.++(spec_symbol_findings())     # Sourceror walk over SPEC §4
      |> Kernel.++(dialyzer_callback_findings())  # parse :dialyxir output
      |> Kernel.++(behaviour_impl_findings())     # Code.ensure_loaded + behaviour_info(:callbacks)

    Mix.Gate.Common.emit_verdict(:contracts, inputs(), findings)
  end

  defp inputs do
    %{
      specs: Path.wildcard("docs/spec/SPEC-*.md"),
      behaviours: behaviour_modules(),  # via :code.all_loaded |> filter behaviour_info/1
      adapter_modules: Path.wildcard("lib/tau/providers/*.ex")
    }
  end
  # ... emit_verdict refuses to skip when any inputs list is empty;
  #     fails the PR with "input enumeration returned 0; gate cannot
  #     prove absence" per root §Acceptance C.
end
```

**`Tau.Credo.Checks.NoTryRescueAcrossProcess` (#2)** — direct adoption
of Credo's documented custom-check pattern:

```elixir
defmodule Tau.Credo.Checks.NoTryRescueAcrossProcess do
  use Credo.Check, base_priority: :high, category: :warning,
    explanations: [check: """
    OTP non-negotiable #7: MUST NOT try/rescue across process boundaries.
    A try/rescue that wraps a Task.async, GenServer.call, send/2,
    GenServer.cast, or :gen_statem.call/cast is forbidden.
    """]

  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
  end

  defp traverse({:try, meta, [opts]} = ast, issues, issue_meta) do
    body = Keyword.get(opts, :do, [])
    if crosses_process_boundary?(body) and Keyword.has_key?(opts, :rescue) do
      {ast, [issue_for(meta, issue_meta) | issues]}
    else
      {ast, issues}
    end
  end
  defp traverse(ast, issues, _meta), do: {ast, issues}
  # crosses_process_boundary? matches Task.async, GenServer.call,
  # :gen_statem.call, send/2, etc.
end
```

Then in `.credo.exs`:
```elixir
{Tau.Credo.Checks.NoTryRescueAcrossProcess, []},
{Tau.Credo.Checks.NoCatchExit, []},
{Tau.Credo.Checks.NoRescueOnUnreachable, []},
```

**`Mix.Tasks.Tau.Gate.Capability` (#3)** — Boundary declaration plus
Sourceror cross-check:

```elixir
# lib/tau/providers/anthropic.ex
defmodule Tau.Providers.Anthropic do
  use Boundary, deps: [Tau.Provider], exports: [:cache_regions, :stream, ...]
  @behaviour Tau.Provider
  @capabilities %{prompt_caching: true, ...}
  # ...
end

# lib/mix/tasks/tau.gate.capability.ex
defmodule Mix.Tasks.Tau.Gate.Capability do
  @capability_to_callback %{
    prompt_caching: {:cache_regions, 2},
    tool_use: {:tools, 1},
    structured_output: {:format/2 via stream opt, 0},  # etc.
  }

  def run(_) do
    Mix.Task.run("compile", [])
    adapters = adapter_modules()  # explicit input enumeration
    if adapters == [], do: Mix.raise("no adapter modules — gate cannot run")
    findings = Enum.flat_map(adapters, &check_adapter/1)
    Mix.Gate.Common.emit_verdict(:capability, %{adapters: adapters}, findings)
  end

  defp check_adapter(mod) do
    caps = mod.__capabilities__()
    exports = mod.__info__(:functions)
    for {cap, true} <- caps,
        {fun, arity} = Map.fetch!(@capability_to_callback, cap),
        not Enum.member?(exports, {fun, arity}),
        do: {:capability_lie, mod, cap, {fun, arity}}
  end
end
```

**`Mix.Tasks.Tau.Gate.TelemetryConsumers` (#4)** — uses adopted
`telemetry_registry` + direct `:telemetry` ETS introspection:

```elixir
def run(_) do
  {:ok, _} = Application.ensure_all_started(:tau)
  :telemetry_registry.discover_all()  # adopted

  # 1. enumerate every :telemetry.execute callsite under lib/ via Sourceror
  emitted = scan_emit_sites("lib/")  # [{[:tau, :session, :start], "lib/tau/session.ex:42"}, ...]
  if emitted == [], do: Mix.raise("0 emit sites — gate cannot prove absence")

  # 2. enumerate handlers registered by application boot (NOT test setup)
  handlers = :ets.tab2list(:telemetry_handler_table)
             |> Enum.reject(&test_attached?/1)  # filter handlers attached from test/

  # 3. assert every emitted event prefix has ≥1 production handler
  findings = for {event, source} <- emitted,
                 not Enum.any?(handlers, &covers?(&1, event)),
                 do: {:no_consumer, event, source}
  Mix.Gate.Common.emit_verdict(:telemetry_consumers, %{emit_sites: length(emitted)}, findings)
end
```

### CI wiring (no silent-skip)

`.github/workflows/ci.yml` adds four required jobs, each pinned with
`continue-on-error: false`, no `|| true`, no `if:` gates that can early-
exit on PR-body shape:

```yaml
gate-contracts:
  name: gate 1 — contract drift
  needs: lint
  steps:
    - uses: actions/checkout@v4
    - uses: erlef/setup-beam@v1
      with: { version-file: .tool-versions, version-type: strict }
    - run: mix deps.get
    - run: mix tau.gate.contracts   # exits non-zero on any finding OR empty input set

gate-no-rescue:
  name: gate 2 — NN #7 conformance
  steps:
    - run: mix credo --strict --only Tau.Credo.Checks.NoTryRescueAcrossProcess,Tau.Credo.Checks.NoCatchExit,Tau.Credo.Checks.NoRescueOnUnreachable
      # NOTE: NOT `|| true`; NOT `continue-on-error`

gate-capability:
  name: gate 3 — capability-flag fidelity
  steps:
    - run: mix tau.gate.capability

gate-telemetry-consumers:
  name: gate 4 — telemetry-consumer presence
  steps:
    - run: mix tau.gate.telemetry_consumers
```

All four are added to GitHub's branch-protection required-status-checks
set so `gh pr merge` rejects without all four green.

### Claude Code plugin shape

```
plugins/tau-code-gates/
├── .claude-plugin/plugin.json
├── commands/
│   └── tau-code-gates-run.md       # slash command: runs all four locally
├── hooks/
│   ├── pre-tool-use.json           # blocks `git commit`/`gh pr ready` on red
│   └── run-gates.sh                # invokes mix tau.gate.{contracts,capability,telemetry_consumers} + credo
└── skills/
    └── interpret-findings/SKILL.md # progressive disclosure for reading verdicts
```

The `PreToolUse` hook matches Anthropic's documented contract: exit 0
allows, exit non-zero blocks with the gate's verdict surfaced in the
agent's transcript. This closes the "agent commits red" gap before CI
even sees the push.

### Silent-skip impossibility

Each `Mix.Gate.Common.emit_verdict/3` call checks that the inputs map
is non-empty for every enumerated category, and exits with status 2
(distinct from "findings present" status 1) when it is — labelled
`gate_infrastructure_failure`. The CI job treats both 1 and 2 as red.
This matches the existing `Mix.Gate.Mutation` "infrastructure failure
vs gate decision" distinction (`ci.yml` already discriminates exit 3
for the mutation gate; we extend the convention).

The CI workflow does not use `if: github.event_name == 'pull_request'`
to gate any of the four; they run on `push` to `**` and on `pull_request`
events identically. The `|| true` pattern at the v1 `ci.yml:115` is
replaced by `mix credo --strict || exit 1` explicitly.

## Tradeoffs

### Strengths

- **Maximises adoption per root §Acceptance D.** Three of the four
  checks reuse mature, widely-deployed substrates (Credo, Dialyxir,
  Boundary); the fourth uses two BEAM Foundation-maintained libs
  (`:telemetry`, `:telemetry_registry`). Bespoke surface is ~300 LoC
  total — auditable in one sitting.
- **Each oracle is independent of agent self-report** (root §Hypothesis
  premise). The compiler, Dialyzer, Credo's AST walker, Boundary's
  compiler plugin, and `:telemetry`'s ETS table are all driven by
  source content, not PR-body claims.
- **Silent-skip impossible by construction.** The `inputs` map check
  inside `emit_verdict/3` fails when enumeration returns empty, and
  CI runs each job without `continue-on-error` and without conditional
  `if:` gates that depend on PR shape. The v1 `ci.yml:115` `|| true`
  pattern has no counterpart in any of the four new jobs.
- **Mirrors v1's existing convention.** Tau already has
  `Mix.Tasks.Tau.Gate.{AcLinkage,Masking,Mutation}` and `Mix.Gate.Common`
  helpers; the four new tasks slot into the same namespace and the
  same verdict shape, so the operability dashboard (sibling leaf) has
  no integration work.
- **PR-body independence.** Unlike Gate 5.1 (AC linkage), none of the
  four new gates reads the PR body; they run on the compiled code. The
  failure mode where "no AC declared → silent skip" is structurally
  absent.
- **Local + CI parity.** The plugin's `PreToolUse` hook runs the same
  Mix tasks the CI runs, so an implementer agent sees the verdict
  before `git commit` returns — accelerating refine cycles and removing
  the "PR-opened-then-CI-red" round-trip for these four classes.
- **Composable with sibling leaves.** AC-binding (#1 sibling) keys off
  `gating-test paths`; capability fidelity (this leaf) keys off
  `@capabilities` attributes; neither overlaps. The mutation gate
  (Gate 5.3) and these four are orthogonal.

### Weaknesses

- **Dialyzer is slow.** Cold PLT build is ~3-5 minutes on Tau's
  current dep set; even with cached PLT, the callback-mismatch step
  adds ~30-60s to CI. This is a real wall-time tax on the gate-1 job.
  Mitigation: cache PLT keyed on `mix.lock` (Tau already caches `_build`
  in `ci.yml:46-50`); skip cold PLT entirely on PR builds when the lock
  is unchanged.
- **Credo custom-check false positives.** `crosses_process_boundary?/1`
  is a pattern-match heuristic, not a flow analysis. A `try/rescue`
  wrapping a function whose body eventually calls `GenServer.call` two
  levels deep is invisible to the check. False negatives are the failure
  mode; false positives can be `# credo:disable-for-next-line` annotated
  but each annotation MUST be flagged in PR review (sibling concern of
  the operability dashboard — surface "credo-disable count delta" per PR).
- **Boundary adoption is invasive.** Adding `use Boundary, deps: [...]`
  to every adapter touches every file under `lib/tau/providers/`. That
  is a single corrective-actions catalogue item, but it lands as one
  large PR that the v2 factory itself must process — a chicken-and-egg
  bootstrap cost. Mitigation: stage Boundary adoption per-adapter behind
  a `Boundary.Mix.Compiler` warning-only mode for the first N PRs.
- **`telemetry_registry` is opt-in and requires per-module
  `@telemetry_event` declarations.** Adoption requires touching every
  module that emits a telemetry event (~30+ modules per the 121 emit
  sites in root §Hypothesis #4). Mitigation: the Sourceror-driven emit-
  site scan (step 1 of `Gate.TelemetryConsumers`) is independent of
  `telemetry_registry` and works on the un-annotated codebase; we adopt
  `telemetry_registry` only for the long-term goal of declarative
  documentation, not as a gate dependency.
- **Distinguishing production from test handlers in
  `:telemetry_handler_table` is heuristic.** "Module path of the
  attaching call" is captured by stack trace at attach time, which is
  not preserved in ETS. We must either (a) wrap `:telemetry.attach/4`
  in a `Tau.Telemetry.attach/4` that tags the call site, or (b) attach
  all production handlers from a single `Tau.Telemetry.Boot` module and
  filter handlers by handler-ID prefix. Option (b) is cheaper but
  requires a one-off refactor of every production `attach/4` call.
- **Plugin ecosystem maturity.** Claude Code's plugin marketplace is
  active but young (2026 H1). `claude-code-elixir` and `claude-elixir-
  phoenix` are reference patterns, not stable APIs; the `PreToolUse`
  hook contract is documented but versioned implicitly. We pin the
  plugin's manifest to a specific Anthropic plugin-schema version and
  set up a renovate-style update gate.
- **No mutation testing for these four gates.** Unlike Gate 5.3 (which
  uses Muzak-style merge-base reversion for AC-binding tests), the
  four code-shape gates have no analogous mutation oracle. If a
  `Tau.Credo.Checks.NoTryRescueAcrossProcess` rule is silently weakened
  (e.g. its `traverse/3` returns `{ast, issues}` unconditionally), no
  test catches it. Mitigation: ship StreamData property tests for each
  Credo check using Credo's documented `assert_issue/1` testing API,
  and gate the check modules themselves under the masking gate (Gate
  5.2 — diff-scans for deleted `assert` lines).
- **Boundary's compile-time enforcement is warning-only by default.**
  Saša Jurić's docs explicitly say "the compiler doesn't force you to
  immediately fix these violations" — we MUST run `mix compile
  --warnings-as-errors` to convert them to gate failures, which Tau
  already does (`ci.yml:64`), but this couples Boundary's verdict to
  the warnings-as-errors discipline.

### Costs

- **New deps.** `:sourceror ~> 1.0`, `:boundary ~> 0.10`,
  `:telemetry_registry ~> 0.3` — all `runtime: false` or
  `runtime: true` (`telemetry_registry`); ~200KB compiled. Acceptable.
- **CI wall-time delta.** +60s for gate-contracts (Dialyzer with warm
  PLT), +5s for gate-no-rescue (Credo on the three new checks), +3s
  for gate-capability (compile + AST walk), +10s for gate-
  telemetry-consumers (app boot + ETS scan + Sourceror walk). Net
  ~+80s per PR; the lint job today is ~3 minutes, so a ~45% increase
  on that job's runtime.
- **Bespoke code volume.** ~300 LoC across the four `Mix.Tasks.Tau.Gate.*`
  modules + ~150 LoC across the three Credo checks + ~80 LoC plugin
  hook shim = ~530 LoC. Compare to a build-from-scratch estimate of
  ~2,500-4,000 LoC (full AST walker + behaviour-introspector + ETS
  abstraction + CI plumbing). 5-7× reduction.
- **One-off refactors.** (a) Add `use Boundary` to every module under
  `lib/tau/providers/`, `lib/tau/coding_agents/`, and core supervisors
  (~20 modules); (b) wrap all production `:telemetry.attach/4` calls
  in `Tau.Telemetry.attach/4` (~30 callsites). Both are catalogued
  corrective-actions and processed by the factory itself.
- **Documentation update.** `.claude/rules/otp-non-negotiables.md` gains
  a "Mechanical enforcement" subsection per invariant naming the Credo
  check that enforces it. This is the documentation-mechanism pairing
  required by root §Acceptance G ("every component produces a machine-
  checkable artifact" — the doc is paired with the check, not standalone).
- **Plugin bootstrap.** ~1 day to scaffold `plugins/tau-code-gates/`,
  ~1 day to write the `PreToolUse` hook + interpret-findings skill,
  ~0.5 day to register with the local plugin marketplace.

## Dependencies

- **Existing**: `:credo ~> 1.7` (`mix.exs:132`), `:dialyxir ~> 1.4`
  (`mix.exs:133`), `:stream_data ~> 1.1` (for property tests of Credo
  checks).
- **New deps to add**: `:sourceror ~> 1.0` (Apache-2.0,
  github.com/doorgan/sourceror), `:boundary ~> 0.10` (MIT,
  github.com/sasa1977/boundary), `:telemetry_registry ~> 0.3`
  (Apache-2.0, github.com/beam-telemetry/telemetry_registry).
- **One-off corrective-actions** (catalogued, processed by factory):
  (1) add `use Boundary` to adapter modules, (2) replace production
  `:telemetry.attach/4` calls with `Tau.Telemetry.attach/4`, (3) add
  `@capabilities` module attribute to every adapter declaring callback-
  implying capabilities.
- **Sibling leaf cooperation**: AC-binding leaf must publish its
  `gating-test paths` schema so we exclude gating-test files from the
  Credo `NoTryRescue` scan (test code is allowed to wrap in
  `try/rescue` for assertion patterns).
- **CI changes**: four new required-status-check jobs in `ci.yml`,
  added to branch-protection rules for `main`.
- **Plugin marketplace**: register `tau-code-gates` in
  `.claude-plugin/marketplace.json` (Tau's own marketplace) and pin the
  Anthropic plugin schema version.

## Build-order (adopt-over-build, smallest gap first)

1. **Adopt the existing layer**: pin `:sourceror`, `:boundary`,
   `:telemetry_registry` versions; cache Dialyzer PLT in `ci.yml`. (0.5d)
2. **Ship `Mix.Tasks.Tau.Gate.Contracts`** wrapping compiler warnings +
   Dialyzer callback diagnostics + Sourceror SPEC §4 symbol scan. Wire
   to CI as required check. (1.5d, mostly the Dialyzer output parser)
3. **Ship three `Tau.Credo.Checks.*`** for NN #7; add to `.credo.exs`;
   property-test each with `assert_issue/1`. (2d, Credo's testing API
   is well-documented but property tests for AST patterns are fiddly)
4. **Ship `Mix.Tasks.Tau.Gate.Capability`** with the `@capabilities ↔
   callback` mapping table; corrective-action issue to add `@capabilities`
   to each adapter. (1d task, 1-2d corrective-action backlog)
5. **Ship `Mix.Tasks.Tau.Gate.TelemetryConsumers`** with the emit-site
   Sourceror walker + ETS handler enumerator; corrective-action issue
   to migrate production `:telemetry.attach/4` calls to
   `Tau.Telemetry.attach/4`. (1.5d task, 2-3d corrective-action backlog)
6. **Wrap as `tau-code-gates` plugin** with `PreToolUse` hook; register
   in the Tau plugin marketplace. (1.5d, including the
   interpret-findings skill)
7. **Update branch protection**: add the four jobs as required status
   checks. (0.5d)

Total: ~10 day-units of factory work, of which ~7 are wrapping/glue and
~3 are corrective-actions catalogued for the factory to process.

## Explicit gaps (no adopted component; bespoke is justified)

- **SPEC §4 symbol resolver (gap for #1).** No ecosystem tool resolves
  backticked symbols in markdown against the live BEAM module exports.
  Bespoke 60-LoC Sourceror walker is justified.
- **`@capabilities ↔ callback` mapping table (gap for #3).** Tau-
  specific data; no ecosystem component models the relationship.
  Bespoke ~30-line map literal in `Mix.Tasks.Tau.Gate.Capability` is
  justified.
- **Production-vs-test handler discrimination (gap for #4).** Adopted
  `:telemetry` does not distinguish callsite origin. Bespoke
  `Tau.Telemetry.attach/4` wrapper (~20 LoC) tagging handler IDs with
  a `:prod` / `:test` prefix is justified.
- **Verdict-shape contract (gap for all four).** The
  `Mix.Gate.Common.emit_verdict/3` shape is Tau's existing convention;
  no ecosystem component speaks it. Reusing Tau's existing helper (not
  bespoke for this leaf — already shipped) is correct.

No other gap remains. Every other surface is adopted.

## Confidence

**Medium-high.** Three of the four substrates (Credo, Dialyxir,
Sourceror) are battle-tested in the Elixir ecosystem with documented
custom-check / AST APIs; the fourth (`:telemetry` ETS) has been the
substrate for `:telemetry`'s own internals since v1.0. The novel
surface — bespoke shims plus the Claude Code plugin wrapping — is
small and bounded. The two confidence-lowering risks are (a) the
production-vs-test handler discrimination heuristic, which is a known
gap with a known workaround (handler-ID prefix); and (b) the Claude
Code plugin schema versioning, which is young. Both are mitigated
above; neither blocks initial shipping. A prototype of
`Tau.Credo.Checks.NoTryRescueAcrossProcess` against the existing
`docs/problems/` rescue-site catalogue would raise confidence to high
within a half-day.

## Prior art / references

- [doorgan/sourceror](https://github.com/doorgan/sourceror) — Elixir AST
  manipulation with zipper API; Apache-2.0; compatible with Elixir
  1.10+; used by `mix format`.
- [rrrene/credo](https://github.com/rrrene/credo) — Elixir static
  analysis; MIT; v1.7.x; documented custom-check API at
  [hexdocs.pm/credo/adding_checks.html](https://hexdocs.pm/credo/adding_checks.html)
  and testing API at
  [hexdocs.pm/credo/testing_checks.html](https://hexdocs.pm/credo/testing_checks.html).
- [jeremyjh/dialyxir](https://github.com/jeremyjh/dialyxir) — Mix tasks
  wrapping Dialyzer; Apache-2.0; v1.4.x; catches
  `callback_missing` / `callback_arg_type_mismatch` warnings.
- [sasa1977/boundary](https://github.com/sasa1977/boundary) — Compile-
  time cross-module dependency enforcement; MIT; v0.10.x; Saša Jurić;
  [hexdocs.pm/boundary](https://hexdocs.pm/boundary/readme.html).
- [beam-telemetry/telemetry](https://github.com/beam-telemetry/telemetry)
  and [telemetry_registry](https://hexdocs.pm/telemetry_registry/TelemetryRegistry.html)
  — Apache-2.0; BEAM-Foundation-maintained; ETS-backed handler table
  with documented `discover_all/0` and `list_events/0` introspection.
- [Stratus3D: "Show All Telemetry Events in Erlang and Elixir"](http://stratus3d.com/blog/2023/10/15/show-all-telemetry-events-in-erlang-and-elixir/)
  — Erlang tracing technique for emit-site discovery; informs the
  Sourceror static-walker alternative we adopt.
- [georgeguimaraes/claude-code-elixir](https://github.com/georgeguimaraes/claude-code-elixir)
  — Claude Code plugin marketplace for Elixir; PostToolUse-runs-credo
  pattern; reference for our plugin shape.
- [oliver-kriska/claude-elixir-phoenix](https://github.com/oliver-kriska/claude-elixir-phoenix)
  — Iron Laws CI gate pattern with 4-agent parallel audits; reference
  for "every PR must pass lint + test + eval" enforcement.
- [anthropics/claude-code/tree/main/plugins](https://github.com/anthropics/claude-code/blob/main/plugins/README.md)
  — Official plugin manifest schema, `PreToolUse` hook contract,
  reference implementations of PreToolUse-blocking pattern.
- [Pixelmojo: Claude Code Hooks: Production-Quality CI/CD Patterns](https://www.pixelmojo.io/blogs/claude-code-hooks-production-quality-ci-cd-patterns)
  — `PreToolUse` exit-code semantics; the "exit non-zero blocks the
  tool call" contract we mirror.
- [AppSignal: Writing a Custom Credo Check in Elixir](https://blog.appsignal.com/2023/08/29/writing-a-custom-credo-check-in-elixir.html)
  — `use Credo.Check`, `Credo.Code.prewalk/2`, `IssueMeta.for/2`
  — the exact template our three NN-#7 checks follow.
- [HexDocs: Module behaviour](https://hexdocs.pm/elixir/main/Module.html)
  — `@behaviour` + `@impl` + `behaviour_info(:callbacks)` runtime
  introspection contract used by the contracts gate.
- Tau in-repo: `lib/mix/gate/common.ex`, `lib/mix/tasks/tau.gate.*.ex`
  — the verdict-shape convention these four new gates conform to;
  `ci.yml` lines 56-75 — the credo+compile-warnings pattern these
  jobs extend without `|| true`.
