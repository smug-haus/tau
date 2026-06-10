---
template_version: 1
template_name: proposal
proposal_id: 3
parent_problem: ../problem.md
---

# Proposal 3: Sign-off rule deck — ASIC tape-out DRC/LVS adapted as a four-deck Mix-task suite with enumerated inputs and a manifest gate

## Approach

Model the pre-merge code-gate substrate after **ASIC tape-out sign-off rule
decks** (DRC, LVS, ERC, antenna). Tape-out shops do not ship a chip while
*any* rule violates, *any* deck fails to run, or *any* "no input" verdict is
returned uncategorised — the foundry's sign-off tool refuses with a hash-
bound manifest. Translated to Tau: build four independent Mix-task "decks"
— `Contracts`, `NoRescue`, `CapabilityFidelity`, `TelemetryConsumers` —
each one a deterministic Sourceror-based AST traverser over an
*enumerated* input set; package them under one umbrella task
`mix tau.gate.code` that emits a single hash-stamped JSON manifest the CI
job pins as a required status check. The deck-runner refuses to produce a
PASS verdict unless every deck reports `inputs_enumerated`,
`inputs_processed`, and `findings`, where `inputs_processed ==
inputs_enumerated` and findings is empty; any other combination — including
empty input list, missing deck binary, parser error — is a hard non-zero
exit. Existing tools are wrapped, not replaced: Dialyzer's `@behaviour`-
callback warnings feed `Contracts`; `mix xref` graph data feeds
`TelemetryConsumers`; Credo custom checks back `NoRescue` rules where AST
walking is awkward; `Sourceror` does the bespoke walks. A bespoke
component is built only where no off-the-shelf check exists (`NoRescue`
unreachable-condition heuristics, capability-flag → callback proof).

## Rationale

