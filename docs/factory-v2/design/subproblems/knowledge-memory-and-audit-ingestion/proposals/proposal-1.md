---
template_version: 1
template_name: proposal
proposal_id: 1
parent_problem: ../problem.md
---

# Proposal 1: A versioned Finding Registry compiled from structured frontmatter, consumed as a typed input by per-PR gates with mandatory applicability accounting

## Approach

Introduce a single authoritative artifact — the **Finding Registry** — that
materialises every open audit finding as a structured, machine-readable record
keyed by `finding-id`. The registry is built deterministically by a Mix task
(`mix tau.audit.compile`) that scans the four authoring surfaces
(`docs/problems/`, `docs/problems-archive-v1-modules/`, `docs/adr/`,
`docs/spec/SPEC-*.md` §3 blocks) for entries containing a typed frontmatter
block, validates them against a published JSON schema, and writes the
compiled registry to `priv/factory/findings.json` plus a Dialyzer-typed
Elixir constant module `Tau.Factory.Findings`. Pre-merge code gates consume
the registry through one and only one entry point — `Tau.Factory.Findings.applicable_to/2`
returning `{:checked, [%Finding{}]}` or `{:checked, []}` — so that "no
applicable findings" is a first-class, observable verdict distinct from
"skipped." A separate **Coverage Ledger** (a CI-emitted JSON artifact per
PR) records, for every open finding in the registry, the tuple
`{finding_id, applicable?, gate_run?, verdict}`; CI fails if any open
finding lacks a row, which is what makes silent-skip impossible. Authoring
a new finding is a no-op for the writer but for the factory becomes a fact
the moment the PR introducing it merges, because `mix tau.audit.compile`
runs on `main` push and the next PR's CI fetches the updated registry.

## Rationale

The leaf's complecting hypothesis identifies three knots: (1) "finding
exists" ≠ "enforcement exists"; (2) "finding closed" ≠ "remediation
happened"; (3) "which gate runs on which PR" is coupled to the diff with
no per-finding lens. The registry decomplects (1) by making the *only*
input gates accept be the compiled registry — code gates may not hard-code
a check list, may not read prose, may not pattern-match on file paths
themselves; they pattern-match on `%Finding{}` structs whose existence is
authored by writing audit prose with a typed frontmatter. (2) is
decomplected by encoding lifecycle as data: `status :: :open | :remediated
| :waived`, with `:waived` carrying an expiry `Date.t()` and a free-text
rationale, both validated at compile time. (3) is decomplected by giving
each finding an explicit `surface :: Surface.t()` (paths/globs + module
regex + optional AST selector); applicability is a pure function
`Surface.intersects?(surface, diff)` whose output is recorded for every
finding on every PR — gates do not decide *whether* to consider a finding,
they merely report the verdict for the slice the registry handed them.
The mandatory Coverage Ledger row-per-finding closes the silent-skip hole
at the substrate level (root §C); the registry's stable IDs and immutable
audit-source linkage close root §10 by construction.

## Sketch

### File layout

```
priv/factory/findings.json                 # compiled registry, gitignored on branches, committed on main
docs/factory-v2/audit-finding-schema.json  # JSON schema (versioned)
lib/tau/factory/findings.ex                # generated module: Tau.Factory.Findings (compile-time constant)
lib/tau/factory/finding.ex                 # %Finding{} struct + types
lib/tau/factory/surface.ex                 # surface manifest + diff-intersection
lib/tau/factory/coverage_ledger.ex         # ledger emitter + validator
lib/mix/tasks/tau.audit.compile.ex         # compile docs → priv/factory/findings.json
lib/mix/tasks/tau.audit.cover.ex           # produce coverage ledger from gate outputs
test/tau/factory/findings_test.exs         # round-trip + schema-validation property tests
test/tau/factory/meta_audit_probe_test.exs # AC(d): synthetic finding fires on probe PR
.github/workflows/audit-registry.yml       # main-push: rebuild + commit findings.json
.github/workflows/audit-coverage.yml       # PR: gates → ledger → fail-if-missing-row
```

### Authoring format (frontmatter convention, identical across all four surfaces)

```yaml
---
finding_id: F-2026-05-NORESCUE-001
status: open                                       # open | remediated | waived
authored: 2026-05-12
authored_in: docs/problems-archive-v1-modules/tau-infrastructure/solution.md
invariant: "No try/rescue or catch :exit across process boundaries (OTP NN #7)"
surface:
  paths: ["lib/tau/**/*.ex"]
  exclude_paths: ["lib/tau/**/_test_support.ex"]
  module_match: ~r/^Tau\..*/
  ast_selector: rescue_or_catch_exit               # named selector in Surface module
gate: Tau.Factory.Gates.NoRescue                   # the gate module that knows how to check this invariant kind
gate_args: {}
remediation:
  pr: null                                          # set on :remediated; required field then
waiver:
  expiry: null                                      # required when status: :waived
  rationale: null                                   # required when status: :waived
---
```

