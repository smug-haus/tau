---
template_version: 1
template_name: solution
parent_problem: ../problem.md
node_kind: leaf
mode: leaf
synthesised_from:
  - proposals/proposal-1.md
  - proposals/proposal-4.md
selection_method: hybrid
revision: 0
---

# Solution: Compiled Finding Registry + Coverage Ledger + Proof-of-Teeth Probes

## Recommendation

Author every audit finding as YAML frontmatter in a structured Markdown
file under `docs/audit/findings/<finding-id>.md`. A Mix compiler
(`mix tau.audit.compile`) deterministically materialises those sources
into a single immutable artifact `priv/factory/findings.json` plus a
generated Dialyzer-typed module `Tau.Factory.Findings`. The pre-merge
code-gates sibling consumes the registry through **one and only one**
contract — `Tau.Factory.Findings.applicable_to/2` returning
`{:checked, applicable, []}` — there is no `:skipped` return path
syntactically. Every finding declares a **probe module** (a
`Tau.Factory.Audit.Probe` behaviour implementation) and a
`proven_at_sha` that compilation validates by re-running the probe
against that historical tree and asserting it returns `{:violation, _}`.
Every PR emits a **Coverage Ledger** (`audit-coverage.json`,
SARIF-shaped) containing one row per open finding; CI exits non-zero
when a row is missing, when an `applicable: true` row has
`gate_run: false`, or when a `gate_run: true` row lacks an evidence
artifact. A nightly **Audit Health** workflow on `main` runs every open
finding's probe and HALTS the factory loop (places
`.claude/STOP-FACTORY`) whenever an open finding's probe returns
`:ok` — proving either the violation was silently fixed (re-status to
`:remediated`) or the probe's teeth fell out (re-author with current
`proven_at_sha`). Waivers are typed fields with required `expires`
date and `rationale`; an expired waiver fails registry compilation.

## Selected from

- **Chosen:** **hybrid of `proposals/proposal-1.md`
  (Versioned Finding Registry + Coverage Ledger) and
  `proposals/proposal-4.md` (Adversarial probes with `proven_at_sha`
  + nightly health gate).**

- **Why chosen:** Proposal 1 dominates on the silent-skip-impossibility
  axis — the Coverage Ledger's row-per-open-finding requirement is the
  cleanest mechanical proof in the four-proposal set that the parent's
  acceptance criterion (c) holds, and the "no `:skipped` return"
  property is structural (no code path returns it) rather than
  procedural. Proposal 1 also wins on ecosystem fit: the Mix-task +
  JSON-Schema + Credo-Check pattern is already proven in the v1
  factory's `Tau.Factory.Gate` and `mix tau.gate.*` CLIs, so reuse is
  immediate. Proposal 4 dominates on the *staleness* axis Proposal 1
  leaves open — a registered finding whose check no longer detects
  anything (because the code shape it watched for was renamed, the
  AST grammar evolved, or the violation was quietly fixed without a
  status flip) is invisible to Proposal 1 but caught the next morning
  by Proposal 4's nightly health gate. The `proven_at_sha` field
  generalises v1's mutation-check property (gate 5.3) from AC tests
  to audit probes — same conceptual surface for the coordinator,
  same proven mechanism. Proposals 2 and 3 were rejected: Proposal 2's
  MCP knowledge-graph server adds a non-hermetic external dependency
  in exchange for agent-side query that the dashboard sibling can
  serve from `Tau.Factory.Findings.all/0` without MCP; Proposal 3's
  Datalog substrate is elegant but adds ~2000 LOC of in-tree
  evaluator on a BEAM where Datalog literacy is rare, where the
  same applicability semantics fall out of a pure function
  (`Surface.intersects?/2`) at a tenth the code.

  The hybrid is more than the sum: Proposal 1 alone leaves the door
  open for a finding-with-toothless-check; Proposal 4 alone has no
  Coverage Ledger and no mechanical proof that every open finding
  was *considered* on every PR (only that probes that ran didn't
  fire). Together: Proposal 1 guarantees consideration on every PR;
  Proposal 4 guarantees that what is considered has currently
  detectable teeth.

| # | Fit | Mechanical enforceability | Silent-skip impossibility | Ecosystem reuse (root §D) | Per-component build cost |
|---|---|---|---|---|---|
| 1 | Yes | High (one Mix task + one ledger) | Highest (no `:skipped` return; row-per-finding) | High (Credo/JSON Schema/Mix/Dialyzer) | Low (~600 LOC + 2 workflows) |
| 2 | Partially | Medium (MCP non-hermetic; adapter is hermetic) | High (`:checked_empty` distinct) | Highest (memory cascade + MCP server) | Low (~200 LOC + Node dep) |
| 3 | Yes | Highest (one binary, deterministic) | Highest (positive-value verdict + workflow lint) | Medium (Datalog rare on BEAM) | High (~1500-2000 LOC in-tree) |
| 4 | Yes | High (probe per finding) | High (probe `:ok`/`:violation`; no `:skipped`) | High (Sobelow/Credo pattern; generalises v1 mutation-check) | Medium (~700 LOC + per-finding probe authoring tax) |