This decomplects four things v1 weaves: (i) the *check definition* from
the *check execution* (decks are versioned files, the runner is generic);
(ii) the *input enumeration* from the *check logic* (each deck must
declare its target list, which removes "silent skip on empty input" by
construction — empty enumeration is itself a finding, mirroring tape-
out's "no-cells-checked" verdict); (iii) the *verdict* from the *agent
narrative* (the CI gate consumes the manifest JSON, not stdout or PR-body
text); (iv) the *tool-of-record* from the *check intent* (Dialyzer-or-
Sourceror-or-Credo is a per-deck implementation choice the spec
documents). The ASIC analogue is exact for AC-D (ecosystem reuse): the
foundry mandates *which* rule decks must pass but lets vendors choose the
checking engine, exactly as this spec mandates the four checks but lets
each deck wrap an existing tool. The manifest pattern makes AC-C (silent-
skip impossibility) structural: a missing deck cannot return "skipped"
because the runner enumerates the expected deck IDs from a spec file
and any missing ID is a hard fail.

## Sketch

### Directory layout

```
lib/mix/tasks/tau.gate.code.ex              # umbrella runner
lib/mix/tasks/tau/gate/
  contracts.ex                              # deck #1
  no_rescue.ex                              # deck #2
  capability_fidelity.ex                    # deck #3
  telemetry_consumers.ex                    # deck #4
lib/tau/gate/
  deck.ex                                   # @behaviour Tau.Gate.Deck
  manifest.ex                               # JSON manifest schema + writer
  enumeration.ex                            # input-set helpers (Path.wildcard, Mix.Project.compile_path, etc.)
priv/gate/decks.toml                        # canonical deck registry (id → module → required?)
.github/workflows/ci.yml                    # one job: `mix tau.gate.code --manifest /tmp/gate.json`
```

### Deck behaviour

```elixir
defmodule Tau.Gate.Deck do
  @moduledoc """
  A pre-merge code-gate deck. Modelled on an ASIC sign-off rule deck:
  declares its inputs, runs deterministically, emits findings as data.
  """

  @type input :: %{kind: atom(), path: Path.t() | nil, module: module() | nil}
  @type finding :: %{
          severity: :error | :warn,
          rule_id: String.t(),
          input: input(),
          message: String.t(),
          evidence: map()
        }
  @type result :: %{
          deck_id: String.t(),
          inputs_enumerated: [input()],
          inputs_processed: [input()],
          findings: [finding()],
          parser_errors: [String.t()]
        }

  @callback deck_id() :: String.t()
  @callback enumerate_inputs() :: {:ok, [input()]} | {:error, String.t()}
  @callback run(inputs :: [input()]) :: result()
end
```

### `CapabilityFidelity` deck (concrete — addresses class #3)

```elixir
defmodule Mix.Tasks.Tau.Gate.CapabilityFidelity do
  @behaviour Tau.Gate.Deck

  @impl true
  def deck_id, do: "capability_fidelity"

  @impl true
  def enumerate_inputs do
    paths = Path.wildcard("lib/tau/providers/*.ex")
    if paths == [] do
      {:error, "no provider modules under lib/tau/providers/*.ex"}
    else
      {:ok, Enum.map(paths, &%{kind: :provider_module, path: &1, module: nil})}
    end
  end

  @impl true
  def run(inputs) do
    findings =
      for %{path: path} = input <- inputs,
          flags = capability_flags(path),
          {flag, true} <- flags,
          callback = required_callback(flag),
          not exports?(path, callback) do
        %{
          severity: :error,
          rule_id: "CF-001",
          input: input,
          message: "#{Path.basename(path)} declares #{flag}: true but does not export #{inspect(callback)}",
          evidence: %{flag: flag, expected_callback: callback}
        }
      end

    %{
      deck_id: deck_id(),
      inputs_enumerated: inputs,
      inputs_processed: inputs,
      findings: findings,
      parser_errors: []
    }
  end

  # Capability → required callback table (the rule deck)
  defp required_callback(:prompt_caching), do: {:cache_regions, 2}
  defp required_callback(:thinking), do: {:thinking_block, 2}
  # ... extend as new capability flags are added

  defp capability_flags(path) do
    # Sourceror walk: find `capabilities` callback impl, extract the map literal
    # ... returns [{:prompt_caching, true}, ...]
  end

  defp exports?(path, {fun, arity}) do
    # Sourceror walk: any `def fun(_, _)` at top level
  end
end
```

### `NoRescue` deck (concrete — addresses class #2)

```elixir
defmodule Mix.Tasks.Tau.Gate.NoRescue do
  @behaviour Tau.Gate.Deck

  @impl true
  def deck_id, do: "no_rescue"

  @impl true
  def enumerate_inputs do
    paths = Path.wildcard("lib/tau/**/*.ex")
    if paths == [] do
      {:error, "no source files under lib/tau/"}
    else
      {:ok, Enum.map(paths, &%{kind: :source_file, path: &1, module: nil})}
    end
  end

  @impl true
  def run(inputs) do
    findings =
      for %{path: path} = input <- inputs,
          site <- rescue_sites(path),
          not waivered?(site) do
        %{
          severity: :error,
          rule_id: "NR-001",
          input: input,
          message: "rescue/catch against unreachable condition (NN #7)",
          evidence: site
        }
      end

    %{deck_id: deck_id(), inputs_enumerated: inputs,
      inputs_processed: inputs, findings: findings, parser_errors: []}
  end

  defp rescue_sites(path), do: # Sourceror: traverse for :try AST nodes, classify
  defp waivered?(site), do:
    # check priv/gate/waivers.toml for {file, line_range, expiry, rule_id}
end
```

### Manifest (`priv/gate/manifest.schema.json`)

```json
{
  "schema_version": 1,
  "generated_at": "ISO-8601",
  "commit_sha": "string",
  "decks": [{
    "deck_id": "capability_fidelity",
    "tool_of_record": "bespoke|dialyzer|credo|xref",
    "verdict": "PASS|FAIL|ERROR",
    "inputs_enumerated_count": 9,
    "inputs_processed_count": 9,
    "findings_count": 2,
    "findings": [/* finding objects */]
  }],
  "overall_verdict": "PASS|FAIL"
}
```

### Umbrella runner

```elixir
defmodule Mix.Tasks.Tau.Gate.Code do
  use Mix.Task
  @required_decks ~w(contracts no_rescue capability_fidelity telemetry_consumers)

  def run(argv) do
    {opts, _} = OptionParser.parse!(argv, strict: [manifest: :string])

    results =
      Enum.map(@required_decks, fn id ->
        mod = deck_module(id)
        case mod.enumerate_inputs() do
          {:ok, inputs} -> mod.run(inputs)
          {:error, msg} -> %{deck_id: id, verdict: :error, error: msg}
        end
      end)

    verdict = if Enum.all?(results, &deck_passes?/1), do: :pass, else: :fail
    File.write!(opts[:manifest], Jason.encode!(%{
      schema_version: 1, commit_sha: commit_sha(), decks: results,
      overall_verdict: verdict
    }))
    if verdict == :fail, do: System.halt(1)
  end

  defp deck_passes?(%{verdict: :error}), do: false
  defp deck_passes?(%{inputs_enumerated: [], findings: []}), do: false   # empty != skip
  defp deck_passes?(%{inputs_processed: p, inputs_enumerated: e}) when p != e, do: false
  defp deck_passes?(%{findings: []}), do: true
  defp deck_passes?(_), do: false
end
```

### CI wiring (replaces v1's `|| true` and `exit 0` patterns)

```yaml
- name: Pre-merge code gates (sign-off deck suite)
  run: mix tau.gate.code --manifest /tmp/gate-manifest.json

- name: Upload gate manifest
  uses: actions/upload-artifact@v4
  with:
    name: gate-manifest
    path: /tmp/gate-manifest.json
```

The job is set as a **required status check on `main`** in branch
protection; absence of the manifest artifact is itself a protection
violation that GitHub enforces independently of the workflow's exit code.

## Tradeoffs

### Strengths

- **Silent-skip impossibility is structural, not procedural** (AC-C). A
  deck whose `enumerate_inputs` returns `{:error, …}` or `{:ok, []}`
  causes the umbrella to FAIL. A deck whose module is absent fails the
  runner's `deck_module/1` lookup. There is no code path that yields PASS
  from an empty input set — the ASIC parallel: "we ran zero rules" is
  never a sign-off verdict.
- **Per-deck tool-of-record is explicit** (AC-D, ecosystem reuse). The
  manifest's `tool_of_record` field records whether `Contracts` wraps
  Dialyzer (`@behaviour` callback warnings + `@callback`/`@impl`
  cross-check), `TelemetryConsumers` wraps `mix xref` (callsites that
  reference `:telemetry.attach`/`Tau.Telemetry.Handler`), or the deck
  is bespoke. Spec records the choice with rationale; reviewer flags any
  deck that switched tools without spec amendment.
- **The manifest is a hash-bound machine artifact** — the verdict the CI
  status check consumes is the manifest's `overall_verdict`, not stdout
  scraping or PR-body text. Falsifies failure class #5 (silent-skip) and
  #7 (local-mix evidence) for *this* leaf's checks.
- **Inputs are enumerated declaratively per deck** — adding a new
  provider, behaviour, or telemetry source automatically enters the
  enumeration; the rule deck does not need editing. This is the ASIC
  property "new cells are checked by existing rules unless explicitly
  waivered."
- **Waiver mechanism is in-tree and expires** — `priv/gate/waivers.toml`
  takes `{file, line_range, rule_id, expires_on, justification}`; the
  runner rejects expired or undated waivers, matching IEC 62304's
  controlled-deviation discipline.
- **Each deck is a `Tau.Gate.Deck` behaviour implementation** — adding
  a fifth concern (e.g. "no `IO.puts` in lib/") is a single new module,
  one row in `decks.toml`, no runner change.

### Weaknesses

- **Sourceror traversal authorship is non-trivial.** The
  `CapabilityFidelity` deck must parse provider modules robustly, including
  metaprogrammed `defcapabilities` macros (Tau already has 9 providers
  with varying styles). First-pass bespoke walks will miss edge cases;
  the gate may false-fail on legitimate constructs until the walks are
  hardened.
- **Dialyzer wrapping introduces PLT-cache fragility.** `Contracts` deck
  needs a warm PLT to read `@behaviour` callback warnings; cold-cache
  CI runs add 3–8 minutes. Caching the PLT in GHA partly mitigates but
  cache-key invalidation on OTP/Elixir upgrade is a known footgun.
- **No incremental mode.** Each PR re-runs all four decks across the
  enumerated input sets. For `NoRescue` over ~80 lib files this is fast,
  but as Tau grows past ~500 modules, total deck wall time may exceed the
  GHA job budget. ASIC shops handle this with hierarchical rule decks; this
  proposal does not.
- **Telemetry-consumer fidelity check is heuristic.** "Production
  consumer" is defined as "module under `lib/tau/` (not `test/`) that
  calls `:telemetry.attach_many` or implements `Tau.Telemetry.Handler`
  behaviour." A consumer registered dynamically from config or a plugin
  may be missed; the gate must accept an allow-list (with the waiver
  expiry discipline) until a runtime introspection check exists.
- **Waiver mechanism is itself a target.** A coordinator under pressure
  to merge may add a long-expiry waiver. The gate enforces the schema
  and expiry but cannot enforce the *justification's* truthfulness;
  reviewers see waivers in the diff and the dashboard surfaces unwaivered-
  to-waivered transitions.

### Costs

- **Build:** ~4 new Mix tasks + 1 behaviour + 1 manifest writer + 1
  enumeration helper ≈ 600–900 LOC of `lib/`, plus `priv/gate/decks.toml`,
  `priv/gate/waivers.toml`, `priv/gate/manifest.schema.json`. Test surface
  ≈ 400 LOC (property tests per deck: "any module exporting flag X without
  callback Y is reported"; "any rescue site in lib/ is reported unless
  waivered"; "empty enumeration is FAIL not PASS"). One-shot author cost
  estimated at 2–3 implementer-days.
- **Deps:** add `{:sourceror, "~> 1.0", runtime: false}`. No runtime
  dependency footprint (Mix-only). Dialyzer and `mix xref` are already in
  `.tool-versions`.
- **CI:** ~30 s for the deck suite on a warm PLT (one job step, one
  artifact upload). Replaces 3 silent-skipping shell-script steps in
  `.github/workflows/ci.yml`; net workflow length unchanged or shorter.
- **Operability:** the manifest artifact is a stable input to the
  operability-and-hygiene-enforcement sibling's dashboard with zero
  parsing work — well-defined JSON schema versioned at
  `priv/gate/manifest.schema.json`.
- **Migration:** existing v1 gates 5.1/5.2/5.3 stay (AC-binding leaf
  owns them); this leaf adds a fourth CI job. v1's `prompt_caching: true`
  liars (Gemini, Bedrock) are pre-existing failures the gate will surface
  on its first run; the audit-ingestion sibling translates these into
  waivered findings with remediation dates rather than insta-breaking
  `main`.

## Dependencies

- **Sourceror 1.0+** for AST walking with formatter-preserving output;
  Tau's `mix.lock` does not currently pin it. Library is stable and
  widely used (Credo, Spitfire, ElixirLS depend on it).
- **`Tau.Provider` behaviour stability** — `CapabilityFidelity` keys off
  `capabilities/0` callback shape. Any restructuring of that callback
  changes the deck's parser.
- **Branch protection rule on `main`** must list `pre-merge code gates`
  as required, with `Require branches to be up to date before merging`
  ON, to prevent merging a stale-base PR whose manifest was generated
  against an older `lib/tau/`. This is a one-time GitHub admin action
  enumerated in the spec's "wiring" section.
- **pre-merge-evidence-and-skip-integrity sibling's manifest contract**
  — that leaf owns the manifest-consumer contract; this leaf produces a
  manifest that conforms to it. Schema co-evolution requires coordination
  in the same PR or back-to-back PRs.
- **knowledge-memory-and-audit-ingestion sibling's waiver registry** —
  this leaf consumes `priv/gate/waivers.toml`; that leaf owns the
  registry's authoring mechanism and expiry sweeps.

## Confidence

**Medium-high.** Sourceror-based AST walks for the specific patterns
named (capability-flag map literal, `try/rescue` AST nodes,
`:telemetry.execute` callsites, `@behaviour` declarations) are well-
trodden: Credo's custom-check infrastructure does exactly this style of
walk. The bespoke piece — capability-flag → required-callback table — is
trivial data. What would raise confidence to **high**: a
proof-of-concept `Mix.Tasks.Tau.Gate.CapabilityFidelity` that correctly
flags Gemini and Bedrock on the current `main` and correctly passes
Anthropic; estimated 2–3 hours.

What would lower it: discovering that Tau providers use macro-generated
`capabilities/0` whose AST is not statically resolvable without macro
expansion. Mitigation: run the gate on `Mix.Project.compile_path()` BEAM
files instead of source, using `:beam_lib.chunks/2` to read attributes
post-expansion. That falls back from "static AST" to "post-compile
introspection" but does not change the gate's external contract.

## Prior art / references

- **ASIC sign-off rule decks (DRC/LVS/ERC/antenna)** — Cadence Innovus,
  Synopsys IC Validator, Mentor Calibre. The "manifest with rule-deck IDs
  and per-deck violation counts that the foundry's sign-off tool refuses
  to accept on any non-zero count" is the structural model adopted here.
  See e.g. *Calibre Verification User's Manual* §"Run hierarchy and
  sign-off requirements."
- **Erlang/OTP release-engineering pre-flight checks** — `rebar3
  ct,dialyzer,xref` invoked together against an enumerated module set;
  the OTP release process's `Makefile` `release_tests` target. Pattern:
  multiple independent checkers each emit machine-readable output; a
  consolidating wrapper fails the release on any one. Mirrors the
  deck-runner pattern here.
- **Credo custom checks** (`Credo.Check` behaviour) — the per-check
  `run_on_all_source_files/2` callback enumerating inputs, returning
  `[Issue.t()]`. This proposal generalises the same shape to four
  decks beyond what Credo natively offers, and Credo itself is wrapped
  for `NoRescue` where Credo's `Credo.Check.Refactor.RescueInsteadOfTry`
  is sufficient.
- **mutation-testing tooling: `muzak`** (Devon Estes,
  github.com/devonestes/muzak) and **`mutant`** (mbj/mutant for Ruby,
  cited as design influence). The pattern of "scriptable check, JSON
  manifest, gate-on-manifest" applies here even though this proposal does
  not itself do mutation — it borrows the verdict-as-artifact discipline.
- **IEC 62304 §5.5.2 / DO-178C §6.3.4 controlled deviation** — waivers
  must be itemised, justified, time-bounded, and reviewed; un-itemised
  deviations are non-compliant. The `priv/gate/waivers.toml` expiry
  discipline maps directly.
- **`semgrep` / `ast-grep` rule packs** — pattern-as-data rules consumed
  by a generic engine; precedent for separating rule definition (decks)
  from rule engine (umbrella runner). Considered as a direct adoption
  (see "Rejected" below) but rejected on impedance mismatch.
- **Bazel `bazel test //... --test_output=errors`** — atomic "all
  required tests for the target ran, none was skipped, exit code is the
  truth" model. Precedent for the manifest-as-truth pattern over text-
  scraping of build output.

## Rejected adoptions

These were considered and rejected; recording why is part of AC-D:

- **`semgrep` or `ast-grep` as the bespoke-deck engine.** Both have
  excellent multi-language pattern matching but treat Elixir as a
  second-class target (no first-class AST support; rules express against
  text patterns or generic AST). The capability-flag → callback proof
  requires resolving `defmodule` attributes and `@callback`/`def`
  matching — Sourceror does this natively in Elixir's own AST; semgrep
  requires regex stand-ins that are fragile against macros. Adopted for
  *file-level* sniffs (e.g. "no `IO.puts` in `lib/`" would be a
  reasonable semgrep rule) but rejected for the four decks named in this
  leaf.
- **`mix dialyzer` alone for `Contracts`.** Dialyzer's `@behaviour`
  callback-completeness warning is necessary but insufficient: it does
  not catch SPEC §4-named structs that do not exist (root failure #1's
  primary form), because struct existence is a compile-time error already
  — the v1 failure was that `@doc` claimed adapters implemented
  callbacks they did not, and `@doc` is not analysed by Dialyzer.
  `Contracts` deck wraps Dialyzer for the callback subset and adds a
  bespoke `@doc`-claim cross-check.
- **`muzak` for `CapabilityFidelity`.** Mutation testing produces signal
  about test coverage of behaviour, not about declaration-vs-implementation
  consistency. Wrong tool for class #3. Mutation testing remains owned by
  the AC-binding sibling's Gate 5.3.
- **Pure Credo custom-check suite.** Credo's check framework is excellent
  for stylistic and small AST patterns but emits findings to stdout with
  no manifest. A Credo-only suite would fail AC-C (silent-skip
  impossibility) because Credo exits 0 when zero files match an
  `:included_files` glob. `NoRescue` wraps Credo's existing rescue check
  but the umbrella manifest layer is mandatory regardless.
- **Hook-based PreToolUse gating.** Hooks fire on local agent actions,
  not on PRs, and cannot enforce on a PR opened from a fork or from
  another agent's worktree. The gate must live in CI to be merge-
  blocking. (Hooks may complement by surfacing findings locally pre-
  push; that is the operability sibling's domain.)

## Silent-skip impossibility — explicit demonstration

Per AC-C, this proposal must make silent skip *structurally* impossible
for the four checks it owns. The argument:

1. **At the runner layer.** `@required_decks` is a compile-time constant
   list. `Mix.Tasks.Tau.Gate.Code` iterates it; a missing deck module
   raises `UndefinedFunctionError` on `deck_module(id)`, which is an
   uncaught exception → non-zero exit → CI red.
2. **At the deck layer.** `enumerate_inputs/0` returning `{:ok, []}`
   makes `deck_passes?` false via the explicit `%{inputs_enumerated: [],
   findings: []}` clause. Returning `{:error, msg}` produces a
   `%{verdict: :error}` result that also fails `deck_passes?`. There is
   no clause that returns `true` on an empty input list.
3. **At the CI layer.** The job step is `mix tau.gate.code --manifest
   …` with no `|| true`, no `exit 0`, no `continue-on-error`. Branch
   protection requires the named status check; GitHub will not allow the
   PR to merge if the check has not reported or reported FAIL.
4. **At the manifest layer.** The status check key includes
   `overall_verdict == PASS` *and* the artifact's existence. If the job
   crashed before writing the manifest, the artifact step (`actions/
   upload-artifact@v4`) fails; the workflow fails; the check fails red;
   merge is blocked.
5. **At the audit-trail layer.** The manifest is committed as a workflow
   artifact, retained 90 days. A reviewer can inspect *which* decks ran,
   *what* inputs each enumerated, *what* findings each produced — a
   reviewer claiming "the gate passed" must point to the artifact, not
   stdout.

No "empty input therefore PASS" code path exists; no "deck missing
therefore skipped" code path exists; no "CI command failed therefore
treated as PASS" code path exists. Each is checked at a different layer
so failure of one defence does not collapse the rest.
