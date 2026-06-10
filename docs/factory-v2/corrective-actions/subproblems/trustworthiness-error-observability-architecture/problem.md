---
template_version: 1
template_name: problem
node_id: corrective-actions-trustworthiness-error-observability-architecture
parent: ../../problem.md
depth: 1
mode: leaf
status: draft
---

# Leaf — trustworthiness audit slice B (error-handling + observability + architecture-and-rule conformance)

## Statement

Process the trustworthiness audit findings cited in the **twelve
proposer files** under
`docs/problems/subproblems/error-handling-fidelity/proposals/`,
`docs/problems/subproblems/observability-fidelity/proposals/`, and
`docs/problems/subproblems/architecture-and-rule-conformance/proposals/`.
For every finding cited in these proposers, produce one catalogue
entry per finding that extracts the verbatim `path:line` evidence,
names the v1 mechanism that should have caught it (or "none"), and
binds the entry to exactly one of the six factory-v2 design dimensions
under `docs/factory-v2/design/subproblems/`.

## Slice scope (input files, exhaustive)

- `docs/problems/subproblems/error-handling-fidelity/problem.md`
  (the dimension framing).
- `docs/problems/subproblems/error-handling-fidelity/proposals/proposal-1.md`
  through `proposal-4.md` (census / deep-dive / adversarial / delta
  methods).
- `docs/problems/subproblems/observability-fidelity/problem.md`.
- `docs/problems/subproblems/observability-fidelity/proposals/proposal-1.md`
  through `proposal-4.md`.
- `docs/problems/subproblems/architecture-and-rule-conformance/problem.md`.
- `docs/problems/subproblems/architecture-and-rule-conformance/proposals/proposal-1.md`
  through `proposal-4.md`.

The slice owns **12 proposer files plus the 3 dimension problem.md
files** — 15 files total. Proposers are the citation source; the
dimension problem.md provides framing (read once, not re-cited).

## Context

The parent problem (`../../problem.md`) requires every cited finding
from the trustworthiness audit's 20 proposer files to produce a
catalogue entry. This leaf processes the error-handling, observability,
and architecture-and-rule-conformance dimensions (the "what the system
does when things go wrong", "what the system makes visible", and "what
the system structurally must obey" axes). The remaining two
trustworthiness dimensions are processed by the sibling
`trustworthiness-declared-semantics-and-test-fidelity`; the v1 module
audit is processed by the two `v1-modules-*` siblings.

## Complecting hypothesis

These three dimensions share a citation-evidence shape: most findings
contrast a structural rule (OTP non-negotiable, supervision tree
shape, telemetry namespace) or a fault-tolerance contract against an
actual code path that violates it. Bundling them lets the leaf
consistently record the "rule → violating path" pair as a single
catalogue field across all three dimensions, rather than splitting
that field shape across siblings.

## Decomposition strategy

(leaf — proceed to proposals)

## Acceptance criteria

- **AC-1 — Per-finding extraction.** Every cited finding in the
  slice's 12 proposer files produces at least one catalogue entry.
  A proposer typically cites several findings; each finding is a
  separate row. Misses are gate failures.

- **AC-2 — Cited evidence carried through.** Each entry records the
  verbatim `path:line` (or `commit:sha`) the proposer cited. No
  synthesised line numbers; no "approximately" references; the entry
  must round-trip to the proposer's literal citation. Where the
  proposer cites a violated rule and the violating code path, both
  citations are preserved (catalogue field `evidence_paths` holds a
  list).

- **AC-3 — Machine-readable output + Markdown render.** Output is two
  artifacts:
  - YAML row entries appended to
    `docs/factory-v2/corrective-actions/subproblems/trustworthiness-error-observability-architecture/findings.yaml`
    keyed by a stable per-finding id (e.g.
    `architecture-and-rule-conformance/proposal-3/F-02`).
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
  Note that "dimension" here is the **factory-v2 design dimension**
  (the prevention mechanism's owner) — NOT the trustworthiness-audit
  dimension the finding was cited under. Multiple dimensions per
  finding is **not** permitted; if no dimension fits, the entry sets
  `dimension: GAP` and `gap_reason` (root AC-D).

- **AC-5 — v1 mechanism named or "none".** Each entry's `v1_mechanism`
  field names the documented rule that should have caught the failure
  (e.g. `otp-non-negotiables.md §1`, `worktree-discipline.md §pre-spawn`,
  `factory-loop.md §Gate 5.2`, `spec-before-code.md §Critic gate`).
  Where no v1 mechanism existed, the field is literally `"none"`.

- **AC-6 — Mechanism classification machine-checkable.** Each entry's
  `v2_mechanism_type` is one of: `mix_gate`, `ci_workflow_step`,
  `hook`, `ast_scan`, `ast_plus_git_scan`, `branch_protection_rule`,
  `agent_with_mechanical_fallback`. Per parent AC-B, no entry may set
  `v2_mechanism_type: agent_only`.

## Out of scope

- **New findings.** The leaf extracts only findings already cited in
  the slice's input proposers; it does NOT generate new audit
  observations while reading.
- **Cross-method de-duplication.** Two proposers (e.g. census +
  adversarial) may cite the same `path:line` from different angles;
  each cited finding receives its own row. Cross-method merging is a
  synthesis step and is out of scope here.
- **Synthesis or thematic summary.** The leaf produces enumerated
  catalogue rows; it does NOT produce narrative summary or category
  overviews. (Root AC-C.)
- **Prioritisation / ranking.** The leaf does NOT order findings by
  severity, importance, or remediation cost. (Root §Out of scope.)
- **Findings outside this slice's three trustworthiness dimensions.**
  `declared-semantics-fidelity` and `test-fidelity` proposers are
  processed by the sibling
  `trustworthiness-declared-semantics-and-test-fidelity`. The v1
  module audit is processed by the two `v1-modules-*` siblings.
- **Designing the v2 mechanisms.** The leaf cites the relevant
  factory-v2 design dimension; it does NOT extend, refine, or critique
  the dimension's design.
- **Re-validating the input findings.** The leaf treats every cited
  finding as a given fact. It does NOT re-read source code to confirm
  or refute the finding.

## Notes for the proposer

- The 4 proposer methods (census, deep-dive, adversarial, delta) cite
  findings at different granularities — census tends to enumerate
  many shallow citations; adversarial cites fewer, deeper ones. The
  leaf treats them identically.
- The 6 dimension leaves live at
  `docs/factory-v2/design/subproblems/<dim>/problem.md`; read each
  dimension's problem.md once to ground binding decisions.
- Use the stable finding-id scheme
  `<trustworthiness-dim>/<proposal-file>/F-NN` so collisions across
  siblings are impossible.