Leaning per `select.md` heuristics: P1 + P4 win on **decomplecting
depth** (data + executable probe + ledger fully decomplect
authoring/enforcement/staleness/consideration); P3 ties on depth but
loses on ecosystem-reuse and cost. P1 + P4 are independently
**reversible** (the registry compiler and the ledger can be
deleted leaving authoring prose intact; probes can be retired with
a status flip). P1's `applicable_to/2` is a **composition** of
pure functions; P4's `Probe` is a **behaviour** — both align with
OTP non-negotiables #2 and #8. The hybrid's per-component scopes
are non-overlapping (registry/ledger vs probe behaviour), so the
combination is composition, not aggregation.

## What changes

### Concrete artifacts the spec calls for

The list below enumerates EVERY new artifact. Build-order is
§Build-order; cross-component contracts are §Cross-component
contracts.

#### Authoring surface

- `docs/audit/findings/` — new directory; the **single authoring
  surface** for audit findings. Existing `docs/problems/`,
  `docs/problems-archive-v1-modules/`, ADRs, and SPEC §3 entries
  remain prose homes for *explanation*; the finding *as gate input*
  lives in `docs/audit/findings/<finding-id>.md`. The prose docs may
  link to the finding ID; the binding direction is finding → prose,
  not prose → finding.
- `docs/audit/findings/_index.md` — auto-generated index produced by
  `mix tau.audit.compile`; lists open / waived / remediated counts
  per surface. Committed and validated for staleness in CI (an
  out-of-date `_index.md` fails the compile step).
- `docs/audit/finding-schema.json` — versioned JSON Schema (Draft
  2020-12) for the YAML frontmatter. `schema_version: 1` is the
  initial value; `mix tau.audit.compile` rejects unknown
  `schema_version`s; bumps require a coordinated schema + compiler PR.
- `docs/audit/SPEC-AUDIT-INGESTION.md` — the SPEC §3 invariants for
  this subsystem (D-NNN allocation: D-700..D-719 reserved). Authored
  per `spec-before-code.md` before any implementer touches the
  registry.

#### Finding frontmatter (authoritative example)

A finding file is a Markdown document whose frontmatter conforms to
`docs/audit/finding-schema.json`. Concrete example:

```markdown
---
schema_version: 1
finding_id: F-2026-05-NORESCUE-007
title: "Port lifecycle wrapped in rescue clause (Bash adapter)"
status: open                              # open | remediated | waived
authored_at: 2026-05-21
authored_in: docs/problems-archive-v1-modules/tau-coding-agent/rescue-sites.md#L42
invariant: "OTP non-negotiable #7 — no try/rescue across process boundaries"
surface:
  paths:
    - "lib/tau/tools/builtin/bash.ex"
    - "lib/tau/coding_agent/**/*.ex"
  exclude_paths: []
  module_match: ~r/^Tau\.(Tools\.Builtin\.Bash|CodingAgent\..*)$/
  ast_selector: rescue_or_catch_exit       # named selector; see Surface module
probe: Tau.Factory.Audit.Probes.PortLifecycleRescue
proven_at_sha: 7c4ad9e2                    # SHA at which the probe is verified to return {:violation, _}
remediation:
  pr: null                                 # required when status: remediated; the PR that fixed it
waiver:
  expires: null                            # ISO-8601 date; required when status: waived
  rationale: null                          # free-text; required when status: waived
  approver: null                           # email; required when status: waived
relations: []                              # optional: [{kind: supersedes, finding_id: F-...}]
---

## Context
<prose explaining the violation, the audit that surfaced it, the remediation strategy>
```

#### Elixir modules (new code under `lib/tau/factory/audit/`)