### Core types

```elixir
defmodule Tau.Factory.Finding do
  @type status :: :open | :remediated | :waived
  @type t :: %__MODULE__{
          id: String.t(),
          status: status(),
          authored: Date.t(),
          authored_in: String.t(),
          invariant: String.t(),
          surface: Tau.Factory.Surface.t(),
          gate: module(),
          gate_args: map(),
          remediation_pr: pos_integer() | nil,
          waiver_expiry: Date.t() | nil,
          waiver_rationale: String.t() | nil
        }
  defstruct [...]
end

defmodule Tau.Factory.Surface do
  @type t :: %__MODULE__{
          paths: [String.t()],
          exclude_paths: [String.t()],
          module_match: Regex.t() | nil,
          ast_selector: atom() | nil
        }
  @spec intersects?(t(), diff :: [String.t()]) :: boolean()
  def intersects?(%__MODULE__{} = s, files), do: ...
end
```

### The single consumption contract

```elixir
defmodule Tau.Factory.Findings do
  @moduledoc "Generated at build time from priv/factory/findings.json"
  @spec all() :: [Finding.t()]
  @spec applicable_to(diff_files :: [String.t()], opts :: keyword()) ::
          {:checked, applicable :: [Finding.t()], skipped :: []}
  # NB: third tuple element is always [] -- there is no "skipped" channel.
end
```

`{:checked, [], []}` means "registry consulted, zero applicable findings"
— a valid, expected, observable verdict. There is no return path that
means "did not consult"; missing consultation surfaces as a missing
Coverage Ledger row, which is a CI-fail.

### Coverage Ledger contract

```elixir
defmodule Tau.Factory.CoverageLedger do
  @type row :: %{
          finding_id: String.t(),
          applicable: boolean(),
          gate_module: module(),
          gate_run: boolean(),
          verdict: :pass | :fail | :n_a,
          evidence_path: String.t()  # path to gate's stdout/stderr artifact
        }
  @spec emit(rows :: [row()], path :: String.t()) :: :ok
  @spec validate!(ledger_path :: String.t(), registry :: [Finding.t()]) ::
          :ok | no_return()
  # validate!/2 raises if: any open finding lacks a row;
  # any applicable=true row has gate_run=false;
  # any gate_run=true row lacks evidence_path.
end
```

### Build / verdict-consumption pipeline (PR CI)

```
                  ┌──────────────────────────────────────────────┐
                  │ Step 1: fetch priv/factory/findings.json     │
                  │         from origin/main (immutable input)   │
                  └──────────────────────────────────────────────┘
                                       │
                                       ▼
              ┌────────────────────────────────────────────────────┐
              │ Step 2: PR diff → file list → Surface.intersects?  │
              │         for every finding → applicability table    │
              └────────────────────────────────────────────────────┘
                                       │
                                       ▼
   ┌─────────────────────────────────────────────────────────────────────┐
   │ Step 3: for each applicable finding, invoke finding.gate.check(     │
   │           finding, diff_paths) → {:pass | :fail, evidence}.         │
   │         For each non-applicable open finding, record :n_a.          │
   └─────────────────────────────────────────────────────────────────────┘
                                       │
                                       ▼
              ┌────────────────────────────────────────────────────┐
              │ Step 4: mix tau.audit.cover → coverage-ledger.json │
              └────────────────────────────────────────────────────┘
                                       │
                                       ▼
       ┌────────────────────────────────────────────────────────────────┐
       │ Step 5: CoverageLedger.validate!(ledger, registry); any        │
       │         :fail verdict OR missing row OR applicable-but-not-run │
       │         exits non-zero. This is the merge gate.                │
       └────────────────────────────────────────────────────────────────┘
```

### Meta-test (AC item d)

```elixir
defmodule Tau.Factory.MetaAuditProbeTest do
  use ExUnit.Case, async: false

  @tag :meta_audit
  test "a freshly-authored finding fires on a probe PR" do
    finding = synthetic_finding(id: "F-PROBE-001",
                                surface: %Surface{paths: ["lib/tau/factory/probe_target.ex"]},
                                gate: Tau.Factory.Gates.AlwaysFail)
    registry = Tau.Factory.Findings.all() ++ [finding]
    diff = ["lib/tau/factory/probe_target.ex"]
    {:checked, applicable, []} =
      Tau.Factory.Findings.applicable_to(diff, registry: registry)
    assert finding in applicable
    rows = run_gates(applicable, diff)
    assert Enum.any?(rows, &(&1.finding_id == "F-PROBE-001" and &1.verdict == :fail))
  end
end
```

### Initial population (AC item e)

