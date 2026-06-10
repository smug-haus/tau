---
template_version: 1
template_name: problem
node_id: corrective-actions-trustworthiness-declared-semantics-and-test-fidelity
parent: ../../problem.md
depth: 1
mode: leaf
status: draft
---

# Leaf — trustworthiness audit slice A (declared-semantics + test fidelity)

## Statement

Process the trustworthiness audit findings cited in the **eight
proposer files** under
`docs/problems/subproblems/declared-semantics-fidelity/proposals/` and
`docs/problems/subproblems/test-fidelity/proposals/`. For every finding
cited in these proposers, produce one catalogue entry per finding that
extracts the verbatim `path:line` evidence, names the v1 mechanism that
should have caught it (or "none"), and binds the entry to exactly one
of the six factory-v2 design dimensions under
`docs/factory-v2/design/subproblems/`.

## Slice scope (input files, exhaustive)

- `docs/problems/subproblems/declared-semantics-fidelity/problem.md`
  (the dimension framing).
- `docs/problems/subproblems/declared-semantics-fidelity/proposals/proposal-1.md`
  (census method).
- `docs/problems/subproblems/declared-semantics-fidelity/proposals/proposal-2.md`
  (deep-dive method).
- `docs/problems/subproblems/declared-semantics-fidelity/proposals/proposal-3.md`
  (adversarial method).
- `docs/problems/subproblems/declared-semantics-fidelity/proposals/proposal-4.md`
  (delta method).
- `docs/problems/subproblems/test-fidelity/problem.md` (the dimension
  framing).
- `docs/problems/subproblems/test-fidelity/proposals/proposal-1.md`
  through `proposal-4.md` (census / deep-dive / adversarial / delta
  methods).

The slice owns **8 proposer files plus the 2 dimension problem.md
files** — 10 files total. Proposers are the citation source; the
dimension problem.md provides framing (read once, not re-cited).

## Context

The parent problem (`../../problem.md`) requires every cited finding
from the trustworthiness audit's 20 proposer files to produce a
catalogue entry. This leaf processes the declared-semantics-fidelity
and test-fidelity dimensions (the "what the system claims to do" and
"what the test suite proves about claims" axes). The remaining three
trustworthiness dimensions are processed by the sibling
`trustworthiness-error-observability-architecture`; the v1 module audit
is processed by the two `v1-modules-*` siblings.

## Complecting hypothesis

These two dimensions share a citation-evidence shape: most findings
contrast a declared contract (in code, docs, or spec) against an actual
runtime path or test path. Bundling them lets the leaf consistently
record the "claim → contradicting path" pair as a single catalogue
field across both dimensions, rather than splitting that field shape
across siblings.

## Decomposition strategy

(leaf — proceed to proposals)

## Acceptance criteria

- **AC-1 — Per-finding extraction.** Every cited finding in the
  slice's 8 proposer files produces at least one catalogue entry.
  A proposer typically cites several findings; each finding is a
  separate row. Misses are gate failures.

- **AC-2 — Cited evidence carried through.** Each entry records the
  verbatim `path:line` (or `commit:sha`) the proposer cited. No
  synthesised line numbers; no "approximately" references; the entry
  must round-trip to the proposer's literal citation. Where the
  proposer cites a code path and a contradicting test path, both
  citations are preserved (catalogue field `evidence_paths` holds a
  list).

- **AC-3 — Machine-readable output + Markdown render.** Output is two
  artifacts:
  - YAML row entries appended to
    `docs/factory-v2/corrective-actions/subproblems/trustworthiness-declared-semantics-and-test-fidelity/findings.yaml`
    keyed by a stable per-finding id (e.g.
    `declared-semantics-fidelity/proposal-2/F-03`).
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
  (e.g. `otp-non-negotiables.md §1`, `spec-before-code.md §Critic
  gate`, `factory-loop.md §Gate 5.2`). Where no v1 mechanism existed,
  the field is literally `"none"`.

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
- **Findings outside this slice's two trustworthiness dimensions.**
  `error-handling-fidelity`, `observability-fidelity`, and
  `architecture-and-rule-conformance` proposers are processed by the
  sibling `trustworthiness-error-observability-architecture`. The v1
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
  leaf treats them identically: each citation, regardless of method,
  produces a row.
- The 6 dimension leaves live at
  `docs/factory-v2/design/subproblems/<dim>/problem.md`; read each
  dimension's problem.md once to ground binding decisions.
- Use the stable finding-id scheme
  `<trustworthiness-dim>/<proposal-file>/F-NN` so collisions across
  siblings are impossible.