- `lib/tau/factory/audit/finding.ex` — `%Finding{}` struct + types;
  pure data; no GenServer (OTP NN #3).
- `lib/tau/factory/audit/surface.ex` — `%Surface{}` struct +
  `intersects?/2` pure function (paths/globs/module-match
  intersection with PR diff); `StreamData` properties.
- `lib/tau/factory/audit/probe.ex` — the `Tau.Factory.Audit.Probe`
  behaviour. Callbacks: `applicable?/1 :: (Diff.t() -> boolean)`,
  `run/1 :: (Ctx.t() -> :ok | {:violation, map})`. Pattern-matched
  on atoms/structs (OTP NN #2).
- `lib/tau/factory/audit/diff.ex` — `%Diff{}` struct
  (`paths`, `module_set`, `ast_changes`); built from
  `git diff origin/main...HEAD`; pure (no IO inside the struct;
  the caller pumps git output in).
- `lib/tau/factory/findings.ex` — **generated** module (compile-time
  constant). Public surface is exactly:
  - `@spec all() :: [Finding.t()]`
  - `@spec applicable_to(diff :: Diff.t(), opts :: keyword()) ::
     {:checked, applicable :: [Finding.t()], skipped :: []}`
  - The third tuple element is constrained by a Dialyzer spec
    (`skipped :: []`) AND by a property test (`property "skipped
    channel is always empty list"`); together this makes
    `:skipped` unreachable in the type system AND the test surface.
- `lib/tau/factory/coverage_ledger.ex` — ledger emitter and
  validator. Public surface:
  - `@spec emit(rows :: [row()], path :: String.t()) :: :ok`
  - `@spec validate!(ledger_path :: String.t(),
     registry :: [Finding.t()]) :: :ok | no_return()`
  - Raises on: any open finding lacking a row; any
    `applicable: true` row with `gate_run: false`; any
    `gate_run: true` row lacking `evidence_path`. Each raise carries
    the finding ID and the failure mode in the message.
- `lib/tau/factory/audit/probes/` — directory of probe modules.
  Seed population (B7-B8 below):
  - `lib/tau/factory/audit/probes/port_lifecycle_rescue.ex`
  - `lib/tau/factory/audit/probes/cross_process_rescue.ex`
  - `lib/tau/factory/audit/probes/cross_process_catch_exit.ex`
  - `lib/tau/factory/audit/probes/capability_flag_fidelity.ex`
  - `lib/tau/factory/audit/probes/telemetry_consumer_required.ex`
  - `lib/tau/factory/audit/probes/behaviour_callback_completeness.ex`
  - additional probes as bootstrap surfaces additional findings
    (~11 from the v1 archive backfill).

#### Mix tasks (`lib/mix/tasks/`)

- `lib/mix/tasks/tau.audit.compile.ex` — `mix tau.audit.compile`.
  Scans `docs/audit/findings/*.md`, validates frontmatter against
  schema, validates each open finding's `proven_at_sha` by
  re-running the probe against that historical tree
  (`git worktree add <tmp> <sha>` and asserting `{:violation, _}`),
  rejects expired waivers, rejects duplicate `finding_id`s, emits
  `priv/factory/findings.json` and regenerates
  `docs/audit/findings/_index.md`. Exits non-zero on any failure.
- `lib/mix/tasks/tau.audit.gate.ex` — `mix tau.audit.gate`. Loads
  registry, computes diff, calls `Findings.applicable_to/2`, invokes
  every applicable probe, emits per-probe evidence artifacts under
  `_build/audit/evidence/<finding-id>.txt`. Writes
  `audit-coverage.json` (the ledger). Exits non-zero on any
  `:violation` OR on `validate!/2` raise.
- `lib/mix/tasks/tau.audit.health.ex` — `mix tau.audit.health`.
  Runs every open finding's probe against the current `main` tree
  (no diff filter; probes that do not error on "no applicable
  change" return `:ok`). Lists each `:ok`-returning open finding as
  a **staleness violation** and writes `priv/factory/STOP-FACTORY`
  (which is then copied to `.claude/STOP-FACTORY` by the workflow,
  per the factory-loop kill-switch convention). Lists each waiver
  whose `expires` is within 7 days as a warning (does not halt).
- `lib/mix/tasks/tau.audit.import.ex` — `mix tau.audit.import`.
  One-shot bootstrap: walks `docs/problems/` and
  `docs/problems-archive-v1-modules/`, generates draft
  `docs/audit/findings/F-V1-*.md` files per flagged finding,
  emits a unified diff for human review (does NOT auto-commit
  per Proposal 1's bootstrap discipline).
- `lib/mix/tasks/tau.audit.scaffold.ex` — `mix tau.audit.scaffold
  <finding-id> [--surface-paths path,path] [--invariant ...]`.
  Stamps a finding YAML + probe stub from templates to reduce the
  per-finding authoring tax (Proposal 4 mitigation).

#### CI workflows (`.github/workflows/`)

- `.github/workflows/audit-registry.yml` — triggers on push to
  `main` and on pull_request. On main: runs `mix tau.audit.compile`
  (which validates all `proven_at_sha`s); if the produced
  `priv/factory/findings.json` differs from the committed one, opens
  an auto-PR to refresh. On PR: runs `mix tau.audit.compile` and
  asserts the output matches the committed `findings.json` byte-for-
  byte (no `--allow-stale` flag; no `continue-on-error`).
- `.github/workflows/audit-coverage.yml` — runs on every PR. Steps:
  (1) checkout PR diff; (2) fetch `priv/factory/findings.json` from
  origin/main (the immutable input); (3) `mix tau.audit.gate`;
  (4) upload `audit-coverage.json` as a workflow artifact; (5)
  comment a registry fingerprint on the PR. No `if:` guard, no
  `continue-on-error`, no `|| true` (the v1 ci.yml:115 anti-pattern
  is explicitly absent).
- `.github/workflows/audit-health.yml` — scheduled (`cron: '0 7 * *
  *'` — 07:00 UTC daily) on `main`. Runs `mix tau.audit.health`.
  On staleness violation: copies the generated STOP-FACTORY sentinel
  to `.claude/STOP-FACTORY` via a commit on a `factory/halt-<date>`
  branch, opens a PR titled `[FACTORY HALT] audit stale: <finding-
  ids>`, and pings the user via a GitHub issue
  (`type: factory-halt`). The kill-switch latency is bounded by one
  factory step (per `factory-loop.md` §"Continuity and the kill
  switch").
- `.github/workflows/audit-workflow-lint.yml` — runs on PR; a guard
  test in `test/ci/workflow_lint_test.exs` parses
  `.github/workflows/*.yml` and asserts no `audit-*` job carries
  `continue-on-error: true`, `if: <conditional that can suppress>`,
  or `|| true`. Borrowed from Proposal 3's §"At CI level" layer-2
  silent-skip defence — small enough to lift without adopting
  Datalog.

#### Hooks (`.claude/hooks/`)

- `.claude/hooks/pre-commit-audit-finding.py` — Python stdlib hook
  (per `hooks-and-scripts.md`): when the commit touches
  `docs/audit/findings/*.md`, runs `mix tau.audit.compile --check`
  (a dry-run mode) and rejects the commit on schema violations or
  duplicate IDs. Cheap (no probe re-runs in the hook; those run in
  CI). Registered in `.claude/settings.json` under
  `hooks.PreToolUse[].Bash`.

#### Plugin / skill surface (`.claude/plugins/polya-audit/`)

The existing `polya-audit` plugin (v1 has `agents/`, `skills/`,
`templates/problem.md`) is extended — not forked — with:

- `.claude/plugins/polya-audit/skills/audit-finding-author.md` — new
  on-demand skill. Loaded when the user types `/polya-audit:audit-
  finding-author` OR when an agent recognises it needs to register
  a finding. Documents the frontmatter schema, the probe-authoring
  workflow, the `proven_at_sha` requirement, and the
  `mix tau.audit.scaffold` shortcut. Includes the canonical YAML
  example block above.
- `.claude/plugins/polya-audit/commands/audit-add.md` — slash command
  `/polya-audit:audit-add "<title>"` that scaffolds a finding +
  probe pair and opens an editor.
- `.claude/plugins/polya-audit/agents/audit-author.md` — sub-agent
  persona briefed to author one finding end-to-end: write the
  frontmatter, write the probe, demonstrate `proven_at_sha`, commit
  the pair. Used by the coordinator when an audit-flagged surface
  needs registration.
- `.claude/plugins/polya-audit/templates/audit-finding.md` — the
  Markdown + frontmatter template the slash command stamps.
- `.claude/plugins/polya-audit/templates/audit-probe.ex.eex` — the
  probe-module Elixir template.

The plugin's `plugin.json` adds these to the existing `skills`,
`commands`, and `agents` arrays. Auto-discovery is by convention
(per `plugin-dev:plugin-structure`); no new manifest fields.

#### Settings (`.claude/settings.json`)

- `hooks.PreToolUse` extended with the pre-commit-audit-finding hook
  registration. No other settings changes; the registry is consumed
  by CI, not by the coordinator session directly.

#### Tests

- `test/tau/factory/audit/finding_test.exs` — round-trip + schema
  validation property tests for `%Finding{}`.
- `test/tau/factory/audit/surface_test.exs` — `intersects?/2`
  property tests (StreamData generators for path/glob inputs).
- `test/tau/factory/findings_test.exs` — generated-module integrity
  (SHA matches `findings.json`; `applicable_to/2` type spec).
- `test/tau/factory/coverage_ledger_test.exs` — `validate!/2` raises
  on each of the three failure modes; happy path emits valid SARIF.
- `test/tau/factory/audit/probe_test.exs` — `Probe` behaviour
  contract (each registered probe exports `applicable?/1` and
  `run/1`; `run/1` returns `:ok` or `{:violation, map()}`).
- `test/tau/factory/meta_audit_probe_test.exs` — **the meta-test**
  (AC item d). Adds a synthetic finding to an in-test registry
  overlay; asserts a probe PR touching the synthetic surface is
  blocked by `mix tau.audit.gate`; asserts the same probe returns
  `:ok` when the fixture is corrected; asserts removing the finding
  removes the block (the meta-test is the "the loop is alive"
  signal).
- `test/tau/factory/golden_findings_test.exs` — borrowed from
  Proposal 3: a corpus of (known-bad-diff, expected-finding-violation)
  pairs that ANY rule-evaluator bug breaks. Runs on every PR and on
  nightly health.
- `test/ci/workflow_lint_test.exs` — workflow-file lint asserting
  no silent-skip patterns in `audit-*` workflows.

#### Dependencies

- `:ex_json_schema ~> 0.10` — compile-time JSON Schema validation.
  ~3 kLOC, MIT, ≈ 4 transitive deps, established Hex package.
- No new runtime dependencies (the registry is a compile-time
  constant; ledger emission uses `Jason` already in deps).
- No Node.js dependency (Proposal 2's MCP server is NOT adopted in
  this leaf; the operability sibling may add an MCP-based query
  layer later as a non-CI-critical-path additive).

## What does not change

- **The `docs/problems/` and `docs/problems-archive-v1-modules/`
  directories.** They remain the prose homes for audit
  investigations. Findings *link* into them via the
  `authored_in:` field; nothing in the registry replaces their
  prose content.
- **`docs/spec/SPEC-*.md` §3 invariants.** A SPEC §3 D-NNN entry
  may *cite* a finding-id, but the gate input is the finding file,
  not the SPEC entry. SPEC↔code drift detection is owned by the
  post-merge-cross-artifact-coherence sibling, not this leaf.
- **The existing `Tau.Factory.Gate` module and `mix tau.gate.*`
  CLIs.** The audit-gate task is additional, not a replacement;
  gates 5.1 / 5.2 / 5.3 keep their current semantics.
- **The `polya-audit` plugin's existing problem/decompose/propose/
  select/validate skills.** They remain the design-process surface
  for new architectural decisions; the audit-finding skill is
  additive.
- **The Claude memory cascade** (`CLAUDE.md`, `TAU.md`,
  `MEMORY.md`). It is NOT used as a registry; per Proposal 2's
  noted weakness, loading 100+ findings into every session context
  is the wrong default. The cascade may eventually load a one-line
  `findings_open_count` summary; that is operability sibling
  territory, not this leaf.
- **The factory-loop's gate (`/pr` skill) and critic/reviewer
  personas.** The audit gate runs in CI; the coordinator does NOT
  call probes directly. The critic and reviewer remain quality
  checks above the mechanical gates (per root §B).
- **Worktree discipline** (`worktree-discipline.md`). The
  `proven_at_sha` historical-tree probe run uses
  `git worktree add` per existing rules; no new isolation pattern.

## Cross-component contracts

These are the load-bearing interfaces between this leaf and its
sibling leaves; they MUST be honoured at the interface boundary.

### → pre-merge-code-gates (Subproblem 2)

- **Input contract.** This leaf delivers
  `Tau.Factory.Findings.applicable_to(diff, opts) :: {:checked,
  applicable :: [Finding.t()], []}`. The sibling consumes this as
  its sole source of audit-driven gate inputs; no hardcoded check
  lists.
- **Probe-execution contract.** Each `%Finding{}` carries a
  `probe :: module()` field; the sibling's gate runner invokes
  `apply(finding.probe, :run, [%Ctx{diff: diff, finding: finding}])`
  and treats `{:violation, _}` as merge-blocking. The `Probe`
  behaviour lives in this leaf; the runner that calls it lives in
  the sibling.
- **No `check_module` parallel surface.** The sibling MUST NOT
  define its own audit-check protocol; it consumes the `Probe`
  behaviour defined here.

### → pre-merge-evidence-and-skip-integrity (Subproblem 3)

- **Coverage Ledger is first-class evidence.** The sibling's
  merge-block decision MUST refuse to merge a PR whose
  `audit-coverage.json` is missing, malformed, or fails
  `CoverageLedger.validate!/2`.
- **No `|| true` on audit workflows.** The sibling's CI-lint guard
  test (`test/ci/workflow_lint_test.exs`) is shared with this leaf;
  this leaf authors the audit-specific assertions, the sibling
  authors the cross-cutting assertions.

### → post-merge-cross-artifact-coherence (Subproblem 4)

- **Findings as inputs to coherence checks.** A SPEC↔SPEC
  contradiction may be authored as a finding whose probe is an
  AST/text comparison across SPEC files; the sibling consumes the
  same `Probe` behaviour, no new substrate.
- **Direction of authority.** This leaf does NOT crawl SPEC §3 for
  invariants; the sibling does (and may emit findings into
  `docs/audit/findings/` as its remediation path).

### → operability-and-hygiene-enforcement (Subproblem 6)

- **Dashboard fields.** `Tau.Factory.Findings.all/0` exposes the
  list; the operability sibling computes counts
  (`findings_open / findings_waived / findings_remediated_this_week
  / waivers_expiring_within_7d / probes_green_on_main_but_open`) for
  its dashboard.
- **Health-gate halt surfacing.** When `mix tau.audit.health`
  writes `.claude/STOP-FACTORY`, the operability dashboard
  surfaces "FACTORY HALTED — audit health" with links to the
  failing finding IDs.
- **MCP layer (optional, deferred).** If the operability sibling
  later adopts an MCP knowledge-graph server for agent-side query
  (Proposal 2's deferred element), it mirrors from
  `priv/factory/findings.json` — never the inverse. CI's
  authoritative input remains the committed JSON.

### → intent-capture-and-ac-binding (Subproblem 1)

- **Disjoint scopes.** This leaf gates code shape against audit
  findings; that leaf gates AC tokens against tests. They share
  no contract; the only overlap is the `polya-audit` plugin's
  template directory.

## Silent-skip impossibility — implementation-level

Root §C is satisfied at FIVE layers; "silent" means "the violation
or omission produces no merge-block signal." Each layer is a
mechanical, scriptable check, not a process discipline.

1. **Type-system layer.** The single consumption contract
   `Findings.applicable_to/2` has return type
   `{:checked, [Finding.t()], []}`. The third tuple element is
   typed as the empty list. There is no `:skipped` return; Dialyzer
   rejects any call site whose pattern would treat the third
   element as non-empty. A property test
   (`test/tau/factory/findings_test.exs`) generates 1000 calls and
   asserts the third element is always `[]`.

2. **Probe behaviour layer.** A probe returns `:ok` or
   `{:violation, map()}`. The atom `:skipped` is not a valid
   return value. A probe whose `applicable?/1` returns `false` is
   reported in the ledger as `applicable: false, gate_run: false,
   verdict: :n_a` — a *positive* row, not an absence.

3. **Coverage Ledger layer.** `CoverageLedger.validate!/2` raises
   when any open finding lacks a row, when any `applicable: true`
   row has `gate_run: false`, or when any `gate_run: true` row
   lacks `evidence_path`. The ledger is uploaded as a CI artifact
   and the validation is invoked in `mix tau.audit.gate` itself,
   so the gate cannot exit zero without the ledger being valid.

4. **Workflow-file layer.** `test/ci/workflow_lint_test.exs`
   parses every `audit-*` workflow YAML and asserts:
   no `continue-on-error: true` on audit jobs; no `if:` predicate
   evaluating to false-by-default; no `|| true` in audit job
   commands; the `audit-coverage` job is present in every PR
   workflow. This test runs on every PR (NOT only when workflows
   change), so a malicious or careless workflow edit that would
   silence the gate is itself caught by a gate.

5. **Health-gate layer.** `mix tau.audit.health` runs nightly on
   `main`. An open finding whose probe returns `:ok` is a
   *positive* signal (the probe has lost its teeth or the
   violation was silently fixed). The workflow halts the factory
   loop by writing `.claude/STOP-FACTORY`, which the
   `factory-loop.md` kill-switch reads at the start of every
   factory step. A silently-passing finding cannot survive past
   the next health-gate cron tick (latency ≤ 24h + one factory
   step).

The composition of layers 1+2 makes silent-skip syntactically
impossible. Layers 3+4 make silent-skip surface-area-impossible
(the ledger has a row per finding; the workflow has no skip
patterns). Layer 5 makes silent-going-stale impossible (a probe
that lost its teeth halts the loop). The only failure mode this
leaf does NOT close is "no finding was ever authored for this
violation class" — owned by §F (Backward integration) and the
bootstrap sweep.

## Migration sketch

The Build-order (§Build-order below) is the migration. The plan
adds one new directory (`docs/audit/findings/`), one new module
namespace (`Tau.Factory.Audit.*` + `Tau.Factory.Findings`), three
Mix tasks, four CI workflows, and one plugin skill — all additive.
No existing module is modified except `mix.exs` (the
`:ex_json_schema` dep) and `.claude/settings.json` (one
PreToolUse hook entry). The bootstrap PR sweep (B8) is the only
human-in-loop work; the registry catches *new* uningested
findings as soon as B5 lands. The factory loop's `/pr` skill is
unchanged; the audit gate appears as one additional CI check the
loop's `freshness re-check` already waits on.

## Build-order

Strict dependency ordering. Each step is independently shippable
(opens one PR, passes the existing factory-loop gates). No step's
PR depends on a later step's artifact being live.

### Week 1 — substrate (deliverable: registry can be authored, but does not yet gate)

- **B1 — Schema + pure-data structs.** Land
  `docs/audit/finding-schema.json`,
  `docs/audit/SPEC-AUDIT-INGESTION.md` (the SPEC §3 invariants per
  `spec-before-code.md`), `lib/tau/factory/audit/finding.ex`,
  `lib/tau/factory/audit/surface.ex` (`intersects?/2` with
  `StreamData` properties), `lib/tau/factory/audit/diff.ex`,
  `lib/tau/factory/audit/probe.ex` (behaviour only, no
  implementations). Tests: `finding_test.exs`, `surface_test.exs`,
  `probe_test.exs` (behaviour-conformance). Closes nothing user-
  visible; pure data layer + behaviour.
  *Depends on:* `:ex_json_schema` Hex dep added.

- **B2 — Compiler task.** Land `lib/mix/tasks/tau.audit.compile.ex`
  and `lib/tau/factory/findings.ex` (generated). Single hand-
  written sample finding under `docs/audit/findings/F-2026-05-
  SAMPLE-001.md` proves the round-trip. Compile-time SHA check.
  Closes AC item (a) for the schema shape.
  *Depends on:* B1.

- **B3 — Consumption contract.** Land
  `Findings.applicable_to/2` with property tests proving the
  third tuple element is always `[]`. Generated module's Dialyzer
  spec enforces the type. Closes AC item (c).
  *Depends on:* B2.

### Week 2 — execution and silent-skip closure

- **B4 — Coverage Ledger.** Land
  `lib/tau/factory/coverage_ledger.ex` (`emit/2`, `validate!/2`).
  Unit tests cover the three failure modes. The ledger is SARIF-
  shaped (Proposal 1's design) for future GitHub Code Scanning
  ingestion. Closes the silent-skip-impossibility surface for this
  leaf at substrate level.
  *Depends on:* B3.

- **B5 — Gate task + CI wiring.** Land
  `lib/mix/tasks/tau.audit.gate.ex`,
  `.github/workflows/audit-registry.yml`,
  `.github/workflows/audit-coverage.yml`,
  `.github/workflows/audit-workflow-lint.yml`,
  `test/ci/workflow_lint_test.exs`. After B5: every PR carries a
  ledger; no PR can merge without one. The sample finding from
  B2 has a stub probe that always returns `:ok` (no real
  violations gated yet — the wiring is verified end-to-end on
  the no-op finding). Closes AC item (g) for CI integration.
  *Depends on:* B4.

- **B6 — Meta-test.** Land
  `test/tau/factory/meta_audit_probe_test.exs` and
  `test/tau/factory/golden_findings_test.exs`. Verifies a
  synthetic finding fires on a probe diff; verifies removing
  the synthetic finding removes the block. Closes AC item (d).
  *Depends on:* B5.

### Week 3 — probe authoring + first real finding + staleness gate

- **B7 — Probe behaviour, first concrete probe, first real
  finding.** Land
  `lib/tau/factory/audit/probes/port_lifecycle_rescue.ex`,
  `docs/audit/findings/F-V1-NORESCUE-001-bash.md` (the Bash
  adapter rescue from the v1 archive), `proven_at_sha` set to
  the commit at which the v1 audit was written. Pair with
  pre-merge-code-gates sibling's runner. Verifies the
  end-to-end loop on a real case (closes AC item (e) partially —
  one of seven rescue sites).
  *Depends on:* B6.

- **B8 — Health gate + plugin surface + scaffold task.** Land
  `lib/mix/tasks/tau.audit.health.ex`,
  `.github/workflows/audit-health.yml`,
  `lib/mix/tasks/tau.audit.scaffold.ex`,
  `.claude/plugins/polya-audit/skills/audit-finding-author.md`,
  `.claude/plugins/polya-audit/commands/audit-add.md`,
  `.claude/plugins/polya-audit/agents/audit-author.md`,
  `.claude/plugins/polya-audit/templates/audit-finding.md`,
  `.claude/plugins/polya-audit/templates/audit-probe.ex.eex`,
  `.claude/hooks/pre-commit-audit-finding.py`. After B8: the
  factory halts overnight when a probe loses its teeth; new
  findings can be authored via `/polya-audit:audit-add`.
  *Depends on:* B7.

### Week 4 — backfill + handoff

- **B9 — Bootstrap import.** Land
  `lib/mix/tasks/tau.audit.import.ex`. Run it; review the
  generated draft findings; commit one PR per surface group
  (estimate ~10 PRs of ~3-5 findings each). Each PR's gate is
  the existing factory-loop. Closes AC item (e) in full.
  *Depends on:* B8.

- **B10 — Dashboard handoff.** Expose `Findings.all/0` via a JSON
  endpoint and the SARIF artifact via GitHub Actions artifact
  download. Hand off to operability-and-hygiene-enforcement
  sibling. Closes AC item (f) for the dashboard surface; the
  sibling owns rendering.
  *Depends on:* B9.

After B5: silent-skip-impossibility is in force.
After B6: the meta-test guarantees the loop is alive.
After B7: the first real audit finding is mechanically gated.
After B8: staleness is caught nightly and halts the loop.
After B9: the v1 archive backlog is registered.
After B10: operability surfaces the registry to the dashboard.

## Open questions

- **AST-selector vocabulary ceiling.** The `Surface.ast_selector`
  field is a named atom (`:rescue_or_catch_exit`, etc.); adding a
  new shape requires Elixir code, not just YAML. The set is finite
  and small (the v1 archive surfaces ~6 distinct AST patterns), but
  novel invariant kinds will need a probe author. Open: do we want
  a more expressive AST DSL (Sourceror-based)? Decision deferred to
  first probe that needs it (Proposal 4's deferral; this hybrid
  inherits it).
- **`proven_at_sha` performance on historical trees.** The B2/B7
  compile-time probe-replay against arbitrary SHAs requires
  `git worktree add <tmp> <sha>` plus a fresh `mix compile` if
  dependencies differ. For AST-only probes this is cheap; for
  probes that need a working `mix` build, it may exceed CI budget.
  Mitigation: AST-only probes for v1 backfill; nightly tier for
  build-needing probes. Open: do we need a probe `tier` field
  (Proposal 4 mentions `tier: :ast | :unit | :integration |
  :nightly`)? Recommend adding it in B7 if any v1 probe needs it.
- **Cross-PR finding authorship lag.** A finding authored on PR #X
  is not in-force until PR #X merges and `priv/factory/findings.
  json` is rebuilt on `main`; concurrent PR #Y introducing the
  same violation will not be gated. This is a deliberate
  consistency choice (registry-of-record == `origin/main`,
  Proposal 1's discipline) but may surprise authors. Mitigation:
  CI comment on PR #X warning that the finding is "in-force after
  merge."
- **Finding-id allocation discipline.** `F-2026-05-NORESCUE-007`
  is the suggested format (year-month + kind + sequence) but
  collisions across concurrent PRs are possible. Recommend
  `mix tau.audit.scaffold` allocates IDs from a registry-side
  monotonic counter at commit time, OR uses a UUID prefix (less
  pretty, collision-free).
- **Waiver approver authority.** The `waiver.approver` field is
  validated as an email; no check on whether that email has
  authority to approve. For Tau's single-author phase this is
  acceptable; multi-author requires a `WAIVERS-APPROVERS.md`
  allowlist (out of scope for the leaf).
- **Probe staleness vs probe-version drift.** A probe whose source
  changes after `proven_at_sha` is recorded — does the compile task
  re-verify against the historical tree on every compile, or only
  when the probe source changes? Recommend: re-verify on every PR
  whose diff touches `lib/tau/factory/audit/probes/`. Otherwise
  trust the recorded SHA. Decision: implementation detail of B2.

## Linked sub-problems / proposals

- `proposals/proposal-1.md` — Versioned Finding Registry + Coverage
  Ledger; provides the substrate, the type-system silent-skip
  closure, and the single consumption contract.
- `proposals/proposal-2.md` — Claude memory cascade + MCP knowledge-
  graph; rejected as primary (non-hermetic CI, cascade not designed
  as registry) but the plugin-skill extension pattern is borrowed
  for the `polya-audit` plugin's authoring surface.
- `proposals/proposal-3.md` — Datalog/EDN knowledge base; rejected
  as primary (high LOC, low BEAM-ecosystem fit) but the
  workflow-lint test (`test/ci/workflow_lint_test.exs`) layer-2
  silent-skip defence and the golden-findings test are lifted.
- `proposals/proposal-4.md` — Adversarial probes with
  `proven_at_sha` + nightly health gate; provides the staleness
  closure that Proposal 1 leaves open. Generalises v1's
  mutation-check (gate 5.3) from AC tests to audit probes.

## Revision history

- (revision 0 — initial leaf-mode synthesis; hybrid of P1 + P4
  with borrowed elements from P3 (workflow-lint) and P2 (plugin
  extension pattern).)