`mix tau.audit.compile --bootstrap` walks the existing audit corpus
(`docs/problems/` and `docs/problems-archive-v1-modules/`) and, for each
known `rescue`-site finding flagged in the prior module audit, writes a
`finding_id: F-V1-NORESCUE-NNN` entry to a bootstrap manifest that the
maintainer copies into the relevant docs file's frontmatter (one PR per
batch). The bootstrap script does NOT silently inject findings — it
generates a diff for review — because the registry's authority depends
on findings being authored, not invented.

## Tradeoffs

### Strengths

- **Single contract surface.** Gates consume the registry through exactly one
  function (`applicable_to/2`); there is no escape hatch and no "skipped"
  return. This is the structural property that makes root §C silent-skip
  impossible *for this leaf*.
- **Lifecycle is data, not prose.** `status`, `waiver_expiry`, and
  `remediation_pr` are typed fields the compiler validates; an expired
  waiver fails compilation of `findings.json`, so waivers cannot quietly
  outlive their expiry (closes leaf-complecting knot #2).
- **Diff-applicability is a pure function.** `Surface.intersects?/2`
  takes the finding's manifest and the PR's file list and returns a
  boolean — no I/O, fully testable with `StreamData`. The applicability
  matrix is therefore reproducible across machines.
- **Reuse over reinvention** (root §D): the gate *execution* layer plugs
  into Credo's check-module shape (each `Tau.Factory.Gates.*` is a thin
  Credo `Check` so the existing `mix credo --strict` pipeline picks it
  up); JSON Schema for the frontmatter is the standard ecosystem choice;
  the Coverage Ledger is a SARIF-shaped JSON for future GitHub Code
  Scanning ingestion.
- **Authoring is low-friction.** Writers add a YAML frontmatter block —
  the same shape ADRs and SPECs already carry — to a Markdown file; no
  separate registration step, no new CLI dance.
- **Meta-test guarantees the loop.** AC (d) is a real ExUnit test in
  CI; if the registry-to-gate plumbing is ever broken, the meta-test
  goes red on the next PR.

### Weaknesses

- **Generated module + JSON file dual-maintenance.** `Tau.Factory.Findings`
  is generated from `priv/factory/findings.json`; the two must not drift.
  Mitigation: a compile-time check that `findings.json`'s SHA-256 matches
  a constant embedded in the module; mismatch fails compilation.
- **JSON Schema rigidity.** Adding a new finding *kind* (e.g. a new
  invariant family unknown to the schema today) requires a schema-version
  bump and a coordinated PR across docs + schema + the relevant gate
  module. Mitigation: schema versioning is explicit (`schema_version`
  field) and the registry compiler supports multiple concurrent versions.
- **Surface AST-selector vocabulary.** `ast_selector: rescue_or_catch_exit`
  is a named selector that must be implemented in `Tau.Factory.Surface`;
  adding novel AST shapes requires Elixir code, not just docs. The set
  is finite and small (rescue/catch, behaviour-callback presence,
  telemetry-execute callsite, capability-flag literal) but it is a real
  ceiling.
- **Bootstrap is a one-time human-in-loop step.** The existing prior-audit
  findings do not magically gain frontmatter; someone must add it in a
  bootstrap PR. The system catches the *next* uningested finding for
  free, not the historical backlog.
- **Cross-PR finding authorship has a lag of one merge.** A finding
  authored on PR #X is not in-force until PR #X merges and the registry
  is rebuilt on `main`; concurrent PR #Y that introduces a violation
  will not be gated by the not-yet-merged finding. This is a deliberate
  consistency choice (registry-of-record == `origin/main`) but worth
  naming.

### Costs

- ~600 LOC of new Elixir (`Finding`, `Surface`, `Findings` generator,
  `CoverageLedger`, two Mix tasks).
- ~150 LOC of JSON Schema + a `:ex_json_schema` Hex dep (≈ 4 transitive
  deps, MIT-licensed, ~3kLOC). Already in the same ecosystem class as
  Jason.
- ~200 LOC of ExUnit (round-trip property test, meta-audit probe test,
  surface-intersection property tests).
- Two new CI workflows (`audit-registry.yml`, `audit-coverage.yml`),
  ~80 lines each.
- Bootstrap pass: a one-off PR per `docs/problems-archive-v1-modules/`
  surface to add finding frontmatter to existing audit prose. ~10 PRs,
  each small.
- No new long-running processes (the registry is a compile-time
  constant), so OTP NN #1 / #3 are unaffected.

## Dependencies

- **pre-merge-code-gates** sibling: must expose at least one concrete
  `Tau.Factory.Gates.NoRescue` (and analogous modules for the other
  invariant kinds) that conforms to the gate-check contract
  (`check(finding, diff_paths) :: {:pass | :fail, evidence}`). This
  proposal *defines* the contract; the sibling *implements* the gates.
