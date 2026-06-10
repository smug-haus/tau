---
template_version: 1
template_name: problem
node_id: corrective-actions-root
parent: null
depth: 0
mode: non-leaf
---

# Root problem — produce the corrective-actions catalogue for v1 audit findings

## Inputs

- The trustworthiness audit at `docs/problems/` — 5 leaf dimensions
  (declared-semantics-fidelity, test-fidelity, error-handling-fidelity,
  observability-fidelity, architecture-and-rule-conformance), 20
  proposer files (4 per leaf × census/deep-dive/adversarial/delta
  methods), each with cited `path:line` evidence and a sub-verdict.
- The archived v1 module audit at `docs/problems-archive-v1-modules/` —
  41 leaf solution + validation pairs, 11 module-root solution +
  validation pairs.
- The 10 failure classes enumerated in
  `docs/factory-v2/design/problem.md` §Hypothesis.
- The 6 dimensions of factory capability the factory-v2 design
  decomposer produced (at
  `docs/factory-v2/design/subproblems/*/problem.md`).

## What this audit must produce

A **corrective-actions catalogue** — one entry per cited audit finding,
each entry mapping that finding to the v2 factory mechanism that
prevents the class. Specifically:

For every finding cited in the trustworthiness audit's 20 proposer
files AND every solution/validation pair in the archived v1 module
audit, produce a catalogue entry with the structure:

- **What failed** — verbatim citation at `path:line` (or `commit:sha`
  for git evidence), with the specific assertion the finding made.
- **v1 mechanism that should have caught it** — the documented rule
  (OTP NN clause, factory-loop section, spec-before-code provision,
  worktree-discipline clause, etc.) that the failure violated. If
  none existed, state "none."
- **v2 factory mechanism** — the dimension of factory capability
  (one of the 6 leaves under `docs/factory-v2/design/subproblems/`)
  that owns prevention; the specific mechanism within that dimension
  that closes the class; whether the mechanism is a Mix gate, CI
  workflow step, hook, AST scan, AST + git scan, branch-protection
  rule, or agent-with-mechanical-fallback.

The catalogue is **input to the v2 factory's first run** — its initial
backlog. Each entry is the v2 factory's machine-readable assertion of
what to enforce on the next PR touching the affected surface.

## Acceptance criteria

- **A — Per-finding coverage.** Every finding cited in any of the 20
  trustworthiness proposers OR any of the 41 v1 module-audit
  solution/validation pairs receives at least one catalogue entry.
  Misses are gate failures.

- **B — No agent-only mechanisms.** The "v2 factory mechanism" column
  may not name "critic reviews", "reviewer reviews", "implementer
  follows discipline", or any other agent-self-report mechanism as
  sole closure. Mechanism MUST be machine-checkable.

- **C — Catalogue is enumerated, not synthesised.** The catalogue
  contains entries grounded in cited evidence. New conclusions /
  recommendations / "while we're here" additions are out of scope —
  the trustworthiness audit and the v1 module audit are the only
  inputs.

- **D — Dimension binding.** Each entry's v2 mechanism MUST cite the
  factory-v2 design dimension (one of the 6 leaves) that owns it. If
  no dimension owns a class, the catalogue surfaces the gap; the gap
  becomes input to a design-cycle revision (a follow-on Polya cycle,
  not a manual synthesis).

- **E — Machine-readable output.** The catalogue's primary output is
  a structured registry (YAML or JSON) at
  `.claude/policies/audit-debt.yaml` that the v2 factory can ingest
  directly. The Markdown render is for human review only.

## Decomposition guidance

The next step MUST decompose this problem into MECE sub-problems that
are **slices of the input corpus** — each leaf processes one bounded
slice of the audit findings end-to-end (extract → bind to dimension →
emit catalogue entries). Suggested slicing:

1. v1 module audit slice 1: tau-session + tau-tui-app
   (the two highest-LOC modules, broadest finding surface).
2. v1 module audit slice 2: tau-providers + tau-coding-agent +
   tau-tools-hooks-mcp (provider/tool dispatch surface).
3. v1 module audit slice 3: tau-memory + tau-settings +
   tau-permissions + tau-extensions + tau-infrastructure +
   tau-cli (remaining modules).
4. Trustworthiness audit slice — declared-semantics-fidelity +
   test-fidelity proposers (4 + 4 files).
5. Trustworthiness audit slice — error-handling-fidelity +
   observability-fidelity + architecture-and-rule-conformance
   proposers (4 + 4 + 4 files).

The decomposer MAY rebalance or re-slice, with MECE preserved.

## Out of scope

- New audit findings not present in the input corpus.
- Designing the v2 mechanisms (workstream 1's design pipeline owns
  that).
- Recommending which corrective actions to do first / priority
  ranking — that is the v2 factory's job once it runs, not the
  catalogue's.
- Rewriting / re-validating the input findings.

## Background

The user's correction: the coordinator wrote a manual 600-line
catalogue in its own context (`docs/factory-v2/corrective-actions.md`,
since deleted). That violates the audit framework's purpose — the
framework exists precisely because the coordinator's in-context
synthesis cannot be trusted on quality-bearing content. The catalogue
is now produced through the same Polya pipeline as everything else
quality-bearing in this project.

## Sub-problems

Axis: **slices of the input audit corpus** — each leaf processes one
bounded slice end-to-end (extract findings → bind each finding to one
of the 6 factory-v2 design dimensions → emit catalogue entries). The
v1 module audit (11 modules, 41 leaves, 11 module-roots) is split into
two slices balanced by validation-LOC; the trustworthiness audit
(5 dimensions × 4 proposers = 20 proposers) is split into two slices
balanced by citation-evidence shape.

1. `subproblems/v1-modules-session-tui-providers-tools-coding/problem.md`
   — v1 module audit slice A: `tau-session`, `tau-tui-app`,
   `tau-providers`, `tau-coding-agent`, `tau-tools-hooks-mcp` (5
   modules: 20 leaves + 5 module-roots; the high-coupling runtime
   subset).
2. `subproblems/v1-modules-cli-memory-settings-permissions-extensions-infrastructure/problem.md`
   — v1 module audit slice B: `tau-cli`, `tau-memory`, `tau-settings`,
   `tau-permissions`, `tau-extensions`, `tau-infrastructure` (6
   modules: 21 leaves + 6 module-roots; the support subset).
3. `subproblems/trustworthiness-declared-semantics-and-test-fidelity/problem.md`
   — trustworthiness slice A: `declared-semantics-fidelity` +
   `test-fidelity` proposers (8 proposer files; "claim → contradicting
   path" evidence shape).
4. `subproblems/trustworthiness-error-observability-architecture/problem.md`
   — trustworthiness slice B: `error-handling-fidelity` +
   `observability-fidelity` + `architecture-and-rule-conformance`
   proposers (12 proposer files; "rule → violating path" evidence
   shape).

MECE: every input file in the corpus maps to exactly one slice
(disjoint module sets across v1 slices; disjoint trustworthiness
dimensions across the two trustworthiness slices; v1 and trustworthiness
corpora live in physically separate directories). Each leaf is
independently solvable — it ingests its slice, binds to the (shared,
read-only) 6 factory-v2 dimension leaves, and emits its own
`findings.yaml` + `findings.md` artifacts without coordinating with
siblings.
