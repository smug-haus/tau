---
template_version: 1
template_name: problem
node_id: corrective-actions-v1-modules-cli-memory-settings-permissions-extensions-infrastructure
parent: ../../problem.md
depth: 1
mode: leaf
status: draft
---

# Leaf — v1 module audit slice B (cli, memory, settings, permissions, extensions, infrastructure)

## Statement

Process the v1 module audit findings for the **six lower-coupling
support modules**: `tau-cli`, `tau-memory`, `tau-settings`,
`tau-permissions`, `tau-extensions`, `tau-infrastructure`. For every
finding cited in these modules' inputs, produce one catalogue entry
per finding that extracts the verbatim `path:line` evidence, names the
v1 mechanism that should have caught it (or "none"), and binds the
entry to exactly one of the six factory-v2 design dimensions under
`docs/factory-v2/design/subproblems/`.

## Slice scope (input files, exhaustive)

Per module, process **both** the module-root pair AND every leaf's
pair:

- `docs/problems-archive-v1-modules/tau-cli/{problem,solution,validation}.md`
  - subproblems: `error-swallowing-rescues`,
    `reflective-module-dispatch`, `run-loop-raw-receive`,
    `wizard-data-fidelity` — each with
    `{problem,solution,validation}.md` plus any `proposals/`.
- `docs/problems-archive-v1-modules/tau-memory/{problem,solution,validation}.md`
  - subproblems: `finch-name-mismatch`, `pending-rot-observability`,
    `retry-recovery-path`, `silent-failure-propagation`.
- `docs/problems-archive-v1-modules/tau-settings/{problem,solution,validation}.md`
  - subproblems: `merge-invariant-properties`,
    `schema-exception-as-flow`, `watcher-exit-catch`.
- `docs/problems-archive-v1-modules/tau-permissions/{problem,solution,validation}.md`
  - subproblems: `evaluator-mode-complecting`,
    `matcher-unit-contracts`, `mode-lattice-properties`,
    `settings-merge-feed`.
- `docs/problems-archive-v1-modules/tau-extensions/{problem,solution,validation}.md`
  - subproblems: `atom-internment`, `unload-resilience`.
- `docs/problems-archive-v1-modules/tau-infrastructure/{problem,solution,validation}.md`
  - subproblems: `circuit-breaker-invariant-split`,
    `global-name-collision`, `supervision-tree-startup`,
    `telemetry-handler-coupling`.

The slice owns **21 leaf solution+validation pairs and 6 module-root
solution+validation pairs**. Validations are typically the densest
citation source; solutions name the rule the finding violated.

## Context

The parent problem (`../../problem.md`) requires every cited finding
from the v1 module audit to produce a catalogue entry mapping it to a
factory-v2 prevention mechanism. This leaf processes the lower-coupling
support modules. The high-coupling runtime modules are processed by
the sibling
`v1-modules-session-tui-providers-tools-coding`; the
trustworthiness-audit corpus is processed by the two
`trustworthiness-*` siblings.

## Complecting hypothesis

The six modules in this slice share a tendency to mix configuration,
schema, and external-resource lifecycle concerns with their core
function, making findings here dominated by data-fidelity, exception-
as-flow, and observability-gap concerns. Bundling them lets the leaf
recognise the recurring "exception as flow" anti-pattern across
settings, cli, and extensions without spreading its citation across
siblings.

## Decomposition strategy

(leaf — proceed to proposals)

## Acceptance criteria

- **AC-1 — Per-finding extraction.** Every cited finding in the slice's
  27 input files (`problem.md`, `solution.md`, `validation.md` at the
  module root and at each named leaf, plus any files under each leaf's
  `proposals/`) produces at least one catalogue entry. The
  extraction is exhaustive: a finding asserted in any of these files
  yields a row.

- **AC-2 — Cited evidence carried through.** Each entry records the
  verbatim `path:line` (or `commit:sha`) the source finding cited. No
  synthesised line numbers; no "approximately" references; the entry
  must round-trip to the source's literal citation.

- **AC-3 — Machine-readable output + Markdown render.** Output is two
  artifacts:
  - YAML row entries appended to
    `docs/factory-v2/corrective-actions/subproblems/v1-modules-cli-memory-settings-permissions-extensions-infrastructure/findings.yaml`
    keyed by a stable per-finding id (e.g.
    `tau-cli/error-swallowing-rescues/F-01`).
  - A Markdown render at `./findings.md` enumerating the same rows in
    human-readable form (one row per heading).

- **AC-4 — Dimension binding.** Each entry's `dimension` field MUST be
  exactly one of the six factory-v2 design dimensions:
  `intent-capture-and-ac-binding`,
  `knowledge-memory-and-audit-ingestion`,
  `operability-and-hygiene-enforcement`,
  `post-merge-cross-artifact-coherence`,
  `pre-merge-code-gates`,
  `pre-merge-evidence-and-skip-integrity`.
  Multiple dimensions per finding is **not** permitted; if a finding
  appears to span dimensions, the leaf picks the single best-fit
  dimension and records the runners-up in `notes`. If no dimension fits,
  the entry sets `dimension: GAP` and `gap_reason` (root AC-D — the gap
  surfaces; it is not silently re-assigned).

- **AC-5 — v1 mechanism named or "none".** Each entry's `v1_mechanism`
  field names the documented rule that should have caught the failure
  (e.g. `otp-non-negotiables.md §1`, `worktree-discipline.md §pre-spawn`,
  `factory-loop.md §Gate 5.2`, `spec-before-code.md §Critic gate`).
  Where no v1 mechanism existed, the field is literally `"none"` —
  this is the case the v2 factory's first run must close.

- **AC-6 — Mechanism classification machine-checkable.** Each entry's
  `v2_mechanism_type` is one of: `mix_gate`, `ci_workflow_step`,
  `hook`, `ast_scan`, `ast_plus_git_scan`, `branch_protection_rule`,
  `agent_with_mechanical_fallback`. Per parent AC-B, no entry may set
  `v2_mechanism_type: agent_only`.

## Out of scope

- **New findings.** The leaf extracts only findings already cited in
  the slice's input files; it does NOT generate new audit observations
  while reading.
- **Synthesis or thematic summary.** The leaf produces enumerated
  catalogue rows; it does NOT produce narrative summary, executive
  summary, or category overviews. (Root AC-C.)
- **Prioritisation / ranking.** The leaf does NOT order findings by
  severity, importance, or remediation cost. (Root §Out of scope.)
- **Findings outside this slice's modules.** `tau-session`,
  `tau-tui-app`, `tau-providers`, `tau-coding-agent`,
  `tau-tools-hooks-mcp` are processed by the sibling
  `v1-modules-session-tui-providers-tools-coding`. Trustworthiness-
  audit proposers are processed by the two `trustworthiness-*` siblings.
- **Designing the v2 mechanisms.** The leaf cites the relevant
  factory-v2 design dimension; it does NOT extend, refine, or critique
  the dimension's design.
- **Re-validating the input findings.** The leaf treats every cited
  finding as a given fact. It does NOT re-read source code to confirm
  or refute the finding.

## Notes for the proposer

- The verbatim citation may appear in the leaf's `problem.md`,
  `solution.md`, `validation.md`, or any file under `proposals/`. All
  four locations are in scope.
- The 6 dimension leaves live at
  `docs/factory-v2/design/subproblems/<dim>/problem.md`; read each
  dimension's problem.md once to ground binding decisions.
- Use a stable finding-id scheme (`<module>/<leaf-or-root>/F-NN`) so
  collisions across siblings are impossible — this slice owns the
  full module; siblings own different modules.
