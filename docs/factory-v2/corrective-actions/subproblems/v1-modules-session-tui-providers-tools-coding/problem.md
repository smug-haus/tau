---
template_version: 1
template_name: problem
node_id: corrective-actions-v1-modules-session-tui-providers-tools-coding
parent: ../../problem.md
depth: 1
mode: leaf
status: draft
---

# Leaf — v1 module audit slice A (session, tui-app, providers, coding-agent, tools-hooks-mcp)

## Statement

Process the v1 module audit findings for the **five highest-coupling
runtime modules**: `tau-session`, `tau-tui-app`, `tau-providers`,
`tau-coding-agent`, `tau-tools-hooks-mcp`. For every finding cited in
these modules' inputs, produce one catalogue entry per finding that
extracts the verbatim `path:line` evidence, names the v1 mechanism that
should have caught it (or "none"), and binds the entry to exactly one
of the six factory-v2 design dimensions under
`docs/factory-v2/design/subproblems/`.

## Slice scope (input files, exhaustive)

Per module, process **both** the module-root pair AND every leaf's
pair:

- `docs/problems-archive-v1-modules/tau-session/{problem,solution,validation}.md`
  - subproblems: `cancellation-teardown`, `cross-cutting-data`,
    `fsm-facade-helpers`, `user-message-routing` — each with
    `{problem,solution,validation}.md` plus any `proposals/`.
- `docs/problems-archive-v1-modules/tau-tui-app/{problem,solution,validation}.md`
  - subproblems: `duplicated-bounded-append`, `model-as-bag-of-maps`,
    `session-side-effects-in-pure-modules`, `transcript-coupling`.
- `docs/problems-archive-v1-modules/tau-providers/{problem,solution,validation}.md`
  - subproblems: `auth-resolution-scatter`, `callback-contract-drift`,
    `capabilities-flag-fidelity`, `usage-normalisation`.
- `docs/problems-archive-v1-modules/tau-coding-agent/{problem,solution,validation}.md`
  - subproblems: `port-lifecycle-rescue`, `router-outer-rescue`,
    `settings-feature-flag-access`, `tool-impl-rescue-ladders`.
- `docs/problems-archive-v1-modules/tau-tools-hooks-mcp/{problem,solution,validation}.md`
  - subproblems: `dynamic-module-generation`, `io-collectors`,
    `mcp-server-concurrency`, `tool-result-contract`.

The slice owns **20 leaf solution+validation pairs and 5 module-root
solution+validation pairs**. Validations are typically the densest
citation source; solutions name the rule the finding violated.

## Context

The parent problem (`../../problem.md`) requires every cited finding
from the v1 module audit to produce a catalogue entry mapping it to a
factory-v2 prevention mechanism. This leaf processes the high-coupling
subset of that corpus. The remaining six modules are processed by the
sibling `v1-modules-cli-memory-settings-permissions-extensions-infrastructure`;
the trustworthiness-audit corpus is processed by the two
`trustworthiness-*` siblings.

## Complecting hypothesis

The five modules in this slice share a tendency to braid process
lifecycle, stream protocol, and tool dispatch into single GenServer /
GenStatem clauses, making findings here dominated by OTP-non-negotiable
and supervision-tree concerns. Bundling them keeps related findings
proximate during extraction, so the leaf can recognise repeat patterns
(e.g. the same rescue-ladder violation cited across coding-agent and
tools-hooks-mcp) without de-duplicating across siblings.

## Decomposition strategy

(leaf — proceed to proposals)

## Acceptance criteria

- **AC-1 — Per-finding extraction.** Every cited finding in the slice's
  25 input files (`problem.md`, `solution.md`, `validation.md` at the
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
    `docs/factory-v2/corrective-actions/subproblems/v1-modules-session-tui-providers-tools-coding/findings.yaml`
    keyed by a stable per-finding id (e.g.
    `tau-session/cancellation-teardown/F-01`).
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
  (e.g. `otp-non-negotiables.md §1`, `worktree-discipline.md
  §pre-spawn`, `factory-loop.md §Gate 5.2`, `spec-before-code.md
  §Critic gate`). Where no v1 mechanism existed, the field is literally
  `"none"` — this is the case the v2 factory's first run must close.

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
- **Findings outside this slice's modules.** `tau-cli`, `tau-memory`,
  `tau-settings`, `tau-permissions`, `tau-extensions`,
  `tau-infrastructure` are processed by the sibling
  `v1-modules-cli-memory-settings-permissions-extensions-infrastructure`.
  Trustworthiness-audit proposers are processed by the two
  `trustworthiness-*` siblings.
- **Designing the v2 mechanisms.** The leaf cites the relevant
  factory-v2 design dimension; it does NOT extend, refine, or critique
  the dimension's design.
- **Re-validating the input findings.** The leaf treats every cited
  finding as a given fact. It does NOT re-read source code to confirm
  or refute the finding.

## Notes for the proposer

- The verbatim citation may appear in the leaf's `problem.md`,
  `solution.md`, `validation.md`, or any file under `proposals/`. All
  four locations are in scope; do not skip a file because another in
  the same leaf already cited the same line.
- The 6 dimension leaves live at
  `docs/factory-v2/design/subproblems/<dim>/problem.md`; read each
  dimension's problem.md once to ground binding decisions.
- Use a stable finding-id scheme (`<module>/<leaf-or-root>/F-NN`) so
  two slices independently extracting findings from the same module
  would not collide. (This slice owns the full module; siblings own
  different modules; collision is impossible within this leaf.)