- **pre-merge-evidence-and-skip-integrity** sibling: must accept the
  Coverage Ledger as a first-class evidence artifact and refuse to
  merge a PR whose ledger validation fails. This is the substrate that
  enforces root §C; this proposal feeds it.
- **operability-and-hygiene-enforcement** sibling: must surface
  `findings_open / findings_waived / findings_remediated_this_week` as
  dashboard fields (root §E). This proposal exposes them via
  `Tau.Factory.Findings.all/0` and a JSON dump endpoint.
- Hex dep: `:ex_json_schema ~> 0.10` (schema validation at compile time).

## §Build-order

Strict ordering — each step is independently shippable, each is gated
by the existing factory-loop, no step opens a PR that depends on a
later step's contract being live.

1. **B1 — Schema + struct.** Land `docs/factory-v2/audit-finding-schema.json`,
   `lib/tau/factory/finding.ex`, `lib/tau/factory/surface.ex`,
   `Tau.Factory.Surface.intersects?/2` with `StreamData` properties.
   Closes nothing yet; pure data layer.
2. **B2 — Compiler task.** Land `mix tau.audit.compile`; emits
   `priv/factory/findings.json` from a single hand-written sample
   finding committed under `docs/problems/`. Compile-time SHA check
   in `Tau.Factory.Findings`. Closes leaf AC item (a) for the schema
   shape.
3. **B3 — Consumption contract.** Land `Tau.Factory.Findings.applicable_to/2`
   with property tests proving the third tuple element is always `[]`
   (no skipped channel). Closes leaf AC item (c) for the applicability
   function.
4. **B4 — Coverage Ledger.** Land `Tau.Factory.CoverageLedger.emit/2`
   and `validate!/2`. Unit tests cover the three failure modes (missing
   row, applicable-not-run, gate-run-no-evidence). Closes the
   silent-skip-impossibility surface for this leaf (root §C).
5. **B5 — CI wiring.** Land `.github/workflows/audit-registry.yml`
   (main-push → rebuild → commit `findings.json`) and
   `.github/workflows/audit-coverage.yml` (PR → run gates → emit ledger
   → validate → set merge status). After B5, every PR carries a ledger;
   no PR can merge without one. Closes leaf AC item (g) for CI
   integration.
6. **B6 — Meta-test.** Land `Tau.Factory.MetaAuditProbeTest`; runs in
   `mix test` and in CI; verifies a synthetic finding fires on a probe
   diff. Closes leaf AC item (d).
7. **B7 — First real finding.** Pair with the pre-merge-code-gates
   sibling: their first concrete gate (`Tau.Factory.Gates.NoRescue`)
   plus an authored frontmatter on the existing rescue-site audit in
   `docs/problems-archive-v1-modules/tau-infrastructure/solution.md`.
   Verifies the end-to-end loop on a real case (closes leaf AC item
   (e) for the rescue surface).
8. **B8 — Bootstrap sweep.** Iterate the remaining surfaces in
   `docs/problems-archive-v1-modules/` and `docs/problems/`, adding
   frontmatter per finding. One PR per surface, each gated by the
   factory-loop. Closes leaf AC item (e) in full.
9. **B9 — Dashboard fields.** Wire `Tau.Factory.Findings.all/0` into
   the operability dashboard. Hands off to operability sibling.

After B5, the silent-skip-impossibility property is in force; after
B7, the system has caught its first real finding end-to-end; after
B8, the historical backlog from root §10 is registered.

## Confidence

**High.** The contract surface is small and pure-functional; the JSON
Schema + Credo Check pattern is well-trodden ecosystem ground; the
silent-skip-impossibility property is structural (no "skipped" return
path exists in the consumption contract, so it cannot be reached). The
two main risks are bootstrap effort (human-in-loop, but bounded) and
the AST-selector vocabulary ceiling (small, finite set). Confidence
rises further once the meta-test (B6) lands and we observe a synthetic
finding round-trip in CI.

## Prior art / references

- `mix credo` custom check modules — same shape as the gate-execution
  layer this proposal feeds; reused, not reinvented.
- Sobelow's rule modules — same per-finding, surface-scoped enforcement
  pattern.
- GitHub Code Scanning SARIF format — the Coverage Ledger is
  SARIF-shaped to enable a future round-trip into the GitHub Security
  tab with no schema rewrite.
- `:ex_json_schema` — established Hex JSON Schema validator,
  compile-time-callable.
- `.claude/plugins/polya-audit/` — the existing in-repo Pólya plugin
  whose templates established the typed-frontmatter authoring convention
  this proposal extends to audit findings.
- The factory-v1 `Tau.Factory.Gate` module (`lib/tau/factory/gate.ex`)
  and its CLI wrappers (`mix tau.gate.ac_linkage`, etc.) — proves the
  "pure function + Mix task + CI job" pattern works for gating in this
  repo.
